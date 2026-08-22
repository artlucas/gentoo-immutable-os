# 06 — Pruning & Toolchain-Free Guarantee

## Three layers of defense

1. **By construction** (stage 30): `emerge --root=` puts build-time deps (BDEPEND) in the
   *builder*, only runtime deps (RDEPEND) in the target. gcc, binutils, make, portage,
   autotools, cmake, rust, build-python simply never get installed into the target.
2. **At install time** (`INSTALL_MASK` + `FEATURES` in the target's `make.conf`): files that
   are useless at runtime are never merged into the target at all.
3. **After the fact** (stage 50): delete residue, then **assert** the guarantee and fail the
   build if anything slipped through.

## Layer 2 — INSTALL_MASK / FEATURES (target `config/portage/make.conf`)

```
FEATURES="nodoc noinfo noman"
INSTALL_MASK="
  /usr/include
  /usr/share/doc /usr/share/info /usr/share/man
  /usr/share/gtk-doc /usr/share/devhelp
  /usr/lib64/pkgconfig /usr/share/pkgconfig /usr/lib64/cmake /usr/share/cmake*
  /usr/share/aclocal
  /usr/lib64/*.a
  /usr/share/gir-1.0 /usr/share/vala        # build-time GIR XML/vapi only
  /usr/share/zsh                               # REVISIT: bash-completion kept for now; size report decides
"
```

GIR note: `/usr/lib64/girepository-1.0` is deliberately **not** masked — those typelibs are
loaded at runtime by gjs and gnome-shell. Only the `.gir` XML and `.vapi` sources above go.

Locale note: `/usr/share/locale` is deliberately **not** in INSTALL_MASK (masking it wholesale
breaks the GNOME UI-language story). Instead, v1 keeps message catalogs for a `build.conf` list
(`LOCALES_KEEP="en de fr es pt_BR it ja zh_CN ru"` default) and stage 50 deletes the rest —
measured savings vs. usability. GNOME/GTK translations follow the same list via `L10N` in the
target make.conf. `REVISIT` markers are resolved during M2 by the size report.

## Layer 3 — stage 50 prune script

Order matters — audit artifacts are saved *before* deletion:

1. **Save audit outputs** (to `/out/reports/` and a copy at
   `<target>/usr/share/${DISTRO_ID}/`):
   - `packages.txt` — every installed package + version + SIZE from the VDB.
   - `size-report.txt` — top-50 packages by installed size (drives future trimming).
   - Diff `packages.txt` against committed `config/portage/expected-packages.txt`
     (**fail build on unexplained additions** — the dependency-audit gate from 03).
2. **Delete Portage artifacts:** `/var/db/pkg` (VDB), `/var/db/repos`, `/var/cache/{distfiles,binpkgs,edb}`,
   `/etc/portage`, `/usr/share/portage`, any `/usr/lib/python*/site-packages/portage*`.
3. **Delete runtime-useless residue:** `*.la` files; static `*.a` that escaped
   INSTALL_MASK; `/usr/share/locale/<not in LOCALES_KEEP>`; `/usr/lib/firmware` blobs for
   hardware classes outside scope (`liquidio`, `netronome`, `mellanox`, `qed` — server NICs;
   list curated in `config/prune-firmware.txt`; saves ~200–400 MiB); kernel build/source
   symlinks in `/lib/modules/*/{build,source}`; `__pycache__` if any.
4. **Strip binaries:** already handled by Portage (`FEATURES=nostrip` NOT set) — verify only.
5. **tmpfiles-clean:** empty `/var/log/*`, `/var/tmp/*`, seeded machine-id blank, no bash
   history, no `/root` residue (`/root` is a symlink anyway).

## The assertion block (build FAILS if any trips)

```bash
assert_absent() { [[ -e "$T/$1" ]] && die "prune violation: $1 exists"; }

# toolchain binaries — check both explicit paths and a PATH sweep
for b in gcc g++ cc c++ cpp ld as ar make cmake ninja meson cargo rustc \
         emerge ebuild portageq equery python python3 pip perl-cpan; do
  find "$T"/usr/bin "$T"/usr/sbin "$T"/bin "$T"/sbin -name "$b" -o -name "$b-*" | grep -q . \
    && die "toolchain binary in target: $b"
done

assert_absent usr/include                 # headers
assert_absent var/db/pkg                  # VDB
assert_absent var/db/repos                # portage tree
assert_absent etc/portage
! find "$T" -name '*.la' | grep -q .      # libtool archives
! find "$T/usr/lib64" -maxdepth 1 -name '*.a' | grep -q .

# interpreter policy: python/perl allowed ONLY if a whitelisted package pulled them
# (v1 whitelist starts EMPTY — if the dep audit shows python arriving, that's a decision,
#  not an accident)
```

**GCC — the @system correction (2026-08-20, first build).** Layer 1 above says the toolchain
"simply never gets installed into the target". That premise is wrong, and the first build
proved it: `sys-devel/gcc` is a member of the profile's **@system** set
(`profiles/base/packages`: `*sys-devel/gcc`), so Portage installs it into *any* new ROOT.
`--with-bdeps=n` does not prevent it — verified by bisection, since `media-libs/mesa`,
`x11-drivers/nvidia-drivers` and `@base` each pull it identically while a leaf package like
`sys-apps/hwdata` pulls nothing. It is also the **only** provider of `libstdc++.so.6` and
`libgcc_s.so.1`, which every C++ program in a GNOME image links against, so it cannot simply
be masked away with `package.provided` either.

The guarantee is about the shipped image, so stage 50 splits the package instead:

| Removed (~270 MB) | Kept (~12 MB) |
|---|---|
| `/usr/libexec/gcc` (cc1, cc1plus, lto1, collect2) | `/usr/lib/gcc/<chost>/<ver>/lib*.so*` |
| `/usr/bin/{gcc,g++,cc,c++,cpp,gcov*,gcc-ar,…}` + `<chost>-` variants | `/etc/ld.so.conf.d/05gcc-*.conf` (so the loader finds them) |
| `<gcc libdir>/{include,include-fixed,plugin,install-tools}`, `*.a`, crt`*.o` | |

Stage 50 asserts both halves: no compiler driver in `/usr/bin`, **and** `libstdc++.so.6` +
`libgcc_s.so.1` still present — a too-aggressive prune would otherwise surface only as a
black screen in stage 70 or on real hardware. Stage 30's verify no longer treats gcc as a
leak; it checks for `rustc`/`clang`/`ld`/`as` instead, which would indicate a genuine
`--with-bdeps`/USE mistake.

**Perl — RESOLVED at the first build (2026-08-20): admitted, narrowly.** The ban tripped, and
the audit found two independent sources:

1. `x11-misc/xdg-utils[perl]` — a hard RDEPEND of both gnome-shell and gdm — gated
   `dev-perl/Net-DBus` and `dev-perl/X11-Protocol`, and Net-DBus dragged XML-Twig and the
   entire LWP/HTML perl stack behind it: **~48 packages**. What it buys is the perl
   `xdg-screensaver` implementation driving X11, which does nothing in a Wayland-only session
   where apps inhibit idle through portals. Disabled (`xdg-utils -perl`) — the cleanest 48
   packages this build removed.
2. `net-fs/samba` lists `dev-lang/perl:=` and `dev-perl/Parse-Yapp` in COMMON_DEPEND with no
   USE guard, and `gnome-control-center[cups]` requires `>=net-fs/samba-4.0.0[client]` just as
   unconditionally. So the GNOME printer panel and a perl interpreter are the same decision.

Admitted after an explicit call to keep the printer panel (plan/03's stated UX). The image
therefore ships `dev-lang/perl` and `dev-perl/Parse-Yapp` and nothing else perl-shaped. To
reverse it, set `gnome-control-center -cups`: printing still works through `net-print/cups`
(apps print normally; printers can be added at `localhost:631`), and perl leaves the image
entirely along with samba and system-config-printer.

Original caveat text (correctly predicted, wrong package): `dev-lang/perl` is an RDEPEND of some base packages
(e.g. openssl's `c_rehash`). The dep audit in stage 30 will show whether it lands; if it does
and the pull is spurious, fix with USE (`-perl`) or `package.provided` — decided during
M1/M2 with the report in hand, not guessed now. The *mechanism* is the audit gate; the
*policy* is "empty whitelist until a human approves an entry."

**Python under GNOME — RESOLVED at the first build (2026-08-20): admitted.** The ban was
tripped, the procedure below was followed, and the outcome is recorded here.

The path was not the predicted `gjs → gobject-introspection` one. `gnome-base/gnome-shell`'s
ebuild declares `dev-python/docutils` and `dev-python/pygobject` in `DEPEND` and then sets
`RDEPEND="${DEPEND}"` — folding them into the runtime dependency set. `dev-lang/python` is
therefore a genuine RDEPEND of any native GNOME image on Gentoo; `--with-bdeps=n` cannot
remove it, and the dep resolves through `gdm → gnome-settings-daemon → libnotify →
gnome-shell → docutils → pillow`. Enabling the control-center printer panel
(`gnome-control-center[cups]`) additionally brings `app-admin/system-config-printer`, which
is itself a Python application.

Admitted to the target, per step 2:

| Package | Why |
|---|---|
| dev-lang/python, dev-lang/python-exec | forced RDEPEND of gnome-shell (below) |
| dev-python/docutils, dev-python/pygobject | gnome-shell `RDEPEND="${DEPEND}"` |
| dev-python/pillow | docutils → pillow |
| app-admin/system-config-printer | gnome-control-center[cups] printer panel |

`scripts/stages/50-prune.sh` drops only `python`/`python3` from the ban list.
`gcc/g++/cc/ld/as/ar/make/cmake/ninja/meson/cargo/rustc/emerge/ebuild/portageq/pip` stay
banned, and `perl` keeps an explicit assertion of its own. The toolchain-free guarantee is
unchanged: no compiler, no Portage, no headers in the image.

For reference, the original procedure was:

1. confirm from `out/reports/packages.txt` which package actually pulls it (a real RDEPEND,
   not a `--with-bdeps` mistake);
2. if it is real, drop `python`/`python3` from the ban list in `scripts/stages/50-prune.sh`
   while keeping `gcc/g++/ld/make/cmake/ninja/meson/cargo/rustc/emerge/ebuild/portageq/perl/pip`,
   and record it here as a deliberate GNOME tradeoff with the package that forced it.

The toolchain-free guarantee (no compiler, no Portage) is unaffected either way — a scripting
interpreter is not a build toolchain.

## The first build's three blind spots (2026-08-21)

The first completed build came in at **8342 MiB installed rootfs against the ~5.5 GiB budget
below — 52% over**, with `/usr` alone at 7289 MiB. Attributing it was only possible from
`out/logs/60-image.log`'s per-file `Processing` lines, because the size report itself was
broken (see below). Three trees accounted for most of the overshoot, and two of them were
things the prune above already *intends* to remove and simply could not see.

**1. `/usr/src` — 145,752 entries (31.5% of every file in the EROFS), but only 219 MiB.**
File count is not bytes: this tree was first identified by counting `Processing` lines in the
stage-60 log, which made it look like the dominant item. It is not — those 145k files are
kernel headers, and they measure 219 MiB. Worth deleting, but an order of magnitude less than
the entry count suggests. Rank by `du`, not by file count.
`sys-kernel/gentoo-kernel-bin` installs a full configured kernel source + build tree at
`/usr/src/linux-<kver>-gentoo-dist-bin` so out-of-tree modules can be built against it. Layer 3
step 3 removes the `/usr/lib/modules/*/{build,source}` **symlinks** — and in doing so removed
the only names that pointed at the tree, which is exactly why nothing ever noticed the tree
itself was still there. The image has no compiler and a read-only `/usr`; its only out-of-tree
module (nvidia, `USE=dist-kernel`) is built at image-build time in stage 30. Deleted, with an
assertion that `nvidia*.ko*` still exists in `/usr/lib/modules` so the cut cannot go too deep.

**2. LLVM shipped a code generator — the toolchain-free guarantee was false.**
`llvm-core/llvm` is a hard dependency of `media-libs/mesa` (radeonsi and llvmpipe dlopen
`libLLVM.so`), so it is not removable. But LLVM installs into `/usr/lib/llvm/<slot>/` rather
than the standard prefixes, so its **14,766 headers, 582 binaries and 360 man pages** were
invisible to the `usr/include` / `usr/share/man` rules *and* to the assertion block, which only
swept `maxdepth 1` in `/usr/bin` and friends. The image was shipping `llc`, `lli`, `opt`,
`bugpoint`, `dsymutil` and `clang-offload-packager`. Stage 50 now deletes
`/usr/lib/llvm/*/{include,share,bin,lib64/cmake}`, unmerges `llvm-core/llvmgold` and
`llvm-core/llvm-toolchain-symlinks`, asserts `libLLVM.so` survives, and — the part that keeps
this fixed — searches `/usr/lib/llvm` **without** a depth limit in the banned-binary sweep, with
`clang/clang++/llc/lli/opt/llvm-as/llvm-link` added to the ban list.

**3. Qt6, and a full Xorg server, both arriving through a single USE flag each.**
Two flags in `package.use/image` (`poppler -qt6`, `pinentry -qt6`) had been added specifically
to keep Qt out of a GNOME-only image, and `dev-qt/{qtbase,qtsvg,qttranslations}` were in the
image anyway: `dev-libs/appstream[qt6]` builds AppStreamQt for KDE Discover and
`dev-libs/libportal[qt6]` builds libportal-qt6, neither of which anything here links. Separately
`x11-drivers/nvidia-drivers[X]` pulled `x11-base/xorg-server` → `xorg-drivers` → every
`xf86-video-*` matching `VIDEO_CARDS`, plus the `x11-apps` client utilities — a complete X
server inside a session that plan/03 defines as Wayland-only. Both closed with USE flags;
`x11-base/xwayland` stays, so X11 Flatpak apps are unaffected.

**Measured breakdown, once the size report was fixed** (pre-prune, MiB, from the first build
where every row actually recorded):

| Tree | Pre-prune | Post-prune |
|---|---|---|
| `usr/lib/firmware` | 2029 | 1629 |
| `usr/lib64` | 1350 | 1327 |
| rest of `/usr` | 1523 | 905 |
| `usr/share/fonts` | 768 | 768 |
| `usr/lib/modules` | 623 | 623 |
| `usr/share/locale` | 329 | 78 |
| `usr/lib/llvm` | 307 | 167 |
| `usr/src` | 219 | 0 |
| **`/usr` total** | **7289** | **5497** |

`linux-firmware` is the largest single item by a wide margin and the prune only trims 11
directories from it — that, and `usr/share/fonts` (noto with `extra`), are the two levers left.
Both were deliberately left alone: hardware compatibility and script coverage are stated goals.

**Installed size and shipped size are not the same lever.** `/usr` fell 1792 MiB (25%) while the
EROFS fell only 207 MiB (7%) and the `.img.zst` 299 MiB (9%). Everything the prune removes —
headers, kernel source, docs, locale catalogs — is highly compressible, so lz4hc had already
reduced it to near nothing in the shipped image. The budget table below is written in INSTALLED
size, where the win is real; do not expect it to translate into A/B update download size. The
incompressible bulk is firmware and fonts.

**Why none of this showed up in the size report.** Stage 50 wrote it as
`du -xsm "$T"/usr "$T"/usr/lib/firmware "$T"/usr/lib/modules "$T"/var 2>/dev/null || true`. `du -x`
refuses to cross a filesystem boundary, so `/var` (a separate mount in the builder) and the
firmware/modules rows were dropped, and the redirection hid the reason — leaving a three-line
report with no per-row data at all, which is precisely what the budget table below is supposed
to be checked against. Fixed: no `-x`, no error suppression, and the itemised rows the budget
names (plus `/usr/src` and `/usr/lib/llvm`) are reported explicitly.

## Size budget

| Component | Budget (installed, pre-EROFS) |
|---|---|
| Base + systemd + net | 0.9 GiB |
| Kernel + modules | 0.6 GiB |
| linux-firmware (post-prune) + microcode + SOF | 0.9 GiB |
| NVIDIA userspace + kernel modules | 0.7 GiB |
| Mesa/graphics/VA | 0.4 GiB |
| GNOME Shell + GTK4 + Mutter (no webkit) | 1.6 GiB *(estimate carried over from the pre-GNOME budget — not yet measured; update from the stage-50 size report after M2)* |
| Fonts (incl. CJK) | 0.4 GiB |
| **Total rootfs** | **~5.5 GiB** |
| **EROFS lz4hc image** | **~2.8–3.3 GiB** (fits 6 GiB slot with 2× headroom) |

Stage 50's size report tracks actuals against this table; >10% regression on any row warrants
a look before release. **The table is still the pre-first-build estimate and is known wrong** —
the first build measured 8342 MiB rootfs / 3177 MiB EROFS, and after the fixes above /usr is
5497 MiB with a 2970 MiB EROFS and a 3004 MiB `.img.zst`. The per-row measured numbers are in
the table further up; these budget rows should be rewritten against them rather than treated as
a target that was met. The `.img.zst` distributable lands ≈ 3.5–4.5 GiB (root image + 4 GiB
var with preinstalled Firefox flatpak, zeros compressed away).

## What is deliberately KEPT

- `bash`, coreutils, util-linux — it's a usable Unix at the console (recovery matters).
- `sudo`, `openssh` (disabled) — admin/debug paths.
- `ldconfig` (glibc runtime part), `systemd-tmpfiles`, `systemd-sysusers` — needed at boot.
- Terminfo, `/usr/share/zoneinfo`, ca-certificates, hwdb — correctness.
- `curl` + zstd/xz CLIs — sysupdate deps and human debugging.
- `gnupg` — spawned by systemd's verify machinery for signed-update checks (see 03/05).
