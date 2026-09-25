#!/usr/bin/env bash
# Tests for the target-snapshot mechanism (plan/34): the common.sh helpers and the stage-30
# choreography they implement — manifest-gated validity, the restore decision table, the
# post-restore atom-count assertion, and the reconcile drop list. Everything runs against
# fixture trees under a temp WORK; nothing needs docker, portage or a real target.
export TEST_FILE_NAME=test-stage30-snapshot
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort

mkdir -p "$WORK"
load_config   # BUILD_PROFILE=desktop (empty suffix), VERSION, SNAPSHOT_* pins, init_paths

# mk_target ATOM... — a fixture $TARGET whose VDB names the given cat/pkg-ver atoms
mk_target() {
  local a
  rm -rf -- "$TARGET"
  mkdir -p "$TARGET/var/db/pkg" "$TARGET/etc"
  for a in "$@"; do mkdir -p "$TARGET/var/db/pkg/$a"; done
  printf 'sentinel\n' > "$TARGET/etc/marker"
}
ATOMS=(cat/keep-1.0 cat/keep-2.0 cat/drop-3.0)

# ---- path plumbing -----------------------------------------------------------------------
# init_paths suffixes the snapshot paths per profile exactly as it suffixes $TARGET, so desktop
# and installer snapshots cannot cross — the per-profile suffix is what makes cross-profile
# restore a non-scenario.
assert_eq "$WORK/target"        "$TARGET"                "desktop: TARGET keeps the empty suffix"
assert_eq "$WORK/target-snap"   "$TARGET_SNAP"           "desktop: TARGET_SNAP beside TARGET"
assert_eq "$WORK/target-snap.manifest" "$TARGET_SNAP_MANIFEST" "desktop: manifest beside the snapshot dir"
assert_eq "$WORK/.target-snap.tmp"    "$TARGET_SNAP_TMP"    "desktop: write tmp is dotted"
assert_eq "$WORK/.target-restore.tmp" "$TARGET_RESTORE_TMP" "desktop: restore tmp is dotted"
(
  BUILD_PROFILE_OVERRIDE=installer load_config >/dev/null 2>&1
  printf '%s\n%s\n' "$TARGET_SNAP" "$TARGET_SNAP_MANIFEST"
) > "$TMP/inst-paths"
assert_match '^'"$WORK"'/target-snap-installer$' "$(sed -n 1p "$TMP/inst-paths")" "installer: TARGET_SNAP suffixed"
assert_match '^'"$WORK"'/target-snap-installer\.manifest$' "$(sed -n 2p "$TMP/inst-paths")" "installer: manifest suffixed"
assert_true "desktop and installer snapshots are different paths" \
    test "$TARGET_SNAP" != "$(sed -n 1p "$TMP/inst-paths")"

# ---- snapshot_write: the happy path ------------------------------------------------------
mk_target "${ATOMS[@]}"
snapshot_write
assert_true  "snapshot dir written"          test -d "$TARGET_SNAP"
assert_true  "manifest written"              test -f "$TARGET_SNAP_MANIFEST"
assert_true  "write tmp cleaned up"          test ! -e "$TARGET_SNAP_TMP"
assert_eq "3" "$(snapshot_manifest_get VDB_COUNT)"     "manifest records the atom count"
assert_eq "$BUILD_PROFILE" "$(snapshot_manifest_get BUILD_PROFILE)" "manifest records the profile"
assert_eq "$VERSION"       "$(snapshot_manifest_get VERSION)"       "manifest records the version"
for k in TARGET_CLOSURE_HASH PORTAGE_CONFIG_HASH SNAPSHOT_DATE SNAPSHOT_SHA256 TIMESTAMP_UTC; do
  assert_true "manifest key present: $k" test -n "$(snapshot_manifest_get "$k")"
done
assert_true "snapshot content matches the target" diff -r -- "$TARGET" "$TARGET_SNAP" >/dev/null
assert_true "snapshot validity accepts its own output" snapshot_manifest_valid

# the escape hatch: NO_TARGET_SNAPSHOT=1 disables the write half entirely
rm -rf -- "$TARGET_SNAP" "$TARGET_SNAP_MANIFEST"
NO_TARGET_SNAPSHOT=1 snapshot_write
assert_true "NO_TARGET_SNAPSHOT=1 writes nothing" test ! -e "$TARGET_SNAP" -a ! -e "$TARGET_SNAP_MANIFEST"

# ---- snapshot_manifest_valid: what refuses ------------------------------------------------
snapshot_write   # regenerate the good pair

