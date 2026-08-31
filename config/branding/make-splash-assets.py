#!/usr/bin/env python3
"""Compose both boot-splash artefacts from the rasterised branding PNGs.

Run once by stage 40, after the rasterise pass, emitting whichever of the two outputs was
asked for:

  --bmp      the systemd-stub `.splash` bitmap, blitted by the firmware-stage stub before the
             kernel starts. Covers firmware -> first modeset.
  --sprites  the tile container read by config/splash/splash.c, which draws on DRM from the
             first modeset to the greeter.

They are produced by ONE script from ONE set of PNGs on purpose. The two halves of the splash
meet mid-boot at the first modeset, and any drift in geometry or brightness between them shows
up as a jump on screen at exactly that moment. There is one layout function, compose_block(),
and both outputs call it.

Two facts about systemd-stub drive the BMP half (src/boot/splash.c, v260):

  * It fills the ENTIRE screen with a flat background first, then blits the bitmap centred.
    That background is hardcoded black — `EFI_GRAPHICS_OUTPUT_BLT_PIXEL background = {}`, with
    a light grey special case for Apple firmware and nothing else. So the BMP canvas is painted
    pure black rather than the design system's #0a0d11 (--surface-sunken) that the KMS splash
    fills with: a canvas in the brand colour would show up as a visible rectangle seam against
    the stub's black fill. The two differ by RGB(10,13,17); the seam would be worse.

  * It does NOT scale. `x_pos = (HorizontalResolution - dib->x) / 2` and the equivalent for y,
    and a bitmap larger than the screen is drawn from the origin and clipped. There is no
    resolution to query before ExitBootServices, hence the explicit --scale, hence
    SPLASH_STUB_SCALE in build.conf. The sprite container has no such problem and carries every
    scale, because splash.c reads the mode off the CRTC before it picks one.

The centred block is drawn at FULL BRIGHTNESS in both outputs. It was previously dimmed to 0.2
because the splash it had to match was plymouth's, whose pulse animation rested at the faded
end of its curve; with the animation gone there is nothing for a dim frame to be consistent
with, and two static images of different brightness meeting at the modeset would read as a
flash. See plan/14.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - the builder installs dev-python/pillow explicitly
    sys.exit("make-splash-assets: Pillow not available — is dev-python/pillow in builder/Dockerfile?")

# Geometry, in design pixels at the 1920x1080 baseline. Authored in the design system and
# duplicated nowhere else now that the plymouth theme is gone — this file is the only place
# the layout is stated.
MARK_BOX = 132  # the logomark's layout box
GAP = 34  # logomark box -> wordmark
PAD_X = 40  # status bar inset from the left/right screen edge
PAD_Y = 28  # status bar inset from the bottom screen edge
ASSET_ZOOM = 4  # BRANDING_ZOOM in lib/common.sh: what the PNGs were rasterised at

SLABS = ("slab-top.png", "slab-mid.png", "slab-bot.png")
WORDMARK = "wordmark.png"
STATUS_LEFT = "status-left.png"
STATUS_RIGHT = "status-right.png"

# --surface-sunken, dark theme: what splash.c fills the screen with, and what the sprite tiles
# are composited over so their antialiased edges land exactly on it.
BG = (0x0A, 0x0D, 0x11)

# The scales the sprite container carries. splash.c picks 2 for panels 2000px tall or more and
# 1 otherwise, falling back sensibly if a scale is missing — so this list is a size/coverage
# tradeoff, not a correctness one. Scale 1 is ~490 KiB and scale 2 ~2 MiB of the root EROFS.
SPRITE_SCALES = (1, 2)

# Container format, read by load_assets() in config/splash/splash.c. Change one, change both.
#
#   0   8   magic "IMSPLSH1"
#   8   4   u32  background, 0x00RRGGBB
#   12  4   u32  tile count
#   16  ..  tile records, 28 bytes each:
#             u32 scale | u32 anchor | u32 w | u32 h | u32 off_x | u32 off_y | u32 data_offset
#   ..      tile pixels, w*h*4 opaque BGRX rows, in record order
MAGIC = b"IMSPLSH1"
HEADER_BYTES = 16
TILE_RECORD_BYTES = 28

ANCHOR_CENTRE = 0
ANCHOR_BOTTOM_LEFT = 1
ANCHOR_BOTTOM_RIGHT = 2

# ---- slab shading -------------------------------------------------------------------------
# The slab SVGs carry their 3D shading as polygon `opacity`, identical in all three files:
#
#     top face (the rhombus)  opacity 0.6   -> baked alpha 153
#     front-left face         opacity 1.0   -> baked alpha 255
#     front-right face        opacity 0.82  -> baked alpha 209
#
# Those values were chosen for an animated splash that multiplied a whole-slab opacity over
# them and was in motion the entire time. They do NOT work for a single static frame: the top
# face is by far the largest surface (~15.5k px against ~6.4k for either side), so at 60% alpha
# over the background the broadest part of the mark is also its dimmest — the shading runs
# backwards, brightest on the faces turned away from the light.
#
# So the static frames re-shade: the same three faces, but the shading is carried in COLOUR at
# full opacity instead of in alpha. The top face — the one facing the light — takes the accent
# value undiminished and the two sides step down from it, which is the way a lit solid actually
# reads. Simply forcing every face to full opacity was the other option and is worse: all three
# polygons share one fill, so they merge into a flat hexagon and the slab stops being a slab.
#
# These constants track the SVGs. Change the polygon opacities there and the BAKED values here
# have to follow, or the faces stop being recognised and fall back to whichever is nearest.
TEAL = (0x0E, 0x9C, 0x8A)  # --accent, the fill every polygon uses
BAKED_TOP, BAKED_LEFT, BAKED_RIGHT = 153, 255, 209
FACE_SHADE = {BAKED_TOP: 1.00, BAKED_LEFT: 0.82, BAKED_RIGHT: 0.66}


def reshade_slab(img: Image.Image) -> Image.Image:
    """Turn the slab's alpha-baked face shading into opaque colour shading.

    Both output channels depend only on the input alpha, so this is done with 256-entry
    lookup tables rather than a per-pixel loop: exact, and fast enough to be free.
    """
    lut_r, lut_g, lut_b, lut_a = [], [], [], []
    for a in range(256):
        face = min(FACE_SHADE, key=lambda f: abs(f - a))
        shade = FACE_SHADE[face]
        # Alpha below the face's own baked value is an antialiased edge; keep it proportional
        # so the silhouette stays smooth instead of turning into stair-steps.
        lut_a.append(min(255, round(255 * a / face)))
        lut_r.append(round(TEAL[0] * shade))
        lut_g.append(round(TEAL[1] * shade))
        lut_b.append(round(TEAL[2] * shade))
    lut_r[0] = lut_g[0] = lut_b[0] = lut_a[0] = 0  # fully transparent stays fully transparent

    alpha = img.getchannel("A")
    return Image.merge(
        "RGBA",
        (alpha.point(lut_r), alpha.point(lut_g), alpha.point(lut_b), alpha.point(lut_a)),
    )


def load(theme: Path, name: str, factor: float) -> Image.Image:
    path = theme / name
    if not path.is_file():
        sys.exit(f"make-splash-assets: missing branding asset {path}")
    img = Image.open(path).convert("RGBA")
    if factor == 1.0:
        return img
    w = max(1, round(img.width * factor))
    h = max(1, round(img.height * factor))
    return img.resize((w, h), Image.LANCZOS)


def compose_block(theme: Path, scale: float, background: tuple[int, int, int]) -> Image.Image:
    """The centred column: [logomark box] + [gap] + [wordmark], flattened onto `background`.

    This is the single source of the splash's layout. Both the stub bitmap and the sprite
    container's centre tile are this function's output; nothing else positions the mark.
    """
    factor = scale / ASSET_ZOOM

    # Re-shade before scaling: the LUT keys off exact baked alpha values, and resampling blends
    # them into intermediates that would no longer identify a face.
    slabs = [reshade_slab(load(theme, n, 1.0)) for n in SLABS]
    slabs = [
        s.resize((max(1, round(s.width * factor)), max(1, round(s.height * factor))), Image.LANCZOS)
        for s in slabs
    ]
    word = load(theme, WORDMARK, factor)

    box_px = round(MARK_BOX * scale)
    gap_px = round(GAP * scale)
    mark_h = max(s.height for s in slabs)

    width = max(max(s.width for s in slabs), word.width)
    height = box_px + gap_px + word.height

    canvas = Image.new("RGB", (width, height), background)

    # The three slabs sit in register on an identical canvas.
    mark_y = (box_px - mark_h) // 2
    for slab in slabs:
        canvas.paste(slab, ((width - slab.width) // 2, mark_y), slab)

    canvas.paste(word, ((width - word.width) // 2, box_px + gap_px), word)
    return canvas


def flatten(img: Image.Image, background: tuple[int, int, int]) -> Image.Image:
    out = Image.new("RGB", img.size, background)
    out.paste(img, (0, 0), img)
    return out


def bgrx(img: Image.Image) -> bytes:
    """RGB -> the XRGB8888 little-endian byte order a DRM dumb buffer expects: B, G, R, pad."""
    b, g, r = img.getchannel("B"), img.getchannel("G"), img.getchannel("R")
    pad = Image.new("L", img.size, 0)
    return Image.merge("RGBA", (b, g, r, pad)).tobytes()


def build_sprites(theme: Path, output: Path) -> None:
    """Emit the tile container for every scale in SPRITE_SCALES."""
    records: list[tuple[int, int, int, int, int, int]] = []
    blobs: list[bytes] = []

    for scale in SPRITE_SCALES:
        factor = scale / ASSET_ZOOM

        block = compose_block(theme, scale, BG)
        records.append((scale, ANCHOR_CENTRE, block.width, block.height, 0, 0))
        blobs.append(bgrx(block))

        # The status fields keep their full, mostly-transparent canvas rather than being
        # cropped to their ink. Each SVG is deliberately over-wide with the text anchored to
        # the edge that field aligns to (see README), so placing the WHOLE canvas at PAD_X from
        # that edge is what makes the text land in the right place without anyone having to
        # know the font's advance width. Flattened onto the background the surplus is invisible,
        # and at these sizes it costs ~25 KiB.
        pad_x = round(PAD_X * scale)
        pad_y = round(PAD_Y * scale)

        left = flatten(load(theme, STATUS_LEFT, factor), BG)
        records.append((scale, ANCHOR_BOTTOM_LEFT, left.width, left.height, pad_x, pad_y))
        blobs.append(bgrx(left))

        right = flatten(load(theme, STATUS_RIGHT, factor), BG)
        records.append((scale, ANCHOR_BOTTOM_RIGHT, right.width, right.height, pad_x, pad_y))
        blobs.append(bgrx(right))

    n = len(records)
    offset = HEADER_BYTES + n * TILE_RECORD_BYTES

    out = bytearray()
    out += MAGIC
    out += struct.pack("<II", (BG[0] << 16) | (BG[1] << 8) | BG[2], n)
    for (scale, anchor, w, h, off_x, off_y), blob in zip(records, blobs):
        out += struct.pack("<7I", scale, anchor, w, h, off_x, off_y, offset)
        offset += len(blob)
    for blob in blobs:
        out += blob

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(bytes(out))
    print(
        f"make-splash-assets: {output} ({n} tiles, scales {','.join(map(str, SPRITE_SCALES))}, "
        f"{len(out) / 1024:.0f} KiB)"
    )


def build_bmp(theme: Path, output: Path, scale: float) -> None:
    # Black, not BG: systemd-stub fills the screen black around the bitmap and a brand-coloured
    # canvas would seam against it. See the module docstring.
    canvas = compose_block(theme, scale, (0, 0, 0))
    output.parent.mkdir(parents=True, exist_ok=True)
    # 24-bit BI_RGB with a 40-byte BITMAPINFOHEADER, which is what Pillow writes for mode RGB
    # and what systemd's bmp_parse_header() accepts. Mode RGB (not RGBA) matters: an alpha
    # channel makes Pillow emit a BITMAPV4 header the stub's parser rejects.
    canvas.save(output, format="BMP")
    print(f"make-splash-assets: {output} ({canvas.width}x{canvas.height}, scale {scale})")


def build_logo(theme: Path, output: Path, scale: float) -> None:
    """The installer's sidebar logo (plan/16).

    A third consumer of compose_block(), and it is here rather than in a new script for the same
    reason the other two share it: Calamares' sidebar sits next to a boot the user watched sixty
    seconds ago, so the two have to be the same block of pixels, not two drawings of one logo
    that drift apart the first time either is touched.

    Flattened onto BG (--surface-sunken) rather than left transparent, and the Calamares branding
    sets SidebarBackground to the same value — so the PNG has no visible edge against the sidebar
    at any scale, and no alpha for a Qt style to composite differently than expected.
    """
    canvas = compose_block(theme, scale, BG)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG")
    print(f"make-splash-assets: {output} ({canvas.width}x{canvas.height}, scale {scale})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--asset-dir", required=True, type=Path, help="where the rasterised PNGs are")
    ap.add_argument("--bmp", type=Path, help="write the systemd-stub .splash bitmap here")
    ap.add_argument("--sprites", type=Path, help="write the KMS splash tile container here")
    ap.add_argument("--logo", type=Path, help="write the installer's branding logo PNG here")
    ap.add_argument(
        "--logo-scale",
        type=float,
        default=0.5,
        help="--logo only: scale of the composed block, 1 = the 1080p design baseline. "
        "0.5 keeps the mark inside Calamares' 190px sidebar without upscaling.",
    )
    ap.add_argument(
        "--scale",
        type=float,
        default=1.0,
        help="--bmp only: effective scale, 1 = the 1080p design baseline (SPLASH_STUB_SCALE)",
    )
    args = ap.parse_args()

    if not args.bmp and not args.sprites and not args.logo:
        sys.exit("make-splash-assets: nothing to do — pass --bmp, --sprites and/or --logo")
    if args.scale <= 0:
        sys.exit("make-splash-assets: --scale must be positive")
    if args.logo_scale <= 0:
        sys.exit("make-splash-assets: --logo-scale must be positive")

    if args.sprites:
        build_sprites(args.asset_dir, args.sprites)
    if args.bmp:
        build_bmp(args.asset_dir, args.bmp, args.scale)
    if args.logo:
        build_logo(args.asset_dir, args.logo, args.logo_scale)


if __name__ == "__main__":
    main()
