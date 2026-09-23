#!/usr/bin/env bash
# Build profiles (plan/16 §3).
#
# Profiles exist so the Calamares installer can be built into a live-only image while the
# installed system stays free of it. Two properties carry that guarantee, and both are the kind
# that fail silently rather than loudly, so both are asserted here:
#
#   1. Two profiles must not share a per-build path. If they did, building one after the other
#      would reuse the other's target rootfs or stage stamps and produce an image nobody asked
#      for — with no error anywhere.
#   2. Two profiles MUST share every identity string the installed system can see. A profile
#      name leaking into a UKI filename or a root partlabel breaks systemd-sysupdate, and it
#      breaks it on the user's machine months after the build.
export TEST_FILE_NAME=test-profiles
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e
load_config

PROFILES=(); while IFS= read -r p; do PROFILES+=("$p"); done < <(profile_list)

# ---- every profile on disk loads and validates -------------------------------------------
(( ${#PROFILES[@]} >= 2 )) || _fail "expected at least the desktop and console profiles"
for p in "${PROFILES[@]}"; do
    assert_true "profile '$p' loads and validates" \
        bash -c "export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t BUILD_PROFILE_OVERRIDE='$p'
                 source '$REPO_ROOT/scripts/lib/common.sh'; load_config"
done

# ---- the default profile keeps every path it had before profiles existed -----------------
# Not cosmetic: an existing work volume, out/ tree and resume state have to stay valid, or
# introducing profiles silently costs someone a multi-hour rebuild.
# harness.sh keeps its counters in shell variables, so a subshell's assertions cannot reach
# them. Pull each profile's derived paths OUT of a subshell instead, prefixed, and compare them
# here where the counters live.
eval "$( BUILD_PROFILE_OVERRIDE=desktop; load_config
         declare -p TARGET CONFIG_ROOT STATE_DIR REPORT_DIR UKI_DIR LOG_DIR IMG_NAME UKI_NAME \
                    ROOT_PARTLABEL PROFILE_LOCK EXPECTED_PACKAGES \
           | sed 's/^declare -[-x]* /D_/; s/^D_/declare -g D_/' )"
assert_eq "$WORK/target" "$D_TARGET"      "desktop TARGET is unsuffixed"
assert_eq "$WORK/config" "$D_CONFIG_ROOT" "desktop CONFIG_ROOT is unsuffixed"
assert_eq "$OUT/state"   "$D_STATE_DIR"   "desktop STATE_DIR is unsuffixed"
assert_eq "$OUT/reports" "$D_REPORT_DIR"  "desktop REPORT_DIR is unsuffixed"
assert_eq "$OUT/uki"     "$D_UKI_DIR"     "desktop UKI_DIR is unsuffixed"
assert_eq "$REPO_ROOT/config/portage/lock/desktop.lock" "$D_PROFILE_LOCK" \
    "desktop lock path"
assert_eq "$REPO_ROOT/config/portage/expected-packages.desktop.txt" "$D_EXPECTED_PACKAGES" \
    "desktop expected-packages path"

eval "$( BUILD_PROFILE_OVERRIDE=console; load_config
         declare -p TARGET CONFIG_ROOT STATE_DIR REPORT_DIR UKI_DIR LOG_DIR IMG_NAME UKI_NAME \
                    ROOT_PARTLABEL PROFILE_LOCK EXPECTED_PACKAGES \
           | sed 's/^declare -[-x]* /C_/; s/^C_/declare -g C_/' )"

# ---- IMG_*_PARTLABEL: this profile's OWN image, vs. ROOT_PARTLABEL's identity (plan/33 §2) ---
eval "$( BUILD_PROFILE_OVERRIDE=installer; load_config
         declare -p ROOT_PARTLABEL IMG_ESP_PARTLABEL IMG_ROOT_PARTLABEL IMG_VAR_PARTLABEL \
           | sed 's/^declare -[-x]* /I_/; s/^I_/declare -g I_/' )"
assert_eq "$D_ROOT_PARTLABEL" "$C_ROOT_PARTLABEL" "ROOT_PARTLABEL: desktop == console (identity, unchanged)"
assert_eq "$D_ROOT_PARTLABEL" "$I_ROOT_PARTLABEL" "ROOT_PARTLABEL: desktop == installer too (identity, unchanged)"
# desktop and console are PROFILE_ROLE=target, so their own image's names ARE the identity names.
eval "$( BUILD_PROFILE_OVERRIDE=desktop; load_config
         declare -p IMG_ESP_PARTLABEL IMG_ROOT_PARTLABEL IMG_VAR_PARTLABEL \
           | sed 's/^declare -[-x]* /D_/; s/^D_/declare -g D_/' )"
