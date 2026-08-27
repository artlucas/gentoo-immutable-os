# 14 — Replacing Plymouth with a KMS boot splash (2026-08-27)

Plymouth is gone. In its place: the `systemd-stub` `.splash` bitmap covers the firmware-to-kernel
window, and a purpose-built ~800-line static binary drawing straight on DRM covers everything
after the first modeset. The initrd carries no graphics at all any more.

Two problems were the same problem, which is why they are solved together here.

**The splash did not work.** In QEMU (`scripts/run-vm.sh`, `-vga none -device virtio-gpu`) the
graphical portion of boot was a black screen, and pressing ESC alternated between black and the
console instead of showing a details view.

**Plymouth was the most expensive thing in the boot artifact.** It is the *only* reason the
initrd contained a GPU driver: dracut's `45plymouth` module depends on its `drm` module, which
pulls the DRM module tree and — because dracut follows `MODULE_FIRMWARE` — every firmware blob
those drivers declare. [plan/11](11-kernel-boot-audit.md) finding 4 then spent a further
**+71.5 MiB** adding `nvidia`/`nvidia-modeset`/`nvidia-drm` and their 98 MiB of GSP firmware,
purely so plymouthd would find a DRM device before the root pivot. The measured UKI was
**168.7 MiB** on a 1 GiB ESP that has to hold two of them.

None of that was ever needed to boot. The initrd mounts exactly two filesystems — the erofs root
and the ext4 `/var` — both on a local GPT disk.

## The constraint that shapes everything

Recorded in [plan/08](08-roadmap.md) and verified again against the shipped 6.18.43 config:
`gentoo-kernel-bin` has `DRM_SIMPLEDRM`, `DRM_EFIDRM`, `DRM_VESADRM` and `SYSFB_SIMPLEFB` all
unset, **and `CONFIG_FB_DEVICE` unset too**.

So there is no firmware-framebuffer DRM device, and there is no `/dev/fb0` at all. Every
fbdev-era splash — fbsplash, splashutils, writing raw pixels to `/dev/fb0`, and Plymouth's own
`frame-buffer.so` fallback — is impossible on this kernel, not merely unfashionable. After the
kernel starts, KMS ioctls on a real driver's card node are the only way to put a pixel on the
screen.

`CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` **is** set, and that is the other half of the
design: with `quiet`, nothing paints the console, so the screen keeps showing whatever was last
scanned out.

## What the boot looks like now

```
firmware ─┬─ systemd-stub blits the .splash bitmap (centred, 1:1, on black)
          │
kernel ───┤   the initrd loads no DRM driver, and `quiet` means no console output,
initrd ───┤   so nothing modesets and nothing takes the framebuffer:
          │   THE STUB IMAGE STAYS ON SCREEN FOR THE WHOLE INITRD
switch-root
          │
          │  udev autoloads amdgpu/i915/xe/nvidia/virtio_gpu → first modeset
          ├─ 70-<id>-splash.rules starts <id>-splash.service → the KMS splash paints
          │   the same still image at the same brightness: no visible hand-off
          │
greeter ──┴─ kwin takes DRM master and modesets; the splash notices its CRTC is no
             longer scanning out its framebuffer and exits, touching nothing
```

The middle band is a genuine improvement that came free: previously the initrd loaded a DRM
driver, so the stub image died at a modeset seconds into the boot and plymouth had to re-draw.
Now nothing modesets until after the pivot.

**It depends on one property of the firmware, and that is worth stating plainly because the
first QEMU test failed on it.** The stub image survives into the kernel only if the framebuffer
the firmware set up still exists after `ExitBootServices`. On a real UEFI machine it does — the
GOP is a linear framebuffer in a PCI BAR and nothing takes it away. Under QEMU with a bare
`-device virtio-gpu` it does **not**: OVMF drives that through VirtioGpuDxe, whose framebuffer
is a host-side virtio resource released at handover, so the image dies the instant the kernel
starts and, with no simpledrm, nothing can draw again until the first modeset.

Measured with QMP screendumps every 0.4 s:

