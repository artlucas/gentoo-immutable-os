#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# appsetup — what the applications page decided, downloaded into the mounted target (plan/25 §5).
#
# The exec half of the `apps` page, the way `accountsetup` is the exec half of `accounts` and
# `disksetup` of `disk`. The page asks; this job runs `flatpak` in the chroot imagedeploy mounted.
#
# WHAT IT DOES, in order:
#
#   1. asks the network question AGAIN, itself, on the host — curl against the same URL the
#      greeting page checks. The verdict the page worked from can be minutes stale by now, and
#      the two halves of the offline rule are both here: no connection means nothing is installed
#      AND the update is skipped, because both are downloads from Flathub.
#   2. installs the refs the page published in `appsSelected` (resolved there: "typical" is
#      already the whole list, "none" is already empty)
#   3. updates every flatpak in the target — ALWAYS, when online, whatever was chosen. The
#      applications that shipped inside the payload were pinned at build time by apps.lock
#      (plan/15); this is the step that lifts them to whatever Flathub has today.
#
# THE FAILURE DISCIPLINE IS THE ONE plan/18 §7.4 ESTABLISHED, taken further than accountsetup
# took it: nothing in this job may fail an install. When this job runs, the operating system is
# already on the disk — root image written, bootloader placed, accounts created — and every
# failure mode left is "a download did not finish". Failing the install for that hands the user a
# machine that works, described as broken, with a retry that rewrites their disk for the sake of
# an app they can add from Discover in a minute. So every flatpak failure below warns, says what
# to do later, and returns None.
#
# The one fatal case is the one that is not this job's fault at all: no rootMountPoint means
# imagedeploy did not run, and "skipping silently" is how an installer ends up claiming an
# applications step that never had a target.

import os
import subprocess

import libcalamares

# See the note in imagedeploy/main.py: this is the idiom every stock module uses.
debug = libcalamares.utils.debug
warning = libcalamares.utils.warning

import gettext

_ = gettext.translation(
    "calamares-python",
    localedir=libcalamares.utils.gettext_path(),
    languages=libcalamares.utils.gettext_languages(),
    fallback=True,
).gettext

# Named rather than spelled inline: these run on the HOST as root, and a PATH lookup is not
# something to leave to the environment Calamares was started in (the same reason accountsetup
# names its CLIs). curl is on the medium by design — net-misc/curl is in the base set — and a
# medium without it answers "offline", which is a state this job handles first-class.
CURL = "/usr/bin/curl"

# How long the connectivity probe may take before it answers "no". Generous rather than tight:
# the wrong answer in the tight direction is "offline" for somebody whose DNS is merely slow, and
# the page's answer to offline is to skip this job entirely.
CHECK_TIMEOUT_S = 15


def pretty_name():
    return _("Installing applications.")


def in_target(root, argv, timeout=None):
    """Run a command inside the mounted target.

    `chroot` rather than libcalamares.utils.target_env_call, for the same reason accountsetup
    gives: this job needs the exit status, the output and a timeout on the same call.
    settings.conf sets dont-chroot: false, and imagedeploy has already mounted the API
    filesystems, so a chroot here is a working environment for flatpak.
    """
    return subprocess.run(
        ["chroot", root] + argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
        text=True,
    )


def log_output(proc):
    for line in (proc.stdout or "").splitlines():
        debug("appsetup: %s" % line)


def tail(proc, lines=5):
    """The last lines of a failed call, for the warning. The whole log is in debug above; a
    warning has to name the cause, not repaste a progress bar."""
    out = (proc.stdout or "").strip().splitlines()
    return " | ".join(out[-lines:])


# ---------------------------------------------------------------------------------------------
# the network question, asked again
# ---------------------------------------------------------------------------------------------

