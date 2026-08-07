#!/usr/bin/env bash
# enter.sh — interactive debug shell inside the builder container with the same
# mounts as a stage run. For post-mortem after a failed stage.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
export REPO="$REPO_ROOT" OUT="$REPO_ROOT/out"
export STAGE_NAME=enter
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
case "$(uname -s)" in MINGW*|MSYS*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*';; esac
load_config

RUNTIME="${1:-docker}"
exec "$RUNTIME" run --rm -it --privileged \
  -v "$REPO_ROOT":/repo:ro \
  -v "${DISTRO_ID}-work":/work \
  -v "${DISTRO_ID}-cache":/cache \
  -v "$OUT":/out \
  "${DISTRO_ID}-builder" -l
