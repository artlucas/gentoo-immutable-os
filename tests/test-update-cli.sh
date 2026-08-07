#!/usr/bin/env bash
# Tests the rendered ${DISTRO_ID}-update CLI: pure version helpers, plus the
# status/rollback/etc-diff commands against mocked system tools.
export TEST_FILE_NAME=test-update-cli
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort
load_config

CLI="$TMP/${DISTRO_ID}-update"
export DISTRO_ID
render_template "$REPO_ROOT/config/rootfs/usr/bin/distro-update.in" "$CLI"
chmod +x "$CLI" 2>/dev/null || true

# ---- pure helpers (sourced, no dispatch) ---------------------------------------
helper() {  # FUNC stdin... — runs a CLI helper function in a clean subshell
    local fn=$1; shift
    # shellcheck disable=SC1090  # $CLI is rendered at test runtime
    ( set +eu; source "$CLI"; "$fn" "$@" )
}

got="$(printf '%s\n' \
    "${DISTRO_ID}_0.1.0.efi" \
    "${DISTRO_ID}_0.2.0+3.efi" \
    "${DISTRO_ID}_0.2.0+2-1.efi" \
    "${DISTRO_ID}_0.10.0.efi" \
    "not-ours.efi" "random.txt" \
    | helper _uki_versions | tr '\n' ' ')"
assert_eq "0.1.0 0.2.0 0.10.0 " "$got" "_uki_versions: parse, strip counters, sort, dedup, ignore foreign files"

assert_eq "0.1.0" "$(printf '0.1.0\n0.2.0\n' | helper _previous_version 0.2.0)" "_previous_version picks the other one"
assert_eq "0.2.0" "$(printf '0.1.0\n0.2.0\n0.3.0\n' | helper _previous_version 0.3.0)" "_previous_version picks newest non-current"
assert_eq "" "$(printf '0.3.0\n' | helper _previous_version 0.3.0)" "_previous_version empty when only current exists"

# ---- mocked end-to-end command runs -----------------------------------------------
MOCK="$TMP/mockbin"; mkdir -p "$MOCK"
FAKE_ESP="$TMP/esp"; mkdir -p "$FAKE_ESP/EFI/Linux"
touch "$FAKE_ESP/EFI/Linux/${DISTRO_ID}_0.1.0.efi" "$FAKE_ESP/EFI/Linux/${DISTRO_ID}_0.2.0.efi"

cat > "$MOCK/bootctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --print-esp-path) echo "$FAKE_ESP" ;;
  set-default)      echo "\$2" > "$TMP/set-default.arg" ;;
esac
EOF
cat > "$MOCK/systemd-sysupdate" <<EOF
#!/usr/bin/env bash
echo "sysupdate \$*" >> "$TMP/sysupdate.calls"
EOF
cat > "$MOCK/lsblk" <<EOF
#!/usr/bin/env bash
printf 'vda2 root_0.2.0 4f68bc64-6acb-4aa4-b891-db7cd79abf44\n'
printf 'vda3 root_0.1.0 4f68bc64-6acb-4aa4-b891-db7cd79abf44\n'
printf 'vda4 var 4d21b016-b534-45c2-a9fb-5c16e091fd2d\n'
EOF
cat > "$MOCK/findmnt" <<'EOF'
#!/usr/bin/env bash
echo /dev/vda2
EOF
cat > "$MOCK/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TMP/systemctl.calls"
EOF
chmod +x "$MOCK"/* 2>/dev/null || true

OSREL="$TMP/os-release"
printf 'ID=%s\nIMAGE_VERSION=0.2.0\n' "$DISTRO_ID" > "$OSREL"

run_cli() {
    PATH="$MOCK:$PATH" _UPDATE_TEST_SKIP_ROOT=1 _UPDATE_TEST_OS_RELEASE="$OSREL" \
        bash "$CLI" "$@" 2>&1
}

out="$(run_cli status)"
assert_contains "installed: 0.2.0" "$out" "status shows current version"
assert_contains "root_0.1.0" "$out" "status lists both slots"
assert_contains "active root: /dev/vda2" "$out" "status shows active root"
assert_contains "${DISTRO_ID}_0.2.0.efi" "$out" "status lists ESP entries"

out="$(run_cli rollback)"
assert_contains "roll back to 0.1.0" "$out" "rollback picks previous version"
assert_eq "${DISTRO_ID}_0.1.0.efi" "$(cat "$TMP/set-default.arg")" "rollback sets previous UKI as default"

out="$(run_cli apply)"
assert_contains "Reboot to activate" "$out" "apply reports staging"
assert_true "apply invoked systemd-sysupdate update" grep -q '^sysupdate update$' "$TMP/sysupdate.calls"

UP="$TMP/upper"; mkdir -p "$UP/ssh"
printf x > "$UP/ssh/sshd_config"; printf x > "$UP/hostname"
out="$(PATH="$MOCK:$PATH" _UPDATE_TEST_ETC_UPPER="$UP" bash "$CLI" etc-diff 2>&1)"
assert_contains "/etc/ssh/sshd_config" "$out" "etc-diff lists nested divergence"
assert_contains "/etc/hostname" "$out" "etc-diff lists top-level divergence"

out="$(run_cli bogus-command)"; rc=$?
assert_eq 1 $rc "unknown command exits 1"

finish