| QEMU display | stub image visible | black | KMS splash |
|---|---|---|---|
| `-vga none -device virtio-gpu` | 1.2 – 2.0 s | **6.9 s** | 8.9 s |
| `-vga std` | 1.2 – 7.7 s | 0.4 s | 8.1 s |
| `-vga none -device virtio-vga` | 1.2 – 8.5 s | **none** | 8.9 s |

`scripts/run-vm.sh` therefore uses **virtio-VGA** — the same virtio-gpu device with a
VGA-compatible framebuffer in a BAR, so it is still one head and the guest still binds
`virtio_gpu`. That is not a workaround for the test rig: it makes the guest behave like the
UEFI machines this image targets, and the bare virtio-gpu case is the unrepresentative one.

Firmware whose framebuffer genuinely does not persist is the one case this design cannot cover,
and closing it needs `DRM_SIMPLEDRM` — see "Open / not verified".

## The design

### 1. Drop DRM master immediately after painting

`config/splash/splash.c` enumerates `/dev/dri/card*`, and for every connected connector takes
its preferred mode, allocates a dumb buffer, fills it with `#0a0d11`, `memcpy`s the sprite rows
in, and modesets. Then — the one structural decision worth reading — it calls
`DRM_IOCTL_DROP_MASTER`.

A modeset survives the loss of master, and the buffer survives as long as the fd is open. So the
image stays on screen, but the compositor can become master whenever it likes: **no ordering, no
`Conflicts=`, no drop-in on the display manager, no handshake of any kind.**

That deletes a whole problem class rather than solving it again. plan/08 open question 6 and
plan/11 finding 7 were both about sequencing a splash teardown against the greeter, and both
found the obvious answer to be either a race or a deadlock:

- `Conflicts=` on the display manager races PLM's own vendor `After=plymouth-quit.service`;
- ordering PLM after `plymouth-quit-wait` while PLM is the only thing that quits plymouthd
  deadlocks the two units.

plan/11 settled it with a drop-in replacing `plymouth-quit.service`'s `ExecStart` with
`plymouth quit --retain-splash`. That worked, but it was still four coupled units. There are now
none: nothing in the image mentions the splash except the splash's own unit and udev rule.

The teardown is correspondingly just `close(2)`. DRM frees a client's framebuffers and dumb
buffers when its fd closes, and calls the driver's `lastclose` — which restores the fbdev console
mode — if it was the last client. Greeter took over: close, change nothing. ESC or SIGTERM:
close, and fbcon comes back.

### 2. How it knows when to stop

A 500 ms tick reads each CRTC's current `fb_id` (`DRM_IOCTL_MODE_GETCRTC`, a read-only ioctl that
works fine without master). When it is no longer ours, someone else has modeset, and the program
exits.

There is also a 120-second backstop, because a splash that outlives a boot which never reaches a
greeter is a machine with no visible way to find out why. ESC is the real answer to that; the
timer is for the case where nobody is watching.

### 3. Assets: pre-composited opaque tiles, no decoding at runtime

`config/branding/make-splash-assets.py` replaces `make-stub-bmp.py` and emits **both** shipped
artefacts from one `compose_block()`:

| artefact | ships in | covers |
|---|---|---|
| `/usr/share/<id>/splash.bin` | root EROFS | first modeset → greeter |
| `splash-<ver>.bmp` | the UKI's `.splash` PE section | firmware → first modeset |

One script and one layout function on purpose: the two halves meet on screen at the first
modeset, so any drift between them shows up exactly there, as a jump.

The container holds tiles as **opaque BGRX rows, already composited over `#0a0d11` in Python**.
The C program fills the screen with the identical colour and `memcpy`s rows — no alpha blending,
no image decoding, no libpng, and the antialiased edges land pixel-exact because they were
composited over the colour they are drawn onto. Three tiles per scale: the centred
logomark+wordmark block, and the two status fields at `PAD_X`/`PAD_Y` from their corners.

