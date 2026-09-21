# Testing

Three layers: an offline suite that runs anywhere, QEMU boot tests that run as pipeline stage 70 against a built image, and policy tests that pin the build's own contracts.

## Offline suite

```sh
bash tests/run-tests.sh
```

Runs with no root, no Docker, no Gentoo downloads, on Git Bash, WSL, or Linux. It covers:

- `bash -n` syntax on every shell script, including the rendered forms of every template
- CR-byte lint (Windows checkouts must stay LF)
- config validation and lint
- unit and integration tests: templating and rebranding, GPT layout math and the `dd` assembly simulation, the update CLI against mocked systemd tools, `build.sh` dry-run wiring, boot-splash asset and cmdline-token consistency, overlay install, profiles, the installer, domain and managed-mode logic

Shellcheck runs when available:

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x -S warning <files>
```

## Policy tests

Two suite members double as regression guards for the contracts the [pinning](pinning.md) and [cache](cache.md) pages describe:

| Test | Asserts |
|---|---|
| `tests/test-pin-policy.sh` | Pins well-formed (digest shape, snapshot date, SHA-256); lock headers record the current `portage_config_hash`; the hash excludes `lock/` and `expected-packages*` and is checkout-path independent; image and builder locks agree on shared packages (only `sys-apps/portage` may diverge); `expected-packages` is a subset of the lock; `apps.lock` shape; the builder Dockerfile copies only `builder.lock`; `--security` detects against the committed lock, never the target |
| `tests/test-binpkg-policy.sh` | `buildpkg` on; `getbinpkg` and `PORTAGE_BINHOST` absent for the target; `PKGDIR=/cache/binpkgs`; `DISTDIR=/cache/distfiles` |

## Stage 70: boot tests

Stage 70 boots the built image in QEMU/OVMF and asserts against the running guest. The guest self-reports through a systemd unit gated on an SMBIOS credential that `run-vm.sh --test` injects; on real hardware the unit stays inert.

| Test | Trigger | Asserts |
|---|---|---|
| T1 smoke | Default | Two boots, self-reported assertions (failed units, boot state) |
| T2 update | `UPDATE_TEST_BASE_IMG=<old.img>` | End-to-end `systemd-sysupdate` update from the old image against `out/release` served over HTTP |
| Domain | `--with-test-dc` | AD join against a disposable Samba domain controller; the guest discovers the domain through real SRV records |
| Managed | `--with-test-api` | Managed-mode enrolment against a FastAPI control plane that signs bundles with the test key |

```sh
bash scripts/build.sh --with-test-dc        # + the domain tests
bash scripts/build.sh --with-test-api       # + the managed tests
```

The fixtures are not stages: they are containers the build stands up and tears down, with stage 70's container joined to their network. Both are incompatible with `--offline` and skip cleanly when absent — the domain and managed tests never fail for the fixture not being there.

## VM tooling

`scripts/run-vm.sh` boots any built image interactively:

```sh
bash scripts/run-vm.sh out/immos-0.3.0.img                    # graphical window
bash scripts/run-vm.sh IMG --headless serial.log              # no display, serial console to file
bash scripts/run-vm.sh IMG --test smoke                       # self-reporting boot
bash scripts/run-vm.sh IMG --test update --update-url http://10.0.2.2:8000/stable
bash scripts/run-vm.sh IMG --writable                         # guest writes hit IMG
bash scripts/run-vm.sh IMG --disk-size 32G                    # bigger virtual disk; repart grows /var
bash scripts/run-vm.sh IMG --extra-disk 32G                   # blank second disk, e.g. an install target
```

`--test domain` and `--test managed` take a single comma-separated credential spec (`--domain domain=corp.test,user=Administrator,password=…`, `--managed api=https://…,code=…,user=…,password=…`).

## Translation upkeep

`scripts/update-translations.sh` refreshes the installer's `.ts` translation sources. It is a maintainer tool and never runs in the build.
