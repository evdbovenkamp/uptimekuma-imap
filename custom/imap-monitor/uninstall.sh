#!/usr/bin/env bash
#
# Rolls back the IMAP monitor patch on a data volume: drops the imap_* columns from the
# "monitor" table and removes the migration's bookkeeping row from knex_migrations, so a
# stock Uptime Kuma image can boot on that volume afterwards without knex's migration-list
# validation crashing on boot ("migration directory is corrupt").
#
# This script never guesses: by default it only performs the database rollback and reports
# what to do next. Pass --apply-compose to also rewrite a compose file's image line and
# recreate the container - a separate, explicit opt-in, since that step touches a running
# service.
#
# IMPORTANT: run this using the PATCHED image (which still has the migration file) against
# the STOPPED volume - never run it after already switching to the stock image.
#
# Usage:
#   ./uninstall.sh --data-volume <volume> --patched-image <tag> \
#       [--container <name>] [--compose-file <path> --stock-image <image> [--apply-compose]]
set -euo pipefail

DATA_VOLUME=""
PATCHED_IMAGE=""
CONTAINER=""
COMPOSE_FILE=""
STOCK_IMAGE=""
APPLY_COMPOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-volume) DATA_VOLUME="$2"; shift 2 ;;
        --patched-image) PATCHED_IMAGE="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
        --stock-image) STOCK_IMAGE="$2"; shift 2 ;;
        --apply-compose) APPLY_COMPOSE=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { echo "[uninstall] $*"; }
die() { echo "[uninstall] ERROR: $*" >&2; exit 1; }

[[ -n "$DATA_VOLUME" ]] || die "--data-volume is required"
[[ -n "$PATCHED_IMAGE" ]] || die "--patched-image is required"
docker image inspect "$PATCHED_IMAGE" >/dev/null 2>&1 || die "Image $PATCHED_IMAGE not found locally"
docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || die "Volume $DATA_VOLUME not found"

if [[ "$APPLY_COMPOSE" == true ]]; then
    [[ -n "$COMPOSE_FILE" && -n "$STOCK_IMAGE" ]] || die "--apply-compose requires --compose-file and --stock-image"
    [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $COMPOSE_FILE"
fi

# --- 1. Stop the service first - never do DB surgery against a live WAL-mode database ----------

if [[ -n "$CONTAINER" ]]; then
    if docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        log "Stopping container $CONTAINER..."
        docker stop "$CONTAINER" >/dev/null
    else
        log "Container $CONTAINER is not running, nothing to stop."
    fi
else
    log "No --container given; assuming the volume is already detached from any running container."
fi

# --- 2. Run the down-migration from the PATCHED image against the stopped volume ---------------

log "Running the IMAP down-migration against volume $DATA_VOLUME using $PATCHED_IMAGE..."
docker run --rm -v "$DATA_VOLUME:/app/data" --entrypoint node "$PATCHED_IMAGE" extra/imap-migration-down.js

# --- 3. Confirm both the columns and the migration row are actually gone -----------------------

log "Verifying rollback..."
CHECK="$(docker run --rm -v "$DATA_VOLUME:/app/data" --entrypoint node "$PATCHED_IMAGE" -e "
    const sqlite3 = require('@louislam/sqlite3');
    const db = new sqlite3.Database('/app/data/kuma.db', sqlite3.OPEN_READONLY);
    db.all('PRAGMA table_info(monitor)', [], (err, columns) => {
        if (err) { console.log('ERROR:' + err.message); process.exit(0); }
        const hasImapColumn = columns.some((c) => c.name.startsWith('imap_'));
        db.get(
            \"SELECT COUNT(*) AS c FROM knex_migrations WHERE name LIKE '%add-imap-monitor%'\",
            [],
            (err2, row) => {
                if (err2) { console.log('ERROR:' + err2.message); process.exit(0); }
                console.log(hasImapColumn ? 'COLUMNS_PRESENT' : 'COLUMNS_GONE');
                console.log(row && row.c > 0 ? 'ROW_PRESENT' : 'ROW_GONE');
            }
        );
    });
")"

echo "$CHECK"
if ! echo "$CHECK" | grep -q "COLUMNS_GONE" || ! echo "$CHECK" | grep -q "ROW_GONE"; then
    die "Rollback verification failed - imap_* columns and/or the knex_migrations row are \
still present. Do NOT switch to the stock image on this volume; it will crash on boot."
fi
log "Rollback verified: imap_* columns and the migration bookkeeping row are both gone."

# --- 4. Optional: flip the compose file and recreate ---------------------------------------------

if [[ "$APPLY_COMPOSE" == true ]]; then
    log "Rewriting image line in $COMPOSE_FILE to $STOCK_IMAGE..."
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak.$(date +%s)"
    sed -i -E "s|^(\s*image:\s*).*|\1$STOCK_IMAGE|" "$COMPOSE_FILE"
    log "Recreating the service..."
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate
    log "Done. A backup of the previous compose file was saved alongside it."
else
    log "Database rollback complete. Compose file untouched (pass --apply-compose to also"
    log "switch the image and recreate the service)."
fi
