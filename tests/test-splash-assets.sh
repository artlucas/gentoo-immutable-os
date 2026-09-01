#!/usr/bin/env bash
# The boot splash is the one thing in this image no automated test can look at: stage 70
# reads a serial port, so a splash that renders nothing still reports green. These are the
# checks that CAN be made offline — that the sources and the generator still refer to each
# other, that the templates render, that the container the splash program reads is well-formed,
# and that the one cmdline token wiring the whole switch together is spelled the same in all
# three places that write it.
export TEST_FILE_NAME=test-splash-assets
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort
load_config

SRC="$REPO_ROOT/config/branding"
GEN="$SRC/make-splash-assets.py"
UNIT="$REPO_ROOT/config/rootfs/usr/lib/systemd/system/distro-splash.service.in"
RULE="$REPO_ROOT/config/rootfs/usr/lib/udev/rules.d/70-distro-splash.rules.in"
STAGE40="$REPO_ROOT/scripts/stages/40-configure.sh"

# same render environment stage 40 exports for the branding templates
SPLASH_STATUS_LEFT="$(printf '%s · V%s · AMD64' "$UPDATE_CHANNEL" "$VERSION" | tr '[:lower:]' '[:upper:]')"
export DISTRO_ID DISTRO_NAME VERSION UPDATE_CHANNEL SPLASH_STATUS_LEFT

# ---- the generator and its sources must still refer to each other -------------------------
# The classic way this breaks is renaming an asset and forgetting the generator (or the
# reverse); both halves fail silently, at boot, on a screen no test looks at.
mapfile -t WANTED < <(grep -oE '"[a-z-]+\.png"' "$GEN" | tr -d '"' | sed 's/\.png$//' | sort -u)
mapfile -t HAVE   < <(find "$SRC" -maxdepth 1 \( -name '*.svg' -o -name '*.svg.in' \) -printf '%f\n' \
                      | sed -E 's/\.svg(\.in)?$//' | sort -u)
assert_true "the generator names at least one asset" test "${#WANTED[@]}" -gt 0
for a in "${WANTED[@]}"; do
    assert_true "asset '$a' used by the generator has an SVG source" \
        test -f "$SRC/$a.svg" -o -f "$SRC/$a.svg.in"
done
for a in "${HAVE[@]}"; do
    assert_true "SVG source '$a' is actually used by the generator" \
        grep -qF "\"$a.png\"" "$GEN"
done

# ---- the asset zoom is written in two files and they must agree ---------------------------
# common.sh rasterises at BRANDING_ZOOM; the generator divides by ASSET_ZOOM. Changing one
# alone resizes the whole splash and nothing complains.
gen_zoom="$(sed -nE 's/^ASSET_ZOOM *= *([0-9]+).*/\1/p' "$GEN")"
assert_eq "$BRANDING_ZOOM" "$gen_zoom" "BRANDING_ZOOM matches the generator's ASSET_ZOOM"

