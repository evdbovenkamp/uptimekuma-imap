#!/usr/bin/env bash
# Generates a throwaway self-signed certificate for the TLS-cert-failure test fixture.
# Secondary/optional - only needed if test #5 cannot be reproduced against a real server
# (see ../functional-test-checklist.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker run --rm -v "$SCRIPT_DIR:/out" alpine:3 sh -c "
    apk add --no-cache openssl >/dev/null &&
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout /out/fixture.key -out /out/fixture.crt \
        -subj '/CN=imap-tls-fixture.invalid'
"
echo "Wrote fixture.crt / fixture.key to $SCRIPT_DIR"