eval "$( BUILD_PROFILE_OVERRIDE=console; load_config
         declare -p IMG_ESP_PARTLABEL IMG_ROOT_PARTLABEL IMG_VAR_PARTLABEL \
           | sed 's/^declare -[-x]* /C_/; s/^C_/declare -g C_/' )"
assert_eq "esp" "$D_IMG_ESP_PARTLABEL" "desktop (target): IMG_ESP_PARTLABEL is unsuffixed"
assert_eq "$D_ROOT_PARTLABEL" "$D_IMG_ROOT_PARTLABEL" "desktop (target): IMG_ROOT_PARTLABEL == ROOT_PARTLABEL"
assert_eq "var" "$D_IMG_VAR_PARTLABEL" "desktop (target): IMG_VAR_PARTLABEL is unsuffixed"
assert_eq "esp" "$C_IMG_ESP_PARTLABEL" "console (target): IMG_ESP_PARTLABEL is unsuffixed"
assert_eq "$C_ROOT_PARTLABEL" "$C_IMG_ROOT_PARTLABEL" "console (target): IMG_ROOT_PARTLABEL == ROOT_PARTLABEL"
assert_eq "var" "$C_IMG_VAR_PARTLABEL" "console (target): IMG_VAR_PARTLABEL is unsuffixed"
# The installer is PROFILE_ROLE=live: its OWN image's names are live_*, never the identity ones —
# the whole fix plan/33 §2 exists for, so booting it next to an installed disk cannot resolve
# PARTLABEL=root_<v> or PARTLABEL=var to the wrong device.
assert_eq "live_esp" "$I_IMG_ESP_PARTLABEL" "installer (live): IMG_ESP_PARTLABEL is live_esp"
assert_eq "live_${I_ROOT_PARTLABEL}" "$I_IMG_ROOT_PARTLABEL" \
    "installer (live): IMG_ROOT_PARTLABEL is live_root_<v>"
assert_true "installer (live): IMG_ROOT_PARTLABEL differs from the identity ROOT_PARTLABEL" \
    test "$I_IMG_ROOT_PARTLABEL" != "$I_ROOT_PARTLABEL"
assert_eq "live_var" "$I_IMG_VAR_PARTLABEL" "installer (live): IMG_VAR_PARTLABEL is live_var"

# ---- fstab.in renders the right names per role (plan/33 §2) ---------------------------------
FSTAB_SRC="$REPO_ROOT/config/rootfs/etc/fstab.in"
assert_true "config/rootfs/etc/fstab.in exists" test -f "$FSTAB_SRC"
(
  IMG_ESP_PARTLABEL=esp IMG_ROOT_PARTLABEL=root_9.9.9 IMG_VAR_PARTLABEL=var
  render_template "$FSTAB_SRC" "$TMP/fstab.target"
)
assert_contains 'PARTLABEL=var'  "$(cat "$TMP/fstab.target")" "target fstab: PARTLABEL=var"
assert_contains 'PARTLABEL=esp'  "$(cat "$TMP/fstab.target")" "target fstab: PARTLABEL=esp"
assert_false "target fstab: no live_ names leaked in" grep -q 'live_' "$TMP/fstab.target"

(
  IMG_ESP_PARTLABEL=live_esp IMG_ROOT_PARTLABEL=live_root_9.9.9 IMG_VAR_PARTLABEL=live_var
  render_template "$FSTAB_SRC" "$TMP/fstab.live"
)
assert_contains 'PARTLABEL=live_var' "$(cat "$TMP/fstab.live")" "live fstab: PARTLABEL=live_var"
assert_contains 'PARTLABEL=live_esp' "$(cat "$TMP/fstab.live")" "live fstab: PARTLABEL=live_esp"
assert_false "live fstab: the installed-system identity PARTLABEL=var is absent" \
    grep -qE 'PARTLABEL=var([[:space:]]|$)' "$TMP/fstab.live"

# ---- 1. no per-build path may be shared between two profiles -------------------------------
for v in TARGET CONFIG_ROOT STATE_DIR REPORT_DIR UKI_DIR LOG_DIR IMG_NAME PROFILE_LOCK EXPECTED_PACKAGES; do
    d="D_$v"; c="C_$v"
    if [[ ${!d} == "${!c}" ]]; then
        _fail "$v is shared between the desktop and console profiles (${!d}) — one build would clobber the other"
    else _pass; fi
done

