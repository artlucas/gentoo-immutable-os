/* Boot splash for the immutable image — the brand mark on every connected output, drawn with
 * DRM/KMS ioctls and nothing else.
 *
 * WHY THIS EXISTS AT ALL, i.e. why not plymouth or any fbdev-era splash.
 *
 * The image runs sys-kernel/gentoo-kernel-bin, whose config we do not own. Verified against
 * 6.18.43: DRM_SIMPLEDRM, DRM_EFIDRM, DRM_VESADRM and SYSFB_SIMPLEFB are unset, and so is
 * CONFIG_FB_DEVICE. That has two consequences that between them rule out every off-the-shelf
 * option:
 *
 *   - there is no generic firmware-framebuffer DRM device, so nothing can draw between the
 *     EFI stub and the first real KMS driver's modeset. That window is covered by the
 *     systemd-stub .splash bitmap instead (see config/branding/make-splash-assets.py), which
 *     is why this program only has to cover the window *after* the modeset.
 *   - there is no /dev/fb0 at all. fbsplash, splashutils, "just dd a raw image at the
 *     framebuffer" and plymouth's own frame-buffer.so renderer are all impossible here, not
 *     merely unfashionable. KMS ioctls on a card node are the only way to put a pixel on
 *     the screen.
 *
 * CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y *is* set, which is the other half of the
 * design: with `quiet` on the cmdline nothing paints the console, so the screen holds whatever
 * was last scanned out until we — or the greeter — modeset over it.
 *
 * THE ONE STRUCTURAL DECISION worth reading before the code: we DROP DRM MASTER immediately
 * after the modeset (see paint_card). A modeset survives the loss of master, and the buffer
 * survives as long as our fd is open, so the image stays on screen — but the compositor can
 * become master whenever it likes, with no ordering, no Conflicts=, and no handshake. The
 * previous plymouth integration spent two rounds of design (plan/08 open question 6, plan/11
 * finding 7) on races and deadlocks between the splash teardown and the greeter, and dropping
 * master deletes that entire problem class rather than solving it again.
 *
 * Consequently the teardown is just close(2). DRM destroys a client's framebuffers and dumb
 * buffers when its fd closes, and calls the driver's lastclose — which restores the fbdev
 * console mode — if we were the last client. So:
 *
 *   - greeter took over  -> close, change nothing, the compositor owns the screen
 *   - ESC / SIGTERM      -> close, we are the last client, fbcon comes back
 *
 * THE ANIMATION, and the one thing about it worth knowing before reading animate() (plan/17).
 * The logomark runs the design system's "layer pulse": one slab at a time dims and recovers,
 * the wave travelling up the stack. It is drawn by writing into the dumb buffer the CRTC is
 * already scanning out — no page flip, no atomic commit, no DRM_IOCTL_MODE_DIRTYFB — because
 * every one of those is DRM_MASTER-gated (drivers/gpu/drm/drm_ioctl.c) and we gave master away
 * two paragraphs ago. Taking it back for even one ioctl per frame is not an option: logind
 * calls drmSetMaster() when it hands the DRM fd to the compositor and returns the failure to
 * the caller, so a splash holding master at the wrong microsecond is a session that does not
 * start. The frame stays on screen either way; the only question is whether it moves.
 *
 * On the hardware this image targets it moves. A dumb buffer on amdgpu, i915, xe or nvidia-drm
 * IS the scanned-out memory, mapped write-combining, so a store lands on the panel with nothing
 * asked of the kernel. On a shadow-buffer driver — virtio_gpu, qxl, vmwgfx, udl — the host only
 * re-reads the buffer on a plane update, so the screen keeps showing whatever the modeset
 * flushed and the mark simply does not move. THAT DEGRADES TO EXACTLY THE OLD SPLASH, on
 * purpose: the first frame is painted with every slab at full brightness, which is the same
 * picture the stub bitmap has been showing since the firmware, so a VM sees the still frame it
 * saw before this animation existed rather than a half-lit mark frozen mid-pulse. To watch the
 * animation without hardware, use `scripts/run-vm.sh IMG --gpu bochs`: -vga std binds the bochs
 * driver, whose dumb buffers are the VRAM BAR QEMU reads continuously. The default virtio-VGA
 * stays the default because the stub image surviving the initrd depends on it (plan/14).
 *
 * Linked -static on purpose. Stage 30 emerges with ROOT=$TARGET and never chroots, so the
 * image's own toolchain cannot be invoked, and stage 50 deletes the compiler anyway; a static
 * binary has no ABI relationship with the image it ships in. Everything used here is a raw
 * syscall wrapper — no NSS, no dlopen, none of the reasons static glibc is normally a trap.
 * It also means no libdrm: the ioctls are the kernel uapi in <drm/drm_mode.h>, used directly.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <linux/input.h>

#ifndef SPLASH_ASSET_PATH
#define SPLASH_ASSET_PATH "/usr/share/splash/splash.bin"
#endif

/* Backstop only. The normal exits are "the greeter modeset over us" and ESC; this exists so a
 * boot that stalls before the greeter still ends up showing a console eventually, instead of a
 * logo forever with no indication anything is wrong. Deliberately long: a slow first boot that
 * grows /var and installs flatpaks must not trip it. */
