# 13 — Distrobox: the mutable userland

## Why

The front page of this repo says the shipped OS contains no compiler and no Portage. That is
the right shape for a desktop and the wrong shape for a developer machine, and the gap is not
one Flatpak closes: Flatpak packages *application windows*. It has no answer to "I need apt,
a compiler and a header package", which is the single most common reason someone gives up on
an immutable distro.

Distrobox is the answer every other immutable distro landed on — Silverblue's toolbox, Bluefin,
Aeon. It runs a full mutable distro inside a **rootless** OCI container with `$HOME`, the
Wayland socket, DBus, and devices bound through, so the shell, the files and the desktop are
shared while the *packages* live somewhere else. That somewhere else is `/var`, on the growable
partition that already holds `/var/lib/flatpak`, so it survives A/B root updates and a factory
reset wipes it.

**This does not weaken the toolchain-free guarantee, it completes it.** plan/06 is about what
ships on the read-only root: no compiler in the EROFS, no Portage, no `/usr/include`, and stage
50 asserts all of it. None of that changes. What changes is that there is now a sanctioned
place for a compiler to exist — in a container, in `/var`, owned by the user, deletable in one
command — instead of the user's only options being "rebuild the image" or "give up". The
assertions in stage 50 draw the line in exactly the same place they already draw it for Flatpak
payloads (`-path "$T/var/lib/flatpak" -prune`): the guarantee is about the image, not about
what the user may run on it.

## Decisions

| | |
|---|---|
| Backend | **rootless podman**, plus the `docker` compatibility wrapper |
| Gating | `INCLUDE_DISTROBOX` in `build.conf`, default **1** |
| Preloaded container | **none** — first `distrobox create` pulls over the network |
| Default image | `docker.io/library/debian:stable` |

**Podman, not docker.** Docker is a root daemon with a socket; podman is a fork/exec model with
no daemon at all, which is the only one of the two that fits an image whose root is read-only
and whose design principle is that nothing privileged runs that does not have to. Rootless is
not a hardening extra here, it is the entire point: containers run under the user's own
subordinate UID range, storage lives in their home, and root is never involved.

**No box is preloaded.** Preloading would mean `podman pull`-ing a base image into the live
user's storage during stage 40 — 300–800 MiB into a `/var` that is 4 GiB as shipped and already
carries Firefox plus four KDE flatpaks. It would also make the *image build* depend on a
registry pull. The cost of not doing it is that the first `distrobox create` needs a network,
which is the same deal Silverblue makes.

**Debian stable as the default image.** Set in `/etc/distrobox/distrobox.conf` rather than left
to distrobox's own default, and written **fully qualified** — a bare `debian:stable` would be
resolved through `containers-common`'s `unqualified-search-registries`, i.e. through a
registry-order heuristic in a config file this image neither owns nor asserts on.

## What actually ships

Two atoms in `@base`, both marked `#distrobox`:

```
app-containers/podman            #distrobox
app-containers/distrobox         #distrobox
```

Everything else arrives as RDEPEND and is deliberately **not** listed — the same discipline
plan/03 applies to baloo's four packages. The full tail, roughly 16 new entries in
`expected-packages.txt`:

| Package | Role |
|---|---|
| `app-containers/crun` | the OCI runtime podman execs (C, not Go — small and fast) |
| `app-containers/conmon`, `app-containers/catatonit` | per-container monitor and PID-1 reaper |
| `app-containers/containers-common` | `/etc/containers` config, and the dependency hub below |
| `app-containers/containers-image`, `-storage`, `-shortnames` | config + docs for the same stack |
| `app-containers/netavark`, `app-containers/aardvark-dns` | rootful container networking and DNS (Rust) |
| `net-misc/passt` (`pasta`) | **the one rootless podman actually uses** for networking |
| `sys-fs/fuse-overlayfs` | rootless overlay fallback where the kernel's own is unavailable |
| `net-firewall/nftables`, `net-libs/libnftnl`, `net-misc/ethertypes` | see below |
| `app-containers/distrobox`, `app-containers/podman` | the two named atoms |

Already in the image and therefore free: `app-crypt/gpgme`, `dev-libs/libassuan`,
`dev-db/sqlite`, `sys-libs/libseccomp`, `net-firewall/iptables`, `sys-fs/fuse`,
`sys-apps/shadow`, `net-libs/libmnl`, `dev-libs/gmp`, `sys-libs/readline`, `dev-libs/jansson`.

