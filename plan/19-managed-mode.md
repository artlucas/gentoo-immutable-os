# 19 — Managed mode

There are two ways this image can know who you are today. A **local-only** machine keeps its
accounts in `/etc/passwd` and nothing outside it has an opinion (plan/01, plan/16 §5.4). An
**AD-joined** machine asks a Windows domain controller (plan/18). Neither fits the household with
four people and three computers, or the shop with six seats and no server room: the first means
creating the same four accounts by hand on every machine and keeping four passwords in sync
forever, and the second means running Active Directory at home.

**Managed mode** is the third: a hosted control plane, operated by whoever ships this distro, that
owns users, groups, device assignments and policy for one household or one small business. Devices
**enrol** once with a code; from then on they pull a signed bundle and apply it locally. Everything
that matters is enforced on the device, from cached data, so a laptop at a friend's house
authenticates, obeys its policy and keeps its books exactly as it does at home. Screen time and
parental controls (§10) are a later milestone that rides on the same bundle and the same queue.

Three properties shape every decision below. The first two are plan/18's, restated because they
have not stopped being true:

1. **`/etc` is an overlay with no 3-way merge** (plan/01). A vendor file the machine edits stops
   receiving vendor updates forever. So the image ships inert mechanism, and enrolment writes
   **data in files that did not exist before**.
2. **A failed unit is a failed boot.** `systemd-boot-check-no-failures.service` gates
   `boot-complete.target`; three failed boots roll the machine back to the previous image. A sync
   client that exits non-zero because the café wifi has a captive portal is not a warning, it is a
   rollback. §8.1.
3. **The network is not available at the moment that matters.** Login happens at the lock screen
   of a closed laptop on a train. Every authentication, authorisation and restriction decision in
   this design is therefore made from local state, and the network only ever *refreshes* that
   state.

## 1. The decision

**Managed users are systemd JSON user records, dropped into `/etc/userdb/`, resolved by
`nss-systemd`, authenticated by `pam_unix` through the shadow NSS interface.** The sync client is
a `<id>-managed` CLI plus a timer; the control plane is an HTTPS API (§5) whose bundles are
OpenPGP-signed with a key baked into the image.

**It costs zero new packages.** Everything above is already in the shipped 0.3.0 desktop image —
measured, not assumed (§2, §9).

| Candidate | Verdict |
|---|---|
| **systemd userdb drop-ins + `pam_unix`** | **Chosen.** No new atoms, no daemon on the login path, offline by construction (the record *is* the cache), and users **enumerate**, so the family appears on the login screen. `nsswitch.conf` already names `systemd` on `passwd`, `group` **and `shadow`** — the last one shipped for `DynamicUser=` and turns out to be exactly what makes this work |
| sssd with `id_provider = ldap` against a hosted directory | Reuses plan/18's client, but needs the control plane to expose LDAP+Kerberos to the internet for a household, and sssd deliberately does **not** enumerate (plan/18 §4.2) — no user list on the greeter, every child types their username. Offline logins work only *after* a first online login, which is the wrong first-boot story for a machine handed to a ten-year-old |
| Materialise `/etc/passwd`/`shadow` lines | Works everywhere, and is what a shell script would do. It edits three vendor files on every sync, permanently freezing them in the overlay against every future release (rule 1), and it puts managed accounts in the same namespace as the local administrator, where a name collision is a silent takeover rather than an error |
| `systemd-homed` records | The closest thing to a designed answer, and unavailable: `sys-apps/systemd` is built `USE=-homed` here, so `systemd-homed.service` is not in the image. Enabling it pulls `cryptsetup` and moves home directories into LUKS images, which changes the `/var` story (plan/01) for a benefit — roaming home directories — nobody asked for |
| kanidm / lldap / FreeIPA | **None are in the pinned tree** (checked 2026-09-08: no `kanidm`, no `lldap`, no `freeipa`). There is no Portage on the target, so "not in the tree" means "cannot ship" |

The local administrator account **stays**, for plan/18 §7.2's reason word for word: it owns
`wheel`, sudo and polkit, it holds the subuid range rootless podman needs (plan/13), and on a root
filesystem with no rescue shell and no package manager it is the only way back in when the control
plane is unreachable, unpaid for, or gone. Managed mode is **additive**, never a replacement.

## 2. The identity mechanism, measured

### 2.1 What a managed user is, on disk

```
/etc/userdb/alice.user                 0644 root:root   the public record
/etc/userdb/alice.user-privileged      0600 root:root   the password hash — mode is load-bearing, §2.3
/etc/userdb/5001.user -> alice.user                     the UID lookup path, §2.3
/etc/userdb/alice.group                0644 root:root
/etc/userdb/5001.group -> alice.group
/etc/userdb/alice:immos-admins.membership   (empty)     group membership, §2.3
```

```json
{
  "userName": "alice",
  "uid": 5001,
  "gid": 5001,
  "realName": "Alice Example",
  "homeDirectory": "/home/alice",
  "shell": "/bin/bash",
  "disposition": "regular"
}
```

…and beside it, readable only by root:

```json
{ "userName": "alice", "privileged": { "hashedPassword": ["$6$…"] } }
```

`/etc/userdb` does not exist in the image; the sync client creates it. Every path above is new, so
rule 1 is satisfied without argument — no vendor file is touched to make a managed user exist.

### 2.2 It works on the image we already build

Verified **2026-09-08** against the built 0.3.0 `desktop` target (the `immos-work` volume's
`target/`), through an overlay + `chroot`, running the target's own glibc, `getent`, `unix_chkpwd`
and `userdbctl`, with **no systemd and therefore no `systemd-userdbd` running at all** — which
exercises the daemonless drop-in fallback, the worst case:

| Probe | Result |
|---|---|
| `getent passwd alice` | `alice:x:5001:5001:Alice Example:/home/alice:/bin/bash` |
| `getent shadow alice` (root) | returns the `$6$` hash — so `pam_unix` has something to check |
| `unix_chkpwd alice nullok`, correct password | **rc=0** |
| `unix_chkpwd alice nullok`, wrong password | rc=7 |
| `getent passwd` enumeration | `alice` and `bobby` both listed |
| `getent group alice` | `alice:x:5001:` |
| `id alice` with a `.membership` file | `uid=5001(alice) gid=5001(alice) groups=5001(alice),10(wheel)` |

`libnss_systemd.so.2` in that image exports `_nss_systemd_getspnam_r`, `_nss_systemd_getspent_r`
and the rest of the shadow interface, and carries `userdb-dropin.c`, `/etc/userdb`, `/run/userdb`
and `io.systemd.DropIn` in its strings. systemd is **260.1**; `systemd-userdbd.socket` is enabled
by the vendor preset (`90-systemd.preset:38`) and nothing in `50-<id>.preset` disables it, so the
daemon path is available on a booted machine and the fallback above is the floor, not the plan.

**The `unix_chkpwd` line is the whole authentication story.** PAM's authenticating processes here
— `login`, `plasmalogin`, `sudo`, the polkit agent — run as root, so `pam_unix` reads the shadow
entry directly; the helper is the unprivileged path and it agrees. No new PAM module, no new NSS
module, no daemon between the user and their password.

### 2.3 Four things a designer would get wrong, and did

