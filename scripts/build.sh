#!/usr/bin/env bash
# build.sh — host entrypoint. Builds the builder container and dispatches the pipeline
# stages into it (one container run per stage: clean logs, clean resume).
#
#   ./scripts/build.sh                     # full build, all stages
#   ./scripts/build.sh --from 40           # resume from stage 40
#   ./scripts/build.sh --only 60           # re-run just stage 60
#   ./scripts/build.sh --console-only      # M1 image (no desktop)
#   ./scripts/build.sh --version 0.2.0     # override VERSION for this run
#   ./scripts/build.sh --dry-run           # print what would run, execute nothing
#
# Runtimes: docker (default), podman, none (run stages directly — Linux host that
# already has all tools; used by CI inside a prepared container).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"

export REPO="$REPO_ROOT" OUT="$REPO_ROOT/out" WORK="${WORK:-$REPO_ROOT/out/work}"
export STAGE_NAME=build
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Git Bash: stop MSYS from rewriting /repo-style container paths in docker args.
case "$(uname -s)" in MINGW*|MSYS*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*';; esac

usage() { grep '^#' "$0" | sed -n '2,20p' | sed 's/^# \{0,1\}//'; }

RUNTIME=auto FROM='' ONLY='' DRY_RUN=0 CLEAN=0 FORCE=0 LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)         FROM="$2"; shift 2 ;;
    --only)         ONLY="$2"; FORCE=1; shift 2 ;;
    --clean)        CLEAN=1; shift ;;
    --console-only) export CONSOLE_ONLY=1; shift ;;
    --version)      export VERSION_OVERRIDE="$2"; shift 2 ;;
    --update-url)   export UPDATE_URL_OVERRIDE="$2"; shift 2 ;;
    --no-verify)    export UPDATE_VERIFY_OVERRIDE=0; shift ;;
    --force)        FORCE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --runtime)      RUNTIME="$2"; shift 2 ;;
    --list)         LIST=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

load_config

# ---- stage discovery ---------------------------------------------------------
STAGES=()
for f in "$SCRIPT_DIR"/stages/[0-9][0-9]-*.sh; do
  [[ -e $f ]] || die "no stage scripts found in $SCRIPT_DIR/stages"
  STAGES+=("$(basename -- "$f")")
done

stage_num() { printf '%s' "${1%%-*}"; }

if [[ $LIST == 1 ]]; then
  for s in "${STAGES[@]}"; do echo "$s"; done
  exit 0
fi

# ---- runtime selection ---------------------------------------------------------
if [[ $RUNTIME == auto ]]; then
  if   command -v docker >/dev/null 2>&1; then RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
  else die "no docker/podman found (use --runtime none on a prepared Linux host)"
  fi
fi
[[ $RUNTIME =~ ^(docker|podman|none)$ ]] || die "invalid --runtime: $RUNTIME"

run() {  # print in dry-run mode, execute otherwise
  if [[ $DRY_RUN == 1 ]]; then printf 'DRY-RUN: %s\n' "$*"; else "$@"; fi
}

BUILDER_TAG="${DISTRO_ID}-builder"
WORK_VOL="${DISTRO_ID}-work"
CACHE_VOL="${DISTRO_ID}-cache"

if [[ $CLEAN == 1 ]]; then
  log "cleaning work volume + state (cache volume kept)"
  if [[ $RUNTIME == none ]]; then
    run rm -rf -- "$WORK" "$OUT/state"
  else
    run "$RUNTIME" volume rm -f "$WORK_VOL"
    run rm -rf -- "$OUT/state"
  fi
fi

# ---- pass-through env ------------------------------------------------------------
ENV_ARGS=()
for v in VERSION_OVERRIDE UPDATE_URL_OVERRIDE UPDATE_VERIFY_OVERRIDE CONSOLE_ONLY FORCE_STAGE; do
  [[ -n ${!v:-} ]] && ENV_ARGS+=(-e "$v=${!v}")
done
[[ $FORCE == 1 ]] && ENV_ARGS+=(-e FORCE_STAGE=1)

# ---- builder image -----------------------------------------------------------------
if [[ $RUNTIME != none ]]; then
  base="$BUILDER_IMAGE"
  [[ -n $BUILDER_DIGEST ]] && base="${BUILDER_IMAGE%%:*}@${BUILDER_DIGEST}"
  [[ -z $BUILDER_DIGEST ]] && warn "BUILDER_DIGEST is empty — unpinned base image (dev builds only)"
  run "$RUNTIME" build -t "$BUILDER_TAG" --build-arg "BASE=$base" "$REPO_ROOT/builder"
fi

# ---- dispatch ------------------------------------------------------------------------
KVM_ARGS=()
[[ -e /dev/kvm ]] && KVM_ARGS=(--device /dev/kvm)

rc=0
for s in "${STAGES[@]}"; do
  n="$(stage_num "$s")"
  [[ -n $FROM && $n -lt $FROM ]] && { log "skip $s (< --from $FROM)"; continue; }
  [[ -n $ONLY && $n != "$ONLY" ]] && continue
  log "==== stage $s ===="
  if [[ $RUNTIME == none ]]; then
    run env FORCE_STAGE="${FORCE_STAGE:-$FORCE}" bash "$SCRIPT_DIR/stages/$s"
  else
    run "$RUNTIME" run --rm --privileged \
      "${KVM_ARGS[@]}" \
      -v "$REPO_ROOT":/repo:ro \
      -v "$WORK_VOL":/work \
      -v "$CACHE_VOL":/cache \
      -v "$OUT":/out \
      "${ENV_ARGS[@]}" \
      "$BUILDER_TAG" "/repo/scripts/stages/$s"
  fi || { rc=$?; die "stage $s failed (rc=$rc) — logs in out/logs/, resume with --from $n"; }
done

log "pipeline complete — artifacts in out/"