def check_internet(url):
    """curl on the HOST, not in the chroot: the live medium has a working resolver and curl of
    its own, and the question is whether the NETWORK is usable — not whether the target is.

    GlobalStorage's `hasInternet` (the greeting page's startup verdict) is deliberately not read:
    minutes pass between requirements-gathering and this job, and the difference between the two
    answers is exactly the case this re-ask exists for — a cable plugged in during the summary
    page should install apps, and one pulled out after it should not start a download.
    """
    if not url:
        warning("appsetup: internetCheckUrl is not configured; assuming offline")
        return False
    try:
        proc = subprocess.run(
            [CURL, "-fsSI", "--max-time", str(CHECK_TIMEOUT_S), url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=CHECK_TIMEOUT_S + 5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as e:
        warning("appsetup: the connectivity probe could not run (%s); assuming offline" % e)
        return False
    return proc.returncode == 0


# ---------------------------------------------------------------------------------------------
# DNS in the chroot
# ---------------------------------------------------------------------------------------------

def mount_resolver(root):
    """Bind a working resolv.conf into the target, or say why it cannot be done.

    flatpak resolves dl.flathub.org from inside the chroot, and glibc reads /etc/resolv.conf
    there — which is systemd-resolved's STUB symlink, pointing into /run/systemd/resolve/. The
    chroot's /run is a fresh tmpfs imagedeploy mounted, so the symlink dangles and there is no
    resolved listening behind it anyway: bound as-is, the stub's 127.0.0.53 would answer nobody.

    The file built exactly for this consumer is /run/systemd/resolve/resolv.conf — resolved's
    record of the REAL upstream servers, documented as the one to bind into containers. When it
    exists and names something that is not the loopback stub, it is bound; otherwise the live
    medium's own /etc/resolv.conf is tried as a plain file, which covers a medium running a
    static resolver config.

    A BIND MOUNT, never a written file: the target's /etc is an overlay whose upper persists, so
    a copied resolv.conf would shadow resolved's symlink on the installed machine with a stale
    copy, and deleting it again would whiteout the lower's symlink out of existence. The mount
    is torn down by the stock `umount` module, which unmounts everything it finds under
    rootMountPoint — emergency: true, so it runs even when this job has already warned its way
    out of something.
    """
    src = "/run/systemd/resolve/resolv.conf"
    if not os.path.isfile(src) or " 127.0.0.53" in open(src, "r", encoding="utf-8").read():
        candidate = os.path.realpath("/etc/resolv.conf")
        if os.path.isfile(candidate) and candidate != "/run/systemd/resolve/stub-resolv.conf":
            src = candidate
        else:
            warning(
                "appsetup: no upstream resolver config to bind (the live medium runs the "
                "resolved stub and /run/systemd/resolve/resolv.conf names nothing else); "
                "flatpak will likely fail to resolve flathub"
            )
            return False

    dst = os.path.join(root, "etc", "resolv.conf")
    if os.path.islink(dst):
        # mount(8) follows the destination's symlink, so the mountpoint is where it POINTS —
        # under the tmpfs /run, which exists but has no systemd/resolve tree until it is made.
        dst = os.path.realpath(dst)
        if not dst.startswith(os.path.realpath(root) + "/"):
            warning("appsetup: the target's resolv.conf points outside the target; not binding")
            return False
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, "a", encoding="utf-8").close()  # the mountpoint, nothing written into it
        subprocess.run(["mount", "--bind", src, dst], check=True)
    except (OSError, subprocess.SubprocessError) as e:
        warning("appsetup: could not bind %s over the target's resolver config: %s" % (src, e))
        return False
    debug("appsetup: bound %s over the target's %s" % (src, dst))
    return True


# ---------------------------------------------------------------------------------------------
# the two flatpak operations
# ---------------------------------------------------------------------------------------------

def ensure_remote(root, conf):
    """flathub, if the target does not have it. A medium built with INSTALLER_PAYLOAD_FLATPAKS=0
    seeds a bare /var — no template, so no /var/lib/flatpak and no remote; every other medium
    ships the remote config inside the var template and this is a no-op."""
    remote = conf.get("remote", "flathub")
    url = conf.get("flathubUrl", "")
    proc = in_target(root, ["flatpak", "remotes", "--system"])
    if proc.returncode != 0:
        warning("appsetup: could not list the target's flatpak remotes: %s" % tail(proc))
        return False
    for line in (proc.stdout or "").splitlines():
        if line.split() and line.split()[0] == remote:
            return True
    if not url:
        warning("appsetup: the target has no '%s' remote and flathubUrl is not configured" % remote)
        return False
    proc = in_target(root, ["flatpak", "remote-add", "--if-not-exists", "--system", remote, url])
    if proc.returncode != 0:
        warning("appsetup: could not add the %s remote to the target: %s" % (remote, tail(proc)))
        return False
    return True


def install_refs(root, refs, conf):
    """The page's list, installed. Warns and returns rather than failing — see the header.

    --or-update (plan/33 §7): on a KEPT store, one or more of the selected refs may already be
    there — it is exactly what keeping a Flatpak store means — and plain `flatpak install`
    refuses an already-installed ref as an error, failing the WHOLE batch over the one app that
    did not need installing. --or-update makes that ref an update instead (to whatever the
    remote's current commit is, same as update_refs() below does for everything already there),
    so one ref that is already present can no longer take the rest of the list down with it. A
    no-op on a fresh install, where nothing in `refs` is present yet.
    """
    if not refs:
        debug("appsetup: nothing selected; skipping the install pass")
        return
    libcalamares.job.setprogress(0.1)
    argv = ["flatpak", "install", "-y", "--or-update", "--system", "--noninteractive",
            conf.get("remote", "flathub")]
    try:
        proc = in_target(root, argv + list(refs), timeout=conf.get("installTimeoutS", 2400))
    except (OSError, subprocess.SubprocessError) as e:
        warning("appsetup: the install could not run (%s); the applications can be added later from Discover" % e)
        return
    log_output(proc)
    if proc.returncode != 0:
        warning(
            "appsetup: flatpak install failed (%s); nothing the install needs is missing and "
            "the applications can be added later from Discover" % tail(proc)
        )
        return
    debug("appsetup: installed %d ref(s)" % len(refs))


def update_refs(root, conf):
    """Every flatpak in the target, lifted to what Flathub has today. ALWAYS run when online —
    this is the half the page never asked about: the payload's own applications were pinned by
    apps.lock at build time, and this is the only moment between the build and the first boot
    that has both the store and a network."""
    libcalamares.job.setprogress(0.6)
    try:
        proc = in_target(
            root,
            ["flatpak", "update", "-y", "--system", "--noninteractive"],
            timeout=conf.get("updateTimeoutS", 1200),
        )
    except (OSError, subprocess.SubprocessError) as e:
        warning("appsetup: the update could not run (%s); the installed versions are the pinned ones" % e)
        return
    log_output(proc)
    if proc.returncode != 0:
        warning(
            "appsetup: flatpak update failed (%s); the target keeps the versions it shipped with" % tail(proc)
        )
        return
    debug("appsetup: update pass complete")


# ---------------------------------------------------------------------------------------------

def run():
    conf = libcalamares.job.configuration
    gs = libcalamares.globalstorage

    root = gs.value("rootMountPoint")
    if not root:
        return (
            _("Configuration Error"),
            _("No rootMountPoint is set — <pre>{!s}</pre> did not run.").format("imagedeploy"),
        )

    refs = [r for r in (gs.value("appsSelected") or []) if r]
    mode = (gs.value("appsMode") or "").strip() or "none"
    if mode not in ("typical", "none", "custom"):
        warning("appsetup: appsMode is %r, which the page never offers; treating it as none" % mode)
        mode = "none"

    if not check_internet((conf.get("internetCheckUrl") or "").strip()):
        warning("appsetup: offline — skipping both the install of %d ref(s) and the update pass" % len(refs))
        warning("appsetup: the applications in the payload are on the disk as they shipped")
        return None

    # Warned above rather than returned from: an online install whose resolver cannot be set up
    # should still try the update pass, which will fail its own way and say so.
    mount_resolver(root)
    if refs and ensure_remote(root, conf):
        install_refs(root, refs, conf)
    elif refs:
        warning("appsetup: no usable remote in the target; the applications can be added later from Discover")
    else:
        debug("appsetup: update-only run (nothing was selected)")
    update_refs(root, conf)
    libcalamares.job.setprogress(0.95)

    os.sync()
    return None
