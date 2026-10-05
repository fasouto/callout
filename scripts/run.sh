#!/bin/sh
# Builds the app and launches it. With a file, opens that file for review.
#
#     scripts/run.sh                      just the menu-bar icon
#     scripts/run.sh docs/sample-plan.md  with a review window
#
# Signs with your Apple Development certificate when there is one, so macOS
# keeps the Accessibility permission from one build to the next. Without one
# it signs ad hoc, and every build has to be allowed again.
set -e
cd "$(dirname "$0")/.."

identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
if [ -n "$identity" ]; then
  # The team is the certificate's organisational unit.
  team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline \
    | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)
else
  identity=-
  team=
fi

xcodegen generate >/dev/null
xcodebuild -project Annotator.xcodeproj -scheme Annotator -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" build \
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
if [ "$identity" = - ]; then
  echo "Signed ad hoc: allow Accessibility again for this build if the shortcut asks."
fi
echo "Annotator is running: look for its icon in the menu bar, a rounded square with lines in it."