# ---- 2. every identity string MUST be shared ----------------------------------------------
# plan/16 §3.4. A system installed from one profile's payload has to be indistinguishable from
# one dd'd from another profile's image, or systemd-sysupdate stops recognising it as ours.
assert_eq "$D_UKI_NAME"       "$C_UKI_NAME"       "UKI filename does not carry the profile"
assert_eq "$D_ROOT_PARTLABEL" "$C_ROOT_PARTLABEL" "root partlabel does not carry the profile"
assert_match '^immos_[0-9]+\.[0-9]+\.[0-9]+\.efi$' "$C_UKI_NAME" \
    "a non-default profile's UKI is still named for the version alone"
assert_match '^root_[0-9]+\.[0-9]+\.[0-9]+$' "$C_ROOT_PARTLABEL" \
    "a non-default profile's partlabel is still the version alone"

# ---- profile_has_set ------------------------------------------------------------------------
assert_true  "desktop profile has @desktop" bash -c "PROFILE_SETS='base hardware desktop'
    source '$REPO_ROOT/scripts/lib/common.sh'; profile_has_set desktop"
assert_false "console profile has no @desktop" bash -c "PROFILE_SETS='base hardware'
    source '$REPO_ROOT/scripts/lib/common.sh'; profile_has_set desktop"
assert_true  "console profile still has @base" bash -c "PROFILE_SETS='base hardware'
    source '$REPO_ROOT/scripts/lib/common.sh'; profile_has_set base"
# Substring matches would make "desk" find "desktop"; set names are compared whole.
assert_false "set membership is not a substring match" bash -c "PROFILE_SETS='base hardware desktop'
    source '$REPO_ROOT/scripts/lib/common.sh'; profile_has_set desk"

# ---- validation rejects malformed profiles --------------------------------------------------
# Each of these would otherwise surface as a strange image rather than as a config error.
bad_profile() {   # label  <assignments run after load_config>
    local label=$1; shift
    if bash -c "export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t
                source '$REPO_ROOT/scripts/lib/common.sh'
                load_config; $*; validate_config" >/dev/null 2>&1; then
        _fail "$label"
    else _pass; fi
}
bad_profile "empty PROFILE_SETS is rejected"           "PROFILE_SETS=''"
bad_profile "PROFILE_SETS without base is rejected"    "PROFILE_SETS='hardware desktop'"
bad_profile "a set with no file is rejected"           "PROFILE_SETS='base nosuchset'"
bad_profile "a malformed set name is rejected"         "PROFILE_SETS='base ../escape'"
bad_profile "an unknown PROFILE_ROLE is rejected"      "PROFILE_ROLE=sometimes"
bad_profile "an empty PROFILE_DESC is rejected"        "PROFILE_DESC=''"

# ...and an unknown profile name dies rather than defaulting to something plausible.
assert_false "an unknown profile name is rejected" bash -c \
    "export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t BUILD_PROFILE_OVERRIDE=nosuch
     source '$REPO_ROOT/scripts/lib/common.sh'; load_config" 2>/dev/null
# ../../etc/passwd must be refused by the NAME pattern, before it is ever used to build a path.
assert_false "a path-shaped profile name is rejected" bash -c \
    "export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t BUILD_PROFILE_OVERRIDE=../../etc/passwd
     source '$REPO_ROOT/scripts/lib/common.sh'; load_config" 2>/dev/null

