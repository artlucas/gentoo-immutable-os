#!/usr/bin/env bash
# Active Directory domain join (plan/18).
#
# Everything asserted here fails silently on a real machine, which is why it is asserted at all:
#
#   1. THE UNJOINED CASE. Every profile ships the AD client, and almost nothing about that may be
#      observable until someone joins. sssd enabled on an unjoined machine is not a warning —
#      systemd-boot-check-no-failures gates boot-complete.target, so it is a failed boot and, on
#      the third one, a rollback to the previous image.
#   2. THE CALAMARES CONTRACT. The installer's domain-join path is Calamares executing a command
#      called `realm` with a fixed argv. That argv lives in someone else's C++, and a version
#      bump that changed it would be discovered by a stranger, mid-install, on their own disk.
#   3. THE KERBEROS INCLUDEDIR RULE. MIT Kerberos parses only those files in an includedir whose
#      names are alphanumerics, dashes and underscores, and treats a MISSING includedir as a hard
#      error. Both halves are silent: the wrong filename is ignored, and the missing directory
#      breaks every kinit on a machine nobody has joined yet.
export TEST_FILE_NAME=test-domain
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$TESTS_DIR")"
source "$TESTS_DIR/harness.sh"

TMP="$(make_tmpdir)"; trap 'rm -rf -- "$TMP"' EXIT
export REPO="$REPO_ROOT" WORK="$TMP/work" OUT="$TMP/out"
export STAGE_NAME='test'
source "$REPO_ROOT/scripts/lib/common.sh"
set +e
load_config

VERIFY=yes
export DISTRO_ID DISTRO_NAME VERSION HOME_URL UPDATE_URL LIVE_USER VERIFY FLATPAK_PREINSTALL
export DISTROBOX_DEFAULT_IMAGE

DST="$TMP/target"
install_rootfs_overlay "$REPO_ROOT/config/rootfs" "$DST"

# ---- 1. the set is in every profile ---------------------------------------------------------
# @installer is named by exactly one profile and test-installer.sh asserts that. @domain is the
# opposite property and it is just as load-bearing: an image cannot install software after the
# fact, so a profile without @domain is a machine that can never be joined.
assert_file "$REPO_ROOT/config/portage/sets/domain" "the @domain set exists"
for atom in sys-auth/sssd app-crypt/adcli; do
    assert_true "@domain names $atom" \
        grep -qx -- "$atom" "$REPO_ROOT/config/portage/sets/domain"
done
# ...and nothing else. The set states intent; the closure is the resolver's business.
DOMAIN_ATOMS="$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/config/portage/sets/domain")"
assert_eq "2" "$DOMAIN_ATOMS" "@domain lists two atoms, not its transitive closure"

for prof in "$REPO_ROOT"/config/profiles/*.conf; do
    p="$(basename -- "${prof%.conf}")"
    assert_true "profile $p names the @domain set" \
        grep -qE '^PROFILE_SETS="[^"]*\bdomain\b' "$prof"
done

# THE FLAG THAT CARRIES THE AD PROVIDER. sys-auth/sssd[samba] is not a preference: upstream's
# Makefile.am builds libsss_ad.la inside `if BUILD_SAMBA` and nowhere else, so -samba produces an
# sssd that installs, validates its config, lets adcli join the domain successfully, and then
# refuses to start on "Unable to load module [ad]". Every build-time assertion in this repo
# passed on that image. Asserted here as a plain string match because the failure it prevents
# costs a full rebuild and a live domain to observe.
PU="$REPO_ROOT/config/portage/package.use/image"
assert_true "sys-auth/sssd is built with USE=samba (the AD provider is inside BUILD_SAMBA)" \
    grep -qE '^sys-auth/sssd[[:space:]].*[[:space:]]samba([[:space:]]|$)' "$PU"
assert_false "sys-auth/sssd is not built with USE=-samba" \
    grep -qE '^sys-auth/sssd[[:space:]].*-samba' "$PU"
# ...and the dependency that flag names: `samba? ( >=net-fs/samba-4.10.2[winbind] )`.
assert_true "net-fs/samba is built with USE=winbind for sssd[samba]" \
    grep -qE '^net-fs/samba[[:space:]].*[[:space:]]winbind([[:space:]]|$)' "$PU"
# winbind brings a second domain client's units into an image that runs exactly one. They are not
# named sssd*, so the preset has to disable them by name.
PRESET="$REPO_ROOT/config/rootfs/usr/lib/systemd/system-preset/50-distro.preset.in"
for u in winbind.service winbindd.service sssd-pac.service sssd-pac.socket; do
    assert_true "the preset disables $u" grep -qx "disable $u" "$PRESET"
done
# Both enablement-symlink assertions must look for winbind too, or the preset above is the only
# thing standing between an unjoined boot and a rollback.
for f in scripts/stages/40-configure.sh scripts/stages/50-prune.sh; do
    assert_true "${f##*/} checks for enabled winbind units, not just sssd*" \
        grep -q "name 'winbind\*'" "$REPO_ROOT/$f"
