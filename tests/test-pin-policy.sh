#!/usr/bin/env bash
# What "pinned" is allowed to mean (plan/15).
#
# Every pin in this build failed SILENTLY before it was made to bind: an empty BUILDER_DIGEST
# only warned, the tree revert died with its container, and the package gate stripped versions
# before diffing. None of those produced an error — they produced a different image. So the
# properties are asserted here, offline, in the same shape as tests/test-binpkg-policy.sh.
export TEST_FILE_NAME=test-pin-policy
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e
load_config

# Per build profile (plan/16 §3.3). The default profile's lock is the one every other
# assertion here is about; a second profile gets its own file by the same rules.
IMAGE_LOCK="$REPO_ROOT/config/portage/lock/${BUILD_PROFILE}.lock"
BUILDER_LOCK="$REPO_ROOT/config/portage/lock/builder.lock"
APPS_LOCK="$REPO_ROOT/config/flatpak/apps.lock"

# ---- the pins are recorded, and well-formed ----------------------------------------------
assert_match '^sha256:[0-9a-f]{64}$' "$BUILDER_DIGEST" "BUILDER_DIGEST is a full sha256 digest"
assert_match '^[0-9]{8}$' "$SNAPSHOT_DATE" "SNAPSHOT_DATE is YYYYMMDD"
assert_match '^[0-9a-f]{64}$' "$SNAPSHOT_SHA256" "SNAPSHOT_SHA256 is a full sha256"
# A truncated or absent hash is a pin that cannot be checked, which is the whole point of
# vendoring the snapshot.
assert_false "validate_config rejects a truncated SNAPSHOT_SHA256" \
    bash -c 'source "'"$REPO_ROOT"'/scripts/lib/common.sh"; load_config; SNAPSHOT_SHA256=c612940; validate_config' 2>/dev/null
assert_false "validate_config rejects an empty SNAPSHOT_SHA256" \
    bash -c 'source "'"$REPO_ROOT"'/scripts/lib/common.sh"; load_config; SNAPSHOT_SHA256=; validate_config' 2>/dev/null

# The tree must be a full-Manifest rsync snapshot, not a git forge tarball of the development
# repo. That distinction cost a 90-minute build: gentoo-mirror/gentoo has md5-cache and a
# plausible timestamp.chk, passes every other check, and then fails in stage 30 with "A file is
# not listed in the Manifest" because its Manifests hold only DIST lines. Both the fetch path
# and the validator must check for an EBUILD entry.
assert_true "tree_validate checks Manifests carry EBUILD entries" \
    grep -q "grep -q '\^EBUILD ' \"\$probe\"" "$REPO_ROOT/scripts/lib/common.sh"
assert_true "the builder's tree fetch asserts full Manifests too" \
    grep -q "grep -q '\^EBUILD ' /var/db/repos/gentoo/sys-apps/systemd/Manifest" "$REPO_ROOT/builder/Dockerfile"
assert_true "the tree comes from a verified rsync snapshot, not a forge tarball" \
    grep -q 'emerge-webrsync --revert' "$REPO_ROOT/builder/Dockerfile"
if grep -q 'codeload' "$REPO_ROOT/builder/Dockerfile" 2>/dev/null; then
    _fail "builder fetches the tree from a git forge — those are thin-Manifest dev-repo trees"
else _pass; fi

# ---- lock file shape ----------------------------------------------------------------------
for f in "$IMAGE_LOCK" "$BUILDER_LOCK"; do
    n="$(basename "$f")"
    assert_file "$f" "$n exists"
    [[ -f $f ]] || continue
    bad="$(lock_atoms "$f" | grep -vE '^=[a-z0-9-]+/[A-Za-z0-9._+-]+-[0-9]' || true)"
    if [[ -n $bad ]]; then _fail "$n has malformed atoms: $(head -3 <<< "$bad" | tr '\n' ' ')"; else _pass; fi
    # Sorted and unique, so a diff of two locks is a diff of their contents and not of their order.
    if diff -q <(lock_atoms "$f") <(lock_atoms "$f" | LC_ALL=C sort -u) >/dev/null; then _pass
    else _fail "$n is not sorted/unique"; fi
    # World-readable: mktemp gives 0600 and mv preserves it, so a lock written without an
    # explicit chmod is unreadable by anyone but its author while git records 100644.
    assert_true "$n is world-readable" test -r "$f"
    perm="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
    assert_match '^6?44$' "$perm" "$n has sane permissions (got ${perm:-unknown})"
    # The header is the whole reason a lock is reviewable rather than merely trusted.
    assert_eq "$SNAPSHOT_DATE" "$(lock_header_value "$f" SNAPSHOT_DATE)" "$n header records the tree pin"
    assert_eq "$(portage_config_hash)" "$(lock_header_value "$f" PORTAGE_CONFIG_HASH)" \
        "$n header records the CURRENT portage config hash"
