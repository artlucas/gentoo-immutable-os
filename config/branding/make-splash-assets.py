#!/usr/bin/env python3
"""Compose every branding artefact from the rasterised PNGs and the slab SVGs.

Run by stage 40, after the rasterise pass, emitting whichever outputs were asked for:

  --bmp       the systemd-stub `.splash` bitmap, blitted by the firmware-stage stub before the
              kernel starts. Covers firmware -> first modeset.
  --sprites   the tile container read by config/splash/splash.c, which draws on DRM from the
              first modeset to the greeter.
  --logo      the Calamares sidebar logo (plan/16).
  --slide     the Calamares progress-page slide (plan/16).
  --theme     the Plasma splash theme's contents (plan/17): the vectors and the design
              constants the QML that runs at login lays itself out with.

They are produced by ONE script from ONE set of sources on purpose. The pieces meet on screen
at two hand-offs — the first modeset, and the login that follows it — and any drift in geometry,
shading or brightness between them shows up exactly there, as a jump. There is one layout
function, build_block(), and every raster consumer calls it.

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

THE BLOCK IS DRAWN AT FULL BRIGHTNESS in every output, and the layer-pulse animation departs
from that frame rather than resting somewhere below it (plan/17). That is what lets the stub
bitmap, the KMS splash's first frame and the Plasma splash's settled frame be the same picture:
the animation is a dip and a recovery, so "everything at full" is a real frame of the loop and
not merely the brightest one. It is also why `DIM = 0.20` — which existed to match plymouth's
pulse resting at the faded end of its curve — is not coming back.
"""

from __future__ import annotations

import argparse
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - the builder installs dev-python/pillow explicitly
    sys.exit("make-splash-assets: Pillow not available — is dev-python/pillow in builder/Dockerfile?")

# Geometry, in design pixels at the 1920x1080 baseline. Authored in the design system and
# duplicated nowhere else — this file is the only place the layout is stated, and the Plasma
# theme reads these numbers out of the generated container rather than restating them.
MARK_BOX = 132  # the logomark's layout box
GAP = 34  # logomark box -> wordmark
PAD_X = 40  # status bar inset from the left/right screen edge
PAD_Y = 28  # status bar inset from the bottom screen edge
ASSET_ZOOM = 4  # BRANDING_ZOOM in lib/common.sh: what the PNGs were rasterised at

SLABS = ("slab-top.png", "slab-mid.png", "slab-bot.png")
WORDMARK = "wordmark.png"
STATUS_LEFT = "status-left.png"
STATUS_RIGHT = "status-right.png"

# --surface-sunken, dark theme: what splash.c fills the screen with, what the Plasma splash
# paints its window with, and what the sprite tiles are composited over so their antialiased
# edges land exactly on it.
BG = (0x0A, 0x0D, 0x11)

# The scales the sprite container carries. splash.c picks 2 for panels 2000px tall or more and
# 1 otherwise, falling back sensibly if a scale is missing — so this list is a size/coverage
# tradeoff, not a correctness one.
SPRITE_SCALES = (1, 2)

# Container format, read by load_assets() in config/splash/splash.c. Change one, change both.
#
#   0   8   magic "IMSPLSH2"
#   8   4   u32  background, 0x00RRGGBB
#   12  4   u32  tile count
#   16  ..  tile records, 40 bytes each:
#             u32 scale | u32 anchor | u32 flags | u32 w | u32 h
#             u32 box_w | u32 box_h | i32 off_x | i32 off_y | u32 data_offset
#   ..      tile pixels, w*h*4 opaque BGRX rows, in record order
#
# A tile is placed by anchoring its BOX to the screen, and off_x/off_y then mean one of two
# things depending on which anchor:
#
#   ANCHOR_CENTRE        the box is centred on the screen and off_* is where this tile sits
#                        INSIDE it. The four pieces the block is cut into share the block as
#                        their box; a whole picture is its own box at offset 0,0.
#   ANCHOR_BOTTOM_*      the box IS the tile, and off_* is its INSET from the screen edges.
#
# The indirection exists for the first case, and it is what makes the pieces land back exactly
# where the flat block had them: centring a 130px slab band and centring the 144px block it
# belongs to are not the same rounding, and the difference would be a visible pixel of jitter
# between the stub bitmap and the frame that replaces it.
#
# v1 -> v2: the record grew the flags, box_w and box_h words, and off_x/off_y became signed.
# The magic is bumped rather than reused because a v1 reader would draw all four pieces of the
# block centred on top of one another and call it a splash.
MAGIC = b"IMSPLSH2"
HEADER_BYTES = 16
TILE_RECORD_BYTES = 40

