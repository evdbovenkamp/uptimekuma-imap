# IMAP monitor - functional test checklist

Run all five in staging (`update-and-reapply.sh stage ...` or a manual `install.sh` +
`verify.sh` + staging compose up) against real credentials, never against production.

| # | Scenario | Monitor config | Expected status | Expected message |
|---|---|---|---|---|
| 1 | Valid credentials, default check type | Correct username/password, `imapCheckType=authenticate_select`, `imapMailbox=INBOX` | UP | `IMAP OK - authenticated and mailbox INBOX selected` |
| 2 | Wrong password | Same as #1, deliberately wrong password | DOWN | `IMAP authentication failed` |
| 3 | Nonexistent mailbox | Correct credentials, `imapMailbox` set to a folder that does not exist | DOWN | `Unable to select mailbox <name>` |
| 4a | Unreachable host | Hostname `192.0.2.1` (TEST-NET-1, RFC 5737), short timeout | DOWN | `IMAP connection timeout` |
| 4b | DNS failure | Hostname `nonexistent.invalid` | DOWN | `DNS resolution failed` |
| 5 | Invalid TLS certificate | `imapSecurity=secure`, hostname set to the server's bare IP address instead of its DNS name (SAN mismatch) | DOWN | `TLS certificate validation failed` |
| 5b | TLS toggle check | Same as #5, with `ignoreTls` enabled | UP | (confirms the toggle actually wires into `tls.rejectUnauthorized`) |

Notes:

- Run #2 (wrong password) once, not repeatedly - repeated failed logins against a real mail
  server can trip fail2ban or an account lockout, which would then also break test #1.
- If #5 cannot be reproduced against your real server (e.g. no stable bare-IP TLS endpoint),
  use the throwaway fixture in `tests/tls-cert-failure/` instead - see its README for how to
  start and tear it down. It is a secondary option, not a dependency for the rest of the suite.
- For #5, use the server's **IPv4** bare address, not an IPv6 one, even if DNS returns both:
  Docker's default bridge network commonly has IPv6 disabled (`docker network inspect bridge
  --format '{{.EnableIPv6}}'`), so an IPv6-only address fails with `ENETUNREACH` regardless of
  the patch's own correctness - confirmed on status-souver.nl, where connecting by hostname
  works fine (resolves/connects over IPv4) but the bare AAAA address does not.
- `tests/run-scenarios.js` runs all seven cases (including 5b) directly against
  `server/monitor-types/imap.js` inside a given image, without needing Uptime Kuma's UI/API:
  `docker run --rm --entrypoint node -e IMAP_TEST_HOST=... -e IMAP_TEST_USER=... -e
  IMAP_TEST_PASS=... -e IMAP_TEST_BARE_IP_HOST=<ipv4> <image-tag> /app/run-scenarios.js`
  (mount the script to `/app/run-scenarios.js`). All seven passed against mailbox.souver.nl
  with `uptime-kuma-imap:2.4.0-imap1.0.0` on 2026-10-11.

### Check-type / security-mode coverage

The seven scenarios above all use `imapCheckType=authenticate_select` + `imapSecurity=secure`.
The other two check types and the `starttls`/`none` security modes were additionally
exercised against a local `greenmail/standalone` test server (`docker run --network host -p
3143:3143 -p 3993:3993 -e GREENMAIL_OPTS='-Dgreenmail.setup.test.imap
-Dgreenmail.setup.test.imaps -Dgreenmail.users=imaptest:imaptestpass@localhost'
greenmail/standalone:latest`, login as `imaptest`/`imaptestpass` - greenmail strips the
`@localhost` from the login name it created) on 2026-10-11:

| Check type | Security | Result |
|---|---|---|
| `connect` | `secure` (993) | UP - `IMAP OK - greeting received` |
| `connect` | `none` (143, plaintext) | UP - `IMAP OK - greeting received` |
| `authenticate` | `secure` (993) | UP - `IMAP OK - authenticated` |
| `authenticate_select` | `secure` (993) | UP - `IMAP OK - authenticated and mailbox INBOX selected` |

**Known residual gap**: the `starttls` upgrade path (`doSTARTTLS: true` passed to
`imapflow`) was NOT exercised against a live server - `mailbox.souver.nl` does not expose
port 143 at all, and `greenmail`'s plain IMAP listener does not advertise the `STARTTLS`
capability, so no available test target supports it. The option is passed straight through
to `imapflow`'s own documented `doSTARTTLS` behavior (verified by reading
`node_modules/imapflow/dist/cjs/types.d.ts`), and the surrounding mode-selection code in
`resolveSecurity()` is simple and already code-reviewed, but this specific path has not had
an end-to-end run. Before relying on `starttls` mode against a server that actually requires
it, test it directly first (e.g. against a Dovecot instance with STARTTLS enabled).
- All five must pass, and the uninstall rehearsal (`uninstall.sh` against the staging volume,
  followed by booting the stock image on it and confirming no migration-corrupt crash) must
  also pass, before promoting a build to production.
