#!/bin/sh
# Builds a notarized, stapled Callout-<version>.dmg in build/release/.
#
#     scripts/release.sh
#
# Needs a "Developer ID Application" certificate in your keychain and a
# notarytool keychain profile (CALLOUT_NOTARY_PROFILE, default callout-notary).
# It checks both before building. Never installs or launches anything.
#
# The app is notarized and stapled first, then the DMG that holds it, so the
# app still opens offline after it is dragged out of the DMG.
set -e
cd "$(dirname "$0")/.."

profile=${CALLOUT_NOTARY_PROFILE:-callout-notary}
cert_kind="Developer ID Application"
. scripts/signing.sh

if [ "$identity" = - ]; then
  cat >&2 <<EOF
No "$cert_kind" certificate in your keychain.
Create it in Xcode: Settings, Accounts, select the paid team (not "Personal
Team"), Manage Certificates, +, Developer ID Application.
EOF
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  cat >&2 <<EOF
No working notarytool keychain profile named "$profile".
Create an app-specific password at account.apple.com, then run in Terminal:
  xcrun notarytool store-credentials $profile --apple-id <Apple ID> --team-id <Team ID>
To use another profile name, set CALLOUT_NOTARY_PROFILE.
EOF
  exit 1
fi

command -v xcodegen >/dev/null || { echo "xcodegen is missing. Install it with: brew install xcodegen" >&2; exit 1; }

# Submits a file, waits, and on anything but Accepted prints Apple's log.
notarize() {
  result=$(mktemp)
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json >"$result" || true
  id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
  rm -f "$result"
  if [ "$status" != Accepted ]; then
    echo "Notarization of $1 ended as: ${status:-no answer from Apple}" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
    exit 1
  fi
}

xcodegen generate >/dev/null
# OTHER_CODE_SIGN_FLAGS reaches Xcode's own signing and the helper's build phase.
xcodebuild -project Callout.xcodeproj -scheme Callout -configuration Release \
  -derivedDataPath build/ReleaseDerivedData \
  CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" \
  OTHER_CODE_SIGN_FLAGS=--timestamp build \
  | grep -E '^\*\* BUILD|error:' || true

app="$PWD/build/ReleaseDerivedData/Build/Products/Release/Callout.app"
[ -d "$app" ] || { echo "The build did not produce $app" >&2; exit 1; }

codesign --verify --deep --strict "$app"
for part in "$app" "$app/Contents/Helpers/callout" "$app"/Contents/PlugIns/*.appex; do
  info=$(codesign -dvv "$part" 2>&1)
  echo "$info" | grep -q 'flags=0x10000(runtime)' \
    || { echo "$part is not signed with the hardened runtime." >&2; exit 1; }
  echo "$info" | grep -q '^Timestamp=' \
    || { echo "$part has no secure timestamp." >&2; exit 1; }
done

out="$PWD/build/release"
mkdir -p "$out"
zip="$out/Callout.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
rm -f "$zip"
xcrun stapler staple "$app"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$out/Callout-$version.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Callout.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname Callout -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null

codesign --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

xcrun stapler validate "$dmg"
spctl -a -t open --context context:primary-signature -vv "$dmg"
mount=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
spctl -a -t exec -vv "$mount/Callout.app" || { hdiutil detach "$mount" >/dev/null; exit 1; }
hdiutil detach "$mount" >/dev/null
echo "Callout $version: $dmg"
