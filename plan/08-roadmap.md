# 08 — Roadmap & Accepted Tradeoffs

## Post-v1 roadmap (rough order)

### 1. Installer ISO with graphical installer
The stated next major goal. Design sketch, so v1 choices don't paint us into a corner:

- **Media:** hybrid ISO (xorriso/grub-mkrescue or systemd-boot ISO layout) carrying (a) a
  live boot of the *same* root EROFS with `systemd.volatile`-style tmpfs var — reusing the
  exact production image, and (b) the compressed disk image payload.
- **Installer:** GNOME-native, GTK4 + libadwaita, so the ISO carries no second toolkit — the
  live session already has the whole GTK stack, and pulling a Qt installer in would roughly
  double the ISO's UI dependencies for one screen flow. Either a purpose-built app or a
  `gnome-initial-setup`-derived flow; either way the responsibilities are the same thin set:
  picks target disk → writes the GPT layout ([04](04-image-and-boot.md)) sized to the disk →
  dd's ESP+root slot → creates var → runs `systemd-firstboot`-style user/locale/TZ pages →
  removes the baked live user. Cost vs. an off-the-shelf installer: more code to write, since
  none of the GTK options is as turnkey as the Qt ones — spike it before committing.
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
- **GNOME Software integration:** OS update visibility in the GUI next to Flatpak updates
  (gnome-software has a pluggable backend API; SteamOS does similar with its own centre).
- `/var` **migration hooks** if a release ever needs them (versioned oneshot design reserved
  in [05](05-updates.md)).

### 5. Hardware & platform breadth
- **fwupd** — UEFI capsule + device firmware updates; needs an ESP-write policy and
  `esp` mount coordination with sysupdate; straightforward addition to @hardware.
- **x86-64-v3 image variant** — measurable speedup on 2020+ big-core machines; second binhost
  + second channel; the generic image remains the compatibility floor.
- **Fingerprint (fprintd), IPU6/MIPI camera stack (libcamera)** as ecosystems mature.
- **Plymouth** flicker-free boot splash (currently: quiet console).
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
| UEFI-only, no BIOS | 5-year hardware window is UEFI-universal |
| Full-image (non-delta) updates | Simplicity + sysupdate stock behavior; roadmap #4 |
| No hibernation (zram-only swap) | Avoids swap-partition sizing and resume-offset fragility on an immutable, repartition-on-first-boot design |
| Baked `live` autologin user in v1 images | The image doubles as live media; real user management arrives with the installer |
| Native GNOME apps limited to gnome-console/nautilus | Everything else Flatpak — the point of the distro; portals make it seamless. file-roller and gnome-text-editor were dropped after 0.1.0: nautilus already extracts/compresses via gnome-autoar, and the editor was the sole consumer of a 12-package tail ([03](03-package-set.md), "Dropped from the native set"). Neither is preinstalled as a Flatpak — `org.gnome.Platform` is ~1.07 GB in a 4 GiB `/var` — so a user who wants one installs it from GNOME Software |
| Generic x86-64 (no AVX2 floor) | Budget Atom-class CPUs sold within the window lack AVX2 |
| WebKitGTK excluded natively (`-gnome-online-accounts`, `evolution-data-server[-oauth]`) | Biggest single build/system-size win; browser ships as Flatpak Firefox |

## Open questions (to resolve during implementation, with data)

1. Does anything in the target set drag in python/perl as an RDEPEND? → dep-audit gate in
   [06](06-pruning.md) decides; fix with USE tweaks or accept with a whitelist entry.
2. Flatpak preinstall inside chroot — verify ostree pulls work under the builder's network;
   fallback `firstboot` mode exists ([03](03-package-set.md)).
3. Exact UKI size with `--no-hostonly` dracut (ESP sized 1 GiB with 2× margin; confirm).
4. GDM Wayland greeter stability on NVIDIA — GDM's shipped udev rule disables Wayland on
   NVIDIA unless DRM modesetting is on, which the UKI cmdline sets (`nvidia-drm.modeset=1`).
   If it still falls back, the greeter would want X11 — revisit the no-Xorg stance for the
   greeter alone before giving it up session-wide.
5. `bash-completion`/zsh data: keep or prune — size report decides (marked REVISIT in 06).
