#!/usr/bin/env bash
# Stage 70 — QEMU/OVMF boot tests (plan/07).
#   default:                       T1 smoke (boot twice, self-reported assertions)
#   UPDATE_TEST_BASE_IMG=old.img:  T2 update E2E against out/release served over HTTP
# The guest self-reports via the distro-test-report unit (gated on an SMBIOS
# credential injected by run-vm.sh --test; absent on real hardware).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE_NAME=70-test
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_config
ensure_dir "$LOG_DIR"; exec > >(tee -a "$LOG_DIR/$STAGE_NAME.log") 2>&1

is_linux || die "stages run inside the builder container only"
IMG="$OUT/$IMG_NAME"
[[ -f $IMG ]] || die "image missing: $IMG — run stage 60"

TIMEOUT=300
[[ -e /dev/kvm ]] || { TIMEOUT=1500; warn "no KVM — TCG emulation, timeouts x5"; }

MARKER="IMAGE-TEST:"
DENY_RE='Kernel panic|emergency\.target|Failed to mount|Timed out waiting for device'

# boot_and_watch WORKIMG LOGFILE [extra run-vm args...] → waits for marker or failure
boot_and_watch() {
  local img=$1 slog=$2; shift 2
  rm -f -- "$slog"
  # --writable: $img is always a disposable copy under $WORK, and both the smoke test
  # (machine-id) and the update E2E (new root slot) assert that boot 1's writes survive into
  # boot 2. run-vm.sh defaults to snapshot=on, which discards them.
  DISTRO_ID="$DISTRO_ID" bash "$SCRIPT_DIR/../run-vm.sh" "$img" --writable --headless "$slog" "$@" &
  local qpid=$!
  local waited=0
  while true; do
    if [[ -f $slog ]]; then
      grep -Eq "$DENY_RE" "$slog" && { kill "$qpid" 2>/dev/null || true; die "boot failure pattern in serial log ($slog)"; }
      grep -q "$MARKER" "$slog" && break
    fi
    kill -0 "$qpid" 2>/dev/null || { grep -q "$MARKER" "$slog" 2>/dev/null && break; die "QEMU exited before test marker (see $slog)"; }
    (( waited >= TIMEOUT )) && { kill "$qpid" 2>/dev/null || true; die "timeout after ${TIMEOUT}s waiting for test marker (see $slog)"; }
    sleep 2; waited=$((waited + 2))
  done
  # guest powers itself off after reporting; give it a moment, then ensure exit
  local grace=0
  while kill -0 "$qpid" 2>/dev/null && (( grace < 60 )); do sleep 2; grace=$((grace + 2)); done
  kill "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true
}

# DETAIL lines are excluded, not just deprioritised: MARKER is "IMAGE-TEST:" and the detail
# prefix is "$MARKER-DETAIL", so a plain grep matches both and `tail -n1` would read whichever
# came last. The guest prints its DETAIL lines AFTER the report, so any run that emitted them
# used to yield empty fields for everything — reporting "guest version=, expected 0.3.0" for
# what was really a sound failure, i.e. hiding the diagnosis the DETAIL lines exist to give.
#
# Fields are read from the guest's per-field lines first (IMAGE-FIELD: key=value, one per line),
# and only then from the summary. The summary is a single long line written to a console shared
# with agetty, and a long enough one comes back folded with the token at the fold repeated on both
# sides — at which point every field past the fold parses as empty and the failure is attributed
# to whatever that field happened to be. The per-field lines are too short to fold.
FIELDMARK='IMAGE-FIELD:'
field() {
  local v
  v="$(grep -- "$FIELDMARK $2=" "$1" 2>/dev/null | tail -n1 | sed -e 's/\r$//' -e "s/.*$FIELDMARK $2=//")"
  if [[ -n $v ]]; then printf '%s' "$v"; return 0; fi
  grep "$MARKER" "$1" | grep -v -- "$MARKER-DETAIL" | tail -n1 | tr -d '\r' | tr ' ' '\n' | sed -n "s/^$2=//p"
}

