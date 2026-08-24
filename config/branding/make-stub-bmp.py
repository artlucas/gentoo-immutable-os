#!/usr/bin/env python3
"""Compose the systemd-stub .splash bitmap from the rasterised Plymouth theme assets.

Run by stage 40 when SPLASH_BACKEND includes the stub. Inputs are the PNGs install_branding()
has already written into the theme directory, so the stub image and the Plymouth theme can
never drift apart: there is one set of sources and one rasterisation.

Two facts about systemd-stub drive every decision here (src/boot/splash.c, v260):

  * It fills the ENTIRE screen with a flat background first, then blits the bitmap centred.
    That background is hardcoded black — `EFI_GRAPHICS_OUTPUT_BLT_PIXEL background = {}`, with
    a light grey special case for Apple firmware and nothing else. So this canvas is painted
    pure black rather than the design system's #0a0d11 (--surface-sunken) that the Plymouth
    theme uses: a canvas in the brand colour would show up as a visible rectangle seam against
    the stub's black fill. The two differ by RGB(10,13,17); the seam would be worse.

  * It does NOT scale. `x_pos = (HorizontalResolution - dib->x) / 2` and the equivalent for y,
    and a bitmap larger than the screen is drawn from the origin and clipped. There is no
    resolution to query at build time, hence the explicit --scale.

The layout is the one in distro.script.in, evaluated once with every slab at DIM — the fully
faded-out end of that theme's (inverted) pulse. The wordmark is NOT dimmed: it is not part of
the animation there either, so fading it would invent a state the theme never draws.

Geometry is identical to the theme's, so with SPLASH_BACKEND=both nothing MOVES at the hand-off
from the stub image to plymouthd, provided --scale matches the panel. Brightness does change,
and by design: the stub frame is the mark at its darkest, and plymouthd — whose inverted curve
rests fully lit — takes over by lighting it. Note that this is a jump, not a fade. The stub
image dies at the first modeset and plymouthd starts on its own clock; there is no shared
timeline the two could be cross-faded along, so `both` reads as a dim mark that snaps lit once
DRM is up, rather than as one continuous animation.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - the builder installs dev-python/pillow explicitly
    sys.exit("make-stub-bmp: Pillow not available — is dev-python/pillow in builder/Dockerfile?")

# Geometry, in design pixels at the 1920x1080 baseline. These MUST track distro.script.in;
# they are the same three constants that file declares at the top.
MARK_BOX = 132  # the logomark's layout box
GAP = 34  # logomark box -> wordmark
ASSET_ZOOM = 4  # BRANDING_ZOOM in lib/common.sh: what the PNGs were rasterised at

SLABS = ("slab-top.png", "slab-mid.png", "slab-bot.png")
WORDMARK = "wordmark.png"

# ---- slab shading -------------------------------------------------------------------------
# The slab SVGs carry their 3D shading as polygon `opacity`, identical in all three files:
#
#     top face (the rhombus)  opacity 0.6   -> baked alpha 153
#     front-left face         opacity 1.0   -> baked alpha 255
#     front-right face        opacity 0.82  -> baked alpha 209
#
# That works for the Plymouth theme, which multiplies a whole-slab SetOpacity() over it and is
# in motion the entire time. It does NOT work for a single static frame: the top face is by far
# the largest surface (~15.5k px against ~6.4k for either side), so at 60% alpha over black the
# broadest part of the mark is also its dimmest — the shading runs backwards, brightest on the
# faces turned away from the light. That is a different complaint from "the mark is dark", which
# is what DIM below deliberately makes it: this one is about the faces being wrong RELATIVE to
# each other, and it survives any uniform dimming applied on top of it.
#
# So the static bitmap re-shades: the same three faces, but the shading is carried in COLOUR at
# full opacity instead of in alpha. The top face — the one facing the light — takes the accent
# value undiminished and the two sides step down from it, which is the way a lit solid actually
# reads. Simply forcing every face to full opacity was the other option and is worse: all three
# polygons share one fill, so they merge into a flat hexagon and the slab stops being a slab.
#
# These constants track the SVGs the same way MARK_BOX/GAP track distro.script.in. Change the
# polygon opacities there and the BAKED values here have to follow, or the faces stop being
# recognised and fall back to whichever is nearest.
TEAL = (0x0E, 0x9C, 0x8A)  # --accent, the fill every polygon uses
BAKED_TOP, BAKED_LEFT, BAKED_RIGHT = 153, 255, 209
FACE_SHADE = {BAKED_TOP: 1.00, BAKED_LEFT: 0.82, BAKED_RIGHT: 0.66}

# ---- fade level ----------------------------------------------------------------------------
# distro.script.in's DIM, and it has to stay equal to it: that file animates the slabs between
# DIM and 1.0, and this one paints the DIM end as a still. Tracked the same way MARK_BOX and GAP
# track the theme's geometry.
#
# Applied to COLOUR rather than to alpha, which is exact here and not merely close: the canvas
# below is pure black because systemd-stub's own fill is (splash.c), and compositing a source
# over black yields src*alpha — so scaling the colour by DIM and scaling the alpha by DIM
# produce identical bytes. Colour is the one that survives the re-shade: the LUT has already
# spent alpha on making the faces opaque, and taking it back would undo that.
DIM = 0.20


def reshade_slab(img: Image.Image) -> Image.Image:
    """Turn the slab's alpha-baked face shading into opaque colour shading, dimmed to DIM.

    The re-shade still earns its keep even though the result is dark: it is what keeps the
    three faces distinguishable. Dimming the ORIGINAL alpha instead would take the top face to
    0.6 * DIM and the sides to 1.0 * DIM and 0.82 * DIM, i.e. it would compress the shading
    towards nothing at the same time as it darkens — and the slab would read as a flat, muddy
    hexagon. Here the face relationships are held in colour and DIM scales all three equally.

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
        lut_r.append(round(TEAL[0] * shade * DIM))
        lut_g.append(round(TEAL[1] * shade * DIM))
        lut_b.append(round(TEAL[2] * shade * DIM))
    lut_r[0] = lut_g[0] = lut_b[0] = lut_a[0] = 0  # fully transparent stays fully transparent

    alpha = img.getchannel("A")
    return Image.merge(
        "RGBA",
        (alpha.point(lut_r), alpha.point(lut_g), alpha.point(lut_b), alpha.point(lut_a)),
    )