Tiles are emitted at **discrete scales 1 and 2**, downsampled with Pillow from the same 4×
`rsvg-convert` output the stub bitmap uses. splash.c picks 2 for panels ≥ 2000 px tall and 1
otherwise, with a documented fallback if a scale is missing. Unlike `SPLASH_STUB_SCALE` — which
exists because `systemd-stub` runs before `ExitBootServices` and has no resolution to ask about —
the KMS half reads the mode off the CRTC, so it needs no build-time knob.

**`make-stub-bmp.py`'s `DIM = 0.20` is gone.** It existed only because Plymouth's pulse animation
rested at the faded end of its curve and the stub frame had to match. With no animation there is
nothing for a dim frame to be consistent with, and two static images of different brightness
meeting at the modeset would read as a flash. `reshade_slab()` stays: it is about the three faces
of the logomark reading correctly in a *still* frame, which is still true — and is now true of
both outputs.

### 4. Starting it early

`config/rootfs/usr/lib/udev/rules.d/70-distro-splash.rules.in`:

```
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="@DISTRO_ID@-splash.service"
```

Event-driven off the DRM device appearing, which is the earliest reachable moment and needs no
`systemd-udev-settle`. Repeat triggers on a multi-GPU machine are no-ops while the unit is
active; the program enumerates every card itself. Render nodes are excluded — they cannot
modeset.

`ACTION=="add"` only, deliberately not `add|change`: a card emits `change` on every connector
hotplug, so `|change` made each monitor plugged into a running desktop a fresh start request for
a unit that had long since exited — a boot splash over somebody's session. Cards are added once
and udev replays `add` at coldplug, so nothing is missed. The program is safe against a spurious
late start anyway, and by construction rather than luck: it takes DRM master before it draws, a
running compositor already holds it, so the attempt fails and it exits without touching the
screen. The rule narrows the window; the master acquisition closes it.

`SPLASH_BACKEND` keeps four values, `plymouth` renamed to `kms` and the default moved to `both`:

| value | `.splash` PE section | `<id>.splash=0` cmdline token |
|---|---|---|
| `both` (default) | yes | no |
| `stub` | yes | yes |
| `kms` | no | no |
| `none` | no | yes |

Nothing else changes with it — the binary, its assets, the unit and the rule are installed in all
four modes, and `ConditionKernelCommandLine=!<id>.splash=0` on the unit is the whole switch. That
preserves the property `build.conf` already advertised: **switching backends is a rerun of stages
40–60, not a rebuild.**

`validate_config()` deliberately **rejects** the old value `plymouth` rather than aliasing it to
`kms`. It is exactly the value a stale `build.conf` still carries, and silently reinterpreting it
would build an image whose splash is not the one the config asked for.

### 5. ESC → details

The program polls every `/dev/input/event*` that advertises `EV_KEY`, rescanning on each tick for
devices udev creates after it starts. Reading evdev rather than the VT is deliberate: owning a VT
means `KDSETMODE`/`KDSKBMODE` and the `VT_PROCESS` switch protocol — which is both the machinery
Plymouth used and the machinery that was visibly misbehaving — and reading `/dev/tty0` directly
would contend with getty for the terminal.

On `KEY_ESC`: raise the console loglevel (`SYSLOG_ACTION_CONSOLE_LEVEL`, undoing `quiet`), close
the DRM fds so `lastclose` restores the fbdev console, then replay the kernel ring buffer to
`/dev/tty0` with the `<N>` priority prefixes stripped. One-way, by choice: a boot that has gone
wrong enough for someone to press ESC is not improved by being able to hide the evidence again,
and toggling is what was flickering before.

**Known limitation, stated rather than left to be rediscovered:** this reveals *kernel* messages,
not systemd's status output. The cmdline ends `console=tty0 console=ttyS0`, and the last
`console=` is what `/dev/console` resolves to for userspace writes, so systemd's status lines go
to the serial port. Reordering the two would move them to the screen — and would break stage 70,
which reads that serial log to decide whether the image booted.

### 6. Why a static binary, compiled in the builder

