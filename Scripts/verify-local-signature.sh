#!/bin/bash
# Reject app identities that lose Accessibility permission when the binary changes.
set -euo pipefail

APP="${1:?usage: verify-local-signature.sh <app> [installed-app]}"
for BIN in "$APP" "$APP/Contents/Helpers/ClipboardTextHelper"; do
    SIGNATURE="$(codesign -dv --verbose=2 "$BIN" 2>&1)"
    REQUIREMENT="$(codesign -d -r- "$BIN" 2>&1)"
    if [[ "$SIGNATURE" != *"Authority="* || "$REQUIREMENT" == *"cdhash"* ]]; then
        echo "✗ $BIN has no stable certificate identity. See docs/signing.md." >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$APP"

INSTALLED="${2:-}"
if [ -n "$INSTALLED" ] && [ -d "$INSTALLED" ]; then
    codesign --verify --deep --strict "$INSTALLED"
    REQUIREMENT="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p')"
    if [ -z "$REQUIREMENT" ] || ! codesign --verify -R="$REQUIREMENT" "$APP"; then
        echo "✗ Signing identity changed; installation would invalidate the saved grant." >&2
        echo "Use the installed app's signing identity. See docs/signing.md." >&2
        exit 1
    fi
fi

echo "✓ Stable signing identity: $APP"