Each of these was found by probing rather than by reading, and each is a silent failure:

- **UID → name needs a symlink.** With only `alice.user` present, `getent passwd 5001` returns
  **not found**, while `getent passwd alice` works. Every `ls -l` in the user's own home would
  print a bare number. The fix is a `5001.user -> alice.user` symlink in the same directory (and
  `5001.group -> alice.group`); with it, `getent passwd 5001` resolves. The client writes both
  names for every record, and the offline suite asserts it.
- **`memberOf` in the user record does nothing through NSS.** A record carrying
  `"memberOf": ["wheel"]` produced `id alice → groups=5001(alice)` — no `wheel`. The empty file
  `alice:wheel.membership` produced `groups=5001(alice),10(wheel)` and a matching
  `getent initgroups`. Membership is a *file name*, not a field. (Both together behave like the
  file alone.) This is the mechanism the admin group in §6.2 rests on.
- **The mode of `.user-privileged` is the security boundary, not the daemon.** At `0644`, a
  process running as uid 1000 read the full `$6$` hash back out of `getent shadow alice`. At
  `0600` the same call returned nothing. In the daemonless path nss-systemd reads the file as the
  *calling* process, so file permissions are the only gate; with `userdbd` running the daemon also
  checks the peer's uid. Both paths must be right, so the client writes `0600 root:root` and
  stage 40 and the offline suite both assert it. §8.3 is what this implies for whose hashes may
  land on which device.
- **`getent group wheel` returns duplicated members** — `wheel:x:10:live,live,alice` — because
  `nsswitch.conf`'s `[SUCCESS=merge]` concatenates sources without de-duplicating. Cosmetic:
  authorisation is by membership, not by list position, and `id` is unaffected. Recorded because
  it looks like a bug in the records and is not, and because the daemon path may or may not
  behave the same way — T-MAN-1 checks it on a booted guest.

### 2.4 The UID range is decided by a file we must not edit

`/etc/login.defs` in the image says `UID_MIN 1000`, `UID_MAX 60000`. Plasma Login Manager's user
list is bounded by exactly those two numbers — `getUids()` parses them out of `login.defs`, not
out of `plasmalogin.conf` (plan/18 §4.2, which also records that narrowing that window means
editing a `sys-apps/shadow` vendor file and freezing it forever). So:

- **Managed UIDs must land in `[1000, 60000]`** or the accounts exist, log in and never appear on
  the greeter. The control plane allocates from **3000–59999**, leaving 1000–2999 for
  installer-created local accounts and keeping clear of `nobody` at 65534.
- The UID is allocated **per organisation, once**, and is the same on every device in it. That is
  the property that makes a USB stick or a NAS share carry sensible ownership between the
  family's machines, and it is not something a per-machine `useradd` can give.
- The greeter shows a user *list* only while `UserModel.rowCount() <= 7` (a hardcoded 7, plan/18
  §4.2); beyond that it shows the "Other…" username prompt. A household is under seven and gets
  faces; a fifteen-seat business is over it and types names. Both work; neither is configurable.

### 2.5 What this mechanism does not give

| | |
|---|---|
| Local password change | `passwd` cannot write a userdb record. `<id>-managed passwd` changes it through the API (online only); offline, the answer is "you cannot", and §5.4's `hashedPassword` is refreshed at the next sync. Say so in the UI rather than letting `passwd` fail with something cryptic |
| Password ageing, lockout counters | `shadow`'s aging fields are not in the record. Lockout is `pam_faillock` (shipped) if wanted later, per device |
| Kerberos tickets, single sign-on to shares | Not this mode. That is what plan/18 is for |
| `subuid`/`subgid` for rootless podman | **Not automatic.** Those are files, not NSS, so the client appends a range per managed user, the way `imageidentity` already does for the installed local user. §8.2 |
| A home directory | Created on first login by the `pam_mkhomedir.so` line stage 40 already appends for plan/18 §2.2. One line, both features |

## 3. What the image ships, and what enrolment writes

**The image ships inert mechanism; enrolment ships data.** Nothing below runs, or has any effect,
on a machine that has never enrolled — which is the property T-MAN-5 asserts, and the direct
descendant of plan/18's T-DOM-4.

| Shipped (read-only, every profile) | Why it cannot be written later |
|---|---|
| `/usr/bin/<id>-managed` | The implementation. There is no Portage on the target |
| `/usr/lib/systemd/system/<id>-managed-sync.{service,timer}` | Units cannot be created by a machine that must not edit `/usr` |
| `/usr/lib/systemd/system/<id>-managed-sync.service.d/10-conditional.conf` — `ConditionPathExists=/var/lib/<id>/managed/enrollment.json` | §8.1 |
| `/usr/lib/<id>/managed-pubring.gpg` | The trust anchor. A key fetched at enrolment time is not a trust anchor |
| `/usr/lib/NetworkManager/dispatcher.d/50-<id>-managed` | Sync-on-connect, so a machine that comes home picks up the day's changes without waiting for the timer |
| `/usr/share/<id>/managed-ui/` (QML) + `/usr/bin/<id>-managed-ui` | The enrolment surface, §7.2 |
| `/usr/share/polkit-1/actions/org.<id>.managed.policy` | So the QML front end can ask for the admin's password properly instead of being setuid or being run with `sudo` |
| the `pam_mkhomedir.so` line (already there, plan/18 §2.2) | Shared with AD |

| Enrolment writes | |
|---|---|
| `/var/lib/<id>/managed/enrollment.json` | `0600` — device id, org id, API base, device secret |
| `/var/lib/<id>/managed/bundle.json` + `bundle.sig` | The last bundle, verbatim as received, and its detached signature |
| `/var/lib/<id>/managed/serial` | Anti-rollback high-water mark, §8.5 |
| `/var/lib/<id>/managed/queue/*.jsonl` | Audit events awaiting upload, §5.5 |
| `/etc/userdb/*` | §2.1 |
| `/etc/sudoers.d/30-managed-admins`, `/etc/polkit-1/rules.d/51-managed-admins.rules` | New files, only when the bundle names an admin group |
| `/etc/subuid`, `/etc/subgid` | **Appends**, and the one exception to "new files only" — §8.2 |
| `/etc/systemd/system/multi-user.target.wants/<id>-managed-sync.timer` | The one enablement symlink |

`<id>-managed leave` removes exactly that list, in reverse, except the home directories and except
`/etc/subuid`'s lines, which are removed only with `--purge` (§8.9).

## 4. `<id>-managed`

Shipped as `config/rootfs/usr/bin/distro-managed.in` and rendered by the same
`render_dest_name()` rebranding that produces `<id>-update` and `<id>-domain`. Written in
**Python 3**, unlike its bash siblings, and that is a decision with a cost: see §9.

```
<id>-managed enroll --code CODE [--name NAME] [--api URL] [--root PATH]
<id>-managed sync [--now] [--quiet]
<id>-managed status [--json]
<id>-managed passwd [USER]
<id>-managed policy [--json]
<id>-managed leave [--purge] [--force]
<id>-managed verify
<id>-managed --print-config          # render records from a bundle, write nothing
```

**`enroll`**, idempotent, everything relative to `--root` (so the installer path in §7.3 is the
same code):

