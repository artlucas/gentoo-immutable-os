"""A throwaway managed-mode control plane, for stage 70's tests (plan/19 §5, Phase B).

WHAT THIS IS. plan/19 §5 specifies a wire contract and says nothing about how a server
implements it — deliberately, because the client has to work against somebody else's service.
This is the reference the tests point at: one org, three users, one device, a real OpenPGP
signature over every bundle. It exists so that "the client speaks the protocol in §5" is a thing
a build can check rather than a thing a design document asserts.

IT IS A FIXTURE, NOT A PRODUCT. Everything is in memory and dies with the container. The
signing key's private half is committed in keys/ so the fixture can sign bundles a built image
accepts, and stage 40 warns loudly when an image trusts it. There is no database, no rate
limiting worth the name, no billing, and the enrolment code is a constant. A real control plane
owes its users all of those; this owes the test suite reproducibility.

THE TEST-CONTROL SURFACE under /test/ is what makes the hard cases reachable: revoking a device
(§8.9's 410 path), replaying an old bundle (§8.5's anti-rollback), corrupting a signature
(§5.7), and queueing a command. None of it is part of §5 and a real server must not have it.
"""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import tempfile
import time
import uuid
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse

GNUPGHOME = os.environ.get("GNUPGHOME", "/var/lib/managed-api/gnupg")
ORG = {"id": "org_01J8FIXTURE", "name": "The Smiths"}
ENROLL_CODE = os.environ.get("MANAGED_TEST_CODE", "K7QF-9M2B")
ADMIN_GROUP = os.environ.get("MANAGED_ADMIN_GROUP", "immos-admins")

# Passwords are in this file on purpose, exactly as the AD fixture's are: it is a test fixture on
# a private network, and a secret nobody can look up is a test nobody can debug.
USER_PASSWORDS = {
    "alice": os.environ.get("MANAGED_TEST_ALICE_PW", "Passw0rd-alice"),
    "bobby": os.environ.get("MANAGED_TEST_BOBBY_PW", "Passw0rd-bobby"),
    # NEVER granted to the test device. T-MAN-2 greps the whole disk for this user's hash, so
    # its only purpose is to be absent.
    "carol": os.environ.get("MANAGED_TEST_CAROL_PW", "Passw0rd-carol"),
}

app = FastAPI(title="managed-mode fixture", docs_url=None, redoc_url=None)


# ---------------------------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------------------------

class State:
    def __init__(self) -> None:
        self.devices: dict[str, dict[str, Any]] = {}
        self.codes: dict[str, dict[str, Any]] = {ENROLL_CODE: {"used": False}}
        self.serial = 412
        self.events: list[dict[str, Any]] = []
        self.heartbeats: list[dict[str, Any]] = []
        self.commands: dict[str, list[dict[str, Any]]] = {}
        self.acks: list[dict[str, Any]] = []
        # Idempotency-Key -> the original response, replayed for 24h (§5.1). A dict is enough:
        # the fixture lives for one test run.
        self.idem: dict[str, Any] = {}
        # Test knobs, all off by default.
        self.tamper = False
        self.replay_serial: int | None = None
        self.hashes = {u: crypt_sha512(p) for u, p in USER_PASSWORDS.items()}


