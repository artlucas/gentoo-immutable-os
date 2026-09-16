#!/usr/bin/env bash
# Managed mode (plan/19), offline.
#
# Everything asserted here is silent when it is wrong, which is the only reason it is asserted:
#
#   1. THE THREE SILENT RECORD FAILURES (§2.3). A userdb record with no <uid>.user symlink
#      resolves by name and not by number, so every `ls -l` in the user's own home prints a bare
#      number. A "memberOf" field in the record does NOTHING through NSS — membership is a FILE
#      NAME. And the mode on .user-privileged decides whether a person can unlock their own
#      screen. Each of the three produces a working-looking machine.
#   2. THE BOOT-INTEGRITY RULE (§8.1). A sync unit enabled on an image that never enrolled, or a
#      client that exits non-zero on a captive portal, is a failed boot — and three of those roll
#      the machine back to the previous image. This is the same failure sssd taught this project
#      in plan/18 §5.1, and the defences are checked here because none of them is observable
#      until the day a machine is somewhere with bad wifi.
#   3. THE TRUST PATH (§5.7). The client verifies a detached signature over the exact bytes it
#      was handed, before parsing them. A tampered bundle and a bundle signed by a key that is
#      not in the image must both be refused, and "refused" must not mean "crashed".
export TEST_FILE_NAME=test-managed
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e
load_config

VERIFY=yes
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER VERIFY FLATPAK_PREINSTALL
export DISTROBOX_DEFAULT_IMAGE MANAGED_API_BASE MANAGED_PUBRING

DST="$TMP/target"
install_rootfs_overlay "$REPO_ROOT/config/rootfs" "$DST"

GOLDEN="$TESTS_DIR/managed-golden"
CLI="$DST/usr/bin/${DISTRO_ID}-managed"

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

# ---- 1. it costs no packages ----------------------------------------------------------------
# The sharpest contrast with plan/18, and the claim plan/19 §9 rests on: the AD client cost 19
# atoms on desktop and 64 on console; this costs none. A @managed set appearing in a profile
# would mean the claim had quietly stopped being true.
assert_false "there is no @managed package set (managed mode adds no packages)" \
    test -f "$REPO_ROOT/config/portage/sets/managed"
for prof in "$REPO_ROOT"/config/profiles/*.conf; do
    p="$(basename -- "${prof%.conf}")"
    assert_false "profile $p does not name a 'managed' set" \
        grep -qE '^PROFILE_SETS="[^"]*\bmanaged\b' "$prof"
done
# ...and the interpreter it DOES make load-bearing. plan/06's interpreter policy says a
# whitelisted interpreter is a decision to record; this is the record, asserted so that a prune
# which removed python3 fails here rather than on a device that cannot enrol.
assert_true "the prune audit records python as held by the managed client" \
    grep -qi 'managed' "$REPO_ROOT/plan/10-prune-audit.md"

# ---- 2. what the image ships (§3) -----------------------------------------------------------
# None of these can be written later: there is no Portage on the target and /usr is read-only.
for f in "usr/bin/${DISTRO_ID}-managed" \
         "usr/bin/${DISTRO_ID}-managed-ui" \
         "usr/lib/systemd/system/${DISTRO_ID}-managed-sync.service" \
         "usr/lib/systemd/system/${DISTRO_ID}-managed-sync.timer" \
         "usr/lib/systemd/system/${DISTRO_ID}-managed-sync.service.d/10-conditional.conf" \
         "usr/lib/NetworkManager/dispatcher.d/50-${DISTRO_ID}-managed" \
         "usr/share/${DISTRO_ID}/managed-ui/main.qml" \
         "usr/share/applications/${DISTRO_ID}-managed-ui.desktop" \
         "usr/share/polkit-1/actions/org.${DISTRO_ID}.managed.policy"; do
    assert_file "$DST/$f" "the overlay installs /$f"
done
# The QML lives in a DIRECTORY carrying the distro id, which basename-only rebranding cannot
# reach — it shipped as /usr/share/distro/ until render_dest_dir existed, and nothing at runtime
# would have said so: the wrapper would simply have opened nothing.
assert_false "no un-rebranded /usr/share/distro directory survives" \
    test -d "$DST/usr/share/distro"
assert_eq "755" "$(stat -c '%a' "$DST/usr/lib/NetworkManager/dispatcher.d/50-${DISTRO_ID}-managed")" \
    "the dispatcher hook is executable (NetworkManager silently skips one that is not)"
assert_eq "755" "$(stat -c '%a' "$CLI")" "the client is executable"

# The front end is pure QML run by the bare qml6 runtime, and two things that a Kirigami app
# would normally take for granted are absent there. Both were found by RUNNING it against the
# built target's own Qt6, and both are silent: the app starts, and shows the wrong thing.
QML="$DST/usr/share/${DISTRO_ID}/managed-ui/main.qml"
# i18n() reaches QML through KLocalizedContext, which a C++ HOST application installs on the
# engine. qml6 installs nothing, so every i18n() call raises "ReferenceError: i18n is not
# defined" and renders an empty string — a window of blank labels.
#
# NB this is the STANDALONE app's QML. The Phase D KCM has its own main.qml in the overlay, and
# that one uses i18n() correctly and must keep doing so: it is loaded by a C++ host that installs
# the context. Two files, opposite rules, and the difference is which runtime opens them.
# Comment lines are stripped first: the file's own header EXPLAINS the absence of i18n(), and a
# check that could not tell an explanation from a call would forbid documenting the reason.
assert_false "the QML calls no i18n() (bare qml6 has no KLocalizedContext)" \
    bash -c "grep -vE '^[[:space:]]*(\*|//|/\*)' '$QML' | grep -q 'i18n('"
# Qt disables XMLHttpRequest on file:// by default. Without the opt-in the view reads its status
# file as an empty response and shows a machine that looks unenrolled.
assert_true "the wrapper enables local-file XHR for the status handoff" \
    grep -q 'QML_XHR_ALLOW_FILE_READ=1' "$DST/usr/bin/${DISTRO_ID}-managed-ui"
# The view cannot run a command, so the exit codes ARE its interface with the wrapper. If the two
# ever disagree, clicking Enrol silently does nothing.
for rc in 10 11 12; do
    assert_true "the QML and the wrapper agree on exit code $rc" \
        bash -c "grep -q 'Qt.exit($rc)' '$QML' && grep -q '^        $rc)' '$DST/usr/bin/${DISTRO_ID}-managed-ui'"
done

# ---- 3. the boot-integrity defences (§8.1) --------------------------------------------------
PRESET="$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
for u in "${DISTRO_ID}-managed-sync.timer" "${DISTRO_ID}-managed-sync.service"; do
    assert_true "the vendor preset disables $u" grep -qx "disable $u" "$PRESET"
done
DROPIN="$DST/usr/lib/systemd/system/${DISTRO_ID}-managed-sync.service.d/10-conditional.conf"
# The rendered path, not the template token: a Condition naming /var/lib/distro/... would make
# the unit skip forever on every machine, and a Condition naming nothing would make it run on
# machines that never enrolled. Both are silent.
assert_true "the drop-in carries the RENDERED enrollment.json path" \
    grep -qx "ConditionPathExists=/var/lib/${DISTRO_ID}/managed/enrollment.json" "$DROPIN"
assert_false "the drop-in has no unrendered token left in it" \
    grep -q '@DISTRO_ID@' "$DROPIN"
# The timer must install into timers.target, not multi-user.target: a timer wanted by
# multi-user.target is started, but `systemctl list-timers` and the timer ordering that goes with
# it belong to timers.target.
assert_true "the timer installs into timers.target" \
    grep -qx 'WantedBy=timers.target' "$DST/usr/lib/systemd/system/${DISTRO_ID}-managed-sync.timer"
assert_true "the sync service is a oneshot" \
    grep -qx 'Type=oneshot' "$DST/usr/lib/systemd/system/${DISTRO_ID}-managed-sync.service"
# Both stages assert that no enablement symlink survives. Losing either check loses the defence,
# and the loss is invisible until an unenrolled machine boots three times.
for f in scripts/stages/40-configure.sh scripts/stages/50-prune.sh; do
    assert_true "${f##*/} checks for enabled ${DISTRO_ID}-managed* units" \
        grep -q -- '-managed\*' "$REPO_ROOT/$f"
