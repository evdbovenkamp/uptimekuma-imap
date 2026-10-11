#!/usr/bin/env bash
#
# Builds a custom Uptime Kuma Docker image with the native IMAP monitor type patched in.
#
# This script only BUILDS a locally tagged image - it never touches any running container,
# compose file, or volume. Promoting a build to staging or production is a separate,
# explicit step (see README.md). All npm/vite steps run inside throwaway containers; no
# Node.js installation is required on the host, only `git` and `docker`.
#
# Usage:
#   ./install.sh [--force] [--upstream-tag <tag>]
#
#   --force              Rebuild even if an image with this tag already exists.
#   --upstream-tag TAG   Upstream Uptime Kuma git tag to build against.
#                        Defaults to COMPATIBILITY's tested_against_upstream.
#
# Environment overrides (all optional):
#   UPSTREAM_REPO         Default: https://github.com/louislam/uptime-kuma.git
#   IMAPFLOW_VERSION       Default: 2.4.0
#   BASE_BUILD_IMAGE      Image used for throwaway npm/vite steps. Default: louislam/uptime-kuma:base2
#   IMAGE_NAME            Default: uptime-kuma-imap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/louislam/uptime-kuma.git}"
IMAPFLOW_VERSION="${IMAPFLOW_VERSION:-2.4.0}"
BASE_BUILD_IMAGE="${BASE_BUILD_IMAGE:-louislam/uptime-kuma:base2}"
IMAGE_NAME="${IMAGE_NAME:-uptime-kuma-imap}"

# Run every throwaway container that writes into the cloned source tree as the invoking host
# user (not the image's default, usually root) - otherwise files it creates are root-owned on
# the host and a later plain `rm -rf` (e.g. on the next run) fails with "Permission denied".
# HOME is redirected to a scratch dir so npm has somewhere writable to put its cache under an
# arbitrary, possibly unknown-to-the-image uid.
DOCKER_RUN_AS_HOST_USER=(-u "$(id -u):$(id -g)" -e "HOME=/tmp/imap-build-home")

FORCE=false
UPSTREAM_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        --upstream-tag)
            UPSTREAM_TAG="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

log() { echo "[install] $*"; }
die() {
    echo "[install] ERROR: $*" >&2
    exit 1
}

# --- Preflight -----------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || die "git is required but not found on PATH"
command -v docker >/dev/null 2>&1 || die "docker is required but not found on PATH"

[[ -f "$SCRIPT_DIR/COMPATIBILITY" ]] || die "COMPATIBILITY file not found next to this script"
[[ -f "$SCRIPT_DIR/VERSION" ]] || die "VERSION file not found next to this script"

PATCH_VERSION="$(grep '^patch_version=' "$SCRIPT_DIR/VERSION" | cut -d= -f2)"
TESTED_AGAINST="$(grep '^tested_against_upstream=' "$SCRIPT_DIR/COMPATIBILITY" | cut -d= -f2)"
[[ -n "$PATCH_VERSION" ]] || die "Could not read patch_version from VERSION"
[[ -n "$TESTED_AGAINST" ]] || die "Could not read tested_against_upstream from COMPATIBILITY"

if [[ -z "$UPSTREAM_TAG" ]]; then
    UPSTREAM_TAG="$TESTED_AGAINST"
fi

if [[ "$UPSTREAM_TAG" != "$TESTED_AGAINST" ]]; then
    log "WARNING: building against upstream $UPSTREAM_TAG, but this patch was last verified"
    log "         against $TESTED_AGAINST. Re-run the full functional test checklist in"
    log "         README.md before promoting this build to staging or production."
fi

IMAGE_TAG="$IMAGE_NAME:$UPSTREAM_TAG-imap$PATCH_VERSION"

log "Upstream tag:   $UPSTREAM_TAG"
log "Patch version:  $PATCH_VERSION"
log "Target image:   $IMAGE_TAG"

# --- Idempotency -----------------------------------------------------------------------------

if [[ "$FORCE" != true ]] && docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    log "Image $IMAGE_TAG already exists. Nothing to do (use --force to rebuild)."
    echo "$IMAGE_TAG"
    exit 0
fi

# --- Fresh clone -------------------------------------------------------------------------------

CLONE_DIR="$BUILD_DIR/src-$UPSTREAM_TAG"
log "Cloning $UPSTREAM_REPO at $UPSTREAM_TAG into $CLONE_DIR"
mkdir -p "$BUILD_DIR"
if [[ -d "$CLONE_DIR" ]]; then
    # A plain `rm -rf` can fail here on a leftover clone from a run of install.sh older than
    # this check, back when build-step containers wrote into it as root. Route the removal
    # through a container too so it succeeds regardless of who owns what inside it.
    docker run --rm -v "$BUILD_DIR:/build" alpine:3 rm -rf "/build/src-$UPSTREAM_TAG"
fi
git clone --depth 1 --branch "$UPSTREAM_TAG" --quiet "$UPSTREAM_REPO" "$CLONE_DIR"

# --- Collision guard ---------------------------------------------------------------------------