# ---- templates render cleanly -------------------------------------------------------------
for t in "$SRC"/*.in; do
    out="$TMP/$(render_dest_name "$(basename -- "$t")")"
    if render_template "$t" "$out"; then _pass; else _fail "render_template failed on $t"; fi
    assert_false "no unresolved tokens in $(basename -- "$out")" \
        grep -qE '@[A-Z][A-Z0-9_]*@' "$out"
done
assert_true "status line carries the version" \
    grep -q "V$VERSION" "$TMP/status-left.svg"
assert_true "status line is uppercased" \
    grep -qE '>[A-Z0-9 ·.]+<' "$TMP/status-left.svg"

# ---- the cmdline token is written in three places and they must agree ---------------------
# The unit disables itself on "<id>.splash=0"; stage 40 puts that token on the UKI cmdline for
# SPLASH_BACKEND=stub and =none; the udev rule names the unit that carries the condition. A
# mismatch fails in the direction nobody notices — the splash draws in the modes that asked for
# no splash, and the build says nothing.
render_template "$UNIT" "$TMP/$DISTRO_ID-splash.service"
render_template "$RULE" "$TMP/70-$DISTRO_ID-splash.rules"
assert_true "the unit disables itself on the branded cmdline token" \
    grep -qx "ConditionKernelCommandLine=!$DISTRO_ID.splash=0" "$TMP/$DISTRO_ID-splash.service"
assert_true "the unit runs the branded splash binary" \
    grep -qx "ExecStart=/usr/bin/$DISTRO_ID-splash" "$TMP/$DISTRO_ID-splash.service"
assert_true "the udev rule starts the unit the condition is on" \
    grep -q "$DISTRO_ID-splash.service" "$TMP/70-$DISTRO_ID-splash.rules"
assert_true "the udev rule only matches modesetting cards, not render nodes" \
    grep -q 'KERNEL=="card\[0-9\]\*"' "$TMP/70-$DISTRO_ID-splash.rules"
assert_true "stage 40 emits the same token the unit tests for" \
    grep -q 'SPLASH_TOKENS+=("$DISTRO_ID.splash=0")' "$STAGE40"
# ...and it must be emitted for exactly the two backends that mean "no KMS splash". Written as
# a check on the case arms rather than on the token so that adding a fifth backend without
# deciding what it does here fails the suite.
assert_true "stage 40 disables the splash for stub and none only" \
    grep -qE '^  stub\|none\) SPLASH_TOKENS\+=' "$STAGE40"

# ---- every SVG must be well-formed, or rsvg-convert emits an empty PNG at build time ------
if command -v python3 >/dev/null 2>&1; then
    for f in "$SRC"/*.svg "$TMP"/*.svg; do
        [[ -f $f ]] || continue
        assert_true "well-formed XML: $(basename -- "$f")" \
            python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$f"
    done
else
    echo "  (python3 absent — skipping XML well-formedness checks)"
fi

# ---- render_branding must survive `set -e` ------------------------------------------------
# Stages run with `set -euo pipefail`, this harness runs with `set +e`, and that gap already hid
# one bug: a trailing `[[ ... ]] && { ...; }` made the function return the last loop iteration's
# false status, so stage 40 aborted immediately after rasterising the branding correctly. Run it
# the way a stage does, with the rasteriser stubbed so this works on any host.
( set -euo pipefail
  rsvg-convert() { printf 'PNGSTUB' > "$4"; }
  export -f rsvg-convert
  render_branding "$SRC" "$TMP/setE" ) >/dev/null 2>&1
assert_eq 0 $? "render_branding returns 0 under set -euo pipefail"

# ---- the real rasterise + generate pass, when the host has the tools -----------------------
if command -v rsvg-convert >/dev/null 2>&1; then
    DST="$TMP/png"
    render_branding "$SRC" "$DST"
    for a in "${WANTED[@]}"; do
        assert_true "$a.png rasterised and non-empty" test -s "$DST/$a.png"
    done
    assert_false "SVG sources do not reach the output dir" compgen -G "$DST/*.svg"
    assert_false "the README does not reach the output dir" test -e "$DST/README.md"

    if python3 -c 'import PIL' 2>/dev/null; then
        python3 "$GEN" --asset-dir "$DST" --sprites "$TMP/splash.bin" --bmp "$TMP/splash.bmp" \
            >/dev/null 2>&1
        assert_true "the generator produced a sprite container" test -s "$TMP/splash.bin"
        assert_true "the generator produced a stub bitmap"      test -s "$TMP/splash.bmp"
        # Parsed exactly the way config/splash/splash.c parses it. "The file exists" says
        # nothing: a container the program cannot read is a splash that exits 0 and leaves a
        # black screen, which is the failure this whole file is here to catch.
        assert_true "the sprite container is well-formed and self-consistent" \
            python3 - "$TMP/splash.bin" <<'PYEOF'
import struct, sys
blob = open(sys.argv[1], "rb").read()
assert blob[:8] == b"IMSPLSH2", "bad magic"
bg, n = struct.unpack_from("<II", blob, 8)
assert bg == 0x0A0D11, f"background {bg:#08x} is not the brand #0a0d11"
assert 0 < n <= 32, f"implausible tile count {n}"
anchors, scales = set(), set()
slots = {}
for i in range(n):
    o = 16 + i * 40
    scale, anchor, flags, w, h, box_w, box_h = struct.unpack_from("<7I", blob, o)
    ox, oy = struct.unpack_from("<ii", blob, o + 28)
    off, = struct.unpack_from("<I", blob, o + 36)
    assert 0 < w <= 16384 and 0 < h <= 16384, f"tile {i} extent {w}x{h}"
    assert anchor in (0, 1, 2), f"tile {i} anchor {anchor}"
    # splash.c rejects a box smaller than the tile it holds; so must the generator's output.
    assert box_w >= w and box_h >= h, f"tile {i} box {box_w}x{box_h} is smaller than {w}x{h}"
    if anchor == 0:
        # Centred: off is the tile's place inside the block, so it must fit inside it.
        assert 0 <= ox <= box_w - w and 0 <= oy <= box_h - h, f"tile {i} sits outside its box"
    else:
        # Corner-anchored: the box IS the tile and off is its inset from the screen edge.
        assert (box_w, box_h) == (w, h), f"tile {i} is corner-anchored but its box is not itself"
        assert ox >= 0 and oy >= 0, f"tile {i} has a negative screen inset"
    assert off + w * h * 4 <= len(blob), f"tile {i} pixels run past the end of the file"
    anchors.add(anchor); scales.add(scale)
    if flags & 0x1:
        slots.setdefault(scale, []).append((flags >> 8) & 0xff)
# The centred block's pieces and both status fields, at every scale offered: a container
# missing the bottom-right tile draws a splash with no "PRESS ESC FOR DETAILS" and says nothing.
assert anchors == {0, 1, 2}, f"expected all three anchors, got {sorted(anchors)}"
assert scales == {1, 2}, f"expected scales 1 and 2, got {sorted(scales)}"
# Exactly one slab per pulse slot per scale. A duplicated slot animates two slabs together and
# leaves a third permanently still — a splash that looks broken rather than one that is absent.
for scale, got in slots.items():
    assert sorted(got) == [0, 1, 2], f"scale {scale} pulse slots are {sorted(got)}, want [0, 1, 2]"
PYEOF

        # THE PROPERTY THE WHOLE HAND-OFF RESTS ON: the pieces the block was cut into, placed
        # back by the container's own box/offset arithmetic, must BE the flat block that the
        # stub bitmap and the installer's logo are. A pixel of drift here is a mark that jumps
        # at the first modeset — exactly what the shared compose function exists to prevent, and
        # newly at risk now that the KMS half no longer ships the block as a single tile.
        assert_true "the container's centre tiles reassemble into build_block() exactly" \
            python3 - "$GEN" "$TMP/splash.bin" "$DST" <<'PYEOF'
import importlib.util, struct, sys
from pathlib import Path
from PIL import Image, ImageChops
sys.dont_write_bytecode = True  # do not leave a __pycache__ in the tracked config/branding
spec = importlib.util.spec_from_file_location("gen", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
blob = Path(sys.argv[2]).read_bytes()
n, = struct.unpack_from("<I", blob, 12)
for scale in g.SPRITE_SCALES:
    ref = g.build_block(Path(sys.argv[3]), scale, g.BG).image
    canvas = Image.new("RGB", ref.size, g.BG)
    seen = 0
    for i in range(n):
        o = 16 + i * 40
        s, anchor, _flags, w, h, box_w, box_h = struct.unpack_from("<7I", blob, o)
        ox, oy = struct.unpack_from("<ii", blob, o + 28)
        off, = struct.unpack_from("<I", blob, o + 36)
        if s != scale or anchor != g.ANCHOR_CENTRE:
            continue
        assert (box_w, box_h) == ref.size, f"scale {scale}: box {box_w}x{box_h} != block {ref.size}"
        b, gc, r, _a = Image.frombytes("RGBA", (w, h), blob[off:off + w * h * 4]).split()
        canvas.paste(Image.merge("RGB", (r, gc, b)), (ox, oy))
        seen += 1
    assert seen == len(g.SLABS) + 1, f"scale {scale}: {seen} centre tiles, want {len(g.SLABS) + 1}"
    box = ImageChops.difference(canvas, ref).getbbox()
    assert box is None, f"scale {scale}: reassembly differs from build_block() at {box}"
PYEOF
        # systemd-stub's bmp_parse_header() rejects the BITMAPV4 header Pillow writes for a
        # mode-RGBA image, and ukify does not check. The symptom is a UKI with a .splash
        # section the firmware silently skips.
        assert_true "the stub bitmap has the 40-byte BITMAPINFOHEADER the stub accepts" \
            python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); assert d[:2]==b"BM"; assert struct.unpack_from("<I",d,14)[0]==40' \
            "$TMP/splash.bmp"

        # ---- the Plasma theme's generated half ---------------------------------------------
        python3 "$GEN" --svg-dir "$SRC" --theme "$TMP/theme" >/dev/null 2>&1
        for f in Design.qml images/slab-top.svg images/slab-mid.svg images/slab-bot.svg \
                 images/wordmark.svg; do
            assert_true "the theme generator produced $f" test -s "$TMP/theme/$f"
        done
        for f in "$TMP"/theme/images/*.svg; do
            assert_true "well-formed XML: theme/$(basename -- "$f")" \
                python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$f"
        done
        # THE TWO SPLASHES MUST SHADE THE MARK IDENTICALLY, and they get there by different
        # routes: the KMS half re-shades PIXELS through reshade_slab()'s alpha LUT, the Plasma
        # half re-shades VECTORS by rewriting each polygon's fill. The two agree by algebra —
        # rsvg gives a polygon with fill F at opacity p an alpha of coverage*p, so the LUT's
        # alpha/face is the same coverage the flat-fill polygon renders with — provided the
        # colours match. This checks the colours, exactly, with no rasteriser and no tolerance.
        assert_true "the theme's slab colours are reshade_slab()'s, face for face" \
            python3 - "$GEN" "$SRC" "$TMP/theme/images" <<'PYEOF'
import importlib.util, sys
import xml.etree.ElementTree as ET
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gen", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
src, out = Path(sys.argv[2]), Path(sys.argv[3])
for slab in g.SLABS:
    stem = slab[: -len(".png")]
    want = [g.shaded_face(float(el.get("opacity", "1")))
            for el in ET.parse(src / f"{stem}.svg").getroot().iter()
            if el.tag.endswith("polygon")]
    got, leftover = [], []
    for el in ET.parse(out / f"{stem}.svg").getroot().iter():
        if el.tag.endswith("polygon"):
            got.append(el.get("fill"))
            if el.get("opacity") is not None:
                leftover.append(el.get("points"))
    assert want, f"{stem}: no polygons in the source"
    assert got == want, f"{stem}: fills {got} != {want}"
    # A surviving opacity would multiply against the QML's animation, and the faces would drift
    # apart as the slab dimmed — the "shading runs backwards" failure, back by another door.
    assert not leftover, f"{stem}: polygons still carry opacity: {leftover}"
PYEOF

        # ---- splash.c's own blitter, run against the container it will read at boot ---------
        # The strongest check available offline, and the only one that exercises the C: compile
        # the real file, blit the real container into memory, and require frame zero to be the
        # flat block byte for byte. That pins the box/offset arithmetic AND the property the
        # animation is built on — that a splash which never gets a second frame (a VM on a
        # shadow-buffer driver) shows exactly the still image this program drew before it could
        # animate at all.
        if command -v gcc >/dev/null 2>&1; then
            cat > "$TMP/blitcheck.c" <<'CEOF'
#define main splash_main_unused
#include "splash.c"
#undef main
int main(int argc, char **argv)
{
    struct assets a = { 0 };
    if (argc < 4 || load_assets(argv[1], &a) != 0)
        return 2;
    uint32_t w = (uint32_t)atoi(argv[2]), h = (uint32_t)atoi(argv[3]), pitch = w * 4;
    uint8_t *fb = malloc((size_t)pitch * h);
    if (!fb)
        return 2;
    fill_bg(fb, pitch, w, h, a.bg);
    uint32_t scale = pick_scale(&a, h);
    for (uint32_t i = 0; i < a.n_tiles; i++)
        if (a.tiles[i].scale == scale)
            blit(fb, pitch, w, h, &a, &a.tiles[i], 256);
    return fwrite(fb, 1, (size_t)pitch * h, stdout) ? 0 : 2;
}
CEOF
            if gcc -std=c11 -O2 -Wall -Wextra -Werror -I "$REPO_ROOT/config/splash" \
                   -o "$TMP/blitcheck" "$TMP/blitcheck.c" 2>"$TMP/blitcheck.err"; then
                _pass
                "$TMP/blitcheck" "$TMP/splash.bin" 1920 1080 > "$TMP/frame0.raw"
                assert_true "splash.c paints frame zero exactly as build_block() composes it" \
                    python3 - "$GEN" "$TMP/frame0.raw" "$DST" <<'PYEOF'
import importlib.util, sys
from pathlib import Path
from PIL import Image, ImageChops
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gen", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
W, H = 1920, 1080
b, gc, r, _a = Image.frombytes("RGBA", (W, H), Path(sys.argv[2]).read_bytes()).split()
got = Image.merge("RGB", (r, gc, b))

png = Path(sys.argv[3])
ref = Image.new("RGB", (W, H), g.BG)
block = g.build_block(png, 1, g.BG).image
ref.paste(block, ((W - block.width) // 2, (H - block.height) // 2))
left = g.flatten(g.load(png, g.STATUS_LEFT, 1 / g.ASSET_ZOOM), g.BG)
right = g.flatten(g.load(png, g.STATUS_RIGHT, 1 / g.ASSET_ZOOM), g.BG)
ref.paste(left, (g.PAD_X, H - g.PAD_Y - left.height))
ref.paste(right, (W - g.PAD_X - right.width, H - g.PAD_Y - right.height))

box = ImageChops.difference(got, ref).getbbox()
assert box is None, f"splash.c's frame differs from the composed reference at {box}"
PYEOF
            else
                _fail "splash.c does not compile: $(head -n3 "$TMP/blitcheck.err")"
            fi
        else
            echo "  (gcc absent — skipping the splash.c blit check; stage 40 compiles it)"
        fi
    else
        echo "  (Pillow absent — skipping the generate pass; builder/Dockerfile installs it)"
    fi
else
    echo "  (rsvg-convert absent — skipping the rasterise pass; stage 10 requires it)"
fi

# ---- the layer pulse is written in two languages and they must agree ----------------------
# plan/17. The KMS splash dips the slabs in C and the Plasma splash dips them in QML, on either
# side of one login, so a divergence is two brand animations at two speeds — visible, and
# invisible to every other check here. The generator is the source: it emits the QML's constants
# into Design.qml, so only the C copy can drift.
SPLASH_C="$REPO_ROOT/config/splash/splash.c"
for k in PULSE_CYCLE_MS PULSE_DEPTH PULSE_SLOTS; do
    py="$(sed -nE "s/^$k *= *([0-9.]+).*/\\1/p" "$GEN")"
    c="$(sed -nE "s/^#define $k ([0-9.]+)$/\\1/p" "$SPLASH_C")"
    assert_true "$k is set in the generator" test -n "$py"
    assert_eq "$py" "$c" "$k matches between the generator and splash.c"
