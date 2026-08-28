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
export UPDATE_CHANNEL SPLASH_STATUS_LEFT DISTROBOX_DEFAULT_IMAGE
install_rootfs_overlay "$REPO/config/rootfs" "$TARGET"

# The overlay ships /etc/distrobox unconditionally (install_rootfs_overlay walks the whole
# tree); an image built without the container stack must not carry a config file for a binary
# it does not have.
if [[ ${INCLUDE_DISTROBOX:-1} != 1 ]]; then
  rm -rf -- "${TARGET:?}/etc/distrobox"
fi

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
#
# Groups, and why these three: wheel is sudo/polkit (see /etc/sudoers.d/wheel and
# 49-wheel.rules), video is DRM/KMS access. "pipewire" is the realtime path — PipeWire ships
# /etc/security/limits.d/25-pw-rlimits.conf granting rtprio 95 / nice -19 to @pipewire and
# nothing else, and this image has no rtkit-daemon to fall back to, so a user outside the
# group gets a sound server with no RT scheduling at all (xruns under load).
#
# "audio" is deliberately NOT here, on media-video/pipewire's own pkg_postinst advice: device
# access comes from logind/uaccess ACLs on the active session, not from the group, and static
# audio-group membership is what breaks device hand-off on fast user switching.
#
# The group comes from acct-group/pipewire, pulled in by @desktop — a --console-only image has
# neither, and useradd fails outright on a group that does not exist rather than skipping it.
LIVE_USER_GROUPS="wheel,video"
if chroot_target "$TARGET" "getent group pipewire" >/dev/null 2>&1; then
  LIVE_USER_GROUPS="$LIVE_USER_GROUPS,pipewire"
else
  [[ ${CONSOLE_ONLY:-0} == 1 ]] \
    || die "no 'pipewire' group in a desktop image — acct-group/pipewire is missing, so the
  RT limits in /etc/security/limits.d/25-pw-rlimits.conf could never apply to anyone"
fi
if ! chroot_target "$TARGET" "id -u '$LIVE_USER'" >/dev/null 2>&1; then
  chroot_target "$TARGET" "useradd -m -G '$LIVE_USER_GROUPS' -s /bin/bash '$LIVE_USER'"
  chroot_target "$TARGET" "echo '$LIVE_USER:$LIVE_USER_PASSWORD' | chpasswd"
else
  # The target persists in the work volume between runs, so on a resumed build (`--from 40`,
  # which the README documents for recovering from a failure) useradd above never runs and any
  # change to the group list would silently never apply. Reconcile it instead of trusting
  # whatever a previous run set — `-G` REPLACES the supplementary list, which is the point:
  # dropping "audio" has to actually drop it. The useradd above is the only thing in the build
  # that touches this user's groups (the subuid/subgid usermod below does not), so there is no
  # other membership to preserve.
  chroot_target "$TARGET" "usermod -G '$LIVE_USER_GROUPS' '$LIVE_USER'" \
    || die "could not reconcile supplementary groups for $LIVE_USER"
fi

# Subordinate UID/GID ranges — what makes podman ROOTLESS (plan/13). Without them
# newuidmap/newgidmap have nothing to map and every `podman`/`distrobox` invocation fails with
# "cannot find UID/GID for user", at first use, long after this build.
#
# useradd above has PROBABLY already done this: the target's /etc/login.defs ships active
# SUB_UID_MIN/SUB_UID_COUNT lines, and sys-apps/shadow's pkg_postinst touches /etc/subuid and
# /etc/subgid, which is the condition shadow allocates on. "Probably" is not a guarantee that
# survives a shadow bump or a login.defs change, so the range is claimed explicitly when it is
# missing, and asserted outright in stage 50.
if [[ ${INCLUDE_DISTROBOX:-1} == 1 ]]; then
  if ! chroot_target "$TARGET" "grep -q '^$LIVE_USER:' /etc/subuid" 2>/dev/null; then
    log "allocating subuid range for $LIVE_USER (useradd did not)"
    chroot_target "$TARGET" "usermod --add-subuids 100000-165535 '$LIVE_USER'" \
      || die "could not allocate subuids for $LIVE_USER — rootless podman would not work"
  fi
  if ! chroot_target "$TARGET" "grep -q '^$LIVE_USER:' /etc/subgid" 2>/dev/null; then
    log "allocating subgid range for $LIVE_USER (useradd did not)"
    chroot_target "$TARGET" "usermod --add-subgids 100000-165535 '$LIVE_USER'" \
      || die "could not allocate subgids for $LIVE_USER — rootless podman would not work"
  fi
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

