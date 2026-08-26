#!/usr/bin/env bash
# run-vm.sh — boot a built disk image in QEMU/OVMF. Used interactively and by stage 70.
#
#   run-vm.sh IMG                          # graphical window
#   run-vm.sh IMG --headless serial.log    # no display, serial console to file
#   run-vm.sh IMG --test smoke             # inject test-mode credential (self-reporting boot)
#   run-vm.sh IMG --test update --update-url http://10.0.2.2:8000/stable
#   run-vm.sh IMG --writable                # guest writes hit IMG (see snapshot note below)
#   run-vm.sh IMG --disk-size 32G           # bigger virtual disk; repart grows /var into it
#   run-vm.sh IMG --disk-size 32G --writable  # ...and the overlay persists across reboots
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export STAGE_NAME=run-vm
# common.sh defaults REPO to the in-container /repo; interactive host runs need the real
# path. Stage 70 already exports REPO, and := leaves that alone.
: "${REPO:="$(dirname -- "$SCRIPT_DIR")"}"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IMG="${1:-}"; shift || true
[[ -n $IMG && -f $IMG ]] || die "usage: run-vm.sh IMG [--headless LOG] [--test smoke|update] [--update-url URL] [--disk-size SIZE]"

HEADLESS_LOG='' TEST_MODE='' TEST_URL='' MEM=4096 SNAPSHOT=on DISK_SIZE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)   HEADLESS_LOG="$2"; shift 2 ;;
    --test)       TEST_MODE="$2"; shift 2 ;;
    --update-url) TEST_URL="$2"; shift 2 ;;
    --memory)     MEM="$2"; shift 2 ;;
    --writable)   SNAPSHOT=off; shift ;;
    --disk-size)  DISK_SIZE="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmds qemu-system-x86_64

# DISTRO_ID for the credential namespace (env override for tests)
if [[ -z ${DISTRO_ID:-} ]]; then
  load_config
fi

find_ovmf() {
  local c
  for c in \
    /usr/share/edk2-ovmf/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2/OvmfX64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [[ -f $c ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

OVMF_CODE="${OVMF_CODE:-$(find_ovmf)}" || die "OVMF firmware not found (set OVMF_CODE=...)"
OVMF_VARS_SRC="${OVMF_CODE/CODE/VARS}"
[[ -f $OVMF_VARS_SRC ]] || die "OVMF VARS not found next to $OVMF_CODE"

VMDIR="$(mktemp -d)"
trap 'rm -rf -- "$VMDIR"' EXIT
cp -- "$OVMF_VARS_SRC" "$VMDIR/VARS.fd"    # fresh NVRAM per run: no state leaks

# ---- --disk-size: room for the guest to actually store things ---------------------------
#
# stage 60 sizes the image to fit its own partitions and nothing more (compute_layout:
# TOTAL_MIB = last partition end + 1 MiB for the backup GPT). The var partition carries
# Weight=1000 and no size cap, so systemd-repart in the initrd grows it to the end of
# WHATEVER DISK the image is on — on real hardware, the target drive. Boot the image file
# directly and there is nothing to grow into: /var comes up at its built VAR_SIZE_MIB,
# ~3.9 GiB, most of which is already Firefox and the KDE flatpaks. That is too small to pull
# a distrobox base image into, which is what this option exists for.
#
# The disk is enlarged with a qcow2 OVERLAY rather than by touching IMG: reads fall through
# to the image, writes and the extra space live in the overlay, and the released artifact is
# never modified. Whether the overlay survives the run follows --writable, for the same
# reason snapshot= does — a two-boot test needs its first boot's writes to still be there.
DISK_ARG="file=$IMG,if=virtio,format=raw,snapshot=$SNAPSHOT"
if [[ -n $DISK_SIZE ]]; then
  require_cmds qemu-img
  img_bytes="$(stat -c '%s' -- "$IMG")"
  want_bytes="$(numfmt --from=iec -- "${DISK_SIZE^^}" 2>/dev/null)" \
    || die "--disk-size: not a size (try 32G): $DISK_SIZE"
  (( want_bytes > img_bytes )) \
    || die "--disk-size $DISK_SIZE is not larger than the image itself ($((img_bytes / 1024 / 1024)) MiB) — nothing would grow"
  if [[ $SNAPSHOT == off ]]; then
    # Persistent: keep the overlay beside the image and REUSE it, so state survives a reboot.
    # Delete this file to start over; the image underneath is untouched either way.
    OVERLAY="${IMG}.overlay.qcow2"
  else
    OVERLAY="$VMDIR/overlay.qcow2"
  fi
  if [[ -f $OVERLAY ]]; then
    log "reusing overlay $OVERLAY (delete it to reset the guest)"
  else
    # -b needs an absolute path: qcow2 stores it in the overlay header and it is resolved
    # relative to the OVERLAY's directory, not the caller's cwd, when the two differ.
    qemu-img create -q -f qcow2 -F raw -b "$(realpath -- "$IMG")" "$OVERLAY" "$DISK_SIZE" \
      || die "could not create overlay $OVERLAY"
    log "overlay $OVERLAY: $DISK_SIZE virtual disk over a $((img_bytes / 1024 / 1024)) MiB image"
  fi
  # snapshot= is deliberately absent: the overlay IS the scratch layer, and setting
  # snapshot=on over it would add a second one and discard the persistence --writable asked for.
  DISK_ARG="file=$OVERLAY,if=virtio,format=qcow2"
fi

ACCEL=tcg; [[ -e /dev/kvm ]] && ACCEL=kvm
# shellcheck disable=SC2054  # commas are QEMU option syntax, not element separators
QEMU=(qemu-system-x86_64
  -machine "q35,accel=$ACCEL" -cpu max -m "$MEM" -smp 4
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
  -drive if=pflash,format=raw,file="$VMDIR/VARS.fd"
  # snapshot=on (default): guest writes go to a temp overlay and the backing file is opened
  # read-only, so an interactive run can never mutate the image it was pointed at (and
  # root-owned build artifacts boot without O_RDWR). Discarded on exit.
  #
  # --writable (snapshot=off) exists because that default silently breaks any test spanning
  # TWO boots: everything the first boot writes to /var — the machine-id systemd generates
  # into the /etc overlay, and a sysupdate'd root slot — is thrown away before the second
  # boot starts. Stage 70 asserts both of those persist, so with snapshot=on the smoke test's
  # machine-id check could only ever pass by accident and the update E2E could not work at
  # all. Stage 70 boots a throwaway copy in $WORK, so mutating it is safe and is the point.
  #
  # --disk-size replaces this with a qcow2 overlay of a larger virtual size; see above.
  -drive "$DISK_ARG"
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
  # -vga none suppresses q35's default VGA adapter, which would otherwise sit alongside
  # virtio-gpu and give the guest two heads (two tabs in the QEMU window). The kernel
  # console still goes to the serial port, not to this display.
  -vga none -device virtio-gpu)

if [[ -n $TEST_MODE ]]; then
  QEMU+=(-smbios "type=11,value=io.systemd.credential:${DISTRO_ID}.test=${TEST_MODE}")
  [[ -n $TEST_URL ]] && QEMU+=(-smbios "type=11,value=io.systemd.credential:${DISTRO_ID}.update_url=${TEST_URL}")
fi

if [[ -n $HEADLESS_LOG ]]; then
  QEMU+=(-display none -serial "file:$HEADLESS_LOG")
else
  QEMU+=(-serial stdio)
fi

log "accel=$ACCEL firmware=$OVMF_CODE"
exec "${QEMU[@]}"
