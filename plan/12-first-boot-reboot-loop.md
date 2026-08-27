# 12 — The first-boot reboot loop (2026-08-26)

The first real 0.2.0 image built clean and then could not boot. Every attempt produced the same
four lines on the serial console and then started over, forever:

```
[FAILED] Failed to start Repartition Root Disk.
Warning: Boot has failed. To debug this issue add "rd.shell rd.debug" to the kernel command line.
Rebooting.
[    3.58] reboot: Restarting system
```

Stage 70 caught it — `timeout after 300s waiting for test marker` — so the build did not ship a
broken image. What it could not do was say *why*, and the console could not either: the failure is
3.5 seconds in, behind `quiet splash`, and the actual error goes to the journal of an initrd that
is about to be thrown away.

There were **two** independent faults. The second was hidden behind the first, and either one
alone is an unbootable image.

## How it was diagnosed without rebuilding

`rd.emergency=reboot` (plan/11, finding 8) is what makes A/B rollback automatic, and it is also
what makes this class of failure opaque: the machine reboots before anything can be read, and
`editor no` in `loader.conf` plus a cmdline sealed inside the UKI means there is no boot-time way
to ask for a shell. That is a deliberate tradeoff, and it does not have to be paid at debug time.

The UKI is just a PE file, so the kernel and initrd can be lifted straight out of it and booted
under QEMU with any cmdline at all — no rebuild, no image surgery, and the real disk image
attached unchanged:

```sh
objcopy -O binary --only-section=.linux  out/uki/immos_0.2.0.efi vmlinuz
objcopy -O binary --only-section=.initrd out/uki/immos_0.2.0.efi initrd.img
qemu-system-x86_64 ... -kernel vmlinuz -initrd initrd.img \
  -append 'root=PARTLABEL=root_0.2.0 rootfstype=erofs ro console=ttyS0 loglevel=6 \
           systemd.journald.forward_to_console=1 rd.emergency=poweroff immos.splash=0'
```

`systemd.journald.forward_to_console=1` is the load-bearing part — it puts the initrd journal on
the serial port, which is where both real error messages turned out to live. `rd.emergency=poweroff`
replaces the reboot loop with a single clean failure. Worth keeping in mind for the next one.

## Fault 1 — `systemd-repart.service` cannot work unmodified in a dracut initrd

```
systemd-repart[324]: No machine ID set, using randomized partition UUIDs.
systemd-repart[324]: Failed to determine backing device of /sysroot/usr: No such file or directory
systemd-repart.service: Main process exited, code=exited, status=1/FAILURE
```

systemd-repart finds the disk to repartition from the backing device of `/sysusr/usr`, falling
back to `/sysroot/usr`. Upstream's unit is ordered `After=initrd-usr-fs.target`,
`Before=initrd-root-fs.target`, which is correct for the systemd/mkosi initrd, where `/sysusr/usr`
is mounted by the time that target is reached.

A dracut initrd mounts neither. `initrd-usr-fs.target` is reached trivially, so repart runs
immediately — measured at 3.088s, where udevd does not start until 3.139s. There are no block
device nodes yet, let alone a mounted root. Both probes miss and repart exits **1**.

The unit tolerates exit 76 ("no root block device") and 77 ("no GPT") precisely so that a machine
with nothing to repartition boots anyway. It does not tolerate 1. So the service fails, and in an
initrd a failed service means emergency, and `rd.emergency=reboot` means the loop.

**Fix:** `config/rootfs/usr/lib/dracut/modules.d/90repart-sysroot/`, a dracut module whose only
job is to drop `Requires=sysroot.mount` / `After=sysroot.mount` into
`systemd-repart.service.d/`. The unit stays `Before=initrd-root-fs.target`, so it still runs
before `/var` is mounted and its `x-systemd.growfs` grows the filesystem into the partition repart
just extended.

It has to be a **dracut module, not a file in `config/rootfs`**: `systemd-repart.service` also
runs on the booted system — harmlessly, reporting `No changes.` — and there `Requires=sysroot.mount`
would name a unit that does not exist.

## Fault 2 — omitting `netfs` made the root filesystem unmountable

With repart fixed, the next boot got one step further and died on the root mount:

```
erofs: Unknown symbol __fscache_acquire_volume (err -2)
erofs: Unknown symbol __fscache_begin_read_operation (err -2)
mount[452]: mount: /sysroot: unknown filesystem type 'erofs'.
```

`netfs` was in class 4 of `config/dracut-omit-drivers.txt`, on the reasoning that it is only the
shared cache layer under ceph, afs, cifs, nfs and 9p — every one of which this initrd omits. That
was true when it was written and is no longer true: since 6.10 `erofs.ko` links against netfs, and
erofs is this image's **root filesystem**. `modinfo -F depends erofs` prints `netfs`.

What makes this one nasty is how quietly it fails. Omitting a dependency does not remove the
module that needs it, and does not fail the build:

- `erofs.ko` is still installed — the existing `has 'fs/erofs/erofs\.ko'` assertion in stage 40
  passed, because the file really is there.
- dracut runs `depmod` over the initrd tree, so `erofs.ko` simply **loses its dependency line** in
  `modules.dep`. Before: `kernel/fs/erofs/erofs.ko: kernel/fs/netfs/netfs.ko`. After:
  `kernel/fs/erofs/erofs.ko:`.
