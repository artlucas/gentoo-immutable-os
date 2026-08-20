# shellcheck shell=bash
# harness.sh — minimal assertion helpers for the offline test suite.
# Each test file sources this, makes assertions, and calls finish at the end.

set -uo pipefail   # deliberately no -e: assertions record failures and continue

ASSERTIONS=0
FAILURES=0

_pass() { ASSERTIONS=$((ASSERTIONS + 1)); }
_fail() { ASSERTIONS=$((ASSERTIONS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL: %s\n' "$*" >&2; }

assert_eq() {        # expected actual label
    if [[ $1 == "$2" ]]; then _pass; else _fail "$3: expected '$1', got '$2'"; fi
}

assert_match() {     # ERE-pattern text label
    if [[ $2 =~ $1 ]]; then _pass; else _fail "$3: '$2' does not match /$1/"; fi
}

assert_true() {      # label command...
    local label=$1; shift
    if "$@"; then _pass; else _fail "$label: command failed: $*"; fi
}

assert_false() {     # label command...
    local label=$1; shift
    if "$@"; then _fail "$label: command unexpectedly succeeded: $*"; else _pass; fi
}

assert_file() {      # path label
    if [[ -f $1 ]]; then _pass; else _fail "$2: file missing: $1"; fi
}

assert_contains() {  # needle haystack label
    if [[ $2 == *"$1"* ]]; then _pass; else _fail "$3: output does not contain '$1'"; fi
}

finish() {
    if [[ $FAILURES -gt 0 ]]; then
        printf '%s: %d/%d assertions FAILED\n' "${TEST_FILE_NAME:-test}" "$FAILURES" "$ASSERTIONS" >&2
        exit 1
    fi
    printf '%s: %d assertions OK\n' "${TEST_FILE_NAME:-test}" "$ASSERTIONS"
}

make_tmpdir() {
    mktemp -d "${TMPDIR:-/tmp}/immos-test.XXXXXX"
}