1. **Preflight.** Root. Not AD-joined (§8.7). Clock sane enough for TLS. `machine-id` exists.
   Network reachable — and if it is not, stop here having written nothing.
2. `POST /v1/enroll` with the code and the device facts (§5.3).
3. Write `enrollment.json` `0600`, then immediately run the first `sync`.
4. Enable and start the timer. On failure to fetch a first bundle: keep the enrolment, report it,
   exit 0 — the device is enrolled and stale, which is a state the design has to survive anyway.

**`sync`**, the only thing the timer runs:

1. `GET /v1/devices/{id}/bundle` with `If-None-Match`. 304 → nothing to do; drain the queue; done.
2. **Verify the signature over the bytes received, before parsing them.** The client never
   re-serialises a bundle before checking it (§5.7).
3. Reject a `serial` lower than the stored high-water mark (§8.5). Reject `min_client_version`
   above our own — and *keep running the old bundle* rather than doing nothing.
4. Render records into `/etc/userdb/` **atomically**: write `.tmp-*`, `fsync`, `rename`. Remove
   records for users the bundle no longer grants this device, and only those — a file the client
   did not write is never deleted.
5. Apply the admin group, sudoers/polkit drop-ins, subuid appends, and the policy in §6.
6. Drain `queue/` to `POST /v1/devices/{id}/events`, oldest first, at-least-once with an
   idempotency key per event.
7. `POST /v1/devices/{id}/heartbeat`, apply any pending commands (§5.3), write the new serial.
8. **Exit 0.** Always. §8.1.

**`status`** prints, in one screen: enrolled or not, org, device name, last successful sync, bundle
serial and age, how many users are provisioned, which policy is in force, and the queue depth. It
is the first thing anyone will run when something is wrong, so it reports the *cached* state
without touching the network unless asked.

**`verify`** is the diagnostic path — DNS, TLS to the API, clock skew, keyring, signature over the
cached bundle, `getent` round-trip for one provisioned user — with exit codes as an interface, the
way plan/18 §7.4 made `<id>-domain verify`'s codes one:

| | |
|---|---|
| `0` | reachable and the cached state verifies |
| `2` | network or DNS: the API could not be reached |
| `3` | the API rejected our credentials — enrolment is dead, the device needs re-enrolling |
| `4` | clock outside tolerance for TLS |
| `5` | signature or anti-rollback failure — the cached bundle is not trustworthy |

### 4.1 The failure discipline

Every sync path ends in `exit 0` except a usage error at an interactive terminal. Not because
errors do not matter, but because the alternatives are worse: an exit code from a timer-driven
oneshot on this OS is a failed unit, a failed boot, and eventually an automatic rollback to a
previous image (§8.1) — triggered, in the field, by a hotel wifi. Errors are reported by
**`status`, the journal and the control plane's own "last seen" clock**, all three of which a
human or the web UI can see, and none of which can brick a machine. `tests/test-managed.sh`
asserts the property directly: the client, run with every failure injected in turn, never exits
non-zero.

## 5. The hosted API

The control plane is operated by whoever ships the distro. This section specifies **the wire
contract only** — the endpoints, the payloads and the rules a client depends on. How the service
is implemented, hosted or billed is out of scope here; what is in scope is that everything below
is what the client already assumes, so a server that satisfies this document works with an
unmodified image.

### 5.1 Shape

- **HTTPS only**, TLS 1.2+, HTTP/1.1 or /2, verified against the system CA bundle
  (`app-misc/ca-certificates`, in the image today). No certificate pinning in v1: pinning a CA in
  a read-only image that updates on its own cadence is a way to brick a fleet from the server side.
- **Base URL is a build knob**, never hardcoded: `MANAGED_API_BASE` in `config/build.conf`, next
  to `DISTRO_ID` and for the same reason (plan/00, "Identity & naming"). Enrolment may override it
  per device (`--api`), which is what makes a self-hosted or staging control plane possible.
- **Versioned in the path**, `/v1`. Additive changes (new fields) do not bump it; a client ignores
  fields it does not know, and the bundle carries `min_client_version` for the other direction.
- **JSON only**, UTF-8, `application/json`. All timestamps RFC 3339 UTC. All durations integer
  seconds.
- **Idempotency**: every POST accepts `Idempotency-Key`; the server must return the original
  response for a repeated key within 24 h. The client retries after a timeout, and must not create
  two devices or double-count an event by doing so.

### 5.2 Device credentials

| | |
|---|---|
| **Enrolment code** | 8 characters, single use, TTL 15 minutes, issued by the web UI and typed by a human. It authorises *creating* one device in one org and nothing else |
| **Device secret** | Opaque, ≥256 bits, returned once at enrolment, stored `0600 root:root` in `enrollment.json`. Sent as `Authorization: Bearer`. Rotated by the server via `next_secret` on any response; the client writes the new one atomically and uses it from the next request |
| **Device id** | Server-assigned, opaque, in every path. Not derived from `machine-id`, which the client sends only as a salted hash (`hw_fingerprint`) so a re-enrolled machine can be *recognised* without the control plane holding a stable hardware identifier |

v1 is bearer-token, which means **a stolen `/var` is a stolen device identity** until it is revoked
(§8.4). Rotation limits the window, the server can revoke instantly, and a `hw_fingerprint` that
changes on a token that did not is exactly the anomaly a control plane should act on. Binding the
credential to a TPM is the real answer and it waits on plan/08's Secure Boot and measured-boot
work — the schema reserves `attestation` for it now so that adding it later is not a version bump.

### 5.3 Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/enroll` | Redeem a code, create a device, receive credentials |
| `GET` | `/v1/devices/{id}/bundle` | The signed policy + identity bundle. `If-None-Match` / `ETag` |
| `POST` | `/v1/devices/{id}/heartbeat` | Liveness + inventory; returns pending commands |
| `POST` | `/v1/devices/{id}/events` | Batched audit/usage events |
| `POST` | `/v1/devices/{id}/commands/{cmd_id}/ack` | Command completion |
| `POST` | `/v1/devices/{id}/password` | A managed user changes their own password |
| `POST` | `/v1/devices/{id}/unenroll` | Voluntary departure, from the device |
| `GET` | `/v1/keys` | Current bundle-signing key set, signed by a currently trusted key |

**`POST /v1/enroll`**

```json
{ "code": "K7QF-9M2B",
  "device": { "name": "kitchen-pc", "hostname": "immos-5dbe4",
              "hw_fingerprint": "sha256:9f2c…", "image_id": "immos",
              "image_version": "0.3.0", "arch": "x86_64",
              "product": "Dell OptiPlex 7090", "client_version": "1" } }
```

```json
{ "device_id": "dev_01J9…", "device_secret": "…", "org": { "id": "org_01J8…", "name": "The Smiths" },
  "api_base": "https://api.example.org", "poll_interval": 3600, "bundle_etag": null }
```

`409` if the code is spent, `410` if it expired, `429` with `Retry-After` under brute force. The
code is short because a human types it, so the server — not the client — is responsible for rate
limiting it into uselessness as a guessing target.

**`GET /v1/devices/{id}/bundle`** returns §5.4, or `304`, or `410 Gone` when the device has been
revoked — which the client treats as an instruction to unenrol itself (§8.9), not as an error.

