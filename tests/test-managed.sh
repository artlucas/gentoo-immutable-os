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
assert_eq "2" "$EB_N" "the overlay renders exactly the two Phase D ebuilds"
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
# The Calamares module: a view module, built out of tree against the installed Calamares.
assert_true "the installer page uses upstream's own calamares_add_plugin" \
    grep -q 'calamares_add_plugin' "$OVL/distro-base/distro-calamares-managed/files/CMakeLists.txt"
assert_true "...declared as a viewmodule (a job cannot draw a page)" \
    grep -q 'TYPE viewmodule' "$OVL/distro-base/distro-calamares-managed/files/CMakeLists.txt"
assert_true "...and found with find_package(Calamares), not a vendored copy" \
    grep -q 'find_package(Calamares REQUIRED)' \
    "$OVL/distro-base/distro-calamares-managed/files/CMakeLists.txt"
# THE RULE THE INSTALLER PAGE EXISTS UNDER (plan/18 §7.4, T-MAN-4): it must not fail the install.
assert_true "the installer page always allows Next" \
    grep -q 'return true;' "$OVL/distro-base/distro-calamares-managed/files/ManagedViewStep.cpp"
assert_true "the page publishes the code to GlobalStorage for the job to read" \
    grep -q 'managedEnrollmentCode' \
    "$OVL/distro-base/distro-calamares-managed/files/ManagedViewStep.cpp"
JOB="$REPO_ROOT/config/calamares/local-modules/managedenroll/main.py.in"
assert_file "$JOB" "the enrolment job is a python module, not more C++"
assert_true "the job reads the same GlobalStorage key the page writes" grep -q 'managedEnrollmentCode' "$JOB"
assert_true "the job records an enrolment that was asked for and did not happen (T-MAN-4)" \
    grep -q 'enrollment-pending.json' "$JOB"
# The one property T-MAN-4 is: every path returns None. A Calamares python job fails the install
# by returning a tuple, so a single `return (` in this file would be an installer that dies
# because a household's router was being replaced.
assert_false "the job never returns a failure tuple — it must not fail the install" \
    grep -qE '^\s*return \(' "$JOB"
assert_true "the job passes --root so it writes into the TARGET, not the live medium" \
    grep -q -- '"--root"' "$JOB"
# The sequence wiring. The page is conditional (it comes from the overlay); the job is not.
CALSET="$REPO_ROOT/config/calamares/settings.conf.in"
assert_true "settings.conf carries the conditional page token" grep -qx '@CAL_MANAGED_PAGE@' "$CALSET"
assert_true "settings.conf names the enrolment job unconditionally" \
    grep -qE '^[[:space:]]*-[[:space:]]+managedenroll$' "$CALSET"
assert_true "stage 40 computes the page token rather than hardcoding it" \
    grep -q 'CAL_MANAGED_PAGE=' "$REPO_ROOT/scripts/stages/40-configure.sh"
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
    grep -qx 'distro-base/distro-kcm-managed' "$REPO_ROOT/config/portage/sets/desktop"
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
