#!/usr/bin/env bash
# relock.sh — move version pins deliberately (plan/15 layer 4).
#
# The locks exist so a rebuild picks the same versions. This is the other half: how a pin moves
# when it should. A patch release is
#
#     edit SNAPSHOT_DATE + SNAPSHOT_SHA256 in config/build.conf   # a newer tree
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
#   ./scripts/relock.sh --all --profile console   # a profile other than the default
#
# Locks are PER BUILD PROFILE (plan/16 §3.3): --profile picks which config/portage/lock/*.lock
# this run re-resolves. --builder and --flatpak are profile-independent and ignore it.
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

# ---------------------------------------------------------------------------------------
# Host half: dispatch into the builder, with the same mounts build.sh uses. Re-execs this
# same file rather than adding a second script, so the modes and their comments live together.
#
# Arguments are parsed HERE ONLY. The container half is re-exec'd with no arguments and takes
# its instructions from the environment, so a default assigned out at the top of the file would
# clobber the -e MODE= this branch passes in — which is precisely what it used to do. Every
# mode arrived inside the container as "atoms" with an empty atom list, so --security skipped
# GLSA detection entirely, held all 655 atoms, released none, emerged nothing, and then printed
# the whole "review out/reports/lock.diff and commit it" epilogue. Exit 0, no diff, no work
# done, no way to tell from the output that it had not run.
# ---------------------------------------------------------------------------------------
if [[ ${RELOCK_IN_CONTAINER:-0} != 1 ]]; then
  MODE=atoms ATOMS=() RUNTIME=auto
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --security) MODE=security; shift ;;
      --all)      MODE=all; shift ;;
      --builder)  MODE=builder; shift ;;
      --flatpak)  MODE=flatpak; shift ;;
      --profile)  export BUILD_PROFILE_OVERRIDE="$2"; shift 2 ;;
      --runtime)  RUNTIME="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      -*)         echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
      *)          ATOMS+=("$1"); shift ;;
    esac
  done

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
    -e "BUILD_PROFILE_OVERRIDE=$BUILD_PROFILE" \
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

# Both come from the host half's -e flags. MODE is asserted rather than defaulted: defaulting it
# is what silently turned every mode into "atoms" and made a --security run that did nothing
# look exactly like one that found nothing.
MODE="${MODE:?relock.sh: MODE is unset — the host half passes it with -e MODE=}"
read -r -a ATOMS <<< "${ATOMS:-}"
log "mode: $MODE${ATOMS[0]+ (${ATOMS[*]})}"

: "${PROFILE_LOCK:?init_paths did not set PROFILE_LOCK}"
GEN_LOCK="$REPORT_DIR/${BUILD_PROFILE}.lock.generated"
PC="$CONFIG_ROOT/etc/portage"
log "profile: $BUILD_PROFILE (${PROFILE_LOCK#"$REPO"/})"

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

# glsa_vdb LOCK ROOT — a throwaway VDB holding exactly the lock's atoms, which is all
# glsa-check needs in order to match. SLOT is read out of the pinned tree's md5-cache and is
# not decoration: GLSA <package> entries carry slot restrictions, so a defaulted SLOT can fail
# to match and hand back an all-clear that is simply wrong.
glsa_vdb() {
  local lock=${1:?glsa_vdb: lock required} root=${2:?glsa_vdb: root required}
  local md5="$TREE_DIR/gentoo/metadata/md5-cache"
  local atom cpv cat pf pn d slot sib n=0 approx=0
  [[ -d $md5 ]] || die "no md5-cache at $md5 — the pinned tree is not populated.
  Reconcile it first:  scripts/build.sh --only 10"
  rm -rf -- "$root"; ensure_dir "$root/var/db/pkg"
  while read -r atom; do
    cpv="${atom#=}"; cat="${cpv%%/*}"; pf="${cpv#*/}"
    d="$root/var/db/pkg/$cat/$pf"; mkdir -p -- "$d"
    printf '%s\n' "$pf"  > "$d/PF"
    printf '%s\n' "$cat" > "$d/CATEGORY"
    printf 'gentoo\n'    > "$d/repository"
    printf '%s\n' "$n"   > "$d/COUNTER"
    slot=""
    if [[ -f $md5/$cat/$pf ]]; then
      slot="$(sed -n 's/^SLOT=//p' "$md5/$cat/$pf")"
    else
      # The exact version is gone from the tree — the normal case straight after a snapshot
      # bump, which is exactly when --security is run. A sibling version's SLOT is a far
      # better guess than "0"; slots move rarely, and a wrong one here means a missed GLSA.
      pn="$(atom_name "$pf")"
      sib="$(compgen -G "$md5/$cat/$pn-[0-9]*" 2>/dev/null | head -n1 || true)"
      [[ -n $sib ]] && slot="$(sed -n 's/^SLOT=//p' "$sib")"
      approx=$((approx + 1))
    fi
    printf '%s\n' "${slot:-0}" > "$d/SLOT"
    n=$((n + 1))
  done < <(lock_atoms "$lock")
  (( n > 0 )) || die "$lock holds no atoms — there is nothing to check"
  log "checking $n locked atoms against the GLSA database in the tree dated $(tree_date)"
  (( approx == 0 )) \
    || warn "$approx of $n locked atoms are no longer in the tree; their SLOT was taken from a
  sibling version. Those are also the atoms most likely to need releasing anyway."
}

