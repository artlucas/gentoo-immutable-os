# A throwaway Active Directory domain controller, for stage 70's domain tests (plan/18 §8 Phase B).
#
# WHY A SEPARATE IMAGE AND NOT THE BUILDER. Provisioning an AD DC needs net-fs/samba[addc], and
# addc's REQUIRED_USE is `json python !system-mitkrb5 winbind` — samba builds its own bundled
# Heimdal. Putting that in builder/Dockerfile would change the USE of net-fs/samba on the
# builder's own "/", and the long note in that file explains why that is dangerous: portage
# evaluates REQUIRED_USE and slot operators for TARGET packages against whatever "/" says about
# the same package name. The image's samba is built `client` and must stay that way, so the
# flags a test fixture wants must never be visible to the resolution that produces the product.
#
# Keeping the DC in its own image also keeps it honest about what it is: a test fixture, not part
# of the build substrate. Nothing in the pipeline depends on it, and `bash tests/run-tests.sh`
# and every offline build work with it absent.
#
# FROM the builder, deliberately: it already carries the pinned Portage tree, the binhost trust
# store from getuto, and this project's SNAPSHOT_DATE. So the DC is built from the same tree the
# image is, and a stale-tree DC cannot silently drift from the client under test.
ARG BUILDER_TAG=immos-builder:latest
FROM ${BUILDER_TAG}

# addc pulls its own Heimdal and a python stack; none of it can reach the target rootfs, because
# this image never runs a stage. `-client` is off because the DC needs the server, and `ads`
# comes along with addc's own requirements.
# The full REQUIRED_USE chain, read off the failing resolution rather than guessed:
#   addc? ( json python !system-mitkrb5 winbind )   and   ads? ( acl ldap python winbind )
# `ldap` is the one that is easy to miss — `ads` implies it, and omitting it fails the build with
# "ads? ( ldap )" and nothing else.
#
# The three below it are samba's own dependencies asking for flags the BUILDER image does not
# carry — builder/Dockerfile mirrors only the lines config/portage/package.use/image needs for
# the target, and none of these is among them. samba[python] wants python bindings in tdb and
# tevent; cifs-utils drags in the same bind[gssapi] the image already sets for sssd. All three
# are confined to this fixture and reach nothing that ships.
RUN { echo 'net-fs/samba addc json python winbind -system-mitkrb5 acl ads ldap client'; \
      echo 'dev-libs/openldap sasl experimental minimal'; \
      echo 'net-dns/bind gssapi'; \
      echo 'sys-libs/tdb python'; \
      echo 'sys-libs/tevent python'; \
    } > /etc/portage/package.use/ad-dc \
 && emerge --quiet-build=y --usepkg --getbinpkg net-fs/samba \
 && rm -rf /var/tmp/portage/*

COPY entrypoint.sh /usr/local/bin/ad-dc
RUN chmod 0755 /usr/local/bin/ad-dc

# 53 DNS, 88 Kerberos, 389 LDAP, 445 SMB, 464 kpasswd. Documentation only — the tests use a
# user-defined docker network where every port is reachable.
EXPOSE 53/udp 53/tcp 88/udp 88/tcp 389/tcp 445/tcp 464/udp 464/tcp

ENTRYPOINT ["/usr/local/bin/ad-dc"]