#define SPLASH_MAX_SECONDS 120

/* How often we check whether someone else has modeset, and rescan for input devices. */
#define TICK_MS 500

/* How often the logomark is redrawn. 25fps is far more than a slow dim-and-recover needs, and
 * costs one lerp over ~17k pixels (scale 1) or ~68k (scale 2) per frame per output — and only
 * for the one slab that is actually moving, because animate() skips a tile whose level has not
 * changed since the last frame. */
#define FRAME_MS 40

/* Animation "B · Layer pulse", from the design system's Spinner. THESE THREE NUMBERS ARE ALSO
 * WRITTEN IN config/branding/make-splash-assets.py, which hands them to the Plasma splash that
 * takes over at login (plan/17); tests/test-splash-assets.sh asserts the two agree, because a
 * drift here is two brand animations at two different speeds on either side of one login. */
#define PULSE_CYCLE_MS 1600
#define PULSE_DEPTH 0.55
#define PULSE_SLOTS 3

#define MAX_CARDS 8
#define MAX_OUTPUTS 16
#define MAX_INPUTS 32
#define MAX_TILES 32

/* ---- asset container ------------------------------------------------------------------
 * Written by config/branding/make-splash-assets.py; the format is documented there and the
 * two must be changed together. Everything is little-endian u32, which is the only endianness
 * this image is ever built for (amd64-only, see the README's hardware window).
 *
 * Tiles are stored as OPAQUE BGRX rows, already composited over the background colour in
 * Python. That is what keeps this file free of any image decoding and of any per-pixel coverage:
 * fill the screen with the same background, memcpy the rows in, done. The antialiased edges land
 * pixel-exact because they were composited over the identical colour we fill with — and, as
 * blit() explains, that same property is what lets a slab be *dimmed* with one lerp and still no
 * alpha channel anywhere.
 *
 * A tile is placed by anchoring its BOX and then offsetting the tile inside it. A whole picture
 * is its own box at offset zero; the four pieces the centred block is cut into share the block
 * as their box and carry their position within it. The indirection earns its keep at the
 * hand-off: centring a 130px slab band and centring the 144px block it belongs to round
 * differently, and the difference would be a pixel of jitter between the stub bitmap and the
 * frame that replaces it. */

#define SPLASH_MAGIC "IMSPLSH2"
#define SPLASH_MAGIC_LEN 8

#define ANCHOR_CENTRE 0
#define ANCHOR_BOTTOM_LEFT 1
#define ANCHOR_BOTTOM_RIGHT 2

/* flags bit 0: this tile is one of the logomark's slabs and takes part in the layer pulse.
 * bits 8..15 are its slot in the wave — 0 dips first, then 1, then 2. */
#define TILE_PULSE 0x1u
#define TILE_PULSE_SHIFT 8

struct tile {
    uint32_t scale;         /* 1 or 2; picked against the mode height at runtime */
    uint32_t anchor;        /* ANCHOR_* — how the BOX is placed on the screen */
    uint32_t flags;         /* TILE_PULSE and its slot */
    uint32_t w, h;          /* the tile's own pixel size */
    uint32_t box_w, box_h;  /* the box the tile sits in; equal to w,h for a whole picture */
    int32_t off_x, off_y;   /* the tile's position inside that box, or the box's inset from an
                             * anchored screen edge when the box IS the tile */
    uint32_t data;          /* byte offset of w*h*4 pixels from the start of the file */
};

#define TILE_RECORD_WORDS 10
#define HEADER_WORDS 4 /* magic(2 words) + bg + count */

struct assets {
    uint8_t *blob;
    size_t size;
    uint32_t bg;      /* 0x00RRGGBB */
    uint32_t n_tiles;
    struct tile tiles[MAX_TILES];
};

/* ---- per-output state ------------------------------------------------------------------ */

struct output {
    int card_fd;
    uint32_t crtc_id;
    uint32_t fb_id;
    uint32_t handle; /* recorded for diagnostics; the buffer is freed by close(2), not by us */

    /* The mapping is kept for the life of the program rather than dropped after the first
     * frame: the animation is nothing but stores through this pointer (see the header). It is
     * never unmapped, because the only ways out of the main loop end the process. */
    uint8_t *pixels;
    uint32_t pitch, width, height;
    uint32_t scale;              /* which sprite set this panel got */
    uint32_t level[MAX_TILES];   /* last level each tile was drawn at, 0..256 */
};

static struct output outputs[MAX_OUTPUTS];
static int n_outputs;

static int card_fds[MAX_CARDS];
static int n_cards;

static volatile sig_atomic_t caught_signal;

static void on_signal(int sig)
{
    (void)sig;
    caught_signal = 1;
}

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* ioctl(2) restarted around signals. Every DRM ioctl below goes through this: a stray SIGCHLD
 * or a SIGWINCH turning a modeset into a spurious failure would be a genuinely baffling bug. */
