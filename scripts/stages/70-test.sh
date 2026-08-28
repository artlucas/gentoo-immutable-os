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
ensure_dir "$OUT/logs"; exec > >(tee -a "$OUT/logs/$STAGE_NAME.log") 2>&1

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
field() { grep "$MARKER" "$1" | grep -v -- "$MARKER-DETAIL" | tail -n1 | tr ' ' '\n' | sed -n "s/^$2=//p"; }

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

  SLOG="$OUT/logs/update-test-boot1.serial.log"
  log "update test: booting base image, applying update from local server"
  boot_and_watch "$WORKIMG" "$SLOG" --test update --update-url "http://10.0.2.2:8000/$UPDATE_CHANNEL"
  # first marker comes from the OLD version confirming the update applied; the guest
  # then reboots into the new version and reports again on a second invocation:
  SLOG2="$OUT/logs/update-test-boot2.serial.log"
  boot_and_watch "$WORKIMG" "$SLOG2" --test update
  assert_report "$SLOG2" "$VERSION"
  log "update E2E passed: base image now runs $VERSION"
else
  # ---- T1: smoke, two boots ---------------------------------------------------------
  WORKIMG="$WORK/smoke-test.img"; cp --sparse=always -- "$IMG" "$WORKIMG"

  SLOG1="$OUT/logs/smoke-boot1.serial.log"
  log "smoke: first boot (repart growth, machine-id generation)"
  boot_and_watch "$WORKIMG" "$SLOG1" --test smoke
  assert_report "$SLOG1" "$VERSION"

  SLOG2="$OUT/logs/smoke-boot2.serial.log"
  log "smoke: second boot (persistence)"
  boot_and_watch "$WORKIMG" "$SLOG2" --test smoke
  assert_report "$SLOG2" "$VERSION"
  m1="$(field "$SLOG1" machine_id)"; m2="$(field "$SLOG2" machine_id)"
  [[ -n $m1 && $m1 == "$m2" ]] || die "machine-id did not persist across boots ($m1 vs $m2)"
  log "smoke tests passed"
fi

stamp_write "$STAGE_NAME" "$(inputs_hash "$IMG")"
