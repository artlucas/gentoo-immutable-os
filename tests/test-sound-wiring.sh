#!/usr/bin/env bash
# The sound stack is wired across four files that have to agree, and nothing offline can boot
# the result — so this asserts the wiring itself. The bug it exists for: 0.3.0 shipped
# media-video/pipewire with its user units installed and NOTHING enabling them, so no sound
# server ran and KDE's volume applet reported "Connection to the sound service lost" on every
# login, while every stage-70 assertion stayed green.
export TEST_FILE_NAME=test-sound-wiring
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

CONFIGURE="$REPO_ROOT/scripts/stages/40-configure.sh"
TEST_STAGE="$REPO_ROOT/scripts/stages/70-test.sh"
REPORT="$REPO_ROOT/config/rootfs/usr/lib/image-test/test-report.sh.in"
DESKTOP_SET="$REPO_ROOT/config/portage/sets/desktop"
USE_FILE="$REPO_ROOT/config/portage/package.use/image"

# ---- the packages that put the units in the image ----------------------------------------
# Enabling a unit that was never installed is a stage-40 die, so these two come first.
assert_true "desktop set installs pipewire"    grep -qx 'media-video/pipewire' "$DESKTOP_SET"
assert_true "desktop set installs wireplumber" grep -qx 'media-video/wireplumber' "$DESKTOP_SET"
# sound-server is what builds pipewire-pulse — the PulseAudio-protocol daemon that plasma-pa
# (via media-libs/pulseaudio-qt) actually talks to. Without it the socket unit does not exist
# and no amount of enabling helps.
assert_true "pipewire is built with sound-server" \
    grep -qE '^media-video/pipewire\s+.*\bsound-server\b' "$USE_FILE"

# ---- stage 40 enables the user units ------------------------------------------------------
# preset-all covers SYSTEM units only; these are per-user and need --global.
assert_true "stage 40 enables the pipewire user units" \
    grep -q 'systemctl --global enable' "$CONFIGURE"
for u in pipewire.socket pipewire-pulse.socket wireplumber.service; do
    assert_true "stage 40 names $u" grep -q "PW_USER_UNITS=(.*$u" "$CONFIGURE"
done
# The regression guard, and the reason this is `enable` and not the tidier-looking mirror of the
# system path: Gentoo ships no catch-all user preset, so systemd's built-in policy is "enable"
# and `--global preset-all` pulls in every user unit with an [Install] section — measured on the
# 0.3.0 rootfs: podman.socket, podman.service, podman-auto-update.timer, speech-dispatcher.socket,
# the gpg-agent sockets. The podman ones contradict the rootless-only rule in 50-<id>.preset, and
# stage 50's guard only scans /etc/systemd/system, so nothing downstream would catch it.
# Comments stripped first — the block above says "--global preset-all" in prose, explaining
# exactly why it is not used, and that must not read as the thing it warns against.
assert_false "stage 40 does not blanket-preset user units" \
    grep -q -- '--global preset-all' <(sed 's/[[:space:]]*#.*$//' "$CONFIGURE")

# ---- stage 40 asserts the enablement actually took -----------------------------------------
# On the symlinks, not on systemctl's exit status: enablement that quietly did not take yields
# an image whose only symptom is a desktop with no audio.
assert_true "stage 40 verifies the pulse socket symlink" \
    grep -q 'sockets.target.wants/pipewire-pulse.socket' "$CONFIGURE"
assert_true "stage 40 verifies the wireplumber symlink" \
    grep -q 'pipewire.service.wants/wireplumber.service' "$CONFIGURE"

# ---- the live user reaches PipeWire's realtime limits --------------------------------------
# /etc/security/limits.d/25-pw-rlimits.conf grants rtprio 95 / nice -19 to @pipewire and nothing
# else, and this image has no rtkit-daemon to fall back to.
assert_true "live user is in the pipewire group" \
    grep -q 'LIVE_USER_GROUPS="wheel,video"' "$CONFIGURE"
assert_true "pipewire is appended to the group list" \
    grep -q 'LIVE_USER_GROUPS,pipewire' "$CONFIGURE"
# ...and not in "audio", on media-video/pipewire's own pkg_postinst advice: device access comes
# from logind/uaccess ACLs on the active session, and static audio-group membership breaks the
# device hand-off on fast user switching.
assert_false "live user is not put in the audio group" \
    grep -qE 'useradd .*-G [^ ]*\baudio\b' "$CONFIGURE"

# ---- the runtime probe and its assertion stay in step ---------------------------------------
# Two halves in two files: the guest reports sound=, stage 70 fails on it. Either one alone is
# silently useless, which is the failure mode this pair of assertions is for.
assert_true "self-test probes the pulse socket with pactl" \
    grep -q 'pactl info' "$REPORT"
assert_true "self-test reports a sound= field" \
    grep -q 'sound=\$sound' "$REPORT"
assert_true "self-test runs the probe as the live user" \
    grep -q "XDG_RUNTIME_DIR=/run/user/\$live_uid" "$REPORT"
# The headless guest never logs anyone in, so the probe has to bring a user manager up itself.
# It must do that with linger: `systemctl start user@<uid>.service` was measured timing out,
# because logind owns that unit and tears it down for a user with no session and no linger.
assert_true "self-test lingers the live user to get a user manager" \
    grep -q 'loginctl enable-linger' "$REPORT"
assert_false "self-test does not start user@ behind logind's back" \
    grep -qE '^\s*systemctl start "user@' "$REPORT"
# field() must ignore DETAIL lines, or a run that emits them reports empty values for every
# field and the failure is misattributed (it surfaced as "guest version=, expected 0.3.0").
assert_true "stage 70 field() filters DETAIL lines" \
    grep -q 'grep -v -- "\$MARKER-DETAIL"' "$TEST_STAGE"
assert_true "stage 70 asserts on the sound field" \
    grep -q 'field "\$slog" sound' "$TEST_STAGE"
assert_true "stage 70 fails when sound is not ok" \
    grep -q 'no sound server' "$TEST_STAGE"

finish
