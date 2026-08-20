# 02 — Build Pipeline

## Principles

- **Everything is Bash**, `set -euo pipefail`, shellcheck-clean.
- **Builds run inside a privileged container** — the host needs only Docker/Podman + Bash for
  the wrapper. Works on Docker Desktop (WSL2 backend) on Windows, or any Linux box.
- **Two-root technique:** the container is a full Gentoo *builder*; the *target* rootfs is a
  directory the builder emerges into with `--root=`. Build-time dependencies (compilers,
  headers, python, portage itself) install into the builder; only runtime dependencies land in
  the target. The shipped OS is toolchain-free *by construction*, and the prune stage
  ([06-pruning.md](06-pruning.md)) enforces it with assertions.
- **Pinned inputs:** stage3/container digest, Portage tree snapshot timestamp, and package set
  are all pinned in `config/build.conf` — two runs from the same config produce functionally
  identical images.
- **Stages are idempotent and resumable** — each writes a stamp; `build.sh` skips completed
  stages unless told otherwise.

## Repository layout

```
immos/
├── plan/                       # these documents
├── config/
│   ├── build.conf              # single source of truth: DISTRO_ID/NAME, VERSION,
│   │                           #   STAGE3_DIGEST, SNAPSHOT_DATE, partition sizes,
│   │                           #   LIVE_USER, FLATPAK_PREINSTALL list, UPDATE_URL
│   ├── portage/                # TARGET portage config (used via --config-root)
│   │   ├── make.conf           # CFLAGS=-march=x86-64 -O2, USE, FEATURES, INSTALL_MASK
│   │   ├── package.use/
│   │   ├── package.license/    # NVIDIA-r2, linux-fw redistributable, intel-ucode
│   │   ├── package.accept_keywords/
│   │   └── sets/               # @base, @hardware, @desktop
│   └── rootfs/                 # file overlay rsync'd onto target in the configure stage
│       ├── etc/                #   os-release template, fstab, gdm/custom.conf, ...
│       ├── usr/lib/            #   systemd units & presets, sysupdate.d/, repart.d/,
│       │                       #   import-pubring.gpg, tmpfiles.d/
│       └── usr/lib/dracut/modules.d/90etc-overlay/
├── scripts/
│   ├── build.sh                # HOST entrypoint: builds builder image, runs container,
│   │                           #   dispatches stages. Flags: --from N, --only N, --clean,
│   │                           #   --console-only (M1 image), --version X.Y.Z
│   ├── enter.sh                # debug shell inside the builder container
│   ├── lib/common.sh           # logging, die(), stamp helpers, chroot helper, conf loader
│   └── stages/                 # run INSIDE the container, in order
│       ├── 10-fetch.sh
│       ├── 20-builder-setup.sh
│       ├── 30-target-rootfs.sh
│       ├── 40-configure.sh
│       ├── 50-prune.sh
│       ├── 60-image.sh
│       ├── 70-test.sh
│       └── 80-release.sh
├── builder/Dockerfile
├── out/                        # gitignored: images, UKIs, logs, state stamps, release/
└── README.md
```

## Builder container

`builder/Dockerfile`:

- `FROM gentoo/stage3:amd64-systemd@sha256:<pinned digest>` (this *is* the stage3 — no
  separate tarball handling; the digest pin is recorded in `build.conf` and bumped
  deliberately).
- Adds build-host tools not in stage3: `erofs-utils`, `dosfstools`, `mtools`, `dracut`,
  `zstd`, `gnupg`, `qemu` (+ `edk2-ovmf` firmware) for the test stage, `pigz`, `rsync`,
  `shellcheck`. systemd's `ukify` comes from the builder's systemd with `USE=boot ukify`.
- The Portage tree inside the builder is synced to the pinned snapshot
  (`emerge-webrsync` against `SNAPSHOT_DATE`) during image build, so the builder image itself
  is reproducible and cacheable.

`scripts/build.sh` (host wrapper) runs it as:

```
docker run --privileged \
  -v "$REPO":/repo:ro                      # scripts + config, read-only
  -v immos-work:/work                      # named volume: target rootfs, scratch
  -v immos-cache:/cache                    # named volume: distfiles + binpkgs (survives runs)
  -v "$REPO/out":/out                      # artifacts + logs + stamps back to host
  immos-builder /repo/scripts/stages/...
```

> **WSL2/NTFS warning (load-bearing):** the target rootfs is built inside a **named volume**
> (`/work`), never on a Windows bind mount. NTFS-backed bind mounts cannot faithfully hold
> Linux permissions, device nodes, xattrs (Flatpak/ostree needs them), or case-sensitive
> trees. Only `/repo` (read-only inputs) and `/out` (flat artifact files) touch the host
> filesystem. `--privileged` is required for chroot + bind mounts + device nodes during
> emerge and for KVM passthrough in the test stage; **no loop devices are ever needed**
> (see [04-image-and-boot.md](04-image-and-boot.md)).

## Stage contract

Every stage script:

- sources `lib/common.sh` + `config/build.conf`; runs under `set -euo pipefail`.
- declares `STAGE_INPUTS` (files/vars it depends on); the stamp is
  `out/state/<stage>.done` containing a hash of those inputs — a config change invalidates
  exactly the stages it affects.