done
assert_true "stage 40 asserts /etc/userdb is NOT in the image (T-MAN-5)" \
    grep -q 'etc/userdb exists in the built image' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 asserts nss-systemd exports the shadow entry point" \
    grep -q '_nss_systemd_getspnam_r' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 50 re-asserts it after the prune" \
    grep -q '_nss_systemd_getspnam_r' "$REPO_ROOT/scripts/stages/50-prune.sh"

# ---- 4. the identity mechanism the image must already provide (§2) --------------------------
# nsswitch.conf is shipped in the read-only lower and is never edited by an enrolment, so the
# shadow line has to be right at BUILD time or managed users resolve and cannot log in.
NSS="$DST/etc/nsswitch.conf"
assert_true "nsswitch.conf's shadow line names the systemd module" \
    grep -qE '^shadow:[[:space:]]+files[[:space:]]+systemd[[:space:]]*$' "$NSS"
assert_true "nsswitch.conf's passwd line names the systemd module" \
    grep -qE '^passwd:.*[[:space:]]systemd[[:space:]]*$' "$NSS"
assert_true "nsswitch.conf's group line names the systemd module" \
    grep -qE '^group:.*[[:space:]]systemd[[:space:]]*$' "$NSS"

# ---- 5. --print-config against golden records (§12) -----------------------------------------
if [[ -z $PY ]]; then
    echo "  (no python3 on this host — skipping the record-rendering assertions)"
else
    FAKE="$TMP/fakeroot"
    mkdir -p "$FAKE/etc"
    printf 'root:x:0:0::/root:/bin/bash\nlive:x:1000:1000::/home/live:/bin/bash\n' > "$FAKE/etc/passwd"
    printf 'root:x:0:\nwheel:x:10:live\nshadow:x:42:\nlive:x:1000:\n' > "$FAKE/etc/group"

    RENDERED="$TMP/records.txt"
    "$PY" "$CLI" --print-config --bundle "$GOLDEN/bundle.json" --root "$FAKE" > "$RENDERED" 2>"$TMP/pc.err"
    assert_eq "0" "$?" "--print-config succeeds on the golden bundle"
    if diff -u "$GOLDEN/records.txt" "$RENDERED" > "$TMP/records.diff"; then
        _pass
    else
        _fail "rendered records differ from tests/managed-golden/records.txt:
$(head -40 "$TMP/records.diff")"
    fi

    # The three silent failures, asserted BY NAME as well as by the diff above — a golden file
    # regenerated by someone who did not know why they matter would keep the diff green.
    assert_true "the <uid>.user symlink is rendered (§2.3: without it getent passwd 5001 fails)" \
        grep -qx '===== /etc/userdb/5001.user -> alice.user =====' "$RENDERED"
    assert_true "the <gid>.group symlink is rendered" \
        grep -qx '===== /etc/userdb/5001.group -> alice.group =====' "$RENDERED"
    assert_true "membership is a FILE NAME, not a record field (§2.3)" \
        grep -qx '===== /etc/userdb/alice:immos-admins.membership (0644 root:root) =====' "$RENDERED"
    assert_false "no memberOf field is emitted (it does nothing through NSS)" \
        grep -q 'memberOf' "$RENDERED"
    # 0640 root:shadow, NOT 0600 root:root. Settled by probe against the built 0.3.0 target:
    # at 0600 a user authenticates at the greeter (where PAM is root) and cannot unlock their
    # own screen (where kscreenlocker_greet is not), because unix_chkpwd is setgid shadow.
    assert_true "the password hash is 0640 root:shadow" \
        grep -qx '===== /etc/userdb/alice.user-privileged (0640 root:shadow) =====' "$RENDERED"
    assert_false "the password hash is NOT 0600 root:root" \
        grep -q 'user-privileged (0600' "$RENDERED"

    # §6.1 / T-MAN-2: a user the bundle does not grant this device does not merely fail to log
    # in — they do not exist here, and their hash was never written.
    assert_false "carol has no record on a device that may not log her in" \
        grep -q 'carol' "$RENDERED"
    assert_false "carol's hash appears nowhere in the rendered output" \
        grep -q 'NEVERSENTTOTHISDEVICE' "$RENDERED"

    # §6.2: managed administrators get their own group, never wheel. wheel is the LOCAL
    # administrator's, and that account is the way back in when the control plane is gone.
    assert_true "the admin group gets a sudoers drop-in" \
        grep -q '30-managed-admins' "$RENDERED"
    assert_false "no managed user is added to wheel by the client" \
        grep -qE '^%wheel' "$RENDERED"
    assert_true "the flatpak install policy is rendered as a polkit rule (§6.3)" \
        grep -q '52-managed-flatpak.rules' "$RENDERED"
    assert_false "flatpak allow/deny lists are NOT enforced in v1" \
        grep -q 'app-run\|launch' "$RENDERED"

    # §2.4: the UID window /etc/login.defs bounds the greeter's user list by. Outside it the
    # account exists, logs in, and never appears on the login screen.
    OUT_OF_RANGE="$TMP/oob.json"
    sed 's/"uid": 5001/"uid": 999/' "$GOLDEN/bundle.json" > "$OUT_OF_RANGE"
    "$PY" "$CLI" --print-config --bundle "$OUT_OF_RANGE" --root "$FAKE" >/dev/null 2>"$TMP/oob.err"
    assert_false "a uid below 1000 is refused (§2.4)" test "$?" -eq 0
    assert_contains "outside" "$(cat "$TMP/oob.err")" "...and the refusal says why"
    sed 's/"uid": 5001/"uid": 70000/' "$GOLDEN/bundle.json" > "$OUT_OF_RANGE"
    "$PY" "$CLI" --print-config --bundle "$OUT_OF_RANGE" --root "$FAKE" >/dev/null 2>&1
    assert_false "a uid above 60000 is refused (§2.4)" test "$?" -eq 0

    # §1: managed accounts must not land in the local administrator's namespace. A name
    # collision there is a silent takeover rather than an error.
    COLLIDE="$TMP/collide.json"
    sed 's/"name": "alice"/"name": "live"/; s/"alice", "bobby"/"live", "bobby"/' \
        "$GOLDEN/bundle.json" > "$COLLIDE"
    "$PY" "$CLI" --print-config --bundle "$COLLIDE" --root "$FAKE" >/dev/null 2>"$TMP/collide.err"
    assert_false "a managed user colliding with a LOCAL account is refused" test "$?" -eq 0
    assert_contains "LOCAL" "$(cat "$TMP/collide.err")" "...and the refusal names the collision"

    # A membership naming a group that exists neither locally nor in the bundle would create a
    # dangling .membership file that resolves to nothing.
    DANGLE="$TMP/dangle.json"
    sed 's/"immos-admins", "wheel"/"immos-admins", "nosuchgroup"/' "$GOLDEN/bundle.json" > "$DANGLE"
    "$PY" "$CLI" --print-config --bundle "$DANGLE" --root "$FAKE" >/dev/null 2>&1
    assert_false "a membership in an undefined group is refused" test "$?" -eq 0

    # ---- 6. the trust path (§5.7) ------------------------------------------------------------
    if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
        KR="$TMP/keyring.gpg"
        # Dearmoring here is not incidental: it is the SAME conversion stage 40 does, so a key
        # that cannot survive it fails in the test suite rather than in the image.
        gpg --dearmor < "$REPO_ROOT/$MANAGED_PUBRING" > "$KR" 2>/dev/null
        assert_true "\$MANAGED_PUBRING dearmors to a non-empty keyring" test -s "$KR"

        # Driven through the client itself rather than through gpgv directly: the thing under
        # test is what the client accepts, not what gpgv accepts.
        cat > "$TMP/verify.py" <<PYEOF