- modprobe honours that and insmods erofs bare. The kernel rejects it for undefined symbols, and
  `mount` reports the perfectly misleading `unknown filesystem type 'erofs'`.

**Fix:** `netfs` removed from the omit list, with a paragraph in that file saying why it must not
go back. `fscache` is kept as a name only — this kernel has no `fscache.ko`, the code having been
merged into netfs — and `cachefiles`, a genuinely separate module with no consumer here, stays.

## The guard

Neither fault was visible to any build-time check, and the omit list is exactly the kind of file
that will grow another too-greedy entry. Stage 40's verify block now resolves **every** module in
the initrd against the *target's* `modules.dep` — the complete one, before dracut pruned it — and
fails the build if any dependency is missing from the initrd:

```
verify: these initrd modules have dependencies that are NOT in the initrd, so the
  kernel would refuse to load them ("Unknown symbol"):
  erofs needs netfs
```

Run against the as-built 0.2.0 initrd, that check found 15 broken edges across 6 modules. One
was `erofs -> netfs`. The other five were the consumer halves of libraries the omit list had
already removed — unloadable dead weight rather than a boot failure, but there for the same
reason, and now omitted alongside what they depend on:

| module | needs | already omitted by |
|---|---|---|
| `erofs` | `netfs` | class 4 — **the root filesystem** |
| `rbd` | `libceph` | class 4 (ceph) |
| `chcr` | `cxgb4` | class 6 |
| `rnbd_client` | `ib_core`, `ib_cm`, `iw_cm`, `rdma_cm` | class 3 |
| `rtrs_client` | same | class 3 |
| `rtrs_core` | same | class 3 |

After both fixes the closure is complete at 731 modules with zero violations.

A second assertion checks the repart drop-in is actually in the initrd, so a rename or a dropped
`--add` argument fails the build rather than the first boot.

Stage 40 also no longer hard-codes `90etc-overlay` as the one custom dracut module — it discovers
them from `config/rootfs/usr/lib/dracut/modules.d/`, so adding a module is one directory.

## Result

Same disk image, initrd rebuilt with both fixes, booted from the extracted kernel:

```
systemd[1]: Mounted /sysroot.
systemd-repart[454]: Applying changes to /dev/vda.
systemd-repart[454]: Growing existing partition 3.
systemd-repart[454]: All done.
systemd[1]: Mounted /sysroot/var.
systemd[1]: Switching root.
systemd[1]: Reached target Graphical Interface.
IMAGE-TEST: ok version=0.2.0 etc_overlay=overlay graphical=yes failed_units=0
            var_size=4143677440 flatpak_remotes=1 resolved=yes dns=yes failed_list=none phase=boot
```

The second `systemd-repart` run, the one on the booted system, reports `No changes.` — which is
the confirmation that the drop-in belongs in the initrd only.

Then rebuilt through the pipeline and re-tested by stage 70 itself, booting the real image through
systemd-boot rather than an extracted kernel:

```
[40-configure] initrd: 730 modules, none matching the 72 omit patterns
[40-configure] initrd: dependency closure complete for all 730 modules
[60-image] image OK: /out/immos-0.2.0.img (3087 MiB compressed)
[70-test] smoke: first boot (repart growth, machine-id generation)
[70-test] smoke: second boot (persistence)
[70-test] smoke tests passed
```

Both boots report `failed_units=0` and the same `machine_id`. The UKI lost 1.2 MiB net — the five
orphaned modules out, netfs (0.7 MiB) back in.

### A note on resuming into stage 50

Getting there took two attempts, for reasons that have nothing to do with these fixes and are
worth writing down. **Stage 50 is destructive and not idempotent**, so `--from 40` cannot be run
twice over the same target:

- it deletes `/usr/lib/firmware/{intel,amd}-ucode` (50-prune.sh:174), which stage 40 needs for the
  UKI's early cpio — the second stage 40 failed its own microcode assertion, exactly as that
  check's error text predicts;
- it deletes the Portage VDB, so a second stage 50 aborts with `target VDB missing`.

Both guards fired correctly and neither is a bug. Rebuilding from stage 30 is the rigorous answer
and costs ~9 hours; the cheap one, used here, is to restore the two microcode trees from the
binpkgs stage 30 already built (`/cache/binpkgs/sys-firmware/intel-microcode`, and `amd-ucode`
from `sys-kernel/linux-firmware`), let stage 40 re-run its signature prune, then remove them again
and run stages 60 and 70 with `--only`. That reproduces the post-stage-50 target exactly.

## Status

| # | Change | Status |
|---|---|---|
| 1 | `90repart-sysroot` dracut module — order repart after `sysroot.mount` | done |
| 2 | `netfs` removed from `config/dracut-omit-drivers.txt` | done |
| 3 | five orphaned consumers omitted (`rbd`, `chcr`, `rnbd_client`, `rtrs_*`) | done |
| 4 | stage 40: initrd dependency-closure check | done |
| 5 | stage 40: assert the repart drop-in is in the initrd | done |
| 6 | stage 40: discover custom dracut modules instead of hard-coding one | done |
