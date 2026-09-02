#!/usr/bin/env bash
# Stage 40 — turn the raw rootfs into this distro: overlay files, users, presets,
# flatpak, chroot finalizers, then build the initrd + UKI from the builder side.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=40-configure
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

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
  profile_has_set desktop \
    && die "no 'pipewire' group in a desktop image — acct-group/pipewire is missing, so the
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
elif profile_has_set desktop; then
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
#
# `flatpak remote-add <url>` FETCHES that .flatpakrepo descriptor — the repo URL and its GPG
# key — so it needs the network before a single object is transferred. Offline that fails
# ahead of everything the sideload repo exists for, so use the archived copy of the same file.
# It is placed inside the target because the command runs in a chroot.
FLATHUB_SRC="https://dl.flathub.org/repo/flathub.flatpakrepo"
if [[ -f ${VENDOR_DIR:-}/flathub.flatpakrepo ]]; then
  install -m 0644 "$VENDOR_DIR/flathub.flatpakrepo" "$TARGET/tmp/flathub.flatpakrepo"
  FLATHUB_SRC="/tmp/flathub.flatpakrepo"
  log "adding the flathub remote from the archived descriptor"
elif [[ ${OFFLINE:-0} == 1 ]]; then
  die "offline build, but the archive has no flathub.flatpakrepo — the remote cannot be added.
  Re-run stage 90 to capture it."
fi
chroot_target "$TARGET" \
  "flatpak remote-add --if-not-exists --system flathub '$FLATHUB_SRC'"
