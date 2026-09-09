# 07 — Testing

## Test tiers

| Tier | When | Where |
|---|---|---|
| T0 script hygiene | every commit | shellcheck + `bash -n` on all scripts; config lint (`build.conf` schema check); pin policy — lock shape, headers, cross-lock agreement, and that every stage consumes the pins it claims to (`test-pin-policy.sh`, plan/15) |
| T1 boot smoke | every image build (stage 70) | QEMU/OVMF in the build container |
| T2 update E2E | before any release | QEMU, two built versions, local HTTP server |
| T3 rollback drill | before any release | QEMU, sabotaged update |
| T4 hardware matrix | per milestone / release | physical machines, manual checklist |

## T1 — Boot smoke (automated, stage 70)

Test builds bake an extra cmdline fragment (`console=ttyS0`) and a `immos-testmode`
credential toggled via SMBIOS (`-smbios type=11,value=io.systemd.credential:immos.test=1`)
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
5. Test-mode oneshot unit (`ConditionCredential=immos.test`) runs late and prints a
   machine-readable line to the serial console:
   `IMAGE-TEST: ok version=<v> root=<partlabel> etc_overlay=rw var=rw flatpak_remotes=1 failed_units=0`
   — produced by checking `findmnt -no SOURCE /etc` is an overlay, `touch /etc/probe && rm`,
   `flatpak remotes | grep -c flathub`, `systemctl --failed --quiet` etc.
6. Clean `systemctl poweroff` via the same unit when in test mode → QEMU exits 0.

The report line has grown fields since this list was written; `autologin=` is the one worth
knowing about here. It asks logind for seat0's *active* session and stage 70 dies unless that is
the live user's, which makes T1 the only automated check that the whole greeter path works — and
since [plan/17](17-animated-splash.md) that includes the boot splash handing DRM master back
before the display manager starts. If the release unit ever stops reaching the splash, logind's
`drmSetMaster()` fails for the compositor and this assertion is what reports it, on an image
where nothing else would.

Console-only (M1) builds run the same harness with assertion 4 swapped for
`Reached target Multi-User System`.

Second-boot check: boot the same disk again and assert the var partition was grown
(`IMAGE-TEST` line reports `var_size`) and machine-id persisted — catches
first-boot-only bugs.

### A timing budget that does not close, observed once on `console` 2026-09-07

`console` timed out at stage 70 on the second smoke boot with **no marker and no DETAIL lines** —
a 1467-byte serial log ending at a login prompt. It did not reproduce: the identical image passed
the same two boots on a re-run, and had passed three times before. So it is a flake, and the
product was never implicated. The *mechanism* is worth writing down anyway, because it is a gap in
the harness rather than noise.

The in-guest reporter bounds its settle with `timeout 180 systemctl is-system-running --wait`, and
its comment states the reason plainly: *"a system that never settles must still produce a report,
otherwise the harness just times out with no information at all."* But `boot_and_watch` caps the
whole boot at `TIMEOUT=300` (KVM). Add it up for the case the bound exists to handle:

| | |
|---|---|
| boot to the point the unit runs | ~30–60 s |
| the settle bound, fully spent | 180 s |
| collection, with its two 15 s polls | up to ~30 s |
| **total** | **up to ~270 s against a 300 s cap** |

Roughly thirty seconds of margin. On the failed boot the settle plainly ran its full 180 s — the
agetty banner redrew 191 s after the first one — and whatever the remaining budget was, it was not
enough. **So the mitigation does not achieve its stated purpose:** precisely when a unit hangs in
`activating`, the report that would name it is the thing that gets killed, and the operator is left
with the bare timeout the bound was written to avoid.

Two cheap changes would close it, neither applied here — they would desync the three images just
built from the tree, and this is harness work, not Active Directory:

1. **Lower the in-guest bound** to ~90 s. Nothing healthy takes that long, and it buys back margin
   for exactly the unhealthy case.
2. **Report the settle outcome.** A `settled=yes|no` field, and on `no` the output of
   `systemctl list-jobs` on `IMAGE-TEST-DETAIL` lines. `dump_failed` lists only *failed* units, so
   a unit stuck in `activating` — the thing that causes this — is currently invisible to it.

The general point is the one [plan/18](18-active-directory.md) §8 already draws from three
separate incidents in one afternoon: a harness that reports the wrong cause costs more than one
that fails outright, and a bound whose timeout does not fit the budget it lives inside is a
report that was never going to arrive.

## T-DOM — Active Directory (stage 70, `build.sh --with-test-dc`)

Added by [plan/18](18-active-directory.md). Skipped, never failed, when no domain controller is
present — an offline build and a plain `build.sh` both stay green.