done

# ---- portage_config_hash must not hash what it constrains ---------------------------------
# The locks record the hash they were generated under, so hashing the locks would make that
# value depend on the file recording it: a hash nothing can reproduce and a guard that fires
# on every relock forever. expected-packages.txt is excluded for the same reason, one step
# weaker. Both exclusions are asserted because dropping either reintroduces the loop silently.
CH_SRC="$(sed -n '/^portage_config_hash()/,/^}/p' "$REPO_ROOT/scripts/lib/common.sh")"
assert_contains "expected-packages*" "$CH_SRC" "portage_config_hash excludes every expected-packages file"
assert_contains "config/portage/lock" "$CH_SRC" "portage_config_hash excludes the lock directory"
# ...and it must not depend on WHERE the repo is checked out. sha256sum prints the filename
# beside the digest, so hashing absolute paths made the host and the container compute two
# different hashes for one identical config. Harmless while the value only ever travelled
# container-to-container; a live bug the moment a lock file records it.
CLONE="$TMP/elsewhere"
mkdir -p "$CLONE"
cp -r "$REPO_ROOT/config" "$CLONE/"
here="$(portage_config_hash)"
there="$(REPO="$CLONE" portage_config_hash)"
assert_eq "$here" "$there" "portage_config_hash does not depend on the checkout path"

# ...and prove the exclusion behaviourally, not just by grep.
before="$(portage_config_hash)"
echo "# scratch" >> "$IMAGE_LOCK"
after="$(portage_config_hash)"
sed -i '$ d' "$IMAGE_LOCK"
assert_eq "$before" "$after" "editing a lock does not change portage_config_hash"

# ---- the two locks must not disagree about a shared package -------------------------------
# Portage's multi-root depgraph evaluates target packages against "/"'s config too (see the
# long note in builder/Dockerfile), so a package at two different versions across the roots can
# surface as a phantom slot conflict blamed on something unrelated.
#
# sys-apps/portage is the one accepted divergence and is listed rather than tolerated silently:
# the builder's copy comes from the stage3 and is never re-emerged, while the target resolves
# the tree's best. It never ships either way — stage 50 unmerges it from the image.
ALLOWED_DIVERGENCE=(sys-apps/portage)
keyed() { lock_atoms "$1" | awk '{n=$0; sub(/^=/,"",n); sub(/-[0-9][^\/]*$/,"",n); print n" "$0}' | LC_ALL=C sort; }
div="$(LC_ALL=C join <(keyed "$IMAGE_LOCK") <(keyed "$BUILDER_LOCK") \
        | awk '$2 != $3 {print $1}' \
        | grep -vxF "$(printf '%s\n' "${ALLOWED_DIVERGENCE[@]}")" || true)"
if [[ -n $div ]]; then
    _fail "image.lock and builder.lock disagree on: $(tr '\n' ' ' <<< "$div")— relock both, or add to ALLOWED_DIVERGENCE with a reason"
else _pass; fi

# ---- expected-packages.txt is a subset of the version-stripped image.lock ------------------
# The lock pins versions upstream of the prune; expected-packages.txt gates the set the prune
# leaves behind. The second is therefore a subset of the first, and checking it here catches a
# mismatch offline instead of at stage 50 after a full build. Both sides strip versions with
# the same expression, so they cannot disagree about where a version starts.
notlocked="$(LC_ALL=C comm -23 \
    <(grep -v '^#' "$REPO_ROOT/config/portage/expected-packages.${BUILD_PROFILE}.txt" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(lock_atoms "$IMAGE_LOCK" | sed -E 's/^=//; s/-[0-9][^\/]*$//' | LC_ALL=C sort -u) || true)"
