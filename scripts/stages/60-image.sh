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

require_cmds mkfs.erofs dump.erofs mkfs.ext4 mkfs.vfat mmd mcopy sfdisk dd truncate zstd rsync tar debugfs

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
# Ownership comes from the staging tree. This used to pass --all-root, and it must not again.
#
# --all-root forces every inode to uid 0 AND gid 0. The gid half is the damage: twenty paths in
# the root tree are owned root:<group> and MEAN it — there, the group IS the permission.
#
#   /usr/libexec/dbus-daemon-launch-helper  ---s--x---  root:messagebus
#   /usr/bin/unix_chkpwd                    -rwxr-sr-x  root:shadow
#   /etc/polkit-1/rules.d                   drwx------  polkitd:polkitd
#   ...plus chage, expiry, utempter (utmp), nvidia-modprobe (video), /etc/cups (lp)
#
# Flattened to root:root, each silently loses the access it exists to grant:
#
#  - dbus-daemon runs as messagebus. Its setuid launch helper is mode 4710 — owner root, group
#    messagebus, OTHER NOTHING — so as root:root it is unexecutable by the one process that ever
#    execs it, and every DBus-ACTIVATED system service dies with "Failed to execute program
#    <name>: Permission denied". Measured in the guest: this is what emptied Calamares' disk
#    picker. KPMcore enumerates disks by having its activated helper run lsblk; activation
#    failed, the scan returned zero devices, and the page drew an empty combo box with no error
#    on screen and nothing in Calamares' own log.
#  - polkitd runs as uid 102 under NoNewPrivileges with no CAP_DAC_OVERRIDE, so a 0700 rules.d
#    owned by root is unreadable to it: EVERY .rules file in the image is silently ignored,
#    including 49-wheel.rules and the installer's own no-password rule.
#  - unix_chkpwd loses gid shadow, so PAM cannot verify a password for a non-root caller.
#
# Nothing ever needed the flag: the tree is built by portage as root inside the container, and
# the only non-root ownership in it is portage's own (asserted below — there is no host uid to
# scrub). Reproducibility comes from -T and the pinned tree, not from erasing ownership.
mkfs.erofs -z "$EROFS_COMPRESSION" -T"$SOURCE_DATE_EPOCH" "$ROOT_EROFS" "$ROOT_STAGE"

# Negative control for the note above: every path that is not root:root in the staging tree must
# still not be root:root in the image. It reads the BUILT image rather than the tree it came
# from, which is the point — it catches mkfs doing something other than what the tree says.
# Restore --all-root and the first path checked here fails.
own_checked=0
while read -r want_uid want_gid path; do
  info="$(dump.erofs --path="/$path" "$ROOT_EROFS" 2>/dev/null)" \
    || die "ownership check: /$path is in the staging tree but absent from the EROFS"
  got_uid="$(sed -n 's/^Uid: *\([0-9]\{1,\}\).*/\1/p' <<<"$info")"
  got_gid="$(sed -n 's/^Uid:.*Gid: *\([0-9]\{1,\}\).*/\1/p' <<<"$info")"
  [[ $got_uid == "$want_uid" && $got_gid == "$want_gid" ]] || die \
"ownership lost in the image: /$path is ${want_uid}:${want_gid} in the staging tree but
  ${got_uid}:${got_gid} in the EROFS. Something is flattening ownership — historically
  mkfs.erofs --all-root. See the note above the mkfs.erofs call."
  own_checked=$((own_checked + 1))
done < <(cd "$ROOT_STAGE" && find . \( ! -uid 0 -o ! -gid 0 \) -printf '%U %G %P\n')
# A tree with NO group-owned paths means the ownership was destroyed upstream of here (or the
# find stopped working), not that there was nothing to protect. Either way the check above
# proved nothing, so say so rather than passing silently.
(( own_checked > 0 )) \
  || die "ownership check found no non-root paths in $ROOT_STAGE — expected at least
  /usr/libexec/dbus-daemon-launch-helper (root:messagebus). Ownership is being flattened
  before stage 60, or the staging copy is not preserving it."
log "ownership: $own_checked non-root path(s) preserved into the EROFS"