ANCHOR_CENTRE = 0
ANCHOR_BOTTOM_LEFT = 1
ANCHOR_BOTTOM_RIGHT = 2

# flags bit 0: this tile is one of the logomark's slabs and takes part in the layer pulse.
# bits 8..15 carry its slot in the wave — 0 dips first, then 1, then 2.
TILE_PULSE = 0x1
TILE_PULSE_SHIFT = 8

# splash.c's `struct assets` carries a fixed tile array; overflowing it is a container the
# program silently refuses to load, i.e. a black screen from the first modeset to the greeter.
MAX_TILES = 32

# ---- slab shading -------------------------------------------------------------------------
# The slab SVGs carry their 3D shading as polygon `opacity`, identical in all three files:
#
#     top face (the rhombus)  opacity 0.6   -> baked alpha 153
#     front-left face         opacity 1.0   -> baked alpha 255
#     front-right face        opacity 0.82  -> baked alpha 209
#
# Those values were chosen for a splash that multiplied a whole-slab opacity over them and was
# in motion the entire time. They do NOT work for a frame at rest: the top face is by far the
# largest surface (~15.5k px against ~6.4k for either side), so at 60% alpha over the background
# the broadest part of the mark is also its dimmest — the shading runs backwards, brightest on
# the faces turned away from the light. That is still true now that the mark moves again,
# because the layer pulse dips a whole slab at a time and never touches the faces separately.
#
# So the shipped slabs re-shade: the same three faces, but the shading is carried in COLOUR at
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

# The slab SVGs' shared viewBox extent, and the two y values that separate one slab's band from
# the next. The three slabs occupy 6..23, 24..41 and 42..59 of that box, so the midpoints of the
# gaps cut the mark into three strips with one whole slab in each. Cutting on fixed lines rather
# than on measured ink bounds keeps the strips stable across scales and resamplings; that each
# slab really does fall inside its own strip is asserted below rather than assumed.
SLAB_VIEWBOX = 64.0
BAND_EDGES = (23.5, 41.5)

# Alpha at or below this counts as "not ink" when checking a slab against its band. Downsampling
# from the 4x rasterisation with LANCZOS rings: its negative lobes leave a couple of rows of
# alpha 3-4 (1.6%) either side of every hard edge, which reaches across the 1-unit gap between
# slabs and would fail an alpha > 0 test on geometry that is in fact correct. Measured on the
# committed SVGs at both sprite scales, the largest spill past a band edge is alpha 4.
INK_ALPHA = 8

# ---- the layer pulse ------------------------------------------------------------------------
# Shared with config/splash/splash.c and the Plasma theme's Splash.qml, and stated here because
# this is the file both of those read their geometry from. Animation "B · Layer pulse" from the
# design system's Spinner: one slab at a time dims and recovers, the wave travelling up the
# stack, and every slab sits at full brightness the instant the loop begins.
PULSE_CYCLE_MS = 1600
PULSE_DEPTH = 0.55  # a slab dips to 1.0 - PULSE_DEPTH at the bottom of its own pulse
PULSE_SLOTS = 3


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


def shaded_face(opacity: float) -> str:
    """The colour reshade_slab() gives a face whose SVG polygon carries `opacity`.

    The two paths have to agree: the KMS splash draws re-shaded PIXELS and the Plasma splash
    draws re-shaded VECTORS, on screens a user sees ninety seconds apart. Both come from
    FACE_SHADE, and tests/test-splash-assets.sh rasterises the vectors and compares.
    """
    baked = round(opacity * 255)
    face = min(FACE_SHADE, key=lambda f: abs(f - baked))
    shade = FACE_SHADE[face]
    return "#%02x%02x%02x" % tuple(round(c * shade) for c in TEAL)


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


