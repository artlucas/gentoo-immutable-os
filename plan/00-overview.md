# 00 — Overview

## What this is

A Gentoo-based, **immutable**, AMD64 Linux distribution:

- **systemd** init and plumbing throughout (boot, networking hooks, updates, journal).
- **Minimal KDE Plasma 6** (Wayland) desktop — only the core session and a handful of native utilities.
- **Flatpak-first applications** — everything beyond the core desktop comes from Flathub.
- **Immutable root filesystem** in the spirit of Fedora Silverblue / SteamOS: the OS is a read-only image; users never modify it, updates replace it atomically.
- **A/B atomic updates with automatic rollback** from version 1.
- **No toolchain, no Portage in the shipped OS.** Gentoo is the *build substrate*, not the runtime experience. The built system cannot compile or emerge anything, by design.
- Delivered as a **single raw GPT disk image** that boots identically in a VM (QEMU/OVMF, Hyper-V, VMware) and on real hardware (written to USB/NVMe with `dd`).

Build tooling is **Bash**, running inside a privileged Docker/Podman container so builds work from any Linux host, including Docker Desktop + WSL2 on Windows.

## Goals

| Goal | How |
|---|---|
| Broad hardware compatibility, machines from ~2021+ | `gentoo-kernel-bin` (Fedora-derived config), full redistributable `linux-firmware`, CPU microcode, SOF audio firmware, full NVIDIA proprietary stack |
| Immutability | Root is a read-only EROFS image; `/etc` is an overlay; `/var` is the only writable partition |
| Atomic updates + rollback | Dual root slots (A/B), `systemd-sysupdate` client, systemd-boot Automatic Boot Assessment |
| Minimal native footprint | Two-root Portage build (`emerge --root=`) so build deps never enter the target; aggressive prune with hard assertions |
| Apps via Flatpak | Flathub preconfigured; KDE Discover with Flatpak backend only; small preinstalled set |
| VM + bare-metal from one artifact | UEFI-only GPT image; `/var` grows to fill whatever disk it lands on at first boot |

## Non-goals (v1)

- **Legacy BIOS boot.** UEFI only. Machines from the last 5 years are UEFI.
- **Secure Boot.** Users must disable it in firmware for v1. Roadmap: self-signed / shim (see [08-roadmap.md](08-roadmap.md)).
- **Graphical installer / installer ISO.** v1 ships the raw disk image only. **Designed as of
  2026-08-28 — see [16-installer.md](16-installer.md)**: Calamares in a live-only build profile,
  so the installer and its dependency tail never reach an installed system.
- **Self-hosting.** The OS cannot rebuild or modify itself. No Portage, no compilers.
- **dm-verity / measured boot.** Immutability in v1 is structural (ro EROFS), not cryptographic. Roadmap.
- **32-bit userland beyond what Steam-class flatpaks bring themselves.** Native multilib kept minimal.
- ~~**Hibernation** (zram-only swap).~~ **REVERSED 2026-08-28 ([plan/16](16-installer.md) §6).**
  The objection was swap-partition sizing and resume-offset fragility on an image that
  repartitions at first boot. An installer knows the disk and the RAM, which answers the sizing
  half; the resume half is answered by discoverable GPT partition types, which need no `resume=`
  in the UKI cmdline at all. Installed systems get a swap partition and hibernation; the dd'd
  factory image keeps the four-partition, zram-only layout unchanged.

## Locked decisions (from project owner)

1. **Full A/B updates in v1** — dual root slots, update client, boot-slot switching, auto-rollback.
2. **NVIDIA proprietary stack baked in** — in addition to all redistributable firmware/microcode.
3. **Privileged container builds** — reproducible builder image; runs on Docker Desktop/WSL2 or any Linux host.
4. **No Secure Boot in v1.**

## Identity & naming

The distro name is a build variable, never hardcoded:

- `config/build.conf` defines `DISTRO_ID` (default placeholder: `immos`), `DISTRO_NAME`, `DISTRO_VERSION`.
- Used in: `/etc/os-release` (`ID`, `IMAGE_ID`, `IMAGE_VERSION`), UKI filenames (`immos_0.1.0.efi`), root partition labels (`root_0.1.0`), sysupdate match patterns, update server paths, the update CLI name (`immos-update`).