**`POST /v1/devices/{id}/heartbeat`**

```json
{ "at": "2026-09-08T09:14:02Z", "uptime_s": 84213, "boot_slot": "a",
  "image_version": "0.3.0", "bundle_serial": 412, "queue_depth": 3,
  "users_provisioned": 4, "last_sync_ok": true, "sessions_active": 1 }
```

```json
{ "poll_interval": 3600,
  "commands": [ { "id": "cmd_01J9…", "type": "sync_now" } ] }
```

Command types in v1 are deliberately few and all reversible: `sync_now`, `lock_sessions`,
`unenroll`. **There is no remote wipe**, and there should not be one until there is a threat model
that survives §8.4 — a command that destroys data, authorised by a bearer token in a file on the
device it destroys, is a footgun pointed at a family's photos.

**`POST /v1/devices/{id}/events`** takes `{"events": [...]}`, at most 1000 or 1 MiB per request,
each event carrying its own `id` (client-generated UUID) for idempotency. `202` on acceptance;
the client deletes the queued lines only on `202`.

**`POST /v1/devices/{id}/password`** takes `{"user":"alice","old":"…","new":"…"}` over TLS, and
the server applies its own password policy. The device never hashes a password for the control
plane — the hash format the record carries is the server's choice, and letting a device propose
one is how a weak hash gets in.

### 5.4 The bundle

One document, signed, cacheable, and the **only** thing that changes a managed machine's identity
or policy. Everything the client needs is in it, because the client may not see the network again
for a month.

```json
{
  "schema": 1,
  "serial": 412,
  "issued_at": "2026-09-08T09:00:00Z",
  "expires_at": "2026-10-08T09:00:00Z",
  "min_client_version": 1,
  "org":    { "id": "org_01J8…", "name": "The Smiths" },
  "device": { "id": "dev_01J9…", "name": "kitchen-pc", "state": "active" },

  "users": [
    { "name": "alice", "uid": 5001, "gid": 5001, "real_name": "Alice Smith",
      "shell": "/bin/bash", "home": "/home/alice", "state": "active",
      "roles": ["admin"],
      "groups": ["immos-admins", "wheel"],
      "hashed_password": ["$6$…"],
      "ssh_authorized_keys": [],
      "subid": { "start": 200000, "count": 65536 } },

    { "name": "bobby", "uid": 5002, "gid": 5002, "real_name": "Bobby Smith",
      "shell": "/bin/bash", "home": "/home/bobby", "state": "active",
      "roles": ["standard"], "groups": [], "hashed_password": ["$6$…"] }
  ],

  "groups": [ { "name": "immos-admins", "gid": 4000 } ],

  "access": { "mode": "listed", "logins_allowed": ["alice", "bobby"] },

  "admin": { "group": "immos-admins", "sudo": true, "polkit": true },

  "policy": {
    "flatpak": { "install_requires_admin": true,
                 "allow": ["*"], "deny": [] },
    "updates": { "auto": true, "window": { "start": "02:00", "end": "05:00" } },
    "session": { "idle_lock_s": 600 }
  },

  "parental": { "schema": 0, "subjects": [] },

  "revoked_users": ["carol"]
}
```

Field by field, where the choice is not obvious:

- **`serial`** is a per-org monotonic counter, not a timestamp. It is what §8.5's anti-rollback
  compares, and a timestamp would make clock manipulation into a downgrade primitive.
- **`expires_at`** is **advisory for identity and binding for nothing**. A device past it keeps
  authenticating its users and keeps enforcing its policy, marks itself stale in `status`, and
  says so at the next heartbeat. A control plane that can lock a family out of their own computers
  by going down for a week is not a feature, it is an outage amplifier (§8.6).
- **`users[].hashed_password`** is an array because the record format takes one, and because a
  password change should be able to overlap. It is present **only for users this device may log
  in** (§8.3) — the same bundle for a different device carries different users entirely. Format is
  crypt(3); `$6$` today, `$y$` (yescrypt) the moment the image's libcrypt is confirmed to take it.
- **`groups`** on a user names *supplementary* groups; the client turns each into a
  `<user>:<group>.membership` file (§2.3). A name that exists locally (`wheel`) merges; a name
  that does not must also appear in the bundle's `groups` array or the client refuses the record
  rather than creating a dangling membership.
- **`access.mode`** is `listed` or `all`. `listed` is the household default and the mechanism
  behind §6.1 — a user not listed does not merely fail to log in, they **do not exist on that
  device**, and their password hash was never sent to it.
- **`revoked_users`** is explicit rather than inferred from absence, so that a truncated or
  filtered bundle can never silently delete accounts. Absence removes a record too, but only after
  the client has verified the bundle covers the whole org (`users` plus `revoked_users` plus
  `access`).
- **`parental`** is reserved at `schema: 0` — nothing reads it in v1 — so §10 does not need a
  bundle version bump on the day it lands.

### 5.5 Events

One JSON object per line in `queue/*.jsonl`, uploaded oldest-first, deleted only on `202`.

```json
{ "id": "9d1f…", "at": "2026-09-08T18:04:11Z", "type": "session.start",
  "user": "bobby", "session": "c7", "seat": "seat0" }
{ "id": "a02c…", "at": "2026-09-08T21:30:02Z", "type": "session.end",
  "user": "bobby", "session": "c7", "active_s": 8400, "idle_s": 3000 }
{ "id": "b71e…", "at": "2026-09-08T21:30:03Z", "type": "policy.enforced",
  "user": "bobby", "rule": "daily_limit", "action": "session_locked" }
{ "id": "c33a…", "at": "2026-09-09T07:02:44Z", "type": "device.state",
  "bundle_serial": 412, "stale": false, "clock_stepped_s": -3600 }
```

Event types in v1: `session.start`, `session.end`, `policy.enforced`, `device.state`,
`enrollment.completed`, `sync.failed`. §10 adds the usage types. The queue is capped (10 MiB,
oldest dropped, and the drop itself is an event), because a device that never reconnects must not
fill `/var` — which on this image is the same partition as every home directory.

### 5.6 Errors, retries, and time

- Errors are `application/problem+json` (RFC 9457) with a stable `type` URI. The client branches on
  the HTTP status and logs the rest.
- `401`/`403` → credentials are dead; stop retrying, report through `status`, keep enforcing the
  cached bundle. `410` → self-unenrol (§8.9). `429`/`5xx` → exponential backoff with full jitter,
  base 60 s, cap 6 h, honouring `Retry-After`.
- **The client never trusts the server's clock for enforcement**, and never sets it. Time comes
  from `systemd-timesyncd` (already enabled). A device whose clock is implausible reports
  `clock_stepped_s` and keeps going; §10 is where that becomes interesting, because the obvious way
  to defeat a screen-time limit is to move the clock.
- `poll_interval` is server-controlled with a client floor of 15 minutes and a ceiling of 24 h,
  plus `RandomizedDelaySec` on the timer so that ten devices in one house do not arrive together.

### 5.7 Signing and key rotation

The bundle is delivered as:

```json
{ "bundle": "<the exact JSON text of §5.4>",
  "signature": "-----BEGIN PGP SIGNATURE-----\n…" }
```