rm -f -- "$TARGET_SNAP_MANIFEST"
assert_false "no manifest -> invalid" snapshot_manifest_valid

printf 'TARGET_CLOSURE_HASH=abc\nBUILD_PROFILE=%s\n' "$BUILD_PROFILE" > "$TARGET_SNAP_MANIFEST"
assert_false "truncated manifest -> invalid" snapshot_manifest_valid

sed "s/^BUILD_PROFILE=.*/BUILD_PROFILE=installer/" "$TARGET_SNAP_MANIFEST" > "$TMP/m.foreign"
mv -- "$TMP/m.foreign" "$TARGET_SNAP_MANIFEST"
assert_false "foreign profile in manifest -> invalid" snapshot_manifest_valid

# an interrupted write: tmp directory populated, old manifest naming content the rm/mv never
# finished replacing (the old snapshot dir is GONE) — the pair reads as absent
sed "s/^BUILD_PROFILE=.*/BUILD_PROFILE=$BUILD_PROFILE/" "$TARGET_SNAP_MANIFEST" > "$TMP/m.ok"
mv -- "$TMP/m.ok" "$TARGET_SNAP_MANIFEST"
rm -rf -- "$TARGET_SNAP"
mkdir -p "$TARGET_SNAP_TMP/cat"
assert_false "interrupted write (tmp dir, no snapshot dir) -> invalid" snapshot_manifest_valid
rm -rf -- "$TARGET_SNAP_TMP"

# ---- snapshot_restore: the §4 decision table ----------------------------------------------
snapshot_write   # good snapshot back in place

# row "VDB present, hash matches": no snapshot read, no cost, target untouched
mk_target "${ATOMS[@]}"
printf '%s' "$(target_closure_hash)" > "$TARGET_HASH_FILE"
printf 'live\n' > "$TARGET/etc/live-marker"
snapshot_restore
assert_eq 0 "$SNAPSHOT_RESTORED" "current closure hash -> no restore"
assert_true "live target untouched" test -f "$TARGET/etc/live-marker"

# row "VDB present, hash file absent (first build)": today's path
rm -f -- "$TARGET_HASH_FILE"
snapshot_restore
assert_eq 0 "$SNAPSHOT_RESTORED" "no hash file yet -> no restore"
assert_true "live target untouched" test -f "$TARGET/etc/live-marker"

# row "VDB missing (post-50), snapshot valid": restore
rm -rf -- "$TARGET/var/db/pkg"
snapshot_restore
assert_eq 1 "$SNAPSHOT_RESTORED" "VDB missing -> restored"
assert_true  "VDB is back"           test -d "$TARGET/var/db/pkg/cat/keep-1.0"
assert_false "post-prune marker gone (restored, not merged onto)" test -e "$TARGET/etc/live-marker"
assert_eq "$(snapshot_manifest_get TARGET_CLOSURE_HASH)" "$(cat "$TARGET_HASH_FILE")" "hash file rewritten from the manifest"
assert_true  "restore tmp cleaned up" test ! -e "$TARGET_RESTORE_TMP"

# row "target absent, snapshot valid": restore
rm -rf -- "$TARGET"
snapshot_restore
assert_eq 1 "$SNAPSHOT_RESTORED" "absent target -> restored"
assert_true "target is the snapshot's tree" test -f "$TARGET/etc/marker"

# row "VDB present, hash mismatch (guard 2's case), snapshot valid": restore — which is what
# makes guard 2's die unreachable in the stage, SNAPSHOT_RESTORED is the arm
printf 'deadbeef' > "$TARGET_HASH_FILE"
snapshot_restore
assert_eq 1 "$SNAPSHOT_RESTORED" "stale closure hash -> restored (guard 2 will not die)"

# row "VDB present, hash mismatch, NO snapshot": the stage's guard 2 must still die — replicate
# its condition with the helper's output
rm -rf -- "$TARGET_SNAP" "$TARGET_SNAP_MANIFEST"
printf 'deadbeef' > "$TARGET_HASH_FILE"
snapshot_restore
assert_eq 0 "$SNAPSHOT_RESTORED" "stale hash, no snapshot -> not restored"
assert_true "guard 2's condition holds (would die)" \
    test -d "$TARGET/var/db/pkg" \
       -a "$(cat "$TARGET_HASH_FILE" 2>/dev/null || echo none)" != none \
       -a "$(cat "$TARGET_HASH_FILE")" != "$(target_closure_hash)" \
       -a "$SNAPSHOT_RESTORED" != 1

