# Uptime Kuma IMAP Monitor

A native **IMAP** monitor type for [Uptime Kuma](https://github.com/louislam/uptime-kuma), delivered as an update-resistant Docker patch layer rather than a one-off container edit.

It checks that a mailbox actually works — connect, negotiate TLS/STARTTLS, log in, open the configured mailbox, log out — not just that something answers on a port. No core Uptime Kuma files are modified in place inside a running container; instead, this repo builds a custom, pinned Docker image from a clean upstream checkout, and ships install/verify/uninstall/update scripts to apply, confirm, and safely roll back the patch across Uptime Kuma upgrades.

## Why a patch layer, not a fork

Uptime Kuma has no plugin system for monitor types. Adding one natively means touching a handful of upstream files. Doing that by hand-editing files inside a running container is explicitly the wrong approach — those edits vanish the moment the container is recreated. This repo instead:

1. Clones a **pinned** upstream tag fresh.
2. Applies a small `git` patch to 4 existing files, plus a few brand-new files that are only ever copied, never patched (so they can never produce a merge conflict).
3. Builds a custom image using upstream's **own, unmodified** `docker/dockerfile`.
4. Lets you test the result in an isolated staging environment, with your own real production data cloned and neutralized, before it ever touches your running instance.

## What you get

- A new **IMAP** option in the "Specific Monitor Type" dropdown, right next to MQTT/RabbitMQ/SMTP/SNMP.
- Three check levels:
  - **Connect** — opens a raw socket (with TLS if configured) and reads the server's IMAP greeting. No credentials required.
  - **Authenticate** — logs in with the given credentials, then logs out. No mailbox is opened.
  - **Authenticate + Select Mailbox** (default) — additionally opens the configured mailbox (`INBOX` by default) before logging out.
- Three TLS modes: **IMAPS** (implicit TLS, port 993, default), **STARTTLS** (plaintext connect then upgrade, port 143, fails if the server doesn't offer it), and **None** (always plaintext — only for trusted internal/test servers).
- An "Ignore TLS certificate errors" toggle (default **off** — certificate errors are enforced by default).
- Specific, functional error messages instead of a generic "Connection failed": `DNS resolution failed`, `IMAP connection timeout`, `TLS handshake failed`, `TLS certificate validation failed`, `IMAP authentication failed`, `IMAP server rejected login`, `Unable to select mailbox <name>`, `IMAP protocol error`, `IMAP connection closed unexpectedly`.
- Credentials stored the same way every other Uptime Kuma monitor type stores them (plain columns on the `monitor` table) — consistent with the rest of the codebase, not a new storage mechanism.

Built on [`imapflow`](https://www.npmjs.com/package/imapflow), an actively maintained IMAP client for Node.js.

## Repository layout

```
.
├── custom/imap-monitor/
│   ├── COMPATIBILITY              # which upstream tag this patch is tested against
│   ├── VERSION                    # this patch's own version
│   ├── install.sh                 # builds a patched image (never touches running services)
│   ├── verify.sh                  # checks a built image before you trust it
│   ├── uninstall.sh                # rolls back imap_* columns + migration bookkeeping
│   ├── update-and-reapply.sh      # build / stage / promote workflow for Uptime Kuma upgrades
│   ├── patches/imap-monitor.patch # the only hand-maintained diff, 4 files
│   ├── files/                     # pure additions, copied in, never patched
│   └── tests/                     # functional test checklist + scenario runner
├── staging/docker-compose.staging.yml
└── deploy/docker-compose.prod.yml  # reference compose for a fresh install
```

## Requirements

- **Your Uptime Kuma instance must already be running via Docker / Docker Compose.** This patch layer builds and ships a custom Docker image, and `install.sh`/`verify.sh`/`uninstall.sh`/`update-and-reapply.sh` all operate through `docker`/`docker compose` commands. A native install (plain Node.js, `pm2`, systemd, no container) is **not supported** by these scripts — the patch's own edits (`patches/imap-monitor.patch` + `custom/imap-monitor/files/`) could in principle be applied to a bare checkout by hand, but nothing here builds, tests, or rolls that back for you.
- `git` and `docker` on the host. No Node.js installation needed — all `npm`/`vite` steps run inside throwaway containers.

## Installation (existing Uptime Kuma instance)

```bash
git clone https://github.com/evdbovenkamp/uptimekuma-imap.git
cd uptimekuma-imap/custom/imap-monitor
./install.sh
```

This clones the upstream tag recorded in `COMPATIBILITY`, applies the patch, adds the `imapflow` dependency, builds the frontend, and produces a locally tagged image such as `uptime-kuma-imap:2.5.6-imap1.0.0`. **It does not touch any running container, volume, or compose file.**

Then verify the build:

```bash
./verify.sh uptime-kuma-imap:2.5.6-imap1.0.0
```

**Strongly recommended before touching a real instance**: boot the image against a *copy* of your data volume on a scratch port, and run through `tests/functional-test-checklist.md` against a real mailbox. See [Staging](#staging-before-touching-anything-live) below.

Once you're satisfied, point your `docker-compose.yml`'s `image:` line at the tag `install.sh` built, pin it (don't use a floating tag like `:2`), and recreate the service:

```yaml
services:
  uptime-kuma:
    image: uptime-kuma-imap:2.5.6-imap1.0.0   # was: louislam/uptime-kuma:2
    # ...unchanged otherwise...
```

```bash
docker compose up -d --force-recreate
```

Your existing data volume, monitors, and users are untouched — the install only adds five nullable columns (`imap_username`, `imap_password`, `imap_security`, `imap_mailbox`, `imap_check_type`) to the `monitor` table via a normal knex migration.

### Staging before touching anything live

```bash
./update-and-reapply.sh stage uptime-kuma-imap:2.5.6-imap1.0.0 --from-volume <your-data-volume-name>
```

This takes a safe **online** backup of your live data volume (SQLite's own `.backup`, not a raw copy of a hot database), sets every monitor and notification channel in that *copy* to inactive (so staging never re-polls your real targets or fires duplicate alerts), and starts it on `127.0.0.1:3002` — reachable only via an SSH tunnel, with no reverse-proxy vhost and no Docker-socket mount. Create or edit an IMAP monitor there through the normal web UI, or run `tests/run-scenarios.js` directly against the image for a fast, credential-based check of all three check types without needing to log in.

## Upgrading Uptime Kuma

Use `update-and-reapply.sh`, never the stock `docker compose pull` — a pinned custom tag has nothing to pull, and a floating tag would silently drop the patch.

```bash
./update-and-reapply.sh build 2.6.0                                    # build + verify, no live touch
./update-and-reapply.sh stage uptime-kuma-imap:2.6.0-imap1.0.0 \
    --from-volume <your-data-volume-name>                              # rehearse on a fresh snapshot
# ...test via the UI or run-scenarios.js, then run the uninstall rehearsal below...
./update-and-reapply.sh promote uptime-kuma-imap:2.6.0-imap1.0.0 \
    --compose-file /path/to/docker-compose.yml \
    --data-volume <your-data-volume-name> \
    --backup-script /path/to/your/backup-script.sh                     # the real swap
```

If upstream has changed the exact lines this patch touches, `install.sh`'s `git apply --check` step will **stop with the exact conflicting hunks** rather than guess a resolution. Re-derive the same four edits against a fresh clone of the new tag (see `patches/imap-monitor.patch` for what they are — a dropdown option, two `v-if` list memberships, a registry entry, a `toJSON()`/`editMonitor` field, and a defaults-object entry; none of it is complicated, upstream just occasionally adds a new monitor type next to one of these exact spots), then regenerate the patch file and update `COMPATIBILITY`.

## Verification

```bash
./verify.sh <image-tag>
```

Checks: the monitor type is registered server-side, the built frontend bundle actually contains the patched form, `imapflow` is present at the expected version, no leftover `<<<<<<<` conflict markers survived the patch, the image boots cleanly on a disposable volume, the knex migration is recorded, and the image carries `imap.patch.version`/`imap.upstream.tag` labels.

`tests/functional-test-checklist.md` lists the five scenarios the original spec requires (valid login, wrong password, nonexistent mailbox, unreachable host, invalid certificate) plus two more (the `ignoreTls` toggle, and coverage of the `connect`/`authenticate` check types and `starttls`/`none` security modes). `tests/run-scenarios.js` runs all of them directly against `server/monitor-types/imap.js` inside a given image.

## Troubleshooting

- **`install.sh` stops with "patch does not apply cleanly"**: upstream changed a line this patch's context depends on. Read the printed hunk(s) — they show exactly what differs — and re-derive that one edit by hand against a fresh clone of the target tag (see [Upgrading](#upgrading-uptime-kuma)). Never force an automatic 3-way merge here.
- **`install.sh` stops with "already appears to ship a native IMAP monitor type"**: upstream added its own IMAP support. Stop and decide whether this patch is still needed for that version.
- **IMAP option missing from the dropdown after installing**: confirm the image you're running actually matches the tag `install.sh` printed (`docker inspect --format '{{.Config.Image}}' <container>`), and that your browser isn't serving a cached frontend bundle (hard refresh).
- **Dependency problem / build fails during `npm ci`**: the error is from upstream's own dependency tree, not this patch — check whether the pinned upstream tag itself builds cleanly before re-reporting it here.
- **Frontend doesn't show IMAP fields after an edit to `ImapMonitorFields.vue`**: you need to rebuild the image (`install.sh --force`) — the Vue component is compiled into `dist/` at build time, not loaded live.
- **Authentication always fails even with correct credentials**: check `imapSecurity`/port match what the server expects (993 for IMAPS, 143 for STARTTLS/none), and that the server isn't rate-limiting/blocking the source IP after prior failed attempts from testing.
- **Mailbox select always fails**: confirm the mailbox name's exact casing and separator (some servers use `.` instead of `/`); the error message includes the exact name that was requested.

## Rollback

To remove the IMAP extension and return to a stock Uptime Kuma image **without losing any monitoring data**:

```bash
./uninstall.sh --data-volume <your-data-volume-name> --patched-image <currently-installed-tag> \
    --container <your-container-name> \
    --compose-file /path/to/docker-compose.yml --stock-image louislam/uptime-kuma:<pinned-version> \
    --apply-compose
```

This stops the service, runs the migration's `down()` **and** removes its bookkeeping row from `knex_migrations` in one step, verifies both are actually gone, then (only with `--apply-compose`) rewrites the compose file's image line to the stock, pinned image and recreates the service. The bookkeeping-row removal is not optional: a stock image's migration directory has no file for this migration, and knex's default migration-list validation rejects that mismatch on boot ("migration directory is corrupt") — crash-looping the container. This exact sequence is rehearsed against a staging volume (see `update-and-reapply.sh stage`) before it is ever run against production.

Without `--compose-file`/`--apply-compose`, the script only performs the database rollback and leaves your running service untouched, so you can inspect the result before deciding to switch images.

## Known limitations

- **Docker-only.** See [Requirements](#requirements) — there is no supported path for a native (non-Docker) Uptime Kuma install.
- Credentials are stored in plaintext in the database, exactly like every other credential-bearing monitor type in Uptime Kuma (MQTT, RabbitMQ, Radius, basic auth, OAuth, ...). This patch does not introduce a new storage mechanism, for better or worse.
- The `STARTTLS` security mode is verified by code review and against a local [`greenmail`](https://hub.docker.com/r/greenmail/standalone) test server, not against a live STARTTLS-capable production IMAP server (none was available when this was built). If your server relies on `STARTTLS` specifically, test it directly before depending on it.
- Each upstream Uptime Kuma release may require re-deriving the four patched hunks if it happens to touch the exact same lines (see [Upgrading](#upgrading-uptime-kuma)). This is inherent to patching rather than forking, and is why `install.sh` stops rather than guessing.

## License

MIT — see [LICENSE](LICENSE). Uptime Kuma itself is also MIT-licensed.
