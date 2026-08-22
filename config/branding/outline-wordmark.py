#!/usr/bin/env python3
"""Convert the Immos wordmark to SVG outlines. One-time developer step; output committed.

Reproduces the design system's Boot splash wordmark:
  font-family: Archivo (700), font-size: 46px, letter-spacing: -0.02em, line-height: 1,
  color: #f6f7f9 (--text-strong, dark theme).
Glyphs become <path> data so no font is needed at build or run time.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.misc.transform import Transform

TTF, TEXT, SIZE, TRACK_EM, FILL = sys.argv[1], "immos", 46.0, -0.02, "#f6f7f9"

font = TTFont(TTF)
upem = font["head"].unitsPerEm
gs = font.getGlyphSet()
cmap = font.getBestCmap()
hmtx = font["hmtx"]
hhea = font["hhea"]

s = SIZE / upem
track = SIZE * TRACK_EM                      # px added after every char, CSS letter-spacing

# CSS line-height:1 -> line box is exactly SIZE tall; half-leading centres the font's
# natural line height (ascent + descent + lineGap) inside it.
nat = (hhea.ascent - hhea.descent + hhea.lineGap) * s
baseline = (SIZE - nat) / 2 + hhea.ascent * s

paths, x, ink = [], 0.0, [None] * 4          # ink = xmin,ymin,xmax,ymax in px
for ch in TEXT:
    gname = cmap[ord(ch)]
    # y-flip: font units are y-up, SVG is y-down, so scale y by -s about the baseline
    t = Transform(s, 0, 0, -s, x, baseline)
    pen = SVGPathPen(gs, ntos=lambda v: f"{v:.2f}")
    gs[gname].draw(TransformPen(pen, t))
    d = pen.getCommands()
    if d:
        paths.append(d)
    bp = BoundsPen(gs)
    gs[gname].draw(TransformPen(bp, t))
    if bp.bounds:
        b = bp.bounds
        ink = [min(ink[0], b[0]) if ink[0] is not None else b[0],
               min(ink[1], b[1]) if ink[1] is not None else b[1],
               max(ink[2], b[2]) if ink[2] is not None else b[2],
               max(ink[3], b[3]) if ink[3] is not None else b[3]]
    x += hmtx[gname][0] * s + track

width = round(x, 2)                          # includes the trailing letter-space, as CSS does
print(f"upem={upem} advance_width={width} baseline={baseline:.2f} ink={ink}", file=sys.stderr)
if ink[1] < -0.01 or ink[3] > SIZE + 0.01:
    print(f"WARNING: ink {ink[1]:.2f}..{ink[3]:.2f} overflows the {SIZE}px line box",
          file=sys.stderr)

out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{SIZE:g}"'
       f' viewBox="0 0 {width} {SIZE:g}" role="img" aria-label="{TEXT}">',
       f'  <g fill="{FILL}">']
out += [f'    <path d="{d}"/>' for d in paths]
out += ["  </g>", "</svg>", ""]
sys.stdout.write("\n".join(out))
