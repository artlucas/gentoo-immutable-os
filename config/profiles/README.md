# config/profiles — build profiles

A **build profile** says *what goes in the image*: which package sets are emerged, and which
build.conf knobs are overridden for this variant. `scripts/build.sh --profile <name>` selects
one; the default is `desktop`.

Introduced by [plan/16](../../plan/16-installer.md) so the Calamares installer can be built into
a live-only image that is booted from USB and thrown away, while the installed system stays free
of it. That guarantee is not a convention — `config/portage/expected-packages.<profile>.txt` is
per-profile and stage 50 fails the build on unexplained additions.

## Two different things are called "profile"

They are unrelated and both apply to every build:

| | Set by | Means |
|---|---|---|
| `PROFILE` | `config/build.conf` | The **Gentoo portage profile** — `default/linux/amd64/23.0/desktop/plasma/systemd`. Selects USE defaults, the ABI and the package.mask baseline |
| `BUILD_PROFILE` | `--profile`, default `desktop` | The **build profile** — this directory. Selects which sets are emerged and which knobs are overridden |

`BUILD_PROFILE` is deliberately **not** a key in `config/build.conf`. Everything in that file is
hashed into `portage_config_hash()`, which every lock header records and stage 20 asserts
against, so adding a key there would invalidate every committed lock for a value that changes
per run anyway.

## Writing one

Same discipline as `build.conf`: `key="value"` only, no logic. Sourced *after* `build.conf`, so
any knob it sets overrides that file's value; command-line overrides (`--version`, …) still win
over both.

| Key | Required | Meaning |
|---|---|---|
| `PROFILE_DESC` | yes | One line, shown by `--list-profiles` |
| `PROFILE_ROLE` | yes | `target` (installable; may be released) or `live` (install media; never released) |
| `PROFILE_SETS` | yes | Space-separated set names from `config/portage/sets/`. Must include `base` |
| `PROFILE_ROOT_SLOTS` | no (2) | Root slots. `2` is the A/B pair every installable image needs; `1` is for live media, which are never updated. A `target` profile with `1` is refused — it would build a machine that boots and can never be updated |
| `PAYLOAD_PROFILE` | no | An installer profile only: the `target` profile whose artifacts this medium writes to disk. Its root EROFS, UKI and `/var` tarball are staged into this image's `/var` by stage 40 |

`live` is not a label. It changes what stage 40 does: `systemd-sysupdate` is disabled on the
medium (its transfer definitions are removed and its units masked), because a stick that is
booted once and thrown away has nothing to update and a half-working update path is worse than
none. It touches the medium only — the installed system's `/usr` comes from the payload, whose
transfers are intact.

Anything else in the file is a `build.conf` override — `INCLUDE_DISTROBOX`, `FLATPAK_PREINSTALL`,
`VAR_SIZE_MIB` and so on.

**A profile selects package sets. It must not change USE flags.** Every profile emerges from the
same config root, the same `make.conf` and the same `package.use`, so packages two profiles share
resolve to the same binpkg in `/cache/binpkgs` and the second profile mostly *merges* instead of
compiling. Change a USE flag per profile and the second build becomes another multi-hour Qt/KDE
compile. See [plan/16](../../plan/16-installer.md) §3.2.

## Per-profile files

The default profile keeps every path it has today, so an existing work volume and `out/` tree stay
valid. Other profiles are suffixed, so two profiles cannot share a target rootfs, a stage stamp or
an output image.

| | `desktop` (default) | any other profile |
|---|---|---|
| lock | `config/portage/lock/desktop.lock` | `config/portage/lock/<name>.lock` |
| audit gate | `config/portage/expected-packages.desktop.txt` | `…expected-packages.<name>.txt` |
| target rootfs | `/work/target` | `/work/target-<name>` |
| config root | `/work/config` | `/work/config-<name>` |
| stage stamps | `out/state` | `out/state-<name>` |
| reports | `out/reports` | `out/reports-<name>` |
| image | `out/<id>-<ver>.img` | `out/<id>-<ver>-<name>.img` |
| root image | `out/<id>_<ver>.root.erofs` | `out/<id>_<ver>-<name>.root.erofs` |
| `/var` template | `out/<id>_<ver>.var.tar.zst` | `out/<id>_<ver>-<name>.var.tar.zst` |

What is **never** profile-suffixed is anything the installed system can see — the UKI filename,
the `root_<version>` partlabel, `os-release`. A system installed from one profile's payload must
be indistinguishable from one dd'd from another's image, or `systemd-sysupdate` breaks. See
[plan/16](../../plan/16-installer.md) §3.4.

## The profiles

| profile | role | sets | is |
|---|---|---|---|
| `desktop` | target | base hardware desktop | The product, and what the installer writes to disk |
| `console` | target | base hardware | The M1 milestone image: systemd + getty, no desktop |
| `installer` | live | base hardware desktop **installer** | A live Plasma session that runs Calamares, plus the `desktop` payload it installs. Booted from a USB stick, never installed. See [config/calamares](../calamares/README.md) |

## The `/var` template

A `target` profile's build publishes its `/var` as `out/<id>_<ver>.var.tar.zst` alongside its root
EROFS (stage 60). Nothing in that image uses it — it exists so an installer medium can **seed** a
`/var` rather than rebuild one, and it is packed from the same staging tree the image's own
`var.img` is built from, so a seeded `/var` and a `dd`'d one are the same bytes by construction.