done
# The provider module itself, checked in both stages: the config validating is not the same
# question as the back end being loadable.
for f in scripts/stages/40-configure.sh scripts/stages/50-prune.sh; do
    assert_true "${f##*/} asserts the sssd provider module for the configured id_provider" \
        grep -q 'libsss_\$SSSD_PROVIDER\.so' "$REPO_ROOT/$f"
done

# ---- 2. the image is domain-READY, so a join writes only new files --------------------------
# The /etc overlay has no 3-way merge: a file this image ships and a join edits stops receiving
# vendor updates forever (plan/01). So each of these has to be right at BUILD time.
NSS="$DST/etc/nsswitch.conf"
assert_true "nsswitch passwd line names sss" \
    grep -qE '^passwd:[[:space:]]+files[[:space:]]+sss[[:space:]]+systemd' "$NSS"
assert_true "nsswitch group line names sss" \
    grep -qE '^group:[[:space:]]+files[[:space:]]+\[SUCCESS=merge\][[:space:]]+sss[[:space:]]' "$NSS"
# NOT on shadow: sssd's NSS responder does not serve shadow entries, and naming a module that
# answers nothing there only slows every lookup down.
assert_false "nsswitch shadow line does NOT name sss" \
    grep -qE '^shadow:.*[[:space:]]sss([[:space:]]|$)' "$NSS"
# ...and stage 40 must know about it. That loop dlopen-checks every module named in the file, and
# a module it does not know about is one whose absence shows up as a domain user who does not
# exist, on a booted machine, with nothing logged.
assert_true "stage 40's NSS module loop includes sss" \
    grep -qE 'for m in resolve systemd myhostname sss; do' \
        "$REPO_ROOT/scripts/stages/40-configure.sh"

assert_file "$DST/etc/krb5.conf" "/etc/krb5.conf ships"
assert_true "krb5.conf includes /etc/krb5.conf.d/" \
    grep -qE '^includedir[[:space:]]+/etc/krb5\.conf\.d/' "$DST/etc/krb5.conf"