static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do {
        r = ioctl(fd, req, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

/* ---- assets ---------------------------------------------------------------------------- */

static int load_assets(const char *path, struct assets *a)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)(HEADER_WORDS * 4) ||
        st.st_size > 64 * 1024 * 1024) {
        close(fd);
        return -1;
    }

    a->size = (size_t)st.st_size;
    a->blob = malloc(a->size);
    if (!a->blob) {
        close(fd);
        return -1;
    }

    size_t got = 0;
    while (got < a->size) {
        ssize_t n = read(fd, a->blob + got, a->size - got);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            close(fd);
            free(a->blob);
            a->blob = NULL;
            return -1;
        }
        got += (size_t)n;
    }
    close(fd);

    if (memcmp(a->blob, SPLASH_MAGIC, SPLASH_MAGIC_LEN) != 0) {
        free(a->blob);
        a->blob = NULL;
        return -1;
    }

    a->bg = rd32(a->blob + 8);
    a->n_tiles = rd32(a->blob + 12);
    if (a->n_tiles == 0 || a->n_tiles > sizeof(a->tiles) / sizeof(a->tiles[0])) {
        free(a->blob);
        a->blob = NULL;
        return -1;
    }

    size_t need = (size_t)HEADER_WORDS * 4 + (size_t)a->n_tiles * TILE_RECORD_WORDS * 4;
    if (a->size < need) {
        free(a->blob);
        a->blob = NULL;
        return -1;
    }

    for (uint32_t i = 0; i < a->n_tiles; i++) {
        const uint8_t *p = a->blob + HEADER_WORDS * 4 + (size_t)i * TILE_RECORD_WORDS * 4;
        struct tile *t = &a->tiles[i];
        t->scale = rd32(p + 0);
        t->anchor = rd32(p + 4);
        t->flags = rd32(p + 8);
        t->w = rd32(p + 12);
        t->h = rd32(p + 16);
        t->box_w = rd32(p + 20);
        t->box_h = rd32(p + 24);
        t->off_x = (int32_t)rd32(p + 28);
        t->off_y = (int32_t)rd32(p + 32);
        t->data = rd32(p + 36);

        /* Bounds-check every tile against the real file length. The build asserts this too,
         * but a truncated asset on a failing disk must not become a wild memcpy in pid ~200
         * of the boot. */
        if (t->w == 0 || t->h == 0 || t->w > 16384 || t->h > 16384) {
            free(a->blob);
            a->blob = NULL;
            return -1;
        }
        /* A box smaller than the tile it holds would place the tile off its own anchor, and a
         * box the generator forgot to fill in (0) would centre it against nothing. */
        if (t->box_w < t->w || t->box_h < t->h || t->box_w > 16384 || t->box_h > 16384) {
            free(a->blob);
            a->blob = NULL;
            return -1;
        }
        size_t bytes = (size_t)t->w * t->h * 4;
        if (t->data > a->size || bytes > a->size - t->data) {
            free(a->blob);
            a->blob = NULL;
            return -1;
        }
    }
    return 0;
}

/* Which sprite set to use for a given panel. The assets are emitted at discrete scales rather
 * than resampled here: the design is authored at a 1920x1080 baseline, so scale 1 covers
 * everything up to and including 1440p and scale 2 covers 4K-class panels. Unlike the
 * systemd-stub bitmap — which cannot know the resolution and so needs SPLASH_STUB_SCALE in
 * build.conf — this program queries the actual mode, so it needs no build-time knob. */
static uint32_t pick_scale(const struct assets *a, uint32_t mode_h)
{
    uint32_t want = (mode_h >= 2000) ? 2 : 1;
    uint32_t best = 0;

    for (uint32_t i = 0; i < a->n_tiles; i++) {
        uint32_t s = a->tiles[i].scale;
        if (s == want)
            return want;
        /* Prefer the largest scale not exceeding what we wanted; failing that, the smallest
         * available, so a container that only carries scale 2 still draws on a 1080p panel. */
        if (s < want && s > best)
            best = s;
    }
    if (best)
        return best;

    best = UINT32_MAX;
    for (uint32_t i = 0; i < a->n_tiles; i++)
        if (a->tiles[i].scale < best)
            best = a->tiles[i].scale;
    return (best == UINT32_MAX) ? 1 : best;
}

/* ---- painting -------------------------------------------------------------------------- */

/* Dim one pre-composited pixel toward the background, `level` in 0..256.
 *
 * The tiles are opaque because Python already composited them: T = A*S + (1-A)*BG, for slab
 * colour S and antialiased coverage A. Drawing that same slab at opacity k is
 *
 *     k*A*S + (1 - k*A)*BG  ==  BG + k*(T - BG)
 *
 * which is a plain lerp between the tile and the background — no alpha channel, no coverage
 * term, and exact at both ends. That identity is the entire reason the container could stay
 * opaque BGRX rows when the mark started moving, and it is why level == 256 below is a memcpy
 * of the very bytes the old static splash blitted. */
static uint32_t dim_px(uint32_t src, uint32_t bg, uint32_t level)
{
    uint32_t out = 0;
    for (unsigned shift = 0; shift <= 16; shift += 8) {
        int32_t sc = (int32_t)((src >> shift) & 0xffu);
        int32_t bc = (int32_t)((bg >> shift) & 0xffu);
        out |= (uint32_t)(bc + (sc - bc) * (int32_t)level / 256) << shift;
    }
    return out;
}