# ---- the image lock ----------------------------------------------------------------------
[[ -d $PC ]] || die "no config root at $CONFIG_ROOT — run:  scripts/build.sh --from 20 --only 20"

# --security: ask portage which packages in the lock have a GLSA against them. glsa-check's
# default solver is getMinUpgrade(minimize=True) — a LEAST-CHANGE upgrade, which is exactly the
# question a patch release asks. The package names come from `-l`, whose one-line-per-GLSA
# format ("<id> [U] <title> ( cat/pkg  cat/pkg )") is far steadier to parse than -p's prose.
#
# Detection runs against a VDB synthesized from <profile>.lock, NOT against $TARGET. Two reasons,
# the first of which is a bug this line used to have:
#
#   1. glsa-check answers "This system is not affected by any of the listed GLSAs", exit 0,
#      against an EMPTY root just as cheerfully as against a clean one — and stage 50 DELETES
#      $TARGET/var/db/pkg, so an empty root is the normal state after any completed build.
#      Pointed at $TARGET, this reported "nothing to relock" for a release it had never
#      actually checked. A silent all-clear is the worst available answer to a security
#      question, and it is indistinguishable from the true one.
#   2. The lock is the authoritative record of what a release resolved, and it is in git. So
#      "does 0.3.0 have a known vulnerability?" becomes a seconds-long query answerable for any
#      past release against any tree, with no rebuild and no target root.
if [[ $MODE == security ]]; then
  GLSA_ROOT="$WORK/.glsa-root"
  glsa_vdb "$PROFILE_LOCK" "$GLSA_ROOT"
  mapfile -t GLSA_IDS < <(ROOT="$GLSA_ROOT" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
    glsa-check -n -q -t all 2>/dev/null | grep -E '^[0-9]{6}-[0-9]+$' || true)
  if (( ${#GLSA_IDS[@]} == 0 )); then
    log "no GLSA affects the locked package set — nothing to relock"
    log "(that is the expected answer most of the time; it is not an error)"
    exit 0
  fi
  log "${#GLSA_IDS[@]} GLSA(s) affect this image:"
  ROOT="$GLSA_ROOT" PORTAGE_CONFIGROOT="$CONFIG_ROOT" glsa-check -n -c -l "${GLSA_IDS[@]}" 2>/dev/null || true
  mapfile -t ATOMS < <(ROOT="$GLSA_ROOT" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
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
  mapfile -t SETS < <(profile_emerge_sets)
  log "re-resolving EVERYTHING against tree $SNAPSHOT_DATE — expect a large diff"
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

# The relock EMERGE, unlike the detection above, does need the real target root: it re-resolves
# against what is actually installed there. Stage 50 deletes that VDB at the end of every build,
# so say so, rather than silently merging 655 packages into an empty root and calling the result
# a relock.
VDB_N=$( { vdb_atoms "$TARGET" || true; } | wc -l )
(( VDB_N > 0 )) || die "$TARGET holds no installed packages — stage 50 deletes the VDB at the end
  of a build, so a relock needs the target root rebuilt first:
      scripts/build.sh --only 20 && scripts/build.sh --only 30
  (detection above needs none of this; it reads config/portage/lock/${BUILD_PROFILE}.lock.)"
log "relocking against $VDB_N packages installed in $TARGET"

# Clear the target root's set memberships first. Stage 30 records @locked-image in
# $TARGET/var/lib/portage/world_sets, and portage enforces world_sets on every later emerge into
# that root — so the relaxed set below does not REPLACE the old pins, it merely sits beside them
# and loses to them. The symptom is not an error:
#
#   WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:
#     (sys-apps/acl-2.4.0-r2 ... binary scheduled for merge) conflicts with
#       =sys-apps/acl-2.3.2-r3 required by @locked-image
#   Total: 0 packages, Size of downloads: 0 KiB
#
# followed by exit 0, "no drift", and the "review the diff and commit it" epilogue at the bottom
# of this file — a relock that relocked nothing, reported as a relock that found nothing to do.
# Stage 30 owns this file and rewrites it, and a relock already ends by telling you to rebuild.
WORLD_SETS="$TARGET/var/lib/portage/world_sets"
if [[ -s $WORLD_SETS ]]; then
  log "clearing the target's world_sets ($(tr '\n' ' ' < "$WORLD_SETS")) — they still carry the old pins"
  : > "$WORLD_SETS"
fi

mirror_target_pkg_config
log "emerging ${SETS[*]} into $TARGET"
ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
  emerge --verbose --usepkg --with-bdeps=n --changed-use --update --oneshot --quiet-build=y "${SETS[@]}"

vdb_atoms "$TARGET" | lock_write "$GEN_LOCK" \
  "${BUILD_PROFILE}.lock — the pre-prune --root=\$TARGET closure, exactly as stage 30 resolves it"
lock_diff "$PROFILE_LOCK" "$GEN_LOCK" | tee "$REPORT_DIR/lock.diff" || true

log ""
log "review ${REPORT_DIR#"$OUT"/}/lock.diff, then:"
log "    cp ${GEN_LOCK#"$OUT"/} config/portage/lock/${BUILD_PROFILE}.lock"
log ""
log "and bump VERSION in config/build.conf before building. plan/05 requires it to increase:"
log "the GPT slot partlabel is derived from it, so a relocked image reusing a version would"
log "ship different contents under a label that claims otherwise."