# The directory must EXIST, and install_rootfs_overlay walks files — an empty directory in
# config/rootfs would simply never arrive. This is what the README.md in it is for.
assert_true "/etc/krb5.conf.d/ exists in the installed overlay" test -d "$DST/etc/krb5.conf.d"
# ...and every file shipped in it must be one Kerberos IGNORES, or it gets parsed as a profile.
for f in "$DST"/etc/krb5.conf.d/*; do
    [[ -e $f ]] || continue
    b="$(basename -- "$f")"
    assert_true "shipped $b is ignored by includedir (its name contains a '.')" \
        grep -q '[.]' <<<"$b"
done
# No default_realm on an unjoined machine: inventing one makes every kinit fail with a confusing
# name instead of an honest "cannot find KDC", and the join drop-in is where it belongs.
assert_false "krb5.conf sets no default_realm" \
    grep -qE '^[[:space:]]*default_realm' "$DST/etc/krb5.conf"

# ---- 3. sssd must not run on a machine nobody has joined ------------------------------------
PRESET="$DST/usr/lib/systemd/system-preset/50-${DISTRO_ID}.preset"
assert_true "the preset disables sssd.service" grep -qx 'disable sssd.service' "$PRESET"
assert_false "the preset never ENABLES an sssd unit" grep -qE '^enable[[:space:]]+sssd' "$PRESET"
DROPIN="$DST/usr/lib/systemd/system/sssd.service.d/10-conditional.conf"
assert_file "$DROPIN" "the sssd.service drop-in ships"
# The second, independent defence. A unit whose Condition fails is SKIPPED, and skipped is what
# systemd-boot-check-no-failures does not count against the boot.
assert_true "the drop-in gates sssd on its own config file existing" \
    grep -qx 'ConditionPathExists=/etc/sssd/sssd.conf' "$DROPIN"
assert_true "stage 40 fails the build on an enabled sssd unit" \
    grep -q 'domain units are ENABLED in the image' "$REPO_ROOT/scripts/stages/40-configure.sh"

# ---- 4. the join CLI ------------------------------------------------------------------------
CLI="$DST/usr/bin/${DISTRO_ID}-domain"
assert_file "$CLI" "the join CLI is installed and rebranded"
assert_true "the join CLI is executable" test -x "$CLI"
assert_true "the join CLI is valid bash" bash -n "$CLI"

FAKE="$TMP/fakeroot"; mkdir -p "$FAKE/etc"; echo "lab-01" > "$FAKE/etc/hostname"
CONF="$("$CLI" join --domain CORP.Example.com --root "$FAKE" --print-config 2>&1)"

# --print-config must be exactly that: no side effects, so the offline suite can check the
# generated files with no domain controller anywhere.
assert_false "--print-config writes nothing" test -e "$FAKE/etc/sssd/sssd.conf"

# The four settings that are decisions rather than defaults (plan/18 §3.1). Each one is the
# difference between "any valid user in the domain can log in" and a support ticket.
assert_true "access_provider is permit by default" \
    grep -qx 'access_provider = permit' <<<"$CONF"
assert_true "ldap_id_mapping is on (AD rarely populates uidNumber)" \
    grep -qx 'ldap_id_mapping = true' <<<"$CONF"
assert_true "credentials are cached for offline login" \
    grep -qx 'cache_credentials = true' <<<"$CONF"
assert_true "users log in with their short name" \
    grep -qx 'use_fully_qualified_names = false' <<<"$CONF"
assert_true "homes land under /home, which is a symlink to /var/home" \
    grep -qx 'fallback_homedir = /home/%u' <<<"$CONF"
assert_true "the domain name is lowercased" grep -qx 'domains  = corp.example.com' <<<"$CONF"
# Two options shipped in the first version of this generator that sssd REJECTS — it exits rather
# than warns on an unknown name. `config_file_version` is a 1.x relic 2.x refuses, and
# `krb5_store_password_if_available` was invented (the real one ends `_if_offline`). Stage 40 now
# runs sssctl config-check against the generated file at build time; these two are pinned here so
# the specific mistakes cannot come back silently.
assert_false "no config_file_version (sssd 2.x rejects it)" \
    grep -q 'config_file_version' <<<"$CONF"
assert_false "no invented krb5_store_password_if_available" \
    grep -q 'krb5_store_password_if_available' <<<"$CONF"
assert_true "the real option name is used" \
    grep -qx 'krb5_store_password_if_offline = true' <<<"$CONF"
assert_true "stage 40 validates the generated config with sssctl" \
    grep -q 'Issues identified by validators: 0' "$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "the realm is uppercased" grep -qx '    default_realm = CORP.EXAMPLE.COM' <<<"$CONF"
assert_true "ad_hostname is the target's own FQDN" \
    grep -qx 'ad_hostname = lab-01.corp.example.com' <<<"$CONF"
# THE INCLUDEDIR NAMING RULE. A realm-named file would end in ".conf", and Kerberos would ignore
# it: the realm would go unconfigured with no error anywhere.
assert_true "the krb5 drop-in has a name includedir will actually parse" \
    grep -qE "^===== .*/etc/krb5\.conf\.d/${DISTRO_ID}_domain =====$" <<<"$CONF"
assert_false "the krb5 drop-in name has no extension" \
    grep -qE "^===== .*/etc/krb5\.conf\.d/[^ ]*\.[^ /]* =====$" <<<"$CONF"

