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
# The live role builds its own UKI HERE (plan/34 §8 — a re-wrap of the desktop's), so there is
# nothing at $UKI_DIR/$UKI_NAME yet when this stage starts; every other role still needs stage
# 40 to have produced one first.
if [[ $PROFILE_ROLE != live ]]; then
  [[ -s $UKI_DIR/$UKI_NAME ]] || die "UKI missing — run stage 40"
else
  [[ -s $PAYLOAD_UKI ]] || die "installer: the base profile's UKI is missing: $PAYLOAD_UKI
  Build the base profile first:  scripts/build.sh --profile $BASE_PROFILE"
fi

require_cmds mkfs.erofs dump.erofs mkfs.ext4 mkfs.vfat mmd mcopy sfdisk dd truncate zstd rsync tar debugfs objcopy fsck.erofs python3 objdump cmp

STAGING="$WORK/staging"; rm -rf -- "$STAGING"; ensure_dir "$STAGING"
IMG="$OUT/$IMG_NAME"

# ---- 1. root EROFS (target minus /var payload; /var itself stays as a mountpoint) ---
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
#
# Computed unconditionally, live role included: the target-role var-tar packing below (2a) uses
# it too, and it costs nothing to have ready.
if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
  SOURCE_DATE_EPOCH="$(date -u -d "${SNAPSHOT_DATE:0:4}-${SNAPSHOT_DATE:4:2}-${SNAPSHOT_DATE:6:2}" +%s)" \
    || die "could not derive a build timestamp from SNAPSHOT_DATE=$SNAPSHOT_DATE"
fi
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ && $SOURCE_DATE_EPOCH -gt 0 ]] \
  || die "SOURCE_DATE_EPOCH must be a positive integer, got '${SOURCE_DATE_EPOCH}' — a zero mtime
on /etc is what stops Plasma Login Manager reading its config at all (see the note above)"
log "erofs timestamp: $SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC'))"

if [[ $PROFILE_ROLE == live ]]; then
  # plan/34 §7.2 step 1: the live role stops building an EROFS of its own tree entirely. The
  # root partition is the DESKTOP's own released artifact, byte for byte (plan/34 §2) — dd'd
  # in section 4 below, never rebuilt here. What this section does instead is extract that
  # artifact (for tree-delta.py, next) and confirm it really is this VERSION's own build: "the
  # release artifact, not /work/target, which another clone may have rebuilt" (two clones share
  # the build volumes — see the memory note on that).
  BASE_EXTRACT="$STAGING/base"
  ensure_dir "$BASE_EXTRACT"
  fsck.erofs --extract="$BASE_EXTRACT" --preserve --overwrite -- "$PAYLOAD_ROOT_EROFS" >/dev/null \
    || die "installer: could not extract $BASE_PROFILE's root.erofs ($PAYLOAD_ROOT_EROFS) for
  the tree-delta comparison"
  grep -q "VERSION_ID=$VERSION" "$BASE_EXTRACT/etc/os-release" \
    || die "installer: $PAYLOAD_ROOT_EROFS's own /etc/os-release does not say VERSION_ID=$VERSION
  — it was built at a different VERSION (or by the other clone sharing this build volume; see
  the memory note on that) and is not the release this build is assembling"
  ROOT_EROFS="$PAYLOAD_ROOT_EROFS"
  root_bytes="$(stat -c%s "$ROOT_EROFS")"
  # Sized from its own contents, not from ROOT_SLOT_SIZE_MIB (plan/34 §7.2 step 5): the
  # installed layout's own slot size stays exactly what it always was — this is the medium's
  # slot only, rounded up to a 64 MiB boundary the way the rest of this file's partitions are.
  ROOT_SLOT_SIZE_MIB=$(( (root_bytes + 64 * 1024 * 1024 - 1) / (64 * 1024 * 1024) * 64 ))
  log "root erofs (desktop's own artifact): $((root_bytes/1024/1024)) MiB, medium slot sized to ${ROOT_SLOT_SIZE_MIB} MiB"