import importlib.util, sys
spec = importlib.util.spec_from_loader("mgd", loader=None)
mod = importlib.util.module_from_spec(spec)
src = open("$CLI").read().replace('if __name__ == "__main__":', 'if False:')
exec(compile(src, "$CLI", "exec"), mod.__dict__)
data = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "r").read()
try:
    mod.verify_signature(data, sig, keyring="$KR")
    print("VERIFIED")
except Exception as e:
    print("REFUSED")
PYEOF
        R="$("$PY" "$TMP/verify.py" "$GOLDEN/bundle.json" "$GOLDEN/bundle.sig" 2>/dev/null)"
        assert_eq "VERIFIED" "$R" "a good signature over the golden bundle verifies"

        # One byte, in the BUNDLE. A client that re-serialised what it parsed before checking
        # would still accept this, and that is the bug §5.7 exists to make impossible.
        sed 's/"serial": 412/"serial": 413/' "$GOLDEN/bundle.json" > "$TMP/tampered.json"
        R="$("$PY" "$TMP/verify.py" "$TMP/tampered.json" "$GOLDEN/bundle.sig" 2>/dev/null)"
        assert_eq "REFUSED" "$R" "a bundle with one byte changed is refused"

        R="$("$PY" "$TMP/verify.py" "$GOLDEN/bundle.json" "$GOLDEN/bundle-untrusted.sig" 2>/dev/null)"
        assert_eq "REFUSED" "$R" "a bundle signed by a key not in the image is refused"

        # ---- 6b. `apply`: the offline half of sync (plan/21 §6) ---------------------------
        # The installer's accounts page enrols before the disk is written, so by the time the
        # target exists there is already a verified bundle in the state directory and asking the
        # control plane again could only lose — a machine whose network dropped in between would
        # get no accounts at all. `apply` is what renders that cached bundle into a root with no
        # network, and it is the SAME code path `sync` uses: apply_bundle() is called by both.
        #
        # This is also the assertion that justifies the shape of the transplant. accountsetup
        # copies the state directory and NOT /etc, because /etc/subuid is an append to a file the
        # target already has — so the last check here is that the live user's range survives.
        AR="$TMP/applyroot"
        mkdir -p "$AR/etc" "$AR/var/lib/$DISTRO_ID/managed"
        printf 'root:x:0:0::/root:/bin/bash\nlive:x:1000:1000::/home/live:/bin/bash\n' > "$AR/etc/passwd"
        printf 'root:x:0:\nwheel:x:10:live\nshadow:x:42:\nlive:x:1000:\n' > "$AR/etc/group"
        printf 'live:100000:65536\n' > "$AR/etc/subuid"
        printf 'live:100000:65536\n' > "$AR/etc/subgid"
        cp "$GOLDEN/bundle.json" "$AR/var/lib/$DISTRO_ID/managed/bundle.json"
        cp "$GOLDEN/bundle.sig"  "$AR/var/lib/$DISTRO_ID/managed/bundle.sig"

        mgd_apply() {
            _MANAGED_TEST_SKIP_ROOT=1 _MANAGED_TEST_KEYRING="$KR" \
                "$PY" "$CLI" apply --root "$AR" "$@" 2>&1
        }

        # Not enrolled: refused, and named as such. This is the one precondition `apply` has that
        # `--print-config` does not — a root with a bundle and no enrolment is a root that has no
        # business being managed.
        OUT="$(mgd_apply)"; rc=$?
        assert_true "apply refuses a root that is not enrolled" bash -c "[[ $rc -ne 0 ]]"
        assert_contains "not enrolled" "$OUT" "...and says which precondition failed"

        printf '{"device_id":"dev-1","device_secret":"s","org":{"name":"Test"},"api_base":"https://x"}\n' \
            > "$AR/var/lib/$DISTRO_ID/managed/enrollment.json"
        OUT="$(mgd_apply)"; rc=$?
        assert_eq "0" "$rc" "apply succeeds on a cached, correctly signed bundle with no network"
        assert_contains "applied bundle serial 412" "$OUT" "and reports the serial it applied"

        # The records themselves, including the two symlinks and the membership FILE NAME that
        # §2.3 measured as silent failures. The golden diff above proves render(); this proves the
        # writes actually happen through this command.
        assert_true "apply writes the user record" test -f "$AR/etc/userdb/alice.user"
        assert_true "...the <uid>.user symlink getent needs" test -L "$AR/etc/userdb/5001.user"
        assert_true "...and the membership file" \
            test -f "$AR/etc/userdb/alice:${DISTRO_ID}-admins.membership"
        # 0640 root:shadow, not 0600: at 0600 a managed user can log in at the greeter and cannot
        # unlock their own screen, because unix_chkpwd runs as them (plan/19 §13.1, measured).
        assert_eq "640" "$(stat -c '%a' "$AR/etc/userdb/alice.user-privileged")" \
            "the privileged record is 0640, not 0600"

        # THE PROPERTY THE WHOLE TRANSPLANT DESIGN RESTS ON: subuid is an APPEND. A copy of the
        # scratch root's /etc/subuid would have clobbered this line, and rootless podman for the
        # local user would have stopped working months later, for no visible reason.
        assert_true "apply appends its own subuid range" \
            grep -qE '^alice:' "$AR/etc/subuid"
        assert_true "...and leaves the local user's range alone" \
            grep -qx 'live:100000:65536' "$AR/etc/subuid"
        assert_true "...same for subgid" \
            bash -c "grep -qE '^alice:' '$AR/etc/subgid' && grep -qx 'live:100000:65536' '$AR/etc/subgid'"

        # Anti-rollback, through the same code sync uses. An old, correctly signed bundle is a
        # valid bundle, and replaying one is the cheapest attack on an offline policy system.
        printf '999\n' > "$AR/var/lib/$DISTRO_ID/managed/serial"
        OUT="$(mgd_apply)"; rc=$?
        assert_true "apply refuses a bundle older than the high-water serial" bash -c "[[ $rc -ne 0 ]]"
        assert_contains "REFUSED a bundle with serial 412" "$OUT" "...naming both serials"
        printf '412\n' > "$AR/var/lib/$DISTRO_ID/managed/serial"

        # And a tampered bundle, because the verify-before-parse discipline has to hold on this
        # path too — it is the one path where the bytes came off local disk rather than the wire.
        sed 's/"serial": 412/"serial": 413/' "$GOLDEN/bundle.json" \
            > "$AR/var/lib/$DISTRO_ID/managed/bundle.json"
        OUT="$(mgd_apply)"; rc=$?
        assert_true "apply refuses a cached bundle whose bytes were edited" bash -c "[[ $rc -ne 0 ]]"
    else
        echo "  (gpg/gpgv absent — skipping the signature assertions)"
    fi

    # ---- 7. the failure discipline (§4.1) ----------------------------------------------------
    # THE ASSERTION THAT PROTECTS THE FLEET. An exit code from a timer-driven oneshot on this OS
    # is a failed unit, a failed boot, and eventually an automatic rollback — triggered, in the
    # field, by hotel wifi. Every one of these is a real failure injected at a different layer.
    SR="$TMP/syncroot"
    mkdir -p "$SR/etc" "$SR/var/lib/$DISTRO_ID/managed"
    cp "$FAKE/etc/passwd" "$FAKE/etc/group" "$SR/etc/"
    run_sync() {  # label; everything after it is the state to sync against
        _MANAGED_TEST_SKIP_ROOT=1 _MANAGED_TEST_ALLOW_HTTP=1 \
            "$PY" "$CLI" sync --root "$SR" --quiet >/dev/null 2>&1
        assert_eq "0" "$?" "sync exits 0 $1"
    }
    run_sync "when the machine is not enrolled at all"

    printf '{"device_id":"dev_x","device_secret":"s","api_base":"https://127.0.0.1:1","org":{"name":"o"}}\n' \
        > "$SR/var/lib/$DISTRO_ID/managed/enrollment.json"
    run_sync "when the control plane is unreachable (the hotel-wifi case)"

    printf '{"device_id":"dev_x","device_secret":"s","api_base":"http://127.0.0.1:1","org":{"name":"o"}}\n' \
        > "$SR/var/lib/$DISTRO_ID/managed/enrollment.json"
    run_sync "when the API base is not even https"

    printf 'not json at all' > "$SR/var/lib/$DISTRO_ID/managed/enrollment.json"
    run_sync "when enrollment.json is corrupt"

    printf '{"device_id":"dev_x"}\n' > "$SR/var/lib/$DISTRO_ID/managed/enrollment.json"
    run_sync "when enrollment.json is missing half its keys"

    # ...and status, the thing a human runs when something is wrong, must work on every one of
    # those states without touching the network.
    _MANAGED_TEST_SKIP_ROOT=1 "$PY" "$CLI" status --root "$SR" >/dev/null 2>&1
    assert_eq "0" "$?" "status exits 0 on a broken enrolment"
    _MANAGED_TEST_SKIP_ROOT=1 "$PY" "$CLI" status --root "$TMP/nothing" >/dev/null 2>&1
    assert_eq "0" "$?" "status exits 0 on a machine that has never enrolled"

    # ---- 8. the request shapes §5 specifies ---------------------------------------------------
    # Pinned so that a server change which breaks them fails here rather than in the field.
    SRC="$(cat "$CLI")"
    for path in '/v1/enroll' '/v1/devices/%s/bundle' '/v1/devices/%s/heartbeat' \
                '/v1/devices/%s/events' '/v1/devices/%s/password' '/v1/devices/%s/unenroll'; do
        assert_contains "$path" "$SRC" "the client uses the §5.3 path $path"
    done
    assert_contains "If-None-Match" "$SRC" "bundle fetches are conditional (§5.3)"
    assert_contains "Idempotency-Key" "$SRC" "POSTs carry an idempotency key (§5.1)"
    assert_contains "next_secret" "$SRC" "the client honours server-driven secret rotation (§5.2)"
    # §5.8 rule 2: no endpoint is on the authentication path, and none may become one. The
    # cheapest true check is that the client never talks to the network to answer a login.
    assert_false "nothing in the client authenticates a user over the network" \
        grep -qE 'def (authenticate|check_password)\b' "$CLI"
