#!/usr/bin/env bash
# build.sh — host entrypoint. Builds the builder container and dispatches the pipeline
# stages into it (one container run per stage: clean logs, clean resume).
#
#   ./scripts/build.sh                     # full build, all stages
#   ./scripts/build.sh --from 40           # resume from stage 40
#   ./scripts/build.sh --only 60           # re-run just stage 60
#   ./scripts/build.sh --profile console   # build a different profile (default: desktop)
#   ./scripts/build.sh --list-profiles     # what profiles exist
#   ./scripts/build.sh --console-only      # deprecated alias for --profile console
#   ./scripts/build.sh --version 0.2.0     # override VERSION for this run
#   ./scripts/build.sh --vendor            # also build the offline release archive (stage 90)
#   ./scripts/build.sh --offline --vendor-dir out/vendor/immos-0.3.0
#                                          # rebuild from a vendored archive, no network at all
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

# Print the contiguous comment block at the top of this file, minus the shebang. A hardcoded
# line range gets silently wrong every time the header grows or shrinks — it had already begun
# printing a shellcheck directive as if it were help text.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

RUNTIME=auto FROM='' ONLY='' DRY_RUN=0 CLEAN=0 FORCE=0 LIST=0 OFFLINE=0 VENDOR_DIR='' LIST_PROFILES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)         FROM="$2"; shift 2 ;;
    --only)         ONLY="$2"; FORCE=1; shift 2 ;;
    --clean)        CLEAN=1; shift ;;
    --profile)      export BUILD_PROFILE_OVERRIDE="$2"; shift 2 ;;
    --list-profiles) LIST_PROFILES=1; shift ;;
    # Deprecated, kept working: --console-only was a bare boolean threaded through eight files
    # before profiles existed (plan/16 §3.5). It is exactly "the profile whose sets omit
    # @desktop", so it forwards to one rather than surviving as a second mechanism.
    --console-only) export BUILD_PROFILE_OVERRIDE=console
                    echo "note: --console-only is deprecated; use --profile console" >&2
                    shift ;;
    --version)      export VERSION_OVERRIDE="$2"; shift 2 ;;
    --update-url)   export UPDATE_URL_OVERRIDE="$2"; shift 2 ;;
    --no-verify)    export UPDATE_VERIFY_OVERRIDE=0; shift ;;
    --force)        FORCE=1; shift ;;
    --vendor)       export VENDOR=1; shift ;;
    --vendor-dir)   VENDOR_DIR="$2"; shift 2 ;;
    --offline)      OFFLINE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --runtime)      RUNTIME="$2"; shift 2 ;;
    --list)         LIST=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

load_config

if [[ $LIST_PROFILES == 1 ]]; then
  printf '%-12s %-8s %-24s %s\n' PROFILE ROLE SETS DESCRIPTION
  while IFS= read -r _p; do
    ( BUILD_PROFILE="$_p"; load_profile
      printf '%-12s %-8s %-24s %s\n' "$_p" "$PROFILE_ROLE" "$PROFILE_SETS" "$PROFILE_DESC" )
  done < <(profile_list)
  exit 0
fi

log "build profile: $BUILD_PROFILE ($PROFILE_DESC) — sets: $PROFILE_SETS"
# Hand the container the profile the HOST resolved, rather than letting it default
# independently. Both sides share DEFAULT_BUILD_PROFILE so they would agree today, but two
# sides defaulting separately is exactly how they stop agreeing later.
export BUILD_PROFILE_OVERRIDE="$BUILD_PROFILE"

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
# The ebuild tree, as a volume rather than an image layer (plan/15). Mounted at the PARENT
# /var/db/repos, not at .../gentoo, so every existing path keeps working: stage 20 symlinks
# make.profile into /var/db/repos/gentoo/profiles/$PROFILE and its generated repos.conf still
# says location = /var/db/repos/gentoo.
TREE_VOL="${DISTRO_ID}-tree"

if [[ $CLEAN == 1 ]]; then
  log "cleaning work volume + state (cache volume kept)"
  # Every profile's stamps, not just the active one's: the work volume below is removed
  # wholesale and takes every profile's target rootfs with it, so leaving another profile's
  # stamps behind would let its next build skip stages whose output no longer exists.
  if [[ $RUNTIME == none ]]; then
    run rm -rf -- "$WORK" "$OUT"/state "$OUT"/state-*
  else
    run "$RUNTIME" volume rm -f "$WORK_VOL"
    # out/ is written by the container as root, so a non-root host cannot rm the stamps —
    # and with set -e that failure aborted --clean before it did anything useful, while the
    # work volume above had ALREADY been removed. Fall back to deleting them as root inside
    # the builder. Host attempt stays first: on a first-ever run the image may not exist yet.
    run rm -rf -- "$OUT"/state "$OUT"/state-* 2>/dev/null \
      || run "$RUNTIME" run --rm --entrypoint /bin/sh -v "$OUT:/out" "$BUILDER_TAG" \
             -c 'rm -rf /out/state /out/state-*'
  fi
fi