else
  # rsync to a staging copy so re-running this stage never mutates $TARGET.
  ROOT_STAGE="$STAGING/root"
  rsync -aHAX --exclude '/var/*' "$TARGET/" "$ROOT_STAGE/"
  ROOT_EROFS="$OUT/$ROOT_IMG_NAME"
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
fi

# ---- verify: the BUILT EROFS carries neither the live user nor its autologin (plan/34 §5) ----
# Unconditional on role: for target this is the tree stage 40 configured, one rsync+mkfs.erofs
# away; for live it is $PAYLOAD_ROOT_EROFS itself, the exact bytes about to be dd'd onto the
# stick — re-proving the desktop build's own record of itself is cheap next to what shipping it
# wrong would cost.
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

if [[ $PROFILE_ROLE == live ]]; then
  # ---- 2·delta. the extension and the upper, by difference (plan/34 §7.2 step 2) -------
  # $VAR_STAGE already carries stage 40's own live-only /etc writes from the rsync just above —
  # overlay/etc/upper/passwd, the autologin drop-in, the rest of §5's split — so tree-delta.py's
  # "a path already in the upper wins" check sees them before it ever considers routing anything
  # there itself: an installer-only /etc customisation must never be overwritten by the
  # desktop's pristine copy of the same path.
  #
  # NEW is $TARGET directly, not a staged copy: tree-delta.py's own EXCLUDE_PREFIXES already
  # skips var/, proc/, sys/, dev/, tmp/, run/ and efi/, which is exactly "the target minus /var
  # and every mountpoint" plan/34 §7.2 asks for, and this stage never writes to $TARGET.
  log "installer: tree-delta $BASE_EXTRACT (desktop's own artifact) vs $TARGET -> $VAR_STAGE"
  python3 "$REPO/scripts/lib/tree-delta.py" "$BASE_EXTRACT" "$TARGET" "$VAR_STAGE" \
    || die "installer: tree-delta failed — see the messages above. plan/34 §6 is what is
  supposed to make a DELETED entry impossible; a CHANGED-not-allowlisted or EARLY-BOOT-RESOURCE
  entry means this build's own /usr or /etc drifted from the base in a way nobody has reviewed."

  # ---- 2·ext. stamp the extension (plan/34 §7.2 step 3) --------------------------------
  EXT_REL_DIR="$VAR_STAGE/lib/extensions/immos-installer/usr/lib/extension-release.d"
  ensure_dir "$EXT_REL_DIR"
  printf 'ID=%s\nVERSION_ID=%s\nARCHITECTURE=x86-64\n' "$DISTRO_ID" "$VERSION" \
    > "$EXT_REL_DIR/extension-release.immos-installer"
  log "installer: extension-release.immos-installer stamped (ID=$DISTRO_ID VERSION_ID=$VERSION)"
fi

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