# row "VDB missing, NO snapshot": today's path — merge into whatever is there
rm -rf -- "$TARGET/var/db/pkg"
snapshot_restore
assert_eq 0 "$SNAPSHOT_RESTORED" "VDB missing, no snapshot -> not restored"

# an invalid snapshot warns once and degrades to the no-snapshot row; it never dies
mk_target "${ATOMS[@]}"
snapshot_write
rm -rf -- "$TARGET/var/db/pkg"
printf 'VDB_COUNT=3\nBUILD_PROFILE=someone-else\n' > "$TARGET_SNAP_MANIFEST"
snapshot_restore 2> "$TMP/restore.err"
assert_eq 0 "$SNAPSHOT_RESTORED" "invalid manifest -> degrades, no restore"
assert_match 'manifest missing or unreadable' "$(cat "$TMP/restore.err")" "invalid snapshot warns with the escape hatch"

# NO_TARGET_SNAPSHOT=1 disables the restore half: a valid snapshot sits there, untouched
mk_target "${ATOMS[@]}"
snapshot_write
rm -rf -- "$TARGET/var/db/pkg"
NO_TARGET_SNAPSHOT=1 snapshot_restore
assert_eq   0 "$SNAPSHOT_RESTORED" "NO_TARGET_SNAPSHOT=1 never restores"
assert_true "snapshot left alone"   test -d "$TARGET_SNAP"

# ---- interrupted restore -------------------------------------------------------------------
# junk left in the restore tmp by an earlier failed attempt is discarded before the copy, and
# never leaks into the restored target
mk_target "${ATOMS[@]}"
snapshot_write
rm -rf -- "$TARGET/var/db/pkg"
mkdir -p "$TARGET_RESTORE_TMP/junkdir"
printf 'junk\n' > "$TARGET_RESTORE_TMP/junkfile"
snapshot_restore
assert_eq 1 "$SNAPSHOT_RESTORED" "restore proceeds over junk in the tmp dir"
assert_false "junk file did not land in the target" test -e "$TARGET/junkfile"
assert_false "junk dir did not land in the target"  test -e "$TARGET/junkdir"

# ---- the post-restore assertion ------------------------------------------------------------
# a manifest that disagrees with its directory is corruption, not a cache miss: die loudly, and
# the live target is NOT replaced
mk_target "${ATOMS[@]}"
snapshot_write
rm -rf -- "$TARGET_SNAP/var/db/pkg/cat/drop-3.0"   # manifest says 3, directory holds 2
printf 'stays\n' > "$TARGET/etc/live-marker"
rm -rf -- "$TARGET/var/db/pkg"
( snapshot_restore ) > "$TMP/corrupt.out" 2>&1
assert_eq 1 "$?" "count mismatch -> restore dies"
assert_true  "live target NOT replaced" test -f "$TARGET/etc/live-marker"
assert_match 'snapshot is corrupt' "$(cat "$TMP/corrupt.out")" "die names the corruption and the escape"

# ---- the reconcile drop list ----------------------------------------------------------------
# LOCKED-side fixture: a config root whose locked-image set names two of the three VDB atoms
mk_target "${ATOMS[@]}"
mkdir -p "$CONFIG_ROOT/etc/portage/sets"
printf '=cat/keep-1.0\n=cat/keep-2.0\n# a comment line, as lock_write emits above the atoms\n' \
  > "$CONFIG_ROOT/etc/portage/sets/locked-image"
assert_eq "=cat/drop-3.0" "$(reconcile_drop_list)" "drop list is exactly the unnamed atom"

printf '=cat/keep-1.0\n=cat/keep-2.0\n=cat/drop-3.0\n' > "$CONFIG_ROOT/etc/portage/sets/locked-image"
assert_eq "" "$(reconcile_drop_list)" "nothing dropped when the lock names everything"

# normalization: the set's spelling and lock_write's spelling of the same closure must agree
# with the VDB's, or the drop list would see phantom differences
printf '=cat/keep-1.0\n\n=cat/keep-2.0\n=cat/drop-3.0\n' \
  | lock_write "$TMP/generated.lock" "fixture closure"
assert_eq "" "$(comm -3 <(vdb_atoms "$TARGET") <(lock_atoms "$TMP/generated.lock"))" \
  "vdb_atoms and lock_atoms spell the same closure identically"

rm -f -- "$CONFIG_ROOT/etc/portage/sets/locked-image"
assert_false "no locked-image set -> no list" reconcile_drop_list

# (The unmerge itself runs `emerge` inside the stage container and is not offline-testable; the
#  existence-guard + `|| warn` pattern it uses is stage 50 §1's, unchanged.)

finish
