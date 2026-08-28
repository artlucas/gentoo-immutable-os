#!/usr/bin/env bash
# relock.sh — move version pins deliberately (plan/15 layer 4).
#
# The locks exist so a rebuild picks the same versions. This is the other half: how a pin moves
# when it should. A patch release is
#
#     edit TREE_COMMIT in config/build.conf   # a newer mirror commit
#     scripts/relock.sh --security            # move ONLY what has a security fix
#     review out/reports/lock.diff, commit it, bump VERSION, build
#
# and everything not named in that diff still carries the version the previous release shipped.
#
#   ./scripts/relock.sh --security          # GLSA-driven: least-change, the normal path
#   ./scripts/relock.sh dev-libs/openssl …  # release exactly these atoms
#   ./scripts/relock.sh --all               # re-resolve everything against the current tree
#   ./scripts/relock.sh --builder           # the builder's own toolchain
#   ./scripts/relock.sh --flatpak           # the preinstalled Flatpaks
#
# Nothing is committed for you: like expected-packages.txt, this writes a generated file and a
# diff and stops. Review it, then copy it into config/portage/lock/.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"

# Print the contiguous comment block at the top of this file, minus the shebang. A hardcoded
# line range gets silently wrong every time the header grows or shrinks — it had already begun
# printing a shellcheck directive as if it were help text.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

MODE=atoms ATOMS=() RUNTIME=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
    --security) MODE=security; shift ;;
    --all)      MODE=all; shift ;;
    --builder)  MODE=builder; shift ;;
    --flatpak)  MODE=flatpak; shift ;;
    --runtime)  RUNTIME="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
    *)          ATOMS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------------------
