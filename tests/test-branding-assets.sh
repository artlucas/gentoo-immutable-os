#!/usr/bin/env bash
# The boot splash is the one thing in this image no automated test can look at: stage 70
# reads a serial port, so a splash that renders nothing still reports green. These are the
# checks that CAN be made offline — that the theme and its assets still refer to each other,
# that the templates render, and that the two places the asset zoom is written still agree.
export TEST_FILE_NAME=test-branding-assets
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
SCRIPT_IN="$SRC/distro.script.in"

# same render environment stage 40 exports for the branding templates
SPLASH_STATUS_LEFT="$(printf '%s · V%s · AMD64' "$UPDATE_CHANNEL" "$VERSION" | tr '[:lower:]' '[:upper:]')"
export DISTRO_ID DISTRO_NAME VERSION UPDATE_CHANNEL SPLASH_STATUS_LEFT

# ---- the theme and its assets must still refer to each other -----------------------------
# The classic way this breaks is renaming an asset and forgetting the script (or the reverse);
# both halves fail silently, at boot, on a screen no test looks at.
mapfile -t WANTED < <(grep -oE 'load\("[^"]+\.png"\)' "$SCRIPT_IN" \
                      | sed -E 's/load\("(.*)\.png"\)/\1/' | sort -u)
mapfile -t HAVE   < <(find "$SRC" -maxdepth 1 \( -name '*.svg' -o -name '*.svg.in' \) -printf '%f\n' \
                      | sed -E 's/\.svg(\.in)?$//' | sort -u)
assert_true "theme script loads at least one asset" test "${#WANTED[@]}" -gt 0
for a in "${WANTED[@]}"; do
    assert_true "asset '$a' loaded by the theme has an SVG source" \
        test -f "$SRC/$a.svg" -o -f "$SRC/$a.svg.in"
done
for a in "${HAVE[@]}"; do
    assert_true "SVG source '$a' is actually loaded by the theme" \
        grep -qF "load(\"$a.png\")" "$SCRIPT_IN"
done

# ---- the asset zoom is written in two files and they must agree ---------------------------
# common.sh rasterises at BRANDING_ZOOM; the theme divides by ASSET_ZOOM. Changing one alone
# resizes the whole splash and nothing complains.
theme_zoom="$(sed -nE 's/^ASSET_ZOOM *= *([0-9]+) *;.*/\1/p' "$SCRIPT_IN")"
assert_eq "$BRANDING_ZOOM" "$theme_zoom" "BRANDING_ZOOM matches the theme's ASSET_ZOOM"

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

# ---- the manifest must point at the file the build actually installs ----------------------
MAN="$TMP/${DISTRO_ID}.plymouth"
assert_file "$MAN" "theme manifest renders to ${DISTRO_ID}.plymouth"
assert_true "manifest selects the script plugin" grep -qx 'ModuleName=script' "$MAN"
assert_true "manifest ScriptFile matches the installed script name" \
    grep -qx "ScriptFile=/usr/share/plymouth/themes/${DISTRO_ID}/${DISTRO_ID}.script" "$MAN"
assert_true "manifest ImageDir matches the installed theme dir" \
    grep -qx "ImageDir=/usr/share/plymouth/themes/${DISTRO_ID}" "$MAN"

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

# ---- install_branding must survive `set -e` -------------------------------------------------
# Stages run with `set -euo pipefail`, this harness runs with `set +e`, and that gap already hid
# one bug: a trailing `[[ ... ]] && { ...; }` made the function return the last loop iteration's
# false status, so stage 40 aborted immediately after installing the branding correctly. Run it
# the way a stage does, with the rasteriser stubbed so this works on any host.
( set -euo pipefail
  rsvg-convert() { printf 'PNGSTUB' > "$4"; }
  export -f rsvg-convert
  install_branding "$SRC" "$TMP/setE" ) >/dev/null 2>&1
assert_eq 0 $? "install_branding returns 0 under set -euo pipefail"

# ---- the real install, when the host happens to have the rasteriser ------------------------
if command -v rsvg-convert >/dev/null 2>&1; then
    DST="$TMP/theme"
    install_branding "$SRC" "$DST"
    for a in "${WANTED[@]}"; do
        assert_true "$a.png rasterised and non-empty" test -s "$DST/$a.png"
    done
    assert_file "$DST/${DISTRO_ID}.script"   "theme script installed under the branded name"
    assert_file "$DST/${DISTRO_ID}.plymouth" "manifest installed under the branded name"
    assert_false "SVG sources do not reach the theme dir" \
        compgen -G "$DST/*.svg"
    assert_false "the README does not reach the theme dir" test -e "$DST/README.md"
else
    echo "  (rsvg-convert absent — skipping the rasterise/install pass; stage 10 requires it)"
fi

finish
