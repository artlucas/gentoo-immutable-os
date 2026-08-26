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
# The splash's bottom-left field, uppercased the way the design system's text-transform does it
# ("Stable · v0.1.0 · amd64" -> "STABLE · V0.1.0 · AMD64"). Composed here rather than in the SVG
# because both halves come from build.conf and neither is a plain @TOKEN@ substitution.
SPLASH_STATUS_LEFT="$(printf '%s · V%s · AMD64' "$UPDATE_CHANNEL" "$VERSION" | tr '[:lower:]' '[:upper:]')"
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER VERIFY FLATPAK_PREINSTALL
export UPDATE_CHANNEL SPLASH_STATUS_LEFT
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

# DNS: systemd-resolved owns resolution in this image (see config/rootfs/etc/nsswitch.conf,
# the NetworkManager drop-in and the preset). /etc/resolv.conf becomes the symlink to
# resolved's stub, which is the state resolved, NetworkManager and glibc's "dns" fallback all
# expect. It is made here rather than shipped in config/rootfs because the overlay installer
# copies regular files only — and because git checkouts on Windows/NTFS do not reliably
# preserve symlinks.
#
# The link DANGLES at build time: /run/systemd/resolve/stub-resolv.conf only exists once
# resolved runs. That is deliberate and load-bearing. target_mount() (lib/common.sh) copies
# the builder's nameservers *through* this symlink into the tmpfs it mounts on the target's
# /run, so the chroot below (flatpak talks to flathub) resolves normally and the builder's
# DNS config disappears with the tmpfs instead of being baked into the image.
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"

# ---- 2. chroot configuration -------------------------------------------------------
target_mount "$TARGET"
trap 'target_umount "$TARGET"' EXIT

# locale generation. sys-apps/locale-gen is a stage3 convenience, not part of the image's
# package set, so the binary does not exist in the target — but glibc's localedef does, and
# locale-gen is only a wrapper around it. Drive localedef directly from /etc/locale.gen so no
# build-only tool has to ship in the image.
ensure_dir "$TARGET/usr/lib/locale"   # localedef writes locale-archive here and won't mkdir it
if chroot_target "$TARGET" "command -v locale-gen >/dev/null"; then
  chroot_target "$TARGET" "locale-gen"
