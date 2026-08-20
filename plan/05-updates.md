# 05 — A/B Updates

## Design summary

The chosen architecture is SteamOS-style A/B: download new root image → write to inactive
slot → install new UKI with a tries counter → reboot → auto-rollback if it doesn't come up.
Rather than hand-rolling the transactional logic in Bash, the **client is
`systemd-sysupdate`** driven by two transfer definitions shipped in the image, wrapped by a
thin branded CLI (`${DISTRO_ID}-update`). sysupdate provides, battle-tested: version
discovery from a manifest, download + decompression + SHA256 + GPG verification, writing the
inactive partition and **relabeling it as the last step** (crash-safe), ESP file installs
with boot-counting filenames, and `InstancesMax` retention. dm-verity is deliberately not
used in v1 (roadmap).

## Versioning

- `VERSION` in `build.conf`: dotted-decimal `X.Y.Z`, strictly increasing by `strverscmp`
  ordering (what sysupdate and systemd-boot both use to pick "newest"). Release discipline:
  never reuse or decrease.
- The running system knows its version from `/etc/os-release` `IMAGE_VERSION`; each artifact
  embeds the version in its filename and (for root partitions) in the GPT partlabel.

Version requirement: the features used below (`.transfer` files, `PathRelativeTo=`, tries
counters) need a recent systemd (≥ v256); pin the systemd version floor in
`config/portage/` accordingly.

## Transfer definitions (shipped at `/usr/lib/sysupdate.d/`)

`50-rootfs.transfer` — the root image → inactive slot:

```ini
[Transfer]
Verify=yes                      # SHA256SUMS + SHA256SUMS.gpg against /usr/lib/systemd/import-pubring.gpg

[Source]
Type=url-file
Path=${UPDATE_URL}              # e.g. https://updates.example.org/immos/stable/
MatchPattern=${DISTRO_ID}_@v.root.erofs.zst

[Target]
Type=partition
Path=auto                       # the GPT the ESP lives on
MatchPartitionType=root
PartitionLabel=root_@v          # ← relabel-on-completion gives us the version-labeled slot
InstancesMax=2                  # exactly our two slots
ReadOnly=yes
```

`60-uki.transfer` — the UKI → ESP with boot counting:

```ini
[Transfer]
Verify=yes

[Source]
Type=url-file
Path=${UPDATE_URL}
MatchPattern=${DISTRO_ID}_@v.efi

[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot             # resolves to the ESP
MatchPattern=${DISTRO_ID}_@v+@l-@d.efi ${DISTRO_ID}_@v+@l.efi ${DISTRO_ID}_@v.efi
TriesLeft=3
TriesDone=0
InstancesMax=2                  # current + previous UKI kept for fallback
RemoveTemporary=yes
```

(`@v` = version, `@l`/`@d` = tries left/done — sysupdate manages the counter suffix that
systemd-boot's Automatic Boot Assessment consumes; see 01 for the rollback flow.)
`${UPDATE_URL}` and `${DISTRO_ID}` are rendered into these files at build time (stage 40).

## Update server = static files

Any HTTPS host (nginx autoindex off is fine — sysupdate reads the checksum manifest, not
directory listings):

```
/immos/stable/
├── SHA256SUMS            # the version manifest: one line per artifact
├── SHA256SUMS.gpg        # detached signature, release key
├── immos_0.1.0.root.erofs.zst
├── immos_0.1.0.efi
├── immos_0.2.0.root.erofs.zst
├── immos_0.2.0.efi
└── img/immos-0.2.0.img.zst        # full disk image for new installs (not used by updater)
```

Stage 80 emits exactly this layout into `out/release/stable/`; publishing is
`rsync out/release/ host:/srv/updates/immos/` — no server-side logic. `UPDATE_CHANNEL`
(`stable` default) is a path segment, giving free channels (`testing`) later by building with
a different channel value.

## Signing

- One offline **release GPG key**; public half baked into the image at
  `/usr/lib/systemd/import-pubring.gpg` (the keyring systemd's import/verify machinery uses).
- Stage 80 signs: `gpg --detach-sign --output SHA256SUMS.gpg SHA256SUMS` with
  `RELEASE_GPG_KEY` (key never lives in the repo; CI secret / local keyring).
- Trust chain: HTTPS for transport + GPG-signed manifest + SHA256 per artifact. Key rotation:
  ship old+new in the pubring for one release cycle (documented procedure, not automated v1).

## Client UX — `${DISTRO_ID}-update` (thin Bash wrapper)

| Command | Does |
|---|---|
| `immos-update check` | `systemd-sysupdate list` → prints current/available |
| `immos-update apply` | `systemd-sysupdate update` → downloads, verifies, writes inactive slot + UKI(+3); prints "reboot to apply" |
| `immos-update reboot` | apply + `systemctl reboot` |
| `immos-update rollback` | `bootctl set-default <previous UKI>` (manual escape hatch) |
| `immos-update status` | slot map: which partlabel/version in each slot, active one, UKI tries state (`bootctl status` + `sfdisk` parse) |
| `immos-update etc-diff` | lists files in the `/etc` overlay upper (local divergence from vendor defaults — see 01) |

Runs as root (polkit rule allows wheel to trigger via `pkexec`). **Unattended updates:**
`systemd-sysupdate.timer` shipped but **disabled by default** in v1 (preset off) — flip to
opt-out once the update path has soaked (roadmap). GNOME Software shows flatpak app updates; OS
updates are CLI-first in v1 (GNOME Software OS-update integration is roadmap).

## Update lifecycle (end to end)

```
running 0.1.0 (slot A = root_0.1.0, slot B = _empty)
  immos-update apply
    → GET SHA256SUMS(.gpg), verify sig; newest = 0.2.0 > 0.1.0
    → GET immos_0.2.0.root.erofs.zst → decompress-stream → write slot B → verify → relabel root_0.2.0
    → GET immos_0.2.0.efi → verify → ESP:/EFI/Linux/immos_0.2.0+3.efi
  reboot
    → sd-boot picks 0.2.0 (+3, highest version) → renames +3→+2-1 … boots
    → boot-complete.target reached → bless-boot renames to immos_0.2.0.efi   ✅ committed
  [failure path] 3 failed attempts → sd-boot ignores 0.2.0, boots immos_0.1.0.efi
    → slot A untouched, system healthy on 0.1.0                                ↩️ rolled back
  next update (0.3.0) overwrites the oldest slot (A) and evicts 0.1.0's UKI (InstancesMax=2)
```

Invariants: the **running** slot is never written; the label/rename steps are last-write
commits; `/var` and the `/etc` overlay are never touched by updates.

## What the updater does NOT do (v1, explicit)

- No delta updates (full image each time, ~2.5–3.5 GiB; zstd + erofs keeps it tolerable).
  Roadmap: casync/systemd-importd delta or erofs `--chunk`-based dedup.
- No verity/signature on the *partition content itself* — integrity is verified at download
  time, not continuously at read time (roadmap: dm-verity).
- No migration hooks. If a release ever needs a `/var` migration, it ships a
  `${DISTRO_ID}-migrate@.service` versioned oneshot (design reserved, not built in v1).

## Testing hooks

Stage 70 runs the full E2E against a `python -m http.server` serving `out/release/` inside
the build container, including the corrupted-slot rollback drill — see
[07-testing.md](07-testing.md).