def crypt_sha512(password: str) -> str:
    """$6$ via openssl. Python's crypt module was removed in 3.13, and passlib is one more pinned
    dependency for something the image already has a binary for."""
    salt = secrets.token_hex(8)
    out = subprocess.run(
        ["openssl", "passwd", "-6", "-salt", salt, password],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


# Constructed AFTER crypt_sha512, which State.__init__ calls: module-level code runs top to
# bottom, and a class body referring to a function defined below it is only fine until something
# actually calls it at import time.
ST = State()


# ---------------------------------------------------------------------------------------------
# the bundle
# ---------------------------------------------------------------------------------------------

def build_bundle(device: dict[str, Any], serial: int) -> dict[str, Any]:
    """§5.4. The users a device may log in ARE the users in its bundle: enforcement is by
    absence, so carol is not filtered out client-side, she is never sent."""
    allowed = device["logins_allowed"]
    users = []
    for name, uid in (("alice", 5001), ("bobby", 5002), ("carol", 5003)):
        if name not in allowed:
            continue
        u: dict[str, Any] = {
            "name": name,
            "uid": uid,
            "gid": uid,
            "real_name": "%s Smith" % name.capitalize(),
            "shell": "/bin/bash",
            "home": "/home/%s" % name,
            "state": "active",
            "roles": ["admin"] if name == "alice" else ["standard"],
            "groups": [ADMIN_GROUP] if name == "alice" else [],
            # §5.4: present ONLY for users this device may log in, which is the same statement
            # as the loop above and is worth making twice.
            "hashed_password": [ST.hashes[name]],
            "ssh_authorized_keys": [],
        }
        if name == "alice":
            u["subid"] = {"start": 200000, "count": 65536}
        users.append(u)

    now = time.time()
    return {
        "schema": 1,
        "serial": serial,
        "issued_at": rfc3339(now),
        "expires_at": rfc3339(now + 30 * 86400),
        "min_client_version": 1,
        "org": ORG,
        "device": {"id": device["id"], "name": device["name"], "state": device["state"]},
        "users": users,
        "groups": [{"name": ADMIN_GROUP, "gid": 4000}],
        "access": {"mode": "listed", "logins_allowed": sorted(allowed)},
        "admin": {"group": ADMIN_GROUP, "sudo": True, "polkit": True},
        "policy": {
            "flatpak": {"install_requires_admin": True, "allow": ["*"], "deny": []},
            "updates": {"auto": True, "window": {"start": "02:00", "end": "05:00"}},
            "session": {"idle_lock_s": 600},
        },
        # Reserved at schema 0: nothing reads it in v1, so §10 needs no bundle version bump on
        # the day parental controls land.
        "parental": {"schema": 0, "subjects": []},
        "revoked_users": [],
    }


def rfc3339(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def sign(text: str) -> str:
    """A real detached OpenPGP signature over the EXACT BYTES the client will store (§5.7).
    Signing the serialised text rather than a structure is what keeps JSON canonicalisation out
    of the trust path — so the fixture must sign the same string it sends, character for
    character, and that is why `bundle` goes over the wire as a string."""
    with tempfile.TemporaryDirectory() as d:
        data = os.path.join(d, "bundle.json")
        with open(data, "w", encoding="utf-8") as f:
            f.write(text)
        p = subprocess.run(
            ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase", "",
             "--armor", "--detach-sign", "--output", os.path.join(d, "sig"), data],
            capture_output=True, text=True, env={**os.environ, "GNUPGHOME": GNUPGHOME},
        )
        if p.returncode != 0:
            raise HTTPException(500, "signing failed: %s" % p.stderr)
        with open(os.path.join(d, "sig"), "r", encoding="utf-8") as f:
            return f.read()


def envelope(device: dict[str, Any], serial: int) -> tuple[dict[str, str], str]:
    bundle = build_bundle(device, serial)
    text = json.dumps(bundle, indent=2, sort_keys=True)
    signature = sign(text)
    if ST.tamper:
        # One byte, in the BUNDLE rather than in the signature: a client that verified a
        # re-serialised copy of what it parsed would still accept this, and that is exactly the
        # bug §5.7 is built to make impossible.
        text = text.replace('"serial": %d' % serial, '"serial": %d' % (serial + 1), 1)
    etag = '"%s-%d-%s"' % (device["id"], serial, "t" if ST.tamper else "c")
    return {"bundle": text, "signature": signature}, etag


# ---------------------------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------------------------

def auth(device_id: str, authorization: str | None) -> dict[str, Any]:
    device = ST.devices.get(device_id)
    if device is None:
        raise problem(404, "no such device")
    if not authorization or not authorization.startswith("Bearer "):
        raise problem(401, "a device bearer token is required")
    if authorization[7:] != device["secret"]:
        raise problem(401, "that device secret is not current")
    if device["state"] == "revoked":
        # §5.3: 410 is an INSTRUCTION TO UNENROL, not an error. The client turns the device back
        # into a working local-only machine rather than bricking it.
        raise problem(410, "this device has been revoked")
    return device


def problem(status: int, detail: str, headers: dict[str, str] | None = None) -> HTTPException:
    """RFC 9457 application/problem+json (§5.6). The client branches on the status and logs the
    rest; the type URI is for humans and dashboards."""
    return HTTPException(
        status_code=status,
        detail={"type": "https://example.org/probs/managed", "title": detail, "detail": detail},
        headers=headers,
    )


@app.exception_handler(HTTPException)
async def problem_handler(request: Request, exc: HTTPException) -> JSONResponse:
    body = exc.detail if isinstance(exc.detail, dict) else {"detail": str(exc.detail)}
    body.setdefault("status", exc.status_code)
    return JSONResponse(status_code=exc.status_code, content=body,
                        headers=exc.headers, media_type="application/problem+json")


def idempotent(key: str | None, produce):
    if not key:
        return produce()
    if key in ST.idem:
        return ST.idem[key]
    result = produce()
    ST.idem[key] = result
    return result


# ---------------------------------------------------------------------------------------------
# §5.3 endpoints
# ---------------------------------------------------------------------------------------------

@app.post("/v1/enroll")
async def enroll(body: dict[str, Any], idempotency_key: str | None = Header(None)):
    code = (body.get("code") or "").strip().upper()
    entry = ST.codes.get(code)
    if entry is None:
        raise problem(404, "no such enrolment code")

    def produce():
        if entry["used"]:
            # 409 if spent, 410 if expired (§5.3). A code authorises creating ONE device in one
            # org and nothing else.
            raise problem(409, "that enrolment code has already been used")
        entry["used"] = True
        device_id = "dev_%s" % uuid.uuid4().hex[:16]
        dev = body.get("device") or {}
        ST.devices[device_id] = {
            "id": device_id,
            "name": dev.get("name") or "unnamed",
            "hw_fingerprint": dev.get("hw_fingerprint", ""),
            "secret": secrets.token_urlsafe(48),
            "state": "active",
            # The household default: this device lists two of the three users, so T-MAN-2 has a
            # user whose hash was never sent here.
            "logins_allowed": {"alice", "bobby"},
            "enrolled_at": rfc3339(time.time()),
            "facts": dev,
        }
        return {
            "device_id": device_id,
            "device_secret": ST.devices[device_id]["secret"],
            "org": ORG,
            "api_base": os.environ.get("MANAGED_API_ADVERTISED_BASE", ""),
            "poll_interval": 3600,
            "bundle_etag": None,
        }

    result = idempotent(idempotency_key, produce)
    # api_base is only sent when the fixture was told what it is reachable as; an empty one would
    # make the client overwrite a working base URL with nothing.
    if not result.get("api_base"):
        result = {k: v for k, v in result.items() if k != "api_base"}
    return result


@app.get("/v1/devices/{device_id}/bundle")
async def bundle(device_id: str, response: Response,
                 authorization: str | None = Header(None),
                 if_none_match: str | None = Header(None)):
    device = auth(device_id, authorization)
    serial = ST.replay_serial if ST.replay_serial is not None else ST.serial
    payload, etag = envelope(device, serial)
    if if_none_match and if_none_match == etag:
        return Response(status_code=304, headers={"ETag": etag})
    response.headers["ETag"] = etag
    return payload


@app.post("/v1/devices/{device_id}/heartbeat")
async def heartbeat(device_id: str, body: dict[str, Any],
                    authorization: str | None = Header(None)):
    auth(device_id, authorization)
    ST.heartbeats.append({"device": device_id, "at": rfc3339(time.time()), **body})
    pending = ST.commands.pop(device_id, [])
    return {"poll_interval": 3600, "commands": pending}


@app.post("/v1/devices/{device_id}/events", status_code=202)
async def events(device_id: str, body: dict[str, Any],
                 authorization: str | None = Header(None),
                 idempotency_key: str | None = Header(None)):
    auth(device_id, authorization)
    incoming = body.get("events") or []
    if len(incoming) > 1000:
        raise problem(413, "at most 1000 events per request")

    def produce():
        seen = {e.get("id") for e in ST.events}
        for e in incoming:
            # Each event carries its own client-generated id for idempotency (§5.3), so an
            # at-least-once client cannot double-count by retrying after a timeout.
            if e.get("id") not in seen:
                ST.events.append({"device": device_id, **e})
        return {"accepted": len(incoming)}

    return idempotent(idempotency_key, produce)


@app.post("/v1/devices/{device_id}/commands/{cmd_id}/ack")
async def ack(device_id: str, cmd_id: str, body: dict[str, Any],
              authorization: str | None = Header(None)):
    auth(device_id, authorization)
    ST.acks.append({"device": device_id, "command": cmd_id, **body})
    return {"ok": True}


@app.post("/v1/devices/{device_id}/password")
async def password(device_id: str, body: dict[str, Any],
                   authorization: str | None = Header(None)):
    auth(device_id, authorization)
    user = body.get("user", "")
    if user not in USER_PASSWORDS:
        raise problem(404, "no such user")
    if body.get("old") != USER_PASSWORDS[user]:
        raise problem(403, "the current password is wrong")
    new = body.get("new") or ""
    # The SERVER applies the password policy and the SERVER chooses the hash format (§5.3). A
    # device that proposed one is how a weak hash gets in.
    if len(new) < 8:
        raise problem(422, "passwords must be at least 8 characters")
    USER_PASSWORDS[user] = new
    ST.hashes[user] = crypt_sha512(new)
    ST.serial += 1
    return {"ok": True, "serial": ST.serial}


@app.post("/v1/devices/{device_id}/unenroll")
async def unenroll(device_id: str, body: dict[str, Any],
                   authorization: str | None = Header(None)):
    auth(device_id, authorization)
    ST.devices[device_id]["state"] = "departed"
    return {"ok": True}


@app.get("/v1/keys")
async def keys():
    """The current signing key set, which a real server signs with a key already in the baked
    keyring — the anchor is always the image (§5.7). The fixture never rotates, so this reports
    the one key it has and nothing depends on it."""
    p = subprocess.run(["gpg", "--armor", "--export"], capture_output=True, text=True,
                       env={**os.environ, "GNUPGHOME": GNUPGHOME})
    return {"keys": [{"id": "fixture", "armored": p.stdout}]}


# ---------------------------------------------------------------------------------------------
# the test-control surface — NOT part of §5, and a real server must not have it
# ---------------------------------------------------------------------------------------------

@app.get("/test/state")
async def test_state():
    return {
        "devices": {k: {kk: (sorted(vv) if isinstance(vv, set) else vv)
                        for kk, vv in v.items() if kk != "secret"}
                    for k, v in ST.devices.items()},
        "serial": ST.serial,
        "events": ST.events,
        "heartbeats": ST.heartbeats,
        "acks": ST.acks,
        "tamper": ST.tamper,
        "replay_serial": ST.replay_serial,
    }


@app.post("/test/revoke/{device_id}")
async def test_revoke(device_id: str):
    """Drives §8.9: the next bundle fetch returns 410 and the device unenrols itself into a
    working local-only machine."""
    ST.devices[device_id]["state"] = "revoked"
    return {"ok": True}


@app.post("/test/bump")
async def test_bump():
    ST.serial += 1
    ST.replay_serial = None
    return {"serial": ST.serial}


@app.post("/test/replay/{serial}")
async def test_replay(serial: int):
    """Serve an OLD, correctly signed bundle. Replaying yesterday's — before a user was revoked,
    before a limit was tightened — is the cheapest attack on any offline policy system (§8.5)."""
    ST.replay_serial = serial
    return {"replay_serial": serial}


@app.post("/test/tamper/{on}")
async def test_tamper(on: int):
    ST.tamper = bool(on)
    return {"tamper": ST.tamper}


@app.post("/test/command/{device_id}/{ctype}")
async def test_command(device_id: str, ctype: str):
    ST.commands.setdefault(device_id, []).append(
        {"id": "cmd_%s" % uuid.uuid4().hex[:12], "type": ctype})
    return {"queued": ctype}


@app.post("/test/allow/{device_id}/{user}")
async def test_allow(device_id: str, user: str):
    ST.devices[device_id]["logins_allowed"].add(user)
    ST.serial += 1
    return {"logins_allowed": sorted(ST.devices[device_id]["logins_allowed"])}


@app.post("/test/deny/{device_id}/{user}")
async def test_deny(device_id: str, user: str):
    ST.devices[device_id]["logins_allowed"].discard(user)
    ST.serial += 1
    return {"logins_allowed": sorted(ST.devices[device_id]["logins_allowed"])}


@app.get("/healthz")
async def healthz():
    return {"ok": True, "serial": ST.serial}
