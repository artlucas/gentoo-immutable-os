#!/bin/bash
# shellcheck shell=bash
# layout.sh — the partition layout, and the one place it is written down (plan/24 §4).
#
# THIS FILE HAS TWO CONSUMERS AND THAT IS THE ENTIRE REASON IT IS A FILE.
#
#   1. THE PIPELINE. common.sh sources it, so stage 60 builds the factory .img from these
#      functions exactly as it always did. Nothing about that path changed when the file moved.
#   2. THE INSTALLER. Stage 40 installs this file VERBATIM onto the installer medium as
#      /usr/libexec/<id>-disk-layout, and the `disksetup` job executes it to get the sfdisk
#      script for the disk the user chose.
#
# Until plan/24 those were two descriptions of one layout: compute_layout() and
# emit_sfdisk_script() built the factory image, and a `partitionLayout:` block in
# modules/partition.conf told Calamares' stock partition module to build the same thing in YAML,
# 300 lines away in another language. tests/test-installer.sh existed largely to compare them
# label for label, GPT type for GPT type and size for size — a test that can only ever catch the
# drift it was taught to look for. plan/16 §3.4 is what makes the drift matter: a machine
# installed from the medium has to be indistinguishable from one dd'd from the .img, or
# systemd-sysupdate stops recognising it. One file cannot disagree with itself.
#
# SOURCE IT OR RUN IT. Sourced, it is a library and defines nothing but functions and the three
# GPT type GUIDs. Run, it is the CLI at the bottom — which is what the installer uses, because a
# python job calling one subprocess is a smaller contract than a python re-implementation of the
# arithmetic.
#
# The shebang on the first line belongs to the second consumer only, and the medium it shipped on
# is the one that explains why it must be there. A shell asked to run a script with no interpreter
# line quietly adopts it — that is what stage 40's probe did, so the probe passed. The python job
# calls execve, which does not: a file whose first two bytes are not `#!` and which is not an ELF
# is "[Errno 8] Exec format error", and every install from that medium died at the first disk.
#
# It must stay SELF-CONTAINED: no $REPO, no load_config, no logging beyond die(). The copy on the
# installer medium has none of those things, and tests/test-installer.sh asserts the two copies
# are byte-identical.

[[ -n ${_IMMOS_LAYOUT_LOADED:-} ]] && return 0
_IMMOS_LAYOUT_LOADED=1

# common.sh defines its own with a stage prefix and this does not replace it — `declare -F` is
# asked precisely so that sourcing order cannot change the message a build prints. Standalone on
# the installer medium there is nothing to inherit, so there has to be one here.
if ! declare -F die >/dev/null 2>&1; then
  die() { printf 'disk-layout: ERROR: %s\n' "$*" >&2; exit 1; }
fi

# ---- GPT / image layout (pure math; unit-tested) ---------------------------------
GPT_TYPE_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
GPT_TYPE_ROOT_X64="4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44"
GPT_TYPE_VAR="4D21B016-B534-45C2-A9FB-5C16E091FD2D"