class Block:
    """The centred column, and the pieces it is cut into.

    `image` is the flat picture the stub bitmap, the installer logo and the installer slide all
    ship as-is. `parts` is the same pixels, cut up so the KMS splash can redraw one slab without
    touching the rest — each part is a CROP OF `image`, which is what makes reassembly exact
    rather than approximately right.
    """

    def __init__(self, image: Image.Image, parts: list[tuple[str, Image.Image, int, int, int]]):
        self.image = image
        self.parts = parts  # (name, image, x, y, pulse_slot or -1)

    @property
    def size(self) -> tuple[int, int]:
        return self.image.size


def build_block(theme: Path, scale: float, background: tuple[int, int, int]) -> Block:
    """The centred column: [logomark box] + [gap] + [wordmark], flattened onto `background`.

    This is the single source of the splash's layout. Every raster artefact this script emits is
    this function's output, whole or in pieces; nothing else positions the mark.
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
    mark_w = max(s.width for s in slabs)
    mark_h = max(s.height for s in slabs)

    width = max(mark_w, word.width)
    height = box_px + gap_px + word.height

    canvas = Image.new("RGB", (width, height), background)

    # The three slabs sit in register on an identical canvas.
    mark_x = (width - mark_w) // 2
    mark_y = (box_px - mark_h) // 2
    for slab in slabs:
        canvas.paste(slab, ((width - slab.width) // 2, mark_y), slab)

    word_x = (width - word.width) // 2
    word_y = box_px + gap_px
    canvas.paste(word, (word_x, word_y), word)

    # The mark box, cut into one strip per slab on the fixed lines in BAND_EDGES.
    edges = [0]
    edges += [round(e / SLAB_VIEWBOX * mark_h) for e in BAND_EDGES]
    edges.append(mark_h)

    parts: list[tuple[str, Image.Image, int, int, int]] = []
    for i, name in enumerate(SLABS):
        top, bottom = edges[i], edges[i + 1]
        if bottom <= top:
            sys.exit(f"make-splash-assets: slab band {name} is empty at scale {scale} — is the "
                     f"mark box ({mark_h}px) too small for {len(SLABS)} bands?")
        # Each slab must be entirely inside its own strip, or the pulse would animate half of
        # one slab together with half of the next. This is the assertion that keeps BAND_EDGES
        # honest if the slab SVGs are ever redrawn.
        ink = slabs[i].getchannel("A").point(lambda v: 255 if v > INK_ALPHA else 0).getbbox()
        if ink is None:
            sys.exit(f"make-splash-assets: {name} rasterised to nothing — did rsvg-convert find it?")
        if ink[1] < top or ink[3] > bottom:
            sys.exit(f"make-splash-assets: {name}'s ink spans rows {ink[1]}..{ink[3]} but its band "
                     f"is {top}..{bottom} at scale {scale}. BAND_EDGES no longer matches the SVGs.")
        crop = canvas.crop((mark_x, mark_y + top, mark_x + mark_w, mark_y + bottom))
        # Slot 0 dips first and the wave travels up the stack, so the BOTTOM slab leads. SLABS
        # is ordered top, mid, bot.
        parts.append((name, crop, mark_x, mark_y + top, len(SLABS) - 1 - i))

    parts.append((WORDMARK, canvas.crop((word_x, word_y, word_x + word.width, word_y + word.height)),
                  word_x, word_y, -1))

    return Block(canvas, parts)


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
    records: list[tuple[int, int, int, int, int, int, int, int, int]] = []
    blobs: list[bytes] = []

    for scale in SPRITE_SCALES:
        factor = scale / ASSET_ZOOM

        block = build_block(theme, scale, BG)
        bw, bh = block.size
        for name, img, x, y, slot in block.parts:
            flags = 0 if slot < 0 else (TILE_PULSE | (slot << TILE_PULSE_SHIFT))
            records.append((scale, ANCHOR_CENTRE, flags, img.width, img.height, bw, bh, x, y))
            blobs.append(bgrx(img))

        # The status fields keep their full, mostly-transparent canvas rather than being
        # cropped to their ink. Each SVG is deliberately over-wide with the text anchored to
        # the edge that field aligns to (see README), so placing the WHOLE canvas at PAD_X from
        # that edge is what makes the text land in the right place without anyone having to
        # know the font's advance width. Flattened onto the background the surplus is invisible.
        # These are their own box: nothing is cut out of them, so box == tile and offset == the
        # inset from the screen edge.
        pad_x = round(PAD_X * scale)
        pad_y = round(PAD_Y * scale)

        left = flatten(load(theme, STATUS_LEFT, factor), BG)
        records.append((scale, ANCHOR_BOTTOM_LEFT, 0, left.width, left.height,
                        left.width, left.height, pad_x, pad_y))
        blobs.append(bgrx(left))

        right = flatten(load(theme, STATUS_RIGHT, factor), BG)
        records.append((scale, ANCHOR_BOTTOM_RIGHT, 0, right.width, right.height,
                        right.width, right.height, pad_x, pad_y))
        blobs.append(bgrx(right))

    n = len(records)
    if n > MAX_TILES:
        sys.exit(f"make-splash-assets: {n} tiles exceeds the {MAX_TILES} splash.c can hold — "
                 f"raise MAX_TILES there and here together, or carry fewer scales")
    offset = HEADER_BYTES + n * TILE_RECORD_BYTES

    out = bytearray()
    out += MAGIC
    out += struct.pack("<II", (BG[0] << 16) | (BG[1] << 8) | BG[2], n)
    for rec, blob in zip(records, blobs):
        scale, anchor, flags, w, h, box_w, box_h, off_x, off_y = rec
        out += struct.pack("<7Iii", scale, anchor, flags, w, h, box_w, box_h, off_x, off_y)
        out += struct.pack("<I", offset)
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
    canvas = build_block(theme, scale, (0, 0, 0)).image
    output.parent.mkdir(parents=True, exist_ok=True)
    # 24-bit BI_RGB with a 40-byte BITMAPINFOHEADER, which is what Pillow writes for mode RGB
    # and what systemd's bmp_parse_header() accepts. Mode RGB (not RGBA) matters: an alpha
    # channel makes Pillow emit a BITMAPV4 header the stub's parser rejects.
    canvas.save(output, format="BMP")
    print(f"make-splash-assets: {output} ({canvas.width}x{canvas.height}, scale {scale})")


def build_logo(theme: Path, output: Path, scale: float) -> None:
    """The installer's sidebar logo (plan/16).

    Another consumer of build_block(), and it is here rather than in a new script for the same
    reason the others share it: Calamares' sidebar sits next to a boot the user watched sixty
    seconds ago, so the two have to be the same block of pixels, not two drawings of one logo
    that drift apart the first time either is touched.

    Flattened onto BG (--surface-sunken) rather than left transparent, and the Calamares branding
    sets SidebarBackground to the same value — so the PNG has no visible edge against the sidebar
    at any scale, and no alpha for a Qt style to composite differently than expected.
    """
    canvas = build_block(theme, scale, BG).image
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG")
    print(f"make-splash-assets: {output} ({canvas.width}x{canvas.height}, scale {scale})")


def build_slide(theme: Path, output: Path, scale: float, size: tuple[int, int]) -> None:
    """The installer's progress-page slide (plan/16).

    The only consumer that needs a CANVAS rather than a tight block: Calamares' SlideshowPictures
    draws the image with QLabel::setPixmap and does not scale it (Slideshow.cpp:280), so the file
    has to arrive at roughly the size it will occupy. 640x360 sits inside the content area of the
    900x600 window the branding asks for, with the sidebar's 190px taken off, and stays centred
    if the user maximises.

    Painted on BG, the same --surface-sunken the sidebar and the boot splash use, so it reads as
    a deliberate brand panel rather than as a stray dark rectangle on the page background.
    """
    block = build_block(theme, scale, BG).image
    canvas = Image.new("RGB", size, BG)
    canvas.paste(block, ((size[0] - block.width) // 2, (size[1] - block.height) // 2))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG")
    print(f"make-splash-assets: {output} ({canvas.width}x{canvas.height}, block scale {scale})")


# ---- the Plasma splash theme's images --------------------------------------------------------

def reshade_svg(src: Path, dst: Path) -> None:
    """Rewrite one slab SVG with its shading carried in colour instead of in opacity.

    The vector twin of reshade_slab(). The Plasma splash animates each slab's opacity in QML, so
    it needs slabs whose own alpha is 1 everywhere the ink is — otherwise the theme would be
    multiplying its animation over the SVG's baked face opacities and the faces would drift
    apart as the slab dimmed, which is precisely the "shading runs backwards" failure the raster
    path re-shades to avoid.

    Done by transforming the committed SVG rather than by writing a new one, so the geometry has
    exactly one source and a change to the mark cannot reach one splash and not the other.
    """
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    tree = ET.parse(src)
    root = tree.getroot()
    touched = 0
    for el in root.iter():
        if not el.tag.endswith("}polygon") and el.tag != "polygon":
            continue
        # No opacity attribute means the face is already opaque, i.e. the front-left face.
        el.set("fill", shaded_face(float(el.get("opacity", "1"))))
        el.attrib.pop("opacity", None)
        touched += 1
    if touched == 0:
        sys.exit(f"make-splash-assets: {src} has no <polygon> to re-shade — has the mark changed?")
    # The fill lives on the parent <g> in the source; a per-polygon fill overrides it, but
    # leaving it would be a second colour statement that silently stops mattering.
    for el in root.iter():
        if (el.tag.endswith("}g") or el.tag == "g") and "fill" in el.attrib:
            del el.attrib["fill"]
    dst.parent.mkdir(parents=True, exist_ok=True)
    tree.write(dst, encoding="unicode", xml_declaration=False)
    dst.write_text(dst.read_text().rstrip() + "\n", encoding="utf-8")


def svg_size(path: Path) -> tuple[float, float]:
    """The width/height an SVG declares, which is what rsvg-convert rasterises it at."""
    root = ET.parse(path).getroot()
    try:
        return float(root.get("width")), float(root.get("height"))
    except (TypeError, ValueError):
        sys.exit(f"make-splash-assets: {path} has no numeric width/height for the theme to size by")


def build_theme(svg_dir: Path, output: Path) -> None:
    """The Plasma splash theme's contents (plan/17): images/*.svg and Design.qml.

    Vectors, not the raster tiles the KMS splash uses, and the reason is that the two splashes
    have opposite constraints. splash.c runs before there is a font, an image decoder or a
    toolkit, so it gets pre-composited pixels; ksplashqml runs inside a Qt session that already
    has QtSvg, so it gets the outlines and stays crisp on a panel of any size and any scale
    factor without the container carrying a tile for each one.

    Design.qml carries the layout and animation constants rather than the QML restating them.
    That is the same discipline the raster half follows by reading its offsets out of the
    container: MARK_BOX, GAP and the pulse timings are stated once, in this file, and a theme
    that hardcoded them would go on rendering perfectly after the design changed — just not the
    same picture as the boot splash it takes over from.
    """
    images = output / "images"
    images.mkdir(parents=True, exist_ok=True)

    names = []
    for slab in SLABS:
        stem = slab[: -len(".png")]
        src = svg_dir / f"{stem}.svg"
        if not src.is_file():
            sys.exit(f"make-splash-assets: missing slab source {src}")
        reshade_svg(src, images / f"{stem}.svg")
        names.append(f"{stem}.svg")

    word_src = svg_dir / "wordmark.svg"
    if not word_src.is_file():
        sys.exit(f"make-splash-assets: missing {word_src}")
    # Copied rather than transformed: the wordmark is already outlined paths at a flat fill, so
    # there is nothing to re-shade and nothing a copy can get wrong.
    (images / "wordmark.svg").write_text(word_src.read_text(encoding="utf-8"), encoding="utf-8")
    names.append("wordmark.svg")

    slab_w, slab_h = svg_size(svg_dir / f"{SLABS[0][:-len('.png')]}.svg")
    word_w, word_h = svg_size(word_src)

    design = output / "Design.qml"
    design.write_text(f"""// GENERATED by config/branding/make-splash-assets.py --theme. Do not edit.