- logs to `out/logs/<stage>.log` (tee'd), prefixes every line with the stage name.
- ends with an explicit **verify block** — cheap assertions that its outputs exist and are
  sane (listed per stage below). A stage that can't verify itself fails loudly.

## Stages

### 10-fetch
Verifies the builder's pinned state and fetches what later stages need.
**Does:** confirm container digest matches `build.conf`; `emerge-webrsync` to
`SNAPSHOT_DATE` if the builder image predates it; pre-fetch distfiles for the target set
(`emerge --root=... --fetchonly`).
**Verify:** snapshot timestamp file matches pin; distfiles fetch exit 0.

### 20-builder-setup
**Does:** write builder `make.conf` (binhost: `FEATURES="getbinpkg buildpkg"` pointing at
`https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/` — generic x86-64,
**not** x86-64-v3, since budget Goldmont-Plus-class CPUs sold within the 5-year window lack
AVX2); eselect profile `default/linux/amd64/23.0/desktop/gnome/systemd`; local binpkg cache
under `/cache/binpkgs`.
**Verify:** `emerge --info` shows expected profile/binhost.

### 30-target-rootfs
The core two-root emerge.
**Does:**
```
export ROOT=/work/target
emerge --root="$ROOT" --config-root=/repo/config/portage \
       --usepkg --with-bdeps=n \
       @base @hardware @desktop
```
- Target portage config (`config/portage/`) sets the same profile, target USE flags,
  `INSTALL_MASK` (see 06), `FEATURES="nodoc noinfo noman"`.
- BDEPENDs resolve into the builder (`/`), RDEPENDs into `$ROOT` — Portage's default ROOT
  semantics. Anything that appears in the target arrived as a *runtime* dependency; the dep
  audit in 06 reviews that list.
- `--console-only` flag (M1) emerges only `@base @hardware`.
**Verify:** `$ROOT/usr/bin/gcc` absent; `$ROOT/lib/modules/*` exists; systemd, gdm, flatpak
binaries present (full build); VDB at `$ROOT/var/db/pkg` present (pruned later, needed by 40/50).

### 40-configure
Turns the raw rootfs into *this* distro.
**Does (from builder, against `$ROOT`):**
- rsync `config/rootfs/` overlay onto `$ROOT` (os-release rendered from template with
  `DISTRO_*`/`VERSION`; fstab; sysupdate.d + repart.d; systemd units incl. `immos-boot-ok.service`;
  tmpfiles.d for `/var` skeleton; GDM autologin conf; NM/PipeWire defaults; dracut module).
- create `/home → var/home`, `/root → var/roothome` symlinks; seed `/var` skeleton.
**Does (chrooted into `$ROOT` — same arch, privileged container):**
- `locale-gen` (list from build.conf), `systemd-firstboot --setup` defaults (TZ=UTC),
  `useradd` the live user, `systemctl preset-all`, enable: gdm, NetworkManager, bluetooth,
  systemd-timesyncd, zram; mask: getty autospawn beyond tty2.
- `flatpak remote-add --if-not-exists flathub <flathub.repo>`; `flatpak install -y --system`
  each of `FLATPAK_PREINSTALL` (default: `org.mozilla.firefox`). Network required — fine in
  the container. Fallback if chrooted install misbehaves: `flatpak preinstall`-style
  first-boot oneshot unit (kept as a build.conf switch `FLATPAK_PREINSTALL_MODE=build|firstboot`).
- finalizers: `ldconfig`, `systemd-hwdb update`, `glib-compile-schemas`, `fc-cache`,
  `update-desktop-database`, `update-mime-database`.
**Does (back in builder):** build initrd + UKI:
`dracut --sysroot $ROOT --no-hostonly ...` then `ukify build ...` →
`out/uki/${DISTRO_ID}_${VERSION}.efi` (details in 01/04).
**Verify:** os-release has correct `IMAGE_ID`/`IMAGE_VERSION`; gdm/NM enabled in presets;
flatpak remote listed; UKI file exists and `ukify inspect` shows expected cmdline.

### 50-prune
See [06-pruning.md](06-pruning.md). **Does:** save package manifest, strip residue, delete
VDB/repos/caches. **Verify:** the hard assertion list (no gcc/ld/make/portage/python except
whitelist, no headers, no static libs); prints size report.

### 60-image
Loopless assembly of `out/${DISTRO_ID}-${VERSION}.img` (+ `.img.zst`).
See [04-image-and-boot.md](04-image-and-boot.md).
**Verify:** `sfdisk --verify`; partition table matches spec; erofs superblock at expected
offset; image boots… (that's stage 70).

### 70-test
QEMU/OVMF boot + smoke assertions; update/rollback E2E when given two versions.
See [07-testing.md](07-testing.md). Uses KVM when `/dev/kvm` exists (WSL2 supports nested
virtualization on Win11), falls back to TCG with longer timeouts.

### 80-release
**Does:** assemble `out/release/<UPDATE_CHANNEL>/` in the sysupdate server layout
([05-updates.md](05-updates.md)): versioned compressed erofs image, versioned UKI,
`SHA256SUMS`, `SHA256SUMS.gpg` (detached sig, release key from outside the repo —
`RELEASE_GPG_KEY` env), plus the standalone `.img.zst` for fresh installs.
**Verify:** `gpg --verify` round-trips against the committed pubkey
(`config/rootfs/usr/lib/systemd/import-pubring.gpg`); filenames match sysupdate
`MatchPattern`s.

## Caching & rebuild speed

- `/cache/distfiles` + `/cache/binpkgs` named volumes persist across builds; after the first
  build, `--usepkg` makes a clean target rebuild minutes-fast.
- The Gentoo binhost covers packages whose USE match; the GNOME stack with our trimmed USE will
  largely build from source once, then live in the local binpkg cache.
- First full build estimate: several hours (GNOME from source dominates). Subsequent: < 30 min.

## Failure & debugging

- Any stage failure leaves `/work` intact; `scripts/enter.sh` drops a shell in the same
  container mounts for post-mortem; `chroot-target` helper (in `common.sh`) enters the target.
- `build.sh --from 40` re-runs from a stage after config tweaks; `--clean` nukes `/work` and
  stamps but keeps `/cache`.