# ---- the vendored archive ------------------------------------------------------------
# Validated and made ABSOLUTE for every use, not just for --offline. The path becomes a
# `docker run -v $VENDOR_DIR:/vendor` argument, and docker reads a relative path as a NAMED
# VOLUME rather than a bind mount:
#
#   docker: Error response from daemon: create out/vendor/immos-0.3.0:
#   "out/vendor/immos-0.3.0" includes invalid characters for a local volume name
#
# which is a confusing rc=125 for what is simply "you typed a relative path". It only ever
# worked because the canonicalisation lived inside the --offline branch below, and --offline is
# how the archive is usually used. It is not the only way: --vendor-dir on its own is what lets
# stage 40 restore the Flatpak store from the archive (2.7 GiB of rsync instead of a Flathub
# download) while the rest of the build still has a network.
if [[ -n $VENDOR_DIR ]]; then
  [[ -d $VENDOR_DIR ]] || die "--vendor-dir not found: $VENDOR_DIR"
  VENDOR_DIR="$(cd -- "$VENDOR_DIR" && pwd)"
fi

# --offline is an assertion, not a hint: every stage runs with --network none, so a build that
# claims to be reproducible from the archive cannot quietly reach out and prove nothing.
if [[ $OFFLINE == 1 ]]; then
  [[ -n $VENDOR_DIR ]] || die "--offline needs --vendor-dir DIR (the archive stage 90 produced)"
  log "offline build from $VENDOR_DIR (every stage runs with --network none)"
fi

# ---- pass-through env ------------------------------------------------------------
ENV_ARGS=()
# NB VENDOR_PROFILE is unrelated to BUILD_PROFILE — it is stage 90's vendoring depth (full or
# not). Three different things in this tree are called "profile"; config/profiles/README.md has
# the table.
for v in VERSION_OVERRIDE UPDATE_URL_OVERRIDE UPDATE_VERIFY_OVERRIDE BUILD_PROFILE_OVERRIDE \
         FORCE_STAGE VENDOR VENDOR_PROFILE ALLOW_UNPINNED; do
  [[ -n ${!v:-} ]] && ENV_ARGS+=(-e "$v=${!v}")
done
[[ $FORCE == 1 ]] && ENV_ARGS+=(-e FORCE_STAGE=1)
# The archive is mounted at a fixed path so stages never have to know the host layout.
[[ -n $VENDOR_DIR ]] && ENV_ARGS+=(-e "VENDOR_DIR=/vendor")
[[ $OFFLINE == 1 ]] && ENV_ARGS+=(-e "OFFLINE=1")

# ---- builder image -----------------------------------------------------------------
if [[ $RUNTIME != none ]]; then
  # A floating base tag means the libc, compiler and profile the image is built against move
  # under you with no diff anywhere, so this is a hard failure rather than the warning it used
  # to be — a warning printed on every single build is a warning nobody reads. ALLOW_UNPINNED
  # is the deliberate escape, and stage 80 refuses to assemble a release from a build that
  # took it (the marker below is how it finds out).
  if [[ -z $BUILDER_DIGEST ]]; then
    [[ ${ALLOW_UNPINNED:-0} == 1 ]] || die "BUILDER_DIGEST is empty — the stage3 base is unpinned.
  Record the digest in config/build.conf:
      docker image inspect $BUILDER_IMAGE --format '{{index .RepoDigests 0}}'
  or, for a throwaway dev build only:  ALLOW_UNPINNED=1 scripts/build.sh ..."
    warn "ALLOW_UNPINNED=1: building against the floating tag $BUILDER_IMAGE — not releasable"
    run mkdir -p -- "$OUT/state"
    run touch -- "$OUT/state/unpinned-build"
  else
    # Stale marker from an earlier unpinned run would keep failing releases forever.
    run rm -f -- "$OUT/state/unpinned-build"
  fi

  if [[ $OFFLINE == 1 ]]; then
    # No `docker build` at all. It needs a network, and reconstructing the builder offline
    # would need the binhost's ~495 binary packages, which the builder image does not retain
    # (its /var/cache/binpkgs is 4 KB — portage consumes and drops them). Loading the archived
    # image is both the reliable path and the honest one: it is the exact builder that produced
    # the release.
    img="$VENDOR_DIR/builder-image.tar.zst"
    [[ -f $img ]] || die "offline build needs $img (produced by stage 90)"
    log "loading archived builder image from $img"
    if [[ $DRY_RUN == 1 ]]; then
      printf 'DRY-RUN: zstd -dc %s | %s load\n' "$img" "$RUNTIME"
      printf 'DRY-RUN: %s tag <loaded> %s\n' "$RUNTIME" "$BUILDER_TAG"
    else
      zstd -dc -- "$img" | "$RUNTIME" load
      "$RUNTIME" image inspect "$BUILDER_TAG" >/dev/null 2>&1 \
        || die "the archived image did not load as $BUILDER_TAG — check stage 90's save step"
    fi
  else
    base="$BUILDER_IMAGE"
    [[ -n $BUILDER_DIGEST ]] && base="${BUILDER_IMAGE%%:*}@${BUILDER_DIGEST}"
    # BINHOST is the builder's OWN binhost, and nothing else's: the builder emerges its tools
    # from binpkgs rather than compiling them, while the image is compiled from source (or from
    # binpkgs this pipeline built) — config/portage/make.conf.in has the reasoning.
    #
    # The build CONTEXT is the repo root, not builder/, because the Dockerfile COPYs
    # config/portage/lock/builder.lock. .dockerignore keeps out/ and .claude/ out of it.
    run "$RUNTIME" build -t "$BUILDER_TAG" -f "$REPO_ROOT/builder/Dockerfile" \
        --build-arg "BASE=$base" --build-arg "BINHOST=$BINHOST_URI" \
        --build-arg "SNAPSHOT_DATE=$SNAPSHOT_DATE" \
        "$REPO_ROOT"
  fi
