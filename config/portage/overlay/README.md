# The in-repo ebuild repository

Four things this project ships have to be **compiled against the target's own Qt6/KF6**, and
therefore cannot be built the way everything else in `config/rootfs/` is:

| | |
|---|---|
| `<id>-kcm-managed` | The System Settings module for managed mode ([plan/19](../../../plan/19-managed-mode.md) §7.2). A Plasma KCM is a C++ plugin; there is no QML-only path into System Settings |
| `<id>-calamares-accounts` | The installer's accounts page ([plan/21](../../../plan/21-installer-accounts-page.md)). Calamares accepts **only** C++ `QtPlugin` view modules — `ModuleFactory.cpp:53` — so a page cannot be a script. Its UI is QML with Kirigami, compiled into the plugin as a Qt resource; the C++ is a thin host |
| `<id>-calamares-language` | The installer's language page ([plan/22](../../../plan/22-installer-language-page.md)), replacing the first half of the stock `welcome` module. Same wall, and one thing of its own: being **first in the sequence**, it is where `QQuickStyle::setStyle()` has to happen for every later QML page to have icons |
| `<id>-calamares-greeting` | The installer's greeting page ([plan/23](../../../plan/23-installer-greeting-page.md)), replacing the other half. It owns the six requirement checks — including the disk check `-DCMAKE_DISABLE_FIND_PACKAGE_LIBPARTED=ON` silently deletes from upstream's — because a requirement is contributed by whichever module is in the sequence. Unlike its siblings it is **Qt Widgets, not QML**: the requirements box it draws is three classes vendored from the stock module, which are private to it and installed nowhere |
| `<id>-calamares-disk` | The installer's disk page ([plan/24](../../../plan/24-installer-disk-page.md)), replacing the stock `partition` module outright rather than configuring it into a picker. Same wall as the others; what is particular to it is what it does **not** link against — no kpmcore, no libparted. It reads `/sys/block` for the disks and asks `lsblk` for what is on them, and the partitioning itself is a python job running the pipeline's own `scripts/lib/layout.sh` |

They go to different images, and the split is deliberate rather than incidental. The KCM is in
`@desktop` marked `#not-live`, so it reaches the product and **not** the installer medium — a live
session is never enrolled, so a "which policy is applied?" page there answers a question nobody
can ask ([plan/20](../../../plan/20-installer-slimming.md) §2.2). All three Calamares pages are in
`@installer` and are therefore the exact opposite: installer-only, because they are how the machine
*being installed* gets its language and its accounts. No package here is ever on both images, and
`config/portage/expected-packages.desktop.txt` is what says so.

One difference is worth knowing before a relock: **all three Calamares pages are mandatory, and
the KCM is not**. The KCM's absence costs a System Settings entry, and the enrolment page that
preceded the accounts page was optional too — `settings.conf` carried a substituted token so a
medium built from a lock that did not yet have it still worked. None of the three is like that. The
accounts page creates the account; the language page is the first step in the sequence and makes the
`QQuickStyle::setStyle()` call the accounts page depends on; the greeting page contributes the
requirement checks that decide whether `Next` may be pressed at all. So stage 40 refuses to build an
installer medium without any of them, rather than shipping a stick that installs a machine nobody
can log into, one that never asks which language to install in, or one that will start writing a
3 GiB payload onto a 16 GiB disk.

**Why an ebuild repository rather than a hand-compile in stage 40.** plan/18 §7.2 rejected
compiling a Calamares module by hand, and the reason was never "C++ is hard": it was that a
hand-compiled plugin is built against *whatever headers happen to be around*, while the target's
Qt6 and KF6 come from this pipeline's own resolution. The two can disagree, and a Qt plugin whose
ABI does not match its host does not fail to build — it fails to **load**, silently, at runtime,
on a machine with no way to install a fix.

Letting Portage build them removes the question, though not quite in the way the shape of the
thing suggests, and the difference is worth stating because it is the one that could bite.

Each package is **installed** into the target root like every other package (`ROOT=$TARGET`), and
it lands in `config/portage/lock/<profile>.lock` and the package audit where the existing
assertions can already see it. But it is **compiled** against the BUILDER root, not the target:
this pipeline never sets `SYSROOT`, so `portageq envvar ESYSROOT` answers `/`, and a `DEPEND` is
therefore resolved and installed there. That is why releasing `<id>-calamares-accounts` in a
relock builds `app-admin/calamares` and its `dev-libs/boost` tail into the builder — the target
already has them, and the builder is where the headers have to be.