Note on terminology: Gentoo's "stage 3" is a **tarball** (`stage3-amd64-systemd-*.tar.xz`), not an ISO. The pipeline consumes the tarball (via the official `gentoo/stage3` container image or a pinned direct download); the Gentoo *install ISO* is not needed anywhere.

## Document map

| Doc | Covers |
|---|---|
| [01-architecture.md](01-architecture.md) | Immutability model, partition layout, boot flow, `/etc` overlay, `/var` lifecycle, first boot |
| [02-build-pipeline.md](02-build-pipeline.md) | Builder container, stage script contract, two-root emerge technique, caching, repo layout |
| [03-package-set.md](03-package-set.md) | Native package list, profile/USE strategy, firmware & NVIDIA, Flatpak strategy |
| [04-image-and-boot.md](04-image-and-boot.md) | Loopless image assembly, exact GPT layout, ESP contents, live/VM usage, first-boot growth |
| [05-updates.md](05-updates.md) | Versioning, sysupdate transfers, release server layout, signing, rollback |
| [06-pruning.md](06-pruning.md) | INSTALL_MASK, prune lists, no-toolchain assertions, size budget |
| [07-testing.md](07-testing.md) | QEMU smoke tests, update/rollback E2E, hardware checklist |
| [08-roadmap.md](08-roadmap.md) | Installer ISO, Secure Boot, verity, and other future work |
| [09-kde-migration.md](09-kde-migration.md) | The GNOME → KDE Plasma 6 swap: package mapping, USE inversions, GTK residue |
| [10-prune-audit.md](10-prune-audit.md) | Measured audit of the 0.2.0 image: what holds each package in, what can leave, ranked by shipped size |
| [11-kernel-boot-audit.md](11-kernel-boot-audit.md) | Measured audit of the boot artifact: what is in the UKI and initrd, CPU microcode, the driver omit list, NVIDIA early KMS, the splash hand-off |
| [12-first-boot-reboot-loop.md](12-first-boot-reboot-loop.md) | The first-boot reboot loop: repart ordering and the erofs→netfs dracut omission |
| [13-distrobox.md](13-distrobox.md) | The mutable userland: rootless podman + distrobox, subuid setup, why it does not weaken the toolchain-free guarantee |
| [16-installer.md](16-installer.md) | The Calamares installer and the build-profile mechanism that keeps it out of the installed system; swap + hibernation; the live ISO |
| [14-boot-splash-kms.md](14-boot-splash-kms.md) | Replacing Plymouth with a KMS splash: why no fbdev option exists on this kernel, the drop-master design, and taking the whole graphics payload out of the initrd |
| [15-version-pinning.md](15-version-pinning.md) | Pinning the tree by commit and every package version by lock file, moving pins deliberately (GLSA-driven patch releases), and the vendored archive that rebuilds a release offline |

## Milestones

- **M0 — Scaffolding.** Repo layout, `config/build.conf`, builder container builds, stage runner executes a no-op pipeline end to end.
- **M1 — Console image boots.** Minimal (no desktop) image: systemd + getty, ro EROFS root, `/etc` overlay, `/var` grows, boots in QEMU/OVMF. *This validates every hard architectural risk (boot flow, overlay, loopless assembly) before desktop complexity is added.*
- **M2 — Desktop image.** Full package set: Plasma Wayland session via Plasma Login Manager autologin, NetworkManager, PipeWire, Flatpak + Flathub, preinstalled Firefox, NVIDIA/firmware present. Prune assertions pass.
- **M3 — Updates E2E.** Build v N and N+1; machine on N updates to N+1 over local HTTP and reboots into it; corrupted-slot test triggers automatic rollback.
- **M4 — Hardware validation.** dd to USB; boot/validate on physical Intel iGPU, AMD, and NVIDIA machines per the checklist in 07.
- **M5 — Installer.** Build profiles, then Calamares on live media, then swap/hibernation and
  the ISO. Phased in [16-installer.md](16-installer.md) §8.
