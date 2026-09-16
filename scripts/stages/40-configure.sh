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
# ---- CONFIG_PROTECT: apply what the merge deferred, BEFORE our overlay -----------------------
# Portage does not overwrite a file under CONFIG_PROTECT (/etc, among others) when a package
# updates it. It writes the new version alongside as ._cfg0000_<name> and leaves it for
# etc-update/dispatch-conf — a human, on a running machine, deciding whether to keep local edits.
#
# THERE IS NO HUMAN HERE AND THERE ARE NO LOCAL EDITS. Every merge in this pipeline goes into a
# freshly emerged root with ROOT=$TARGET, so the "old" file is only ever a previous build's
# vendor copy. Left alone, those updates are silently discarded and the image ships whatever the
# first build that ever created the file happened to write.
#
# That is not hypothetical, and it is how this block came to exist. sys-auth/pambase was rebuilt
# with USE=sssd for Active Directory support (plan/18): the package merged, its VDB records
# USE=sssd, pam_sss.so is installed and every package audit passes — and /etc/pam.d/system-auth
# was still the pam_sss-less version from a build nine days earlier, sitting next to a
# ._cfg0000_system-auth that had the twelve lines that make domain login work. The symptom would
# have been "authentication just fails", on a correctly built image, with nothing anywhere to
# point at a config file that was written and then ignored. Same shape as the cracklib
# dictionary in section 2 and --all-root in stage 60: a build-time detail with no trace near the
# symptom.
#
# Applied BEFORE install_rootfs_overlay, and the order is the whole design: the vendor's new file
# replaces the vendor's old one, and then our own config replaces both. Reversing it would let a
# package update clobber the files this repo ships. Numeric sort so that when several updates
# have stacked up (._cfg0000_, ._cfg0001_) the newest wins.
cfg_applied=0
while IFS= read -r cfg; do
  [[ -n $cfg ]] || continue
  dir="$(dirname -- "$cfg")"; base="$(basename -- "$cfg")"
  real="$dir/${base#._cfg????_}"
  log "config update: applying ${real#"$TARGET"/} (was deferred by CONFIG_PROTECT)"
  mv -f -- "$cfg" "$real"
  cfg_applied=$((cfg_applied + 1))
done < <(find "$TARGET/etc" -name '._cfg????_*' -print 2>/dev/null | sort)
(( cfg_applied == 0 )) || log "applied $cfg_applied deferred config update(s)"

install_rootfs_overlay "$REPO/config/rootfs" "$TARGET"

# The overlay ships /etc/distrobox unconditionally (install_rootfs_overlay walks the whole
# tree); an image built without the container stack must not carry a config file for a binary
# it does not have.
if [[ ${INCLUDE_DISTROBOX:-1} != 1 ]]; then
  rm -rf -- "${TARGET:?}/etc/distrobox"
fi

# The same argument as /etc/distrobox above, one surface further out — and it is the half of
# plan/20 §2.2 that the set marker cannot reach.
#
# The managed-mode KCM is `#not-live` in config/portage/sets/desktop, so a live build never
# emerges it. The QML front end beside it (plan/19 §7.2) is NOT a package: it is three files in
# config/rootfs, and install_rootfs_overlay walks the whole tree, so /usr/bin/<id>-managed-ui,
# its QML and its launcher entry land on every profile including this one. The result is a live
# medium carrying "Managed Settings" in Kickoff under System — visually the exact row §2.2 was
# written to remove, arriving by a different road. A live session enrols nothing, so the app
# opens on "not enrolled" and is discarded with the stick twenty minutes later.
#
# THE CLI STAYS, and that split is the whole point. /usr/bin/<id>-managed is what the Calamares
# accounts page execs — from this session, first with --root pointed at a scratch tree to enrol
# before the disk is written and then, through the accountsetup job, with --root pointed at the
# mounted target to apply the bundle there (plan/21 §3, §6) — so it is how the machine BEING
# INSTALLED gets enrolled, the one managed-mode job a live medium genuinely has. What goes is
# the front end a person would open; what stays is the tool the installer drives. The polkit
# action stays with it for the same reason: it authorises `pkexec <id>-managed`, and that
# binary is still here.
if [[ $PROFILE_ROLE == live ]]; then
  rm -f  -- "${TARGET:?}/usr/bin/${DISTRO_ID}-managed-ui" \
            "${TARGET:?}/usr/share/applications/${DISTRO_ID}-managed-ui.desktop"
  rm -rf -- "${TARGET:?}/usr/share/${DISTRO_ID}/managed-ui"
  log "live profile ($BUILD_PROFILE): removed the managed-mode front end (launcher entry,
  wrapper and QML) — a live session is never enrolled. The CLI stays: Calamares execs it to
  enrol the installed system"
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

# ---- managed mode: the bundle-signing trust anchor (plan/19 §5.7) --------------------------
# ARMOURED IN THE REPO, BINARY IN THE IMAGE. gpgv wants a binary keyring; the repo wants a file
# that diffs and that the suite's CRLF check can read a byte at a time, and a binary .gpg is
# neither. One dearmor here settles it, and the result is what /usr/bin/<id>-managed verifies
# every bundle against — the anchor is always the image, never a key fetched at enrolment time.
#
# Not gated on a MANAGED_VERIFY knob, deliberately, and this is the one place it differs from
# UPDATE_VERIFY above. plan/19 §5.8 rule 1 is "never send unsigned policy", with no trusted
# transport exception; a build switch that turned bundle verification off would be a switch that
# turns the whole security model off, and it would eventually ship enabled.
[[ -f $REPO/$MANAGED_PUBRING ]] \
  || die "MANAGED_PUBRING points at $MANAGED_PUBRING, which does not exist. Managed mode cannot
  verify a policy bundle without a trust anchor baked into the image, and there is no Portage on
  the target to add one later (plan/19 §5.7)."
require_cmds gpg
gpg --dearmor < "$REPO/$MANAGED_PUBRING" > "$WORK/managed-pubring.gpg" \
  || die "could not dearmor $MANAGED_PUBRING — is it an ASCII-armoured OpenPGP public key?"
[[ -s $WORK/managed-pubring.gpg ]] \
  || die "$MANAGED_PUBRING dearmored to an EMPTY keyring. gpg exits 0 on an armour block that
  contains no key, so the size is the only evidence anything was in it."
install -D -m 0644 "$WORK/managed-pubring.gpg" \
  "$TARGET/usr/lib/$DISTRO_ID/managed-pubring.gpg"
# The committed default is a throwaway whose PRIVATE half is in tests/managed-api/keys/, so that
# the stage-70 fixture can sign bundles a real image accepts. An image built against it will take
# policy from anyone who has read this repository.
MANAGED_KEY_UIDS="$(gpg --show-keys --with-colons "$REPO/$MANAGED_PUBRING" 2>/dev/null || true)"
if [[ $MANAGED_KEY_UIDS == *"TEST KEY"* ]]; then
  warn "managed mode is trusting the TEST bundle-signing key from $MANAGED_PUBRING.
  Its private half is committed in tests/managed-api/keys/ — anyone with this repo can sign
  policy for this image. Fine for a dev build and for the stage-70 fixture; never ship it."
fi

# locale.gen from LOCALE_GEN, which load_config() derives from config/languages.conf — one row per
# language the installer offers, so the locales this compiles below are exactly the locales the
# language page can promise (plan/22 §2b).
#
# DATA LINES ONLY. No header, no provenance comment, however much one belongs here: Calamares' own
# locale module reads this file as its list of available locales (modules/locale.conf names it as
# localeGenPath), and loadLocales() strips a leading '#' and keeps the REST of the line as a locale
# name. A comment mentioning "UTF-8" would survive its filter and arrive in the installer's locale
# dialog as an entry. The provenance is recorded in config/languages.conf and in modules/locale.conf
# instead, where nothing parses it.
printf '%s\n' "${LOCALE_GEN//;/$'\n'}" > "$TARGET/etc/locale.gen"
# The image's DEFAULT, deliberately still en_US regardless of how long the table above is: this is
# what the medium itself boots with and what imageidentity keeps when the chosen locale turns out
# not to be compiled. The installed system's value is written by imageidentity from the choice.
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

# READ THE ARCHIVE BACK, which is the assertion that matters and the one nothing used to make.
# Every locale in the table is a row the installer offers and a promise imageidentity has to be
# able to keep: target_has_locale() checks `locale -a` on the installed system before writing
# /etc/locale.conf, and answers by keeping en_US and warning. So a localedef that produced nothing
# turns into an installed desktop in English, three stages and one reboot away from the cause.
#
# Here, rather than in stage 70, because here is where the target is mounted and the archive was
# just written — stage 70 boots a finished image and would be asserting the same fact one layer
# further from anything it could fix. The normalisation is imageidentity's own, character for
# character, so the two cannot disagree about what "the target has this locale" means.
TARGET_LOCALES="$(chroot_target "$TARGET" "locale -a" 2>/dev/null | tr -d ' ' | tr '[:upper:]' '[:lower:]' || true)"
# Distinguished from "the locale is missing", because the two have different fixes and the
# per-locale message below would blame the table for a missing binary.
[[ -n $TARGET_LOCALES ]] \
  || die "\`locale -a\` produced nothing in the target, so the compiled locales cannot be checked.
  /usr/bin/locale comes with sys-libs/glibc; a target without it has a package-set problem, not a
  config/languages.conf problem."
