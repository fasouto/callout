#!/bin/sh
# Builds the app and launches it. With a file, opens that file for review.
#
#     scripts/run.sh                      just the menu-bar icon
#     scripts/run.sh docs/sample-plan.md  with a review window
#
# Signs ad hoc, so no Apple ID is needed. For a signature that keeps the
# Accessibility permission between builds, run from Xcode with your team instead.
set -e
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project Annotator.xcodeproj -scheme Annotator -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build \
  | grep -E '^\*\* BUILD|error:' || true

app="$PWD/build/DerivedData/Build/Products/Debug/Annotator.app"
[ -d "$app" ] || { echo "The build did not produce $app" >&2; exit 1; }

# One copy serves every request, so a running one has to go first.
pkill -f "Annotator.app/Contents/MacOS/Annotator" 2>/dev/null && sleep 0.5 || true

if [ -n "$1" ]; then
  file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  open "$app" --args --review "$file"
else
  open "$app"
fi
echo "Annotator is running: look for the pencil icon in the menu bar."
