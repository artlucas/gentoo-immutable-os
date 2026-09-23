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

# layout_names ROLE VERSION — sets NAME_ESP, NAME_ROOT, NAME_VAR: the PARTLABELs a partition
# of that role carries. Split from emit_sfdisk_script (plan/33 §2) because keep mode needs the
# names on their own, to compare against a disk's existing table without emitting anything.
#
# TWO NAMESPACES, NOT ONE. Before this, a live medium's own three partitions and an INSTALLED
# system's carried the identical strings — esp/root_<v>/var — because plan/16 §3.4 forbids
# suffixing the identity names an installed machine is found and updated by. That was fine until
# a live medium had to boot next to a disk carrying the same names: /dev/disk/by-partlabel/<name>
# then resolves to whichever device udev enumerated first, independently per partition, and keep
# mode (plan/33) is precisely the scenario where both are attached — the installer stick IS
# booted on a machine that already has this distro installed.
#
# `target`: unchanged, still esp/root_<v>/var — every string disksetup, imagedeploy, the
# manifest and systemd-sysupdate compare against, and none of them may move.
# `live`: live_esp/live_root_<v>/live_var. A live image is never a sysupdate target, so §3.4's
# ban on suffixing does not apply to it — these three strings exist ONLY so a live medium's own
# disk never collides with an installed one's.
layout_names() {
  local role=$1 version=$2
  case "$role" in
    target) NAME_ESP="esp";      NAME_ROOT="root_${version}";      NAME_VAR="var" ;;
    live)   NAME_ESP="live_esp"; NAME_ROOT="live_root_${version}"; NAME_VAR="live_var" ;;
    *) die "layout_names: ROLE must be target or live (got: $role)" ;;
  esac
}

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

# emit_sfdisk_script VERSION [ROLE] — prints the sfdisk input for the computed layout.
# compute_layout must have been called first. ROLE defaults to "target", which is every caller
# but one: stage 60 is the only place a live image gets built, and it is the only caller that
# ever passes "live" (plan/33 §2).
#
# The NAMES come from layout_names(), and for ROLE=target they are the installed system's
# identity and are never profile-suffixed: the initrd finds root by PARTLABEL=root_<version> off
# the UKI cmdline, /etc/fstab finds var and esp by PARTLABEL, sysupdate matches root_@v, and
# repart.d/50-var.conf grows the partition whose TYPE is var. Change one of those strings and an
# installed machine stops updating (plan/16 §3.4). ROLE=live's names exist only so a live
# medium's own disk cannot be confused with an installed one's (plan/33 §2) — nothing outside
# this file and the live image's own fstab ever looks for them.
emit_sfdisk_script() {
  local version=$1 role=${2:-target}
  [[ -n ${TOTAL_MIB:-} ]] || die "emit_sfdisk_script: call compute_layout first"
  layout_names "$role" "$version"
  printf 'label: gpt\n'
  printf 'start=%sMiB, size=%sMiB, type=%s, name="%s"\n' \
         "$P1_START_MIB" "$P1_SIZE_MIB" "$GPT_TYPE_ESP" "$NAME_ESP"
  printf 'start=%sMiB, size=%sMiB, type=%s, name="%s"\n' \
         "$P2_START_MIB" "$P2_SIZE_MIB" "$GPT_TYPE_ROOT_X64" "$NAME_ROOT"
  # Slot B, present only on installable images. "_empty" is systemd-sysupdate's own convention
  # for an unused instance slot, not a name this project invented: sysupdate's partition target
  # claims a partition whose label is empty or "_empty" when it needs a free instance. Never
  # role-prefixed — a live image never has a slot B (PROFILE_ROOT_SLOTS=1) to begin with.
  if [[ ${PART_COUNT:-4} == 4 ]]; then
    printf 'start=%sMiB, size=%sMiB, type=%s, name="_empty"\n' \
           "$P3_START_MIB" "$P3_SIZE_MIB" "$GPT_TYPE_ROOT_X64"
  fi
  printf 'start=%sMiB, size=%sMiB, type=%s, name="%s"\n' \
         "$VAR_START_MIB" "$((PART_COUNT == 4 ? P4_SIZE_MIB : P3_SIZE_MIB))" "$GPT_TYPE_VAR" "$NAME_VAR"
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
# ROLE IS ALWAYS "target" TOO, for the same shape of reason (plan/33 §2): this function writes
# the disk an installer is about to hand back as a running machine, and a running machine is by
# definition what ROLE=target names. Passing that through to emit_sfdisk_script explicitly, below,
# rather than relying on its default — an installer's own default must never depend on another
# function's — is what makes the second sentence of this paragraph checkable by reading this file
# alone.
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
  emit_sfdisk_script "$version" target
}

