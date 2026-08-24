#!/usr/bin/env bash
# Where binaries are allowed to come from (plan/02, "Where binaries come from"):
#   builder "/"   — binhost, verified, never compiled without reason
#   image $TARGET — compiled here, or reused from this pipeline's own /cache/binpkgs
# Both directions fail silently in a build log (a binpkg merges like a source build, a source
# build is merely slow), so the split is pinned here instead of being left to review.
export TEST_FILE_NAME=test-binpkg-policy
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e
load_config

# ---- the target config, as stage 20 actually renders it ---------------------------------
JOBS=8 L10N="en de" render_template "$REPO_ROOT/config/portage/make.conf.in" "$TMP/make.conf"
MC="$(cat "$TMP/make.conf")"

assert_true  "target FEATURES caches its own builds (buildpkg)" \
    grep -qE '^[[:space:]]*FEATURES=.*buildpkg' "$TMP/make.conf"
assert_false "target FEATURES must not enable getbinpkg" \
    grep -qE '^[[:space:]]*FEATURES=.*getbinpkg' "$TMP/make.conf"
assert_false "target must not set PORTAGE_BINHOST" \
    grep -qE '^[[:space:]]*PORTAGE_BINHOST=' "$TMP/make.conf"
assert_contains 'PKGDIR="/cache/binpkgs"'   "$MC" "target binpkg cache is the /cache volume"
assert_contains 'DISTDIR="/cache/distfiles"' "$MC" "target distfiles are the /cache volume"
# BINHOST_URI is the builder's key; nothing may substitute it into the target's config.
assert_false "BINHOST_URI does not reach the target config" \
    grep -q "$BINHOST_URI" "$TMP/make.conf"

# ---- the builder is the opposite: binaries, verified -------------------------------------
DF="$REPO_ROOT/builder/Dockerfile"
assert_true "builder enables FEATURES=getbinpkg" grep -q 'FEATURES=.*getbinpkg' "$DF"
assert_true "builder points the binrepo at the BINHOST build-arg" \
    grep -q 'sync-uri' "$DF"
assert_true "builder verifies binpkg signatures" grep -q 'verify-signature = true' "$DF"
assert_true "builder asserts getbinpkg actually took effect" \
    grep -q 'portageq envvar FEATURES' "$DF"
assert_true "builder emerges with --getbinpkg" grep -q 'emerge .*--getbinpkg' "$DF"
# getuto builds the trust store portage checks signatures against; after the emerge it is
# useless — portage would already have fallen back to compiling, silently.
first_getuto="$(grep -n 'getuto' "$DF" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f1)"
first_emerge="$(grep -n '^ && emerge \|^RUN emerge ' "$DF" | head -n1 | cut -d: -f1)"
assert_true "getuto runs before the builder's first emerge" \
    test -n "$first_getuto" -a -n "$first_emerge" -a "$first_getuto" -lt "$first_emerge"

# ---- stage 20: sweeps the cache, refuses a binhost-capable target config ------------------
S20="$REPO_ROOT/scripts/stages/20-builder-setup.sh"
assert_true "stage 20 sweeps binhost binpkgs out of the target cache" \
    grep -q 'prune_binhost_binpkgs /cache/binpkgs' "$S20"
assert_true "stage 20 verify rejects getbinpkg in the rendered target make.conf" \
    grep -q "die \"verify: target make.conf enables getbinpkg" "$S20"
assert_true "stage 20 verify rejects PORTAGE_BINHOST in the rendered target make.conf" \
    grep -q "die \"verify: target make.conf sets PORTAGE_BINHOST" "$S20"

# ---- stage 30: target emerge is source-or-local-cache, builder emerge is binary -----------
S30="$REPO_ROOT/scripts/stages/30-target-rootfs.sh"
target_emerge="$(grep -n 'emerge --verbose' "$S30")"
assert_contains '--usepkg' "$target_emerge" "target emerge may reuse local binpkgs"
if [[ $target_emerge == *"--getbinpkg"* ]]; then
    _fail "target emerge must not pass --getbinpkg: $target_emerge"
else
    _pass
fi
assert_true "buildhost (builder-root) emerge uses the binhost" \
    grep -q 'emerge --oneshot --noreplace --usepkg --getbinpkg' "$S30"
assert_true "stage 30 guards the effective target FEATURES" \
    grep -q 'portageq envvar FEATURES' "$S30"
assert_true "stage 30 guards the effective target PORTAGE_BINHOST" \
    grep -q 'portageq envvar PORTAGE_BINHOST' "$S30"

finish