if [[ $PROFILE_ROLE == live ]]; then
  # ---- verify: the sysext and its polkit rule, read back from the BUILT var image (plan/34
  # §7.2 step 7 — the --all-root lesson again: this is the file that actually merges over /usr
  # and the ownership polkitd actually reads, not what the staging tree said either one was) ----
  POLKITD_LINE="$(grep '^polkitd:' "$TARGET/etc/passwd" || true)"
  [[ -n $POLKITD_LINE ]] || die "installer: no polkitd user in $TARGET/etc/passwd"
  POLKITD_UID="$(cut -d: -f3 <<<"$POLKITD_LINE")"; POLKITD_GID="$(cut -d: -f4 <<<"$POLKITD_LINE")"

  RULES_STAT="$(debugfs -R "stat /overlay/etc/upper/polkit-1/rules.d" "$VAR_IMG" 2>/dev/null)"
  [[ -n $RULES_STAT ]] || die "installer: no overlay/etc/upper/polkit-1/rules.d in the built var
  image — the installer's own polkit rule should have routed there via tree-delta.py (plan/34
  §7.2)"
  RULES_MODE="$(sed -n 's/.*Mode: *\([0-7]\{4\}\).*/\1/p' <<<"$RULES_STAT" | head -1)"
  RULES_UID="$(sed -n 's/.*User: *\([0-9]\+\).*/\1/p' <<<"$RULES_STAT" | head -1)"
  RULES_GID="$(sed -n 's/.*Group: *\([0-9]\+\).*/\1/p' <<<"$RULES_STAT" | head -1)"
  [[ $RULES_MODE == 0700 ]] \
    || die "installer: overlay/etc/upper/polkit-1/rules.d is mode $RULES_MODE in the built var
  image, expected 0700 — polkitd would refuse to read every .rules file in it (see the ownership
  note in section 1 above)"
  [[ $RULES_UID == "$POLKITD_UID" && $RULES_GID == "$POLKITD_GID" ]] \
    || die "installer: overlay/etc/upper/polkit-1/rules.d is ${RULES_UID}:${RULES_GID} in the
  built var image, expected ${POLKITD_UID}:${POLKITD_GID} (polkitd:polkitd)"
  log "installer: overlay/etc/upper/polkit-1/rules.d is 0700 polkitd:polkitd in the built var image"

  EXT_STAT="$(debugfs -R "stat /lib/extensions/immos-installer" "$VAR_IMG" 2>/dev/null)"
  [[ -n $EXT_STAT ]] || die "installer: no lib/extensions/immos-installer in the built var image"
  EXT_UID="$(sed -n 's/.*User: *\([0-9]\+\).*/\1/p' <<<"$EXT_STAT" | head -1)"
  EXT_GID="$(sed -n 's/.*Group: *\([0-9]\+\).*/\1/p' <<<"$EXT_STAT" | head -1)"
  [[ $EXT_UID == 0 && $EXT_GID == 0 ]] \
    || die "installer: lib/extensions/immos-installer is ${EXT_UID}:${EXT_GID} in the built var
  image, expected 0:0 (root) — systemd-sysext refuses to merge an extension it does not own"
  log "installer: lib/extensions/immos-installer is root-owned in the built var image"

  DONE_STAT="$(debugfs -R "stat /lib/$DISTRO_ID/flatpak-preinstall.done" "$VAR_IMG" 2>/dev/null)"
  grep -q "Type: *regular" <<<"$DONE_STAT" \
    || die "installer: no lib/$DISTRO_ID/flatpak-preinstall.done in the built var image — the
  base profile's firstboot Flatpak-install unit would try to install apps on the stick"
  log "installer: lib/$DISTRO_ID/flatpak-preinstall.done present in the built var image"
fi