def load(theme: Path, name: str, factor: float) -> Image.Image:
    path = theme / name
    if not path.is_file():
        sys.exit(f"make-stub-bmp: missing theme asset {path}")
    img = Image.open(path).convert("RGBA")
    w = max(1, round(img.width * factor))
    h = max(1, round(img.height * factor))
    return img.resize((w, h), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--theme-dir", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument(
        "--scale",
        type=float,
        default=1.0,
        help="effective scale, same units as the theme's `scale` (1 = the 1080p baseline)",
    )
    args = ap.parse_args()

    if args.scale <= 0:
        sys.exit("make-stub-bmp: --scale must be positive")

    factor = args.scale / ASSET_ZOOM
    # Re-shade before scaling: the LUT keys off exact baked alpha values, and resampling
    # blends them into intermediates that would no longer identify a face.
    slabs = [reshade_slab(load(args.theme_dir, n, 1.0)) for n in SLABS]
    slabs = [
        s.resize((max(1, round(s.width * factor)), max(1, round(s.height * factor))), Image.LANCZOS)
        for s in slabs
    ]
    word = load(args.theme_dir, WORDMARK, factor)

    # Same column the theme builds: [logomark box] + [gap] + [wordmark line box], centred.
    box_px = round(MARK_BOX * args.scale)
    gap_px = round(GAP * args.scale)
    mark_w = max(s.width for s in slabs)
    mark_h = max(s.height for s in slabs)

    width = max(mark_w, word.width)
    height = box_px + gap_px + word.height

    canvas = Image.new("RGB", (width, height), (0, 0, 0))

    # The three slabs sit in register on an identical canvas, all at DIM — the theme's pulse is
    # an opacity animation over these same images, and DIM is the faded-out end it swings to.
    mark_y = (box_px - mark_h) // 2
    for slab in slabs:
        canvas.paste(slab, ((width - slab.width) // 2, mark_y), slab)

    canvas.paste(word, ((width - word.width) // 2, box_px + gap_px), word)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    # 24-bit BI_RGB with a 40-byte BITMAPINFOHEADER, which is what Pillow writes for mode RGB
    # and what systemd's bmp_parse_header() accepts. Mode RGB (not RGBA) matters: an alpha
    # channel makes Pillow emit a BITMAPV4 header the stub's parser rejects.
    canvas.save(args.output, format="BMP")
    print(f"make-stub-bmp: {args.output} ({width}x{height}, scale {args.scale}, slabs at {DIM:.0%})")


if __name__ == "__main__":
    main()
