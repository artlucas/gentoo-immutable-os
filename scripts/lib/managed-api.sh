# shellcheck shell=bash
# managed-api.sh — host-side lifecycle for stage 70's throwaway managed-mode control plane
# (plan/19 Phase B).
#
# Sourced by build.sh. Everything here is optional: with no fixture running, stage 70 skips its
# managed tests the way it skips the domain ones without a DC, and every other build path is
# untouched.
#
# HOW THE GUEST REACHES THE CONTROL PLANE, which is simpler than the AD case and worth saying
# plainly because the two look alike and are not:
#
#   QEMU guest --(slirp 10.0.2.x)--> stage-70 container --(docker bridge)--> fixture container
#
# QEMU's user-mode networking NATs outbound TCP to anything the container can reach, and this is
# ONE TCP PORT to a fixed address. Managed mode needs no SRV records, no Kerberos and no DNS at
# all — the API base is a URL the client is handed at enrolment — so unlike scripts/lib/ad-dc.sh
# there is nothing to do about the guest's resolver. That difference is the whole reason managed
# mode works from a coffee shop and a domain join does not.
#
# The fixture gets a STATIC address on the same user-defined network the DC uses, so a build can
# run --with-test-dc and --with-test-api together without either one moving.

MANAGED_API_NETWORK="${MANAGED_API_NETWORK:-${AD_DC_NETWORK:-${DISTRO_ID:-immos}-testnet}}"
MANAGED_API_SUBNET="${MANAGED_API_SUBNET:-${AD_DC_SUBNET:-172.31.77.0/24}}"
MANAGED_API_IP="${MANAGED_API_IP:-172.31.77.20}"
MANAGED_API_PORT="${MANAGED_API_PORT:-8443}"
MANAGED_API_NAME="${MANAGED_API_NAME:-${DISTRO_ID:-immos}-testapi}"
MANAGED_API_TAG="${MANAGED_API_TAG:-${DISTRO_ID:-immos}-testapi:latest}"
MANAGED_API_CODE="${MANAGED_API_CODE:-K7QF-9M2B}"
MANAGED_API_ALICE_PW="${MANAGED_API_ALICE_PW:-Passw0rd-alice}"
MANAGED_API_BOBBY_PW="${MANAGED_API_BOBBY_PW:-Passw0rd-bobby}"
MANAGED_API_CAROL_PW="${MANAGED_API_CAROL_PW:-Passw0rd-carol}"

managed_api_url() { printf 'https://%s:%s' "$MANAGED_API_IP" "$MANAGED_API_PORT"; }

managed_api_build() {   # RUNTIME BUILDER_TAG
    local rt=$1 builder=$2
    log "test API: building $MANAGED_API_TAG from $builder"
    run "$rt" build --build-arg "BUILDER_TAG=$builder" -t "$MANAGED_API_TAG" \
        "$REPO_ROOT/tests/managed-api" \
        || die "test API image build failed. It creates a venv and pip-installs FastAPI, which
  needs a network the first time; none of it reaches the target rootfs (tests/managed-api/Dockerfile)."
}

managed_api_up() {      # RUNTIME
    local rt=$1
    "$rt" network inspect "$MANAGED_API_NETWORK" >/dev/null 2>&1 \
        || run "$rt" network create --subnet "$MANAGED_API_SUBNET" "$MANAGED_API_NETWORK" \
        || die "could not create the $MANAGED_API_NETWORK docker network"
    managed_api_down "$rt"
    log "test API: starting $MANAGED_API_NAME at $(managed_api_url)"
    run "$rt" run -d --rm \
        --name "$MANAGED_API_NAME" \
        --network "$MANAGED_API_NETWORK" --ip "$MANAGED_API_IP" \
        --hostname managed-api \
        -e "MANAGED_API_IP=$MANAGED_API_IP" \
        -e "MANAGED_API_PORT=$MANAGED_API_PORT" \
        -e "MANAGED_API_CN=managed-api" \
        -e "MANAGED_TEST_CODE=$MANAGED_API_CODE" \
        -e "MANAGED_TEST_ALICE_PW=$MANAGED_API_ALICE_PW" \
        -e "MANAGED_TEST_BOBBY_PW=$MANAGED_API_BOBBY_PW" \
        -e "MANAGED_TEST_CAROL_PW=$MANAGED_API_CAROL_PW" \
        -e "MANAGED_ADMIN_GROUP=${DISTRO_ID}-admins" \
        -e "MANAGED_API_ADVERTISED_BASE=$(managed_api_url)" \
        "$MANAGED_API_TAG" >/dev/null \
        || die "could not start the test control plane"

    # Uvicorn binds fast, but the first request also imports FastAPI and shells out to openssl
    # for three password hashes. Waiting on the health endpoint rather than on a fixed sleep is
    # what keeps this from being a flaky test on a loaded machine.
    local i
    for i in $(seq 60); do
        if "$rt" exec "$MANAGED_API_NAME" \
                /opt/managed-api/venv/bin/python -c \
                "import urllib.request, ssl
ctx = ssl._create_unverified_context()
urllib.request.urlopen('https://127.0.0.1:${MANAGED_API_PORT}/healthz', context=ctx, timeout=2)" \
                >/dev/null 2>&1; then
            log "test API: ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    "$rt" logs "$MANAGED_API_NAME" 2>&1 | tail -20
    die "the test control plane did not answer /healthz within 60s (logs above)"
}

managed_api_down() {    # RUNTIME
    local rt=$1
    "$rt" rm -f "$MANAGED_API_NAME" >/dev/null 2>&1 || true
}

# The environment stage 70 needs to find and drive the fixture. Printed one per line, the way
# ad_dc_env_args does, so build.sh can mapfile it into a -e array.
managed_api_env_args() {
    printf '%s\n' \
        "-e" "MANAGED_API_IP=$MANAGED_API_IP" \
        "-e" "MANAGED_API_PORT=$MANAGED_API_PORT" \
        "-e" "MANAGED_API_URL=$(managed_api_url)" \
        "-e" "MANAGED_API_CODE=$MANAGED_API_CODE" \
        "-e" "MANAGED_API_ALICE_PW=$MANAGED_API_ALICE_PW" \
        "-e" "MANAGED_API_BOBBY_PW=$MANAGED_API_BOBBY_PW" \
        "-e" "MANAGED_API_CAROL_PW=$MANAGED_API_CAROL_PW"
}

managed_api_run_args() {
    printf '%s\n' "--network" "$MANAGED_API_NETWORK"
}