# ---- inspecting an EXISTING disk (plan/33 §4) -------------------------------------
#
# ONE DEFINITION OF "can this disk be kept", for the same reason plan/24 §4 gave
# emit_install_sfdisk_script its own home here: the disk page asks this question to draw the
# tick box, and the disksetup job asks it again before it writes anything, and a job that writes
# a disk does not take a page's word for what the page saw (§6). Two implementations of "is this
# an install, and can it be reused" would be two chances to disagree about a disk full of
# somebody's files — so there is one, and both callers run it as a subprocess.
#
# inspect_installed_layout DEVICE ESP_MIB SLOT_MIB — reads an `sfdisk --dump DEVICE` on stdin,
# a pure text function with no side effects, and prints key=value lines (one key per line, so a
# reader can `grep '^key='` or split on the first '='). Returns 0 whenever it completed an
# analysis — "not an install", "an install that cannot be kept" and "an install that can" are all
# completed analyses — and 2 only on a usage error (bad arguments; there was nothing to analyse).
inspect_installed_layout() {
  local device=$1 esp_mib=$2 slot_mib=$3
  if [[ -z $device || ! $esp_mib =~ ^[0-9]+$ || ! $slot_mib =~ ^[0-9]+$ ]]; then
    printf 'disk-layout inspect: DEVICE is required, and ESP_MIB/SLOT_MIB must be positive integers\n' >&2
    return 2
  fi

  local dump; dump="$(cat)"
  local label sector_size
  label="$(sed -n 's/^label:[[:space:]]*//p' <<<"$dump" | head -n1)"
  sector_size="$(sed -n 's/^sector-size:[[:space:]]*//p' <<<"$dump" | head -n1)"
  sector_size="${sector_size:-512}"

  # One partition line per partition, in sfdisk --dump's own syntax:
  #   /dev/sda2 : start=     2099200, size=    12582912, type=<GUID>, uuid=..., name="root_0.3.0"
  # Everything this function needs is on that one line. The header block above it (label:,
  # device:, unit:, sector-size:, the blank line before the partitions) never starts with the
  # device path, which is the filter below.
  #
  # THE PARTITION NUMBER COMES FROM THE NODE, not from position in the dump: stripping the
  # --device prefix and then an optional "p" turns /dev/nvme0n1p2, /dev/sda2 and a scratch
  # file's disk.img2 all into "2", which is the one thing an nvme node and a SATA node do not
  # spell the same way.
  local -A P_START=() P_SIZE=() P_TYPE=() P_NAME=()
  local nums=() line node num start size type name
  while IFS= read -r line; do
    [[ $line == "$device"* ]] || continue
    node="$(cut -d: -f1 <<<"$line" | tr -d '[:space:]')"
    num="${node#"$device"}"; num="${num#p}"
    [[ $num =~ ^[0-9]+$ ]] || continue
    nums+=("$num")
    start="$(grep -oE 'start=[[:space:]]*[0-9]+' <<<"$line" | grep -oE '[0-9]+')"
    size="$(grep -oE 'size=[[:space:]]*[0-9]+'   <<<"$line" | grep -oE '[0-9]+')"
    type="$(grep -oE 'type=[^,]+'                <<<"$line" | cut -d= -f2 | tr -d '[:space:]')"
    name="$(grep -oE 'name="[^"]*"'              <<<"$line" | sed -E 's/^name="(.*)"$/\1/')"
    P_START[$num]=$start; P_SIZE[$num]=$size; P_TYPE[$num]=$type; P_NAME[$num]=$name
  done <<<"$dump"

  # installed= — the highest root_<v> by `sort -V`, wherever on the disk it is. Printed for
  # `keep` AND `refuse`, never for `none`: a disk that fails the layout or size checks below may
  # still be recognisably a PREVIOUS install of this distro, and §3's "cannot be kept" sentence
  # names it. Bare version, not the partition label — installed=0.3.0, not installed=root_0.3.0.
  local n roots=() installed=""
  for n in "${nums[@]}"; do
    [[ ${P_NAME[$n]} == root_* ]] && roots+=("${P_NAME[$n]#root_}")
  done
  (( ${#roots[@]} )) && installed="$(printf '%s\n' "${roots[@]}" | sort -V | tail -n1)"

  # verdict=none — the cheap, TABLE-INDEPENDENT check first: is there even a partition claiming
  # to be this distro's var? Without one, nothing below matters, and a disk running a different
  # OS (or nothing at all) must never be reported as "an install that cannot be kept" — it is
  # simply not one, and the page does exactly what it did before this document.
  local has_var=0
  for n in "${nums[@]}"; do
    if [[ ${P_NAME[$n]} == var && ${P_TYPE[$n],,} == "${GPT_TYPE_VAR,,}" ]]; then
      has_var=1; break
    fi
  done
  if [[ $has_var == 0 ]]; then
    printf 'verdict=none\n'
    return 0
  fi

  # verdict=refuse reason=table — a var-typed partition matched above, but the table itself is
  # not GPT. Real hardware cannot actually produce this (MBR has no type GUIDs to match against
  # in the first place), but a helper that trusted the match above without checking the table
  # would still be wrong to, so it is checked rather than assumed.
  if [[ ${label,,} != gpt ]]; then
    printf 'verdict=refuse\nreason=table\n'
    [[ -n $installed ]] && printf 'installed=%s\n' "$installed"
    return 0
  fi

  # verdict=refuse reason=layout — exactly four partitions, numbered 1-4, in ascending physical
  # order, each the role this distro's own layout gives it (plan/16 §3.4): p1 the ESP, p2 and p3
  # root slots (typed ROOT_X64, named root_<v> or _empty — at least one root_<v>, or there is no
  # version to boot), p4 var.
  local layout_ok=1 sorted
  if [[ ${#nums[@]} -ne 4 ]]; then
    layout_ok=0
  else
    sorted="$(printf '%s\n' "${nums[@]}" | sort -n | tr '\n' ' ')"
    [[ $sorted == "1 2 3 4 " ]] || layout_ok=0
  fi
  if [[ $layout_ok == 1 ]]; then
    (( P_START[1] < P_START[2] && P_START[2] < P_START[3] && P_START[3] < P_START[4] )) \
      || layout_ok=0
  fi
  if [[ $layout_ok == 1 ]]; then
    [[ ${P_TYPE[1],,} == "${GPT_TYPE_ESP,,}"      && ${P_NAME[1]} == esp ]]      || layout_ok=0
    [[ ${P_TYPE[2],,} == "${GPT_TYPE_ROOT_X64,,}" \
      && ( ${P_NAME[2]} == root_* || ${P_NAME[2]} == _empty ) ]]                 || layout_ok=0
    [[ ${P_TYPE[3],,} == "${GPT_TYPE_ROOT_X64,,}" \
      && ( ${P_NAME[3]} == root_* || ${P_NAME[3]} == _empty ) ]]                 || layout_ok=0
    [[ ${P_NAME[2]} == root_* || ${P_NAME[3]} == root_* ]]                       || layout_ok=0
    [[ ${P_TYPE[4],,} == "${GPT_TYPE_VAR,,}"      && ${P_NAME[4]} == var ]]      || layout_ok=0
  fi
  if [[ $layout_ok == 0 ]]; then
    printf 'verdict=refuse\nreason=layout\n'
    [[ -n $installed ]] && printf 'installed=%s\n' "$installed"
    return 0
  fi

  # Sizes, in MiB: size= is in sectors, sector-size: (default 512) is what converts them. Checked
  # against THIS BUILD's ESP_MIB/SLOT_MIB, not the size of the image being written — a disk whose
  # slots are smaller than this build's is a disk future updates will not fit either, and keeping
  # it would only move the failure to the next sysupdate.
  local esp_actual_mib=$(( P_SIZE[1] * sector_size / 1024 / 1024 ))
  local slot_actual_mib=$(( P_SIZE[2] * sector_size / 1024 / 1024 ))
  local spare_actual_mib=$(( P_SIZE[3] * sector_size / 1024 / 1024 ))
  local var_actual_mib=$(( P_SIZE[4] * sector_size / 1024 / 1024 ))

  if (( esp_actual_mib < esp_mib )); then
    printf 'verdict=refuse\nreason=esp-size\n'
    [[ -n $installed ]] && printf 'installed=%s\n' "$installed"
    return 0
  fi
  if (( slot_actual_mib < slot_mib || spare_actual_mib < slot_mib )); then
    printf 'verdict=refuse\nreason=slot-size\n'
    [[ -n $installed ]] && printf 'installed=%s\n' "$installed"
    return 0
  fi

  # verdict=keep — the roles are always THESE FOUR PARTITION NUMBERS, never whichever one
  # currently holds root_<v>: the new root always goes into p2 and p3 is always the spare that
  # gets relabelled _empty first (disksetup's keep_disk(), §6). Nothing is running from either
  # slot on this path — the installer boots from its own medium — so there is no "active slot"
  # to avoid, and fixing the roles is what removes the ambiguity two partitions could otherwise
  # share the very label being written.
  printf 'verdict=keep\n'
  printf 'esp=1\nslot=2\nspare=3\nvar=4\n'
  printf 'esp_mib=%s\nslot_mib=%s\nspare_mib=%s\nvar_mib=%s\n' \
    "$esp_actual_mib" "$slot_actual_mib" "$spare_actual_mib" "$var_actual_mib"
  [[ -n $installed ]] && printf 'installed=%s\n' "$installed"
  return 0
}

# ---- the CLI ---------------------------------------------------------------------
# Only when RUN, never when sourced. BASH_SOURCE[0] is this file either way; $0 is this file only
# when it is the script bash was started on.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  set -euo pipefail

  usage() {
    cat >&2 <<'USAGE'
usage: disk-layout sfdisk  --disk-mib N --esp-mib N --slot-mib N --version X.Y.Z [--min-var-mib N]
       disk-layout inspect --device DEV --esp-mib N --slot-mib N     (stdin: `sfdisk --dump DEV`)

sfdisk    prints the sfdisk script for an installed machine's disk, on stdout. This is the same
          layout the factory image is built with, from the same two functions, because it is the
          same file.
inspect   reads an `sfdisk --dump` of an EXISTING disk on stdin and prints key=value lines saying
          whether it already holds an install of this distro and, if so, whether it can be kept
          (plan/33 §4). The disk page and the disksetup job both run this, so they cannot
          disagree about a disk.
USAGE
    exit 2
  }

  cmd="${1:-}"; shift || true
  case "$cmd" in
    sfdisk)
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
      ;;
    inspect)
      device=""; esp=""; slot=""
      while (( $# )); do
        case "$1" in
          --device)   device="${2:-}"; shift 2 ;;
          --esp-mib)  esp="${2:-}";    shift 2 ;;
          --slot-mib) slot="${2:-}";   shift 2 ;;
          *) usage ;;
        esac
      done
      [[ -n $device && -n $esp && -n $slot ]] || usage
      inspect_installed_layout "$device" "$esp" "$slot"
      ;;
    *) usage ;;
  esac
fi
