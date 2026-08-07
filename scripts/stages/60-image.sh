#!/usr/bin/env bash
# Stage 60 — loopless image assembly (plan/04): every filesystem is built from a
# directory with userspace tools, partitions are dd'd into place by offset. No loop
# devices, no mounts — works in any privileged container, incl. Docker Desktop/WSL2.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=60-image
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
[[ -d $TARGET/usr ]] || die "target rootfs missing"
[[ -s $UKI_DIR/$UKI_NAME ]] || die "UKI missing — run stage 40"

require_cmds mkfs.erofs mkfs.ext4 mkfs.vfat mmd mcopy sfdisk dd truncate zstd rsync

STAGING="$WORK/staging"; rm -rf -- "$STAGING"; ensure_dir "$STAGING"
IMG="$OUT/$IMG_NAME"

# ---- 1. root EROFS (target minus /var payload; /var itself stays as a mountpoint) ---
# rsync to a staging copy so re-running this stage never mutates $TARGET.
ROOT_STAGE="$STAGING/root"
rsync -aHAX --exclude '/var/*' "$TARGET/" "$ROOT_STAGE/"
ROOT_EROFS="$OUT/$ROOT_IMG_NAME"
mkfs.erofs -z "$EROFS_COMPRESSION" -T0 --all-root "$ROOT_EROFS" "$ROOT_STAGE"

root_bytes="$(stat -c%s "$ROOT_EROFS")"
slot_bytes="$((ROOT_SLOT_SIZE_MIB * 1024 * 1024))"
(( root_bytes <= slot_bytes )) \
  || die "root image ($((root_bytes/1024/1024)) MiB) exceeds slot size (${ROOT_SLOT_SIZE_MIB} MiB)"
log "root erofs: $((root_bytes/1024/1024)) MiB of ${ROOT_SLOT_SIZE_MIB} MiB slot"

# ---- 2. var ext4 (the target's /var payload: flatpaks, overlay skeleton, homes) ------
VAR_STAGE="$STAGING/var"
rsync -aHAX "$TARGET/var/" "$VAR_STAGE/"
ensure_dir "$VAR_STAGE/overlay/etc/upper" "$VAR_STAGE/overlay/etc/work" \
           "$VAR_STAGE/home" "$VAR_STAGE/roothome"
VAR_IMG="$STAGING/var.img"
truncate -s "${VAR_SIZE_MIB}M" "$VAR_IMG"
mkfs.ext4 -q -F -L var -d "$VAR_STAGE" "$VAR_IMG"

# ---- 3. ESP vfat via mtools ------------------------------------------------------------
ESP_IMG="$STAGING/esp.img"
truncate -s "${ESP_SIZE_MIB}M" "$ESP_IMG"
mkfs.vfat -F32 -n ESP "$ESP_IMG" >/dev/null

SDBOOT=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
[[ -f $SDBOOT ]] || die "systemd-boot binary not found in builder"
LOADER_CONF="$STAGING/loader.conf"
printf 'timeout 0\ndefault %s_*\neditor no\n' "$DISTRO_ID" > "$LOADER_CONF"

mmd   -i "$ESP_IMG" ::/EFI ::/EFI/BOOT ::/EFI/systemd ::/EFI/Linux ::/loader
mcopy -i "$ESP_IMG" "$SDBOOT" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$SDBOOT" ::/EFI/systemd/systemd-bootx64.efi
mcopy -i "$ESP_IMG" "$LOADER_CONF" ::/loader/loader.conf
# factory UKI ships WITHOUT a tries counter: it's the known-good baseline (plan/01)
mcopy -i "$ESP_IMG" "$UKI_DIR/$UKI_NAME" "::/EFI/Linux/$UKI_NAME"

# ---- 4. GPT + concatenation --------------------------------------------------------------
compute_layout "$ESP_SIZE_MIB" "$ROOT_SLOT_SIZE_MIB" "$VAR_SIZE_MIB"
rm -f -- "$IMG"
truncate -s "${TOTAL_MIB}M" "$IMG"
emit_sfdisk_script "$VERSION" | sfdisk --quiet "$IMG"

ddp() { dd if="$1" of="$IMG" bs=1MiB seek="$2" conv=notrunc,sparse status=none; }
ddp "$ESP_IMG"    "$P1_START_MIB"
ddp "$ROOT_EROFS" "$P2_START_MIB"
# slot B (p3) stays zeros
ddp "$VAR_IMG"    "$P4_START_MIB"

zstd -T0 -f -q "$IMG" -o "$IMG.zst"

# ---- verify ---------------------------------------------------------------------------------
sfdisk --verify "$IMG" || die "verify: sfdisk rejects partition table"
# EROFS superblock magic (little-endian e2 e1 f5 e0) at offset 1024 inside p2
magic="$(dd if="$IMG" bs=1 skip=$(( P2_START_MIB*1024*1024 + 1024 )) count=4 status=none | od -An -tx1 | tr -d ' \n')"
[[ $magic == e2e1f5e0 ]] || die "verify: EROFS magic not found in root slot (got: $magic)"
# FAT boot sector jump instruction at p1 start
fatb="$(dd if="$IMG" bs=1 skip=$(( P1_START_MIB*1024*1024 )) count=1 status=none | od -An -tx1 | tr -d ' \n')"
[[ $fatb == eb || $fatb == e9 ]] || die "verify: no FAT boot sector at ESP offset (got: $fatb)"
log "image OK: $IMG ($(du -m "$IMG.zst" | cut -f1) MiB compressed)"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
