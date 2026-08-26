# immos

A Gentoo-built, **immutable**, Flatpak-first, minimal-KDE-Plasma Linux distribution for AMD64
(machines from roughly the last 5 years; UEFI-only). Ships as a single disk image that boots
in VMs and from USB/disk on real hardware, with A/B atomic updates and automatic rollback.
The shipped OS contains no compiler and no Portage — Gentoo is the build system, not the
runtime.

**Status: implemented, pre-first-build.** The build system is complete and offline-tested;
the first real image build (which downloads the Gentoo stage3 container + packages) has not
been run yet. The full design lives in [`plan/`](plan/00-overview.md):

| | |
|---|---|
| [00-overview](plan/00-overview.md) | Goals, decisions, milestones |
| [01-architecture](plan/01-architecture.md) | Immutability, partitions, boot & rollback flow |
| [02-build-pipeline](plan/02-build-pipeline.md) | Containerized Bash build stages |
| [03-package-set](plan/03-package-set.md) | Native packages, firmware/NVIDIA, Flatpak strategy |
| [04-image-and-boot](plan/04-image-and-boot.md) | Image assembly, ESP, VM/USB usage |
| [05-updates](plan/05-updates.md) | A/B updates via systemd-sysupdate, signing |
| [06-pruning](plan/06-pruning.md) | Toolchain-free guarantee & size budget |
| [07-testing](plan/07-testing.md) | QEMU smoke/update/rollback tests, hardware matrix |
| [08-roadmap](plan/08-roadmap.md) | Installer ISO, Secure Boot, verity, tradeoffs |
| [11-kernel-boot-audit](plan/11-kernel-boot-audit.md) | Kernel/UKI/initrd audit: microcode, driver omit list, NVIDIA early KMS |

## Building

Any host with Docker/Podman and Bash — including Docker Desktop (WSL2) on Windows:

```sh
bash scripts/build.sh                 # full pipeline → out/immos-<ver>.img(.zst)
bash scripts/build.sh --console-only  # M1 milestone image (no desktop)
bash scripts/build.sh --dry-run       # show what would run
bash scripts/build.sh --from 40       # resume after a failure
bash scripts/enter.sh                 # debug shell in the builder container
bash scripts/run-vm.sh out/immos-0.1.0.img   # boot the result in QEMU/OVMF
```

First build notes: set `BUILDER_DIGEST` in `config/build.conf` to pin the stage3 base;
signing needs a key (see `config/keys/README.md`) or use `--no-verify` for dev images.
Target machines must have Secure Boot disabled (v1; see plan/08).

Everything the image ships is **compiled** by the build — no binary packages are downloaded
into it, so the first build takes hours. Those builds are cached as binpkgs in the
`immos-cache` volume, which later builds reuse, and which `--clean` deliberately keeps. The
*builder's* own tools are the opposite: installed as binaries from the Gentoo binhost
(`BINHOST_URI`). See [plan/02](plan/02-build-pipeline.md#where-binaries-come-from).

## Testing

`bash tests/run-tests.sh` — offline suite (no Gentoo downloads, no root): bash syntax on
every script incl. rendered templates, CR-byte lint, config lint, and unit/integration
tests (config validation, templating/rebranding, GPT layout math + dd assembly simulation,
update-CLI behavior against mocked systemd tools, build.sh dry-run wiring, boot-splash theme
and asset consistency). Runs on Git
Bash, WSL, or Linux. Shellcheck runs when available (e.g.
`docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x -S warning <files>`).

The QEMU boot/update/rollback tests (plan/07) run as pipeline stage 70 and require a built
image. On Windows checkouts, keep files LF: `find . -path ./out -prune -o -type f -print0 |
xargs -0 dos2unix -q` (the suite's CRLF check catches violations).
