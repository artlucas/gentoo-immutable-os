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
    else
        _fail "branding.desc names '$f', which is neither committed in config/calamares/branding/installer/ nor generated by stage 40 — Calamares would bail with \"Image file … does not exist\""
    fi
done

# THE SIDEBAR READS FROM THE LEFT (plan/26 §5). The widget flavour hard-codes centred step names
# in upstream's ProgressTreeDelegate — unreachable from branding — so the QML flavour is used and
# the branding component ships the sidebar QML itself (searchQmlFile looks in the branding
# directory before the compiled-in stock copy). Both halves are asserted: the flavour switched,
# and the shipped file is the left-aligned one.
assert_true "branding.desc switches the sidebar to QML" \
    grep -qE '^sidebar:[[:space:]]+qml$' "$BRAND"
assert_true "...and only the sidebar — the bottom bar stays widget" \
    grep -qE '^navigation:[[:space:]]+widget$' "$BRAND"
SIDEBAR_QML="$CAL/branding/installer/calamares-sidebar.qml"
assert_file "$SIDEBAR_QML" "the branding component carries its own calamares-sidebar.qml"
assert_true "...whose step text is left-aligned with a margin" \
    bash -c "grep -q 'anchors.left: parent.left' '$SIDEBAR_QML' &&
             grep -q 'anchors.leftMargin: 12' '$SIDEBAR_QML'"
assert_false "...and no step text is centred any more" \
    bash -c "sed -n '/Repeater {/,/^        }/p' '$SIDEBAR_QML' |
             grep -v '^[[:space:]]*//' | grep -q 'horizontalCenter'"
