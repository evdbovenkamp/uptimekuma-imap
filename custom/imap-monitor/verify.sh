#!/usr/bin/env bash
#
# Verifies a Docker image built by install.sh actually has the IMAP monitor patch wired up
# correctly, without touching any running container or real data. Boots the image once,
# briefly, against a throwaway, disposable volume on a scratch port - always cleaned up,
# even on failure.
#
# Usage: ./verify.sh <image-tag>
set -uo pipefail

IMAGE_TAG="${1:-}"
[[ -n "$IMAGE_TAG" ]] || { echo "Usage: $0 <image-tag>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION_NAME="2026-10-11-1200-add-imap-monitor.js"
SCRATCH_PORT="${IMAP_VERIFY_PORT:-13001}"
SCRATCH_VOLUME="imap-verify-$$"
SCRATCH_CONTAINER="imap-verify-$$"

FAIL=0
pass() { echo "[verify] PASS: $1"; }
fail() {
    echo "[verify] FAIL: $1" >&2
    FAIL=1
}

cleanup() {
    docker stop "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$SCRATCH_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_in_image() {
    docker run --rm --entrypoint sh "$IMAGE_TAG" -c "$1"
}

# --- 1. Server-side registration ----------------------------------------------------------

if run_in_image "grep -q '\"imap\"' server/uptime-kuma-server.js && test -f server/monitor-types/imap.js"; then
    pass "IMAP monitor type registered in server/uptime-kuma-server.js"
else
    fail "IMAP monitor type NOT registered"
fi

# --- 2. Frontend bundle contains the IMAP form fields --------------------------------------

if run_in_image "grep -rl 'imapCheckType' dist/assets/*.js >/dev/null 2>&1"; then
    pass "Frontend bundle contains IMAP-specific strings"
else
    fail "Frontend bundle does NOT contain IMAP-specific strings (was the patched src/ actually built?)"
fi

# --- 3. imapflow dependency present ----------------------------------------------------------

IMAPFLOW_VERSION_IN_IMAGE="$(run_in_image "node -e \"console.log(require('./node_modules/imapflow/package.json').version)\"" 2>/dev/null || true)"
if [[ -n "$IMAPFLOW_VERSION_IN_IMAGE" ]]; then
    pass "imapflow present in image (version $IMAPFLOW_VERSION_IN_IMAGE)"
else
    fail "imapflow NOT found in node_modules inside the image"
fi

# --- 4. No leftover conflict markers --------------------------------------------------------

if run_in_image "grep -rn '^<<<<<<<\|^=======\$\|^>>>>>>>' server src db 2>/dev/null"; then
    fail "Unresolved conflict markers found inside the image"
else
    pass "No leftover conflict markers"
fi

# --- 5. Boot test + migration bookkeeping ---------------------------------------------------

docker volume create "$SCRATCH_VOLUME" >/dev/null

# Seed db-config.json so the server goes straight into Database.connect() + migrate.latest()
# on first boot, instead of stopping at the "no database configured yet" setup wizard (which
# would otherwise report as healthy without ever running a single migration).
docker run --rm -v "$SCRATCH_VOLUME:/app/data" --entrypoint sh "$IMAGE_TAG" \
    -c 'echo "{\"type\":\"sqlite\"}" > /app/data/db-config.json'

docker run -d --rm \
    --name "$SCRATCH_CONTAINER" \
    -v "$SCRATCH_VOLUME:/app/data" \
    -p "127.0.0.1:$SCRATCH_PORT:3001" \
    "$IMAGE_TAG" >/dev/null

BOOTED=false
for _ in $(seq 1 30); do
    STATUS="$(docker inspect --format '{{.State.Health.Status}}' "$SCRATCH_CONTAINER" 2>/dev/null || echo "")"
    if [[ "$STATUS" == "healthy" ]]; then
        BOOTED=true
        break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$SCRATCH_CONTAINER" 2>/dev/null)" != "true" ]]; then
        break
    fi
    sleep 2
done

if [[ "$BOOTED" == true ]]; then
    pass "Container boots and reports healthy on a clean volume"
else
    fail "Container did not become healthy within the timeout"
    echo "[verify] --- container logs ---" >&2
    docker logs "$SCRATCH_CONTAINER" 2>&1 | tail -50 >&2 || true
fi

if [[ "$BOOTED" == true ]]; then
    MIGRATION_CHECK="$(docker exec "$SCRATCH_CONTAINER" node -e "
        const sqlite3 = require('@louislam/sqlite3');
        const db = new sqlite3.Database('/app/data/kuma.db', sqlite3.OPEN_READONLY);
        db.get('SELECT COUNT(*) AS c FROM knex_migrations WHERE name = ?', ['$MIGRATION_NAME'], (err, row) => {
            if (err) { console.log('ERROR'); process.exit(0); }
            console.log(row && row.c > 0 ? 'FOUND' : 'MISSING');
        });
    " 2>/dev/null || echo "ERROR")"

    if [[ "$MIGRATION_CHECK" == "FOUND" ]]; then
        pass "IMAP knex migration recorded in knex_migrations"
    else
        fail "IMAP knex migration NOT recorded in knex_migrations (got: $MIGRATION_CHECK)"
    fi
fi

# --- 6. Image labels -------------------------------------------------------------------------

PATCH_LABEL="$(docker inspect --format '{{index .Config.Labels "imap.patch.version"}}' "$IMAGE_TAG" 2>/dev/null || true)"
UPSTREAM_LABEL="$(docker inspect --format '{{index .Config.Labels "imap.upstream.tag"}}' "$IMAGE_TAG" 2>/dev/null || true)"
if [[ -n "$PATCH_LABEL" && -n "$UPSTREAM_LABEL" ]]; then
    pass "Image labels present (imap.patch.version=$PATCH_LABEL, imap.upstream.tag=$UPSTREAM_LABEL)"
else
    fail "Image labels missing (imap.patch.version / imap.upstream.tag)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "[verify] All checks passed for $IMAGE_TAG"
else
    echo "[verify] One or more checks FAILED for $IMAGE_TAG" >&2
fi
exit "$FAIL"