The client writes `bundle` to disk **verbatim, as bytes**, and verifies the detached signature over
those bytes with `gpg` against `/usr/lib/<id>/managed-pubring.gpg`. It parses only after the
signature verifies. Handing the client a string rather than a nested object is deliberate: it
removes JSON canonicalisation from the trust path entirely, which is where this class of design
usually breaks.

This reuses plan/05's idiom exactly — OpenPGP ed25519, detached signature, public half committed
in `config/keys/` and baked into the image — with a **separate key** from the release key. They
have different lifetimes and different exposure: the release key signs a handful of artefacts from
an offline machine, the service key signs every bundle for every org, continuously, on a host that
is on the internet. Rotation follows plan/05's: ship old+new in one keyring for a release cycle,
then drop the old. `GET /v1/keys` allows an in-band rotation, but only to a key signed by one
already in the baked keyring — the anchor is always the image.

### 5.8 What the server must never do

Constraints that exist to keep the client honest, and that a server implementation has to respect
for any of §8 to hold:

1. **Never send unsigned policy.** There is no "trusted transport" exception; TLS authenticates
   the host, not the payload's author.
2. **Never require an online check to log in.** No endpoint is on the authentication path, and
   none may become one.
3. **Never expire identity.** §5.4's `expires_at`, §8.6.
4. **Never ship a user's hash to a device that user may not use.** §8.3.
5. **Never hand out a command that destroys local data.** §5.3.

## 6. Policy in v1

### 6.1 Per-device access control

The device's bundle contains exactly the users it may log in, so enforcement is *by absence*: no
record, no NSS entry, no password hash on that disk, nothing to attack. A shared family PC lists
everyone; a parent's laptop lists one; the shop's till lists the till accounts and not the owner's.
Belt and braces for the shared-device case, where the same bundle covers users with different
rights, is `pam_access` (shipped) driven by a generated `/etc/security/access.d/` drop-in — but
that is a *second* mechanism, and v1 does not enable it, because two overlapping access rules is
how you get a machine that nobody can log into for a reason nobody can find.

### 6.2 Administrators

`admin.group` names a group the bundle also defines (default `<id>-admins`, gid from the org's
range). Membership arrives as `.membership` files (§2.3). The client then writes, only if
`admin.sudo` / `admin.polkit` are set:

```
/etc/sudoers.d/30-managed-admins      %<id>-admins ALL=(ALL:ALL) ALL
/etc/polkit-1/rules.d/51-managed-admins.rules
```

both new files, mirroring what `<id>-domain --admin-group` already writes for AD (plan/18 §3) and
deliberately **not** by adding managed users to `wheel`. `wheel` is the local administrator's
group and the local administrator is the way back in; keeping the two sets separate means a
control-plane mistake cannot remove the account that would fix it.

### 6.3 Applications

The image is Flatpak-first (plan/03), so app policy is Flatpak policy. In v1 the client enforces
one thing, because it is the one thing that is enforceable cleanly: **`install_requires_admin`**,
written as a polkit rule over `org.freedesktop.Flatpak.app-install` /
`runtime-install` / `app-uninstall`, so a standard user gets an authentication prompt they cannot
answer and an administrator gets one they can.

`allow`/`deny` lists are carried in the bundle and **not enforced yet**, deliberately. Blocking
*launch* rather than *install* needs a session-side agent that can see what is starting, and that
agent is §10's, arriving with the milestone that actually needs it. Carrying the fields now means
the web UI and the schema do not change when it does. (`malcontent`, the GNOME parental-controls
framework that would otherwise be the obvious dependency, is **not in the pinned tree** — checked
2026-09-08 — and neither is any KDE equivalent. Everything in §10 is ours to build.)

### 6.4 The rest

`policy.updates` and `policy.session` are read and applied where the mechanism already exists
(the sysupdate timer, which is disabled by preset today; the Plasma idle-lock default). Anything
requiring a new enforcement point is out of v1 by the same rule as §6.3: **the bundle may carry a
field before the client enforces it, but the client may not enforce a field the bundle does not
carry.**

## 7. The surfaces

### 7.1 The web UI owns everything except enrolment

Creating users, resetting passwords, assigning devices, editing policy, and — when §10 lands —
setting schedules and reading screen-time reports all happen in the control plane's web UI, on a
phone or a laptop, by a parent or an owner who may never open a terminal. That is the right home
for it: it is the only surface that can show the *whole* household at once, it needs no code in a
read-only image, and it does not need the device it is describing to be switched on.

The device therefore needs exactly three things locally: **enrol**, **show me what is in force**,
and **unenrol**. That is a much smaller UI than it first appears, and the smallness is what makes
§7.2 affordable.

### 7.2 On the device: QML now, a KCM after

**A Plasma KCM is a compiled C++ plugin, and plan/18 §7.2's argument against compiling one applies
here verbatim**: it would have to be built against the target's Qt6/KF6, and the builder's Qt6
comes from the binhost and need not ABI-match. That argument is why the AD feature has no custom
Calamares page, and it does not get weaker for being inconvenient.

What is different here is that we do not need a plugin to get a UI. Measured on the built target:
**`/usr/bin/qml6` ships**, and so do `org.kde.kirigami` and `kirigami-addons` as QML modules. A
pure-QML Kirigami application therefore runs on the image today, with **no compilation, no ABI
coupling and no new packages** — `<id>-managed-ui` is a three-line wrapper around
`qml6 /usr/share/<id>/managed-ui/main.qml`, talking to `<id>-managed` through polkit
(`org.<id>.managed.policy`, `pkexec`, both shipped). It gets a `.desktop` entry, and System
Settings does not list it.

That last clause is the whole gap, and it is worth being plain about: **a QML app in the launcher
is not the System Settings module that was asked for.** Getting into System Settings means a real
KCM, and the honest way to build one on this pipeline is not to hand-compile it in stage 40 but to
**let Portage build it** — a small in-repo overlay (`config/portage/overlay/`) carrying an ebuild
for `<id>-kcm-managed`, emerged into the target root like every other KDE package, ABI-correct by
construction, landing in the lock file and the audit list where the existing assertions can see it.
That is new machinery for this repo (an overlay, a `relock.sh` that understands a non-`::gentoo`
repo, an ebuild to maintain across KF6 bumps), which is why it is Phase D and not Phase A — but it
is the mechanism, and once it exists the Calamares module in §7.3 is the same mechanism a second
time.

### 7.3 The installer page

Calamares accepts **only C++ `QtPlugin` view modules** — `ModuleFactory.cpp:53`, quoted in plan/18
§7.2, and confirmed against the installed medium on 2026-09-08: every `*q` module (`usersq`,
`welcomeq`, `packagechooserq`) is a compiled plugin that renders QML from
`/usr/share/calamares/qml/`, and the three modules this repo ships are all `interface: python`
**jobs**, which cannot draw a page. There is no QML or Python view interface to sneak through.

Three ways to have enrolment at install time, and the plan takes all three in order:

1. **First boot, not install time (Phase A).** The QML app from §7.2 runs on the freshly installed
   desktop, where the network is up and the person holding the enrolment code is sitting in front
   of it. Unlike an AD join — which *cannot* be deferred, because only the DC can issue the keytab
   and only the operator has domain credentials (plan/18 §7.4) — a managed enrolment needs nothing
   that expires. Deferring costs one screen, and it is the only option that costs nothing.
