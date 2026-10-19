#!/bin/bash
# Build the executable and assemble a minimal FocusEdit.app bundle so that
# NSDocument open/save panels, recent documents and document types work.
set -euo pipefail
cd "$(dirname "$0")"

# Refuse to build if the version files disagree (see VERSION_MANAGEMENT.md).
if ! python3 scripts/update_version.py status; then
    echo "package: version files are out of sync — run: python3 scripts/update_version.py sync" >&2
    exit 1
fi

swift build "$@"

BIN="$(swift build --show-bin-path)"
APP=".build/FocusEdit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FocusEdit" "$APP/Contents/MacOS/FocusEdit"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Stamp the build number (CFBundleVersion) with a UTC timestamp so macOS never
# confuses a new build of the same marketing version with a cached old one.
BUILD_NO="$(date -u +%Y%m%d.%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NO" "$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# Generate the app icon (rendered by the binary itself) and build the .icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN/FocusEdit" --makeicon "$ICONSET"
if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "Built AppIcon.icns"
else
    echo "WARNING: iconutil failed; app will use the default icon"
fi

# Ad-hoc sign the whole bundle last (it seals Info.plist and the icon), then
# verify, so a broken bundle fails here and not with SIGKILL at launch.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Assembled $APP (version $VERSION, build $BUILD_NO, ad-hoc signed)"
