#!/bin/sh
# Builds the app and launches it. With a file, opens that file for review.
#
#     scripts/run.sh                      just the menu-bar icon
#     scripts/run.sh docs/sample-plan.md  with a review window
#
# A development build, run from the build folder. scripts/install.sh puts a
# release build in /Applications instead.
set -e
cd "$(dirname "$0")/.."
. scripts/signing.sh

xcodegen generate >/dev/null
xcodebuild -project Callout.xcodeproj -scheme Callout -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" build \
  | grep -E '^\*\* BUILD|error:' || true

app="$PWD/build/DerivedData/Build/Products/Debug/Callout.app"
[ -d "$app" ] || { echo "The build did not produce $app" >&2; exit 1; }

# One copy serves every request, so a running one has to go first.
pkill -f "Callout.app/Contents/MacOS/Callout" 2>/dev/null && sleep 0.5 || true

if [ -n "$1" ]; then
  file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  open "$app" --args --review "$file"
else
  open "$app"
fi
if [ "$identity" = - ]; then
  echo "Signed ad hoc: allow Accessibility again for this build if the shortcut asks."
fi
echo "Callout is running: look for its icon in the menu bar, a rounded square with lines in it."
