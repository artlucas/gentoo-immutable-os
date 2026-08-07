#!/usr/bin/env bash
# run-tests.sh — the full offline test suite (T0 + unit/integration tests that need
# no Gentoo image, no Docker, no root). Runs on Git Bash, WSL, or Linux.
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
FAILED=0

section() { printf '\n=== %s ===\n' "$*"; }

# ---- T0a: bash syntax on every shell file (incl. dracut + rootfs scripts) -------
section "bash -n syntax"
SH_FILES=()
while IFS= read -r -d '' f; do SH_FILES+=("$f"); done < <(
    find "$REPO_ROOT/scripts" "$REPO_ROOT/tests" \
         "$REPO_ROOT/config/rootfs/usr/lib/dracut" \
         -type f -name '*.sh' -print0 2>/dev/null
)
SH_FILES+=("$REPO_ROOT/scripts/build.sh")
for f in "${SH_FILES[@]}"; do
    if bash -n "$f" 2>/tmp/syntax.err; then
        printf '  ok   %s\n' "${f#"$REPO_ROOT"/}"
    else
        printf '  FAIL %s\n' "${f#"$REPO_ROOT"/}"; cat /tmp/syntax.err
        FAILED=1
    fi
done

# templates: render with dummy values, then bash -n
section "bash -n on rendered templates"
export REPO="$REPO_ROOT" WORK="${TMPDIR:-/tmp}/rt-work" OUT="${TMPDIR:-/tmp}/rt-out"
export STAGE_NAME=lint
# shellcheck source=../scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit; this runner must keep going after failures
load_config
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER FLATPAK_PREINSTALL
export VERIFY=yes
for t in "$REPO_ROOT"/config/rootfs/usr/bin/*.in "$REPO_ROOT"/config/rootfs/usr/lib/image-test/*.in; do
    [[ -e $t ]] || continue
    out_f="${TMPDIR:-/tmp}/rendered-$(basename "$t" .in)"
    if render_template "$t" "$out_f" && bash -n "$out_f"; then
        printf '  ok   %s (rendered)\n' "${t#"$REPO_ROOT"/}"
    else
        printf '  FAIL %s\n' "${t#"$REPO_ROOT"/}"; FAILED=1
    fi
done

# ---- T0b: no CR bytes anywhere that Linux will read ---------------------------------
# Byte-level via od: MSYS grep silently strips \r when reading files in text mode,
# so a naive `grep $'\r'` is unreliable on Windows hosts.
section "CRLF check"
CRLF_HITS=""
while IFS= read -r -d '' f; do
    if od -An -c -- "$f" | grep -q '\\r'; then
        CRLF_HITS+="$f"$'\n'
    fi
done < <(find "$REPO_ROOT" -path "$REPO_ROOT/out" -prune -o -path "$REPO_ROOT/.git" -prune -o -type f -print0)
if [[ -n $CRLF_HITS ]]; then
    printf '  FAIL: CR bytes found in:\n%s' "$CRLF_HITS"
    FAILED=1
else
    echo "  ok: no CR bytes in tracked tree"
fi

# ---- T0c: config lint ------------------------------------------------------------------
section "config lint"
if ( load_config ) >/dev/null 2>&1; then
    echo "  ok: build.conf validates"
else
    echo "  FAIL: build.conf does not validate"; FAILED=1
fi
# sets must not reference obviously bogus atoms (basic shape check)
BAD_ATOMS="$(grep -hEv '^\s*(#|$)' "$REPO_ROOT"/config/portage/sets/* \
    | sed 's/\s*#.*$//' | grep -Ev '^[a-z0-9-]+/[A-Za-z0-9._+-]+\s*$' || true)"
if [[ -n $BAD_ATOMS ]]; then
    printf '  FAIL: malformed atoms in sets:\n%s\n' "$BAD_ATOMS"; FAILED=1
else
    echo "  ok: package sets well-formed"
fi

# ---- shellcheck (optional: skipped when unavailable) --------------------------------------
section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S warning "${SH_FILES[@]}"; then
        echo "  ok: shellcheck clean"
    else
        echo "  FAIL: shellcheck findings"; FAILED=1
    fi
else
    echo "  skipped (shellcheck not installed on this host)"
fi

# ---- unit/integration tests -------------------------------------------------------------------
for t in "$TESTS_DIR"/test-*.sh; do
    section "$(basename "$t")"
    if bash "$t"; then :; else FAILED=1; fi
done

section "result"
if [[ $FAILED -ne 0 ]]; then
    echo "TEST SUITE FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