# ---- the sound server -------------------------------------------------------------------
# preset-all above is SYSTEM units only. PipeWire is a per-user service and ships nothing that
# enables itself, which is how 0.3.0 booted with no sound server at all and KDE's volume applet
# showed "Connection to the sound service lost" on every login.
#
# There is no autostart fallback to rely on: media-video/pipewire wraps /etc/xdg/autostart/
# pipewire.desktop and /usr/bin/gentoo-pipewire-launcher in `if ! use systemd`, and this image
# is a systemd profile — so neither is installed and the user units are the ONLY start path.
# /etc/pulse/client.conf ships `autospawn = no`, so libpulse cannot paper over it either: the
# pulse client just fails to connect, which is the message the applet is reporting verbatim.
#
# Targeted `--global enable`, NOT `--global preset-all`. Gentoo ships no catch-all user preset,
# so systemd's compiled-in default policy is "enable" and preset-all pulls in every user unit
# in the image that has an [Install] section — measured on this rootfs: podman.socket,
# podman.service, podman-auto-update.timer, speech-dispatcher.socket, the gpg-agent sockets,
# mpris-proxy, machines.target. The podman ones directly contradict the vendor preset's
# rootless-only rule (see 50-@DISTRO_ID@.preset), and stage 50's guard only scans
# /etc/systemd/system, so nothing downstream would have caught it.
#
# Sockets, not services: pipewire-pulse.socket is what the applet connects to, and
# pipewire-pulse.service then pulls in pipewire.service (BindsTo) and wireplumber via
# pipewire-session-manager.service (Wants). Enabling wireplumber.service is what writes both
# that alias and pipewire.service.wants/wireplumber.service. This is the same set Fedora and
# Arch ship, and it means a session that never touches audio never starts the daemons.
PW_USER_UNITS=(pipewire.socket pipewire-pulse.socket wireplumber.service)
if [[ -f $TARGET/usr/lib/systemd/user/pipewire-pulse.socket ]]; then
  log "enabling sound server user units: ${PW_USER_UNITS[*]}"
  chroot_target "$TARGET" "systemctl --global enable ${PW_USER_UNITS[*]}" \
    || die "could not enable the PipeWire user units — the image would boot without sound"