static void blit(uint8_t *dst, uint32_t pitch, uint32_t sw, uint32_t sh, const struct assets *a,
                 const struct tile *t, uint32_t level)
{
    long x, y;

    /* The BOX is what gets anchored; the tile then sits at its own offset inside it. For a
     * whole picture the two are the same thing and off_* is the inset from the screen edge. */
    switch (t->anchor) {
    case ANCHOR_BOTTOM_LEFT:
        x = (long)t->off_x;
        y = (long)sh - (long)t->off_y - (long)t->box_h;
        break;
    case ANCHOR_BOTTOM_RIGHT:
        x = (long)sw - (long)t->off_x - (long)t->box_w;
        y = (long)sh - (long)t->off_y - (long)t->box_h;
        break;
    default:
        x = ((long)sw - (long)t->box_w) / 2 + (long)t->off_x;
        y = ((long)sh - (long)t->box_h) / 2 + (long)t->off_y;
        break;
    }

    /* A tile wider or taller than the panel is not an error — a 1024x768 screen with scale-1
     * assets is a legitimate configuration — so clip rather than refuse to draw. */
    long src_x = 0, src_y = 0;
    if (x < 0) { src_x = -x; x = 0; }
    if (y < 0) { src_y = -y; y = 0; }
    if (src_x >= (long)t->w || src_y >= (long)t->h)
        return;

    long cw = (long)t->w - src_x;
    long ch = (long)t->h - src_y;
    if (x + cw > (long)sw) cw = (long)sw - x;
    if (y + ch > (long)sh) ch = (long)sh - y;
    if (cw <= 0 || ch <= 0)
        return;

    const uint8_t *src = a->blob + t->data;
    for (long row = 0; row < ch; row++) {
        uint8_t *drow = dst + (size_t)(y + row) * pitch + (size_t)x * 4;
        const uint8_t *srow = src + (size_t)(src_y + row) * t->w * 4 + (size_t)src_x * 4;
        if (level >= 256) {
            memcpy(drow, srow, (size_t)cw * 4);
            continue;
        }
        uint32_t *dp = (uint32_t *)drow;
        const uint32_t *sp = (const uint32_t *)srow;
        for (long col = 0; col < cw; col++)
            dp[col] = dim_px(sp[col], a->bg, level);
    }
}

/* Animation "B · Layer pulse": each slab dims and recovers inside its own third of the cycle,
 * the wave travelling up the stack, and EVERY slab is at full brightness at ms == 0.
 *
 * That last property is not incidental. The first frame is painted at ms == 0, so it is the
 * same picture as the stub bitmap the firmware has been showing — which is what makes the
 * hand-off at the modeset invisible, and what makes a shadow-buffer driver that never sees a
 * second frame show the old static splash rather than a mark stopped mid-dip.
 *
 * The curve is a triangle run through smoothstep rather than a sine, which keeps this file free
 * of libm: smoothstep's derivative is zero at both ends, so the joins at the start, the middle
 * and the end of a slab's window are all smooth despite the triangle's corner. */
static uint32_t pulse_level(uint64_t ms, uint32_t slot)
{
    double phase = (double)(ms % PULSE_CYCLE_MS) / (double)PULSE_CYCLE_MS;
    double u = phase - (double)slot / (double)PULSE_SLOTS;
    if (u < 0.0)
        u += 1.0;
    u *= (double)PULSE_SLOTS;   /* this slab's own window is u in [0,1) */
    if (u >= 1.0)
        return 256;             /* between pulses: at rest, full brightness, drawn as a memcpy */

    double v = 2.0 * u - 1.0;
    if (v < 0.0)
        v = -v;
    v = 1.0 - v;                            /* triangle: 0 -> 1 -> 0 across the window */
    double bump = v * v * (3.0 - 2.0 * v);  /* smoothstep */
    double level = (1.0 - PULSE_DEPTH * bump) * 256.0;
    if (level < 0.0)
        level = 0.0;
    if (level > 256.0)
        level = 256.0;
    return (uint32_t)(level + 0.5);
}

static void fill_bg(uint8_t *dst, uint32_t pitch, uint32_t w, uint32_t h, uint32_t bg)
{
    /* XRGB8888: the same 32-bit word every pixel, so the inner loop is a word store. */
    for (uint32_t row = 0; row < h; row++) {
        uint32_t *p = (uint32_t *)(dst + (size_t)row * pitch);
        for (uint32_t col = 0; col < w; col++)
            p[col] = bg;
    }
}

/* Allocate a dumb buffer for `mode`, paint it, and light it up on `crtc_id`. */
static int show_on_crtc(int fd, uint32_t crtc_id, uint32_t connector_id,
                        struct drm_mode_modeinfo *mode, const struct assets *a)
{
    struct drm_mode_create_dumb create = { 0 };
    create.width = mode->hdisplay;
    create.height = mode->vdisplay;
    create.bpp = 32;
    if (xioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0)
        return -1;