assert_report() {  # LOG expected_version
  local slog=$1 want_ver=$2
  grep -q "$MARKER ok" "$slog" || die "guest reported failure: $(grep "$MARKER" "$slog" | tail -n1)"
  local got; got="$(field "$slog" version)"
  [[ $got == "$want_ver" ]] || die "guest version=$got, expected $want_ver"
  [[ $(field "$slog" etc_overlay) == overlay ]] || die "guest /etc is not an overlay"
  [[ $(field "$slog" failed_units) == 0 ]] || die "guest has failed units"
  # DNS: only the resolver's own state is asserted. Whether a name actually resolved is
  # reported as dns=yes/no and left alone — that depends on the build host's network, not on
  # the image.
  [[ $(field "$slog" resolved) == yes ]] \
    || die "systemd-resolved is not active in the guest (resolved=$(field "$slog" resolved)) — /etc/nsswitch.conf routes host lookups through it"
  [[ $(field "$slog" dns) == yes ]] || warn "guest could not resolve a public name (dns=no) — network-dependent, not failing the test"
  if profile_has_set desktop; then
    [[ $(field "$slog" graphical) == yes ]] || die "graphical.target not reached in guest"
    # Sound. Asserted, not merely reported: unlike dns above, nothing in it depends on the
    # build host — the guest has no audio device either way, and this measures whether a client
    # can CONNECT to the pulse socket, which is exactly what KDE's volume applet does. A green
    # smoke test with no audio at all is what this exists to stop happening twice.
    local snd; snd="$(field "$slog" sound)"
    [[ $snd == ok ]] \
      || die "guest has no sound server (sound=$snd) — nothing is listening on the pulse
socket. Check that stage 40 enabled pipewire.socket, pipewire-pulse.socket and
wireplumber.service for users; see the IMAGE-TEST-DETAIL pactl/pw-units lines above"
    # Autologin. A v1 image is live media (plan/01); a greeter asking for a password is a
    # broken image, not a cosmetic issue. This went unasserted through 0.2.x and 0.3.0 and was
    # broken in all of them — every inode carried an epoch mtime, so plasmalogin never read its
    # own config and fell back to the greeter without logging one word about it. Nothing else in
    # this report catches that: graphical=yes is the SYSTEM target and stays green throughout.
    # The value carries the seat's actual active session on failure, e.g. no(plasmalogin/greeter).
    local al; al="$(field "$slog" autologin)"
    [[ $al == yes ]] \
      || die "guest did not autologin $LIVE_USER (autologin=$al) — seat0's active session is not
a live-user session. Check [Autologin] in /etc/plasmalogin.conf.d/10-autologin.conf, and check
that stage 60 stamped a NON-ZERO mtime on the erofs (SOURCE_DATE_EPOCH); an epoch mtime makes
plasmalogin skip its config silently"
  fi
  # ---- T-DOM-4: the domain client, on a machine nobody has joined (plan/18) ------------
  # Every profile ships sssd, and almost every machine will never be joined — so the assertion
  # that matters is that adding domain support changed NOTHING for everyone else.
  #
  # sssd must be inactive, and "inactive" is not a synonym for "harmless" here: it exits
  # non-zero with no /etc/sssd/sssd.conf, systemd-boot-check-no-failures gates
  # boot-complete.target, and a failed unit is therefore a failed boot that burns a try and, on
  # the third, rolls the machine back to the previous image. failed_units=0 above would catch
  # that, but only as an anonymous count; this names the cause.
  local sssd_state dom; sssd_state="$(field "$slog" sssd)"; dom="$(field "$slog" domain)"
  case "$dom:$sssd_state" in
    joined:active) : ;;
    joined:*)
      die "guest is joined to a domain but sssd=$sssd_state — no domain account could log in" ;;
    *:inactive) : ;;
    *:absent)
      die "guest has no sssd.service at all (sssd=absent). @domain is named by every profile
(config/profiles/README.md), so this image cannot be joined to a domain and cannot install the
client afterwards — there is no Portage on the target" ;;
    *)
      die "guest is NOT joined to a domain but sssd=$sssd_state. It must stay inactive: an sssd
that starts and fails takes boot-complete.target with it, which burns a boot try and eventually
rolls the machine back. Check the 'disable sssd.service' preset line and the
ConditionPathExists drop-in (plan/18 §5.1)" ;;
  esac
  # ...and the other half of the same property: /etc/nsswitch.conf names the sss module and
  # /etc/pam.d carries pam_sss on every image. If either misbehaves with no sssd listening, then
  # domain support broke local login for everyone who never wanted it. Resolving the live user
  # through nss is the cheapest honest test of that.
  [[ $(field "$slog" nss_local) == yes ]] \
    || die "guest cannot resolve its own local user through nss (nss_local=$(field "$slog" nss_local)).
