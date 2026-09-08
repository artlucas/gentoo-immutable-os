# shellcheck shell=bash
# ad-dc.sh — host-side lifecycle for stage 70's throwaway Active Directory domain (plan/18 §8).
#
# Sourced by build.sh. Everything here is optional: with no DC running, stage 70 skips its
# domain tests the way stage 80 skips a live profile, and every other build path is untouched.
#
# HOW THE GUEST REACHES THE DOMAIN, which is the part that needed proving. Three hops:
#
#   QEMU guest --(slirp 10.0.2.x)--> stage-70 container --(docker bridge)--> DC container
#
# QEMU's user-mode network NATs outbound TCP and UDP to anything the container can reach, so
# LDAP (389), Kerberos (88) and kpasswd (464) need nothing special. DNS is the hop that does,
# because Active Directory is discovered through SRV records and QEMU answers the guest's DNS
# itself at 10.0.2.3 — by relaying to whatever the CONTAINER's /etc/resolv.conf names. So the
# whole mechanism is one docker flag: run the stage-70 container with --dns pointing at the DC,
# and the guest's SRV lookups arrive at the domain controller with no guest-side configuration,
# no seeded NetworkManager profile, and no change to the image under test. That last point is
# what makes the test worth anything: the guest is the shipped image, byte for byte.
#
# The DC gets a STATIC address on a user-defined network, because --dns takes an address and
# docker's embedded DNS (which would resolve the container name) is exactly the thing being
# replaced here.

AD_DC_NETWORK="${AD_DC_NETWORK:-${DISTRO_ID:-immos}-testnet}"
AD_DC_SUBNET="${AD_DC_SUBNET:-172.31.77.0/24}"
AD_DC_IP="${AD_DC_IP:-172.31.77.10}"
AD_DC_NAME="${AD_DC_NAME:-${DISTRO_ID:-immos}-testdc}"
AD_DC_TAG="${AD_DC_TAG:-${DISTRO_ID:-immos}-testdc:latest}"
AD_DC_REALM="${AD_DC_REALM:-IMMOS.TEST}"
AD_DC_ADMIN="${AD_DC_ADMIN:-Administrator}"
AD_DC_ADMIN_PASSWORD="${AD_DC_ADMIN_PASSWORD:-Passw0rd-immos-test}"
AD_DC_TEST_USER="${AD_DC_TEST_USER:-testuser}"
AD_DC_TEST_PASSWORD="${AD_DC_TEST_PASSWORD:-Passw0rd-testuser}"

ad_dc_domain() { printf '%s' "${AD_DC_REALM,,}"; }

ad_dc_build() {   # RUNTIME BUILDER_TAG
    local rt=$1 builder=$2
    log "test DC: building $AD_DC_TAG from $builder"
    run "$rt" build --build-arg "BUILDER_TAG=$builder" -t "$AD_DC_TAG" \
        "$REPO_ROOT/tests/ad-dc" \
        || die "test DC image build failed. It emerges net-fs/samba[addc], which builds samba's
  bundled Heimdal — expect it to be slow the first time and cached thereafter."
}

ad_dc_up() {      # RUNTIME
    local rt=$1
    "$rt" network inspect "$AD_DC_NETWORK" >/dev/null 2>&1 \
        || run "$rt" network create --subnet "$AD_DC_SUBNET" "$AD_DC_NETWORK" \
        || die "could not create the $AD_DC_NETWORK docker network"
    ad_dc_down "$rt"
    log "test DC: starting $AD_DC_NAME at $AD_DC_IP (realm $AD_DC_REALM)"
    # --privileged is not for the DC's sake but for samba's: it wants to bind port 53 and set
    # its own capabilities. This is a disposable fixture on a private network.
    run "$rt" run -d --rm --privileged \
        --name "$AD_DC_NAME" \
        --network "$AD_DC_NETWORK" --ip "$AD_DC_IP" \
        --hostname dc \
        -e "AD_REALM=$AD_DC_REALM" \
        -e "AD_ADMIN_PASSWORD=$AD_DC_ADMIN_PASSWORD" \
        -e "AD_TEST_USER=$AD_DC_TEST_USER" \
        -e "AD_TEST_PASSWORD=$AD_DC_TEST_PASSWORD" \
        "$AD_DC_TAG" >/dev/null \
        || die "could not start the test domain controller"
    # Wait for the readiness line the entrypoint prints AFTER provisioning, rather than sleeping
    # a guessed number of seconds: a first run provisions a domain and takes far longer than a
    # rerun that finds sam.ldb already there.
    local waited=0
    until "$rt" logs "$AD_DC_NAME" 2>&1 | grep -q 'ad-dc: starting samba'; do
        (( waited >= 300 )) && {
            "$rt" logs "$AD_DC_NAME" 2>&1 | tail -30
            die "test DC did not come up within 300s (log above)"
        }
        sleep 3; waited=$((waited + 3))
    done
    log "test DC: ready after ${waited}s"
}

ad_dc_down() {    # RUNTIME
    local rt=$1
    "$rt" rm -f "$AD_DC_NAME" >/dev/null 2>&1 || true
}

# The docker arguments stage 70 needs to see the DC. --dns is the whole mechanism (see the
# header); --network puts the container on the same bridge so that address is routable.
ad_dc_run_args() {
    printf '%s\n' --network "$AD_DC_NETWORK" --dns "$AD_DC_IP"
}

# Handed to the stage as environment. Stage 70 treats AD_DC_IP being set as "domain tests are
# possible"; unset means skip, not fail.
ad_dc_env_args() {
    printf '%s\n' \
        -e "AD_DC_IP=$AD_DC_IP" \
        -e "AD_DC_REALM=$AD_DC_REALM" \
        -e "AD_DC_DOMAIN=$(ad_dc_domain)" \
        -e "AD_DC_ADMIN=$AD_DC_ADMIN" \
        -e "AD_DC_ADMIN_PASSWORD=$AD_DC_ADMIN_PASSWORD" \
        -e "AD_DC_TEST_USER=$AD_DC_TEST_USER" \
        -e "AD_DC_TEST_PASSWORD=$AD_DC_TEST_PASSWORD"
}