# Host half: dispatch into the builder, with the same mounts build.sh uses. Re-execs this
# same file rather than adding a second script, so the modes and their comments live together.
# ---------------------------------------------------------------------------------------
if [[ ${RELOCK_IN_CONTAINER:-0} != 1 ]]; then
  export REPO="$REPO_ROOT" OUT="$REPO_ROOT/out" WORK="${WORK:-$REPO_ROOT/out/work}"
  export STAGE_NAME=relock
  # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
  case "$(uname -s)" in MINGW*|MSYS*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*';; esac
  load_config

  if [[ $RUNTIME == auto ]]; then
    if   command -v docker >/dev/null 2>&1; then RUNTIME=docker
    elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
    else die "no docker/podman found"
    fi
  fi
  [[ $MODE != atoms || ${#ATOMS[@]} -gt 0 ]] \
    || die "name at least one atom, or pass --security / --all / --builder / --flatpak"

  exec "$RUNTIME" run --rm --privileged \
    -v "$REPO_ROOT":/repo:ro \
    -v "${DISTRO_ID}-work":/work \
    -v "${DISTRO_ID}-cache":/cache \
    -v "${DISTRO_ID}-tree":/var/db/repos \
    -v "$OUT":/out \
    -e RELOCK_IN_CONTAINER=1 -e RELOCK=1 \
    -e "MODE=$MODE" -e "ATOMS=${ATOMS[*]-}" \
    "${DISTRO_ID}-builder" /repo/scripts/relock.sh
fi

# ---------------------------------------------------------------------------------------
# Container half.
# ---------------------------------------------------------------------------------------
STAGE_NAME=relock
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/relock.log") 2>&1
tree_assert
read -r -a ATOMS <<< "${ATOMS:-}"

IMAGE_LOCK="$LOCK_DIR/image.lock"
PC="$CONFIG_ROOT/etc/portage"

# ---- --flatpak: read the deployed commits back out of the target ------------------------
# No emerge involved. The refs are whatever stage 40 installed; this records where they landed.
if [[ $MODE == flatpak ]]; then
  FP="$TARGET/var/lib/flatpak"
  [[ -d $FP/repo/refs/heads ]] || die "no flatpak installation in $TARGET — run stage 40 first"
  OUTF="$REPORT_DIR/apps.lock.generated"
  ensure_dir "$REPORT_DIR"
  {
    sed -n '1,/^# Flathub garbage-collects/p' "$REPO/config/flatpak/apps.lock" 2>/dev/null \
      || printf '# apps.lock — preinstalled Flatpaks pinned to exact Flathub commits.\n'
    find "$FP/repo/refs/heads" -type f | while read -r r; do
      ref="${r#"$FP"/repo/refs/heads/}"
      printf '%s %s\n' "${ref#deploy/}" "$(cat -- "$r")"
    done | sort
  } > "$OUTF"
  log "wrote $(grep -vc '^#' "$OUTF") refs to ${OUTF#"$OUT"/}"
  diff -u "$REPO/config/flatpak/apps.lock" "$OUTF" || true
  die "review ${OUTF#"$OUT"/} and copy it to config/flatpak/apps.lock if the change is intended"
fi

# ---- --builder: the builder's own "/" ----------------------------------------------------
if [[ $MODE == builder ]]; then
  [[ -f /etc/portage/sets/builder-request ]] \
    || die "no @builder-request set in this image — it is written by builder/Dockerfile"
  log "re-resolving the builder's own closure from @builder-request"
  emerge --quiet-build=y --usepkg --getbinpkg --update --deep @builder-request
  ensure_dir "$REPORT_DIR"
  vdb_atoms / | lock_write "$REPORT_DIR/builder.lock.generated" \
    "builder.lock — the builder's own \"/\" closure, installed from the binhost"
  lock_diff "$LOCK_DIR/builder.lock" "$REPORT_DIR/builder.lock.generated" || true
  die "review out/reports/builder.lock.generated and copy it to config/portage/lock/builder.lock.
  NB the builder image must then be rebuilt so its own root matches the lock it ships."
fi

# ---- the image lock ----------------------------------------------------------------------
[[ -d $PC ]] || die "no config root at $CONFIG_ROOT — run:  scripts/build.sh --from 20 --only 20"

# --security: ask portage which installed packages have a GLSA against them. glsa-check's
# default solver is getMinUpgrade(minimize=True) — a LEAST-CHANGE upgrade, which is exactly the
# question a patch release asks. The package names come from `-l`, whose one-line-per-GLSA
# format ("<id> [U] <title> ( cat/pkg  cat/pkg )") is far steadier to parse than -p's prose.
if [[ $MODE == security ]]; then
  log "checking $TARGET against the GLSA database in the pinned tree"
  mapfile -t GLSA_IDS < <(ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
    glsa-check -n -q -t all 2>/dev/null | grep -E '^[0-9]{6}-[0-9]+$' || true)
  if (( ${#GLSA_IDS[@]} == 0 )); then
    log "no GLSA affects the locked package set — nothing to relock"
    log "(that is the expected answer most of the time; it is not an error)"
    exit 0
  fi
  log "${#GLSA_IDS[@]} GLSA(s) affect this image:"
  ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" glsa-check -n -c -l "${GLSA_IDS[@]}" 2>/dev/null || true
  mapfile -t ATOMS < <(ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
    glsa-check -n -l "${GLSA_IDS[@]}" 2>/dev/null \
    | sed -n 's/.*(\(.*\)).*/\1/p' | tr ' ' '\n' | grep -E '^[a-z0-9-]+/' | sort -u)
  (( ${#ATOMS[@]} )) || die "GLSAs were reported but no package names could be read out of
  glsa-check -l. Name the atoms explicitly instead:  scripts/relock.sh cat/pkg ..."
  log "releasing: ${ATOMS[*]}"
fi

# Compose the set this relock emerges.
#
# The whole mechanism, in three lines: take the lock, DROP the atoms being released, and add
# them back unversioned. Everything still named at an exact version cannot move; the released
# ones float to the best the pinned tree offers. That is the difference between a patch release
# and a wholesale upgrade, and it is why --all is a separate mode rather than the default.
ensure_dir "$REPORT_DIR"
RELOCK_SET="$PC/sets/relock-target"
if [[ $MODE == all ]]; then
  SETS=(@base @hardware); [[ ${CONSOLE_ONLY:-0} == 1 ]] || SETS+=(@desktop)
  log "re-resolving EVERYTHING against tree $TREE_COMMIT — expect a large diff"
else
  [[ -f $PC/sets/locked-image ]] || die "no locked-image set — run:  scripts/build.sh --only 20"
  STALE="$CONFIG_ROOT/.lock-missing"
  [[ -f $STALE ]] || : > "$STALE"
  printf '%s\n' "${ATOMS[@]}" | sed '/^$/d' | sort -u > "$REPORT_DIR/.relock-released"

  # released  = names this run is deliberately moving
  # stale     = exact atoms the pinned tree no longer carries; they must be dropped whether or
  #             not anyone asked, because keeping them fails the emerge on precisely the pins
  #             this run exists to replace. Their NAME is added back unversioned so the package
  #             is still requested rather than silently leaving the graph.
  awk '
    function name(a) { sub(/^=/, "", a); sub(/-[0-9][^\/]*$/, "", a); return a }
    FILENAME ~ /\.relock-released$/ { released[$0] = 1; next }
    FILENAME ~ /\.lock-missing$/    { stale[$0] = 1; free[name($0)] = 1; next }
    {
      n = name($0)
      if (n in released) next          # asked for: comes back unversioned below
      if ($0 in stale)   next          # gone upstream: same
      print                            # everything else stays pinned exactly
    }
    END { for (n in released) print n; for (n in free) print n }
  ' "$REPORT_DIR/.relock-released" "$STALE" "$PC/sets/locked-image" \
    | sed '/^$/d' | sort -u > "$RELOCK_SET"

  held=$(grep -c '^=' "$RELOCK_SET" || true)
  freed=$(grep -vc '^=' "$RELOCK_SET" || true)
  log "relock set: $held atoms held at their locked versions, $freed released to re-resolve"
  rm -f -- "$REPORT_DIR/.relock-released"
  SETS=(@relock-target)
fi

mirror_target_pkg_config
log "emerging ${SETS[*]} into $TARGET"
ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
  emerge --verbose --usepkg --with-bdeps=n --changed-use --update --quiet-build=y "${SETS[@]}"

vdb_atoms "$TARGET" | lock_write "$REPORT_DIR/image.lock.generated" \
  "image.lock — the pre-prune --root=\$TARGET closure, exactly as stage 30 resolves it"
lock_diff "$IMAGE_LOCK" "$REPORT_DIR/image.lock.generated" | tee "$REPORT_DIR/lock.diff" || true

log ""
log "review out/reports/lock.diff, then:"
log "    cp out/reports/image.lock.generated config/portage/lock/image.lock"
log ""
log "and bump VERSION in config/build.conf before building. plan/05 requires it to increase:"
log "the GPT slot partlabel is derived from it, so a relocked image reusing a version would"
log "ship different contents under a label that claims otherwise."
