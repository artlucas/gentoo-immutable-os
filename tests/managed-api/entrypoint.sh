#!/usr/bin/env bash
# Bring up the throwaway managed-mode control plane (plan/19 Phase B).
#
# Everything here is thrown away with the container: the signing key is imported into a GNUPGHOME
# under /var/lib, the TLS certificate is generated fresh on every start, and all state lives in
# the FastAPI process's memory.
set -euo pipefail

STATE=/var/lib/managed-api
export GNUPGHOME="$STATE/gnupg"
CERT_DIR="$STATE/tls"
PORT="${MANAGED_API_PORT:-8443}"

mkdir -p "$GNUPGHOME" "$CERT_DIR"
chmod 700 "$GNUPGHOME"

# The bundle-signing key. Its PUBLIC half is committed at config/keys/managed-pubring.asc and
# baked into the image, which is the only reason a guest accepts anything this fixture signs.
if ! gpg --list-secret-keys >/dev/null 2>&1 || [[ -z "$(gpg --list-secret-keys --with-colons 2>/dev/null)" ]]; then
    gpg --batch --quiet --import /opt/managed-api/keys/signing-key.asc
    # Ultimate trust on our own key, so --detach-sign never stops to ask.
    FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
    printf '%s:6:\n' "$FPR" | gpg --batch --import-ownertrust
    echo "managed-api: imported signing key $FPR"
fi

# HTTPS ONLY, because the client refuses anything else (plan/19 §5.1) and a fixture that made it
# accept http would be testing a client nobody ships. The certificate is self-signed, so the
# GUEST sets _MANAGED_TEST_INSECURE=1 for the test phase — the one place in this design where a
# test relaxes something a real device must not.
if [[ ! -f $CERT_DIR/server.pem ]]; then
    CN="${MANAGED_API_CN:-managed-api}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$CN" \
        -addext "subjectAltName=DNS:$CN,DNS:localhost,IP:127.0.0.1,IP:${MANAGED_API_IP:-127.0.0.1}" \
        -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.pem" 2>/dev/null
    echo "managed-api: generated a self-signed certificate for $CN"
fi

echo "managed-api: listening on https://0.0.0.0:$PORT (enrolment code ${MANAGED_TEST_CODE:-K7QF-9M2B})"
exec /opt/managed-api/venv/bin/uvicorn app:app \
    --app-dir /opt/managed-api \
    --host 0.0.0.0 --port "$PORT" \
    --ssl-keyfile "$CERT_DIR/server.key" \
    --ssl-certfile "$CERT_DIR/server.pem" \
    --log-level info
