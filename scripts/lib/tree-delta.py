#!/usr/bin/env python3
"""tree-delta.py BASE NEW OUT — the installer's own tree, as a DIFFERENCE against the desktop's
(plan/34 §7.2). Routes the difference into OUT (the live medium's staged /var), fails the build
on anything the difference cannot represent safely.

WHY A DIFFERENCE AT ALL. The stick's root partition is the desktop's own root.erofs, byte for
byte (plan/34 §2) — the medium never builds a root of its own. What makes it a live INSTALLER
rather than a dd'd desktop.img is Calamares and its tail, merged over /usr at boot by
systemd-sysext, plus a handful of live-only /etc files the existing /etc overlay (plan/01)
already knows how to merge. Both mechanisms only ever ADD or REPLACE a path at that path; neither
can represent a path the base has and the extension's view does not. So plan/34 §6 makes the
installer's OWN tree a superset of the desktop's at identical package versions BEFORE this script
ever runs — its job is to prove that promise held, not to make it true.

WHAT A "PATH" IS. BASE and NEW are two already-extracted directory trees (BASE: the desktop's
released root.erofs, extracted read-only; NEW: the installer's own $TARGET, already excluding
/var and every mountpoint the caller does not want compared — see the EXCLUDE_PREFIXES note
below). Every entry under each, symlinks included and NOT followed, is one path. Two paths at the
same relative location are compared on: type, mode, uid, gid, rdev (device nodes), symlink
target, xattrs, and — for regular files — sha256. mtimes are read nowhere in this file: an EROFS
build stamps every inode with the same build timestamp (60-image.sh's SOURCE_DATE_EPOCH note),
so comparing them would either always agree for the wrong reason or never agree for no reason at
all.

THE OUTCOMES, in the order this script actually decides them (plan/34 §7.2 step 2's table,
resolved into one procedure — the checkpoint-3 coordinator's explicit rulings on the two things
the table's row order and prose left ambiguous: an already-upper path is decided BEFORE the
allowlist or any fail check, not after; and /etc gets the SAME "changed needs an allowlist,
added does not" split as /usr, not a free pass just because the overlay mechanism can carry any
content once it is there):

  1. DELETED (in BASE, missing from NEW)               → the build FAILS. §6 is what is supposed
                                                           to make this list empty; a non-empty
                                                           one means that promise broke.
  2. changed or added, under etc/, ALREADY present in   → left alone. An earlier stage (plan/34
     OUT's upper (checked before anything below)          §5's live-user split, or this script's
                                                           own previous run) already put the
                                                           correct upper copy there; the base's
                                                           byte-for-byte content is not needed on
                                                           top of a file that is deliberately not
                                                           the base's content any more.
  3. ADDED, under etc/, not already upper                → routed to OUT's upper freely. Pure new
                                                           content the desktop's /etc never had —
                                                           the installer config, the sysupdate
                                                           masks, the polkit rule, and so on.
  4. CHANGED (not added), under etc/, not already        → routed to OUT's upper if on
     upper                                                 ALLOWED_CHANGED_ETC, else the build
                                                           FAILS. A changed /etc file is the SAME
                                                           kind of claim a changed /usr file is —
                                                           "this build's own tree legitimately
                                                           differs from the base's here, reviewed
                                                           and named" — and the hwdb.bin episode
                                                           (this same checkpoint) is exactly the
                                                           silent, unreviewed drift this rule exists
                                                           to catch before it reaches a live medium.
  5. changed or added, under usr/, names a path sysext   → the build FAILS regardless of anything
     cannot deliver (os-release, or a unit/sysusers.d/     else. A sysext merges over /usr only
     tmpfiles.d/udev-rule directory)                       after early boot has already read every
                                                           one of these once; shipping a changed
                                                           or added one in the extension is a
                                                           silent no-op at best.
  6. ADDED, under usr/, nothing else applies             → routed to the extension. Pure new
                                                           content the desktop never had — the
                                                           reason a difference-based sysext works
                                                           at all.
  7. CHANGED (not added), under usr/, on the allowlist   → routed to the extension. The allowlist
                                                           is deliberately small: caches stage 40
                                                           regenerates from content already in
                                                           both trees, whose bytes an independent
                                                           run cannot be expected to reproduce
                                                           (plan/34 §7.2's own words), or a file
                                                           this build deliberately edits with the
                                                           same reasoning as the /etc case above.
                                                           A compiled binary (a .so, an ELF) is
                                                           never allowlisted: two independent
                                                           builds of identical source are expected
                                                           to be byte-identical, so a binary that
                                                           differs is a build bug to fix at the
                                                           source, not a difference to accommodate.
  8. CHANGED (not added), under usr/, not on the         → the build FAILS. An unexplained,
     allowlist                                              unreviewed content difference between
                                                           two builds of the same package versions
                                                           is exactly the drift plan/34 §6 exists
                                                           to make loud.
  9. changed or added, outside usr/ and etc/             → the build FAILS. Neither mechanism can
                                                           carry it: a sysext only ever merges
                                                           /usr (and /opt, unused here); the /etc
                                                           overlay only ever merges /etc.

Everything else — a path unchanged between BASE and NEW, or a path under an excluded prefix — is
silently skipped: unchanged content is already served by the base partition, and needs no copy of
itself anywhere on the stick.
"""
import hashlib
import os
import stat
import sys

