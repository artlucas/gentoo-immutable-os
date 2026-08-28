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
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

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
# The EROFS build timestamp, stamped onto EVERY inode (mkfs.erofs applies --all-time by
# default). It has to be deterministic — two builds of the same commit are meant to produce the
# same bytes — and it must not be ZERO, which is what this used to pass.
#
# -T0 cost the image its autologin, and the reason is worth stating in full because nothing in
# the build or the boot says a word about it. Plasma Login Manager decides whether to read
# /etc/plasmalogin.conf.d by taking the newest mtime under it and comparing that against its own
# "config already loaded" timestamp, which starts zero-initialised. Clamp every inode to the
# epoch and that comparison concludes nothing is newer than never: the drop-in is never parsed,
# [Autologin] User stays empty, and the daemon skips straight to the greeter. It skips SILENTLY
# — both "Autologin failed!" and "Unable to find autologin session entry" live inside the branch
# an empty username never enters, so the journal shows a clean, successful greeter start and no
# error of any kind. That is why this looked like a config bug for as long as it did; the config
# was correct the whole time and was simply never read.
#
# Measured in the guest against the shipped 0.3.0 image: restarting plasmalogin with the config
# untouched autologins nobody, and `touch /etc/plasmalogin.conf.d` — an mtime, not one byte of
# content — followed by the same restart puts the live user on seat0 immediately.
#
# SNAPSHOT_DATE is the source because it is already a build.conf pin: stable across rebuilds and
# machines, and it moves only when the inputs it names move. SOURCE_DATE_EPOCH overrides it if
# the caller exports one, which is the cross-project convention for exactly this value.
if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
  SOURCE_DATE_EPOCH="$(date -u -d "${SNAPSHOT_DATE:0:4}-${SNAPSHOT_DATE:4:2}-${SNAPSHOT_DATE:6:2}" +%s)" \
    || die "could not derive a build timestamp from SNAPSHOT_DATE=$SNAPSHOT_DATE"
fi
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ && $SOURCE_DATE_EPOCH -gt 0 ]] \
  || die "SOURCE_DATE_EPOCH must be a positive integer, got '${SOURCE_DATE_EPOCH}' — a zero mtime
on /etc is what stops Plasma Login Manager reading its config at all (see the note above)"
log "erofs timestamp: $SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC'))"
mkfs.erofs -z "$EROFS_COMPRESSION" -T"$SOURCE_DATE_EPOCH" --all-root "$ROOT_EROFS" "$ROOT_STAGE"

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