fi

# ---- vendor archive: the host-side half (plan/15 layer 7) ---------------------------
# `docker save` cannot run from inside the builder, so the two image tarballs are written here
# and stage 90 — which runs in the container and can see /cache, the tree and the target —
# fills in the rest and writes the manifest over all of it.
#
# Done BEFORE the stage loop so stage 90 finds the tarballs already in place and the manifest
# it writes covers them.
if [[ ${VENDOR:-0} == 1 && $RUNTIME != none ]]; then
  VOUT="$OUT/vendor/${DISTRO_ID}-${VERSION}"
  log "vendoring: saving container images into $VOUT"
  # out/ is written by the containers as root, so a non-root host cannot mkdir inside it — the
  # same wrinkle --clean already works around by deleting stamps from inside the builder. Create
  # the directory as root in a container and hand it to the invoking user, because the two
  # `docker save` pipelines below run on the HOST and write as that user.
  if [[ $DRY_RUN == 1 ]]; then
    printf 'DRY-RUN: %s run --rm -v %s:/out %s mkdir+chown /out/vendor\n' "$RUNTIME" "$OUT" "$BUILDER_TAG"
  else
    "$RUNTIME" run --rm -v "$OUT:/out" --entrypoint /bin/sh "$BUILDER_TAG" -c \
      "mkdir -p '/out/vendor/${DISTRO_ID}-${VERSION}' && chown -R $(id -u):$(id -g) /out/vendor" \
      || die "could not create $VOUT inside the container"
  fi
  if [[ $DRY_RUN == 1 ]]; then
    printf 'DRY-RUN: %s save %s | zstd -T0 -q -o %s/builder-image.tar.zst\n' "$RUNTIME" "$BUILDER_TAG" "$VOUT"
    printf 'DRY-RUN: %s save %s | zstd -T0 -q -o %s/stage3-base.tar.zst\n' "$RUNTIME" "$BUILDER_IMAGE" "$VOUT"
  else
    # The builder image is the fast path AND the honest one: it is the exact builder that
    # produced the release, tree included. An offline rebuild loads this rather than running
    # `docker build`, which would need a network and the binhost's ~495 binary packages that
    # the image does not retain.
    "$RUNTIME" save "$BUILDER_TAG" | zstd -T0 -q -o "$VOUT/builder-image.tar.zst.tmp"
    mv -f -- "$VOUT/builder-image.tar.zst.tmp" "$VOUT/builder-image.tar.zst"
    # The stage3 is redundant with the builder image above and is kept anyway, for ~600 MB,
    # because it is what lets the builder be RECONSTRUCTED and audited rather than trusted as
    # an opaque 3 GB blob.
    base_ref="$BUILDER_IMAGE"
    [[ -n $BUILDER_DIGEST ]] && base_ref="${BUILDER_IMAGE%%:*}@${BUILDER_DIGEST}"
    if "$RUNTIME" image inspect "$base_ref" >/dev/null 2>&1; then
      "$RUNTIME" save "$base_ref" | zstd -T0 -q -o "$VOUT/stage3-base.tar.zst.tmp"
      mv -f -- "$VOUT/stage3-base.tar.zst.tmp" "$VOUT/stage3-base.tar.zst"
    else
      warn "stage3 base $base_ref not present locally — archive will lack stage3-base.tar.zst"
    fi
  fi
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
    MOUNT_ARGS=(-v "$REPO_ROOT":/repo:ro
                -v "$WORK_VOL":/work
                -v "$CACHE_VOL":/cache
                -v "$TREE_VOL":/var/db/repos
                -v "$OUT":/out)
    [[ -n $VENDOR_DIR ]] && MOUNT_ARGS+=(-v "$VENDOR_DIR":/vendor:ro)
    NET_ARGS=()
    [[ $OFFLINE == 1 ]] && NET_ARGS=(--network none)
    run "$RUNTIME" run --rm --privileged \
      "${KVM_ARGS[@]}" \
      "${NET_ARGS[@]}" \
      "${MOUNT_ARGS[@]}" \
      "${ENV_ARGS[@]}" \
      "$BUILDER_TAG" "/repo/scripts/stages/$s"
  fi || { rc=$?; die "stage $s failed (rc=$rc) — logs in ${LOG_DIR#"$OUT"/}/, resume with --from $n"; }
done

log "pipeline complete — artifacts in out/"
