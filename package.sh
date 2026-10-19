#!/bin/bash
# Build the Release app (Apple Silicon and Intel) and pack it into a drag-to-install DMG.
#   ./package.sh            → .build/FocusEdit.app and .build/dist/FocusEdit-<version>.dmg
#   ./package.sh --open     also open the DMG in Finder
#   ./package.sh --no-dmg   only the app bundle (faster while developing)
#
# Every run stamps a new build number (CFBundleVersion, UTC date.time such as 20261019.143205),
# so macOS does not keep the Dock icon or other cached details of an earlier build.
#
# The app is ad-hoc signed: it runs on this Mac, but on other Macs Gatekeeper asks for
# "Open Anyway" until Developer ID signing and notarization arrive.
set -euo pipefail
cd "$(dirname "$0")"

open_dmg=false
make_dmg=true
for arg in "$@"; do
  case "$arg" in
    --open) open_dmg=true ;;
    --no-dmg) make_dmg=false ;;
    -h | --help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (use --open, --no-dmg or --help)" >&2
      exit 2
      ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }
fail() {
  echo "package failed: $1" >&2
  exit 1
}

mkdir -p .build
python3 scripts/update_version.py status >/dev/null ||
  fail "version files are out of sync; see python3 scripts/update_version.py status"

step "Build Release (arm64 + x86_64)"
arch_flags=(-c release --arch arm64 --arch x86_64)
if ! swift build "${arch_flags[@]}" >.build/release-build.log 2>&1; then
  grep -E 'error:' .build/release-build.log | head -20 >&2
  fail "swift build failed; full log: .build/release-build.log"
fi
bin="$(swift build "${arch_flags[@]}" --show-bin-path)"

step "Assemble FocusEdit.app"
app=.build/FocusEdit.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FocusEdit" "$app/Contents/MacOS/FocusEdit"
cp Info.plist "$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"

# Two integers that only grow: macOS compares CFBundleVersion component by component.
build=$(date -u +%Y%m%d.%H%M%S)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")

# The icon is drawn in code: the binary renders the iconset, iconutil packs the .icns.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
"$app/Contents/MacOS/FocusEdit" --makeicon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns" ||
  fail "iconutil could not build AppIcon.icns"

# Sign last: the signature seals Info.plist and the icon. A broken bundle fails here, not at launch.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app" || fail "the app's signature does not verify"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")" = "$build" ] ||
  fail "the app's CFBundleVersion is not the stamped build $build"
archs=$(lipo -archs "$app/Contents/MacOS/FocusEdit")

if ! $make_dmg; then
  printf '\nAssembled %s (version %s, build %s, %s)\n' "$app" "$version" "$build" "$archs"
  exit 0
fi

step "Pack DMG"
dist=.build/dist
dmg="$dist/FocusEdit-$version.dmg"
stage="$dist/stage"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/FocusEdit.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "FocusEdit $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
hdiutil verify -quiet "$dmg" || fail "the DMG checksum does not verify"

printf '\nCreated %s (%s, version %s, build %s, %s)\n' "$dmg" "$(du -h "$dmg" | cut -f1 | tr -d ' ')" \
  "$version" "$build" "$archs"
echo "Install it with ./install.sh"
echo "Ad-hoc signed: runs on this Mac; other Macs need System Settings → Privacy & Security → Open Anyway."
$open_dmg && open "$dmg"
exit 0
