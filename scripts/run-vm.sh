#!/usr/bin/env bash
# run-vm.sh — boot a built disk image in QEMU/OVMF. Used interactively and by stage 70.
#
#   run-vm.sh IMG                          # graphical window
#   run-vm.sh IMG --headless serial.log    # no display, serial console to file
#   run-vm.sh IMG --test smoke             # inject test-mode credential (self-reporting boot)
#   run-vm.sh IMG --test update --update-url http://10.0.2.2:8000/stable
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export STAGE_NAME=run-vm
# common.sh defaults REPO to the in-container /repo; interactive host runs need the real
# path. Stage 70 already exports REPO, and := leaves that alone.
: "${REPO:="$(dirname -- "$SCRIPT_DIR")"}"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IMG="${1:-}"; shift || true
[[ -n $IMG && -f $IMG ]] || die "usage: run-vm.sh IMG [--headless LOG] [--test smoke|update] [--update-url URL]"

HEADLESS_LOG='' TEST_MODE='' TEST_URL='' MEM=4096
while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)   HEADLESS_LOG="$2"; shift 2 ;;
    --test)       TEST_MODE="$2"; shift 2 ;;
    --update-url) TEST_URL="$2"; shift 2 ;;
    --memory)     MEM="$2"; shift 2 ;;
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

ACCEL=tcg; [[ -e /dev/kvm ]] && ACCEL=kvm
# shellcheck disable=SC2054  # commas are QEMU option syntax, not element separators
QEMU=(qemu-system-x86_64
  -machine "q35,accel=$ACCEL" -cpu max -m "$MEM" -smp 4
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
  -drive if=pflash,format=raw,file="$VMDIR/VARS.fd"
  # snapshot=on: guest writes go to a temp overlay and the backing file is opened
  # read-only, so a run can never mutate the image it was pointed at (and root-owned
  # build artifacts boot without O_RDWR). Discarded on exit; reboots within one run persist.
  -drive file="$IMG",if=virtio,format=raw,snapshot=on
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
  -device virtio-gpu)

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