ALLOW="$("$CLI" join --domain corp.example.com --root "$FAKE" \
         --allow-groups 'Linux Users' --admin-group 'Domain Admins' --print-config 2>&1)"
assert_true "--allow-groups switches to the simple access provider" \
    grep -qx 'access_provider = simple' <<<"$ALLOW"
assert_true "--allow-groups lists the groups" \
    grep -qx 'simple_allow_groups = Linux Users' <<<"$ALLOW"
assert_false "--allow-groups drops the permit provider" \
    grep -qx 'access_provider = permit' <<<"$ALLOW"
# sudo needs the space in a group name escaped; polkit does not.
assert_true "--admin-group escapes the space for sudoers" \
    grep -qx '%Domain\\ Admins ALL=(ALL:ALL) ALL' <<<"$ALLOW"
assert_true "--admin-group writes a polkit admin rule" \
    grep -q 'unix-group:Domain Admins' <<<"$ALLOW"

# AD stores a computer as sAMAccountName NAME$, capped at 16 characters. Failing by name here is
# far kinder than an LDAP constraint violation three steps into a join.
echo "workstation-0001" > "$FAKE/etc/hostname"
LONG="$("$CLI" join --domain corp.example.com --root "$FAKE" --print-config 2>&1)"; rc=$?
assert_eq "1" "$rc" "a 16-character hostname is refused before any join is attempted"
assert_contains "Active Directory allows 15" "$LONG" "and the error says why"
echo "lab-01" > "$FAKE/etc/hostname"

# ---- 5. the Calamares contract --------------------------------------------------------------
# Quoted from src/modules/users/ActiveDirectoryJob.cpp in calamares 3.4.2:
#
#   { "realm", "join", m_domain, "-U", m_adminLogin, "--install=" + installPath, "--verbose" }
#
# ...run with RunLocation::RunInHost, the admin password on stdin, and a 30-second timeout. If a
# calamares bump changes any of that, this is where it should be found.
SHIM_SRC="$REPO_ROOT/config/calamares/system/realm.in"
assert_file "$SHIM_SRC" "the realm shim exists"
assert_true "the realm shim is valid bash" bash -n "$SHIM_SRC"
SHIM="$TMP/realm"
render_template "$SHIM_SRC" "$SHIM"; chmod +x "$SHIM"
assert_false "no unresolved tokens in the rendered shim" grep -qE '@[A-Z][A-Z0-9_]*@' "$SHIM"

# Drive it with Calamares' exact argv, with a stub on PATH standing in for the join CLI.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/${DISTRO_ID}-domain" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@"
STUB
chmod +x "$TMP/bin/${DISTRO_ID}-domain"
ARGV="$(PATH="$TMP/bin:$PATH" "$SHIM" join corp.example.com -U Administrator \
        --install=/tmp/target/ --verbose </dev/null 2>&1)"
assert_contains "join" "$ARGV" "the shim forwards a join"
assert_contains "--domain
corp.example.com" "$ARGV" "the positional domain becomes --domain"
assert_contains "--user
Administrator" "$ARGV" "-U becomes --user"
assert_contains "--root
/tmp/target/" "$ARGV" "--install= becomes --root, so writes go to the TARGET not the medium"
assert_contains "--password-stdin" "$ARGV" "the password is forwarded on stdin"

