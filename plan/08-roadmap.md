# 08 — Roadmap & Accepted Tradeoffs

## Post-v1 roadmap (rough order)

### 1. Installer ISO with graphical installer
The stated next major goal. Design sketch, so v1 choices don't paint us into a corner:

- **Media:** hybrid ISO (xorriso/grub-mkrescue or systemd-boot ISO layout) carrying (a) a
  live boot of the *same* root EROFS with `systemd.volatile`-style tmpfs var — reusing the
  exact production image, and (b) the compressed disk image payload.
- **Installer:** Qt/Kirigami, so the ISO carries no second toolkit — the live session already
  has the whole Qt6 + Frameworks stack, and pulling a GTK installer in would roughly double the
  ISO's UI dependencies for one screen flow. (This reverses with the desktop: the same argument
  said GTK4 + libadwaita when the session was GNOME.) The responsibilities are the same thin
  set either way: picks target disk → writes the GPT layout ([04](04-image-and-boot.md)) sized
  to the disk → dd's ESP+root slot → creates var → runs `systemd-firstboot`-style
  user/locale/TZ pages → removes the baked live user.
  The cost calculation also flips, in our favour: the turnkey options in this space (Calamares
  above all) *are* the Qt ones, so "more code to write than an off-the-shelf installer" is no
  longer a given — spike Calamares against a purpose-built Kirigami app before committing.
- v1 groundwork already in place: identical image on any medium, var-grows-to-disk, no
  NVRAM dependency, all identity in `build.conf`.

### 2. Secure Boot
Options, in increasing effort: (a) document `sbctl`-style self-enrollment for enthusiasts
(sign our UKIs with a key the user enrolls); (b) ship a signing-friendly flow in the
installer (generate machine-owner key, enroll via firmware setup mode, sign both sd-boot and
UKI); (c) shim review process for a Microsoft-signed shim — only worth it with real adoption.
UKI-everywhere makes any of these a signing step in stage 80, not an architecture change.

### 3. dm-verity + signed partitions
Move integrity from download-time to read-time: emit a verity hash tree per root image
(`systemd-repart`/`veritysetup` at build), UKI cmdline gains `roothash=`, sysupdate ships the
verity partition alongside (the transfer/partition scheme was chosen to be compatible —
add two `usr-verity`-style partitions or switch root→usr layout then). Pairs naturally with
Secure Boot for a full trust chain.

### 4. Update improvements
- **Deltas:** full-image updates are ~3 GiB; evaluate systemd-sysupdate + casync chunk store,
  or erofs chunk-dedup between consecutive images.
- **Unattended updates:** enable `systemd-sysupdate.timer` by default (staged rollout knob:
  `UPDATE_URL` per channel already supports `stable`/`testing`).
- **Discover integration:** OS update visibility in the GUI next to Flatpak updates. Discover
  has a pluggable backend API the same way gnome-software did; SteamOS does similar with its
  own centre.
- `/var` **migration hooks** if a release ever needs them (versioned oneshot design reserved
  in [05](05-updates.md)).

### 5. Hardware & platform breadth
- **fwupd** — UEFI capsule + device firmware updates; needs an ESP-write policy and
  `esp` mount coordination with sysupdate; straightforward addition to @hardware.
- **x86-64-v3 image variant** — measurable speedup on 2020+ big-core machines; a second
  `COMMON_FLAGS`, its own binpkg cache (the image compiles what it ships, so the two variants
  cannot share one) and its own update channel; the generic image remains the compatibility
  floor.
- **Fingerprint (fprintd), IPU6/MIPI camera stack (libcamera)** as ecosystems mature.
- **ARM64** — the pipeline is arch-parameterizable in principle (crossdev or native arm64
  builder); explicitly out of scope until AMD64 is solid.

### 6. Ecosystem/ops
- CI runners with KVM for the full T1–T3 suite ([07](07-testing.md)).
- Reproducible-build verification (two independent builds → identical erofs digest; `-T0`
  and pinned inputs already aim at this).
- A real name, branding, wallpaper, and `HOME_URL` — everything is already behind
  `DISTRO_ID`/`DISTRO_NAME` in `build.conf`.

## Accepted tradeoffs (decided, documented, not bugs)

