#!/bin/bash
# Install a DMG built by ./package.sh into /Applications, so the Dock shows the new icon.
#   ./install.sh          install .build/dist/FocusEdit-<version>.dmg
#   ./install.sh <dmg>    install that DMG
#
# Quits a running FocusEdit, moves the installed copy to the Trash (nothing is deleted), copies the
# new one, re-registers it with Launch Services, makes it forget older copies in the Trash and
# restarts the Dock: without that the Dock can keep showing a cached, blank icon.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  -h | --help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

fail() {
  echo "install failed: $1" >&2
  exit 1
}

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
dmg=${1:-.build/dist/FocusEdit-$version.dmg}
[ -f "$dmg" ] || fail "no DMG at $dmg; run ./package.sh first"
app=/Applications/FocusEdit.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$2/Contents/Info.plist"; }
running() { /bin/ps -ax -o command= | grep -q "^$app/Contents/MacOS/FocusEdit"; }

if running; then
  # A document with unsaved changes asks whether to save; answer it, then run install.sh again.
  osascript -e 'tell application id "com.example.focusedit" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do running || break; sleep 0.25; done
  running && fail "FocusEdit is still running; quit it (save your documents) and try again"
fi

mount=$(mktemp -d)
trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
[ -d "$mount/FocusEdit.app" ] || fail "$dmg has no FocusEdit.app"

if [ -d "$app" ]; then
  trashed="$HOME/.Trash/FocusEdit $(plist CFBundleShortVersionString "$app") (build $(plist CFBundleVersion "$app")).app"
  [ -e "$trashed" ] && trashed="${trashed%.app} $(date +%H%M%S).app"
  mv "$app" "$trashed"
fi
ditto "$mount/FocusEdit.app" "$app"
codesign --verify --deep --strict "$app" || fail "the installed app's signature does not verify"

touch "$app"
"$lsregister" -f "$app"
# A copy Launch Services never registered answers -10814 (not found): nothing to forget.
for stale in "$HOME"/.Trash/FocusEdit*.app; do
  [ -d "$stale" ] && { "$lsregister" -u "$stale" >/dev/null 2>&1 || true; }
done
killall Dock
open "$app"
echo "Installed FocusEdit $(plist CFBundleShortVersionString "$app") (build $(plist CFBundleVersion "$app")) and restarted the Dock."
echo "Older copies are in the Trash; empty it when you no longer need them."