done
# The container format is agreed the same way, and this is the pair that fails silently: a
# splash.c reading v1 records out of a v2 file computes garbage offsets and draws nothing.
assert_true "splash.c and the generator agree on the container magic" \
    grep -q "$(sed -nE 's/^MAGIC = b"(.*)"$/\1/p' "$GEN")" "$SPLASH_C"
gen_rec="$(sed -nE 's/^TILE_RECORD_BYTES = ([0-9]+).*/\1/p' "$GEN")"
c_words="$(sed -nE 's/^#define TILE_RECORD_WORDS ([0-9]+).*/\1/p' "$SPLASH_C")"
assert_eq "$gen_rec" "$((c_words * 4))" "the tile record is the same size on both sides"
gen_max="$(sed -nE 's/^MAX_TILES = ([0-9]+).*/\1/p' "$GEN")"
c_max="$(sed -nE 's/^#define MAX_TILES ([0-9]+).*/\1/p' "$SPLASH_C")"
assert_eq "$gen_max" "$c_max" "MAX_TILES matches between the generator and splash.c"

# ---- the Plasma splash theme (plan/17) ----------------------------------------------------
PLASMA="$REPO_ROOT/config/plasma"
LNF="$PLASMA/lookandfeel"
assert_file "$LNF/metadata.json.in" "the look-and-feel package has a descriptor"
assert_file "$LNF/contents/splash/Splash.qml" "the look-and-feel package has a splash script"

