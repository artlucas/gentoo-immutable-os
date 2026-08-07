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
