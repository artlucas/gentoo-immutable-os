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
- **Those tools are installed from the Gentoo binhost, not compiled.** The stage3 base already
  ships `/etc/portage/binrepos.conf/gentoo.conf` (official binhost, `verify-signature = true`)
  and `sec-keys/openpgp-keys-gentoo-release`; the Dockerfile adds `FEATURES=getbinpkg`, points
  the repo at `BINHOST_URI` from `build.conf` (passed as a `--build-arg` by `build.sh`), and
  emerges with `--usepkg --getbinpkg`. This is the builder's own `/` only, and it is the
  **opposite** of the rule for the image — see "Where binaries come from" below.
  - `getuto` runs **before** that emerge. With `verify-signature = true`, portage checks binpkg
    signatures against the trust store in `/etc/portage/gnupg`, and `getuto` is what builds that
    store. If it runs afterwards (as it originally did), portage can verify nothing the binhost
    serves and falls back to compiling — a slow build, not an error, so the regression is silent.
  - Packages whose USE this image overrides (`mesa[vulkan]`, `polkit[gtk]`, the qemu target
    list, …) still build from source: the binhost's copies were built against the default
    profile's USE and portage correctly refuses a mismatched binpkg. Before this change the
    figure was ~98 packages compiled on every Dockerfile edit, roughly an hour of wall clock.
  - Because that fallback is silent, the same `RUN` asserts it did not happen: `portageq envvar
    FEATURES` must list `getbinpkg` and `/etc/portage/gnupg/pubring.kbx` must be non-empty, or
    the image build fails.

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

## Where binaries come from

Two roots, two opposite rules, and the failure mode in both directions is silent — a binpkg
merges exactly like a source build, and a source build is just slower — so each is asserted:

| | builder `/` | image `$TARGET` |
|---|---|---|
| config | builder's `/etc/portage` (`builder/Dockerfile`) | `$WORK/config` from `config/portage/` |
| binhost | `BINHOST_URI`, `FEATURES=getbinpkg`, signature-verified | **none** |
| binaries reused | official binhost + `/var/cache/binpkgs` | `/cache/binpkgs`, this pipeline's own `buildpkg` output |
| otherwise | compiles | compiles |
| asserted by | the `portageq`/trust-store checks in the Dockerfile | stage 20 verify block + stage 30 `portageq` guard |

The image compiles what it ships because the binhost builds against the **default** profile's
USE, and portage merges a remote binpkg whenever its recorded USE happens to satisfy the graph:
that makes the package set a function of what the binhost published rather than of this repo.
`config/portage/package.use/image` documents one such incident — `x11-misc/xdg-utils` resolving
to a binhost copy built with `gnome+dbus`, whose baked RDEPEND pulled ~37 perl packages a source
build of the same ebuild does not.

`--getbinpkg` is per **invocation**, not per root (`_emerge/actions.py` reads it off the target
root's `FEATURES` and then populates every tree with it), which is why stage 30 runs the
builder-root `@buildhost` install as a separate emerge from the target's.

The `/cache` volume outlives the config, so stage 20 also sweeps binpkgs the binhost served to
older builds out of `/cache/binpkgs` — `--usepkg` cannot tell them apart, but the packages can:
Gentoo signs its binpkgs and this pipeline does not, so a `.gpkg.tar` carrying `*.sig` members
is one of theirs (`prune_binhost_binpkgs` in `scripts/lib/common.sh`). Distfiles are untouched.

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
**Does:** write the **target's** `make.conf` into `$WORK/config` — this is the `PORTAGE_CONFIGROOT`
stage 30 emerges the target with, *not* the builder's own `/etc/portage/make.conf` (the builder's
binhost is set up in the Dockerfile; see "Builder container" above). `FEATURES="… buildpkg"`
with no `getbinpkg` and no `PORTAGE_BINHOST`: the image is compiled here and cached in
`/cache/binpkgs` for later builds. `COMMON_FLAGS` is generic x86-64, **not** x86-64-v3, since
budget Goldmont-Plus-class CPUs sold within the 5-year window lack AVX2; profile
`default/linux/amd64/23.0/desktop/gnome/systemd`. Also sweeps binhost-built binpkgs left in
`/cache/binpkgs` by older builds (see "Where binaries come from").
**Verify:** `emerge --info` shows the expected profile; the rendered `make.conf` has neither
`getbinpkg` nor `PORTAGE_BINHOST`.

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
- `--usepkg` **without** `--getbinpkg`: the only binaries this emerge may reuse are ones an
  earlier run built into `/cache/binpkgs`. A `portageq` guard ahead of it fails the stage if
  the target config ever grows `getbinpkg`/`PORTAGE_BINHOST` again. The builder-root
  `@buildhost` install runs first, as its own emerge, *with* `--getbinpkg`.
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
- Those cached binpkgs are this pipeline's own (`FEATURES=buildpkg`), which is the whole
  mechanism: the image is compiled once and reused, rather than downloaded.
- First full build estimate: several hours — the entire target set compiles, not just the
  GNOME stack whose USE the binhost never matched anyway. Subsequent: < 30 min.
- A change that invalidates the target (any `config/portage` edit — stage 30's staleness guard
  spells this out) costs a recompile of whatever the cache no longer covers, so the binpkg
  cache volume is worth keeping even when the work volume is wiped.

## Failure & debugging

- Any stage failure leaves `/work` intact; `scripts/enter.sh` drops a shell in the same
  container mounts for post-mortem; `chroot-target` helper (in `common.sh`) enters the target.
- `build.sh --from 40` re-runs from a stage after config tweaks; `--clean` nukes `/work` and
  stamps but keeps `/cache`.
