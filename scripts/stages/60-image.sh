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

require_cmds mkfs.erofs mkfs.ext4 mkfs.vfat mmd mcopy sfdisk dd truncate zstd rsync tar

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

# ---- 2a. the var TEMPLATE — a payload artifact, not part of this image ----------------
# An installer medium cannot rebuild a /var; it seeds one. So a target-role build publishes its
# /var as a tarball beside the root EROFS, and the installer profile stages that file into its
# own /var and unpacks it onto the disk it is installing (plan/16 §5.1 step 4).
#
# Written from $VAR_STAGE, the same tree the ext4 above is built from, so the seeded /var and the
# dd'd one are the same bytes by construction rather than by two code paths agreeing.
#
# Only for `target` profiles: a live medium's /var holds the payload itself, and tarring that
# would be an installer image trying to pack a copy of its own payload.
#
# --numeric-owner because this tarball is unpacked on a machine whose /etc/passwd is the target's,
# not the builder's; --sort=name and a fixed --mtime because two builds of one commit are meant to
# produce the same bytes. zstd -3: the flatpak store is ~2.7 GiB of already-deployed files, and
# the difference between -3 and -19 here is minutes of build time for a few percent of a stick.
if [[ $PROFILE_ROLE == target ]]; then
  VAR_TAR="$OUT/$VAR_TEMPLATE_NAME"
  log "var template: packing $VAR_STAGE -> ${VAR_TAR#"$OUT"/}"
  tar --create --directory="$VAR_STAGE" \
      --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
      --xattrs --acls . \
    | zstd -T0 -3 -q -o "$VAR_TAR.tmp"
  mv -f -- "$VAR_TAR.tmp" "$VAR_TAR"
  log "var template: $(du -m "$VAR_TAR" | cut -f1) MiB compressed"
fi

# The var partition has to actually HOLD what stage 40 staged into it. For the desktop profile
# that has always been slack; for an installer profile the payload is ~5 GiB and a var sized by
# habit rather than by measurement produces an mkfs.ext4 that succeeds and an image that is
# missing files. mkfs.ext4 -d does not fail on a full filesystem — it warns, and the warning
# scrolls past — so check the free space and name the value to raise.
var_used_kib="$(du -sk "$VAR_STAGE" | cut -f1)"
var_need_mib=$(( var_used_kib / 1024 + var_used_kib / 1024 / 20 + 64 ))   # +5% metadata, +64 MiB
(( VAR_SIZE_MIB >= var_need_mib )) || die "var partition is too small for its contents:
  staged $(( var_used_kib / 1024 )) MiB, need >= ${var_need_mib} MiB (ext4 metadata + slack),
  VAR_SIZE_MIB is ${VAR_SIZE_MIB}.
  Raise VAR_SIZE_MIB in $( [[ $BUILD_PROFILE == "$DEFAULT_BUILD_PROFILE" ]] \
      && echo config/build.conf || echo "config/profiles/$BUILD_PROFILE.conf" )"

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
# PROFILE_ROOT_SLOTS is 2 for anything installable and 1 for live media, which has nothing to
# update and would otherwise carry 6 GiB of zeros on every stick (plan/16 §3.1).
compute_layout "$ESP_SIZE_MIB" "$ROOT_SLOT_SIZE_MIB" "$VAR_SIZE_MIB" "$PROFILE_ROOT_SLOTS"
log "layout: ${PART_COUNT} partitions, ${PROFILE_ROOT_SLOTS} root slot(s), ${TOTAL_MIB} MiB total"
rm -f -- "$IMG"
truncate -s "${TOTAL_MIB}M" "$IMG"
emit_sfdisk_script "$VERSION" | sfdisk --quiet "$IMG"

# BY ROLE, not by index: with one root slot the var partition is p3, and a hardcoded P4 offset
# would write the whole var filesystem past the end of the image — into sparse nothing, with dd
# reporting success.
ddp() { dd if="$1" of="$IMG" bs=1MiB seek="$2" conv=notrunc,sparse status=none; }
ddp "$ESP_IMG"    "$ESP_START_MIB"
ddp "$ROOT_EROFS" "$ROOT_A_START_MIB"
# slot B, where there is one, stays zeros: it is the empty half of the A/B pair
ddp "$VAR_IMG"    "$VAR_START_MIB"

zstd -T0 -f -q "$IMG" -o "$IMG.zst"

# ---- verify ---------------------------------------------------------------------------------
sfdisk --verify "$IMG" || die "verify: sfdisk rejects partition table"
# EROFS superblock magic (little-endian e2 e1 f5 e0) at offset 1024 inside p2
magic="$(dd if="$IMG" bs=1 skip=$(( ROOT_A_START_MIB*1024*1024 + 1024 )) count=4 status=none | od -An -tx1 | tr -d ' \n')"
[[ $magic == e2e1f5e0 ]] || die "verify: EROFS magic not found in root slot (got: $magic)"
# FAT boot sector jump instruction at p1 start
fatb="$(dd if="$IMG" bs=1 skip=$(( ESP_START_MIB*1024*1024 )) count=1 status=none | od -An -tx1 | tr -d ' \n')"
[[ $fatb == eb || $fatb == e9 ]] || die "verify: no FAT boot sector at ESP offset (got: $fatb)"
log "image OK: $IMG ($(du -m "$IMG.zst" | cut -f1) MiB compressed)"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
