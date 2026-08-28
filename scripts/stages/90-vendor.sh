#!/usr/bin/env bash
# Stage 90 — the vendored release archive (plan/15 layer 7).
#
# A pin says WHICH inputs; this says where they are kept. Gentoo removes old ebuilds routinely
# and Flathub garbage-collects old commits, so without an archive a pin only buys a shrinking
# window in which a release can still be rebuilt. With one, a release stays rebuildable with no
# internet connection at all:  build.sh --offline --vendor-dir <this directory>
#
# No-op unless VENDOR=1 (build.sh --vendor). At 13-14 GB this is a release artifact, not
# something to produce on every run.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=90-vendor
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config

# The skip check runs BEFORE the tee redirect below, and that ordering is the whole point.
# `exec > >(tee ...)` hands stdout to a process substitution that the shell does not wait for,
# so a script that exits immediately afterwards can die before tee has flushed — or even
# created — the log file. That is exactly what happened: on a run without --vendor this stage
# produced no output and no out/logs/90-vendor.log at all, i.e. it skipped silently, which is
# the one thing every other stage here is written to avoid. Printing before the redirect is
# installed keeps the message on the pipeline's own stdout where it cannot be lost.
if [[ ${VENDOR:-0} != 1 ]]; then
  printf '[%s] %s\n' "$STAGE_NAME" \
    "VENDOR is not 1 — skipping the offline archive (build.sh --vendor to produce it)"
  exit 0
fi

ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1
is_linux || die "stages run inside the builder container only"

# One DISTDIR for both roots (see the function). Per stage, because each runs in its own
# container and nothing written to /etc/portage survives to the next.
share_builder_distdir
tree_assert

V="$OUT/vendor/${DISTRO_ID}-${VERSION}"
ensure_dir "$V"
log "assembling the offline archive in ${V#"$OUT"/}"

# ---- 1. the pinned tree ---------------------------------------------------------------
# Redundant with the builder image (which carries the same tree) and kept anyway: it is small
# compressed, and it is what stage 10 restores from when the tree volume is stale on a machine
# that has the archive but not the image loaded.
# Prefer the ORIGINAL upstream tarball that emerge-webrsync --keep left in DISTDIR: it is the
# exact artifact SNAPSHOT_SHA256 pins and that upstream signed, so a restore can be verified
# against build.conf rather than trusted. Only fall back to re-tarring the unpacked tree.
TREE_TAR="$V/$(snapshot_tarball_name)"
if [[ -f $TREE_TAR ]]; then
  log "snapshot tarball already archived"
elif [[ -f $(snapshot_cached_path) ]]; then
  cp -f "$(snapshot_cached_path)" "$TREE_TAR"
  got="$(sha256_file "$TREE_TAR")"
  [[ -z ${SNAPSHOT_SHA256:-} || $got == "$SNAPSHOT_SHA256" ]] \
    || die "archived snapshot hashes to $got, build.conf pins $SNAPSHOT_SHA256"
  log "archived the upstream snapshot $(snapshot_tarball_name) (sha256 verified)"
elif [[ ${OFFLINE:-0} != 1 ]]; then
  # Re-fetch rather than re-tar. A tarball of the unpacked tree is a different artifact from the
  # one upstream signed and SNAPSHOT_SHA256 pins, so archiving it would put an unverifiable copy
  # in the one place that exists to be verifiable years later. The real file is 47 MB.
  log "no cached snapshot — fetching $(snapshot_tarball_name) to archive the signed artifact"
  wget -qO "$TREE_TAR.tmp" \
    "https://distfiles.gentoo.org/snapshots/$(snapshot_tarball_name)" \
    || die "could not fetch $(snapshot_tarball_name) to archive.
  distfiles.gentoo.org keeps roughly nine days of snapshots, so this pin may have aged out —
  which is the situation this archive exists to prevent, arriving one release too late."
  got="$(sha256_file "$TREE_TAR.tmp")"
  [[ $got == "$SNAPSHOT_SHA256" ]] \
    || die "fetched snapshot hashes to $got, build.conf pins $SNAPSHOT_SHA256"
  mv -f -- "$TREE_TAR.tmp" "$TREE_TAR"
  cp -f "$TREE_TAR" "$(snapshot_cached_path)" 2>/dev/null || true
  log "archived $(snapshot_tarball_name) (sha256 verified against the pin)"
