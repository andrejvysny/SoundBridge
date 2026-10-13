#!/bin/bash
# Fails if the shared protocol headers drifted between driver, host and app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$ROOT/packages/driver/include"
COPIES=(
    "$ROOT/packages/host/Sources/CSoundBridgeAudio/include"
    "$ROOT/apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include"
)
HEADERS=(RFSharedAudio.h RFSecureIPC.h)

if [ "${1:-}" = "--fix" ]; then
    for copy in "${COPIES[@]}"; do
        for header in "${HEADERS[@]}"; do
            cp "$CANONICAL/$header" "$copy/$header"
        done
    done
fi

status=0
for copy in "${COPIES[@]}"; do
    for header in "${HEADERS[@]}"; do
        if ! cmp -s "$CANONICAL/$header" "$copy/$header"; then
            echo "ERROR: $copy/$header differs from $CANONICAL/$header" >&2
            status=1
        fi
    done
done

if [ "$status" -eq 0 ]; then
    echo "OK: protocol headers in sync"
else
    echo "Run: tools/check_protocol_sync.sh --fix" >&2
fi
exit "$status"