# ---- 5b. verify, and why a failed join must not fail the install ----------------------------
# The installer cannot ask "is this domain real?" before it writes the disk. Calamares' users
# module keeps the domain and credentials in Config members and never publishes them to
# GlobalStorage (3.4.2 Config.cpp), so the realm shim is the first code in the whole install that
# learns a domain was asked for — by which point `partition` and `imagedeploy` have run.
#
# What follows from that is the rule this section pins. ActiveDirectoryJob turns a non-zero exit
# from the shim into JobResult::error, and it is appended BEFORE CreateUserJob, and before
# `removeuser` and `imageidentity` in the exec list. So a shim that exits non-zero on an
# unreachable DC leaves an installed disk with no chosen account, @LIVE_USER@ still present, and
# autologin still on — a failed install that boots into the live medium's session. The shim
# therefore verifies first, writes nothing if the check fails, and exits 0 regardless.
VBIN="$TMP/vbin"; mkdir -p "$VBIN"
cat > "$VBIN/adcli" <<'STUB'
#!/usr/bin/env bash
[[ ${ADCLI_MODE:-ok} == down ]] && { echo "adcli: failed to lookup domain" >&2; exit 1; }
[[ $1 == info ]] && printf 'domain-name = %s\ndomain-controller = dc.%s\n' "$2" "$2"
exit 0
STUB
cat > "$VBIN/kinit" <<'STUB'
#!/usr/bin/env bash
read -r _pw
case ${KINIT_MODE:-ok} in
  bad)  echo "kinit: Password incorrect while getting initial credentials" >&2; exit 1 ;;
  skew) echo "kinit: Clock skew too great while getting initial credentials" >&2; exit 1 ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$VBIN/kdestroy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VBIN/systemctl"
