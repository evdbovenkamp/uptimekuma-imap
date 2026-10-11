#!/usr/bin/env bash
#
# Three explicit, separately-invoked stages for updating Uptime Kuma while keeping the IMAP
# monitor patch applied. Deliberately NOT one linear script that runs end to end on its own:
# staging must be reviewed by a human before anything touches production.
#
#   ./update-and-reapply.sh build <new-upstream-tag>
#       Builds and verifies a new patched image. Delegates to install.sh/verify.sh.
#       Touches nothing live.
#
#   ./update-and-reapply.sh stage <image-tag> --from-volume <prod-data-volume>
#       Takes a safe ONLINE backup of the live data volume (sqlite's .backup, not a raw
#       copy of a hot WAL database), neutralizes every monitor and notification channel in
#       that COPY (so staging never re-polls real targets or fires duplicate alerts), and
#       starts staging on 127.0.0.1:3002. Does not touch the live volume or container.
#       Run the functional test checklist against the result yourself before continuing.
#
#   ./update-and-reapply.sh promote <image-tag> --compose-file <path> --data-volume <volume> \
#       [--container <name>] [--backup-script <path>]
#       The actual production swap: optionally runs an existing backup script first, then
#       rewrites the compose file's image line and recreates the service. Only run this
#       after staging has fully passed and you have explicitly decided to proceed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[update] $*"; }
die() { echo "[update] ERROR: $*" >&2; exit 1; }

STAGE="${1:-}"
[[ -n "$STAGE" ]] || die "Usage: $0 {build|stage|promote} ..."
shift

case "$STAGE" in
    build)
        NEW_TAG="${1:-}"
        [[ -n "$NEW_TAG" ]] || die "Usage: $0 build <new-upstream-tag>"
        log "Building against upstream tag $NEW_TAG..."
        IMAGE_TAG="$("$SCRIPT_DIR/install.sh" --upstream-tag "$NEW_TAG" | tail -1)"
        log "Built $IMAGE_TAG. Verifying..."
        "$SCRIPT_DIR/verify.sh" "$IMAGE_TAG"
        log "Build + verify passed: $IMAGE_TAG"
        log "Next: $0 stage $IMAGE_TAG --from-volume <your-prod-data-volume>"
        ;;

    stage)
        IMAGE_TAG="${1:-}"
        [[ -n "$IMAGE_TAG" ]] || die "Usage: $0 stage <image-tag> --from-volume <prod-data-volume>"
        shift
        FROM_VOLUME=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --from-volume) FROM_VOLUME="$2"; shift 2 ;;
                *) die "Unknown argument: $1" ;;
            esac
        done
        [[ -n "$FROM_VOLUME" ]] || die "--from-volume is required"
        docker volume inspect "$FROM_VOLUME" >/dev/null 2>&1 || die "Volume $FROM_VOLUME not found"

        STAGING_VOLUME="uptime-kuma-staging-data"
        log "Removing any previous staging volume..."
        docker volume rm "$STAGING_VOLUME" >/dev/null 2>&1 || true
        docker volume create "$STAGING_VOLUME" >/dev/null

        log "Taking an online backup of $FROM_VOLUME into $STAGING_VOLUME (safe against a live WAL writer)..."
        docker run --rm \
            -v "$FROM_VOLUME:/src:ro" \
            -v "$STAGING_VOLUME:/dst" \
            alpine:3 sh -c "apk add --no-cache sqlite >/dev/null && sqlite3 /src/kuma.db \".backup /dst/kuma.db\""

        log "Neutralizing every monitor and notification channel in the staging copy..."
        docker run --rm \
            -v "$STAGING_VOLUME:/data" \
            alpine:3 sh -c "apk add --no-cache sqlite >/dev/null && sqlite3 /data/kuma.db \
                'UPDATE monitor SET active = 0; UPDATE notification SET active = 0;'"

        log "Starting staging on 127.0.0.1:3002..."
        IMAP_IMAGE_TAG="$IMAGE_TAG" docker compose -f "$SCRIPT_DIR/../../staging/docker-compose.staging.yml" up -d

        log "Staging is up. Open an SSH tunnel to 127.0.0.1:3002 and run the functional"
        log "test checklist (custom/imap-monitor/tests/functional-test-checklist.md) and the"
        log "uninstall rehearsal (uninstall.sh against $STAGING_VOLUME) before promoting anything."
        ;;

    promote)
        IMAGE_TAG="${1:-}"
        [[ -n "$IMAGE_TAG" ]] || die "Usage: $0 promote <image-tag> --compose-file <path> --data-volume <volume> [--container <name>] [--backup-script <path>]"
        shift
        COMPOSE_FILE=""
        DATA_VOLUME=""
        CONTAINER=""
        BACKUP_SCRIPT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
                --data-volume) DATA_VOLUME="$2"; shift 2 ;;
                --container) CONTAINER="$2"; shift 2 ;;
                --backup-script) BACKUP_SCRIPT="$2"; shift 2 ;;
                *) die "Unknown argument: $1" ;;
            esac
        done
        [[ -n "$COMPOSE_FILE" && -n "$DATA_VOLUME" ]] || die "--compose-file and --data-volume are required"
        [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: $COMPOSE_FILE"
        docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || die "Image $IMAGE_TAG not found locally"

        if [[ -n "$BACKUP_SCRIPT" ]]; then
            [[ -x "$BACKUP_SCRIPT" ]] || die "Backup script not found or not executable: $BACKUP_SCRIPT"
            log "Running $BACKUP_SCRIPT before touching production..."
            "$BACKUP_SCRIPT"
        else
            log "WARNING: no --backup-script given. Proceeding without a fresh backup."
        fi

        log "Rewriting image line in $COMPOSE_FILE to $IMAGE_TAG..."
        cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak.$(date +%s)"
        sed -i -E "s|^(\s*image:\s*).*|\1$IMAGE_TAG|" "$COMPOSE_FILE"

        log "Recreating the service..."
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate

        log "Promoted. A backup of the previous compose file was saved alongside it."
        log "Update COMPATIBILITY's tested_against_upstream/last_verified_date by hand once"
        log "you have confirmed the production instance is healthy."
        ;;

    *)
        die "Unknown stage: $STAGE (expected build|stage|promote)"
        ;;
esac
