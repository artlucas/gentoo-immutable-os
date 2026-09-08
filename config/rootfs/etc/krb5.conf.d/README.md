# /etc/krb5.conf.d

`/etc/krb5.conf` ends with `includedir /etc/krb5.conf.d/`, and MIT Kerberos treats a **missing**
include directory as an error — `"Included profile directory could not be read"` — which would
break every `kinit` on a machine that has never been joined to a domain. This file exists so the
directory does, and for no other reason.

It is safe to leave here. `includedir` parses only those files whose names consist **solely** of
alphanumerics, dashes and underscores; `README.md` contains a `.`, so Kerberos ignores it.

That rule is also a constraint on what a join may write: `<distro>-domain join` writes
`/etc/krb5.conf.d/<distro>_domain`, with no extension, because a realm-named file like
`CORP.EXAMPLE.COM.conf` would be **silently ignored** and the realm would go unconfigured with no
error anywhere. See [plan/18](../../../../plan/18-active-directory.md) §3.
