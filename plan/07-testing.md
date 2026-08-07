# 07 — Testing

## Test tiers

| Tier | When | Where |
|---|---|---|
| T0 script hygiene | every commit | shellcheck + `bash -n` on all scripts; config lint (`build.conf` schema check) |
| T1 boot smoke | every image build (stage 70) | QEMU/OVMF in the build container |
| T2 update E2E | before any release | QEMU, two built versions, local HTTP server |
| T3 rollback drill | before any release | QEMU, sabotaged update |
| T4 hardware matrix | per milestone / release | physical machines, manual checklist |

## T1 — Boot smoke (automated, stage 70)

Test builds bake an extra cmdline fragment (`console=ttyS0`) and a `arttest-testmode`
credential toggled via SMBIOS (`-smbios type=11,value=io.systemd.credential:arttest.test=1`)
so the *same* image can run assertions without differing from the shipped one beyond the UKI
cmdline. QEMU invocation (shared `run-vm.sh`):

```
qemu-system-x86_64 -machine q35,accel=kvm:tcg -cpu max -m 4096 -smp 4
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd
  -drive if=pflash,format=raw,file=$WORK/OVMF_VARS.fd        # fresh per-run copy: no NVRAM state leaks between tests
  -drive file=$IMG,if=virtio,format=raw
  -device virtio-gpu -display none -serial file:$WORK/serial.log
  -netdev user,id=n0 -device virtio-net,netdev=n0
```

KVM used when `/dev/kvm` is present (Docker `--privileged` passes it through; WSL2 on Win11
supports nested virt). TCG fallback multiplies all timeouts ×5.

Assertions (a watcher tails `serial.log` with a deadline, default 180 s KVM):

1. `systemd-boot` banner seen → bootloader OK.
2. `Welcome to ${DISTRO_NAME}` → kernel+initrd+switch-root OK.
3. No `Failed to mount` / `emergency.target` / `Kernel panic` strings (deny-list).
4. `Reached target Graphical Interface` → session stack up.
5. Test-mode oneshot unit (`ConditionCredential=arttest.test`) runs late and prints a
   machine-readable line to the serial console:
   `ARTTEST-TEST: ok version=<v> root=<partlabel> etc_overlay=rw var=rw flatpak_remotes=1 failed_units=0`
   — produced by checking `findmnt -no SOURCE /etc` is an overlay, `touch /etc/probe && rm`,
   `flatpak remotes | grep -c flathub`, `systemctl --failed --quiet` etc.
6. Clean `systemctl poweroff` via the same unit when in test mode → QEMU exits 0.

Console-only (M1) builds run the same harness with assertion 4 swapped for
`Reached target Multi-User System`.

Second-boot check: boot the same disk again and assert the var partition was grown
(`ARTTEST-TEST` line reports `var_size`) and machine-id persisted — catches
first-boot-only bugs.

## T2 — Update E2E (stage 70 `--update-test`)

```
1. Build version A (e.g. 0.0.1) and version B (0.0.2) — CI does this with two
   `build.sh --version` invocations sharing /cache (fast).
2. Serve out/release/ via `python3 -m http.server` on a bridge the VM can reach
   (qemu user-net → 10.0.2.2). Test-mode images point UPDATE_URL at it via credential.
3. Boot image A. Test unit (update-test variant) runs `arttest-update apply`, asserts
   sysupdate exit 0, asserts slot B now labeled root_0.0.2 (sfdisk -J), asserts
   ESP has arttest_0.0.2+3.efi. Reboots.
4. Watcher asserts next boot reports version=0.0.2 and, after boot-complete, the UKI was
   blessed (renamed, no +tries suffix) — checked on 3rd boot or via guest probe of /efi.
5. Assert old version still present: slot A labeled root_0.0.1, arttest_0.0.1.efi on ESP.
```

## T3 — Rollback drill

Two failure injections, both must end with the machine healthy on version A:

- **Broken image:** build a deliberately bad version B (test hook: `SABOTAGE=panic` builds a
  UKI whose cmdline appends `systemd.unit=emergency.target`… better: append
  `panic=5 init=/nonexistent`). Apply update, let it fail 3 boots, assert 4th boot serial
  shows `version=0.0.1` and B's UKI name carries `+0-3`.
- **Corrupted download:** flip bytes in the served `.erofs.zst`, assert `arttest-update
  apply` fails (checksum), system untouched, exit code nonzero, slot B unchanged.

Also asserted: GPG — strip `SHA256SUMS.gpg` from the server, `apply` must refuse.

## T4 — Physical hardware checklist (manual, per release)

Minimum matrix (aligned with the 5-year compatibility target):

| Machine class | Must pass |
|---|---|
| Intel laptop, iGPU (Iris Xe class), 2021+ | boot from USB, Wi-Fi, BT, audio (SOF), suspend/resume, brightness, external display (HDMI/USB-C) |
| AMD laptop (Zen 3+ APU) | same list, amdgpu |
| Desktop w/ NVIDIA RTX (Turing+) | boot, `nvidia` module loaded (not nouveau), Plasma Wayland session on NVIDIA, vulkaninfo, video decode |
| Any machine | update A→B→bless over real network; manual `arttest-update rollback`; Flatpak install via Discover; reboot persistence of user files + Wi-Fi creds |

Recorded as a filled-in copy of `plan/checklists/hw-<machine>-<version>.md` (template to be
added with M4). Known-limit notes to verify rather than pass: Pascal-or-older NVIDIA falls
back to nouveau; IPU6 MIPI webcams may not stream.

## CI shape (later, but designed for now)

Stages already run in a container with no interactive steps and produce logs/artifacts under
`out/` — mapping to GitHub Actions/GitLab is: T0 on PR; T1 on merge (needs KVM runner or
slow-TCG tolerance); T2/T3 nightly; T4 manual. No design changes needed, just runners.
