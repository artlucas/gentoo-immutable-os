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

GIR note: `/usr/lib64/girepository-1.0` used to be deliberately **not** masked — those typelibs
were loaded at runtime by gjs and gnome-shell. **That exception is withdrawn with GNOME**
(plan/09): global `USE=-introspection` means most of them are not built at all, nothing in a
Plasma image loads one, and stage 50 now deletes the directory as a guard against the ones
`dev-libs/glib` still builds (it keeps the flag per-package). Rollback moves as a pair — put
`introspection` back globally *and* take the directory out of the deletion list.

Locale note: `/usr/share/locale` is deliberately **not** in INSTALL_MASK (masking it wholesale
breaks the desktop UI-language story). Instead, v1 keeps message catalogs for a `build.conf` list
(`LOCALES_KEEP="en de fr es pt_BR it ja zh_CN ru"` default) and stage 50 deletes the rest —
measured savings vs. usability. GNOME/GTK translations follow the same list via `L10N` in the
target make.conf. `REVISIT` markers are resolved during M2 by the size report.

## Layer 3 — stage 50 prune script

Order matters — audit artifacts are saved *before* deletion:

1. **Save audit outputs** (to `/out/reports/` and a copy at
   `<target>/usr/share/${DISTRO_ID}/`):
   - `packages.txt` — every installed package + version + SIZE from the VDB.
   - `size-report.txt` — top-50 packages by installed size (drives future trimming).
   - Diff `packages.txt` against committed `config/portage/expected-packages.<profile>.txt`
     (**fail build on unexplained additions** — the dependency-audit gate from 03). The file is
     per build profile ([plan/16](16-installer.md) §3.3), and that is what makes "the installer
     and its GRUB/os-prober/squashfs tail never reach an installed system" an assertion that
     breaks the build rather than a convention anyone has to remember.
2. **Delete Portage artifacts:** `/var/db/pkg` (VDB), `/var/db/repos`, `/var/cache/{distfiles,binpkgs,edb}`,
   `/etc/portage`, `/usr/share/portage`, any `/usr/lib/python*/site-packages/portage*`.
3. **Delete runtime-useless residue:** `*.la` files; static `*.a` that escaped
   INSTALL_MASK; `/usr/share/locale/<not in LOCALES_KEEP>`; `/usr/lib/firmware` blobs for
   hardware classes outside scope (`liquidio`, `netronome`, `mellanox`, `qed` — server NICs;
   list curated in `config/prune-firmware.txt`; **measured 2026-08-25 at 479 MiB** since the
   whole `qcom` ARM SoC tree joined it — see plan/10 finding 2); kernel build/source
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

1. `x11-misc/xdg-utils[perl]` gated `dev-perl/Net-DBus` and `dev-perl/X11-Protocol`, and
   Net-DBus dragged XML-Twig and the entire LWP/HTML perl stack behind it: **~48 packages**.
   What it buys is the perl `xdg-screensaver` implementation driving X11, which does nothing in
   a Wayland-only session where apps inhibit idle through portals. Disabled
   (`xdg-utils -perl -gnome` — see the note in `package.use/image`; `-gnome` is the flag that
   actually holds the LWP stack out) — the cleanest 48 packages this build removed. **This item
   stands unchanged under Plasma**; a dry-run depgraph confirms the LWP stack resolves to the
   *builder* root only, never to the image.
2. `net-fs/samba` lists `dev-lang/perl:=` and `dev-perl/Parse-Yapp` in COMMON_DEPEND with no
   USE guard. **The holder changed with the desktop; the dependency fact did not.** Under GNOME
   it was `gnome-control-center[cups]` → `app-admin/system-config-printer` → samba. Under
   Plasma it is direct: `kde-apps/kio-extras[samba]`, kept for `smb://` browsing in Dolphin.
   `kde-plasma/print-manager` talks to CUPS directly and needs no samba at all, so printing is
   no longer part of this decision.

Admitted after an explicit call — under GNOME to keep the printer panel, under Plasma to keep
`smb://`. The image therefore ships `dev-lang/perl` and `dev-perl/Parse-Yapp` and nothing else
perl-shaped. To reverse it, set `kde-apps/kio-extras -samba`: samba, perl and Parse-Yapp all
leave the image together, and what is lost is network-share browsing in Dolphin. Printing is
unaffected either way.