render_template "$LNF/metadata.json.in" "$TMP/metadata.json"
render_template "$PLASMA/ksplashrc.in" "$TMP/ksplashrc"
assert_false "no unresolved tokens in metadata.json" grep -qE '@[A-Z][A-Z0-9_]*@' "$TMP/metadata.json"
assert_false "no unresolved tokens in ksplashrc" grep -qE '@[A-Z][A-Z0-9_]*@' "$TMP/ksplashrc"
assert_true "the descriptor is valid JSON" \
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/metadata.json"
# KPackage compares the descriptor's id against the DIRECTORY it loaded and installs Breeze as
# the fallback on the strength of that comparison; ksplashqml then resolves ksplashrc's Theme as
# that same id. All three have to be one string, and if they are not, ksplashqml silently draws
# Breeze's splash instead of ours.
assert_true "the package declares Id \"$DISTRO_ID\"" \
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["KPlugin"]["Id"] == sys.argv[2]' \
    "$TMP/metadata.json" "$DISTRO_ID"
assert_true "ksplashrc selects that package" grep -qx "Theme=$DISTRO_ID" "$TMP/ksplashrc"
# Engine is checked in three places before anything is drawn, and any other value means no
# splash at all rather than a different one.
assert_true "ksplashrc keeps the QML engine" grep -qx "Engine=KSplashQML" "$TMP/ksplashrc"
assert_true "it is a Plasma/LookAndFeel package" \
    grep -q '"KPackageStructure": "Plasma/LookAndFeel"' "$TMP/metadata.json"