/etc/nsswitch.conf's passwd line names the sss module; with sssd not running, nss_sss must
return unavailable and let the files module answer (plan/18 §2)"

  # ---- T-MAN-5: managed mode, on a machine nobody has enrolled (plan/19 §8.1) ----------
  # The exact counterpart of T-DOM-4 above, for the same reason: managed mode ships on every
  # profile and almost every machine will never enrol, so what has to be asserted is that adding
  # it changed NOTHING for everyone else. "skipped" is the healthy state — the sync unit's
  # ConditionPathExists says no, systemd records that as skipped rather than failed, and
  # boot-check-no-failures does not count it.
  local mgd userdb mtimer
  mgd="$(field "$slog" managed)"; userdb="$(field "$slog" userdb)"
  mtimer="$(field "$slog" managed_timer)"
  case "$mgd" in
    unenrolled|enrolled) : ;;
    failed)
      die "guest's ${DISTRO_ID}-managed-sync.service FAILED. On an unenrolled machine it must be
SKIPPED by its ConditionPathExists drop-in; a unit that starts and fails takes
boot-complete.target with it, burns a boot try, and on the third rolls the machine back to the
previous image (plan/19 §8.1)" ;;
    absent)
      die "guest has no ${DISTRO_ID}-managed-sync.service at all. The unit ships in every profile
and cannot be added later — there is no Portage on the target" ;;
    *)
      die "guest reported managed=$mgd, which this harness does not know how to read" ;;
  esac
  if [[ $mgd == unenrolled ]]; then
    [[ $userdb == absent ]]       || die "guest has /etc/userdb without ever having enrolled (userdb=$userdb). That directory
is created by enrolment; shipping one puts a directory in the read-only lower that the /etc
overlay then has to shadow (plan/19 §3, T-MAN-5)"
    # `enabled` here would mean the vendor preset did not take — which has happened in this
    # project before, and is why plan/19 §8.1 has three independent defences rather than one.
    case "$mtimer" in
      disabled|masked|static|indirect|"") : ;;
      *) die "guest's ${DISTRO_ID}-managed-sync.timer is '$mtimer' on a machine that never
enrolled. Check the 'disable ${DISTRO_ID}-managed-sync.timer' line in the vendor preset" ;;
    esac
  fi

  # Rootless containers (plan/13). Asserted rather than reported, unlike dns above, because
  # nothing in it depends on the build host's network: `podman info` reads the kernel's userns
  # support, the setuid map helpers and the local storage driver and nothing else. "na" is the
  # INCLUDE_DISTROBOX=0 image correctly saying it has no podman.
  if [[ ${INCLUDE_DISTROBOX:-1} == 1 ]]; then
    local rootless; rootless="$(field "$slog" podman_rootless)"
    [[ $rootless == true ]] \
      || die "guest podman is not rootless-capable (podman_rootless=$rootless) — check the subuid
range for $LIVE_USER, the setuid bit on newuidmap/newgidmap, and CONFIG_USER_NS in the kernel"
  fi
}

if [[ -n ${UPDATE_TEST_BASE_IMG:-} ]]; then
  # ---- T2: update E2E -------------------------------------------------------------
  [[ -d $RELEASE_DIR ]] || die "no release dir — run stage 80 for the new version first"
  [[ -f $UPDATE_TEST_BASE_IMG ]] || die "base image missing: $UPDATE_TEST_BASE_IMG"
  WORKIMG="$WORK/update-test.img"; cp --sparse=always -- "$UPDATE_TEST_BASE_IMG" "$WORKIMG"

  ( cd "$OUT/release" && exec python3 -m http.server 8000 --bind 0.0.0.0 ) &
  HTTP_PID=$!; trap 'kill $HTTP_PID 2>/dev/null || true' EXIT
  sleep 1

  SLOG="$LOG_DIR/update-test-boot1.serial.log"
  log "update test: booting base image, applying update from local server"
  boot_and_watch "$WORKIMG" "$SLOG" --test update --update-url "http://10.0.2.2:8000/$UPDATE_CHANNEL"
  # first marker comes from the OLD version confirming the update applied; the guest
  # then reboots into the new version and reports again on a second invocation:
  SLOG2="$LOG_DIR/update-test-boot2.serial.log"
  boot_and_watch "$WORKIMG" "$SLOG2" --test update
  assert_report "$SLOG2" "$VERSION"
  log "update E2E passed: base image now runs $VERSION"
