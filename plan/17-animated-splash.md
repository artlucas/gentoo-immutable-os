# 17 — The mark moves: an animated splash on both sides of the login (2026-09-01)

The brand mark has been on screen since [plan/14](14-boot-splash-kms.md) and it has been a still
picture the whole way. This adds the design system's **layer pulse** to it — one slab dimming and
recovering at a time, the wave travelling up the stack — and extends the same drawing past the
greeter into a **Plasma splash screen**, so the window between the login and a painted desktop
stops being Breeze's logo on black.

Three things are true of the result and each of them decided a piece of the design:

- **The animation departs from the still frame rather than resting below it.** Every slab is at
  full brightness at t = 0, so "everything at full" is a real frame of the loop and not merely
  the brightest one.
- **Nothing coordinates with anything.** The KMS splash still drops DRM master immediately and
  the Plasma splash still ends by being killed; neither gained a handshake.
- **One layout function still composes every artefact.** The stub bitmap, the sprite tiles, the
  installer's sidebar logo and the Plasma theme's vectors all come out of `build_block()`.

## What the user sees now

```
firmware ─┬─ systemd-stub blits the .splash bitmap: mark at full brightness
          │
kernel ───┤   nothing modesets, so THE STILL IMAGE HOLDS THROUGH THE INITRD
initrd ───┤
switch-root
          │
          ├─ <id>-splash paints frame zero — THE SAME PICTURE, byte for byte — modesets,
          │   drops master, and only then starts the pulse
greeter ──┤  kwin modesets; the splash notices and exits, touching nothing
          │
login ────┤  ksplashqml paints #0a0d11 and fades the same mark in, running the same pulse
          │
desktop ──┴─ kwin's `login` effect fades the splash window out over 500ms
```

## 1. Why the boot splash can animate at all

This is the whole engineering content of the change, and it is a constraint rather than a
technique.

`paint_card()` calls `DRM_IOCTL_DROP_MASTER` the moment it has drawn — plan/14's one structural
decision, and the thing that deleted the entire class of "sequence the splash teardown against
the greeter" problems. **Every ioctl that would present a new frame is `DRM_MASTER`-gated.**
Verified in the shipped kernel's own source, `drivers/gpu/drm/drm_ioctl.c` at 6.18:

```c
DRM_IOCTL_DEF(DRM_IOCTL_MODE_DIRTYFB, drm_mode_dirtyfb_ioctl, DRM_MASTER),
```

and the same for `SETCRTC`, `PAGE_FLIP` and `ATOMIC`. So a splash without master cannot flip,
cannot commit, and cannot ask a driver to flush.

**Taking master back for one ioctl per frame was considered and rejected outright.** kwin does
not call `drmSetMaster()` itself; it receives the DRM fd from logind, and logind's
`session_device_start()` calls `drmSetMaster()` on that fd and **returns the failure to its
caller**. A splash holding master for even the microsecond a `DIRTYFB` takes, at the wrong
moment, is a session that does not start. That is not a risk worth a moving logo.

What is left is the one thing that needs no permission: **storing into the dumb buffer the CRTC
is already scanning out.** `show_on_crtc()` therefore keeps its `mmap` instead of dropping it
after the first frame, and `animate()` re-blits the slabs that have moved.

### Where that works, and where it honestly does not

| driver | dumb buffer is | the mark |
|---|---|---|
| amdgpu, i915, xe, nvidia-drm | the scanned-out memory, mapped write-combining | **animates** |
| bochs (`qemu -vga std`) | the VRAM BAR the host reads continuously | **animates** |
| virtio_gpu, qxl, vmwgfx, udl | a shadow the host re-reads only on a plane update | holds frame zero |

The second row is why `scripts/run-vm.sh` grew `--gpu bochs`. The default stays virtio-VGA,
because the property it was chosen for — the firmware framebuffer surviving `ExitBootServices`,
i.e. the stub image lasting through the initrd — is what stage 70 and every boot-flow measurement
in plan/14 depend on. `--gpu bochs` exists to *look at* the animation, not to test the boot.

