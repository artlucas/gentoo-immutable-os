#!/usr/bin/env bash
# Stage 40 — turn the raw rootfs into this distro: overlay files, users, presets,
# flatpak, chroot finalizers, then build the initrd + UKI from the builder side.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=40-configure
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
[[ -d $TARGET/usr ]] || die "target rootfs missing — run stage 30 first"

# ---- 1. file overlay ------------------------------------------------------------
# Render variables available to templates (@NAME@ tokens):
VERIFY="$([[ $UPDATE_VERIFY == 1 ]] && echo yes || echo no)"
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER VERIFY FLATPAK_PREINSTALL
install_rootfs_overlay "$REPO/config/rootfs" "$TARGET"

# permissions the generic overlay rules can't know:
[[ -f $TARGET/etc/sudoers.d/wheel ]] && chmod 0440 "$TARGET/etc/sudoers.d/wheel"

# stateful trees live on /var (plan/01)
rm -rf -- "${TARGET:?}/home" "${TARGET:?}/root"
ln -s var/home     "$TARGET/home"
ln -s var/roothome "$TARGET/root"
ensure_dir "$TARGET/var/home" "$TARGET/var/roothome" \
           "$TARGET/var/overlay/etc/upper" "$TARGET/var/overlay/etc/work" "$TARGET/efi"
chmod 0700 "$TARGET/var/roothome"

# machine-id: empty file = "generate at first boot"
: > "$TARGET/etc/machine-id"

# update verification keyring
if [[ $UPDATE_VERIFY == 1 ]]; then
  [[ -f $REPO/config/keys/import-pubring.gpg ]] \
    || die "UPDATE_VERIFY=1 but config/keys/import-pubring.gpg missing (or set UPDATE_VERIFY=0 for dev)"
  install -D -m 0644 "$REPO/config/keys/import-pubring.gpg" \
    "$TARGET/usr/lib/systemd/import-pubring.gpg"
else
  warn "UPDATE_VERIFY=0 — image will accept unsigned updates (dev only)"
fi

# locale.gen from build.conf (';'-separated entries)
printf '%s\n' "${LOCALE_GEN//;/$'\n'}" > "$TARGET/etc/locale.gen"
echo 'LANG=en_US.UTF-8'   > "$TARGET/etc/locale.conf"
echo 'KEYMAP=us'          > "$TARGET/etc/vconsole.conf"
ln -sfn ../usr/share/zoneinfo/UTC "$TARGET/etc/localtime"

# ---- 2. chroot configuration -------------------------------------------------------
target_mount "$TARGET"
trap 'target_umount "$TARGET"' EXIT

chroot_target "$TARGET" "locale-gen"

# live user (v1 live-style images; the future installer replaces this)
if ! chroot_target "$TARGET" "id -u '$LIVE_USER'" >/dev/null 2>&1; then
  chroot_target "$TARGET" "useradd -m -G wheel,video,audio -s /bin/bash '$LIVE_USER'"
  chroot_target "$TARGET" "echo '$LIVE_USER:$LIVE_USER_PASSWORD' | chpasswd"
fi

# unit presets shipped by the overlay decide what's enabled
chroot_target "$TARGET" "systemctl preset-all --preset-mode=enable-only" || \
  warn "preset-all reported errors (often benign; review log)"

# flatpak: remote always; apps per FLATPAK_PREINSTALL_MODE
chroot_target "$TARGET" \
  "flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
if [[ $FLATPAK_PREINSTALL_MODE == build && -n ${FLATPAK_PREINSTALL// /} ]]; then
  for app in $FLATPAK_PREINSTALL; do
    log "preinstalling flatpak: $app"
    chroot_target "$TARGET" "flatpak install -y --system --noninteractive flathub '$app'"
  done
  # apps are baked in — the firstboot preinstall unit must never fire
  ensure_dir "$TARGET/var/lib/$DISTRO_ID"
  : > "$TARGET/var/lib/$DISTRO_ID/flatpak-preinstall.done"
fi

# finalizers (guarded: console-only images lack the GUI tools)
chroot_target "$TARGET" "ldconfig"
chroot_target "$TARGET" "systemd-hwdb update --usr"
chroot_target "$TARGET" "command -v glib-compile-schemas >/dev/null && glib-compile-schemas /usr/share/glib-2.0/schemas || true"
chroot_target "$TARGET" "command -v fc-cache >/dev/null && fc-cache -f || true"
chroot_target "$TARGET" "command -v update-desktop-database >/dev/null && update-desktop-database || true"
chroot_target "$TARGET" "command -v update-mime-database >/dev/null && update-mime-database /usr/share/mime || true"

target_umount "$TARGET"
trap - EXIT

# ---- 3. initrd + UKI (built HERE, in the builder — the target has no dracut) --------
KVER="$(basename -- "$(find "$TARGET/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)")"
[[ -n $KVER ]] || die "cannot determine kernel version from target modules"
log "kernel: $KVER"

KERNEL_IMG=""
for c in "$TARGET/usr/lib/modules/$KVER/vmlinuz" "$TARGET/boot/vmlinuz-$KVER" "$TARGET/boot/kernel-$KVER"; do
  [[ -f $c ]] && { KERNEL_IMG="$c"; break; }
done
[[ -n $KERNEL_IMG ]] || die "kernel image not found in target (checked modules dir and /boot)"

# our dracut module must be visible to the *builder's* dracut
cp -r "$TARGET/usr/lib/dracut/modules.d/90etc-overlay" /usr/lib/dracut/modules.d/

INITRD="$WORK/initrd-$VERSION.img"
dracut --force --no-hostonly --reproducible \
  --sysroot "$TARGET" --kver "$KVER" \
  --add "systemd etc-overlay systemd-repart" \
  --omit "network network-legacy nfs iscsi lvm mdraid multipath dmraid cifs brltty" \
  --early-microcode \
  "$INITRD"

CMDLINE="root=PARTLABEL=$ROOT_PARTLABEL rootfstype=erofs ro nvidia-drm.modeset=1 console=ttyS0 console=tty0 quiet"
UKIFY=ukify; [[ -x /usr/lib/systemd/ukify ]] && UKIFY=/usr/lib/systemd/ukify
ensure_dir "$UKI_DIR"
"$UKIFY" build \
  --linux="$KERNEL_IMG" \
  --initrd="$INITRD" \
  --cmdline="$CMDLINE" \
  --os-release="@$TARGET/etc/os-release" \
  --output="$UKI_DIR/$UKI_NAME"

# ---- verify ---------------------------------------------------------------------------
grep -q "IMAGE_VERSION=$VERSION" "$TARGET/etc/os-release" || die "verify: os-release version mismatch"
grep -q "ID=$DISTRO_ID" "$TARGET/etc/os-release"          || die "verify: os-release ID mismatch"
[[ -s $UKI_DIR/$UKI_NAME ]]                               || die "verify: UKI missing/empty"
[[ -f $TARGET/usr/lib/sysupdate.d/50-rootfs.transfer ]]   || die "verify: sysupdate transfer missing"
[[ -L $TARGET/home ]]                                     || die "verify: /home symlink missing"
log "configure complete; UKI at $UKI_DIR/$UKI_NAME"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