assert_true "...and the colours still come from the branding style, not the copy" \
    grep -q 'Branding.styleString' "$SIDEBAR_QML"
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
# SIX since plan/25, and the sixth is the first that replaces nothing: `appsetup` downloads what
# the applications page chose, and no stock module ever asked that question. The five before it
# are substitutions — disksetup took the exec half of the stock `partition` module when its page
# was replaced (a view step owns its jobs()), accountsetup replaced managedenroll AND the stock
# `users` module's jobs (plan/21), and imagedeploy, imagebootloader and imageidentity replaced
# unpackfs+mount, bootloader, and a pile of per-image fixups nothing stock covers.
(( ${#OURS[@]} == 6 )) || _fail "expected six local modules, found ${#OURS[@]}: ${OURS[*]}"
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
# is nothing that can honestly be pre-selected.
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
# THE ERROR GLUED TO ITS FIELD (plan/27 §6). A Kirigami.FormLayout gives every child its own row
# and its own gap, which put the red message a row — and the meter's row — away from the field it
# answered. Field and message now share one spacing-0 form row, the shape ComputerNameField has
# always had.
assert_true "the password field and its message share one spacing-0 form row" \
    bash -c "grep -A3 'Kirigami.FormData.label: accounts.passwordLabel' '$OVL_ACCOUNTS/files/qml/LocalForm.qml' |
             grep -qE '^[[:space:]]*spacing: 0$'"
assert_true "...and so do the repeat field and its mismatch message" \
    bash -c "grep -A3 'Kirigami.FormData.label: accounts.passwordRepeatLabel' '$OVL_ACCOUNTS/files/qml/LocalForm.qml' |
             grep -qE '^[[:space:]]*spacing: 0$'"

# PasswordField IS KIRIGAMI'S, AND THERE IS NO OTHER. QtQuick.Controls has no type of that name,
# so a `QQC2.PasswordField` is not a control with the wrong look — it is a type error, and the
# whole component tree fails to load with it. DomainForm instantiates unconditionally in
# Accounts.qml, so that one line took the entire page down: the QQuickWidget painted its clear
# colour, which is white, and the accounts page came up blank in every mode. The QML travels
# inside the .so as a resource and nothing compiles it at build time, so this reaches a VM
# untouched by the compiler that built the module around it — which is what this check is for.
assert_false "no QQC2.PasswordField: QtQuick.Controls has no such type" \
    grep -rq 'QQC2\.PasswordField' "$OVL_ACCOUNTS/files/qml"
assert_true "the domain form's three password fields are Kirigami's" \
    bash -c "[[ \$(grep -c 'Kirigami.PasswordField {' '$OVL_ACCOUNTS/files/qml/DomainForm.qml') -eq 3 ]]"

# The sequence must not name the stock modules that cannot work here. Each of these would fail
# or, worse, half-succeed: localecfg runs `locale-gen` in a target that has none; unpackfs looks
# for a squashfs; bootloader/grubcfg generate a GRUB config for a machine that boots a UKI;
# fstab writes a file that ships in the immutable image; machineid would give every machine
# installed from this medium the same one.
#
# TWO ENTRIES ON THIS LIST WOULD ACTUALLY WORK, and that is what makes them worth asserting: the
# rest fail loudly on a medium like this one, while these two would run and produce a second page
# each.
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
for forbidden in localecfg unpackfs fstab bootloader grubcfg initcpio initcpiocfg dracut \
                 initramfs machineid packages netinstall displaymanager mount users welcome \
                 partition; do
    assert_false "the sequence does not name the stock '$forbidden' module" \
        grep -qE "^[[:space:]]*-[[:space:]]+$forbidden$" "$SETTINGS"
done
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
assert_true "the applications page comes after accounts and before summary" \
    bash -c "
      seq=\$(sed -n '/^- show:/,/^- exec:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx accounts) -lt \$(idx apps) ]] &&
      [[ \$(idx apps) -lt \$(idx summary) ]]"
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
# /etc overlay — every write below depends on it) and BEFORE removeuser and imageidentity, which
# delete the live user and read `username` out of GlobalStorage to allocate its subuid range.
assert_true "accountsetup runs after imagedeploy and before removeuser and imageidentity" \
    bash -c "
      seq=\$(sed -n '/^- exec:/,/^- show:/p' '$SETTINGS' | sed -nE 's/^[[:space:]]*-[[:space:]]+([a-z][a-z0-9_-]*)\$/\\1/p')
      idx() { printf '%s\\n' \"\$seq\" | grep -nxF \"\$1\" | cut -d: -f1; }
      [[ \$(idx imagedeploy) -lt \$(idx accountsetup) ]] &&
      [[ \$(idx accountsetup) -lt \$(idx removeuser) ]] &&
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
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-apps/files"

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
#   - the highlight is `ListView.isCurrentItem`, so it follows the VIEW's currentIndex. A delegate
#     whose onClicked wrote straight to `language.currentIndex` changed the language — the window
#     really did retranslate — and left the highlight where the keyboard had put it. The first row
#     therefore looked selected no matter which one you clicked.
#   - QQuickItemView::componentComplete() selects row 0 for itself unless currentIndex was
#     explicitly cleared, and `onCurrentIndexChanged` then pushed that 0 into C++ — throwing away
#     the English that setConfigurationMap() had chosen. The installer opened in German, because
#     German is what config/languages.conf lists first.
assert_true "a click moves the VIEW's currentIndex, which is what draws the highlight" \
    grep -qE '^\s*onClicked: list\.currentIndex = row\.index$' "$QML"
assert_false "no delegate writes the C++ index directly — that is the bug that froze the highlight" \
    grep -qE 'onClicked:.*language\.currentIndex' "$QML"
assert_true "the ListView clears its currentIndex so componentComplete() cannot select row 0" \
    grep -qE '^\s*currentIndex: -1$' "$QML"
assert_true "the view is seeded from C++ once the component is complete" \
    grep -qE '^\s*Component\.onCompleted: list\.currentIndex = language\.currentIndex$' "$QML"
assert_true "a view-driven change is pushed back to C++" \
    grep -qE '^\s*onCurrentIndexChanged: language\.currentIndex = list\.currentIndex$' "$QML"
assert_true "and C++ can drive the view back, for the indexes setCurrentIndex() refuses" \
    bash -c "sed -n '/Connections {/,/^                }/p' '$QML' |
             grep -q 'list.currentIndex = language.currentIndex'"
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

# THE VENDORED BOX IS VENDORED, not adopted. checker/ is three files copied from Calamares' welcome
# module; the value of that is that the diff against a future release is a header and one rename,
# so each file has to say where it came from, and none of them may still refer to upstream's own
# config class.
for f in CheckerContainer ResultsListWidget ResultDelegate; do
    assert_true "checker/$f records where it was vendored from" \
        bash -c "grep -q 'VENDORED FROM CALAMARES' '$GREET_SRC/checker/$f.h' &&
                 grep -q 'VENDORED FROM CALAMARES' '$GREET_SRC/checker/$f.cpp'"
done
assert_false "nothing in checker/ still includes upstream's Config.h" \
    grep -rqE '#include "Config\.h"' "$GREET_SRC/checker"
# The three things ResultsListWidget calls on the object it is handed. Renaming one of them in
# GreetingConfig compiles here and fails only at link time in a container an hour into a build.
for m in warningMessage requirementsModel unsatisfiedRequirements; do
    assert_true "GreetingConfig still answers $m(), which the vendored box calls" \
        grep -qE "^\s*(QString|Calamares::RequirementsModel\*|QAbstractItemModel\*) $m\(\) const" \
            "$GREET_SRC/GreetingConfig.h"
done

# NO SECOND LOGO. ResultsListWidget puts the branding's productWelcome image into the box, expanding,
# as soon as every requirement passes — so a logo in the page header above it is the "logo sized to
# fill whatever space is left over" that plan/22 opened by complaining about.
assert_false "the greeting page draws no logo of its own" \
    grep -qE 'ProductLogo|ProductWelcome|imagePath' "$GREET_SRC/GreetingPage.cpp"

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
# Comments stripped: the job explains in prose which labels stage 60 gives the factory image's
# filesystems, and a naive count reads the explanation as a second mkfs.
assert_eq "1" "$(grep -vE '^[[:space:]]*#' "$DISK_JOB" | grep -c 'mkfs.ext4')" \
    "the job makes exactly one ext4 filesystem"
assert_eq "1" "$(grep -vE '^[[:space:]]*#' "$DISK_JOB" | grep -c 'mkfs.vfat')" \
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
    grep -q 'tr( "Erase this disk?" )' "$DISK_SRC/DiskConfig.h"
assert_true "...and its subtitle is composed whole in C++, selection and language both" \
    grep -q 'DiskConfig::confirmSubtitle' "$DISK_SRC/DiskConfig.cpp"

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
assert_eq "$APPS_EXPECTED" \
    "$(sed -nE 's/^[[:space:]]+- id:[[:space:]]+(\S+).*/\1/p' "$APPS_CONF" | tr '\n' ' ' | sed 's/ $//')" \
    "apps.conf offers the six applications, in file order"
assert_eq "$APPS_EXPECTED" \
    "$(sed -nE 's/^[[:space:]]+- id:[[:space:]]+(\S+).*/\1/p' "$APPS_SRC/apps.conf" | tr '\n' ' ' | sed 's/ $//')" \
    "...and the packaged fallback offers exactly the same six"
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
    bash -c "[[ \$(sed -nE 's/^[[:space:]]+description:[[:space:]]+(\S.*)$/\1/p' '$APPS_CONF' | wc -l) -eq 6 ]]"
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
    bash -c "grep -q '\"flatpak\", \"install\", \"-y\", \"--system\", \"--noninteractive\"' '$APPS_JOB' &&
             grep -q '\"flatpak\", \"update\", \"-y\", \"--system\", \"--noninteractive\"' '$APPS_JOB'"
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

# THE LABEL IS PART OF THE CONTROL (plan/27 §7). The three mode rows put their text beside bare
# radio buttons and the custom rows beside checkboxes, and a QQC2 control without `text:` does
# not extend its hit area to a sibling label — so each label block is a MouseArea that does what
# the control's own click does. Four of them: three modes, one per app row.
assert_true "every label block is a click target beside its control" \
    bash -c "grep -c 'cursorShape: Qt.PointingHandCursor' '$APPS_QML' | grep -qx 4"
assert_true "...each mode's click answers the same question its radio does" \
    bash -c "grep -A4 'cursorShape: Qt.PointingHandCursor' '$APPS_QML' | grep -q 'apps.mode = \"typical\"'"
# The custom row leads with a name and a sentence: the Flathub id stays the key C++ and the job
# exchange, and stops being the text the row is read by.
assert_false "no label draws the Flathub identifier any more" \
    grep -q 'text: appRow.modelData.id' "$APPS_QML"
assert_true "...the description sits under the name instead" \
    grep -q 'text: appRow.modelData.description' "$APPS_QML"
assert_true "...and a click on it toggles the checkbox it belongs to" \
    bash -c "grep -A6 'cursorShape: Qt.PointingHandCursor' '$APPS_QML' |
             grep -q 'apps.setSelected('"

# The module is `apps`, everywhere the siblings are: built by that name, sidebar named by the
# page's one noun, QML inside the .so.
assert_true "the plugin is built as 'apps'" \
    grep -qE '^calamares_add_plugin\(apps$' "$APPS_SRC/CMakeLists.txt"
assert_true "...and the sidebar says Applications" \
    bash -c "sed -n '/^AppsViewStep::prettyName/,/^}/p' '$APPS_SRC/AppsViewStep.cpp' | grep -q 'tr( \"Applications\" )'"
assert_true "...and the QML travels inside the .so rather than being installed a second time" \
    grep -q 'qt6_add_resources(${APPS_TARGET}' "$APPS_SRC/CMakeLists.txt"

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

# The set names six atoms: Calamares, and the five view modules this project plugs into it — the
# accounts page (plan/21), the language page (plan/22), the greeting page (plan/23), the disk page
# (plan/24) and the applications page (plan/25). Everything else in the ~25-package tail is
# resolved, and a set that starts listing transitive deps stops describing intent.
#
# The count is asserted rather than the names, and it is a NUMBER on purpose: adding an atom here is
# exactly the change that should have to be argued for in a diff, because @installer is the one set
# whose contents the product image is forbidden to contain. The fourth was argued in plan/23 and was
# a SPLIT of the third rather than new weight. The fifth is argued in plan/24 and is a REPLACEMENT:
# it takes a stock module out of the sequence rather than adding a page, and it drops this
# installer's last use of KPMcore with it. The sixth is argued in plan/25 and is the first that
# replaces NOTHING — a new question, with no stock module that ever asked it.
assert_eq "6" "$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/config/portage/sets/installer")" \
    "@installer names exactly six atoms"
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

finish
