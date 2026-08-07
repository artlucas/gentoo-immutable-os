#!/usr/bin/env bash
# Installs the REAL config/rootfs overlay into a temp dir and asserts rendering,
# rebranding, and permission rules — i.e. exactly what stage 40 will do on Linux.
export TEST_FILE_NAME=test-overlay-install
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e   # common.sh enables errexit for stages; assertions must record, not abort
load_config

# same render environment stage 40 exports
VERIFY=yes
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER VERIFY FLATPAK_PREINSTALL

DST="$TMP/target"
install_rootfs_overlay "$REPO_ROOT/config/rootfs" "$DST"

# templates rendered, tokens resolved
assert_file "$DST/etc/os-release" "os-release installed"
assert_true "os-release has IMAGE_VERSION" grep -q "IMAGE_VERSION=$VERSION" "$DST/etc/os-release"
assert_true "os-release has ID" grep -q "^ID=$DISTRO_ID\$" "$DST/etc/os-release"
assert_false "no unresolved tokens anywhere" \
    grep -rqE '@[A-Z][A-Z0-9_]*@' "$DST"

# rebranding: distro-* files became ${DISTRO_ID}-*
assert_file "$DST/usr/bin/${DISTRO_ID}-update" "update CLI rebranded"
assert_file "$DST/usr/lib/systemd/system/${DISTRO_ID}-boot-ok.service" "boot-ok unit rebranded"
assert_file "$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset" "preset rebranded"
assert_file "$DST/usr/lib/tmpfiles.d/${DISTRO_ID}-state.conf" "tmpfiles rebranded"
[[ -e $DST/usr/bin/distro-update || -e $DST/usr/bin/distro-update.in ]] \
    && _fail "unrebranded artifact left behind" || _pass

# sysupdate transfers: sysupdate's own @v/@l/@d wildcards must survive rendering
T="$DST/usr/lib/sysupdate.d/50-rootfs.transfer"
assert_file "$T" "rootfs transfer installed"
assert_true "transfer keeps @v wildcard"    grep -q "MatchPattern=${DISTRO_ID}_@v.root.erofs.zst" "$T"
assert_true "transfer URL rendered"         grep -q "Path=$UPDATE_URL" "$T"
assert_true "transfer Verify rendered"      grep -q "Verify=yes" "$T"
U="$DST/usr/lib/sysupdate.d/60-uki.transfer"
assert_true "uki transfer keeps tries tokens" grep -q '@v+@l-@d' "$U"

# preset references rebranded unit names
assert_true "preset enables rebranded boot-ok" \
    grep -q "enable ${DISTRO_ID}-boot-ok.service" "$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"

# flatpak preinstall unit got the app list
assert_true "preinstall unit lists apps" \
    grep -q "$FLATPAK_PREINSTALL" "$DST/usr/lib/systemd/system/${DISTRO_ID}-flatpak-preinstall.service"

# permissions: bin + .sh executable, units not (skip on filesystems without exec bits)
if [[ "$(uname -s)" == Linux ]]; then
    assert_true "update CLI executable" test -x "$DST/usr/bin/${DISTRO_ID}-update"
    assert_true "dracut hook executable" test -x "$DST/usr/lib/dracut/modules.d/90etc-overlay/etc-overlay.sh"
    assert_false "unit file not executable" test -x "$DST/usr/lib/systemd/system/${DISTRO_ID}-boot-ok.service"
fi

# rendered shell scripts must be syntactically valid bash
assert_true "rendered update CLI parses" bash -n "$DST/usr/bin/${DISTRO_ID}-update"
assert_true "rendered test-report parses" bash -n "$DST/usr/lib/image-test/test-report.sh"

# dracut module completeness
for f in module-setup.sh etc-overlay.service etc-overlay.sh; do
    assert_file "$DST/usr/lib/dracut/modules.d/90etc-overlay/$f" "dracut module: $f"
done

finish