# Not the same package as the installer medium's, and the thing that must not cross over is the
# layout script: it pins Calamares to the task manager, and it would reach every installed
# machine if this package ever grew a contents/layouts/.
assert_false "the splash package ships no desktop layout script" \
    test -e "$LNF/contents/layouts"

QML="$LNF/contents/splash/Splash.qml"
assert_true "the splash script is the QML ksplashqml loads by property" grep -q 'property int stage' "$QML"
assert_true "it reveals itself on a stage change" grep -q 'onStageChanged' "$QML"
# Breeze tests `stage == 2`; ksplash's own README says stages may be reordered or take zero
# time, and an equality test against a number that moved leaves the splash permanently invisible.
assert_true "the reveal is a >= test, not an equality" grep -qE 'stage >= 2' "$QML"
assert_true "it instantiates the generated design constants" grep -qE '^ *Design \{' "$QML"
for img in slab-top slab-mid slab-bot wordmark; do
    assert_true "the QML draws images/$img.svg" grep -q "images/$img.svg" "$QML"
done
# The three slabs must each be given a different slot or the wave is not a wave.
for slot in 0 1 2; do
    assert_true "a slab is bound to pulse slot $slot" \
        grep -q "root.slabOpacity(root.cycle, $slot)" "$QML"
done