while IFS='|' read -r lang_id lang_locale lang_label _; do
  [[ -n $lang_id ]] || continue
  want_locale="$(printf '%s' "$lang_locale" | sed 's/UTF-8/utf8/' | tr -d '-' | tr '[:upper:]' '[:lower:]')"
  grep -qx -- "$want_locale" <<<"$TARGET_LOCALES" \
    || die "the target cannot load $lang_locale, which config/languages.conf offers as
  $lang_label ($lang_id). localedef ran over /etc/locale.gen a few lines above; a locale missing
  from \`locale -a\` now means it failed there. Choosing that language in the installer would
  give the installed system LANG=en_US.UTF-8 and a warning nobody reads (plan/22 §2b)."
done <<<"$LANGUAGES_TABLE"
log "locales: $(grep -c . <<<"$LANGUAGES_TABLE") compiled and readable in the target"

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
    log "restoring the archived flatpak tree (install would need the remote summary)"
    ensure_dir "$TARGET/var/lib/flatpak"
    rsync -aH --delete "$VENDOR_DIR/flatpak/" "$TARGET/var/lib/flatpak/"
    # The restored tree IS the locked state — the archive was packed from a build that had
    # already been pinned, so its refs and its deployed directories both carry the locked
    # commits. The pinning loop below must therefore not run over it; see the note there.
    FLATPAK_RESTORED=1
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
  #
  # IT TAKES MORE THAN ONE PASS, because pinning a PARENT DRAGS ITS EXTENSIONS FORWARD.
  # `flatpak update --commit=<c> org.kde.Platform` updates the runtime and everything hanging off
  # it in one transaction, and the extensions in that transaction are re-resolved against the
  # remote's CURRENT summary — the commit argument applies to the ref that was named, not to its
  # relations. A single pass in lock order therefore pins an extension correctly and then undoes
  # it a moment later, because the lock is sorted and '.' sorts before '/', so
  # org.kde.Platform.Locale is ALWAYS reached before org.kde.Platform. From the 2026-09-13
  # desktop build, three lines apart in the log:
  #
  #     Updating runtime/org.kde.Platform.Locale/x86_64/6.10   <- row 12, deploys fd8f2b9352c2
  #     Updating runtime/org.kde.Platform.Locale/x86_64/6.10   <- dragged by row 13, to 3bd0cc910140
  #     Updating runtime/org.kde.Platform/x86_64/6.10          <- row 13
  #
  # and the readback below then failed the build on a ref this loop had itself moved. It is the
  # same flatpak behaviour the restore guard below was written for on 2026-09-07; that fix
  # covered the RESTORED tree and left the ordinary online install exposed, and the gap stayed
  # hidden only because every build in between restored from the archive.
  #
  # So: deploy, ask what is deployed, deploy whatever is still wrong, repeat. It converges
  # because the drag only runs one way — pinning an extension never moves its parent — and it
  # needs no model of which ref extends which, which is the part that would go stale. (A prefix
  # rule would already be wrong: the KStyle.Adwaita row extends org.kde.Platform through an
  # extension point whose name appears nowhere in this lock.)
  APPS_LOCK="$REPO/config/flatpak/apps.lock"
  if [[ -f $APPS_LOCK ]]; then
    # What the target has deployed right now, as "<ref> <12-char commit>" lines, with the ref
    # FULLY QUALIFIED — "app/org.kde.ark/x86_64/stable", the form apps.lock uses.
    #
    # `flatpak list` prints the ref without that prefix, and the prefix is what distinguishes an
    # app from a runtime of the same name, so it is put back by asking twice rather than by
    # stripping it off the lock. --app and --runtime are the filters that make the two halves
    # separable; --all is what includes EXTENSIONS in the runtime half (.Locale, GL.default),
    # and those are in the lock precisely because they are most of the bytes. Measured in this
    # target: 12 refs listed by default, 17 with --all.
    fp_deployed() {
      local kind
      for kind in app runtime; do
        chroot_target "$TARGET" \
          "flatpak list --system --all --$kind --columns=ref,active" 2>/dev/null \
          | tr -d '\r' | awk -v k="$kind" 'NF >= 2 { print k "/" $1, $2 }'
      done
    }
    # The locked refs the target does NOT have at their locked commit, one per line as
    # "<ref> <locked commit> <deployed commit>". Empty output means the tree matches the lock,
    # so this is both the loop's work list and the readback's verdict — the two cannot drift
    # apart into disagreeing about what "pinned" means.
    fp_drift() {
      local active ref commit got
      active="$(fp_deployed)"
      while read -r ref commit; do
        [[ -n $ref && $ref != \#* ]] || continue
        got="$(printf '%s\n' "$active" | awk -v r="$ref" '$1 == r {print $2}')"
        # `flatpak list` abbreviates the commit to 12 chars; compare on the prefix it prints.
        [[ -n $got && $commit == "$got"* ]] \
          || printf '%s %s %s\n' "$ref" "$commit" "${got:-<not-installed>}"
      done < <(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d')
    }

  # NOT after a restore, and this is a real failure rather than an optimisation. A restored tree
  # is already at the locked commits; running the loop over it re-contacts Flathub and drags the
  # extensions exactly as described above. The result is that pinning UNDOES the restore:
  # measured 2026-09-07, a tree restored with org.kde.Platform.Locale at the locked fd8f2b9352c2
  # came back out of this loop at Flathub's current 3bd0cc910140, and the readback below then
  # failed the build on a pin the archive had supplied correctly. The guard used to be
  # `OFFLINE != 1`, which covered the fully-offline build and missed `--vendor-dir` on its own —
  # the mode that rebuilds a release's Flatpak state while still emerging packages normally.
   if [[ ${OFFLINE:-0} != 1 && ${FLATPAK_RESTORED:-0} != 1 ]]; then
    # Four is a bound, not an expectation: one pass to deploy, one to undo the drag, one to find
    # nothing left to do. A lock still disagreeing after four is not a drag but a ref that cannot
    # be deployed at all, and the readback below is what says so, with the refs named.
    for fp_pass in 1 2 3 4; do
      mapfile -t FP_DRIFT < <(fp_drift)
      (( ${#FP_DRIFT[@]} )) || break
      log "flatpak: pin pass $fp_pass — ${#FP_DRIFT[@]} ref(s) not at their locked commit"
      for fp_row in "${FP_DRIFT[@]}"; do
        read -r ref commit got <<<"$fp_row"
        # A ref the lock names and the target does not have at all cannot be `update`d into
        # existence — `flatpak update` on an uninstalled ref is an error, not an install. It
        # happens: FLATPAK_PREINSTALL names the five APPS, and everything else in the lock
        # arrives as a dependency of whatever build of those apps Flathub is serving today, so a
        # runtime or extension that today's build no longer pulls in is simply absent. The lock
        # is the specification of what ships, so fetch it by name and let the pin below place it.
        if [[ $got == '<not-installed>' ]]; then
          log "flatpak: installing $ref — named by apps.lock, absent from the target"
          chroot_target "$TARGET" \
            "flatpak install -y --system --noninteractive flathub '$ref'" \
            || die "could not install $ref, which config/flatpak/apps.lock names.
  If Flathub has withdrawn the ref entirely, the lock is what has to change — re-resolve it with
  scripts/relock.sh --flatpak, or rebuild from the vendored archive with --vendor-dir."
        fi
        chroot_target "$TARGET" \
          "flatpak update -y --system --noninteractive --commit='$commit' '$ref'" \
          || die "could not deploy $ref at $commit.
  Flathub garbage-collects old commits, so a pin that has aged out is the expected cause.
  Re-resolve the flatpak lock:  scripts/relock.sh --flatpak
  (or rebuild from the vendored archive, which still has the objects — pass --vendor-dir and
  stage 40 restores its tree instead of installing)"
      done
    done

    # Then drop whatever the install dragged in that the lock does not name.
    #
    # `flatpak install` resolves an app's dependencies against TODAY's Flathub, so it pulls the
    # runtime today's build of that app wants. The pin above puts the app back to the commit the
    # lock names, which may want a different runtime — and nothing removes the first. On
    # 2026-09-13 org.kde.ark had moved to org.kde.Platform 6.11 while every locked app still runs
    # on 6.10, so the tree held BOTH KDE runtimes: ~1 GiB of a second Platform, its Locale and
    # its KStyle that no installed app referenced, that apps.lock does not name, and that would
    # therefore have shipped as the only unpinned bytes in an image whose whole design is that
    # there are none.
    #
    # BY NAME, not `--unused`. That was the first attempt and it is wrong: --unused means "no
    # installed app REQUIRES this", which is a different question from "the lock does not name
    # this", and the gap between them is the optional extensions. It removed
    # org.freedesktop.Platform.codecs-extra — 145 MiB of ffmpeg the image ships ON PURPOSE, which
    # nothing "requires" precisely because it is optional — and the readback below caught it.
    # The lock is the specification; "deployed but unlocked" is the exact complement of it, and
    # `scripts/relock.sh --flatpak` writes the lock from the deployed refs, so the two are the
    # same set by construction.
    #
    # One invocation for all of them: uninstalling a runtime takes its extensions with it, and a
    # second call naming an extension already removed that way would fail on nothing being wrong.
    LOCK_REFS="$(grep -v '^[[:space:]]*#' "$APPS_LOCK" | sed '/^[[:space:]]*$/d' | awk '{print $1}')"
    FP_EXTRA=()
    while read -r dref _; do
      [[ -n $dref ]] || continue
      grep -qxF -- "$dref" <<<"$LOCK_REFS" || FP_EXTRA+=("$dref")
    done < <(fp_deployed)
    if (( ${#FP_EXTRA[@]} )); then
      log "flatpak: removing ${#FP_EXTRA[@]} ref(s) deployed but not named by apps.lock: ${FP_EXTRA[*]}"
      # No die on failure: flatpak refuses to remove a runtime an installed app still needs, and
      # that refusal is information rather than a build failure — it means the lock is missing a
      # ref the apps genuinely use, which `relock.sh --flatpak` is what fixes. The image ships
      # the extra bytes in the meantime instead of shipping a broken app.
      chroot_target "$TARGET" \
        "flatpak uninstall -y --system --noninteractive ${FP_EXTRA[*]@Q}" \
        || warn "could not remove ${FP_EXTRA[*]} — the image will carry unpinned refs.
  If an app needs one of them, apps.lock is out of date: scripts/relock.sh --flatpak"
    fi
   else
    log "flatpak: tree restored from the archive; not re-pinning it (see the note above)"
   fi

    # Read it back. UNCONDITIONALLY — for the restored tree as much as the installed one.
    #
    # This used to sit inside the pinning branch, so the offline/restore path skipped it
    # entirely while a comment above claimed that path "is verified exactly as the online one is
    # rather than being taken on trust". It was not: an archive that had been packed wrong, or an
    # rsync that dropped a ref, would have shipped unnoticed. It is the check either way.
    # `flatpak update --commit=` on an already-current ref exits 0 and says "Nothing to do",
    # which is indistinguishable from success — so ask what is actually deployed rather than
    # trusting that the loop above did anything.
    fp_bad=0
    while read -r ref commit got; do
      [[ -n $ref ]] || continue
      warn "flatpak $ref is at '$got', lock says ${commit:0:12}"
      fp_bad=1
    done < <(fp_drift)
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
# the installer's accounts page rejects EVERY password with "The password fails the dictionary
# check - error loading dictionary". (It was Calamares' own users page that hit this first;
# plan/21 replaced that page with one that calls pwquality_check() itself, which is the same
# library and therefore the same trap.) No password is strong enough to pass a dictionary that
# will not load, so Next never enables and the medium cannot install anything. Reproduced
# against the 0.3.0 installer target through libpwquality directly, and fixed by this command.
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
    || die "create-cracklib-dict failed — the installer's accounts page would reject every
  password with 'The password fails the dictionary check - error loading dictionary'"
  # cracklib-packer prints "<words read> <words written>" and nothing else.
  CRACKLIB_WORDS="${CRACKLIB_OUT##*[[:space:]]}"
  [[ $CRACKLIB_WORDS =~ ^[1-9][0-9]*$ ]] \
    || die "cracklib-packer wrote ${CRACKLIB_WORDS:-no} words — the dictionary at
  /usr/lib/cracklib_dict is empty, and libpwquality would pass every password it should reject.
  Is /usr/share/dict/ empty? sys-libs/cracklib installs cracklib-small there."
  log "cracklib dictionary: $CRACKLIB_WORDS words at /usr/lib/cracklib_dict"
fi

# ...and one more thing the vendor stacks do not do for us. A domain user (plan/18) has no home
# directory until the first time they log in, and nothing in Gentoo's PAM stacks creates one:
# sys-auth/pambase has no flag for it, and sys-auth/oddjob — which is what Fedora uses — is not
# in the tree at all. So the line is ours.
#
# It is appended HERE, at build time, and not written at join time on purpose. /etc/pam.d lives
# in the read-only lower; a join that edited it would copy the whole file up into the /etc
# overlay and freeze it at this release's content forever, because the overlay has no 3-way
# merge (plan/01). Appending at build time means every release ships a freshly generated pambase
# stack with our one line on the end.
#
# system-login is the right file rather than system-auth: it is the session stack the console
# getty (login -> system-local-login), the greeter (plasmalogin, `session substack system-login`)
# and sshd (system-remote-login) all reach, and `sudo`/`su` — which include system-auth instead —
# must NOT create home directories. Appending puts it after `-session optional pam_systemd.so`,
# which is the same position Fedora's `postlogin` occupies.
#
# umask=0077 so a domain user's home is not world-readable on a shared machine. Gated on the
# module existing, but the module ships with sys-libs/pam and @base has that in every profile,
# so the verify block below turns "absent" into a build failure rather than a silent skip.
# ...and one more finalizer, for the same reason as the cracklib dictionary: something that can
# only be checked with the target's own tools, whose absence is invisible until a user hits it.
#
# sssd VALIDATES its configuration and refuses to start on an unknown option. Not a warning — the
# daemon exits, and on a machine that has just been joined the symptom is "the join failed" with
# the real cause three layers down in `systemctl status`. Two invalid options shipped in the very
# first version of the generator here and were found only by booting a guest against a live
# domain controller: `config_file_version`, which sssd 1.x required and 2.x rejects, and
# `krb5_store_password_if_available`, which was simply invented — the real option is
# `krb5_store_password_if_offline`. Neither is a typo a human would spot, and both look right.
#
# So the generator's output is checked against sssd's own schema at BUILD time, with sssctl from
# the same package that will read it. `--print-config sssd` renders a representative config
# without touching anything; the domain name is arbitrary because option NAMES are what is being
# validated, not reachability.
if [[ -x $TARGET/usr/sbin/sssctl || -x $TARGET/usr/bin/sssctl ]]; then
  log "validating the generated sssd.conf against sssd's own schema"
  ensure_dir "$TARGET/etc/sssd"
  chroot_target "$TARGET" \
    "${DISTRO_ID}-domain join --domain validate.invalid --user check --print-config sssd \
       > /etc/sssd/sssd.conf && chmod 0600 /etc/sssd/sssd.conf" \
    || die "could not render a sample sssd.conf with ${DISTRO_ID}-domain --print-config"
  # sssctl reports "Issues identified by validators: 0" for an EMPTY file, so the render has to be
  # shown to have produced something before its verdict means anything. The `|| die` above covers
  # a generator that exits non-zero; this covers one that exits 0 and writes nothing, which is the
  # same shape as the empty-check-passes-vacuously bug this file exists to prevent.
  [[ -s $TARGET/etc/sssd/sssd.conf ]] \
    || die "${DISTRO_ID}-domain --print-config sssd rendered an EMPTY file; sssctl would validate
  it clean and prove nothing"
  grep -q '^\[domain/' "$TARGET/etc/sssd/sssd.conf" \
    || die "the rendered sssd.conf has no [domain/...] section — sssctl validates that clean too"
  SSSD_CHECK="$(chroot_target "$TARGET" "sssctl config-check" 2>&1 || true)"
  rm -f -- "$TARGET/etc/sssd/sssd.conf"
  grep -q '^Issues identified by validators: 0' <<<"$SSSD_CHECK" || die \
"the sssd.conf that ${DISTRO_ID}-domain generates is REJECTED by sssd's own validator:

$SSSD_CHECK

sssd exits rather than warns on an unknown option, so a machine joined with this config would
report a failed join with the cause buried in systemctl status. Fix the generator in
config/rootfs/usr/bin/distro-domain.in; the valid option names are in
/usr/share/sssd/sssd.api.d/ inside the target."
  log "sssd.conf validates clean"
fi

PAM_LOGIN="$TARGET/etc/pam.d/system-login"
if [[ -f $PAM_LOGIN ]] && ! grep -q 'pam_mkhomedir\.so' "$PAM_LOGIN"; then
  log "adding pam_mkhomedir to the system-login session stack (domain users have no home yet)"
  {
    printf '\n'
    printf '# Added by stage 40 (plan/18): create a home directory on first login. Domain\n'
    printf '# accounts come from sssd and have no home until they log in once.\n'
    printf 'session\t\toptional\tpam_mkhomedir.so\tumask=0077 skel=/etc/skel\n'
  } >> "$PAM_LOGIN"
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
  # The ACCOUNTS PAGE is a compiled Calamares view module from the in-repo overlay (plan/21), and
  # it reaches an image only through a re-resolved lock. Its predecessor — the managed-enrolment
  # page — was OPTIONAL, and settings.conf carried a substituted token so a medium without it
  # still built. This one is not optional: it is the installer's only account-creation step, so a
  # medium without it produces an install that runs all the way to "finished" and leaves a disk
  # with no account anyone can log into. Calamares would not even complain — a settings.conf that
  # names a module installed nowhere is a step it silently drops.
  #
  # So this is a die, here, before anything is rendered, rather than a warn and an empty line.
  compgen -G "$TARGET/usr/lib*/calamares/modules/accounts/module.desc" >/dev/null \
    || die "verify: the installer's accounts page is not installed, so this medium would boot an
  installer that creates no accounts (plan/21). It comes from
  ${DISTRO_ID}-base/${DISTRO_ID}-calamares-accounts in config/portage/overlay, which reaches an
  image only through a re-resolved lock:
      scripts/relock.sh ${DISTRO_ID}-base/${DISTRO_ID}-calamares-accounts --profile installer"
  log "installer: the accounts page is installed"

  # THE LANGUAGE PAGE, and its absence is worse than a missing page (plan/22). It is the FIRST
  # entry in settings.conf's sequence, and it is where QQuickStyle::setStyle() happens — a call
  # that is silently ignored once any QML has imported Qt Quick Controls. So a medium without it
  # would open on the greeting with no language ever chosen, and would draw the accounts page in
  # Fusion with no icons. Same die, same reason, same relock as the accounts page above.
  compgen -G "$TARGET/usr/lib*/calamares/modules/language/module.desc" >/dev/null \
    || die "verify: the installer's language page is not installed, so this medium would never ask
  which language to install in, and would draw every later QML page in the wrong Qt Quick Controls
  style (plan/22 §3). It comes from
  ${DISTRO_ID}-base/${DISTRO_ID}-calamares-language in config/portage/overlay, which reaches an
  image only through a re-resolved lock:
      scripts/relock.sh ${DISTRO_ID}-base/${DISTRO_ID}-calamares-language --profile installer"
  log "installer: the language page is installed"

  # THE GREETING PAGE (plan/23), and this is the one whose absence has no visible symptom worth
  # trusting. It contributes the six requirement checks that decide whether Next may be pressed at
  # all — including the disk check upstream's welcome module drops in silence on a Calamares built
  # without libparted (plan/22 §3a) — so a medium without it does not show an error, it shows a
  # working installer that will happily start writing a 3 GiB payload onto a 16 GiB disk.
  compgen -G "$TARGET/usr/lib*/calamares/modules/greeting/module.desc" >/dev/null \
    || die "verify: the installer's greeting page is not installed, so this medium would run no
  requirement checks at all and would let an install begin on a disk too small to hold it
  (plan/23 §5). It comes from
  ${DISTRO_ID}-base/${DISTRO_ID}-calamares-greeting in config/portage/overlay, which reaches an
  image only through a re-resolved lock:
      scripts/relock.sh ${DISTRO_ID}-base/${DISTRO_ID}-calamares-greeting --profile installer"
  log "installer: the greeting page is installed"

  # THE DISK PAGE (plan/24), and its absence is the one that fails in the exec phase rather than
  # on screen. It is the only page that chooses a disk, and the `disksetup` job reads that choice
  # out of GlobalStorage — so a medium without it boots an installer that asks for a language, a
  # keyboard and an account, says "really install?", and then stops with no device to write to,
  # having already told the user their disk was about to be erased.
  compgen -G "$TARGET/usr/lib*/calamares/modules/disk/module.desc" >/dev/null \
    || die "verify: the installer's disk page is not installed, so this medium would run an
  installer with nothing to choose a disk with and would fail in the exec phase (plan/24 §5). It
  comes from ${DISTRO_ID}-base/${DISTRO_ID}-calamares-disk in config/portage/overlay, which
  reaches an image only through a re-resolved lock:
      scripts/relock.sh ${DISTRO_ID}-base/${DISTRO_ID}-calamares-disk --profile installer"
  log "installer: the disk page is installed"

  # INSTALLER_LANGUAGES — the `languages:` block for modules/language.conf — is built by
  # load_languages() in lib/common.sh, not here, because this stage is not the only thing that
  # renders that template: tests/test-installer.sh renders the whole Calamares tree offline, and a
  # token only this stage defined made every one of those renders die.
  log "installer: language page offers $(grep -c '^    - id:' <<<"$INSTALLER_LANGUAGES") languages"

  export GPT_TYPE_ROOT_X64 GPT_TYPE_VAR ROOT_SLOT_SIZE_MIB ROOT_PARTLABEL UKI_NAME PAYLOAD_DIR
  # ...and the two the disk page and its job are rendered from (plan/24). ESP_SIZE_MIB and
  # MIN_INSTALL_DISK_GB are build.conf's; each reaches TWO templates, which is the whole reason
  # they are rendered rather than written out: modules/disk.conf draws the bar and states the
  # minimum, modules/disksetup.conf creates the partitions and re-checks the minimum, and
  # modules/greeting.conf gates Next on the same number.
  export ESP_SIZE_MIB MIN_INSTALL_DISK_GB

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
  # WIPE FIRST. This tree is rendered, never merged: every file under /etc/calamares comes from
  # config/calamares and nothing in the package set owns a path here. Without the removal the
  # target root — which persists in the work volume across runs — keeps whatever an EARLIER build
  # rendered, so deleting a module's .conf.in from the repository leaves its .conf on the medium
  # forever.
  #
  # Found by building plan/22: welcome.conf.in was deleted, `welcome` left the sequence, and
  # /etc/calamares/modules/welcome.conf was still on the finished image. It was inert — Calamares
  # only reads configs for modules the sequence names — but "inert" is a property of today's
  # settings.conf, and a stale config for a module that later comes back under the same name is
  # not inert at all. tests/test-installer.sh did not catch it either: it asserts against the
  # freshly rendered tree, where the file legitimately does not exist.
  rm -rf -- "$TARGET/etc/calamares"

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

  # ---- our own pages, in the user's language (plan/22 §4) ------------------------------------
  #
  # Calamares installs a BRANDING translator on QCoreApplication and reloads it on every language
  # change, from a path the branding component already owns: Branding.cpp:296 builds the prefix as
  # <componentDir>/lang/calamares-<componentName>_, and BrandingLoader::tryLoad() appends the
  # locale. So a .qm at .../branding/installer/lang/calamares-installer_de.qm is loaded for the
  # `de` row and NOTHING ELSE HAS TO BE WIRED — a QTranslator installed on the application
  # resolves by (context, sourceText) whichever library the context lives in, so our modules'
  # tr() and qsTr() strings come out of this one file. No QTranslator of our own, no fourth
  # mechanism, no retranslation plumbing.
  #
  # The loop is over the TABLE and not over the directory, in both directions: a language offered
  # with no .ts is a page that quietly falls back to English on one screen in nine, and a .ts for
  # a language nobody offers is dead weight. check-translations.py refuses both, plus the failure
  # that has no symptom at all — a <source> that does not match the code byte for byte, which Qt
  # reports by leaving the string in English.
  CAL_LANG_SRC="$CAL_SRC/branding/installer/lang"
  CAL_LANG_DST="$TARGET/etc/calamares/branding/installer/lang"
  [[ -d $CAL_LANG_SRC ]] \
    || die "installer: $CAL_LANG_SRC is missing — every page this project wrote would be English
  in all nine languages the picker offers (plan/22 §4)"

  python3 "$REPO/scripts/lib/check-translations.py" \
    --table "$REPO/config/languages.conf" \
    --lang-dir "$CAL_LANG_SRC" \
    --source-dir "$REPO/config/portage/overlay/distro-base/distro-calamares-language/files" \
    --source-dir "$REPO/config/portage/overlay/distro-base/distro-calamares-greeting/files" \
    --source-dir "$REPO/config/portage/overlay/distro-base/distro-calamares-accounts/files" \
    --source-dir "$REPO/config/portage/overlay/distro-base/distro-calamares-disk/files" \
    || die "installer: the branding translations do not match config/languages.conf or the module
  sources (plan/22 §4). Nothing above this line is a runtime error in Qt — a mismatched source
  string is a page that stays English — which is why it is a build failure here."

  # lrelease is on the BUILDER, not in the image: dev-qt/qttools:6[linguist] is a DEPEND of the
  # overlay's Calamares modules and DEPEND is installed into ESYSROOT, which this pipeline leaves
  # at "/" (config/portage/overlay/README.md). Gentoo puts the Qt6 tools in a versioned libdir
  # rather than on PATH, so both are tried.
  LRELEASE=""
  for c in lrelease-qt6 lrelease; do
    command -v "$c" >/dev/null 2>&1 && { LRELEASE="$c"; break; }
  done
  if [[ -z $LRELEASE ]]; then
    for c in /usr/lib64/qt6/bin/lrelease /usr/lib/qt6/bin/lrelease; do
      [[ -x $c ]] && { LRELEASE="$c"; break; }
    done
  fi
  [[ -n $LRELEASE ]] \
    || die "installer: no lrelease on the builder, so the branding translations cannot be
  compiled. It arrives as dev-qt/qttools:6[linguist], a DEPEND of the overlay's Calamares
  modules — a builder without it has not emerged them."

  ensure_dir "$CAL_LANG_DST"
  while IFS='|' read -r lang_id _ lang_label _; do
    [[ -n $lang_id ]] || continue
    # `en` has no file and needs none: it is the source language, so tr() already answers in it.
    [[ $lang_id == en ]] && continue
    ts="$CAL_LANG_SRC/calamares-installer_${lang_id}.ts"
    qm="$CAL_LANG_DST/calamares-installer_${lang_id}.qm"
    "$LRELEASE" -silent "$ts" -qm "$qm" \
      || die "installer: lrelease failed on $ts"
    # lrelease exits 0 having written nothing when every message is unfinished, and an empty .qm
    # loads without complaint — a translated language that is entirely English.
    [[ -s $qm ]] \
      || die "installer: $qm is empty. lrelease drops unfinished messages, so a .ts file with no
  finished translation compiles to nothing and $lang_label ($lang_id) would render in English."
    chmod 0644 -- "$qm"
  done <<<"$LANGUAGES_TABLE"
  log "installer: compiled $(find "$CAL_LANG_DST" -name '*.qm' | wc -l) branding translations"

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

  # ---- the layout helper: the pipeline's own partitioner, on the medium (plan/24 §4) --------
  #
  # scripts/lib/layout.sh, VERBATIM. It is a library when sourced — common.sh sources it, so stage
  # 60 builds the factory .img from these functions — and a CLI when executed, which is how the
  # `disksetup` job gets the sfdisk script for the disk the user chose.
  #
  # THE COPY IS THE POINT. Until plan/24 the installed machine's partitions came from a
  # `partitionLayout:` block in modules/partition.conf and the factory image's came from
  # emit_sfdisk_script() in lib/common.sh: two descriptions of one layout, 300 lines apart in two
  # languages, that tests/test-installer.sh had to compare label by label and GUID by GUID. That
  # test could only ever catch the drift it was taught to look for, and plan/16 §3.4 is what makes
  # drift fatal — a machine whose partition labels or GPT types differ from the image's is one
  # systemd-sysupdate stops recognising. One file cannot disagree with itself.
  #
  # cp and chmod rather than cal_install: this is not a template (it must stay byte-identical) and
  # it has to be executable, which cal_install's 0644 would take away.
  DISK_LAYOUT_SRC="$REPO/scripts/lib/layout.sh"
  DISK_LAYOUT_DST="$TARGET/usr/libexec/$DISTRO_ID-disk-layout"
  [[ -f $DISK_LAYOUT_SRC ]] \
    || die "installer: $DISK_LAYOUT_SRC is missing — it is where the partition layout lives, and
  the medium's disksetup job runs it to produce the sfdisk script (plan/24 §4)"
  ensure_dir "$(dirname -- "$DISK_LAYOUT_DST")"
  cp -f -- "$DISK_LAYOUT_SRC" "$DISK_LAYOUT_DST"
  chmod 0755 -- "$DISK_LAYOUT_DST"
  # Byte-for-byte, asserted rather than assumed. A rendered or rewritten copy would be a second
  # description again, which is the thing this file exists to stop.
  cmp -s "$DISK_LAYOUT_SRC" "$DISK_LAYOUT_DST" \
    || die "installer: $DISK_LAYOUT_DST is not byte-identical to $DISK_LAYOUT_SRC"
  # ...and it has to actually run on the medium, which is a different claim from "it was copied".
  # The builder's bash is the image's bash, so a syntax error here is a syntax error there.
  bash -n "$DISK_LAYOUT_DST" \
    || die "installer: the disk layout helper does not parse as bash"
  # THE INTERPRETER LINE, CHECKED AS BYTES RATHER THAN BY RUNNING THE FILE. The `disksetup` job
  # starts this helper with python's subprocess — plain execve — and execve refuses a text file
  # whose first two bytes are not `#!`. Everything else here reads it through a shell, and a
  # shell quietly adopts a shebang-less script (bash's ENOEXEC fallback), which is how a medium
  # shipped whose every install died at "[Errno 8] Exec format error" one screen after the user
  # agreed to the erase. `env` is no detector either: glibc's execvp keeps the /bin/sh fallback,
  # so a shebang-less helper survives that too. The magic is asserted here, and so is the
  # interpreter it names — a shebang pointing at a binary the medium does not carry is ENOENT,
  # which differs from ENOEXEC only in which of the two is missing.
  [[ $(head -n 1 -- "$DISK_LAYOUT_DST") == '#!/bin/bash' ]] \
    || die "installer: the disk layout helper has no interpreter line. A shell runs it anyway,
  which is why this was never noticed, but the job execve's it — every install from the medium
  would fail with \"Exec format error\" (plan/24 §4)"
  [[ -x $TARGET/bin/bash ]] \
    || die "installer: /bin/bash is not on the medium, so its own disk layout helper cannot run"
  # One real invocation, against a plausible disk, checked for the one string an installed machine
  # cannot boot without. This is the cheapest place to catch a layout helper that runs and emits
  # the wrong thing: everything after it is a stranger's hardware.
  _layout_probe="$("$DISK_LAYOUT_DST" sfdisk --disk-mib 65536 \
                     --esp-mib "$ESP_SIZE_MIB" --slot-mib "$ROOT_SLOT_SIZE_MIB" \
                     --version "$VERSION")" \
    || die "installer: the disk layout helper failed on a 64 GiB disk"
  for _want in "name=\"esp\"" "name=\"$ROOT_PARTLABEL\"" "name=\"_empty\"" "name=\"var\""; do
    grep -qF -- "$_want" <<<"$_layout_probe" \
      || die "installer: the disk layout helper does not create $_want. The initrd finds root by
  PARTLABEL off the UKI cmdline and /etc/fstab finds var and esp the same way, so a machine
  installed from this medium would not boot (plan/16 §3.4)."
  done
  # Counted out of the probe, not out of PART_COUNT: the helper ran in a subprocess, so this
  # stage's own shell variables say nothing about what it produced.
  log "installer: the disk layout helper is installed and creates $(grep -c '^start=' <<<"$_layout_probe") partitions"

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

  # NO /usr/bin/realm HERE ANY MORE, and its absence is asserted below. The shim existed for one
  # caller: Calamares' stock users module, whose ActiveDirectoryJob hardcodes the command name
  # `realm` and which realmd — not in the Gentoo tree — would otherwise have had to provide. With
  # the accounts page owning domain join (plan/21), the `accountsetup` job runs
  # $DISTRO_ID-domain directly, and a /usr/bin/realm on the medium would be a command with no
  # caller that answers to a name people expect to mean realmd.

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

  # ---- the one wallpaper this medium carries (plan/20 §2.1) -----------------------------
  # A Wallpaper/Images KPackage, installed for this profile alone. The live medium dropped the
  # 216.8 MiB collection from the set and has stage 50 delete Breeze's own 38.3 MiB `Next`, so
  # without this /usr/share/wallpapers is empty and the containment has nothing to draw. The
  # answer used to be the solid-colour plugin; this is 0.4 MiB of branded artwork instead, which
  # keeps all but 0.4 of the 255.1 MiB and gives the medium the same mark the boot splash showed.
  #
  # LIVE ONLY, like everything else in this block. The PRODUCT keeps the full collection and
  # Breeze's default — a machine somebody owns gets to choose its own background, and section 3i
  # of stage 50 asserts that direction too.
  #
  # THE DIRECTORY NAME IS THE PACKAGE ID and both are $DISTRO_ID, the same string the
  # look-and-feel package above uses. metadata.json.in renders the id, so a renamed distro moves
  # the directory and the descriptor together; they are compared below because KPackage uses that
  # comparison to decide whether the package loads at all, and a mismatch is silent.
  WP_DIR="$TARGET/usr/share/wallpapers/$DISTRO_ID"
  # Rebuilt rather than merged into, for the reason section 2c gives about the look-and-feel
  # package: `build.sh --from 40` reruns this against a work volume that already has the last
  # run's package in it, and a renamed image file would otherwise leave its predecessor behind
  # for findPreferredImageInPackage() to keep choosing.
  rm -rf -- "$WP_DIR"
  while IFS= read -r -d '' f; do
    rel="${f#"$CAL_SRC/system/wallpaper/"}"
    cal_install "$f" "$WP_DIR/${rel%.in}"
  done < <(find "$CAL_SRC/system/wallpaper" -type f -print0)
  find "$WP_DIR" -type d -exec chmod 0755 {} +

  # The three things that have to be true for a wallpaper package to resolve, none of which fails
  # loudly at runtime — plasmashell draws an empty containment and logs nothing anyone reads.
  grep -q "\"Id\": \"$DISTRO_ID\"" "$WP_DIR/metadata.json" \
    || die "verify: the wallpaper package in $WP_DIR does not declare Id \"$DISTRO_ID\". KPackage
  compares the descriptor's id against the directory it loaded from, exactly as it does for the
  look-and-feel package, and a mismatch makes the package invalid rather than wrong"
  # WallpaperPackage::findPreferredImageInPackage() picks the file whose BASENAME parses as
  # <width>x<height> and ignores every file that does not (packagefinder.cpp, resSize()). A
  # wallpaper committed as `wallpaper.png` would leave the package valid, the entry list
  # non-empty and the chosen image null.
  wp_images=$(find "$WP_DIR/contents/images" -type f -regextype posix-extended \
                   -regex '.*/[0-9]+x[0-9]+\.(png|jpg|jpeg|webp)' 2>/dev/null | wc -l)
  [[ $wp_images -ge 1 ]] \
    || die "verify: $WP_DIR/contents/images holds no file named <width>x<height>.<ext>.
  findPreferredImageInPackage() selects on that basename and skips everything else, so the
  package would load and then resolve to no image at all"
  # ...and the layout script has to name the directory this section just created. Two independent
  # strings, one rendered from config/calamares/system/wallpaper and one from the layout template,
  # and a drift between them is a blank desktop on a medium that built clean.
  grep -qF "'/usr/share/wallpapers/$DISTRO_ID/'" \
       "$LNF_DIR/contents/layouts/org.kde.plasma.desktop-layout.js" \
    || die "verify: the live layout script does not point org.kde.image at $WP_DIR — the
  containment would fall back through DefaultWallpaper::defaultWallpaperPackage() to Breeze's
  Next, which stage 50 section 3i deletes on this medium, and draw nothing"

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

  # The language page (plan/22). Four ways this can be wrong, and the first is the one with no
  # symptom on the page it breaks.
  #
  # IT HAS TO BE THE FIRST `show:` ENTRY, not merely present. ModuleManager::loadModules() walks
  # the sequence in order, and QQuickStyle::setStyle() — which this module makes on behalf of every
  # QML page in the installer — is silently ignored once anything has imported Qt Quick Controls.
  # Put another QML view step ahead of it and the accounts page loses Breeze's colours, Breeze's
  # metrics and every icon, with one warning on stderr.
  CAL_FIRST_SHOW="$(sed -nE '/^sequence:/,$ { /^- show:/,/^- / { s/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_@-]*)[[:space:]]*$/\1/p } }' \
                      "$CAL_SETTINGS" | head -1)"
  [[ $CAL_FIRST_SHOW == language ]] \
    || die "verify: the first module in settings.conf's show sequence is '${CAL_FIRST_SHOW:-<none>}',
  not 'language'. That module is where QQuickStyle::setStyle() happens for the whole installer, and
  the call is ignored once any QML has imported Qt Quick Controls — so anything ahead of it costs
  every later page its icons, colours and metrics (plan/22 §3b)."
  grep -qE '^type:[[:space:]]+"?viewmodule"?' \
    "$(compgen -G "$TARGET/usr/lib*/calamares/modules/language/module.desc" | head -1)" \
    || die "verify: the language module's descriptor does not declare type: viewmodule."

  # ...AND THE GREETING IS THE SECOND (plan/23). Order matters here for a reason that is not
  # QQuickStyle's: the greeting's verdict, its logo and the sentence about erasing the disk are all
  # drawn in the language the previous page just chose. Behind the language page it reads in a
  # language somebody picked; ahead of it, in whatever the medium booted with.
  CAL_SECOND_SHOW="$(sed -nE '/^sequence:/,$ { /^- show:/,/^- / { s/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_@-]*)[[:space:]]*$/\1/p } }' \
                       "$CAL_SETTINGS" | sed -n 2p)"
  [[ $CAL_SECOND_SHOW == greeting ]] \
    || die "verify: the second module in settings.conf's show sequence is '${CAL_SECOND_SHOW:-<none>}',
  not 'greeting'. The greeting states the verdict in the language the page before it chose, and it
  is the step whose Next is gated on the requirement checks (plan/23 §5)."
  grep -qE '^type:[[:space:]]+"?viewmodule"?' \
    "$(compgen -G "$TARGET/usr/lib*/calamares/modules/greeting/module.desc" | head -1)" \
    || die "verify: the greeting module's descriptor does not declare type: viewmodule."

  # The stock welcome module must NOT be in the sequence. Like `users`, it is still installed and
  # cannot be removed — and like `users`, it is the entry on the forbidden list that would actually
  # WORK, which is what makes it worth asserting: a third first page with its own language picker,
  # and its requirements check would re-add the storage entry it then drops.
  grep -qE '^[[:space:]]*-[[:space:]]+welcome$' "$CAL_SETTINGS" \
    && die "verify: settings.conf names the stock 'welcome' module, which plan/22 replaced and
  plan/23 replaced the rest of. It would draw a second language picker below its own requirements
  list, and its storage check is the one -DWITHOUT_LIBPARTED silently deletes
  (GeneralRequirements.cpp:357)."

  # The rendered list, against the table it came from. A render that produced no rows leaves the
  # installer's first screen blank, and the module logs an error nobody is watching for.
  # ...and nothing else survived from an older build. The wipe above is what makes this true; this
  # is the assertion that says so, because the wipe is one line that a future edit could drop
  # while every other check in this stage kept passing.
  while IFS= read -r leftover; do
    [[ -f $CAL_SRC/modules/$(basename -- "$leftover") || -f $CAL_SRC/modules/$(basename -- "$leftover").in ]] \
      || die "verify: $TARGET/etc/calamares/modules/$(basename -- "$leftover") is on the medium but
  config/calamares/modules ships no such file. /etc/calamares is rendered rather than merged, so a
  file with no source is residue from an earlier build — see the rm above."
  done < <(find "$TARGET/etc/calamares/modules" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)

  CAL_LANG_CONF="$TARGET/etc/calamares/modules/language.conf"
  LANG_ROWS_TABLE="$(grep -c . <<<"$LANGUAGES_TABLE")"
  LANG_ROWS_CONF="$(grep -cE '^[[:space:]]+- id:' "$CAL_LANG_CONF" || true)"
  [[ $LANG_ROWS_CONF == "$LANG_ROWS_TABLE" ]] \
    || die "verify: language.conf offers $LANG_ROWS_CONF languages and config/languages.conf names
  $LANG_ROWS_TABLE. The list is rendered from the table by this stage, so they can only differ if
  the rendering is broken."
  LANG_ROWS_GEN="$(grep -c . "$TARGET/etc/locale.gen" || true)"
  [[ $LANG_ROWS_GEN == "$LANG_ROWS_TABLE" ]] \
    || die "verify: /etc/locale.gen has $LANG_ROWS_GEN lines and config/languages.conf names
  $LANG_ROWS_TABLE languages. Every offered language needs a compiled locale, or imageidentity
  refuses the choice and the installed system comes up in English (plan/22 §2b)."
  while IFS='|' read -r lang_id lang_locale lang_label _; do
    [[ -n $lang_id ]] || continue
    grep -qxF "$lang_locale UTF-8" "$TARGET/etc/locale.gen" \
      || die "verify: /etc/locale.gen does not name $lang_locale, which the language page offers
  as $lang_label — so choosing it would give the installed system LANG=en_US.UTF-8 and a warning"
  done <<<"$LANGUAGES_TABLE"
  # That the locales were actually COMPILED — `locale -a` against the built root — is stage 70's
  # assertion rather than this one's. It is the same fact checked one layer further out, where the
  # image is a finished artefact instead of a mount this stage still owns.
  log "installer: $LANG_ROWS_TABLE languages offered, compiled and translated"

  # The disk requirement, in the file that now carries it (plan/23 §3). This is the number whose
  # absence has no symptom until an install is already under way, and it has been silently absent
  # before: it spent the life of the stock welcome module being deleted at startup by
  # -DWITHOUT_LIBPARTED. Both halves are asserted, because `check` without `required` reports a
  # failure and lets Next be pressed anyway.
  CAL_GREET_CONF="$TARGET/etc/calamares/modules/greeting.conf"
  [[ -f $CAL_GREET_CONF ]] \
    || die "verify: /etc/calamares/modules/greeting.conf was not rendered, so the greeting module
  gets no configuration, runs no checks, and its page sits on a spinner for ever (plan/23 §3)."
  for k in requiredStorage requiredRam internetCheckUrl; do
    grep -qE "^[[:space:]]+$k:" "$CAL_GREET_CONF" \
      || die "verify: greeting.conf does not set $k."
  done
  for k in storage ram root; do
    [[ $(grep -cE "^[[:space:]]+-[[:space:]]+$k\$" "$CAL_GREET_CONF") == 2 ]] \
      || die "verify: greeting.conf does not both check AND require '$k'. A requirement that is
  checked and not required is reported on the page and does not block Next, which for storage is
  the exact shape of the bug plan/22 §3a closed."
  done
  grep -qE '^[[:space:]]+requirements:' "$CAL_LANG_CONF" \
    && die "verify: language.conf still carries a requirements: block. Those keys moved to
  greeting.conf with the module that reads them (plan/23 §3); a copy left behind is a second
  source of truth for the disk size, and the module that reads language.conf ignores it."

  # The accounts page (plan/21). The sequence check above already dies if settings.conf names a
  # module that is installed nowhere; these are the other three ways this pair can be wrong, and
  # every one of them is silent at runtime.
  grep -qE '^[[:space:]]*-[[:space:]]+accounts$' "$CAL_SETTINGS" \
    || die "verify: settings.conf's show sequence does not name the accounts page, so the
  installer would ask nobody about accounts and create none (plan/21)"
  grep -qE '^type:[[:space:]]+"?viewmodule"?' \
    "$(compgen -G "$TARGET/usr/lib*/calamares/modules/accounts/module.desc" | head -1)" \
    || die "verify: the accounts module's descriptor does not declare type: viewmodule. A job
  cannot draw a page, and Calamares would run it as a step with no UI."
  # ...and the JOB that applies what the page decided. Nothing else creates an account: the stock
  # `users` module is gone from this installer, so a missing accountsetup is an install that
  # finishes with an empty /etc/passwd upper and no way in.
  [[ -f $TARGET/usr/share/calamares/local-modules/accountsetup/main.py ]] \
    || die "verify: the accountsetup job is missing. It is the only thing in this installer that
  creates an account, joins a domain or applies an enrolment; without it the install reports
  success and the disk has nothing to log into."
  grep -qE '^[[:space:]]*-[[:space:]]+accountsetup$' "$CAL_SETTINGS" \
    || die "verify: settings.conf's exec sequence does not name accountsetup"
  # The stock users module must NOT be in the sequence. It is still installed — it comes with
  # app-admin/calamares and there is no USE flag that removes it — and naming it would create a
  # second, additive account-creation step whose own AD checkbox contradicts the page's modes.
  grep -qE '^[[:space:]]*-[[:space:]]+users$' "$CAL_SETTINGS" \
    && die "verify: settings.conf names the stock 'users' module, which plan/21 replaced. Two
  account-creation steps would both run, and the stock one's Active Directory checkbox is
  additive by construction (Config.cpp:1088-1104) — exactly the shape the accounts page exists
  to remove."

  # The payload, and the one string that ties it to the boot. Three files have to agree about it:
  # the layout helper CREATES a partition with this label (checked against a real invocation
  # further up, where the helper is installed), disksetup.conf tells the job to REFUSE a layout
  # that did not, and imagedeploy.conf LOOKS for it. They are rendered from the same variable, so
  # this catches an edit that hardcoded one of them.
  #
  # Until plan/24 the first of those three was modules/partition.conf's partitionLayout block. It
  # is gone, along with the module it configured.
  [[ -s $TARGET$PAYLOAD_DIR/root.erofs && -s $TARGET$PAYLOAD_DIR/uki.efi ]] \
    || die "verify: the payload is missing from $PAYLOAD_DIR"
  grep -q "\"root_partlabel\": \"$ROOT_PARTLABEL\"" "$TARGET$PAYLOAD_DIR/manifest.json" \
    || die "verify: manifest.json's root_partlabel is not $ROOT_PARTLABEL"
  [[ ! -e $TARGET/etc/calamares/modules/partition.conf ]] \
    || die "verify: /etc/calamares/modules/partition.conf is on the medium, but the stock
  partition module left the sequence in plan/24. A stale config for a module that later comes back
  under the same name is not inert — see the welcome.conf finding above the rm -rf of /etc/calamares."
  grep -q "\"$ROOT_PARTLABEL\"" "$TARGET/etc/calamares/modules/disksetup.conf" \
    || die "verify: disksetup.conf does not require the layout to create a partition labelled
  $ROOT_PARTLABEL — the initrd's root=PARTLABEL=$ROOT_PARTLABEL would find nothing on the
  installed disk"
  grep -q "$ROOT_PARTLABEL" "$TARGET/etc/calamares/modules/imagedeploy.conf" \
    || die "verify: imagedeploy.conf does not look for $ROOT_PARTLABEL"

  # The autostart entry and the polkit rule are what make this a live INSTALLER rather than a
  # live desktop that happens to have Calamares on it.
  [[ -f $TARGET/etc/xdg/autostart/$DISTRO_ID-installer.desktop ]] \
    || die "verify: the installer autostart entry is missing — nothing would launch Calamares"
  [[ -f $TARGET/etc/polkit-1/rules.d/49-$DISTRO_ID-installer.rules ]] \
    || die "verify: the installer polkit rule is missing — pkexec would prompt for a password"
  # The domain-join path is now the accounts page's third mode, executed by `accountsetup`
  # calling $DISTRO_ID-domain directly (plan/21 §5). Two assertions, both inverses of what stood
  # here while Calamares' own users page owned the feature:
  #
  #   - accounts.conf must OFFER the mode, or the page draws two radio buttons and a machine
  #     nobody can join;
  #   - /usr/bin/realm must be ABSENT, because a file with that name is realmd to everyone who
  #     reads a support answer, and this medium's only implementation is $DISTRO_ID-domain.
  grep -qE '^modes:.*\bdomain\b' "$TARGET/etc/calamares/modules/accounts.conf" \
    || die "verify: accounts.conf's modes: does not offer 'domain', so the installer would have
  no domain-join option at all (plan/18 §7.1, plan/21 §1)"
  [[ ! -e $TARGET/usr/bin/realm ]] \
    || die "verify: /usr/bin/realm is on the medium, but nothing calls it any more — the stock
  users module that hardcoded that name is not in the sequence (plan/21 §5). Leaving a
  realmd-shaped file that is not realmd is worse than having neither."
  [[ -x $TARGET/usr/bin/$DISTRO_ID-domain ]] \
    || die "verify: /usr/bin/$DISTRO_ID-domain is missing, but accounts.conf offers domain mode —
  the join would fail at a command that is not there"
  [[ -x $TARGET/usr/bin/$DISTRO_ID-managed ]] \
    || die "verify: /usr/bin/$DISTRO_ID-managed is missing, but accounts.conf offers managed
  mode — the page could not enrol and Next would never enable (plan/21 §3)"
  grep -qx 'RequirePassword=false' "$TARGET/etc/xdg/kscreenlockerrc" 2>/dev/null \
    || die "verify: /etc/xdg/kscreenlockerrc does not set RequirePassword=false — the live
  session would lock itself after five idle minutes and ask for a password nobody was told to
  expect. Grepped rather than stat'd: the file existing is not the property that matters."
  # The other half of the same file, and it exists BECAUSE the half above leaves Autolock on: the
  # shield engages five minutes into an unattended install, so this greeter is the screen most
  # likely to be facing the room. kscreenlocker does not read the containment's wallpaper — its
  # own fallback chain ends at Breeze's Next, which stage 50 deletes here — so an unset key is a
  # black lock screen on a medium whose desktop has a wallpaper.
  grep -qx "Image=/usr/share/wallpapers/$DISTRO_ID/" "$TARGET/etc/xdg/kscreenlockerrc" 2>/dev/null \
    || die "verify: /etc/xdg/kscreenlockerrc does not point the greeter at
  /usr/share/wallpapers/$DISTRO_ID — the lock screen would draw black behind the unlock UI while
  the desktop behind it has a wallpaper. The key lives in
  [Greeter][Wallpaper][org.kde.image][General], which is the group greeterapp.cpp builds."

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
  # the accounts page rejects every password typed with "The password fails the dictionary check
  # - error loading dictionary", and Next never enables.
  #
  # All three files, not just the dictionary: .pwd is the packed word data, .pwi its index and
  # .hwm the hash-bucket high-water marks, and cracklib opens .pwi and .hwm alongside .pwd.
  # /usr/lib/cracklib_dict is libcrack.so's --with-default-dict path; accounts.conf names no
  # dictpath, so this is the only place libpwquality will look. The page calls pwquality_check()
  # itself now instead of leaving it to Calamares' own users module (plan/21 §2) — same library,
  # same compiled-in dictionary path, same trap.
  for cl_ext in pwd pwi hwm; do
    [[ -s $TARGET/usr/lib/cracklib_dict.$cl_ext ]] \
      || die "verify: /usr/lib/cracklib_dict.$cl_ext is missing or empty — libpwquality would
  reject every password on the installer's accounts page with 'error loading dictionary', and
  Next would never enable"
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
              "usr/share/wallpapers/$DISTRO_ID" \
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
for m in resolve systemd myhostname sss; do
  compgen -G "$TARGET/usr/lib64/libnss_$m.so"* >/dev/null \
    || compgen -G "$TARGET/usr/lib/libnss_$m.so"* >/dev/null \
    || die "verify: /etc/nsswitch.conf uses the $m module but libnss_$m is not installed"