else
  # ---- T1: smoke, two boots ---------------------------------------------------------
  WORKIMG="$WORK/smoke-test.img"; cp --sparse=always -- "$IMG" "$WORKIMG"

  SLOG1="$LOG_DIR/smoke-boot1.serial.log"
  log "smoke: first boot (repart growth, machine-id generation)"
  boot_and_watch "$WORKIMG" "$SLOG1" --test smoke
  assert_report "$SLOG1" "$VERSION"

  SLOG2="$LOG_DIR/smoke-boot2.serial.log"
  log "smoke: second boot (persistence)"
  boot_and_watch "$WORKIMG" "$SLOG2" --test smoke
  assert_report "$SLOG2" "$VERSION"
  m1="$(field "$SLOG1" machine_id)"; m2="$(field "$SLOG2" machine_id)"
  [[ -n $m1 && $m1 == "$m2" ]] || die "machine-id did not persist across boots ($m1 vs $m2)"
  log "smoke tests passed"

  # ---- T-DOM-3: join a real Active Directory domain, and leave it again (plan/18 §9) ----
  # SKIPPED, not failed, when no domain controller is present. build.sh --with-test-dc stands one
  # up and exports AD_DC_IP; without it there is nothing to join, and an offline build must stay
  # green — the same rule stage 80 follows for a live profile.
  #
  # Nothing about the guest is special. It is the same disposable copy the smoke test just used,
  # booting the shipped image with one extra SMBIOS credential. The domain becomes reachable
  # because build.sh put THIS CONTAINER on the DC's network with --dns pointing at it, and QEMU's
  # user-mode networking relays the guest's DNS to whatever this container's resolv.conf names —
  # so the SRV lookups AD discovery depends on arrive at the domain controller with no guest
  # configuration at all (scripts/lib/ad-dc.sh).
  if [[ -z ${AD_DC_IP:-} ]]; then
    log "domain tests: skipped (no test domain controller — pass --with-test-dc to build.sh)"
  elif ! profile_has_set desktop; then
    log "domain tests: skipped (T-DOM-3 needs a full user session; console profile)"
  else
    log "domain: joining ${AD_DC_DOMAIN} through the test DC at ${AD_DC_IP}"
    # Point THIS CONTAINER's resolver straight at the domain controller, and do it here rather
    # than relying on the --dns docker was given.
    #
    # QEMU's user-mode networking answers the guest's DNS itself and relays to whatever
    # /etc/resolv.conf names — which is the whole mechanism that lets an unmodified guest
    # discover the domain (scripts/lib/ad-dc.sh). On a user-defined docker network that file
    # says `nameserver 127.0.0.11`, docker's embedded resolver, because there it is mandatory
    # and --dns only tells THAT resolver where to forward. A loopback nameserver is the one
    # address libslirp handles inconsistently across versions — some builds use it as-is, others
    # decide it cannot be right and substitute their own. Writing the DC's routable address
    # removes the question: it is reachable from this namespace either way, and the guest's SRV
    # lookups then land on the domain controller with no version-dependent behaviour in between.
    if [[ -w /etc/resolv.conf ]]; then
      printf 'nameserver %s\nsearch %s\n' "$AD_DC_IP" "$AD_DC_DOMAIN" > /etc/resolv.conf
      log "domain: container resolver pointed at $AD_DC_IP (slirp relays the guest's DNS here)"
    else
      warn "cannot rewrite /etc/resolv.conf — the guest's SRV lookups may not reach the DC"
    fi
    DLOG="$LOG_DIR/domain-test.serial.log"
    boot_and_watch "$WORKIMG" "$DLOG" --test domain \
      --domain "domain=${AD_DC_DOMAIN},user=${AD_DC_ADMIN},password=${AD_DC_ADMIN_PASSWORD},testuser=${AD_DC_TEST_USER},testpassword=${AD_DC_TEST_PASSWORD}"
    grep -q "$MARKER ok" "$DLOG" \
      || die "domain test: guest reported failure: $(grep "$MARKER" "$DLOG" | tail -n1)"

    # The join, and then the three things a domain member must actually be able to do. Each is
    # a different layer and each fails independently, so each gets its own message.
    [[ $(field "$DLOG" join) == ok ]] \
      || die "domain: the join failed. See the IMAGE-TEST-DETAIL join: lines above — adcli