Stage 30 emerges with `ROOT="$TARGET"` and never chroots, so the image's own toolchain cannot be
invoked; stage 50 deletes the compiler anyway (plan/06). `-static` removes the question: the
binary has no ABI relationship with the image's libraries, which is also what makes it immune to
the library pruning stage 50 performs *after* it is installed. It uses only raw syscall wrappers
— no NSS, no `dlopen` — which are the usual reasons to distrust static glibc. It also means no
libdrm: the ioctls are the kernel uapi in `<drm/drm_mode.h>`, used directly.

Stage 40 asserts the result has **no `PT_INTERP` segment**, rather than grepping `file(1)` for
"statically linked". `PT_INTERP` is the thing that actually makes the kernel look for a dynamic
loader, so its absence *is* the property being asserted. This is the most important assertion in
the block: a dynamic build works perfectly at build time and then stops working one stage later,
in a different image, as a splash that silently never draws.

This is the repo's first compiled artifact — everything else is shell, Python or config.

## Initrd: `--omit drm`

```diff
-  --add "systemd etc-overlay systemd-repart repart-sysroot plymouth" \
-  --install "${PLYMOUTH_LIBS[*]}" \
-  --omit "network network-legacy nfs ... resume" \
-  --add-drivers "nvidia nvidia_modeset nvidia_drm" \
+  --add "systemd etc-overlay systemd-repart repart-sysroot" \
+  --omit "drm simpledrm plymouth network network-legacy nfs ... resume" \
```

**Both entries are omissions rather than absences, and `plymouth`'s is not defensive — it is
required.** dracut assembles a default module set from every module whose `check()` passes, and
`45plymouth`'s passes on the mere presence of `plymouth-populate-initrd` and the two binaries in
the sysroot (`45plymouth/module-setup.sh:38`). Dropping it from `--add` therefore achieves
nothing at all while the package is installed: dracut picks it up by itself, it declares
`depends() { echo drm; }`, and the run dies with

```
dracut[E]: Module 'plymouth' depends on module 'drm', which can't be installed
```

which is exactly what the first build of this change did. Once the package is gone `check()`
fails and the module is skipped, so the entry becomes belt-and-braces — worth keeping for the day
something reintroduces plymouth as somebody else's dependency.

`drm` earns its omission the same way: it is a module *other* modules can pull in, so leaving it
to chance is how the GPU tree comes back — silently, as a UKI that grew 110 MiB for no reason
anyone notices.

Stage 40 asserts, over the `lsinitrd` listing, that **no `drivers/gpu/` module and no `nvidia*`
module** is present, and separately that **no NVIDIA GSP firmware** is, since dracut follows
`MODULE_FIRMWARE` and the firmware half could regress on its own. That is the direct analogue of
the omit-pattern leak check plan/11 finding 3 added, and it turns a future regression into a
failed build.

Two cmdline tokens went with plymouth: `splash`, which only ever meant "plymouth graphical
mode", and `plymouth.ignore-serial-consoles`, which existed because plymouthd would otherwise
claim `ttyS0` as a text display and mirror systemd status into the log stage 70 scans.
`<id>-splash` never opens a serial port.

`nvidia-drm.modeset=1` and `usr/lib/modprobe.d/10-nvidia-drm.conf` both **stay**. Their scope has
narrowed to the booted system, not their importance: `nvidia-modeset` and `nvidia-drm` still have
no modalias, so without the softdep nothing loads them and neither the splash nor kwin gets a DRM
device.

## Console-only images

Stage 40 removes the unit and the udev rule on `--console-only`, the same way it used to remove
the retain-splash drop-in, and for a sharper reason. There, agetty is the next thing to touch the
screen — and because this program holds a framebuffer on the CRTC, fbcon would render the login
prompt into a buffer nobody is scanning out. The failure is not "text behind a logo", it is an
invisible console.

## Measured

Stage 40 run against the 0.3.0 target, before and after, on the same machine and the same
kernel — so this is a like-for-like rebuild of the boot artifact and nothing else.