> **SUPERSEDED for the perl half (2026-08-25, [10-prune-audit.md](10-prune-audit.md) §
> "Corrections").** `kio-extras -samba` no longer takes perl with it. `sys-apps/lm-sensors`
> RDEPENDs `dev-lang/perl` unconditionally — `sensors-detect` is a perl script — and lm-sensors
> is pulled by `kde-plasma/libksysguard` and `kde-plasma/ksystemstats`, i.e. by the System
> Monitor in `@desktop`. The flag still frees 36.1 MiB (samba, mit-krb5, cifs-utils, the
> talloc/tdb/tevent trio, Parse-Yapp); `dev-lang/perl` (47.4 MiB) stays either way. The image
> also ships more than "nothing else perl-shaped": nine packages, 47.6 MiB, counting the
> `virtual/perl-*` and `perl-core/*` that perl itself drags in.

Original caveat text (correctly predicted, wrong package): `dev-lang/perl` is an RDEPEND of some base packages
(e.g. openssl's `c_rehash`). The dep audit in stage 30 will show whether it lands; if it does
and the pull is spurious, fix with USE (`-perl`) or `package.provided` — decided during
M1/M2 with the report in hand, not guessed now. The *mechanism* is the audit gate; the
*policy* is "empty whitelist until a human approves an entry."

**Python — RESOLVED again at the first Plasma build (2026-08-25): admitted, and the chain is
not the desktop's.** It was RESOLVED under GNOME (2026-08-20) on a chain that no longer exists,
reopened by the migration, and is now settled from the build's own dependency tree.

The GNOME chain was: `gnome-base/gnome-shell` declared `dev-python/docutils` and
`dev-python/pygobject` in `DEPEND` and then set `RDEPEND="${DEPEND}"`, folding them into the
runtime set, resolving through `gdm → gnome-settings-daemon → libnotify → gnome-shell →
docutils → pillow`. **None of those packages is in the image any more**, and neither is
`dev-python/docutils` or `dev-python/pillow`.

Python still ships, on a chain that has nothing to do with which desktop is installed —
traced with `emerge -p --tree` against the pinned snapshot:

| Package | Held by |
|---|---|
| `dev-lang/python`, `python-exec`, `python-exec-conf` | the two chains below |
| `dev-python/pygobject` | `sys-power/power-profiles-daemon` → `sys-power/switcheroo-control` |
| `dev-python/pycairo` | `dev-python/pygobject` |
| `dev-python/pyxdg` | `app-accessibility/speech-dispatcher[python]` (`+python` by default) |
| `dev-python/{requests,urllib3,certifi,idna,charset-normalizer,pysocks}` | `app-portage/gemato` — **orphans**, see below |
| `dev-python/{setuptools,packaging,platformdirs,more-itertools,jaraco-context,jaraco-functools,jaraco-text}` | the same Portage tooling cluster — **orphans** |
| `dev-python/gentoo-common` | `dev-lang/python-exec` |

`sys-power/power-profiles-daemon` is in `@desktop` deliberately and was in the GNOME set too, so
this is not a Plasma cost — the GNOME image was paying for it as well, hidden behind the much
louder gnome-shell chain.

**The orphan cluster is a real, actionable finding.** Thirteen of the twenty surviving
`dev-python/*` packages are held by `app-portage/gemato` and the setuptools stack, and stage 50
*already unmerges* gemato, getuto, portage-utils and `sys-apps/portage` itself — but not the
packages left dangling behind them. Nothing in the image imports them. Adding them to the
unmerge loop in section 1 of `50-prune.sh` is the obvious next trim; it was left out of the
Plasma migration deliberately, because that loop is shared with the console-only image and the
change deserves its own before/after measurement rather than riding along with a desktop swap.

> **MEASURED, and it is not the next trim (2026-08-25,
> [10-prune-audit.md](10-prune-audit.md)).** The before/after this paragraph asks for was done by
> reconstructing the VDB from the binpkg cache. Applying stage 50's existing unmerge list orphans
> **fifteen** packages worth **1.78 MiB** — six `dev-python/*` plus `pax-utils`, `sandbox`,
> `install-xattr`, `debugedit` and the portage user/group accounts. Worth unmerging for hygiene,
> but it is a rounding error, and the count above is wrong in the other direction too:
> `setuptools`, `packaging`, `platformdirs`, `more-itertools` and the `jaraco-*` trio are **not**
> orphans — `dev-libs/gobject-introspection` RDEPENDs `dev-python/setuptools`, and g-i is held by
> `pygobject` ← `power-profiles-daemon` and by `libqrtr-glib` ← `modemmanager` ←
> `networkmanager`. Unmerging them would leave a broken dependency in the image. The trims that
> actually matter are firmware compression, `noto[-extra]` and the wallpapers; see 10.

`scripts/stages/50-prune.sh` drops only `python`/`python3` from the ban list.
`gcc/g++/cc/ld/as/ar/make/cmake/ninja/meson/cargo/rustc/emerge/ebuild/portageq/pip` stay
banned, and `perl` keeps an explicit assertion of its own. The toolchain-free guarantee is
unchanged: no compiler, no Portage, no headers in the image — a scripting interpreter is not a
build toolchain.

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
`dev-libs/libportal[qt6]` builds libportal-qt6, neither of which anything then linked. Separately
`x11-drivers/nvidia-drivers[X]` pulled `x11-base/xorg-server` → `xorg-drivers` → every
`xf86-video-*` matching `VIDEO_CARDS`, plus the `x11-apps` client utilities — a complete X
server inside a session that plan/03 defines as Wayland-only. Both closed with USE flags;
`x11-base/xwayland` stays, so X11 Flatpak apps are unaffected.

> **The Qt half of this reads the other way round under Plasma** (plan/09). Qt is the image's
> own toolkit now, so `appstream[qt6]` has a real consumer — `plasma-workspace` RDEPENDs
> `>=dev-libs/appstream-1[qt6]` — and `pinentry[qt6]` is the prompt that matches the session.
> `poppler` does not merely become harmless but **inverts**: `kde-frameworks/kfilemetadata[pdf]`
> *requires* `app-text/poppler[qt6(-)]`, and it is `cairo` that goes off, because that backend
> existed for poppler-glib and its only consumer was `app-misc/localsearch`.
> `dev-libs/libportal` turns out not to be in the Plasma graph at all.
>
> The Xorg half stands, and got *stronger*: it took three `-X` flags under GNOME and takes two
> now, because `kde-plasma/kwin` is Wayland-only by construction (the X11 compositor is a
> separate `kde-plasma/kwin-x11`). A dry-run depgraph against the pinned tree resolves with no
> `xorg-server` and no `xf86-*` at all.

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

> **Both levers can be pulled without paying either price (2026-08-25,
> [10-prune-audit.md](10-prune-audit.md)).** The premise that firmware and fonts can only shrink
> by giving up coverage turns out to be false for both. `sys-kernel/linux-firmware[compress-zstd]`
> keeps every blob and the shipped kernel decompresses on load (`CONFIG_FW_LOADER_COMPRESS_ZSTD=y`
> in gentoo-kernel-bin); `media-fonts/noto[-extra]` removes only Condensed/SemiBold/Extra *weights*
> and leaves every script family intact. Add the ARM-only vendor firmware that cannot load on
> amd64 at all — `qcom` is 458 MiB of Snapdragon platform blobs — and the two "untouchable" rows
> give up **1390 MiB installed / 640 MiB of EROFS** between them with no loss of hardware support
> or script coverage. Measured, not estimated: see 10.

## Measured: the first Plasma build (2026-08-25)

Same pipeline, same `du` invocation, so these are directly comparable with the GNOME column.
GNOME is the 0.1.0 build of 2026-08-23; Plasma is 0.2.0.

**Pre-prune, itemised** (MiB — `du` de-duplicates nested operands, so the `/usr` row is
*rest of* `/usr`, and the `/usr total` row is the sum):

| Tree | GNOME 0.1.0 | Plasma 0.2.0 | Δ |
|---|---|---|---|
| `usr/lib/firmware` | 2029 | 2029 | — |
| `usr/lib64` | 1346 | **1711** | **+365** |
| rest of `/usr` | 1317 | 1359 | +42 |
| `usr/share/fonts` | 768 | 847 | +79 |
| `usr/lib/modules` | 623 | 623 | — |
| `usr/share/locale` | 323 | 388 | +65 |
| `usr/lib/llvm` | 307 | 307 | — |
| `usr/share/icons` | 26 | **161** | **+135** |
| `usr/src` | 219 | 219 | — |
| **`/usr` total** | **6958** | **7644** | **+686** |
| `/var` | 2490 | 2495 | +5 |
| **target, post-prune** | **7674** | **8362** | **+688** |

The desktop swap costs **+688 MiB installed**, and it is concentrated in exactly two rows:
`usr/lib64` (+365, Qt6 + Frameworks shared libraries) and `usr/share/icons` (+135,
`breeze-icons` — Breeze ships a far larger icon set than Adwaita). Fonts and locale grew
because Qt and KDE ship their own catalogues. Everything the budget calls incompressible —
firmware, modules, LLVM, kernel source — is bit-for-bit unchanged, which is the expected
result of a change that touches only the desktop layer.

**Shipped artefacts** (MiB):

| Artefact | GNOME 0.1.0 | Plasma 0.2.0 | Δ |
|---|---|---|---|
| root EROFS (lz4hc) | 2884.2 | 3380.8 | +496.6 (+17%) |
| root EROFS `.zst` — the A/B update payload | 2107.4 | 2519.0 | +411.6 (+20%) |
| full disk `.img.zst` | 3082.6 | 3496.7 | +414.1 (+13%) |
| UKI | 238.5 | 240.6 | +2.1 |

The EROFS grew *more* than the installed tree did (+496 vs +688 installed, but +17% vs +9%),
which is the mirror image of the note below: Qt/KDE's addition is mostly shared libraries and
icon SVGs, which compress far less well than the headers and locale catalogues the prune
removes. Budget headroom is unaffected — 3381 MiB still fits the 6144 MiB root slot with 1.8×
margin — but the A/B **download** grew 20%, which is the number that matters to users on slow
links.

> **Reading `out/reports/size-report.txt` correctly.** The file is written by *two different*
> `du` runs and mixing them up is easy: `50-prune.sh:101` writes the ten itemised rows
> **before** any deletion, and `50-prune.sh:400` appends a single final row from
> `du -xsm "$T"` **after** the prune. So rows 1–10 are pre-prune and row 11 is post-prune —
> they are not summable. Worse, that last one still carries the `-x` that this document already
> records as having silently dropped `/var` from the old report. Splitting them into two clearly
> labelled files is a small, worthwhile fix that has not been made.

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
| Plasma 6 + Qt6 + Frameworks (no webengine) | ~1.9 GiB *(measured 2026-08-25: the desktop layer is +688 MiB installed over the GNOME image's, whose own row was an unmeasured 1.6 GiB estimate. Treat this as "GNOME's estimate plus a real delta", not as an independently measured figure — no row in this table has ever been measured in isolation)* |
| Fonts (incl. CJK) | 0.4 GiB |
| **Total rootfs** | **~5.5 GiB** |
| **EROFS lz4hc image** | **~2.8–3.3 GiB** (fits 6 GiB slot with 2× headroom) |

Stage 50's size report tracks actuals against this table; >10% regression on any row warrants
a look before release. **The table is still the pre-first-build estimate and is known wrong** —
every row except the desktop one is an unvalidated guess, and the totals below it are now two
desktops out of date. Measured reality, from the two builds in the section above:

| | Budget | GNOME 0.1.0 | Plasma 0.2.0 |
|---|---|---|---|
| Total rootfs (installed, post-prune) | ~5.5 GiB | 7674 MiB | **8362 MiB** |
| EROFS lz4hc image | ~2.8–3.3 GiB | 2884 MiB | **3381 MiB** |

The rootfs has been ~50% over budget since the first build and the desktop swap did not cause
that — `linux-firmware` (2029 MiB) and fonts (847 MiB) are the two rows that blow it, and both
were deliberately left alone because hardware compatibility and script coverage are stated
goals. The EROFS still lands inside its stated range and inside the 6144 MiB slot with 1.8×
margin. **These per-row budget numbers should be rewritten from measurement rather than kept as
a target that was never met**; that is a documentation task, not a build one.

## What is deliberately KEPT

- `bash`, coreutils, util-linux — it's a usable Unix at the console (recovery matters).
- `sudo`, `openssh` (disabled) — admin/debug paths.
- `ldconfig` (glibc runtime part), `systemd-tmpfiles`, `systemd-sysusers` — needed at boot.
- Terminfo, `/usr/share/zoneinfo`, ca-certificates, hwdb — correctness.
- `curl` + zstd/xz CLIs — sysupdate deps and human debugging.
- `gnupg` — spawned by systemd's verify machinery for signed-update checks (see 03/05).
