#!/bin/bash
# Download Sparkle's release tools (generate_appcast, sign_update) and verify
# them against a pinned digest.
#
# The appcast is signed with the private update key, so these tools must not come
# from an artifact produced by an earlier build job: they are fetched here and
# checked against the same SHA-256 SwiftPM enforces for the pinned Sparkle
# version. Keep VERSION/SHA256 in step with the `exact:` pin in
# apps/mac/SoundBridgeApp/Package.swift.
set -euo pipefail

VERSION="2.10.0"
SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-for-Swift-Package-Manager.zip"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?usage: fetch_sparkle_tools.sh <destination-dir>}"

if ! grep -q "exact: \"$VERSION\"" "$ROOT/apps/mac/SoundBridgeApp/Package.swift"; then
    echo "ERROR: Package.swift does not pin Sparkle $VERSION" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --output "$WORK/sparkle.zip" "$URL"
echo "$SHA256  $WORK/sparkle.zip" | shasum -a 256 -c -

mkdir -p "$DESTINATION"
unzip -q -o "$WORK/sparkle.zip" -d "$WORK/extracted"
find "$WORK/extracted" -type f \( -name generate_appcast -o -name sign_update \) -exec cp {} "$DESTINATION/" \;
chmod +x "$DESTINATION/generate_appcast" "$DESTINATION/sign_update"
echo "OK: verified Sparkle $VERSION tools in $DESTINATION"