if [[ -n $notlocked ]]; then
    _fail "expected-packages.txt names packages absent from image.lock: $(tr '\n' ' ' <<< "$notlocked")"
else _pass; fi

# ---- the flatpak lock ----------------------------------------------------------------------
assert_file "$APPS_LOCK" "apps.lock exists"
if [[ -f $APPS_LOCK ]]; then
    bad="$(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d' \
            | grep -vE '^(app|runtime)/[A-Za-z0-9._-]+/[a-z0-9_]+/[A-Za-z0-9._-]+ [0-9a-f]{64}$' || true)"
    if [[ -n $bad ]]; then _fail "apps.lock malformed: $(head -2 <<< "$bad")"; else _pass; fi
    # Runtimes are most of the shipped bytes. An apps-only lock would leave nearly all of
    # /var/lib/flatpak unpinned while looking complete.
    assert_true "apps.lock pins runtimes, not just apps" grep -q '^runtime/' "$APPS_LOCK"
    # Every app named in build.conf must actually be pinned.
    fp_ok=1
    for a in $FLATPAK_PREINSTALL; do
        grep -q "^app/$a/" "$APPS_LOCK" || { _fail "apps.lock does not pin $a"; fp_ok=0; }
    done
    [[ $fp_ok == 1 ]] && _pass
fi

# ---- the pipeline actually consumes all of this --------------------------------------------
DF="$REPO_ROOT/builder/Dockerfile"
assert_false "builder no longer syncs an unpinned tree" grep -qE '^RUN emerge-webrsync' "$DF"
assert_true "builder asserts the fetched tree has md5-cache" grep -q 'metadata/md5-cache' "$DF"
# The ARG must precede the RUN, or the layer has no cache buster and never invalidates —
# which is the exact bug this replaced.
arg_line="$(grep -n '^ARG SNAPSHOT_DATE' "$DF" | head -n1 | cut -d: -f1)"
# The RUN that syncs, not the comment that explains it: match a non-comment line, or this
# passes on prose and proves nothing.
run_line="$(grep -n 'emerge-webrsync --revert' "$DF" | grep -v ':[[:space:]]*#' | head -n1 | cut -d: -f1)"
assert_true "ARG TREE_COMMIT precedes the fetch (cache buster)" \
    test -n "$arg_line" -a -n "$run_line" -a "$arg_line" -lt "$run_line"
assert_true "builder emerges the locked set" grep -q 'locked-builder' "$DF"
# The builder must COPY only its own lock. Copying the directory keys the layer on image.lock
# too, so relocking the IMAGE would invalidate the builder layer and the ~1 hour of source
# builds behind it — for a file the builder never reads.
assert_true "builder COPYs only builder.lock, not the lock directory" \
    grep -q 'COPY config/portage/lock/builder.lock' "$DF"
if grep -qE '^COPY config/portage/lock/ ' "$DF"; then
    _fail "builder COPYs the whole lock dir — image.lock would bust the builder layer"
else _pass; fi

S10="$REPO_ROOT/scripts/stages/10-fetch.sh"
assert_true "stage 10 reconciles the tree volume against the pin" grep -q 'tree_populate' "$S10"
assert_true "stage 10 asserts the pin" grep -q 'tree_assert' "$S10"
assert_true "stage 10 checks the builder closure against builder.lock" grep -q 'builder.lock' "$S10"

S20="$REPO_ROOT/scripts/stages/20-builder-setup.sh"
assert_true "stage 20 asserts the tree pin before resolving" grep -q 'tree_assert' "$S20"
assert_true "stage 20 writes the locked-image set" grep -q 'sets/locked-image' "$S20"
assert_true "stage 20 pre-flights the lock against the tree's md5-cache" grep -q 'md5-cache' "$S20"

S30="$REPO_ROOT/scripts/stages/30-target-rootfs.sh"
assert_true "stage 30 emerges the lock when one exists" grep -q '@locked-image' "$S30"
assert_true "stage 30 diffs the result against the lock" grep -q 'lock_diff' "$S30"

S40="$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 deploys the locked flatpak commits" grep -q -- '--commit=' "$S40"
assert_true "stage 40 reads the deployed commits back" grep -q 'columns=ref,active' "$S40"