    struct drm_mode_fb_cmd fb = { 0 };
    fb.width = create.width;
    fb.height = create.height;
    fb.pitch = create.pitch;
    fb.bpp = 32;
    fb.depth = 24;
    fb.handle = create.handle;
    if (xioctl(fd, DRM_IOCTL_MODE_ADDFB, &fb) != 0)
        goto err_dumb;

    struct drm_mode_map_dumb map = { 0 };
    map.handle = create.handle;
    if (xioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map) != 0)
        goto err_fb;

    uint8_t *pixels = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                           (off_t)map.offset);
    if (pixels == MAP_FAILED)
        goto err_fb;

    fill_bg(pixels, create.pitch, create.width, create.height, a->bg);

    /* Frame zero, with every slab at full: byte-for-byte the frame this program drew before it
     * could animate, and the same picture as the stub bitmap it is taking over from. */
    uint32_t scale = pick_scale(a, create.height);
    for (uint32_t i = 0; i < a->n_tiles; i++)
        if (a->tiles[i].scale == scale)
            blit(pixels, create.pitch, create.width, create.height, a, &a->tiles[i], 256);

    struct drm_mode_crtc set = { 0 };
    set.crtc_id = crtc_id;
    set.fb_id = fb.fb_id;
    set.set_connectors_ptr = (uint64_t)(uintptr_t)&connector_id;
    set.count_connectors = 1;
    set.mode = *mode;
    set.mode_valid = 1;
    if (xioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set) != 0) {
        munmap(pixels, create.size);
        goto err_fb;
    }

    if (n_outputs < MAX_OUTPUTS) {
        struct output *o = &outputs[n_outputs++];
        o->card_fd = fd;
        o->crtc_id = crtc_id;
        o->fb_id = fb.fb_id;
        o->handle = create.handle;
        /* Kept mapped: animate() writes straight into the memory the CRTC is scanning out,
         * which is the only way to move a pixel once master is gone. */
        o->pixels = pixels;
        o->pitch = create.pitch;
        o->width = create.width;
        o->height = create.height;
        o->scale = scale;
        for (uint32_t i = 0; i < MAX_TILES; i++)
            o->level[i] = 256;
    } else {
        munmap(pixels, create.size);
    }
    return 0;

err_fb:
    xioctl(fd, DRM_IOCTL_MODE_RMFB, &fb.fb_id);
err_dumb:;
    struct drm_mode_destroy_dumb destroy = { .handle = create.handle };
    xioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    return -1;
}

/* Two-pass ioctl: the kernel fills in the counts when the pointers are NULL, then fills the
 * arrays on a second call. This is the documented DRM uapi pattern, not a trick. */