rm -f "$TARGET/tmp/flathub.flatpakrepo"

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
  # Offline: RESTORE the archived /var/lib/flatpak rather than installing into it.
  #
  # `flatpak install` cannot be made to work without the network, even pointed at a sideload
  # repo holding every object: it resolves a ref name to a commit through the remote's summary
  # index and dies with "Unable to load summary from remote flathub" before reading a single
  # sideloaded byte. Restoring the tree needs no lookup at all, and gives an offline rebuild
  # byte-identical application state — which is the stronger property for a reproducible build.
  #
  # The readback below still runs and still has to pass, so this path is verified exactly as
  # the online one is rather than being taken on trust.
  if [[ ${OFFLINE:-0} == 1 || -d ${VENDOR_DIR:-}/flatpak/repo ]]; then
    [[ -d ${VENDOR_DIR:-}/flatpak/repo ]] \
      || die "offline build, but the archive has no flatpak/ tree — stage 40 cannot supply apps"
    log "restoring the archived flatpak tree (offline: install would need the remote summary)"
    ensure_dir "$TARGET/var/lib/flatpak"
    rsync -aH --delete "$VENDOR_DIR/flatpak/" "$TARGET/var/lib/flatpak/"
  else
    for app in $FLATPAK_PREINSTALL; do
      log "preinstalling flatpak: $app"
      chroot_target "$TARGET" "flatpak install -y --system --noninteractive flathub '$app'"
    done
  fi

  # ---- pin every ref to its locked commit (plan/15 layer 5) --------------------------
  # The install above takes whatever Flathub serves today, which is what made two builds of
  # the same release ship different Firefoxes. Deploying the locked commit afterwards is the
  # supported way to land on an exact version — there is no "install this commit" verb.
  #
  # Runtimes are in the lock too, and they arrive as dependencies rather than being named in
  # FLATPAK_PREINSTALL, so this loop is what pins most of the shipped bytes.
  APPS_LOCK="$REPO/config/flatpak/apps.lock"
  if [[ -f $APPS_LOCK && ${OFFLINE:-0} != 1 ]]; then
    while read -r ref commit; do
      [[ -n $ref && $ref != \#* ]] || continue
      chroot_target "$TARGET" \
        "flatpak update -y --system --noninteractive --commit='$commit' '$ref'" \
        || die "could not deploy $ref at $commit.
  Flathub garbage-collects old commits, so a pin that has aged out is the expected cause.
  Re-resolve the flatpak lock:  scripts/relock.sh --flatpak
  (or rebuild from the vendored archive, which still has the objects)"
    done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')

    # Read it back. `flatpak update --commit=` on an already-current ref exits 0 and says
    # "Nothing to do", which is indistinguishable from success — so ask what is actually
    # deployed rather than trusting that the loop above did anything.
    #
    # --all, not the default listing: bare `flatpak list` omits extensions (.Locale,
    # GL.default), and those are in the lock precisely because they are most of the bytes.
    # Checked against flatpak on this host: 12 refs listed by default, 17 with --all.
    FP_ACTIVE="$(chroot_target "$TARGET" \
      "flatpak list --system --all --columns=ref,active" 2>/dev/null | tr -d '\r')"
    fp_bad=0
    while read -r ref commit; do
      [[ -n $ref && $ref != \#* ]] || continue
      # `flatpak list` prints the ref WITHOUT its app/ or runtime/ prefix
      # ("org.kde.ark/x86_64/stable"), while the lock keeps the prefix because that is what
      # distinguishes an app from a runtime of the same name. Compare on the stripped form.
      short="${ref#*/}"
      got="$(printf '%s\n' "$FP_ACTIVE" | awk -v r="$short" '$1 == r {print $2}')"
      # `flatpak list` abbreviates the commit to 12 chars; compare on the prefix it prints.
      [[ -n $got && $commit == "$got"* ]] || {
        warn "flatpak $ref is at '${got:-<not installed>}', lock says ${commit:0:12}"
        fp_bad=1
      }
    done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')
    (( fp_bad == 0 )) || die "the deployed flatpak commits do not match config/flatpak/apps.lock
  (see the warnings above). The image would ship different application versions than the lock
  claims, which is the whole failure this lock exists to prevent."
    log "flatpak: $(grep -vc '^[[:space:]]*#' "$APPS_LOCK") refs deployed at their locked commits"
  elif [[ -f $APPS_LOCK ]]; then
    log "flatpak: restored from the archive; readback below is the check"
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

# ...and one more finalizer that is not a cache rebuild but a pkg_postinst this build can never
# have run. sys-libs/cracklib compiles its dictionary in pkg_postinst, guarded by
# `if [[ -z ${ROOT} ]]` — true when portage merges into the live root, false for every merge
# stage 30 does with ROOT=$TARGET. So the image ships the raw word list
# (/usr/share/dict/cracklib-small, which multilib_src_install_all installs) and a libcrack.so
# whose compiled-in default dictionary is /usr/lib/cracklib_dict, and nothing at that path.
# It is /usr/lib rather than /usr/share because the ebuild passes
# --with-default-dict=/usr/lib/cracklib_dict so the dictionary is shared between ABIs.
#
# The symptom is entirely the installer's, and it is fatal to an install: FascistCheck cannot
# open the dictionary, dev-libs/libpwquality turns that into PWQ_ERROR_CRACKLIB_CHECK, and
# Calamares' users page rejects EVERY password with "The password fails the dictionary check -
# error loading dictionary". No password is strong enough to pass a dictionary that will not
# load, so Next never enables and the medium cannot install anything. Reproduced against the
# 0.3.0 installer target through libpwquality directly, and fixed by exactly this command.
#
# Guarded on the tool rather than on the profile: cracklib is @installer tail
# (config/portage/sets/installer), so desktop and console images have no dictionary to build and
# no libpwquality to read one. The word list is globbed rather than named, which is what the
# ebuild's own postinst line does — adding sys-apps/cracklib-words later should widen the
# dictionary here without an edit. Deterministic either way: cracklib-format sorts under LC_ALL=C.
#
# -o is passed explicitly so the path written here is the same string the readback below and
# stage 50's prune assertion test, rather than three independent guesses at a compiled-in
# default. The word count is read back because an empty word list is not an error to
# cracklib-packer — it writes a valid, useless dictionary and exits 0.
if [[ -x $TARGET/usr/bin/create-cracklib-dict ]]; then
  log "building the cracklib dictionary (cracklib's pkg_postinst skips ROOT=\$TARGET merges)"
  CRACKLIB_OUT="$(chroot_target "$TARGET" \
    "create-cracklib-dict -o /usr/lib/cracklib_dict /usr/share/dict/*")" \
    || die "create-cracklib-dict failed — Calamares' users page would reject every password with
  'The password fails the dictionary check - error loading dictionary'"
  # cracklib-packer prints "<words read> <words written>" and nothing else.
  CRACKLIB_WORDS="${CRACKLIB_OUT##*[[:space:]]}"
  [[ $CRACKLIB_WORDS =~ ^[1-9][0-9]*$ ]] \
    || die "cracklib-packer wrote ${CRACKLIB_WORDS:-no} words — the dictionary at
  /usr/lib/cracklib_dict is empty, and libpwquality would pass every password it should reject.
  Is /usr/share/dict/ empty? sys-libs/cracklib installs cracklib-small there."
  log "cracklib dictionary: $CRACKLIB_WORDS words at /usr/lib/cracklib_dict"
fi

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
    -DSPLASH_RELEASE_FLAG="\"/run/$DISTRO_ID-splash.release\"" \
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
SPLASH_RELEASE_UNIT="$TARGET/usr/lib/systemd/system/$DISTRO_ID-splash-release.service"
SPLASH_RELEASE_WANTS="$TARGET/etc/systemd/system/graphical.target.wants"
if ! profile_has_set desktop; then
  log "no-desktop profile ($BUILD_PROFILE): removing the KMS splash units and udev rule (agetty owns the screen)"
  rm -f -- "$SPLASH_UNIT" "$SPLASH_RULE" "$SPLASH_RELEASE_UNIT"
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

  # The release unit, and the ONE reason it has to exist (plan/17).
  #
  # The splash holds DRM master from its modeset until this unit signals it, because every ioctl
  # that presents a new frame is master-gated and nothing but a real GPU shows a second frame
  # without one. logind calls drmSetMaster() when it hands the DRM fd to the compositor and
  # returns the failure to its caller, so a splash still holding master when the display manager
  # starts is a session that never starts. Being ordered Before= the DM — and pulled into the
  # same transaction by graphical.target, which is also what Wants= the DM — is what stops that
  # from ever happening.
  #
  # Enabled by hand rather than by `systemctl enable`: there is no systemd running here to ask,
  # and this is exactly the symlink the enable would make. graphical.target.wants, not
  # display-manager.service.wants — the DM is only reachable here through an alias, and the
  # unit's own [Install] comment says why that is a poor thing to hang a boot on.
  [[ -f $SPLASH_RELEASE_UNIT ]] \
    || die "verify: $SPLASH_RELEASE_UNIT missing — the overlay in config/rootfs did not install it
  The splash would hold DRM master until its own MASTER_HOLD_SECONDS backstop, which is a
  greeter that may fail to take the DRM device for as long as that lasts."
  grep -qx "Before=display-manager.service" "$SPLASH_RELEASE_UNIT" \
    || die "verify: $DISTRO_ID-splash-release.service is not ordered before the display manager"
  grep -qx "ExecStart=-/usr/bin/systemctl kill --signal=SIGUSR1 $DISTRO_ID-splash.service" \
       "$SPLASH_RELEASE_UNIT" \
    || die "verify: $DISTRO_ID-splash-release.service does not signal $DISTRO_ID-splash.service"
  grep -qx "ExecStart=-/usr/bin/touch /run/$DISTRO_ID-splash.release" "$SPLASH_RELEASE_UNIT" \
    || die "verify: $DISTRO_ID-splash-release.service does not write the flag splash.c reads
  (SPLASH_RELEASE_FLAG, compiled in above) — a splash that starts after the display manager
  would take DRM master with nothing left to tell it to let go."
  [[ -x $TARGET/usr/bin/touch && -x $TARGET/usr/bin/systemctl ]] \
    || die "verify: the release unit's two ExecStart binaries are not both in the image"
  ensure_dir "$SPLASH_RELEASE_WANTS"
  ln -sfn "../../../../usr/lib/systemd/system/$DISTRO_ID-splash-release.service" \
          "$SPLASH_RELEASE_WANTS/$DISTRO_ID-splash-release.service"
  [[ -e $SPLASH_RELEASE_WANTS/$DISTRO_ID-splash-release.service ]] \
    || die "verify: the release unit's wants symlink does not resolve — it would never run,
  and the splash would keep DRM master into the greeter's start."
  grep -qx "WantedBy=graphical.target" "$SPLASH_RELEASE_UNIT" \
    || die "verify: $DISTRO_ID-splash-release.service is not WantedBy=graphical.target — the
  symlink above and the unit's [Install] disagree about how it gets pulled in."
  log "boot splash: master released by $DISTRO_ID-splash-release.service, ordered before display-manager.service"
fi

# ---- 2c. the Plasma splash screen (plan/17) ------------------------------------------
# The other half of the same picture. The KMS splash above holds the brand mark from the first
# modeset to the greeter; this is what draws it from the login to a painted desktop, and it is
# the same mark running the same layer pulse because both come out of the generator that just
# built splash.bin.
#
# DESKTOP PROFILES ONLY. A console image has no Plasma to configure, so nothing here runs for it
# — and the else branch asserts nothing is there anyway, which is a statement about stale work
# volumes rather than about this stage.
if profile_has_set desktop; then
  # The Look-and-Feel package. Its id is what /etc/xdg/ksplashrc names, and ksplashqml resolves
  # that id straight to this directory (SplashWindow::setGeometry -> KPackage::setPath).
  SPLASH_LNF_ID="$DISTRO_ID"
  SPLASH_LNF_DIR="$TARGET/usr/share/plasma/look-and-feel/$SPLASH_LNF_ID"
  PLASMA_SRC="$REPO/config/plasma"
  # Rebuilt from scratch, like the branding PNG directory above: `build.sh --from 40` reruns this
  # against a work volume that already has the last run's package in it, and a slab renamed in
  # config/branding would otherwise leave its old SVG behind for the QML to keep drawing.
  rm -rf -- "$SPLASH_LNF_DIR"
  # And the package this one absorbed. The installer medium's layout used to live in a second
  # Look-and-Feel package, $DISTRO_ID-installer, until it turned out that kdeglobals can only
  # name one of them and the one it named had no splash in it (plan/17). Nothing writes that
  # directory any more, so on a work volume that predates the merge it would simply survive into
  # the image — a dead package, listed nowhere, shipped anyway.
  rm -rf -- "$TARGET/usr/share/plasma/look-and-feel/$DISTRO_ID-installer"
  while IFS= read -r -d '' f; do
    rel="${f#"$PLASMA_SRC/lookandfeel/"}"
    dst="$SPLASH_LNF_DIR/${rel%.in}"
    ensure_dir "$(dirname -- "$dst")"
    if [[ $f == *.in ]]; then render_template "$f" "$dst"; else cp -- "$f" "$dst"; fi
    chmod 0644 -- "$dst"
  done < <(find "$PLASMA_SRC/lookandfeel" -type f -print0)

  # The generated half of the package: the re-shaded slab vectors the QML animates, and the
  # Design.qml it takes its geometry and its pulse timings from. Generated rather than committed
  # for the same reason splash.bin is — the shading and the layout have one source, and it is
  # the script that composed the frame this splash takes over from.
  python3 "$REPO/config/branding/make-splash-assets.py" \
    --svg-dir "$REPO/config/branding" \
    --theme "$SPLASH_LNF_DIR/contents/splash" \
    || die "Plasma splash: theme asset generation failed"
  # A preview for System Settings -> Appearance -> Splash Screen. Same canvas function as the
  # installer's slide, at the 300x169 Breeze's own previews/splash.png uses.
  python3 "$REPO/config/branding/make-splash-assets.py" \
    --asset-dir "$BRANDING_PNG" --logo-scale 0.6 \
    --slide "$SPLASH_LNF_DIR/contents/previews/splash.png" --slide-size 300x169 \
    || die "Plasma splash: preview generation failed"
  find "$SPLASH_LNF_DIR" -type f -exec chmod 0644 {} +
  find "$SPLASH_LNF_DIR" -type d -exec chmod 0755 {} +

  # /etc/xdg, not a skel copy: KConfig cascades it under ~/.config, so these are the defaults for
  # the live account, for the installer medium's live account and for every account Calamares
  # creates, with no per-user step anywhere.
  #
  # BOTH FILES, AND kdeglobals IS THE ONE THAT DECIDES. startplasma prepends
  # ~/.config/kdedefaults to XDG_CONFIG_DIRS and writes its own ksplashrc in there on first
  # login, derived from the Look-and-Feel package id kdeglobals names — so /etc/xdg/ksplashrc is
  # shadowed on every real session and naming a package with no splash in it silently yields
  # Breeze. See config/plasma/kdeglobals.in; the installer profile adds its layout script to the
  # SAME package below rather than pointing this key somewhere else.
  render_template "$PLASMA_SRC/ksplashrc.in" "$TARGET/etc/xdg/ksplashrc"
  chmod 0644 -- "$TARGET/etc/xdg/ksplashrc"
  render_template "$PLASMA_SRC/kdeglobals.in" "$TARGET/etc/xdg/kdeglobals"
  chmod 0644 -- "$TARGET/etc/xdg/kdeglobals"

  # The package id is written in three independently rendered files and they have to be the same
  # string. If they drift nothing fails: ksplashqml cannot find the package, falls back to
  # Breeze, and the machine boots to somebody else's logo on a screen no test can see.
  grep -q "\"Id\": \"$SPLASH_LNF_ID\"" "$SPLASH_LNF_DIR/metadata.json" \
    || die "verify: the look-and-feel package in $SPLASH_LNF_ID does not declare Id \"$SPLASH_LNF_ID\""
  grep -qx "Theme=$SPLASH_LNF_ID" "$TARGET/etc/xdg/ksplashrc" \
    || die "verify: /etc/xdg/ksplashrc does not select Theme=$SPLASH_LNF_ID — the splash would
  silently fall back to Breeze."
  grep -qx "LookAndFeelPackage=$SPLASH_LNF_ID" "$TARGET/etc/xdg/kdeglobals" \
    || die "verify: /etc/xdg/kdeglobals does not name $SPLASH_LNF_ID as the Look-and-Feel
  package. That key, not ksplashrc, is what a Plasma session turns into a splash theme — every
  account would get ~/.config/kdedefaults/ksplashrc written from some other package's id and
  the splash would silently fall back to Breeze. See config/plasma/kdeglobals.in."
  for f in Splash.qml Design.qml images/slab-top.svg images/slab-mid.svg images/slab-bot.svg \
           images/wordmark.svg; do
    [[ -s $SPLASH_LNF_DIR/contents/splash/$f ]] \
      || die "verify: $SPLASH_LNF_DIR/contents/splash/$f is missing or empty"
  done

  # ksplashqml is what loads all of the above, and it is a plasma-workspace binary rather than
  # anything this build produces — so it is exactly the kind of thing that can leave with a USE
  # flag change and take the splash with it, silently.
  [[ -x $TARGET/usr/bin/ksplashqml ]] \
    || die "verify: /usr/bin/ksplashqml is missing from the target — nothing would draw the
  Plasma splash. It ships in kde-plasma/plasma-workspace."

  # THE FADE OUT IS KWIN'S, not the theme's: SplashApp::setStage() calls QGuiApplication::exit()
  # on the "desktop" stage before the window could render another frame, so what actually fades
  # the splash away is the `login` effect — 500ms of opacity on windowClosed for a window whose
  # class is "ksplashqml ksplashqml". It is EnabledByDefault and this image ships no kwinrc, so
  # the default is what applies. Asserted rather than configured, because if upstream ever flips
  # that default the splash does not break, it just stops fading — and that is a change worth
  # noticing at build time instead of on a user's screen.
  KWIN_LOGIN="$TARGET/usr/share/kwin-wayland/effects/login/metadata.json"
  [[ -f $KWIN_LOGIN ]] \
    || die "verify: kwin's login effect is missing ($KWIN_LOGIN). Nothing would fade the Plasma
  splash out when the desktop appears — see plan/17."
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["KPlugin"]["EnabledByDefault"] else 1)' \
      "$KWIN_LOGIN" \
    || die "verify: kwin's login effect is no longer EnabledByDefault. The Plasma splash would
  vanish instead of fading out; ship an /etc/xdg/kwinrc with [Plugins] loginEnabled=true, or
  decide the snap is acceptable — see plan/17."

  log "Plasma splash: /usr/share/plasma/look-and-feel/$SPLASH_LNF_ID, selected for all users by /etc/xdg/ksplashrc"
else
  # The converse, for the same reason the installer block has one: nothing above runs on a
  # console image, so anything here came from a stale work volume rather than from this build.
  for leak in "usr/share/plasma/look-and-feel/$DISTRO_ID" etc/xdg/ksplashrc etc/xdg/kdeglobals; do
    [[ -e $TARGET/$leak ]] \
      && die "verify: $BUILD_PROFILE has no desktop, but /$leak exists in the target. Wipe the
  work volume and rebuild — a stale target is carrying Plasma config into a console image."
  done
fi

# ---- 2d. the graphical installer (plan/16) -------------------------------------------
# Everything in this section is `installer`-profile only. It installs Calamares' configuration
# and our four replacement modules, and it stages the PAYLOAD — the desktop profile's own root
# EROFS, UKI and /var tarball — into this image's /var, which is where an installer medium keeps
# the thing it installs (plan/16 §5.1).
#
# Nothing here runs for the desktop or console profiles, and that is asserted from the other end
# too: config/portage/expected-packages.desktop.txt names no part of the Calamares tail, so stage
# 50 fails the build if any of it ever reaches the product image.
if profile_has_set installer; then
  [[ $PROFILE_ROLE == live ]] \
    || die "profile $BUILD_PROFILE emerges @installer but has PROFILE_ROLE=$PROFILE_ROLE.
  The installer's dependency tail — GRUB with a legacy-BIOS platform, os-prober, squashfs-tools,
  boost — is only acceptable because it is thrown away with the medium (plan/16). Shipping it on
  an installable image is the one thing profiles exist to prevent."
  have_exe_t() { local n=$1; [[ -x $TARGET/usr/bin/$n || -x $TARGET/usr/sbin/$n ]]; }
  have_exe_t calamares || die "verify: app-admin/calamares is missing from the installer target"

  CAL_SRC="$REPO/config/calamares"
  [[ -d $CAL_SRC ]] || die "config/calamares is missing — it is the installer's whole configuration"

  # Tokens the Calamares templates use, beyond the ones section 1 already exported. Each is a
  # value that must agree with something else in the build, which is why they are rendered from
  # the build's own variables rather than written out in the YAML:
  #   GPT_TYPE_*         the partition types emit_sfdisk_script() writes
  #   ROOT_PARTLABEL     the label the UKI cmdline's root=PARTLABEL= looks for
  #   UKI_NAME           the filename sysupdate's 60-uki.transfer matches
  #   PAYLOAD_DIR        where this section stages the payload, below
  export GPT_TYPE_ROOT_X64 GPT_TYPE_VAR ROOT_SLOT_SIZE_MIB ROOT_PARTLABEL UKI_NAME PAYLOAD_DIR

  # Renders *.in through render_template and copies everything else verbatim. Deliberately NOT
  # install_rootfs_overlay: that walks config/rootfs and rebrands "distro" in basenames, and this
  # tree needs neither — Calamares module directory names are internal identifiers that must
  # match their module.desc exactly, so rebranding them would be a way to break them.
  cal_install() {
    local src=$1 dst=$2
    ensure_dir "$(dirname -- "$dst")"
    if [[ $src == *.in ]]; then render_template "$src" "$dst"; else cp -- "$src" "$dst"; fi
    chmod 0644 -- "$dst"
  }

  # /etc/calamares is the FIRST path Calamares searches for all three of these
  # (libcalamares/Settings.cpp, modulesystem/Module.cpp, CalamaresApplication.cpp), which is why
  # the configuration lives there rather than in /usr/share/calamares.
  log "installer: rendering the Calamares configuration into /etc/calamares"
  cal_install "$CAL_SRC/settings.conf.in" "$TARGET/etc/calamares/settings.conf"
  for f in "$CAL_SRC"/modules/*; do
    [[ -f $f ]] || continue
    b="$(basename -- "$f")"; cal_install "$f" "$TARGET/etc/calamares/modules/${b%.in}"
  done
  for f in "$CAL_SRC"/branding/installer/*; do
    [[ -f $f ]] || continue
    b="$(basename -- "$f")"; cal_install "$f" "$TARGET/etc/calamares/branding/installer/${b%.in}"
  done

  # Our modules go in a directory of their own rather than in among upstream's, so "which of
  # these did we write?" is answered by the path. settings.conf's modules-search names it.
  for d in "$CAL_SRC"/local-modules/*/; do
    [[ -d $d ]] || continue
    m="$(basename -- "$d")"
    for f in "$d"*; do
      [[ -f $f ]] || continue
      b="$(basename -- "$f")"
      cal_install "$f" "$TARGET/usr/share/calamares/local-modules/$m/${b%.in}"
    done
    # ModuleManager matches the descriptor's `name` against the DIRECTORY name and silently skips
    # the module when they differ — no error, the module just never appears in the sequence and
    # the install stops at a step that does not exist. Assert it here instead.
    grep -qE "^name:[[:space:]]+\"$m\"" "$TARGET/usr/share/calamares/local-modules/$m/module.desc" \
      || die "verify: module.desc in local-modules/$m does not declare name: \"$m\" — Calamares
  would skip it silently and the install would stop at a missing step"
  done

  # The branding logo, composed by the same function that produces the boot splash's two halves.
  # Every raster artefact in this build comes out of one build_block(): the user sees this
  # sidebar a minute after watching that splash, so they must be the same pixels rather than two
  # drawings of one logo.
  python3 "$REPO/config/branding/make-splash-assets.py" \
    --asset-dir "$BRANDING_PNG" \
    --logo  "$TARGET/etc/calamares/branding/installer/logo.png" \
    --slide "$TARGET/etc/calamares/branding/installer/slide.png" \
    || die "installer: branding image generation failed"
  for img in logo slide; do
    [[ -s $TARGET/etc/calamares/branding/installer/$img.png ]] \
      || die "installer: branding $img.png is empty — Calamares exits at startup without its branding"
    chmod 0644 -- "$TARGET/etc/calamares/branding/installer/$img.png"
  done

  # Live-medium ergonomics, all three of them the same argument: the live account's password is
  # printed in this medium's own documentation, so nothing on the medium should stop to ask for
  # it. Start the installer on login; let the live user authenticate for that ONE polkit action
  # without a prompt; and let the screen locker be dismissed without one (kscreenlockerrc's
  # [Daemon] RequirePassword, which starts the greeter --nolock and unlocks on first input).
  cal_install "$CAL_SRC/system/49-installer.rules.in" \
              "$TARGET/etc/polkit-1/rules.d/49-$DISTRO_ID-installer.rules"
  cal_install "$CAL_SRC/system/installer-autostart.desktop.in" \
              "$TARGET/etc/xdg/autostart/$DISTRO_ID-installer.desktop"
  cal_install "$CAL_SRC/system/kscreenlockerrc.in" "$TARGET/etc/xdg/kscreenlockerrc"

  # The live session's panel. Same argument one step further out: the medium exists to run one
  # application, so the task manager pins that application and nothing else. Left alone, the
  # Icons-Only Task Manager pins its KConfigXT defaults — System Settings, Discover, Dolphin and
  # a browser this profile does not install — and Calamares, the one thing here, is not among
  # them.
  #
  # It takes a Look-and-Feel package to change that, and the indirection is not ours: an applet's
  # KConfigXT default can only be beaten by a layout SCRIPT (Plasma::Corona::config() opens the
  # appletsrc with KConfig::SimpleConfig, which does not cascade, so the /etc/xdg trick the two
  # files above use is not available here), and ShellCorona::loadDefaultLayout() reads that
  # script from the Look-and-Feel package /etc/xdg/kdeglobals names.
  #
  # INTO THE PACKAGE SECTION 2c ALREADY BUILT, not a second one beside it. This medium used to
  # ship its layout in a package of its own, @DISTRO_ID@-installer, and point kdeglobals at
  # that; the splash stayed in @DISTRO_ID@ and /etc/xdg/ksplashrc was supposed to keep naming
  # it. It does not work, and the failure is silent: startplasma writes
  # ~/.config/kdedefaults/ksplashrc from the LookAndFeelPackage id before the session starts,
  # that directory outranks /etc/xdg, and a package with no contents/splash in it makes
  # ksplashqml fall back to Breeze without a word in the journal. One package carries both, the
  # id in kdeglobals is the same one everywhere, and the layout is the only thing this profile
  # adds to it. See config/plasma/kdeglobals.in.
  LNF_ID="$DISTRO_ID"
  LNF_DIR="$TARGET/usr/share/plasma/look-and-feel/$LNF_ID"
  [[ -f $LNF_DIR/metadata.json ]] \
    || die "installer: the look-and-feel package $LNF_ID has not been built — section 2c is
  supposed to have created it before this runs. Check that this profile has the desktop set."
  while IFS= read -r -d '' f; do
    rel="${f#"$CAL_SRC/system/lookandfeel/"}"
    cal_install "$f" "$LNF_DIR/${rel%.in}"
  done < <(find "$CAL_SRC/system/lookandfeel" -type f -print0)

  # The pin resolves through KService, which resolves through /usr/share/applications — so the
  # launcher is only as real as the .desktop file app-admin/calamares installs. A rename upstream
  # would leave a panel with one dead icon on it and no other way to start the installer once the
  # autostarted window is closed, and nothing else in this build would notice.
  [[ -f $TARGET/usr/share/applications/calamares.desktop ]] \
    || die "verify: /usr/share/applications/calamares.desktop is missing from the target, but the
  panel layout pins applications:calamares.desktop — the live session's only visible launcher
  would resolve to nothing"
  # Both halves in the one package. Section 2c built it for the splash and this section added the
  # layout to it; a copy that overwrote contents/splash, or a metadata.json.in reappearing under
  # config/calamares/system/lookandfeel and replacing 2c's, would leave the medium with a
  # LookAndFeelPackage that has no splash in it — which is the exact shape of the bug this
  # merge was made to fix, and it is silent at runtime.
  for half in contents/splash/Splash.qml contents/layouts/org.kde.plasma.desktop-layout.js; do
    [[ -s $LNF_DIR/$half ]] \
      || die "verify: $LNF_DIR/$half is missing or empty — the medium's one look-and-feel package
  has to carry the splash AND the panel layout, because /etc/xdg/kdeglobals can only name one"
  done
  grep -q "\"Id\": \"$LNF_ID\"" "$LNF_DIR/metadata.json" \
    || die "verify: the look-and-feel package in $LNF_ID does not declare Id \"$LNF_ID\" — check
  that nothing under config/calamares/system/lookandfeel overwrote the metadata.json section 2c
  rendered from config/plasma/lookandfeel"

  # ---- the payload ---------------------------------------------------------------------
  # Three files another profile's build produced, copied in unchanged. Under /var because stage
  # 60 builds the root EROFS with --exclude '/var/*' — it is the only place ~5 GiB can go — and
  # because the payload is data this medium carries, not part of the system it runs.
  : "${PAYLOAD_ROOT_EROFS:?installer profile without PAYLOAD_PROFILE — init_paths set no payload paths}"
  PAYLOAD_STAGE="$TARGET$PAYLOAD_DIR"
  ensure_dir "$PAYLOAD_STAGE"

  # Copy only what is not already there, byte-identically. `build.sh --from 40` is the documented
  # iteration loop, and re-copying 5 GiB on every pass would make it unusable.
  # Sets PAYLOAD_SUM/PAYLOAD_SIZE rather than echoing them, and that is not a style choice:
  # log() writes to stdout, so a `$(stage_payload ...)` would swallow every progress line into
  # the captured value — and a die() inside a command substitution exits only the SUBSHELL, so a
  # missing payload would be reported and then ignored.
  stage_payload() {   # stage_payload SRC DST_BASENAME LABEL
    local src=$1 base=$2 label=$3 dst="$PAYLOAD_STAGE/$2" sum
    [[ -f $src ]] || die "installer: the $label is missing from the payload profile's output:
      $src
  Build the payload profile first:  scripts/build.sh --profile $PAYLOAD_PROFILE"
    sum="$(sha256_file "$src")"
    if [[ -f $dst && $(stat -c%s "$dst") == $(stat -c%s "$src") && $(sha256_file "$dst") == "$sum" ]]; then
      log "installer: $label already staged ($(du -m "$dst" | cut -f1) MiB)"
    else
      log "installer: staging the $label ($(du -m "$src" | cut -f1) MiB)"
      cp --reflink=auto -f -- "$src" "$dst.tmp" && mv -f -- "$dst.tmp" "$dst"
      chmod 0444 -- "$dst"
    fi
    PAYLOAD_SUM="$sum"; PAYLOAD_SIZE="$(stat -c%s "$src")"
  }

  stage_payload "$PAYLOAD_ROOT_EROFS" root.erofs "root filesystem image"
  ROOT_SUM="$PAYLOAD_SUM"; ROOT_SIZE="$PAYLOAD_SIZE"
  stage_payload "$PAYLOAD_UKI"        uki.efi    "kernel image (UKI)"
  UKI_SUM="$PAYLOAD_SUM";  UKI_SIZE="$PAYLOAD_SIZE"
  VAR_SUM=""; VAR_SIZE=0
  if [[ ${INSTALLER_PAYLOAD_FLATPAKS:-1} == 1 ]]; then
    stage_payload "$PAYLOAD_VAR_TAR" var.tar.zst "/var template"
    VAR_SUM="$PAYLOAD_SUM"; VAR_SIZE="$PAYLOAD_SIZE"
  else
    # Not an error, and the difference matters at install time: imagedeploy warns about a MISSING
    # template and seeds a bare /var, which is the correct behaviour for a medium deliberately
    # built without one. Remove a stale copy so a rebuild with the switch flipped does not keep
    # installing Flatpaks the build no longer claims to carry.
    log "installer: INSTALLER_PAYLOAD_FLATPAKS=0 — no /var template (installed systems get no preinstalled Flatpaks)"
    rm -f -- "$PAYLOAD_STAGE/var.tar.zst"
  fi

  # The manifest is what imagedeploy verifies the medium against before it writes 2.7 GiB to
  # someone's disk. It is also the only human-readable record on the stick of what this medium
  # installs, which is worth having when someone finds an unlabelled USB stick in a drawer.
  {
    printf '{\n'
    printf '  "distro_id": "%s",\n'        "$DISTRO_ID"
    printf '  "version": "%s",\n'          "$VERSION"
    printf '  "payload_profile": "%s",\n'  "$PAYLOAD_PROFILE"
    printf '  "built_by_profile": "%s",\n' "$BUILD_PROFILE"
    printf '  "root_partlabel": "%s",\n'   "$ROOT_PARTLABEL"
    printf '  "uki_name": "%s",\n'         "$UKI_NAME"
    printf '  "root_erofs": { "file": "root.erofs", "sha256": "%s", "size": %s },\n' "$ROOT_SUM" "$ROOT_SIZE"
    printf '  "uki":        { "file": "uki.efi",    "sha256": "%s", "size": %s }'    "$UKI_SUM"  "$UKI_SIZE"
    if [[ -n $VAR_SUM ]]; then
      printf ',\n  "var_template": { "file": "var.tar.zst", "sha256": "%s", "size": %s }\n' "$VAR_SUM" "$VAR_SIZE"
    else
      printf '\n'
    fi
    printf '}\n'
  } > "$PAYLOAD_STAGE/manifest.json"
  chmod 0444 -- "$PAYLOAD_STAGE/manifest.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PAYLOAD_STAGE/manifest.json" \
    || die "installer: the generated manifest.json is not valid JSON"
  log "installer: payload staged in $PAYLOAD_DIR ($(du -sm "$PAYLOAD_STAGE" | cut -f1) MiB total)"
fi

# ---- 2e. live media never update themselves (plan/16 §3.4) ---------------------------
# A medium that is booted, used once and thrown away has nothing to update, and an update path
# that half-works is worse than none: `<id>-update` would report a version, offer to write a new
# root into a slot the live layout does not have (PROFILE_ROOT_SLOTS=1), and fail somewhere the
# user cannot act on.
#
# This touches the LIVE image only. The installed system's /usr comes from the payload EROFS,
# which the desktop build produced with its transfers intact — so removing them here cannot make
# an installed machine unupdatable, and stage 70's T-INST-3 is the assertion that it did not.
if [[ $PROFILE_ROLE == live ]]; then
  log "live profile ($BUILD_PROFILE): disabling systemd-sysupdate on the medium itself"
  rm -f -- "$TARGET"/usr/lib/sysupdate.d/*.transfer
  chroot_target "$TARGET" "systemctl mask systemd-sysupdate.service systemd-sysupdate.timer" \
    >/dev/null 2>&1 || warn "could not mask the systemd-sysupdate units"
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

# --early-microcode has nothing to contribute if the trees are already gone, and the check that
# notices is 200 lines below, AFTER dracut and ukify have run. That is ten minutes to be told
# something knowable in a millisecond — and the condition is not exotic: `build.sh --only 40`
# after a completed stage 50 is the ordinary edit-and-retry loop for anything in this stage, and
# stage 50 deletes exactly these two trees. Same condition, same advice, before the work.
#
# The post-build assertion below STAYS. This one proves the input existed; that one proves the
# output contains it, which is a different claim and the one that actually protects the image.
if [[ ! -d $TARGET/usr/lib/firmware/intel-ucode && ! -d $TARGET/usr/lib/firmware/amd-ucode ]]; then
  die "the target has no CPU microcode to pack into the initrd — both
  usr/lib/firmware/{intel,amd}-ucode are gone. Stage 50 deletes them (the early cpio built here
  is the only copy anything reads), so this is a stage 40 re-run against an already-pruned
  target. dracut would succeed and --early-microcode would contribute NOTHING, leaving every
  Intel and AMD machine on whatever microcode its firmware happened to load.
  Rebuild from stage 30 instead:  scripts/build.sh --profile $BUILD_PROFILE --from 30"
fi

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
# v2 (plan/17): 40-byte records — scale, anchor, flags, w, h, box_w, box_h as unsigned, off_x
# and off_y SIGNED, then the pixel offset. The signed pair is the reason this cannot be read as
# "<10I": a tile above the block's centre has a negative off_y, and reading it unsigned puts the
# mark four billion pixels off the top of the screen.
assert blob[:8] == b"IMSPLSH2", "bad magic"
bg, n = struct.unpack_from("<II", blob, 8)
assert 0 < n <= 32, f"implausible tile count {n}"
assert bg == 0x0A0D11, f"background {bg:#08x} is not the brand #0a0d11"
scales, pulses = set(), {}
for i in range(n):
    scale, anchor, flags, w, h, bw, bh, ox, oy, off = struct.unpack_from("<7IiiI", blob, 16 + i * 40)
    assert 0 < w <= 16384 and 0 < h <= 16384, f"tile {i} has implausible extent {w}x{h}"
    assert anchor in (0, 1, 2), f"tile {i} has unknown anchor {anchor}"
    assert bw >= w and bh >= h, f"tile {i} is bigger than the box it is placed in"
    assert off + w * h * 4 <= len(blob), f"tile {i} pixels run past the end of the file"
    scales.add(scale)
    if flags & 0x1:  # TILE_PULSE
        pulses.setdefault(scale, []).append(flags >> 8)
assert scales == {1, 2}, f"expected sprite scales 1 and 2, got {sorted(scales)}"
# Without these the splash still draws — it just never moves, which is a regression nothing
# downstream would report. One slab per slot: a duplicated slot animates two together and
# leaves the third permanently still.
for scale in sorted(scales):
    assert sorted(pulses.get(scale, [])) == [0, 1, 2], \
        f"scale {scale} has pulse slots {sorted(pulses.get(scale, []))}, expected one slab in each of 0,1,2"
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
  # Matched against the PATH and restricted to kernel modules and firmware, because the
  # obvious pattern is wrong in a way that fails a perfectly good build. '/nvidia[-_.]' puts a
  # literal '.' in the character class, so it matches etc/modprobe.d/nvidia.conf — 1488 bytes
  # of "blacklist nouveau" that nvidia-drivers installs and dracut sweeps in with the rest of
  # /etc/modprobe.d. That is not a graphics driver, it is not 70 MiB, and there is nothing to
  # act on when it is reported.
  #
  # What must still be caught is the real regression this guards: a dracut module pulling the
  # DRM tree back in. Those arrive as .ko files under drivers/gpu/ or as nvidia*.ko, plus the
  # firmware behind them — all three are matched below, and a config file is not.
  GPU_IN_INITRD="$(awk '
    { p = $NF }
    p ~ /drivers\/gpu\//                            { print; next }
    p ~ /(^|\/)nvidia[^\/]*\.ko(\.(xz|zst|gz))?$/    { print; next }
    p ~ /(^|\/)firmware\/nvidia\//                   { print; next }
  ' <<<"$INITRD_LIST" || true)"
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
# Live media have had their transfers removed by section 2e, deliberately; an installable image
# without them would be a machine that can never take an update.
if [[ $PROFILE_ROLE == target ]]; then
  [[ -f $TARGET/usr/lib/sysupdate.d/50-rootfs.transfer ]] || die "verify: sysupdate transfer missing"
else
  compgen -G "$TARGET/usr/lib/sysupdate.d/*.transfer" >/dev/null \
    && die "verify: $BUILD_PROFILE is a live profile but still carries sysupdate transfers"
fi
[[ -L $TARGET/home ]]                                     || die "verify: /home symlink missing"

# The desktop session hand-off. Each of these is a failure that would otherwise surface only as
# a black screen or a console login on a machine that is supposed to autologin — stage 70 reads
# a serial port and would report green for all three.
if profile_has_set desktop; then
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

# The installer. Each of these is a failure whose only symptom is a Calamares that refuses to
# start, or worse, one that starts and stops at a step that does not exist — on a user's machine,
# with their disk already partitioned.
if profile_has_set installer; then
  # Branding is fatal to Calamares by its own design: "Cowardly refusing to continue startup
  # without branding" (CalamaresApplication::initBranding), and the componentName inside the
  # descriptor must equal its directory name or Branding::Branding bails.
  CAL_BRAND="$TARGET/etc/calamares/branding/installer/branding.desc"
  [[ -f $CAL_BRAND ]] || die "verify: $CAL_BRAND missing — Calamares exits at startup without it"
  grep -qE '^componentName:[[:space:]]+installer$' "$CAL_BRAND" \
    || die "verify: branding.desc does not declare componentName: installer (it must equal its directory name)"
  [[ -s $TARGET/etc/calamares/branding/installer/logo.png ]] \
    || die "verify: the branding logo is missing or empty"

  # Every module named in settings.conf's sequence must actually exist, as either one of ours or
  # one of upstream's. A typo here is not an error at startup — the module is simply absent from
  # the sequence, and the install runs to "finished" having skipped, say, the step that writes
  # the bootloader.
  CAL_SETTINGS="$TARGET/etc/calamares/settings.conf"
  [[ -f $CAL_SETTINGS ]] || die "verify: $CAL_SETTINGS missing"
  while read -r mod; do
    [[ -n $mod ]] || continue
    mod="${mod%%@*}"                       # instance keys: module@id
    [[ -f $TARGET/usr/share/calamares/local-modules/$mod/module.desc ]] && continue
    compgen -G "$TARGET/usr/lib*/calamares/modules/$mod/module.desc" >/dev/null && continue
    die "verify: settings.conf's sequence names the module '$mod', which is installed nowhere.
  Calamares does not report this — it drops the step and the install silently skips it."
  done < <(sed -nE '/^sequence:/,/^[a-z]/ s/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_@-]*)[[:space:]]*$/\1/p' \
             "$CAL_SETTINGS" | grep -vxE 'show|exec')

  # The payload, and the one string that ties it to the boot: partition.conf creates a partition
  # with this label and the UKI cmdline looks for it. They are rendered from the same variable,
  # so this catches an edit that hardcoded one of them.
  [[ -s $TARGET$PAYLOAD_DIR/root.erofs && -s $TARGET$PAYLOAD_DIR/uki.efi ]] \
    || die "verify: the payload is missing from $PAYLOAD_DIR"
  grep -q "\"root_partlabel\": \"$ROOT_PARTLABEL\"" "$TARGET$PAYLOAD_DIR/manifest.json" \
    || die "verify: manifest.json's root_partlabel is not $ROOT_PARTLABEL"
  grep -q "\"$ROOT_PARTLABEL\"" "$TARGET/etc/calamares/modules/partition.conf" \
    || die "verify: partition.conf does not create a partition labelled $ROOT_PARTLABEL —
  the initrd's root=PARTLABEL=$ROOT_PARTLABEL would find nothing on the installed disk"
  grep -q "$ROOT_PARTLABEL" "$TARGET/etc/calamares/modules/imagedeploy.conf" \
    || die "verify: imagedeploy.conf does not look for $ROOT_PARTLABEL"

  # The autostart entry and the polkit rule are what make this a live INSTALLER rather than a
  # live desktop that happens to have Calamares on it.
  [[ -f $TARGET/etc/xdg/autostart/$DISTRO_ID-installer.desktop ]] \
    || die "verify: the installer autostart entry is missing — nothing would launch Calamares"
  [[ -f $TARGET/etc/polkit-1/rules.d/49-$DISTRO_ID-installer.rules ]] \
    || die "verify: the installer polkit rule is missing — pkexec would prompt for a password"
  grep -qx 'RequirePassword=false' "$TARGET/etc/xdg/kscreenlockerrc" 2>/dev/null \
    || die "verify: /etc/xdg/kscreenlockerrc does not set RequirePassword=false — the live
  session would lock itself after five idle minutes and ask for a password nobody was told to
  expect. Grepped rather than stat'd: the file existing is not the property that matters."

  # The panel. Read back for the same reason: /etc/xdg/kdeglobals existing says nothing about
  # whether it names the package, and the package existing says nothing about whether its one
  # script is the one that pins the installer. Both halves have to hold or the live session comes
  # up with Plasma's stock pins — System Settings, Discover, Dolphin, an absent browser — and the
  # installer reachable only from the menu.
  LNF_LAYOUT="$TARGET/usr/share/plasma/look-and-feel/$DISTRO_ID/contents/layouts/org.kde.plasma.desktop-layout.js"
  grep -qx "LookAndFeelPackage=$DISTRO_ID" "$TARGET/etc/xdg/kdeglobals" 2>/dev/null \
    || die "verify: /etc/xdg/kdeglobals does not select the $DISTRO_ID look-and-feel package —
  plasmashell would fall back to Breeze's layout and pin Plasma's stock four. The layout script
  went into that package, so this key has to be the package that has it."
  grep -qF 'writeConfig("launchers", ["applications:calamares.desktop"])' "$LNF_LAYOUT" 2>/dev/null \
    || die "verify: $LNF_LAYOUT does not write applications:calamares.desktop into the task
  manager's launchers — the medium's panel would carry every application except the one it
  exists to run. Matched on the writeConfig call, not the string: this file explains the pin in
  a comment, and a comment is not a pin."
  # loadTemplate() is what builds the panel in the first place. A layout script that pins the
  # installer onto a panel it forgot to create is a live session with no panel at all, and this
  # script runs exactly once, at first login, where nothing is left to correct it.
  grep -q 'loadTemplate("org.kde.plasma.desktop.defaultPanel")' "$LNF_LAYOUT" 2>/dev/null \
    || die "verify: $LNF_LAYOUT never loads the default panel template — the live session would
  start with no panel, no clock and no system tray"

  # The password dictionary, built by section 2's finalizer because cracklib's own pkg_postinst
  # cannot (see there). Read back here rather than trusted, because this is the one installer
  # failure that survives every other check in this file AND stage 70: the medium boots, the
  # greeter autologins, Calamares starts with its branding, the disk step completes — and then
  # the users page rejects every password typed with "The password fails the dictionary check -
  # error loading dictionary", with the install already half-committed.
  #
  # All three files, not just the dictionary: .pwd is the packed word data, .pwi its index and
  # .hwm the hash-bucket high-water marks, and cracklib opens .pwi and .hwm alongside .pwd.
  # /usr/lib/cracklib_dict is libcrack.so's --with-default-dict path; users.conf names no
  # dictpath, so this is the only place libpwquality will look.
  for cl_ext in pwd pwi hwm; do
    [[ -s $TARGET/usr/lib/cracklib_dict.$cl_ext ]] \
      || die "verify: /usr/lib/cracklib_dict.$cl_ext is missing or empty — libpwquality would
  reject every password on Calamares' users page with 'error loading dictionary', and the
  install could never get past it"
  done
fi

# The converse, asserted on every OTHER profile: none of this may reach an installable image.
# expected-packages.<profile>.txt catches the PACKAGES; these are the files this stage writes,
# which no package audit would ever see.
if ! profile_has_set installer; then
  for leak in etc/calamares "usr/share/calamares/local-modules" \
              "etc/xdg/autostart/$DISTRO_ID-installer.desktop" \
              "etc/polkit-1/rules.d/49-$DISTRO_ID-installer.rules" \
              "etc/xdg/kscreenlockerrc" \
              "usr/share/plasma/look-and-feel/$DISTRO_ID/contents/layouts" \
              "${PAYLOAD_DIR#/}"; do
    [[ -e $TARGET/$leak ]] \
      && die "verify: $BUILD_PROFILE does not include @installer, but /$leak exists in the target.
  Wipe the work volume and rebuild — a stale target is carrying installer files into a product image."
  done
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
#
# config/calamares/** joins them for exactly the same reason, one step worse: editing a Calamares
# module config is a stage-40-only change with no other trace, so a stamp that ignored the tree
# would skip the stage that installs it and leave the previous configuration on the medium while
# the log reported success. find|sort so the list is stable across filesystems.
mapfile -t CAL_INPUTS < <(find "$REPO/config/calamares" -type f | LC_ALL=C sort)
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" \
  "$REPO/config/prune-firmware.txt" "$REPO/config/prune-microcode.txt" \
  "$REPO/config/dracut-omit-drivers.txt" \
  "$REPO/config/splash/splash.c" "$REPO/config/branding/make-splash-assets.py" \
  "${CAL_INPUTS[@]}")"
