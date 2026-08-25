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

# ---- 3. initrd + UKI (built HERE, in the builder — the target has no dracut) --------
KVER="$(basename -- "$(find "$TARGET/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)")"
[[ -n $KVER ]] || die "cannot determine kernel version from target modules"
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
dracut --force --no-hostonly --reproducible \
  --sysroot "$TARGET" --kver "$KVER" \
  --add "systemd etc-overlay systemd-repart plymouth" \
  --install "${PLYMOUTH_LIBS[*]}" \
  --omit "network network-legacy nfs iscsi lvm mdraid multipath dmraid cifs brltty" \
  --early-microcode \
  "$INITRD"

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
CMDLINE="root=PARTLABEL=$ROOT_PARTLABEL rootfstype=erofs ro nvidia-drm.modeset=1 console=tty0 console=ttyS0 quiet ${SPLASH_TOKENS[*]} plymouth.ignore-serial-consoles loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0"
log "splash backend: $SPLASH_BACKEND"

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
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
