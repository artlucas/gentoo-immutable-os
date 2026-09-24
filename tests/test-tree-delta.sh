#!/usr/bin/env bash
# scripts/lib/tree-delta.py, exercised against tiny constructed BASE/NEW trees (plan/34 §7.2,
# §12's new test-tree-delta.sh). No image, no Docker: this is pure filesystem + Python, so every
# routing decision and every fail case can be proven offline.
export TEST_FILE_NAME=test-tree-delta
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TD="$REPO_ROOT/scripts/lib/tree-delta.py"
assert_file "$TD" "scripts/lib/tree-delta.py exists"

command -v python3 >/dev/null 2>&1 || { echo "  (python3 absent — test-tree-delta skipped)"; finish; }

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT

# fresh() NAME — a clean {base,new,out}/NAME trio, base and new seeded IDENTICALLY with one file
# each under usr/ and etc/, so every scenario below only has to add the ONE difference it means
# to test, and everything else in the tree is provably unchanged (routes nowhere, fails nothing).
fresh() {
    local d="$TMP/$1"
    rm -rf -- "$d"; mkdir -p "$d/base/usr/bin" "$d/base/etc" "$d/new/usr/bin" "$d/new/etc" "$d/out"
    printf 'tool\n' > "$d/base/usr/bin/tool"; printf 'tool\n' > "$d/new/usr/bin/tool"
    printf 'cfg\n'  > "$d/base/etc/thing.conf"; printf 'cfg\n' > "$d/new/etc/thing.conf"
}

run_td() { python3 "$TD" "$TMP/$1/base" "$TMP/$1/new" "$TMP/$1/out" >"$TMP/$1/stdout" 2>"$TMP/$1/stderr"; }

# ---- deletion fails the build -----------------------------------------------------------------
fresh del
rm -f "$TMP/del/new/usr/bin/tool"
run_td del; rc=$?
assert_eq 1 "$rc" "deletion: exit code"
assert_true "deletion: stderr names the missing path" grep -qF "usr/bin/tool" "$TMP/del/stderr"
assert_true "deletion: stderr says DELETED" grep -q "DELETED" "$TMP/del/stderr"

# ---- changed under usr/, not allowlisted, fails -------------------------------------------
fresh notallow
printf 'different\n' > "$TMP/notallow/new/usr/bin/tool"
run_td notallow; rc=$?
assert_eq 1 "$rc" "changed-not-allowlisted: exit code"
assert_true "changed-not-allowlisted: stderr names it" grep -qF "usr/bin/tool" "$TMP/notallow/stderr"

# ---- changed under etc/, not allowlisted, fails --------------------------------------------
fresh etc_notallow
printf 'cfg2\n' > "$TMP/etc_notallow/new/etc/thing.conf"
run_td etc_notallow; rc=$?
assert_eq 1 "$rc" "changed-etc-not-allowlisted: exit code"
assert_true "changed-etc-not-allowlisted: stderr names it" \
    grep -qF "etc/thing.conf" "$TMP/etc_notallow/stderr"
assert_false "changed-etc-not-allowlisted: nothing routed to the upper" \
    test -e "$TMP/etc_notallow/out/overlay/etc/upper/thing.conf"

# ---- changed under etc/, allowlisted, routes to the upper -----------------------------------
fresh etc_allow
printf 'old-cache\n' > "$TMP/etc_allow/base/etc/ld.so.cache"
printf 'new-cache\n' > "$TMP/etc_allow/new/etc/ld.so.cache"
run_td etc_allow; rc=$?
assert_eq 0 "$rc" "changed-etc-allowlisted: exit code"
assert_eq "new-cache" "$(cat "$TMP/etc_allow/out/overlay/etc/upper/ld.so.cache")" \
    "changed-etc-allowlisted: routed to the upper with the new content"

# ---- added under etc/ routes to the upper freely, no allowlist needed -----------------------
fresh etc_added
mkdir -p "$TMP/etc_added/new/etc/xdg"
printf 'new-file\n' > "$TMP/etc_added/new/etc/xdg/newconf.conf"
run_td etc_added; rc=$?
assert_eq 0 "$rc" "added-etc: exit code"
assert_eq "new-file" "$(cat "$TMP/etc_added/out/overlay/etc/upper/xdg/newconf.conf")" \
    "added-etc: routed to the upper freely"

# ---- change outside usr/ and etc/ fails --------------------------------------------------------
fresh outside
mkdir -p "$TMP/outside/base/opt" "$TMP/outside/new/opt"
printf 'a\n' > "$TMP/outside/base/opt/x"
printf 'b\n' > "$TMP/outside/new/opt/x"
run_td outside; rc=$?
assert_eq 1 "$rc" "outside usr/etc: exit code"
assert_true "outside usr/etc: stderr names it" grep -qF "opt/x" "$TMP/outside/stderr"

# ---- a unit in the sysext fails ------------------------------------------------------------
fresh unit
mkdir -p "$TMP/unit/new/usr/lib/systemd/system"
printf '[Unit]\n' > "$TMP/unit/new/usr/lib/systemd/system/foo.service"
run_td unit; rc=$?
assert_eq 1 "$rc" "unit in sysext: exit code"
assert_true "unit in sysext: stderr says EARLY-BOOT" grep -q "EARLY-BOOT" "$TMP/unit/stderr"

