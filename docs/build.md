# Build

## Prerequisites

- Docker or Podman. `build.sh` auto-detects `docker` first, then `podman`; override with `--runtime docker`, `--runtime podman`, or `--runtime none`. `--runtime none` runs stages directly on the host and requires a Linux host that already carries every tool the stages use.
- Bash. Git Bash with Docker Desktop (WSL2) on Windows works; `build.sh` disables MSYS path rewriting itself. Keep the checkout LF; the test suite's CRLF check rejects violations.
- No host root. Stage containers run `--privileged`. `/dev/kvm` is passed through when present, for stage 70.
- Network access on the first build: the stage3 base image, the tree snapshot, and every source tarball are downloaded. Later builds run mostly from the [build cache](cache.md).

## Run a full build

```sh
bash scripts/build.sh
```

Runs every stage in `scripts/stages/` in numeric order and writes the compressed disk image to `out/immos-<version>.img.zst`; the raw `out/immos-<version>.img` remains beside it. The first invocation builds the `immos-builder` container image and compiles every package from source. Subsequent invocations reuse the build cache: unchanged packages merge from binary packages in minutes instead of compiling.

Inspect a build before running it:

```sh
bash scripts/build.sh --dry-run        # print every container command, execute nothing
bash scripts/build.sh --list           # list the stage scripts
bash scripts/build.sh --list-profiles  # table of build profiles
```

## Build profiles

| Profile | Role | Sets | Description |
|---|---|---|---|
| `desktop` (default) | `target` | `base hardware domain desktop` | The product image |
| `console` | `target` | `base hardware domain` | systemd + getty, no desktop |
| `installer` | `live` | `base hardware domain desktop installer` | Live installer/desktop medium: the `desktop` profile's own root EROFS, byte for byte, plus Calamares and its dependency tail as a systemd system extension on the medium's own `/var` ([plan/34](../plan/34-installer-sysext.md)) |

```sh
bash scripts/build.sh --profile console
bash scripts/build.sh --profile installer
```

Rules:

- The `installer` profile requires a completed `desktop` build at the same `VERSION`, named `BASE_PROFILE`: its own root partition *is* the desktop's root EROFS, dd'd there by stage 60 rather than staged as a file; stage 40 stages the desktop's UKI and a `var-base.tar.zst` (the desktop's own `/var` minus the Flatpak store, which is unpacked into the medium's own `/var/lib/flatpak` instead) as what an install seeds a fresh disk's `/var` from. All three are what `imagedeploy` writes to the target disk ([plan/34](../plan/34-installer-sysext.md) §7, §9).
- A `live` profile is never released; stage 80 skips it by design. A `target` profile with a single root slot is refused — an installable image needs both A/B slots.
- Per-build state is profile-suffixed: the target root, stamps, reports and images carry `-<profile>`. Artifacts the installed system can see — the UKI filename and the `root_<version>` GPT partlabel — never carry the profile.

## Select and resume stages

```sh
bash scripts/build.sh --from 40   # run stages 40 onward
bash scripts/build.sh --only 60   # re-run one stage (implies the force flag)
bash scripts/build.sh --force     # set FORCE_STAGE=1 for every stage
```

Every stage reached by the dispatcher runs. Stages are idempotent and cache-backed, and each writes a stamp under `out/state*/` recording an inputs hash. Resume is explicit through `--from` and `--only`; stamps are state records, not an automatic skip mechanism. When a stage fails, the dispatcher prints the log path and the `--from` value that resumes after the failure.

## Environment variables

`build.sh` forwards these to every stage container:

| Variable | Effect |
|---|---|
| `VERSION_OVERRIDE` | Overrides `VERSION` for this run (`--version X.Y.Z`) |
| `UPDATE_URL_OVERRIDE` | Overrides `UPDATE_URL` (`--update-url URL`) |
| `UPDATE_VERIFY_OVERRIDE` | `0` via `--no-verify`: render update transfers with `Verify=no` |
| `BUILD_PROFILE_OVERRIDE` | Selects the build profile (`--profile NAME`) |
| `FORCE_STAGE` | Set to `1` by `--force` and `--only`; forwarded to stage containers |
| `VENDOR` | `1` runs stage 90 (`--vendor`) |
| `VENDOR_PROFILE` | Stage 90 vendoring depth |
| `ALLOW_UNPINNED` | `1` permits an empty `BUILDER_DIGEST` — development builds only; marks the build unreleasable |
| `RELOCK` | `1` relaxes stage 20's assertions (config hash, closure-shaping keys, stale atoms) during a re-resolve; set by `scripts/relock.sh`, or exported for a manual `--only 20`/`--only 30` preparation run |
| `RELEASE_GPG_KEY` | Key ID that signs `SHA256SUMS` in stage 80; required when `UPDATE_VERIFY=1` |

## Artifacts

| Path | Content |
|---|---|
| `out/immos-<version>[-<profile>].img` and `.img.zst` | Disk image, raw and zstd-compressed |
| `out/immos_<version>[-<profile>].root.erofs` | Root filesystem image — `target` profiles (`desktop`, `console`) only. A `live` profile's medium carries no root EROFS of its own: stage 60 dd's `BASE_PROFILE`'s artifact straight into the medium's root partition instead ([plan/34](../plan/34-installer-sysext.md) §7.2) |
| `out/uki[-<profile>]/immos_<version>.efi` | Unified kernel image. For `installer`, this is the **live** UKI — `BASE_PROFILE`'s own UKI re-wrapped with `live_*` cmdline labels, byte-identical to it in every other section ([plan/34](../plan/34-installer-sysext.md) §8) |
| `out/immos_<version>[-<profile>].var.tar.zst` | `/var` template — `target` profiles only. A `live` profile stages a `var-base.tar.zst` (the base profile's template minus the Flatpak store) inside its own image instead; it is never published to `out/` separately ([plan/34](../plan/34-installer-sysext.md) §7.1) |
| `out/release/<channel>/` | Release channel layout for `systemd-sysupdate` (stage 80) |
| `out/vendor/immos-<version>/` | Offline release archive (stage 90, `--vendor`) |
| `out/logs*/` | Per-stage logs |
| `out/reports*/` | Lock diffs, audit outputs, test reports |
| `out/state*/` | Stage stamps |

Boot a produced image:

```sh
bash scripts/run-vm.sh out/immos-0.3.0.img
```

See [Testing](testing.md) for the VM tooling.

## Signing

A release with `UPDATE_VERIFY=1` signs `SHA256SUMS` with `RELEASE_GPG_KEY=<key-id>` from the environment; the public half is committed at `config/keys/import-pubring.gpg` (see `config/keys/README.md`). For development images, pass `--no-verify` and update transfers render with `Verify=no`. Stage 80 refuses to assemble a release from a build that ran with `ALLOW_UNPINNED=1`.

## Clean

```sh
bash scripts/build.sh --clean
```

Removes the `immos-work` volume and every `out/state*` stamp directory, for every profile. The `immos-cache` volume is kept deliberately; see [Build cache](cache.md).

## Debug shell

```sh
bash scripts/enter.sh
```

Opens an interactive shell in the builder container with the same mounts as a stage run: the checkout at `/repo` (read-only), the work volume at `/work`, the cache volume at `/cache`, and `out/` at `/out`. The tree volume is not mounted; run `bash scripts/build.sh --only 10` first when the shell needs the pinned ebuild tree.
