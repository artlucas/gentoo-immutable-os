#!/usr/bin/env bash
# build.sh --dry-run: verifies the orchestrator wires stages, mounts, env
# pass-through and flags correctly — without executing anything.
export TEST_FILE_NAME=test-build-dryrun
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

BUILD="$REPO_ROOT/scripts/build.sh"

run_build() { bash "$BUILD" --dry-run --runtime docker "$@" 2>&1; }

out="$(run_build)"; rc=$?
assert_eq 0 $rc "dry-run exits 0"
assert_contains "DRY-RUN: docker build" "$out" "builder image build planned"
for s in 10-fetch 20-builder-setup 30-target-rootfs 40-configure 50-prune 60-image 70-test 80-release; do
    assert_contains "stages/$s.sh" "$out" "stage $s dispatched"
done
assert_contains "--privileged" "$out" "privileged container"
assert_contains "/repo:ro" "$out" "repo mounted read-only"
assert_contains "-work:/work" "$out" "work volume mounted"
assert_contains "-cache:/cache" "$out" "cache volume mounted"

out="$(run_build --from 60)"
assert_contains "skip 10-fetch" "$out" "--from skips earlier stages"
assert_contains "stages/60-image.sh" "$out" "--from runs target stage"
assert_contains "stages/70-test.sh" "$out" "--from runs later stages"
if [[ $out == *"stages/30-target-rootfs.sh"* ]]; then _fail "--from must not run stage 30"; else _pass; fi

out="$(run_build --only 60)"
assert_contains "stages/60-image.sh" "$out" "--only runs the stage"
if [[ $out == *"stages/70-test.sh"* ]]; then _fail "--only must not run other stages"; else _pass; fi

out="$(run_build --console-only --version 0.9.9)"
assert_contains "CONSOLE_ONLY=1" "$out" "--console-only exported to container"
assert_contains "VERSION_OVERRIDE=0.9.9" "$out" "--version exported to container"

out="$(bash "$BUILD" --dry-run --runtime docker --version bogus 2>&1)"; rc=$?
assert_eq 1 $rc "invalid --version rejected by config validation"

out="$(bash "$BUILD" --list --runtime docker 2>&1)"
assert_contains "60-image.sh" "$out" "--list enumerates stages"

out="$(bash "$BUILD" --dry-run --runtime bogus 2>&1)"; rc=$?
assert_eq 1 $rc "invalid runtime rejected"

finish