# Never compared: BASE and NEW are both taken with /var (and every real or virtual mountpoint)
# already excluded by the caller, but this script is defensive about it anyway, the same way
# checkpoint 2's own ad-hoc comparison script was — a stray /proc or /sys entry under either tree
# would make every "changed" and "deleted" result downstream meaningless.
EXCLUDE_PREFIXES = ("var/", "proc/", "sys/", "dev/", "tmp/", "run/", "efi/")

# plan/34 §7.2's own allowlist, exactly: caches stage 40 regenerates from content already
# present in both trees (so an independent run's bytes are not expected to match another
# independent run's — see the hwdb.bin and kcm_managed.so findings this same checkpoint fixed
# for the two ways "unexplained" can turn out to mean "explainable, but not by this list"), plus
# files this build deliberately edits or whose content is inherently tail-specific. A NAME, not
# a directory: each entry is the exact relative path, checked verbatim, so a same-named cache
# appearing somewhere new still fails — the allowlist describes known instances, not a class of
# file.
#
# usr/share/immos/manifest.txt: on the stick it describes the MERGED /usr — the desktop's own
# packages plus the extension's — which is correct and expected to differ from the base's own
# manifest describing only itself.
ALLOWED_CHANGED_USR = frozenset({
    "usr/share/applications/mimeinfo.cache",
    "usr/share/immos/manifest.txt",
})
# Same principle as ALLOWED_CHANGED_USR, applied to /etc: a CHANGED (not added) /etc path still
# needs a named, reviewed reason, even though the /etc overlay mechanism could technically carry
# any content once routed. Silent, unreviewed drift is exactly what plan/34 §6 exists to make
# loud, and it does not stop being loud just because the destination happens to be the upper
# instead of the extension — the hwdb.bin episode (this same checkpoint) was precisely a /etc
# (well, /etc/udev) file whose changed content nobody had reviewed the reason for.
ALLOWED_CHANGED_ETC = frozenset({
    "etc/ld.so.cache",
    "etc/xdg/kdeglobals",
})

# A .so (or any other compiled binary) must never be added here (checkpoint 3's explicit rule):
# two independent builds of identical package versions are expected to be byte-identical, and a
# build that is not means something upstream of this script is broken, not that this script
# should shrug at the symptom. Enforced structurally: ALLOWED_CHANGED_USR is names, not a
# suffix/type rule, so nothing here can accidentally match every .so in the tree — but a reviewer
# adding a specific .so's path to this set is exactly the mistake this comment exists to stop.