//
// The design-system constants the boot splash is composed with, handed to the QML so the two
// splashes are one drawing seen at two moments rather than two drawings of one logo that drift.
// Sibling .qml files in a package directory are types without an import, so Splash.qml just
// says `Design {{ id: design }}`.
import QtQuick

QtObject {{
    // Design pixels at the 1920x1080 baseline: everything here is multiplied by
    // screenHeight / baselineHeight, which is exactly how splash.c picks its sprite scale.
    readonly property real baselineHeight: 1080
    readonly property real markBox: {MARK_BOX}
    readonly property real gap: {GAP}

    // The rasterisable size the SVGs declare. The mark is centred inside markBox rather than
    // filling it, and the wordmark sets the block's width.
    readonly property real slabWidth: {slab_w:g}
    readonly property real slabHeight: {slab_h:g}
    readonly property real wordmarkWidth: {word_w:g}
    readonly property real wordmarkHeight: {word_h:g}

    // Animation "B · Layer pulse". splash.c runs this identical curve on the frame before this
    // one, so a change here is a change there.
    readonly property int pulseCycleMs: {PULSE_CYCLE_MS}
    readonly property real pulseDepth: {PULSE_DEPTH}
    readonly property int pulseSlots: {PULSE_SLOTS}

    // --surface-sunken. The same value splash.c fills the screen with.
    readonly property color background: "#{BG[0]:02x}{BG[1]:02x}{BG[2]:02x}"
}}
""", encoding="utf-8")

    print(f"make-splash-assets: {output} ({', '.join(names)}, Design.qml)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--asset-dir", type=Path, help="where the rasterised PNGs are")
    ap.add_argument("--svg-dir", type=Path, help="where the branding SVG sources are (--theme)")
    ap.add_argument("--bmp", type=Path, help="write the systemd-stub .splash bitmap here")
    ap.add_argument("--sprites", type=Path, help="write the KMS splash tile container here")
    ap.add_argument("--logo", type=Path, help="write the installer's branding logo PNG here")
    ap.add_argument("--slide", type=Path, help="write the installer's progress-page slide here")
    ap.add_argument("--theme", type=Path,
                    help="write the Plasma splash theme's generated contents (images/ and "
                         "Design.qml) into here")
    ap.add_argument(
        "--slide-size",
        default="640x360",
        help="--slide only: canvas size WxH. Calamares does not scale the slide, so this is "
        "the size it occupies on the progress page.",
    )
    ap.add_argument(
        "--logo-scale",
        type=float,
        default=1.0,
        help="--logo only: scale of the composed block, 1 = the 1080p design baseline. "
        "Sized for HiDPI: Calamares draws the logo into a fixed 80x80 box and asks for the "
        "pixmap at size * devicePixelRatio, so a 2x panel wants ~160px of source height.",
    )
    ap.add_argument(
        "--scale",
        type=float,
        default=1.0,
        help="--bmp only: effective scale, 1 = the 1080p design baseline (SPLASH_STUB_SCALE)",
    )
    args = ap.parse_args()

    raster = (args.bmp, args.sprites, args.logo, args.slide)
    if not any(raster) and not args.theme:
        sys.exit("make-splash-assets: nothing to do — pass --bmp, --sprites, --logo, --slide "
                 "and/or --theme")
    if any(raster) and not args.asset_dir:
        sys.exit("make-splash-assets: --asset-dir is required for the raster outputs")
    if args.theme and not args.svg_dir:
        sys.exit("make-splash-assets: --theme needs --svg-dir (the branding SVG sources)")
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
    if args.slide:
        try:
            w, h = (int(v) for v in args.slide_size.lower().split("x", 1))
        except ValueError:
            sys.exit(f"make-splash-assets: --slide-size must be WxH, got {args.slide_size!r}")
        if w < 1 or h < 1:
            sys.exit("make-splash-assets: --slide-size must be positive")
        build_slide(args.asset_dir, args.slide, args.logo_scale, (w, h))
    if args.theme:
        build_theme(args.svg_dir, args.theme)


if __name__ == "__main__":
    main()