2. **Zero-touch, for the shop with six identical machines (Phase C).** The enrolment code is
   supplied to the installed system as a **systemd credential** — the mechanism this repo already
   drives through `-smbios type=11` in `run-vm.sh` (plan/18 Phase B) — or as a file on the
   install medium. A first-boot oneshot redeems it and deletes it. No page, no typing, six
   machines.
3. **A real Calamares page (Phase D),** as an ebuild in the same overlay §7.2 needs, appended
   before `CreateUserJob` the way `ActiveDirectoryJob` is — and inheriting plan/18 §7.4's lesson
   whole: **it must not fail the install.** A control plane that is unreachable while someone
   installs a machine is a Tuesday. The job verifies, records the intent in
   `/var/lib/<id>/managed/enrollment-pending.json`, exits 0, and lets `CreateUserJob`,
   `removeuser` and `imageidentity` run. An installed machine that is not yet enrolled and says so
   is recoverable in one command; the alternative is a machine with no account, still autologging
   into the live user, presented as a failed install.

Rejected: **overloading the existing Active Directory page** by teaching the `realm` shim to
recognise a managed org. It costs nothing to build and it is the wrong thing to ship — a household
would be typing their family's name into a box labelled *Active Directory*, and the two modes would
share a code path whose exclusivity (§8.7) is precisely what needs to stay obvious.

## 8. The hazards

### 8.1 The sync unit must never fail

Same rule as sssd (plan/18 §5.1), defended the same three ways, because the failure mode —
`systemd-boot-check-no-failures.service` → `boot-complete.target` → three tries → rollback — does
not care why the unit failed:

- `disable <id>-managed-sync.timer` in `50-<id>.preset.in`;
- a shipped drop-in carrying `ConditionPathExists=/var/lib/<id>/managed/enrollment.json`, so on an
  unenrolled machine the unit is **skipped**, which `boot-check-no-failures` does not count;
- and §4.1's discipline inside the client, which is the one that matters in the field, because the
  first two only protect the machine that never enrolled.

Stage 40 asserts no `<id>-managed*` enablement symlink survives into the built image. T-MAN-5
asserts `failed_units=0` on a booted, unenrolled image; **T-MAN-6 asserts the same on an enrolled
image with the control plane switched off**, which is the case that actually happens.

### 8.2 The one vendor file this feature appends to

`/etc/subuid` and `/etc/subgid` are not NSS — `newuidmap` reads the files — so rootless podman
(plan/13) for a managed user needs lines in them. They ship with `live:100000:65536`, and
`imageidentity` already appends the installed user's range, so the overlay has already copied them
up on every installed machine before this feature exists. Appending is therefore consistent with
what the system already does, and the client:

