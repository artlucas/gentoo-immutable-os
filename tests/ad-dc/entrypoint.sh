#!/usr/bin/env bash
# Provision a disposable Active Directory domain and run it in the foreground.
#
# Everything here is thrown away with the container. The passwords are in this file on purpose:
# it is a test fixture on a private docker network, and a secret nobody can look up is a test
# nobody can debug. Nothing in it ever reaches an image.
set -euo pipefail

REALM="${AD_REALM:-IMMOS.TEST}"
DOMAIN="${AD_DOMAIN:-IMMOS}"
ADMIN_PASSWORD="${AD_ADMIN_PASSWORD:-Passw0rd-immos-test}"
TEST_USER="${AD_TEST_USER:-testuser}"
TEST_PASSWORD="${AD_TEST_PASSWORD:-Passw0rd-testuser}"
ADMIN_GROUP="${AD_ADMIN_GROUP:-Linux Admins}"

lower_realm="${REALM,,}"

if [[ ! -f /var/lib/samba/private/sam.ldb ]]; then
    echo "ad-dc: provisioning $REALM"
    rm -f /etc/samba/smb.conf
    # --use-rfc2307 adds the NIS schema. sssd's ldap_id_mapping=true does not need it, but a DC
    # that HAS the attributes lets the same fixture exercise the other id-mapping mode later
    # without being rebuilt.
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="$REALM" \
        --domain="$DOMAIN" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$ADMIN_PASSWORD" \
        --option="dns forwarder = 8.8.8.8"

    # The KDC's own krb5.conf, which samba writes for us.
    cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

    samba-tool user create "$TEST_USER" "$TEST_PASSWORD" \
        --given-name=Test --surname=User --mail-address="$TEST_USER@$lower_realm"
    samba-tool group add "$ADMIN_GROUP"
    samba-tool group addmembers "$ADMIN_GROUP" "$TEST_USER"
    echo "ad-dc: provisioned $REALM with user $TEST_USER and group '$ADMIN_GROUP'"
fi

# Announce readiness on stdout AFTER provisioning, because the host waits for this line rather
# than sleeping a guessed number of seconds.
echo "ad-dc: starting samba for $REALM"
exec samba --foreground --no-process-group --debuglevel=1
