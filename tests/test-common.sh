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
# The rewrite is token-wise, not substring-wise: "distrobox" is its own word and must survive
# intact, or /etc/distrobox/distrobox.conf ships as immosbox.conf and distrobox never reads it.
assert_eq "distrobox.conf"               "$(render_dest_name distrobox.conf.in)"     "distro as a substring is NOT rebranded"
assert_eq "distrobox"                    "$(render_dest_name distrobox)"             "bare substring untouched"
assert_eq "${DISTRO_ID}"                 "$(render_dest_name distro)"                "bare token rebranded"

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
printf 'pkg/a\npkg/cjk-thing  #cjk\npkg/print-thing #printing\npkg/box-thing #distrobox\n# comment\n' > "$TMP/set"
INCLUDE_CJK_FONTS=0 INCLUDE_PRINTING=1 INCLUDE_DISTROBOX=1 filter_set_file "$TMP/set" "$TMP/set.out"
assert_false "cjk line dropped"    grep -q cjk-thing "$TMP/set.out"
assert_true  "printing line kept"  grep -q print-thing "$TMP/set.out"
assert_false "marker comment stripped from kept line" grep -q '#printing' "$TMP/set.out"
assert_true  "plain line kept"     grep -q 'pkg/a' "$TMP/set.out"
assert_true  "distrobox line kept when INCLUDE_DISTROBOX=1" grep -q box-thing "$TMP/set.out"
assert_false "distrobox marker stripped from kept line" grep -q '#distrobox' "$TMP/set.out"

# ...and the other way round: the switch has to actually remove the packages, or an
# INCLUDE_DISTROBOX=0 image silently ships the whole container stack anyway.
INCLUDE_CJK_FONTS=1 INCLUDE_PRINTING=1 INCLUDE_DISTROBOX=0 filter_set_file "$TMP/set" "$TMP/set.off"
assert_false "distrobox line dropped when INCLUDE_DISTROBOX=0" grep -q box-thing "$TMP/set.off"
assert_true  "cjk line kept when its own switch is 1"          grep -q cjk-thing "$TMP/set.off"
assert_true  "plain line still kept"                           grep -q 'pkg/a'   "$TMP/set.off"

# Unset must mean 1, in filter_set_file and validate_config alike — a build.conf written
# before this knob existed still has to produce the same image the default does.
( unset INCLUDE_DISTROBOX; filter_set_file "$TMP/set" "$TMP/set.unset" )
assert_true "distrobox line kept when the switch is unset" grep -q box-thing "$TMP/set.unset"

# ---- seed_merged_usr -------------------------------------------------------------------------
# The exact stage3 shape, asserted link by link. Getting /usr/sbin wrong produced an image with
# no console login at all and nothing red anywhere (see the function's own comment), so "it
# booted" is not evidence this is right — only the link targets are.
SEED="$TMP/seedroot"; mkdir -p "$SEED"
seed_merged_usr "$SEED"
assert_eq "usr/bin"   "$(readlink "$SEED/bin")"      "/bin -> usr/bin"
assert_eq "usr/bin"   "$(readlink "$SEED/sbin")"     "/sbin -> usr/bin (NOT usr/sbin)"
assert_eq "usr/lib"   "$(readlink "$SEED/lib")"      "/lib -> usr/lib"
assert_eq "usr/lib64" "$(readlink "$SEED/lib64")"    "/lib64 -> usr/lib64"
assert_eq "bin"       "$(readlink "$SEED/usr/sbin")" "/usr/sbin -> bin (sbin is merged)"
assert_true "/usr/bin is a real directory" test -d "$SEED/usr/bin" -a ! -L "$SEED/usr/bin"
# The property all of that exists for: a binary installed to any sbin path is reachable at the
# /usr/bin path every Gentoo systemd unit hardcodes.
: > "$SEED/usr/sbin/agetty"
assert_true "a binary installed to /usr/sbin resolves at /usr/bin" test -e "$SEED/usr/bin/agetty"
assert_true "...and at /sbin"                                      test -e "$SEED/sbin/agetty"
# Idempotent: stage 30 is resumable and calls this on every run.
seed_merged_usr "$SEED"
assert_eq "bin" "$(readlink "$SEED/usr/sbin")" "re-seeding leaves /usr/sbin alone"
# A pre-existing REAL /usr/sbin is the old broken layout and must be refused, not silently kept.
SPLIT="$TMP/splitroot"; mkdir -p "$SPLIT/usr/sbin"
assert_false "a real /usr/sbin is rejected" \
    bash -c 'source "$1"/scripts/lib/common.sh 2>/dev/null; seed_merged_usr "$2"' _ "$REPO_ROOT" "$SPLIT"

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

# ---- prune_binhost_binpkgs -------------------------------------------------------------------
# A binhost gpkg is a tar with *.sig members alongside the payload; one this pipeline built has
# no signature. Both shapes are fabricated here — the point of the function is telling them
# apart without a portage, so the test does not need one either.
PKG="$TMP/pkgdir"
mk_gpkg() {          # DIR CPV SIGNED
    local dir=$1 cpv=$2 signed=$3 stage
    stage="$TMP/stage/$cpv"   # separate line: bash expands the whole `local` before assigning
    rm -rf -- "$TMP/stage"; mkdir -p "$stage"
    : > "$stage/gpkg-1"; : > "$stage/metadata.tar.xz"; : > "$stage/image.tar.xz"
    if [[ $signed == signed ]]; then : > "$stage/metadata.tar.xz.sig"; : > "$stage/image.tar.xz.sig"; fi
    mkdir -p "$dir"
    ( cd "$TMP/stage" && tar -cf "$dir/$cpv.gpkg.tar" "$cpv" )
}
mk_gpkg "$PKG/cat-egory" remote-1-1 signed
mk_gpkg "$PKG/cat-egory" local-1-1  unsigned
mk_gpkg "$PKG/oth-er"    remote-2-1 signed
printf 'not a tar' > "$PKG/cat-egory/broken-1-1.gpkg.tar"
printf 'old format'  > "$PKG/cat-egory/legacy-1-1.tbz2"
: > "$PKG/Packages"; : > "$PKG/Packages.gz"

n="$(prune_binhost_binpkgs "$PKG")"
assert_eq 2 "$n" "counts the binhost-signed packages it removed"
assert_false "signed gpkg removed"        test -f "$PKG/cat-egory/remote-1-1.gpkg.tar"
assert_false "signed gpkg removed (2)"    test -f "$PKG/oth-er/remote-2-1.gpkg.tar"
assert_true  "locally built gpkg kept"    test -f "$PKG/cat-egory/local-1-1.gpkg.tar"
assert_true  "unreadable archive kept"    test -f "$PKG/cat-egory/broken-1-1.gpkg.tar"
assert_true  "non-gpkg kept"              test -f "$PKG/cat-egory/legacy-1-1.tbz2"
assert_false "stale index dropped"        test -f "$PKG/Packages"
assert_false "stale index.gz dropped"     test -f "$PKG/Packages.gz"

# idempotent, and a clean cache is left completely alone
: > "$PKG/Packages"
assert_eq 0 "$(prune_binhost_binpkgs "$PKG")" "second pass removes nothing"
assert_true "index kept when nothing was removed" test -f "$PKG/Packages"
assert_eq 0 "$(prune_binhost_binpkgs "$TMP/no-such-pkgdir")" "missing PKGDIR is not an error"

finish
