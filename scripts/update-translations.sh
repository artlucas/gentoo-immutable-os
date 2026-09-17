#!/usr/bin/env bash
# Refresh the installer's .ts files from the module sources (plan/22 §4).
#
# WHAT THIS IS FOR. Our Calamares modules call tr() and qsTr(); Calamares loads the compiled
# result as its BRANDING translator, out of
# config/calamares/branding/installer/lang/calamares-installer_<id>.qm. Those .qm files are built
# by stage 40 from the .ts files in that directory, and the .ts files are committed — they are
# content, not build output, because a human writes the translations.
#
# lupdate is what keeps their <source> elements in step with the code. Run it after adding or
# changing a translatable string; it adds new messages as `type="unfinished"`, marks removed ones
# `vanished`, and leaves existing translations alone. Then somebody fills in the new entries —
# and the step at the bottom un-vanishes the three pseudo-contexts lupdate can never see, which
# used to be somebody's chore too.
#
# IT DOES NOT RUN IN THE BUILD, on purpose. A build stage that rewrote files in the repository
# would make `git status` depend on whether you had built, and would quietly "fix" the one failure
# the check exists to catch: a <source> that no longer matches the code is a string that silently
# stays English, and it should stop a build rather than be papered over by the next one.
#
#   scripts/update-translations.sh            # refresh every language in config/languages.conf
#
# Runs lupdate inside the builder image, because that is where dev-qt/qttools:6[linguist] is —
# it arrives as a DEPEND of the overlay's Calamares modules (config/portage/overlay/README.md).
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The same three exports enter.sh makes before sourcing: common.sh's log/die want a stage name and
# init_paths wants an out directory, and this script is neither a stage nor a build.
export REPO OUT="$REPO/out" STAGE_NAME=translations
# shellcheck source=lib/common.sh
source "$REPO/scripts/lib/common.sh"
load_config

LANG_DIR="config/calamares/branding/installer/lang"
# Every module whose tr()/qsTr() strings this catalogue carries. lupdate RECURSES into each, which
# is how the greeting module's files/checker/ — upstream's requirements box, vendored (plan/23 §2) —
# gets scanned without a fourth entry here.
SOURCES=(
  "config/portage/overlay/distro-base/distro-calamares-language/files"
  "config/portage/overlay/distro-base/distro-calamares-greeting/files"
  "config/portage/overlay/distro-base/distro-calamares-accounts/files"
  "config/portage/overlay/distro-base/distro-calamares-disk/files"
  "config/portage/overlay/distro-base/distro-calamares-apps/files"
)

# The .ts list is the TABLE's, both ways: a language with no file gets one, and a file for a
# language nobody offers is not created or refreshed. check-translations.py refuses the leftovers.
TS_ARGS=()
while IFS='|' read -r lang_id _ _ _; do
  [[ -n $lang_id && $lang_id != en ]] || continue
  TS_ARGS+=( "$LANG_DIR/calamares-installer_${lang_id}.ts" )
done <<<"$LANGUAGES_TABLE"
[[ ${#TS_ARGS[@]} -gt 0 ]] || die "config/languages.conf offers no language but 'en'"

log "refreshing ${#TS_ARGS[@]} translation files from ${#SOURCES[@]} module source trees"

# -locations none: lupdate's default writes <location filename= line=> into every message, so a
# one-line edit anywhere in a source file re-numbers hundreds of entries and the diff stops being
# readable. The line numbers are of no use to a translator and of none to the build.
# -no-obsolete is deliberately NOT passed: a message that disappears should be kept as `vanished`
# so its translation survives a rename and can be reused, rather than being deleted the first time
# somebody reflows a string.
# /repo read-only with the ONE directory lupdate writes bound read-write over it. The alternative
# — mounting the whole checkout writable — would let a tool whose job is to edit nine files edit
# anything, in a container running as root, for no benefit.
#
# --user, because without it every refreshed .ts comes back owned by root and the next person to
# edit one needs sudo to do it. HOME is set for the same reason enter.sh does not need to: bash -l
# reads profile scripts that expect one.
RUNTIME="${1:-docker}"
"$RUNTIME" run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$REPO":/repo:ro \
  -v "$REPO/$LANG_DIR:/repo/$LANG_DIR" \
  "${DISTRO_ID}-builder" -lc "
    set -euo pipefail
    cd /repo
    lu=\"\$(command -v lupdate-qt6 || command -v lupdate || echo /usr/lib64/qt6/bin/lupdate)\"
    [[ -x \$lu ]] || { echo 'no lupdate on the builder: dev-qt/qttools:6[linguist] is not merged there' >&2; exit 1; }
    \"\$lu\" -locations none -extensions cpp,h,qml ${SOURCES[*]} -ts ${TS_ARGS[*]}
  " || die "lupdate failed"

# ---- the pseudo-contexts, un-vanished ----------------------------------------------------------
#
# lupdate marks every message it did not find in the sources `vanished` — right for a renamed
# string, wrong for the three contexts whose sources it cannot see BY DESIGN (check-translations.py
# names them): LanguageNames arrives at runtime out of config/languages.conf, AppsDescriptions out
# of modules/apps.conf, CalamaresSidebar out of the branding sidebar's qsTranslate calls in a
# directory no lupdate run scans. Every one of their entries would re-vanish on every refresh,
# lrelease would drop them, and somebody would have to flip them back by hand — the chore this
# step used to be. Their translations survive the round-trip because -no-obsolete is not passed;
# only the marker is wrong, and only the marker is fixed here.
python3 - "$LANG_DIR" <<'EOF'
import pathlib, re, sys

lang_dir = pathlib.Path(sys.argv[1])
PSEUDO = ("LanguageNames", "AppsDescriptions", "CalamaresSidebar")
fixed = 0
for ts in sorted(lang_dir.glob("*.ts")):
    text = ts.read_text(encoding="utf-8")
    context = None
    out = []
    for line in text.splitlines(keepends=True):
        m = re.search(r"<name>([^<]+)</name>", line)
        if m:
            context = m.group(1)
        if context in PSEUDO and 'type="vanished"' in line:
            line = line.replace(' type="vanished"', "")
            fixed += 1
        out.append(line)
    ts.write_text("".join(out), encoding="utf-8")
print(f"un-vanished {fixed} pseudo-context entries")
EOF

log "done. Now fill in the new entries, then verify:"
log "  python3 scripts/lib/check-translations.py --table config/languages.conf \\"
log "      --lang-dir $LANG_DIR \\"
log "      $(printf -- '--source-dir %s ' "${SOURCES[@]}")"
