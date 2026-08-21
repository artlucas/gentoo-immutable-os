# shellcheck shell=bash
# shellcheck disable=SC2034  # most variables set here are consumed by sourcing scripts
# common.sh — shared library for all build scripts. Bash 4+.
# Pure functions here are unit-tested on any platform (tests/); functions that
# mount/chroot are Linux-only and guarded.

[[ -n ${_IMMOS_COMMON_LOADED:-} ]] && return 0
_IMMOS_COMMON_LOADED=1

set -euo pipefail

# ---- paths (overridable for tests; container uses the defaults) -------------
: "${REPO:=/repo}"
: "${WORK:=/work}"
: "${OUT:=/out}"

STAGE_NAME="${STAGE_NAME:-$(basename -- "${BASH_SOURCE[-1]:-main}" .sh)}"

# ---- logging ----------------------------------------------------------------
log()  { printf '[%s] %s\n' "$STAGE_NAME" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$STAGE_NAME" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$STAGE_NAME" "$*" >&2; exit 1; }

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

is_linux() { [[ $(uname -s) == Linux ]]; }

# ---- config ------------------------------------------------------------------
load_config() {
  local f="${1:-$REPO/config/build.conf}"
  [[ -f $f ]] || die "config not found: $f"
  # shellcheck source=/dev/null
  source "$f"
  # host-provided overrides (build.sh flags travel as env vars into the container)
  [[ -n ${VERSION_OVERRIDE:-}       ]] && VERSION="$VERSION_OVERRIDE"
  [[ -n ${UPDATE_URL_OVERRIDE:-}    ]] && UPDATE_URL="$UPDATE_URL_OVERRIDE"
  [[ -n ${UPDATE_VERIFY_OVERRIDE:-} ]] && UPDATE_VERIFY="$UPDATE_VERIFY_OVERRIDE"
  : "${CONSOLE_ONLY:=0}"
  validate_config
  init_paths
}