The ABI guarantee still holds, because stage 20 mirrors the target's `package.use` onto the
builder and both roots install the same versions from the same pinned tree: at the time of
writing both carry `dev-qt/qtbase-6.11.1` and `kde-frameworks/*-6.27.0`. It holds by
CONSTRUCTION, not by ASSERTION — `builder.lock` and `<profile>.lock` are separate files and
nothing compares them. If they ever drift on Qt6 or KF6, these plugins would be compiled against
one and loaded against the other, which is exactly the silent load failure described above. Any
change that moves Qt or KF in one lock and not the other should move both.

## Layout

```
config/portage/overlay/
  metadata/layout.conf          masters = gentoo; thin manifests
  profiles/repo_name.in         the repo's name — rendered, so it follows DISTRO_ID
  profiles/categories.in        the one category, likewise
  distro-base/
    distro-kcm-managed/
      distro-kcm-managed-N.ebuild.in
      files/                    the entire source tree, copied by src_unpack
    distro-calamares-accounts/
      distro-calamares-accounts-N.ebuild.in
      files/                    C++, the QML under files/qml/, and the fallback module .conf
    distro-calamares-language/
      distro-calamares-language-N.ebuild.in
      files/                    same shape; no -DDISTRO_ID, because this page execs nothing
    distro-calamares-greeting/
      distro-calamares-greeting-N.ebuild.in
      files/                    C++ only — no qml/ — plus files/checker/, vendored from Calamares
    distro-calamares-disk/
      distro-calamares-disk-N.ebuild.in
      files/                    same shape as the language page; DiskModel is its own file
                                because it calls tr() and a Qt context is a class name
```

**Everything is rendered and rebranded on the way in.** Stage 20 runs the same
`install_rootfs_overlay()` over this tree that stage 40 runs over `config/rootfs/`: `*.in` files
have their `@TOKEN@`s substituted, and every path segment that is exactly the token `distro`
becomes `${DISTRO_ID}`. So `distro-base/distro-kcm-managed/distro-kcm-managed-1.0.ebuild.in`
installs as `immos-base/immos-kcm-managed/immos-kcm-managed-1.0.ebuild`, and renaming the distro
still needs one line in `config/build.conf` and nothing else.

The **C++ and QML sources under `files/` are not templates** and are copied byte for byte. Where
they need the distro's identity they take it as a compile definition the ebuild passes in
(`-DDISTRO_ID=`), which keeps `@TOKEN@` out of source files that a compiler, a linter or an IDE
also has to read.

## No Manifest files, on purpose

`metadata/layout.conf` sets `thin-manifests = true`, and no ebuild here has a `SRC_URI` — the
sources are in `files/`, inside the repository. A thin Manifest records only `DIST` entries, so
with no distfiles there is nothing for one to say. This is the same arrangement every local
overlay uses, and it is why `ebuild ... digest` is not part of anyone's workflow here.

## Adding a package

1. Write `distro-base/<name>/<name>-<version>.ebuild.in` and its `files/`.
2. Name it in the profile set that should carry it (`config/portage/sets/desktop`, `installer`…),
   with `#not-live` after the atom if a medium that boots once and is discarded should not have
   it — `filter_set_file` strips those lines on any profile whose `PROFILE_ROLE` is `live`.
3. **Re-resolve the lock**, because a locked build emerges `@locked-image` and nothing else:

   ```sh
   scripts/build.sh --only 20 && scripts/build.sh --only 30   # a target root with a VDB
   scripts/relock.sh <id>-base/<id>-kcm-managed               # release just this one
   cp out/reports/<profile>.lock.generated config/portage/lock/<profile>.lock
   ```

   `relock.sh --all` also works and is almost always the wrong tool: it re-resolves *everything*
   and moves every version pin as a side effect of adding one package (plan/15).

## What this repository is not

It is not a place to carry patched versions of Gentoo packages. `masters = gentoo` means an
ebuild here with the same name as one in the tree **shadows** it, and a shadowed package is a
version pin nobody can see in the lock diff. If a Gentoo package needs changing, the honest
mechanisms are `config/portage/package.use`, a `package.mask`, or a patch upstream.