# ---- every committed lock and audit file belongs to a real profile --------------------------
# A stale desktop.lock left behind after a profile is renamed would be silently ignored by every
# build, which is the same failure mode as having no lock at all.
for f in "$REPO_ROOT"/config/portage/lock/*.lock; do
    n="$(basename -- "$f" .lock)"
    [[ $n == builder ]] && continue          # the builder's own root, not a build profile
    if printf '%s\n' "${PROFILES[@]}" | grep -qx "$n"; then _pass
    else _fail "config/portage/lock/$n.lock does not correspond to any profile in config/profiles/"; fi
done
for f in "$REPO_ROOT"/config/portage/expected-packages.*.txt; do
    [[ -e $f ]] || continue
    n="$(basename -- "$f" .txt)"; n="${n#expected-packages.}"
    if printf '%s\n' "${PROFILES[@]}" | grep -qx "$n"; then _pass
    else _fail "config/portage/expected-packages.$n.txt does not correspond to any profile"; fi
done

# ---- the guarantee the whole mechanism exists for --------------------------------------------
# plan/16 §2: Calamares drags in GRUB (built with the legacy BIOS platform), Gentoo's GRUB theme
# artwork, os-prober and squashfs-tools, all as unconditional RDEPENDs. None of it is usable by a
# UKI/systemd-boot/EROFS system, and none of it may reach one. The audit gate in stage 50 is what
# enforces that at build time; this is the same assertion offline, and it is deliberately in
# place BEFORE the installer profile exists so it cannot be added without someone seeing it.
INSTALLER_TAIL=(app-admin/calamares sys-boot/grub sys-boot/grub-themes-gentoo sys-boot/os-prober
                sys-fs/squashfs-tools dev-libs/boost dev-cpp/yaml-cpp)
for prof in "${PROFILES[@]}"; do
    ep="$REPO_ROOT/config/portage/expected-packages.$prof.txt"
    [[ -f $ep ]] || continue
    role="$( BUILD_PROFILE_OVERRIDE="$prof"; load_config >/dev/null 2>&1; printf '%s' "$PROFILE_ROLE" )"
    [[ $role == target ]] || continue        # live profiles are allowed the whole tail
    for atom in "${INSTALLER_TAIL[@]}"; do
        if grep -qx -- "$atom" "$ep"; then
            _fail "installable profile '$prof' ships $atom — the installer tail must stay on live media only (plan/16 §3.3)"
        else _pass; fi
    done
done

# ---- the C++ runtime must be requested explicitly, in @base --------------------------------
# Regression test for the bug the first console build found (plan/16 §8, Phase 0). sys-devel/gcc
# is Gentoo's only provider of libstdc++.so.6, plan/06 recorded it as arriving by itself through
# @system, and it had silently stopped doing so for every set combination that omits @desktop.
# The symptom was 424 unrunnable binaries in a fresh ROOT, and nothing said a word until a
# program was actually executed. Asserted here because it is invisible until then.
assert_true "@base names sys-devel/gcc (the only libstdc++.so.6 provider)" \
    grep -qx 'sys-devel/gcc' "$REPO_ROOT/config/portage/sets/base"
for prof in "${PROFILES[@]}"; do
    ep="$REPO_ROOT/config/portage/expected-packages.$prof.txt"
    [[ -f $ep ]] || continue
    if grep -qx 'sys-devel/gcc' "$ep"; then _pass
    else _fail "profile '$prof' ships no sys-devel/gcc — every C++ binary in it would fail to start"; fi
done

# ---- per-profile build state (the staleness fingerprint) -----------------------------------
# init_paths' own rule is "everything per-BUILD is profile-scoped". TARGET_HASH_FILE is the one
# that was not, and it is the fingerprint stage 30 compares $TARGET against before deciding the
# root is stale. One shared file meant an installer build stamped its hash over the desktop's,
# so each profile then read a fingerprint describing a root that is not its own — a false "wipe
# and rebuild" on a good target, or, the half that actually ships a wrong image, silence on a
# stale one because the other profile had just written the current hash over it.
for _p in desktop installer console; do
    eval "$( BUILD_PROFILE_OVERRIDE=$_p; WORK=/w; load_config
             declare -p TARGET TARGET_HASH_FILE | sed 's/^declare -[-x]* /P_/; s/^P_/declare -g P_/' )"
    assert_true "$_p: TARGET_HASH_FILE is defined by init_paths" test -n "${P_TARGET_HASH_FILE:-}"
    # The fingerprint must sit beside the target it describes: same suffix, always.
    assert_eq "${P_TARGET#/w/target}" "${P_TARGET_HASH_FILE#/w/target-config-hash}" \
        "$_p: the fingerprint carries the same profile suffix as its target root"
done
# ...and no two profiles may share one, which is the bug stated directly.
assert_eq "3" "$( for _p in desktop installer console; do
                      ( BUILD_PROFILE_OVERRIDE=$_p; WORK=/w; load_config; printf '%s\n' "$TARGET_HASH_FILE" )
                  done | sort -u | wc -l )" \
    "the three profiles' fingerprints are three distinct paths"
# Stage 30 must use the variable for BOTH halves of the guard. They used to be two literal
# strings that happened to agree, which is how one of them could be fixed and the other missed.
S30="$REPO_ROOT/scripts/stages/30-target-rootfs.sh"
assert_true "stage 30 reads the guard through TARGET_HASH_FILE" \
    grep -q 'PREV_TGT_HASH="$(cat "$TARGET_HASH_FILE"' "$S30"
assert_true "...and writes it through the same variable" \
    grep -qF '> "$TARGET_HASH_FILE"' "$S30"
assert_false "...and nowhere spells the unsuffixed path by hand" \
    grep -q 'WORK/target-config-hash"' "$S30"

finish
