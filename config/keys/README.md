# Release signing keys

Images with `UPDATE_VERIFY=1` (the default) require:

- `import-pubring.gpg` — **committed** here; baked into images at
  `/usr/lib/systemd/import-pubring.gpg`. systemd-sysupdate verifies
  `SHA256SUMS.gpg` against it before applying any update.
- The **private** release key — NEVER in this repo. Stage 80 signs with
  `RELEASE_GPG_KEY=<key-id>` from the environment (local keyring or CI secret).

Generate once (offline machine recommended):

```sh
gpg --quick-generate-key "MyDistro Release Signing <release@example.org>" ed25519 sign never
gpg --export "MyDistro Release Signing" > import-pubring.gpg   # commit this file
```

Key rotation: export old+new into one pubring for a full release cycle, then drop
the old key (plan/05).

Dev builds without signing: set `UPDATE_VERIFY=0` in `config/build.conf`
(or pass `--no-verify` to build.sh) — images then accept unsigned updates. Never
ship such an image.

## Managed-mode bundle signing (plan/19)

- `managed-pubring.asc` — **not committed** (this directory is `.gitignore`d, and deliberately:
  a repository is not where keys live). Put your service key's public half here, ASCII-armoured,
  and point `MANAGED_PUBRING` in `config/build.conf` at it. Stage 40 dearmors it into
  `/usr/lib/<id>/managed-pubring.gpg`, and `<id>-managed` verifies every policy bundle's detached
  signature against it with `gpgv`, over the exact bytes it was handed, before parsing them.
- The **private** service key — for a real deployment, never in this repo.
- Until you do that, `MANAGED_PUBRING` defaults to `tests/managed-api/keys/pubring.asc`, a
  throwaway whose private half is committed beside it. See the warning below.

**Armoured here, binary in the image**, on purpose. `gpgv` wants a binary keyring; a repository
wants a file that diffs, that survives a checkout on Windows, and that the test suite's CRLF check
can read a byte at a time. `gpg --dearmor` in stage 40 costs one line and removes the conflict.

**A separate key from the release key above**, also on purpose: they have different lifetimes and
very different exposure. The release key signs a handful of artifacts from an offline machine; the
service key signs every bundle for every organisation, continuously, on a host that is on the
internet. Rotation follows plan/05's — ship old+new in one armour block for a release cycle, then
drop the old.

> **The default `MANAGED_PUBRING` is a TEST key**, at `tests/managed-api/keys/pubring.asc`, with
> its private half committed beside it at `signing-key.asc`. That pair exists so the stage-70
> fixture can sign bundles a built image actually accepts, and so a fresh clone builds without
> anyone having to generate a key first. **An image built against it will take policy from anyone
> who has read this repository.** Stage 40 warns, loudly, whenever it sees `TEST KEY` in the uid.
> Replace it before shipping anything.

```sh
gpg --quick-generate-key "MyDistro Managed Mode <managed@example.org>" ed25519 sign never
gpg --armor --export "MyDistro Managed Mode" > config/keys/managed-pubring.asc   # commit this
```

There is deliberately **no** `MANAGED_VERIFY=0` escape hatch to match `UPDATE_VERIFY`. plan/19
§5.8 rule 1 is "never send unsigned policy", with no trusted-transport exception — a switch that
turned bundle verification off would turn the whole security model off, and it would eventually
ship enabled.