validate_config() {
  local v
  for v in DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL UPDATE_CHANNEL UPDATE_VERIFY \
           BUILDER_IMAGE SNAPSHOT_DATE PROFILE BINHOST_URI \
           ESP_SIZE_MIB ROOT_SLOT_SIZE_MIB VAR_SIZE_MIB EROFS_COMPRESSION \
           LIVE_USER LOCALE_GEN LOCALES_KEEP FLATPAK_PREINSTALL_MODE; do
    [[ -n ${!v:-} ]] || die "build.conf: $v is required"
  done
  [[ $DISTRO_ID =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "build.conf: DISTRO_ID must match [a-z][a-z0-9-]* (got: $DISTRO_ID)"
  version_valid "$VERSION" || die "build.conf: VERSION must be X.Y.Z (got: $VERSION)"
  local n
  for n in ESP_SIZE_MIB ROOT_SLOT_SIZE_MIB VAR_SIZE_MIB; do
    [[ ${!n} =~ ^[0-9]+$ ]] || die "build.conf: $n must be an integer MiB count"
  done
  [[ $UPDATE_VERIFY =~ ^[01]$ ]] || die "build.conf: UPDATE_VERIFY must be 0 or 1"
  [[ $FLATPAK_PREINSTALL_MODE =~ ^(build|firstboot)$ ]] \
    || die "build.conf: FLATPAK_PREINSTALL_MODE must be build|firstboot"
  [[ $SNAPSHOT_DATE =~ ^[0-9]{8}$ ]] || die "build.conf: SNAPSHOT_DATE must be YYYYMMDD"
}

init_paths() {
  TARGET="$WORK/target"
  CONFIG_ROOT="$WORK/config"            # assembled portage --config-root (stage 20)
  UKI_DIR="$OUT/uki"
  STATE_DIR="$OUT/state"
  REPORT_DIR="$OUT/reports"
  RELEASE_DIR="$OUT/release/$UPDATE_CHANNEL"
  IMG_NAME="${DISTRO_ID}-${VERSION}.img"
  UKI_NAME="${DISTRO_ID}_${VERSION}.efi"
  ROOT_IMG_NAME="${DISTRO_ID}_${VERSION}.root.erofs"
  ROOT_PARTLABEL="root_${VERSION}"
}

# ---- versions -----------------------------------------------------------------
version_valid() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# version_gt A B: true if A > B (GNU sort -V ordering, same family as strverscmp)
version_gt() {
  [[ $1 != "$2" ]] && [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# ---- templates ------------------------------------------------------------------
# render_template SRC DST — replaces @NAME@ tokens with the value of variable NAME.
# Fails on tokens whose variable is unset (typos die loudly, at build time).
render_template() {
  local src=$1 dst=$2 content name t
  [[ -f $src ]] || die "template not found: $src"
  content="$(cat -- "$src"; printf x)"; content="${content%x}"
  local tokens
  tokens="$(grep -oE '@[A-Z][A-Z0-9_]*@' -- "$src" | sort -u || true)"
  for t in $tokens; do
    name="${t//@/}"
    [[ -n ${!name+x} ]] || die "template $src: variable $name is unset"
    content="${content//"$t"/${!name}}"
  done
  printf '%s' "$content" > "$dst"
}

# render_dest_name BASENAME — strips a trailing .in and rewrites every "distro"
# token in the basename to "${DISTRO_ID}" (files in config/rootfs use "distro" in
# their names so the distro can be renamed in build.conf alone; e.g.
# distro-update.in → immos-update, 50-distro.preset.in → 50-immos.preset).
render_dest_name() {
  local name=$1
  name="${name%.in}"
  name="${name//distro/${DISTRO_ID}}"
  printf '%s' "$name"
}

# install_rootfs_overlay SRC_ROOT DST_ROOT — copies the config/rootfs tree onto the
# target: *.in files are rendered, "distro-" basenames rebranded, permissions set
# explicitly (the repo may live on NTFS: exec bits are unreliable there).
install_rootfs_overlay() {
  local src_root=$1 dst_root=$2
  [[ -d $src_root ]] || die "overlay source missing: $src_root"
  local f rel dir base dst mode
  while IFS= read -r -d '' f; do
    rel="${f#"$src_root"/}"
    dir="$(dirname -- "$rel")"
    base="$(render_dest_name "$(basename -- "$rel")")"
    [[ $dir == . ]] && dst="$dst_root/$base" || dst="$dst_root/$dir/$base"
    mkdir -p -- "$(dirname -- "$dst")"
    if [[ $f == *.in ]]; then
      render_template "$f" "$dst"
    else
      cp -- "$f" "$dst"
    fi
    mode=0644
    case "/$dir/$base" in
      */bin/*|*.sh) mode=0755 ;;
    esac
    chmod "$mode" -- "$dst"
  done < <(find "$src_root" -type f -print0)
}

# ---- GPT / image layout (pure math; unit-tested) ---------------------------------
GPT_TYPE_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
GPT_TYPE_ROOT_X64="4F68BC64-6ACB-4AA4-B891-DB7CD79ABF44"
GPT_TYPE_VAR="4D21B016-B534-45C2-A9FB-5C16E091FD2D"

# compute_layout ESP_MIB SLOT_MIB VAR_MIB — sets P{1..4}_START_MIB/_SIZE_MIB and
# TOTAL_MIB. 1 MiB leading alignment gap + 1 MiB trailing slack for the backup GPT.
compute_layout() {
  local esp=$1 slot=$2 var=$3
  P1_START_MIB=1;                              P1_SIZE_MIB=$esp
  P2_START_MIB=$((P1_START_MIB + P1_SIZE_MIB)); P2_SIZE_MIB=$slot
  P3_START_MIB=$((P2_START_MIB + P2_SIZE_MIB)); P3_SIZE_MIB=$slot
  P4_START_MIB=$((P3_START_MIB + P3_SIZE_MIB)); P4_SIZE_MIB=$var
  TOTAL_MIB=$((P4_START_MIB + P4_SIZE_MIB + 1))
}

# emit_sfdisk_script VERSION — prints the sfdisk input for the computed layout.
# compute_layout must have been called first.
emit_sfdisk_script() {
  local version=$1
  [[ -n ${TOTAL_MIB:-} ]] || die "emit_sfdisk_script: call compute_layout first"
  cat <<EOF
label: gpt
start=${P1_START_MIB}MiB, size=${P1_SIZE_MIB}MiB, type=${GPT_TYPE_ESP}, name="esp"
start=${P2_START_MIB}MiB, size=${P2_SIZE_MIB}MiB, type=${GPT_TYPE_ROOT_X64}, name="root_${version}"
start=${P3_START_MIB}MiB, size=${P3_SIZE_MIB}MiB, type=${GPT_TYPE_ROOT_X64}, name="_empty"
start=${P4_START_MIB}MiB, size=${P4_SIZE_MIB}MiB, type=${GPT_TYPE_VAR}, name="var"
EOF
}

# ---- stage stamps (resume support) -------------------------------------------------
sha256_file() { sha256sum -- "$1" | cut -d' ' -f1; }

# inputs_hash [FILES...] — stable hash of the given files' contents plus
# $STAGE_INPUTS_EXTRA (for non-file inputs like config values).
inputs_hash() {
  local f
  {
    for f in "$@"; do
      [[ -f $f ]] && sha256_file "$f" || printf 'missing:%s\n' "$f"
    done
    printf '%s\n' "${STAGE_INPUTS_EXTRA:-}"
  } | sha256sum | cut -d' ' -f1
}

stamp_path()    { printf '%s/%s.done' "$STATE_DIR" "$1"; }
stamp_matches() { local s; s="$(stamp_path "$1")"; [[ -f $s && $(cat -- "$s") == "$2" ]]; }
stamp_write()   { mkdir -p -- "$STATE_DIR"; printf '%s' "$2" > "$(stamp_path "$1")"; }

# seed_merged_usr TARGET — create the merged-/usr symlink layout in an empty target root.
#
# A stage3 tarball ships /bin, /sbin, /lib and /lib64 as symlinks into /usr. This pipeline's
# target starts life as a bare mkdir, so without seeding, the first package that installs to
# /bin creates it as a REAL directory and every later package follows suit: the result is a
# split-usr root where bash, sh, mount, login, kmod and glibc itself live in /bin and /lib
# while the other ~1300 binaries live in /usr/bin. The 23.0 profile is merged-usr, and
# systemd >=255 refuses to boot a split-usr system, so such an image never comes up. It also
# silently breaks every /usr/lib/modules and /usr/lib/firmware path the later stages use.
seed_merged_usr() {
  local t=$1 d
  ensure_dir "$t/usr/bin" "$t/usr/sbin" "$t/usr/lib" "$t/usr/lib64"
  for d in bin sbin lib lib64; do
    [[ -L $t/$d ]] && continue
    [[ -d $t/$d ]] && die "target has a real /$d directory — it was populated before the
  merged-/usr symlinks existed (split-usr). Wipe the work volume and re-run stage 30:
  docker volume rm -f \${DISTRO_ID:-immos}-work"
    ln -s "usr/$d" "$t/$d"
  done
}

# seed_target_dirs TARGET — create the directories a stage3 tarball would ship but that no
# package owns. sys-apps/baselayout declares none of these in CONTENTS, so on a target built
# from an empty directory they simply never appear.
#
# They are needed twice over: stage 40 bind-mounts /proc, /sys and /dev to run the chroot
# finalizers ("mount: /work/target/proc: mount point does not exist"), and the booted image
# needs them as mount points — systemd cannot create them itself on a read-only erofs root.
seed_target_dirs() {
  local t=$1
  ensure_dir "$t"/{proc,sys,dev,dev/pts,run,mnt,media,boot,var/tmp,var/log,var/cache}
  ensure_dir "$t/usr/lib/locale"   # glibc's locale-archive lives here; localedef will not create it
  chmod 0555 "$t/proc" "$t/sys"
  ensure_dir "$t/tmp"; chmod 1777 "$t/tmp" "$t/var/tmp"
}

# mirror_target_pkg_config — copy the assembled target package.use/keywords/license onto the
# builder's own "/etc/portage".
#
# Portage's depgraph evaluates target packages against "/"'s profile + package.use as well as
# the target's (see the long note in builder/Dockerfile), so a flag set only for the target
# yields a second, differently-configured instance of the same package in the graph — phantom
# slot conflicts and REQUIRED_USE failures blamed on packages we never asked for on "/".
#
# This must run in EVERY container that resolves a depgraph, not once: build.sh dispatches
# each stage into its own `docker run --rm`, so anything written to /etc/portage by stage 20
# is gone by the time stage 30 starts. Cheap and idempotent, so stages just call it.
mirror_target_pkg_config() {
  local pc="${1:-$CONFIG_ROOT/etc/portage}" bpc=/etc/portage d
  [[ -d $pc ]] || die "mirror_target_pkg_config: no config-root at $pc (run stage 20 first)"
  for d in package.use package.accept_keywords package.license package.mask; do
    ensure_dir "$bpc/$d"
    # sorts after the Dockerfile's own "builder" file, so these win where the two disagree
    cat "$pc/$d"/* > "$bpc/$d/zz-target-mirror" 2>/dev/null || :
  done
}

# ---- chroot into the target (Linux/container only) ----------------------------------
_TARGET_MOUNTS=(proc sys dev dev/pts run)

target_mount() {
  is_linux || die "target_mount: Linux only"
  local t=$1
  # cheap insurance: a resumed build may have a target that predates seed_target_dirs
  mkdir -p -- "$t"/{proc,sys,dev,dev/pts,run}
  mount -t proc proc "$t/proc"
  mount --rbind /sys "$t/sys";  mount --make-rslave "$t/sys"
  mount --rbind /dev "$t/dev";  mount --make-rslave "$t/dev"
  mount -t tmpfs tmpfs "$t/run"
  # DNS for the chroot, without leaking the builder's nameservers into the image.
  # From stage 40 on, $t/etc/resolv.conf is a DANGLING symlink to systemd-resolved's stub
  # under /run — and /run is the tmpfs mounted just above. Copying the builder's resolv.conf
  # to that path therefore writes THROUGH the symlink into the tmpfs (cp follows a symlinked
  # destination), so the chroot resolves normally and the copy dies with the tmpfs at
  # target_umount. Before stage 40 the path does not exist yet and this writes a plain file,
  # which stage 50 removes. Either way -e is false at this point; the test is written as
  # "not present, or present only as a symlink" so an already-materialised file is not
  # clobbered on a resumed build.
  if [[ -f /etc/resolv.conf ]]; then
    mkdir -p "$t/run/systemd/resolve"
    cp -L /etc/resolv.conf "$t/etc/resolv.conf.build" 2>/dev/null || true
    if [[ ! -e $t/etc/resolv.conf || -L $t/etc/resolv.conf ]]; then
      cp -L /etc/resolv.conf "$t/etc/resolv.conf" || true
    fi
  fi
}

target_umount() {
  is_linux || return 0
  local t=$1
  umount -R "$t/run"  2>/dev/null || true
  umount -R "$t/dev"  2>/dev/null || true
  umount -R "$t/sys"  2>/dev/null || true
  umount -R "$t/proc" 2>/dev/null || true
  rm -f "$t/etc/resolv.conf.build"
}

chroot_target() {
  local t=$1; shift
  chroot "$t" /bin/bash -o pipefail -euc "$*"
}

# ---- misc ---------------------------------------------------------------------------
ensure_dir() { mkdir -p -- "$@"; }

# filter_set_file SRC DST — strips '#cjk' / '#printing' marked lines when the
# corresponding build.conf switch is 0, and comment/blank lines otherwise pass through
# to portage untouched (portage ignores comments itself; markers must go though).
filter_set_file() {
  local src=$1 dst=$2 line out
  : > "$dst"
  while IFS= read -r line || [[ -n $line ]]; do
    out=$line
    if [[ $line == *'#cjk'* ]];      then [[ ${INCLUDE_CJK_FONTS:-1} == 1 ]] || continue; out="${line%%#*}"; fi
    if [[ $line == *'#printing'* ]]; then [[ ${INCLUDE_PRINTING:-1}  == 1 ]] || continue; out="${line%%#*}"; fi
    printf '%s\n' "$out" >> "$dst"
  done < "$src"
}