| | before | after | Δ |
|---|---|---|---|
| **UKI** (`immos_0.3.0.efi`) | **169.6 MiB** | **59.9 MiB** | **−109.8 MiB, −65%** |
| main initrd | 147.9 MiB | 38.1 MiB | −109.7 MiB, −74% |
| modules in the initrd | 735 | 673 | −62 |
| `drivers/gpu` + `nvidia*` modules in the initrd | many | **0** | asserted by stage 40 |
| NVIDIA GSP firmware in the initrd | 98 MiB | **0** | asserted by stage 40 |
| splash binary on the root EROFS | — | 676 KiB | static, stripped |
| `splash.bin` on the root EROFS | — | 845 KiB | scales 1 and 2 |

Two UKIs on the 1 GiB ESP is now **120 MiB, 8.6× headroom** — up from 3.0×, and better than the
7.5× the ESP was originally sized for before any splash existed. `ESP_SIZE_MIB` does not move.

The initrd and the UKI fell by the same 110 MiB, which is the whole story in one line: every byte
removed was graphics, and the initrd is where all of it was. Note that only 62 *modules* left —
the bulk is firmware those modules declared through `MODULE_FIRMWARE` and dracut pulled in behind
them. The image pays about 1.5 MiB on the root filesystem for the replacement.

Verified in the produced initrd: zero matches for `drivers/gpu/`, `nvidia`, `firmware/nvidia/` or
`gsp_*.bin`; `erofs.ko`, `overlay.ko`, both microcode blobs and the repart drop-in all still
present; the dependency closure complete for all 673 modules; and no file mentioning plymouth
(the single `lsinitrd` hit is dracut's own record of the `--omit` argument).

## Verification

Offline (`./tests/run-tests.sh`): `tests/test-splash-assets.sh` replaces
`test-branding-assets.sh`. It checks that the generator and the SVG sources still name each
other, that `BRANDING_ZOOM` matches the generator's `ASSET_ZOOM`, that the templates render, that
the sprite container parses **the way `splash.c` parses it** (magic, background, per-tile bounds,
all three anchors, both scales), that the stub BMP has the 40-byte `BITMAPINFOHEADER`
`systemd-stub`'s parser accepts rather than the BITMAPV4 header Pillow writes for RGBA — and that
the `<id>.splash=0` token is spelled identically in the unit, the udev rule and stage 40, which
is the drift that would fail in the silent direction.

Nothing here can see the actual screen; stage 70 reads a serial port, so a black screen and a
perfect splash are indistinguishable to it. **It needs an eyeball in QEMU** (`scripts/run-vm.sh`):
the stub image before the kernel, the image persisting through the initrd, the KMS splash
appearing at the modeset with no jump, the greeter painting over it, and ESC revealing the log
once and staying text.

## Verified in QEMU

Booted from the assembled image with QMP screendumps every 0.4 s (`-vga none -device
virtio-vga`, the harness in `scripts/run-vm.sh`):

```
1.2 s   systemd-stub blits the .splash bitmap
1.2 – 8.5 s   it stays on screen, through the kernel and the whole initrd
8.9 s   the KMS splash takes over — no black frame at the hand-off
12.6 s  kwin modesets for the greeter
13.8 s  the greeter paints
```

The one residual black frame is **12.6 → 13.8 s, between the splash and the greeter**, and it is
not ours: the splash still owns a lit framebuffer at 12.6 s, and what blanks it is kwin
modesetting to its own buffer before it has painted anything into it. Nothing on this side can
prevent that — dropping master is what lets kwin modeset whenever it likes, which is the design
— and it is the same ~1 s plymouth's `--retain-splash` could not close either. Reducing it is a
compositor-startup question, not a splash one.

## Open / not verified

- **Real hardware of any kind.** Everything above is QEMU. The firmware-framebuffer property the
  stub half depends on is the thing to confirm first.
- **Real NVIDIA hardware.** Same status as plan/11 finding 4, which was never confirmed on
  hardware either.
- **Panels above 1080p**, i.e. the scale-2 sprite path. The chooser is exercised by the offline
  suite; the appearance is not.
- **Multi-monitor.** The program paints every connected output and takes one CRTC per connector;
  untested with more than one head attached.
- **`SPLASH_STUB_SCALE` remains a build-time guess** for the stub half. Unchanged by this work —
  it is a property of `systemd-stub`, not of anything here.