# ---- file capabilities, which are the same class of bug one metadata field over -------------
# sys-auth/sssd (plan/18) is the first package in this image whose correctness depends on POSIX
# file capabilities rather than on ownership:
#
#   usr/libexec/sssd/ldap_child   cap_dac_read_search=p
#   usr/libexec/sssd/krb5_child   cap_dac_read_search,cap_setuid,cap_setgid=p
#   usr/libexec/sssd/sssd_pam     cap_dac_read_search=p
#
# cap_dac_read_search is how those helpers read /etc/krb5.keytab — 0600 root:root — while running
# as the unprivileged sssd user. Lose it and authentication fails with a permission error nowhere
# near the cause, which is the shape of every other bug this stage asserts against.
#
# Two places it can be lost, and they fail differently, so both halves are checked:
#
#  1. PORTAGE MAY NEVER HAVE SET IT. fcaps.eclass is not obviously safe under ROOT=$TARGET, and
#     this pipeline has been bitten by exactly that assumption before: sys-libs/cracklib's
#     pkg_postinst is guarded on `[[ -z ${ROOT} ]]` and had never run in this project's history
#     (plan/16). getcap on the staging tree is that half.
#  2. THE IMAGE FORMAT MAY DROP IT. rsync carries xattrs (-X above), but mkfs.erofs is where
#     --all-root ate ownership, so this reads the BUILT image like the ownership check does.
#
# The image half asks dump.erofs for the inode's Xattr size rather than for the capability
# itself, and that is a deliberate second choice: dump.erofs cannot print xattr VALUES, and
# fsck.erofs --extract — the only other way in — silently declines to restore security.* xattrs,
# so extracting and running getcap reports "no capability" on an image that has one. Measured, on
# a two-file probe: a file with a capability gives `Xattr size: 48` and one without gives 0, and
# `mkfs.erofs -x-1` (xattrs disabled) drops the first to 0. Portage sets no user.* xattrs on
# these paths, so on a binary whose staging copy has exactly one xattr — the capability, proved
# by getcap in half 1 — a non-zero Xattr size in the image is that capability and nothing else.
SSSD_CAP_PATHS=(usr/libexec/sssd/ldap_child usr/libexec/sssd/krb5_child usr/libexec/sssd/sssd_pam)
cap_checked=0
for cp in "${SSSD_CAP_PATHS[@]}"; do
  [[ -e $ROOT_STAGE/$cp ]] || continue
  getcap "$ROOT_STAGE/$cp" | grep -q 'cap_dac_read_search' || die \
"file capability missing: /$cp has no cap_dac_read_search in the staging tree.
  sssd's helpers run as the sssd user and read /etc/krb5.keytab (0600 root:root) through that
  capability, so a domain login fails with a permission error that names neither. The ebuild
  sets it through fcaps.eclass; if that eclass skips ROOT=\$TARGET merges the way cracklib's
  pkg_postinst does, this becomes a stage-40 chroot finalizer (setcap), exactly as the cracklib
  dictionary did."
  cap_xattr="$(dump.erofs --path="/$cp" "$ROOT_EROFS" 2>/dev/null \
    | sed -n 's/.*Xattr size: *\([0-9]\{1,\}\).*/\1/p')"
  [[ ${cap_xattr:-0} -gt 0 ]] || die \
"file capability lost in the image: /$cp carries cap_dac_read_search in the staging tree but its
  EROFS inode has Xattr size ${cap_xattr:-none}. Something is dropping extended attributes
  between rsync and mkfs.erofs — the capability equivalent of --all-root."
  cap_checked=$((cap_checked + 1))
done
# Same non-vacuity guard as the ownership check above: @domain is in every profile, so finding
# none of these means the check proved nothing rather than that there was nothing to protect.
(( cap_checked > 0 )) || die "capability check found no sssd helpers in $ROOT_STAGE — @domain is
  named by every profile (config/profiles/README.md), so this check ran against nothing"
log "capabilities: $cap_checked sssd helper(s) preserved into the EROFS"

root_bytes="$(stat -c%s "$ROOT_EROFS")"
slot_bytes="$((ROOT_SLOT_SIZE_MIB * 1024 * 1024))"
(( root_bytes <= slot_bytes )) \
  || die "root image ($((root_bytes/1024/1024)) MiB) exceeds slot size (${ROOT_SLOT_SIZE_MIB} MiB)"
log "root erofs: $((root_bytes/1024/1024)) MiB of ${ROOT_SLOT_SIZE_MIB} MiB slot"

