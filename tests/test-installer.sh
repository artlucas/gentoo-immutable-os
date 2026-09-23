#!/usr/bin/env bash
# The graphical installer (plan/16 Phase A).
#
# Three classes of failure are asserted here, and they share a shape: each one produces a build
# that succeeds, a medium that boots, and an installer that goes wrong on a stranger's hardware
# with their disk already partitioned.
#
#   1. THE INSTALLER AND THE PIPELINE DISAGREE ABOUT THE DISK. They cannot any more — since
#      plan/24 both partition from scripts/lib/layout.sh, and stage 40 puts that same file on the
#      medium — so what section 5 asserts is that the arrangement is still that arrangement. The
#      way it comes apart is somebody re-introducing a second copy of the layout, which looks like
#      a perfectly reasonable patch; if the labels or GPT types then drift, the installed machine
#      boots (the initrd finds root by PARTLABEL) right up until it does not.
#   2. A MODULE IS SILENTLY ABSENT. ModuleManager matches module.desc's `name` against its
#      DIRECTORY name and skips the module when they differ — no error, no log line at the level
#      anyone reads. The install then runs to "finished" having never written the bootloader.
#   3. THE INSTALLER LEAKS INTO THE PRODUCT. expected-packages.<profile>.txt catches the
#      packages (asserted in test-profiles.sh); the SET membership that would put them there is
#      caught here.
export TEST_FILE_NAME=test-installer
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e

CAL="$REPO_ROOT/config/calamares"
# The accounts page is not in config/calamares at all: it is a compiled view module, so it
# lives in the in-repo ebuild repository. Its configuration is in CAL and its code is here.
OVL_ACCOUNTS="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-accounts"

# ---- 1. the profile ------------------------------------------------------------------------
assert_file "$REPO_ROOT/config/profiles/installer.conf" "the installer profile exists"
assert_file "$REPO_ROOT/config/portage/sets/installer"  "the @installer set exists"

eval "$( BUILD_PROFILE_OVERRIDE=installer; load_config
         declare -p PROFILE_ROLE PROFILE_SETS PROFILE_ROOT_SLOTS PAYLOAD_PROFILE \
                    ROOT_PARTLABEL UKI_NAME PAYLOAD_DIR IMG_NAME \
                    PAYLOAD_ROOT_EROFS PAYLOAD_UKI PAYLOAD_VAR_TAR VERSION \
                    ROOT_SLOT_SIZE_MIB ESP_SIZE_MIB MIN_INSTALL_DISK_GB \
                    DISTRO_ID DISTRO_NAME LIVE_USER HOME_URL INTERNET_CHECK_URL \
                    NTP_SERVERS \
           | sed 's/^declare -[-x]* /I_/; s/^I_/declare -g I_/' )"

assert_eq "live"    "$I_PROFILE_ROLE"       "the installer profile is a LIVE profile"
assert_eq "1"       "$I_PROFILE_ROOT_SLOTS" "live media get one root slot, not an A/B pair"
assert_eq "desktop" "$I_PAYLOAD_PROFILE"    "the installer installs the desktop profile"
for s in base hardware desktop installer; do
    assert_true "@$s is in the installer profile's sets" \
        bash -c "PROFILE_SETS='$I_PROFILE_SETS'; source '$REPO_ROOT/scripts/lib/common.sh'; profile_has_set $s"
done

# The payload is the DESKTOP profile's artifacts, so the paths must be unsuffixed — a suffix here
# would mean the installer stages its own output and installs a copy of itself, Calamares tail
# and all.
assert_eq "$OUT/${I_DISTRO_ID}_${I_VERSION}.root.erofs" "$I_PAYLOAD_ROOT_EROFS" \
    "the payload root image is the default profile's"
assert_eq "$OUT/uki/$I_UKI_NAME" "$I_PAYLOAD_UKI" "the payload UKI is the default profile's"
assert_eq "$OUT/${I_DISTRO_ID}_${I_VERSION}.var.tar.zst" "$I_PAYLOAD_VAR_TAR" \
    "the payload var template is the default profile's"
# ...while everything per-build IS suffixed, or two profiles would clobber each other.
assert_match '\-installer\.img$' "$I_IMG_NAME" "the installer image is profile-suffixed"

# ---- 2. validation refuses the shapes that would ship the tail ------------------------------
bad() {   # label  <assignments run after load_config>
    local label=$1; shift
    if bash -c "export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t
                source '$REPO_ROOT/scripts/lib/common.sh'
                load_config; $*; validate_config" >/dev/null 2>&1; then
        _fail "$label"
    else _pass; fi
}
bad "an installable profile may not have one root slot"  "PROFILE_ROLE=target; PROFILE_ROOT_SLOTS=1"
bad "PROFILE_ROOT_SLOTS must be 1 or 2"                  "PROFILE_ROOT_SLOTS=3"
bad "PAYLOAD_PROFILE may not name a missing profile"     "PAYLOAD_PROFILE=nosuch"
bad "PAYLOAD_PROFILE may not name the profile itself"    "BUILD_PROFILE=desktop; PAYLOAD_PROFILE=desktop"
bad "PAYLOAD_PROFILE may not name a live profile"        "PAYLOAD_PROFILE=installer"
bad "INSTALLER_PAYLOAD_FLATPAKS must be 0 or 1"          "INSTALLER_PAYLOAD_FLATPAKS=yes"

# ---- 3. the one-slot layout -----------------------------------------------------------------
# The failure this guards is silent: with one root slot the var partition is p3, so a caller that
# still writes to P4_START_MIB puts the whole var filesystem past the end of the image — into
# sparse nothing, with dd reporting success.
compute_layout 1024 6144 4096 2
assert_eq "4" "$PART_COUNT"                   "two slots produce four partitions"
assert_eq "$P4_START_MIB" "$VAR_START_MIB"    "with two slots, var is p4"
assert_eq "$P3_START_MIB" "$ROOT_B_START_MIB" "with two slots, slot B is p3"
two_slot_total=$TOTAL_MIB

compute_layout 1024 6144 4096 1
assert_eq "3" "$PART_COUNT"                   "one slot produces three partitions"
assert_eq "$P3_START_MIB" "$VAR_START_MIB"    "with one slot, var is p3"
assert_eq "" "$ROOT_B_START_MIB"              "with one slot there is no slot B"
assert_eq "" "${P4_START_MIB:-}"              "a one-slot layout leaks no P4 offset from an earlier call"
[[ $TOTAL_MIB -lt $two_slot_total ]] && _pass \
    || _fail "a one-slot image should be smaller than a two-slot one ($TOTAL_MIB vs $two_slot_total)"

one_slot_script="$(compute_layout 1024 6144 4096 1; emit_sfdisk_script 9.9.9)"
assert_eq "3" "$(grep -c '^start=' <<<"$one_slot_script")" "the one-slot sfdisk script has 3 partitions"
assert_false "a one-slot image has no _empty slot" grep -q '_empty' <<<"$one_slot_script"
assert_true  "a one-slot image still has esp, root and var" \
    bash -c "grep -q 'name=\"esp\"' <<<\"\$1\" && grep -q 'name=\"root_9.9.9\"' <<<\"\$1\" && grep -q 'name=\"var\"' <<<\"\$1\"" _ "$one_slot_script"

two_slot_script="$(compute_layout 1024 6144 4096 2; emit_sfdisk_script 9.9.9)"
assert_eq "4" "$(grep -c '^start=' <<<"$two_slot_script")" "the two-slot sfdisk script is unchanged at 4 partitions"
assert_true "an installable image still gets its _empty slot B" grep -q '_empty' <<<"$two_slot_script"

# ---- 4. the Calamares tree renders, with no token left behind -------------------------------
# render_template dies on a token whose variable is unset, so this is also the check that stage
# 40 exports everything the templates ask for. It is run with the same exports stage 40 makes.
RENDER="$TMP/rendered"; mkdir -p "$RENDER"
# There is no computed token here any more, and that is itself the property worth stating.
# @CAL_MANAGED_PAGE@ used to be one: the managed-enrolment page was optional, so stage 40 decided
# whether settings.conf named it and this function had to render both answers. plan/21 replaced
# that page with the accounts page, which is MANDATORY — it is what creates the account — so
# settings.conf names it unconditionally and stage 40 dies rather than substituting nothing.
render_all() {
    ( set -e
      export REPO="$REPO_ROOT" WORK="$TMP/w" OUT="$TMP/o" STAGE_NAME=t BUILD_PROFILE_OVERRIDE=installer
      source "$REPO_ROOT/scripts/lib/common.sh"
      load_config
      export DISTRO_ID DISTRO_NAME VERSION HOME_URL INTERNET_CHECK_URL LIVE_USER UPDATE_URL UPDATE_CHANNEL
      export GPT_TYPE_ROOT_X64 GPT_TYPE_VAR GPT_TYPE_ESP ROOT_SLOT_SIZE_MIB ROOT_PARTLABEL \
             UKI_NAME PAYLOAD_DIR
      while IFS= read -r -d '' f; do
          rel="${f#"$CAL"/}"; out="$RENDER/${rel%.in}"
          mkdir -p -- "$(dirname -- "$out")"
          if [[ $f == *.in ]]; then render_template "$f" "$out"; else cp -- "$f" "$out"; fi
      done < <(find "$CAL" -type f -print0) )
}
assert_true "every Calamares template renders (no unset @TOKEN@)" render_all
assert_false "settings.conf.in carries no computed sequence token any more" \
    grep -q '@CAL_MANAGED_PAGE@' "$CAL/settings.conf.in"
# -I, GNU grep's own binary test, for the same reason run-tests.sh's CRLF scan grew one: this
# tree now carries a PNG (the medium's one wallpaper, plan/20 §2.1), and 382 KB of DEFLATE output
# contains "@Q@" and "@A@" by arithmetic rather than by anyone's mistake. A token scan is a
# statement about text; a file with no text in it cannot fail it meaningfully.
assert_false "no unrendered @TOKEN@ survives in the rendered tree" \
    bash -c "grep -rIlE '@[A-Z][A-Z0-9_]*@' '$RENDER' | grep -q ."

# ---- 5. ONE description of the disk layout, and the medium carries it ------------------------
# THE check this file exists for, and plan/24 changed its shape rather than its subject.
#
# It used to compare two descriptions of one layout: emit_sfdisk_script() in lib/common.sh built
# the factory .img, a `partitionLayout:` block in modules/partition.conf told Calamares' stock
# partition module to build the same thing, and this section checked them against each other label
# by label and GUID by GUID. That can only ever catch the drift it was taught to look for.
#
# There is one description now. lib/layout.sh holds it, common.sh sources it, and stage 40 puts
# the same file on the installer medium for the `disksetup` job to run. So what is asserted here
# is that the arrangement is still that arrangement — because the way it would come apart is
# somebody re-introducing a second copy, which would look like a perfectly reasonable patch.
LAYOUT_SH="$REPO_ROOT/scripts/lib/layout.sh"
assert_file "$LAYOUT_SH" "lib/layout.sh, the one description of the partition layout"
assert_true "common.sh sources it rather than defining the layout itself" \
    grep -qE '^source "\$\(dirname -- "\$\{BASH_SOURCE\[0\]\}"\)/layout\.sh"' \
        "$REPO_ROOT/scripts/lib/common.sh"
for fn in compute_layout emit_sfdisk_script emit_install_sfdisk_script; do
    assert_true "layout.sh defines $fn" grep -qE "^$fn\(\) \{" "$LAYOUT_SH"
    assert_false "...and common.sh does not define $fn a second time" \
        grep -qE "^$fn\(\) \{" "$REPO_ROOT/scripts/lib/common.sh"
done
# Self-contained, because the copy on the medium has no $REPO, no load_config and no build.conf.
# Comments stripped first: the file's own header explains at length why it must not reach for any
# of these, and a scan that read the explanation as the thing would fail on the documentation.
assert_false "layout.sh reaches for nothing the installer medium does not have" \
    bash -c "grep -vE '^[[:space:]]*#' '$LAYOUT_SH' | grep -qE '\\\$REPO|load_config|BUILD_PROFILE'"
# Library when sourced, CLI when run. The guard is what keeps sourcing it from parsing arguments.
assert_true "layout.sh runs its CLI only when executed" \
    grep -qF 'if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then' "$LAYOUT_SH"

# The factory image's layout, unchanged by the move.
factory="$(compute_layout 1024 6144 4096 2; emit_sfdisk_script "$I_VERSION")"
for token in "$I_ROOT_PARTLABEL" '_empty' 'esp' 'var'; do
    assert_true "the factory layout names '$token'" grep -q -- "\"$token\"" <<<"$factory"
done

# ...and the INSTALLER's layout, from the same file, for a disk somebody owns. This is the
# assertion the old partition.conf comparison was standing in for, and it is now a real one: the
# same four names, the same two GPT types, the same slot size, computed by the same function.
installed="$(emit_install_sfdisk_script 65536 "$I_ESP_SIZE_MIB" "$I_ROOT_SLOT_SIZE_MIB" "$I_VERSION")"
assert_eq "4" "$(grep -c '^start=' <<<"$installed")" "an installed machine gets four partitions"
for token in "$I_ROOT_PARTLABEL" '_empty' 'esp' 'var'; do
    assert_true "the installed layout names '$token'" grep -q -- "\"$token\"" <<<"$installed"
done
assert_eq "2" "$(grep -c "$GPT_TYPE_ROOT_X64" <<<"$installed")" \
    "the INSTALLED system gets both A/B root slots, even though the medium has one"
assert_true "the installed layout uses the pipeline's var GPT type" \
    grep -qi "$GPT_TYPE_VAR" <<<"$installed"
assert_true "the installed layout sizes the root slots from ROOT_SLOT_SIZE_MIB" \
    grep -q "size=${I_ROOT_SLOT_SIZE_MIB}MiB" <<<"$installed"
# var takes the REMAINDER, which is what makes the first-boot repart grow a no-op on an installed
# machine — and what makes the layout fit a disk of any size at all.
assert_true "var is sized to what is left of the disk" \
    bash -c 'grep -q "name=\"var\"" <<<"$1" &&
             [[ $(sed -nE "s/.*start=([0-9]+)MiB, size=([0-9]+)MiB.*var.*/\\1 \\2/p" <<<"$1") ]]' _ "$installed"
assert_true "the whole layout adds up to exactly the disk it was given" \
    bash -c 'read -r st sz < <(sed -nE "s/^start=([0-9]+)MiB, size=([0-9]+)MiB.*var\".*/\\1 \\2/p" <<<"$1")
             (( st + sz + 1 == 65536 ))' _ "$installed"
# A disk too small for the layout is refused rather than truncated. The page is supposed to have
# refused it first; this is the second of the two checks that stand between a bad number and a
# half-written GPT.
assert_false "a disk too small for the layout is refused" \
    bash -c "source '$LAYOUT_SH'; emit_install_sfdisk_script 8192 1024 6144 9.9.9 2>/dev/null"

# partition.conf is GONE, and the stale-config hazard is why this is asserted rather than assumed:
# stage 40 wipes /etc/calamares before rendering precisely because a deleted .conf.in otherwise
# leaves its .conf on the medium forever (the welcome.conf finding, plan/22).
assert_false "modules/partition.conf.in is gone with the module it configured" \
    test -e "$CAL/modules/partition.conf.in"
assert_false "...and nothing renders a partition.conf" test -e "$RENDER/modules/partition.conf"

# The medium's copy of the layout, and the one path that names it. A job that cannot find its
# helper fails after the user has been told their disk is about to be erased.
STAGE40="$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 installs layout.sh onto the medium" \
    grep -qF 'DISK_LAYOUT_SRC="$REPO/scripts/lib/layout.sh"' "$STAGE40"
assert_true "...verbatim, and asserts it" grep -qF 'cmp -s "$DISK_LAYOUT_SRC" "$DISK_LAYOUT_DST"' "$STAGE40"
assert_true "...executable" grep -qF 'chmod 0755 -- "$DISK_LAYOUT_DST"' "$STAGE40"
DISKSETUP_CONF="$RENDER/modules/disksetup.conf"
assert_file "$DISKSETUP_CONF" "disksetup.conf rendered"
assert_true "disksetup.conf names the helper stage 40 installs" \
    grep -qE "^layoutHelper:[[:space:]]+\"/usr/libexec/${I_DISTRO_ID}-disk-layout\"" "$DISKSETUP_CONF"
assert_true "...and stage 40 installs it under exactly that name" \
    grep -qF 'DISK_LAYOUT_DST="$TARGET/usr/libexec/$DISTRO_ID-disk-layout"' "$STAGE40"
# THE INTERPRETER LINE, WITHOUT WHICH THE HELPER IS NOT A PROGRAM. The job runs this file with
# python's subprocess — plain execve — and execve refuses a text file whose first two bytes are
# not `#!`. A shell would have adopted it anyway (bash's ENOEXEC fallback), which is how stage
# 40's probe passed and a whole medium shipped whose every install died at "[Errno 8] Exec
# format error" one screen after the user agreed to the erase. Sourcing — the pipeline's path —
# never reads the line, so it costs the builder nothing.
assert_eq "#!/bin/bash" "$(head -n 1 "$LAYOUT_SH")" \
    "the layout helper carries the interpreter its execve requires"
# The builder has to check for it as bytes: running the file proves nothing (the shell adopts a
# shebang-less script), and neither does `env`, because glibc's execvp keeps the /bin/sh fallback.
assert_true "stage 40 checks the helper's interpreter line itself" \
    grep -qF "== '#!/bin/bash'" "$STAGE40"
# The other half of the same failure: a shebang naming an interpreter the medium does not carry
# is ENOENT, one screen later all the same.
assert_true "...and checks the interpreter is on the medium" \
    grep -qF '[[ -x $TARGET/bin/bash ]]' "$STAGE40"
# The job must not grow a layout of its own. A GPT type GUID in main.py would be the second
# description coming back by another door.
assert_false "the disksetup job carries no partition layout of its own" \
    grep -qiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        "$CAL/local-modules/disksetup/main.py"

