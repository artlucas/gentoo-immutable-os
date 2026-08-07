#!/usr/bin/env bash
# Simulates stage 60's loopless assembly at miniature scale with REAL dd:
# builds a tiny GPT-less byte layout using compute_layout offsets, writes marker
# "partitions", reads them back by offset. Proves the offset math + dd invocation
# pattern without any Linux-only tooling.
export TEST_FILE_NAME=test-image-layout
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort
load_config

# ---- miniature layout: 1 MiB units, same code path as production sizes ---------
compute_layout 2 3 4          # ESP=2MiB, slots=3MiB, var=4MiB
assert_eq 1  "$P1_START_MIB" "mini: esp start"
assert_eq 3  "$P2_START_MIB" "mini: slotA start"
assert_eq 6  "$P3_START_MIB" "mini: slotB start"
assert_eq 9  "$P4_START_MIB" "mini: var start"
assert_eq 14 "$TOTAL_MIB"    "mini: total"

# no partition overlaps, all within disk
assert_true "p1 fits before p2" test $((P1_START_MIB + P1_SIZE_MIB)) -le "$P2_START_MIB"
assert_true "p2 fits before p3" test $((P2_START_MIB + P2_SIZE_MIB)) -le "$P3_START_MIB"
assert_true "p3 fits before p4" test $((P3_START_MIB + P3_SIZE_MIB)) -le "$P4_START_MIB"
assert_true "p4 inside disk"    test $((P4_START_MIB + P4_SIZE_MIB)) -lt "$TOTAL_MIB"

IMG="$TMP/mini.img"
MIB=1048576

# create sized empty image (dd seek trick: no truncate dependency)
dd if=/dev/zero of="$IMG" bs=$MIB seek=$TOTAL_MIB count=0 status=none 2>/dev/null \
  || dd if=/dev/zero of="$IMG" bs=$MIB count=$TOTAL_MIB status=none
actual_size="$(wc -c < "$IMG" | tr -d ' ')"
assert_eq "$((TOTAL_MIB * MIB))" "$actual_size" "image sized exactly TOTAL_MIB"

# marker "filesystems" (ESP marker mimics a FAT jump byte at offset 0)
make_marker() { # file size_mib tag
    printf '%s' "$3" > "$1"
    dd if=/dev/zero of="$1" bs=$MIB seek="$2" count=0 status=none 2>/dev/null || true
}
make_marker "$TMP/esp.img"  2 $'\xebESP-MARKER'
make_marker "$TMP/root.img" 3 'ROOT-MARKER'
make_marker "$TMP/var.img"  4 'VAR-MARKER'

# EXACT dd pattern from stage 60 (ddp)
for spec in "esp.img:$P1_START_MIB" "root.img:$P2_START_MIB" "var.img:$P4_START_MIB"; do
    f="${spec%%:*}"; off="${spec##*:}"
    dd if="$TMP/$f" of="$IMG" bs=$MIB seek="$off" conv=notrunc status=none
done

read_at() { dd if="$IMG" bs=$MIB skip="$1" count=1 status=none | head -c "$2"; }
assert_eq $'\xebESP-MARKER' "$(read_at "$P1_START_MIB" 11)" "ESP lands at p1 offset"
assert_eq 'ROOT-MARKER'     "$(read_at "$P2_START_MIB" 11)" "root lands at p2 offset"
assert_eq 'VAR-MARKER'      "$(read_at "$P4_START_MIB" 10)" "var lands at p4 offset"
# slot B stays zeroed
assert_eq '' "$(read_at "$P3_START_MIB" 16 | tr -d '\0')" "slot B untouched"
# dd with conv=notrunc must not grow the image
assert_eq "$((TOTAL_MIB * MIB))" "$(wc -c < "$IMG" | tr -d ' ')" "image size unchanged after writes"

# ---- production-size sanity re-check against build.conf ---------------------------
compute_layout "$ESP_SIZE_MIB" "$ROOT_SLOT_SIZE_MIB" "$VAR_SIZE_MIB"
script="$(emit_sfdisk_script "$VERSION")"
assert_eq 4 "$(grep -c '^start=' <<<"$script")" "four partitions emitted"
assert_contains "name=\"root_${VERSION}\"" "$script" "current version in root label"
# sfdisk script offsets match compute_layout
assert_contains "start=${P2_START_MIB}MiB" "$script" "slot A offset consistent"
assert_contains "start=${P4_START_MIB}MiB" "$script" "var offset consistent"

finish