fi

# ---- 9. mode exclusivity, in both directions (§8.7, T-MAN-7) --------------------------------
DOMAIN_CLI="$DST/usr/bin/${DISTRO_ID}-domain"
assert_true "${DISTRO_ID}-domain join refuses on a machine enrolled in managed mode" \
    grep -q "managed/enrollment.json" "$DOMAIN_CLI"
# Matched on the suffix, not on the rendered id: the bash sibling writes "${ID}-managed leave",
# which expands at RUN time rather than at template-render time.
assert_true "...and the refusal names the way out" \
    grep -q -- '-managed leave' "$DOMAIN_CLI"
assert_true "${DISTRO_ID}-managed enroll refuses on a machine joined to a domain" \
    grep -q 'etc/sssd/sssd.conf' "$CLI"
assert_true "...and that refusal names the way out too" \
    grep -q -- "-domain leave" "$CLI"
# Preflight in both: a refusal that happens after the first write is not a refusal.
assert_true "the domain refusal is preflight, before adcli runs" \
    "$PY" -c "
import sys
src = open('$DOMAIN_CLI').read()
sys.exit(0 if src.index('managed/enrollment.json') < src.index('adcli join') else 1)"

# ---- 10. the API fixture (Phase B) ----------------------------------------------------------
# It is optional by construction — every offline build and this suite work with it absent — but
# what it contains is not optional, because stage 70 assumes each piece.
assert_file "$TESTS_DIR/managed-api/Dockerfile" "the API fixture has a Dockerfile"
assert_file "$TESTS_DIR/managed-api/app.py" "the API fixture has its FastAPI app"
assert_file "$TESTS_DIR/managed-api/entrypoint.sh" "the API fixture has an entrypoint"
assert_file "$TESTS_DIR/managed-api/keys/signing-key.asc" "the fixture carries a signing key"
assert_true "the fixture is built FROM the pinned builder, like tests/ad-dc" \
    grep -q 'ARG BUILDER_TAG' "$TESTS_DIR/managed-api/Dockerfile"
assert_true "the fixture's python dependencies are pinned to exact versions" \
    grep -qE "'fastapi==[0-9]" "$TESTS_DIR/managed-api/Dockerfile"
# The fixture signs with the private half of the key the image trusts. If those two ever stop
# being a pair, every stage-70 sync fails on a bad signature and the cause is two files apart.
if command -v gpg >/dev/null 2>&1; then
    PUB_FPR="$(gpg --show-keys --with-colons "$REPO_ROOT/$MANAGED_PUBRING" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}')"
    SEC_FPR="$(gpg --show-keys --with-colons "$TESTS_DIR/managed-api/keys/signing-key.asc" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}')"
    assert_eq "$PUB_FPR" "$SEC_FPR" \
        "the fixture's signing key is the pair of the one baked into the image"
    assert_contains "TEST KEY" \
        "$(gpg --show-keys "$REPO_ROOT/$MANAGED_PUBRING" 2>/dev/null)" \
        "the committed default key says it is a test key (stage 40 warns on exactly this)"
fi

# ---- 10b. Phase D: the in-repo ebuild repository ---------------------------------------------
# Two things managed mode ships have to be COMPILED against the target's own Qt6/KF6 — a Plasma
# KCM and a Calamares view module — and neither can be a script. Everything asserted here is
# structure that portage reads silently: a repository it cannot key, an ebuild it cannot find, a
# category it does not accept. In each case the repository looks present and has no packages in
# it, and nothing says so.
OVL="$REPO_ROOT/config/portage/overlay"
assert_file "$OVL/metadata/layout.conf" "the overlay has a layout.conf"
assert_true "the overlay declares masters = gentoo (eclasses, licences, categories)" \
    grep -qE '^masters = gentoo$' "$OVL/metadata/layout.conf"
assert_true "the overlay uses thin manifests (no SRC_URI means no Manifest to write)" \
    grep -qE '^thin-manifests = true$' "$OVL/metadata/layout.conf"
assert_file "$OVL/profiles/repo_name.in" "the overlay's repo_name is a template, so it follows DISTRO_ID"
assert_file "$OVL/profiles/categories.in" "...and so is its category list"
# Rendered, the repo name must equal DISTRO_ID: portage keys a repository by that file, and a
# mismatch makes every ::<id> atom unresolvable while the repository itself looks fine.
OVL_DST="$TMP/overlay"
install_rootfs_overlay "$OVL" "$OVL_DST"
assert_eq "$DISTRO_ID" "$(tr -d '[:space:]' < "$OVL_DST/profiles/repo_name")" \
    "the rendered repo_name is DISTRO_ID"
assert_eq "${DISTRO_ID}-base" "$(tr -d '[:space:]' < "$OVL_DST/profiles/categories")" \
    "the rendered category is <id>-base"
assert_true "the category directory is rebranded too" test -d "$OVL_DST/${DISTRO_ID}-base"
assert_false "no un-rebranded distro-base directory survives" test -d "$OVL_DST/distro-base"
# Portage looks an ebuild up at <category>/<pn>/<pn>-<pv>.ebuild. A rebranding rule that ever
# disagreed with itself between the directory and the file would produce a repository with no
# packages and no error.
EB_N=0
while IFS= read -r eb; do
    EB_N=$((EB_N + 1))
    ebdir="$(basename -- "$(dirname -- "$eb")")"
    ebfile="$(basename -- "$eb")"
    assert_eq "$ebdir" "${ebfile%-*}" "$(basename "$eb") sits in a directory of its own name"
    assert_false "$(basename "$eb") has no unrendered token left in it" \
        grep -q '@[A-Z][A-Z0-9_]*@' "$eb"