elif [[ ${CONSOLE_ONLY:-0} != 1 ]]; then
  die "no pipewire-pulse.socket in a desktop image — is media-video/pipewire[sound-server] installed?"
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
  # An offline build has no Flathub. The archive carries an OSTree repo holding exactly the
  # locked commits (stage 90), and --sideload-repo is how flatpak is told to read objects from
  # it instead of the network. The remote still has to be configured — it is, above — because
  # that is where the signing key and the ref metadata come from; sideloading replaces the
  # transport, not the trust.
  FP_SIDELOAD=()
  if [[ -d ${VENDOR_DIR:-}/flatpak ]]; then
    FP_SIDELOAD=(--sideload-repo=/vendor/flatpak)
    log "flatpak: sideloading from ${VENDOR_DIR}/flatpak"
  elif [[ ${OFFLINE:-0} == 1 ]]; then
    die "offline build, but the archive has no flatpak/ repo — stage 40 cannot install apps"
  fi

  for app in $FLATPAK_PREINSTALL; do
    log "preinstalling flatpak: $app"
    chroot_target "$TARGET" "flatpak install -y --system --noninteractive ${FP_SIDELOAD[*]-} flathub '$app'"
  done

  # ---- pin every ref to its locked commit (plan/15 layer 5) --------------------------
  # The install above takes whatever Flathub serves today, which is what made two builds of
  # the same release ship different Firefoxes. Deploying the locked commit afterwards is the
  # supported way to land on an exact version — there is no "install this commit" verb.
  #
  # Runtimes are in the lock too, and they arrive as dependencies rather than being named in
  # FLATPAK_PREINSTALL, so this loop is what pins most of the shipped bytes.
  APPS_LOCK="$REPO/config/flatpak/apps.lock"
  if [[ -f $APPS_LOCK ]]; then
    while read -r ref commit; do
      [[ -n $ref && $ref != \#* ]] || continue
      chroot_target "$TARGET" \
        "flatpak update -y --system --noninteractive ${FP_SIDELOAD[*]-} --commit='$commit' '$ref'" \
        || die "could not deploy $ref at $commit.
  Flathub garbage-collects old commits, so a pin that has aged out is the expected cause.
  Re-resolve the flatpak lock:  scripts/relock.sh --flatpak
  (or rebuild from the vendored archive, which still has the objects)"
    done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')

    # Read it back. `flatpak update --commit=` on an already-current ref exits 0 and says
    # "Nothing to do", which is indistinguishable from success — so ask what is actually
    # deployed rather than trusting that the loop above did anything.
    FP_ACTIVE="$(chroot_target "$TARGET" \
      "flatpak list --system --columns=ref,active" 2>/dev/null | tr -d '\r')"
    fp_bad=0
    while read -r ref commit; do
      [[ -n $ref && $ref != \#* ]] || continue
      got="$(printf '%s\n' "$FP_ACTIVE" | awk -v r="$ref" '$1 == r {print $2}')"
      # `flatpak list` abbreviates the commit; compare on the prefix it prints.
      [[ -n $got && $commit == "$got"* ]] || {
        warn "flatpak $ref is at '${got:-<not installed>}', lock says ${commit:0:12}"
        fp_bad=1
      }
    done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')
    (( fp_bad == 0 )) || die "the deployed flatpak commits do not match config/flatpak/apps.lock
  (see the warnings above). The image would ship different application versions than the lock
  claims, which is the whole failure this lock exists to prevent."
    log "flatpak: $(grep -vc '^[[:space:]]*#' "$APPS_LOCK") refs deployed at their locked commits"
  else
    warn "no config/flatpak/apps.lock — preinstalled Flatpaks are UNPINNED (plan/15 layer 5)"
  fi

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
# Two artefacts, one set of sources, and neither of them is a theme in the image.
#
#   $WORK/branding/*.png      rasterised from config/branding/*.svg — BUILD INPUTS ONLY
#   $TARGET/usr/share/$ID/splash.bin   the KMS splash's tile container (ships)
#   $WORK/splash-$VERSION.bmp          the UKI's .splash section, built in section 3 (ships
#                                      inside the UKI, not on the root filesystem)
#
# Nothing about this has to run before dracut any more, which is the point: the initrd carries
# no splash at all now. It stays here because the .splash bitmap is a ukify input and ukify runs
# in section 3.
BRANDING_PNG="$WORK/branding"
rm -rf -- "$BRANDING_PNG"
render_branding "$REPO/config/branding" "$BRANDING_PNG"

SPLASH_SHARE="$TARGET/usr/share/$DISTRO_ID"
SPLASH_ASSETS="$SPLASH_SHARE/splash.bin"
ensure_dir "$SPLASH_SHARE"
python3 "$REPO/config/branding/make-splash-assets.py" \
  --asset-dir "$BRANDING_PNG" --sprites "$SPLASH_ASSETS" \
  || die "splash sprite generation failed"
[[ -s $SPLASH_ASSETS ]] || die "splash sprite container is empty: $SPLASH_ASSETS"
chmod 0644 -- "$SPLASH_ASSETS"

# The splash program. Compiled HERE, by the builder's gcc, and linked -static.
#
# It cannot be built in the target: stage 30 emerges with ROOT=$TARGET and never chroots, so
# there is no way to invoke the image's own toolchain, and stage 50 deletes the compiler
# anyway (plan/06's toolchain-free guarantee). -static removes the question entirely — the
# binary has no ABI relationship with the image's libraries, which is also what makes it
# immune to the library pruning stage 50 does after this.
#
# -ffile-prefix-map keeps the builder's absolute source path out of the binary, so two builds
# of the same commit produce the same bytes (the erofs is meant to be reproducible; see
# plan/08 roadmap 6).
SPLASH_BIN="$TARGET/usr/bin/$DISTRO_ID-splash"
gcc -std=c11 -O2 -static -Wall -Wextra -Werror \
    -ffile-prefix-map="$REPO"=. \
    -DSPLASH_ASSET_PATH="\"/usr/share/$DISTRO_ID/splash.bin\"" \
    -o "$SPLASH_BIN" "$REPO/config/splash/splash.c" \
  || die "boot splash did not compile"
strip "$SPLASH_BIN" || true
chmod 0755 -- "$SPLASH_BIN"
log "boot splash: $(basename -- "$SPLASH_BIN") $(stat -c%s "$SPLASH_BIN") bytes, assets $(stat -c%s "$SPLASH_ASSETS") bytes"

# The KMS splash is a DESKTOP-only thing, for the same reason the old retain-splash drop-in was.
# On --console-only the next thing to touch the screen is agetty — and because this program
# holds a framebuffer on the CRTC, fbcon would render the login prompt into a buffer nobody is
# scanning out. The result is not "text behind a logo", it is an invisible console. So the unit
# and its udev rule come back out of that image entirely.
SPLASH_UNIT="$TARGET/usr/lib/systemd/system/$DISTRO_ID-splash.service"
SPLASH_RULE="$TARGET/usr/lib/udev/rules.d/70-$DISTRO_ID-splash.rules"
if [[ ${CONSOLE_ONLY:-0} == 1 ]]; then
  log "console-only image: removing the KMS splash unit and udev rule (agetty owns the screen)"
  rm -f -- "$SPLASH_UNIT" "$SPLASH_RULE"
else
  [[ -f $SPLASH_UNIT ]] \
    || die "verify: $SPLASH_UNIT missing — the overlay in config/rootfs did not install it"
  [[ -f $SPLASH_RULE ]] \
    || die "verify: $SPLASH_RULE missing — nothing would ever start the splash"
  # The unit's ConditionKernelCommandLine and the token section 3 puts on the cmdline are two
  # independently rendered strings that have to be the same one. If they drift, SPLASH_BACKEND
  # stops working in the direction that fails silently: the splash draws in every mode,
  # including the ones that asked for no splash at all.
  grep -qx "ConditionKernelCommandLine=!$DISTRO_ID.splash=0" "$SPLASH_UNIT" \
    || die "verify: $SPLASH_UNIT does not carry ConditionKernelCommandLine=!$DISTRO_ID.splash=0
  — SPLASH_BACKEND=stub and =none would not actually disable the splash."
  grep -q "$DISTRO_ID-splash.service" "$SPLASH_RULE" \
    || die "verify: 70-$DISTRO_ID-splash.rules does not name $DISTRO_ID-splash.service"
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

# our dracut modules must be visible to the *builder's* dracut. Discovered from the overlay
# source rather than listed here, so adding a module is one directory and nothing else.
mapfile -t DRACUT_MODS < <(
  cd "$REPO/config/rootfs/usr/lib/dracut/modules.d" && printf '%s\n' */
)
DRACUT_MODS=("${DRACUT_MODS[@]%/}")
(( ${#DRACUT_MODS[@]} )) \
  || die "no dracut modules under config/rootfs/usr/lib/dracut/modules.d"
for _m in "${DRACUT_MODS[@]}"; do
  [[ -d $TARGET/usr/lib/dracut/modules.d/$_m ]] \
    || die "dracut module $_m is in config/rootfs but not in the target — overlay not applied?"
  rm -rf -- "/usr/lib/dracut/modules.d/$_m"
  cp -r "$TARGET/usr/lib/dracut/modules.d/$_m" /usr/lib/dracut/modules.d/
done
log "custom dracut modules: ${DRACUT_MODS[*]}"

# dracut is a builder tool and is deliberately not part of the image's package set, but
# --sysroot resolves BOTH dracutbasedir and every module file dracut-install copies relative
# to the sysroot. Without a copy inside the target it dies on
# "/work/target/usr/lib/dracut/dracut-functions.sh: No such file or directory"; with only
# dracutbasedir overridden it "succeeds" while silently failing to install initqueue,
# loginit, rdsosreport, shutdown and dracut-util into the initramfs. So: lend the target a
# full copy for the duration of the run, then take it away again.
DRACUT_LIB="$TARGET/usr/lib/dracut"
MODS_KEEP="$WORK/dracut-modules.keep"
rm -rf -- "$MODS_KEEP"; ensure_dir "$MODS_KEEP"
for _m in "${DRACUT_MODS[@]}"; do
  [[ -d $DRACUT_LIB/modules.d/$_m ]] && cp -a "$DRACUT_LIB/modules.d/$_m" "$MODS_KEEP/$_m"
done
ensure_dir "$DRACUT_LIB"
cp -a /usr/lib/dracut/. "$DRACUT_LIB/"

INITRD="$WORK/initrd-$VERSION.img"

# The driver omit list. Moved out of a literal argument (it used to read --omit-drivers "nouveau")
# into config/dracut-omit-drivers.txt, which carries the class-by-class reasoning the way
# prune-firmware.txt does — and, more to the point, carries the warning that dracut matches these
# against the module NAME and not the path, so a path-shaped entry is a silent no-op.
# nouveau is still in there, unchanged in effect; it just has company now.
mapfile -t OMIT_DRIVERS < <(read_list_file "$REPO/config/dracut-omit-drivers.txt")
(( ${#OMIT_DRIVERS[@]} )) || die "config/dracut-omit-drivers.txt parsed to nothing"
log "omitting ${#OMIT_DRIVERS[@]} driver patterns from the initrd"

# The initrd has NO GRAPHICS IN IT, and "drm" in the --omit list is what enforces that.
#
# This is the change plan/14 exists for. dracut's 45plymouth module depends on its drm module,
# so as long as a splash lived in the initrd the initrd also carried the DRM driver tree and —
# because dracut follows MODULE_FIRMWARE — every firmware blob those drivers declare. plan/11
# finding 4 then added nvidia/nvidia-modeset/nvidia-drm on top, dragging 98 MiB of GSP firmware
# with them, purely so plymouthd would find a DRM device before the root pivot. That was
# +71.5 MiB of UKI, on an ESP that holds two of them.
#
# None of it was ever needed to BOOT. The initrd mounts exactly two filesystems, the erofs root
# and the ext4 /var, both on a local GPT disk. The splash it was carrying all that weight for is
# now drawn after switch-root by $DISTRO_ID-splash, out of the root filesystem, where a GPU
# driver costs nothing extra because the image ships it anyway.
#
# BOTH "drm" and "plymouth" are OMITTED rather than merely not added, and plymouth's entry is
# not defensive — it is required. dracut assembles a default module set from every module whose
# check() passes, and 45plymouth's passes on the mere presence of plymouth-populate-initrd and
# the two binaries in the sysroot (45plymouth/module-setup.sh:38). So dropping it from --add
# achieves nothing at all while sys-boot/plymouth is installed: dracut picks it up by itself,
# it declares depends() on drm, and the run then dies with
#
#     dracut[E]: Module 'plymouth' depends on module 'drm', which can't be installed
#
# which is exactly what happened the first time this was built. Once the package is gone
# check() fails and the module is skipped, so the entry becomes belt-and-braces — worth keeping
# for the day something reintroduces plymouth as somebody else's dependency.
#
# "drm" earns its omission the same way: it is a module OTHER modules can pull in, so leaving it
# to chance is how the GPU tree comes back silently. The verify block below asserts no
# drivers/gpu module and no nvidia*.ko survived into the initrd, which turns a future regression
# into a failed build instead of a UKI that quietly regrew.
#
# The cmdline keeps nvidia-drm.modeset=1 and the image keeps usr/lib/modprobe.d/10-nvidia-drm.conf:
# those are about the BOOTED system now — nvidia-modeset and nvidia-drm have no modalias, so
# without the softdep nothing loads them, and then neither the splash nor kwin gets a DRM device.

dracut --force --no-hostonly --reproducible \
  --sysroot "$TARGET" --kver "$KVER" \
  --add "systemd etc-overlay systemd-repart repart-sysroot" \
  --omit "drm simpledrm plymouth network network-legacy nfs iscsi lvm mdraid multipath dmraid cifs brltty virtfs virtiofs lunmask nvdimm qemu-net resume" \
  --omit-drivers "${OMIT_DRIVERS[*]}" \
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

# take the borrowed dracut tree back out of the image, keeping the modules the overlay ships
rm -rf -- "$DRACUT_LIB"
for _m in "${DRACUT_MODS[@]}"; do
  [[ -d $MODS_KEEP/$_m ]] || continue
  ensure_dir "$DRACUT_LIB/modules.d"
  cp -a "$MODS_KEEP/$_m" "$DRACUT_LIB/modules.d/$_m"
done
rm -rf -- "$MODS_KEEP"
[[ -s $INITRD ]] || die "dracut produced no initrd at $INITRD"

# console order matters: the LAST console= becomes /dev/console for userspace. With
# "console=ttyS0 console=tty0" that was tty0, so everything written to /dev/console — including
# the IMAGE-TEST marker from the self-test unit — went to the graphical console while stage 70
# watched the serial port and timed out. tty0 stays listed so the screen still shows the boot.
#
# Splash flags, and why each is here:
#   loglevel / rd.udev.log_level    keep stray printk from punching through the splash. Safe for
#                                   stage 70: "Kernel panic" is level 0 and always prints, and
#                                   both the IMAGE-TEST marker and systemd's own messages are
#                                   userspace writes to /dev/console, unaffected by printk level.
#   quiet                           the other half of that. With CONFIG_FRAMEBUFFER_CONSOLE_
#                                   DEFERRED_TAKEOVER=y, no console output means fbcon never
#                                   takes the framebuffer, which is what lets the systemd-stub
#                                   bitmap survive all the way through the initrd now that the
#                                   initrd loads no DRM driver to modeset over it.
#   vt.global_cursor_default=0      no blinking text cursor over the splash
#
# Two tokens that used to be here are gone with plymouth (plan/14): "splash", which only ever
# meant "plymouth graphical mode", and "plymouth.ignore-serial-consoles", which existed because
# plymouthd would otherwise claim ttyS0 as a text display and mirror systemd status into the log
# stage 70 scans. $DISTRO_ID-splash never opens a serial port.
#
# SPLASH_BACKEND (build.conf) selects between the two halves of the splash by adding at most one
# token, and NOTHING ELSE about the image changes with it — the splash binary, its assets, its
# unit and its udev rule are installed in all four modes. "$DISTRO_ID.splash=0" is the single
# condition the unit itself carries, so switching backends stays a rerun of stages 40-60 rather
# than a rebuild:
#
#   both  stub bitmap, then the KMS splash at the first modeset   (.splash section, no token)
#   stub  the stub bitmap alone; black from the modeset onward     (.splash section, token)
#   kms   no pre-kernel image; splash from the first modeset       (no section, no token)
#   none  neither — the control when comparing the other three     (no section, token)
SPLASH_TOKENS=()
case $SPLASH_BACKEND in
  stub|none) SPLASH_TOKENS+=("$DISTRO_ID.splash=0") ;;
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

CMDLINE="root=PARTLABEL=$ROOT_PARTLABEL rootfstype=erofs ro nvidia-drm.modeset=1 console=tty0 console=ttyS0 quiet ${SPLASH_TOKENS[*]} loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 ${RECOVERY_TOKENS[*]}"
log "splash backend: $SPLASH_BACKEND; initrd emergency shell: ${DEBUG_INITRD:-0}"

# The stub bitmap comes out of the same script and the same PNGs as the KMS splash's sprites in
# section 2b, so the two halves of the splash cannot drift — one set of sources, one layout
# function, two outputs. That matters more here than it did with plymouth: the stub image and
# the KMS frame are now the same still picture at the same brightness, and they meet on screen
# at the first modeset, where any disagreement reads as a jump.
UKIFY_SPLASH=()
if [[ $SPLASH_BACKEND == stub || $SPLASH_BACKEND == both ]]; then
  STUB_BMP="$WORK/splash-$VERSION.bmp"
  require_cmds python3
  python3 "$REPO/config/branding/make-splash-assets.py" \
    --asset-dir "$BRANDING_PNG" --bmp "$STUB_BMP" --scale "$SPLASH_STUB_SCALE" \
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
#
# The binary must be STATICALLY linked, and this is the assertion that matters most in the whole
# block. A dynamic build works perfectly here and in every check below, then stops working after
# stage 50's toolchain split and library sweep — a failure that appears one stage later, in a
# different image, as a splash that silently never draws.
# Asked as "does it have a PT_INTERP segment?" rather than by grepping file(1) for the words
# "statically linked": PT_INTERP is the thing that actually makes the kernel go looking for a
# dynamic loader, so its absence IS the property being asserted, and the answer does not depend
# on which magic database the builder happens to ship.
if readelf -l "$SPLASH_BIN" 2>/dev/null | grep -q 'INTERP'; then
  die "verify: $SPLASH_BIN is dynamically linked (it has a PT_INTERP segment). The image has no
  compiler and stage 50 prunes libraries out from under it; a dynamic splash binary would fail
  to exec at boot with nothing on screen and nothing in the journal."
fi
[[ -x $SPLASH_BIN ]] || die "verify: $SPLASH_BIN is not executable"

# The asset container, parsed the way config/splash/splash.c parses it. Checking that the file
# merely exists says nothing: a truncated or misgenerated container is a splash that loads
# nothing and exits 0, i.e. a black screen with no error anywhere.
python3 - "$SPLASH_ASSETS" <<'PYEOF' || die "verify: splash asset container is malformed"
import struct, sys
blob = open(sys.argv[1], "rb").read()
assert blob[:8] == b"IMSPLSH1", "bad magic"
bg, n = struct.unpack_from("<II", blob, 8)
assert 0 < n <= 16, f"implausible tile count {n}"
assert bg == 0x0A0D11, f"background {bg:#08x} is not the brand #0a0d11"
scales = set()
for i in range(n):
    scale, anchor, w, h, ox, oy, off = struct.unpack_from("<7I", blob, 16 + i * 28)
    assert 0 < w <= 16384 and 0 < h <= 16384, f"tile {i} has implausible extent {w}x{h}"
    assert anchor in (0, 1, 2), f"tile {i} has unknown anchor {anchor}"
    assert off + w * h * 4 <= len(blob), f"tile {i} pixels run past the end of the file"
    scales.add(scale)
assert scales == {1, 2}, f"expected sprite scales 1 and 2, got {sorted(scales)}"
PYEOF
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
  # ---- no graphics in the initrd ------------------------------------------------------
  # The assertion plan/14 turns on. dracut's "drm" module is in the --omit list above, but it is
  # a module OTHER modules can depend on, so the way it comes back is silently — someone adds a
  # dracut module in a year's time, the initrd regrows the DRM tree and the firmware behind it,
  # and the only symptom is a UKI that got 70 MiB bigger for no reason anybody notices.
  #
  # There is nothing to trade off here. The initrd mounts an erofs root and an ext4 /var and
  # then switch-roots; it has no use for a GPU, and the splash that used to need one is now
  # drawn out of the root filesystem after the pivot.
  GPU_IN_INITRD="$(grep -E 'drivers/gpu/|/nvidia[-_.]|/nvidia\.ko' <<<"$INITRD_LIST" || true)"
  if [[ -n $GPU_IN_INITRD ]]; then
    die "verify: the initrd contains graphics drivers, which nothing in it can use:
$(head -n 20 <<<"$GPU_IN_INITRD")
  dracut's 'drm' module is omitted in the call above; something has pulled it back in as a
  dependency. See plan/14 — this is 70+ MiB of UKI and the reason plymouth was removed."
  fi
  # The firmware those drivers drag behind them, checked separately: dracut follows
  # MODULE_FIRMWARE, so the GSP blobs are ~98 MiB that arrive without any module name matching
  # the pattern above if only the firmware half regresses.
  if grep -qE 'firmware/nvidia/|gsp_[a-z0-9]+\.bin' <<<"$INITRD_LIST"; then
    die "verify: the initrd carries NVIDIA GSP firmware. Nothing in the initrd loads nvidia.ko
  any more; this is ~98 MiB of ESP for a splash that no longer lives here."
  fi

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

  # ---- the filesystems this initrd actually mounts -------------------------------------
  # erofs for the root and overlay for the /etc overlay module. ext4 (/var, x-initrd.mount) is
  # BUILT IN to this kernel and is correctly absent from the module list — do not "fix" that by
  # adding an ext4.ko check here. These two are asserted because the omit list below is the kind
  # of thing that grows a too-greedy regex, and a missing erofs.ko is an unbootable image.
  has 'fs/erofs/erofs\.ko' \
    || die "verify: initrd has no erofs.ko — root=PARTLABEL=... rootfstype=erofs cannot mount"
  has 'fs/overlayfs/overlay\.ko' \
    || die "verify: initrd has no overlay.ko — the etc-overlay dracut module cannot mount /etc"

  # First-boot growth. Without this drop-in the stock systemd-repart.service runs before dracut
  # has mounted /sysroot, cannot find a disk to work on, and exits 1 — which is not one of the
  # unit's tolerated exit codes, so the initrd goes to emergency and reboots. See
  # config/rootfs/usr/lib/dracut/modules.d/90repart-sysroot/module-setup.sh.
  has 'systemd-repart\.service\.d/10-sysroot\.conf' \
    || die "verify: initrd has no systemd-repart.service.d/10-sysroot.conf — the repart-sysroot
  dracut module did not install, and first boot would fail in the initrd and reboot forever"

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

    # ---- ...and did not break what stayed behind -----------------------------------------
    # The check above proves the omit list took effect. It says nothing about what the removals
    # BROKE, and that failure is silent by construction: dracut runs depmod over the initrd
    # tree, so a module whose dependency was omitted keeps its .ko and merely loses the
    # dependency line in modules.dep. modprobe then insmods it bare and the kernel rejects it
    # with "Unknown symbol". Nothing is logged at build time; the symptom arrives at boot.
    #
    # That is exactly how omitting netfs made erofs.ko unloadable — the ROOT filesystem module,
    # present, passing the has() check above, and unable to mount, so every boot died in the
    # initrd and rd.emergency=reboot looped forever with only "Failed to start Repartition Root
    # Disk" on the console. See the netfs paragraph in config/dracut-omit-drivers.txt.
    #
    # So resolve each initrd module against the TARGET's modules.dep — the complete one, before
    # dracut pruned it — and require the whole closure to be inside the initrd.
    TARGET_DEP="$TARGET/usr/lib/modules/$KVER/modules.dep"
    if [[ ! -f $TARGET_DEP ]]; then
      warn "verify: $TARGET_DEP not found — initrd dependency-closure check skipped"
    else
      broken="$(printf '%s\n' "${INITRD_MODS[@]}" | awk '
        NR == FNR { present[$0] = 1; next }
        /\.ko:/ {
          mod = $1; sub(/:$/, "", mod); sub(/.*\//, "", mod); sub(/\.ko$/, "", mod)
          gsub(/-/, "_", mod)
          if (!(mod in present)) next
          for (i = 2; i <= NF; i++) {
            dep = $i; sub(/.*\//, "", dep); sub(/\.ko$/, "", dep); gsub(/-/, "_", dep)
            if (!(dep in present)) print "  " mod " needs " dep
          }
        }' - "$TARGET_DEP" | sort -u)"
      if [[ -n $broken ]]; then
        die "verify: these initrd modules have dependencies that are NOT in the initrd, so the
  kernel would refuse to load them (\"Unknown symbol\"):
$broken
  Either drop the dependency's pattern from config/dracut-omit-drivers.txt, or omit the module
  that needs it as well. Do NOT ignore this for a filesystem or block driver — if the module is
  erofs, overlay or ext4, the image cannot boot at all."
      fi
      log "initrd: dependency closure complete for all ${#INITRD_MODS[@]} modules"
    fi
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
  # The converse: a leftover .splash in a kms-only or none build would paint an image the
  # kernel then blanks, which reads as a flicker no one ordered.
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
  # There is deliberately NOTHING here about a splash-to-greeter hand-off, and that absence is
  # the result plan/14 was after. The splash drops DRM master the moment it has painted, so the
  # greeter needs no ordering against it, no Conflicts=, and no drop-in on either unit — kwin
  # takes master, modesets, and the splash notices and exits. plan/08 open question 6 and
  # plan/11 finding 7 were both about machinery that no longer exists.
  # KWallet auto-unlock. Gentoo's PLM ebuild ships PAM stacks that already carry
  #   -auth    optional pam_kwallet5.so
  #   -session optional pam_kwallet5.so auto_start
  # and the leading "-" makes each line a no-op when the module is absent — so a missing
  # kde-plasma/kwallet-pam degrades to "prompt for the wallet password" rather than failing to
  # log in. A warning, not a die, for that reason.
  compgen -G "$TARGET/usr/lib64/security/pam_kwallet"*.so >/dev/null \
    || compgen -G "$TARGET/usr/lib/security/pam_kwallet"*.so >/dev/null \
    || warn "verify: no pam_kwallet module — KWallet will prompt instead of auto-unlocking"
  # Sound. Asserted on the SYMLINKS rather than on `systemctl --global enable`'s exit status,
  # for the same reason the display-manager alias above is: enablement that silently did not
  # take produces an image whose only symptom is a desktop with no audio, found by a user.
  [[ -L $TARGET/etc/systemd/user/sockets.target.wants/pipewire-pulse.socket ]] \
    || die "verify: pipewire-pulse.socket not enabled for users — nothing would listen on
  \$XDG_RUNTIME_DIR/pulse/native and KDE's volume applet reports 'Connection to the sound
  service lost' (autospawn is off in /etc/pulse/client.conf, so libpulse cannot recover)"
  [[ -L $TARGET/etc/systemd/user/sockets.target.wants/pipewire.socket ]] \
    || die "verify: pipewire.socket not enabled for users"
  # wireplumber is the session manager: without it PipeWire runs but adopts no ALSA card, so
  # the applet connects and then shows no output devices at all.
  [[ -L $TARGET/etc/systemd/user/pipewire.service.wants/wireplumber.service ]] \
    || die "verify: wireplumber.service not enabled — PipeWire would start with no session
  manager, and no audio device would ever be adopted"
  # The live user must be able to reach those RT limits, or the group membership above was lost.
  chroot_target "$TARGET" "id -nG '$LIVE_USER'" 2>/dev/null | tr ' ' '\n' | grep -qx pipewire \
    || die "verify: $LIVE_USER is not in the 'pipewire' group — no rtprio/nice limits apply
  (there is no rtkit-daemon in this image to fall back to)"
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
#
# The splash sources are in the hash for the same reason and it is the one that bites daily:
# `build.sh --from 40` is the documented iteration loop for the splash, and a stamp that ignored
# splash.c would happily skip the stage that compiles it, leaving the previous binary in place
# while the log says the build succeeded.
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" \
  "$REPO/config/prune-firmware.txt" "$REPO/config/prune-microcode.txt" \
  "$REPO/config/dracut-omit-drivers.txt" \
  "$REPO/config/splash/splash.c" "$REPO/config/branding/make-splash-assets.py")"