# sysext's hard limits (plan/34 §3's own citation of the systemd-sysext manual): it cannot ship
# early-boot resources, because everything below is read once, before a sysext could ever be
# merged over /usr. A changed OR added instance of any of these fails regardless of the
# allowlist — there is no content that would make shipping one in the extension work.
EARLY_BOOT_BLOCKED_EXACT = frozenset({"usr/lib/os-release"})
EARLY_BOOT_BLOCKED_DIR_PREFIXES = (
    "usr/lib/systemd/system/",
    "usr/lib/sysusers.d/",
    "usr/lib/tmpfiles.d/",
    "usr/lib/udev/rules.d/",
)


def is_early_boot_blocked(relpath):
    if relpath in EARLY_BOOT_BLOCKED_EXACT:
        return True
    return any(relpath.startswith(p) for p in EARLY_BOOT_BLOCKED_DIR_PREFIXES)


# security.capability is excluded from the xattr comparison entirely, on both sides, not
# allowlisted per path — this is a caller-side tool limitation, not a real difference to name
# instances of. BASE is populated by `fsck.erofs --extract --preserve` (60-image.sh), and
# fsck.erofs's own extractor silently declines to restore security.* xattrs no matter what
# --preserve asks for (the same limitation stage 60's OWN target-role capability check works
# around, by reading the EROFS's Xattr size directly through dump.erofs instead of extracting
# it — see the comment above that check). So BASE's extracted copy of every capability-bearing
# binary (ping, arping, the sssd helpers, several KDE system helpers) reads back with NO
# security.capability at all, while NEW's real merged tree still has it — a difference that is
# entirely an artifact of how BASE was read, not something either build actually did
# differently. Confirmed on a real installer build: usr/bin/ping and
# usr/libexec/sssd/ldap_child's sha256 matched exactly between BASE and NEW; only the
# capability xattr, present in NEW and silently absent from BASE, made tree-delta call them
# "changed". Since plan/34 §6 already guarantees identical package versions in both trees, a
# file whose CONTENT matches is running the same fcaps.eclass call either way — there is
# nothing here for this script to catch that stage 40/60's own capability checks (proven
# against the real, unextracted image) do not already prove more reliably.
XATTR_COMPARE_EXCLUDE = frozenset({"security.capability"})