static int paint_card(const char *path, const struct assets *a)
{
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;

    /* udev starts us the moment the card appears, so the driver may still be settling and
     * another client (none should exist this early, but say a leftover) may hold master.
     * Retry briefly rather than losing the splash to a race we can simply wait out. */
    int have_master = 0;
    for (int attempt = 0; attempt < 10; attempt++) {
        if (xioctl(fd, DRM_IOCTL_SET_MASTER, NULL) == 0) {
            have_master = 1;
            break;
        }
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    if (!have_master) {
        close(fd);
        return -1;
    }

    struct drm_mode_card_res res = { 0 };
    if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) != 0)
        goto err;
    if (res.count_connectors == 0 || res.count_crtcs == 0)
        goto err;

    uint32_t *connectors = calloc(res.count_connectors, sizeof(uint32_t));
    uint32_t *crtcs = calloc(res.count_crtcs, sizeof(uint32_t));
    uint32_t *encoders = calloc(res.count_encoders ? res.count_encoders : 1, sizeof(uint32_t));
    uint32_t *fbs = calloc(res.count_fbs ? res.count_fbs : 1, sizeof(uint32_t));
    if (!connectors || !crtcs || !encoders || !fbs) {
        free(connectors); free(crtcs); free(encoders); free(fbs);
        goto err;
    }
    uint32_t n_conn = res.count_connectors, n_crtc = res.count_crtcs;
    res.connector_id_ptr = (uint64_t)(uintptr_t)connectors;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)encoders;
    res.fb_id_ptr = (uint64_t)(uintptr_t)fbs;
    if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) != 0) {
        free(connectors); free(crtcs); free(encoders); free(fbs);
        goto err;
    }
    /* The second call re-reports the counts, and they can be LARGER than the first call said —
     * a hotplug between the two is all it takes. The kernel fills only as many entries as we
     * asked for, but it writes back the true total, so trusting count_* here would walk off the
     * end of these allocations. Iterate over what was actually allocated instead. */
    if (res.count_connectors < n_conn)
        n_conn = res.count_connectors;
    if (res.count_crtcs < n_crtc)
        n_crtc = res.count_crtcs;

    /* One CRTC can drive only one output, so a CRTC handed to one connector must not be
     * offered to the next. */
    uint8_t *crtc_taken = calloc(n_crtc ? n_crtc : 1, 1);
    int painted = 0;

    for (uint32_t ci = 0; crtc_taken && ci < n_conn; ci++) {
        struct drm_mode_get_connector conn = { 0 };
        conn.connector_id = connectors[ci];
        if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) != 0)
            continue;
        if (conn.connection != 1 /* DRM_MODE_CONNECTED */ || conn.count_modes == 0)
            continue;

        struct drm_mode_modeinfo *modes = calloc(conn.count_modes, sizeof(*modes));
        uint32_t *conn_encoders = calloc(conn.count_encoders ? conn.count_encoders : 1,
                                         sizeof(uint32_t));
        if (!modes || !conn_encoders) {
            free(modes); free(conn_encoders);
            continue;
        }
        uint32_t n_modes = conn.count_modes, n_enc = conn.count_encoders;
        conn.modes_ptr = (uint64_t)(uintptr_t)modes;
        conn.encoders_ptr = (uint64_t)(uintptr_t)conn_encoders;
        conn.count_props = 0;
        conn.props_ptr = 0;
        conn.prop_values_ptr = 0;
        if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) != 0 || conn.count_modes == 0) {
            free(modes); free(conn_encoders);
            continue;
        }
        /* Clamped for the same reason as the resource counts above: the connector is re-probed
         * on this call and can come back with more modes than the allocation was sized for. */
        if (conn.count_modes < n_modes)
            n_modes = conn.count_modes;
        if (conn.count_encoders < n_enc)
            n_enc = conn.count_encoders;

        /* The driver sorts modes best-first, so modes[0] is already the right answer on every
         * driver we ship — but DRM_MODE_TYPE_PREFERRED is the flag that actually says so, and
         * honouring it is what stops a stale EDID from putting the splash in 640x480. */
        struct drm_mode_modeinfo *mode = &modes[0];
        for (uint32_t mi = 0; mi < n_modes; mi++) {
            if (modes[mi].type & DRM_MODE_TYPE_PREFERRED) {
                mode = &modes[mi];
                break;
            }
        }

        /* Find a free CRTC this connector can actually reach. The connector's current encoder
         * is tried first — on a display already lit by the firmware that is the one the
         * hardware is set up for — then every other encoder it lists. */
        int done = 0;
        for (uint32_t pass = 0; pass < 2 && !done; pass++) {
            for (uint32_t ei = 0; ei < n_enc && !done; ei++) {
                uint32_t enc_id = conn_encoders[ei];
                if (pass == 0 && (conn.encoder_id == 0 || enc_id != conn.encoder_id))
                    continue;
                if (pass == 1 && enc_id == conn.encoder_id)
                    continue;

                struct drm_mode_get_encoder enc = { .encoder_id = enc_id };
                if (xioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc) != 0)
                    continue;

                for (uint32_t k = 0; k < n_crtc && !done; k++) {
                    if (crtc_taken[k] || !(enc.possible_crtcs & (1u << k)))
                        continue;
                    if (show_on_crtc(fd, crtcs[k], conn.connector_id, mode, a) == 0) {
                        crtc_taken[k] = 1;
                        painted++;
                        done = 1;
                    }
                }
            }
        }

        free(modes);
        free(conn_encoders);
    }

    free(crtc_taken);
    free(connectors);
    free(crtcs);
    free(encoders);
    free(fbs);

    if (!painted)
        goto err;

    /* The decision this whole program is shaped around — see the header comment. From here the
     * frame stays on screen because a modeset persists and our fd keeps the buffer alive, but
     * the compositor can take master the instant it wants to, with nothing to coordinate. */
    xioctl(fd, DRM_IOCTL_DROP_MASTER, NULL);

    if (n_cards < MAX_CARDS)
        card_fds[n_cards++] = fd;
    return 0;

err:
    close(fd);
    return -1;
}

/* ---- input ----------------------------------------------------------------------------- */

/* Reading evdev rather than the VT is deliberate. Owning a VT means KDSETMODE/KDSKBMODE and
 * the VT_PROCESS switch protocol, which is both the machinery plymouth used and the machinery
 * that was visibly misbehaving; and reading /dev/tty0 directly would contend with getty for
 * the terminal. evdev needs none of that and costs one open() per device. */

struct input_dev {
    int fd;
    char name[256]; /* NAME_MAX + 1: sized so the compiler can see the copy cannot truncate */
};

static struct input_dev inputs[MAX_INPUTS];
static int n_inputs;

static int already_open(const char *name)
{
    for (int i = 0; i < n_inputs; i++)
        if (strcmp(inputs[i].name, name) == 0)
            return 1;
    return 0;
}

/* Rescanned on every tick: udev may still be creating input nodes when the DRM device — and
 * therefore this program — appears, so a single scan at startup would miss the keyboard on
 * exactly the fast boots where it matters least and the slow ones where it matters most. */