done < <(find "$OVL_DST" -name '*.ebuild')
# Six since plan/25: the managed-mode KCM, the accounts page, the language page, the greeting page,
# the disk page and the applications page. A count rather than a set, so adding a seventh has to be
# argued for in a diff — this repository's ebuild repository exists for the handful of things that
# must be compiled against the target's own Qt6/KF6, and it is not a place to keep packages that
# could be files in config/rootfs. (The fourth was a SPLIT of the third rather than a new
# capability: a Calamares view step is one entry in the sidebar, so the language page's two screens
# had to become two modules. The fifth is a REPLACEMENT: it takes the stock partition module out of
# both sequences. The sixth replaces nothing — no stock module ever asked which applications to
# add.)
assert_eq "6" "$EB_N" "the overlay renders exactly its six ebuilds"
# EAPI 8 and no SRC_URI: the sources are in files/, which is what makes these buildable with
# --network none and what removes the need for a Manifest.
while IFS= read -r eb; do
    assert_true "$(basename "$eb") declares EAPI=8" grep -qx 'EAPI=8' "$eb"
    assert_false "$(basename "$eb") has no SRC_URI" grep -qE '^SRC_URI=' "$eb"
    assert_true "$(basename "$eb") copies its sources from FILESDIR" grep -q 'FILESDIR' "$eb"
done < <(find "$OVL_DST" -name '*.ebuild')
# The sources must NOT be templates: a .cpp with @TOKEN@ in it does not compile, does not lint
# and does not open in an editor. The distro id arrives as a compile definition instead.
assert_false "no C++ or QML source in the overlay is a template" \
    bash -c "find '$OVL' \( -name '*.cpp' -o -name '*.h' -o -name '*.qml' \) -name '*.in' | grep -q ."
# ...and the converse of the standalone app's rule, asserted so that nobody "fixes" one to match
# the other: the KCM's QML is loaded by a C++ host that DOES install a KLocalizedContext, so its
# strings are translatable and should stay wrapped.
assert_true "the KCM's QML uses i18n() (its host installs a KLocalizedContext)" \
    grep -q 'i18n(' "$OVL/distro-base/distro-kcm-managed/files/ui/main.qml"
assert_true "the KCM takes the distro id as a compile definition" \
    grep -q 'DISTRO_ID' "$OVL/distro-base/distro-kcm-managed/files/CMakeLists.txt"
# The KCM must land where System Settings looks, and nowhere else is equivalent.
assert_true "the KCM installs into plasma/kcms/systemsettings" \
    grep -q 'kcmutils_add_qml_kcm' "$OVL/distro-base/distro-kcm-managed/files/CMakeLists.txt"
assert_file "$OVL/distro-base/distro-kcm-managed/files/kcm_managed.json" \
    "the KCM carries the plugin metadata System Settings reads out of the .so"
assert_true "...including the parent category, without which it is kcmshell-only" \
    grep -q 'X-KDE-System-Settings-Parent-Category' \
    "$OVL/distro-base/distro-kcm-managed/files/kcm_managed.json"
# The Calamares module: a view module, built out of tree against the installed Calamares. Since
# plan/21 it is the accounts page — one page carrying all three identity modes — and enrolment is
# the second of them rather than a screen of its own.
PAGE="$OVL/distro-base/distro-calamares-accounts/files"
assert_true "the installer page uses upstream's own calamares_add_plugin" \
    grep -q 'calamares_add_plugin' "$PAGE/CMakeLists.txt"
assert_true "...declared as a viewmodule (a job cannot draw a page)" \
    grep -q 'TYPE viewmodule' "$PAGE/CMakeLists.txt"
assert_true "...and found with find_package(Calamares), not a vendored copy" \
    grep -q 'find_package(Calamares REQUIRED)' "$PAGE/CMakeLists.txt"
# The QML travels inside the .so. A second install path is a page that renders blank on a medium
# nobody can fix, with nothing in the log (plan/21 §2).
assert_true "the page's QML is compiled into the plugin as a Qt resource" \
    grep -q 'qt6_add_resources' "$PAGE/CMakeLists.txt"
assert_true "...and the C++ loads it from qrc:, not from a filesystem path" \
    grep -q 'qrc:/accounts/qml/Accounts.qml' "$PAGE/AccountsViewStep.cpp"
for q in Accounts ComputerNameField LocalForm ManagedForm DomainForm; do
    assert_file "$PAGE/qml/$q.qml" "the page ships qml/$q.qml"
    assert_true "...and CMakeLists lists it in the resource, or it is not in the .so" \
        grep -qF "qml/$q.qml" "$PAGE/CMakeLists.txt"
done

# The PACKAGED FALLBACK config, and the one line that decides whether it exists on disk.
# calamares_add_plugin() globs *.conf out of the plugin directory and then guards the install on
# `if(INSTALL_CONFIG)` — an option Calamares' own top-level CMakeLists defines and
# CalamaresConfig.cmake does not export, so out of tree it is undefined and the file is silently
# not installed. Measured on a built target root: /usr/share/calamares/modules/ held no
# accounts.conf until this was set. Nothing warned, because the glob DID find the file, so the
# macro also skipped its "NO_CONFIG should be set." advice.
assert_file "$PAGE/accounts.conf" "the plugin ships a fallback configuration"
assert_true "...and turns on the option that actually installs it" \
    grep -qE '^set\(INSTALL_CONFIG ON\)' "$PAGE/CMakeLists.txt"
# NO_CONFIG is the other way to silence that glob, and it would be a disaster here: it stamps
# `noconfig: true` into module.desc, and Calamares then never calls setConfigurationMap() at
# all — no modes offered, no groups, an empty page.
assert_false "...and does not claim to have no configuration" \
    bash -c "grep -E '^[^#]*NO_CONFIG' '$PAGE/CMakeLists.txt' | grep -q NO_CONFIG"
# qsTr, not i18n: the bare Qt Quick engine Calamares hosts installs no KLocalizedContext, and
# i18n() there is a ReferenceError and an empty string (plan/19 §7.2, measured).
# Comment lines excluded, because the file that explains why i18n() is wrong necessarily
# contains the string. A grep that cannot tell the two apart is a grep that has to be relaxed
# the first time somebody documents the rule.
assert_true "the page's QML does not call i18n() (nothing installs a KLocalizedContext)" \
    bash -c "python3 - <<'EOF'
import pathlib, sys
for f in pathlib.Path('$PAGE/qml').glob('*.qml'):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(('*', '/*', '//')):
            continue
        if 'i18n(' in stripped:
            sys.exit('%s:%d calls i18n()' % (f.name, n))
EOF"
assert_true "...it uses qsTr() instead" bash -c "grep -rq 'qsTr(' '$PAGE/qml'"

# THE STYLE, AND WHY THE GUARD IN FRONT OF IT IS PART OF THE CONTRACT.
# Kirigami picks its platform integration plugin from the Qt Quick Controls style's name, and
# that plugin is what initialises the icon theme — so the wrong style is not a cosmetic
# difference on this page, it is Breeze colours, Breeze metrics AND every icon, all at once.
# The guard cannot be `QQuickStyle::name().isEmpty()`: name() resolves a style and reports the
# answer rather than reporting that nobody chose, and measured in the medium's own Qt under the
# environment `pkexec calamares` gets, that answer is "Fusion". The environment variable is the
# only thing here that expresses a choice, and pkexec strips the one Plasma exports.
assert_true "the page asks for the desktop Qt Quick Controls style" \
    grep -qF 'setStyle( QStringLiteral( "org.kde.desktop" ) )' "$PAGE/AccountsViewStep.cpp"
assert_true "...gated on the environment, which is the only place a style can be chosen" \
    grep -qF 'qEnvironmentVariableIsEmpty( "QT_QUICK_CONTROLS_STYLE" )' "$PAGE/AccountsViewStep.cpp"
# Comment lines excluded: the comment that explains why this guard is wrong has to quote it.
assert_false "...and not on QQuickStyle::name(), which is never empty" \
    bash -c "grep -vE '^[[:space:]]*(//|/\*|\*)' '$PAGE/AccountsViewStep.cpp' | grep -q 'name().isEmpty()'"