**The degraded case is the old splash exactly.** Frame zero is painted with every slab at full,
before the modeset that flushes it, so a VM on a shadow-buffer driver shows the still image this
program drew before it could animate at all — not a mark stopped mid-dip. The offline suite pins
that: it compiles `splash.c`, blits the real container into memory and requires the result to
equal `build_block()`'s composition byte for byte.

## 2. Dimming a slab without an alpha channel

plan/14's container ships **opaque BGRX rows, already composited over `#0a0d11` in Python**, and
that was sold as "no alpha blending, no image decoding". Animating it appeared to need the alpha
back. It does not, and the reason is one line of algebra.

A shipped tile is `T = A·S + (1−A)·BG` for slab colour `S` and antialiased coverage `A`. Drawing
that slab at opacity `k` is

```
k·A·S + (1 − k·A)·BG  ==  BG + k·(T − BG)
```

— a plain lerp between the tile and the background, with no coverage term anywhere. `dim_px()` is
three integer lerps on a packed word, `k` runs 0…256, and `k == 256` is a `memcpy` of the very
bytes the static splash blitted. The container stays opaque and the program stays free of any
per-pixel alpha.

## 3. Cutting the block into slabs

The lerp needs the slabs addressable one at a time, so the centred block is no longer one tile.
The logomark's box is cut into three horizontal bands on the fixed lines in `BAND_EDGES` (the
midpoints of the 1-unit gaps the mark is drawn with), each band a crop of the very canvas the
stub bitmap and the installer logo are made of.

Two things keep that honest:

- **Each slab must land inside its own band.** Asserted in the generator against the measured ink
  bounds, at every sprite scale, with a documented alpha threshold — LANCZOS ringing from the 4×
  rasterisation leaves alpha 3–4 either side of every hard edge, which would fail a naive
  `alpha > 0` test on geometry that is correct.
- **The pieces must reassemble into the flat block exactly.** Which is why the container format
  changed rather than being reused.

### The format change, and why the magic was bumped

`IMSPLSH1` → `IMSPLSH2`. Records grew from 28 to 40 bytes: a `flags` word carrying `TILE_PULSE`
and the slab's slot in the wave, a `box_w`/`box_h` pair, and `off_x`/`off_y` became signed.

The box is the part worth explaining. **A tile is placed by anchoring its box and then offsetting
the tile inside it.** For a whole picture the box is the tile; for the four pieces of the block,
the box is the block. That indirection is not decoration — centring a 130 px slab band and
centring the 144 px block it belongs to round differently, and the difference is a pixel of
jitter between the stub bitmap and the frame that replaces it, at exactly the hand-off plan/14
went to trouble to make invisible.

The magic is bumped rather than reused because a v1 reader would draw all four pieces of the block
centred on top of one another and call it a splash.

The container got **smaller**: 845 KiB → 710 KiB, because the block's empty gap region is no
longer stored.

## 4. The curve

```
level_i(t) = 1 − DEPTH · smoothstep(triangle(u_i)),  u_i = 3·frac(t/CYCLE − i/3) clamped to its
                                                            own third, else level = 1
```

`CYCLE = 1600 ms`, `DEPTH = 0.55`, three slots, slot 0 (the **bottom** slab) leading so the wave
travels up the stack. A triangle run through smoothstep rather than a sine, which keeps `splash.c`
free of libm: smoothstep's derivative is zero at both ends, so the joins at the start, the middle
and the end of each slab's window are all smooth despite the triangle's corner.

Two properties matter more than the shape:

- **`level(0) = 1` for every slot.** That is what makes frame zero the still image.
- **Exactly one slab is dipping at any moment**, since each window is its own third of the cycle.

The three constants live in `make-splash-assets.py`, which writes them into the theme's generated
`Design.qml`; `splash.c` restates them as `#define`s and `tests/test-splash-assets.sh` asserts the
two agree. A drift there is two brand animations at two speeds on either side of one login, and
nothing else would notice.

## 5. The Plasma splash

