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
- **The KMS splash now holds DRM master, and one unit ordering gives it back.** That is the
  reversal in this plan, and section 1 is about why it was forced and what makes it safe.
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
          │   KEEPS DRM MASTER, and pulses, presenting each frame with DIRTYFB
          │
          ├─ <id>-splash-release, ordered Before= the display manager: the mark settles at
          │   full brightness and master goes back. The picture does not move or go away.
          │
greeter ──┤  kwin takes the DRM device from logind and modesets; the splash notices and exits
          │
login ────┤  ksplashqml paints #0a0d11 and fades the same mark in, running the same pulse
          │
desktop ──┴─ kwin's `login` effect fades the splash window out over 500ms
```

## 1. Why the boot splash can animate at all

This is the whole engineering content of the change, and it is a constraint rather than a
technique.

`paint_card()` used to call `DRM_IOCTL_DROP_MASTER` the moment it had drawn — plan/14's one
structural decision, and the thing that deleted the entire class of "sequence the splash teardown
against the greeter" problems. **Every ioctl that would present a new frame is `DRM_MASTER`-gated.**
Verified in the shipped kernel's own source, `drivers/gpu/drm/drm_ioctl.c` at 6.18:

```c
DRM_IOCTL_DEF(DRM_IOCTL_MODE_DIRTYFB, drm_mode_dirtyfb_ioctl, DRM_MASTER),
```

and the same for `SETCRTC`, `PAGE_FLIP` and `ATOMIC`. So a splash without master cannot flip,
cannot commit, and cannot ask a driver to flush.

### The attempt that did not survive contact with the kernel

The first version of this plan kept plan/14's decision and animated by **storing into the dumb
buffer the CRTC is already scanning out** — the one thing that needs no permission. It shipped,
and on the intended demonstration path it did nothing at all.

The claim it rested on was that `bochs` (`qemu -vga std`) scans out of the VRAM BAR, so a store
lands in memory the host re-reads continuously. That was true of the driver that used the VRAM
GEM helper. It is not true of the driver in the kernel this image pins. From `bochs.ko` on
6.18.43, as shipped:

```
depends: drm_client_lib,drm_kms_helper,drm_shmem_helper
U drm_gem_shmem_dumb_create      U drm_gem_begin_shadow_fb_access
U drm_gem_fb_create_with_dirty   U drm_fb_memcpy
U drm_atomic_helper_damage_iter_init
```

Dumb buffers are ordinary shmem pages and the driver memcpys the damaged rectangles into the BAR
**on commit**. bochs is a shadow-buffer driver now, exactly like `virtio_gpu`, `qxl`, `vmwgfx`
and `udl`, and every QEMU display is one. A masterless splash gets one frame everywhere except
on a real GPU — where the claim does hold, and where nobody can watch it during development.

### What the design is now

The splash **holds master from its modeset until something tells it to let go**, presents each
frame with `DRM_IOCTL_MODE_DIRTYFB` (one clip rect per slab that moved), and hands master back
before the greeter can want it. Both `bochs` and `virtio_gpu` implement the dirty callback —
`virtio-gpu.ko` links `drm_atomic_helper_dirtyfb` and `drm_plane_enable_fb_damage_clips` — so
the default `run-vm.sh` VM animates, and `--gpu bochs` was removed again along with the claim
that produced it.

### What makes holding master safe

kwin does not call `drmSetMaster()` itself; it receives the DRM fd from logind, and logind's
`session_device_start()` calls `drmSetMaster()` on that fd and **returns the failure to its
caller**. A splash still holding master when the greeter starts is a session that never starts.
So the release is not best-effort, and it is not one mechanism:

- **`<id>-splash-release.service`** is `Before=display-manager.service` and `WantedBy=`
  `graphical.target`. systemd will not start the DM until it has run. It writes
  `/run/<id>-splash.release` and then sends `SIGUSR1`; the splash settles the mark at full
  brightness, presents that, drops master, and **stays exactly where it is** — the modeset
  stands and the fd keeps the buffer alive, so the hand-off the greeter sees is the same
  seamless one plan/14 designed.
- **The flag file, written before the signal**, covers a splash that has not started yet. udev
  starts it on a card appearing and nothing forbids that from landing late; a signal cannot
  reach a process that does not exist. `splash.c` reads the flag before it opens a card and
  takes the old path — one still frame, master dropped immediately.
- **`MASTER_HOLD_SECONDS` (30)** releases master anyway if neither of those happens: a profile
  with no display manager, a compositor started by hand, a unit that was not pulled in. The
  failure mode is a mark that stops moving, which is the splash this image had yesterday.

**This is an ordering, not a handshake**, and that distinction is the whole reason it is
acceptable where plan/11 finding 7's plymouth teardown was not. Nothing here waits on the
greeter and the greeter waits on nothing here. The release unit's failures are all ignored (`-`
prefixed `ExecStart=`), because a decoration must never fail a boot.

### Where the animation is presented

| driver | dumb buffer is | presenting |
|---|---|---|
| amdgpu, i915, xe, nvidia-drm | the scanned-out memory, mapped write-combining | the store already landed; `DIRTYFB` may return `-ENOSYS`, ignored |
| bochs (`qemu -vga std`), virtio_gpu, qxl, vmwgfx, udl | shmem pages the driver copies into the scanout | `DIRTYFB` is the copy — this is why master is held |

**The degraded case is the old splash exactly.** Frame zero is painted with every slab at full,
and so is the last frame before master goes back, so a splash that never gets to animate shows
the still image this program drew before it could animate at all — not a mark stopped mid-dip.
The offline suite pins that: it compiles `splash.c`, blits the real container into memory and
requires the result to equal `build_block()`'s composition byte for byte.

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

### Every user, from the /etc/xdg layer

`/etc/xdg/kdeglobals` and `/etc/xdg/ksplashrc`, and nothing else. KConfig cascades
`$XDG_CONFIG_DIRS` underneath `~/.config`, so they are the image's defaults for anyone who has
not chosen otherwise, and System Settings still writes a user's own choice to
`~/.config/ksplashrc` and wins over both.

| account | how it gets the splash |
|---|---|
| the live user on the product image | reads the file off the read-only root |
| the live user on the installer medium | same file, same root |
| an account Calamares creates | the installed system **is** the desktop profile's root EROFS written to disk, so the file is there before the account exists |

No skel copy, no first-login hook, no Calamares job. The overlay-backed `/etc` that
[plan/16](16-installer.md) leans on is not even needed here — the file is on the read-only root
and nothing has to write it.

**`LookAndFeelPackage`, not `Theme`** — which is the opposite of what this plan said until
0.3.0, and the correction cost a release. Both images shipped `/etc/xdg/ksplashrc` with
`Theme=<id>`, both booted to Breeze, and nothing anywhere logged a word about it.

`ksplashqml`'s resolution order really is command line (the systemd unit passes none), then
`ksplashrc`'s `[KSplash] Theme`, then `kdeglobals`' `LookAndFeelPackage`, then Breeze. What the
plan missed is **which `ksplashrc`**. Before any of the session starts, `startplasma`'s
`setupPlasmaEnvironment()` (`plasma-workspace/startkde/startplasma.cpp`):

1. **prepends `~/.config/kdedefaults` to `XDG_CONFIG_DIRS`** — so that directory outranks
   `/etc/xdg` for every KConfig read the session makes; and
2. if `~/.config/kdedefaults/package` does not already name the Look-and-Feel package, runs
   `KLookAndFeelManager` in `Defaults` mode over it, which **writes
   `~/.config/kdedefaults/ksplashrc`**: `Theme` from that package's `contents/defaults`
   `[ksplashrc][KSplash] Theme` if it has one, and **otherwise from the package id itself**
   (`libklookandfeel/klookandfeelmanager.cpp`, `save()`).

So on a fresh account the effective `Theme` is the id in `kdeglobals`, written into a file that
beats `/etc/xdg`, before `ksplashqml` is ever started. Measured on the medium as built:

```
$ cat ~/.config/kdedefaults/ksplashrc          $ XDG_CONFIG_DIRS=$HOME/.config/kdedefaults:/etc/xdg \
[KSplash]                                        kreadconfig6 --file ksplashrc --group KSplash --key Theme
Engine=KSplashQML                              immos-installer
Theme=immos-installer
```

`<id>-installer` had no `contents/splash`, so `ksplashqml` resolved it, found nothing and fell
back to Breeze — `splashwindow.cpp` does that on any load failure with a single `qCWarning` on a
category that is off by default. On the product image, which shipped no `kdeglobals` at all, the
built-in default `org.kde.breeze.desktop` produced the same result by the same route.

**One package per image, therefore.** `kdeglobals` can name exactly one, so the installer
medium's task-manager layout script ([plan/16](16-installer.md)) goes *into* the splash package,
added by stage 40 for that profile only, rather than into a second package that `kdeglobals`
would have to name instead. The product's copy has no `contents/layouts` and the layout resolves
to Breeze's, so nothing of the installer's reaches an installed machine — which was the whole
point of splitting them in the first place, achieved without the split.

Two things follow that are worth stating because neither is obvious:

- **Do not give the package a `contents/defaults`.** `KLookAndFeelManager` reads that file
  through the same fallback chain, so shipping one *replaces* Breeze's wholesale instead of
  overriding a key in it, and `ColorScheme`, `widgetStyle`, `Icons` and the cursor theme would
  stop being written for every fresh account.
- **`/etc/xdg/ksplashrc` stays**, and is still asserted, but it is no longer load-bearing: it
  covers `ksplashqml` run by hand, the X11 path (`setupKSplash()` reads `ksplashrc` itself and
  passes the theme on the command line), the Splash Screen KCM before a session has written
  `kdedefaults`, and `Engine`, which three separate code paths check before anything is drawn.

Stage 40 asserts all three spellings of the id — `kdeglobals`, `ksplashrc` and the package's own
`metadata.json` — because a disagreement between any two of them is silent at runtime.

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
| per animated frame | — | one lerp over ~17k px (scale 1) or ~68k (scale 2) plus one `DIRTYFB`, for the **one** slab that moved |

`animate()` skips a tile whose level equals what it was last drawn at, so a slab between pulses
costs a comparison, and most frames repaint exactly one band — and hands the kernel exactly one
clip rectangle, which is what keeps the shadow-buffer copy to a band rather than a screen. The
poll loop wakes at 25 fps for the animation while the takeover check and the input rescan stay on
their original 500 ms tick — running a `GETCRTC` per output at frame rate would be twenty-five
times the ioctls to learn the same thing.

The frames stop when master goes back, which on a normal boot is a second or two before the
greeter. Nothing is drawn or presented after that: the mark is settled at full brightness and
the program is only watching for the takeover, exactly as it did before plan/17.

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
- stage 40 guards the whole thing on the `desktop` set and asserts kwin's `login` effect;
- every link in the master release is checked separately, because the one that breaks silently
  breaks the greeter and not the splash: the release unit is `Before=display-manager.service`,
  it is `WantedBy=graphical.target` and stage 40 makes exactly that symlink, it signals the unit
  the udev rule starts, the flag path in the unit is the `-DSPLASH_RELEASE_FLAG` stage 40
  compiles in, `splash.c` reads that flag before it opens a card and acts on `SIGUSR1`, and
  `MASTER_HOLD_SECONDS` is well short of `SPLASH_MAX_SECONDS`.

**None of that can see a screen.** The Plasma half was developed against a real `qml6` render at
1920×1080 with frames captured offscreen — the fade-in, the wave order (bottom → middle → top) and
the dip depth were all read off those frames, and the settled frame compared against the stub
bitmap's block — but that is a development check on a workstation, not a gate in the suite.

## Open / not verified

- **The greeter still starting.** This is the one that matters. The splash now holds DRM master
  for the seconds before the display manager, and the argument that it always lets go in time is
  a systemd ordering plus two backstops — read out of the unit files, not watched on a booting
  machine. If the release never reaches the splash, logind's `drmSetMaster()` fails and the
  session does not start; `MASTER_HOLD_SECONDS` bounds that to 30 seconds rather than the boot.
  First thing to confirm, on the profile that has a display manager.
- **The boot splash animating at all.** `DIRTYFB` presenting each frame is from the drivers'
  symbol tables (`bochs.ko` and `virtio-gpu.ko` both link the dirty helper), not from a screen.
  It fails safe: the mark holds its full-brightness first frame, which is the splash plan/14
  shipped.
- **The Plasma splash inside a real session.** Everything above is `qml6` on a workstation, not
  `ksplashqml` under kwin. The theme resolution path, the layer-shell window and kwin's `login`
  effect are all read out of the pinned 6.6.6 sources rather than observed.
- **kwin's fade-out timing against a slow first boot.** The splash is killed at the `desktop`
  stage regardless; how much of the 500 ms fade is visible over a desktop still painting itself
  is a compositor-startup question, the same one plan/14 left open for the greeter.
- **Multi-monitor.** `animate()` walks every output the splash painted, but plan/14's untested
  multi-head case is untested here too — and now there is a second thing to get wrong on it.