# compute_layout ESP_MIB SLOT_MIB VAR_MIB [SLOTS] — sets the partition offsets for the image.
# 1 MiB leading alignment gap + 1 MiB trailing slack for the backup GPT.
#
# Two APIs over the same numbers, deliberately:
#   POSITIONAL  P<n>_START_MIB / P<n>_SIZE_MIB for n in 1..PART_COUNT, in on-disk order. This is
#               what the sfdisk script and the byte-offset assertions in tests/ speak.
#   BY ROLE     ESP_START_MIB, ROOT_A_START_MIB, ROOT_B_START_MIB, VAR_START_MIB. Callers that
#               care WHICH partition they are writing should use these, because the positional
#               index of `var` moves with SLOTS and a hardcoded P4 would silently write the
#               payload past the end of a one-slot image.
#
# SLOTS is the number of root slots, 2 (default) or 1:
#   2  the A/B layout every INSTALLABLE image has. Slot B ships as zeros under PARTLABEL=_empty;
#      systemd-sysupdate writes the next version into it and relabels (plan/01, plan/05).
#   1  live media only. A live medium is never updated — stage 40 masks systemd-sysupdate for
#      live-role profiles — so a second 6 GiB slot would be 6 GiB of zeros on every stick.
#      Requested by config/profiles/*.conf's PROFILE_ROOT_SLOTS (plan/16 §3.1).
compute_layout() {
  local esp=$1 slot=$2 var=$3 slots=${4:-2}
  [[ $slots == 1 || $slots == 2 ]] || die "compute_layout: SLOTS must be 1 or 2 (got: $slots)"

  # Stale offsets from an earlier call in the same shell are worse than absent ones: a 1-slot
  # layout that inherits P4_* from a 2-slot one hands out an offset for a partition that does
  # not exist. The tests call this repeatedly in one process, so clear before setting.
  unset P1_START_MIB P1_SIZE_MIB P2_START_MIB P2_SIZE_MIB \
        P3_START_MIB P3_SIZE_MIB P4_START_MIB P4_SIZE_MIB ROOT_B_START_MIB

  P1_START_MIB=1;                              P1_SIZE_MIB=$esp
  P2_START_MIB=$((P1_START_MIB + P1_SIZE_MIB)); P2_SIZE_MIB=$slot
  ESP_START_MIB=$P1_START_MIB
  ROOT_A_START_MIB=$P2_START_MIB

  if [[ $slots == 2 ]]; then
    P3_START_MIB=$((P2_START_MIB + P2_SIZE_MIB)); P3_SIZE_MIB=$slot
    P4_START_MIB=$((P3_START_MIB + P3_SIZE_MIB)); P4_SIZE_MIB=$var
    ROOT_B_START_MIB=$P3_START_MIB
    VAR_START_MIB=$P4_START_MIB
    PART_COUNT=4
    TOTAL_MIB=$((P4_START_MIB + P4_SIZE_MIB + 1))
  else
    P3_START_MIB=$((P2_START_MIB + P2_SIZE_MIB)); P3_SIZE_MIB=$var
    ROOT_B_START_MIB=""
    VAR_START_MIB=$P3_START_MIB
    PART_COUNT=3
    TOTAL_MIB=$((P3_START_MIB + P3_SIZE_MIB + 1))
  fi
}

# emit_sfdisk_script VERSION — prints the sfdisk input for the computed layout.
# compute_layout must have been called first.
#
# The NAMES here are the installed system's identity and are never profile-suffixed: the initrd
# finds root by PARTLABEL=root_<version> off the UKI cmdline, /etc/fstab finds var and esp by
# PARTLABEL, sysupdate matches root_@v, and repart.d/50-var.conf grows the partition whose TYPE
# is var. Change one of these strings and an installed machine stops updating (plan/16 §3.4).
emit_sfdisk_script() {
  local version=$1
  [[ -n ${TOTAL_MIB:-} ]] || die "emit_sfdisk_script: call compute_layout first"
  printf 'label: gpt\n'
  printf 'start=%sMiB, size=%sMiB, type=%s, name="esp"\n' \
         "$P1_START_MIB" "$P1_SIZE_MIB" "$GPT_TYPE_ESP"
  printf 'start=%sMiB, size=%sMiB, type=%s, name="root_%s"\n' \
         "$P2_START_MIB" "$P2_SIZE_MIB" "$GPT_TYPE_ROOT_X64" "$version"
  # Slot B, present only on installable images. "_empty" is systemd-sysupdate's own convention
  # for an unused instance slot, not a name this project invented: sysupdate's partition target
  # claims a partition whose label is empty or "_empty" when it needs a free instance.
  if [[ ${PART_COUNT:-4} == 4 ]]; then
    printf 'start=%sMiB, size=%sMiB, type=%s, name="_empty"\n' \
           "$P3_START_MIB" "$P3_SIZE_MIB" "$GPT_TYPE_ROOT_X64"
  fi
  printf 'start=%sMiB, size=%sMiB, type=%s, name="var"\n' \
         "$VAR_START_MIB" "$((PART_COUNT == 4 ? P4_SIZE_MIB : P3_SIZE_MIB))" "$GPT_TYPE_VAR"
}