S80="$REPO_ROOT/scripts/stages/80-release.sh"
assert_true "stage 80 writes provenance" grep -q 'provenance.txt' "$S80"
assert_true "stage 80 refuses to release an unpinned build" grep -q 'unpinned-build' "$S80"

S90="$REPO_ROOT/scripts/stages/90-vendor.sh"
assert_file "$S90" "stage 90 exists"
assert_true "stage 90 no-ops unless VENDOR=1" grep -q 'VENDOR:-0' "$S90"
# Two properties, both of which the archive's completeness depends on: the fetch must consider
# the whole closure (a fresh empty root, not the populated target), and it must not let a binpkg
# satisfy a package — that is exactly how /cache/distfiles came to be incomplete in the first
# place, since a binary merge never looks at SRC_URI.
assert_true "stage 90 fetches against a fresh empty root" grep -q 'FETCH_ROOT' "$S90"
assert_true "stage 90 does not let binpkgs satisfy the fetch" \
    grep -q -- '--fetchonly --usepkg=n' "$S90"
assert_true "stage 90 archives the flatpak objects" grep -q 'create-usb' "$S90"

# relock.sh --security. glsa-check answers "This system is not affected by any of the listed
# GLSAs", exit 0, against an EMPTY root exactly as cheerfully as against a clean one — and stage
# 50 DELETES $TARGET/var/db/pkg at the end of every build, so pointing detection at $TARGET
# returned a silent all-clear for a release nothing had ever actually checked. Detection reads
# image.lock instead, which is both always present and the authoritative record of the release.
RELOCK="$REPO_ROOT/scripts/relock.sh"
SEC_BLOCK="$(sed -n '/MODE == security/,/^fi$/p' "$RELOCK")"
assert_true "relock.sh detects GLSAs from the lock" grep -q 'glsa_vdb "\$PROFILE_LOCK"' "$RELOCK"
assert_false "relock.sh never points glsa-check at the target root" \
    grep -q 'ROOT="\$TARGET"' <(printf '%s\n' "$SEC_BLOCK")
assert_true "…and reads SLOT from the tree, which GLSA atoms match on" \
    grep -q 'md5-cache' "$RELOCK"
assert_true "relock.sh refuses to relock into an empty target root" \
    grep -q 'VDB_N > 0' "$RELOCK"

# relock.sh re-execs itself into the builder with no arguments and passes the mode in the
# environment. A top-level "MODE=atoms" default therefore CLOBBERED it: every mode reached the
# container as "atoms", so --security skipped GLSA detection, released nothing, emerged nothing,
# and still printed the "review the diff and commit it" epilogue. A column-0 MODE= assignment is
# the signature of that bug returning.
assert_false "relock.sh does not default MODE before it dispatches" grep -q '^MODE=atoms' "$RELOCK"
assert_true "relock.sh's container half requires MODE to be passed in" \
    grep -q 'MODE:?relock.sh: MODE is unset' "$RELOCK"

BUILD="$REPO_ROOT/scripts/build.sh"
assert_true "build.sh mounts the tree volume at /var/db/repos" grep -q '/var/db/repos' "$BUILD"
assert_true "build.sh builds from the repo root with -f" grep -q -- '-f "\$REPO_ROOT/builder/Dockerfile"' "$BUILD"
assert_true "build.sh passes the tree pin as a build-arg" grep -q 'SNAPSHOT_DATE=\$SNAPSHOT_DATE' "$BUILD"
assert_true "build.sh isolates the network when --offline" grep -q -- '--network none' "$BUILD"
assert_true "build.sh loads the archived builder rather than building it offline" \
    grep -q 'builder-image.tar.zst' "$BUILD"
assert_file "$REPO_ROOT/.dockerignore" ".dockerignore exists (context is now the repo root)"
assert_true ".dockerignore keeps out/ out of the build context" grep -qx 'out/' "$REPO_ROOT/.dockerignore"

# An unpinned base must be a hard failure, not the warning it used to be. Asserted by source
# rather than by running build.sh: BUILDER_DIGEST comes from build.conf and has no env
# override, so a behavioural test would have to rewrite the repo's own config.
assert_true "build.sh dies on an empty BUILDER_DIGEST" \
    grep -q 'BUILDER_DIGEST is empty' "$BUILD"
assert_true "…with ALLOW_UNPINNED as the deliberate escape" grep -q 'ALLOW_UNPINNED' "$BUILD"

finish