static void scan_inputs(void)
{
    DIR *d = opendir("/dev/input");
    if (!d)
        return;

    struct dirent *e;
    while ((e = readdir(d)) != NULL && n_inputs < MAX_INPUTS) {
        if (strncmp(e->d_name, "event", 5) != 0 || already_open(e->d_name))
            continue;

        char path[PATH_MAX];
        snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue;

        /* Keep only devices that report keys. A touchpad or an accelerometer waking us on
         * every packet would turn the poll loop into a spin. */
        unsigned long bits = 0;
        if (ioctl(fd, EVIOCGBIT(0, sizeof(bits)), &bits) < 0 || !(bits & (1UL << EV_KEY))) {
            close(fd);
            continue;
        }

        inputs[n_inputs].fd = fd;
        snprintf(inputs[n_inputs].name, sizeof(inputs[n_inputs].name), "%s", e->d_name);
        n_inputs++;
    }
    closedir(d);
}

static int drain_input_for_esc(int fd)
{
    struct input_event ev;
    ssize_t n;
    int esc = 0;

    while ((n = read(fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev))
        if (ev.type == EV_KEY && ev.code == KEY_ESC && ev.value == 1)
            esc = 1;

    return esc;
}

/* ---- details view ----------------------------------------------------------------------- */

/* One-way by design: ESC reveals the boot log and the splash does not come back. Toggling
 * between a graphical and a text view is precisely what was flickering before, and a boot that
 * has gone wrong enough for someone to press ESC is not improved by being able to hide the
 * evidence again.
 *
 * A limitation worth knowing rather than rediscovering: this reveals KERNEL messages, not
 * systemd's status output. The cmdline ends `console=tty0 console=ttyS0`, and the last console=
 * is the one /dev/console resolves to for userspace writes, so systemd's status lines go to the
 * serial port. Reordering the two would move them to the screen — and would break stage 70,
 * which reads that serial log to decide whether the image booted. */
static void reveal_console(void)
{
    /* Undo `quiet`. SYSLOG_ACTION_CONSOLE_LEVEL = 8; 7 is KERN_DEBUG, i.e. everything. */
    klogctl(8, NULL, 7);

    /* Closing our fds is the whole teardown: DRM frees the framebuffers and dumb buffers with
     * the client, and because we are the last one, lastclose restores the fbdev console mode.
     * Done BEFORE painting so that fbcon's buffer is the one being scanned out by the time
     * anything is written to it. */
    for (int i = 0; i < n_cards; i++)
        close(card_fds[i]);
    n_cards = 0;
    n_outputs = 0;

    /* Replay the ring buffer, so ESC shows the boot so far rather than only what happens
     * next — the messages someone pressing ESC actually wants are already in the past.
     * SYSLOG_ACTION_READ_ALL = 3. */
    int len = klogctl(10, NULL, 0); /* SYSLOG_ACTION_SIZE_BUFFER */
    if (len <= 0 || len > 1 << 20)
        len = 1 << 18;

    char *buf = malloc((size_t)len + 1);
    if (!buf)
        return;

    int got = klogctl(3, buf, len);
    if (got <= 0) {
        free(buf);
        return;
    }
    buf[got] = '\0';

    int tty = open("/dev/tty0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (tty < 0) {
        free(buf);
        return;
    }

    /* Strip the "<N>" priority prefix each record carries, so the screen reads like dmesg
     * rather than like a raw kmsg dump. */
    char *line = buf;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        if (nl)
            *nl = '\0';

        char *text = line;
        if (text[0] == '<') {
            char *close_angle = strchr(text, '>');
            if (close_angle && close_angle - text <= 4)
                text = close_angle + 1;
        }

        size_t tlen = strlen(text);
        if (write(tty, text, tlen) != (ssize_t)tlen)
            break;
        if (write(tty, "\r\n", 2) != 2)
            break;

        line = nl ? nl + 1 : NULL;
    }

    close(tty);
    free(buf);
}

/* ---- animation ---------------------------------------------------------------------------- */

/* Redraw whichever slabs have moved since the last frame, on every output.
 *
 * Only the slab tiles carry TILE_PULSE, so the wordmark and the status fields are painted once
 * by show_on_crtc() and never touched again — and a slab that is between pulses compares equal
 * to its last level and is skipped entirely, so most frames repaint exactly one band.
 *
 * There is nothing to tell the kernel afterwards. See the header: every ioctl that would flush
 * or flip is DRM_MASTER-gated, and on the drivers this image targets a store into the mapped
 * dumb buffer is already on the panel. */
static void animate(const struct assets *a, uint64_t ms)
{
    for (int i = 0; i < n_outputs; i++) {
        struct output *o = &outputs[i];
        if (!o->pixels)
            continue;
        for (uint32_t ti = 0; ti < a->n_tiles; ti++) {
            const struct tile *t = &a->tiles[ti];
            if (t->scale != o->scale || !(t->flags & TILE_PULSE))
                continue;
            uint32_t level = pulse_level(ms, (t->flags >> TILE_PULSE_SHIFT) & 0xffu);
            if (level == o->level[ti])
                continue;
            o->level[ti] = level;
            blit(o->pixels, o->pitch, o->width, o->height, a, t, level);
        }
    }
}

/* ---- takeover detection ------------------------------------------------------------------ */

/* The greeter's compositor becomes master and modesets; from that moment the CRTC scans out
 * its framebuffer rather than ours and we have nothing left to do. Asking the CRTC what it is
 * currently showing is a read-only ioctl that works fine without master, which is what makes
 * this possible at all after DROP_MASTER. */
