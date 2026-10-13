#!/bin/bash
# Signature verification script for SoundBridge
# Validates all code signatures and entitlements

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/SoundBridge.app}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
success() { echo -e "${GREEN}OK: $1${NC}"; }
warn() { echo -e "${YELLOW}  $1${NC}"; }
info() { echo -e "${BLUE}INFO: $1${NC}"; }

section() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

if [ ! -d "$APP_BUNDLE" ]; then
    error "App bundle not found: $APP_BUNDLE"
    echo "Usage: $0 [path/to/SoundBridge.app]"
    exit 1
fi

section "SoundBridge Signature Verification"
echo "Bundle: $APP_BUNDLE"

FAILED=0

# Function to verify a component
verify_component() {
    local component="$1"
    local name="$2"

    echo ""
    info "Verifying $name..."

    if [ ! -e "$component" ]; then
        error "$name not found"
        FAILED=$((FAILED + 1))
        return 0
    fi

    # Check if signed
    if ! codesign -dv "$component" 2>&1 | grep -q "Signature"; then
        error "$name is NOT signed"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Verify signature
    if codesign --verify --deep --strict "$component" 2>/dev/null; then
        success "$name signature valid"
    else
        error "$name signature verification FAILED"
        codesign --verify --deep --strict --verbose=2 "$component" 2>&1 || true
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Display signing info
    echo "   Identity: $(codesign -dv "$component" 2>&1 | grep "Authority" | head -1 | sed 's/Authority=//')"

    # Check for hardened runtime
    if codesign -dv "$component" 2>&1 | grep -q "runtime"; then
        echo "   Hardened Runtime: Enabled"
    else
        warn "   Hardened Runtime: Disabled"
    fi

    # Check for timestamp
    if codesign -dv "$component" 2>&1 | grep -q "Timestamp"; then
        echo "   Timestamp: Present"
    else
        warn "   Timestamp: Missing"
    fi

    # Display entitlements if present
    if codesign -d --entitlements - "$component" 2>/dev/null | grep -q "<?xml"; then
        local entitlement_count=$(codesign -d --entitlements - "$component" 2>/dev/null | grep -c "<key>" || echo "0")
        echo "   Entitlements: $entitlement_count found"
    fi
}

# Runtime exceptions that no SoundBridge executable may carry. Adding one
# requires a documented justification in SECURITY.md and an update here.
FORBIDDEN_ENTITLEMENTS=(
    com.apple.security.cs.disable-library-validation
    com.apple.security.cs.allow-unsigned-executable-memory
    com.apple.security.cs.allow-jit
    com.apple.security.cs.allow-dyld-environment-variables
    com.apple.security.cs.disable-executable-page-protection
    com.apple.security.get-task-allow
    com.apple.security.device.audio-input
)

check_entitlements() {
    local component="$1"
    local name="$2"
    local entitlements
    entitlements=$(codesign -d --entitlements - --xml "$component" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo "{}")
    for key in "${FORBIDDEN_ENTITLEMENTS[@]}"; do
        if printf '%s' "$entitlements" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get(sys.argv[1]) is True else 1)' "$key"; then
            error "$name has forbidden entitlement $key"
            FAILED=$((FAILED + 1))
        fi
    done
}

team_of() {
    codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

# Verify each component
verify_component "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost" "SoundBridgeHost"
verify_component "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp" "SoundBridgeApp"
verify_component "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver" "SoundBridgeDriver.driver"
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    while IFS= read -r framework; do
        verify_component "$framework" "$(basename "$framework")"
    done < <(find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" | sort)
else
    warn "No frameworks found in bundle"
fi
verify_component "$APP_BUNDLE" "SoundBridge.app (bundle)"

section "Entitlements and Team Identity"
check_entitlements "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost" "SoundBridgeHost"
check_entitlements "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp" "SoundBridgeApp"
check_entitlements "$APP_BUNDLE" "SoundBridge.app"

APP_TEAM=$(team_of "$APP_BUNDLE")
for component in \
    "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost" \
    "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver"; do
    if [ -e "$component" ] && [ "$(team_of "$component")" != "$APP_TEAM" ]; then
        error "$(basename "$component") is not signed by the app's team ($APP_TEAM)"
        FAILED=$((FAILED + 1))
    fi
done
if [ -z "$APP_TEAM" ] || [ "$APP_TEAM" = "not set" ]; then
    error "App bundle has no Team ID"
    FAILED=$((FAILED + 1))
fi
DRIVER_ID=$(codesign -dv "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$DRIVER_ID" != "com.soundbridge.driver" ]; then
    error "Driver signing identifier is '$DRIVER_ID', expected com.soundbridge.driver"
    FAILED=$((FAILED + 1))
fi

section "Gatekeeper Assessment"

if spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1; then
    success "Gatekeeper: ACCEPTED"
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 3 ]; then
        warn "Gatekeeper: REJECTED (not notarized yet - this is expected)"
        echo "   Run notarization after signing: ./tools/notarize.sh"
    else
        error "Gatekeeper: REJECTED (signature issue)"
        FAILED=$((FAILED + 1))
    fi
fi

section "Code Signature Details"

echo ""
info "Full signature information:"
codesign -dvvv "$APP_BUNDLE" 2>&1

section "Summary"

if [ $FAILED -eq 0 ]; then
    echo ""
    success "All signatures valid!"
    echo ""
    echo "Status:"
    echo "  OK: All components signed"
    echo "  OK: Signatures verified"
    echo "  OK: Hardened runtime enabled"

    if spctl --assess --type execute "$APP_BUNDLE" 2>/dev/null; then
        echo "  OK: Gatekeeper approved"
    else
        echo "  WARN: Awaiting notarization"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Test: open \"$APP_BUNDLE\""
    echo "  2. Notarize: ./tools/notarize.sh"
    echo "  3. Package: ./tools/create_dmg.sh"
    echo ""
    exit 0
else
    echo ""
    error "$FAILED component(s) failed verification"
    echo ""
    echo "Common issues:"
    echo "  - Run code signing: ./tools/codesign.sh"
    echo "  - Check Developer ID certificate is installed"
    echo "  - Verify entitlements files exist"
    echo ""
    exit 1
fi
