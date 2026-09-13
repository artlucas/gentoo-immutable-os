#!/usr/bin/env bash
# The graphical installer (plan/16 Phase A).
#
# Three classes of failure are asserted here, and they share a shape: each one produces a build
# that succeeds, a medium that boots, and an installer that goes wrong on a stranger's hardware
# with their disk already partitioned.
#
#   1. THE CALAMARES CONFIG AND THE PIPELINE DISAGREE. modules/partition.conf creates the
#      partitions and scripts/lib/common.sh's emit_sfdisk_script() creates the factory image's.
#      They are 300 lines apart in two languages, and if the labels or GPT types drift the
#      installed machine boots (the initrd finds root by PARTLABEL) right up until it does not.
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
                    ROOT_SLOT_SIZE_MIB DISTRO_ID DISTRO_NAME LIVE_USER HOME_URL \
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
      export DISTRO_ID DISTRO_NAME VERSION HOME_URL LIVE_USER UPDATE_URL UPDATE_CHANNEL
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

# ---- 5. the config and the pipeline agree on the disk ---------------------------------------
# THE check this file exists for. emit_sfdisk_script() writes the factory image's partitions;
# partition.conf writes the installed machine's. plan/16 §3.4: they have to be the same, or a
# machine installed from the medium is not the same system as one dd'd from the .img and
# systemd-sysupdate stops recognising it.
PART_CONF="$RENDER/modules/partition.conf"
assert_file "$PART_CONF" "partition.conf rendered"
factory="$(compute_layout 1024 6144 4096 2; emit_sfdisk_script "$I_VERSION")"
for token in "$I_ROOT_PARTLABEL" '_empty' 'esp' 'var'; do
    assert_true "the factory layout names '$token'" grep -q -- "\"$token\"" <<<"$factory"
done
# ...and the installer creates the same three it is responsible for (the ESP is created by the
# partition module itself, from the `efi:` block, not from partitionLayout).
assert_true "partition.conf creates $I_ROOT_PARTLABEL"  grep -q "\"$I_ROOT_PARTLABEL\"" "$PART_CONF"
assert_true "partition.conf creates the _empty slot B"  grep -q '"_empty"' "$PART_CONF"
assert_true "partition.conf creates var"                grep -q '"var"' "$PART_CONF"
assert_true "partition.conf labels the ESP 'esp'"       grep -qE 'label:[[:space:]]+"esp"' "$PART_CONF"
# The GPT type GUIDs, which are what systemd-repart and systemd-sysupdate actually match on.
assert_true "partition.conf uses the pipeline's root GPT type" \
    grep -qi "$GPT_TYPE_ROOT_X64" "$PART_CONF"
assert_true "partition.conf uses the pipeline's var GPT type" \
    grep -qi "$GPT_TYPE_VAR" "$PART_CONF"
assert_true "partition.conf sizes the root slots from ROOT_SLOT_SIZE_MIB" \
    grep -q "\"${I_ROOT_SLOT_SIZE_MIB}M\"" "$PART_CONF"
# Two root slots, because an installed machine that cannot be updated is the failure profiles
# and A/B exist to prevent — and the live medium having one slot must not become the target's.
assert_eq "2" "$(grep -c "$GPT_TYPE_ROOT_X64" "$PART_CONF")" \
    "the INSTALLED system gets both A/B root slots, even though the medium has one"

# The label that ties the disk to the boot: partition.conf writes it, imagedeploy looks for it,
# and the UKI cmdline (stage 40) and sysupdate's transfer both hardcode the same shape.
assert_true "imagedeploy.conf looks for the partition partition.conf creates" \
    grep -q "\"$I_ROOT_PARTLABEL\"" "$RENDER/modules/imagedeploy.conf"
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

# ---- 6. the modules exist and are wired into the sequence -----------------------------------
SETTINGS="$RENDER/settings.conf"
assert_file "$SETTINGS" "settings.conf rendered"
mapfile -t OURS < <(find "$CAL/local-modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
# Still four after plan/21, by substitution rather than by coincidence: accountsetup replaced
# managedenroll AND the stock `users` module's jobs, alongside imagedeploy, imagebootloader and
# imageidentity.
(( ${#OURS[@]} == 4 )) || _fail "expected four local modules, found ${#OURS[@]}: ${OURS[*]}"
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
for forbidden in localecfg unpackfs fstab bootloader grubcfg initcpio initcpiocfg dracut \
                 initramfs machineid packages netinstall displaymanager mount users welcome; do
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
        --source-dir "$REPO_ROOT/config/portage/overlay/distro-base/distro-calamares-accounts/files"

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

# The set names four atoms: Calamares, and the three view modules this project plugs into it — the
# accounts page (plan/21), the language page (plan/22) and the greeting page (plan/23). Everything
# else in the ~25-package tail is resolved, and a set that starts listing transitive deps stops
# describing intent.
#
# The count is asserted rather than the names, and it is a NUMBER on purpose: adding an atom here is
# exactly the change that should have to be argued for in a diff, because @installer is the one set
# whose contents the product image is forbidden to contain. The fourth was argued in plan/23 and is
# a SPLIT of the third rather than new weight: a Calamares view step is one entry in the sidebar, so
# a page with two screens had to become two modules.
assert_eq "4" "$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/config/portage/sets/installer")" \
    "@installer names exactly four atoms"
for atom in app-admin/calamares distro-base/distro-calamares-accounts \
            distro-base/distro-calamares-greeting distro-base/distro-calamares-language; do
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