A Plasma/LookAndFeel package at `/usr/share/plasma/look-and-feel/<id>/` carrying one thing, the
splash, because that is the unit Plasma packages a splash in: `ksplashqml` resolves `ksplashrc`'s
`[KSplash] Theme` as a package id and loads `contents/splash/Splash.qml` out of it.

### It ships vectors, and that is the one place the two splashes differ in kind

`splash.c` runs before there is a font, an image decoder or a toolkit, so it gets pre-composited
pixels at two discrete scales. `ksplashqml` runs inside a Qt session that already has QtSvg, so it
gets outlines and stays crisp at any panel size and any scale factor without the container
carrying a tile for each one.

That means the slab shading is applied twice, by two functions, and they have to agree.
`reshade_slab()` rewrites pixels through an alpha LUT; `reshade_svg()` rewrites each polygon's
`opacity` into a shaded `fill`. They agree by construction — `rsvg` gives a polygon with fill *F*
at opacity *p* an alpha of `coverage · p`, so the LUT's `alpha / face` is the same coverage the
flat-fill polygon renders with — provided the **colours** match, which the offline suite checks
face for face with no rasteriser and no tolerance.

`Design.qml` is generated from the same constants, so the QML restates neither the geometry nor
the timings. A theme that hardcoded `132` and `34` would go on rendering perfectly after the
design changed — just not the same picture as the boot splash it takes over from.

### Every user, from one file

`/etc/xdg/ksplashrc`, and nothing else. KConfig cascades `$XDG_CONFIG_DIRS` underneath
`~/.config`, so it is the image's default for anyone who has not chosen otherwise, and System
Settings still writes a user's own choice to `~/.config/ksplashrc` and wins.

| account | how it gets the splash |
|---|---|
| the live user on the product image | reads the file off the read-only root |
| the live user on the installer medium | same file, same root |
| an account Calamares creates | the installed system **is** the desktop profile's root EROFS written to disk, so the file is there before the account exists |

No skel copy, no first-login hook, no Calamares job. The overlay-backed `/etc` that
[plan/16](16-installer.md) leans on is not even needed here — the file is on the read-only root
and nothing has to write it.

**`Theme`, not `LookAndFeelPackage`**, and that choice is what keeps the installer medium working.
`ksplashqml`'s resolution order is: command line (the systemd unit passes none), then
`ksplashrc`'s `Theme`, then `kdeglobals`' `LookAndFeelPackage`, then Breeze. The installer profile
sets `LookAndFeelPackage=<id>-installer` for its task-manager layout script; `Theme` wins over it,
so the live session gets our splash *and* its own panel, out of two small packages. Merging them
would ship the installer's layout script to every installed machine.

### The fade in is ours; the fade out cannot be

`stage` is written by `SplashWindow::setStage`. On Wayland stage 2 (`wm`) is set in `SplashApp`'s
constructor, so it arrives as soon as the QML has loaded — which is the moment to start
revealing. The **background is opaque from the first frame** and only the content fades: the
window is a layer-shell overlay, and fading the whole thing in would show a moment of whatever
kwin has underneath.

The test is `stage >= 2`, not Breeze's `stage == 2`. ksplash's own README says stages may be
added, removed or reordered and that a stage can take zero time; an equality test against a
number that moved leaves the splash permanently invisible, which is the one failure here nobody
would notice until a machine booted to a black screen.

**The fade out is not available to the theme at all.** `SplashApp::setStage()`:

```cpp
void SplashApp::setStage(int stage)
{
    m_stage = stage;
    if (m_stage == 6) {
        QGuiApplication::exit(EXIT_SUCCESS);
    }
    for (SplashWindow *w : std::as_const(m_windows)) {
        w->setStage(stage);
    }
}
```

`exit()` is called *before* stage 6 reaches the windows, so the event loop is already unwinding
before any animation the QML started could render a frame.