`config/portage/expected-packages.txt` is **not** updated in the same commit as the package-set
change, on purpose — it is generated, not hand-written (see its header). The first build after
this change stops at stage 50 with the exact diff; the workflow is the one commit `16e8201`
used for Spectacle:

```sh
bash scripts/build.sh                                   # stops at stage 50 with the diff
cp out/reports/expected-packages.txt.generated \
   config/portage/expected-packages.txt                 # after reviewing it
bash scripts/build.sh --from 50
```

Predicting the list here would be hand-writing it, and the gate is symmetric — an entry that
does not appear fails the diff exactly like a missing one — so there is nothing to gain and a
precedent to lose.

### No keyword exception

Worth recording, because it is the thing that would normally make a change this size expensive
here. `config/portage/package.accept_keywords/image` opens with "Keep empty if possible —
stable amd64 only", and the whole stack has a stable-`amd64` version at `SNAPSHOT_DATE`:
`distrobox-1.8.2.5`, `podman-5.8.2`, `crun-1.28`, `conmon-2.1.13`, `catatonit-0.2.1`,
`containers-common-0.64.2`, `netavark-1.17.1`, `aardvark-dns-1.17.1`, `passt-2025.12.15`,
`fuse-overlayfs-1.16`, `nftables-1.1.6`. Newer versions of most of them are `~amd64`; none is
taken. This change adds **zero** lines to that file.

### A firewall stack arrives that nothing runs