# THE CHOOSER'S ROWS DO NOT INHERIT THE INDICATOR'S SIDE FROM THE STYLE.
# RadioDelegate draws its indicator at leftPadding in qqc2-desktop-style and at
# `width - width - rightPadding` in Qt's Basic and Fusion — the far end of a row whose text is on
# the left — and Fusion also fills every delegate with palette.base, an opaque white slab per
# row. RadioButton is the control all three put at leftPadding, and Basic and Fusion decide that
# by asking whether `text` is set, so the bullet lands in the middle of the row without it.
# Comment lines excluded here too, for the same reason: the comment above the delegate names the
# control it is deliberately not using.
assert_false "the chooser does not use the control whose indicator changes sides" \
    bash -c "grep -vE '^[[:space:]]*(//|/\*|\*)' '$PAGE/qml/Accounts.qml' | grep -q 'RadioDelegate'"
assert_true "...it uses RadioButton" \
    grep -qF 'QQC2.RadioButton' "$PAGE/qml/Accounts.qml"
# On the CONTROL, not on the label inside it — the title is drawn by a Label in the contentItem
# and binds the same expression, so a grep for the string alone passes with the control's own
# text gone, which is the state that moves the bullet.
assert_true "...with text set on the control, which is what Basic and Fusion place the indicator by" \
    bash -c "python3 - <<'EOF'
import pathlib, sys
lines = pathlib.Path('$PAGE/qml/Accounts.qml').read_text().splitlines()
try:
    start = next(n for n, l in enumerate(lines) if 'delegate: QQC2.RadioButton' in l)
except StopIteration:
    sys.exit('the chooser delegate is not a RadioButton')
for line in lines[start + 1:]:
    stripped = line.strip()
    if stripped.startswith('contentItem:'):
        sys.exit('the RadioButton sets no text of its own before its contentItem')
    if stripped.startswith('text:'):
        break
EOF"
assert_true "...and a ground of its own, transparent until the row is hovered or chosen" \
    bash -c "grep -A8 'background: Rectangle' '$PAGE/qml/Accounts.qml' | grep -q '\"transparent\"'"

# ...AND EVERY Q_PROPERTY MUST BE ABLE TO CHANGE, or the page freezes silently. This page has no
# OK button of its own: it drives Calamares' Next entirely through property notifications, so a
# property declared with a NOTIFY signal that nothing ever emits is a field a person can type
# into while Next stays grey forever. CONSTANT is the other legal answer, and the right one for
# the three `<mode>Offered` flags and the organisation hint — they are read out of accounts.conf
# before the QQuickWidget is constructed (widget() is lazy; setConfigurationMap has already run)
# and cannot change afterwards.
assert_true "every Q_PROPERTY is CONSTANT or has a NOTIFY signal that is actually emitted" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys

hdr = pathlib.Path('$PAGE/AccountsConfig.h').read_text()
cpp = pathlib.Path('$PAGE/AccountsConfig.cpp').read_text()
emitted = set(re.findall(r'emit\s+(\w+)\s*\(', cpp))

props = re.findall(r'Q_PROPERTY\(\s*[\w:<>\s\*]+?\s+(\w+)\s+READ\s+\w+(.*?)\)', hdr, re.S)
if len(props) < 20:
    sys.exit('parsed only %d Q_PROPERTYs — the extraction is broken' % len(props))
dead = []
for name, rest in props:
    if 'CONSTANT' in rest:
        continue
    m = re.search(r'NOTIFY\s+(\w+)', rest)
    if not m:
        dead.append('%s has neither NOTIFY nor CONSTANT' % name)
    elif m.group(1) not in emitted:
        dead.append('%s notifies %s, which nothing emits' % (name, m.group(1)))
if dead:
    sys.exit('; '.join(dead))
EOF"

# EVERY `accounts.<x>` IN THE QML MUST EXIST ON THE C++ OBJECT, and nothing else checks this.
# The config reaches QML as a context property, so a name that is not there is not a build
# error and not a runtime error either: the engine logs one warning to a console nobody is
# watching and evaluates the binding as undefined. A renamed Q_PROPERTY therefore produces a
# page that draws correctly and does nothing — a disabled Next that no field can enable, or a
# button whose onClicked calls a slot that is not there. The compile cannot catch it; this can.
#
# Resolvable means: a Q_PROPERTY, a member of `public Q_SLOTS:` (which is how the setters and
# the three actions are exposed — Q_INVOKABLE would do as well and neither is used here), or an
# enumerator of a Q_ENUM. Comment lines are stripped first, for the reason the i18n check above
# strips them.
assert_true "every accounts.* binding in the QML resolves to a property, slot or enum" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys

hdr = pathlib.Path('$PAGE/AccountsConfig.h').read_text()
known = set(re.findall(r'Q_PROPERTY\(\s*[\w:<>\s\*]+?\s+(\w+)\s', hdr))
known |= set(re.findall(r'Q_INVOKABLE\s+[\w:<>\s\*&]+?\s+(\w+)\s*\(', hdr))
# public Q_SLOTS: up to the next section marker. Only slots are callable from QML; a plain
# public method compiles and then is not there at runtime, which is the trap this closes.
m = re.search(r'public Q_SLOTS:(.*?)(?:^Q_SIGNALS:|^private:|^protected:)', hdr, re.S | re.M)
if not m:
    sys.exit('AccountsConfig.h has no public Q_SLOTS: section')
known |= set(re.findall(r'\b(\w+)\s*\(', m.group(1)))
for e in re.finditer(r'enum\s+\w+\s*\{([^}]*)\}', hdr):
    known |= {t for t in re.findall(r'(\w+)', e.group(1)) if t[:1].isupper()}

bad = []
for f in sorted(pathlib.Path('$PAGE/qml').glob('*.qml')):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        if line.strip().startswith(('*', '/*', '//')):
            continue
        for name in re.findall(r'\baccounts\.(\w+)', re.sub(r'//.*\$', '', line)):
            if name not in known:
                bad.append('%s:%d accounts.%s' % (f.name, n, name))
if bad:
    sys.exit('not on AccountsConfig: ' + ', '.join(bad))
EOF"

# THE RULE THIS PAGE PARTLY REVERSES (plan/18 §7.4, plan/21 §3). Its predecessor returned true
# from isNextEnabled() unconditionally. This one asks the config, because managed mode creates no
# local account and must not be left until the enrolment has actually happened — and the two other
# modes still gate on nothing but their own fields.
assert_true "Next is mode-dependent rather than unconditional" \
    grep -q 'return m_config->nextEnabled();' "$PAGE/AccountsViewStep.cpp"
assert_true "...local and domain mode gate on field validity only" \
    grep -qF 'm_loginNameValid && m_passwordValid && passwordsMatch()' "$PAGE/AccountsConfig.cpp"
assert_true "...and managed mode gates on a completed enrolment that granted somebody" \
    grep -qF 'm_enrolState == Succeeded && !m_grantedUsers.isEmpty()' "$PAGE/AccountsConfig.cpp"
# TWO SCREENS, ONE VIEW STEP, AND FOUR FUNCTIONS THAT HAVE TO AGREE (plan/21 §1a).
# The choice is on the first screen and the chosen mode's fields on the second, and Calamares
# drives that through ViewStep::isAtBeginning()/back() and isAtEnd()/next(): back() is only
# called instead of leaving the module while isAtBeginning() is false, and next() only while
# isAtEnd() is false (ViewManager.cpp). Both default to `return true` in the version this
# replaced, and that is the failure worth catching — with isAtEnd() true on the chooser, Next
# leaves the page from the first screen and publishes a mode whose fields nobody filled in.
assert_true "the view step reports which of its two screens is showing" \
    grep -qF 'return m_config->onChooser();' "$PAGE/AccountsViewStep.cpp"
assert_true "...on both ends" \
    grep -qF 'return m_config->onFields();' "$PAGE/AccountsViewStep.cpp"
assert_true "...so the window's Back moves between them" \
    grep -qF 'm_config->goToChooser();' "$PAGE/AccountsViewStep.cpp"
