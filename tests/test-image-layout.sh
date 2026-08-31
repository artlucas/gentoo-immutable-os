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

# ---- EROFS must not flatten ownership -------------------------------------------
# mkfs.erofs --all-root forces every inode to uid 0 AND gid 0. The gid half broke three things
# at once, all silently and all far from the cause: dbus-daemon (user messagebus) could no
# longer execute its own 4710 root:messagebus launch helper, so every DBus-ACTIVATED system
# service failed — which is what left Calamares' disk picker empty, KPMcore enumerating disks
# through exactly that activation; polkitd (uid 102, NoNewPrivileges, no CAP_DAC_OVERRIDE)
# could not read a root-owned 0700 rules.d, so every .rules file in the image was ignored; and
# unix_chkpwd lost gid shadow, so PAM could not verify a password for a non-root caller.
# See plan/04 step 1 and the note above mkfs.erofs in stage 60.
STAGE60="$REPO_ROOT/scripts/stages/60-image.sh"
# Anchored at column 0: the real invocation is top-level, and an indented match would also pick
# up the die message below it, which names --all-root on purpose. Reading your own error text as
# if it were code is exactly the false positive this suite has been bitten by before.
mkfs_line="$(grep -E '^mkfs\.erofs ' "$STAGE60")"
assert_true  "stage 60 still invokes mkfs.erofs"  test -n "$mkfs_line"
assert_false "mkfs.erofs invocation is free of --all-root" \
  grep -q -- '--all-root' <<<"$mkfs_line"
assert_match 'dump\.erofs' "$(grep -E '^require_cmds' "$STAGE60")" \
  "stage 60 requires dump.erofs for the ownership check"
assert_contains 'ownership lost in the image' "$(cat "$STAGE60")" \
  "stage 60 verifies ownership survived into the EROFS"

# The real round trip, when the tools are here (they are in the builder container; a bare host
# skips). Negative control included: the same tree built WITH --all-root must fail the check,
# otherwise this test would pass against a broken image.
if command -v mkfs.erofs >/dev/null 2>&1 && command -v dump.erofs >/dev/null 2>&1; then
  ETREE="$TMP/etree"; mkdir -p "$ETREE/usr/libexec"
  echo helper > "$ETREE/usr/libexec/helper"
  # gid 101 is messagebus in the target; any non-zero gid exercises the same path. chgrp needs
  # privileges we may not have on a dev host — skip the round trip rather than fail on that.
  if chgrp 101 "$ETREE/usr/libexec/helper" 2>/dev/null; then
    erofs_gid() {   # image -> gid of /usr/libexec/helper
      dump.erofs --path=/usr/libexec/helper "$1" 2>/dev/null \
        | sed -n 's/^Uid:.*Gid: *\([0-9]\{1,\}\).*/\1/p'
    }
    mkfs.erofs -T1755648000 "$TMP/keep.erofs" "$ETREE" >/dev/null 2>&1
    assert_eq 101 "$(erofs_gid "$TMP/keep.erofs")" "erofs preserves gid without --all-root"
    mkfs.erofs -T1755648000 --all-root "$TMP/flat.erofs" "$ETREE" >/dev/null 2>&1
    assert_eq 0 "$(erofs_gid "$TMP/flat.erofs")" "negative control: --all-root does flatten gid"
  fi
fi

finish