reports the LDAP or Kerberos error verbatim, and the three usual causes are the account not
being allowed to create computer objects, DNS not resolving _ldap._tcp.dc._msdcs.${AD_DC_DOMAIN},
and clock skew"
    [[ $(field "$DLOG" domain_user) == yes ]] \
      || die "domain: getent passwd ${AD_DC_TEST_USER} found nothing (domain_user=$(field "$DLOG" domain_user)).
The join succeeded, so this is nss_sss, sssd's id mapping, or the LDAP bind — not the enrollment.
Check that /etc/nsswitch.conf's passwd line names sss and that libnss_sss survived the prune"
    local_uid="$(field "$DLOG" domain_uid)"
    [[ $local_uid =~ ^[0-9]+$ ]] \
      || die "domain: the domain user has no numeric uid (domain_uid=$local_uid) — ldap_id_mapping
did not produce a POSIX id from the object SID"
    [[ $(field "$DLOG" kinit) == yes ]] \
      || die "domain: kinit for ${AD_DC_TEST_USER} failed (kinit=$(field "$DLOG" kinit)).
Kerberos is what pam_sss authenticates with, so this is the layer under a failed login. See the
IMAGE-TEST-DETAIL kinit: lines; clock skew and a missing /etc/krb5.conf.d drop-in look identical
from the login screen and quite different here"
    case "$(field "$DLOG" pam)" in
      yes) : ;;
      no-script)
        die "domain: script(1) is missing from the image, so the PAM check could not run. It is
util-linux's and @base has util-linux in every profile, so something pruned it" ;;
      *)
        die "domain: PAM did not authenticate ${AD_DC_TEST_USER} (pam=$(field "$DLOG" pam)).
This is su, so it exercises pam_sss on the system-auth AUTH stack and nothing else. Check that
sys-auth/pambase was built with USE=sssd; see the IMAGE-TEST-DETAIL su: lines above" ;;
    esac
    # The console login, which is a DIFFERENT PAM service from the one above and the reason this
    # check exists separately: su-l includes su includes system-auth, so su never touches
    # system-login. The greeter, the console and sshd all substack system-login, and that is where
    # pam_mkhomedir lives — so this is the only step that proves a human logging in gets a home.
    [[ $(field "$DLOG" login) == yes ]] \
      || die "domain: ${AD_DC_TEST_USER} could not log in on the console (login=$(field "$DLOG" login)).
pam_sss authenticated this user through su, so the auth half works and the failure is in the
system-login stack itself — see the IMAGE-TEST-DETAIL login: lines above"
    [[ $(field "$DLOG" home) == yes ]] \
      || die "domain: no home directory was created for ${AD_DC_TEST_USER} (home=$(field "$DLOG" home)).
The console login above SUCCEEDED, so the session stack ran and pam_mkhomedir did not do its job.
Stage 40 appends it to /etc/pam.d/system-login; a domain user who logs in to a missing home gets a
session that starts in / with no config"
    [[ $(field "$DLOG" failed_units) == 0 ]] \
      || die "domain: the guest has failed units after joining ($(field "$DLOG" failed_list))"

    # ...and leaving must put the machine back. A join that cannot be undone is a machine that
    # has to be reinstalled, on an OS that cannot be reinstalled selectively.
    [[ $(field "$DLOG" left) == ok ]] || die "domain: $DISTRO_ID-domain leave failed"
    [[ $(field "$DLOG" conf_gone) == yes ]] \
      || die "domain: /etc/sssd/sssd.conf survived the leave — the next boot would start sssd
