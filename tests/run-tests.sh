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
# SPLASH_BACKEND picks which of two very different boot paths the image gets, and a typo in it
# would otherwise surface only as a screen nobody automated can see. Every accepted value must
# validate, anything else must be rejected, and an absent key must default (build.conf files
# predating the switch still have to load).
SPLASH_LINT_OK=1
for v in plymouth stub both none; do
    ( load_config; SPLASH_BACKEND="$v"; validate_config ) >/dev/null 2>&1 \
        || { echo "  FAIL: SPLASH_BACKEND=$v rejected"; SPLASH_LINT_OK=0; }
done
for v in Plymouth stub,both "" bogus; do
    if ( load_config; SPLASH_BACKEND="$v"; validate_config ) >/dev/null 2>&1; then
        echo "  FAIL: SPLASH_BACKEND=$v accepted"; SPLASH_LINT_OK=0
    fi
done
if ( load_config; unset SPLASH_BACKEND SPLASH_STUB_SCALE; validate_config; [[ $SPLASH_BACKEND == plymouth ]] ) >/dev/null 2>&1; then
    :
else
    echo "  FAIL: SPLASH_BACKEND does not default to plymouth"; SPLASH_LINT_OK=0
fi
for v in 0 -1 1.5 x; do
    # shellcheck disable=SC2034  # read by validate_config, which runs in this same subshell
    if ( load_config; SPLASH_STUB_SCALE="$v"; validate_config ) >/dev/null 2>&1; then
        echo "  FAIL: SPLASH_STUB_SCALE=$v accepted"; SPLASH_LINT_OK=0
    fi
done
if [[ $SPLASH_LINT_OK == 1 ]]; then
    echo "  ok: SPLASH_BACKEND / SPLASH_STUB_SCALE validation"
else
    FAILED=1
fi
# DEBUG_INITRD decides whether a broken root slot drops to a dracut shell or reboots into the
# other slot, i.e. whether plan/01's automatic rollback is automatic. Same three properties as
# SPLASH_BACKEND above: both values accepted, anything else rejected, absent key defaults — a
# build.conf predating the knob must still validate.
DBG_LINT_OK=1
for v in 0 1; do
    ( load_config; DEBUG_INITRD="$v"; validate_config ) >/dev/null 2>&1 \
        || { echo "  FAIL: DEBUG_INITRD=$v rejected"; DBG_LINT_OK=0; }
done
for v in "" 2 yes true -1; do
    if ( load_config; DEBUG_INITRD="$v"; validate_config ) >/dev/null 2>&1; then
        echo "  FAIL: DEBUG_INITRD=$v accepted"; DBG_LINT_OK=0
    fi
done
if ( load_config; unset DEBUG_INITRD; validate_config; [[ $DEBUG_INITRD == 0 ]] ) >/dev/null 2>&1; then
    :
else
    echo "  FAIL: DEBUG_INITRD does not default to 0"; DBG_LINT_OK=0
fi
[[ $DBG_LINT_OK == 1 ]] && echo "  ok: DEBUG_INITRD validation" || FAILED=1

# ---- the three hardware lists ------------------------------------------------------------
# prune-firmware.txt, prune-microcode.txt and dracut-omit-drivers.txt are read by stages 40 and
# 50 and drive deletions on a root filesystem and the contents of the UKI. All three are mostly
# comment by design, so the failure they invite is a typo that parses to nothing and silently
# prunes nothing — which looks exactly like success. Check the shape offline, where it is free.
section "hardware list files"
LIST_OK=1
for l in prune-firmware.txt prune-microcode.txt dracut-omit-drivers.txt; do
    f="$REPO_ROOT/config/$l"
    if [[ ! -f $f ]]; then
        echo "  FAIL: $l missing"; LIST_OK=0; continue
    fi
    mapfile -t ENTRIES < <(read_list_file "$f")
    if (( ${#ENTRIES[@]} == 0 )); then
        echo "  FAIL: $l parses to zero entries"; LIST_OK=0; continue
    fi
    printf '  ok   %s (%d entries)\n' "$l" "${#ENTRIES[@]}"
done
# prune-firmware.txt names paths under /usr/lib/firmware and is applied with rm -rf as root.
BAD="$(read_list_file "$REPO_ROOT/config/prune-firmware.txt" | grep -E '^/|\.\.' || true)"
if [[ -n $BAD ]]; then
    printf '  FAIL: prune-firmware.txt has absolute or traversing entries:\n%s\n' "$BAD"; LIST_OK=0
fi
# prune-microcode.txt entries are bare signature prefixes, matched as intel-ucode/<entry>*.
BAD="$(read_list_file "$REPO_ROOT/config/prune-microcode.txt" | grep -Ev '^[0-9a-f]{2}-[0-9a-f]{2}$' || true)"
if [[ -n $BAD ]]; then
    printf '  FAIL: prune-microcode.txt entries must be ff-mm signature prefixes:\n%s\n' "$BAD"; LIST_OK=0
fi
# ...and it must not name a signature the image is meant to keep. plan/08 puts budget Atom-class
# client CPUs explicitly in scope (they are why the image has no AVX2 floor), so pruning one of
# them would contradict a documented decision — and would do it invisibly, on hardware no test
# here runs on.
for keep in 06-37 06-4c 06-5c 06-7a; do
    if read_list_file "$REPO_ROOT/config/prune-microcode.txt" | grep -qx "$keep"; then
        echo "  FAIL: prune-microcode.txt prunes $keep, an in-scope Atom-class client CPU (plan/08)"
        LIST_OK=0
    fi
done
# dracut-omit-drivers.txt is matched against MODULE NAMES; a path-shaped entry is a silent no-op
# (see that file's header, and the empirical check in plan/11).
BAD="$(read_list_file "$REPO_ROOT/config/dracut-omit-drivers.txt" | grep -E '/' || true)"
if [[ -n $BAD ]]; then
    printf '  FAIL: dracut-omit-drivers.txt has path-shaped entries (dracut matches names):\n%s\n' "$BAD"; LIST_OK=0
fi
# ...and it must never omit a module this image boots on. erofs is the root filesystem, overlay
# is the /etc overlay, and the nvidia trio is the early-KMS splash: a too-greedy regex here is
# the difference between a UKI that shrank and one that cannot mount its own root.
for m in erofs overlay nvme sd_mod ahci nvidia nvidia_modeset nvidia_drm amdgpu i915 xe virtio_blk usb_storage; do
    HIT="$(read_list_file "$REPO_ROOT/config/dracut-omit-drivers.txt" \
        | sed 's/-/_/g' | while IFS= read -r p; do [[ $m =~ ^${p}$ ]] && echo "$p"; done)"
    if [[ -n $HIT ]]; then
        echo "  FAIL: dracut-omit-drivers.txt pattern '$HIT' would omit '$m', which this image boots on"
        LIST_OK=0
    fi
done
[[ $LIST_OK == 1 ]] && echo "  ok: hardware lists well-formed" || FAILED=1

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
