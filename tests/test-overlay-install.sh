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
export DISTROBOX_DEFAULT_IMAGE

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
# The splash pair, and the udev rule in particular: render_dest_name() rewrites the segment
# "distro" wherever it falls in a basename, so "70-distro-splash.rules.in" has to survive both
# the leading numeric prefix and the two-part suffix. If it does not, the rule installs under a
# name udev still reads but which names a unit that does not exist — a splash that never starts,
# on an image where nothing else would notice.
assert_file "$DST/usr/lib/systemd/system/${DISTRO_ID}-splash.service" "splash unit rebranded"
assert_file "$DST/usr/lib/udev/rules.d/70-${DISTRO_ID}-splash.rules" "splash udev rule rebranded"
assert_true "the installed rule starts the installed unit" \
    grep -q "${DISTRO_ID}-splash.service" "$DST/usr/lib/udev/rules.d/70-${DISTRO_ID}-splash.rules"
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

# distrobox default image reached the rendered config (plan/13). This is the only place the
# build.conf value is consumed, and a wrong or unrendered one fails at `distrobox create` time
# on a user's machine, not here — hence the offline check.
assert_file "$DST/etc/distrobox/distrobox.conf" "distrobox.conf installed"
assert_true "distrobox.conf carries the default image" \
    grep -q "container_image_default=\"$DISTROBOX_DEFAULT_IMAGE\"" "$DST/etc/distrobox/distrobox.conf"

# The preset must keep the system-wide podman units off: rootless is the whole design (plan/13),
# and a podman.socket enabled by a vendor preset is exactly how systemd-networkd once got in.
PRESET="$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
for u in podman.service podman.socket podman-restart.service podman-auto-update.timer; do
    assert_true "preset disables $u" grep -q "^disable $u\$" "$PRESET"
done

# permissions: bin + .sh executable, units not (skip on filesystems without exec bits)
if [[ "$(uname -s)" == Linux ]]; then
    assert_true "update CLI executable" test -x "$DST/usr/bin/${DISTRO_ID}-update"
    assert_true "dracut hook executable" test -x "$DST/usr/lib/dracut/modules.d/90etc-overlay/etc-overlay.sh"
    assert_false "unit file not executable" test -x "$DST/usr/lib/systemd/system/${DISTRO_ID}-boot-ok.service"
fi

# rendered shell scripts must be syntactically valid bash
assert_true "rendered update CLI parses" bash -n "$DST/usr/bin/${DISTRO_ID}-update"
assert_true "rendered test-report parses" bash -n "$DST/usr/lib/image-test/test-report.sh"

# ---- DNS: systemd-resolved + nsswitch ------------------------------------------------
# The pieces are only correct together, so they are checked together: nsswitch pointing at a
# resolver nothing enables fails closed, and NetworkManager writing its own resolv.conf takes
# resolved back out of the path. (The resolv.conf symlink itself is made by stage 40, not by
# the overlay, so it is asserted there and in stage 50 instead of here.)
N="$DST/etc/nsswitch.conf"
assert_file "$N" "nsswitch.conf installed"
assert_true "hosts line goes through resolved first" \
    grep -qE '^hosts:[[:space:]]+resolve[[:space:]]+\[!UNAVAIL=return\][[:space:]]' "$N"
assert_true "dns stays as the last-resort fallback" grep -qE '^hosts:.*[[:space:]]dns$' "$N"
# mymachines needs systemd[importd], which this image does not build — naming it would only
# produce lookup errors (see the file's own comment).
assert_false "no mymachines module" grep -qE '^hosts:.*mymachines' "$N"
assert_true "passwd resolves DynamicUser identities" grep -qE '^passwd:.*[[:space:]]systemd$' "$N"

NM="$DST/usr/lib/NetworkManager/conf.d/10-dns-resolved.conf"
assert_file "$NM" "NetworkManager DNS drop-in installed"
assert_true "NM hands DNS to resolved"        grep -qx 'dns=systemd-resolved' "$NM"
assert_true "NM never writes /etc/resolv.conf" grep -qx 'rc-manager=unmanaged' "$NM"

assert_true "preset enables systemd-resolved" \
    grep -qx 'enable systemd-resolved.service' "$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
assert_true "resolved drop-in turns the LLMNR responder off" \
    grep -qx 'LLMNR=no' "$DST/usr/lib/systemd/resolved.conf.d/10-image.conf"

# ---- exactly one network manager -----------------------------------------------------
# Stage 50 deletes systemd-networkd from the image; these disables are what stops stage 40
# from leaving an enablement symlink pointing at a unit file that is about to be removed.
P="$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
for u in systemd-networkd.service systemd-networkd.socket \
         systemd-networkd-wait-online.service systemd-networkd-wait-online@.service \
         systemd-network-generator.service; do
    assert_true "preset disables $u" grep -qx "disable $u" "$P"
done
assert_true "preset enables NetworkManager" grep -qx 'enable NetworkManager.service' "$P"

# the guest self-test must report the fields stage 70 asserts on
R="$DST/usr/lib/image-test/test-report.sh"
assert_true "self-test reports resolved=" grep -q 'resolved=\$resolved' "$R"
assert_true "self-test reports dns="      grep -q 'dns=\$dns' "$R"

# dracut module completeness
for f in module-setup.sh etc-overlay.service etc-overlay.sh; do
    assert_file "$DST/usr/lib/dracut/modules.d/90etc-overlay/$f" "dracut module: $f"
done

finish
