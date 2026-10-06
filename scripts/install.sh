#!/bin/sh
# Builds a release copy of Annotator and installs it in /Applications.
#
#     scripts/install.sh
#
# Replaces an installed copy, quits any running one, and opens the new one.
# The Claude Code plugin finds the app there by itself.
set -e
cd "$(dirname "$0")/.."
. scripts/signing.sh

xcodegen generate >/dev/null
xcodebuild -project Annotator.xcodeproj -scheme Annotator -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" build \
  | grep -E '^\*\* BUILD|error:' || true

built="$PWD/build/DerivedData/Build/Products/Release/Annotator.app"
[ -d "$built" ] || { echo "The build did not produce $built" >&2; exit 1; }
codesign --verify --deep --strict "$built"

pkill -f "Annotator.app/Contents/MacOS/Annotator" 2>/dev/null && sleep 0.5 || true

target=/Applications/Annotator.app
rm -rf "$target"
ditto "$built" "$target"

# Development builds would otherwise answer annotator:// links and the Share
# menu as well; the installed copy is the one macOS should use.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in build/DerivedData/Build/Products/Debug/Annotator.app "$built"; do
  [ -d "$copy" ] && "$lsregister" -u "$PWD/$copy" 2>/dev/null || true
done
"$lsregister" -f "$target"

open "$target"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$target/Contents/Info.plist")
echo "Annotator $version is installed in /Applications and running."
if [ "$identity" = - ]; then
  echo "Signed ad hoc: allow Accessibility again if the shortcut asks."
fi