# ONE NUMBER FOR THE MINIMUM DISK, rendered into both pages that use it (plan/24, Q1). The greeting
# page decides whether Next may be pressed; the disk page decides which rows are selectable. Two
# numbers would eventually be two answers, and the symptom is an installer that says this computer
# can install and then offers nothing to install onto.
DISK_CONF="$RENDER/modules/disk.conf"
assert_file "$DISK_CONF" "disk.conf rendered"
# disk.conf and disksetup.conf must name the SAME helper (plan/33 §5): the page's own
# `disk-layout inspect` and the job's re-check are the same subprocess call, run against the
# same binary, or "the page offered a keep and the job refused it" becomes a possible outcome.
disk_conf_helper="$(sed -nE 's/^layoutHelper:[[:space:]]+"([^"]+)".*/\1/p' "$DISK_CONF")"
disksetup_conf_helper="$(sed -nE 's/^layoutHelper:[[:space:]]+"([^"]+)".*/\1/p' "$DISKSETUP_CONF")"
assert_eq "/usr/libexec/${I_DISTRO_ID}-disk-layout" "$disk_conf_helper" \
    "disk.conf's layoutHelper is the installed helper's path"
assert_eq "$disksetup_conf_helper" "$disk_conf_helper" \
    "disk.conf and disksetup.conf name the same layoutHelper"

# The keep path's own probe (plan/33 §11): stage 40 does not just install the helper and prove
# it can WRITE a layout (above) — it also proves the helper's `inspect` recognises that very
# layout as keepable, against a real sfdisk table rather than a fixture.
assert_true "stage 40 also probes the helper's inspect path" \
    grep -qF '"$DISK_LAYOUT_DST" inspect --device "$_layout_scratch"' "$STAGE40"
assert_true "...and requires verdict=keep" grep -qF "grep -qx 'verdict=keep'" "$STAGE40"
assert_true "...and requires installed=\$VERSION" \
    grep -qF 'grep -qx "installed=$VERSION"' "$STAGE40"

min_greeting="$(sed -nE 's/^[[:space:]]*requiredStorage:[[:space:]]+([0-9.]+).*/\1/p' "$RENDER/modules/greeting.conf")"
min_disk="$(sed -nE 's/^minimumDiskSize:[[:space:]]+([0-9.]+).*/\1/p' "$DISK_CONF")"
min_job="$(sed -nE 's/^minimumDiskSize:[[:space:]]+([0-9.]+).*/\1/p' "$DISKSETUP_CONF")"
assert_eq "$I_MIN_INSTALL_DISK_GB" "$min_greeting" "greeting.conf's requiredStorage is build.conf's number"
assert_eq "$I_MIN_INSTALL_DISK_GB" "$min_disk"     "disk.conf's minimumDiskSize is the same number"
assert_eq "$I_MIN_INSTALL_DISK_GB" "$min_job"      "and so is the job's re-check"
# ...and the page draws the same geometry the job creates.
assert_eq "$I_ESP_SIZE_MIB" "$(sed -nE 's/^espSizeMiB:[[:space:]]+([0-9]+).*/\1/p' "$DISK_CONF")" \
    "disk.conf's bar is drawn from the build's ESP size"
assert_eq "$I_ROOT_SLOT_SIZE_MIB" "$(sed -nE 's/^rootSlotSizeMiB:[[:space:]]+([0-9]+).*/\1/p' "$DISK_CONF")" \
    "disk.conf's bar is drawn from the build's root slot size"

# DECIMAL, on both pages (plan/24 §3). This is invisible at build time and obvious to a user: the
# greeting page used to say "34.4 GiB needed" for a config that said 32.0, and the disk page lists
# disks by the size printed on them. The two have to agree, and the only thing that makes them
# agree is the formatter each one uses.
GREET_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-greeting/files"
DISK_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-disk/files"
APPS_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-apps/files"
assert_true "the greeting page reports disk sizes in decimal GB" \
    bash -c "sed -n '/^diskBytes( qint64 bytes )/,/^}/p' '$GREET_SRC/Requirements.cpp' |
             grep -q 'DataSizeSIFormat'"
assert_true "...and its storage requirement is read as GB, not GiB" \
    grep -q 'm_requiredStorageGB \* GB' "$GREET_SRC/Requirements.cpp"
assert_true "memory stays IEC, because RAM really is sold in binary multiples" \
    bash -c "sed -n '/^memoryBytes( qint64 bytes )/,/^}/p' '$GREET_SRC/Requirements.cpp' |
             grep -q 'DataSizeIecFormat'"
assert_true "the disk page uses the same decimal formatter" \
    bash -c "sed -n '/^DiskModel::formatSize( qint64 bytes )/,/^}/p' '$DISK_SRC/DiskModel.cpp' |
             grep -q 'DataSizeSIFormat'"

# AND THE NUMBERS HAVE TO ARRIVE AT ALL, which for one build they did not. Calamares'
# utils/Yaml.cpp reads every unquoted integer scalar into a QVariant holding a qlonglong, and
# utils/Variant.cpp's getDouble() accepts only Int and Double — so `requiredStorage: 32` returned
# the caller's default and `requiredStorage: 32.0` returned 32. Moving these keys onto
# build.conf's integers therefore turned four of the five numbers on these two pages into zero:
# the greeting dropped its disk check and announced that a machine with NO DISK ATTACHED could
# install, the disk page offered "a disk of at least 0 bytes", and the plan bar drew nothing.
#
# Nothing else in this file could have caught that — the template was right, the rendered file was
# right, and the value was simply never delivered. So the assertion is on the READER: both pages
# parse their own numbers, and neither may call the upstream function that drops them.
for f in "$GREET_SRC/Requirements.cpp" "$DISK_SRC/DiskConfig.cpp"; do
    n="$(basename "$f")"
    assert_true "$n reads its configuration numbers with configNumber()" \
        grep -q '^configNumber( const QVariantMap& map' "$f"
    assert_false "...and not with Calamares::getDouble(), which drops YAML integers" \
        bash -c "grep -vE '^[[:space:]]*\*|^[[:space:]]*//' '$f' | grep -q 'Calamares::getDouble'"
    assert_true "...refusing booleans rather than converting them" \
        bash -c "sed -n '/^configNumber( const QVariantMap& map/,/^}/p' '$f' |
                 grep -q 'QMetaType::Bool'"
done
# Every numeric key on either page goes through it, so a sixth one cannot quietly go back.
# Two map names, because the greeting's numbers sit under a nested `requirements:` block while
# the disk page's are top-level keys: three call sites hand configNumber() the configurationMap
# and two hand it the requirements sub-map, and a grep for either spelling alone undercounts.
assert_eq "5" \
    "$(cat "$GREET_SRC/Requirements.cpp" "$DISK_SRC/DiskConfig.cpp" |
       grep -cE 'configNumber\( (configurationMap|requirements),')" \
    "all five numeric keys on the two pages are read that way"

# The label that ties the disk to the boot: the layout helper writes it, imagedeploy looks for it,
# and the UKI cmdline (stage 40) and sysupdate's transfer both hardcode the same shape.
assert_true "imagedeploy.conf looks for the partition the layout creates" \
    grep -q "\"$I_ROOT_PARTLABEL\"" "$RENDER/modules/imagedeploy.conf"
assert_true "disksetup.conf checks the layout produced that same label" \
    grep -q "^rootPartLabel:[[:space:]]*\"$I_ROOT_PARTLABEL\"" "$DISKSETUP_CONF"
assert_true "imagebootloader.conf installs the UKI under its identity name" \
    grep -q "\"$I_UKI_NAME\"" "$RENDER/modules/imagebootloader.conf"
assert_false "no Calamares config carries the profile name in an identity string" \
    grep -rq 'root_.*-installer\|_0\..*-installer\.efi' "$RENDER"

# ---- 5b. the branding file Calamares will actually accept -----------------------------------
# Calamares exits before drawing a window if this file is wrong, so every failure here is
# "the installer does not start" on a medium that built cleanly.
BRAND="$RENDER/branding/installer/branding.desc"
assert_file "$BRAND" "branding.desc rendered"
# componentName must equal the directory name (Branding.cpp:229) or it bails.
assert_true "branding.desc's componentName matches its directory" \
    grep -qE '^componentName:[[:space:]]+installer$' "$BRAND"
# The three sections loadStrings() requires to be maps; a missing one throws and bails.
for k in strings images style; do
    assert_true "branding.desc has a '$k' map" grep -qE "^$k:" "$BRAND"
done
# slideshow is the ONE key Branding.cpp reads through get(), which throws KeyNotFound for a
# missing key — "FATAL in …branding.desc key not found: slideshow", an exit before any window.
# Omitting it is an easy and entirely silent mistake to make, and an EMPTY list is not a fix
# either: SlideshowPictures then displays Calamares' own squid mascot on our progress page.
assert_true "branding.desc declares a slideshow (Calamares makes it mandatory)" \
    grep -qE '^slideshow:' "$BRAND"
assert_true "the slideshow is not empty (an empty list shows Calamares' own mascot)" \
    bash -c 'sed -n "/^slideshow:/,/^[a-zA-Z]/p" "$1" | grep -qE "^[[:space:]]*-[[:space:]]+\"?[^ \"]+"' _ "$BRAND"

# EVERY file the branding names must be one the build actually produces. This is the assertion
# that catches a branding key referring to an asset nobody generates — which Calamares reports
# only at startup, as "Image file … does not exist", on the medium.
# sed strips comments first: this file explains the squid fallback in prose, and a naive scan
# reads ":/data/images/squid.svg" out of the explanation as if it were a setting.
mapfile -t BRAND_FILES < <(sed 's/#.*//' "$BRAND" | grep -oE '"[^"]+\.(png|svg|qml)"' | tr -d '"' | sort -u)
(( ${#BRAND_FILES[@]} > 0 )) || _fail "branding.desc names no image files at all"
for f in "${BRAND_FILES[@]}"; do
    if [[ -f $CAL/branding/installer/$f ]]; then
        _pass   # committed in the repo
    elif grep -qE -- "--(logo|slide|bmp|sprites)[[:space:]]+\"[^\"]*/$f\"" "$REPO_ROOT/scripts/stages/40-configure.sh"; then
        _pass   # generated into the branding component by stage 40
    elif [[ $f == /* ]] && grep -qF -- "\"$f\"" "$REPO_ROOT/scripts/stages/40-configure.sh"; then
        # A THIRD CASE SINCE plan/32 §2: a file that comes from the IMAGE rather than from this
        # directory — productIcon is Calamares' own icon, installed by app-admin/calamares. The
        # evidence is the same evidence one indirection over: stage 40 names the path and dies if
        # it is not in the target, so this asserts that the check exists and names this file.
        _pass
    else
        _fail "branding.desc names '$f', which is neither committed in config/calamares/branding/installer/, generated by stage 40, nor an absolute path stage 40 checks for in the target — Calamares would bail with \"Image file … does not exist\""
    fi
done

# BOTH WINDOW PANELS ARE QML (plan/26 §5 for the sidebar, plan/28 for the bar under it). The
# widget flavours draw Breeze's metrics — and, for the sidebar, hard-code centred step names in
# upstream's ProgressTreeDelegate, unreachable from branding — beside nine pages that draw the
# design system's. The branding component ships both files itself, because searchQmlFile looks in
# the branding directory before the compiled-in stock copy.
assert_true "branding.desc switches the sidebar to QML" \
    grep -qE '^sidebar:[[:space:]]+qml$' "$BRAND"
assert_true "...and the navigation bar with it" \
    grep -qE '^navigation:[[:space:]]+qml$' "$BRAND"
SIDEBAR_QML="$CAL/branding/installer/calamares-sidebar.qml"
NAV_QML="$CAL/branding/installer/calamares-navigation.qml"
assert_file "$SIDEBAR_QML" "the branding component carries its own calamares-sidebar.qml"
assert_file "$NAV_QML" "...and its own calamares-navigation.qml"
assert_false "no step text is centred any more" \
    bash -c "sed -n '/Repeater {/,/^        }/p' '$SIDEBAR_QML' |
             grep -v '^[[:space:]]*//' | grep -q 'horizontalCenter'"

# THE PANELS PAINT THE DESIGN SYSTEM, AND THEY GET IT THE ONLY WAY THEY CAN. They belong to no
# view module, so there is no .so to compile a Qt resource into and stage 20's fan-out does not
# reach them: stage 40 stages Theme.qml beside them instead, where QML's implicit
# local-directory import finds it. Miss that and both panels fail to load with a type error —
# a window with a blank rail and no buttons.
for panel in "$SIDEBAR_QML" "$NAV_QML"; do
    assert_true "$(basename -- "$panel") owns a token object" \
        grep -qE '^\s*readonly property Theme ds: Theme \{\}$' "$panel"
done
# EVERY ViewManager LABEL IN THE NAVIGATION BAR IS STRIPPED OF ITS MNEMONIC, and the booted
# medium is what asked for this assertion: the bar came up reading "&Cancel  &Back  &Next".
# ViewManager's labels are WIDGET labels — "&Back" marks Alt-B — and a QWidget eats the ampersand
# and underlines the letter, while a QML Text has no such convention and draws the ampersand.
# Upstream's calamares-navigation.qml, which this file was copied from, has the same bug; it is
# titled "Sample of QML navigation". Nothing offline catches a wrong STRING in a label, so what is
# pinned here is the shape: no ViewManager *Label may reach a NavButton without going through
# plainLabel().
NAV_RAW_LABELS="$(grep -cE 'label:[[:space:]]*ViewManager\.[A-Za-z]*Label' "$NAV_QML" || true)"
assert_eq "0" "$NAV_RAW_LABELS" \
    "no navigation label binds ViewManager's mnemonic text straight into a QML Text"
assert_true "the navigation bar strips widget mnemonics from its labels" \
    grep -qE '^\s*function plainLabel\(' "$NAV_QML"

assert_true "stage 40 stages Theme.qml into the branding component for them" \
    grep -q 'cal_install "$CAL_THEME_SRC" "$TARGET/etc/calamares/branding/installer/Theme.qml"' \
        "$REPO_ROOT/scripts/stages/40-configure.sh"

# THE SAME COLOUR IN THREE PLACES, AND THEY HAVE TO AGREE. The sidebar's ground is
# --surface-page; branding.desc states it for the widget flavours, Theme.qml states it for the
# QML ones, and stage 40 passes it to make-splash-assets.py as the ground logo.png is FLATTENED
# ONTO. A disagreement between the first two is a mismatched rail; a disagreement with the third
# is a logo with a visible rectangle round it, which is the exact thing branding.desc's oldest
# comment promises will not happen.
BRAND_SIDEBAR_BG="$(grep -oE 'SidebarBackground:[[:space:]]+"#[0-9a-fA-F]{6}"' "$BRAND" |
                    grep -oE '#[0-9a-fA-F]{6}')"
THEME_SURFACE_PAGE="$(grep -oE 'readonly property color basalt50: +"#[0-9a-fA-F]{6}"' "$CAL/qml/Theme.qml" |
                      grep -oE '#[0-9a-fA-F]{6}')"
STAGE40_BG="$(grep -oE 'INSTALLER_SURFACE_PAGE="#[0-9a-fA-F]{6}"' \
                  "$REPO_ROOT/scripts/stages/40-configure.sh" | grep -oE '#[0-9a-fA-F]{6}')"
assert_eq "$THEME_SURFACE_PAGE" "$BRAND_SIDEBAR_BG" \
    "branding.desc's SidebarBackground is Theme.qml's --surface-page"
assert_eq "$THEME_SURFACE_PAGE" "$STAGE40_BG" \
    "...and so is the ground stage 40 flattens logo.png onto"
assert_true "...which stage 40 actually passes to the generator" \
    grep -q -- '--bg "$INSTALLER_SURFACE_PAGE"' "$REPO_ROOT/scripts/stages/40-configure.sh"

# AND THE WORDMARK'S INK, which is the half of this that the offline suite found rather than
# predicted. config/branding/wordmark.svg fills its glyphs with the DARK theme's --text-strong,
# because that was every consumer's ground when it was outlined — so on the light sidebar the
# wordmark IS the ground and the logo is a logomark with a blank space under it. Nothing about
# the build says so; the mark still renders, the canvas is still the right size.
THEME_TEXT_STRONG="$(grep -oE 'readonly property color basalt900: +"#[0-9a-fA-F]{6}"' "$CAL/qml/Theme.qml" |
                     grep -oE '#[0-9a-fA-F]{6}')"
STAGE40_INK="$(grep -oE 'INSTALLER_TEXT_STRONG="#[0-9a-fA-F]{6}"' \
                   "$REPO_ROOT/scripts/stages/40-configure.sh" | grep -oE '#[0-9a-fA-F]{6}')"
assert_eq "$THEME_TEXT_STRONG" "$STAGE40_INK" \
    "the wordmark's ink is Theme.qml's --text-strong"
assert_true "...and stage 40 passes it alongside the ground" \
    grep -q -- '--ink "$INSTALLER_TEXT_STRONG"' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "...and the generator refuses an ink that equals its ground" \
    grep -q 'if installer_ink == installer_bg:' "$REPO_ROOT/config/branding/make-splash-assets.py"
# ...and the BOOT splash is not dragged along with it. One layout function, two grounds: --bg
# defaults to the dark --surface-sunken precisely so that build_slide()'s second caller, the
# Plasma splash preview, keeps the theme it belongs to.
assert_true "the generator still defaults to the boot splash's dark ground" \
    grep -qE '^    installer_bg = parse_bg\(args\.bg\) if args\.bg else BG$' \
        "$REPO_ROOT/config/branding/make-splash-assets.py"
assert_false "...and the Plasma splash preview is not given the installer's" \
    bash -c "grep -A3 'previews/splash.png' '$REPO_ROOT/scripts/stages/40-configure.sh' | grep -q -- '--bg'"
# The sidebar's own two words ask the catalogue BY NAME (plan/27 §3): qsTranslate with an explicit
# CalamaresSidebar context, because the context a plain qsTr would use is unspellable without a
# QML-aware lupdate to discover it. The context is hand-maintained in the .ts files, the
# LanguageNames bargain — see the pseudo-context assertions in the translations section.
assert_true "the sidebar's buttons ask the catalogue by a named context" \
    grep -q 'qsTranslate("CalamaresSidebar", "About")' "$SIDEBAR_QML"
assert_false "...and no bare qsTr() call is left in it either" \
    grep -q 'qsTr("' "$SIDEBAR_QML"
# The file's NAME is load-bearing twice over: CalamaresWindow finds this copy by it (searchQmlFile
# asks for "calamares-sidebar"), and the language module finds the built panel by it in order to
# retranslate the engine nobody else does — see the LanguageViewStep assertions below.
assert_true "the language module knows this file by name, which is how the sidebar re-says" \
    grep -q "\"$(basename "$SIDEBAR_QML")\"" \
        "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-language/files/LanguageViewStep.cpp"

# ---- 6. the modules exist and are wired into the sequence -----------------------------------
SETTINGS="$RENDER/settings.conf"
assert_file "$SETTINGS" "settings.conf rendered"
mapfile -t OURS < <(find "$CAL/local-modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
# EIGHT since plan/28 §6, and the count is a number on purpose: a job module that appears without
# being argued for is a job nobody reviewed.
#
# Six of them are substitutions for stock modules whose PAGES this project replaced — a view step
# owns its jobs(), so replacing a page orphans whatever job was attached to it. disksetup took the
# exec half of stock `partition` (plan/24); accountsetup replaced managedenroll AND the stock
# `users` module's jobs (plan/21); localesetup and keyboardsetup took SetTimezoneJob and
# SetKeyboardLayoutJob when plan/28 §6 replaced the `locale` and `keyboard` pages; imagedeploy and
# imagebootloader replaced unpackfs+mount and bootloader.
#
# Two replace nothing at all: `appsetup` downloads what the applications page chose, and no stock
# module ever asked that question; `imageidentity` is a pile of per-image fixups nothing stock
# covers.
(( ${#OURS[@]} == 8 )) || _fail "expected eight local modules, found ${#OURS[@]}: ${OURS[*]}"
for m in "${OURS[@]}"; do
    d="$CAL/local-modules/$m"
    assert_file "$d/module.desc" "$m has a module descriptor"
    # main.py or main.py.in — cal_install renders the second into the first, and accountsetup
    # needs to be a template because it execs /usr/bin/<id>-managed and -domain by name.
    SCRIPT="$d/main.py"; [[ -f $SCRIPT ]] || SCRIPT="$d/main.py.in"
    assert_file "$SCRIPT"        "$m has a main.py"
    # The silent-skip failure: ModuleManager compares this against the directory name.
    assert_true "$m's module.desc declares name: \"$m\"" \
        grep -qE "^name:[[:space:]]+\"$m\"" "$d/module.desc"
    assert_true "$m declares the python interface" grep -qE '^interface:[[:space:]]+"python"' "$d/module.desc"
    assert_true "$m declares script: main.py"      grep -qE '^script:[[:space:]]+"main.py"' "$d/module.desc"
    # Calamares calls run(); a helper that shadows it means the module does nothing and reports
    # success, which is exactly what a first draft of imagedeploy did.
    assert_eq "1" "$(grep -cE '^def run\(' "$SCRIPT")" "$m defines run() exactly once"
    # Rendered before parsing when it is a template: @DISTRO_ID@ is not valid Python, and a check
    # that skipped templates would stop checking the newest module in the list.
    PYSRC="$SCRIPT"
    if [[ $SCRIPT == *.in ]]; then
        PYSRC="$TMP/$m-main.py"
        ( export REPO="$REPO_ROOT" WORK="$TMP/w" OUT="$TMP/o" STAGE_NAME=t
          source "$REPO_ROOT/scripts/lib/common.sh"; load_config
          render_template "$SCRIPT" "$PYSRC" )
    fi
    assert_true "$m/main.py is valid python" python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PYSRC"
    # ...and it has to be IN the sequence, or it is dead code on the medium.
    assert_true "$m appears in settings.conf's sequence" grep -qE "^[[:space:]]*-[[:space:]]+$m$" "$SETTINGS"
    # ...with a config, since every one of them reads build-time facts out of one. accountsetup
    # is the exception, and for a reason worth stating: its configuration is accounts.conf,
    # which belongs to the PAGE. Both read the same file — the page for the fields it draws and
    # the validation it applies, the job for defaultGroups' must_exist and writeHostsFile — so a
    # second accountsetup.conf would be a place for the two halves of one decision to disagree.
    [[ $m == accountsetup ]] \
        || assert_file "$RENDER/modules/$m.conf" "$m has a rendered config"
done

# Every module named in the sequence must have a config we ship or be a stock module that needs
# none. Checked the other way round: every config we ship must be referenced, or it is a file
# nobody reads that looks like configuration.
for f in "$RENDER"/modules/*.conf; do
    n="$(basename -- "$f" .conf)"
    assert_true "modules/$n.conf is referenced by the sequence" \
        grep -qE "^[[:space:]]*-[[:space:]]+$n$" "$SETTINGS"
done
# accounts.conf passes the loop above because `accounts` IS in the sequence — but it is the only
# config in this tree read by a module that is not in this tree, so its keys are checked here
# rather than left to the page to fail on quietly. Each of these four is load-bearing: modes
# decides which radio buttons exist at all, defaultGroups is what the job asserts against the
# target, enrolScratchRoot is where the page enrols before the disk is written, and secretsPath is
# the only channel a password travels on (plan/21 §3, §4).
ACCOUNTS_CONF="$RENDER/modules/accounts.conf"
assert_file "$ACCOUNTS_CONF" "accounts.conf rendered"
for k in modes defaultGroups passwordRequirements enrolScratchRoot secretsPath failsafeUserName; do
    assert_true "accounts.conf sets $k" grep -qE "^$k:" "$ACCOUNTS_CONF"
done
assert_true "accounts.conf offers all three modes" \
    bash -c "grep -E '^modes:' '$ACCOUNTS_CONF' | grep -q 'local' &&
             grep -E '^modes:' '$ACCOUNTS_CONF' | grep -q 'managed' &&
             grep -E '^modes:' '$ACCOUNTS_CONF' | grep -q 'domain'"
# The scratch root and the secrets file are both on tmpfs, and that is not cosmetic: /run is the
# only writable path on the live medium that is guaranteed not to survive the reboot, and the
# secrets file holds a plaintext password until the job unlinks it.
for k in enrolScratchRoot secretsPath; do
    assert_true "accounts.conf's $k is under /run" \
        grep -qE "^$k:[[:space:]]+\"?/run/" "$ACCOUNTS_CONF"
done

# ---- 6a. the accounts page's own behaviour (plan/26) ------------------------------------------
# THE CHOOSER OPENS ANSWERED. Local is pre-selected when the profile offers it, which turns the
# first screen from a question into a confirmation for the machines that outnumber all the
# others; a profile offering no local mode keeps plan/21's nothing-selected rule, because there
# is nothing that can honestly be pre-selected. This is the C++ half, and it was the only half
# until plan/31 §3: the CARDS did not read it, so the page opened in a mode the screen did not
# name. Section 6w has the other half.
assert_true "setConfigurationMap pre-selects Local when it is offered" \
    bash -c "sed -n '/^AccountsConfig::setConfigurationMap/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -q 'm_mode = Local'"
# A WEAK PASSWORD IS A WARNING, NOT A WALL. The two-part gate: the button asks "complete?", the
# door asks "strong, or warned?" — so a complete-but-weak password leaves Next lit and puts the
# warning in the press, exactly as the disk page puts the erase question there.
assert_true "accounts.conf allows the weak-password question" \
    grep -qE '^[[:space:]]+allowWeakPasswords:' "$ACCOUNTS_CONF"
assert_true "the page reads the knob" \
    grep -q 'allowWeakPasswords' "$OVL_ACCOUNTS/files/AccountsConfig.cpp"
assert_true "the button asks complete, not strong" \
    bash -c "sed -n '/^AccountsConfig::nextEnabled() const/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -q 'm_allowWeakPasswords || m_passwordValid'"
assert_true "the door is passwordSettled(), asked on the way out" \
    grep -q 'passwordSettled()' "$OVL_ACCOUNTS/files/AccountsViewStep.cpp"
assert_true "...and the dialog's accept completes the advance" \
    grep -q 'ViewManager::instance()->next()' "$OVL_ACCOUNTS/files/AccountsViewStep.cpp"
assert_true "editing the password withdraws a given answer" \
    bash -c "sed -n '/^AccountsConfig::setPassword/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -q 'm_weakPasswordAccepted = false'"
# AUTO-LOGIN, OFFERED RATHER THAN FORBIDDEN: the checkbox on the local form, the mode-gated
# GlobalStorage key, and the job that writes the drop-in either way.
assert_true "the local form carries the checkbox" \
    grep -q 'Log in automatically as this user' "$OVL_ACCOUNTS/files/AccountsConfig.h"
assert_true "the page publishes autoLogin, local mode only" \
    grep -q 'm_mode == Local && m_autoLogin' "$OVL_ACCOUNTS/files/AccountsConfig.cpp"
assert_true "imageidentity honours the request with the same keys the image's drop-in uses" \
    bash -c "grep -q 'value(\"autoLogin\")' '$CAL/local-modules/imageidentity/main.py' &&
             grep -q 'Session=plasma' '$CAL/local-modules/imageidentity/main.py'"

# THE WORDS ARE C++ PROPERTIES (plan/27 §1). The builder's lupdate is built without QML support
# (plan/25 §4), so a qsTr() in this module's QML never reached the branding catalogue — the
# accounts page rendered English in all eight translated languages, and the weak-password dialog
# plan/26 added asked its question in English too. Every string is a tr()'d AccountsConfig
# property now, and the two retranslate halves — the halves this was the one QML module without —
# are what re-say them when the language changes.
assert_false "no qsTr() call is left in the accounts QML" \
    grep -rq 'qsTr("' "$OVL_ACCOUNTS/files/qml"
assert_true "the words live on AccountsConfig, where lupdate can see them" \
    grep -q 'tr( "Use this password anyway?" )' "$OVL_ACCOUNTS/files/AccountsConfig.h"
assert_true "the config carries the retranslate slot" \
    grep -q 'CALAMARES_RETRANSLATE_SLOT( &AccountsConfig::retranslate )' "$OVL_ACCOUNTS/files/AccountsConfig.cpp"
assert_true "...and the view step retranslates its QML engine on a language change" \
    grep -q 'engine()->retranslate()' "$OVL_ACCOUNTS/files/AccountsViewStep.cpp"
# PasswordCheck says its two strings in its own context: the QObject context they used to live in
# can never be finished (check 5 demands a file whose stem is the context name, and nothing is
# named QObject.cpp) — the one context in the catalogue that was unfinishable by construction.
# Comment lines excluded: the one explaining the change necessarily names what changed.
assert_true "PasswordCheck names its own context rather than QObject's" \
    grep -q 'translate( "PasswordCheck"' "$OVL_ACCOUNTS/files/PasswordCheck.cpp"
assert_false "...and no QObject::tr is left in it" \
    bash -c "grep -vE '^[[:space:]]*(//|/\*|\*)' '$OVL_ACCOUNTS/files/PasswordCheck.cpp' |
             grep -q 'QObject::tr'"
# THE ERROR GLUED TO ITS FIELD (plan/27 §6), and since plan/28 it cannot come unglued. A
# Kirigami.FormLayout gave every child its own row and its own gap, which put the red message a
# row — and the meter's row — away from the field it answered; the fix was one spacing-0 form row
# per field, which worked and had to be remembered at every new field. The shared Field object
# carries label, value, error and hint as ONE item, so there is no longer a layout that could
# separate them and no rule left to remember. What these assert is that the forms use it.
assert_false "no form builds its own field out of a Kirigami.FormLayout row any more" \
    grep -rq 'Kirigami.FormData.label' "$OVL_ACCOUNTS/files/qml"
assert_true "the password field carries its own error message" \
    bash -c "grep -A5 'label: accounts.passwordLabel' '$OVL_ACCOUNTS/files/qml/LocalForm.qml' |
             grep -q 'error: accounts.passwordMessage'"
assert_true "...and the repeat field carries its own mismatch message" \
    bash -c "grep -A5 'label: accounts.passwordRepeatLabel' '$OVL_ACCOUNTS/files/qml/LocalForm.qml' |
             grep -q 'accounts.passwordsDifferText'"

# A PASSWORD FIELD MUST MASK, AND THE WAY IT DOES IT IS ONE PROPERTY. QtQuick.Controls has no
# `PasswordField` at all, so a `QQC2.PasswordField` is not a control with the wrong look — it is
# a type error, and the whole component tree fails to load with it. DomainForm instantiates
# unconditionally in Accounts.qml, so that one line took the entire page down: the QQuickWidget
# painted its clear colour, which is white, and the accounts page came up blank in every mode.
# Kirigami.PasswordField was the answer then; the shared Field's `echoPassword` is the answer now,
# and the same class of mistake — a field that silently shows what it is typing — is what these
# two assertions are about. The QML travels inside the .so as a resource and nothing compiles it
# at build time, so a type error reaches a VM untouched by the compiler that built the module
# around it; section 6i's qmllint pass is the other half of this net.
assert_false "no QQC2.PasswordField: QtQuick.Controls has no such type" \
    grep -rq 'QQC2\.PasswordField' "$OVL_ACCOUNTS/files/qml"
assert_true "the domain form's three password fields mask what is typed into them" \
    bash -c "[[ \$(grep -c 'echoPassword: true' '$OVL_ACCOUNTS/files/qml/DomainForm.qml') -eq 3 ]]"
assert_true "...and so do the local form's two" \
    bash -c "[[ \$(grep -c 'echoPassword: true' '$OVL_ACCOUNTS/files/qml/LocalForm.qml') -eq 2 ]]"

# The sequence must not name the stock modules that cannot work here. Each of these would fail
# or, worse, half-succeed: localecfg runs `locale-gen` in a target that has none; unpackfs looks
# for a squashfs; bootloader/grubcfg generate a GRUB config for a machine that boots a UKI;
# fstab writes a file that ships in the immutable image; machineid would give every machine
# installed from this medium the same one.
#
# THREE ENTRIES ON THIS LIST WOULD ACTUALLY WORK, and that is what makes them worth asserting:
# the rest fail loudly on a medium like this one, while these three would run and do the wrong
# thing instead — two of them a second page each, the third silently, on the one disk this whole
# feature exists to protect.
#
# `users` since plan/21. It is still installed, because it comes with app-admin/calamares and no
# USE flag removes it, so naming it costs nothing at build time and produces a second, additive
# account-creation step at run time: its own Active Directory checkbox appends a job and then
# creates the local account anyway (Config.cpp:1088-1104), which is precisely the shape the
# accounts page exists to remove.
#
# `welcome` since plan/22, for the same shape of reason. It would draw its own language combo box
# under its own requirements list — two pickers, and the second one writing GS LANG after the
# first. Worse, it would re-add the `storage` requirement and then delete it again: the ebuild's
# -DCMAKE_DISABLE_FIND_PACKAGE_LIBPARTED=ON makes GeneralRequirements.cpp:357 drop storage from
# both the check list and the required list with only a cWarning, which is the bug plan/22 §3a
# exists to close and this line keeps closed. Our `greeting` module (plan/23) borrows that page's
# requirements BOX and none of its checker, which is the whole of the difference.
#
# `partition` since plan/24, and it is the third of that kind: it WOULD work. Configured as it was
# — allowManualPartitioning off, a fixed partitionLayout — it produced a usable disk picker for the
# whole of Phase A. Naming it now would produce a second disk page, with upstream's words, whose
# jobs would rewrite the disk a second time from a layout that lives nowhere any more.
#
# `removeuser` since plan/33 §7, and it is the most dangerous of the three: RemoveUserJob.cpp
# (calamares-3.4.2) runs `userdel -f -r <live>` UNCONDITIONALLY — it takes no configuration that
# could tell it to stand down for a kept disk, which every other job this document touches does
# read (diskKeepData). On a disk kept from a factory image dd'd straight to a drive, @LIVE_USER@
# may be the only account there is, and `-r` deletes its home directory: the exact files this
# whole feature exists to keep. Its job — userdel on the live user, on an ERASE only — moved into
# accountsetup's own remove_live_user(), the last thing that job does, checked further down.
for forbidden in localecfg unpackfs fstab bootloader grubcfg initcpio initcpiocfg dracut \
                 initramfs machineid packages netinstall displaymanager mount users welcome \
                 partition removeuser; do
    assert_false "the sequence does not name the stock '$forbidden' module" \
        grep -qE "^[[:space:]]*-[[:space:]]+$forbidden$" "$SETTINGS"
done
assert_false "modules/removeuser.conf.in is deleted with the module it configured" \
    test -e "$CAL/modules/removeuser.conf.in"
assert_false "...and nothing renders a removeuser.conf" test -e "$RENDER/modules/removeuser.conf"
# ...and the pair that replaced it is there, in the right phase each. `accounts` in show: and
# `accountsetup` in exec: is not interchangeable — a page in the exec list draws nothing and a job
# in the show list is a step with no UI.
assert_true "the show sequence names the accounts page" \
    bash -c "sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+accounts\$'"
assert_true "the exec sequence names accountsetup" \
    bash -c "sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+accountsetup\$'"
# ...and the disk pair, the same way (plan/24). `disk` draws the page and `disksetup` writes the
# GPT; they are two modules for the same reason `accounts` and `accountsetup` are, plus one this
# pair has on its own — a Calamares view step owns its jobs(), so the partitioner had to leave with
# the page it belonged to.
assert_true "the show sequence names the disk page" \
    bash -c "sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+disk\$'"
assert_true "the exec sequence names disksetup" \
    bash -c "sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+disksetup\$'"
# ...and the applications pair, the same way (plan/25). `apps` draws the page, `appsetup`
# downloads its answer — two modules for the same one-question reason as the two pairs above.
assert_true "the show sequence names the applications page" \
    bash -c "sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+apps\$'"
assert_true "the exec sequence names appsetup" \
    bash -c "sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | grep -qE '^[[:space:]]*-[[:space:]]+appsetup\$'"
# LAST of the show sequence. Everything before it describes the machine being built; this
# describes what goes on top, so it belongs after the last machine question (accounts) and
# immediately before the summary that repeats every answer back.
assert_true "the applications page comes after accounts and before the summary" \
    bash -c "
      seq=\$(sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx accounts) -lt \$(idx apps) ]] &&
      [[ \$(idx apps) -lt \$(idx review) ]]"
# The disk page must come BEFORE the accounts page, and not because either depends on the other:
# the accounts page can spend minutes enrolling a managed machine against a real service (plan/21
# §3), and asking somebody to do that before they know whether the installer can even use their
# disk is the wrong order to waste their time in.
assert_true "the disk page comes before the accounts page" \
    bash -c "
      seq=\$(sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx disk) -lt \$(idx accounts) ]]"
# FIRST in exec:, and that is the one ordering in this file with no recovery. imagedeploy writes
# the root image into a partition by PARTLABEL; if it ran before the partitioner there would be no
# such partition, and if anything ran between them it would be operating on a disk that is about to
# be rewritten.
assert_true "disksetup is the FIRST exec step" \
    bash -c "sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' |
             sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p' | head -1 | grep -qx disksetup"

# Order, inside exec:. accountsetup must run AFTER imagedeploy (which mounts the target and its
# /etc overlay — every write below depends on it) and BEFORE imageidentity, which reads
# `username` out of GlobalStorage to allocate its subuid range.
#
# REMOVEUSER IS GONE FROM THIS CHECK, not merely from the sequence (plan/33 §7, §11): stock
# `removeuser` ran unconditionally and could not be told to stand down for a kept disk, so its
# job — userdel on the live user — moved INTO accountsetup, as the last thing that job does on
# an erase (see remove_live_user() in the accountsetup source, checked further down). The
# ordering this assertion used to protect — the real account exists before the live one goes —
# is now enforced by that function running after create_local_user() in the same job, which
# tests/test-domain.sh's comment on this module also used to name; both are corrected here.
assert_true "accountsetup runs after imagedeploy and before imageidentity" \
    bash -c "
      seq=\$(sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx imagedeploy) -lt \$(idx accountsetup) ]] &&
      [[ \$(idx accountsetup) -lt \$(idx imageidentity) ]]"
# appsetup LAST of the chroot work, after imageidentity and before umount (plan/25 §5). It needs
# everything imageidentity needed — a deployed, /var-seeded, chroot-ready target — and it must be
# the last thing that touches the target, because the one failure it can meet (a download that
# did not finish) is one every job before it would have had to decide something about, and the
# one after it (umount) exists to tear the target down whatever happened.
assert_true "appsetup runs after imageidentity and before umount" \
    bash -c "
      seq=\$(sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx imageidentity) -lt \$(idx appsetup) ]] &&
      [[ \$(idx appsetup) -lt \$(idx umount) ]]"

# ---- 6b. the language page (plan/22) --------------------------------------------------------
#
# FIRST, not merely present, and that is the one assertion here with no visible symptom on the
# page it protects. ModuleManager::loadModules() walks the sequence in order, and this module is
# where QQuickStyle::setStyle("org.kde.desktop") happens for the whole installer —
# a call Qt ignores, with one line on stderr, once anything has imported QtQuick.Controls. Put any
# other QML view step ahead of it and the ACCOUNTS page loses Breeze's colours, Breeze's metrics
# and every icon (plan/21 §1b measured all three in a VM).
FIRST_SHOW="$(sed -nE '/^sequence:/,$ { /^- show:/,/^- / { s/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_@-]*)[[:space:]]*$/\1/p } }' \
                "$SETTINGS" | head -1)"
assert_eq "language" "$FIRST_SHOW" "the language page is the FIRST module in the show sequence"

# ...AND THE GREETING IS SECOND (plan/23). Not for QQuickStyle's reason — this one draws no QML —
# but because everything on it is drawn in the language the page before it chose: the verdict, the
# product name and the sentence about erasing the disk.
SECOND_SHOW="$(sed -nE '/^sequence:/,$ { /^- show:/,/^- / { s/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_@-]*)[[:space:]]*$/\1/p } }' \
                 "$SETTINGS" | sed -n 2p)"
assert_eq "greeting" "$SECOND_SHOW" "the greeting page is the SECOND module in the show sequence"

LANGUAGE_CONF="$RENDER/modules/language.conf"
GREETING_CONF="$RENDER/modules/greeting.conf"
assert_file "$LANGUAGE_CONF" "language.conf rendered"
assert_file "$GREETING_CONF" "greeting.conf rendered"
assert_false "welcome.conf is gone — the stock module it configured is out of the sequence" \
    test -e "$RENDER/modules/welcome.conf"

# The requirement block, and `storage` in BOTH lists. Upstream's module accepted the same two keys
# and then discarded them (GeneralRequirements.cpp:357 under -DWITHOUT_LIBPARTED), so asserting
# that they are configured is not enough on its own — hence the source check further down.
#
# IN greeting.conf SINCE plan/23, and not in language.conf: a requirement is contributed by
# whichever module is in the sequence, so the keys live beside the module that reads them. The
# negative half matters as much as the positive one — a copy left in language.conf would be a
# second, ignored source of truth for the one number this page exists to enforce.
for k in requiredStorage requiredRam internetCheckUrl; do
    assert_true "greeting.conf sets $k" grep -qE "^[[:space:]]+$k:" "$GREETING_CONF"
done
assert_false "language.conf carries no requirements: block any more" \
    grep -qE "^[[:space:]]*requirements:" "$LANGUAGE_CONF"
if python3 -c 'import yaml' 2>/dev/null; then
    assert_true "greeting.conf checks AND requires storage, ram and root" \
        python3 -c '
import sys, yaml
r = yaml.safe_load(open(sys.argv[1]))["requirements"]
need = {"storage", "ram", "root"}
assert need <= set(r["check"]), "check: is missing %s" % (need - set(r["check"]))
assert need <= set(r["required"]), "required: is missing %s" % (need - set(r["required"]))
assert "internet" not in r["required"], "internet must not block: the payload is on the stick"
assert "power" not in r["required"], "power must not block: installing on battery is fine"
' "$GREETING_CONF"

    # The rendered list against the table it came from. A render that produced no rows leaves the
    # installer's first screen blank and logs an error nobody is watching for.
    assert_true "language.conf's list matches config/languages.conf row for row" \
        python3 -c '
import sys, yaml
rows = [[f.strip() for f in l.split("|")]
        for l in open(sys.argv[2], encoding="utf-8").read().splitlines()
        if l.strip() and not l.lstrip().startswith("#")]
got = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["languages"]
assert len(got) == len(rows), "%d rendered, %d in the table" % (len(got), len(rows))
for g, r in zip(got, rows):
    assert [g["id"], g["locale"], g["label"], g["english"]] == r, "%r != %r" % (g, r)
' "$LANGUAGE_CONF" "$REPO_ROOT/config/languages.conf"
fi

# THE PROPERTY THE WHOLE PAGE EXISTS FOR, expressed as one: nothing the user reads is a code, and
# no two rows are indistinguishable. The second half is what upstream's model could not give us —
# measured against Qt 6.11.1, `ja`/`ja-Hira` and `zh`/`zh_CN` render identically in BOTH of the
# roles it exposes (plan/22 §2a) — so it is asserted here on the table we control instead.
assert_true "no label or locale is a code, and no two rows collide" \
    python3 -c '
import sys
rows = [[f.strip() for f in l.split("|")]
        for l in open(sys.argv[1], encoding="utf-8").read().splitlines()
        if l.strip() and not l.lstrip().startswith("#")]
assert rows, "the table names no languages"
for r in rows:
    assert len(r) == 4, "not four fields: %r" % (r,)
    assert not any(c in r[2] for c in "_@"), "the label %r looks like a locale code" % r[2]
    assert ".UTF-8" not in r[2], "the label %r contains a charset" % r[2]
seen = {}
for kind, i in (("id", 0), ("locale", 1), ("label", 2), ("english", 3)):
    vals = [r[i] for r in rows]
    dup = {v for v in vals if vals.count(v) > 1}
    assert not dup, "duplicate %s: %s" % (kind, ", ".join(sorted(dup)))
assert any(r[0] == "en" for r in rows), "en is the fallback both Qt and imageidentity use"
' "$REPO_ROOT/config/languages.conf"

# The translations, through the same checker stage 40 runs — one implementation, two callers, so
# the build and the test cannot disagree about what a valid .ts file is. The failure it catches has
# no runtime symptom at all: a <source> that does not match the code byte for byte is a string Qt
# never looks up, which renders in English on one screen in one language.
assert_true "the branding translations match the table and the module sources" \
    python3 "$REPO_ROOT/scripts/lib/check-translations.py" \
        --table "$REPO_ROOT/config/languages.conf" \
        --lang-dir "$REPO_ROOT/config/calamares/branding/installer/lang" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-language/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-greeting/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-accounts/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-disk/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-apps/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-keymap/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-review/files" \
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-done/files"

# ...AND THE LIST OF SOURCE DIRECTORIES IS THE SAME LIST STAGE 40 PASSES. Two callers, one
# implementation — but two argument lists, and a module missing from one of them is a module whose
# strings are checked at build time and not here, or here and not at build time. Neither half
# fails; the catalogue simply stops being checked for a page, which is how a whole context goes
# stale unnoticed.
assert_true "every module this stage 40 translates is checked here too" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys
here = pathlib.Path('$REPO_ROOT/tests/test-installer.sh').read_text()
stage = pathlib.Path('$REPO_ROOT/scripts/stages/40-configure.sh').read_text()
pat = re.compile(r'--source-dir \"[^\"]*distro-calamares-([a-z]+)/files\"')
mine = sorted(set(pat.findall(here)))
theirs = sorted(set(pat.findall(stage)))
assert mine == theirs, 'test checks %s; stage 40 checks %s' % (mine, theirs)
assert mine, 'neither names any module at all'
EOF"

# THE THREE PSEUDO-CONTEXTS (plan/27 §2-§4): contexts whose sources no lupdate run can see —
# LanguageNames out of languages.conf, AppsDescriptions out of apps.conf, CalamaresSidebar out of
# the branding sidebar — are exempt from the source-matching checks and are un-vanished again
# after every lupdate run, or lrelease would drop them and the picker's second line (and now the
# app descriptions and the sidebar's buttons) would silently fall back to English.
assert_true "check-translations names the three pseudo-contexts" \
    grep -q '"LanguageNames", "AppsDescriptions", "CalamaresSidebar"' \
        "$REPO_ROOT/scripts/lib/check-translations.py"
assert_true "update-translations un-vanishes what lupdate cannot see" \
    grep -q 'PSEUDO = ("LanguageNames", "AppsDescriptions", "CalamaresSidebar")' \
        "$REPO_ROOT/scripts/update-translations.sh"

# ---- 6c. the language page's source (plan/22) ----------------------------------------------
LANG_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-language/files"
QML="$LANG_SRC/qml/Language.qml"

# THE SELECTION CROSSES THE QML/C++ BOUNDARY, AND BOTH DIRECTIONS ARE LOAD-BEARING. Both of the
# page's selection bugs were one property handled in one direction, and both of them COMPILE, RUN
# and look like a working page:
#
#   - the highlight is the VIEW's isCurrentItem, so it follows the VIEW's currentIndex. A delegate
#     whose tap handler wrote straight to `language.currentIndex` changed the language — the window
#     really did retranslate — and left the highlight where the keyboard had put it. The first row
#     therefore looked selected no matter which one you clicked.
#   - QQuickItemView::componentComplete() selects row 0 for itself unless currentIndex was
#     explicitly cleared, and `onCurrentIndexChanged` then pushed that 0 into C++ — throwing away
#     the English that setConfigurationMap() had chosen. The installer opened in German, because
#     German is what config/languages.conf lists first.
#
# THE VIEW IS A GridView SINCE plan/28 and was a ListView before it, which is why these match on
# the mechanism rather than on a type name: two columns is a design decision and the bugs above
# are not. What may NOT change is that it stays a view at all — QQuickItemView is where
# currentIndex, the 2-D arrow keys and Home/End come from, on a page some of whose users cannot
# read the labels on anything else. A Repeater in a GridLayout draws the same picture and has
# none of it, so that substitution is the one this asserts against.
assert_true "the languages are drawn by a view, not a Repeater — arrow keys depend on it" \
    grep -qE '^\s*(Grid|List)View \{$' "$QML"
assert_true "a tap moves the VIEW's currentIndex, which is what draws the highlight" \
    grep -qE '^\s*onTapped: grid\.currentIndex = cell\.index$' "$QML"
assert_false "no delegate writes the C++ index directly — that is the bug that froze the highlight" \
    grep -qE '(onTapped|onClicked):.*language\.currentIndex' "$QML"
assert_true "the view clears its currentIndex so componentComplete() cannot select row 0" \
    grep -qE '^\s*currentIndex: -1$' "$QML"
assert_true "the view is seeded from C++ once the component is complete" \
    grep -qE '^\s*Component\.onCompleted: grid\.currentIndex = language\.currentIndex$' "$QML"
assert_true "a view-driven change is pushed back to C++" \
    grep -qE '^\s*onCurrentIndexChanged: language\.currentIndex = grid\.currentIndex$' "$QML"
assert_true "and C++ can drive the view back, for the indexes setCurrentIndex() refuses" \
    bash -c "sed -n '/Connections {/,/^                }/p' '$QML' |
             grep -q 'grid.currentIndex = language.currentIndex'"
# The C++ half of the default. bestIndexFor() answers -1 on the C locale this medium boots with, so
# `en` is what the page must fall back to — never row 0, which is whatever the table lists first.
assert_true "English is the fallback, not the first row of the table" \
    grep -q 'indexOfId( QStringLiteral( "en" ) )' "$LANG_SRC/LanguageConfig.cpp"

# ONE SCREEN, ONE QUESTION (plan/23). The greeting was this module's second screen, reached through
# isAtBeginning()/isAtEnd(); a step that still reported a screen there would move the window's Back
# and Next inside itself and never reach the module that now owns the greeting.
assert_false "the language step no longer reports a screen from isAtBeginning()/isAtEnd()" \
    grep -qE 'onLanguages\(\)|onWelcome\(\)|goToWelcome\(\)' "$LANG_SRC/LanguageViewStep.cpp"
assert_false "and it no longer contributes requirements — those moved with the page" \
    grep -q 'checkRequirements' "$LANG_SRC/LanguageViewStep.cpp"
assert_false "no Requirements source is left behind in the language module" \
    bash -c "ls '$LANG_SRC'/Requirements.* >/dev/null 2>&1"

# EVERY `language.<name>` IN THE QML RESOLVES TO SOMETHING C++ DECLARES. A typo'd binding in QML is
# not an error and not a warning: the expression evaluates to undefined and the control renders
# empty or invisible, so this is the check that turns a silent blank into a failed build.
assert_true "every QML binding resolves to a LanguageConfig property or method" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
qml = (d / "qml" / "Language.qml").read_text(encoding="utf-8")
hdr = (d / "LanguageConfig.h").read_text(encoding="utf-8")
used = sorted(set(re.findall(r"\blanguage\.([A-Za-z_][A-Za-z0-9_]*)", qml)))
assert used, "the QML binds to nothing at all — is the context property still called language?"
known = set(re.findall(r"Q_PROPERTY\(\s*\S+\s+(\w+)\s+READ", hdr))
known |= set(re.findall(r"\b(\w+)\s*\([^)]*\)\s*(?:const)?\s*;", hdr))
missing = [u for u in used if u not in known]
assert not missing, "QML binds to %s, which LanguageConfig does not declare" % ", ".join(missing)
' "$LANG_SRC"
# ...and every property either is CONSTANT or notifies a signal that something actually emits. A
# NOTIFY naming a signal nobody emits is a binding that is evaluated once and then never again —
# the page simply stops updating, which is indistinguishable from "the value did not change".
assert_true "every Q_PROPERTY is CONSTANT or notifies an emitted signal" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
hdr = (d / "LanguageConfig.h").read_text(encoding="utf-8")
cpp = (d / "LanguageConfig.cpp").read_text(encoding="utf-8")
bad = []
for decl in re.findall(r"Q_PROPERTY\((.*?)\)", hdr, re.S):
    flat = " ".join(decl.split()); name = flat.split()[1]
    if "CONSTANT" in flat:
        continue
    m = re.search(r"NOTIFY\s+(\w+)", flat)
    if not m:
        bad.append("%s is neither CONSTANT nor NOTIFY" % name)
    elif not re.search(r"void\s+%s\s*\(" % m.group(1), hdr):
        bad.append("%s notifies %s, which is not declared" % (name, m.group(1)))
    elif not re.search(r"emit\s+%s\s*\(" % m.group(1), cpp):
        bad.append("%s notifies %s, which nothing emits" % (name, m.group(1)))
assert not bad, "; ".join(bad)
' "$LANG_SRC"
# The engine retranslate, which is the line whose absence leaves every qsTr() in the language the
# installer started in. Slideshow.cpp:57 is the only other place in the tree that needs it.
assert_true "the view step retranslates its QML engine on a language change" \
    grep -q 'engine()->retranslate()' "$LANG_SRC/LanguageViewStep.cpp"
# AND THE WINDOW'S SIDEBAR, WHICH IS A PANEL NO MODULE OWNS (plan/27 §3). CalamaresWindow builds
# calamares-sidebar.qml into a QQuickWidget and retranslates it from nowhere, so both of the
# sidebar's caches go stale on a language change: the qsTranslate() bindings that say About and
# Debug (a translation binding re-evaluates only on an engine retranslate) and the step names,
# which are `text: display` on the ViewManager model and re-read only on dataChanged — a signal
# upstream emits nowhere, because the widget flavour re-reads prettyName() on every repaint. This
# module does both, being the one that changes the language.
assert_true "...and the window's own QML panels with it" \
    grep -q 'retranslateWindowPanels()' "$LANG_SRC/LanguageViewStep.cpp"
assert_true "...finding the sidebar by the file the window loaded it from" \
    grep -q '"calamares-sidebar.qml"' "$LANG_SRC/LanguageViewStep.cpp"
assert_true "...and nudging the step names, which are a model read rather than a binding" \
    bash -c "sed -n '/^retranslateWindowPanels/,/^}/p' '$LANG_SRC/LanguageViewStep.cpp' |
             grep -q 'dataChanged'"
# And the style call stays in the FIRST module, which is this one.
assert_true "the language module sets the Qt Quick Controls style" \
    grep -q 'QQuickStyle::setStyle' "$LANG_SRC/LanguageViewStep.cpp"

# ---- 6d. the greeting page's source (plan/23) ------------------------------------------------
GREET_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-greeting/files"

# INHERITING UPSTREAM'S ESCAPE HATCH WOULD RE-OPEN THE HOLE IN SILENCE. GeneralRequirements guards
# its storage check with `#ifdef WITHOUT_LIBPARTED` and, when that is defined, removes the entry
# from both lists rather than failing. Our checker measures /sys/block instead and must never grow
# the same conditional — a build with it would pass every assertion above and still never check a
# disk (plan/22 §3a).
#
# The PREPROCESSOR use, not the token: Requirements.h quotes upstream's #ifdef at length, because
# an escape hatch you cannot find is how this stayed broken. What must never appear is a
# conditional that compiles the check out.
assert_false "the requirement checker carries no WITHOUT_LIBPARTED escape hatch" \
    grep -rqE '^[[:space:]]*#[[:space:]]*(if|ifdef|ifndef|elif).*LIBPARTED' "$GREET_SRC"
assert_true "the requirement checker reads /sys/block itself" \
    grep -q '/sys/block' "$GREET_SRC/Requirements.cpp"
assert_true "the greeting module is the one that contributes the checks" \
    grep -q 'm_requirements->checkRequirements()' "$GREET_SRC/GreetingViewStep.cpp"

# Next is the installer's first real gate, and it gates on the MANDATORY list only — `internet` is
# checked and deliberately not required, because the payload travels on the stick.
assert_true "Next is gated on the mandatory requirements" \
    bash -c "sed -n '/^GreetingViewStep::isNextEnabled/,/^}/p' '$GREET_SRC/GreetingViewStep.cpp' |
             grep -q 'satisfiedMandatory()'"
assert_true "and the verdict moving re-asks the button, or a bigger disk clears nothing" \
    grep -q 'satisfiedMandatoryChanged' "$GREET_SRC/GreetingViewStep.cpp"
# isBackEnabled(), which stock WelcomeViewStep answers false because it has nowhere to go. This
# page has the language list behind it, and copying upstream's answer strands anyone who picked the
# wrong language on a page they cannot read.
assert_true "isBackEnabled() returns true, not stock welcome's false" \
    bash -c "sed -n '/^GreetingViewStep::isBackEnabled/,/^}/p' '$GREET_SRC/GreetingViewStep.cpp' |
             grep -q 'return true;'"
# The style call belongs to whichever module loads FIRST and is ignored everywhere else. A second
# one here would look harmless and be dead. `^[^/*]*` so that the comment in GreetingViewStep.cpp
# explaining the absence does not read as the thing it is explaining.
assert_false "the greeting module does not set the Qt Quick Controls style" \
    grep -rqE '^[^/*]*QQuickStyle::setStyle' "$GREET_SRC"

# THE VENDORING IS OVER (plan/28). checker/ was three files copied from Calamares' welcome module,
# on the argument that "they are not in libcalamaresui and no header of theirs is installed, so a
# module that wants the box has to carry the source" (plan/23 §2). What was never true of the
# MODEL — libcalamares/modulesystem/RequirementsModel.h IS installed — is what made the copies
# unnecessary the moment the page became QML: a ListView binds the model directly.
#
# These assert the deletion rather than the copies, because a re-appearing checker/ would mean
# somebody reintroduced the failures-only box the design replaced, and because a vendored tree
# that nothing builds is the worst of both.
assert_false "the vendored requirements box is gone, not merely unused" \
    test -e "$GREET_SRC/checker"
assert_false "...and so is the QWidget page that hosted it" \
    bash -c "test -e '$GREET_SRC/GreetingPage.cpp' || test -e '$GREET_SRC/GreetingPage.h'"
# Comment lines excluded: the note explaining why the include_directories() line went necessarily
# names the directory it went with.
assert_false "...and the CMakeLists builds neither" \
    bash -c "grep -vE '^[[:space:]]*#' '$GREET_SRC/CMakeLists.txt' |
             grep -qE 'checker/|GreetingPage\.cpp'"

# THE PAGE IS QML IN A QQuickWidget, like its four siblings, and it binds Calamares' own model.
assert_true "the greeting page is QML hosted in a QQuickWidget" \
    bash -c "grep -q 'new QQuickWidget()' '$GREET_SRC/GreetingViewStep.cpp' &&
             grep -q 'qrc:/greeting/qml/Greeting.qml' '$GREET_SRC/GreetingViewStep.cpp'"
assert_true "...with GreetingConfig as its context property" \
    grep -q 'setContextProperty( QStringLiteral( "greeting" ), m_config )' "$GREET_SRC/GreetingViewStep.cpp"
assert_true "...and the engine retranslated on a language change" \
    grep -q 'engine()->retranslate()' "$GREET_SRC/GreetingViewStep.cpp"
assert_true "the page binds Calamares' requirements model directly" \
    bash -c "grep -q 'Q_PROPERTY( QAbstractItemModel\* requirements' '$GREET_SRC/GreetingConfig.h' &&
             grep -q 'model: greeting.problems' '$GREET_SRC/qml/Greeting.qml'"

# FAILURES AND WARNINGS ONLY, AND NO PANEL WHEN THERE ARE NONE (plan/30 §2). This reverses
# plan/28, whose assertion here was that no proxy filtered the list; the machine this installer
# normally runs on passes everything, and six green rows saying OK above the one sentence anybody
# reads is a panel that is never read. What the vendored box got wrong was not the filtering —
# it was showing an EMPTY bordered box, which is indistinguishable from one still checking.
assert_true "the panel lists only what is wrong" \
    bash -c "grep -q 'class UnsatisfiedRequirements : public QSortFilterProxyModel' '$GREET_SRC/GreetingConfig.h' &&
             grep -q 'Q_PROPERTY( QAbstractItemModel\* problems' '$GREET_SRC/GreetingConfig.h'"
# The role, not a filterFixedString against whatever QVariant(bool) renders as.
assert_true "...filtered on the model's own Satisfied role" \
    grep -q 'RequirementsModel::Satisfied' "$GREET_SRC/GreetingConfig.cpp"
assert_false "...and not on a stringified bool" \
    grep -qE 'setFilterFixedString|setFilterRole' "$GREET_SRC/GreetingConfig.cpp"
# The panel goes away entirely, which is the half the vendored box never did.
assert_true "the panel is absent on a machine with nothing wrong" \
    grep -q 'visible: !greeting.checked || greeting.hasProblems' "$GREET_SRC/qml/Greeting.qml"
# ...but NOT before the first round has landed: "nothing is wrong" is not yet true then, and that
# state already has a drawing — the spinner.
assert_true "...but stays for the spinner while the first round runs" \
    grep -q 'visible: !greeting.checked$' "$GREET_SRC/qml/Greeting.qml"
# hasProblems is the proxy's row count and NOT !satisfiedMandatory: a warning is not a blocker,
# and the internet check is deliberately optional, so a machine with no network has a panel to
# show and a verdict that still says it can install.
assert_true "...on the count of problems, not on the mandatory verdict" \
    grep -q 'return m_problems->rowCount() > 0;' "$GREET_SRC/GreetingConfig.cpp"
# A re-check that clears the last failure must COLLAPSE the panel, not empty it.
assert_true "...and the panel collapses when a re-check clears the last failure" \
    bash -c "grep -q 'connect( m_problems, &QAbstractItemModel::modelReset' '$GREET_SRC/GreetingConfig.cpp' &&
             grep -q 'void problemsChanged();' '$GREET_SRC/GreetingConfig.h'"
# When the panel goes, the verdict moves up into its place — which a ColumnLayout does for free
# with a child whose `visible` is false. What does NOT come for free is the spare height: without
# a filler the verdict would be stretched to the foot of the page.
assert_true "the verdict moves up into the space the panel had" \
    bash -c "tr '\n' ' ' < '$GREET_SRC/qml/Greeting.qml' |
             grep -qE 'Item \{ *Layout.fillHeight: true *\} *\} *\}'"
assert_true "a row says whether its check blocks the install or merely reports" \
    bash -c "grep -q 'required property bool mandatory' '$GREET_SRC/qml/Greeting.qml' &&
             grep -q 'greeting.requiredLabel' '$GREET_SRC/qml/Greeting.qml' &&
             grep -q 'greeting.optionalLabel' '$GREET_SRC/qml/Greeting.qml'"

# THE "NOT YET" STATE IS DRAWN, and it is not the same as "nothing is wrong". `satisfiedMandatory`
# is false before anything has been measured, so a page that rendered that verdict straight away
# would say "this computer cannot install" for the second the first scan takes.
assert_true "the page waits for the first round of checks before reporting a verdict" \
    bash -c "grep -q 'Q_PROPERTY( bool checked' '$GREET_SRC/GreetingConfig.h' &&
             grep -q 'visible: !greeting.checked' '$GREET_SRC/qml/Greeting.qml'"
# ...and `checked` is driven by modelReset, not by the verdict signals. Neither of those fires
# when a second round agrees with the first, so a machine that passed everything immediately would
# sit on its spinner for ever.
assert_true "...driven by the model reset, which fires on every round" \
    bash -c "sed -n '/GreetingConfig::GreetingConfig/,/^}/p' '$GREET_SRC/GreetingConfig.cpp' |
             grep -q 'QAbstractItemModel::modelReset'"

# NO SECOND LOGO. The branding's productWelcome image is the sidebar's, and a logo in this page's
# header would be the "logo sized to fill whatever space is left over" that plan/22 opened by
# complaining about.
assert_false "the greeting page draws no logo of its own" \
    grep -rqE 'ProductLogo|ProductWelcome|imagePath' "$GREET_SRC"

# ---- 6e. the disk page's source, and the job it hands the disk to (plan/24) ------------------
DISK_JOB="$CAL/local-modules/disksetup/main.py"
DISK_QML="$DISK_SRC/qml/Disk.qml"

# THE ONE ASSERTION IN THIS FILE THAT IS ABOUT SOMEBODY'S DATA.
#
# Until plan/24 the installation medium was kept out of the disk picker by code we did not write:
# PartUtils::getDevices( WritableOnly ) drops any device holding a partition mounted at "/"
# (core/DeviceList.cpp:178), and the stock partition module never showed it. We do not run that
# code any more. The rule is ours now, in three places, and every one of them has to stay:
#
#   the page   so the medium cannot be selected
#   the job    so a stale or forged GlobalStorage value cannot be acted on
#   the greeting page's checker, which already had its own copy, so "is there a disk big enough"
#              and "which disks may I use" cannot answer differently
#
# The test is the CONTAINMENT rule rather than the words: /sys/block/<disk>/<partition> exists iff
# that partition belongs to that disk, which is what makes nvme0n1p3 resolve to nvme0n1 without
# any rule about trailing digits. A rewrite that went back to string surgery would pass a grep for
# "live" and fail on NVMe.
assert_true "the disk page excludes the disk the installer is running from" \
    bash -c "sed -n '/^liveMediumDisk()/,/^}/p' '$DISK_SRC/DiskConfig.cpp' | grep -q '/sys/block/%1/%2'"
assert_true "...by containment, not by chopping digits off a partition name" \
    grep -q 'QStorageInfo::root().device()' "$DISK_SRC/DiskConfig.cpp"
assert_true "the job re-checks it before writing anything" \
    bash -c "grep -q 'def disk_of' '$DISK_JOB' && grep -q 'os.path.exists(\"/sys/block/{}/{}\"' '$DISK_JOB'"
assert_true "...and refuses the medium by name" \
    bash -c "sed -n '/^def check_target/,/^def /p' '$DISK_JOB' | grep -q 'is the disk this installer is running from'"
assert_true "...and refuses a target the page never confirmed" \
    bash -c "sed -n '/^def check_target/,/^def /p' '$DISK_JOB' | grep -q 'diskConfirmed'"
assert_true "...and refuses anything that is not a whole disk" \
    bash -c "sed -n '/^def check_target/,/^def /p' '$DISK_JOB' | grep -q 'is not a whole disk'"
# The greeting page's copy of the same rule, which predates this page and must not be quietly
# dropped now that a second one exists.
assert_true "the greeting page's checker still excludes the medium too" \
    bash -c "sed -n '/^Requirements::largestInstallableDiskB/,/^}/p' '$GREET_SRC/Requirements.cpp' |
             grep -q '/sys/block/%1/%2'"

# A desktop session automounts what it finds, so the target's partitions may well be mounted when
# the user reaches this page. sfdisk will rewrite the table underneath them and the kernel will
# then refuse to re-read it — an install that appears to work and writes the payload to the old
# offsets.
assert_true "the job releases mounts and swap on the target before touching it" \
    bash -c "grep -q 'def release_disk' '$DISK_JOB' && grep -q 'swapoff' '$DISK_JOB' && grep -q 'umount' '$DISK_JOB'"
assert_true "...and stops rather than continuing when it cannot" \
    bash -c "sed -n '/^def release_disk/,/^def /p' '$DISK_JOB' | grep -q 'could not be unmounted'"
# wipefs before sfdisk: sfdisk writes a GPT and does not remove a stale MBR or a filesystem
# superblock sitting where the new ESP will be, and blkid would go on reporting the old one.
assert_true "old signatures are wiped before the new table is written" \
    bash -c "sed -n '/^def write_table/,/^def /p' '$DISK_JOB' | grep -q 'wipefs'"
assert_true "and the job waits for udev before it makes a filesystem" \
    bash -c "grep -q 'def settle_for' '$DISK_JOB' && grep -q 'settle_for(\[esp' '$DISK_JOB'"

# THE ROOT SLOTS ARE NOT FORMATTED. What goes in slot A is an EROFS image written byte-for-byte by
# imagedeploy; a mkfs here would be a filesystem overwritten one step later, and slot B ships as
# zeros for systemd-sysupdate to claim.
# QUOTED, not just the bare word: the job's prose — in `#` comments and in docstrings, which a
# `#`-only strip does not touch — explains in words which labels stage 60 gives the factory
# image's filesystems and which of the two paths calls make_esp() (plan/33 §6), and mentions
# both tool names doing it. Only actual Python string-literal arguments are quoted like this.
assert_eq "1" "$(grep -c '"mkfs\.ext4"' "$DISK_JOB")" \
    "the job makes exactly one ext4 filesystem"
assert_eq "1" "$(grep -c '"mkfs\.vfat"' "$DISK_JOB")" \
    "...and exactly one FAT32 one"
assert_false "neither root slot is formatted" \
    bash -c "grep -E 'mkfs' '$DISK_JOB' | grep -q 'root_a\|root_b'"
# The two filesystem labels the factory image carries. Nothing reads them — fstab finds both
# partitions by PARTLABEL — but "indistinguishable from an image dd'd to the disk" is the property
# this installer is built around, and lsblk shows a label to anyone comparing the two.
assert_true "the installer's var label matches the factory image's" \
    bash -c "grep -q 'mkfs.ext4 -q -F -L var' '$REPO_ROOT/scripts/stages/60-image.sh' &&
             grep -qE '^varLabel:[[:space:]]+\"var\"' '$DISKSETUP_CONF'"
assert_true "...and so does the ESP's" \
    bash -c "grep -q 'mkfs.vfat -F32 -n ESP' '$REPO_ROOT/scripts/stages/60-image.sh' &&
             grep -qE '^espLabel:[[:space:]]+\"ESP\"' '$DISKSETUP_CONF'"

# THE CONTRACT WITH THE REST OF THE SEQUENCE. imagedeploy finds the root slot by `partlabel` and
# the other two by `mountPoint`; imagebootloader finds /efi the same way. Both were written against
# what KPMcore used to publish, and the test of an honest replacement is that neither needed a line
# changed — so the keys they read are asserted here, on the module that now writes them.
assert_true "the job publishes the partitions list the rest of the sequence reads" \
    bash -c "grep -q 'globalstorage.insert(\"partitions\"' '$DISK_JOB'"
for k in partlabel mountPoint device; do
    assert_true "...with a '$k' on every entry" \
        bash -c "sed -n '/partitions = \[/,/\]/p' '$DISK_JOB' | grep -q '\"$k\"'"
done
assert_true "...naming /efi and /var, which is how the next two modules find them" \
    bash -c "sed -n '/partitions = \[/,/\]/p' '$DISK_JOB' | grep -q '\"/efi\"' &&
             sed -n '/partitions = \[/,/\]/p' '$DISK_JOB' | grep -q '\"/var\"'"

# ---- the page ------------------------------------------------------------------------------
# THE CONFIRMATION IS ASKED AT THE BUTTON, not in front of it (plan/26 §1). Next lights for a
# disk alone; a press that has not been answered opens the erase dialog instead of leaving —
# which is the accounts pager's mechanism worn as a dialog: ViewManager::next() calls the step's
# next() while isAtEnd() is false, and isAtEnd() is the confirmation state.
assert_true "Next is enabled by a selected disk alone" \
    bash -c "sed -n '/^DiskConfig::nextEnabled() const/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'isInstallable( m_currentIndex )'"
assert_false "...and the confirmation no longer darkens the button" \
    bash -c "sed -n '/^DiskConfig::nextEnabled() const/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'm_confirmed'"
assert_true "isAtEnd() is the confirmation, so the window's Next opens the prompt instead of leaving" \
    bash -c "sed -n '/^DiskViewStep::isAtEnd/,/^}/p' '$DISK_SRC/DiskViewStep.cpp' |
             grep -q 'return m_config->confirmed();'"
assert_true "the step's next() is what asks" \
    bash -c "sed -n '/^DiskViewStep::next()$/,/^}/p' '$DISK_SRC/DiskViewStep.cpp' |
             grep -q 'requestConfirmation()'"
assert_true "...and accepting completes the advance the press asked for" \
    grep -q 'ViewManager::instance()->next()' "$DISK_SRC/DiskViewStep.cpp"
# ...and the question is asked on EVERY press: leaving the page withdraws the answer, so a
# Back-and-return cannot turn the next Next into a silent one.
assert_true "onLeave() re-arms the question" \
    bash -c "sed -n '/^DiskViewStep::onLeave/,/^}/p' '$DISK_SRC/DiskViewStep.cpp' |
             grep -q 'setConfirmed( false )'"
# The job's contract is unchanged: publish() says "installable AND confirmed" explicitly, because
# nextEnabled() — which it used to call — now answers a different question.
assert_true "publish() keeps diskConfirmed meaning the agreed erase" \
    bash -c "sed -n '/^DiskConfig::publish/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'isInstallable( m_currentIndex ) && m_confirmed'"
# ...and the disk-change clear stays, belt and braces beside the onLeave clear.
assert_true "changing the disk clears the confirmation" \
    bash -c "sed -n '/^DiskConfig::setCurrentIndex/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'setConfirmed( false )'"
# The QML half: the dialog that answers, and no checkbox left on the panel.
assert_true "the QML carries the confirmation dialog" \
    bash -c "grep -q 'Kirigami.PromptDialog' '$DISK_QML' && grep -q 'disk.acceptConfirmation()' '$DISK_QML'"
assert_false "...and the checkbox it replaced is gone" \
    grep -q 'Erase this disk and everything on it' "$DISK_QML"
# A blocked row can never become the selection, whichever way it is reached — mouse, arrow key or
# a stale index from C++.
assert_true "a disk that cannot be installed to is refused as a selection" \
    bash -c "sed -n '/^DiskConfig::setCurrentIndex/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'isInstallable( index )'"

# The selection crosses the QML/C++ boundary in both directions, and both are load-bearing — the
# language page paid for these three lines with an installer that opened in the wrong language
# (plan/22 §9). Here the same mistakes would pre-select somebody's disk, or draw one disk as chosen
# while installing onto another.
assert_true "a click moves the VIEW's currentIndex, which is what draws the highlight" \
    grep -qE '^\s*onClicked: list\.currentIndex = row\.index$' "$DISK_QML"
assert_false "no delegate writes the C++ index directly" \
    grep -qE 'onClicked:.*disk\.currentIndex' "$DISK_QML"
assert_true "the ListView clears its currentIndex so componentComplete() cannot select row 0" \
    grep -qE '^\s*currentIndex: -1$' "$DISK_QML"
assert_true "the view is seeded from C++ once the component is complete" \
    grep -qE '^\s*Component\.onCompleted: list\.currentIndex = disk\.currentIndex$' "$DISK_QML"
assert_true "a view-driven change is pushed back to C++" \
    grep -qE '^\s*onCurrentIndexChanged: disk\.currentIndex = list\.currentIndex$' "$DISK_QML"
assert_true "and C++ can drive the view back, for the rows setCurrentIndex() refuses" \
    bash -c "sed -n '/Connections {/,/^                }/p' '$DISK_QML' |
             grep -q 'list.currentIndex = disk.currentIndex'"

# Greyed, not hidden (plan/24, Q3): the medium's own disk stays in the list, saying why.
assert_true "disks that cannot be used are listed and disabled, not filtered out" \
    grep -qE '^\s*enabled: !row\.blocked$' "$DISK_QML"
# The encryption control is drawn and disabled. Hiding it would mean the first person to ask about
# encryption has to ask whether it was forgotten (plan/24 §7).
assert_true "the encryption control exists, disabled, with a reason" \
    bash -c "grep -q 'Encrypt this disk' '$DISK_SRC/DiskConfig.h' &&
             grep -q 'Not yet available' '$DISK_SRC/DiskConfig.h'"
assert_true "...and nothing in this module can turn it on" \
    bash -c "grep -q 'bool encryptionAvailable() const { return false; }' '$DISK_SRC/DiskConfig.h'"
assert_false "...and no encryption is implemented behind it" \
    grep -rqi 'cryptsetup\|luksFormat' "$DISK_SRC" "$DISK_JOB"

# The style call belongs to whichever module loads FIRST — the language page — and is silently
# ignored everywhere else. `^[^/*]*` so the comment here explaining its absence is not read as the
# thing it explains.
assert_false "the disk module does not set the Qt Quick Controls style" \
    grep -rqE '^[^/*]*QQuickStyle::setStyle' "$DISK_SRC"
# ...and the QML engine is retranslated, or every string bound from a C++ property stays in the
# language the installer started in.
assert_true "the view step retranslates its QML engine on a language change" \
    grep -q 'engine()->retranslate()' "$DISK_SRC/DiskViewStep.cpp"
# THE DISK PAGE'S WORDS ARE C++ PROPERTIES TOO (plan/27 §1) — the same treatment the applications
# page established: no qsTr() call is left in the QML, the erase dialog asks its question in
# catalogue words, and its subtitle is composed whole in C++ so the two sentences the page says
# cannot diverge from the dialog's copy of them in a second language.
assert_false "no qsTr() call is left in the disk QML" \
    grep -q 'qsTr("' "$DISK_QML"
assert_true "the erase dialog's words live on DiskConfig, where lupdate can see them" \
    grep -q 'tr( "Erase this disk?" )' "$DISK_SRC/DiskConfig.cpp"
assert_true "...and its subtitle is composed whole in C++, selection and language both" \
    grep -q 'DiskConfig::confirmSubtitle' "$DISK_SRC/DiskConfig.cpp"
# confirmTitle/confirmAcceptLabel moved out of line for the same reason confirmSubtitle already
# was: they now say something different while keeping (plan/33 §5, §9), so the header only
# declares them and DiskConfig.cpp is where both branches of each live.
assert_true "confirmTitle branches on keeping" \
    bash -c "sed -n '/^DiskConfig::confirmTitle/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'tr( \"Reinstall on this disk?\" )'"
assert_true "confirmAcceptLabel branches on keeping" \
    bash -c "sed -n '/^DiskConfig::confirmAcceptLabel/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'tr( \"Reinstall\" )'"

# A Qt context IS a class name, and check-translations.py check 5 resolves one to the file whose
# stem matches. DiskModel says its own strings, so it has to be its own file or every one of them
# would silently stay English the first time this page is translated (plan/23 §3).
assert_file "$DISK_SRC/DiskModel.cpp" "DiskModel is a file of its own, because it calls tr()"
assert_true "...and DiskConfig.cpp declares no DiskModel methods" \
    bash -c "! grep -qE '^DiskModel::' '$DISK_SRC/DiskConfig.cpp'"

# THE NAME ON A ROW IS A NAME, NOT AN IDENTIFIER. The kernel-side strings are `vendor` + `model`,
# and what each bus puts in them differs: NVMe has the whole name in `model`; USB splits it
# usefully ("SanDisk" + "Ultra"); SATA reports "ATA" — the bus, not the maker — while the model
# already begins with the maker; and virtio offers a PCI vendor ID ("0x1af4") with no model at
# all, which is how every disk in a QEMU guest was once titled "0x1af4" where a name belongs.
# The vendor is kept only when it is a maker's name, and a disk with no model is named for its
# bus — by DiskModel, at read time, so a language change can say it again — rather than by the
# device node, which the row already shows small next to the title.
assert_true "a hex vendor ID is never the name on the row" \
    bash -c "grep -q 'startsWith( QLatin1String( \"0x\" ) )' '$DISK_SRC/DiskConfig.cpp'"
assert_true "...nor is the SATA bus string, which is not a maker" \
    bash -c "grep -q 'vendor != QLatin1String( \"ATA\" )' '$DISK_SRC/DiskConfig.cpp'"
assert_true "...nor a vendor the model already begins with" \
    bash -c "grep -q 'model.startsWith( vendor )' '$DISK_SRC/DiskConfig.cpp'"
assert_false "a disk with no model is not named by its device node" \
    grep -q 'e\.title = e\.node' "$DISK_SRC/DiskConfig.cpp"
assert_true "...it is named for its bus, in DiskModel, where a retranslate says it again" \
    bash -c "grep -q 'tr( \"VirtIO disk\" )' '$DISK_SRC/DiskModel.cpp' &&
             grep -q 'tr( \"NVMe disk\" )' '$DISK_SRC/DiskModel.cpp' &&
             grep -q 'tr( \"Disk\" )' '$DISK_SRC/DiskModel.cpp'"
assert_true "the row reads the title through the one composer" \
    bash -c "sed -n '/^DiskModel::data/,/^}/p' '$DISK_SRC/DiskModel.cpp' | grep -q 'return rowTitle( e );'"
assert_true "...and a language change re-says it, so the generic name is not scan-time English" \
    bash -c "sed -n '/^DiskModel::retranslated/,/^}/p' '$DISK_SRC/DiskModel.cpp' | grep -q 'TitleRole'"
assert_true "the summary names the disk with the same composer the row used" \
    bash -c "grep -q 'DiskModel::rowTitle( e )' '$DISK_SRC/DiskConfig.cpp'"

# EVERY `disk.<name>` IN THE QML RESOLVES TO SOMETHING C++ DECLARES. A typo'd binding in QML is not
# an error and not a warning: the expression is undefined and the control renders empty, so this is
# what turns a silent blank into a failed build.
assert_true "every QML binding resolves to a DiskConfig property or method" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
qml = (d / "qml" / "Disk.qml").read_text(encoding="utf-8")
hdr = (d / "DiskConfig.h").read_text(encoding="utf-8")
used = sorted(set(re.findall(r"\bdisk\.([A-Za-z_][A-Za-z0-9_]*)", qml)))
assert used, "the QML binds to nothing at all - is the context property still called disk?"
known = set(re.findall(r"Q_PROPERTY\(\s*\S+\s+(\w+)\s+READ", hdr))
known |= set(re.findall(r"\b(\w+)\s*\([^)]*\)\s*(?:const)?\s*;", hdr))
missing = [u for u in used if u not in known]
assert not missing, "QML binds to %s, which DiskConfig does not declare" % ", ".join(missing)
' "$DISK_SRC"
# ...and every property either is CONSTANT or notifies a signal something actually emits. A NOTIFY
# naming a signal nobody emits is a binding evaluated once and then never again — the page simply
# stops updating, which looks exactly like "the value did not change".
assert_true "every Q_PROPERTY is CONSTANT or notifies an emitted signal" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
hdr = (d / "DiskConfig.h").read_text(encoding="utf-8")
cpp = (d / "DiskConfig.cpp").read_text(encoding="utf-8")
bad = []
for decl in re.findall(r"Q_PROPERTY\((.*?)\)", hdr, re.S):
    flat = " ".join(decl.split()); name = flat.split()[1]
    if "CONSTANT" in flat:
        continue
    m = re.search(r"NOTIFY\s+(\w+)", flat)
    if not m:
        bad.append("%s is neither CONSTANT nor NOTIFY" % name)
    elif not re.search(r"void\s+%s\s*\(" % m.group(1), hdr):
        bad.append("%s notifies %s, which is not declared" % (name, m.group(1)))
    elif not re.search(r"emit\s+%s\s*\(" % m.group(1), cpp):
        bad.append("%s notifies %s, which nothing emits" % (name, m.group(1)))
assert not bad, "; ".join(bad)
' "$DISK_SRC"

# THE PACKAGED FALLBACK AND THE BUILD HAVE TO AGREE. files/disk.conf is what makes the module
# loadable on its own (CalamaresConfig.cmake never exports INSTALL_CONFIG, so the glob installs
# nothing without it) and the medium never reads it — /etc wins. That is exactly what lets it drift:
# nothing on the medium would ever notice a fallback that still said 20 GB, and the first person to
# load this module outside the pipeline would get a page enforcing a minimum this build abandoned.
DISK_FALLBACK="$DISK_SRC/disk.conf"
assert_file "$DISK_FALLBACK" "the packaged fallback disk.conf exists"
assert_eq "$I_MIN_INSTALL_DISK_GB" \
    "$(sed -nE 's/^minimumDiskSize:[[:space:]]+([0-9.]+).*/\1/p' "$DISK_FALLBACK")" \
    "the fallback's minimum matches build.conf"
assert_eq "$I_ESP_SIZE_MIB" \
    "$(sed -nE 's/^espSizeMiB:[[:space:]]+([0-9]+).*/\1/p' "$DISK_FALLBACK")" \
    "the fallback's ESP size matches build.conf"
assert_eq "$I_ROOT_SLOT_SIZE_MIB" \
    "$(sed -nE 's/^rootSlotSizeMiB:[[:space:]]+([0-9]+).*/\1/p' "$DISK_FALLBACK")" \
    "the fallback's root slot size matches build.conf"

# The module is `disk`, everywhere. A viewmodule called `partition` would collide file-for-file
# with app-admin/calamares' own and ModuleManager would resolve the duplicate by search order,
# silently (plan/24 §5).
assert_true "the plugin is built as 'disk'" \
    grep -qE '^calamares_add_plugin\(disk$' "$DISK_SRC/CMakeLists.txt"
assert_true "...and the sidebar says Disk" \
    bash -c "sed -n '/^DiskViewStep::prettyName/,/^}/p' '$DISK_SRC/DiskViewStep.cpp' | grep -q 'tr( \"Disk\" )'"
assert_true "...and the QML travels inside the .so rather than being installed a second time" \
    grep -q 'qt6_add_resources(${DISK_TARGET}' "$DISK_SRC/CMakeLists.txt"

# ---- 6f. the applications page, and the job that downloads its answer (plan/25) -------------
APPS_JOB="$CAL/local-modules/appsetup/main.py"
APPS_QML="$APPS_SRC/qml/Apps.qml"
APPS_CONF="$RENDER/modules/apps.conf"
APPS_JOB_CONF="$RENDER/modules/appsetup.conf"

# THE LIST IS THE OFFER, and two files carry it: modules/apps.conf is what the page draws its
# rows from and the packaged fallback is what loads the module where /etc/calamares is not.
# The two must agree app for app — the medium reads the /etc copy, so nothing would ever notice
# a fallback still offering an app a newer conf dropped. Six ids, none of them in
# config/flatpak/apps.lock: these are DOWNLOADED at install time, which is the whole difference
# between this list and FLATPAK_PREINSTALL.
APPS_EXPECTED="org.mozilla.Thunderbird org.videolan.VLC org.libreoffice.LibreOffice org.kde.krita org.kde.krdc org.kde.kate"
assert_file "$APPS_CONF" "apps.conf rendered"
# SCOPED TO THE `apps:` BLOCK, because plan/30 §5 gave the file a second list of the same shape —
# `included:`, what the image already carries — and a bare sweep for "- id:" would now conflate
# what this page OFFERS with what it merely reports.
ids_in_block() { awk -v b="$2:" '$1 == b { f = 1; next } /^[^ ]/ { f = 0 } f && $2 == "id:" { print $3 }' "$1" | tr '\n' ' ' | sed 's/ $//'; }
assert_eq "$APPS_EXPECTED" "$(ids_in_block "$APPS_CONF" apps)" \
    "apps.conf offers the six applications, in file order"
assert_eq "$APPS_EXPECTED" "$(ids_in_block "$APPS_SRC/apps.conf" apps)" \
    "...and the packaged fallback offers exactly the same six"

# ---- what the image already carries (plan/30 §5) --------------------------------------------
#
# A HAND-KEPT LIST DESCRIBING A BUILD FACT is the drift this section exists to stop: the five
# Flatpaks in `included:` are build.conf's FLATPAK_PREINSTALL and nothing derives one from the
# other, so a sixth preinstalled application would otherwise arrive on the disk with the page
# still saying eight.
APPS_INCLUDED="$(ids_in_block "$APPS_CONF" included)"
assert_true "apps.conf says what the image already carries" \
    bash -c "[[ -n '$APPS_INCLUDED' ]]"
assert_eq "$APPS_INCLUDED" "$(ids_in_block "$APPS_SRC/apps.conf" included)" \
    "...and the packaged fallback lists exactly the same ones"
for pre in $(bash -c 'source "'"$REPO_ROOT"'/config/build.conf"; echo $FLATPAK_PREINSTALL'); do
    assert_true "...including $pre, which the image preinstalls" \
        bash -c "printf '%s\n' $APPS_INCLUDED | grep -qx '$pre'"
done
# ONE-DIRECTIONAL: the natives (Dolphin, Konsole, Spectacle) are not in FLATPAK_PREINSTALL and
# never will be, so this does not assert the converse. What it DOES assert is that nothing is in
# both lists — an application the page offers to download and also claims is already there.
for id in $APPS_INCLUDED; do
    assert_false "...and $id is not also offered for download" \
        bash -c "printf '%s\n' $APPS_EXPECTED | grep -qx '$id'"
done
# Read-only on the page: these are facts, not check boxes.
assert_true "the included list is drawn as chips, not as controls" \
    bash -c "grep -q 'model: apps.included' '$APPS_SRC/qml/Apps.qml' &&
             grep -q 'Accessible.role: Accessible.StaticText' '$APPS_SRC/qml/Apps.qml'"
assert_true "...from a property that retranslates like the offered list" \
    bash -c "grep -B2 'READ included' '$APPS_SRC/AppsConfig.h' | grep -q 'NOTIFY retranslated'"

# ---- the whole page scrolls (plan/30 §5) -----------------------------------------------------
#
# The heading and the offline note were pinned while the choices scrolled in a box beneath them,
# which gave the page two scroll positions and an inner scrollbar starting partway down it.
assert_true "the applications page scrolls as one page" \
    bash -c "grep -q 'anchors.fill: parent' '$APPS_SRC/qml/Apps.qml' &&
             grep -q 'id: scroll' '$APPS_SRC/qml/Apps.qml' &&
             grep -q 'width: scroll.availableWidth' '$APPS_SRC/qml/Apps.qml'"
assert_false "...with no inner scroller left inside it" \
    bash -c "[[ \$(grep -c 'QQC2.ScrollView {' '$APPS_SRC/qml/Apps.qml') -gt 1 ]]"
# The margins are the CONTENT's — a `sheet` Item carrying them, the shape Accounts.qml uses —
# because qqc2-desktop-style's ScrollView binds the four individual padding properties and an
# assignment to the grouped `padding` on the scroller would lose to them in silence.
assert_true "...and the page's margins are the content's, not the scroller's" \
    bash -c "grep -q 'id: sheet' '$APPS_SRC/qml/Apps.qml' &&
             grep -q 'implicitHeight: column.implicitHeight + 2 \* margin' '$APPS_SRC/qml/Apps.qml'"
assert_true "apps.conf defaults to the typical set" \
    grep -qE '^defaultMode:[[:space:]]+typical$' "$APPS_CONF"

# A DESCRIPTION UNDER EVERY NAME (plan/27 §7), in both confs and agreeing — the medium reads the
# /etc copy, so a fallback still describing an app a newer conf reworded would render its stale
# sentence with nothing to notice. Six, one per id, and each a sentence the custom row shows under
# the name where the Flathub identifier used to sit.
assert_eq "$(sed -nE 's/^[[:space:]]+description:[[:space:]]+(\S.*)$/\1/p' "$APPS_CONF" | tr '\n' '|' | sed 's/|$//')" \
    "$(sed -nE 's/^[[:space:]]+description:[[:space:]]+(\S.*)$/\1/p' "$APPS_SRC/apps.conf" | tr '\n' '|' | sed 's/|$//')" \
    "the packaged fallback carries the same descriptions"
assert_true "...one per application, none missing" \
    bash -c "[[ \$(awk '\$1 == \"apps:\" { f = 1; next } /^[^ ]/ { f = 0 } f && \$1 == \"description:\"' '$APPS_CONF' | wc -l) -eq 6 ]]"
# The description is the one conf-sourced string that translates: its English text is the lookup
# key into the hand-maintained AppsDescriptions context (the LanguageNames bargain), and the list
# property gives up CONSTANT for retranslated so the re-read follows a language change.
assert_true "C++ copies the description key through to the QML" \
    grep -q 'QStringLiteral( "description" )' "$APPS_SRC/AppsConfig.cpp"
assert_true "...wrapping it in the AppsDescriptions context at read time" \
    grep -q 'translate( "AppsDescriptions"' "$APPS_SRC/AppsConfig.cpp"
assert_true "the app list notifies retranslated, so descriptions re-say" \
    bash -c "grep -B2 'READ apps' '$APPS_SRC/AppsConfig.h' | grep -q 'NOTIFY retranslated'"

# ONE ANSWER TO "IS THERE INTERNET". The job's own probe curls the same URL the greeting page's
# requirements block checks; two URLs would be two verdicts, and the offline path turns on that
# verdict (the page forces its second answer, the job skips both its passes).
assert_file "$APPS_JOB_CONF" "appsetup.conf rendered"
assert_eq "$(sed -nE 's/^[[:space:]]*internetCheckUrl:[[:space:]]+"([^"]+)".*/\1/p' "$GREETING_CONF")" \
    "$(sed -nE 's/^[[:space:]]*internetCheckUrl:[[:space:]]+"([^"]+)".*/\1/p' "$APPS_JOB_CONF")" \
    "appsetup probes the same URL the greeting checks"
# AND THAT URL IS THE CHECK KNOB, NOT HOME_URL. Both render from build.conf's INTERNET_CHECK_URL:
# HOME_URL is metadata for the product's own site, which was NXDOMAIN when this assertion was
# written, and a probe against a dead domain says "no internet" on every machine that has
# internet — the greeting always reported offline and the apps page always forced "None extra"
# until the knob existed. Asserted against the knob (not a literal URL) so pointing it at the
# real product site one day needs no test change.
assert_eq "$I_INTERNET_CHECK_URL" \
    "$(sed -nE 's/^[[:space:]]*internetCheckUrl:[[:space:]]+"([^"]+)".*/\1/p' "$APPS_JOB_CONF")" \
    "the shared probe URL is build.conf's INTERNET_CHECK_URL, not HOME_URL"
for k in remote flathubUrl installTimeoutS updateTimeoutS; do
    assert_true "appsetup.conf sets $k" grep -qE "^$k:" "$APPS_JOB_CONF"
done

# THE OFFLINE RULE, IN BOTH HALVES. The page re-asks the internet question every time it is
# entered (the greeting's startup verdict is minutes old by then), forces "none" when the answer
# is no, and the QML disables the two choices that need a connection so the force never fights
# the user. The job re-asks AGAIN, itself, and skips both its passes offline — the page's answer
# is not authority for spending forty minutes of someone's data plan either way.
assert_true "the page re-asks the internet question on every entry" \
    bash -c "sed -n '/^AppsViewStep::onActivate/,/^}/p' '$APPS_SRC/AppsViewStep.cpp' | grep -q 'recheckInternet'"
assert_true "the check is the greeting page's own Manager call, URL and all" \
    grep -q 'Calamares::Network::Manager nam' "$APPS_SRC/AppsConfig.cpp"
assert_true "...and the offline verdict forces the second answer" \
    bash -c "sed -n '/^AppsConfig::recheckInternet/,/^}/p' '$APPS_SRC/AppsConfig.cpp' | grep -q 'm_mode = QStringLiteral( \"none\" )'"
assert_true "the two choices that need a connection are disabled offline, not hidden" \
    bash -c "grep -c 'enabled: apps.hasInternet' '$APPS_QML' | grep -qx 2"
assert_true "the job re-checks connectivity itself, on the host" \
    grep -q 'def check_internet' "$APPS_JOB"
assert_true "...and skips the install AND the update when offline" \
    grep -q 'skipping both the install' "$APPS_JOB"

# THE ONE RULE THE JOB MAY NOT BREAK: no download failure may fail an install. When appsetup
# runs, the OS is on the disk; failing for a stalled LibreOffice would present a working machine
# as broken and offer a retry that rewrites the disk for an app Discover installs in a minute.
# Its single fatal case is the one that is not its fault: no rootMountPoint means imagedeploy
# never ran, and silence there is the lie this count exists to prevent.
assert_eq "1" "$(grep -c 'return (' "$APPS_JOB")" \
    "the job's only error tuple is the missing-rootMountPoint configuration error"
assert_true "the install and update passes run flatpak noninteractively" \
    bash -c "grep -q '\"flatpak\", \"install\", \"-y\", \"--or-update\", \"--system\", \"--noninteractive\"' '$APPS_JOB' &&
             grep -q '\"flatpak\", \"update\", \"-y\", \"--system\", \"--noninteractive\"' '$APPS_JOB'"
# --or-update (plan/33 §7): on a KEPT store, one or more selected apps may already be there, and
# plain `flatpak install` fails the WHOLE batch on the one app that did not need installing.
assert_true "the install pass tolerates apps a kept store already has" \
    grep -q -- '--or-update' "$APPS_JOB"
assert_true "the update pass runs even when nothing was selected" \
    grep -qE '^[[:space:]]+update_refs\(root, conf\)$' "$APPS_JOB"

# DNS IN THE CHROOT IS THE ONE THING imagedeploy DOES NOT PROVIDE and flatpak cannot live
# without: the target's /etc/resolv.conf is resolved's stub symlink into a /run the chroot
# remounted empty, and it dangles. A BIND MOUNT is the only shape that is right on both sides
# of the overlay — a written file would persist past the reboot, a deleted one would whiteout
# the lower's symlink out of existence — and the stock umount module cleans the mount up.
assert_true "the job binds a working resolver config into the target" \
    bash -c "grep -q 'run/systemd/resolve/resolv.conf' '$APPS_JOB' &&
             grep -q 'mount.*--bind' '$APPS_JOB'"

# THE PAGE'S CONTRACT WITH THE JOB IS TWO KEYS, and the mode is not one the job acts on: the
# page resolves "typical" to its ids before publishing, so the job cannot disagree with the
# conf about what the set was. The intersection for "custom" is taken in the same place.
assert_true "the page publishes exactly the two keys the job reads" \
    bash -c "grep -q 'gs->insert( QStringLiteral( \"appsMode\" )' '$APPS_SRC/AppsConfig.cpp' &&
             grep -q 'gs->insert( QStringLiteral( \"appsSelected\" )' '$APPS_SRC/AppsConfig.cpp'"

# EVERY `apps.<name>` IN THE QML RESOLVES TO SOMETHING C++ DECLARES — the disk page's check, for
# the disk page's reason: a typo'd binding in QML renders empty, silently.
assert_true "every QML binding resolves to an AppsConfig property or method" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
qml = (d / "qml" / "Apps.qml").read_text(encoding="utf-8")
hdr = (d / "AppsConfig.h").read_text(encoding="utf-8")
used = sorted(set(re.findall(r"\bapps\.([A-Za-z_][A-Za-z0-9_]*)", qml)))
assert used, "the QML binds to nothing at all - is the context property still called apps?"
known = set(re.findall(r"Q_PROPERTY\(\s*\S+\s+(\w+)\s+READ", hdr))
known |= set(re.findall(r"\b(\w+)\s*\([^)]*\)\s*(?:const)?\s*;", hdr))
missing = [u for u in used if u not in known]
assert not missing, "QML binds to %s, which AppsConfig does not declare" % ", ".join(missing)
' "$APPS_SRC"
# ...and every property either is CONSTANT or notifies a signal something actually emits.
assert_true "every Q_PROPERTY is CONSTANT or notifies an emitted signal" \
    python3 -c '
import re, sys, pathlib
d = pathlib.Path(sys.argv[1])
hdr = (d / "AppsConfig.h").read_text(encoding="utf-8")
cpp = (d / "AppsConfig.cpp").read_text(encoding="utf-8")
bad = []
for decl in re.findall(r"Q_PROPERTY\((.*?)\)", hdr, re.S):
    flat = " ".join(decl.split()); name = flat.split()[1]
    if "CONSTANT" in flat:
        continue
    m = re.search(r"NOTIFY\s+(\w+)", flat)
    if not m:
        bad.append("%s is neither CONSTANT nor NOTIFY" % name)
    elif not re.search(r"void\s+%s\s*\(" % m.group(1), hdr):
        bad.append("%s notifies %s, which is not declared" % (name, m.group(1)))
    elif not re.search(r"emit\s+%s\s*\(" % m.group(1), cpp):
        bad.append("%s notifies %s, which nothing emits" % (name, m.group(1)))
assert not bad, "; ".join(bad)
' "$APPS_SRC"

# NO qsTr() CALL IN THIS MODULE'S QML, and the reason is the toolchain: the builder's lupdate
# (dev-qt/qttools 6.11) is built without QML support, so a qsTr() here has never reached the
# branding catalogue and would render English in all nine languages. Every string this page
# shows is a tr()'d AppsConfig property instead — see AppsConfig.h. The day the builder grows
# QML-aware lupdate, this assertion is the one to drop. (The grep matches the CALL — a quote
# after the paren — because the comments above say qsTr() too, saying why there is none.)
assert_false "the QML carries no qsTr() call of its own" \
    grep -q 'qsTr("' "$APPS_QML"

# THE LABEL IS PART OF THE CONTROL (plan/27 §7, and since plan/28 literally so). A QQC2 control
# without `text:` does not extend its hit area to a sibling label, so the three mode rows and the
# app rows each needed a MouseArea beside a bare radio or checkbox to make their words clickable.
# The repaint removed that whole class of bug instead of re-styling it: the card IS the control,
# with `background`, `indicator` and `contentItem` all replaced, so the words are inside the hit
# area, inside the keyboard target and inside the accessible object. What must not come back is a
# bare mark with the words outside it — which is what these two assertions pin.
assert_true "the mode cards and app tiles are the controls, drawn whole" \
    bash -c "grep -c '^ *indicator: null$' '$APPS_QML' | grep -qx 2"
assert_false "...so no label needs a MouseArea to become clickable" \
    grep -qE '^\s*MouseArea \{' "$APPS_QML"
assert_true "...and a mode card still answers the question its radio does" \
    grep -q 'onClicked: apps.mode = card.modeId' "$APPS_QML"
# The app tile leads with a name and a sentence: the Flathub id stays the key C++ and the job
# exchange, and stops being the text the row is read by.
assert_false "no label draws the Flathub identifier any more" \
    grep -qE 'text: app(Row|Box)\.modelData\.id' "$APPS_QML"
assert_true "...the description sits under the name instead" \
    grep -q 'text: appBox.modelData.description' "$APPS_QML"
assert_true "...and toggling the tile is what changes the selection" \
    grep -q 'onToggled: apps.setSelected(appBox.modelData.id, checked)' "$APPS_QML"

# The module is `apps`, everywhere the siblings are: built by that name, sidebar named by the
# page's one noun, QML inside the .so.
assert_true "the plugin is built as 'apps'" \
    grep -qE '^calamares_add_plugin\(apps$' "$APPS_SRC/CMakeLists.txt"
assert_true "...and the sidebar says Applications" \
    bash -c "sed -n '/^AppsViewStep::prettyName/,/^}/p' '$APPS_SRC/AppsViewStep.cpp' | grep -q 'tr( \"Applications\" )'"
assert_true "...and the QML travels inside the .so rather than being installed a second time" \
    grep -q 'qt6_add_resources(${APPS_TARGET}' "$APPS_SRC/CMakeLists.txt"

# ---- 6g. the design system's tokens (plan/28) ------------------------------------------------
# The installer paints the Immos Design System, and the whole palette arrives through ONE file.
# Three ways that can come apart, none of which fails a build:
#
#   1. A MODULE FORGETS TO NAME IT. stage 20 stages Theme.qml into every module whose CMakeLists
#      asks for it, which means naming it IS the opt-in. A module that instantiates Theme{} and
#      does not list the file gets a QML type error at load and renders a blank page — the exact
#      failure every CMakeLists' "a resource cannot be half-installed" note is about. Stage 20
#      cannot catch it (it only sees what the build files ask for); this can.
#   2. A COLOUR IS INVENTED. Anything in Theme.qml that is not in the design system is a shade
#      somebody liked, and by the time it is noticed it is on nine pages. Every literal has to be
#      in config/branding/README.md's provenance table, which is the same bargain
#      test-splash-assets.sh strikes with the splash colours.
#   3. THE LIGHT/DARK NESTING INVERTS. surface-card is WHITE and surface-page is the GREY in the
#      light theme, and every inset panel in the installer is "page on card". Swap them — which is
#      what transcribing the dark palette by mistake does — and every panel vanishes into its
#      background while still rendering perfectly.
THEME_QML="$CAL/qml/Theme.qml"
assert_file "$THEME_QML" "the design system's tokens have one canonical copy"

# NOT a singleton, and this is the decision being pinned rather than a style preference: a QML
# singleton needs a qmldir beside it and an import path registered on the engine, which is the
# second QML search order that every module's CMakeLists refuses in writing.
assert_false "Theme.qml is not a QML singleton (that would need an import path)" \
    grep -q 'pragma Singleton' "$THEME_QML"
assert_false "...and there is no qmldir beside it" \
    test -e "$CAL/qml/qmldir"

# The light-theme nesting, asserted as the two values rather than as prose.
assert_true "surfaceCard is white (light theme, not dark)" \
    grep -qE 'readonly property color surfaceCard: *white' "$THEME_QML"
assert_true "...and surfacePage is the grey it sits on" \
    grep -qE 'readonly property color surfacePage: *basalt50' "$THEME_QML"
assert_true "the teal accent is the design system's --accent" \
    grep -qE 'readonly property color accent: *"#0e9c8a"' "$THEME_QML"

# Archivo is not packaged in Gentoo and the substitution is deliberate (config/branding/README.md).
# Asserted because "display headings stopped being bold" is how somebody would 'fix' it by pointing
# fontDisplay at a family the medium does not carry, which fontconfig answers silently.
assert_true "fontDisplay is the documented IBM Plex substitution for Archivo" \
    grep -qE 'readonly property string fontDisplay: *"IBM Plex Sans"' "$THEME_QML"
assert_false "...and no font property asks for Archivo, which the medium does not carry" \
    grep -qE 'property string font[A-Za-z]*: *"Archivo"' "$THEME_QML"

# The shared input is the second file in that directory, and it is shared for the same reason.
assert_file "$CAL/qml/Field.qml" "the design system's labelled input is shared, not copied per form"
assert_false "...and says none of its own words — every string is passed in" \
    grep -q 'qsTr("' "$CAL/qml/Field.qml"

# Every module that has QML must compile the shared files in with it.
THEME_MODULES=0
for d in "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files; do
    [[ -d $d/qml ]] || continue
    THEME_MODULES=$(( THEME_MODULES + 1 ))
    m="$(basename -- "$(dirname -- "$d")")"
    assert_true "$m compiles qml/Theme.qml into its own resource" \
        grep -q 'qml/Theme\.qml' "$d/CMakeLists.txt"
    # A module that USES a shared component must also compile it in. Naming the file is the
    # opt-in, so the two have to agree or the page loads with a QML type error and renders blank
    # — which is the failure every CMakeLists in this tree has a paragraph about.
    for shared in "$CAL"/qml/*.qml; do
        sc="$(basename -- "$shared" .qml)"
        [[ $sc == Theme ]] && continue
        if grep -rqE "^[[:space:]]*$sc \{" "$d/qml"; then
            assert_true "$m instantiates $sc and compiles qml/$sc.qml in with it" \
                grep -qF "qml/$sc.qml" "$d/CMakeLists.txt"
        fi
    done
    # ...and the page must OWN its token object rather than hold an id for it, so that passing it
    # to a child can be qualified. `ds: ds` binds a child's property to itself (the child's own
    # `ds` shadows the page's in the right-hand side's scope): a binding loop, an undefined theme,
    # and a page painted in whatever null evaluates to. Neither qmllint nor a grep for colours
    # would see it; this does.
    assert_false "$m never passes its token object to a child unqualified" \
        grep -rqE '^[[:space:]]*ds: ds$' "$d/qml"
    # The repository must NOT carry the copies: they are staged by stage 20 into the rendered
    # overlay, and a checked-in copy is a second source of truth that drifts silently.
    for shared in "$CAL"/qml/*.qml; do
        assert_false "...and does not carry a checked-in copy of $(basename -- "$shared")" \
            test -e "$d/qml/$(basename -- "$shared")"
    done
done
assert_true "at least one module carries QML at all" test "$THEME_MODULES" -gt 0

# EVERY PAGE TAKES ITSELF OUT OF BREEZE, and this is the sweep that catches the one that did not.
# Kirigami resolves its colours from the platform theme unless `inherit` is cleared, so a page
# that forgets the line renders perfectly — in whatever Plasma theme the live session is running,
# beside eight pages that are painting the brand. Nothing else fails; there is no log line. The
# page file is the one named after its module, which is the convention every module here follows.
for d in "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files; do
    [[ -d $d/qml ]] || continue
    m="$(basename -- "$(dirname -- "$d")")"
    page="$d/qml/$(python3 -c 'import sys; print(sys.argv[1].rsplit("-",1)[1].capitalize())' "$m").qml"
    assert_file "$page" "$m's page file is named after its module"
    assert_true "...and takes itself out of the desktop theme" \
        grep -qE '^\s*Kirigami\.Theme\.inherit: false$' "$page"
    assert_true "...and owns the token object it paints from" \
        grep -qE '^\s*readonly property Theme ds: Theme \{\}$' "$page"
    # There is no Custom in Kirigami's ColorSet enum — the first repaint set one, it evaluated to
    # undefined, and both pages would have rendered in the wrong palette in silence.
    # (The ASSIGNMENT, not the word: the comment above the block in each page says what Custom
    # was and why it is gone, and a grep for the word would fail on the explanation.)
    assert_false "...without assigning a colour set that does not exist" \
        grep -qE '^\s*Kirigami\.Theme\.colorSet:.*Custom' "$page"
done

# Stage 20 is the only thing that puts those files where the CMakeLists expect them.
STAGE20="$REPO_ROOT/scripts/stages/20-builder-setup.sh"
assert_true "stage 20 stages the shared QML into the rendered overlay" \
    grep -q 'SHARED_QML_SRC=' "$STAGE20"
assert_true "...driven by which CMakeLists name which file, not by a hand-kept list" \
    grep -q 'grep -qF "qml/$base" "$cml"' "$STAGE20"
assert_true "...and refuses a build where they reached no module at all" \
    grep -q 'SHARED_QML_N > 0' "$STAGE20"

# Provenance: every colour in the token object is one the design system published.
THEME_UNDOCUMENTED=""
while read -r c; do
    grep -qi -- "$c" "$REPO_ROOT/config/branding/README.md" || THEME_UNDOCUMENTED+=" $c"
done < <(grep -oiE '#[0-9a-f]{6}' "$THEME_QML" | tr 'A-F' 'a-f' | sort -u)
assert_eq "" "$THEME_UNDOCUMENTED" \
    "every colour literal in Theme.qml is recorded in config/branding/README.md"

# ---- 6h. no qsTr() in any installer QML (plan/27 §1) -----------------------------------------
# The builder's lupdate is built WITHOUT QML support, so a qsTr() in a .qml is extracted by
# nothing, reaches no .ts file, and renders English in every language — with the page working
# perfectly in the one language nobody needed it to. Disk.qml has carried this as a comment since
# plan/27; a comment does not fail a build. Every user-visible string belongs on the module's
# Config object as a tr()'d Q_PROPERTY, which is what the per-page property sweeps below check.
QSTR_OFFENDERS=""
while IFS= read -r -d '' f; do
    grep -q 'qsTr("' "$f" && QSTR_OFFENDERS+=" ${f#"$REPO_ROOT"/}"
done < <(find "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files/qml \
              -name '*.qml' -print0 2>/dev/null)
assert_eq "" "$QSTR_OFFENDERS" \
    "no installer QML calls qsTr() — the builder's lupdate cannot see it (plan/27 §1)"

# ---- 6i. the QML actually parses, and resolves what it references (plan/28) -------------------
# THE CHECK THAT FOUND A BUG THE MOMENT IT WAS WRITTEN. The first repaint set
#
#     Kirigami.Theme.colorSet: Kirigami.Theme.Custom
#
# on two pages. There is no `Custom` in Kirigami's ColorSet enum — it is
# View/Window/Button/Selection/Tooltip/Complementary/Header — so the expression was undefined, the
# assignment was accepted in silence, and the pages would have rendered perfectly in the wrong
# palette. That is the exact shape of failure this whole plan is about, and no grep-based
# assertion above would ever have seen it.
#
# qmllint comes from dev-qt/qtdeclarative, which is in the BUILDER and not on a developer's host,
# so this runs in the builder image when there is one and skips when there is not — the same
# bargain section 7 makes with PyYAML and test-splash-assets.sh makes with rsvg-convert. It is a
# read-only container over a copy of the QML; it builds nothing.
#
# `unqualified` is filtered out and must be: `language`, `disk`, `accounts` and `apps` are context
# properties injected by C++ at run time, so qmllint cannot know they exist and says so once per
# binding. The property-sweep assertions above are what check those, and they check them better.
#
# Theme.qml is copied in beside each page because that is where stage 20 puts it — a lint that
# could not resolve the token object would report every `theme.` reference and drown the signal.
if command -v docker >/dev/null 2>&1 && docker image inspect "${I_DISTRO_ID}-builder:latest" >/dev/null 2>&1; then
    QMLDIR="$TMP/qmllint"
    # GLOBBED, not listed: a module added later is linted by existing here, which is the whole
    # point of a check that catches type errors no compiler sees.
    for d in "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files; do
        m="$(basename -- "$(dirname -- "$d")")"; m="${m#distro-calamares-}"
        src="$d/qml"
        [[ -d $src ]] || continue
        mkdir -p "$QMLDIR/$m"
        cp "$src"/*.qml "$QMLDIR/$m/"
        cp "$REPO_ROOT"/config/calamares/qml/*.qml "$QMLDIR/$m/"
    done
    QML_SHARED_PRUNE=()
    for shared in "$REPO_ROOT"/config/calamares/qml/*.qml; do
        QML_SHARED_PRUNE+=( ! -name "$(basename -- "$shared")" )
    done
    QML_TARGETS=()
    while IFS= read -r -d '' f; do QML_TARGETS+=( "/q/${f#"$QMLDIR"/}" ); done \
        < <(find "$QMLDIR" -name '*.qml' "${QML_SHARED_PRUNE[@]}" -print0 | sort -z)
    # The shared files are linted once, through whichever module comes first alphabetically —
    # they are byte-identical copies, so linting them five times says the same thing five times.
    for shared in "$REPO_ROOT"/config/calamares/qml/*.qml; do
        QML_TARGETS+=( "/q/accounts/$(basename -- "$shared")" )
    done
    QML_OUT="$(docker run --rm --entrypoint /usr/lib64/qt6/bin/qmllint \
                   -v "$QMLDIR":/q:ro "${I_DISTRO_ID}-builder:latest" \
                   "${QML_TARGETS[@]}" 2>&1 \
               | grep -E '^(Error|Warning):' | grep -v '\[unqualified\]' || true)"
    assert_eq "" "$QML_OUT" "every installer .qml parses and resolves what it references"
else
    echo "  (no ${I_DISTRO_ID}-builder image — skipping the qmllint pass)"
fi

# ---- 6j. the palette for the widgets Calamares draws itself (plan/28) ------------------------
# The exec step's progress page, the error dialog and the About box are Qt widgets that branding
# cannot reach; they resolve through KColorScheme, which reads [Colors:*] out of kdeglobals. The
# groups are appended on this profile only — so the failure this guards is an installer that
# paints the design system on nine pages and Breeze on the tenth, which is worse than not having
# started.
COLORS_SRC="$REPO_ROOT/config/plasma/colors-installer.in"
assert_file "$COLORS_SRC" "the installer session carries a palette for its widget surfaces"
STAGE40="$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 appends it to kdeglobals rather than replacing the file" \
    grep -qF 'cat -- "$WORK/colors-installer" >> "$TARGET/etc/xdg/kdeglobals"' "$STAGE40"
assert_true "...and reads the result back, because a silent no-op is the failure" \
    grep -qF "grep -qx '\[Colors:Selection\]'" "$STAGE40"
# ...and ONLY on this profile. The product image's user picks a scheme in System Settings, and a
# hard-coded palette in /etc/xdg would override a choice that is not the distribution's to make.
assert_true "...inside the installer-only section of stage 40" \
    bash -c "python3 - <<'EOF'
import pathlib, sys
s = pathlib.Path('$REPO_ROOT/scripts/stages/40-configure.sh').read_text()
append = s.index('colors-installer')
marker = s.index('config/calamares is missing')   # the installer section's own guard
sys.exit(0 if append > marker else 'the palette is appended outside the installer section')
EOF"

# THE PALETTE AND THE TOKENS ARE THE SAME COLOURS. KColorScheme wants r,g,b; Theme.qml states
# #rrggbb; a mismatch is a progress page in a slightly different white from the page above it,
# which is the kind of thing that is obvious in a screenshot and invisible in a diff.
assert_true "the palette's window, view, selection and text are Theme.qml's own" \
    bash -c "python3 - <<'EOF'
import pathlib, re, sys

theme = pathlib.Path('$CAL/qml/Theme.qml').read_text()
colors = pathlib.Path('$COLORS_SRC').read_text()

def token(name):
    m = re.search(r'readonly property color %s: +\"(#[0-9a-fA-F]{6})\"' % name, theme)
    assert m, 'Theme.qml has no %s' % name
    h = m.group(1).lstrip('#')
    return '%d,%d,%d' % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

def group(name):
    m = re.search(r'\[%s\]\n((?:[A-Za-z].*\n)+)' % re.escape(name), colors)
    assert m, 'the palette has no [%s]' % name
    return dict(l.split('=', 1) for l in m.group(1).strip().splitlines())

bad = []
checks = [
    ('Colors:Window',    'BackgroundNormal', 'basalt50'),   # --surface-page
    ('Colors:Window',    'ForegroundNormal', 'basalt700'),  # --text-body
    ('Colors:View',      'BackgroundNormal', 'white'),      # --surface-card
    ('Colors:View',      'ForegroundNormal', 'basalt900'),  # --text-strong
    ('Colors:Selection', 'BackgroundNormal', 'accent'),
    ('Colors:Selection', 'ForegroundNormal', 'accentOn'),
]
for g, key, name in checks:
    want, got = token(name), group(g).get(key)
    if want != got:
        bad.append('[%s] %s is %s, Theme.qml says %s (%s)' % (g, key, got, want, name))
sys.exit('; '.join(bad) if bad else 0)
EOF"
# The typeface too: the widget surfaces should not be the one part of the installer still in Noto.
assert_true "...and the palette sets the same typeface the pages ask for" \
    bash -c "grep -q '^font=IBM Plex Sans,' '$COLORS_SRC' && grep -q '^fixed=IBM Plex Mono,' '$COLORS_SRC'"

# ---- 6k. the four pages plan/28 §6 took back from upstream -----------------------------------
#
# WHAT MAKES THESE FOUR DIFFERENT FROM THE FIVE BEFORE THEM, and what these assertions are about:
# each one replaces a STOCK module that is still installed, under its own name, on the same disk.
# So the failure mode is not "the installer has no summary page" — it is settings.conf naming
# `review`, ModuleManager finding no module of that name, silently dropping the step, and
# upstream's `summary` sitting unused two directories away. Nothing logs it at a level anyone
# reads, and the medium installs with one screen missing.
for pair in location:locale keymap:keyboard review:summary done:finished; do
    NEW="${pair%%:*}"; OLD="${pair#*:}"
    SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-$NEW/files"
    CLASS="$(python3 -c 'import sys; print(sys.argv[1].capitalize())' "$NEW")"

    assert_dir_exists() { [[ -d $1 ]]; }
    assert_true "$NEW is a module in the overlay" assert_dir_exists "$SRC"
    # The plugin's NAME is what ModuleManager matches against the directory it was installed
    # into, and calamares_add_plugin derives both from this one argument.
    assert_true "...built as '$NEW', which is not the stock module's name" \
        grep -qE "^calamares_add_plugin\($NEW\$" "$SRC/CMakeLists.txt"
    assert_false "...and never as '$OLD', which would collide file-for-file with upstream's" \
        grep -qE "^calamares_add_plugin\($OLD\$" "$SRC/CMakeLists.txt"
    # The QML travels inside the .so, like its five siblings'.
    assert_true "...with its QML compiled into the plugin rather than installed a second time" \
        grep -q "qt6_add_resources(\${$(python3 -c 'import sys; print(sys.argv[1].upper())' "$NEW")_TARGET}" \
            "$SRC/CMakeLists.txt"
    assert_file "$SRC/${CLASS}ViewStep.cpp" "...and a view step named after it"
    assert_file "$SRC/${CLASS}Config.cpp"   "...and a config object beside it"

    # EVERY `<ctx>.<name>` IN THE QML RESOLVES TO SOMETHING C++ DECLARES. A typo'd binding in QML
    # is not an error and not a warning: the expression evaluates to undefined and the control
    # renders empty or invisible. This is the check that turns a silent blank into a failed build,
    # and it is the same one the language, disk and applications pages have had since plan/25.
    assert_true "$NEW: every QML binding resolves to a property or method C++ declares" \
        python3 -c '
import re, sys, pathlib
d, ctx, cls = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
qml = (d / "qml" / (cls + ".qml")).read_text(encoding="utf-8")
hdr = (d / (cls + "Config.h")).read_text(encoding="utf-8")
used = sorted(set(re.findall(r"\b%s\.([A-Za-z_][A-Za-z0-9_]*)" % ctx, qml)))
assert used, "the QML binds to nothing at all — is the context property still called %s?" % ctx
known = set(re.findall(r"Q_PROPERTY\(\s*\S+\s+(\w+)\s+READ", hdr))
known |= set(re.findall(r"\b(\w+)\s*\([^)]*\)\s*(?:const)?\s*[;{]", hdr))
missing = [u for u in used if u not in known]
assert not missing, "QML binds to %s, which %sConfig does not declare" % (", ".join(missing), cls)
' "$SRC" "$NEW" "$CLASS"

    # ...and every property either is CONSTANT or notifies a signal that something actually
    # emits. A NOTIFY naming a signal nobody emits is a binding evaluated once and then never
    # again — the page simply stops updating, which is indistinguishable from "nothing changed".
    assert_true "$NEW: every Q_PROPERTY is CONSTANT or notifies an emitted signal" \
        python3 -c '
import re, sys, pathlib
d, cls = pathlib.Path(sys.argv[1]), sys.argv[2]
hdr = (d / (cls + "Config.h")).read_text(encoding="utf-8")
cpp = (d / (cls + "Config.cpp")).read_text(encoding="utf-8")
bad = []
for decl in re.findall(r"Q_PROPERTY\((.*?)\)", hdr, re.S):
    flat = " ".join(decl.split()); name = flat.split()[1]
    if "CONSTANT" in flat:
        continue
    m = re.search(r"NOTIFY\s+(\w+)", flat)
    if not m:
        bad.append("%s is neither CONSTANT nor NOTIFY" % name)
    elif not re.search(r"void\s+%s\s*\(" % m.group(1), hdr):
        bad.append("%s notifies %s, which is not declared" % (name, m.group(1)))
    elif not re.search(r"emit\s+%s\s*\(" % m.group(1), cpp):
        bad.append("%s notifies %s, which nothing emits" % (name, m.group(1)))
assert not bad, "; ".join(bad)
' "$SRC" "$CLASS"

    # The engine retranslate, whose absence leaves every binding in the language the installer
    # started in. Every QML module in this installer carries this line.
    assert_true "$NEW: the view step retranslates its QML engine on a language change" \
        grep -q 'engine()->retranslate()' "$SRC/${CLASS}ViewStep.cpp"
    # ...and the style call stays in the FIRST module, which is the language page's.
    assert_false "$NEW: does not set the Qt Quick Controls style" \
        grep -qE '^[^/*]*QQuickStyle::setStyle' "$SRC/${CLASS}ViewStep.cpp"
done

# THE SEQUENCE NAMES THE NEW MODULES AND NOT THE STOCK ONES. Both halves matter, and the second
# more: a `- locale` left in the exec list runs upstream's SetTimezoneJob against a Config nobody
# filled in, which writes the medium's own default over whatever the user answered — an install
# that silently comes up in UTC with a page that said otherwise.
for pair in location:locale keymap:keyboard review:summary done:finished \
            localesetup:locale keyboardsetup:keyboard; do
    NEW="${pair%%:*}"; OLD="${pair#*:}"
    assert_true "the sequence names $NEW" \
        grep -qE "^[[:space:]]*-[[:space:]]+$NEW\$" "$SETTINGS"
    assert_false "...and no longer names the stock $OLD" \
        grep -qE "^[[:space:]]*-[[:space:]]+$OLD\$" "$SETTINGS"
done
assert_true "stage 40 refuses a rendered settings.conf that still names one" \
    grep -q 'for stale in locale:localesetup keyboard:keyboardsetup summary:review finished:done' \
        "$REPO_ROOT/scripts/stages/40-configure.sh"

# ---- 6l. the two jobs the replaced pages left behind -----------------------------------------
#
# A view step owns its jobs(), so replacing the stock `locale` and `keyboard` PAGES orphaned
# SetTimezoneJob and SetKeyboardLayoutJob. These two took them over, in Python, beside the six job
# modules this installer already had.
for job in localesetup keyboardsetup; do
    assert_file "$CAL/local-modules/$job/main.py"    "$job is a python job module"
    assert_file "$CAL/local-modules/$job/module.desc" "...with a descriptor"
    # ModuleManager matches module.desc's `name` against its DIRECTORY name and skips the module
    # in silence when they differ — the failure class this whole file was written for.
    assert_true "...whose name matches its directory" \
        grep -qE "^name:[[:space:]]+\"$job\"" "$CAL/local-modules/$job/module.desc"
    assert_true "...declared as a python job" \
        bash -c "grep -qE '^type:[[:space:]]+\"job\"' '$CAL/local-modules/$job/module.desc' &&
                 grep -qE '^interface:[[:space:]]+\"python\"' '$CAL/local-modules/$job/module.desc'"
    assert_file "$RENDER/modules/$job.conf" "...and a rendered configuration"
done

# THE KEYS THE PAGES PUBLISH ARE THE KEYS THE JOBS READ, and this is the seam where a rename is
# invisible: both sides compile, both sides run, and the job simply finds nothing and warns into a
# log at the end of an install.
assert_true "localesetup reads the location page's own keys" \
    bash -c "grep -q 'locationRegion' '$CAL/local-modules/localesetup/main.py' &&
             grep -q 'locationZone'   '$CAL/local-modules/localesetup/main.py' &&
             grep -q 'locationRegion' '$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/LocationConfig.cpp'"
assert_true "keyboardsetup reads the keymap page's own keys" \
    bash -c "grep -q 'keyboardLayout'  '$CAL/local-modules/keyboardsetup/main.py' &&
             grep -q 'keyboardVariant' '$CAL/local-modules/keyboardsetup/main.py' &&
             grep -q 'keyboardLayout'  '$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-keymap/files/KeymapConfig.cpp'"

# THE CONSOLE KEYMAP COMES FROM THE TARGET, not from a copy. Upstream resolves an X11 layout to a
# console keymap through a kbd-model-map compiled into Calamares' own QRC — a snapshot of a table.
# systemd ships that table, and systemd-localed reads it on the installed machine, so reading the
# TARGET's copy is the one arrangement in which this job and localed cannot disagree. A table
# vendored into this repo would be a third answer.
assert_true "keyboardsetup resolves the console keymap from the target's own kbd-model-map" \
    grep -q '/usr/share/systemd/kbd-model-map' "$CAL/local-modules/keyboardsetup/main.py"
assert_false "...and this repo ships no copy of that table" \
    bash -c "find '$REPO_ROOT/config' -name 'kbd-model-map*' | grep -q ."
# A layout with no console equivalent is NOT a failed install: the graphical session reads the X11
# file, which is written either way, and KEYMAP staying as the image shipped it is a defensible
# outcome. Returning an error there would fail an install over a tty nobody is going to use.
assert_true "...and a layout with no console keymap warns rather than failing the install" \
    bash -c "sed -n '/no console keymap for X11 layout/,/return None/p' '$CAL/local-modules/keyboardsetup/main.py' |
             grep -q 'return None'"

# /etc/locale.conf HAS EXACTLY ONE WRITER (plan/22 §6). imageidentity writes it, and only for a
# locale the image actually compiled; a second writer in localesetup would be the precise failure
# that check exists to prevent — a LANG the target cannot load, which glibc answers with the C
# locale rather than an error.
assert_false "localesetup does not write /etc/locale.conf — imageidentity owns it" \
    bash -c "grep -vE '^[[:space:]]*#' '$CAL/local-modules/localesetup/main.py' | grep -q 'locale.conf'"
assert_true "...and imageidentity still does" \
    grep -q '/etc/locale.conf' "$CAL/local-modules/imageidentity/main.py"

# ---- 6m. inline components do not reach outward (plan/28) ------------------------------------
#
# An `component Foo: Item { ... }` inside a page is its OWN component, and an unqualified name
# inside it does not resolve the way it does in the file around it: qmllint reports "ds is a
# member of a parent element", which is a lookup up the parent CHAIN — the dynamic scoping that
# `pragma ComponentBehavior: Bound` exists to discourage, and which every one of these files
# declares at the top.
#
# WHAT IT COSTS WHEN IT FAILS is the reason this is a test and not a style note. A `ds.accent`
# that resolves to undefined is a control drawn in no colour at all; a `QQC2.ButtonGroup.group:
# modeGroup` that resolves to undefined is three radio cards in no group, all selectable at once,
# on the page that decides what gets installed. Neither logs anything.
#
# So the rule is: an inline component declares what it needs as a required property and is handed
# it. This checks the two names that were actually reached for — the token object and the button
# group — inside every `component X:` body in the installer's QML.
assert_true "no inline component reaches outside itself for the theme or a button group" \
    python3 -c '
import pathlib, re, sys

bad = []
for qml in sorted(pathlib.Path(sys.argv[1]).glob("distro-calamares-*/files/qml/*.qml")):
    text = qml.read_text(encoding="utf-8")
    # Each `component Name: Type {` opens a body that ends where the brace it opened closes.
    for m in re.finditer(r"^(\s*)component\s+(\w+)\s*:", text, re.M):
        indent, name = m.group(1), m.group(2)
        rest = text[m.end():]
        # The body ends at the first line indented no further than the declaration that closes
        # a brace — good enough here, and far simpler than a QML parser, because every one of
        # these files is written with four-space indentation throughout.
        end = re.search(r"^%s\}" % re.escape(indent), rest, re.M)
        body = rest[: end.start()] if end else rest
        code = "\n".join(l for l in body.splitlines() if not l.strip().startswith("//"))
        hits = sorted(set(re.findall(r"(?<![A-Za-z0-9_.])(ds\.\w+|modeGroup)", code)))
        if hits:
            bad.append("%s: component %s reaches for %s" % (qml.name, name, ", ".join(hits)))
assert not bad, "; ".join(bad)
' "$REPO_ROOT/config/portage/overlay/distro-base"

# ---- 6n. keyboardsetup's console-keymap lookup, against a real table ---------------------------
#
# THIS IS THE ONE PIECE OF NEW LOGIC IN plan/28 §6 THAT IS NOT A BINDING OR A LAYOUT, and it is
# the one whose failure is quietest: a wrong console keymap is a tty that types the wrong letters
# on a machine whose graphical session is perfectly fine, which nobody discovers until they drop
# to one.
#
# The table is systemd's /usr/share/systemd/kbd-model-map, and the job reads the TARGET's copy —
# the same file localed reads on the installed machine. A developer host running systemd has the
# same file, so this exercises the real parser against a real table rather than a fixture; where
# it is absent the check skips, the same bargain the YAML pass makes with PyYAML.
#
# WHAT IT PINS is the shape of the answer, not systemd's data: an exact variant match beats a row
# with no variant, an X11 name whose console name DIFFERS resolves to the console one, and a
# layout the table does not mention returns nothing rather than guessing.
KEYMAP_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-keymap/files"
KBD_MAP=/usr/share/systemd/kbd-model-map
if [[ -r $KBD_MAP ]]; then
    assert_true "keyboardsetup resolves X11 layouts to console keymaps the way the table says" \
        python3 - "$REPO_ROOT/config/calamares/local-modules/keyboardsetup/main.py" "$KBD_MAP" <<'EOF'
import importlib.util, pathlib, sys, tempfile, types

# The module under test is imported from the TRACKED tree, and importing a file writes a
# __pycache__ beside it — which is how a .pyc ends up in a commit. test-splash-assets.sh sets the
# same flag for the same reason.
sys.dont_write_bytecode = True

main_py, table = sys.argv[1], pathlib.Path(sys.argv[2])

# The job reads <root>/usr/share/systemd/kbd-model-map, so give it a root with just that in it.
tmp = tempfile.mkdtemp()
dst = pathlib.Path(tmp, "usr/share/systemd")
dst.mkdir(parents=True)
(dst / "kbd-model-map").write_bytes(table.read_bytes())

# The module imports libcalamares at top level for its logging helpers; it is not importable
# outside Calamares, so it is stubbed. Nothing under test touches anything else on it.
lc = types.ModuleType("libcalamares")
lc.utils = types.SimpleNamespace(debug=lambda *a: None, warning=lambda *a: None,
                                 gettext_path=lambda: None, gettext_languages=lambda: ["en"])
lc.globalstorage = types.SimpleNamespace(value=lambda k: None)
lc.job = types.SimpleNamespace(configuration={})
sys.modules["libcalamares"] = lc

spec = importlib.util.spec_from_file_location("keyboardsetup", main_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Read the expectations OUT OF THE TABLE rather than hard-coding systemd's data: the point is the
# parser, and a fixed answer here would fail the day systemd renames a keymap.
rows = []
for line in table.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        f = line.split()
        if len(f) >= 4:
            rows.append((f[0], f[1].split(",")[0], f[3]))

bad = []
def check(layout, variant, want, why):
    got = mod.console_keymap(tmp, layout, variant)
    if got != want:
        bad.append("%s/%s -> %r, expected %r (%s)" % (layout, variant or "-", got, want, why))

# 1. An X11 layout with a plain row resolves to that row's console name — including the ones where
#    the two names differ, which is the whole reason a table exists.
plain = {}
for console, xlayout, xvariant in rows:
    if xvariant in ("", "-") and xlayout not in plain:
        plain[xlayout] = console
assert plain, "no variant-less rows in the table at all — has its format changed?"
for xlayout, console in list(plain.items())[:12]:
    check(xlayout, "", console, "plain row")
differing = [x for x, c in plain.items() if x != c]
assert differing, "no row in the table has a console name differing from its X11 name"
check(differing[0], "", plain[differing[0]], "console name differs from the X11 name")

# 2. An exact variant match beats the plain row for the same layout.
for console, xlayout, xvariant in rows:
    if xvariant not in ("", "-") and xlayout in plain and console != plain[xlayout]:
        check(xlayout, xvariant, console, "exact variant beats the plain row")
        break
else:
    assert False, "no layout in the table has both a plain row and a distinct variant row"

# 3. A layout the table does not mention is None, not a guess.
check("zzzz-not-a-layout", "", None, "unknown layout")
# 4. ...and so is an unknown VARIANT of a known layout, falling back to the plain row.
known = next(iter(plain))
check(known, "zzzz-not-a-variant", plain[known], "unknown variant falls back to the plain row")

assert not bad, "; ".join(bad)
EOF
else
    echo "  ($KBD_MAP absent — skipping the console-keymap lookup check)"
fi

# ---- 6o. the xkb registry still has the shape KeymapConfig parses ------------------------------
#
# KeymapConfig::loadRegistry() reads /usr/share/X11/xkb/rules/evdev.xml with QXmlStreamReader and
# forty lines of its own, rather than vendoring 300 lines of upstream's parser (plan/28 §6). What
# that trades away is upstream's maintenance of the format, so the format is checked here: the
# nesting the parser assumes is `<layoutList><layout><configItem><name|description>` with a
# sibling `<variantList><variant><configItem><name|description>`, and a `<modelList>` and
# `<optionList>` around it that use the SAME element names and must not be mistaken for layouts.
#
# A developer host with x11-misc/xkeyboard-config has the same file the medium does, so this reads
# the real registry; where it is absent the check skips. It cannot run the C++ — what it pins is
# the assumption the C++ is built on, which is the half that changes without anyone here touching
# a line.
XKB_RULES=/usr/share/X11/xkb/rules/evdev.xml
if [[ -r $XKB_RULES ]] && python3 -c 'import xml.etree.ElementTree' 2>/dev/null; then
    assert_true "the xkb registry nests layouts and variants the way KeymapConfig reads them" \
        python3 - "$XKB_RULES" "$KEYMAP_SRC/KeymapConfig.cpp" <<'EOF'
import sys, xml.etree.ElementTree as ET, pathlib, re

root = ET.parse(sys.argv[1]).getroot()
cpp = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

# 1. The file the C++ names is the file being checked.
assert '"/usr/share/X11/xkb/rules/evdev.xml"' in cpp, \
    "KeymapConfig no longer names evdev.xml; this check is testing the wrong file"

layouts = root.find("layoutList").findall("layout")
assert len(layouts) > 20, "only %d layouts — the registry is not the list it used to be" % len(layouts)

# 2. Every layout carries the two elements the parser reads, in a configItem of its own.
for l in layouts:
    assert l.find("configItem/name") is not None, "a layout with no configItem/name"
    assert l.find("configItem/description") is not None, "a layout with no configItem/description"

# 3. Variants live in a variantList SIBLING of that configItem, shaped the same way. At least one
#    layout must have them, or the page's second dropdown is empty for everybody.
withvars = [l for l in layouts if l.find("variantList") is not None]
assert withvars, "no layout has a variantList at all"
v = withvars[0].find("variantList").find("variant")
assert v.find("configItem/name") is not None, "a variant with no configItem/name"

# 4. THE TRAP THE PARSER HAS TO AVOID: modelList and optionList use the same element names, and
#    they surround layoutList in the same document. The parser only appends on </layout>, so this
#    asserts the thing that would break it — a <layout> element somewhere else in the file.
assert root.find("modelList") is not None, "no modelList — the document shape has changed"
strays = [e for e in root.iter("layout") if e not in layouts]
assert not strays, "%d <layout> elements outside layoutList" % len(strays)
EOF
else
    echo "  ($XKB_RULES absent — skipping the xkb registry shape check)"
fi

# ---- 6p. no layout child sizes itself from the size the layout gave it (plan/28 §9) ---------
#
# THE BUG THIS EXISTS FOR STOPPED THE INSTALLER FROM STARTING, and nothing else offline said a
# word about it. calamares-sidebar.qml's logo read:
#
#     height: 32;
#     sourceSize.height: height * 2;   // for a HiDPI panel
#
# An Image inside a ColumnLayout does not own its height — the LAYOUT assigns it, computed from
# the item's implicitHeight — and an Image takes its implicitHeight from sourceSize the moment
# sourceSize is set. So the item asked to be twice as tall as the layout had just made it, on
# every pass: 32, 64, 128, and the sidebar doubled until the window was 2.8 million pixels tall.
# The backing store's QImage is width x height x 4 — 11.7 GB — and it failed to allocate; the
# failed flush scheduled another repaint, which failed the same way. Calamares sat at 100% CPU
# forever, having already logged "Window now visible" for a window that never drew a pixel. On a
# booted medium that is an installer that does not start, with nothing in any log to say why.
#
# THE QML ENGINE DOES NOT CALL THIS A BINDING LOOP and never will: the cycle closes through
# QQuickLayout's C++ rather than through the engine, so there is no warning at any logging level,
# nothing in the session log, and qmllint (section 6i) sees a perfectly well-typed file. Refusing
# the shape is the only way to catch it without booting.
#
# THE SHAPE: a property that FEEDS a layout's calculation — implicitWidth/implicitHeight,
# sourceSize, Layout.preferred/minimum/maximum — bound to an expression that reads this item's own
# BARE `width` or `height`, which is exactly what the layout writes back. Qualified reads are not
# flagged and must not be: `parent.width`, `form.width` and `logo.implicitWidth` are somebody
# else's number, imposed from outside, and cannot close a cycle onto this item. Comments are
# stripped first, so the word "height" in the prose above a constant is not a failure.
SIZE_LOOP_OFFENDERS=""
while IFS= read -r -d '' f; do
    hit="$(awk '
        {
            line = $0; sub(/\/\/.*/, "", line)
            if (line ~ /^[[:space:]]*(implicitWidth|implicitHeight|sourceSize\.(width|height)|Layout\.(preferred|minimum|maximum)(Width|Height))[[:space:]]*:/) {
                v = line; sub(/^[^:]*:/, "", v)
                if (v ~ /(^|[^.A-Za-z0-9_])(width|height)([^A-Za-z0-9_]|$)/) print FNR
            }
        }' "$f")"
    [ -n "$hit" ] && SIZE_LOOP_OFFENDERS+=" ${f#"$REPO_ROOT"/}:$(echo "$hit" | tr '\n' ',')"
done < <(find "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files/qml \
              "$CAL/qml" "$CAL/branding/installer" -maxdepth 1 -name '*.qml' -print0 2>/dev/null)
assert_eq "" "$SIZE_LOOP_OFFENDERS" \
    "no installer QML feeds a layout an implicit size computed from its own width or height"

# ---- 6q. the four corrections plan/28's VM walk-through asked for -----------------------------
#
# Each of these is a thing that looked right in a screenshot and was wrong in front of somebody.

# 1. THE VERDICT WEARS A STATUS MARK. The one line that says whether this machine can be
# installed at all was the only status on the page set as plain text, while every row above it
# carried a 22px chip. Both tones, not just the good one: a tick that appears on success and
# leaves nothing behind on failure makes the failure read as "not checked yet", which is the
# state the spinner above it already means. (The ROWS have since lost their chip — plan/31 §4,
# section 6w below — which leaves this one the only mark on the page and does not change why it
# is there.)
GREETING_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-greeting/files/qml/Greeting.qml"
assert_true "the greeting verdict carries a status chip" \
    grep -qE 'color: checksSatisfied\.satisfied \? ds\.statusSuccessBg : ds\.statusDangerBg' "$GREETING_QML"
assert_true "...a tick when the machine passes, and an exclamation when it does not" \
    grep -qE 'text: checksSatisfied\.satisfied \? "✓" : "!"' "$GREETING_QML"
# The chip reads the MODEL's verdict, through the same object the recheck line already uses. Two
# answers to one question is how a page comes to disagree with the Next button beside it —
# GreetingViewStep::isNextEnabled() reads satisfiedMandatory and this page must not hold a copy.
assert_true "...and takes that verdict from the requirements model, not from a second count" \
    grep -qE 'greeting\.requirements\.satisfiedMandatory' "$GREETING_QML"

# 2. THE PLACE THIS INSTALLER OPENS ON. Etc/UTC was the honest answer to "where is this machine"
# and the wrong default for a page: nothing here detects location, so the choice is between a pin
# that is right for most people who boot this medium and one that is right for nobody.
LOCATION_CONF="$CAL/modules/location.conf"
assert_true "the location page opens on America/Toronto" \
    bash -c "grep -qE '^region: +\"America\"' '$LOCATION_CONF' && grep -qE '^zone: +\"Toronto\"' '$LOCATION_CONF'"
# The zone has to be one tzdata actually carries, or the page silently opens on whatever the
# region's first zone happens to be. Checked against the host's own tzdata when there is one.
if [[ -d /usr/share/zoneinfo ]]; then
    assert_file "/usr/share/zoneinfo/America/Toronto" \
        "...and that is a zone tzdata carries, not a city somebody typed"
fi
# THE MEDIUM'S OWN CLOCK IS NOT THE INSTALLED MACHINE'S. Stage 40 symlinks the live session's
# /etc/localtime to UTC and still must: a live session that re-dated itself from a page the user
# has not reached yet would be a surprise with nothing behind it. The target's symlink is
# localesetup's, written in the exec phase from the keys above.
assert_true "the live medium's own clock stays on UTC" \
    grep -qE '^ln -sfn \.\./usr/share/zoneinfo/UTC "\$TARGET/etc/localtime"$' \
        "$REPO_ROOT/scripts/stages/40-configure.sh"
# A default this module cannot honour has to SAY so. The check used to be made after clampZone(),
# which had already replaced an unknown zone with the region's first — so it could only ever fire
# for a region with no zones at all, and it named the fallback twice and the configured value
# never. With a named city rather than UTC in the configuration, the silent version of that is an
# installer that quietly opens on some other place in the same region and looks deliberate.
LOCATION_CPP="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/LocationConfig.cpp"
assert_true "an unhonourable default is detected BEFORE the clamp that would hide it" \
    bash -c "awk '/const bool defaultExists/ { f = NR } /^ *clampZone\(\);/ { if (f && NR > f) { print \"ok\"; exit } }' '$LOCATION_CPP' | grep -q ok"

# 3. NO MESSAGE MAY SIZE THE COLUMN IT SITS IN. LocalForm lays its fields out in a two-column
# grid, and a grid column is at least as wide as the widest implicit width in it. A Text's
# implicitWidth is its text on ONE line — wrapMode changes how it draws, not what it asks for —
# so the moment libpwquality answered, the password cell demanded a column wide enough to set that
# sentence unwrapped and the other column shrank to pay for it. Measured with the real component
# under a real Qt: 254/448 before the message, 566/136 with it, and back again when it cleared.
# The whole form rearranged itself while somebody was typing into it.
FIELD_QML="$CAL/qml/Field.qml"
FIELD_TEXTS="$(grep -cE '^    Text \{$' "$FIELD_QML")"
FIELD_NEUTRAL="$(grep -cE '^        Layout\.preferredWidth: 0$' "$FIELD_QML")"
assert_eq "2" "$FIELD_TEXTS" "the shared field has exactly two texts of its own: its label and its message"
assert_eq "$FIELD_TEXTS" "$FIELD_NEUTRAL" \
    "...and neither asks its layout for a width, so a message cannot resize the form"

# 4. THE RELOAD MARK. "Check again" is the only do-that-once-more control in the installer and it
# is on two pages, so it is one glyph on both — drawn, like every other mark here, because
# Kirigami.Icon would resolve out of the Breeze icon theme in Breeze's colour, and U+21BB is not
# in IBM Plex Sans (fontconfig would substitute a stranger's arrow for that one character).
BUTTON_QML="$CAL/qml/Button.qml"
assert_true "the shared button can carry a glyph" \
    grep -qE '^    property string icon: ""$' "$BUTTON_QML"
assert_true "...drawn on a Canvas rather than resolved from the desktop's icon theme" \
    grep -qE '^            Canvas \{$' "$BUTTON_QML"
# NARROWLY: the shared controls. Kirigami.Icon is right where the picture belongs to somebody
# else — an application's own icon on the apps page, a drive's on the disk page — and wrong for a
# mark that is part of this design system, which is every mark inside a control here. So the
# assertion is about the control, not about the installer: Button.qml does not import Kirigami at
# all, and therefore cannot grow an icon it did not draw.
assert_false "the shared button draws its glyph rather than resolving one from a theme" \
    grep -qE '^import org\.kde\.kirigami|icon\.name:' "$BUTTON_QML"
# The glyph has to be in the button's WIDTH, or a button sized for its label alone clips the one
# thing this change added. The row is what carries both now.
assert_true "the button's width counts the glyph beside the label, not the label alone" \
    grep -qE '^    implicitWidth: content\.implicitWidth \+ 2 \* button\._padding$' "$BUTTON_QML"
for pair in disk:rescan apps:recheckInternet; do
    m="${pair%%:*}"
    q="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-$m/files/qml/$(python3 -c 'import sys; print(sys.argv[1].capitalize())' "$m").qml"
    assert_true "$m's Check again button carries the reload mark" \
        grep -qE '^ +icon: "refresh"$' "$q"
    # Both buttons are the SHARED one. A QQC2.Button here would be drawn by qqc2-desktop-style in
    # Breeze's metrics whatever Kirigami.Theme says, and it is the icon that would give it away.
    assert_true "...on the shared Button, so both pages get the same one" \
        grep -qE '^ +label: '"$m"'\.checkAgainLabel$' "$q"
done

# ---- 6r. the clock the page can now set (plan/29) ---------------------------------------------
#
# The location page drew a clock and could not correct it. Everything below is one of the three
# ends that had to exist before the checkbox was allowed to: the servers, the page, and the
# installed system.

# 1. THE SERVERS, AND THE KEY THEY ARE WRITTEN UNDER. FallbackNTP is the whole design: DHCP's
# servers and the domain controller's NTP= both outrank it, which is what lets a build-time
# default coexist with a network that has its own opinion.
NTP_DROPIN_SRC="$REPO_ROOT/config/rootfs/etc/systemd/timesyncd.conf.d/05-distro-ntp.conf.in"
assert_file "$NTP_DROPIN_SRC" "the image ships a timesyncd drop-in template"
assert_true "...which sets FallbackNTP from build.conf" \
    grep -qx 'FallbackNTP=@NTP_SERVERS@' "$NTP_DROPIN_SRC"
# NTP= would outrank both DHCP and `<id>-domain join`'s 10-domain.conf, on every machine this
# image ever becomes, and the symptom is a domain login failing on clock skew months later.
assert_false "...and never NTP=, which belongs to the domain controller" \
    grep -qE '^NTP=' "$NTP_DROPIN_SRC"
# The 05- prefix is what keeps that true: drop-ins are read in lexical order and a later file wins
# the keys it sets, so this one has to sort BEFORE 10-domain.conf.
assert_true "...and sorts before the domain drop-in it must not outrank" \
    bash -c '[[ "05-distro-ntp.conf" < "10-domain.conf" ]]'
assert_true "the domain client still writes the drop-in this one defers to" \
    grep -q '10-domain.conf' "$REPO_ROOT/config/rootfs/usr/bin/distro-domain.in"

# EMPTY IS NOT THE SAME AS UNSET. `FallbackNTP=` with nothing after it CLEARS systemd's compiled-in
# list rather than inheriting it, so an unset knob must delete the file instead of rendering it.
assert_true "an empty NTP_SERVERS deletes the drop-in rather than emptying it" \
    grep -qE 'rm -f -- "\$NTP_DROPIN"' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "...and build.conf's default for the knob is empty, not a list" \
    grep -qE '^ +: "\$\{NTP_SERVERS=\}"$' "$REPO_ROOT/scripts/lib/common.sh"
# A comma-separated list is the mistake with no symptom: timesyncd reads the whole string as one
# host name, fails to resolve it, and the clock is simply wrong.
assert_false "a comma-separated NTP_SERVERS is refused" \
    bash -c 'set -e
             export REPO="'"$REPO_ROOT"'" OUT="'"$TMP"'/o" STAGE_NAME=t
             source "'"$REPO_ROOT"'/scripts/lib/common.sh"
             load_config
             NTP_SERVERS="a.example,b.example" validate_config' 2>/dev/null

# 2. THE PAGE. The box, the button, and the line that says whether either worked.
LOCATION_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/qml/Location.qml"
LOCATION_H="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/LocationConfig.h"
LOCATION_CPP="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/LocationConfig.cpp"
assert_true "the location page opens with network time ticked" \
    grep -qE '^networkTime: true$' "$CAL/modules/location.conf"
assert_true "...and the packaged fallback agrees with the image's own preset" \
    grep -qE '^networkTime: true$' \
        "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/location.conf"
assert_true "the page draws a network-time checkbox" \
    grep -qE 'onToggled: location\.networkTime = ntpBox\.checked' "$LOCATION_QML"
assert_true "...a Set-date-and-time button, disabled while the network owns the clock" \
    bash -c "grep -qE 'label: location\.setTimeLabel' '$LOCATION_QML' && grep -qE 'enabled: location\.canSetTime' '$LOCATION_QML'"
assert_true "...and a status line that reports what actually happened" \
    grep -qE 'text: location\.syncStatus' "$LOCATION_QML"
# NO qsTr() ANYWHERE IN IT, the rule every page here follows: the builder's lupdate is built
# without QML support, so a string in this file would reach no catalogue (plan/27 §1).
assert_false "...with no string of its own" grep -q 'qsTr("' "$LOCATION_QML"

# CHECKING THE BOX IS THE ACTION, not a note of a preference. It runs timedatectl on this machine
# and then watches NTPSynchronized — because announcing "set from the network" the instant
# set-ntp returns is a claim about a server that has not been asked yet.
assert_true "checking the box enables NTP on the running machine" \
    grep -qE 'QStringLiteral\( "set-ntp" \)' "$LOCATION_CPP"
assert_true "...and the page waits for a server to answer before saying it worked" \
    grep -qE 'QStringLiteral\( "NTPSynchronized" \)' "$LOCATION_CPP"
assert_true "...applied when the page opens, not only when somebody touches it" \
    grep -qE 'm_config->applyNetworkTime\(\);' \
        "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/LocationViewStep.cpp"
# THE TYPED TIME IS READ IN THE CHOSEN ZONE AND WRITTEN IN THE MACHINE'S. `timedatectl set-time`
# reads its argument in the zone /etc/localtime names, which on this medium is UTC — so handing it
# the string the user typed would set the clock hours wrong in the way that looks like it worked.
assert_true "a hand-set time is converted out of the chosen zone before it is written" \
    grep -qE 'entered\.toLocalTime\(\)\.toString' "$LOCATION_CPP"
assert_true "...and refused outright while the network owns the clock" \
    grep -qE 'Turn off automatic time before setting the clock by hand' "$LOCATION_CPP"
# The two typed fields take ONE format, not the locale's: 03/04/2026 is two different days on two
# sides of an ocean and the field cannot ask which was meant. The TIME grew a second form in
# plan/30 §3 — see §6t — and the point survives it: both forms are fixed, and neither is QLocale's.
assert_true "the dialog's fields take one unambiguous format" \
    bash -c "grep -qE 'kEditDateFormat = \"yyyy-MM-dd\"' '$LOCATION_CPP' && grep -qE 'kEditTimeFormat24 = \"HH:mm\"' '$LOCATION_CPP'"
# The dialog is the design system's, not Breeze's. The erase confirmation is the one
# Kirigami.PromptDialog left in this installer and it is noted rather than defended.
assert_false "the set-time dialog is not a second unbranded Breeze prompt" \
    grep -qE '^ +Kirigami\.PromptDialog \{' "$LOCATION_QML"
assert_true "...but a Popup this page draws itself" \
    grep -qE '^ +QQC2\.Popup \{' "$LOCATION_QML"
# Both shared components have to be NAMED by the module's own build file or they never reach the
# resource — stage 20's fan-out is derived from exactly these lines.
LOCATION_CML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/CMakeLists.txt"
for shared in Button Field; do
    assert_true "the location module compiles in $shared.qml" \
        grep -qE "^ +qml/$shared\.qml$" "$LOCATION_CML"
done

# 3. THE INSTALLED SYSTEM, which is what makes this a question rather than a live-session
# convenience. The published key is OURS and spelled so: upstream's locale module has no notion of
# network time, so there is no contract here to honour and a name that looked like one would lie.
assert_true "the page publishes its answer for the exec phase" \
    grep -qE 'QStringLiteral\( "locationNetworkTime" \)' "$LOCATION_CPP"
LOCALESETUP="$REPO_ROOT/config/calamares/local-modules/localesetup/main.py"
assert_true "localesetup reads it" \
    grep -qE 'globalstorage\.value\("locationNetworkTime"\)' "$LOCALESETUP"
# ABSENT IS NOT FALSE. A missing key means the page is not in the sequence, and the right answer
# then is the image's own — which is on, because the vendor preset enables timesyncd.
assert_true "...and treats an absent key as the image's own default, not as a no" \
    grep -qE 'wanted = True if value is None else bool\(value\)' "$LOCALESETUP"
# A MASK, NOT A DISABLE: deleting the .wants symlink is a whiteout that the next `systemctl
# preset-all` undoes, which would quietly switch network time back on.
assert_true "unticking it masks timesyncd in the target" \
    grep -qE 'os\.symlink\(os\.devnull, mask\)' "$LOCALESETUP"
assert_true "...and takes the preset's enablement symlink with it" \
    grep -qE 'TIMESYNCD_WANT = "/etc/systemd/system/sysinit\.target\.wants/"' "$LOCALESETUP"
# The unit this is all about has to actually be enabled in the image, or "ticked" means nothing.
assert_true "the image enables systemd-timesyncd in the first place" \
    grep -qx 'enable systemd-timesyncd.service' \
        "$REPO_ROOT/config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in"

# ---- 6u. the disk list's vertical rhythm (plan/30 §4) ---------------------------------------
#
# Each row holds a 16px title over a 12px mono line — 40px of content that was carrying 32px of
# padding, in a list whose gaps were as tall as a line of its own text. 16 is the design system's
# CARD padding and 10 its card gutter; this is a list of rows, and it takes the row values.
DISK_ROW_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-disk/files/qml/Disk.qml"
assert_true "the gap between disks is the row gutter, not the card gutter" \
    grep -qE '^ +spacing: ds\.space2 - 2$' "$DISK_ROW_QML"
assert_true "...and a row's own padding came down with it" \
    bash -c "grep -qE '^ +topPadding: ds\.space3 - 2$' '$DISK_ROW_QML' &&
             grep -qE '^ +bottomPadding: ds\.space3 - 2$' '$DISK_ROW_QML'"
# The row must still be taller than anything in it: the radio mark, the drive icon and the
# "not eligible" badge are all 20-22px, and 10px of padding leaves room for every one of them.
assert_false "...but not below the height of the marks the row carries" \
    grep -qE '^ +(top|bottom)Padding: ds\.space2( |$)' "$DISK_ROW_QML"

# ---- 6t. the clock's two shapes (plan/30 §3) --------------------------------------------------
#
# The page draws a clock and the dialog takes one, and until now the first was formatted by
# QLocale and the second was 24-hour whatever the first said. Both read the same key now.

for f in "$REPO_ROOT/config/calamares/modules/location.conf" \
         "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/location.conf"; do
    assert_true "$(basename -- "$(dirname -- "$f")")/location.conf asks for a 12-hour clock" \
        grep -qE '^twelveHour: true$' "$f"
done
assert_true "the page reads the key, defaulting to 12-hour" \
    grep -q 'm_twelveHour = Calamares::getBool( configurationMap, QStringLiteral( "twelveHour" ), true );' \
    "$LOCATION_CPP"
# THE CLOCK STOPPED ASKING QLocale, which is the behaviour change under the feature: Qt knows
# whether a language writes 13:45 or 1:45 PM, and this page must not let the language picker
# override a build-time decision.
assert_false "the clock is no longer formatted by the language picker" \
    grep -q 'QLocale().toString( now.time()' "$LOCATION_CPP"
assert_true "...but by the flag" \
    bash -c "grep -q 'kClockFormat12 = \"h:mm AP\"' '$LOCATION_CPP' &&
             grep -q 'kClockFormat24 = \"HH:mm\"' '$LOCATION_CPP'"
# The two typed formats differ by ONE LETTER'S CASE, which is the kind of thing worth pinning.
assert_true "the typed time has a 12-hour form and a 24-hour form" \
    bash -c "grep -q 'kEditTimeFormat12 = \"hh:mm\"' '$LOCATION_CPP' &&
             grep -q 'kEditTimeFormat24 = \"HH:mm\"' '$LOCATION_CPP'"
# The words are QLocale's, so they are not nine more translations to keep.
assert_true "AM and PM come from the language, not from a catalogue" \
    bash -c "grep -q 'QLocale().amText()' '$LOCATION_CPP' &&
             grep -q 'QLocale().pmText()' '$LOCATION_CPP'"
# ...and therefore the index crosses the boundary, never the word.
assert_true "the meridiem crosses as an index" \
    bash -c "grep -q 'Q_INVOKABLE bool applySystemTime( const QString& date, const QString& time, int meridiem );' '$LOCATION_H' &&
             grep -q 'setTimeDialog.meridiem = parseInt(key, 10);' '$LOCATION_QML'"
assert_true "...and -1 means there is no meridiem to apply" \
    grep -q 'property int meridiem: -1' "$LOCATION_QML"
# 12 AM is hour 0 and 12 PM is hour 12; every other hour is itself plus twelve after noon. An
# off-by-twelve here sets the machine half a day wrong and the page shows what was typed.
assert_true "12 AM is midnight and 12 PM is noon" \
    bash -c "grep -q 'const int typed = t.hour() % 12;' '$LOCATION_CPP' &&
             grep -q 'const int hour = meridiem == 1 ? typed + 12 : typed;' '$LOCATION_CPP'"
# "hh" does not range-check in Qt — it says how to PRINT an hour, not which hours exist.
assert_true "a 12-hour field refuses an hour outside 1-12" \
    grep -q 't.hour() < 1 || t.hour() > 12' "$LOCATION_CPP"
# The select appears only on a 12-hour clock, and the grid keeps three columns either way.
assert_true "the dialog shows an AM/PM select only on a 12-hour clock" \
    bash -c "grep -q 'visible: location.twelveHour' '$LOCATION_QML' &&
             grep -q 'columns: 3' '$LOCATION_QML'"
# It is the page's own Picker, which is why that component had to move to the document root.
assert_true "the select is the page's own hand-drawn combo" \
    grep -qE '^    component Picker: ColumnLayout \{$' "$LOCATION_QML"
# The hint under the field and the parse error both said "24-hour clock" in so many words.
assert_true "the hint under the time field follows the flag" \
    grep -q 'return m_twelveHour ? tr( "Hours and minutes, as in %1" )' "$LOCATION_H"
assert_true "...and so does the complaint when it will not parse" \
    grep -q 'The time must be written hours:minutes, as in %1.' "$LOCATION_CPP"

# ---- 6s. the keyboard reaches every control, and says where it is (plan/30 §1) ---------------
#
# WHAT THIS SECTION CANNOT CHECK is whether Tab actually moves between Calamares' three separate
# QQuickWidgets; that is qquickwidget.cpp's behaviour and it is verified on a booted medium. What
# it can check is the half that is ours: that every control which a person can operate declares a
# tab stop and draws the ring, because each of the five gaps plan/30 found was a control that
# looked finished and had simply never been reachable.

SHARED_QML="$REPO_ROOT/config/calamares/qml"
NAV_QML="$REPO_ROOT/config/calamares/branding/installer/calamares-navigation.qml"
SIDEBAR_QML="$REPO_ROOT/config/calamares/branding/installer/calamares-sidebar.qml"

# 1. THE SHARED INPUT. A bare TextInput defaults activeFocusOnTab to false — this is the line that
# put every accounts field and both set-time fields on the chain.
assert_true "the shared Field takes tab focus" \
    grep -qE '^ +activeFocusOnTab: true$' "$SHARED_QML/Field.qml"
assert_true "...and draws the ring on activeFocus" \
    grep -q 'visible: input.activeFocus' "$SHARED_QML/Field.qml"

# 2. THE SHARED CHECK BOX, which exists because two pages had drawn the same unreachable control.
assert_file "$SHARED_QML/CheckBox.qml" "the design system has one check box"
assert_true "...which takes tab focus" \
    grep -qE '^ +activeFocusOnTab: true$' "$SHARED_QML/CheckBox.qml"
assert_true "...and can be operated from the keyboard" \
    grep -q 'Keys.onSpacePressed' "$SHARED_QML/CheckBox.qml"
assert_true "...and announces itself as a check box" \
    grep -q 'Accessible.role: Accessible.CheckBox' "$SHARED_QML/CheckBox.qml"
# It must NOT toggle itself: C++ is the source of truth on both pages that use it, and a control
# that flipped its own state would disagree with the install for one frame on every click.
assert_false "...and never assigns its own checked" \
    grep -qE '^ +control\.checked = ' "$SHARED_QML/CheckBox.qml"
for m in accounts done; do
    d="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-$m"
    assert_true "the $m module compiles the shared check box in" \
        grep -qF 'qml/CheckBox.qml' "$d/files/CMakeLists.txt"
done
# The two hand-drawn copies are gone rather than merely unused.
assert_false "the accounts page no longer draws its own check box" \
    grep -q 'property bool checked' \
    "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-accounts/files/qml/LocalForm.qml"
assert_false "the finished page no longer draws its own check box" \
    grep -q 'id: restartBox' \
    "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-done/files/qml/Done.qml"

# 3. THE NAVIGATION BAR. Cancel, Back and Next were a Rectangle with a MouseArea on it.
assert_true "the navigation bar's buttons take tab focus" \
    grep -qE '^ +activeFocusOnTab: button\.active;$' "$NAV_QML"
assert_true "...and can be pressed from the keyboard" \
    grep -q 'Keys.onSpacePressed: if (button.active)' "$NAV_QML"
assert_true "...and draw the ring" \
    grep -q 'visible: button.activeFocus;' "$NAV_QML"
# A disabled Back must not be a tab stop that does nothing: this bar's two-state property is
# `active`, not `enabled`, so the guard has to read the one the instances actually set.
assert_false "...and a dead button is not a tab stop" \
    grep -qE '^ +activeFocusOnTab: true;$' "$NAV_QML"

# 4. THE SIDEBAR's two meta buttons, the same shape and the same hole.
assert_true "the sidebar's meta buttons take tab focus" \
    grep -qE '^ +activeFocusOnTab: true;$' "$SIDEBAR_QML"
assert_true "...and can be pressed from the keyboard" \
    grep -q 'Keys.onReturnPressed: metaButton.activated();' "$SIDEBAR_QML"
# The refactor into one inline component must not have moved the catalogue keys: the panel is
# found by filename and its strings are keyed on the CalamaresSidebar context (plan/27 §3).
for word in About Debug; do
    assert_true "...and still asks the CalamaresSidebar catalogue for \"$word\"" \
        grep -qF "qsTranslate(\"CalamaresSidebar\", \"$word\")" "$SIDEBAR_QML"
done

# 5. THE TWO VIEWS. QQuickItemDelegate sets Qt::NoFocus in its constructor, so the rows cannot be
# tab stops and the view has to be one — and a ring bound to a delegate's `visualFocus` could
# never have appeared, which is what these two replace.
DISK_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-disk/files/qml/Disk.qml"
LANG_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-language/files/qml/Language.qml"
assert_true "the disk list is a tab stop" \
    grep -qE '^ +activeFocusOnTab: true$' "$DISK_QML"
assert_true "...and its ring follows the view's focus, not the row's" \
    grep -q 'readonly property bool keyboardFocus: list.activeFocus && row.highlighted' "$DISK_QML"
assert_false "...so no delegate ring is bound to visualFocus any more" \
    grep -q 'visible: row.visualFocus' "$DISK_QML"
assert_true "the language grid is a tab stop" \
    grep -qE '^ +activeFocusOnTab: true$' "$LANG_QML"
assert_true "...and its ring follows the view's focus" \
    grep -q 'readonly property bool keyboardFocus: grid.activeFocus && cell.current' "$LANG_QML"

# 6. ONE RING, EVERYWHERE. Every page that has a control the keyboard can land on draws the same
# 3px ring in the same colour — a border colour alone cannot carry the state on a control that is
# already accent-bordered because it is selected, which is every chooser in this installer.
for f in "$SHARED_QML/Button.qml" "$SHARED_QML/Field.qml" "$SHARED_QML/CheckBox.qml" \
         "$DISK_QML" "$LANG_QML" "$NAV_QML" "$SIDEBAR_QML" \
         "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-apps/files/qml/Apps.qml" \
         "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-accounts/files/qml/Accounts.qml" \
         "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-keymap/files/qml/Keymap.qml" \
         "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-location/files/qml/Location.qml"; do
    name="$(basename -- "$f")"
    assert_true "$name draws the installer's focus ring" \
        grep -qE 'anchors\.margins: -3' "$f"
    # Newlines folded first: three of these call sites wrap the argument list, and a ring in a
    # colour nobody else uses is exactly the drift this assertion is here to stop.
    assert_true "...in the shared colour" \
        bash -c "tr '\n' ' ' < '$f' | grep -qE 'mix\( *([A-Za-z_]+\.)*accent, *([A-Za-z_]+\.)*surface(Card|Page), *0\.4 *\)'"
done

# ---- 6v. the three corrections the walk-through asked for (plan/30) --------------------------
#
# Each of these is a thing that looked right in the checkout and was wrong at 1024x640.

# 1. "hh" IS NOT A 12-HOUR HOUR ON THE WAY OUT. Qt documents it as "00 to 23 OR 01 to 12 IF
# AP/A/ap/a IS USED", and the dialog's format deliberately carries no AM/PM marker — so the field
# opened on "13:06" and the range check below would then have refused the value the dialog itself
# had filled in. The card beside it read "1:06 PM" the whole time, because the CLOCK format does
# carry AP. editTime() composes the string instead of formatting it.
assert_false "the typed time is not formatted through a bare hh" \
    grep -q 'toString( QString::fromLatin1( m_twelveHour ? kEditTimeFormat12' "$LOCATION_CPP"
assert_true "...it is composed from the converted hour" \
    grep -q 'const int hour = t.hour() % 12 == 0 ? 12 : t.hour() % 12;' "$LOCATION_CPP"
# The clock on the card is the one place "AP" belongs, and it is what makes h/hh mean 12 there.
assert_true "...and the clock's own format is the one that carries AP" \
    grep -q 'kClockFormat12 = "h:mm AP"' "$LOCATION_CPP"

# 2. THE PAGE MARGIN IS A TOKEN, AND IT IS NOT THE MOCKUP'S 36. branding.desc asks for a 1024x640
# window, the navigation bar takes 72 of the height, and 36 top and bottom did not fit: the
# accounts chooser overflowed by ONE PIXEL and drew a full-height scrollbar to say so.
THEME_QML="$REPO_ROOT/config/calamares/qml/Theme.qml"
assert_true "the page margin is a token" \
    bash -c "grep -qE '^ +readonly property int pageMarginV: 28$' '$THEME_QML' &&
             grep -qE '^ +readonly property int pageMarginH: 44$' '$THEME_QML'"
# Every page reads it. A page that set its own is the page that scrolls again.
for f in "$REPO_ROOT"/config/portage/overlay/distro-base/distro-calamares-*/files/qml/*.qml; do
    name="$(basename -- "$f")"
    case "$name" in Theme.qml|Button.qml|Field.qml|CheckBox.qml) continue ;; esac
    assert_false "$name does not transcribe the mockup's 36 any more" \
        grep -q 'ds.space8 + ds.space1' "$f"
    assert_false "...nor its 44" \
        grep -q 'ds.space10 + ds.space1' "$f"
done

# 3. THE SUMMARY TABLE SCROLLED FOR ONE ROW. Six decisions in a box sized for five and a sliver,
# behind a scrollbar twenty pixels long — the shape the applications page was asked to lose.
REVIEW_QML="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-review/files/qml/Review.qml"
assert_true "the summary page scrolls as one page" \
    bash -c "grep -q 'id: scroll' '$REVIEW_QML' && grep -q 'id: sheet' '$REVIEW_QML'"
assert_true "...and its table is as tall as its rows" \
    grep -q 'implicitHeight: rows.contentHeight + 2 \* ds.borderWidth' "$REVIEW_QML"
assert_false "...with no scroller of its own left inside it" \
    bash -c "[[ \$(grep -c 'QQC2.ScrollView {' '$REVIEW_QML') -gt 1 ]]"
# A flickable that cannot move still eats a wheel event, which on a page that scrolls as a whole
# is a dead patch in the middle of it.
assert_true "...and the view it holds is not interactive" \
    grep -qE '^ +interactive: false$' "$REVIEW_QML"

# ---- 6w. the sidebar that truncates, and three defaults (plan/31) ---------------------------
#
# Four reports off plan/30's second build. Three are one line each in a QML file; the fourth is a
# number Calamares does not let anybody set.

# 1. EVERY CELL OF THE SET-TIME GRID SITS AT ITS OWN HEIGHT (plan/31 §1). Layout.fillHeight
# defaults to TRUE for a layout item, and Field and Picker are both ColumnLayouts — so the short
# cell in a row was stretched to the tall cell's height and spread the surplus between its own
# children. That is why the AM/PM label sat 8px low over a box 20px low: not one offset, two.
# All three cells, not just the Picker: two Fields whose hints wrap to a different number of
# lines have the same disagreement waiting in them.
assert_eq "3" \
    "$(tr '\n' ' ' < "$LOCATION_QML" \
        | grep -oE 'Layout\.fillHeight: false +Layout\.alignment: Qt\.AlignTop' | wc -l)" \
    "all three cells of the set-time grid are pinned to the top of their row"
# Top-aligning only lines the LABELS up. What lines the boxes up is that a Field and a Picker put
# the same gap under the label and the same height under that — so these four lines are the other
# half of the fix, and changing one of them without the other is a dialog that is aligned at the
# top and ragged in the middle.
assert_true "a Field's label and box are ds.space2 apart, over a controlHeightMd box" \
    bash -c "grep -qE '^ +spacing: field\.ds\.space2$' '$FIELD_QML' &&
             grep -qE '^ +implicitHeight: field\.ds\.controlHeightMd$' '$FIELD_QML'"
assert_true "...and the Picker beside it says the same two things" \
    bash -c "grep -qE '^ +spacing: picker\.ds\.space2$' '$LOCATION_QML' &&
             grep -qE '^ +implicitHeight: picker\.ds\.controlHeightMd$' '$LOCATION_QML'"

# 2. THE STEP RAIL IS 224PX, AND CALAMARES GIVES IT 168 (plan/31 §2). CalamaresWindow.cpp builds
# the sidebar with qBound( 100, defaultFontHeight() * 12, w < windowPreferredWidth ? 100 : 190 )
# and setDimension() turns that into setFixedWidth(), so the number is a literal no branding key,
# config key or QML property can reach — and 190 is only its ceiling: the default font's height
# on this medium is 14, so the rail gets 168 and the label gets 87 of it. EIGHT of the ninety
# labels this installer can show (ten steps, nine languages) are wider than that, measured from
# the shipped IBM Plex TTF at 14px semibold: Добро Пожаловать (130), Zusammenfassung (123),
# Местоположение (117), アプリケーション (112), Учётные записи (109), Primeros pasos (100),
# Anwendungen (93) and Приложения (87). At 224 the budget is 145 and none of them are.
assert_true "the language module states the rail's width as a measured constant" \
    grep -qE '^static constexpr int kSidebarWidth = 224;$' "$LANG_SRC/LanguageViewStep.cpp"
assert_true "...and sets it on the panel the window built from calamares-sidebar.qml" \
    bash -c "sed -n '/^widenSidebar()/,/^}/p' '$LANG_SRC/LanguageViewStep.cpp' |
             grep -q 'calamares-sidebar.qml' &&
             sed -n '/^widenSidebar()/,/^}/p' '$LANG_SRC/LanguageViewStep.cpp' |
             grep -q 'setFixedWidth( kSidebarWidth )'"
# A rail that is too narrow looks like a rail somebody chose, so the one thing this must not do
# is fail quietly: if the panel is not there, the log says which words will be cut off and why.
assert_true "...and says so in the log if that panel is not there to widen" \
    grep -q 'the step rail keeps the width' "$LANG_SRC/LanguageViewStep.cpp"
# THE ARITHMETIC THE 224 CAME FROM, PINNED WHERE IT LIVES. 224 less the panel's two 16px margins,
# the row's two 10px margins, the 16px step mark and the 11px gap after it is 145px for the label
# — 15px past the widest of the ninety. Every number in that sentence is in the sidebar's QML, and moving
# any of them without redoing the sum is how the labels get cut off again with the file still
# looking correct.
assert_true "the rail's own margins are what the 224 was measured against" \
    bash -c "grep -qE '^ +anchors\.leftMargin: ds\.space4;$' '$SIDEBAR_QML' &&
             grep -qE '^ +anchors\.rightMargin: ds\.space4;$' '$SIDEBAR_QML'"
assert_true "...as are the step row's" \
    bash -c "grep -qE '^ +anchors\.leftMargin: ds\.space2 \+ 2;$' '$SIDEBAR_QML' &&
             grep -qE '^ +anchors\.rightMargin: ds\.space2 \+ 2;$' '$SIDEBAR_QML' &&
             grep -qE '^ +spacing: ds\.space3 - 1;$' '$SIDEBAR_QML'"
assert_true "...and the mark the label makes room for is still 16px" \
    bash -c "sed -n '/The mark: a ring for the step/,/^ *}$/p' '$SIDEBAR_QML' |
             grep -qE 'implicitWidth: 16;'"
# The elide stays, as the net under all of that: a language nobody measured is one translation
# away, and a cut-off word is still better than a word drawn over the page.
assert_true "the step label still elides rather than overrunning the rail" \
    bash -c "sed -n '/LEFT-ALIGNED, which is the one change/,/^ *}$/p' '$SIDEBAR_QML' |
             grep -q 'elide: Text.ElideRight;'"

# 2b. AND THE PAGE THAT PAID FOR THE 56PX. The disk page's lede went from one line to two in a
# narrower column, the list lost 36px with it, and two disks that had fitted since plan/24 came
# back behind a scrollbar — which is the shape plan/30 was asked to remove. The list is now as
# tall as its rows and no taller, so it scrolls when a machine has twelve disks and not when it
# has two. Measured offscreen before it was written: two rows give contentHeight 138 and a 138px
# view, twenty give 1434 and a view capped at the page's 536.
assert_true "the disk list is capped at the height of its own rows" \
    grep -qE '^ +Layout\.maximumHeight: list\.contentHeight$' "$DISK_QML"
# THE CAP IS NOT ENOUGH ON ITS OWN, and the first attempt shipped as if it were. A cap cannot
# create room: two disks need 141px of viewport and the page could spare 124, so the list still
# scrolled — by seventeen pixels, with the second row (the medium the installer booted from,
# which every real machine shows) half-drawn behind a scrollbar. The gutter between this page's
# five blocks is where the rest comes from: four gaps at 12 rather than 20.
assert_true "the disk page's blocks sit on a tighter gutter than the other pages'" \
    bash -c "sed -n '/^    ColumnLayout {/,/^        Layout/p' '$DISK_QML' |
             grep -qE '^ +spacing: ds\.space3$'"
assert_true "...and the planned-layout panel gives up 8px of its own padding" \
    bash -c "grep -qE 'implicitHeight: planBody\.implicitHeight \+ 2 \* \(ds\.space4 - 2\)' '$DISK_QML' &&
             grep -qE '^ +anchors\.margins: ds\.space4 - 2$' '$DISK_QML'"
# AND NO FILLER AT THE FOOT OF THE PAGE. An Item with fillHeight is a second claimant on the
# surplus and a ColumnLayout splits what is going spare between everything that can grow: with
# one there, the list gave up about fourteen pixels to a blank Item and kept its scrollbar.
# Measured on the medium — the list ran 283..400 with the filler and 283..405 without.
assert_false "...and nothing else on the page competes for the height the list needs" \
    bash -c "sed -n '/---- what will happen to it/,\$p' '$DISK_QML' |
             grep -qE '^ +Layout\.fillHeight: true$'"

# 3. THE CHOOSER SHOWS THE MODE IT IS ALREADY IN (plan/31 §3). AccountsConfig has selected Local
# since plan/26 §2 — 6a asserts it — but the cards never read it, because the ButtonGroup above
# them is deliberately the UI's own source of truth and a group starts with nothing checked. The
# page therefore opened on a mode nothing on the screen named, with Next lit and no reason given.
ACCOUNTS_QML="$OVL_ACCOUNTS/files/qml/Accounts.qml"
assert_true "the card for the configured mode checks itself when it is built" \
    bash -c "tr '\n' ' ' < '$ACCOUNTS_QML' |
             grep -qE 'Component\.onCompleted: \{ +if \(choice\.modelData\.mode === accounts\.mode\) \{ +choice\.checked = true;'"
# IMPERATIVE, AND ONCE. A binding on `checked` is broken by the first click — the reason the
# group owns the state at all — so this must not become one.
assert_false "...and does not bind checked, which the first click would break" \
    grep -qE '^ +checked: ' "$ACCOUNTS_QML"

# 4. ONE EXCLAMATION, ON THE LINE THAT MEANS IT (plan/31 §4). Since plan/30 the greeting panel
# lists only what is wrong, so the row chip was an exclamation on every row, in a tone the badge
# at the other end of the same row already spells out in words — and it was the same 22px chip,
# at the same size, that the verdict wears. Six copies of a mark is not an emphasis.
assert_false "the greeting's rows carry no status chip of their own" \
    grep -qE 'text: row\.satisfied \? "✓" : "!"' "$GREETING_QML"
assert_eq "1" "$(grep -c '"✓" : "!"' "$GREETING_QML")" \
    "...so the page has exactly one of them left, and it is the verdict's"
# What still says which is which, now that the chip does not: the badge, in the same two tones.
assert_true "...and the row still says Required or Optional in the tone it means" \
    bash -c "grep -q 'greeting.requiredLabel' '$GREETING_QML' &&
             grep -q 'greeting.optionalLabel' '$GREETING_QML'"

# ---- 6x. keeping what is on the disk (plan/33) -------------------------------------------
#
# The feature this whole file gained a new section for: a disk that already holds an install of
# this distro can be reinstalled onto while keeping its accounts, files, apps and settings. §2's
# partition-label fix is asserted in test-common.sh and test-profiles.sh; everything below is the
# checkbox, the job, the pages that stand down, and the summary/finish rows.

# ---- inspect_installed_layout(), against fixtures (plan/33 §4) -------------------------------
# No sfdisk needed: heredoc `sfdisk --dump` texts, fed straight to the function layout.sh
# defines — the SAME function both the disk page and the disksetup job run as a subprocess, so a
# fixture that passes here is a fixture both of them agree about.
assert_true "inspect_installed_layout is defined only in layout.sh" \
    bash -c "[[ \$(grep -rl '^inspect_installed_layout()' '$REPO_ROOT/scripts') == '$LAYOUT_SH' ]]"

inspect_of() {   # DEVICE ESP_MIB SLOT_MIB <<< DUMP
    bash -c "source '$LAYOUT_SH'; inspect_installed_layout \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}

# keep: one real root_<v> and one _empty, exactly the shape a fresh install leaves.
keep_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=     2099200, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/sda3 : start=    14682112, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="_empty"
/dev/sda4 : start=    27265024, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
keep_out="$(inspect_of /dev/sda 100 6144 <<<"$keep_dump")"
assert_contains 'verdict=keep'    "$keep_out" "fixture: root_0.3.0 + _empty is verdict=keep"
assert_contains 'installed=0.3.0' "$keep_out" "fixture: installed= is the version on the disk"
assert_contains 'esp=1'           "$keep_out" "fixture: esp is partition 1"
assert_contains 'slot=2'          "$keep_out" "fixture: slot is always partition 2"
assert_contains 'spare=3'         "$keep_out" "fixture: spare is always partition 3"
assert_contains 'var=4'           "$keep_out" "fixture: var is partition 4"

# keep: BOTH slots hold a real root_<v> (two successful installs/updates) — installed= is the
# HIGHER one, by sort -V, not the one that happens to sit in p2.
two_root_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=     2099200, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.4.0"
/dev/sda3 : start=    14682112, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/sda4 : start=    27265024, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
two_root_out="$(inspect_of /dev/sda 100 6144 <<<"$two_root_dump")"
assert_contains 'verdict=keep'    "$two_root_out" "fixture: two root_* is still verdict=keep"
assert_contains 'installed=0.4.0' "$two_root_out" "fixture: installed= is the HIGHER of the two versions"

# nvme-style nodes: the "p" separator, stripped correctly.
nvme_dump='label: gpt
sector-size: 512

/dev/nvme0n1p1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/nvme0n1p2 : start=     2099200, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/nvme0n1p3 : start=    14682112, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="_empty"
/dev/nvme0n1p4 : start=    27265024, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
nvme_out="$(inspect_of /dev/nvme0n1 100 6144 <<<"$nvme_dump")"
assert_contains 'verdict=keep' "$nvme_out" "fixture: nvme-style p2/p3/p4 nodes resolve correctly"

# none: no var at all — a disk running something else entirely.
none_dump='label: gpt
sector-size: 512

/dev/sda1 : start=2048, size=2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"'
none_out="$(inspect_of /dev/sda 100 6144 <<<"$none_dump")"
assert_eq "verdict=none" "$none_out" "fixture: no var partition at all is verdict=none, and nothing else"

# refuse/table: a var-typed, var-named partition present, but the table itself is not GPT.
dos_dump='label: dos
sector-size: 512

/dev/sda4 : start=2048, size=2097152, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
dos_out="$(inspect_of /dev/sda 100 6144 <<<"$dos_dump")"
assert_contains 'verdict=refuse' "$dos_out" "fixture: a var match on a non-gpt table is verdict=refuse"
assert_contains 'reason=table'   "$dos_out" "fixture: ...reason=table"

# refuse/layout: three partitions, not four.
three_part_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=     2099200, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/sda3 : start=    14682112, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
three_out="$(inspect_of /dev/sda 100 6144 <<<"$three_part_dump")"
assert_contains 'verdict=refuse' "$three_out" "fixture: three partitions is verdict=refuse"
assert_contains 'reason=layout'  "$three_out" "fixture: ...reason=layout"

# refuse/layout: a wrong type on the root slot (right name, wrong GUID).
wrong_type_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=     2099200, size=    12582912, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root_0.3.0"
/dev/sda3 : start=    14682112, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="_empty"
/dev/sda4 : start=    27265024, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
wrong_type_out="$(inspect_of /dev/sda 100 6144 <<<"$wrong_type_dump")"
assert_contains 'verdict=refuse' "$wrong_type_out" "fixture: a wrong-typed root slot is verdict=refuse"
assert_contains 'reason=layout'  "$wrong_type_out" "fixture: ...reason=layout"

# refuse/esp-size: p1 smaller than ESP_MIB.
small_esp_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=      206848, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/sda3 : start=    12789760, size=    12582912, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="_empty"
/dev/sda4 : start=    25372672, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
small_esp_out="$(inspect_of /dev/sda 200 6144 <<<"$small_esp_dump")"
assert_contains 'verdict=refuse'  "$small_esp_out" "fixture: an ESP smaller than ESP_MIB is verdict=refuse"
assert_contains 'reason=esp-size' "$small_esp_out" "fixture: ...reason=esp-size"

# refuse/slot-size: a root slot smaller than SLOT_MIB.
small_slot_dump='label: gpt
sector-size: 512

/dev/sda1 : start=        2048, size=      2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
/dev/sda2 : start=     2099200, size=     2097152, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="root_0.3.0"
/dev/sda3 : start=     4196352, size=     2097152, type=4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44, name="_empty"
/dev/sda4 : start=     6293504, size=    60000000, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var"'
small_slot_out="$(inspect_of /dev/sda 100 6144 <<<"$small_slot_dump")"
assert_contains 'verdict=refuse'   "$small_slot_out" "fixture: a root slot smaller than SLOT_MIB is verdict=refuse"
assert_contains 'reason=slot-size' "$small_slot_out" "fixture: ...reason=slot-size"

# usage error: 2, not 1 or a crash.
( inspect_of /dev/sda not-a-number 6144 <<<"$keep_dump" ) >/dev/null 2>&1
assert_eq "2" "$?" "inspect: a non-numeric ESP_MIB is a usage error (exit 2)"

# ---- disk.conf.in and the page: layoutHelper, and the checked signature (plan/33 §5) ---------
assert_true "modules/disk.conf.in also gains layoutHelper" \
    grep -qE '^layoutHelper:[[:space:]]+"/usr/libexec/@DISTRO_ID@-disk-layout"' \
        "$CAL/modules/disk.conf.in"
assert_true "the page calls inspectDisk() from enumerate()" \
    grep -q 'inspectDisk( e )' "$DISK_SRC/DiskConfig.cpp"
assert_true "...gated on a var-labelled lsblk child, the cheap pre-filter" \
    bash -c "sed -n '/^DiskConfig::enumerate/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -q 'hasVarPartition'"
assert_true "...and layoutHelper is read with Calamares::getString, not configNumber" \
    grep -q 'Calamares::getString( configurationMap, QStringLiteral( "layoutHelper" )' \
        "$DISK_SRC/DiskConfig.cpp"
# The configNumber call-site count stays at five (plan/24 §11) — a string key must never add a
# sixth. Re-asserted here beside the new key, not just in section 5, so the two cannot drift.
assert_eq "5" \
    "$(cat "$GREET_SRC/Requirements.cpp" "$DISK_SRC/DiskConfig.cpp" |
       grep -cE 'configNumber\( (configurationMap|requirements),')" \
    "adding layoutHelper did not move the five-call-site pin"
assert_true "the page publishes diskKeepData" \
    grep -q 'gs->insert( QStringLiteral( "diskKeepData" ), keeping() )' "$DISK_SRC/DiskConfig.cpp"
assert_false "no GPT type GUID reaches DiskConfig.cpp from inspectDisk()" \
    bash -c "sed -n '/^DiskConfig::inspectDisk/,/^}/p' '$DISK_SRC/DiskConfig.cpp' |
             grep -qiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'"

# ---- disksetup: the keep path (plan/33 §6) ----------------------------------------------------
assert_true "keep_disk() exists" grep -q '^def keep_disk' "$DISK_JOB"
KEEP_DISK_BODY="$(sed -n '/^def keep_disk/,/^def /p' "$DISK_JOB")"
# "write_table(device" — the real call SIGNATURE, with its first argument immediately after the
# paren — not the bare word, which the function's own docstring uses (in prose, with no argument)
# to explain that this path never calls it.
assert_false "the keep path never calls write_table()" \
    grep -qF 'write_table(device' <<<"$KEEP_DISK_BODY"
assert_false "...and never wipefs'es the whole device" \
    grep -qE 'wipefs.*\bdevice\b' <<<"$KEEP_DISK_BODY"
# _empty is relabelled BEFORE the slot — the spare may already carry the very label about to be
# written to the slot, and two partitions sharing one PARTLABEL is what plan/33 §2 exists to
# remove (see the module's own comment on keep_disk()). Exact call-site substrings, not the bare
# word "_empty" or "layout[\"slot\"]" — both appear a second time in this module's docstrings and
# in publish_partitions(), which would make either line number meaningless on its own.
spare_line="$(grep -nF 'str(layout["spare"]), "_empty"' "$DISK_JOB" | head -1 | cut -d: -f1)"
slot_line="$(grep -nF 'str(layout["slot"]), str(conf.get("rootPartLabel")' "$DISK_JOB" | head -1 | cut -d: -f1)"
assert_true "both relabel calls were found" test -n "$spare_line" -a -n "$slot_line"
assert_true "the spare is relabelled _empty before the slot gets the new root label" \
    bash -c "(( $spare_line < $slot_line ))"
assert_true "check_kept_files() runs e2fsck -p" \
    bash -c "sed -n '/^def check_kept_files/,/^def /p' '$DISK_JOB' | grep -q '\"e2fsck\", \"-p\"'"
assert_true "...and checks overlay/etc/upper" \
    bash -c "sed -n '/^def check_kept_files/,/^def /p' '$DISK_JOB' | grep -q '\"overlay\", \"etc\", \"upper\"'"
assert_true "...and checks lib/<distroId>" \
    bash -c "sed -n '/^def check_kept_files/,/^def /p' '$DISK_JOB' | grep -q '\"lib\", distro_id'"
assert_true "...mounted read-only" \
    bash -c "sed -n '/^def check_kept_files/,/^def /p' '$DISK_JOB' | grep -q '\"-o\", \"ro\"'"
assert_true "...and unmounted (and the scratch dir removed) in a finally" \
    bash -c "sed -n '/^def check_kept_files/,/^def /p' '$DISK_JOB' | grep -q 'finally:'"
assert_true "inspect_layout() dies loudly unless verdict is keep" \
    grep -q "cannot be kept" "$DISK_JOB"
assert_true "run() reads keep from diskKeepData" \
    grep -q 'keep = bool(libcalamares.globalstorage.value("diskKeepData"))' "$DISK_JOB"
assert_true "publish_partitions() is shared by both paths" \
    bash -c "grep -q 'esp, root_a, root_b, var = keep_disk' '$DISK_JOB' &&
             grep -q 'partitions = publish_partitions(esp, root_a, root_b, var, conf)' '$DISK_JOB'"
assert_true "disksetup.conf.in gains distroId" \
    grep -qE '^distroId:[[:space:]]+"@DISTRO_ID@"' "$REPO_ROOT/config/calamares/modules/disksetup.conf.in"
assert_true "...rendered" grep -qE "^distroId:[[:space:]]+\"$I_DISTRO_ID\"" "$DISKSETUP_CONF"

# ---- the jobs that stand down (plan/33 §7) -----------------------------------------------------
# `run()` is the LAST function in each of these files, so /^def run/,$ is its whole body.
for job in localesetup keyboardsetup imageidentity; do
    assert_true "$job reads diskKeepData in run()" \
        bash -c "sed -n '/^def run/,\$p' '$CAL/local-modules/$job/main.py' | grep -q 'diskKeepData'"
done
ACCOUNTSETUP_JOB="$REPO_ROOT/config/calamares/local-modules/accountsetup/main.py.in"
assert_true "accountsetup reads diskKeepData in run()" \
    bash -c "sed -n '/^def run/,\$p' '$ACCOUNTSETUP_JOB' | grep -q 'diskKeepData'"
assert_true "...and does nothing but the secrets-file unlink while keeping" \
    bash -c "sed -n '/^def run/,\$p' '$ACCOUNTSETUP_JOB' | grep -A2 'diskKeepData' | grep -q 'return None'"
assert_true "accountsetup's userdel on the live user is outside keep only" \
    bash -c "sed -n '/^def run/,\$p' '$ACCOUNTSETUP_JOB' | grep -q 'remove_live_user(root)'"
IMAGEDEPLOY_JOB="$CAL/local-modules/imagedeploy/main.py"
assert_true "imagedeploy reads diskKeepData too" grep -q 'diskKeepData' "$IMAGEDEPLOY_JOB"
assert_true "...and skips the var template extraction under it" \
    bash -c "sed -n '/seed \/var/,/---- 4\./p' '$IMAGEDEPLOY_JOB' | grep -q 'if keep:'"
assert_true "...and skips the early /etc/hostname write under it too" \
    bash -c "sed -n '/hostname, EARLY/,/---- 5\./p' '$IMAGEDEPLOY_JOB' | grep -q 'if keep:'"
assert_true "...the directory belt-and-braces still runs unconditionally" \
    bash -c "! sed -n '/Belt and braces/,/chmod.*roothome/p' '$IMAGEDEPLOY_JOB' | grep -q 'if keep'"

# imagebootloader: the NVRAM dedup applies in both modes, by PARTUUID, not by reading diskKeepData
# at all — see scripts/run-vm.sh's note and the module's own header on why.
BOOTLOADER_JOB="$CAL/local-modules/imagebootloader/main.py"
assert_true "imagebootloader skips a duplicate NVRAM entry by PARTUUID" \
    bash -c "grep -q 'def blkid_partuuid' '$BOOTLOADER_JOB' && grep -q 'def existing_boot_entry' '$BOOTLOADER_JOB'"

# ---- the pages after the disk (plan/33 §8) ------------------------------------------------------
assert_true "AccountsViewStep::onActivate() reads diskKeepData" \
    grep -q 'gs->value( QStringLiteral( "diskKeepData" ) ).toBool()' "$OVL_ACCOUNTS/files/AccountsViewStep.cpp"
assert_true "...into AccountsConfig::setKeeping()" \
    grep -q 'm_config->setKeeping(' "$OVL_ACCOUNTS/files/AccountsViewStep.cpp"
assert_true "AccountsConfig::publish() writes accountsMode \"kept\" while keeping" \
    grep -q 'QStringLiteral( "accountsMode" ), QStringLiteral( "kept" )' "$OVL_ACCOUNTS/files/AccountsConfig.cpp"
assert_true "...and clears every identity key" \
    bash -c "sed -n '/^AccountsConfig::publish/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -c 'QString()\|QStringList()\|false' | grep -qE '^(1[0-9]|[2-9][0-9])\$'"
assert_true "...and deletes any secrets file an earlier forward pass left" \
    bash -c "sed -n '/^AccountsConfig::publish/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -q 'QFile::remove( m_secretsPath )'"
assert_true "keeping() releases a live managed enrolment, the same path leaving managed mode takes" \
    bash -c "sed -n '/^AccountsConfig::setKeeping/,/^}/p' '$OVL_ACCOUNTS/files/AccountsConfig.cpp' |
             grep -q 'releaseEnrolment()'"
assert_true "the pager's isAtBeginning/isAtEnd both read keeping()" \
    bash -c "grep -q 'm_config->keeping() || m_config->onChooser()' '$OVL_ACCOUNTS/files/AccountsViewStep.cpp' &&
             grep -q 'm_config->keeping() ||' '$OVL_ACCOUNTS/files/AccountsViewStep.cpp'"
assert_true "Accounts.qml draws a kept block and hides the chooser/fields under it" \
    bash -c "grep -q 'visible: accounts.keeping' '$ACCOUNTS_QML' &&
             grep -q 'visible: accounts.onChooser && !accounts.keeping' '$ACCOUNTS_QML' &&
             grep -q 'visible: accounts.onFields && !accounts.keeping' '$ACCOUNTS_QML'"

REVIEW_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-review/files"
assert_false "the review page never reads the never-published 'device' key" \
    grep -q '"device"' "$REVIEW_SRC/ReviewConfig.cpp"
assert_true "...it reads diskDevice, which DiskConfig::publish() actually writes" \
    grep -q '"diskDevice"' "$REVIEW_SRC/ReviewConfig.cpp"
assert_true "...and diskKeepData, cached as the page's own keeping property" \
    grep -q '"diskKeepData"' "$REVIEW_SRC/ReviewConfig.cpp"
assert_true "eraseTitle/eraseBody both branch on keeping" \
    bash -c "sed -n '/^ReviewConfig::eraseTitle/,/^}/p' '$REVIEW_SRC/ReviewConfig.cpp' | grep -q 'm_keeping' &&
             sed -n '/^ReviewConfig::eraseBody/,/^}/p' '$REVIEW_SRC/ReviewConfig.cpp' | grep -q 'm_keeping'"
assert_true "Review.qml's panel takes the warning tone while keeping" \
    grep -q 'review.keeping ? ds.statusWarningBg : ds.statusDangerBg' "$REVIEW_SRC/qml/Review.qml"

DONE_SRC="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-done/files"
assert_true "the finish page reads diskKeepData in collect()" \
    grep -q '"diskKeepData"' "$DONE_SRC/DoneConfig.cpp"
assert_true "...and pageTitle/pageLede both branch on it" \
    bash -c "sed -n '/^DoneConfig::pageTitle/,/^}/p' '$DONE_SRC/DoneConfig.cpp' | grep -q 'm_keeping' &&
             sed -n '/^DoneConfig::pageLede/,/^}/p' '$DONE_SRC/DoneConfig.cpp' | grep -q 'm_keeping'"

# The three rows that say "Kept as it is on this computer" — language, location, keyboard. Each
# page's answer configures the installer session only while keeping (plan/33 §1), so its summary
# row must say so rather than name a setting that will not be applied.
for pair in language:LanguageConfig location:LocationConfig keymap:KeymapConfig; do
    mod="${pair%%:*}"; cls="${pair#*:}"
    src="$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-$mod/files/$cls.cpp"
    assert_true "$mod's prettyStatus() reads diskKeepData" \
        bash -c "sed -n '/^$cls::prettyStatus/,/^}/p' '$src' | grep -q 'diskKeepData'"
    assert_true "...and says 'Kept as it is on this computer'" \
        bash -c "sed -n '/^$cls::prettyStatus/,/^}/p' '$src' | grep -q 'Kept as it is on this computer'"
done

# ---- 7. YAML is YAML ------------------------------------------------------------------------
# Calamares parses these with yaml-cpp and reports a parse error as a startup failure, so a
# stray tab is a medium that does not install. Skipped rather than failed where PyYAML is absent,
# the same way the splash test treats rsvg-convert.
if python3 -c 'import yaml' 2>/dev/null; then
    while IFS= read -r -d '' f; do
        assert_true "${f#"$RENDER"/} is valid YAML" \
            python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f"
    done < <(find "$RENDER" \( -name '*.conf' -o -name '*.desc' \) -type f -print0)
else
    echo "  (PyYAML absent — skipping the YAML parse pass)"
fi

# ---- 8. the tail stays on the medium --------------------------------------------------------
# @installer must be named by exactly one profile, and that profile must be live. This is the
# set-level half of the guarantee test-profiles.sh asserts at the package level.
installer_users=(); live_users=()
while IFS= read -r p; do
    sets="$( BUILD_PROFILE_OVERRIDE="$p"; load_config >/dev/null 2>&1; printf '%s' "$PROFILE_SETS" )"
    role="$(sed -nE 's/^[[:space:]]*PROFILE_ROLE="?([a-z]+)"?.*/\1/p' \
              "$REPO_ROOT/config/profiles/$p.conf" | tail -n1)"
    if [[ " $sets " == *" installer "* ]]; then
        installer_users+=("$p")
        [[ $role == live ]] && live_users+=("$p")
    fi
done < <(profile_list)
assert_eq "1" "${#installer_users[@]}" "exactly one profile emerges @installer"
assert_eq "${#installer_users[@]}" "${#live_users[@]}" \
    "every profile that emerges @installer is a live profile"

# The set names seven atoms: Calamares, the five view modules this project plugs into it — the
# accounts page (plan/21), the language page (plan/22), the greeting page (plan/23), the disk page
# (plan/24) and the applications page (plan/25) — and one typeface. Everything else in the
# ~25-package tail is resolved, and a set that starts listing transitive deps stops describing
# intent.
#
# The count is asserted rather than the names, and it is a NUMBER on purpose: adding an atom here is
# exactly the change that should have to be argued for in a diff, because @installer is the one set
# whose contents the product image is forbidden to contain. The fourth was argued in plan/23 and was
# a SPLIT of the third rather than new weight. The fifth is argued in plan/24 and is a REPLACEMENT:
# it takes a stock module out of the sequence rather than adding a page, and it drops this
# installer's last use of KPMcore with it. The sixth is argued in plan/25 and is the first that
# replaces NOTHING — a new question, with no stock module that ever asked it. The seventh is
# argued in plan/28 and is the first that is not a module at all: media-fonts/ibm-plex, because
# the pages set their type by family NAME and a name fontconfig cannot resolve is substituted
# silently — the installer renders, and simply stops looking like the design system. The last
# four are plan/28 §6, and they are the end of the argument rather than four more of it: with
# `location`, `keymap`, `review` and `done` in the set, NO PAGE IN THE SEQUENCE IS UPSTREAM'S.
assert_eq "11" "$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/config/portage/sets/installer")" \
    "@installer names exactly eleven atoms"
assert_true "...one of which is the typeface the pages name" \
    grep -qx 'media-fonts/ibm-plex' "$REPO_ROOT/config/portage/sets/installer"
# ...and every page in the show sequence comes from one of them. This is the assertion that says
# "no stock pages left" in a way a future edit cannot quietly undo: a step added to settings.conf
# without a module behind it in @installer is a step Calamares drops in silence.
assert_true "every page in the sequence is a module this project builds" \
    bash -c "
      seq=\$(sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      seq=\"\$seq \$(sed -n '/^- exec:/,\$p' '$SETTINGS' | sed -n '/^- show:/,\$p' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')\"
      missing=
      for page in \$seq; do
        grep -qx \"distro-base/distro-calamares-\$page\" '$REPO_ROOT/config/portage/sets/installer' || missing=\"\$missing \$page\"
      done
      [[ -z \$missing ]] || { echo \"pages with no module in @installer:\$missing\"; false; }"
for atom in app-admin/calamares distro-base/distro-calamares-accounts \
            distro-base/distro-calamares-greeting distro-base/distro-calamares-language \
            distro-base/distro-calamares-disk distro-base/distro-calamares-apps; do
    assert_true "@installer names $atom" \
        grep -qxF "$atom" "$REPO_ROOT/config/portage/sets/installer"
done
assert_true "@installer names the accounts view module from the overlay" \
    grep -qx 'distro-base/distro-calamares-accounts' "$REPO_ROOT/config/portage/sets/installer"
assert_true "@installer names app-admin/calamares" \
    grep -qx 'app-admin/calamares' "$REPO_ROOT/config/portage/sets/installer"

# The keyword exception is mandatory (both stable revisions cap at python3_13 and this image is
# on 3.14) — but it must stay scoped to the one package.
assert_true "app-admin/calamares carries a ~amd64 exception" \
    grep -qE '^app-admin/calamares[[:space:]]+~amd64' "$REPO_ROOT/config/portage/package.accept_keywords/image"

# A live profile must never reach the release layout. The release directory IS the update
# channel: sysupdate's 50-rootfs.transfer claims any <id>_@v.root.erofs.zst there, so an
# installer root published beside the product one would be offered to installed machines as the
# next version — carrying Calamares, GRUB and os-prober with it. Nothing else catches this,
# because stage 50's audit gate is per-profile and the installer's own file legitimately lists
# the whole tail.
assert_true "stage 80 gates the release on PROFILE_ROLE" \
    grep -q 'PROFILE_ROLE != target' "$REPO_ROOT/scripts/stages/80-release.sh"
# ...and it must SKIP rather than die: `build.sh --profile installer` runs the whole pipeline, and
# a medium that built correctly should not end in a red error for declining to do something it was
# never supposed to do.
assert_true "stage 80 skips a live profile rather than failing the build" \
    grep -q 'exit 0' "$REPO_ROOT/scripts/stages/80-release.sh"
# The gate must come BEFORE anything is written into the release directory.
assert_true "the role gate precedes the release directory being created" \
    bash -c 'gate=$(grep -n "PROFILE_ROLE != target" "$1" | cut -d: -f1)
             mkdir=$(grep -n "ensure_dir .*RELEASE_DIR" "$1" | head -1 | cut -d: -f1)
             [ -n "$gate" ] && [ -n "$mkdir" ] && [ "$gate" -lt "$mkdir" ]' _ \
    "$REPO_ROOT/scripts/stages/80-release.sh"

# ---- 9. the password dictionary --------------------------------------------------------------
# accounts.conf hands every password to libpwquality — the accounts page calls pwquality_check()
# with these options itself (plan/21 §2), where Calamares' stock users page used to — and
# libpwquality's dictionary check is not optional: dev-libs/libpwquality RDEPENDs on
# sys-libs/cracklib unconditionally, there is no USE flag that drops it and no config key that
# turns it off. cracklib compiles that dictionary
# in pkg_postinst behind `if [[ -z ${ROOT} ]]` — so it runs for a merge into the live root and
# never for the ROOT=$TARGET merges stage 30 does. Left alone the image carries the raw word list
# at /usr/share/dict/cracklib-small and nothing at all at /usr/lib/cracklib_dict.
#
# What that ships is a medium that boots, autologins, starts Calamares with its branding, and
# then rejects EVERY password on the accounts page with "The password fails the dictionary check -
# error loading dictionary". No password is strong enough to pass a dictionary that will not load,
# so Next never enables and the medium cannot install anything at all. (It is worse than it was
# before plan/21 and also caught sooner: the page is now BEFORE the disk step rather than after
# it.) It is the fourth member of this file's family of failures and nothing else
# sees it: stage 70 reads a serial port, and the package audits are all satisfied (cracklib IS
# installed — it is its postinst that did not run).
assert_true "accounts.conf routes passwords through libpwquality" \
    grep -qE '^[[:space:]]*libpwquality:' "$ACCOUNTS_CONF"
# ...and names no dictpath of its own, which is what leaves cracklib's compiled-in default
# (/usr/lib/cracklib_dict, from the ebuild's --with-default-dict) as the only path it will open.
assert_false "accounts.conf sets no dictpath, so the compiled-in default is the one that matters" \
    grep -q 'dictpath' "$ACCOUNTS_CONF"
# The page is what reads those options now, so the code that does it is part of this contract.
assert_true "the accounts page calls pwquality_check() with accounts.conf's options" \
    bash -c "grep -q 'pwquality_check' '$OVL_ACCOUNTS/files/PasswordCheck.cpp' &&
             grep -q 'pwquality_set_option' '$OVL_ACCOUNTS/files/PasswordCheck.cpp'"
assert_true "stage 40 builds the dictionary cracklib's pkg_postinst never got to build" \
    grep -q 'create-cracklib-dict -o /usr/lib/cracklib_dict' "$REPO_ROOT/scripts/stages/40-configure.sh"
# All three files: cracklib opens .pwi (the index) and .hwm (the bucket high-water marks)
# alongside .pwd, so a readback on the word data alone would pass a half-written dictionary.
assert_true "stage 40 reads all three dictionary files back before the medium is built" \
    grep -q 'for cl_ext in pwd pwi hwm' "$REPO_ROOT/scripts/stages/40-configure.sh"
# The dictionary lands in /usr/lib at maxdepth 1, which is exactly what stage 50 section 3d
# sweeps. 3d deletes by file content (ELFCLASS32 or a GNU ld script) so it is safe today; the
# assertion is what makes a future rewrite of that sweep fail loudly instead of silently.
assert_true "stage 50 asserts the dictionary survived the prune" \
    grep -q 'cracklib_dict' "$REPO_ROOT/scripts/stages/50-prune.sh"

# ---- 10. the live session's own ergonomics --------------------------------------------------
# config/calamares/system/ is not Calamares configuration at all: it is what makes a medium whose
# account password is published usable without ever typing it. Each file is installed by stage 40
# for this profile only, and each would be wrong on a product image — a security regression for
# the three here, a Plasma panel pinning an installer nobody installed for the two in section 11
# — so both halves are asserted: the file says what it should, and stage 40 both writes it on the
# medium and refuses to let it exist anywhere else.
LOCKRC="$RENDER/system/kscreenlockerrc"
assert_file "$LOCKRC" "the live session's kscreenlockerrc rendered"
# TWO groups now, and that is exactly why this needs a parser rather than a grep. The file used
# to have one, so "is the key in the right section?" was free; since the greeter's wallpaper
# joined it (plan/20 §2.1, the medium's one wallpaper) a RequirePassword that drifted below the
# [Greeter] header would still grep clean and mean nothing at all — kscreenlocker reads
# RequirePassword from [Daemon] and nowhere else.
lockrc_group_of() {  # key -> the [Group] header it sits under
    awk -v k="$1" '/^\[/ { g = $0 } $0 ~ "^" k "=" { print g; exit }' "$LOCKRC"
}
assert_eq "[Daemon]
[Greeter][Wallpaper][org.kde.image][General]" "$(grep '^\[' "$LOCKRC")" \
    "kscreenlockerrc declares exactly two groups"
assert_true "...and turns RequirePassword off" \
    grep -qx 'RequirePassword=false' "$LOCKRC"
assert_eq "[Daemon]" "$(lockrc_group_of RequirePassword)" \
    "...in [Daemon], which is the only group kscreenlocker reads it from"
# The greeter's wallpaper. Its group name is four levels deep because greeterapp.cpp builds it
# that way — KScreenSaverSettingsBase -> "Greeter" -> "Wallpaper" -> wallpaperPluginId() — and
# then hands it to a KConfigLoader driven by org.kde.image's main.xml, whose only group is
# "General". Get any level wrong and the key is silently ignored.
assert_eq "[Greeter][Wallpaper][org.kde.image][General]" "$(lockrc_group_of Image)" \
    "the greeter's wallpaper is in the four-level group kscreenlocker actually reads"
assert_true "...and names the one wallpaper package this medium carries" \
    grep -qx "Image=/usr/share/wallpapers/$I_DISTRO_ID/" "$LOCKRC"
# An absolute path to the DIRECTORY, not the package id: MediaProxy::setSource() runs this value
# through QUrl::fromUserInput(), which turns a bare id into an http:// URL and not a wallpaper.
assert_false "...as a path, not as a bare package id" \
    grep -qx "Image=$I_DISTRO_ID" "$LOCKRC"
# Autolock is left alone on purpose (the shield still engages, it just does not prompt). Asserted
# so that turning it off later is a deliberate edit here rather than a quiet one there.
assert_false "kscreenlockerrc does not also disable Autolock" \
    grep -q '^Autolock=' "$LOCKRC"

STAGE40="$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 installs kscreenlockerrc into /etc/xdg on the medium" \
    grep -qF 'cal_install "$CAL_SRC/system/kscreenlockerrc.in" "$TARGET/etc/xdg/kscreenlockerrc"' "$STAGE40"
assert_true "...and reads the key back out of the target before building the medium" \
    grep -qF "grep -qx 'RequirePassword=false'" "$STAGE40"
# ---- 11. the panel pins the installer and nothing else --------------------------------------
# The medium runs one program, so its task manager pins one program. Left alone it pins four and
# none of them is that one: the Icons-Only Task Manager's launchers come from a KConfigXT default
# (plasma-desktop applets/taskmanager/main.xml) of System Settings, Discover, a file manager and
# preferred://browser — an app store on a stick that is discarded in twenty minutes, and a
# browser that is not installed at all here, because this profile sets FLATPAK_PREINSTALL="" and
# Firefox travels in the payload.
#
# The failure this section guards is not "the wrong icons": it is that a KConfigXT default cannot
# be beaten by a config file, so the FIX is a layout script run once at first login — and a
# layout script that does not run, does not parse, or is not the one plasmashell reaches for
# leaves the live session with the stock four, or with no panel at all. There is no second login
# to correct it on a medium that autologins once and is thrown away.
LNF="$RENDER/system/lookandfeel"
LAYOUT="$LNF/contents/layouts/org.kde.plasma.desktop-layout.js"
assert_file "$LAYOUT" "the Plasma layout script that is this directory's entire point"
# ONE Look-and-Feel package per image, and this directory is not it. The layout goes INTO the
# splash package config/plasma builds (plan/17), because /etc/xdg/kdeglobals can name exactly one
# package and startplasma turns that id into ~/.config/kdedefaults/ksplashrc before the session
# starts — so a second package here, named by kdeglobals and carrying no contents/splash, is a
# medium that boots to Breeze with every config file in it saying otherwise. That is not a
# hypothetical: it shipped, and a descriptor reappearing here would bring it straight back by
# overwriting the one config/plasma rendered.
assert_false "this directory ships no descriptor of its own" \
    test -e "$LNF/metadata.json"
assert_eq "1" "$(find "$LNF" -type f | wc -l)" \
    "...and nothing but the layout script, which is copied into the splash package"

# The two halves of the hook, either of which is useless alone: kdeglobals names the package, and
# the package is where ShellCorona::loadDefaultLayout() looks for the script. Both come from
# config/plasma now, on every profile with a desktop rather than on this one.
PLASMA_SRC="$REPO_ROOT/config/plasma"
KDEGLOBALS="$TMP/kdeglobals"
assert_true "the image's kdeglobals renders" \
    bash -c "( set -e
               export REPO='$REPO_ROOT' WORK='$TMP/w' OUT='$TMP/o' STAGE_NAME=t BUILD_PROFILE_OVERRIDE=installer
               source '$REPO_ROOT/scripts/lib/common.sh'; load_config
               render_template '$PLASMA_SRC/kdeglobals.in' '$KDEGLOBALS' )"
assert_eq "[KDE]" "$(grep '^\[' "$KDEGLOBALS")" "kdeglobals declares exactly one group, [KDE]"
assert_true "...and points LookAndFeelPackage at the image's own package, not an installer one" \
    grep -qx "LookAndFeelPackage=$I_DISTRO_ID" "$KDEGLOBALS"
# KPackage compares the descriptor's id against the directory it loaded from, and uses the
# comparison to decide whether Breeze becomes the fallback package. Same silent-skip shape as a
# module.desc whose name is not its directory's, asserted the same way.
assert_true "the descriptor's plugin id is the directory kdeglobals names" \
    grep -qF "\"Id\": \"@DISTRO_ID@\"" "$PLASMA_SRC/lookandfeel/metadata.json.in"
# A layout script that does not parse is a live session with NO PANEL — plasmashell logs the
# parse error and moves on, and there is no second login on this medium to fix it. Checked with
# node when the box has one; this suite stays dependency-free, so the alternative is not checking
# it here at all. The engine that actually runs the file is QJSEngine, which is why the script is
# written in plain ES5 that both accept.
if command -v node >/dev/null 2>&1; then
    assert_true "the layout script parses as JavaScript" node --check "$LAYOUT"
else
    echo "  (node absent — skipping the layout script's parse check)"
fi

# The pin itself, and the one string it turns on: app-admin/calamares's own menu entry, which is
# in /usr/share/applications where KService can resolve it. Our /etc/xdg/autostart copy is not,
# and would resolve to nothing.
assert_true "the layout pins applications:calamares.desktop on the task manager" \
    grep -qF 'writeConfig("launchers", ["applications:calamares.desktop"])' "$LAYOUT"
# ONE pin. The whole request is that nothing else is pinned, and the cheapest way to catch a
# second one creeping in is to count the launcher URLs the script contains. Counted over the code
# with the comments stripped, because the comments quote the stock defaults this replaces.
LAYOUT_CODE="$TMP/layout-code.js"
grep -v '^[[:space:]]*//' "$LAYOUT" > "$LAYOUT_CODE"
assert_eq "1" "$(grep -oF 'applications:' "$LAYOUT_CODE" | wc -l)" \
    "exactly one launcher is written — no other application is pinned"
assert_false "the layout pins none of Plasma's stock four" \
    grep -qE 'systemsettings\.desktop|org\.kde\.discover|preferred://' "$LAYOUT_CODE"
# The panel has to exist before anything can be pinned to it, and loadTemplate() is what builds
# it. It also keeps the panel upstream's by reference rather than by copy.
assert_true "the layout builds the panel from upstream's template" \
    grep -qF 'loadTemplate("org.kde.plasma.desktop.defaultPanel")' "$LAYOUT"
# Breeze's own layout sets this and ours replaces Breeze's, so dropping it would leave the
# desktop containment with no wallpaper plugin at all.
#
# org.kde.image AND the image, in the same loop, because on this medium neither half means
# anything alone: /usr/share/wallpapers holds exactly one package after stage 50 section 3i
# (plan/20 — the collection is `#not-live` in the set and Breeze's own `Next` is deleted), and
# org.kde.image that does not name it falls back through
# DefaultWallpaper::defaultWallpaperPackage() to `Next`, which is the thing that is gone.
#
# Asserted against the comment-stripped copy, because the comments above these lines quote both
# the plugin ids and the path, and a plain grep over the file would pass on the explanation alone.
assert_true "...and selects the image wallpaper plugin" \
    grep -qF "wallpaperPlugin = 'org.kde.image'" "$LAYOUT_CODE"
assert_true "...and names the one wallpaper package this medium carries" \
    grep -qF "writeConfig('Image', '/usr/share/wallpapers/$I_DISTRO_ID/')" "$LAYOUT_CODE"
# The config group has to be the wallpaper's, not the containment's own. Applet::writeConfig
# treats ["Wallpaper", ...] specially (applet.cpp: inWallpaperConfig), and a group path that
# misses it writes a key nothing ever reads.
assert_true "...into the wallpaper plugin's own config group" \
    grep -qF "currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General']" "$LAYOUT_CODE"
# The solid-colour plugin was this medium's answer until it had a wallpaper of its own. Asserted
# as absent so that a revert has to be deliberate: with both lines present the last write wins
# and which one that is depends on statement order.
assert_false "...and no longer falls back to the solid-colour plugin" \
    grep -qF "wallpaperPlugin = 'org.kde.color'" "$LAYOUT_CODE"

# ---- wallpapers: 254.7 of 255.1 MiB the live medium does not carry (plan/20) ---------------
# Three halves now, which is one more than the design started with: the 216.8 MiB collection is
# dropped from the SET so it is never emerged and never reaches installer.lock; the 38.3 MiB
# Breeze ships as `Next` is deleted by stage 50, because breeze is also the widget style and the
# look-and-feel fallback and cannot be dropped as a package; and 0.4 MiB of this distro's own
# artwork is installed by stage 40 and deliberately survives the deletion, so that org.kde.image
# has something to draw.
DESKTOP_SET="$REPO_ROOT/config/portage/sets/desktop"
STAGE50="$REPO_ROOT/scripts/stages/50-prune.sh"
assert_true "@desktop marks the wallpaper collection #not-live" \
    grep -qE '^kde-plasma/plasma-workspace-wallpapers\s+#not-live$' "$DESKTOP_SET"
# The deletion is defined by what SURVIVES, not by a list of what goes — a wallpaper arriving in
# the closure later (breeze picking up a second one, a dependency that ships artwork) is then
# dropped by default rather than kept by default. Asserted on that shape, not just on the effect.
assert_true "stage 50 prunes /usr/share/wallpapers to the distro's own package on a live profile" \
    grep -qF 'find "$T/usr/share/wallpapers" -mindepth 1 -maxdepth 1 ! -name "$DISTRO_ID"' "$STAGE50"
assert_false "...and no longer deletes the directory wholesale, which would take ours with it" \
    grep -qF 'rm -rf -- "$T/usr/share/wallpapers"' "$STAGE50"
# ...and only on a live one. This is the direction that would damage the PRODUCT, so it is
# asserted from the outside rather than trusted to the reader of the stage.
assert_true "...and the deletion is inside a PROFILE_ROLE == live guard" \
    grep -qF 'if [[ $PROFILE_ROLE == live ]]; then' "$STAGE50"
assert_true "...and the prune refuses a target image that lost Breeze's default wallpaper" \
    grep -qF 'usr/share/wallpapers/Next' "$STAGE50"
# Both directions on the live medium, because both are silent at runtime: a missing package is a
# blank desktop, and a surviving collection is the cost without the saving.
assert_true "...and refuses a live medium that lost the one wallpaper it does carry" \
    grep -qF 'usr/share/wallpapers/$DISTRO_ID is missing from a live medium' "$STAGE50"
assert_true "...and refuses one that still carries any other" \
    grep -qF 'wallpapers other than $DISTRO_ID survived the prune' "$STAGE50"

# The package itself. A Wallpaper/Images KPackage has exactly two requirements that fail silently
# — a descriptor id matching its directory, and an image whose BASENAME parses as <W>x<H> —
# and plasmashell reports neither: it draws an empty containment and logs nothing anyone reads.
WP_SRC="$CAL/system/wallpaper"
assert_file "$WP_SRC/metadata.json.in" "the live medium's wallpaper package has a descriptor"
assert_true "...whose id renders to the directory stage 40 installs it as" \
    grep -qF '"Id": "@DISTRO_ID@"' "$WP_SRC/metadata.json.in"
# findPreferredImageInPackage() selects on the basename (packagefinder.cpp, resSize) and skips
# every file that does not parse, so a wallpaper committed as `wallpaper.png` leaves the package
# valid, the entry list non-empty and the chosen image null.
assert_eq "1" "$(find "$WP_SRC/contents/images" -type f 2>/dev/null | wc -l)" \
    "...and exactly one image, since this medium's whole point is that there is only one"
assert_true "...named <width>x<height>, which is what Plasma selects on" \
    bash -c 'find "$1/contents/images" -type f -regextype posix-extended \
                  -regex ".*/[0-9]+x[0-9]+\.(png|jpg|jpeg|webp)" | grep -q .' _ "$WP_SRC"
assert_true "stage 40 installs it into /usr/share/wallpapers for this profile" \
    grep -qF 'WP_DIR="$TARGET/usr/share/wallpapers/$DISTRO_ID"' "$STAGE40"
assert_true "...and reads the descriptor's id back before the medium is built" \
    grep -qF 'does not declare Id \"$DISTRO_ID\"' "$STAGE40"
assert_true "...and refuses to build a medium whose layout does not name the package" \
    grep -qF "grep -qF \"'/usr/share/wallpapers/\$DISTRO_ID/'\"" "$STAGE40"
# The product is untouched: it keeps the collection, keeps Breeze's default, and does NOT get
# this package — a wallpaper the user cannot remove is a worse default than one they can. The
# guarantee is positional, so it is checked positionally: the install has to sit after stage 40's
# `if profile_has_set installer` guard, which is the same thing that keeps the polkit rule, the
# autostart entry and the layout script off every other image.
wp_line=$(grep -n 'WP_DIR="\$TARGET/usr/share/wallpapers' "$STAGE40" | head -1 | cut -d: -f1)
inst_line=$(grep -n '^if profile_has_set installer; then' "$STAGE40" | head -1 | cut -d: -f1)
assert_true "...inside stage 40's installer-only block, so no other profile installs it" \
    bash -c '[[ -n $1 && -n $2 && $1 -gt $2 ]]' _ "$wp_line" "$inst_line"
assert_true "desktop.lock still carries the wallpaper collection" \
    grep -qE '^=kde-plasma/plasma-workspace-wallpapers-' "$REPO_ROOT/config/portage/lock/desktop.lock"

# The two locks, from opposite directions. These are the assertions that actually catch a
# regression: everything above is about intent, and a lock is what a build emerges.
assert_false "installer.lock does not carry the wallpaper collection" \
    grep -qE '^=kde-plasma/plasma-workspace-wallpapers-' "$REPO_ROOT/config/portage/lock/installer.lock"
assert_true "...and desktop.lock still does — the product keeps its wallpapers" \
    grep -qE '^=kde-plasma/plasma-workspace-wallpapers-' "$REPO_ROOT/config/portage/lock/desktop.lock"
assert_false "installer.lock does not carry the managed System Settings module" \
    grep -qE "^=${I_DISTRO_ID}-base/${I_DISTRO_ID}-kcm-managed-" "$REPO_ROOT/config/portage/lock/installer.lock"
assert_true "...and desktop.lock still does" \
    grep -qE "^=${I_DISTRO_ID}-base/${I_DISTRO_ID}-kcm-managed-" "$REPO_ROOT/config/portage/lock/desktop.lock"
# The package audit has to agree with the lock, or stage 50 fails the build on drift rather
# than on the thing that drifted.
assert_false "expected-packages.installer.txt lists neither" \
    grep -qE "^(kde-plasma/plasma-workspace-wallpapers|${I_DISTRO_ID}-base/${I_DISTRO_ID}-kcm-managed)$" \
        "$REPO_ROOT/config/portage/expected-packages.installer.txt"
assert_true "...and expected-packages.desktop.txt lists both" \
    bash -c "grep -qx 'kde-plasma/plasma-workspace-wallpapers' '$REPO_ROOT/config/portage/expected-packages.desktop.txt' &&
             grep -qx '${I_DISTRO_ID}-base/${I_DISTRO_ID}-kcm-managed' '$REPO_ROOT/config/portage/expected-packages.desktop.txt'"

# ---- the managed-mode QML front end: the half no lock can see (plan/20 §2.2) ---------------
# Every assertion above this one reads a lock or an audit list, and for the KCM that is enough.
# For the front end it is not, and the gap is the bug it was written for: <id>-managed-ui is
# three files in config/rootfs, install_rootfs_overlay copies the whole tree onto every profile,
# and so a live medium showed "Managed Settings" in Kickoff while installer.lock,
# expected-packages.installer.txt and the KCM assertions above all correctly reported the module
# gone. Nothing that records what the image contains could see it.
#
# So these assert the removal and its two guards directly, by path. They are deliberately
# literal: the failure mode is a rename in config/rootfs leaving a removal that matches nothing,
# and a test that recomputed the paths the same way the stage does would rename right along with
# it and stay green.
assert_true "the overlay ships the managed front end unconditionally (so a profile must remove it)" \
    bash -c "[[ -f '$REPO_ROOT/config/rootfs/usr/bin/distro-managed-ui.in' &&
                -f '$REPO_ROOT/config/rootfs/usr/share/distro/managed-ui/main.qml.in' &&
                -f '$REPO_ROOT/config/rootfs/usr/share/applications/distro-managed-ui.desktop.in' ]]"
assert_true "...and its launcher entry is the 'Managed Settings' row a live medium must not show" \
    grep -qx 'Name=Managed Settings' \
        "$REPO_ROOT/config/rootfs/usr/share/applications/distro-managed-ui.desktop.in"
assert_true "stage 40 removes the wrapper and the launcher entry on live media" \
    grep -qF 'rm -f  -- "${TARGET:?}/usr/bin/${DISTRO_ID}-managed-ui"' "$STAGE40"
assert_true "...and the QML the wrapper opens" \
    grep -qF 'rm -rf -- "${TARGET:?}/usr/share/${DISTRO_ID}/managed-ui"' "$STAGE40"
# The removal is only correct if it is INSIDE a live-role guard: unguarded, it would take the
# front end off the product too, and the product is the one profile that needs it.
ui_rm_line=$(grep -n 'rm -rf -- "${TARGET:?}/usr/share/${DISTRO_ID}/managed-ui"' "$STAGE40" | head -1 | cut -d: -f1)
ui_guard_line=$(awk 'NR < '"$ui_rm_line"' && /^if \[\[ \$PROFILE_ROLE == live \]\]; then$/ { n = NR } END { print n }' "$STAGE40")
assert_true "...inside a PROFILE_ROLE=live guard, so the desktop profile keeps its front end" \
    bash -c '[[ -n $1 && -n $2 && $1 -lt $2 && $(( $2 - $1 )) -lt 12 ]]' _ "$ui_guard_line" "$ui_rm_line"
# Both stages assert the ABSENCE, because the removal itself is silent when it stops matching.
assert_true "stage 40 verifies the front end is gone from a live medium" \
    grep -qF 'the managed-mode front end is on a PROFILE_ROLE=$PROFILE_ROLE medium' "$STAGE40"
assert_true "stage 50 re-checks it after the prune, where nothing else would notice" \
    grep -qF 'the managed-mode front end survived onto a PROFILE_ROLE=$PROFILE_ROLE medium' "$STAGE50"
# The line this whole section draws: the CLI is not the front end and must stay, or the
# accounts page has nothing to exec — twice over, since plan/21. The PAGE runs it to enrol into a
# scratch root before the disk is written, and the JOB runs it again to apply the cached bundle
# into the target.
assert_false "...but the CLI itself is never removed — the accounts page and its job exec it" \
    grep -qE 'rm .*\$\{TARGET:\?\}/usr/bin/\$\{DISTRO_ID\}-managed"' "$STAGE40"
assert_true "...and accountsetup is what execs it from the live session" \
    grep -qF '"/usr/bin/%s-managed" % ID' \
        "$REPO_ROOT/config/calamares/local-modules/accountsetup/main.py.in"
assert_true "...as does the page, by the same path" \
    grep -qF '/usr/bin/%1-%2' "$OVL_ACCOUNTS/files/AccountsConfig.cpp"
# And the domain half, for the same reason: <id>-domain is what the job joins with now that the
# realm shim is gone, so a prune that removed it would break domain mode with nothing to say.
assert_true "the job joins through <id>-domain, not through a realm shim" \
    grep -qF '"/usr/bin/%s-domain" % ID' \
        "$REPO_ROOT/config/calamares/local-modules/accountsetup/main.py.in"
assert_false "...and no realm shim is left anywhere in the tree" \
    bash -c "[[ -e '$REPO_ROOT/config/calamares/system/realm.in' ]]"
assert_true "stage 40 asserts /usr/bin/realm is absent from the medium" \
    grep -qF 'usr/bin/realm is on the medium' "$STAGE40"

# ---- GRUB: 68.4 MiB of a bootloader this medium never runs (plan/20 §2.3) -------------------
# A file deletion, because sys-boot/grub is an unconditional RDEPEND of app-admin/calamares and
# keeps arriving. Nothing in the package audit can see this one, so these assertions and stage
# 50's are the only things standing between a renamed upstream path and 68 MiB coming back.
assert_true "stage 50 removes GRUB's platform modules and data" \
    grep -qF 'rm -rf -- "$T/usr/lib/grub" "$T/usr/share/grub" "$T/etc/grub.d"' "$STAGE50"
assert_true "...and its 27 tools, from /usr/bin only — /usr/sbin is a symlink to it" \
    grep -qF "find \"\$T/usr/bin\" -maxdepth 1 -name 'grub-*' -delete" "$STAGE50"
assert_true "...and fails the build if any GRUB path survives the prune" \
    grep -qF 'GRUB residue after prune' "$STAGE50"
# The half that matters more: the medium's REAL bootloader must outlive the deletion of its
# dead one. imagebootloader reads this file out of the mounted target, not out of the medium,
# but a prune that took it here is a prune that cut in the wrong direction.
assert_true "...and asserts systemd-boot survived the GRUB deletion" \
    grep -qF 'usr/lib/systemd/boot/efi/systemd-bootx64.efi' "$STAGE50"
# The claim the deletion rests on: the install goes through our module, never the stock one.
assert_true "the Calamares exec sequence names imagebootloader, not grub" \
    grep -qE '^\s+- imagebootloader$' "$CAL/settings.conf.in"
assert_false "...and never names the stock bootloader or grubcfg modules" \
    grep -qE '^\s+- (bootloader|grubcfg)$' "$CAL/settings.conf.in"

# ---- ghostscript and Spectacle: package removals, so the lock is the assertion --------------
PU_INSTALLER="$REPO_ROOT/config/portage/package.use/profile.installer"
assert_file "$PU_INSTALLER" "the installer-only package.use fragment exists"
assert_true "it turns off the PDF thumbnailer that drags in ghostscript" \
    grep -qE '^kde-apps/thumbnailers\s+-pdf$' "$PU_INSTALLER"
assert_true "@desktop marks Spectacle #not-live" \
    grep -qE '^kde-plasma/spectacle\s+#not-live$' "$DESKTOP_SET"
# Six packages from the ghostscript chain and three from Spectacle's. Asserted against the LOCK,
# because that is what a build emerges — the set and the USE flag are only the request.
for gone in app-text/ghostscript-gpl app-text/dvipsk dev-libs/kpathsea \
            media-fonts/arphicfonts media-fonts/urw-fonts media-gfx/kio-ps-thumbnailer \
            kde-plasma/spectacle media-libs/kquickimageeditor media-libs/opencv; do
    assert_false "installer.lock does not carry $gone" \
        grep -qE "^=${gone}-[0-9]" "$REPO_ROOT/config/portage/lock/installer.lock"
    assert_true "...and desktop.lock still does" \
        grep -qE "^=${gone}-[0-9]" "$REPO_ROOT/config/portage/lock/desktop.lock"
    assert_false "...and expected-packages.installer.txt does not list it" \
        grep -qx "$gone" "$REPO_ROOT/config/portage/expected-packages.installer.txt"
done
# app-text/poppler-data looks like it should survive and does not, which is worth pinning down
# because the first reading of this got it backwards. app-text/poppler names the atom, so a grep
# finds two consumers — but poppler's is `cjk? ( app-text/poppler-data )` and cjk is not in its
# default IUSE, while ghostscript's is unconditional. poppler stays (kfilemetadata needs it) and
# poppler-data goes with ghostscript. Nothing is lost: poppler is built -cjk and never read them.
assert_false "poppler-data goes with ghostscript — poppler's dep on it is cjk?, and cjk is off" \
    grep -qE '^=app-text/poppler-data-[0-9]' "$REPO_ROOT/config/portage/lock/installer.lock"
assert_true "...but poppler itself stays, for kde-frameworks/kfilemetadata" \
    grep -qE '^=app-text/poppler-[0-9]' "$REPO_ROOT/config/portage/lock/installer.lock"
# The orphan tail the resolver found and no hand-edit would have: dropping two named packages
# took nineteen. These are the ones that prove the lock was REGENERATED, not edited (plan/20 §2.7).
for orphan in dev-cpp/abseil-cpp dev-libs/protobuf dev-libs/flatbuffers dev-cpp/eigen \
              dev-qt/qtimageformats media-libs/libmng media-libs/jbig2dec net-dns/libidn; do
    assert_false "orphan dropped with its parent: $orphan" \
        grep -qE "^=${orphan}-[0-9]" "$REPO_ROOT/config/portage/lock/installer.lock"
done
# kde-apps/thumbnailers itself stays: only its pdf flag changed, and Dolphin still RDEPENDs it.
assert_true "kde-apps/thumbnailers itself stays — only the pdf flag moved" \
    grep -qE '^=kde-apps/thumbnailers-[0-9]' "$REPO_ROOT/config/portage/lock/installer.lock"

# ---- Discover: an app store on a stick that is discarded (plan/20 §4.3) ---------------------
# A set marker, so the lock and the audit are the assertions — the same shape as Spectacle above,
# and the reason that shape is preferred: the atom leaves installer.lock, so what the image IS
# and what the audit SAYS cannot drift.
assert_true "@desktop marks Discover #not-live" \
    grep -qE '^kde-plasma/discover\s+#not-live$' "$DESKTOP_SET"
assert_false "installer.lock does not carry Discover" \
    grep -qE '^=kde-plasma/discover-[0-9]' "$REPO_ROOT/config/portage/lock/installer.lock"
assert_true "...and desktop.lock still does — a machine somebody owns gets an app store" \
    grep -qE '^=kde-plasma/discover-[0-9]' "$REPO_ROOT/config/portage/lock/desktop.lock"
assert_false "...and expected-packages.installer.txt does not list it" \
    grep -qx 'kde-plasma/discover' "$REPO_ROOT/config/portage/expected-packages.installer.txt"
assert_true "...while expected-packages.desktop.txt does" \
    grep -qx 'kde-plasma/discover' "$REPO_ROOT/config/portage/expected-packages.desktop.txt"
# The USE line stays where it is. It is in package.use/image, which every profile reads, and that
# is correct: USE is resolved per package, the flags are for the profile that still HAS Discover,
# and moving them to profile.installer would say the opposite of what is meant.
assert_true "Discover's USE flags stay in the shared package.use, for the profile that keeps it" \
    grep -qE '^kde-plasma/discover\s' "$REPO_ROOT/config/portage/package.use/image"
# The panel is a separate mechanism and is NOT made redundant by the package going away: KService
# drops an unresolvable launcher silently, so without the rewrite the medium's panel would come
# up with the two stock pins that DO resolve and still not the installer.
assert_true "the layout script still rewrites the stock pins rather than relying on the removal" \
    grep -qF 'writeConfig("launchers"' "$LAYOUT_CODE"

# ---- the Emoji Selector: a file deletion, because plasma-desktop is not droppable -----------
# 0.4 MiB, and not a size change — it is section 3g's argument (a tool with no audience on this
# image) applied to a medium whose whole session is one installer. Nothing in the package audit
# can see this one, so these assertions and stage 50's are all there is.
assert_true "stage 50 removes the Emoji Selector's menu entry" \
    grep -qF '"$T/usr/share/applications/org.kde.plasma.emojier.desktop"' "$STAGE50"
# BOTH descriptors: /usr/share/applications is what Kickoff lists, /usr/share/kglobalaccel is the
# global-shortcut registration. Deleting one leaves the feature half present.
assert_true "...and its global-shortcut descriptor, not just the launcher" \
    grep -qF '"$T/usr/share/kglobalaccel/org.kde.plasma.emojier.desktop"' "$STAGE50"
assert_true "...and the binary behind them" \
    grep -qF '"$T/usr/bin/plasma-emojier"' "$STAGE50"
assert_true "...and the QML plugin, which nothing else in the target imports" \
    grep -qF '"$T/usr/lib64/qt6/qml/org/kde/plasma/emoji"' "$STAGE50"
assert_true "...and fails the build if any of those paths stops matching" \
    grep -qF 'the Emoji Selector survived the prune' "$STAGE50"
# Live media only, like sections 3i and 3j: the product keeps it. An emoji picker is worth
# nothing on a stick with nowhere to paste into and is ordinary on a machine somebody owns.
assert_true "...on live media only, so the product keeps it" \
    bash -c 'awk "/^# ---- 3k[.]/,/^# ---- 4[.]/" "$1" | grep -qF "PROFILE_ROLE == live"' \
    _ "$STAGE50"
# media-fonts/noto-emoji is NOT touched and must not be. It is the font that renders emoji the
# INSTALLER ITSELF may have to draw — Calamares' welcome page is a language picker, and a
# translated string or a keyboard-layout name carrying an emoji renders as tofu without it.
assert_true "the emoji FONT stays in the set — it is what renders glyphs, not an app" \
    grep -qx 'media-fonts/noto-emoji' "$DESKTOP_SET"
assert_true "...and in installer.lock" \
    grep -qE '^=media-fonts/noto-emoji-[0-9]' "$REPO_ROOT/config/portage/lock/installer.lock"

assert_true "stage 40 installs kdeglobals into /etc/xdg on every desktop profile" \
    grep -qF 'render_template "$PLASMA_SRC/kdeglobals.in" "$TARGET/etc/xdg/kdeglobals"' "$STAGE40"
assert_true "...and copies this layout into the package that already carries the splash" \
    grep -qF 'find "$CAL_SRC/system/lookandfeel" -type f -print0' "$STAGE40"
assert_true "...into LNF_DIR=the image's own package id, not a -installer one" \
    grep -qF 'LNF_ID="$DISTRO_ID"' "$STAGE40"
assert_true "...and refuses a package that lost either half" \
    grep -qF 'contents/splash/Splash.qml contents/layouts/org.kde.plasma.desktop-layout.js' "$STAGE40"
assert_true "...and reads the pin back out of the target before building the medium" \
    grep -qF 'writeConfig("launchers", ["applications:calamares.desktop"])' "$STAGE40"
assert_true "...and refuses a target whose calamares.desktop the pin could not resolve" \
    grep -qF 'usr/share/applications/calamares.desktop' "$STAGE40"

# The leak list, which is the only thing standing between these files and a product image: an
# entry there is quoted whole, so this matches the guard and not the install line above it.
for leaked in 'etc/xdg/kscreenlockerrc' \
              'usr/share/plasma/look-and-feel/$DISTRO_ID/contents/layouts' \
              'usr/share/wallpapers/$DISTRO_ID' \
              'etc/xdg/autostart/$DISTRO_ID-installer.desktop' \
              'etc/polkit-1/rules.d/49-$DISTRO_ID-installer.rules'; do
    assert_true "stage 40 refuses to let /$leaked reach a non-installer profile" \
        grep -qF "\"$leaked\"" "$STAGE40"
done

# ---- the live user and its autologin leave the root image (plan/34 §5) --------------------
# The build-time mechanism cannot run for real without a $TARGET, which this offline suite does
# not build — so, like the sections above, this checks that the SOURCE actually implements each
# step plan/34 §5 describes, not that a real build produces the right bytes (stage 40/60's own
# verify blocks, and the real build in the task's report, cover that).
STAGE60="$REPO_ROOT/scripts/stages/60-image.sh"
assert_true "stage 40 snapshots the six account files before touching them" \
    grep -qF 'LIVE_ACCT_FILES=(passwd shadow group gshadow subuid subgid)' "$STAGE40"
assert_true "...and moves the modified copies into the /etc overlay's upper" \
    grep -qF 'mv -f -- "$TARGET/etc/$_f" "$UPPER_ETC/$_f"' "$STAGE40"
assert_true "...and restores the pristine snapshot to the lower" \
    grep -qF 'mv -f -- "$LIVE_ACCT_SNAPSHOT/$_f" "$TARGET/etc/$_f"' "$STAGE40"
assert_true "stage 40 renders the autologin drop-in from config/live-seed, not config/rootfs" \
    grep -qF 'config/live-seed/plasmalogin.conf.d/10-autologin.conf.in' "$STAGE40"
assert_true "...into the upper, not the lower" \
    grep -qF 'render_template "$LIVE_SEED_AUTOLOGIN" "$UPPER_ETC/plasmalogin.conf.d/10-autologin.conf"' \
    "$STAGE40"
assert_true "stage 40 dies if \$LIVE_USER is still in the lower /etc/passwd" \
    grep -qF 'grep -qE "^$LIVE_USER:" "$TARGET/etc/passwd"' "$STAGE40"
assert_true "stage 40 dies if 10-autologin.conf is still in the lower" \
    grep -qF '[[ -e $TARGET/etc/plasmalogin.conf.d/10-autologin.conf ]]' "$STAGE40"
assert_true "stage 40's later pipewire-group check reads the upper, not a chroot id lookup" \
    grep -qF '"$UPPER_ETC/group"' "$STAGE40"

assert_true "stage 60 excludes the live seed from the var template tarball" \
    grep -qF '"./overlay/etc/upper/*"' "$STAGE60"
assert_true "...and the live user's home" \
    grep -qF '"./home/$LIVE_USER"' "$STAGE60"
assert_true "...and verifies neither made it into the packed tarball" \
    grep -qF 'overlay/etc/upper/.' "$STAGE60"
assert_true "stage 60 reads the BUILT var.img back with debugfs (loopless, plan/04)" \
    grep -qF 'debugfs -R "cat /overlay/etc/upper/passwd" "$VAR_IMG"' "$STAGE60"
assert_true "...and the BUILT root EROFS with dump.erofs" \
    grep -qF 'dump.erofs --cat --path=/etc/passwd "$ROOT_EROFS"' "$STAGE60"

# stage 50's rootless-podman check has to follow the same swap, or it greps a lower that was
# just restored to pristine and fails every build with INCLUDE_DISTROBOX=1 (found while making
# this change: it originally read "$T/etc/$f", which the live-user swap emptied of LIVE_USER).
assert_true "stage 50's subuid/subgid check reads the /etc overlay's upper, not the lower" \
    grep -qF '"$T/var/overlay/etc/upper/$f"' "$STAGE50"

finish