# ---- sysusers.d / tmpfiles.d / udev rule in the sysext each fail --------------------------
for d in sysusers.d tmpfiles.d "udev/rules.d"; do
    key="ebr-$(tr '/.' '--' <<<"$d")"
    fresh "$key"
    mkdir -p "$TMP/$key/new/usr/lib/$d"
    printf 'x\n' > "$TMP/$key/new/usr/lib/$d/50-foo.conf"
    run_td "$key"; rc=$?
    assert_eq 1 "$rc" "$d in sysext: exit code"
    assert_true "$d in sysext: stderr says EARLY-BOOT" grep -q "EARLY-BOOT" "$TMP/$key/stderr"
done

# ---- usr/lib/os-release fails, added or changed --------------------------------------------
fresh osrel_add
mkdir -p "$TMP/osrel_add/new/usr/lib"
printf 'ID=live\n' > "$TMP/osrel_add/new/usr/lib/os-release"
run_td osrel_add; rc=$?
assert_eq 1 "$rc" "os-release added: exit code"
assert_true "os-release added: stderr says EARLY-BOOT" grep -q "EARLY-BOOT" "$TMP/osrel_add/stderr"

fresh osrel_chg
mkdir -p "$TMP/osrel_chg/base/usr/lib" "$TMP/osrel_chg/new/usr/lib"
printf 'ID=desktop\n' > "$TMP/osrel_chg/base/usr/lib/os-release"
printf 'ID=live\n'    > "$TMP/osrel_chg/new/usr/lib/os-release"
run_td osrel_chg; rc=$?
assert_eq 1 "$rc" "os-release changed: exit code"

# ---- upper-wins: a path already staged in overlay/etc/upper is left untouched ---------------
fresh upperwins
mkdir -p "$TMP/upperwins/out/overlay/etc/upper"
printf 'PREEXISTING\n' > "$TMP/upperwins/out/overlay/etc/upper/thing.conf"
printf 'cfg2\n' > "$TMP/upperwins/new/etc/thing.conf"   # would otherwise route here
run_td upperwins; rc=$?
assert_eq 0 "$rc" "upper-wins: exit code"
assert_eq "PREEXISTING" "$(cat "$TMP/upperwins/out/overlay/etc/upper/thing.conf")" \
    "upper-wins: the pre-existing upper file is untouched, not overwritten"

# ---- a clean added/changed pair routes correctly, with mode/ownership/xattrs/symlinks kept,
#      and mtime differences are ignored entirely ------------------------------------------
fresh route
mkdir -p "$TMP/route/new/usr/share/newapp"
printf 'new content\n' > "$TMP/route/new/usr/share/newapp/data.txt"
chmod 0640 "$TMP/route/new/usr/share/newapp/data.txt"
ln -s data.txt "$TMP/route/new/usr/share/newapp/data-link.txt"
if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
    setfattr -n user.tree_delta_test -v marker "$TMP/route/new/usr/share/newapp/data.txt" 2>/dev/null || true
fi
mkdir -p "$TMP/route/new/etc/xdg"
printf 'new-conf\n' > "$TMP/route/new/etc/xdg/added.conf"   # ADDED, not changed — routes freely
touch -d "2020-01-01" "$TMP/route/base/usr/bin/tool"
touch -d "2030-06-15" "$TMP/route/new/usr/bin/tool"   # content identical, mtime wildly different
run_td route; rc=$?
assert_eq 0 "$rc" "route: exit code"
EXT="$TMP/route/out/lib/extensions/immos-installer/usr"
UPPER="$TMP/route/out/overlay/etc/upper"
assert_file "$EXT/share/newapp/data.txt" "route: file routed to the extension"
assert_eq "640" "$(stat -c%a "$EXT/share/newapp/data.txt")" "route: mode preserved"
assert_eq "$(stat -c%u:%g "$TMP/route/new/usr/share/newapp/data.txt")" \
          "$(stat -c%u:%g "$EXT/share/newapp/data.txt")" "route: ownership preserved"
assert_true "route: symlink preserved as a symlink" test -L "$EXT/share/newapp/data-link.txt"
assert_eq "data.txt" "$(readlink "$EXT/share/newapp/data-link.txt")" "route: symlink target preserved"
assert_true "route: parent directory mode matches the source" \
    bash -c "[[ \$(stat -c%a '$TMP/route/new/usr/share/newapp') == \$(stat -c%a '$EXT/share/newapp') ]]"
assert_file "$UPPER/xdg/added.conf" "route: added etc/ file routed to the upper"
assert_eq "new-conf" "$(cat "$UPPER/xdg/added.conf")" "route: upper file carries the new content"
assert_false "route: usr/bin/tool (identical content, only mtime differs) was NOT routed" \
    test -e "$EXT/bin/tool"
if command -v getfattr >/dev/null 2>&1 && getfattr -n user.tree_delta_test --only-values \
     "$TMP/route/new/usr/share/newapp/data.txt" >/dev/null 2>&1; then
    assert_eq "marker" \
        "$(getfattr -n user.tree_delta_test --only-values "$EXT/share/newapp/data.txt" 2>/dev/null)" \
        "route: xattr preserved"
fi

# ---- a compiled binary must never be allowlisted (checkpoint 3's explicit rule) -------------
assert_false "tree-delta.py's allowlist names no .so" \
    bash -c "grep -E '\"[^\"]*\.so\"' '$TD' | grep -v '^\s*#'"

finish