# ---- verify: the BUILT EROFS carries neither the live user nor its autologin (plan/34 §5) ----
# `dump.erofs --cat --path=X` reads a single file straight out of the image with no extraction
# and no mount — cheap enough to run here even though $ROOT_EROFS can be several GiB. stage 40
# already asserted this of $TARGET/etc, which rsync (above, --exclude '/var/*' only — no /etc
# special-casing) copied here verbatim; this is the same fact checked on the artifact that
# actually ships, one rsync+mkfs.erofs away from what stage 40 saw.
#
# POSITIVE CONTROL FIRST, and this is not decoration: both checks below assert ABSENCE, and a
# `dump.erofs --cat` that fails outright — wrong --path syntax, a corrupted image, a future
# fsck.erofs that changes its error-reporting shape — prints NOTHING to stdout, which is
# BYTE-IDENTICAL to the passing case. A silent tool failure would make both `die`s below
# unreachable and the build would report success having checked nothing. Reading a file that
# MUST exist and MUST match proves the tool can read this image at this path syntax before
# either negative assertion is trusted.
ROOT_PASSWD_PROBE="$(dump.erofs --cat --path=/etc/passwd "$ROOT_EROFS" 2>/dev/null)"
grep -qE '^root:' <<<"$ROOT_PASSWD_PROBE" \
  || die "verify: dump.erofs --cat --path=/etc/passwd $ROOT_EROFS produced no 'root:' line —
the tool, the image or the --path syntax is broken, and the live-user/autologin checks right
after this one would otherwise pass on that same silence."
grep -qE "^${LIVE_USER}:" <<<"$ROOT_PASSWD_PROBE" \
  && die "verify: $ROOT_EROFS's /etc/passwd has a $LIVE_USER entry — an installed disk is this EROFS,
byte for byte (plan/34 §2), and would ship it."
if [[ -n "$(dump.erofs --cat --path=/etc/plasmalogin.conf.d/10-autologin.conf "$ROOT_EROFS" 2>/dev/null)" ]]; then
  die "verify: $ROOT_EROFS carries /etc/plasmalogin.conf.d/10-autologin.conf — it must only ever
be in the /etc overlay's upper (plan/34 §5)."
fi
log "root erofs: verified no $LIVE_USER and no 10-autologin.conf in the lower"

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
#
# --exclude the live seed (plan/34 §5): overlay/etc/upper/* is stage 40's live-account swap (the
# directory itself stays, empty, so the installer's own useradd has somewhere to write) and
# home/$LIVE_USER is the live user's own home. Both are THIS build's own live view, seeded fresh
# for every boot of THIS image — never something a machine installed FROM this tarball should
# inherit. Before this, an installed disk's fresh /var could carry a stale live:x:1000: account
# and its published password by way of the very tarball meant to seed a clean install.
if [[ $PROFILE_ROLE == target ]]; then
  VAR_TAR="$OUT/$VAR_TEMPLATE_NAME"
  log "var template: packing $VAR_STAGE -> ${VAR_TAR#"$OUT"/}"
  tar --create --directory="$VAR_STAGE" \
      --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
      --exclude="./overlay/etc/upper/*" --exclude="./home/$LIVE_USER" \
      --xattrs --acls . \
    | zstd -T0 -3 -q -o "$VAR_TAR.tmp"
  mv -f -- "$VAR_TAR.tmp" "$VAR_TAR"
  log "var template: $(du -m "$VAR_TAR" | cut -f1) MiB compressed"

  # ---- verify: the tarball that seeds an installed disk carries neither (plan/34 §5) ----------
  # --list only (no extraction of the ~GiB Flatpak store inside): the exclude above should leave
  # no member under overlay/etc/upper/ or home/$LIVE_USER at all, so a listing is enough.
  #
  # POSITIVE CONTROL: `tar --list` on a truncated write or a corrupted archive can exit non-zero
  # with partial or empty output — uncaught here, since the pipeline below only pipes the
  # variable through `grep`, never checks tar's own exit status. Empty output is indistinguishable
  # from "correctly excluded", so both `die`s after this would go silently unreachable on exactly
  # the archive most worth catching. `./overlay/etc/work` is unconditional (ensure_dir above,
  # every var template) and proves the listing itself succeeded before either negative check runs.
  TAR_MEMBERS="$(tar --list --zstd --file="$VAR_TAR")"
  grep -qF './overlay/etc/work' <<<"$TAR_MEMBERS" \
    || die "verify: tar --list $VAR_TAR does not show ./overlay/etc/work, which every var
  template unconditionally carries — the listing itself failed (or the archive is corrupt), and
  the overlay/etc/upper and home/\$LIVE_USER checks right after this one would otherwise pass on
  that same silence."
  grep -q '^\./overlay/etc/upper/.' <<<"$TAR_MEMBERS" \
    && die "verify: $VAR_TAR still carries a file under overlay/etc/upper/ — the --exclude above
  did not take, and an installed disk's fresh /var would inherit this build's own live account."
  grep -qE "^\./home/${LIVE_USER}(/|\$)" <<<"$TAR_MEMBERS" \
    && die "verify: $VAR_TAR still carries home/$LIVE_USER — the --exclude above did not take."
  log "var template: verified neither overlay/etc/upper/* nor home/$LIVE_USER is packed"
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

