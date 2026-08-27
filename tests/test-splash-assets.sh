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
assert blob[:8] == b"IMSPLSH1", "bad magic"
bg, n = struct.unpack_from("<II", blob, 8)
assert bg == 0x0A0D11, f"background {bg:#08x} is not the brand #0a0d11"
assert 0 < n <= 16, f"implausible tile count {n}"
anchors, scales = set(), set()
for i in range(n):
    scale, anchor, w, h, ox, oy, off = struct.unpack_from("<7I", blob, 16 + i * 28)
    assert 0 < w <= 16384 and 0 < h <= 16384, f"tile {i} extent {w}x{h}"
    assert anchor in (0, 1, 2), f"tile {i} anchor {anchor}"
    assert off + w * h * 4 <= len(blob), f"tile {i} pixels run past the end of the file"
    anchors.add(anchor); scales.add(scale)
# One centred block and both status fields, at every scale offered: a container missing the
# bottom-right tile draws a splash with no "PRESS ESC FOR DETAILS" and nothing says so.
assert anchors == {0, 1, 2}, f"expected all three anchors, got {sorted(anchors)}"
assert scales == {1, 2}, f"expected scales 1 and 2, got {sorted(scales)}"
PYEOF
        # systemd-stub's bmp_parse_header() rejects the BITMAPV4 header Pillow writes for a
        # mode-RGBA image, and ukify does not check. The symptom is a UKI with a .splash
        # section the firmware silently skips.
        assert_true "the stub bitmap has the 40-byte BITMAPINFOHEADER the stub accepts" \
            python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); assert d[:2]==b"BM"; assert struct.unpack_from("<I",d,14)[0]==40' \
            "$TMP/splash.bmp"
    else
        echo "  (Pillow absent — skipping the generate pass; builder/Dockerfile installs it)"
    fi
else
    echo "  (rsvg-convert absent — skipping the rasterise pass; stage 10 requires it)"
fi

finish