done

# Nothing may still be deferred by CONFIG_PROTECT. Section 1 applies them all before the overlay
# goes down; anything left here is a config update that this build wrote and then shipped without
# — which is invisible in every package audit, because the PACKAGE is installed and correct.
LEFTOVER_CFG="$(find "$TARGET/etc" -name '._cfg????_*' -printf '%P\n' 2>/dev/null | tr '\n' ' ')"
[[ -z ${LEFTOVER_CFG// /} ]] \
  || die "verify: CONFIG_PROTECT files are still pending in the target: $LEFTOVER_CFG
  The image would ship the OLD version of each of these while the VDB records the new package.
  Section 1 should have applied them — did something merge into \$TARGET after it ran?"

# ---- Active Directory readiness (plan/18) ---------------------------------------------------
# Every profile ships @domain, so every profile is checked. Each of these fails silently at
# runtime if it is wrong, which is why they are build failures here.
#
# The NSS half is already covered by the loop above (nsswitch.conf names sss, and libnss_sss must
# therefore exist). What is left is PAM, the units, and the one file a join needs to write into.
grep -qE '^passwd:[[:space:]]+files[[:space:]]+sss[[:space:]]' "$TARGET/etc/nsswitch.conf" \
  || die "verify: nsswitch.conf passwd line does not name the sss module — domain accounts would
  not resolve, and the image cannot be fixed after the fact (there is no Portage on the target)"
# pam_sss comes from sys-auth/pambase[sssd], which GENERATES the stack. Assert the outcome rather
# than the flag: a pambase upgrade that changed the template is exactly the silent regression
# this is here to catch.
for f in system-auth system-login; do
  [[ -f $TARGET/etc/pam.d/$f ]] || die "verify: /etc/pam.d/$f is missing — is sys-auth/pambase installed?"
done
grep -q 'pam_sss\.so' "$TARGET/etc/pam.d/system-auth" \
  || die "verify: /etc/pam.d/system-auth has no pam_sss.so — sys-auth/pambase was built without
  USE=sssd, so no domain user could ever authenticate (config/portage/package.use/image)"
# ...and the converse, which is the one that would lock everyone out of an UNJOINED machine:
# pam_unix must still be reachable.
grep -q 'pam_unix\.so' "$TARGET/etc/pam.d/system-auth" \
  || die "verify: /etc/pam.d/system-auth has no pam_unix.so — local password authentication is
  gone. An unjoined image would have no way to log in at all."
grep -q 'pam_mkhomedir\.so' "$TARGET/etc/pam.d/system-login" \
  || die "verify: pam_mkhomedir is not in the system-login session stack — a domain user would
  log in to a missing home directory"
compgen -G "$TARGET/lib64/security/pam_sss.so" >/dev/null \
  || compgen -G "$TARGET/usr/lib64/security/pam_sss.so" >/dev/null \
  || die "verify: the PAM stack names pam_sss.so but the module is not installed"
compgen -G "$TARGET/lib64/security/pam_mkhomedir.so" >/dev/null \
  || compgen -G "$TARGET/usr/lib64/security/pam_mkhomedir.so" >/dev/null \
  || die "verify: the PAM stack names pam_mkhomedir.so but the module is not installed"
# The join tools themselves. Absent, `<id>-domain join` fails on a machine that cannot install
# them — which is the whole reason @domain is in every profile.
for b in sssd adcli; do
  [[ -x $TARGET/usr/sbin/$b || -x $TARGET/usr/bin/$b ]] \
    || die "verify: $b is in neither /usr/sbin nor /usr/bin — @domain did not deliver the AD
  client (plan/18 §2), and the target cannot install it later"
done
# /etc/krb5.conf ends with `includedir /etc/krb5.conf.d/`, and MIT Kerberos treats a MISSING
# include directory as a hard error ("Included profile directory could not be read") — which
# would break kinit on every unjoined machine. The directory exists because config/rootfs ships
# a README.md in it; assert the pair, since install_rootfs_overlay walks files and an empty
# directory would simply not arrive.
grep -q '^includedir[[:space:]]\+/etc/krb5\.conf\.d/' "$TARGET/etc/krb5.conf" \
  || die "verify: /etc/krb5.conf does not include /etc/krb5.conf.d/"
[[ -d $TARGET/etc/krb5.conf.d ]] \
  || die "verify: /etc/krb5.conf names includedir /etc/krb5.conf.d/ but the directory does not
  exist — MIT Kerberos fails to read any profile at all, so kinit breaks on every machine"
# THE BOOT-INTEGRITY ONE (plan/18 §5.1). sssd must not be enabled on an image that has never been
# joined: it exits non-zero with no sssd.conf, systemd-boot-check-no-failures gates
# boot-complete.target, and a failed boot burns a try and eventually rolls the machine back. The
# glob catches responder units the preset does not name by hand — and winbind*, which is not a
# responder at all but arrives with net-fs/samba[winbind] because sys-auth/sssd[samba] demands it.
# This image installs two domain clients and runs one; a `sssd*` glob alone would have let the
# other one boot.
SSSD_ENABLED="$(find "$TARGET/etc/systemd/system" \( -name 'sssd*' -o -name 'winbind*' \) \
  -printf '%P\n' 2>/dev/null | tr '\n' ' ')"
[[ -z ${SSSD_ENABLED// /} ]] \
  || die "verify: domain units are ENABLED in the image: $SSSD_ENABLED
  On an unjoined machine sssd exits non-zero, which fails boot-complete.target and burns a boot
  try — three of those roll the machine back to the previous image (plan/18 §5.1). Add a
  \`disable\` line for each to config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in."
[[ -f $TARGET/usr/lib/systemd/system/sssd.service.d/10-conditional.conf ]] \
  || die "verify: the sssd.service ConditionPathExists drop-in is missing — the second of the two
  independent defences in plan/18 §5.1"
[[ -x $TARGET/usr/bin/${DISTRO_ID}-domain ]] \
  || die "verify: /usr/bin/${DISTRO_ID}-domain is missing or not executable — there would be no
  way to join a domain on an image that cannot install one"
# The provider module the generated sssd.conf names. `sssctl config-check` above validates the
# file's SYNTAX and says nothing about whether the back end it names can be loaded: sssd's
# providers are dlopen()ed plugins, and the AD one is built only under sys-auth/sssd[samba].
# Built without it, everything here passed, the domain join SUCCEEDED, and sssd then died on
# "Unable to load module [ad] ... libsss_ad.so: cannot open shared object file". Checked twice —
# here, and again after the prune in stage 50.
# Rendered ONCE into a variable, for the SIGPIPE/pipefail reason documented at the lsinitrd and
# objdump checks above: `... | sed | head -1` lets head exit first, sed dies of SIGPIPE, and the
# pipeline reports 141 — which under `set -e` aborts the stage before the die below can say why.
# --computer-name is pinned, unlike the config-check call in section 2: this runs AFTER
# target_umount, so /proc is no longer mounted in the chroot and the CLI's hostname fallback
# (/proc/sys/kernel/hostname, since this image ships no /etc/hostname — the name is derived at
# first boot) has nothing to read. The name is irrelevant to which provider the config names.
SSSD_SAMPLE="$(chroot_target "$TARGET" \
  "${DISTRO_ID}-domain join --domain validate.invalid --user check \
     --computer-name VERIFYCHECK --print-config sssd" 2>/dev/null || true)"
SSSD_PROVIDER="$(sed -n 's/^[[:space:]]*id_provider[[:space:]]*=[[:space:]]*\([a-z0-9_]\{1,\}\).*/\1/p' \
  <<<"$SSSD_SAMPLE" | tail -1)"
[[ -n $SSSD_PROVIDER ]] || die "verify: could not read id_provider from ${DISTRO_ID}-domain"
[[ -e $TARGET/usr/lib64/sssd/libsss_$SSSD_PROVIDER.so \
   || -e $TARGET/usr/lib/sssd/libsss_$SSSD_PROVIDER.so ]] \
  || die "verify: sssd.conf says id_provider = $SSSD_PROVIDER but libsss_$SSSD_PROVIDER.so is not
  installed. sssd dlopen()s that module by name and exits when it is missing — after a join that
  otherwise succeeds. The AD provider is built ONLY with sys-auth/sssd[samba]; check that flag in
  config/portage/package.use/image."
# ---- managed mode readiness (plan/19 §12) ---------------------------------------------------
# Managed mode costs no packages, so almost nothing about it is observable until someone enrols
# — which makes every check here a build failure rather than a runtime surprise on a machine
# that cannot install anything.
#
# THE ONE THAT THE WHOLE FEATURE RESTS ON. Authentication for a managed user is one NSS symbol in
# one shared object: nss-systemd's shadow interface, reached through /etc/nsswitch.conf's
# `shadow: files systemd` line. Same class of check as plan/18 §5.4's libsss_<provider>.so
# assertion and for the same reason — the module being installed and the module being able to
# serve what the config names are two different questions.
grep -qE '^shadow:[[:space:]]+files[[:space:]]+systemd[[:space:]]*$' "$TARGET/etc/nsswitch.conf" \
  || die "verify: nsswitch.conf's shadow line does not end in the systemd module. Managed users
  authenticate through pam_unix reading a shadow entry that nss-systemd synthesises from
  /etc/userdb; without this line they resolve, appear on the greeter, and cannot log in."
NSS_SYSTEMD_SO="$(compgen -G "$TARGET/usr/lib64/libnss_systemd.so"* || compgen -G "$TARGET/lib64/libnss_systemd.so"* || true)"
[[ -n $NSS_SYSTEMD_SO ]] \
  || die "verify: /etc/nsswitch.conf names the systemd module but libnss_systemd.so is not
  installed — managed mode has no identity mechanism at all"
# Rendered ONCE into a variable rather than piped into `grep -q`, for the SIGPIPE/pipefail
# reason documented at the lsinitrd and objdump checks above: grep -q exits at the first match,
# the producer dies of SIGPIPE, and the pipeline reports 141 — which here would be read as "the
# symbol is missing" and would fail the build on a perfectly good image.
NSS_SYMS="$(nm -D --defined-only "${NSS_SYSTEMD_SO%% *}" 2>/dev/null \
            || readelf -sW --dyn-syms "${NSS_SYSTEMD_SO%% *}" 2>/dev/null || true)"
for sym in _nss_systemd_getspnam_r _nss_systemd_getpwnam_r; do
  # The whole authentication path is this symbol. A systemd built without the shadow half of
  # nss-systemd installs cleanly, resolves users, and silently cannot verify a password.
  [[ $NSS_SYMS == *"$sym"* ]] \
    || die "verify: ${NSS_SYSTEMD_SO%% *} does not export $sym. nss-systemd cannot serve the
  shadow entry pam_unix checks a managed user's password against (plan/19 §2.2)."
done
# /etc/userdb must NOT be in the image (T-MAN-5). Enrolment creates it; shipping it — even
# empty — would put a directory in the read-only lower that the /etc overlay then has to shadow.
[[ ! -e $TARGET/etc/userdb ]] \
  || die "verify: /etc/userdb exists in the built image. It is created by enrolment, and an
  image that has never enrolled must not have one (plan/19 §3, T-MAN-5)."
# The client, the units, the keyring and the front end. None can be added later: there is no
# Portage on the target and /usr is read-only.
[[ -x $TARGET/usr/bin/${DISTRO_ID}-managed ]] \
  || die "verify: /usr/bin/${DISTRO_ID}-managed is missing or not executable — there would be no
  way to enrol an image that cannot install one"
chroot_target "$TARGET" "python3 -c 'import ast,sys; ast.parse(open(\"/usr/bin/${DISTRO_ID}-managed\").read())'" \
  || die "verify: /usr/bin/${DISTRO_ID}-managed does not parse as Python on the TARGET's own
  interpreter. The offline suite compiles it with the build host's python; this is the one that
  will actually run it."
for u in ${DISTRO_ID}-managed-sync.service ${DISTRO_ID}-managed-sync.timer; do
  [[ -f $TARGET/usr/lib/systemd/system/$u ]] \
    || die "verify: /usr/lib/systemd/system/$u is missing. Units cannot be created by a machine
  that must not edit /usr (plan/19 §3)."
done
MANAGED_DROPIN="$TARGET/usr/lib/systemd/system/${DISTRO_ID}-managed-sync.service.d/10-conditional.conf"
[[ -f $MANAGED_DROPIN ]] \
  || die "verify: the sync service's ConditionPathExists drop-in is missing — the second of the
  three independent defences in plan/19 §8.1"
grep -qx "ConditionPathExists=/var/lib/${DISTRO_ID}/managed/enrollment.json" "$MANAGED_DROPIN" \
  || die "verify: $MANAGED_DROPIN does not carry the rendered enrollment.json path. A Condition
  naming a path nothing ever writes makes the unit skip forever; one naming the wrong distro id
  makes it run on an unenrolled machine. Neither says anything at runtime."
[[ -s $TARGET/usr/lib/$DISTRO_ID/managed-pubring.gpg ]] \
  || die "verify: /usr/lib/$DISTRO_ID/managed-pubring.gpg is missing or empty — no policy bundle
  could ever be verified, and the trust anchor cannot be added after the image is built"
# THE BOOT-INTEGRITY ONE (plan/19 §8.1), exactly as for sssd above: a timer enabled on an image
# that has never enrolled runs a sync that has nothing to sync, and any non-zero exit from it is
# a failed boot and, on the third, a rollback.
MANAGED_ENABLED="$(find "$TARGET/etc/systemd/system" -name "${DISTRO_ID}-managed*" \
  -printf '%P\n' 2>/dev/null | tr '\n' ' ')"
[[ -z ${MANAGED_ENABLED// /} ]] \
  || die "verify: managed-mode units are ENABLED in the image: $MANAGED_ENABLED
  Add a \`disable\` line for each to config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in."
# The front end §7.2 measured as possible. Each half fails silently without the other: a wrapper
# with no QML shows nothing, and QML with no qml6 is a file nobody can open.
#
# ...on a medium somebody keeps. On a live one the assertion runs the other way: section 1
# deletes all three files right after install_rootfs_overlay, so what is checked here is that
# the deletion actually matched. It is the only thing that would notice a rename — the overlay
# would keep installing the front end under a new basename and the removal would keep silently
# matching nothing, which is precisely how "Managed Settings" reached a live medium the set
# marker was already excluding.
if [[ $PROFILE_ROLE == live ]]; then
  MANAGED_UI_LEFT=""
  for f in "usr/bin/${DISTRO_ID}-managed-ui" \
           "usr/share/applications/${DISTRO_ID}-managed-ui.desktop" \
           "usr/share/$DISTRO_ID/managed-ui"; do
    [[ -e $TARGET/$f ]] && MANAGED_UI_LEFT+=" /$f"
  done
  [[ -z ${MANAGED_UI_LEFT// /} ]] \
    || die "verify: the managed-mode front end is on a PROFILE_ROLE=$PROFILE_ROLE medium:$MANAGED_UI_LEFT
  A live session enrols nothing, so this is a Settings entry that can only ever say 'not
  enrolled' (plan/20 §2.2). It ships from config/rootfs rather than from a package, so no set
  marker can drop it — check the removal in section 1 of this stage against the paths above."
  log "live profile ($BUILD_PROFILE): the managed-mode front end is deliberately absent"
else
  [[ -x $TARGET/usr/bin/${DISTRO_ID}-managed-ui ]] \
    || die "verify: /usr/bin/${DISTRO_ID}-managed-ui is missing or not executable"
  [[ -f $TARGET/usr/share/$DISTRO_ID/managed-ui/main.qml ]] \
    || die "verify: /usr/share/$DISTRO_ID/managed-ui/main.qml is missing. install_rootfs_overlay
  rebrands the 'distro' segment in DIRECTORY names too (render_dest_dir); if this is absent,
  check whether it landed at /usr/share/distro/ instead."
fi
[[ -f $TARGET/usr/share/polkit-1/actions/org.$DISTRO_ID.managed.policy ]] \
  || die "verify: the managed-mode polkit action file is missing — the QML front end would have
  to be setuid or run under sudo to change anything"
[[ -x $TARGET/usr/lib/NetworkManager/dispatcher.d/50-$DISTRO_ID-managed ]] \
  || die "verify: the NetworkManager dispatcher hook is missing or not executable. NetworkManager
  silently skips a non-executable dispatcher script, so sync-on-connect would never fire and
  nothing would say why."
# Only where the front end above survived: on a live medium qml6 has no managed-mode caller,
# and demanding it there would fail a build over a dependency of something this profile just
# deleted on purpose.
if [[ $PROFILE_ROLE != live ]] && profile_has_set desktop; then
  [[ -x $TARGET/usr/bin/qml6 ]] \
    || die "verify: /usr/bin/qml6 is not in the image, so the pure-QML managed front end cannot
  run. plan/19 §7.2 rests on it shipping; if dev-qt/qtdeclarative stopped installing it, the
  front end needs a compiled plugin and that is a design change, not a build fix."
fi
# /etc/shadow's mode and group are load-bearing for managed mode, not just for local accounts:
# .user-privileged is written 0640 root:shadow because unix_chkpwd is setgid shadow, and that is
# the ONLY way an unprivileged PAM caller — the screen locker — can verify a managed user's
# password (plan/19 §2.3, settled by probe). If the group ever went away, managed users would log
# in at the greeter and be unable to unlock their own screens.
MANAGED_SHADOW_GROUP="$(grep -c '^shadow:' "$TARGET/etc/group" || true)"
[[ ${MANAGED_SHADOW_GROUP:-0} -ge 1 ]] \
  || die "verify: there is no 'shadow' group in the image. Managed mode writes password hashes
  0640 root:shadow so that setgid-shadow unix_chkpwd can read them for an unprivileged caller."
SHADOW_MODE="$(stat -c '%a %U:%G' "$TARGET/etc/shadow" 2>/dev/null || true)"
[[ $SHADOW_MODE == "640 root:shadow" ]] \
  || warn "/etc/shadow is '$SHADOW_MODE', not '640 root:shadow'. Managed mode mirrors that mode
  for its own hashes; if the vendor changed it, plan/19 §2.3 should be re-measured."

# ---- managed mode, Phase D: the two compiled surfaces (plan/19 §7.2, §7.3) ------------------
# Both come from config/portage/overlay and reach an image only through a re-resolved lock, so
# neither is asserted into existence — a build that has not been relocked yet must still produce
# a working image. What IS asserted is that a package which DID install put its files where the
# thing that loads them looks, because in both cases the failure is silent: System Settings shows
# no module, and Calamares drops a step, and neither says a word.
MANAGED_KCM="$(compgen -G "$TARGET/usr/lib*/qt6/plugins/plasma/kcms/systemsettings/kcm_managed.so" || true)"
if [[ -n $MANAGED_KCM ]]; then
  # A Plasma 6 KCM carries its metadata INSIDE the plugin; there is no .desktop to read it from
  # any more. An empty or missing KPlugin block gives a module System Settings can load and
  # cannot name, so it appears as a blank row.
  # Rendered ONCE into a variable, not piped into `grep -q` — the same SIGPIPE/pipefail trap
  # documented at the lsinitrd, objdump and nss-systemd checks above, and this assertion was
  # written with the bug rather than against it. `strings` on a 50 KB plugin produces far more
  # output than grep -q needs: grep exits at the first of the twelve KPlugin hits, strings dies
  # of SIGPIPE, and the pipeline yields 141. Under `set -o pipefail` that reads as "no metadata"
  # and fails the build on a correct image — CONFIRMED, this is exactly how it first failed, on
  # a plugin whose metadata was intact.
  KCM_STRINGS="$(strings -- "${MANAGED_KCM%% *}" 2>/dev/null || true)"
  [[ $KCM_STRINGS == *KPlugin* ]] \
    || die "verify: kcm_managed.so carries no KPlugin metadata. System Settings reads the name,
  icon and category out of the plugin itself (Plasma 6 has no .desktop for KCMs), so this module
  would appear as an unnamed row or not at all."
  # kcmutils_generate_desktop_file writes this, and it is what makes the module findable by
  # SEARCH rather than only by browsing to its category.
  compgen -G "$TARGET/usr/share/applications/kcm_managed.desktop" >/dev/null \
    || warn "kcm_managed.so is installed but /usr/share/applications/kcm_managed.desktop is not.
  The module will be in System Settings and will not come up when someone searches for it."
  log "managed mode: the System Settings module is installed"
elif [[ $PROFILE_ROLE == live ]]; then
  # Not a warning here, and not an omission either: on a live medium the module is absent ON
  # PURPOSE (plan/20). It is marked `#not-live` in config/portage/sets/desktop, so filter_set_file
  # drops it before the set is ever emerged — a live session enrols nothing, so a "which policy
  # is applied?" page would answer "not enrolled" for twenty minutes and then be thrown away
  # with the stick. The Calamares enrolment page, which is the half a live medium DOES need, is
  # checked separately above.
  log "live profile ($BUILD_PROFILE): the managed System Settings module is deliberately absent"
elif profile_has_set desktop; then
  warn "the managed-mode System Settings module is not installed (plan/19 §7.2, Phase D).
  The QML app at /usr/bin/${DISTRO_ID}-managed-ui still works and is in the launcher. The KCM
  comes from ${DISTRO_ID}-base/${DISTRO_ID}-kcm-managed in config/portage/overlay, which reaches
  an image only through a re-resolved lock:
      scripts/relock.sh ${DISTRO_ID}-base/${DISTRO_ID}-kcm-managed --profile $BUILD_PROFILE"
fi

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
# config/languages.conf is in this list for the same argument one layer up: it is the source of
# /etc/locale.gen, of language.conf's rendered list and of which .ts files get compiled, and a row
# added to it leaves no other trace stage 40 could notice. Without it, adding a language would
# report success and produce a medium that still offers the old list (plan/22 §2b).
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" \
  "$REPO/config/languages.conf" \
  "$REPO/config/prune-firmware.txt" "$REPO/config/prune-microcode.txt" \
  "$REPO/config/dracut-omit-drivers.txt" \
  "$REPO/config/splash/splash.c" "$REPO/config/branding/make-splash-assets.py" \
  "$REPO/scripts/lib/check-translations.py" \
  "${CAL_INPUTS[@]}")"