if [[ $PROFILE_ROLE == live ]]; then
  # ---- 3a. the live UKI: a re-wrap of the desktop's own (plan/34 §8) -------------------
  # Same kernel, same initrd, same os-release, same uname, same splash (when there is one) —
  # only .cmdline differs, because the stick's partitions are live_* on purpose (plan/33 §2).
  #
  # objcopy --update-section replaces exactly one PE section and leaves every other byte alone,
  # which is what makes "every OTHER section is byte-identical to the desktop UKI's" true BY
  # CONSTRUCTION — a from-scratch `ukify build` reassembly (extract every section, hand them all
  # back to ukify) would need to be TRUSTED to reproduce the same PE layout, padding and
  # checksums byte for byte, which is a much larger and less certain claim for the same result.
  CMDLINE_FILE="$STAGING/desktop.cmdline"
  objcopy -O binary --only-section=.cmdline "$PAYLOAD_UKI" "$CMDLINE_FILE" \
    || die "installer: could not read .cmdline out of the base profile's UKI: $PAYLOAD_UKI"
  DESKTOP_CMDLINE="$(cat "$CMDLINE_FILE")"

  # The three label tokens, built the SAME way stage 40 built them (mount_extra_*_token,
  # scripts/lib/common.sh) — "var"/"esp" are the target role's own NAME_VAR/NAME_ESP
  # (scripts/lib/layout.sh), i.e. exactly what the desktop's OWN stage 40 run fed those
  # functions when it built ITS cmdline. $IMG_*_PARTLABEL here are THIS (live) profile's own
  # names — already "live_root_$VERSION"/"live_var"/"live_esp" (plan/33 §2).
  DESKTOP_VAR_TOKEN="$(mount_extra_var_token var)"
  DESKTOP_ESP_TOKEN="$(mount_extra_esp_token esp)"
  DESKTOP_ROOT_TOKEN="root=PARTLABEL=$ROOT_PARTLABEL"
  LIVE_VAR_TOKEN="$(mount_extra_var_token "$IMG_VAR_PARTLABEL")"
  LIVE_ESP_TOKEN="$(mount_extra_esp_token "$IMG_ESP_PARTLABEL")"
  LIVE_ROOT_TOKEN="root=PARTLABEL=$IMG_ROOT_PARTLABEL"

  LIVE_CMDLINE="$DESKTOP_CMDLINE"
  for tok_from in "$DESKTOP_ROOT_TOKEN" "$DESKTOP_VAR_TOKEN" "$DESKTOP_ESP_TOKEN"; do
    tok_n="$(grep -o -F -- "$tok_from" <<<"$LIVE_CMDLINE" | wc -l)"
    [[ $tok_n == 1 ]] || die "installer: the base profile's UKI cmdline names
  '$tok_from' $tok_n time(s), expected exactly 1 — cannot safely rewrap it for the live medium
  (plan/34 §8). cmdline was: $DESKTOP_CMDLINE"
  done
  LIVE_CMDLINE="${LIVE_CMDLINE//$DESKTOP_ROOT_TOKEN/$LIVE_ROOT_TOKEN}"
  LIVE_CMDLINE="${LIVE_CMDLINE//$DESKTOP_VAR_TOKEN/$LIVE_VAR_TOKEN}"
  LIVE_CMDLINE="${LIVE_CMDLINE//$DESKTOP_ESP_TOKEN/$LIVE_ESP_TOKEN}"
  LIVE_CMDLINE_FILE="$STAGING/live.cmdline"
  printf '%s' "$LIVE_CMDLINE" > "$LIVE_CMDLINE_FILE"

  ensure_dir "$UKI_DIR"
  cp -f -- "$PAYLOAD_UKI" "$UKI_DIR/$UKI_NAME"
  objcopy --update-section ".cmdline=$LIVE_CMDLINE_FILE" "$UKI_DIR/$UKI_NAME" \
    || die "installer: objcopy could not replace .cmdline in the live UKI"

  # ---- verify: every section but .cmdline is byte-identical to the desktop UKI's -------
  UKI_SEC_LIST="$(objdump -h "$PAYLOAD_UKI" | awk '/^ *[0-9]+ \./{print $2}')"
  [[ -n $UKI_SEC_LIST ]] || die "installer: objdump -h listed no sections in $PAYLOAD_UKI"
  sec_checked=0
  for sec in $UKI_SEC_LIST; do
    [[ $sec == .cmdline ]] && continue
    A="$STAGING/sec-a"; B="$STAGING/sec-b"
    objcopy -O binary --only-section="$sec" "$PAYLOAD_UKI"    "$A" 2>/dev/null || : > "$A"
    objcopy -O binary --only-section="$sec" "$UKI_DIR/$UKI_NAME" "$B" 2>/dev/null || : > "$B"
    cmp -s -- "$A" "$B" || die "installer: live UKI's $sec section differs from the base
  profile's — the rewrap is supposed to touch .cmdline only"
    sec_checked=$((sec_checked + 1))
  done
  (( sec_checked > 0 )) || die "installer: section-identity check compared nothing — objdump's
  section list parsed to just .cmdline, which would mean this check proved nothing"
  READBACK_CMDLINE="$(objcopy -O binary --only-section=.cmdline "$UKI_DIR/$UKI_NAME" "$STAGING/sec-c" \
    && cat "$STAGING/sec-c")"
  [[ $READBACK_CMDLINE == "$LIVE_CMDLINE" ]] \
    || die "installer: live UKI's own .cmdline does not read back as what was written"
  log "installer: live UKI re-wrapped from $PAYLOAD_UKI — $sec_checked section(s) verified byte-identical, only .cmdline replaced"