def walk(root):
    """Every path under root, symlinks not followed, keyed by its path relative to root."""
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        if rel_dir == "":
            dirnames[:] = [d for d in dirnames if not (d + "/").startswith(EXCLUDE_PREFIXES)]
        for name in dirnames + filenames:
            relpath = os.path.join(rel_dir, name) if rel_dir else name
            relpath = relpath.replace(os.sep, "/")
            if any(relpath.startswith(p) for p in EXCLUDE_PREFIXES):
                continue
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            mode = stat.S_IMODE(st.st_mode)
            xattrs = {}
            try:
                for xname in os.listxattr(full, follow_symlinks=False):
                    if xname in XATTR_COMPARE_EXCLUDE:
                        continue
                    xattrs[xname] = os.getxattr(full, xname, follow_symlinks=False)
            except OSError:
                pass  # some filesystems/paths do not support xattrs at all; treat as none
            xattr_key = tuple(sorted(xattrs.items()))
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(full)
                entries[relpath] = ("link", mode, st.st_uid, st.st_gid, None, target, xattr_key)
            elif stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                with open(full, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                entries[relpath] = ("file", mode, st.st_uid, st.st_gid, h.hexdigest(), None, xattr_key)
            elif stat.S_ISDIR(st.st_mode):
                entries[relpath] = ("dir", mode, st.st_uid, st.st_gid, None, None, xattr_key)
            elif stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
                entries[relpath] = ("dev", mode, st.st_uid, st.st_gid, st.st_rdev, None, xattr_key)
            elif stat.S_ISFIFO(st.st_mode):
                entries[relpath] = ("fifo", mode, st.st_uid, st.st_gid, None, None, xattr_key)
            else:
                entries[relpath] = ("other", mode, st.st_uid, st.st_gid, None, None, xattr_key)
    return entries


def ensure_parents(new_root, full_relpath, strip_prefix, dst_root):
    """Every ancestor directory of full_relpath (a path relative to new_root, e.g.
    "etc/xdg/foo.conf") below strip_prefix (e.g. "etc/"), materialised under dst_root with the
    SAME mode and ownership as its counterpart in new_root — not os.makedirs' own default mode.

    Needed because a routed path's immediate parent is often itself UNCHANGED between the base
    and the installer's tree, so it is never in `added` or `changed` and never gets its own
    explicit copy_one() call — but overlayfs presents an UPPER (or extension) directory's own
    mode/uid/gid in the merged view whenever that directory exists on both sides, so a plain
    os.makedirs(exist_ok=True) default (this process's umask, this process's uid/gid — root:root
    only by coincidence of running as root) would silently shadow the base's real permissions
    for every unchanged ancestor of anything this script ever routes.
    """
    stripped = full_relpath[len(strip_prefix):]
    parts = stripped.split("/")[:-1]   # every ancestor below the prefix; the leaf excluded
    acc = []
    for part in parts:
        acc.append(part)
        rel_dir = "/".join(acc)                              # relative to dst_root
        src_dir = os.path.join(new_root, strip_prefix, rel_dir)  # relative to new_root
        dst_dir = os.path.join(dst_root, rel_dir)
        if os.path.isdir(dst_dir) and not os.path.islink(dst_dir):
            continue
        st = os.lstat(src_dir)
        os.makedirs(dst_dir, exist_ok=True)
        os.chmod(dst_dir, stat.S_IMODE(st.st_mode))
        os.chown(dst_dir, st.st_uid, st.st_gid)
        try:
            for xname in os.listxattr(src_dir, follow_symlinks=False):
                os.setxattr(dst_dir, xname, os.getxattr(src_dir, xname, follow_symlinks=False), follow_symlinks=False)
        except OSError:
            pass


def copy_one(src, dst):
    """Materialise one path from src at dst, preserving type, mode, ownership, xattrs and
    symlink targets. mtime is deliberately not preserved — see the module docstring."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    st = os.lstat(src)
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(src)
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(target, dst)
        os.chown(dst, st.st_uid, st.st_gid, follow_symlinks=False)
    elif stat.S_ISDIR(st.st_mode):
        os.makedirs(dst, exist_ok=True)
        os.chmod(dst, stat.S_IMODE(st.st_mode))
        os.chown(dst, st.st_uid, st.st_gid)
    else:
        import shutil
        if os.path.lexists(dst):
            os.unlink(dst)
        shutil.copy2(src, dst)
        os.chmod(dst, stat.S_IMODE(st.st_mode))
        os.chown(dst, st.st_uid, st.st_gid)
    try:
        for xname in os.listxattr(src, follow_symlinks=False):
            os.setxattr(dst, xname, os.getxattr(src, xname, follow_symlinks=False), follow_symlinks=False)
    except OSError:
        pass


def main():
    if len(sys.argv) != 4:
        print("usage: tree-delta.py BASE NEW OUT", file=sys.stderr)
        return 2
    base_root, new_root, out_root = sys.argv[1:4]

    base = walk(base_root)
    new = walk(new_root)
    base_keys, new_keys = set(base), set(new)

    deleted = sorted(base_keys - new_keys)
    added = sorted(new_keys - base_keys)
    common = base_keys & new_keys
    # [0:4] = (type, mode, uid, gid); [4] = sha256 (files) / rdev (devices), None for the rest;
    # [5] = symlink target, None for non-links; [6] = xattr_key. Comparing the whole 7-tuple in
    # one shot is deliberately not "wrong for directories" the way it looks — a directory's own
    # [4] and [5] are always None on both sides, so they can never be the reason a dir differs.
    changed = sorted(k for k in common if base[k] != new[k])

    upper_dir = os.path.join(out_root, "overlay", "etc", "upper")
    ext_dir = os.path.join(out_root, "lib", "extensions", "immos-installer", "usr")

    failures = []
    # PASS 1: classify only — nothing is written to OUT until every path has been decided, so a
    # failure discovered on path #900 never leaves paths #1-899 already routed to a staging area
    # a failed build is supposed to have produced nothing useful in.
    upper_actions = []   # (relpath, upper_target)
    ext_actions = []     # (relpath, ext_target, usr_rel)
    skipped_upper_wins = []

    if deleted:
        failures.append(
            "DELETED (in the desktop's tree, missing from the installer's — plan/34 §6 is "
            "supposed to make this list empty):\n" + "\n".join(f"  {p}" for p in deleted[:50])
            + (f"\n  ... and {len(deleted) - 50} more" if len(deleted) > 50 else "")
        )

    for relpath in added + changed:
        is_added = relpath in added
        if relpath.startswith("etc/"):
            etc_rel = relpath[len("etc/"):]
            upper_target = os.path.join(upper_dir, etc_rel)
            if os.path.lexists(upper_target):
                skipped_upper_wins.append(relpath)
                continue
            if (not is_added) and relpath not in ALLOWED_CHANGED_ETC:
                failures.append(
                    f"CHANGED, not on the /etc allowlist (unexplained content drift between two "
                    f"builds of the same package versions): {relpath}"
                )
                continue
            upper_actions.append((relpath, upper_target))
            continue
        elif relpath.startswith("usr/"):
            if is_early_boot_blocked(relpath):
                kind = "added" if is_added else "changed"
                failures.append(
                    f"EARLY-BOOT RESOURCE ({kind}, cannot ship in a sysext — merged over /usr "
                    f"only after early boot has already read it once): {relpath}"
                )
                continue
            if (not is_added) and relpath not in ALLOWED_CHANGED_USR:
                failures.append(
                    f"CHANGED, not on the allowlist (unexplained content drift between two "
                    f"builds of the same package versions): {relpath}"
                )
                continue
            usr_rel = relpath[len("usr/"):]
            ext_target = os.path.join(ext_dir, usr_rel)
            ext_actions.append((relpath, ext_target, usr_rel))
            continue
        else:
            kind = "added" if is_added else "changed"
            failures.append(f"{kind.upper()}, outside usr/ and etc/ (neither mechanism can carry it): {relpath}")

    if failures:
        print("tree-delta: FAILED\n", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
            print(file=sys.stderr)
        return 1

    # PASS 2: every path is a routing action now, so write them all.
    ext_size_by_top = {}   # first path segment under usr/ -> byte total, for the size report
    for relpath, upper_target in upper_actions:
        ensure_parents(new_root, relpath, "etc/", upper_dir)
        copy_one(os.path.join(new_root, relpath), upper_target)
    for relpath, ext_target, usr_rel in ext_actions:
        ensure_parents(new_root, relpath, "usr/", ext_dir)
        copy_one(os.path.join(new_root, relpath), ext_target)
        if new[relpath][0] == "file":
            top = usr_rel.split("/", 1)[0] if "/" in usr_rel else usr_rel
            ext_size_by_top[top] = ext_size_by_top.get(top, 0) + os.path.getsize(os.path.join(new_root, relpath))

    print(f"tree-delta: deleted={len(deleted)} added={len(added)} changed={len(changed)}")
    print(f"tree-delta: {len(upper_actions)} path(s) routed to the upper, "
          f"{len(skipped_upper_wins)} already there and left alone")
    print(f"tree-delta: {len(ext_actions)} path(s) routed to the extension")
    if ext_size_by_top:
        print("tree-delta: extension size by top-level usr/ directory:")
        for top, size in sorted(ext_size_by_top.items(), key=lambda kv: -kv[1]):
            print(f"  {size:>12} bytes  usr/{top}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
