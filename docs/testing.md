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
bash scripts/run-vm.sh IMG --extra-disk 32G --extra-disk-keep # ...and keep it beside IMG across runs
```

`--test domain` and `--test managed` take a single comma-separated credential spec (`--domain domain=corp.test,user=Administrator,password=…`, `--managed api=https://…,code=…,user=…,password=…`).

`--extra-disk-keep` is what makes the extra disk survive the run — reused at `IMG.extra-disk.qcow2` on the next call instead of being thrown away with the rest of the VM's scratch state, and `run-vm.sh` boots a qcow2 passed as `IMG` directly (its format is autodetected), so that disk can also be booted on its own. Together they are the loop a reinstall-and-keep test needs:

```sh
bash scripts/run-vm.sh out/immos-<v>-installer.img --extra-disk 40G --extra-disk-keep   # 1. install
bash scripts/run-vm.sh out/immos-<v>-installer.img.extra-disk.qcow2 --writable          # 2. use it
bash scripts/run-vm.sh out/immos-<v>-installer.img --extra-disk-keep                    # 3. reinstall, keeping
bash scripts/run-vm.sh out/immos-<v>-installer.img.extra-disk.qcow2 --writable          # 4. check it
```

### The installer, end to end

Since [plan/34](../plan/34-installer-sysext.md) the medium *is* the desktop, and Calamares ships
as a `systemd-sysext` extension on the stick's own `/var` rather than in any root image
(plan/34 §3). None of this has an automated boot test in stage 70 — it is driven by hand with
`run-vm.sh`, the way the reinstall walkthrough below is. An erase install has been verified end
to end against the `de78ad3` build (plan/34 §11's own measured build): the installed root's
sha256 equals `out/immos_0.3.1.root.erofs`, there is no `calamares` and no `live` user on the
target, the preinstalled Flatpaks run, and there are no failed units. A `--extra-disk-keep`
reinstall has not had the same pass yet — walk it by hand with the loop above.

### Reinstall and keep, by hand

The installer's "Keep my files, apps and settings" checkbox (plan/33) has no automated boot test — walk it with the loop above:

1. **Install** (step 1): boot the installer image with a fresh `--extra-disk-keep` target, and install onto it normally — the disk holds nothing yet, so the disk page offers only the plain erase.
2. **Use it** (step 2): boot the installed disk on its own (`IMG.extra-disk.qcow2`, `--writable` so the changes stick), add a file and a Flatpak, change the time zone and keyboard layout, and note the hostname and `/etc/machine-id`.
3. **Reinstall, keeping** (step 3): boot the installer image again with the same `--extra-disk-keep` target. The disk page now names the disk by the version already on it and offers the keep checkbox, ticked by default. Install with it ticked.
4. **Check it** (step 4): boot the installed disk again. The file, the Flatpak, the time zone, the keyboard layout, the hostname and the machine-id are all unchanged; `findmnt / /var` names the same disk the installer booted from a moment before, not the stick. `sfdisk --dump` on the disk shows the new `root_<v>` in partition 2 and `_empty` in partition 3.
5. **Reinstall, erasing**: run the loop once more with the checkbox unticked, and confirm the disk comes back with none of the above.

The disk page itself is checked at 1024×640 (the installer's minimum window size) in English and German, with two disks listed — one that offers keeping and one that does not.

## Translation upkeep

`scripts/update-translations.sh` refreshes the installer's `.ts` translation sources. It is a maintainer tool and never runs in the build.