# emit_install_sfdisk_script DISK_MIB ESP_MIB SLOT_MIB VERSION [MIN_VAR_MIB]
#
# The INSTALLER's call, and the only thing plan/24 added to this file. The factory image is built
# to a size the pipeline chose; an installed machine is built to the size of a disk somebody
# owns, so `var` is what is left over rather than a number from build.conf.
#
# TWO SLOTS ALWAYS. A live medium gets one (PROFILE_ROOT_SLOTS=1) because it is never updated;
# a machine somebody installs gets the A/B pair, or it installs cleanly and can never take an
# update. Nothing here offers the choice, which is why there is no SLOTS parameter.
#
# `var` takes the remainder rather than a fixed size, which is also what makes the first-boot
# repart grow a no-op on an installed machine: 50-var.conf grows the var partition to the end of
# the disk, and there is nothing left to grow into.
emit_install_sfdisk_script() {
  local disk=$1 esp=$2 slot=$3 version=$4 min_var=${5:-4096}
  local n
  for n in "$disk" "$esp" "$slot" "$min_var"; do
    [[ $n =~ ^[0-9]+$ ]] || die "emit_install_sfdisk_script: '$n' is not an integer MiB count"
  done
  [[ -n $version ]] || die "emit_install_sfdisk_script: no version"

  # 1 MiB leading gap + 1 MiB trailing slack, the same two compute_layout accounts for. They are
  # subtracted HERE as well because the caller's disk is a fixed size: TOTAL_MIB has to come back
  # equal to it, not one megabyte over.
  local var=$(( disk - 1 - esp - 2 * slot - 1 ))
  (( var >= min_var )) || die "a disk of ${disk} MiB leaves ${var} MiB for /var, and this layout
  needs at least ${min_var} MiB after the ESP (${esp} MiB) and both ${slot} MiB root slots. The
  disk page is supposed to have refused this disk before anything reached here."

  compute_layout "$esp" "$slot" "$var" 2
  (( TOTAL_MIB == disk )) || die "computed a ${TOTAL_MIB} MiB layout for a ${disk} MiB disk"
  emit_sfdisk_script "$version"
}

# ---- the CLI ---------------------------------------------------------------------
# Only when RUN, never when sourced. BASH_SOURCE[0] is this file either way; $0 is this file only
# when it is the script bash was started on.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  set -euo pipefail

  usage() {
    cat >&2 <<'USAGE'
usage: disk-layout sfdisk --disk-mib N --esp-mib N --slot-mib N --version X.Y.Z [--min-var-mib N]

Prints the sfdisk script for an installed machine's disk, on stdout. This is the same layout the
factory image is built with, from the same two functions, because it is the same file.
USAGE
    exit 2
  }

  cmd="${1:-}"; shift || true
  [[ $cmd == sfdisk ]] || usage

  disk=""; esp=""; slot=""; version=""; min_var=4096
  while (( $# )); do
    case "$1" in
      --disk-mib)    disk="${2:-}";    shift 2 ;;
      --esp-mib)     esp="${2:-}";     shift 2 ;;
      --slot-mib)    slot="${2:-}";    shift 2 ;;
      --version)     version="${2:-}"; shift 2 ;;
      --min-var-mib) min_var="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n $disk && -n $esp && -n $slot && -n $version ]] || usage

  emit_install_sfdisk_script "$disk" "$esp" "$slot" "$version" "$min_var"
fi