| Tradeoff | Rationale |
|---|---|
| Pascal (GTX 10-series) & older NVIDIA → nouveau fallback | `kernel-open` covers Turing+ only; pre-Turing machines fall outside the 5-year target. Revisit only if user demand appears (would require the legacy proprietary branch and a second driver variant) |
| No 3-way `/etc` merge (overlay upper shadows vendor changes) | OSTree-grade merge machinery is not worth v1 complexity; `immos-update etc-diff` gives visibility |
| No Secure Boot in v1 | Owner decision; documented "disable in firmware"; roadmap #2 |
| Boot splash cannot render a passphrase prompt | `sys-boot/plymouth[-pango]`: all splash text is pre-rendered to PNG at build time, so no font ships in the image. Costs nothing today (no LUKS, no fsck prompt); adding full-disk encryption means turning `pango` back on first — it pulls no new packages, since pango/cairo/libpng are already there for the GTK theming bridge |
| Possible brief console flash between firmware logo and splash | `gentoo-kernel-bin` is a binary dist-kernel and `/usr/src` is pruned, so the graphics config is whatever Gentoo ships and cannot be changed without leaving `-bin`. Verified against the 6.18.43 config: `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` (good), but `DRM_SIMPLEDRM`, `DRM_EFIDRM`, `DRM_VESADRM` and `SYSFB_SIMPLEFB` are all **unset**, and `CONFIG_FB_DEVICE` is unset too — so there is no generic firmware-framebuffer DRM device and no `/dev/fb0` either. Plymouth must wait for a real DRM driver, and plymouth's `frame-buffer.so` renderer can never be the fallback. Pre-empting the firmware logo is now possible via `SPLASH_BACKEND=both` (a `.splash` section in the UKI, see [04](04-image-and-boot.md)), but that covers only the pre-kernel window; closing the modeset gap itself needs a kernel with simpledrm, i.e. `sys-kernel/gentoo-kernel` with a custom config |
| NVIDIA machines get no splash until after the root pivot | The proprietary modules live in `/usr/lib/modules/<kver>/video/` and are **not** in the initrd (dracut's `drm` module globs `drivers/gpu/drm` only), while `/etc/modprobe.d/nvidia.conf` — which *is* in the initrd — blacklists `nouveau`. So the initrd has no usable DRM device on NVIDIA at all: plymouth waits out `DeviceTimeout=8` and falls back to text. Fix is `--add-drivers "nvidia nvidia-drm nvidia-modeset"` in stage 40. Related: the initrd also carries ~150 MiB of nouveau GSP firmware (`/usr/lib/firmware/nvidia`) for that blacklisted driver, because stage 50's firmware prune runs *after* stage 40 builds the initrd |
| UEFI-only, no BIOS | 5-year hardware window is UEFI-universal |
| Full-image (non-delta) updates | Simplicity + sysupdate stock behavior; roadmap #4 |
| No hibernation (zram-only swap) | Avoids swap-partition sizing and resume-offset fragility on an immutable, repartition-on-first-boot design |
| Baked `live` autologin user in v1 images | The image doubles as live media; real user management arrives with the installer |
| Native apps limited to Konsole/Dolphin | Everything else Flatpak — the point of the distro; portals make it seamless. Ark, Kate, Okular and Gwenview are deliberately absent for the same reason file-roller and gnome-text-editor were dropped after 0.1.0 ([03](03-package-set.md), "Dropped from the native set"). One genuine regression to note: Dolphin does **not** get archive handling for free the way nautilus did through gnome-autoar. A user who wants any of these installs it from Discover |
| Generic x86-64 (no AVX2 floor) | Budget Atom-class CPUs sold within the window lack AVX2 |
| No browser engine natively (`USE=-webengine` + hard masks on `net-libs/webkit-gtk` and `dev-qt/qtwebengine`) | Biggest single build/system-size win; browser ships as Flatpak Firefox. Under GNOME this was `-gnome-online-accounts` + `evolution-data-server[-oauth]` holding webkit-gtk out; under Plasma it is a global USE flag plus the mask, i.e. structural rather than flag-dependent |

## Open questions (to resolve during implementation, with data)

1. Does anything in the target set drag in python/perl as an RDEPEND? → dep-audit gate in
   [06](06-pruning.md) decides; fix with USE tweaks or accept with a whitelist entry.
2. Flatpak preinstall inside chroot — verify ostree pulls work under the builder's network;
   fallback `firstboot` mode exists ([03](03-package-set.md)).
3. Exact UKI size with `--no-hostonly` dracut (ESP sized 1 GiB with 2× margin; confirm).
4. Wayland on NVIDIA — this used to be a *greeter* question (GDM's shipped udev rule disabled
   Wayland on NVIDIA unless DRM modesetting was on, which the UKI cmdline sets with
   `nvidia-drm.modeset=1`). With Plasma Login Manager it collapses into the **session**
   question, because PLM runs its greeter on `kwin` — the same compositor the session uses.
   There is no separate greeter stack to fall back independently, and no X11 fallback exists to
   fall back *to*: `kde-plasma/kwin` is Wayland-only and `kwin-x11` is not installed. So if this
   fails on NVIDIA it fails at the session level and the fix is session-wide, not greeter-only.
5. `bash-completion`/zsh data: keep or prune — size report decides (marked REVISIT in 06).
6. **Restore a retain-splash hand-off.** `gdm[plymouth]` quit the splash itself with
   `--retain-splash` once the greeter had painted, so there was no black frame between splash
   and login. Plasma Login Manager has no equivalent, so `plymouth-quit.service` tears the
   splash down and `plasmalogin.service` is merely ordered after `plymouth-quit-wait` — a
   deterministic hand-off, but a visible one. Worth a look at whether PLM can be made to run
   `plymouth quit --retain-splash` from a drop-in `ExecStartPre`/`ExecStartPost`.
