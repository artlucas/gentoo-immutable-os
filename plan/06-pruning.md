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
  /usr/share/qt6/mkspecs
  /usr/share/zsh                               # REVISIT: bash-completion kept for now; size report decides
"
```

Locale note: `/usr/share/locale` is deliberately **not** in INSTALL_MASK (masking it wholesale
breaks the KDE UI-language story). Instead, v1 keeps message catalogs for a `build.conf` list
(`LOCALES_KEEP="en de fr es pt_BR it ja zh_CN ru"` default) and stage 50 deletes the rest —
measured savings vs. usability. KDE/Qt translations follow the same list via `L10N` in the
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

Perl caveat (known, handled): `dev-lang/perl` is an RDEPEND of some base packages
(e.g. openssl's `c_rehash`, some KDE deps historically). The dep audit in stage 30 will show
whether it lands; if it does and the pull is spurious, fix with USE (`-perl`) or
`package.provided` — decided during M1/M2 with the report in hand, not guessed now. Same
procedure for python (GTK/glib tooling sometimes drags it): the *mechanism* is the audit
gate; the *policy* is "empty whitelist until a human approves an entry."

## Size budget

| Component | Budget (installed, pre-EROFS) |
|---|---|
| Base + systemd + net | 0.9 GiB |
| Kernel + modules | 0.6 GiB |
| linux-firmware (post-prune) + microcode + SOF | 0.9 GiB |
| NVIDIA userspace + kernel modules | 0.7 GiB |
| Mesa/graphics/VA | 0.4 GiB |
| Plasma + KF6 + Qt6 (no webengine) | 1.6 GiB |
| Fonts (incl. CJK) | 0.4 GiB |
| **Total rootfs** | **~5.5 GiB** |
| **EROFS lz4hc image** | **~2.8–3.3 GiB** (fits 6 GiB slot with 2× headroom) |

Stage 50's size report tracks actuals against this table; >10% regression on any row warrants
a look before release. The `.img.zst` distributable lands ≈ 3.5–4.5 GiB (root image + 4 GiB
var with preinstalled Firefox flatpak, zeros compressed away).

## What is deliberately KEPT

- `bash`, coreutils, util-linux — it's a usable Unix at the console (recovery matters).
- `sudo`, `openssh` (disabled) — admin/debug paths.
- `ldconfig` (glibc runtime part), `systemd-tmpfiles`, `systemd-sysusers` — needed at boot.
- Terminfo, `/usr/share/zoneinfo`, ca-certificates, hwdb — correctness.
- `curl` + zstd/xz CLIs — sysupdate deps and human debugging.
- `gnupg` — spawned by systemd's verify machinery for signed-update checks (see 03/05).
