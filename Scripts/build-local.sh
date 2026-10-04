#!/bin/bash
# Build a signed local app; optionally replace the installed copy without changing its identity.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIGURATION="${1:-Debug}"
ACTION="${2:-}"
case "$CONFIGURATION" in
    Debug) NAME="Tinycast Dev"; BUNDLE_ID="com.tinycast.app.dev" ;;
    Release) NAME="Tinycast"; BUNDLE_ID="com.tinycast.app" ;;
    *) echo "usage: build-local.sh [Debug|Release] [--install]" >&2; exit 2 ;;
esac
if [ "$#" -gt 2 ] || { [ -n "$ACTION" ] && [ "$ACTION" != --install ]; }; then
    echo "usage: build-local.sh [Debug|Release] [--install]" >&2
    exit 2
fi

APP="build/DerivedData/Build/Products/$CONFIGURATION/$NAME.app"
DESTINATION="/Applications/$NAME.app"
BUILD_ARGUMENTS=(-project Tinycast.xcodeproj -scheme Tinycast -configuration "$CONFIGURATION"
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
VERSION="${TINYCAST_BUILD_VERSION:-}"
if [ -z "$VERSION" ] && [ -d "$DESTINATION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DESTINATION/Contents/Info.plist")"
fi
if [ -n "$VERSION" ]; then
    BUILD_ARGUMENTS+=("MARKETING_VERSION=$VERSION")
fi

xcodebuild "${BUILD_ARGUMENTS[@]}" build
./Scripts/verify-local-signature.sh "$APP"
if [ "$CONFIGURATION" = Release ]; then
    ./Scripts/verify-signature.sh "$APP"
fi
if [ "$ACTION" != --install ]; then
    exit 0
fi

./Scripts/verify-local-signature.sh "$APP" "$DESTINATION"
STAGE="$(mktemp -d /Applications/.tinycast-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$NAME.app"
./Scripts/verify-local-signature.sh "$STAGE/$NAME.app" "$DESTINATION"
osascript - "$BUNDLE_ID" <<'APPLESCRIPT'
on run arguments
    set bundleID to item 1 of arguments
    if application id bundleID is running then
        tell application id bundleID to quit
    end if
end run
APPLESCRIPT
for ATTEMPT in {1..20}; do
    if ! pgrep -x "$NAME" >/dev/null; then break; fi
    sleep 0.5
done
if pgrep -x "$NAME" >/dev/null; then
    echo "✗ $NAME is still running; installation stopped." >&2
    exit 1
fi
if [ -d "$DESTINATION" ]; then
    mv "$DESTINATION" "$STAGE/previous.app"
fi
if ! mv "$STAGE/$NAME.app" "$DESTINATION"; then
    if [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$DESTINATION"; fi
    exit 1
fi
open "$DESTINATION"
echo "✓ Installed and launched $DESTINATION"