assert_true "...and so does its Next" \
    grep -qF 'm_config->goToFields();' "$PAGE/AccountsViewStep.cpp"
# The page can still change screens without going through ViewManager — setMode() sends the page
# back to the chooser if the mode ever changes while the fields are showing — and ViewManager only
# re-reads the navigation state after its own back()/next(). Without this connection the window's
# Next keeps describing the screen you just left, which on the way back to the chooser is an
# enabled Next that skips the form.
assert_true "...and a screen change from inside the page re-asks the Next button" \
    grep -qF 'AccountsConfig::stepChanged' "$PAGE/AccountsViewStep.cpp"
# Next means something different on each screen. On the chooser it gates on the one question the
# chooser asks; the hostname is deliberately not in it, because the field that holds it is on the
# screen you have not reached yet.
assert_true "Next on the chooser gates on a mode having been picked" \
    bash -c "grep -A6 'm_step == ChooseMode' '$PAGE/AccountsConfig.cpp' | grep -q 'return modeChosen();'"
# The same discipline the modes are under: a context property cannot spell
# `AccountsConfig.FillFields`, so the QML reads named booleans and `accounts.step === 1` — a
# binding that renumbering the enum breaks in silence — is not allowed to appear.
assert_true "no QML binding compares the step to a number" \
    bash -c "python3 - <<'EOF'
import pathlib, sys
bad = []
for f in sorted(pathlib.Path('$PAGE/qml').glob('*.qml')):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(('*', '/*', '//')):
            continue
        if 'accounts.step' in stripped:
            bad.append('%s:%d' % (f.name, n))
if bad:
    sys.exit('reads accounts.step directly: ' + ', '.join(bad))
EOF"
# The window's own Back is the ONE way back to the chooser. The second screen's header used to
# carry a `Change` button that did the same thing; two controls for one movement is two things to
# keep in agreement, and the one in the corner is the one every other page in the installer has.
assert_true "the page draws no navigation of its own" \
    bash -c "! grep -qE 'accounts\.goTo(Chooser|Fields)\(\)' '$PAGE/qml/Accounts.qml'"

# The enrolment happens on the PAGE, into a scratch root, before the disk is written — which is
# what makes the blocking safe: a failure there costs nothing.
assert_true "the page enrols into a scratch root, not into the target" \
    grep -qF 'm_scratchRoot' "$PAGE/AccountsConfig.cpp"
assert_true "...seeding the empty machine-id the client refuses to enrol without" \
    grep -qF 'etc/machine-id' "$PAGE/AccountsConfig.cpp"
assert_true "...and releasing the device again if the mode or the code changes" \
    grep -qF 'QStringLiteral( "leave" )' "$PAGE/AccountsConfig.cpp"

# The page<->job contract. GlobalStorage, minus the two things that must never be in it.
assert_true "the page publishes the mode for the job to read" \
    grep -q 'accountsMode' "$PAGE/AccountsConfig.cpp"
assert_true "...and the scratch root the job transplants from" \
    grep -q 'managedEnrollmentScratchRoot' "$PAGE/AccountsConfig.cpp"
# THE KEY THAT WENT AWAY. The page this replaced published the live enrolment code to
# GlobalStorage, which Calamares can dump to its log. There is no reason for it to be there now:
# by the time the job runs, the code has been spent (plan/21 §4).
assert_false "no GlobalStorage key carries the enrolment code any more" \
    grep -q 'managedEnrollmentCode' "$PAGE/AccountsConfig.cpp"
assert_false "...and no password is inserted into GlobalStorage either" \
    bash -c "grep -E 'gs->insert' '$PAGE/AccountsConfig.cpp' | grep -qi password"
assert_true "the passwords go to a 0600 file on tmpfs whose path is published instead" \
    bash -c "grep -q 'accountsSecretsPath' '$PAGE/AccountsConfig.cpp' &&
             grep -q 'QFileDevice::ReadOwner | QFileDevice::WriteOwner' '$PAGE/AccountsConfig.cpp'"

JOB="$REPO_ROOT/config/calamares/local-modules/accountsetup/main.py.in"
assert_file "$JOB" "the work is a python module, not more C++"
# ...and the two sides agree on what is IN that file. It is the only channel a password takes,
# and it is untyped JSON: a key the page renames and the job does not means `secrets.get()`
# returns None. That does not create a passwordless account — create_local_user refuses and
# fails the install, which is the right answer and a terrible way to find out.
assert_true "the page and the job spell the secrets-file keys the same way" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys
cpp = pathlib.Path('$PAGE/AccountsConfig.cpp').read_text()
job = pathlib.Path('$JOB').read_text()
written = set(re.findall(r'secrets\.insert\(\s*QStringLiteral\(\s*\"([^\"]+)\"', cpp))
read = set(re.findall(r'secrets\.get\(\s*\"([^\"]+)\"', job))
if not written or not read:
    sys.exit('parsed no secret keys at all (written=%s read=%s)' % (sorted(written), sorted(read)))
if written != read:
    sys.exit('page writes %s, job reads %s' % (sorted(written), sorted(read)))
EOF"
assert_true "the job reads the same GlobalStorage keys the page writes" \
    bash -c "for k in accountsMode managedEnrollmentScratchRoot accountsSecretsPath; do
                 grep -q \"\$k\" '$JOB' || exit 1; done"
# ...and the whole list, mechanically, in both directions. The three greps above name the keys
# somebody thought of; this one names the keys that are there. GlobalStorage is an untyped
# string-keyed map on both sides, so a key the page renames and the job does not is not an error
# anywhere: `gs.value()` returns None, the field the person typed is silently dropped, and the
# install completes without it. That is how a typed DC address, or an OU, goes missing.
#
# Two exemptions, both stated rather than pattern-matched. `rootMountPoint` is Calamares' own
# key, published by the mount module. `managedOrgName` has no reader on purpose (plan/21 §4) —
# it is in the log for the operator, and asserting that keeps it from being quietly repurposed.
assert_true "every key the job reads is published, and every key published is read or exempt" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys

cpp = pathlib.Path('$PAGE/AccountsConfig.cpp').read_text()
job = pathlib.Path('$JOB').read_text()

published = set(re.findall(r'gs->insert\(\s*QStringLiteral\(\s*\"([^\"]+)\"', cpp))
# gs.value(\"literal\") AND gs.value(key) where key comes from a (key, flag) table — the domain
# Advanced options are forwarded through such a loop, so a literal-only scan calls them unread.
read = set(re.findall(r'gs\.value\(\s*\"([^\"]+)\"', job))
read |= set(re.findall(r'\(\s*\"(domain[A-Za-z]+)\"\s*,\s*\"--', job))

CALAMARES_OWN = {'rootMountPoint'}
WRITE_ONLY = {'managedOrgName'}

missing = sorted(read - published - CALAMARES_OWN)
if missing:
    sys.exit('the job reads keys the page never publishes: ' + ', '.join(missing))
orphans = sorted(published - read - WRITE_ONLY)
if orphans:
    sys.exit('the page publishes keys nothing reads: ' + ', '.join(orphans))
if not published or not read:
    sys.exit('parsed no keys at all — the extraction is broken, not the contract')
EOF"
# The one that went away with `managedenroll`: a boolean saying \"managed mode was chosen\" beside
# a mode that already says so. Two keys for one fact matter only when they disagree. Matched
# against the insert lines rather than the file, because the file explains the absence by name.
assert_false "no boolean duplicates accountsMode" \
    bash -c "grep -E '^[^/]*gs->insert' '$PAGE/AccountsConfig.cpp' |
             grep -q managedEnrollmentRequested"
assert_true "the job unlinks the secrets file whatever else happened" \
    bash -c "grep -q 'finally:' '$JOB' && grep -q 'os.unlink(secrets_path)' '$JOB'"
assert_true "the job records an enrolment that was asked for and did not happen (T-MAN-4)" \
    grep -q 'enrollment-pending.json' "$JOB"