chmod +x "$VBIN"/*
export _DOMAIN_TEST_SKIP_ROOT=1

assert_true "the CLI documents a verify subcommand" grep -q '^  verify ' "$CLI"
# The PATH override belongs on the CLI, not on printf: the stubs are for the process doing the
# looking up.
v() { printf 'pw\n' | PATH="$VBIN:$PATH" "$CLI" verify --domain corp.example.com "$@"; }

VOUT="$(v --user Administrator --password-stdin 2>&1)"; rc=$?
assert_eq "0" "$rc" "verify exits 0 when the domain answers and the account authenticates"
assert_contains "domain logins will work" "$VOUT" "and says so in the terms the operator asked in"

VOUT="$(ADCLI_MODE=down v --user Administrator --password-stdin 2>&1)"; rc=$?
assert_eq "2" "$rc" "an unreachable domain is exit 2"
assert_contains "cannot reach the domain" "$VOUT" "named as unreachable, not as a failed join"

VOUT="$(KINIT_MODE=bad v --user Administrator --password-stdin 2>&1)"; rc=$?
assert_eq "3" "$rc" "rejected credentials are exit 3, distinct from an unreachable domain"

VOUT="$(KINIT_MODE=skew v --user Administrator --password-stdin 2>&1)"; rc=$?
assert_eq "4" "$rc" "clock skew is exit 4 — the failure Kerberos reports least legibly"
assert_contains "five minutes" "$VOUT" "and the message names the tolerance"

# A failing preflight must leave the target byte-identical. This is what makes exiting 0 from the
# shim honest: there is no half-written enrollment to reason about afterwards.
VROOT="$TMP/vroot"; mkdir -p "$VROOT/etc" "$VROOT/var/lib"; echo "lab-01" > "$VROOT/etc/hostname"
BEFORE="$(find "$VROOT" | sort)"
PATH="$VBIN:$PATH" ADCLI_MODE=down printf 'pw\n' | \
    PATH="$VBIN:$PATH" ADCLI_MODE=down "$CLI" join --domain corp.example.com --user Administrator \
        --root "$VROOT" --password-stdin >/dev/null 2>&1
rc=$?
assert_eq "2" "$rc" "join hands verify's exit code back, so the shim can tell the operator which"
assert_eq "$BEFORE" "$(find "$VROOT" | sort)" "a failed preflight writes nothing to the target"

# The shim: exit 0, and a record the installed system can report.
SOUT="$(PATH="$VBIN:$DST/usr/bin:$PATH" ADCLI_MODE=down printf 'secret\n' | \
        PATH="$VBIN:$DST/usr/bin:$PATH" ADCLI_MODE=down "$SHIM" join corp.example.com \
        -U Administrator "--install=$VROOT/" --verbose 2>&1)"; rc=$?
assert_eq "0" "$rc" "the shim exits 0 on an unreachable domain, so Calamares does not abort the
  install between deploying the filesystem and creating the local user"
assert_contains "NOT JOINED" "$SOUT" "while saying plainly that it did not join"
assert_contains "domain-pending" "$(find "$VROOT" -type f)" \
    "and records the asked-for join in the target"
assert_true "status reports a join that was requested and did not happen" \
    grep -q 'A domain join was requested during installation' "$CLI"
assert_true "leave removes the pending record too" grep -q 'p_pending "$root"' "$CLI"

# ---- 6. the installer wiring ----------------------------------------------------------------
USERS_CONF="$REPO_ROOT/config/calamares/modules/users.conf.in"
assert_true "the users page offers Active Directory" \
    grep -qx 'allowActiveDirectory: true' "$USERS_CONF"
assert_true "stage 40 installs the shim as an executable" \
    grep -q 'chmod 0755 -- "$TARGET/usr/bin/realm"' "$REPO_ROOT/scripts/stages/40-configure.sh"
# ...and it must not reach a product image. The shim only makes sense on the medium, and a
# /usr/bin/realm on an installed system is a realmd that is not realmd.
assert_true "stage 40 fails if /usr/bin/realm leaks into a non-installer profile" \
    grep -q 'usr/bin/realm' "$REPO_ROOT/scripts/stages/40-configure.sh"

# The hostname ordering trap (plan/18 §7.3): ActiveDirectoryJob runs BEFORE SetHostNameJob, so
# without this the computer account is created under the live medium's own name.
assert_true "imagedeploy writes /etc/hostname from global storage" \
    grep -q 'libcalamares.globalstorage.value("hostname")' \
        "$REPO_ROOT/config/calamares/local-modules/imagedeploy/main.py"

# ---- 7. the prune must not take any of it ---------------------------------------------------
PRUNE="$REPO_ROOT/scripts/stages/50-prune.sh"
for needle in libnss_sss pam_sss pam_mkhomedir 'adcli missing after prune' nsupdate \
              '/etc/krb5.conf.d missing after prune'; do
    assert_true "stage 50 asserts $needle survives" grep -qF -- "$needle" "$PRUNE"
done

# ---- 8. the test domain controller and the boot-test wiring ---------------------------------
# The harness is optional by design: with no DC, stage 70 skips its domain tests and every other
# build path is untouched. What is asserted here is that "optional" is implemented as SKIP and
# never as a silent pass — a domain test that quietly does nothing is worse than none.
assert_file "$REPO_ROOT/tests/ad-dc/Dockerfile"    "the test DC image is defined"
assert_file "$REPO_ROOT/tests/ad-dc/entrypoint.sh" "the test DC entrypoint exists"
assert_true "the test DC entrypoint is valid bash" bash -n "$REPO_ROOT/tests/ad-dc/entrypoint.sh"
assert_file "$REPO_ROOT/scripts/lib/ad-dc.sh"      "the DC lifecycle library exists"
# addc's REQUIRED_USE is `json python !system-mitkrb5 winbind`, i.e. samba with its OWN Heimdal.
# That must never be visible to the resolution that builds the product image, which is why the
# fixture is a separate image and not a builder package.
assert_true "the DC image builds samba with addc" \
    grep -q 'net-fs/samba addc' "$REPO_ROOT/tests/ad-dc/Dockerfile"
assert_false "the BUILDER does not build samba with addc" \
    grep -q 'net-fs/samba.*addc' "$REPO_ROOT/builder/Dockerfile"
# The builder's samba line is a USE MIRROR of the target's and must stay verbatim, or portage
# evaluates the target's samba against flags the target does not have.
assert_true "the builder still mirrors the image's samba flags verbatim" \
    grep -q "echo 'net-fs/samba client winbind'" "$REPO_ROOT/builder/Dockerfile"

STAGE70="$REPO_ROOT/scripts/stages/70-test.sh"
assert_true "stage 70 SKIPS the domain tests with no DC, rather than failing" \
    grep -q 'domain tests: skipped (no test domain controller' "$STAGE70"
assert_true "stage 70 asserts the unjoined case (T-DOM-4)" \
    grep -q 'is NOT joined to a domain but sssd=' "$STAGE70"
# The guest's DNS is relayed by slirp to whatever THIS container's resolv.conf names, and on a
# user-defined docker network that is 127.0.0.11 — a loopback address libslirp handles
# inconsistently. Stage 70 writes the DC's routable address instead.
assert_true "stage 70 points the container resolver at the DC before booting" \
    grep -q 'nameserver %s' "$STAGE70"
# `-smbios type=11,value=...` is a QEMU option LIST: QEMU splits the argument on commas before
# the guest sees anything, so an unescaped "domain=x,user=y" spec dies with "Invalid parameter
# 'user'" before boot. QEMU's escape for a literal comma is a doubled one.
assert_true "run-vm.sh doubles the commas in the domain credential" \
    grep -q 'DOMAIN_SPEC//,/,,' "$REPO_ROOT/scripts/run-vm.sh"
for f in join domain_user kinit pam home left conf_gone; do
    assert_true "stage 70 asserts the $f field of the domain report" \
        grep -qF "field \"\$DLOG\" $f" "$STAGE70"
done
# --with-test-dc cannot work offline (it builds an image) and must say so rather than producing
# a confusing docker error halfway through a long build.
assert_true "build.sh offers --with-test-dc" grep -q -- '--with-test-dc)' "$REPO_ROOT/scripts/build.sh"
assert_true "--with-test-dc refuses --offline" \
    grep -q 'with-test-dc needs a network' "$REPO_ROOT/scripts/build.sh"
# Only stage 70 joins the DC's network: a --dns pointing at a domain controller would break the
# distfile and binhost fetches stages 10, 20 and 30 depend on.
assert_true "only stage 70 is put on the test network" \
    grep -q 'AD_DC_ARGS\[@\]} -gt 0 && \$n == 70' "$REPO_ROOT/scripts/build.sh"

REPORTER="$REPO_ROOT/config/rootfs/usr/lib/image-test/test-report.sh.in"
assert_true "the guest reporter has a domain mode" grep -qx 'domain)' "$REPORTER"
assert_true "the guest reports whether sssd is running" grep -q 'sssd=\$sssd ' "$REPORTER"
assert_true "the guest reports whether LOCAL users still resolve" \
    grep -q 'nss_local=' "$REPORTER"
# The harness stops watching at the FIRST marker line, so a domain run must report exactly once.
DOMAIN_REPORTS="$(sed -n '/^domain)/,/^    ;;/p' "$REPORTER" | grep -c '^    report "ok')"
assert_eq "1" "$DOMAIN_REPORTS" "the domain mode emits exactly one marker line (the harness reads the first)"
# ...and no call to report() smuggles a DETAIL line in. report() prefixes $MARKER, so
# `report "$MARKER-DETAIL ..."` prints a second marker line and boot_and_watch stops watching
# there — before the real report is written.
assert_false "no report() call carries a DETAIL prefix" \
    grep -q 'report "\$MARKER-DETAIL' "$REPORTER"

# ---- 9. CONFIG_PROTECT --------------------------------------------------------------------
# The defect this feature exposed, and it was never specific to it: portage does not overwrite a
# file under CONFIG_PROTECT, it writes ._cfg0000_<name> beside it. sys-auth/pambase merged with
# USE=sssd, recorded USE=sssd in its VDB and installed pam_sss.so — and /etc/pam.d/system-auth
# stayed the pam_sss-less version from an earlier build, with the correct one sitting unused next
# to it. Every package audit passes; domain login just never works.
STAGE40="$REPO_ROOT/scripts/stages/40-configure.sh"
assert_true "stage 40 applies deferred CONFIG_PROTECT updates" \
    grep -q "find \"\$TARGET/etc\" -name '._cfg????_\*'" "$STAGE40"
assert_true "stage 40 fails the build if any survive" \
    grep -q 'CONFIG_PROTECT files are still pending' "$STAGE40"
# Order is the whole design: vendor's new file replaces vendor's old one, and THEN our own
# config replaces both. Reversed, a package update would clobber what config/rootfs ships.
CFG_LINE="$(grep -n "name '._cfg????_\*'" "$STAGE40" | head -1 | cut -d: -f1)"
OVL_LINE="$(grep -n 'install_rootfs_overlay "\$REPO/config/rootfs"' "$STAGE40" | head -1 | cut -d: -f1)"
assert_true "the config updates are applied BEFORE the rootfs overlay" \
    test "$CFG_LINE" -lt "$OVL_LINE"

finish
