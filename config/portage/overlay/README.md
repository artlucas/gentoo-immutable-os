# The in-repo ebuild repository

Two things this project ships have to be **compiled against the target's own Qt6/KF6**, and
therefore cannot be built the way everything else in `config/rootfs/` is:

| | |
|---|---|
| `<id>-kcm-managed` | The System Settings module for managed mode ([plan/19](../../../plan/19-managed-mode.md) §7.2). A Plasma KCM is a C++ plugin; there is no QML-only path into System Settings |
| `<id>-calamares-managed` | The installer page for managed enrolment (plan/19 §7.3). Calamares accepts **only** C++ `QtPlugin` view modules — `ModuleFactory.cpp:53` — so a page cannot be a script |

**Why an ebuild repository rather than a hand-compile in stage 40.** plan/18 §7.2 rejected
compiling a Calamares module by hand, and the reason was never "C++ is hard": it was that a
hand-compiled plugin is built against *whatever headers happen to be around*, while the target's
Qt6 and KF6 come from this pipeline's own resolution. The two can disagree, and a Qt plugin whose
ABI does not match its host does not fail to build — it fails to **load**, silently, at runtime,
on a machine with no way to install a fix.

Letting Portage build them removes the question. Each package is emerged into the target root
like every other package, against the exact `dev-qt/*` and `kde-frameworks/*` versions
`config/portage/lock/<profile>.lock` pins, and it lands in the lock file and the package audit
where the existing assertions can already see it.

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
    distro-calamares-managed/
      ...
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
2. Name it in the profile set that should carry it (`config/portage/sets/desktop`, `installer`…).
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