- allocates from the bundle's `subid.start`, defaulting to **200000 + n·65536**, above the
  100000–165535 the live and installed users hold, so a range is never reused (an overlap is a
  container-isolation hole, and `imageidentity`'s own comment says so);
- rewrites only lines it owns, matched by user name, and leaves every other line byte-identical;
- removes them on `leave --purge` only.

Everything else this feature writes is a new file, per rule 1.

### 8.3 Password hashes on every device

A managed device holds the crypt hash of every user it may log in. That is the price of offline
authentication and there is no version of this design without it — but it bounds neatly:

- **Scope is policy.** §6.1's `access.mode: listed` means the child's laptop never receives the
  parent's hash. That is not a side effect; it is the reason per-device access control is in v1
  scope rather than deferred.
- **Mode is the boundary**, measured in §2.3: `0600 root:root` on `.user-privileged`, asserted at
  build time on the shipped tree and at run time by the test suite. At `0644` any local user reads
  every hash on the machine through `getent shadow`.
- **A stolen disk yields the hashes**, exactly as `/etc/shadow` does on any Linux laptop today,
  because `/var` is not encrypted (plan/01; encryption is plan/08 roadmap). This is not a
  regression introduced here — it is the same exposure the local admin account already has — but a
  household putting *four* people's passwords on a laptop that goes to school has multiplied it,
  and that is worth saying out loud in the web UI when someone assigns a user to a portable device.

### 8.4 The threat model, stated honestly

**Managed mode restrains a user of the machine. It does not restrain an attacker with physical
access, and §10's parental controls are the case where those two are the same person.**

What holds: a standard managed user cannot edit `/etc/userdb`, the policy bundle, the queue or the
enforcement units — all root-owned, on a root filesystem that is read-only for everything but
`/var`. What does not hold: anyone who can boot other media, attach the disk to another machine, or
obtain root can remove `/var/lib/<id>/managed/` and turn the device back into an unmanaged one.
Secure Boot is disabled by design in v1 (plan/00), there is no dm-verity and no disk encryption
(plan/08), so there is nothing to stop that and this document will not pretend otherwise.

What is affordable now, and is in scope:

- **Tamper is visible**, not prevented. A device that stops heartbeating, or comes back with a
  bundle serial below the one the server issued, or reports `clock_stepped_s`, is *reported* — and
  in a household, a parent knowing is most of the mechanism.
- Managed users are not administrators unless the bundle says so (§6.2), and a child account that
  is not in `wheel` and not in `<id>-admins` cannot `sudo` its way out.

What would actually raise the bar is the plan/08 roadmap — Secure Boot, dm-verity, LUKS with a
TPM-sealed key — and when it lands, §5.2's reserved `attestation` field is where a device
credential stops being a file anyone can copy.

### 8.5 Bundle rollback and clock manipulation

An old, correctly signed bundle is a valid bundle. Replaying yesterday's — before a user was
revoked, before a limit was tightened — is the cheapest attack on any offline policy system. So the
client stores the highest `serial` it has ever accepted in `/var/lib/<id>/managed/serial` and
refuses anything lower, logging and reporting the attempt. The stored serial is root-owned; an
attacker who can rewrite it can also delete the whole directory (§8.4), which is the boundary this
mechanism sits inside, not one it claims to cross.

Clocks are not trusted for anything but TLS validity: `serial` is a counter, `expires_at` cannot
lock anyone out (§8.6), and §10's accounting is monotonic-clock based with wall-clock steps
reported rather than obeyed.

### 8.6 The control plane will be down

Design assumption, not a risk to be mitigated away. When the API is unreachable — outage, expired
subscription, cancelled service, DNS — the device:

- **keeps authenticating** every user in its cached bundle, indefinitely;
- **keeps enforcing** the cached policy, indefinitely;
- queues its events until the cap (§5.5), then drops the oldest;
- says "last synced 9 days ago" in `status`, in the QML app, and in the greeter's session message
  if it ever grows one.

The one thing it will not do is degrade into a machine nobody can log into. That is why identity
never expires (§5.8 rule 3), and why the local administrator account exists (§1).

### 8.7 One mode at a time

Local-only, AD-joined and managed are mutually exclusive, and the two CLIs enforce it in both
directions: `<id>-managed enroll` refuses when `/etc/sssd/sssd.conf` exists, `<id>-domain join`
refuses when `enrollment.json` does, each naming the other and how to leave it. Both refusals are
preflight, before anything is written. There is no technical reason the UID spaces would collide —
sssd's are SID-derived and far above 60000 — but two systems provisioning accounts on one machine
is a support burden with no user behind it.

### 8.8 It is surveillance, and the design has to say so

§10 collects when people use their computers, and eventually what they use it for. For children in
a household, that is the point. For a small business, **employee monitoring is regulated** in most
of the jurisdictions this would ship into, and "the OS made it easy" is not a defence for the
operator or for whoever runs the control plane. The design constraints that follow from it are
concrete, and they are cheaper to build in now than to retrofit:

- **Minimise.** Durations, app identifiers, session boundaries. Not window titles, not URLs, not
  keystrokes, not screenshots. The event schema in §5.5 has no field for any of those and should
  not grow one.
- **Be visible.** A monitored session says so — a permanent, non-dismissable indicator in the
  panel, and `<id>-managed status` readable by the monitored user, showing exactly what is
  collected and what limits apply. A user who cannot see the rules cannot follow them.
- **Symmetry where it exists.** Adults in a household are users too; the web UI should not make it
  easier to monitor a person than to show that person their own data.
- **Retention is the server's job**, and it should be short by default and stated in the UI.
- **Consent belongs to the operator**, not to us: the control plane requires an explicit
  acknowledgement before enabling monitoring on a device assigned to an adult account, and records
  who acknowledged it.

### 8.9 The exit

A household that stops paying, or an operator that shuts down, must not take the family's computers
with it. `<id>-managed leave` therefore has one behaviour that is not merely the inverse of enrol:
by default it **materialises every managed user as a local account** — `useradd -u <same uid>` with
the same home, the same group memberships, the same shadow hash copied from the record — and only
then removes the drop-ins. UIDs are preserved, so every file in every home directory still belongs
to the person who owns it. `--purge` skips that and removes the accounts, and asks twice.

The same path runs on `410 Gone` (§5.3), so a device revoked at the control plane degrades into a
working, unmanaged, local-only machine rather than into a brick.

## 9. What it costs

**Zero new packages, on every profile.** Verified 2026-09-08 against
`config/portage/expected-packages.desktop.txt` and the built target: `sys-apps/systemd` 260.1 with
`nss-systemd` and `userdbctl`, `dev-lang/python` 3.14 with `requests`/`urllib3`/`certifi`,
`net-misc/curl`, `dev-libs/openssl`, `app-crypt/gnupg`, `app-misc/ca-certificates` (a 214 KiB CA
bundle at `/etc/ssl/certs/ca-certificates.crt`), `sys-libs/pam` with `pam_unix`, `pam_time`,
`pam_access`, `pam_exec`, `pam_listfile`, `pam_faillock`, `pam_mkhomedir`, plus `qml6`, Kirigami,
`pkexec` and `loginctl` for §7.2. There is no `@managed` set to write, which is the sharpest
contrast with plan/18: **the AD client cost 19 atoms on desktop and 64 on console; this costs
none.**

It is not free of consequences, though, and two are worth stating before Phase A rather than after:

- **It pins the Python cluster.** plan/10 §"orphaned Python cluster" measures
  `dev-python/{requests,urllib3,idna,charset-normalizer,certifi,pysocks}` and friends at ~1.8 MiB
  and holds them as removable-in-principle. A `<id>-managed` written in Python makes them
  load-bearing. 1.8 MiB is a cheap price for JSON parsing, HTTPS with a maintained CA path and a
  readable 600-line client instead of a bash program shelling out to `curl` and parsing JSON with
  `sed` — but it takes an option off plan/10's table, and plan/06's interpreter policy says that is
  a decision to record, not an accident to discover. Recorded here. (The alternative, if that
  cluster is ever wanted gone: the client needs only `curl` + `openssl` + a JSON parser, and
  Python's stdlib `json` is what makes the difference. There is no `jq` in the image.)
- **§7.2 and §7.3 are not free.** The QML app is; the KCM and the Calamares page need an in-repo
  Portage overlay, which is genuinely new machinery for this pipeline (§7.2), and that is the
  entire reason they are phased last.

New files in the repo, all of them ours:

```
config/rootfs/usr/bin/distro-managed.in
config/rootfs/usr/lib/systemd/system/distro-managed-sync.{service,timer}.in
config/rootfs/usr/lib/systemd/system/distro-managed-sync.service.d/10-conditional.conf
config/rootfs/usr/lib/NetworkManager/dispatcher.d/50-distro-managed.in
config/rootfs/usr/share/distro/managed-ui/*.qml
config/rootfs/usr/share/polkit-1/actions/org.distro.managed.policy.in
config/keys/managed-pubring.gpg
tests/managed-api/                       the fixture, §12
tests/test-managed.sh
plan/19-managed-mode.md
```

## 10. Parental controls and screen time — the later milestone

Sketched here only far enough that v1 does not paint it into a corner. It is a separate milestone
with its own document when it starts.

**The mechanism is almost entirely already in the image**, which is the useful finding:

| Need | Mechanism, shipped today |
|---|---|
| Session start/stop, who is logged in, idle | `systemd-logind` — `loginctl`, `IdleHint`, session objects on D-Bus |
| Warn | Plasma notifications from a per-session user unit |
| Lock | `loginctl lock-session` |
| End a session | `loginctl terminate-session`, or freeze the user slice for a "time's up, save your work" pause |
| Deny a login outright, in a time window | `pam_time.so` + a generated file, or `pam_exec.so` calling the checker — the hook line is **appended at build time** to the vendor PAM stack, the way `pam_mkhomedir` already is (plan/18 §2.2), and is inert without policy data |
| Which app is in front | KWin scripting over D-Bus; `flatpak ps` for Flatpak instances |
| Restrict an app | Flatpak install policy via polkit today (§6.3); launch policy needs the session agent |
| Monotonic accounting | `CLOCK_BOOTTIME`, so setting the wall clock back does not refund an hour |

**What is absent:** `malcontent` is not in the pinned tree, and KDE ships no equivalent. Every
piece of policy, accounting and UI above the primitives is ours to write — which is the argument
for keeping it a milestone with a design document, not a phase of this one.

**The shape it will take**, so the v1 schema is right:

- a **system** unit that owns policy and enforcement, and a **user** unit per session that owns
  observation (foreground app, idle) and the warnings;
- accounting written to `/var/lib/<id>/managed/usage/`, aggregated per user per day, uploaded as
  §5.5 events, capped and rotated like the queue;
- an enforcement ladder that is always warn → lock → end, never a silent kill, because a child
  losing an hour of homework to a screen-time rule is how a household stops using the feature;
- limits expressed per user per day, per weekday, and per app category, with a bank of "ask for
  more" requests that a parent approves in the web UI — the one flow that has to work when the
  device is offline and the parent's phone is not (queue the request, apply the grant at next
  sync, and let a parent standing next to the machine authorise it locally through polkit);
- `parental.schema` in the bundle goes from `0` to `1`, and nothing else in §5.4 changes.

## 11. Phasing

Each phase ends in something demonstrable, and no phase may regress the unenrolled image.

**Phase A — the client and the mechanism.** `<id>-managed` (enroll/sync/status/verify/leave), the
records, the units and the preset, the keyring, the polkit action, the QML enrolment app, stage 40
and 50 assertions, and the offline test suite against golden bundles through `--print-config`.
*Exit:* **T-MAN-5** — an image that has never enrolled boots with `failed_units=0`, local login
unaffected, `/etc/userdb` absent — and **T-MAN-1** on a booted guest against the fixture: enrol,
sync, `getent passwd` a managed user, log in on the console, home directory created, leave, local
login still works. Nothing may regress before anything is gained.

**Phase B — the API fixture.** `tests/managed-api/`, a container serving §5 with a fixed org, two
users and a signing key, built the way `tests/ad-dc/` is (from the pinned builder, never touching
the target's resolution) and wired into stage 70 by `build.sh --with-test-api`. DC-less runs skip
rather than fail, exactly as the domain tests do.
*Exit:* the guest completes an enrol → sync → login → leave cycle against it, unattended.

**Phase C — policy and the offline story.** Per-device access, the admin group and its drop-ins,
subuid, the Flatpak install policy, the event queue, anti-rollback, `410`-triggered self-unenrol
and `leave`'s materialisation (§8.9). Zero-touch enrolment by systemd credential.
*Exit:* **T-MAN-2**, **T-MAN-3**, **T-MAN-6** — including the one that matters most: a guest
enrolled, then cut off from the API entirely, still logs its users in and still enforces, over
three reboots, with `failed_units=0`.

**Phase D — the overlay, the KCM, the installer page.** `config/portage/overlay/`, `relock.sh`
support for a non-`::gentoo` repo, `<id>-kcm-managed`, then the Calamares view module and its
never-fail-the-install job.
*Exit:* **T-MAN-4** and **T-MAN-7**; System Settings lists the module and the installer completes
with the control plane unreachable.

**Phase E — parental controls.** Its own document (§10).

## 12. Testing

| ID | What |
|---|---|
| **T-MAN-1** | **The round trip.** Enrol a running desktop image against the fixture; a managed user resolves through NSS with the org's UID, authenticates through PAM on a real `login(1)` console login, gets a home directory; then leave, and the local account still works. Also checks §2.3's group-merge duplication on the *daemon* path |
| **T-MAN-2** | **Scoped records.** A user the bundle does not grant this device has no record, no `getent` entry and no hash anywhere on the disk — checked by grepping `/etc/userdb` and `/var` for the hash the fixture holds for them |
| **T-MAN-3** | **Anti-rollback.** Replay an older signed bundle: refused, logged, reported; the newer policy stays in force. Tamper one byte of a current bundle: refused |
| **T-MAN-4** | **The install that cannot reach the control plane.** Tick enrolment in the installer, point it at a dead API. The install *completes*: the chosen local account exists, `live` is gone, autologin is off, nothing managed was written, and `status` on the installed disk reports the requested enrolment and why it did not happen. plan/18 §7.4's lesson, applied before it can be learned again |
| **T-MAN-5** | **The unenrolled regression.** A managed-ready but never-enrolled image boots with `failed_units=0`, `/etc/userdb` does not exist, and `getent passwd <live user>` is unchanged |
| **T-MAN-6** | **The offline machine.** Enrolled, then the API is taken away. Three reboots: logins work, policy holds, the queue grows and is capped, `failed_units=0` throughout, `status` says stale |
| **T-MAN-7** | **Mode exclusivity.** `<id>-domain join` on a managed machine refuses and writes nothing; `<id>-managed enroll` on a joined machine refuses and writes nothing |
| **T-MAN-8** | **The exit.** `leave` without `--purge` on a device with two managed users leaves two working local accounts with the same UIDs, the same homes and the same passwords |

Offline suite, `tests/test-managed.sh`, needing no network and no fixture: `--print-config` output
for a golden bundle diffed against golden records, **including the `<uid>.user` symlinks, the
`.membership` file names and the `0600` mode on `.user-privileged`** (§2.3 — all three are silent
failures); signature verification against a test keyring, including a negative for a tampered
bundle and one for a bundle signed by an untrusted key; the preset disables the timer and the
`ConditionPathExists` drop-in exists; the client exits 0 under every injected failure (§4.1);
UID allocation stays inside `[1000, 60000]` (§2.4); and the API client's request shapes pinned
against §5's examples so a server change that breaks them fails here rather than in the field.

Build-time, stage 40 and 50: `/etc/userdb` is **not** in the image; no `<id>-managed*` enablement
symlink survives; the keyring is present and non-empty; `nss-systemd` provides the shadow entry
points (`_nss_systemd_getspnam_r` in `libnss_systemd.so.2`) — the same class of check as plan/18
§5.4's `libsss_<provider>.so` assertion, and for the same reason: **the daemon being installed and
the daemon being able to serve what the config names are two different questions**, and this
feature's entire authentication path is one NSS symbol in one shared object.

## 13. Open questions

1. **Does the daemon path behave like the drop-in path?** §2.2's probes ran with no `userdbd`.
   With the socket active, lookups go through `io.systemd.Multiplexer`, and two things need
   re-checking on a booted guest: whether the privileged section is still gated (it should be
   gated *twice* — peer uid and file mode), and whether the group-merge duplication in §2.3
   persists. T-MAN-1 covers both; nothing in the design changes either way, but the assertions
   should be written against what is true.
2. **`$y$` (yescrypt) or `$6$`?** The image's libcrypt is `sys-libs/libxcrypt`, which supports
   yescrypt, but `unix_chkpwd` was measured against `$6$` only. Cheap to settle in Phase A, and
   the answer belongs in §5.4 before any password is ever hashed by the control plane.
3. **Where does a business's device inventory stop?** §5.3's heartbeat carries enough for "which
   machines exist and are they alive". Anything past that — installed Flatpaks, disk health,
   hardware — is a product decision with a privacy cost, and it should be asked before it is
   built, not after.
4. **Does the KCM justify the overlay?** Phase D's cost is an in-repo ebuild repository and the
   lock/relock machinery to go with it, for a UI whose whole job is enrol, show, unenrol. If the
   QML app from Phase A proves sufficient in use, the overlay is better spent on the Calamares
   page alone — or not at all.
5. **Multi-org devices** — a machine shared between a household and a business, or a child's
   laptop that is also a school's. Out of scope for v1: one device, one org, one bundle.

## Changes to other documents

| Document | Change |
|---|---|
| [00-overview](00-overview.md) | Document map gains a row; "three kinds of identity" replaces plan/18's two |
| [01-architecture](01-architecture.md) | "First boot & default user" gains managed users as a fourth kind of identity, and `/etc/userdb` as a new `/etc` overlay tenant |
| [03-package-set](03-package-set.md) | A note that this feature adds **no** packages, and that `dev-lang/python` and the requests cluster become load-bearing (§9) |
| [06-pruning](06-pruning.md) | The interpreter policy gains its first recorded decision: Python is whitelisted, held by `<id>-managed` |
| [10-prune-audit](10-prune-audit.md) | The "orphaned Python cluster" is no longer orphaned |
| [07-testing](07-testing.md) | T-MAN-1..8 and the `tests/managed-api/` fixture |
| [16-installer](16-installer.md) | §5.3's module map gains the managed enrolment job (Phase D); §7.3's zero-touch credential path |
| [18-active-directory](18-active-directory.md) | `<id>-domain join` gains the §8.7 refusal when a machine is enrolled |
| README | New row in the plan table |
