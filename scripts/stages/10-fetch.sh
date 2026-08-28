#!/usr/bin/env bash
# Stage 10 — builder preflight + input pinning.
# Verifies the builder has every tool later stages need, reconciles the ebuild tree volume
# against the SNAPSHOT_DATE pin, and asserts the builder's own closure matches builder.lock.
# Fails fast here beats failing 2 hours into stage 30.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=10-fetch
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"

# One DISTDIR for both roots (see the function). Per stage, because each runs in its own
# container and nothing written to /etc/portage survives to the next.
share_builder_distdir

# ---- tool preflight (everything any later stage shells out to) ---------------
# wget + tar replace emerge-webrsync here: the tree now arrives as a commit-pinned tarball
# (plan/15), and requiring a tool this pipeline no longer uses would only mislead.
require_cmds emerge wget tar eselect portageq \
  mkfs.erofs mkfs.vfat mkfs.ext4 mtools mcopy mmd \
  sfdisk dd truncate zstd rsync dracut gpg rsvg-convert objdump \
  qemu-system-x86_64 sha256sum
[[ -x /usr/lib/systemd/ukify ]] || command -v ukify >/dev/null 2>&1 \
  || die "ukify not found (builder systemd must be built with USE=ukify)"
[[ -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]] \
  || die "systemd-boot EFI binary missing (builder systemd must be built with USE=boot)"

# ---- vendored archive (offline rebuilds) --------------------------------------------
# Seeded here rather than in build.sh because this is where the assertions already live, and
# because /cache and /var/db/repos are container-side paths the host should not have to know.
if [[ -n ${VENDOR_DIR:-} && -d ${VENDOR_DIR:-} ]]; then
  log "vendored archive present at $VENDOR_DIR"
  if [[ -d $VENDOR_DIR/distfiles ]]; then
    ensure_dir /cache/distfiles
    # -n: never overwrite. A distfile is content-addressed by its Manifest checksum, so a
    # local copy that verifies is the same file; copying over it would only cost time.
    cp -rn "$VENDOR_DIR/distfiles/." /cache/distfiles/ 2>/dev/null || true
    log "distfiles seeded: $(find /cache/distfiles -type f | wc -l) files"
  fi
  if [[ -d $VENDOR_DIR/binpkgs ]]; then
    ensure_dir /cache/binpkgs
    cp -rn "$VENDOR_DIR/binpkgs/." /cache/binpkgs/ 2>/dev/null || true
    log "binpkgs seeded: $(find /cache/binpkgs -name '*.gpkg.tar' -o -name '*.tbz2' | wc -l) packages"
  fi
fi

# ---- ebuild tree: reconcile the volume against the pin -------------------------------
# /var/db/repos is a named volume, so unlike the old emerge-webrsync --revert this survives
# the stage boundary and stages 20/30 resolve against the tree this pin names.
have="$(tree_marker_read)"; want="$(tree_pin_id)"
if [[ $have == "$want" ]]; then
  log "tree is at the pin: $SNAPSHOT_DATE"
else
  log "tree is at '$have', pin is '$want' — repopulating"
  vendored=""
  for cand in "${VENDOR_DIR:-}/$(snapshot_tarball_name)" "${VENDOR_DIR:-}/tree-$SNAPSHOT_DATE.tar.zst"; do
    [[ -n ${VENDOR_DIR:-} && -f $cand ]] && { vendored="$cand"; break; }
  done
  if [[ -n $vendored ]]; then
    tree_populate "$vendored"
  elif [[ ${OFFLINE:-0} == 1 ]]; then
    die "offline build, but the archive has no snapshot for $SNAPSHOT_DATE and the tree volume
  is at '$have'. The archive does not match this build.conf."
  else
    tree_populate
  fi
fi

# ---- builder closure vs builder.lock -------------------------------------------------
# dracut, systemd/ukify and erofs-utils build the shipped initrd, UKI and root filesystem, so
# the builder's own versions are image inputs (plan/15 layer 3). The Dockerfile emerges
# @locked-builder, but a builder image can also be older than the lock in the repo — that is
# the case this catches, and it is invisible otherwise because every tool still works.
BUILDER_LOCK="$LOCK_DIR/builder.lock"
if [[ -f $BUILDER_LOCK ]]; then
  ensure_dir "$REPORT_DIR"
  vdb_atoms / | lock_write "$REPORT_DIR/builder.lock.generated" \
    "builder.lock — the builder's own \"/\" closure, installed from the binhost"
  if lock_diff "$BUILDER_LOCK" "$REPORT_DIR/builder.lock.generated" > "$REPORT_DIR/builder-lock.diff"; then
    log "builder closure matches builder.lock ($(lock_atoms "$BUILDER_LOCK" | wc -l) atoms)"
  else
    cat "$REPORT_DIR/builder-lock.diff"
    die "the builder image's own closure does not match config/portage/lock/builder.lock.
  Rebuild the builder image (build.sh does this automatically), or if the difference is
  intended, re-resolve the lock:  scripts/relock.sh --builder"
  fi
else
  ensure_dir "$REPORT_DIR"
  vdb_atoms / | lock_write "$REPORT_DIR/builder.lock.generated" \
    "builder.lock — the builder's own \"/\" closure, installed from the binhost"
  warn "no config/portage/lock/builder.lock yet — review $REPORT_DIR/builder.lock.generated
  and commit it as config/portage/lock/builder.lock (plan/15)"
fi

# ---- verify -----------------------------------------------------------------------
tree_assert
log "preflight OK — snapshot $SNAPSHOT_DATE (tree timestamp $(tree_date)), sha256 pinned"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
