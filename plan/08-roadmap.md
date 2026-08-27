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
- **Own the kernel config** — `sys-kernel/gentoo-kernel` instead of `-bin`. The single largest
  remaining lever, and the one thing [plan/11](11-kernel-boot-audit.md) could not touch: the
  generic dist-kernel ships 4910 modules / 623 MiB and cannot compress modules. A config cut to
  this image's hardware scope would be worth more than every prune in plan/10 and plan/11
  combined. The cost is owning that config across every kernel bump, and a source kernel build
  in the pipeline. It would also give the splash a firmware framebuffer to draw on
  (`DRM_SIMPLEDRM`), which is now a nicety rather than the fix for anything —
  [plan/14](14-boot-splash-kms.md) covers the pre-modeset window with the EFI stub instead.
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
| Pascal (GTX 10-series) & older NVIDIA → no working GPU driver | `kernel-open` covers Turing+ only; pre-Turing machines fall outside the 5-year target. `nouveau` is dropped from `VIDEO_CARDS` and was never a live fallback anyway — `nvidia-drivers` blacklists it unconditionally (plan/03, plan/10). Revisit only if user demand appears (would require the legacy proprietary branch and a second driver variant) |
| No 3-way `/etc` merge (overlay upper shadows vendor changes) | OSTree-grade merge machinery is not worth v1 complexity; `immos-update etc-diff` gives visibility |
| No Secure Boot in v1 | Owner decision; documented "disable in firmware"; roadmap #2 |
| Boot splash cannot render a passphrase prompt, or any text at all | Every glyph is pre-rendered to pixels at build time and the splash ships as opaque tiles ([plan/14](14-boot-splash-kms.md)), so no font, no text engine and no image decoder is in the image or the boot path. Costs nothing today (no LUKS, no fsck prompt). This was previously a USE-flag decision (`sys-boot/plymouth[-pango]`, reversible by flipping the flag); it is now structural — adding full-disk encryption would mean giving the splash program a text renderer, or handing the prompt to something else entirely |
| No generic firmware framebuffer: the splash must be two programs, not one | `gentoo-kernel-bin` is a binary dist-kernel and `/usr/src` is pruned, so the graphics config is whatever Gentoo ships and cannot be changed without leaving `-bin`. Verified against the 6.18.43 config: `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` (good, and load-bearing), but `DRM_SIMPLEDRM`, `DRM_EFIDRM`, `DRM_VESADRM` and `SYSFB_SIMPLEFB` are all **unset**, and `CONFIG_FB_DEVICE` is unset too — so there is no generic firmware-framebuffer DRM device and no `/dev/fb0` either. Nothing can draw before the first real KMS driver except the EFI stub, and every fbdev-era splash is impossible outright. [plan/14](14-boot-splash-kms.md) covers the timeline with two pieces instead of one: the stub's `.splash` bitmap up to the first modeset, and a DRM client after it. The remaining gap is now the *modeset itself*, not the minutes around it |
| ~~NVIDIA machines get no splash until after the root pivot~~ | **MOOT since 2026-08-27 ([plan/14](14-boot-splash-kms.md)).** plan/11 finding 4 fixed this by putting the three nvidia modules in the initrd at a cost of +71.5 MiB of UKI, nearly all of it GSP firmware. No splash runs before the root pivot on *any* GPU now — the stub bitmap covers that window on all hardware equally, and the initrd carries no graphics at all. `10-nvidia-drm.conf`'s softdep stays and is still the only thing that loads `nvidia-drm`; its scope is now the booted system |
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
6. ~~**Restore a retain-splash hand-off.**~~ **CLOSED 2026-08-27
   ([plan/14](14-boot-splash-kms.md)).** Answered twice, and the second answer is that the
   question was the wrong shape. plan/11 finding 7 solved it within plymouth by changing the
   teardown rather than who performs it (a drop-in replacing `plymouth-quit.service`'s
   `ExecStart` with `plymouth quit --retain-splash`) — correct, and still four coupled units.
   The KMS splash drops DRM master the moment it has painted, so kwin can take master whenever
   it likes and the splash notices afterwards and exits. There is nothing to order, nothing to
   conflict with, and nothing left in the image that mentions the splash except its own unit and
   udev rule. Both the race and the deadlock this question spent two rounds on are gone with the
   coupling that created them.
