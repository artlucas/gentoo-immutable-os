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
- **Graphical installer / installer ISO.** v1 ships the raw disk image only. Roadmap item.
- **Self-hosting.** The OS cannot rebuild or modify itself. No Portage, no compilers.
- **dm-verity / measured boot.** Immutability in v1 is structural (ro EROFS), not cryptographic. Roadmap.
- **32-bit userland beyond what Steam-class flatpaks bring themselves.** Native multilib kept minimal.
- **Hibernation** (zram-only swap).

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

## Milestones

- **M0 — Scaffolding.** Repo layout, `config/build.conf`, builder container builds, stage runner executes a no-op pipeline end to end.
- **M1 — Console image boots.** Minimal (no desktop) image: systemd + getty, ro EROFS root, `/etc` overlay, `/var` grows, boots in QEMU/OVMF. *This validates every hard architectural risk (boot flow, overlay, loopless assembly) before desktop complexity is added.*
- **M2 — Desktop image.** Full package set: Plasma Wayland session via Plasma Login Manager autologin, NetworkManager, PipeWire, Flatpak + Flathub, preinstalled Firefox, NVIDIA/firmware present. Prune assertions pass.
- **M3 — Updates E2E.** Build v N and N+1; machine on N updates to N+1 over local HTTP and reboots into it; corrupted-slot test triggers automatic rollback.
- **M4 — Hardware validation.** dd to USB; boot/validate on physical Intel iGPU, AMD, and NVIDIA machines per the checklist in 07.
- **M5 (future) — Installer ISO** and roadmap items.