static int someone_else_took_over(void)
{
    if (n_outputs == 0)
        return 1;

    for (int i = 0; i < n_outputs; i++) {
        struct drm_mode_crtc get = { .crtc_id = outputs[i].crtc_id };
        if (xioctl(outputs[i].card_fd, DRM_IOCTL_MODE_GETCRTC, &get) != 0)
            return 1;
        if (get.fb_id != outputs[i].fb_id)
            return 1;
    }
    return 0;
}

/* ---- main -------------------------------------------------------------------------------- */

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

int main(int argc, char **argv)
{
    const char *asset_path = (argc > 1) ? argv[1] : SPLASH_ASSET_PATH;

    /* Nothing here is worth a message on a console the splash is about to cover, and a failure
     * to draw must never hold up the boot: every error path below simply exits 0. The build
     * asserts the things that could actually be wrong (binary static, assets present and
     * well-formed, unit and udev rule installed), so a silent no-op at runtime means the
     * hardware said no, not that the image is broken. */
    struct assets a = { 0 };
    if (load_assets(asset_path, &a) != 0)
        return 0;

    struct sigaction sa = { 0 };
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    DIR *d = opendir("/dev/dri");
    if (!d)
        return 0;

    struct dirent *e;
    while ((e = readdir(d)) != NULL && n_cards < MAX_CARDS) {
        if (strncmp(e->d_name, "card", 4) != 0)
            continue;
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "/dev/dri/%s", e->d_name);
        paint_card(path, &a);
    }
    closedir(d);

    if (n_outputs == 0)
        return 0;

    scan_inputs();

    /* Two clocks, deliberately separate. The poll wakes on the FRAME clock so the mark moves
     * smoothly, while the takeover check and the input rescan stay on the 500ms TICK they were
     * designed around — running a GETCRTC per output at 25fps to watch for the greeter would be
     * twenty-five times the ioctls to learn the same thing. */
    struct timespec tick = { .tv_sec = 0, .tv_nsec = FRAME_MS * 1000L * 1000L };
    uint64_t started = now_ms();
    uint64_t last_tick = started;

    for (;;) {
        struct pollfd pfds[MAX_INPUTS];
        for (int i = 0; i < n_inputs; i++) {
            pfds[i].fd = inputs[i].fd;
            pfds[i].events = POLLIN;
            pfds[i].revents = 0;
        }

        int r = ppoll(pfds, (nfds_t)n_inputs, &tick, NULL);

        if (caught_signal) {
            /* Shutdown, or the unit being stopped. Release the screen so whatever runs next
             * owns it, rather than leaving a logo over a machine that is powering off. */
            for (int i = 0; i < n_cards; i++)
                close(card_fds[i]);
            break;
        }

        if (r > 0) {
            int esc = 0;
            for (int i = 0; i < n_inputs; i++)
                if (pfds[i].revents & POLLIN)
                    esc |= drain_input_for_esc(inputs[i].fd);
            if (esc) {
                reveal_console();
                break;
            }
            /* A key that was not ESC still consumed the poll timeout; fall through so the
             * elapsed clock and the takeover check stay on their own schedule. */
        }

        /* Measured against the monotonic clock rather than counted in ticks: a keyboard held
         * down returns from ppoll early every time, and a tick counter would then stretch both
         * the animation and the backstop by however long someone leans on the spacebar. */
        uint64_t now = now_ms();

        animate(&a, now - started);

        if (now - last_tick < TICK_MS)
            continue;
        last_tick = now;

        if (someone_else_took_over())
            break; /* the greeter is up: change nothing, just let the fds close */

        if (now - started >= (uint64_t)SPLASH_MAX_SECONDS * 1000u) {
            /* Two very different situations reach this line, and they want opposite things.
             *
             * The boot really is stalled — then showing the log is the whole point of having a
             * backstop, because otherwise the machine sits on a logo with no way to find out
             * why short of someone happening to press ESC.
             *
             * Or the desktop is up and we simply did not notice: on a multi-head machine the
             * compositor may have lit a CRTC we are not watching, leaving ours still showing
             * our own framebuffer forever. Dumping the kernel log and raising the console
             * loglevel underneath a running session would be pure vandalism.
             *
             * Asking whether anyone else holds DRM master separates them exactly. A compositor
             * is always master; if nothing is, nothing is driving the display. Taking master to
             * find out is safe *here* specifically because a successful acquisition proves
             * nobody else wanted it, and it is handed straight back — which is why this is done
             * once, at the backstop, rather than on every tick where it would race a compositor
             * that is only just starting up.
             */
            int idle = 1;
            for (int i = 0; i < n_cards; i++) {
                if (xioctl(card_fds[i], DRM_IOCTL_SET_MASTER, NULL) == 0)
                    xioctl(card_fds[i], DRM_IOCTL_DROP_MASTER, NULL);
                else
                    idle = 0;
            }
            if (idle) {
                reveal_console();
            } else {
                for (int i = 0; i < n_cards; i++)
                    close(card_fds[i]);
            }
            break;
        }

        scan_inputs();
    }

    return 0;
}
