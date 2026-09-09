#!/usr/bin/env bash
# Stage 20 — assemble the TARGET portage config-root at $WORK/config.
# emerge --config-root=$WORK/config controls everything merged into the image;
# the builder's own /etc/portage stays stock.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=20-builder-setup
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"

# One DISTDIR for both roots (see the function). Per stage, because each runs in its own
# container and nothing written to /etc/portage survives to the next.
share_builder_distdir

# The depgraph below resolves against /var/db/repos/gentoo, so assert it is the pinned tree
# before resolving anything. Each stage is its own container — this cannot be done once.
tree_assert

PC="$CONFIG_ROOT/etc/portage"
rm -rf -- "$CONFIG_ROOT"
ensure_dir "$PC"/{package.use,package.license,package.accept_keywords,package.mask,sets}

# profile symlink (profile tree lives in the builder's synced repo)
PROFILE_DIR="/var/db/repos/gentoo/profiles/$PROFILE"
[[ -d $PROFILE_DIR ]] || die "profile not found in repo: $PROFILE"
ln -sfn "$PROFILE_DIR" "$PC/make.profile"

# make.conf — rendered from repo template
JOBS="$(nproc)"
# L10N uses hyphens (pt-BR); LOCALES_KEEP uses underscores (pt_BR directory names)
L10N="$(printf '%s' "$LOCALES_KEEP" | tr '_' '-')"
export JOBS L10N   # BINHOST_URI is the builder's own setting; the target has no binhost
render_template "$REPO/config/portage/make.conf.in" "$PC/make.conf"