else
  while read -r loc charset; do
    [[ -z $loc || $loc == \#* ]] && continue
    base="${loc%%.*}"                                   # en_US.UTF-8 -> en_US
    [[ $loc == *@* ]] && base="${base}@${loc##*@}"       # keep @modifiers (de_DE@euro)
    log "localedef: $loc ($charset)"
    chroot_target "$TARGET" "localedef -i '$base' -f '$charset' '$loc'"
  done < "$TARGET/etc/locale.gen"
fi

# live user (v1 live-style images; the future installer replaces this)
if ! chroot_target "$TARGET" "id -u '$LIVE_USER'" >/dev/null 2>&1; then
  chroot_target "$TARGET" "useradd -m -G wheel,video,audio -s /bin/bash '$LIVE_USER'"
  chroot_target "$TARGET" "echo '$LIVE_USER:$LIVE_USER_PASSWORD' | chpasswd"
fi

# unit presets shipped by the overlay decide what's enabled
chroot_target "$TARGET" "systemctl preset-all --preset-mode=enable-only" || \
  warn "preset-all reported errors (often benign; review log)"

# ...but --preset-mode=enable-only IGNORES every "disable" line in our preset file, and
# preset-all also applies the VENDOR presets, which enable units we do not want. That is how
# the image ended up running systemd-networkd alongside NetworkManager, with
# systemd-networkd-wait-online.service failing every boot. Apply our disables explicitly.
PRESET_FILE="$TARGET/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
if [[ -f $PRESET_FILE ]]; then
  while read -r unit; do
    [[ -z $unit ]] && continue
    log "disabling per preset: $unit"
    chroot_target "$TARGET" "systemctl disable '$unit'" >/dev/null 2>&1 \
      || warn "could not disable $unit (may be static or absent)"
  done < <(sed -nE 's/^disable[[:space:]]+([^[:space:]]+).*/\1/p' "$PRESET_FILE")
fi

# ldconfig.service is static, so it cannot be disabled — only masked. It must be masked here:
# Gentoo builds systemd with -Dsplit-bin=false, so systemd's exec search path is
# /usr/local/bin:/usr/bin with NO sbin, while ldconfig lives in /usr/sbin. Its bare
# "ExecStart=ldconfig" therefore always fails 203/EXEC ("Unable to locate executable").
# Nothing is lost: /etc/ld.so.cache is generated below at build time, and on a read-only
# erofs root there is nothing for a boot-time cache rebuild to discover.
chroot_target "$TARGET" "systemctl mask ldconfig.service" >/dev/null 2>&1 \
  || warn "could not mask ldconfig.service"

# flatpak: remote always; apps per FLATPAK_PREINSTALL_MODE
chroot_target "$TARGET" \
  "flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo"

# Locale scoping, BEFORE any install. Without an explicit xa.languages, flatpak pulls the
# .Locale extension subpath for every language the runtime ships:
# org.freedesktop.Platform.Locale alone was 824 MiB of the 2495 MiB /var this image carried,
# plus 48 MiB for org.mozilla.firefox.Locale — in an image whose build.conf names nine locales
# and whose stage-50 prune deletes every other message catalog out of /usr/share/locale on
# exactly that list. Measured saving (plan/10): 615 + 40 = 655 MiB off /var.
#
# Set unconditionally, not just in "build" mode: the key is written to
# /var/lib/flatpak/repo/config, which ships with the image, so the firstboot preinstall unit
# and every later `flatpak install` the user runs inherit it too.
#
# The subpaths are keyed by bare LANGUAGE code — the deployed extension has "pt" and "zh", never
# "pt_BR" or "zh_CN", and no "en" at all (English lives in the runtime itself). So the region
# suffix is stripped rather than passed through. flatpak would tolerate the longer form (it
# derives the base language itself and ignores a subpath that does not exist), but the config
# would then name subpaths that are not there, which misleads anyone reading it back.
FLATPAK_LANGS="$(printf '%s\n' $LOCALES_KEEP | sed 's/[_.@].*//' | sed '/^$/d' | sort -u | paste -sd';')"
[[ -n $FLATPAK_LANGS ]] || die "LOCALES_KEEP produced an empty flatpak language list"
log "flatpak languages: $FLATPAK_LANGS"
chroot_target "$TARGET" "flatpak config --system --set languages '$FLATPAK_LANGS'" \
  || die "flatpak config --set languages failed — the image would ship every locale on Flathub"
# Read it back. A silently-unset key costs 655 MiB and is invisible until someone measures /var,
# which is the same failure mode plan/06 records for the size report itself.
FL_READBACK="$(chroot_target "$TARGET" "flatpak config --system --get languages" 2>/dev/null | tr -d '[:space:]')"
[[ $FL_READBACK == "$FLATPAK_LANGS" ]] \
  || die "flatpak xa.languages reads back as '${FL_READBACK:-<unset>}', expected '$FLATPAK_LANGS'"

if [[ $FLATPAK_PREINSTALL_MODE == build && -n ${FLATPAK_PREINSTALL// /} ]]; then
  for app in $FLATPAK_PREINSTALL; do
    log "preinstalling flatpak: $app"
    chroot_target "$TARGET" "flatpak install -y --system --noninteractive flathub '$app'"
  done
  # apps are baked in — the firstboot preinstall unit must never fire
  ensure_dir "$TARGET/var/lib/$DISTRO_ID"
  : > "$TARGET/var/lib/$DISTRO_ID/flatpak-preinstall.done"
fi

# NetworkManager must actually agree that resolved owns DNS. The drop-in is installed under
# /usr/lib/NetworkManager/conf.d, and whether NM reads that path (rather than a libdir variant)
# is a build-time detail of the ebuild, not something the file's presence proves. --print-config
# parses the real config stack and prints the effective values, so ask NM itself.
# NB: the binary is addressed by absolute path. chroot(2) does not reset PATH, and Gentoo
# builds systemd with -Dsplit-bin=false — so a bare "NetworkManager" resolves against whatever
# the builder's PATH happens to be, which need not contain /usr/sbin.
NM_BIN=""
for c in /usr/sbin/NetworkManager /usr/bin/NetworkManager /usr/libexec/NetworkManager; do
  [[ -x $TARGET$c ]] && { NM_BIN="$c"; break; }
done
if [[ -z $NM_BIN ]]; then
  die "NetworkManager binary not found in target — it is in @base and the DNS wiring depends on it"
elif NM_CONFIG="$(chroot_target "$TARGET" "$NM_BIN --print-config" 2>/dev/null)"; then
  NM_DNS="$(sed -nE 's/^[[:space:]]*dns=([^[:space:]]+).*/\1/p' <<<"$NM_CONFIG" | tail -n1)"
  [[ $NM_DNS == systemd-resolved ]] \
    || die "NetworkManager effective dns=${NM_DNS:-<unset>}, expected systemd-resolved — is the conf.d drop-in in a directory NM reads?"
  log "NetworkManager effective dns=$NM_DNS"
else
  warn "$NM_BIN --print-config failed in the chroot — DNS backend unverified"
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

# ---- 2b. boot splash -----------------------------------------------------------------
# Must run BEFORE dracut: dracut's plymouth module copies the theme out of $TARGET into the
# initramfs, so a theme installed afterwards would exist on the root filesystem and be missing
# from the initrd — i.e. no splash until the root pivot, which is most of the boot.
THEME_DIR="$TARGET/usr/share/plymouth/themes/$DISTRO_ID"
install_branding "$REPO/config/branding" "$THEME_DIR"
# Both dracut and plymouthd resolve the default theme through this symlink. install_rootfs_overlay
# copies regular files only, so it is made here — same reason as the resolv.conf link above.
ln -sfn "$DISTRO_ID/$DISTRO_ID.plymouth" "$TARGET/usr/share/plymouth/themes/default.plymouth"
# dracut's plymouth module (45plymouth) locates plymouth through its own helper and, if that
# helper is not in the sysroot, its check() returns 1 and dracut SKIPS THE MODULE ENTIRELY —
# no error, no warning, just an initrd with no splash in it. Fail here instead, where the
# message can say what is wrong.
PPI=""
for c in /usr/libexec/plymouth /usr/lib64/plymouth /usr/lib/plymouth; do
  [[ -x $TARGET$c/plymouth-populate-initrd ]] && { PPI="$c"; break; }
done
[[ -n $PPI ]] \
  || die "plymouth-populate-initrd not found under $TARGET/{usr/libexec,usr/lib64,usr/lib}/plymouth
  — dracut's plymouth module would silently install nothing and the image would boot bare."
PLYMOUTH_PLUGIN_DIR=""
for c in /usr/lib64/plymouth /usr/lib/plymouth; do
  [[ -f $TARGET$c/script.so ]] && { PLYMOUTH_PLUGIN_DIR="$c"; break; }
done
[[ -n $PLYMOUTH_PLUGIN_DIR ]] \
  || die "plymouth's script plugin not found under $TARGET/{usr/lib64,usr/lib}/plymouth
  — the theme names ModuleName=script and plymouthd would have nothing to interpret it with."
log "boot splash theme installed at $THEME_DIR (dracut helper: $PPI)"

# The splash-to-greeter hand-off (plymouth-quit.service.d/10-retain-splash.conf) hardcodes this
# path. systemd's "-" prefix swallows a 203/EXEC just as it swallows a non-zero exit, so a
# plymouth binary that moved would not fail anything — the splash would simply go back to
# blanking the screen before the greeter, silently, which is the regression that drop-in exists
# to remove.
RETAIN_DROPIN="$TARGET/usr/lib/systemd/system/plymouth-quit.service.d/10-retain-splash.conf"
[[ -x $TARGET/usr/bin/plymouth ]] \
  || die "verify: /usr/bin/plymouth missing from target — plymouth-quit.service.d/10-retain-splash.conf
  names that exact path and systemd would ignore its absence"
# ...and it is a DESKTOP-only drop-in. On --console-only the next thing to touch the screen is
# agetty, which renders its login prompt into the same framebuffer — a retained splash would sit
# behind the text rather than being replaced by a greeter. That image keeps the plain teardown.
if [[ ${CONSOLE_ONLY:-0} == 1 && -f $RETAIN_DROPIN ]]; then
  log "console-only image: removing the retain-splash drop-in (no greeter to hand off to)"
  rm -f -- "$RETAIN_DROPIN"
  rmdir -- "$(dirname -- "$RETAIN_DROPIN")" 2>/dev/null || true
fi

# ---- 2c. firmware + microcode prune, BEFORE dracut -----------------------------------
# This has to happen here rather than in stage 50, and the reason is the finding plan/10 closed
# with rather than solved: stage 50 runs AFTER this stage, so config/prune-firmware.txt only ever
# reached the root filesystem. The 0.2.1 UKI still carried every blob the list names — the qcom
# ARM SoC firmware included — on the ESP of every installed machine and in every A/B update.
#
# The microcode half is why this is worth more than tidiness. dracut's --early-microcode packs
# /usr/lib/firmware/{intel,amd}-ucode into the initrd's EARLY cpio, which the kernel must read
# before it can decompress anything and which is therefore stored UNCOMPRESSED. On the 0.2.2 UKI
# that was 34.8 MiB of 135.5 — a quarter of the boot artifact, at 1 byte saved per byte pruned.
#
# Stage 50 calls this again as a guard, so `--from 50` converges too. Idempotent either way.
prune_hardware_trees "$TARGET"

# ---- 3. initrd + UKI (built HERE, in the builder — the target has no dracut) --------
# Exactly one, asserted. This used to be `find … | head -n1`, which picks an ARBITRARY directory
# in readdir order — so a target that ever ended up with two module trees (a kernel bump merged
# into an existing root, say) would build a UKI for whichever one the filesystem happened to list
# first, with a kernel and a module set that disagree. Nothing downstream would notice: the image
# builds, boots as far as the initrd, and then has no drivers.
mapfile -t KVERS < <(find "$TARGET/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
(( ${#KVERS[@]} == 1 )) \
  || die "expected exactly one kernel in $TARGET/usr/lib/modules, found ${#KVERS[@]}: ${KVERS[*]:-<none>}"
KVER="${KVERS[0]}"
log "kernel: $KVER"

KERNEL_IMG=""
# $WORK/vmlinuz-$KVER is last and is OUR copy, not the target's — see the stash below.
for c in "$TARGET/usr/lib/modules/$KVER/vmlinuz" "$TARGET/boot/vmlinuz-$KVER" \
         "$TARGET/boot/kernel-$KVER" "$WORK/vmlinuz-$KVER"; do
  [[ -f $c ]] && { KERNEL_IMG="$c"; break; }
done
[[ -n $KERNEL_IMG ]] || die "kernel image not found in target (checked modules dir, /boot and $WORK)"

# Stash it. /usr/lib/modules/$KVER/vmlinuz is a SYMLINK into /usr/src/linux-$KVER, and stage 50
# deletes /usr/src wholesale — so after one full build the target's kernel image is a dangling
# link and this stage can no longer run against that rootfs without re-emerging the kernel.
# That turns "rebuild the UKI with a different cmdline or splash" from a two-minute rerun of
# stages 40-60 into a full rebuild, which is the whole point of SPLASH_BACKEND being a switch.
# Copying costs ~15 MB in the work volume and makes stage 40 idempotent across stage 50.
if [[ $KERNEL_IMG != "$WORK/vmlinuz-$KVER" ]]; then
  cp -f -- "$KERNEL_IMG" "$WORK/vmlinuz-$KVER"
fi
log "kernel image: $KERNEL_IMG"

# our dracut module must be visible to the *builder's* dracut
cp -r "$TARGET/usr/lib/dracut/modules.d/90etc-overlay" /usr/lib/dracut/modules.d/

# dracut is a builder tool and is deliberately not part of the image's package set, but
# --sysroot resolves BOTH dracutbasedir and every module file dracut-install copies relative
# to the sysroot. Without a copy inside the target it dies on
# "/work/target/usr/lib/dracut/dracut-functions.sh: No such file or directory"; with only
# dracutbasedir overridden it "succeeds" while silently failing to install initqueue,
# loginit, rdsosreport, shutdown and dracut-util into the initramfs. So: lend the target a
# full copy for the duration of the run, then take it away again.
DRACUT_LIB="$TARGET/usr/lib/dracut"
OVERLAY_MOD_KEEP="$WORK/90etc-overlay.keep"
rm -rf -- "$OVERLAY_MOD_KEEP"
[[ -d $DRACUT_LIB/modules.d/90etc-overlay ]] && cp -a "$DRACUT_LIB/modules.d/90etc-overlay" "$OVERLAY_MOD_KEEP"
ensure_dir "$DRACUT_LIB"
cp -a /usr/lib/dracut/. "$DRACUT_LIB/"

INITRD="$WORK/initrd-$VERSION.img"
# dracut's 45plymouth module does NOT honour --sysroot for its payload. It hands the work to
# plymouth-populate-initrd without setting PLYMOUTH_SYSROOT, so the helper reads the BUILDER's
# filesystem — which has no plymouth at all — and quietly installs nothing but the two binaries
# dracut itself copies. That produced an initrd with plymouthd in it, an EMPTY theme directory,
# and no script plugin or DRM renderer: a splash that could never draw. module-setup.sh runs
# the helper with stderr sent to /dev/null, so there was not one word of warning.
#
# The helper documents these variables for exactly this case ("For running on a
# (cross-compiled) sysroot"). PLYMOUTH_PLUGIN_PATH has to be given too: its default is
# "$(plymouth --get-splash-plugin-path)", which runs the builder's absent plymouth. Same-arch
# here, so the default ldd is fine — inst_library copies from under the sysroot regardless.
export PLYMOUTH_SYSROOT="$TARGET"
export PLYMOUTH_THEME_NAME="$DISTRO_ID"
export PLYMOUTH_PLUGIN_PATH="$PLYMOUTH_PLUGIN_DIR"

# ...and one thing PLYMOUTH_SYSROOT does NOT fix. plymouth-populate-initrd resolves the splash
# plugins' shared libraries with a plain `ldd`, which — unlike dracut's installer — is not
# sysroot-aware: run from the builder, which has no plymouth on it, it cannot resolve
# libply-splash-graphics.so.5 and drops it without a word. script.so links against exactly that
# one library, so plymouthd's dlopen() of the theme's plugin fails and plymouth falls back to
# its grey text splash — every boot, no error, nothing in the journal. The other libply
# libraries survive only incidentally, because plymouthd itself links them and dracut installs
# plymouthd's dependencies correctly. dracut's --install DOES resolve against the sysroot, so
# name them there instead of trusting the helper.
PLYMOUTH_LIBS=()
for l in "$TARGET"/usr/lib64/libply*.so* "$TARGET"/usr/lib/libply*.so*; do
  [[ -e $l ]] && PLYMOUTH_LIBS+=("${l#"$TARGET"}")
done
(( ${#PLYMOUTH_LIBS[@]} )) || die "no libply* libraries in $TARGET — is sys-boot/plymouth installed?"

# The driver omit list. Moved out of a literal argument (it used to read --omit-drivers "nouveau")
# into config/dracut-omit-drivers.txt, which carries the class-by-class reasoning the way
# prune-firmware.txt does — and, more to the point, carries the warning that dracut matches these
# against the module NAME and not the path, so a path-shaped entry is a silent no-op.
# nouveau is still in there, unchanged in effect; it just has company now.
mapfile -t OMIT_DRIVERS < <(read_list_file "$REPO/config/dracut-omit-drivers.txt")
(( ${#OMIT_DRIVERS[@]} )) || die "config/dracut-omit-drivers.txt parsed to nothing"
log "omitting ${#OMIT_DRIVERS[@]} driver patterns from the initrd"

# NVIDIA early KMS. Closes the plan/08 tradeoff "NVIDIA machines get no splash until after the
# root pivot": the initrd had no usable DRM device on NVIDIA at all, so plymouthd waited out
# DeviceTimeout=8 and fell back to text on every NVIDIA machine, every boot, silently.
#
# --add-drivers, deliberately NOT --force-drivers. The force variant also writes a modules-load.d
# entry, which would load nvidia.ko on every AMD and Intel machine too — a pointless probe and
# ~30 MiB of resident driver on hardware it will never bind. Autoloading is left to udev, which
# matches nvidia.ko's PCI aliases; the other two modules have no modalias at all and are pulled
# in behind it by the softdep in usr/lib/modprobe.d/10-nvidia-drm.conf (installed by the overlay
# in section 1, and copied into the initrd by dracut along with the rest of modprobe.d).
#
# COST, measured on 0.2.2 and stated here because it is the one change that makes the UKI bigger:
# nvidia.ko 24.3 + nvidia-modeset 4.5 + nvidia-drm 0.5 MiB, and — the expensive half — nvidia.ko
# declares MODULE_FIRMWARE for gsp_tu10x.bin (28.7) and gsp_ga10x.bin (69.5), so dracut pulls
# 98 MiB of GSP firmware in behind them. +71.5 MiB compressed, nearly all of it the firmware,
# which only compresses to 84%. nvidia-uvm and nvidia-peermem are NOT listed: they are the CUDA
# side, nothing in an initrd touches them, and the verify block below asserts they stayed out.
NVIDIA_DRIVERS="nvidia nvidia_modeset nvidia_drm"

dracut --force --no-hostonly --reproducible \
  --sysroot "$TARGET" --kver "$KVER" \
  --add "systemd etc-overlay systemd-repart plymouth" \
  --install "${PLYMOUTH_LIBS[*]}" \
  --omit "network network-legacy nfs iscsi lvm mdraid multipath dmraid cifs brltty virtfs virtiofs lunmask nvdimm qemu-net resume" \
  --omit-drivers "${OMIT_DRIVERS[*]}" \
  --add-drivers "$NVIDIA_DRIVERS" \
  --compress "zstd -19 -T0" \
  --early-microcode \
  "$INITRD"
# The six --omit additions, all of them dracut modules for a root device this image never has:
# virtfs/virtiofs (VM shared folders as root — the 9p driver goes with them in the omit list),
# lunmask (SAN LUN masking), nvdimm (pmem), qemu-net (no network in the initrd at all) and
# resume (plan/08: zram-only swap, no hibernation, so there is no resume= to honour). "qemu"
# itself stays — stage 70's guest boots virtio-blk.
#
# --compress: dracut's auto-detected default is "zstd -15" (dracut:3253). -19 measured 69.9 ->
# 61.2 MiB on the trimmed tree, for build time and nothing else; dracut's own
# check_kernel_compress_support already guards whether the kernel can read zstd at all, and the
# level does not change that answer.

# take the borrowed dracut tree back out of the image, keeping the module the overlay ships
rm -rf -- "$DRACUT_LIB"
if [[ -d $OVERLAY_MOD_KEEP ]]; then
  ensure_dir "$DRACUT_LIB/modules.d"
  cp -a "$OVERLAY_MOD_KEEP" "$DRACUT_LIB/modules.d/90etc-overlay"
  rm -rf -- "$OVERLAY_MOD_KEEP"
fi
[[ -s $INITRD ]] || die "dracut produced no initrd at $INITRD"

# console order matters: the LAST console= becomes /dev/console for userspace. With
# "console=ttyS0 console=tty0" that was tty0, so everything written to /dev/console — including
# the IMAGE-TEST marker from the self-test unit — went to the graphical console while stage 70
# watched the serial port and timed out. tty0 stays listed so the screen still shows the boot.
#
# Splash flags, and why each is here:
#   splash                          show the graphical theme rather than plymouth's details view
#   plymouth.ignore-serial-consoles LOAD-BEARING. console=ttyS0 above would otherwise make
#                                   plymouthd claim the serial port as a text display and mirror
#                                   forwarded systemd status onto it — straight into the log
#                                   stage 70 scans for "Failed to mount" and friends.
#   loglevel / rd.udev.log_level    keep stray printk from punching through the splash. Safe for
#                                   stage 70: "Kernel panic" is level 0 and always prints, and
#                                   both the IMAGE-TEST marker and systemd's own messages are
#                                   userspace writes to /dev/console, unaffected by printk level.
#   vt.global_cursor_default=0      no blinking text cursor over the splash
#
# The two splash tokens are chosen by SPLASH_BACKEND (build.conf). Note what does NOT change
# with it: plymouth stays merged, its theme stays installed, and the dracut plymouth module
# stays in the --add list above, so the initrd payload and every assertion in the verify block
# below hold in all four modes. Turning plymouth "off" is exactly the one condition its own
# unit ships with — ConditionKernelCommandLine=!plymouth.enable=0 on plymouth-start.service,
# present in both the initrd copy and the rootfs copy — and nothing else. Switching backends
# is therefore a rerun of stages 40-60, not a rebuild.
SPLASH_TOKENS=()
case $SPLASH_BACKEND in
  plymouth|both) SPLASH_TOKENS+=(splash) ;;
  stub|none)     SPLASH_TOKENS+=(plymouth.enable=0) ;;
esac
# Initrd failure policy (DEBUG_INITRD in build.conf). On the default (0) a root filesystem that
# cannot be found or mounted REBOOTS rather than dropping to a dracut emergency shell. That is
# what makes plan/01's automatic rollback actually automatic: systemd-boot decrements an entry's
# tries counter when it BOOTS it, but a machine parked at an emergency prompt never finishes the
# attempt — so a bad slot used to need three manual power cycles before sd-boot gave up on it and
# fell through to the previous UKI. Rebooting spends those three tries by itself, in seconds.
# rd.shell=0 is the half that matters on a machine with no keyboard attached; rd.emergency=reboot
# is the half that matters on one that has.
RECOVERY_TOKENS=()
[[ ${DEBUG_INITRD:-0} == 1 ]] || RECOVERY_TOKENS+=(rd.shell=0 rd.emergency=reboot)

CMDLINE="root=PARTLABEL=$ROOT_PARTLABEL rootfstype=erofs ro nvidia-drm.modeset=1 console=tty0 console=ttyS0 quiet ${SPLASH_TOKENS[*]} plymouth.ignore-serial-consoles loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 ${RECOVERY_TOKENS[*]}"
log "splash backend: $SPLASH_BACKEND; initrd emergency shell: ${DEBUG_INITRD:-0}"

# The stub bitmap is composed from the PNGs install_branding() just rasterised, so it cannot
# drift from the Plymouth theme — one set of sources, one rasterisation, two consumers.
UKIFY_SPLASH=()
if [[ $SPLASH_BACKEND == stub || $SPLASH_BACKEND == both ]]; then
  STUB_BMP="$WORK/splash-$VERSION.bmp"
  require_cmds python3
  python3 "$REPO/config/branding/make-stub-bmp.py" \
    --theme-dir "$THEME_DIR" --output "$STUB_BMP" --scale "$SPLASH_STUB_SCALE" \
    || die "stub splash bitmap generation failed"
  [[ -s $STUB_BMP ]] || die "stub splash bitmap is empty: $STUB_BMP"
  UKIFY_SPLASH+=(--splash="$STUB_BMP")
fi

UKIFY=ukify; [[ -x /usr/lib/systemd/ukify ]] && UKIFY=/usr/lib/systemd/ukify
ensure_dir "$UKI_DIR"
"$UKIFY" build \
  --linux="$KERNEL_IMG" \
  --initrd="$INITRD" \
  --cmdline="$CMDLINE" \
  "${UKIFY_SPLASH[@]}" \
  --os-release="@$TARGET/etc/os-release" \
  --output="$UKI_DIR/$UKI_NAME"

# ---- verify ---------------------------------------------------------------------------
grep -q "IMAGE_VERSION=$VERSION" "$TARGET/etc/os-release" || die "verify: os-release version mismatch"
grep -q "ID=$DISTRO_ID" "$TARGET/etc/os-release"          || die "verify: os-release ID mismatch"
[[ -s $UKI_DIR/$UKI_NAME ]]                               || die "verify: UKI missing/empty"

# Boot splash. Every piece is checked because the splash is invisible to every automated test
# we have: stage 70 reads a serial port, so an image that boots to a black screen passes it.
[[ -f $THEME_DIR/$DISTRO_ID.script ]]   || die "verify: splash theme script missing"
[[ -f $THEME_DIR/$DISTRO_ID.plymouth ]] || die "verify: splash theme manifest missing"
for a in slab-top slab-mid slab-bot wordmark status-left status-right; do
  [[ -s $THEME_DIR/$a.png ]] || die "verify: splash asset $a.png missing or empty"
done
[[ -L $TARGET/usr/share/plymouth/themes/default.plymouth ]] \
  || die "verify: default.plymouth symlink missing — dracut and plymouthd both resolve the theme through it"
[[ -x $TARGET/usr/sbin/plymouthd || -x $TARGET/usr/bin/plymouthd ]] \
  || die "verify: plymouthd missing from target (is sys-boot/plymouth in @base?)"
# ...and it has to be IN THE INITRD, not merely in the target. dracut --sysroot can report
# success while silently installing nothing — that is the trap documented at the lend/borrow
# dance above, and it would show up only as a splash that never appears before the root pivot.
if command -v lsinitrd >/dev/null 2>&1; then
  # Listed ONCE into a variable, deliberately. "lsinitrd ... | grep -q" looks obvious and is
  # wrong here: grep -q exits at the first match, lsinitrd dies of SIGPIPE, and this script's
  # `set -o pipefail` reports the pipeline as failed (141) even though the pattern WAS found.
  # That false negative is what failed the first build with the payload sitting in the initrd.
  INITRD_LIST="$(lsinitrd "$INITRD" 2>/dev/null || true)"
  has() { grep -q -- "$1" <<<"$INITRD_LIST"; }
  has 'plymouthd$' \
    || die "verify: initrd carries no plymouthd — the dracut plymouth module did not install"
  # The theme and the plugin that interprets it come from plymouth-populate-initrd, which is
  # the half that silently reads the wrong filesystem when PLYMOUTH_SYSROOT is unset. Assert
  # them individually: "plymouthd is present" says nothing about whether it can draw.
  has "themes/$DISTRO_ID/$DISTRO_ID.script" \
    || die "verify: initrd has plymouthd but not the $DISTRO_ID theme (PLYMOUTH_SYSROOT wrong?)"
  has 'plymouth/script.so' \
    || die "verify: initrd has the theme but not script.so — nothing would interpret it"
  has 'renderers/drm.so' \
    || die "verify: initrd has no DRM renderer — the splash would fall back to text"
  # Presence is not enough: a plugin whose libraries are missing dlopen()s to nothing and
  # plymouth falls back silently. Check what each one actually links against.
  for so in "$PLYMOUTH_PLUGIN_DIR/script.so" "$PLYMOUTH_PLUGIN_DIR/renderers/drm.so"; do
    while read -r lib; do
      [[ -z $lib ]] && continue
      has "$lib" || die "verify: $so needs $lib, which is not in the initrd — plymouth would dlopen() it, fail, and silently fall back to the text splash"
    done < <(objdump -p "$TARGET$so" 2>/dev/null | awk '/NEEDED/{print $2}')
  done
  for a in slab-top slab-mid slab-bot wordmark status-left status-right; do
    has "themes/$DISTRO_ID/$a.png" || die "verify: initrd theme is missing $a.png"
  done

  # ---- CPU microcode ------------------------------------------------------------------
  # Stage 50 deletes /usr/lib/firmware/{intel,amd}-ucode from the root filesystem, because the
  # early cpio built right here is the only copy anything ever reads. That creates exactly one
  # dangerous ordering: a later `build.sh --from 40` runs dracut against a target the previous
  # run already stripped, and --early-microcode then contributes NOTHING. The image boots
  # perfectly and every Intel and AMD machine silently runs on whatever microcode its firmware
  # loaded. Nothing else in this repo would ever notice, so assert it here.
  has 'kernel/x86/microcode/GenuineIntel.bin' \
    || die "verify: the initrd's early cpio has no Intel microcode. If this build resumed with
  --from 40, the target's intel-ucode tree was already deleted by a previous stage 50 — rebuild
  from stage 30, or restore sys-firmware/intel-microcode into the target first."
  has 'kernel/x86/microcode/AuthenticAMD.bin' \
    || die "verify: the initrd's early cpio has no AMD microcode (same cause as the Intel check
  above — see sys-firmware/intel-microcode / linux-firmware's amd-ucode in the target)."

  # ---- NVIDIA early KMS ---------------------------------------------------------------
  # All three modules AND the GSP firmware, individually. nvidia.ko alone gets a splash on
  # nothing: without nvidia-modeset and nvidia-drm no DRM device is ever registered, and without
  # the GSP blobs nvidia.ko cannot initialise a Turing-or-later GPU at all. Each absence looks
  # identical from outside — plymouth times out and falls back to text — which is precisely the
  # failure this change exists to remove.
  for m in video/nvidia.ko video/nvidia-modeset.ko video/nvidia-drm.ko; do
    has "$m\$" || die "verify: initrd is missing $m — NVIDIA machines would get no splash before
  the root pivot, which is the plan/08 tradeoff --add-drivers was added to close."
  done
  for b in gsp_ga10x.bin gsp_tu10x.bin; do
    has "firmware/nvidia/.*/$b" \
      || die "verify: initrd has the nvidia modules but not $b — nvidia.ko would fail to
  initialise the GPU. dracut pulls this from nvidia.ko's MODULE_FIRMWARE; check that stage 2c's
  prune did not take /usr/lib/firmware/nvidia/<version>/ with it (prune-firmware.txt class 3 is
  scoped to the nouveau codename directories and must never carry a bare 'nvidia' entry)."
  done
  # ...and the CUDA half must have stayed out. --add-drivers pulls dependencies, not siblings, so
  # this holds today; it is asserted because "add the nvidia drivers" is exactly the line a future
  # edit would widen to a glob, and nvidia-uvm is 5.1 MiB of initrd for a compute API no initrd
  # has ever called.
  if has 'nvidia-uvm\.ko'; then
    die "verify: initrd contains nvidia-uvm.ko — that is the CUDA driver, useless before
  switch-root. Only nvidia, nvidia-modeset and nvidia-drm belong in NVIDIA_DRIVERS."
  fi
  # The softdep that makes the other two load at all. nvidia.ko is autoloaded by udev from its
  # PCI alias; nvidia-modeset and nvidia-drm have no modalias and would sit there unloaded.
  has 'modprobe.d/10-nvidia-drm.conf' \
    || die "verify: initrd has the nvidia modules but not usr/lib/modprobe.d/10-nvidia-drm.conf —
  udev autoloads nvidia.ko and nothing would ever load nvidia-modeset/nvidia-drm behind it."

  # ---- the filesystems this initrd actually mounts -------------------------------------
  # erofs for the root and overlay for the /etc overlay module. ext4 (/var, x-initrd.mount) is
  # BUILT IN to this kernel and is correctly absent from the module list — do not "fix" that by
  # adding an ext4.ko check here. These two are asserted because the omit list below is the kind
  # of thing that grows a too-greedy regex, and a missing erofs.ko is an unbootable image.
  has 'fs/erofs/erofs\.ko' \
    || die "verify: initrd has no erofs.ko — root=PARTLABEL=... rootfstype=erofs cannot mount"
  has 'fs/overlayfs/overlay\.ko' \
    || die "verify: initrd has no overlay.ko — the etc-overlay dracut module cannot mount /etc"

  # ---- the omit list actually took ------------------------------------------------------
  # This is the check that turns a mistyped entry in config/dracut-omit-drivers.txt into a failed
  # build instead of a UKI that quietly did not shrink. dracut matches these against the module
  # NAME with "-" normalised to "_" and the pattern anchored at both ends, so reproduce exactly
  # that here rather than grepping for the raw strings.
  mapfile -t INITRD_MODS < <(grep -oE '[^/]+\.ko(\.[a-z0-9]+)?$' <<<"$INITRD_LIST" \
    | sed -E 's/\.ko(\.[a-z0-9]+)?$//; s/-/_/g' | sort -u)
  if (( ${#INITRD_MODS[@]} == 0 )); then
    warn "verify: no kernel modules found in the initrd listing — omit-list check skipped"
  else
    _omit_alt="$(printf '%s|' "${OMIT_DRIVERS[@]//-/_}")"
    leaked="$(printf '%s\n' "${INITRD_MODS[@]}" | grep -E "^(${_omit_alt%|})\$" || true)"
    if [[ -n $leaked ]]; then
      die "verify: config/dracut-omit-drivers.txt names these, but they are in the initrd anyway:
  $(tr '\n' ' ' <<<"$leaked")
  dracut matches --omit-drivers against the MODULE NAME, not the path — a path-shaped entry is a
  silent no-op (see the header of that file)."
    fi
    log "initrd: ${#INITRD_MODS[@]} modules, none matching the ${#OMIT_DRIVERS[@]} omit patterns"
  fi
else
  warn "lsinitrd not available — initrd splash contents unverified"
fi

# The stub splash is a PE section, so it is invisible to every check above. ukify exits 0 for
# an unreadable --splash argument in some versions, and the stub itself simply skips a section
# it cannot parse — either way the failure mode is a black screen with nothing logged.
#
# Sectioned into a variable first, and the comparison written as a full `if` rather than a
# trailing `&&`: `objdump | grep -q` hits the same SIGPIPE/pipefail false negative documented
# at the lsinitrd check above, and a bare `[[ ... ]] && die` as the last statement of an if
# body makes `set -e` abort the stage when the condition is false.
UKI_SECTIONS="$(objdump -h "$UKI_DIR/$UKI_NAME" 2>/dev/null || true)"
if [[ $SPLASH_BACKEND == stub || $SPLASH_BACKEND == both ]]; then
  if ! grep -q '\.splash' <<<"$UKI_SECTIONS"; then
    die "verify: SPLASH_BACKEND=$SPLASH_BACKEND but the UKI has no .splash section"
  fi
else
  # The converse: a leftover .splash in a plymouth-only build would paint an image the kernel
  # then blanks, which reads as a flicker no one ordered.
  if grep -q '\.splash' <<<"$UKI_SECTIONS"; then
    die "verify: SPLASH_BACKEND=$SPLASH_BACKEND but the UKI carries a .splash section"
  fi
fi
[[ -f $TARGET/usr/lib/sysupdate.d/50-rootfs.transfer ]]   || die "verify: sysupdate transfer missing"
[[ -L $TARGET/home ]]                                     || die "verify: /home symlink missing"

# The desktop session hand-off. Each of these is a failure that would otherwise surface only as
# a black screen or a console login on a machine that is supposed to autologin — stage 70 reads
# a serial port and would report green for all three.
if [[ ${CONSOLE_ONLY:-0} != 1 ]]; then
  # /etc/plasmalogin.conf.d/10-autologin.conf says Session=plasma. That names a file, and the
  # file comes from kde-plasma/plasma-login-sessions[wayland] — not from the display manager
  # and not from plasma-workspace. Without it the greeter has nothing to log in TO.
  [[ -f $TARGET/usr/share/wayland-sessions/plasma.desktop ]] \
    || die "verify: /etc/plasmalogin.conf.d names Session=plasma but no plasma.desktop wayland session exists — is kde-plasma/plasma-login-sessions[wayland] installed?"
  # plasmalogin.service's [Install] is Alias=display-manager.service, so this symlink IS the
  # enablement. preset-all reports errors only as a warning above (they are usually benign),
  # which is exactly why the outcome is asserted rather than the exit status trusted.
  compgen -G "$TARGET/etc/systemd/system/display-manager.service" >/dev/null \
    || die "verify: plasmalogin.service not enabled (preset did not take — no display-manager.service alias)"
  # The splash-to-greeter hand-off, both halves. The drop-in's empty "ExecStart=" is what stops
  # systemd running the vendor's plain `plymouth quit` first and resetting the console anyway, so
  # it is asserted rather than assumed — an editor tidying away a line that looks like a typo
  # would put the black frame back with nothing to show for it.
  [[ -f $RETAIN_DROPIN ]] \
    || die "verify: plymouth-quit.service.d/10-retain-splash.conf missing from a desktop image —
  the greeter would paint over a blanked screen (plan/08 open question 6)"
  grep -qE '^ExecStart=$' "$RETAIN_DROPIN" \
    || die "verify: 10-retain-splash.conf has no empty ExecStart= reset — ExecStart is additive in
  a Type=oneshot unit, so the vendor's plain 'plymouth quit' would still run first"
  # KWallet auto-unlock. Gentoo's PLM ebuild ships PAM stacks that already carry
  #   -auth    optional pam_kwallet5.so
  #   -session optional pam_kwallet5.so auto_start
  # and the leading "-" makes each line a no-op when the module is absent — so a missing
  # kde-plasma/kwallet-pam degrades to "prompt for the wallet password" rather than failing to
  # log in. A warning, not a die, for that reason.
  compgen -G "$TARGET/usr/lib64/security/pam_kwallet"*.so >/dev/null \
    || compgen -G "$TARGET/usr/lib/security/pam_kwallet"*.so >/dev/null \
    || warn "verify: no pam_kwallet module — KWallet will prompt instead of auto-unlocking"
fi

# DNS wiring: every piece of it, because each half is useless alone — nsswitch pointing at a
# resolver that is not enabled fails closed, and an enabled resolver nothing consults is dead
# weight that still holds port 53.
RESOLV_STUB=../run/systemd/resolve/stub-resolv.conf
[[ -L $TARGET/etc/resolv.conf && $(readlink "$TARGET/etc/resolv.conf") == "$RESOLV_STUB" ]] \
  || die "verify: /etc/resolv.conf is not the symlink to $RESOLV_STUB"
grep -qE '^hosts:[[:space:]]+resolve[[:space:]]' "$TARGET/etc/nsswitch.conf" \
  || die "verify: nsswitch.conf hosts line does not start with the resolve module"
compgen -G "$TARGET/etc/systemd/system/*.target.wants/systemd-resolved.service" >/dev/null \
  || die "verify: systemd-resolved.service not enabled (preset did not take)"
# The NSS modules named in nsswitch.conf are glibc dlopen() targets: a missing one is not an
# error at build time and only shows up as silently degraded lookups on a booted machine.
for m in resolve systemd myhostname; do
  compgen -G "$TARGET/usr/lib64/libnss_$m.so"* >/dev/null \
    || compgen -G "$TARGET/usr/lib/libnss_$m.so"* >/dev/null \
    || die "verify: /etc/nsswitch.conf uses the $m module but libnss_$m is not installed"
done
log "configure complete; UKI at $UKI_DIR/$UKI_NAME"
# The three hardware lists are stage-40 inputs now, not just stage-50 ones: section 2c prunes
# firmware and microcode before dracut, and the omit list decides what goes into the initrd. A
# stamp that did not cover them would let an edit to any of the three be skipped on a resume.
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" \
  "$REPO/config/prune-firmware.txt" "$REPO/config/prune-microcode.txt" \
  "$REPO/config/dracut-omit-drivers.txt")"
