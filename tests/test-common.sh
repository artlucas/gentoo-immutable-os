#!/usr/bin/env bash
# Unit tests for scripts/lib/common.sh pure functions.
export TEST_FILE_NAME=test-common
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort

# ---- config loads and validates -------------------------------------------------
( load_config ) >/dev/null 2>&1
assert_eq 0 $? "load_config accepts the committed build.conf"

( VERSION_OVERRIDE=9.9.9; load_config >/dev/null 2>&1; [[ $VERSION == 9.9.9 ]] )
assert_eq 0 $? "VERSION_OVERRIDE takes effect"

( VERSION_OVERRIDE=not-a-version; load_config ) >/dev/null 2>&1
assert_eq 1 $? "bad VERSION override rejected"

# ---- versions ---------------------------------------------------------------------
assert_true  "version_valid 1.2.3"      version_valid 1.2.3
assert_false "version_valid 1.2"        version_valid 1.2
assert_false "version_valid v1.2.3"     version_valid v1.2.3
assert_true  "0.2.0 > 0.1.9"            version_gt 0.2.0 0.1.9
assert_true  "0.10.0 > 0.9.0 (numeric)" version_gt 0.10.0 0.9.0
assert_false "equal versions not gt"    version_gt 1.0.0 1.0.0
assert_false "0.9.0 !> 0.10.0"          version_gt 0.9.0 0.10.0

# ---- templates -----------------------------------------------------------------------
printf 'id=@FOO@ name="@BAR_BAZ@" keep=@v tail' > "$TMP/t.in"
FOO=alpha BAR_BAZ="two words" render_template "$TMP/t.in" "$TMP/t.out"
assert_eq 'id=alpha name="two words" keep=@v tail' "$(cat "$TMP/t.out")" "token replacement"

printf 'x=@UNSET_TOKEN@\n' > "$TMP/u.in"
( render_template "$TMP/u.in" "$TMP/u.out" ) >/dev/null 2>&1
assert_eq 1 $? "unset template variable dies"

printf 'line1\nline2\n' > "$TMP/n.in"
render_template "$TMP/n.in" "$TMP/n.out"
assert_eq "$(printf 'line1\nline2\n' | od -c | head -c 200)" "$(od -c < "$TMP/n.out" | head -c 200)" "trailing newline preserved"

# ---- render_dest_name ------------------------------------------------------------------
load_config
assert_eq "${DISTRO_ID}-update"          "$(render_dest_name distro-update.in)"      "rename+strip .in"
assert_eq "${DISTRO_ID}-boot-ok.service" "$(render_dest_name distro-boot-ok.service.in)" "unit rename"
assert_eq "50-${DISTRO_ID}.preset"       "$(render_dest_name 50-distro.preset.in)"   "mid-name token rename"
assert_eq "fstab"                        "$(render_dest_name fstab)"                 "plain file untouched"
assert_eq "os-release"                   "$(render_dest_name os-release.in)"         "strip .in only"

# ---- layout math ---------------------------------------------------------------------------
compute_layout 1024 6144 4096
assert_eq 1     "$P1_START_MIB" "ESP starts at 1MiB"
assert_eq 1025  "$P2_START_MIB" "slot A offset"
assert_eq 7169  "$P3_START_MIB" "slot B offset"
assert_eq 13313 "$P4_START_MIB" "var offset"
assert_eq 17410 "$TOTAL_MIB"    "total size (incl. trailing GPT slack)"

script="$(emit_sfdisk_script 0.1.0)"
assert_contains 'label: gpt' "$script" "sfdisk header"
assert_contains 'name="root_0.1.0"' "$script" "versioned root label"
assert_contains 'name="_empty"' "$script" "empty slot B label"
assert_contains "$GPT_TYPE_ESP" "$script" "ESP type GUID"
assert_contains "$GPT_TYPE_VAR" "$script" "var type GUID"
assert_eq 2 "$(grep -c "$GPT_TYPE_ROOT_X64" <<<"$script")" "two root-typed partitions"

# ---- filter_set_file --------------------------------------------------------------------------
printf 'pkg/a\npkg/cjk-thing  #cjk\npkg/print-thing #printing\n# comment\n' > "$TMP/set"
INCLUDE_CJK_FONTS=0 INCLUDE_PRINTING=1 filter_set_file "$TMP/set" "$TMP/set.out"
assert_false "cjk line dropped"    grep -q cjk-thing "$TMP/set.out"
assert_true  "printing line kept"  grep -q print-thing "$TMP/set.out"
assert_false "marker comment stripped from kept line" grep -q '#printing' "$TMP/set.out"
assert_true  "plain line kept"     grep -q 'pkg/a' "$TMP/set.out"

# ---- inputs_hash ---------------------------------------------------------------------------------
printf 'aaa' > "$TMP/h1"; printf 'bbb' > "$TMP/h2"
h_a="$(inputs_hash "$TMP/h1" "$TMP/h2")"
h_b="$(inputs_hash "$TMP/h1" "$TMP/h2")"
assert_eq "$h_a" "$h_b" "hash is stable"
printf 'ccc' > "$TMP/h2"
h_c="$(inputs_hash "$TMP/h1" "$TMP/h2")"
assert_true "hash changes with content" test "$h_a" != "$h_c"
h_d="$(STAGE_INPUTS_EXTRA=x inputs_hash "$TMP/h1")"
h_e="$(STAGE_INPUTS_EXTRA=y inputs_hash "$TMP/h1")"
assert_true "hash changes with extra input" test "$h_d" != "$h_e"

finish