if [[ -f "$CLONE_DIR/server/monitor-types/imap.js" ]] || grep -q '"imap"' "$CLONE_DIR/server/uptime-kuma-server.js"; then
    die "Upstream $UPSTREAM_TAG already appears to ship a native IMAP monitor type. \
Refusing to overwrite it - check whether this patch is still needed for this version."
fi

# --- Apply patch (check first, never guess on conflict) ---------------------------------------

PATCH_FILE="$SCRIPT_DIR/patches/imap-monitor.patch"
log "Checking patch applies cleanly..."
if ! (cd "$CLONE_DIR" && git apply --check "$PATCH_FILE") 2>/tmp/imap-patch-check.log; then
    log "ERROR: patch does not apply cleanly against $UPSTREAM_TAG. Details:"
    cat /tmp/imap-patch-check.log >&2
    die "Fix the patch (or update COMPATIBILITY) before retrying. Not guessing a resolution."
fi
(cd "$CLONE_DIR" && git apply "$PATCH_FILE")
log "Patch applied."

# --- Copy additive files (never patched, so they can never conflict) --------------------------

log "Copying additive files..."
mkdir -p "$CLONE_DIR/server/monitor-types" "$CLONE_DIR/src/components" "$CLONE_DIR/db/knex_migrations" "$CLONE_DIR/extra"
cp "$SCRIPT_DIR/files/server/monitor-types/imap.js" "$CLONE_DIR/server/monitor-types/imap.js"
cp "$SCRIPT_DIR/files/src/components/ImapMonitorFields.vue" "$CLONE_DIR/src/components/ImapMonitorFields.vue"
cp "$SCRIPT_DIR/files/db/knex_migrations/"*.js "$CLONE_DIR/db/knex_migrations/"
cp "$SCRIPT_DIR/files/extra/imap-migration-down.js" "$CLONE_DIR/extra/imap-migration-down.js"

# --- Safety net: no leftover conflict markers --------------------------------------------------

if grep -rn '^<<<<<<<\|^=======$\|^>>>>>>>' "$CLONE_DIR/server" "$CLONE_DIR/src" "$CLONE_DIR/db" 2>/dev/null; then
    die "Unresolved conflict markers found after applying the patch. This should be unreachable \
(git apply --check already succeeded) - investigate before continuing."
fi

# --- Add the imapflow dependency (never hand-patch package.json/package-lock.json) -------------

log "Adding imapflow@$IMAPFLOW_VERSION to package.json..."
docker run --rm "${DOCKER_RUN_AS_HOST_USER[@]}" -v "$CLONE_DIR:/app" -w /app "$BASE_BUILD_IMAGE" node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.dependencies = pkg.dependencies || {};
pkg.dependencies.imapflow = '$IMAPFLOW_VERSION';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 4) + '\n');
"
log "Regenerating package-lock.json..."
docker run --rm "${DOCKER_RUN_AS_HOST_USER[@]}" -v "$CLONE_DIR:/app" -w /app "$BASE_BUILD_IMAGE" \
    npm install --package-lock-only --no-audit --no-fund

# --- Merge the new i18n keys into src/lang/en.json (never hand-patch that file either) ---------

log "Merging IMAP translation keys into src/lang/en.json..."
docker run --rm "${DOCKER_RUN_AS_HOST_USER[@]}" \
    -v "$CLONE_DIR:/app" \
    -v "$SCRIPT_DIR/files/src/lang/imap.en.json:/tmp/imap.en.json:ro" \
    -w /app "$BASE_BUILD_IMAGE" node -e "
const fs = require('fs');
const base = JSON.parse(fs.readFileSync('src/lang/en.json', 'utf8'));
const extra = JSON.parse(fs.readFileSync('/tmp/imap.en.json', 'utf8'));
const merged = Object.assign({}, base, extra);
fs.writeFileSync('src/lang/en.json', JSON.stringify(merged, null, 4) + '\n');
"

# --- Full install + frontend build (needs devDependencies, so a throwaway container) -----------

log "Running npm ci + vite build (this can take a few minutes)..."
docker run --rm "${DOCKER_RUN_AS_HOST_USER[@]}" -v "$CLONE_DIR:/app" -w /app -e PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 "$BASE_BUILD_IMAGE" \
    sh -c "npm ci --no-audit --no-fund && npm run build"

[[ -d "$CLONE_DIR/dist" ]] || die "npm run build did not produce a dist/ directory"
log "Frontend build produced dist/."

# --- Docker image build, using upstream's own, unmodified Dockerfile ---------------------------

log "Building Docker image with upstream's docker/dockerfile (target: release)..."
docker build \
    -f "$CLONE_DIR/docker/dockerfile" \
    --target release \
    --label "imap.patch.version=$PATCH_VERSION" \
    --label "imap.upstream.tag=$UPSTREAM_TAG" \
    -t "$IMAGE_TAG" \
    "$CLONE_DIR"

log "Built $IMAGE_TAG"
log "Next steps: run verify.sh $IMAGE_TAG, then promote to staging manually (see README.md)."
log "This script does not touch any running container or compose file."
echo "$IMAGE_TAG"
