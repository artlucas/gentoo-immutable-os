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
  # Defaulted rather than required: a build.conf written before the splash-backend switch
  # existed still has to validate, and "both" — stub bitmap plus KMS splash — is the whole
  # timeline, so it is the right thing for a config that did not say.
  #
  # ${x=y}, NOT ${x:=y}. The colon form also substitutes for an EMPTY value, which would make
  # a truncated `SPLASH_BACKEND=""` silently mean "both" instead of failing — every other
  # key here dies on empty, and an empty value in a hand-edited build.conf is a typo, not a
  # request for the default. Unset defaults; empty falls through to the pattern check below.
  #
  # NB the value "plymouth" is deliberately NOT accepted as an alias for "kms". Plymouth is
  # gone (plan/14); silently reinterpreting the old name would let a stale build.conf produce
  # an image whose splash is not the one it asked for, with nothing said about it.
  : "${SPLASH_BACKEND=both}"
  : "${SPLASH_STUB_SCALE=1}"
  # Same ${x=y} reasoning as the two above: a build.conf predating the knob still validates.
  : "${DEBUG_INITRD=0}"
  # ...and again for the containers switch (plan/13). Default 1 matches filter_set_file's own
  # ${INCLUDE_DISTROBOX:-1}, so the two cannot disagree about what "unset" means.
  : "${INCLUDE_DISTROBOX=1}"
  # Set-but-possibly-empty, so that render_template's "is this variable defined?" check passes
  # for config/rootfs/etc/distrobox/distrobox.conf.in even in an INCLUDE_DISTROBOX=0 build,
  # where stage 40 deletes the rendered file again. The non-empty requirement is asserted below
  # and only when the switch is on.
  : "${DISTROBOX_DEFAULT_IMAGE=}"
  local v
  for v in DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL UPDATE_CHANNEL UPDATE_VERIFY \
           BUILDER_IMAGE SNAPSHOT_DATE SNAPSHOT_SHA256 PROFILE BINHOST_URI \
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
  [[ $SPLASH_BACKEND =~ ^(kms|stub|both|none)$ ]] \
    || die "build.conf: SPLASH_BACKEND must be kms|stub|both|none (got: $SPLASH_BACKEND)"
  [[ $SPLASH_STUB_SCALE =~ ^[1-9][0-9]*$ ]] \
    || die "build.conf: SPLASH_STUB_SCALE must be a positive integer (got: $SPLASH_STUB_SCALE)"
  [[ $DEBUG_INITRD =~ ^[01]$ ]] || die "build.conf: DEBUG_INITRD must be 0 or 1"
  [[ $INCLUDE_DISTROBOX =~ ^[01]$ ]] \
    || die "build.conf: INCLUDE_DISTROBOX must be 0 or 1 (got: $INCLUDE_DISTROBOX)"
  # Only required when the switch is on: an image built without distrobox has no use for it,
  # and demanding it there would fail builds that legitimately never set the key.
  [[ $INCLUDE_DISTROBOX == 0 || -n $DISTROBOX_DEFAULT_IMAGE ]] \
    || die "build.conf: DISTROBOX_DEFAULT_IMAGE is required when INCLUDE_DISTROBOX=1"
  [[ $FLATPAK_PREINSTALL_MODE =~ ^(build|firstboot)$ ]] \
    || die "build.conf: FLATPAK_PREINSTALL_MODE must be build|firstboot"
  [[ $SNAPSHOT_DATE =~ ^[0-9]{8}$ ]] || die "build.conf: SNAPSHOT_DATE must be YYYYMMDD"
  # Full 64-hex. This is what makes a vendored snapshot verifiable years after upstream has
  # dropped it, so a truncated or absent value is a pin that cannot be checked.
  [[ $SNAPSHOT_SHA256 =~ ^[0-9a-f]{64}$ ]] \
    || die "build.conf: SNAPSHOT_SHA256 must be a full 64-character sha256 (got: $SNAPSHOT_SHA256)"
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
#
# "Token" is meant literally: the name is split on '-' and '.', and only a segment that is
# EXACTLY "distro" is rebranded. This used to be a plain substring replacement, which silently
# mangles any filename that merely contains the word — config/rootfs/etc/distrobox.conf.in
# installed itself as /etc/distrobox/immosbox.conf, a config file distrobox never reads and
# nothing would have reported. Every name the overlay actually ships (distro-update,
# 50-distro.preset, distro-boot-ok.service, ...) uses the word as a whole token, so the two
# rules agree on all of them and differ only where the old one was wrong.
render_dest_name() {
  local name=$1 out="" seg delim rest
  name="${name%.in}"
  rest="$name"
  while [[ -n $rest ]]; do
    if [[ $rest =~ ^([^-.]*)([-.])(.*)$ ]]; then
      seg="${BASH_REMATCH[1]}"; delim="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    else
      seg="$rest"; delim=""; rest=""
    fi
    [[ $seg == distro ]] && seg="$DISTRO_ID"
    out+="$seg$delim"
  done
  printf '%s' "$out"
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

# ---- branding / boot splash ------------------------------------------------------
# The zoom factor SVG sources are rasterised at. Everything in config/branding is authored in
# pixels at the 1920x1080 design baseline, and config/branding/make-splash-assets.py divides by
# the same number (ASSET_ZOOM there) — changing it in one place only silently resizes the splash.
BRANDING_ZOOM=4

# render_branding SRC_DIR OUT_DIR — rasterise the branding SVGs for the splash generator.
#   *.svg / *.svg.in  → OUT_DIR/<name>.png at BRANDING_ZOOM (templates rendered first)
#   anything else (README, the wordmark generator, the python) is ignored on purpose.
#
# OUT_DIR is a BUILD directory, not a path in the image. Nothing here ships: the PNGs are the
# input to make-splash-assets.py, which composes them into the two artefacts that do ship — the
# UKI's .splash bitmap and the KMS splash's tile container. That is the whole reason the image
# needs no image decoder and no font at boot.
render_branding() {
  local src=$1 dst=$2
  [[ -d $src ]] || die "branding source missing: $src"
  require_cmds rsvg-convert
  ensure_dir "$dst"
  local f base name svg tmp=""
  for f in "$src"/*; do
    [[ -f $f ]] || continue
    base="$(basename -- "$f")"
    case "$base" in
      *.svg|*.svg.in)
        name="${base%.in}"; name="${name%.svg}"
        svg="$f"
        if [[ $f == *.in ]]; then
          tmp="$(mktemp)"; render_template "$f" "$tmp"; svg="$tmp"
        fi
        rsvg-convert -z "$BRANDING_ZOOM" -o "$dst/$name.png" "$svg" \
          || die "rsvg-convert failed on $base"
        # rsvg-convert exits 0 on an SVG it could not draw (a missing font, say), so the
        # size is the only evidence that anything was actually rendered.
        [[ -s $dst/$name.png ]] || die "branding: $name.png is empty — did rsvg-convert find the font?"
        chmod 0644 -- "$dst/$name.png"
        # A plain `if`, not `[[ -n $tmp ]] && { ...; }`: under `set -e` the && form makes the
        # whole function return 1 whenever the last file processed took the false branch, and
        # stages would abort here having done all the work correctly.
        if [[ -n $tmp ]]; then rm -f -- "$tmp"; tmp=""; fi
        ;;
    esac
  done
  return 0   # never let the last iteration's case status become the function's
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
# portage_config_hash — fingerprint of everything stage 20 bakes into $CONFIG_ROOT.
#
# expected-packages.txt is deliberately excluded: it is the audit gate's DATA, not an input to
# the config root, and it is rewritten every time the package set legitimately changes — hashing
# it would make the guards below fire on their own output.
#
# config/portage/lock/ is excluded for the same reason, one step stronger. The locks do not just
# record the resolution, they CONSTRAIN it (stage 30 emerges @locked-image), and each lock header
# records the portage_config_hash it was generated under. Hashing the locks here would make that
# recorded value depend on the file recording it — a hash that can never be reproduced, and a
# guard that fires on every relock forever. The one-way assertion in stage 20 (header hash vs
# current hash) is what catches "the config changed and the lock did not", without the cycle.
#
# tests/test-pin-policy.sh asserts both exclusions are still here. A future edit that drops one
# reintroduces the loop silently — the symptom is a build that cannot be made to pass.
# PATHS ARE RELATIVE, and that is not cosmetic: sha256sum prints the filename alongside the
# digest, so hashing absolute paths made this value depend on WHERE the repo is checked out.
# The host computes /home/you/immos/config/... and the container computes /repo/config/...,
# giving two different "config hashes" for one identical config. That was invisible while the
# value was only ever written and read inside containers (stage 20 -> stage 30), and it stops
# being invisible the moment the hash is recorded in a committed file, as the locks do.
# LC_ALL=C for the sort for the same reason the locks use it: collation must not vary.
portage_config_hash() {
  (
    cd "$REPO" || return 1
    {
      find config/portage -type f ! -name 'expected-packages.txt' \
           ! -path 'config/portage/lock/*' -print0 \
        | LC_ALL=C sort -z | xargs -0 -r sha256sum
      sha256sum config/build.conf
    } | sha256sum | cut -d' ' -f1
  )
}

# ---- the ebuild tree pin (plan/15) -----------------------------------------------------
# The tree lives in the ${DISTRO_ID}-tree named volume mounted at /var/db/repos, NOT in a
# builder image layer. That distinction is the whole fix: before this, stage 10 synced the tree
# inside a `docker run --rm` and the result died with the container, so stages 20 and 30
# resolved against whatever the un-cache-busted `RUN emerge-webrsync` layer happened to hold.
TREE_DIR="${TREE_DIR:-/var/db/repos}"
TREE_MARKER_NAME=".tree-pin"

tree_marker_path() { printf '%s/%s' "$TREE_DIR" "$TREE_MARKER_NAME"; }
tree_marker_read() { cat -- "$(tree_marker_path)" 2>/dev/null || printf 'none'; }
tree_pin_id()      { printf '%s %s' "$SNAPSHOT_DATE" "$SNAPSHOT_SHA256"; }

snapshot_tarball_name() { printf 'gentoo-%s.tar.xz' "$SNAPSHOT_DATE"; }

# Where the snapshot is KEPT, as opposed to where webrsync happens to drop it.
#
# emerge-webrsync writes to portage's DISTDIR, which for the builder's own "/" is
# /var/cache/distfiles — inside the container, so it dies with the stage that fetched it. The
# tarball is the one artifact SNAPSHOT_SHA256 pins and upstream signed, and stage 90 archives
# it, so it has to outlive its stage: /cache is a named volume and does.
snapshot_cache_dir() { printf '%s' "${SNAPSHOT_CACHE_DIR:-/cache/distfiles}"; }
snapshot_cached_path() { printf '%s/%s' "$(snapshot_cache_dir)" "$(snapshot_tarball_name)"; }

# tree_date — the checked-out tree's snapshot date as YYYYMMDD, or "" if unreadable.
tree_date() {
  local ts="$TREE_DIR/gentoo/metadata/timestamp.chk"
  [[ -f $ts ]] || return 0
  date -u -d "$(cat -- "$ts")" +%Y%m%d 2>/dev/null || true
}

# tree_validate DIR — everything portage needs a repo to be, asserted before it is trusted.
#
# The Manifest check is not paranoia; it is the bug it was written for. A tree fetched from
# github.com/gentoo-mirror/gentoo has metadata/md5-cache and a plausible timestamp.chk, passes
# every other check here, and then fails 90 minutes later in stage 30 with "A file is not
# listed in the Manifest" — because that mirror is the development repo, whose Manifests hold
# only DIST lines, while its layout.conf claims thin-manifests = false. Checking one known
# package's Manifest for an EBUILD line costs nothing and catches the whole class.
tree_validate() {
  local d=${1:?tree_validate: dir required}
  [[ -d $d/metadata/md5-cache ]] \
    || die "tree at $d has no metadata/md5-cache — not a synced rsync tree"
  [[ -f $d/metadata/timestamp.chk ]] \
    || die "tree at $d has no metadata/timestamp.chk"
  local thin probe
  thin="$(sed -nE 's/^[[:space:]]*thin-manifests[[:space:]]*=[[:space:]]*([a-z]+).*/\1/p' \
            "$d/metadata/layout.conf" 2>/dev/null | head -n1)"
  probe="$d/sys-apps/systemd/Manifest"
  if [[ ${thin:-false} != true && -f $probe ]]; then
    grep -q '^EBUILD ' "$probe" || die "tree at $d declares thin-manifests=${thin:-false} but its
  Manifests list no EBUILD entries (checked sys-apps/systemd). Portage will verify ebuilds it
  cannot find listed and refuse to merge them. This is what a tree fetched from the DEVELOPMENT
  repo looks like; the rsync snapshots on distfiles.gentoo.org are full-Manifest trees."
  fi
}

# tree_assert — the guard every depgraph-resolving stage runs before it resolves anything.
# Cheap and idempotent: each stage is its own container, so this cannot be done once.
tree_assert() {
  local have want; have="$(tree_marker_read)"; want="$(tree_pin_id)"
  [[ $have == "$want" ]] || die "the ebuild tree at $TREE_DIR is pinned to '$have',
  but build.conf says '$want'. The tree volume outlived a pin bump.
  Re-run stage 10 to reconcile it:  scripts/build.sh --only 10"
  # NOT compared against SNAPSHOT_DATE. Upstream's snapshot filename is offset from the tree it
  # contains: gentoo-20260820.tar.xz unpacks to a tree whose metadata/timestamp.chk reads
  # 2026-08-21 (the snapshot is cut just after midnight UTC the following day, and its GPG
  # signature is timestamped 2026-08-21 00:50). An equality check here therefore fails on a
  # perfectly good tree, which is exactly what it did the first time this ran.
  #
  # Nothing is lost by dropping it, because SNAPSHOT_SHA256 is the stronger claim and is
  # already in the marker compared above: it pins the exact bytes, verified at populate time
  # against a tarball whose upstream GPG signature was also checked. The date is a filename.
  #
  # SNAPSHOT_DATE still feeds SOURCE_DATE_EPOCH in stage 60, which only requires a stable
  # non-zero value — being a day off the tree's own timestamp is immaterial there.
  local d; d="$(tree_date)"
  [[ -n $d ]] || die "the pinned tree at $TREE_DIR has no readable metadata/timestamp.chk"
}

# tree_populate [TARBALL] — put the pinned tree at $TREE_DIR/gentoo, from a local tarball if one
# is given (the vendored archive), otherwise via emerge-webrsync.
#
# emerge-webrsync rather than a plain download: it verifies upstream's published digest AND its
# GPG signature (check_file_digest / check_file_signature) before unpacking, so the trust chain
# is upstream's rather than ours. --keep retains the tarball in DISTDIR, which is how the sha256
# below can be checked at all and how stage 90 archives it.
#
# ORDER IS LOAD-BEARING, and it is the one failure that would survive every other assertion
# here: validate, then move into place, then write the marker LAST. Writing the marker before
# the tree is known good turns a half-finished sync into a tree permanently marked correct,
# which tree_assert would then agree with forever.
tree_populate() {
  local tarball=${1:-} tmp="$TREE_DIR/.tree-incoming"
  ensure_dir "$TREE_DIR"
  rm -rf -- "$tmp"; ensure_dir "$tmp"

  if [[ -n $tarball ]]; then
    [[ -f $tarball ]] || die "tree tarball not found: $tarball"
    if [[ -n ${SNAPSHOT_SHA256:-} ]]; then
      local got; got="$(sha256_file "$tarball")"
      [[ $got == "$SNAPSHOT_SHA256" ]] || die "vendored tree tarball has sha256 $got,
  build.conf says $SNAPSHOT_SHA256 — the archive does not match this config"
    fi
    log "unpacking pinned tree from $tarball"
    tar -xf "$tarball" -C "$tmp" --strip-components=1
  else
    log "syncing pinned tree snapshot $SNAPSHOT_DATE via emerge-webrsync"
    # webrsync unpacks into the repo location itself, so let it, then adopt the result.
    emerge-webrsync --revert="$SNAPSHOT_DATE" --keep \
      || die "could not sync the pinned snapshot gentoo-$SNAPSHOT_DATE.tar.xz.
  distfiles.gentoo.org keeps roughly nine days of snapshots, so an older pin 404s here — that is
  what stage 90's archive exists to prevent. Move the pin to a live snapshot, or restore from a
  vendored archive:  build.sh --offline --vendor-dir DIR"
    rm -rf -- "$tmp"
    snapshot_park_kept_tarball
    tree_verify_kept_tarball
    tree_validate "$TREE_DIR/gentoo"
    printf '%s' "$(tree_pin_id)" > "$(tree_marker_path)"
    return 0
  fi

  tree_validate "$tmp"
  rm -rf -- "$TREE_DIR/gentoo"
  mv -- "$tmp" "$TREE_DIR/gentoo"
  printf '%s' "$(tree_pin_id)" > "$(tree_marker_path)"    # last, deliberately
}

# snapshot_park_kept_tarball — move webrsync's --keep output into the persistent cache, with
# its signature and digest alongside, so stage 90 can archive the authentic upstream artifact
# rather than a re-tarred copy of the unpacked tree.
snapshot_park_kept_tarball() {
  local dd f dest; dest="$(snapshot_cache_dir)"
  dd="$(portageq envvar DISTDIR 2>/dev/null || true)"
  [[ -n $dd && -d $dd ]] || return 0
  [[ $dd -ef $dest ]] && return 0          # already the same directory
  ensure_dir "$dest"
  for f in "$(snapshot_tarball_name)" "$(snapshot_tarball_name).gpgsig" "$(snapshot_tarball_name).md5sum"; do
    [[ -f $dd/$f ]] && cp -f -- "$dd/$f" "$dest/$f"
  done
  [[ -f $dest/$(snapshot_tarball_name) ]] \
    && log "parked $(snapshot_tarball_name) in $dest (survives the stage boundary)"
  return 0
}

# share_builder_distdir — point the BUILDER's own "/" at the same DISTDIR the target uses.
#
# The two-root emerge otherwise has two of them, and only one persists. Target packages use the
# config root's DISTDIR (/cache/distfiles, a named volume); anything portage resolves for "/"
# uses the builder's, which is /var/cache/distfiles — inside the container.
#
# That asymmetry breaks an offline build in BOTH directions, and it took two failed attempts to
# see the second one. Fetching: sources for builder-root packages are downloaded and then thrown
# away with the container, so they never reach the archive. Restoring: seeding the archive into
# /cache/distfiles does not help either, because the builder-root merge does not look there.
# One DISTDIR removes the whole class rather than patching each direction separately.
#
# Written per stage, like mirror_target_pkg_config and for the same reason: every stage is its
# own `docker run --rm`, so nothing written to /etc/portage survives to the next. Idempotent.
share_builder_distdir() {
  local dest; dest="$(snapshot_cache_dir)"
  ensure_dir "$dest"
  grep -qs "^DISTDIR=\"$dest\"" /etc/portage/make.conf \
    || printf 'DISTDIR="%s"\n' "$dest" >> /etc/portage/make.conf
}

# distfiles_sweep — move anything portage downloaded into the BUILDER's own DISTDIR across to
# the persistent cache. Belt-and-braces now that share_builder_distdir makes them one directory:
# a no-op in that case, and still correct if some path bypasses it.
#
# The two-root emerge has two DISTDIRs. Target packages use the config root's
# (/cache/distfiles, a named volume, which stage 90 archives); packages resolved for the
# builder's own "/" use the builder's, which is /var/cache/distfiles — inside the container, so
# it dies with the stage.
#
# That is not a corner case: stage 30 installs DEPENDs to "/" even under --with-bdeps=n, so a
# real build needs those sources. It cost an offline rebuild, which reached package 226 of 657
# and could not fetch sys-kernel/installkernel-68 — a file stage 90 HAD downloaded, into the
# directory that does not survive the container.
distfiles_sweep() {
  local dd dest n=0; dest="$(snapshot_cache_dir)"
  dd="$(portageq envvar DISTDIR 2>/dev/null || true)"
  [[ -n $dd && -d $dd ]] || return 0
  [[ $dd -ef $dest ]] && return 0
  ensure_dir "$dest"
  local f
  while IFS= read -r -d '' f; do
    [[ -f $dest/${f##*/} ]] && continue
    cp -f -- "$f" "$dest/${f##*/}" && n=$((n + 1))
  done < <(find "$dd" -maxdepth 1 -type f ! -name '*.__download__' -print0 2>/dev/null)
  (( n > 0 )) && log "swept $n distfile(s) from the builder DISTDIR into $dest"
  return 0
}

# tree_verify_kept_tarball — check the snapshot against SNAPSHOT_SHA256. Upstream's signature
# says the file is Gentoo's; this says it is the same one this config was pinned to and locked
# against.
tree_verify_kept_tarball() {
  local tb got
  tb="$(snapshot_cached_path)"
  if [[ ! -f $tb ]]; then
    tb="$(portageq envvar DISTDIR 2>/dev/null || echo /cache/distfiles)/$(snapshot_tarball_name)"
  fi
  if [[ ! -f $tb ]]; then
    warn "no $(snapshot_tarball_name) on disk — cannot check SNAPSHOT_SHA256"
    return 0
  fi
  got="$(sha256_file "$tb")"
  if [[ -z ${SNAPSHOT_SHA256:-} ]]; then
    warn "SNAPSHOT_SHA256 is empty; the snapshot hashes to $got — record it in config/build.conf"
    return 0
  fi
  [[ $got == "$SNAPSHOT_SHA256" ]] || die "the snapshot upstream served hashes to
  $got, but config/build.conf pins $SNAPSHOT_SHA256. Same filename, different bytes."
  log "snapshot sha256 matches the pin"
}

# ---- version locks (plan/15) ---------------------------------------------------------
# A lock file is a commented header plus one exact atom per line: "=cat/pkg-1.2.3".
# Generated, never authored — the same rule config/portage/expected-packages.txt states.
LOCK_DIR="${LOCK_DIR:-$REPO/config/portage/lock}"

# lock_atoms FILE — the atoms alone, comments and blank lines stripped, sorted.
#
# LC_ALL=C, and every other sort that touches a lock does the same. Collation order is
# locale-dependent — glibc's en_US.UTF-8 ignores punctuation that C does not — so the same
# closure written on two machines would come out in two orders and diff against itself. A lock
# whose byte content depends on the builder's locale is not a lock.
lock_atoms() {
  local f=${1:?lock_atoms: file required}
  [[ -f $f ]] || return 1
  sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' -- "$f" | LC_ALL=C sort -u
}

# lock_header_value FILE KEY — read one "# KEY: value" line out of a lock header.
lock_header_value() {
  local f=${1:?} k=${2:?}
  [[ -f $f ]] || return 1
  sed -nE "s/^#[[:space:]]*${k}:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\\1/p" -- "$f" | head -n1
}

# lock_write FILE TITLE < atoms-on-stdin — write a lock with the provenance header every
# consumer asserts against. The header is the whole reason a lock is reviewable: it says which
# tree and which config produced these versions, so a diff can be judged rather than trusted.
lock_write() {
  local f=${1:?lock_write: file required} title=${2:?lock_write: title required}
  local tmp; tmp="$(mktemp)"
  {
    printf '# %s\n' "$title"
    printf '# GENERATED by scripts/relock.sh — do not hand-edit. See plan/15.\n'
    printf '#\n'
    printf '# SNAPSHOT_SHA256: %s\n'    "$SNAPSHOT_SHA256"
    printf '# SNAPSHOT_DATE: %s\n'      "$SNAPSHOT_DATE"
    printf '# PROFILE: %s\n'            "$PROFILE"
    printf '# PORTAGE_CONFIG_HASH: %s\n' "$(portage_config_hash)"
    # These four change the closure through filter_set_file, so a lock generated under one
    # setting is simply wrong for another. Recorded so that is visible rather than inferred.
    printf '# INCLUDE_CJK_FONTS: %s\n'  "${INCLUDE_CJK_FONTS:-1}"
    printf '# INCLUDE_PRINTING: %s\n'   "${INCLUDE_PRINTING:-1}"
    printf '# INCLUDE_DISTROBOX: %s\n'  "${INCLUDE_DISTROBOX:-1}"
    printf '# CONSOLE_ONLY: %s\n'       "${CONSOLE_ONLY:-0}"
    printf '#\n'
    LC_ALL=C sort -u
  } > "$tmp"
  # mktemp creates 0600 and mv preserves it, so without this the committed locks end up
  # unreadable by anyone but their author — git records 100644, so a fresh clone disagrees with
  # the machine that wrote them. It also propagates: stage 90 copies the locks into the archive,
  # where it made three manifest entries unverifiable from the host.
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$f"
}

# lock_diff OLD NEW — three sections, because they are three different kinds of news and a
# combined diff buries the first in the second. Returns 1 if anything differs.
#
# Versions are stripped with the SAME expression stage 50 uses on packages-cpv.txt
# ("-[0-9][^/]*$"), deliberately. That is what makes "expected-packages.txt is a subset of the
# version-stripped lock" a checkable invariant rather than an approximate one: two different
# rules for finding where a version starts would disagree on some atom eventually, and the
# disagreement would show up as a phantom add plus a phantom remove.
lock_diff() {
  local old=$1 new=$2
  awk '
    function name(a) { sub(/^=/, "", a); sub(/-[0-9][^\/]*$/, "", a); return a }
    FNR == NR { if ($0 !~ /^#/ && $0 != "") { o[name($0)] = $0 }; next }
    $0 !~ /^#/ && $0 != "" { n[name($0)] = $0 }
    END {
      for (k in n) if (!(k in o)) added[++na] = n[k]
      for (k in o) if (!(k in n)) removed[++nr] = o[k]
      for (k in o) if ((k in n) && o[k] != n[k]) {
        a = o[k]; b = n[k]; sub(/^=/, "", a); sub(/^=/, "", b)
        changed[++nc] = a " -> " b
      }
      drift = 0
      if (na) { drift = 1; printf "ADDED PACKAGES (%d):\n", na;   for (i = 1; i <= na; i++) print "  " added[i]   | "sort"; close("sort") }
      if (nr) { drift = 1; printf "REMOVED PACKAGES (%d):\n", nr; for (i = 1; i <= nr; i++) print "  " removed[i] | "sort"; close("sort") }
      if (nc) { drift = 1; printf "VERSION CHANGES (%d):\n", nc;  for (i = 1; i <= nc; i++) print "  " changed[i] | "sort"; close("sort") }
      if (!drift) { c = 0; for (k in n) c++; printf "no drift: %d atoms, all at their locked versions\n", c }
      exit drift
    }
  ' "$old" "$new"
}

# atom_name "=cat/pkg-1.2.3-r4" -> "cat/pkg", by stage 50's rule (see lock_diff).
atom_name() {
  printf '%s' "${1#=}" | sed -E 's/-[0-9][^/]*$//'
}

# vdb_atoms ROOT — the installed closure of a root, as lock atoms.
vdb_atoms() {
  local r=${1:?vdb_atoms: root required}
  [[ -d $r/var/db/pkg ]] || return 1
  ( cd "$r/var/db/pkg" && printf '%s\n' */* ) | sed 's|^|=|' | LC_ALL=C sort -u
}

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
#
# SBIN IS MERGED INTO BIN TOO, and that half is easy to get wrong, because a layout with a real
# /usr/sbin looks perfectly reasonable and boots. A stage3 on the 23.0 profile has:
#
#     /bin -> usr/bin     /sbin -> usr/bin     /usr/sbin -> bin     (one inode per binary)
#
# NOT /sbin -> usr/sbin with /usr/sbin a directory of its own. This pipeline seeded the latter
# until 0.3.0, which left 259 binaries in a /usr/sbin that nothing else in the system believes
# in — and the systemd units are what disbelieve it. Gentoo builds systemd with
# -Dsplit-bin=false, so every unit it ships names /usr/bin/<tool> for helpers that util-linux
# installs to sbin. The result was four dead units:
#
#     getty@.service, serial-getty@.service, console-getty.service, container-getty@.service
#         ExecStart=-/usr/bin/agetty ...        (agetty was only at /usr/sbin/agetty)
#
# i.e. THE IMAGE HAD NO TEXT CONSOLE LOGIN AT ALL, on tty1 or serial. Invisible for two
# reasons: the desktop autologins to Plasma so nobody reaches a console, and the "-" prefix on
# those ExecStart lines tells systemd to ignore the 203/EXEC, so the units respawn silently and
# never reach failed state — `systemctl --failed` stays empty and stage 70's failed_units=0
# assertion passes. It surfaced only when a serial login for manual testing never got a prompt.
# The same layout is why /usr/sbin/runuser was off the service PATH (see the note in
# usr/lib/image-test/test-report.sh.in).
seed_merged_usr() {
  local t=$1 d
  ensure_dir "$t/usr/bin" "$t/usr/lib" "$t/usr/lib64"
  # /usr/sbin first and separately: it points at bin *within* /usr, not at usr/bin from the
  # root, so it cannot go through the loop below.
  if [[ ! -L $t/usr/sbin ]]; then
    [[ -d $t/usr/sbin ]] && die "target has a real /usr/sbin directory — it was populated under
  the old sbin-split layout, and the binaries in it are invisible to every systemd unit that
  names /usr/bin/<tool>. Wipe the work volume and re-run stage 30:
  docker volume rm -f \${DISTRO_ID:-immos}-work"
    ln -s bin "$t/usr/sbin"
  fi
  # /sbin joins /bin at usr/bin — both, deliberately, not usr/sbin.
  for d in bin sbin lib lib64; do
    [[ -L $t/$d ]] && continue
    [[ -d $t/$d ]] && die "target has a real /$d directory — it was populated before the
  merged-/usr symlinks existed (split-usr). Wipe the work volume and re-run stage 30:
  docker volume rm -f \${DISTRO_ID:-immos}-work"
    case $d in
      bin|sbin) ln -s usr/bin "$t/$d" ;;
      *)        ln -s "usr/$d" "$t/$d" ;;
    esac
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

# prune_binhost_binpkgs PKGDIR — delete the binary packages the official binhost served from
# the target's binpkg cache, keep the ones this pipeline built, print how many went.
#
# The image is built from source or from this pipeline's own earlier builds: the target
# make.conf sets neither getbinpkg nor PORTAGE_BINHOST. But PKGDIR lives in the /cache volume,
# which outlives that rule and predates it, and --usepkg cannot tell where a binpkg came from
# — a binhost copy downloaded by an older build merges exactly like a locally built one. So
# without this sweep the policy holds for the download and not for the image.
#
# Provenance is readable off the package: the Gentoo binhost signs, this pipeline does not
# (FEATURES has no binpkg-signing), so a gpkg carrying *.sig members is one of theirs. Only
# gpkg is examined, because a signed binpkg only exists in that format — portage sets
# gpkg_only whenever a binrepo requires signature verification (_populate_remote in
# portage/dbapi/bintree.py), so a .tbz2 cannot have come from the verified binhost.
#
# A setup that signs its OWN binpkgs (FEATURES=binpkg-signing) would read as binhost-built
# here and lose its cache. That is not this pipeline; signing local builds is the change that
# has to revisit this.
prune_binhost_binpkgs() {
  local dir=${1:?prune_binhost_binpkgs: PKGDIR required} p listing n=0
  [[ -d $dir ]] || { printf '0'; return 0; }
  while IFS= read -r -d '' p; do
    # tar into a variable rather than `tar -tf "$p" | grep -q`: grep exits at its first match,
    # tar dies of SIGPIPE, and under pipefail the pipeline then reports failure — i.e. a
    # signed package would read as unsigned, which is the one answer that must not be wrong.
    listing="$(tar -tf "$p" 2>/dev/null)" || continue   # unreadable: not ours to delete
    grep -q '\.sig$' <<<"$listing" || continue
    rm -f -- "$p"
    n=$((n + 1))
  done < <(find "$dir" -type f -name '*.gpkg.tar' -print0)
  # The index still lists what was just deleted; portage rebuilds it on the next populate.
  if (( n > 0 )); then rm -f -- "$dir/Packages" "$dir/Packages.gz"; fi
  printf '%s' "$n"
}

# ---- hardware trees this image can never load (firmware, microcode) ------------------
# read_list_file PATH — print the meaningful lines of one of the config/*.txt hardware lists:
# comments dropped (whole-line and trailing), surrounding whitespace trimmed, blanks removed.
#
# Shared rather than repeated, because all three of these files (prune-firmware.txt,
# prune-microcode.txt, dracut-omit-drivers.txt) are mostly comment by design — the reasoning for
# each entry is the point of the file — and three near-identical sed scripts is three places for
# the parsing to drift apart.
read_list_file() {
  local f=${1:?read_list_file: path required}
  [[ -f $f ]] || die "list file not found: $f"
  sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' -- "$f"
}

# prune_hardware_trees TARGET — delete the firmware and the CPU microcode signatures this image
# can never load, per config/prune-firmware.txt and config/prune-microcode.txt.
#
# ORDERING IS THE ENTIRE POINT OF THIS FUNCTION EXISTING. The firmware prune used to live only in
# stage 50, which runs AFTER stage 40 builds the initrd — so plan/10 measured a 0.2.1 UKI still
# carrying every blob the prune list names and recorded it as an open finding ("The UKI did not
# shrink, and that is a finding"). Stage 40 now calls this immediately before dracut and stage 50
# calls it again as a guard, so the lists reach the root filesystem AND the UKI no matter which
# --from a build resumed at. Idempotent by construction: every deletion is of a path that may
# already be gone.
prune_hardware_trees() {
  local t=${1:?prune_hardware_trees: TARGET required}
  local fw="$t/usr/lib/firmware" entry f n=0 m=0
  if [[ ! -d $fw ]]; then
    warn "prune_hardware_trees: $fw does not exist — nothing to prune"
    return 0
  fi

  if [[ -f $REPO/config/prune-firmware.txt ]]; then
    while IFS= read -r entry; do
      # The list is repo-controlled, but it is also the one file here that names paths, and a
      # leading "/" or a ".." in it would delete outside the firmware tree with root privileges.
      [[ $entry == /* || $entry == *..* ]] \
        && die "prune-firmware.txt: refusing unsafe entry '$entry'"
      [[ -e $fw/$entry ]] || continue
      rm -rf -- "${fw:?}/$entry"
      n=$((n + 1))
    done < <(read_list_file "$REPO/config/prune-firmware.txt")
    log "firmware prune: removed $n tree(s) named in prune-firmware.txt"
  fi

  # Microcode entries are PREFIXES of signature filenames (06-8f matches 06-8f-04, 06-8f-05, …),
  # not directories, so they cannot share the loop above.
  local uc="$fw/intel-ucode"
  if [[ -d $uc && -f $REPO/config/prune-microcode.txt ]]; then
    while IFS= read -r entry; do
      [[ $entry == */* || $entry == *..* ]] \
        && die "prune-microcode.txt: entries are bare signature prefixes, got '$entry'"
      for f in "$uc/$entry"*; do
        [[ -f $f ]] || continue
        rm -f -- "$f"
        m=$((m + 1))
      done
    done < <(read_list_file "$REPO/config/prune-microcode.txt")
    # A list that matched everything would produce a UKI whose early cpio carries no Intel
    # microcode at all — which boots perfectly and is silently wrong on every Intel machine.
    # Stage 40 asserts the UKI end of this; assert the tree end here, where the deletion happens.
    compgen -G "$uc/06-*" >/dev/null \
      || die "prune-microcode.txt matched every Intel signature — the image would ship microcode
  for no current CPU at all. Check the class 2 date rule in that file."
    log "microcode prune: removed $m Intel signature(s), $(find "$uc" -type f | wc -l) kept"
  fi
  return 0
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
  # under /run — and /run is the tmpfs mounted just above.
  #
  # This used to copy to $t/etc/resolv.conf and rely on cp following the symlinked
  # destination. GNU cp does that only when the destination EXISTS; for a dangling link it
  # refuses outright — "cp: not writing through dangling symlink" — and the `|| true` here
  # swallowed it, leaving the chroot with no resolver at all. The symptom was stage 40 dying
  # much later at the flatpak remote-add with "Could not resolve hostname", and it only ever
  # appeared on a re-run: on a first-ever build target_mount runs BEFORE stage 40 creates the
  # symlink, so the copy landed as a plain file and DNS worked.
  #
  # Write to the stub path directly instead. Post-stage-40 that materialises the file the
  # dangling symlink points at (in the tmpfs, so it dies at target_umount); pre-stage-40 the
  # plain-file branch below still applies. Neither leaks into the image: stage 50 asserts
  # /etc/resolv.conf is the symlink and nothing else.
  if [[ -f /etc/resolv.conf ]]; then
    mkdir -p "$t/run/systemd/resolve"
    cp -L /etc/resolv.conf "$t/run/systemd/resolve/stub-resolv.conf" || true
    cp -L /etc/resolv.conf "$t/etc/resolv.conf.build" 2>/dev/null || true
    # only when the path is genuinely absent — never clobber the stage-40 symlink, and never
    # overwrite a real file a resumed build already materialised.
    if [[ ! -e $t/etc/resolv.conf && ! -L $t/etc/resolv.conf ]]; then
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

# filter_set_file SRC DST — strips '#cjk' / '#printing' / '#distrobox' marked lines when the
# corresponding build.conf switch is 0, and comment/blank lines otherwise pass through
# to portage untouched (portage ignores comments itself; markers must go though).
filter_set_file() {
  local src=$1 dst=$2 line out
  : > "$dst"
  while IFS= read -r line || [[ -n $line ]]; do
    out=$line
    if [[ $line == *'#cjk'* ]];      then [[ ${INCLUDE_CJK_FONTS:-1} == 1 ]] || continue; out="${line%%#*}"; fi
    if [[ $line == *'#printing'* ]]; then [[ ${INCLUDE_PRINTING:-1}  == 1 ]] || continue; out="${line%%#*}"; fi
    if [[ $line == *'#distrobox'* ]]; then [[ ${INCLUDE_DISTROBOX:-1} == 1 ]] || continue; out="${line%%#*}"; fi
    printf '%s\n' "$out" >> "$dst"
  done < "$src"
}