else
  die "offline build with no cached snapshot and nothing to fetch from — the archive cannot be
  assembled without $(snapshot_tarball_name)"
fi

# ---- 2. distfiles: the guarantee ------------------------------------------------------
# /cache/distfiles holds only what was actually BUILT from source. Anything merged from a
# binpkg never fetched its sources, so the cache is not known to cover the closure — and an
# archive silently missing files would only surface during a future offline rebuild, which is
# the worst possible time to find out.
#
# THE WHOLE CLOSURE IS OBTAINED WITH A FRESH EMPTY ROOT, NOT WITH --emptytree. Both make
# portage consider every package rather than only what is missing, and they are not otherwise
# equivalent: --emptytree re-resolves DEPEND for packages that are merely installed, and
# against this config that fails outright —
#
#     The following USE changes are necessary to proceed:
#     >=dev-qt/qttools-6.11.1 linguist
#
# reached via kde-frameworks/kcoreaddons <- kde-apps/baloo-widgets <- dolphin[semantic-desktop],
# because package.use/image sets -linguist. An empty root asks the question a clean rebuild
# actually asks — "install all of this from nothing" — and resolves cleanly, which is also
# exactly the set of distfiles a clean rebuild needs. Using the more aggressive flag here would
# have made the archive impossible to build for a reason that has nothing to do with archiving.
#
# --fetchonly does no building, so the empty root is never populated.
# The same "/" mirror stages 20 and 30 install. This stage resolves a depgraph, and
# lib/common.sh is explicit that the mirror "must run in EVERY container that resolves a
# depgraph" — portage evaluates target packages against the builder's own /etc/portage too, so
# without it a flag set only for the target reads as unset. Omitting it here failed the fetch on
#
#     >=net-firewall/iptables-1.8.13 nftables
#     # required by app-containers/containers-common -> podman -> distrobox
#
# for a flag config/portage/package.use/image has declared all along.
mirror_target_pkg_config

FETCH_ROOT="$WORK/fetchroot"
rm -rf -- "$FETCH_ROOT"
ensure_dir "$FETCH_ROOT"
seed_merged_usr "$FETCH_ROOT"
seed_target_dirs "$FETCH_ROOT"

log "completing distfiles for the image closure (this fetches, it does not build)"
if [[ -f $CONFIG_ROOT/etc/portage/sets/locked-image ]]; then
  FETCH_SETS=(@locked-image)
else
  warn "no @locked-image set — falling back to the loose sets for the fetch"
  FETCH_SETS=(@base @hardware); [[ ${CONSOLE_ONLY:-0} == 1 ]] || FETCH_SETS+=(@desktop)
fi
ROOT="$FETCH_ROOT" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
  emerge --fetchonly --usepkg=n --with-bdeps=n --quiet-build=y "${FETCH_SETS[@]}" \
  || die "could not fetch every distfile for ${FETCH_SETS[*]}.
  The archive would be incomplete, which is the one failure this stage exists to prevent.
  A SRC_URI that 404s means a pin has outlived its upstream tarball: relock that atom."
# Packages resolved for the builder's own "/" download into ITS DistDIR, not the config root's,
# and that one is container-local. Without this the archive silently lacks them — see the
# function's comment for the offline rebuild it broke.
distfiles_sweep
rm -rf -- "$FETCH_ROOT"

# --usepkg=n above is deliberate too: with binpkg reuse on, portage is satisfied by a binary
# and never looks at SRC_URI, which is precisely how the cache came to be incomplete.

log "completing distfiles for the builder closure"
if [[ -f /etc/portage/sets/locked-builder ]]; then
  emerge --fetchonly --usepkg=n --quiet-build=y @locked-builder \
    || warn "some builder distfiles could not be fetched — the builder image is archived
  whole, so this only affects rebuilding the builder from source rather than loading it"
  distfiles_sweep