`containers-common` RDEPENDs `net-firewall/nftables` and `net-firewall/iptables[nftables]`
unconditionally. Neither is used: rootless podman networks through `pasta`, and netavark's nft
driver talks netlink rather than shelling out to `nft`. There is no USE flag that declines
them. `iptables` was already in the image (NetworkManager's `connection-sharing`) but built
without `nftables`, so it gains a flag and a rebuild; `nftables` is new and is built as small as
its IUSE allows — notably `-python`, because stage 50's interpreter policy has not decided
whether python may ship and a firewall tool nothing executes must not be what decides it.

### Go and Rust on the builder

podman is Go; netavark and aardvark-dns are Rust. Both toolchains are BDEPEND, so they install
to the builder's `/` and never reach the image. They are named explicitly in
`builder/Dockerfile` anyway, for a reason that is not just caching: `virtual/rust` is satisfied
by either `dev-lang/rust` or `dev-lang/rust-bin`, and with neither installed portage is free to
pick the from-source one — hours of compiling a toolchain to produce two 10 MiB binaries.
Installing `rust-bin` from the binhost first settles it.

## Rootless, structurally

Three things have to be true together, and each fails silently on its own:

1. **`newuidmap` / `newgidmap` are setuid-root.** They ship mode `4755` from `sys-apps/shadow`
   — plain setuid bits, **not** file capabilities, which is why EROFS carries them intact with
   no xattr concern. Without the setuid bit the binaries are present and every `podman`
   invocation dies in a way that names neither of them. Stage 50 asserts the mode.
2. **The live user has subordinate ID ranges.** `useradd -m` in stage 40 probably allocates
   them already — the target's `/etc/login.defs` ships active `SUB_UID_MIN`/`SUB_UID_COUNT`
   lines and shadow's `pkg_postinst` creates `/etc/subuid` and `/etc/subgid`, which is the
   condition it allocates on. "Probably" does not survive a shadow bump, so stage 40 claims
   `100000-165535` explicitly when the range is missing, and stage 50 asserts it landed.
3. **No system-wide podman socket.** `podman.service`, `podman.socket`, `podman-restart`,
   `podman-auto-update.timer` and `podman-clean-transient` are all `disable`d in the vendor
   preset, for the same reason `sshd.service` is. Stage 50 asserts no enablement symlink
   survives — `preset-all` also applies *vendor* presets, which is precisely how
   systemd-networkd once got enabled behind our backs (plan/03).

Stage 70 checks all three at once from inside a booted guest, with one reported field:

```
podman_rootless=$(runuser -u live -- podman info --format '{{.Host.Security.Rootless}}')
```

`podman info` and not `podman run`: no image is preinstalled, so anything that pulls would turn
this assertion into a test of the build host's network. What it does exercise is
`CONFIG_USER_NS` in `gentoo-kernel-bin`, the setuid map helpers through EROFS, the subuid range,
and a storage driver that works on the ext4 `/var`. It is asserted, not merely reported.

## The docker wrapper

`podman[wrapper]` installs `/usr/bin/docker`, a shell wrapper that execs podman. It is kept:
it costs one file, and a great deal of muscle memory and a great many scripts say `docker`.
The ebuild's `!app-containers/docker-cli` blocker is inert — no docker package is in this image
or ever will be.

What does **not** ship is the `podman-docker.conf` tmpfiles snippet that comes with the flag.
It symlinks `/run/docker.sock` at `/run/podman/podman.sock`, the *rootful* API socket this
image's preset disables and nothing ever starts. Stage 50 deletes it and asserts it stayed
deleted: a socket path that exists and refuses every connection is a worse failure than one
that is simply absent, because it makes a client report "connection refused" instead of
"docker is not running".

## What the user gets

```sh
distrobox create --name dev             # pulls docker.io/library/debian:stable
distrobox enter dev
sudo apt install build-essential        # a compiler, in /var, off the read-only root
distrobox-export --app gimp             # its launcher appears in the Plasma menu
```

Storage is `~/.local/share/containers` → `/var/home/<user>/…`, so boxes survive A/B updates and
are removed by a factory reset (plan/05). `distrobox rm dev` and the compiler is gone.

## Verified on the 0.3.0 image

Driven over the serial console of a booted guest (`run-vm.sh --disk-size 40G`), not inferred
from the build:

```
/dev/vda4  27G  2.8G  23G  11% /var
distrobox create --name dev --yes
    Trying to pull docker.io/library/debian:stable...
    Copying blob 21267a18de01 [====================>] 46.2MiB / 47.1MiB
    Distrobox 'dev' successfully created.
podman images   -> docker.io/library/debian:stable 248 MB
podman ps -a    -> dev  Created  docker.io/library/debian:stable
distrobox enter dev -- sh -c 'cat /etc/debian_version; id -u; touch ~/made-in-box; ...'
    Starting container... [OK]   Installing basic packages... [OK]
    Setting up sudo... [OK]      Container Setup Complete!
    13.6          <- Debian 13.6 inside the box
    1000          <- same uid as the host user: the rootless mapping works
    done-inside
ls -l ~/made-in-box -> -rw-r--r-- 1 live live 0 /home/live/made-in-box
/dev/vda4  27G  3.6G  22G  14% /var
```

The last two lines are the point of the whole feature: a file written from inside the
container is on the host's `$HOME` with the host user's ownership, and the packages that made
it possible cost `/var` 0.8 GiB rather than costing the read-only root anything.

**That 0.8 GiB is also why `--disk-size` exists.** A stock image's `/var` is 3.9 GiB with
~2.8 GiB already spent on Firefox and the KDE flatpaks, leaving under a gigabyte — enough to
*just* land the base image and nothing else, so the first `apt install` in the box would fail
on a full disk. On real hardware repart grows `/var` into the whole drive at first boot and
the problem never arises; it is specific to booting the image file directly in a VM.

## Known consequences

- **`/var` pressure.** A Debian box is ~400 MiB pulled plus whatever gets installed into it.
  The shipped `VAR_SIZE_MIB=4096` already carries Firefox and four KDE flatpaks; on real
  hardware `systemd-repart` grows `/var` to the disk at first boot (plan/01), so this only
  bites in a VM booted from an unexpanded image.
- **First build is longer.** Go and Rust on the builder, plus podman/netavark/aardvark-dns
  compiled into `/cache/binpkgs`. Cached thereafter.
- **The installer will need the same subuid work.** Stage 40 handles `LIVE_USER`. A future
  installer (plan/08) creating a real user must allocate subordinate ranges too, or rootless
  podman breaks for that user and only that user. `/etc/login.defs` makes `useradd` do it by
  default, which is why this is a note rather than a blocker.
- **`INCLUDE_DISTROBOX=0` must stay real.** Stage 50 asserts the *negative* case too — an image
  built with the switch off that still contains podman means `filter_set_file` silently stopped
  filtering, which is the kind of thing that only shows up as an unexplained size regression.

## A bug this found

`render_dest_name()` rebrands `distro` in overlay filenames to `${DISTRO_ID}`, and it did so as
a plain **substring** replacement. `config/rootfs/etc/distrobox/distrobox.conf.in` therefore
installed itself as `/etc/distrobox/immosbox.conf` — a config file distrobox never reads, with
nothing anywhere reporting a problem. The rule is now token-wise: the name is split on `-` and
`.`, and only a segment that is exactly `distro` is rewritten. Every name the overlay actually
ships uses the word as a whole token, so the two rules agree everywhere except where the old one
was wrong. Covered by `tests/test-common.sh`.