against a domain this machine is no longer enrolled in"
    [[ $(field "$DLOG" local_user) == yes ]] \
      || die "domain: the local $LIVE_USER account stopped resolving after leaving the domain"
    log "domain tests passed: joined ${AD_DC_DOMAIN}, authenticated ${AD_DC_TEST_USER}, left cleanly"
  fi

  # ---- T-MAN-1: enrol in managed mode, and leave again (plan/19 §12) ----------------------
  # SKIPPED, not failed, when no control plane is running. build.sh --with-test-api stands one
  # up and exports MANAGED_API_URL; without it there is nothing to enrol with, and an offline
  # build must stay green — the same rule the domain tests follow.
  #
  # Unlike the domain case, NOTHING has to be done about the guest's DNS. Managed mode reaches
  # its control plane by URL, over one TCP port, which QEMU's user-mode networking NATs to
  # whatever this container can reach. That is the difference that makes managed mode work from
  # a coffee shop and a domain join not.
  if [[ -z ${MANAGED_API_URL:-} ]]; then
    log "managed tests: skipped (no test control plane — pass --with-test-api to build.sh)"
  else
    log "managed: enrolling against the test control plane at ${MANAGED_API_URL}"
    MLOG="$LOG_DIR/managed-test.serial.log"
    boot_and_watch "$WORKIMG" "$MLOG" --test managed \
      --managed "api=${MANAGED_API_URL},code=${MANAGED_API_CODE},user=alice,password=${MANAGED_API_ALICE_PW},absent=carol"
    grep -q "$MARKER ok" "$MLOG" \
      || die "managed test: guest reported failure: $(grep "$MARKER" "$MLOG" | tail -n1)"

    # Each of these is a different layer and each fails independently, so each gets its own
    # message — the same discipline the domain assertions above follow.
    [[ $(field "$MLOG" enroll) == ok ]] \
      || die "managed: enrolment failed. See the IMAGE-TEST-DETAIL enroll: lines above. The
three usual causes are the control plane being unreachable from the guest, the enrolment code
having already been spent, and the guest's clock being too far out for TLS"
    [[ $(field "$MLOG" managed_user) == yes ]] \
      || die "managed: getent passwd alice found nothing (managed_user=$(field "$MLOG" managed_user)).
The enrolment succeeded, so the bundle arrived and verified — this is nss-systemd not reading
/etc/userdb. Check that /etc/nsswitch.conf's passwd line still ends in the systemd module and
that libnss_systemd.so survived the prune"
    MANAGED_UID="$(field "$MLOG" managed_uid)"
    [[ $MANAGED_UID =~ ^[0-9]+$ ]] \
      || die "managed: the managed user has no numeric uid (managed_uid=$MANAGED_UID)"
    (( MANAGED_UID >= 1000 && MANAGED_UID <= 60000 )) \
      || die "managed: uid $MANAGED_UID is outside [1000, 60000], so the account exists, logs in,
and never appears on the greeter — /etc/login.defs bounds Plasma Login Manager's user list by
exactly those two numbers (plan/19 §2.4)"
    # §2.3's first silent failure: without the <uid>.user symlink the record resolves by name and
    # not by number, and every ls -l in that user's own home prints a bare uid.
    [[ $(field "$MLOG" byuid) == yes ]] \
      || die "managed: getent passwd $MANAGED_UID found nothing while getent passwd alice worked.
The <uid>.user symlink is missing from /etc/userdb (plan/19 §2.3)"
    # ...and the second: membership is a FILE NAME, not a field in the record.
    [[ $(field "$MLOG" group) == yes ]] \
      || die "managed: alice is not in ${DISTRO_ID}-admins (group=$(field "$MLOG" group)). Group
membership comes from an empty <user>:<group>.membership file; a memberOf field in the record
does nothing at all through NSS (plan/19 §2.3)"
    # ...and the third, which is the one that decides whether a person can use their computer.
    [[ $(field "$MLOG" priv_mode) == "640:root:shadow" ]] \
      || die "managed: alice.user-privileged is $(field "$MLOG" priv_mode), expected 640:root:shadow.
At 0600 root:root the hash is unreadable to setgid-shadow unix_chkpwd, so a managed user logs in
at the greeter and then cannot unlock their own screen (plan/19 §2.3, §13.1)"
    [[ $(field "$MLOG" chkpwd) == yes ]] \
      || die "managed: alice could not prove her own password unprivileged (chkpwd=$(field "$MLOG" chkpwd)).