fi

# Whatever the two passes above did or did not manage, the archive must contain the sources for
# every package a build actually installs — including the handful portage puts on "/" (DEPEND is
# installed to the build host even under --with-bdeps=n). Ask the real stage-30 resolution what
# those are and make sure each one's distfiles are present, rather than inferring it.
log "checking the builder-root packages stage 30 installs are covered"
mapfile -t HOST_PKGS < <(
  ROOT="$TARGET" PORTAGE_CONFIGROOT="$CONFIG_ROOT" \
    emerge --pretend --usepkg --with-bdeps=n --quiet "${FETCH_SETS[@]}" 2>/dev/null \
    | grep -E '^\[ebuild' | grep -v "to $TARGET/" \
    | sed -E 's/^\[[^]]*\][[:space:]]*//; s/[[:space:]].*$//' || true
)
if (( ${#HOST_PKGS[@]} )); then
  log "  ${#HOST_PKGS[@]} builder-root package(s): ${HOST_PKGS[*]}"
  emerge --fetchonly --usepkg=n --quiet-build=y "${HOST_PKGS[@]/#/=}" \
    || die "could not fetch sources for the builder-root packages stage 30 needs.
  An offline rebuild would stop partway through stage 30 exactly where these are merged."
  distfiles_sweep
else
  log "  none"
fi

ensure_dir "$V/distfiles"
rsync -a --delete /cache/distfiles/ "$V/distfiles/"
log "distfiles: $(find "$V/distfiles" -type f | wc -l) files, $(du -sh "$V/distfiles" | cut -f1)"

# ---- 3. binpkgs: the accelerator ------------------------------------------------------
# Optional by profile. Without them an offline rebuild still works and recompiles from source,
# which is complete but takes hours; with them it is mostly merges.
if [[ ${VENDOR_PROFILE:-full} == full ]]; then
  ensure_dir "$V/binpkgs"
  rsync -a --delete /cache/binpkgs/ "$V/binpkgs/"
  log "binpkgs: $(find "$V/binpkgs" -name '*.gpkg.tar' -o -name '*.tbz2' | wc -l) packages, $(du -sh "$V/binpkgs" | cut -f1)"
else
  rm -rf -- "$V/binpkgs"
  log "binpkgs: skipped (VENDOR_PROFILE=$VENDOR_PROFILE — offline rebuilds will compile from source)"
fi

# ---- 4. the flatpaks ------------------------------------------------------------------
# An OSTree repo holding exactly the locked commits, which `flatpak install --sideload-repo=`
# reads instead of the network during an offline stage 40.
APPS_LOCK="$REPO/config/flatpak/apps.lock"
if [[ -f $APPS_LOCK && -d $TARGET/var/lib/flatpak/repo && $FLATPAK_PREINSTALL_MODE == build ]]; then
  mapfile -t FP_REFS < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d' | awk '{print $1}')
  if (( ${#FP_REFS[@]} )); then
    # The target's own /var/lib/flatpak/repo IS an OSTree repo, and it already holds exactly the
    # commits apps.lock pins — stage 40 deployed them there. Copying it is the whole job.
    #
    # `flatpak create-usb` is the tool nominally built for this and cannot be used: it implements
    # the older P2P distribution scheme, which requires the remote to carry a collection ID, and
    # Flathub does not set one —
    #
    #   error: Remote 'flathub' does not have a collection ID set, which is required for
    #          P2P distribution of 'app/org.kde.ark/x86_64/stable'
    #
    # Setting one with `flatpak remote-modify --collection-id` was rejected: it would rewrite
    # the remote config inside the shipped image to satisfy a build-host tool.
    log "archiving ${#FP_REFS[@]} flatpak refs at their locked commits"
    ensure_dir "$V/flatpak"
    rsync -a --delete "$TARGET/var/lib/flatpak/repo/" "$V/flatpak/"

    # Assert the copy is a usable repo that actually contains the pinned commits, rather than
    # trusting that rsync copied the right directory. Checked per ref against the lock, because
    # a repo missing one app is exactly as broken as a repo missing all of them, and only one
    # of those two is obvious by eye.
    fp_missing=0
    while read -r ref commit; do
      [[ -n $ref && $ref != \#* ]] || continue
      have="$(cat "$V/flatpak/refs/heads/deploy/$ref" 2>/dev/null || true)"
      if [[ $have != "$commit" ]]; then
        warn "archived flatpak repo has $ref at '${have:-<absent>}', lock says ${commit:0:12}"
        fp_missing=1
      fi
      [[ -d $V/flatpak/objects ]] || { warn "archived flatpak repo has no objects/"; fp_missing=1; }
    done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')
    (( fp_missing == 0 )) || die "the archived flatpak repo does not carry every locked ref at its
  locked commit — an offline build would install the wrong application versions, or fail."
    log "flatpak repo: $(du -sh "$V/flatpak" | cut -f1), all ${#FP_REFS[@]} refs at their locked commits"
  fi
else
  log "flatpak: nothing to archive (mode=$FLATPAK_PREINSTALL_MODE)"
fi

# ---- 5. the locks and the provenance ---------------------------------------------------
# Copies, so the archive is self-describing: you can read what it claims to be without the
# repository it came from.
ensure_dir "$V/locks"
for l in "$LOCK_DIR"/image.lock "$LOCK_DIR"/builder.lock "$REPO/config/flatpak/apps.lock"; do
  [[ -f $l ]] && cp -f "$l" "$V/locks/"
done
cp -f "$REPO/config/build.conf" "$V/build.conf"
PROV="$RELEASE_DIR/${DISTRO_ID}_${VERSION}.provenance.txt"
[[ -f $PROV ]] && cp -f "$PROV" "$V/provenance.txt"

# ---- 6. the manifest -------------------------------------------------------------------
# Covers every file in the archive including the two image tarballs build.sh wrote before the
# stage loop. Signed with the release key when one is configured, the same way SHA256SUMS is.
log "hashing the archive (this walks every distfile)"
( cd "$V" && find . -type f ! -name 'MANIFEST.sha256*' -print0 | sort -z \
    | xargs -0 sha256sum > MANIFEST.sha256 )
if [[ -n ${RELEASE_GPG_KEY:-} ]]; then
  gpg --batch --yes --local-user "$RELEASE_GPG_KEY" \
      --detach-sign --output "$V/MANIFEST.sha256.gpg" "$V/MANIFEST.sha256"
fi

# ---- verify -----------------------------------------------------------------------------
[[ -s $V/MANIFEST.sha256 ]] || die "verify: empty manifest"
[[ -f $V/builder-image.tar.zst ]] \
  || die "verify: builder-image.tar.zst missing — an offline rebuild has no builder to load.
  build.sh writes it on the host before the stages run; check that --vendor reached it."
[[ -s $TREE_TAR ]] || die "verify: no tree archived"
[[ -d $V/distfiles ]] || die "verify: no distfiles in the archive"
log "archive complete: $(du -sh "$V" | cut -f1) in ${V#"$OUT"/}"
log "$(wc -l < "$V/MANIFEST.sha256") files, manifest$([[ -f $V/MANIFEST.sha256.gpg ]] && echo ' signed' || echo ' UNSIGNED')"

# Said loudly and deliberately. Everything above is a plausible archive; only an actual offline
# rebuild proves it is a complete one, and the gap between those two is exactly where a missing
# distfile hides until the year you need it.
warn "NOT YET PROVEN: an archive that has not had an offline rebuild run against it is not
  known to work. Run the acceptance test before treating this as a release artifact:
      ${RUNTIME:-docker} volume rm -f ${DISTRO_ID}-work ${DISTRO_ID}-cache ${DISTRO_ID}-tree
      scripts/build.sh --offline --vendor-dir ${V#"$OUT"/../}"
stamp_write "$STAGE_NAME" "$(inputs_hash "$V/MANIFEST.sha256")"