# ---- stage 40 must install all of that, and only where there is a desktop -----------------
assert_true "stage 40 installs the look-and-feel package" \
    grep -q 'config/plasma' "$STAGE40"
assert_true "stage 40 generates the theme assets" \
    grep -q -- '--theme "\$SPLASH_LNF_DIR/contents/splash"' "$STAGE40"
assert_true "stage 40 writes /etc/xdg/ksplashrc" \
    grep -q 'etc/xdg/ksplashrc' "$STAGE40"
# A console image has no Plasma; installing a look-and-feel package there would be dead weight
# on a root filesystem this project audits by the megabyte.
assert_true "the Plasma splash is guarded on the desktop set" \
    grep -q '^if profile_has_set desktop; then$' "$STAGE40"
# The fade-out is kwin's login effect, not the theme's — see plan/17. Losing it does not break
# the boot, it just stops the splash fading, which is why it is asserted at build time.
assert_true "stage 40 asserts kwin's login effect is present and enabled by default" \
    grep -q 'kwin-wayland/effects/login/metadata.json' "$STAGE40"
assert_true "stage 40 asserts ksplashqml itself is in the image" \
    grep -q 'usr/bin/ksplashqml' "$STAGE40"

# ---- the initrd GPU assertion must not fire on config files -------------------------------
# plan/14's guard exists to catch a dracut module dragging the DRM tree back into the initrd —
# 70+ MiB of UKI, arriving silently. Its first regex was '/nvidia[-_.]', which puts a literal
# '.' in the character class and so matched etc/modprobe.d/nvidia.conf: 1488 bytes of
# "blacklist nouveau" that nvidia-drivers installs and dracut sweeps in with the rest of
# /etc/modprobe.d. That failed a build whose initrd was completely clean, and the message told
# the reader to go looking for a dependency that was never pulled in.
#
# Both directions are pinned here: a real driver or its firmware must still be caught, and a
# config file must not be.
gpu_match() {
    awk '
      { p = $NF }
      p ~ /drivers\/gpu\//                            { print; next }
      p ~ /(^|\/)nvidia[^\/]*\.ko(\.(xz|zst|gz))?$/   { print; next }
      p ~ /(^|\/)firmware\/nvidia\//                  { print; next }
    ' <<<"$1"
}
for good in \
    "-rw-r--r-- 1 root root 1488 Aug  5 09:19 etc/modprobe.d/nvidia.conf" \
    "-rw-r--r-- 1 root root  100 Aug  5 09:19 etc/nvidia-something.conf" \
    "-rw-r--r-- 1 root root  100 Aug  5 09:19 usr/lib/modules/6.18/kernel/fs/erofs/erofs.ko.xz"; do
    if [[ -n $(gpu_match "$good") ]]; then
        _fail "initrd GPU guard false-positives on: ${good##* }"
    else _pass; fi
done
for bad in \
    "-rw-r--r-- 1 root root 200000 Aug  5 09:19 usr/lib/modules/6.18/kernel/drivers/gpu/drm/drm.ko.xz" \
    "-rw-r--r-- 1 root root 900000 Aug  5 09:19 usr/lib/modules/6.18/video/nvidia.ko.zst" \
    "-rw-r--r-- 1 root root 100000 Aug  5 09:19 usr/lib/firmware/nvidia/ad10x/gsp.bin"; do
    if [[ -z $(gpu_match "$bad") ]]; then
        _fail "initrd GPU guard misses a real driver: ${bad##* }"
    else _pass; fi
done
# ...and the shipped stage must actually use that shape, not the old loose one. Comment lines
# are excluded because the fix's own comment quotes the broken pattern in order to explain it.
S40="$REPO_ROOT/scripts/stages/40-configure.sh"
if grep -v '^[[:space:]]*#' "$S40" | grep -q "nvidia\[-_\.\]"; then
    _fail "stage 40 still uses the loose /nvidia[-_.] pattern, which matches nvidia.conf"
else _pass; fi

finish