THIS IS THE LOCK SCREEN. kscreenlocker_greet is not setuid and runs as the user, so pam_unix
execs unix_chkpwd, which is setgid shadow — and that is the only path by which an unprivileged
caller can read a managed user's hash. rc=9 means it could not read the hash at all; rc=7 means
it read it and disagreed"
    [[ $(field "$MLOG" login) == yes ]] \
      || die "managed: alice could not log in on the console (login=$(field "$MLOG" login)).
unix_chkpwd already accepted her password, so the auth half works and the failure is in the
system-login stack itself — see the IMAGE-TEST-DETAIL login: lines above"
    [[ $(field "$MLOG" home) == yes ]] \
      || die "managed: no home directory was created for alice (home=$(field "$MLOG" home)).
The console login SUCCEEDED, so the session stack ran and pam_mkhomedir did not do its job. That
line is appended to /etc/pam.d/system-login by stage 40 and is shared with the domain feature"
    # T-MAN-2. carol is in the fixture's org and is NOT granted this device, so her hash was
    # never sent here — enforcement by absence (plan/19 §6.1).
    case "$(field "$MLOG" absent)" in
      yes) : ;;
      resolves) die "managed: carol RESOLVES on a device her bundle does not grant. The client is
  provisioning users the control plane did not send to this device (plan/19 §6.1)" ;;
      on-disk)  die "managed: carol's name appears under /etc/userdb on a device that may not log
  her in. Her password hash should never have reached this disk (plan/19 §8.3)" ;;
      *) die "managed: the absent-user check did not run (absent=$(field "$MLOG" absent))" ;;
    esac
    [[ $(field "$MLOG" sudoers) == yes ]] \
      || die "managed: /etc/sudoers.d/30-managed-admins was not written, so the bundle's admin
group grants nothing (plan/19 §6.2)"
    [[ $(field "$MLOG" subuid) == yes ]] \
      || die "managed: alice has no /etc/subuid range, so rootless podman cannot start a
container for her (plan/19 §8.2)"
    [[ $(field "$MLOG" sync_rc) == 0 ]] \
      || die "managed: ${DISTRO_ID}-managed sync exited $(field "$MLOG" sync_rc). It must exit 0 on
every path: a non-zero exit from a timer-driven oneshot on this OS is a failed unit, a failed
boot, and on the third one a rollback to the previous image (plan/19 §4.1)"
    [[ $(field "$MLOG" timer) == enabled ]] \
      || die "managed: ${DISTRO_ID}-managed-sync.timer is $(field "$MLOG" timer) after enrolling.
Enrolment is what enables it; without it the device never picks up a revoked account"
    [[ $(field "$MLOG" failed_units) == 0 ]] \
      || die "managed: the guest has failed units after enrolling ($(field "$MLOG" failed_list))"

    # T-MAN-8. Leaving must produce a working, unmanaged machine — not a machine with no
    # accounts. A household that stops paying must not lose its computers (plan/19 §8.9).
    [[ $(field "$MLOG" left) == ok ]] || die "managed: ${DISTRO_ID}-managed leave failed"
    [[ $(field "$MLOG" kept_uid) == yes ]] \
      || die "managed: after leaving, alice does not exist with her original uid
(kept_uid=$(field "$MLOG" kept_uid)). \`leave\` is supposed to materialise every managed user as a
LOCAL account with the same uid, so that every file in her home still belongs to her. Note the
ordering trap this catches: useradd asks getpwnam whether the name is taken, so materialising
before the userdb records are removed fails on every user and deletes the accounts instead"
    [[ $(field "$MLOG" kept_pw) == yes ]] \
      || die "managed: after leaving, alice's password no longer works (kept_pw=$(field "$MLOG" kept_pw)).
The crypt hash is copied out of the record into /etc/shadow by usermod -p"
    [[ $(field "$MLOG" userdb_after) == absent ]] \
      || die "managed: /etc/userdb survived the leave — the machine still has managed records
that nothing will ever refresh"
    [[ $(field "$MLOG" local_user) == yes ]] \
      || die "managed: the local $LIVE_USER account stopped resolving after leaving managed mode"
    log "managed tests passed: enrolled, authenticated alice unprivileged, logged in, left cleanly"
  fi
fi

stamp_write "$STAGE_NAME" "$(inputs_hash "$IMG")"