# package.use is the one config directory that is NOT a straight copy, because USE is resolved
# once per package and this pipeline builds several profiles from one repo.
#
# A file named "profile.<name>" belongs to that build profile alone and is skipped by every
# other one; everything else is shared and always copied. The case that forced this: the
# installer profile's <id>-calamares-managed is built out of tree against the installed
# Calamares, and CalamaresConfig.cmake hardcodes LinguistTools into the REQUIRED Qt6 component
# list every consumer inherits — so dev-qt/qttools needs USE=linguist to build the installer
# page, while the desktop and console images want neither that flag nor the Qt Linguist GUI it
# also builds. Copying package.use wholesale offered only "on everywhere" or "off everywhere",
# and neither is true (plan/19 §7.3).
#
# The naming mirrors config/portage/sets/, where the profile likewise selects which files apply,
# so there is one convention to learn rather than two.
for f in "$REPO"/config/portage/package.use/*; do
  b="$(basename "$f")"
  if [[ $b == profile.* ]]; then
    [[ $b == "profile.$BUILD_PROFILE" ]] || continue
    log "package.use: including $b for the $BUILD_PROFILE profile"
  fi
  cp "$f" "$PC/package.use/"
done
cp "$REPO"/config/portage/package.license/*         "$PC/package.license/"
cp "$REPO"/config/portage/package.accept_keywords/* "$PC/package.accept_keywords/"
cp "$REPO"/config/portage/package.mask/*            "$PC/package.mask/"

# Fingerprint of what was just copied. Stage 30 refuses to run against a config root that no
# longer matches the repo — see the guards there for the two ways that silently produced a
# wrong image before.
portage_config_hash > "$CONFIG_ROOT/.inputs-hash"

# sets, with cjk/printing filtering per build.conf. WHICH sets comes from the build profile
# (plan/16) — a console image has no @desktop, so copying one in would only invite a later
# emerge to reference a set this image was never meant to have.
# shellcheck disable=SC2086  # deliberate splitting: PROFILE_SETS is a space-separated list
for s in $PROFILE_SETS; do
  filter_set_file "$REPO/config/portage/sets/$s" "$PC/sets/$s"
done

# ---- the in-repo ebuild repository (plan/19 Phase D) ----------------------------------------
# Two things this project ships have to be COMPILED against the target's own Qt6/KF6 — the
# System Settings module and the Calamares installer page — and a hand-compile in a build stage
# would build them against whatever headers happened to be around. An ABI-mismatched Qt plugin
# does not fail to build; it fails to LOAD, silently, on a machine with no way to install a fix.
# Letting Portage build them removes the question (config/portage/overlay/README.md).
#
# RENDERED, NOT COPIED, and with the same function stage 40 uses on config/rootfs: *.in files get
# their @TOKEN@s substituted and every path segment that is exactly "distro" becomes $DISTRO_ID.
# So the repository, its category and its packages all follow build.conf, and renaming the distro
# stays a one-line change.
#
# Into $CONFIG_ROOT rather than left in /repo: /repo is mounted read-only, and portage writes
# metadata cache into a repository's own directory.
OVERLAY_SRC="$REPO/config/portage/overlay"
OVERLAY_DST="$CONFIG_ROOT/overlay"
if [[ -d $OVERLAY_SRC ]]; then
  rm -rf -- "$OVERLAY_DST"
  install_rootfs_overlay "$OVERLAY_SRC" "$OVERLAY_DST"
  OVERLAY_NAME="$(cat "$OVERLAY_DST/profiles/repo_name" 2>/dev/null | tr -d '[:space:]')"
  [[ $OVERLAY_NAME == "$DISTRO_ID" ]] \
    || die "the overlay's profiles/repo_name renders to '${OVERLAY_NAME:-<empty>}' and DISTRO_ID
  is '$DISTRO_ID'. Portage keys a repository by that file, so a mismatch makes every ::$DISTRO_ID
  atom unresolvable while the repository itself looks perfectly present."
  # An ebuild whose directory name does not match its own filename is invisible to portage, and
  # the rebranding above touches BOTH — so a token rule that ever disagreed with itself would
  # produce a repository with no packages in it and no error anywhere.
  while IFS= read -r -d '' eb; do
    ebdir="$(basename -- "$(dirname -- "$eb")")"
    ebfile="$(basename -- "$eb")"
    [[ ${ebfile%-*} == "$ebdir" ]] \
      || die "overlay: $ebfile is in a directory called $ebdir. Portage looks up an ebuild by
  <category>/<pn>/<pn>-<pv>.ebuild and finds nothing when those disagree."
  done < <(find "$OVERLAY_DST" -name '*.ebuild' -print0)
  OVERLAY_N="$(find "$OVERLAY_DST" -name '*.ebuild' | wc -l)"
  log "overlay: rendered $OVERLAY_N ebuild(s) into ::$DISTRO_ID"
else
  OVERLAY_DST=""
  warn "config/portage/overlay is missing — the System Settings module and the installer page
  cannot be built (plan/19 Phase D)"
fi

# ---- the version lock (plan/15) ------------------------------------------------------
# <profile>.lock is the full pre-prune closure at exact versions, so stage 30 can emerge it as
# a set and the resolver has no freedom left. The loose sets above stay: they are the request
# that a relock re-resolves from, and stage 30 falls back to them when no lock exists.
#
# One lock PER PROFILE (plan/16 §3.3). It used to be a single image.lock whose header recorded
# CONSOLE_ONLY, and stage 20 died when that disagreed with the build — so a console build
# demanded a relock, and relocking back demanded another. Two profiles could not both be locked
# at once, which profiles make untenable.
: "${PROFILE_LOCK:?init_paths did not set PROFILE_LOCK}"
if [[ -f $PROFILE_LOCK ]]; then
  # 1. Does the lock still describe THIS config? The lock cannot be part of
  #    portage_config_hash (that is a cycle — see the note on the function), so the hash it was
  #    generated under is recorded in its header and asserted one-way here. This is what
  #    catches "package.use changed and the lock did not", which would otherwise build an image
  #    whose flags and whose versions were resolved against different configs.
  want_hash="$(portage_config_hash)"
  have_hash="$(lock_header_value "$PROFILE_LOCK" PORTAGE_CONFIG_HASH)"
  [[ $have_hash == "$want_hash" || ${RELOCK:-0} == 1 ]] || die "config/portage or build.conf changed since ${BUILD_PROFILE}.lock
  was generated (lock says ${have_hash:-<none>}, config hashes to $want_hash).
  The lock is resolved against the OLD config, so this build would emerge one set of versions
  with a different set of flags. Re-resolve it:  scripts/relock.sh --all --profile $BUILD_PROFILE"

  # 2. Do the switches that reshape the closure still agree? filter_set_file resolves these
  #    before the set is ever emerged, so a lock generated with CJK fonts on is simply the
  #    wrong lock for a build with them off — and nothing downstream would say so.
  for k in INCLUDE_CJK_FONTS INCLUDE_PRINTING INCLUDE_DISTROBOX PROFILE_ROLE \
           BUILD_PROFILE PROFILE_SETS; do
    lv="$(lock_header_value "$PROFILE_LOCK" "$k")"
    cv="${!k:-}"
    [[ -z $lv || $lv == "$cv" || ${RELOCK:-0} == 1 ]] || die "${BUILD_PROFILE}.lock was generated with $k=$lv, this build has $k=$cv.
  That switch changes the package closure, so the lock does not describe this build.
  Re-resolve it:  scripts/relock.sh --all --profile $BUILD_PROFILE"
  done

  # 3. Does the pinned tree still carry every locked version? An exact atom whose ebuild has
  #    been removed upstream is the failure that WILL happen in steady state — Gentoo cleans
  #    out old versions routinely. Checking metadata/md5-cache is a file-existence sweep and
  #    costs milliseconds, and it reports EVERY unbuildable pin at once. Left to emerge, the
  #    same problem surfaces as one atom at a time, minutes into a run.
  MD5C=/var/db/repos/gentoo/metadata/md5-cache
  missing=(); MISSING_ATOMS=()
  while IFS= read -r atom; do
    [[ -f $MD5C/${atom#=} ]] && continue
    # ...and then the overlay, which has no md5-cache of its own and does not need one: it is a
    # handful of ebuilds in a directory portage reads directly. Without this branch every locked
    # overlay atom reads as "gone from the pinned tree" and the build stops, telling the operator
    # to relock a package that upstream never carried in the first place (plan/19 Phase D).
    if [[ -n $OVERLAY_DST ]]; then
      cpv="${atom#=}"; ovl_cat="${cpv%%/*}"; ovl_pf="${cpv#*/}"
      # PN from PF, in the order portage splits them: strip an optional -rN revision FIRST, then
      # the version. `${pf%-*}` alone turns immos-kcm-managed-1.0-r1 into immos-kcm-managed-1.0,
      # which is a directory that does not exist — and the atom would then be reported missing
      # for the one build shape (a revbump) where it is most certainly present.
      ovl_pn="${ovl_pf%-r[0-9]*}"; ovl_pn="${ovl_pn%-*}"
      [[ -f $OVERLAY_DST/$ovl_cat/$ovl_pn/$ovl_pf.ebuild ]] && continue
    fi
    missing+=("$atom")
  done < <(lock_atoms "$PROFILE_LOCK")
  if (( ${#missing[@]} )); then
    printf '  %s\n' "${missing[@]}"
    # A relock is exactly the operation run to fix this, so it must not be blocked by it.
    # scripts/relock.sh sets RELOCK=1 and composes its own set; the stale atoms are dropped
    # there rather than here.
    [[ ${RELOCK:-0} == 1 ]] && warn "${#missing[@]} locked atom(s) are gone from the pinned tree
  — continuing because this is a relock, which is what resolves them"
    [[ ${RELOCK:-0} == 1 ]] || die "${#missing[@]} locked version(s) are not in the pinned tree ($SNAPSHOT_DATE).
  Upstream removes old versions routinely, so this is expected when the tree pin moves forward.
  Release exactly those atoms and re-resolve them:  scripts/relock.sh ${missing[0]#=}
  (a binpkg in /cache does not rescue this: --usepkg resolves against the ebuild tree)"
    MISSING_ATOMS=("${missing[@]}")
  fi

  # Written even during a relock: relock.sh composes its own set FROM this one, dropping the
  # atoms it is releasing, so it needs the full locked set on disk first.
  lock_atoms "$PROFILE_LOCK" > "$PC/sets/locked-image"
  printf '%s\n' "${MISSING_ATOMS[@]:-}" | sed '/^$/d' > "$CONFIG_ROOT/.lock-missing"
  log "version lock: $(wc -l < "$PC/sets/locked-image") atoms, $(( $(wc -l < "$CONFIG_ROOT/.lock-missing") )) not in the pinned tree"
else
  warn "no config/portage/lock/${BUILD_PROFILE}.lock — stage 30 will resolve the loose sets and generate one"
fi

# repos.conf → builder's synced tree, plus the overlay above.
#
# masters = gentoo in the overlay's layout.conf makes the tree's eclasses and licences visible to
# it; this file is what makes the overlay visible to portage at all.
ensure_dir "$PC/repos.conf"
cat > "$PC/repos.conf/gentoo.conf" <<'EOF'
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
EOF
if [[ -n $OVERLAY_DST ]]; then
  # priority higher than the tree's default (0) so that, if a name ever did collide, the
  # behaviour is the documented one rather than whichever repository portage happened to read
  # first. config/portage/overlay/README.md says why a collision must never be created on purpose.
  cat > "$PC/repos.conf/$DISTRO_ID.conf" <<EOF
[$DISTRO_ID]
location = $OVERLAY_DST
masters = gentoo
priority = 50
auto-sync = no
EOF
  # ...and onto the BUILDER's own /etc/portage as well, for the same reason
  # mirror_target_pkg_config exists: the depgraph for a ROOT= emerge is computed with the
  # builder's configuration in play, and a repository the builder cannot see is one the resolver
  # will not resolve against.
  ensure_dir /etc/portage/repos.conf
  cp -- "$PC/repos.conf/$DISTRO_ID.conf" "/etc/portage/repos.conf/$DISTRO_ID.conf"
fi

# Mirror the target's per-package config onto the builder's own "/" (see the function's
# comment in lib/common.sh for why the depgraph needs this). Stage 30 repeats the call —
# each stage is a separate container, so this does not persist.
mirror_target_pkg_config
log "mirrored target package.use/keywords/license onto builder /etc/portage"

ensure_dir /cache/binpkgs /cache/distfiles

# /cache is a named volume and outlives any config change, so it can still hold binpkgs the
# official binhost served to an older build — back when the target's make.conf did set
# getbinpkg. Those are ordinary binpkgs to --usepkg, which has no idea where a package came
# from, so leaving them there would keep merging binhost binaries into images built by a
# config that no longer asks for any. Distfiles are untouched: source tarballs are exactly
# what building from source needs, and their Manifest checksums say what they are.
dropped="$(prune_binhost_binpkgs /cache/binpkgs)"
if (( dropped > 0 )); then
  log "dropped $dropped binhost-built binpkg(s) from /cache/binpkgs — they get rebuilt from source"
fi

# ---- verify ------------------------------------------------------------------
out="$(env ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" emerge --info 2>/dev/null | head -n1)"
log "emerge --info: $out"
grep -q 'x86-64' "$PC/make.conf" || die "verify: make.conf render failed"
# Image packages are built from source or from this pipeline's own binpkgs (plan/02). Both of
# these would silently reintroduce binhost binaries: FEATURES=getbinpkg on the target root is
# also what turns --getbinpkg on for the whole emerge invocation (_emerge/actions.py), and a
# PORTAGE_BINHOST with no getbinpkg is one --getbinpkg away from being live.
grep -qE '^[[:space:]]*FEATURES=.*getbinpkg' "$PC/make.conf" \
  && die "verify: target make.conf enables getbinpkg — the image is built from source
  (or from /cache/binpkgs); the binhost is the builder's, see config/portage/make.conf.in"
grep -qE '^[[:space:]]*PORTAGE_BINHOST=' "$PC/make.conf" \
  && die "verify: target make.conf sets PORTAGE_BINHOST — see config/portage/make.conf.in"
[[ -e $PC/make.profile/eapi || -e $PC/make.profile/parent ]] || die "verify: bad profile symlink"
log "config-root assembled at $CONFIG_ROOT"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "$REPO"/config/portage/make.conf.in "$REPO"/config/portage/sets/*)"
