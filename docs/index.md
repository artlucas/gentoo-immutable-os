# immos

immos is a Gentoo-built, immutable, Flatpak-first Linux distribution for AMD64 (UEFI-only). The build produces a single raw disk image with two root slots: `systemd-sysupdate` writes the next version into the inactive slot, and `systemd-boot` rolls back to the previous slot after three failed boot attempts. The shipped image contains no compiler and no Portage — Gentoo is the build system, not the runtime. Mutable userland ships as distrobox (rootless podman) and preinstalled Flatpaks.

The repository is a pure Bash build system on top of Docker or Podman. `scripts/build.sh` builds the builder container image and dispatches each pipeline stage as its own privileged container; the host needs no root and no Gentoo installation. Every build input is pinned: the stage3 base image by digest, the ebuild tree by dated snapshot and SHA-256, every package version by per-profile lock files, and every preinstalled Flatpak by exact Flathub commit. A rebuild of a release selects the same versions; see [Pinning](pinning.md).

## Documentation map

| Page | Scope |
|---|---|
| [Build](build.md) | Prerequisites, invocations, build profiles, artifacts |
| [Pipeline](pipeline.md) | Volumes, stages 10–90, stamps, determinism |
| [Pinning](pinning.md) | Pin model: base image, tree snapshot, package locks, Flatpak commits |
| [Relock](relock.md) | Moving pins deliberately: modes, preconditions, review flow |
| [Build cache](cache.md) | Cache contents, reuse rules, invalidation, offline rebuilds |
| [Scenarios](scenarios.md) | Worked end-to-end procedures, including a security update |
| [Testing](testing.md) | Offline suite, QEMU boot tests, VM tooling |

## Repository layout

| Path | Content |
|---|---|
| `scripts/build.sh` | Host entry point: builds the builder image, dispatches stages |
| `scripts/relock.sh` | Re-resolves version locks |
| `scripts/enter.sh` | Debug shell inside the builder container |
| `scripts/run-vm.sh` | Boots a built image in QEMU/OVMF |
| `scripts/update-translations.sh` | Refreshes installer translation sources; never runs in the build |
| `scripts/stages/` | Pipeline stages, `NN-name.sh`, one container per stage |
| `scripts/lib/` | Shared shell library (`common.sh`, `layout.sh`) |
| `config/build.conf` | Build inputs, pins, image geometry — the single source of truth |
| `config/profiles/` | Build profiles: `desktop`, `console`, `installer` |
| `config/portage/sets/` | Package set requests — the files maintainers edit |
| `config/portage/lock/` | Resolved version locks — generated, committed, never hand-edited |
| `config/portage/overlay/` | In-repo ebuild repository for the C++ plugins |
| `config/portage/package.use/`, `package.mask/`, `package.accept_keywords/`, `package.license/` | Portage configuration applied to the target |
| `config/portage/expected-packages.<profile>.txt` | Audit gate allowlist: the package set the image is allowed to ship |
| `config/flatpak/apps.lock` | Preinstalled Flatpaks pinned to exact Flathub commits |
| `config/rootfs/` | File overlay copied onto the target root |
| `builder/Dockerfile` | The builder container image |
| `tests/` | Offline test suite |
| `out/` | Artifacts, logs, reports, stage stamps — untracked |

!!! note "Two meanings of profile"
    `PROFILE` in `config/build.conf` is the Gentoo portage profile (`default/linux/amd64/23.0/desktop/plasma/systemd`) and selects USE defaults and the ABI. A **build profile** (`BUILD_PROFILE`, selected with `--profile`) is a file in `config/profiles/` that selects package sets and overrides build knobs. Every build has both.

## Build this documentation

```sh
python3 -m venv .venv
.venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve             # live preview at http://127.0.0.1:8000
.venv/bin/mkdocs build --strict    # validation pass; warnings fail the build
```