What actually fades the splash away is kwin's **`login` effect** — `animate(… Effect.Opacity, 1
→ 0 …)` over `animationTime(500)` on `windowClosed`, matched on
`windowClass === "ksplashqml ksplashqml"`. Confirmed against kwin 6.6.6 that this applies to the
layer-shell window ksplashqml actually creates: `WaylandWindow`'s constructor calls
`updateResourceName()`, which sets both resource name and class from the executable's file name,
and `EffectsHandler::setupWindowConnections()` is wired for every window `Workspace` adds.

It is `EnabledByDefault` and this image ships no `kwinrc`, so the default applies. **Stage 40
asserts it** — that the effect is installed and that its metadata still says
`EnabledByDefault: true` — rather than pinning it in config, because losing it breaks nothing: the
splash would snap away instead of fading, on a screen no automated test can see. An assertion
turns that into a failed build and a decision, which is the outcome worth having.

## 6. Cost

| | before | after |
|---|---|---|
| `splash.bin` | 845 KiB | **710 KiB** |
| `<id>-splash` binary | 676 KiB | 676 KiB (stripped; no libm, no new dependency) |
| the Plasma theme on the root | — | ~20 KiB (four SVGs, `Design.qml`, a 300×169 preview) |
| per animated frame | — | one lerp over ~17k px (scale 1) or ~68k (scale 2), for the **one** slab that moved |

`animate()` skips a tile whose level equals what it was last drawn at, so a slab between pulses
costs a comparison, and most frames repaint exactly one band. The poll loop wakes at 25 fps for
the animation while the takeover check and the input rescan stay on their original 500 ms tick —
running a `GETCRTC` per output at frame rate would be twenty-five times the ioctls to learn the
same thing.

## Verification

Offline (`./tests/run-tests.sh`), all in `tests/test-splash-assets.sh`:

- the container parses **the way `splash.c` parses it**, at the v2 record size, with every tile
  inside its own box under whichever meaning its anchor gives the offset;
- exactly one slab per pulse slot per scale — a duplicated slot would animate two slabs together
  and leave a third permanently still;
- the centre tiles, placed back by the container's own box/offset arithmetic, **reassemble into
  `build_block()` byte for byte** at both scales;
- `splash.c` compiles, and its own blitter run against the real container produces a 1920×1080
  frame identical to the composed reference — the block *and* both status fields at their anchors;
- the theme's slab colours are `reshade_slab()`'s, face for face, and no polygon kept an
  `opacity` that would multiply against the QML's animation;
- the pulse constants, the container magic, the record size and `MAX_TILES` all agree between the
  generator and `splash.c`;
- the package id, `ksplashrc`'s `Theme` and stage 40's assertion are one string;
- the QML binds three different pulse slots and reveals on `stage >= 2`;
- stage 40 guards the whole thing on the `desktop` set and asserts kwin's `login` effect.

**None of that can see a screen.** The Plasma half was developed against a real `qml6` render at
1920×1080 with frames captured offscreen — the fade-in, the wave order (bottom → middle → top) and
the dip depth were all read off those frames, and the settled frame compared against the stub
bitmap's block — but that is a development check on a workstation, not a gate in the suite.

## Open / not verified

- **The boot splash animating on real hardware.** The entire "a store into a mapped dumb buffer
  reaches the panel" argument is from the drivers' design, not from a machine. It is the first
  thing to confirm, and it fails safe: the mark holds its full-brightness first frame.
- **The boot splash animating in QEMU.** `--gpu bochs` is the intended way to look at it and has
  not been run against a built image.
- **The Plasma splash inside a real session.** Everything above is `qml6` on a workstation, not
  `ksplashqml` under kwin. The theme resolution path, the layer-shell window and kwin's `login`
  effect are all read out of the pinned 6.6.6 sources rather than observed.
- **kwin's fade-out timing against a slow first boot.** The splash is killed at the `desktop`
  stage regardless; how much of the 500 ms fade is visible over a desktop still painting itself
  is a compositor-startup question, the same one plan/14 left open for the greeter.
- **Multi-monitor.** `animate()` walks every output the splash painted, but plan/14's untested
  multi-head case is untested here too — and now there is a second thing to get wrong on it.