# ---- verify: the BUILT var image, not $VAR_STAGE (plan/34 §5, plan/16's --all-root lesson) ----
# This is what actually boots — dd'd desktop.img and console.img, and this build's own live
# medium — so it is read back rather than trusted from the staging tree it was built from.
# debugfs, not a mount: stage 60 stays loopless (module header, above). `cat`/`ls` against a
# missing path both exit 0 and print nothing to stdout (an error goes to stderr instead), so
# checking stdout content is the right test either way.
debugfs -R "cat /overlay/etc/upper/passwd" "$VAR_IMG" 2>/dev/null | grep -qE "^${LIVE_USER}:" \
  || die "verify: $VAR_IMG's overlay/etc/upper/passwd has no $LIVE_USER entry — desktop.img and
console.img would boot with no live user to autologin as (plan/34 §5)."
[[ -n "$(debugfs -R "cat /overlay/etc/upper/plasmalogin.conf.d/10-autologin.conf" "$VAR_IMG" 2>/dev/null)" ]] \
  || die "verify: $VAR_IMG has no overlay/etc/upper/plasmalogin.conf.d/10-autologin.conf."
log "var image: verified $LIVE_USER and the autologin drop-in are both in the built var.img"

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
# By role (plan/33 §2): a live image's own partitions carry live_esp/live_root_<v>/live_var, so
# that booting it on a machine that already has this distro installed — keep mode's whole
# scenario — cannot resolve a by-partlabel symlink to the wrong disk. A target image's names are
# unchanged (esp/root_<v>/var), so the desktop and console outputs are byte-identical to before.
emit_sfdisk_script "$VERSION" "$PROFILE_ROLE" | sfdisk --quiet "$IMG"

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
# The names actually written, not just the names asked for — emit_sfdisk_script takes ROLE
# through a default argument, and a default silently reverting to "target" is exactly the kind
# of drift that would leave a live medium's disk carrying the installed-system identity labels
# again (plan/33 §2), invisibly: sfdisk --verify above passes on either set of strings.
IMG_DUMP="$(sfdisk --dump "$IMG")"
grep -qF "name=\"$IMG_ROOT_PARTLABEL\"" <<<"$IMG_DUMP" \
  || die "verify: the image's partition table does not name $IMG_ROOT_PARTLABEL"
grep -qF "name=\"$IMG_VAR_PARTLABEL\"" <<<"$IMG_DUMP" \
  || die "verify: the image's partition table does not name $IMG_VAR_PARTLABEL"
# EROFS superblock magic (little-endian e2 e1 f5 e0) at offset 1024 inside p2
magic="$(dd if="$IMG" bs=1 skip=$(( ROOT_A_START_MIB*1024*1024 + 1024 )) count=4 status=none | od -An -tx1 | tr -d ' \n')"
[[ $magic == e2e1f5e0 ]] || die "verify: EROFS magic not found in root slot (got: $magic)"
# FAT boot sector jump instruction at p1 start
fatb="$(dd if="$IMG" bs=1 skip=$(( ESP_START_MIB*1024*1024 )) count=1 status=none | od -An -tx1 | tr -d ' \n')"
[[ $fatb == eb || $fatb == e9 ]] || die "verify: no FAT boot sector at ESP offset (got: $fatb)"
log "image OK: $IMG ($(du -m "$IMG.zst" | cut -f1) MiB compressed)"
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf")"