# T-MAN-4's property, now stated per path rather than per file, because plan/21 gave this job one
# path that SHOULD fail. A Calamares python job fails an install by returning a tuple: on the
# network-facing paths that would be an installer that dies because a household's router was
# being replaced, and on the useradd path it is the honest answer to a machine with no way in.
assert_true "the network-facing paths return None" \
    bash -c "python3 - <<'EOF'
import re, sys
src = open('$JOB').read()
for fn in ('transplant_enrolment', 'join_domain'):
    body = src.split('def %s(' % fn, 1)[1].split('\ndef ', 1)[0]
    if re.search(r'^\s+return \(', body, re.M):
        sys.exit('%s returns a failure tuple' % fn)
EOF"
assert_true "...and only create_local_user() may fail the install" \
    bash -c "python3 - <<'EOF'
import re, sys
src = open('$JOB').read()
body = src.split('def create_local_user(', 1)[1].split('\ndef ', 1)[0]
if not re.search(r'^\s+return \(', body, re.M):
    sys.exit('create_local_user cannot report failure at all')
EOF"
assert_true "the job passes --root so it writes into the TARGET, not the live medium" \
    grep -q -- '"--root"' "$JOB"
# The transplant, and why it is a state-directory copy rather than an /etc copy (plan/21 §6).
assert_true "the job copies the state directory the page's enrolment produced" \
    grep -q 'shutil.copytree' "$JOB"
assert_true "...and asks the client to render it into the target, offline" \
    grep -qF '"apply", "--root", root' "$JOB"
assert_true "...then enables the sync timer in the target, which the page could not" \
    grep -qF 'systemctl' "$JOB"
# The sequence wiring. Both halves are unconditional now: the page creates the account, so a
# medium without it is not a medium with one screen missing.
CALSET="$REPO_ROOT/config/calamares/settings.conf.in"
assert_false "settings.conf carries no conditional page token any more" \
    grep -q '@CAL_MANAGED_PAGE@' "$CALSET"
assert_true "settings.conf names the accounts page unconditionally" \
    grep -qE '^[[:space:]]*-[[:space:]]+accounts$' "$CALSET"
assert_true "settings.conf names the job unconditionally" \
    grep -qE '^[[:space:]]*-[[:space:]]+accountsetup$' "$CALSET"
assert_true "stage 40 refuses to build a medium whose lock did not carry the page" \
    grep -qF "the installer's accounts page is not installed" \
        "$REPO_ROOT/scripts/stages/40-configure.sh"
# Stage 20 is what makes the repository exist at all.
assert_true "stage 20 renders the overlay into the config root" \
    grep -q 'install_rootfs_overlay "\$OVERLAY_SRC"' "$REPO_ROOT/scripts/stages/20-builder-setup.sh"
assert_true "stage 20 writes a repos.conf entry for it" \
    grep -q 'repos.conf/\$DISTRO_ID.conf' "$REPO_ROOT/scripts/stages/20-builder-setup.sh"
# ...and the lock check must not report an overlay atom as missing from the pinned tree, which
# would send whoever hit it off to relock a package upstream never carried.
assert_true "stage 20's lock check looks in the overlay as well as the tree" \
    grep -q 'OVERLAY_DST/\$ovl_cat' "$REPO_ROOT/scripts/stages/20-builder-setup.sh"
assert_true "relock --restamp warns when the lock lacks an overlay package the profile wants" \
    grep -q 'does not name the overlay package' "$REPO_ROOT/scripts/relock.sh"
# The sets, with the same "distro" token the filenames use, rebranded by filter_set_file.
assert_true "@desktop names the KCM from the overlay" \
    grep -qE '^distro-base/distro-kcm-managed(\s|$)' "$REPO_ROOT/config/portage/sets/desktop"
# ...and marked `#not-live`, which is what keeps it off the installer medium (plan/20). A live
# session enrols nothing, so the module would report "not enrolled" until the stick is pulled.
assert_true "...and marks it #not-live, so no live medium emerges it" \
    grep -qE '^distro-base/distro-kcm-managed\s+#not-live$' "$REPO_ROOT/config/portage/sets/desktop"
assert_eq "" \
    "$(printf 'distro-base/distro-kcm-managed  #not-live\n' > "$TMP/s3.in"
       PROFILE_ROLE=live filter_set_file "$TMP/s3.in" "$TMP/s3.out"; tr -d '[:space:]' < "$TMP/s3.out")" \
    "filter_set_file drops a #not-live atom on a live profile"
assert_eq "${DISTRO_ID}-base/${DISTRO_ID}-kcm-managed" \
    "$(printf 'distro-base/distro-kcm-managed  #not-live\n' > "$TMP/s4.in"
       PROFILE_ROLE=target filter_set_file "$TMP/s4.in" "$TMP/s4.out"; tr -d '[:space:]' < "$TMP/s4.out")" \
    "...and keeps it, rebranded and with the marker stripped, on a target profile"
# The Calamares half is the one a live medium DOES want, and it is in a different set precisely
# so the two can differ. If this ever picked up a marker, the medium would lose the enrolment
# page and installs would silently produce unenrolled machines.
assert_false "the Calamares enrolment page is NOT #not-live — the installer needs it" \
    grep -q '#not-live' "$REPO_ROOT/config/portage/sets/installer"
# Stage 40 must not warn about the module being absent on a medium that dropped it on purpose:
# a warning nobody should act on is how the ones that matter get ignored.
assert_true "stage 40 treats a live profile's missing KCM as deliberate, not as a warning" \
    grep -q 'the managed System Settings module is deliberately absent' \
        "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 50 fails a live medium that carries the KCM anyway" \
    grep -q 'It is marked #not-live in config/portage/sets/desktop' \
        "$REPO_ROOT/scripts/stages/50-prune.sh"
assert_eq "${DISTRO_ID}-base/${DISTRO_ID}-kcm-managed" \
    "$(printf 'distro-base/distro-kcm-managed\n' > "$TMP/s.in"; filter_set_file "$TMP/s.in" "$TMP/s.out"; tr -d '[:space:]' < "$TMP/s.out")" \
    "filter_set_file rebrands an overlay atom"
assert_eq "app-misc/distrobox" \
    "$(printf 'app-misc/distrobox\n' > "$TMP/s2.in"; filter_set_file "$TMP/s2.in" "$TMP/s2.out"; tr -d '[:space:]' < "$TMP/s2.out")" \
    "...and leaves an atom that merely CONTAINS the word alone"

# ---- 11. build wiring -------------------------------------------------------------------------
assert_true "build.conf carries an https MANAGED_API_BASE" \
    grep -qE '^MANAGED_API_BASE="https://' "$REPO_ROOT/config/build.conf"
# config/keys/ is .gitignored, so a default naming a file there would break every fresh clone's
# build on a file nobody could have — which is exactly what happened before this assertion.
assert_file "$REPO_ROOT/$MANAGED_PUBRING" \
    "MANAGED_PUBRING points at a file that actually exists in a fresh checkout"
assert_false "MANAGED_PUBRING does not default into the .gitignored config/keys directory" \
    bash -c "[[ '$MANAGED_PUBRING' == config/keys/* ]]"
assert_true "stage 40 bakes the bundle-signing keyring into the image" \
    grep -q 'managed-pubring.gpg' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 dearmors it rather than committing a binary keyring" \
    grep -q 'gpg --dearmor' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "build.sh has a --with-test-api flag" \
    grep -q -- '--with-test-api' "$REPO_ROOT/scripts/build.sh"
assert_true "stage 70 skips the managed tests when no fixture is running" \
    grep -q 'MANAGED_API_URL' "$REPO_ROOT/scripts/stages/70-test.sh"
assert_true "run-vm.sh can inject the managed test credential" \
    grep -q -- '--managed' "$REPO_ROOT/scripts/run-vm.sh"
assert_true "the guest self-report reports managed state on a normal boot (T-MAN-5)" \
    grep -q 'managed=' "$REPO_ROOT/config/rootfs/usr/lib/image-test/test-report.sh.in"

finish
