#!/usr/bin/env bash
# Stage 10 — builder preflight + input pinning.
# Verifies the builder has every tool later stages need and moves the ebuild repo
# to the pinned snapshot. Fails fast here beats failing 2 hours into stage 30.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=10-fetch
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"

# ---- tool preflight (everything any later stage shells out to) ---------------
require_cmds emerge emerge-webrsync eselect \
  mkfs.erofs mkfs.vfat mkfs.ext4 mtools mcopy mmd \
  sfdisk dd truncate zstd rsync dracut gpg rsvg-convert objdump \
  qemu-system-x86_64 sha256sum
[[ -x /usr/lib/systemd/ukify ]] || command -v ukify >/dev/null 2>&1 \
  || die "ukify not found (builder systemd must be built with USE=ukify)"
[[ -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]] \
  || die "systemd-boot EFI binary missing (builder systemd must be built with USE=boot)"

# ---- ebuild repo snapshot pin --------------------------------------------------
TS_FILE=/var/db/repos/gentoo/metadata/timestamp.chk
current=""
[[ -f $TS_FILE ]] && current="$(date -u -d "$(cat "$TS_FILE")" +%Y%m%d 2>/dev/null || true)"
if [[ $current != "$SNAPSHOT_DATE" ]]; then
  log "repo snapshot is '$current', pin is '$SNAPSHOT_DATE' — syncing to pin"
  emerge-webrsync --revert="$SNAPSHOT_DATE"
else
  log "repo snapshot matches pin: $SNAPSHOT_DATE"
fi

# ---- verify -----------------------------------------------------------------------
[[ -f $TS_FILE ]] || die "verify: no repo timestamp after sync"
log "preflight OK"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