fi

# ---- 3. ESP vfat via mtools ------------------------------------------------------------
ESP_IMG="$STAGING/esp.img"
# plan/34 §7.2 step 5: the medium's own ESP is sized from what it actually holds — one UKI,
# ever — not from ESP_SIZE_MIB, which budgets for the INSTALLED layout's two systemd-boot
# tries-counter renames of an A/B pair. The installed layout itself is untouched.
if [[ $PROFILE_ROLE == live ]]; then
  truncate -s "${MEDIUM_ESP_SIZE_MIB}M" "$ESP_IMG"
else
  truncate -s "${ESP_SIZE_MIB}M" "$ESP_IMG"
fi
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
# The ESP argument matches whichever size ESP_IMG was actually truncated to above (section 3) —
# MEDIUM_ESP_SIZE_MIB for live, ESP_SIZE_MIB for target — or the partition table and the
# filesystem dd'd into it disagree on how big p1 is.
LAYOUT_ESP_MIB=$ESP_SIZE_MIB
[[ $PROFILE_ROLE == live ]] && LAYOUT_ESP_MIB=$MEDIUM_ESP_SIZE_MIB
compute_layout "$LAYOUT_ESP_MIB" "$ROOT_SLOT_SIZE_MIB" "$VAR_SIZE_MIB" "$PROFILE_ROOT_SLOTS"
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
if [[ $PROFILE_ROLE == live ]]; then
  # ---- 4a. verify: the partition just written IS the manifest's root_erofs (plan/34 §7.2
  # step 6) — a read of what dd actually put on disk, not a re-hash of $ROOT_EROFS, which would
  # only prove the SOURCE file is what it always was, not that dd wrote it correctly.
  MANIFEST_ROOT_SUM="$(sed -n 's/.*"root_erofs": *{[^}]*"sha256": *"\([a-f0-9]*\)".*/\1/p' \
    "$TARGET$PAYLOAD_DIR/manifest.json")"
  [[ -n $MANIFEST_ROOT_SUM ]] || die "installer: could not read root_erofs.sha256 out of
  $TARGET$PAYLOAD_DIR/manifest.json"
  root_mib_span=$(( (root_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
  READBACK_SUM="$(dd if="$IMG" bs=1MiB skip="$ROOT_A_START_MIB" count="$root_mib_span" status=none \
    | head -c "$root_bytes" | sha256sum | cut -d' ' -f1)"
  [[ $READBACK_SUM == "$MANIFEST_ROOT_SUM" ]] \
    || die "installer: the root partition just written does not match manifest.json's
  root_erofs.sha256 (manifest: $MANIFEST_ROOT_SUM, read back: $READBACK_SUM) — the dd above wrote
  something other than $PAYLOAD_ROOT_EROFS"
  log "installer: root partition sha256 readback matches the manifest ($READBACK_SUM)"
fi
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
# Same reasoning as stage 40's own addition of these three (plan/34 §7.1): without them, a
# desktop rebuild at the same VERSION is invisible to stage 60's own `--from 60` stamp check.
PAYLOAD_STAMP_INPUTS=()
[[ -n ${BASE_PROFILE:-} ]] \
  && PAYLOAD_STAMP_INPUTS=("$PAYLOAD_ROOT_EROFS" "$PAYLOAD_UKI" "$PAYLOAD_VAR_TAR")
stamp_write "$STAGE_NAME" "$(inputs_hash "$REPO/config/build.conf" "${PAYLOAD_STAMP_INPUTS[@]}")"