**The fixture.** `tests/ad-dc/` builds a container *from the pinned builder image*, emerges
`net-fs/samba[addc]` in it and provisions a disposable `IMMOS.TEST` domain with one test user and
one group. It is a separate image on purpose: `addc` requires samba to build its own Heimdal, and
that USE must never be visible to the resolution that produces the product (`builder/Dockerfile`
explains why a package's flags on the builder's `/` leak into the target's REQUIRED_USE).

**How the guest reaches it, which was the part worth proving.** Three hops —
`guest --(slirp)--> stage-70 container --(docker bridge)--> DC`. QEMU's user networking NATs
outbound TCP/UDP, so LDAP, Kerberos and kpasswd need nothing. DNS is the hop that does, because AD
is discovered through SRV records: QEMU answers the guest's DNS itself and relays to whatever the
*container's* `/etc/resolv.conf` names. So the whole mechanism is one docker flag — `build.sh`
runs stage 70 with `--dns <dc>` — and **the guest is the shipped image, unmodified**. No seeded
network profile, no special build, nothing to keep in sync.

| ID | Asserts |
|---|---|
| **T-DOM-1** | Install from the medium with the AD box ticked: the DC holds a computer account under the **typed** hostname (plan/18 §7.3), and the target's `/var` overlay carries `sssd.conf`, the keytab and the enablement symlink. Blocked on the same unattended-Calamares work as plan/16 §10 q5; manual until then |
| **T-DOM-2** | The installed disk boots and a domain user logs in; `live` is gone and autologin is off |
| **T-DOM-3** | Runtime join on a desktop image: `getent passwd` resolves the domain user with a mapped uid, `kinit` gets a TGT, `su -` authenticates through PAM, `pam_mkhomedir` creates the home. Then `leave`, and the machine is back to what it was |
| **T-DOM-4** | **The unjoined regression, and the one that runs on every build.** A domain-ready image that has never been joined boots with `failed_units=0`, `sssd=inactive` (not `failed`, which would fail `boot-complete.target` and burn a boot try), and local accounts still resolving through an `nsswitch.conf` that names `sss` |

T-DOM-4 needs no domain controller and is folded into the existing smoke report, so the property
that matters to every user who will never join a domain is checked on every single build.

## T-MAN — Managed mode (stage 70, `build.sh --with-test-api`)

Added by [plan/19](19-managed-mode.md). Skipped, never failed, when no control plane is running,
exactly as T-DOM is.

**The fixture.** `tests/managed-api/` builds a container from the pinned builder and runs a
FastAPI implementation of plan/19 §5 over HTTPS: one org, three users, one device, and a **real
detached OpenPGP signature** over every bundle, made with the private half of the key baked into
the image. The FastAPI stack is not in the pinned tree, so it is pip-installed into a venv under
`/opt` — the same isolation argument `tests/ad-dc/` makes about samba's USE flags, and for the
same reason: nothing there participates in resolving a package for the target. A `/test/` control
surface, which no real server may have, is what makes the hard cases reachable — revoke a device,
replay an old bundle, corrupt one byte of a current one.

**How the guest reaches it**, and the contrast with T-DOM is the interesting part: it just does.
Managed mode reaches its control plane by **URL, over one TCP port**, which QEMU's user-mode
networking NATs to whatever the stage-70 container can reach. There are no SRV records, no
Kerberos and no DNS involvement at all, so unlike the domain fixture there is nothing to arrange
about the guest's resolver. That difference is not an accident of the test rig; it is why managed
mode works from a coffee shop and a domain join does not.

| ID | Asserts |
|---|---|
| **T-MAN-1** | **The round trip.** Enrol a running desktop image against the fixture; a managed user resolves through NSS by name *and by uid* (the `<uid>.user` symlink), carries a supplementary group (a `.membership` **file**, not a record field), has a `0640 root:shadow` hash, **proves that password unprivileged through `unix_chkpwd`** — the lock-screen path, plan/19 §13.1 — logs in on a real console and gets a home directory. Then `leave`, and both accounts are still there as local ones |
| **T-MAN-2** | **Scoped records.** A user the bundle does not grant this device has no record, no `getent` entry and no trace under `/etc/userdb` — enforcement by absence, so the hash was never sent |
| **T-MAN-3** | **Anti-rollback and tamper.** An older correctly-signed bundle is refused and the newer policy stays in force; a bundle with one byte changed fails signature verification; a bundle signed by a key not in the image is refused. All three exit 0 |
| **T-MAN-4** | **The install that cannot reach the control plane.** Phase D; blocked on the same unattended-Calamares work as T-DOM-1 |
| **T-MAN-5** | **The unenrolled regression, and the one that runs on every build.** A managed-ready image that has never enrolled boots with `failed_units=0`, its sync unit **skipped** rather than failed, `/etc/userdb` absent and the timer disabled |
| **T-MAN-6** | **The offline machine.** Enrolled, then the API taken away: logins work, policy holds, the queue grows and is capped, `failed_units=0` across three reboots. Phase C |
| **T-MAN-7** | **Mode exclusivity.** `<id>-domain join` on a managed machine refuses and writes nothing, and the converse. Asserted offline today, including that the refusal is *preflight* — before `adcli` runs |
| **T-MAN-8** | **The exit.** `leave` on a device with two managed users leaves two working local accounts with the same uids, homes and passwords. Folded into T-MAN-1's guest run, because the ordering bug it catches (materialising before removing the records) turns `leave` into an account deletion |

T-MAN-5, like T-DOM-4, needs no fixture and rides on the existing smoke report — so the property
that matters to every user who will never enrol is checked on every single build.

**Offline**, `tests/test-managed.sh` needs neither network nor fixture: `--print-config` diffed
against golden records (including the symlinks, the `.membership` names and the `0640` mode — all
three silent failures), signature verification with negatives for a tampered bundle and an
untrusted key, the preset and the `ConditionPathExists` drop-in, the §5 request shapes, the UID
window, and the one that protects the fleet — **the client exits 0 under every injected failure**.

## T2 — Update E2E (stage 70 `--update-test`)

```
1. Build version A (e.g. 0.0.1) and version B (0.0.2) — CI does this with two
   `build.sh --version` invocations sharing /cache (fast).
2. Serve out/release/ via `python3 -m http.server` on a bridge the VM can reach
   (qemu user-net → 10.0.2.2). Test-mode images point UPDATE_URL at it via credential.
3. Boot image A. Test unit (update-test variant) runs `immos-update apply`, asserts
   sysupdate exit 0, asserts slot B now labeled root_0.0.2 (sfdisk -J), asserts
   ESP has immos_0.0.2+3.efi. Reboots.
4. Watcher asserts next boot reports version=0.0.2 and, after boot-complete, the UKI was
   blessed (renamed, no +tries suffix) — checked on 3rd boot or via guest probe of /efi.
5. Assert old version still present: slot A labeled root_0.0.1, immos_0.0.1.efi on ESP.
```

## T3 — Rollback drill

Two failure injections, both must end with the machine healthy on version A:

- **Broken image:** build a deliberately bad version B (test hook: `SABOTAGE=panic` builds a
  UKI whose cmdline appends `systemd.unit=emergency.target`… better: append
  `panic=5 init=/nonexistent`). Apply update, let it fail 3 boots, assert 4th boot serial
  shows `version=0.0.1` and B's UKI name carries `+0-3`.
- **Corrupted download:** flip bytes in the served `.erofs.zst`, assert `immos-update
  apply` fails (checksum), system untouched, exit code nonzero, slot B unchanged.

Also asserted: GPG — strip `SHA256SUMS.gpg` from the server, `apply` must refuse.

## T4 — Physical hardware checklist (manual, per release)

Minimum matrix (aligned with the 5-year compatibility target):

| Machine class | Must pass |
|---|---|
| Intel laptop, iGPU (Iris Xe class), 2021+ | boot from USB, Wi-Fi, BT, audio (SOF), suspend/resume, brightness, external display (HDMI/USB-C) |
| AMD laptop (Zen 3+ APU) | same list, amdgpu |
| Desktop w/ NVIDIA RTX (Turing+) | boot, `nvidia` module loaded (not nouveau), Plasma Wayland session on NVIDIA (the greeter refuses Wayland there without DRM modesetting — the UKI cmdline already carries `nvidia-drm.modeset=1`, so confirm `loginctl show-session` reports `Type=wayland` and not a silent X11 fallback), vulkaninfo, video decode |
| Any machine | update A→B→bless over real network; manual `immos-update rollback`; Flatpak install via Discover; reboot persistence of user files + Wi-Fi creds |

Recorded as a filled-in copy of `plan/checklists/hw-<machine>-<version>.md` (template to be
added with M4). Known-limit notes to verify rather than pass: Pascal-or-older NVIDIA has no
working GPU driver (nouveau is dropped from the package set and blacklisted anyway, plan/03);
IPU6 MIPI webcams may not stream.

## CI shape (later, but designed for now)

Stages already run in a container with no interactive steps and produce logs/artifacts under
`out/` — mapping to GitHub Actions/GitLab is: T0 on PR; T1 on merge (needs KVM runner or
slow-TCG tolerance); T2/T3 nightly; T4 manual. No design changes needed, just runners.
