#!/bin/sh
# Redraws the screenshots in the README from the window tests, which draw every
# window off screen at two pixels a point.
#
#     scripts/screenshots.sh
set -e
cd "$(dirname "$0")/.."

out=$(mktemp -d)
# Quiet unless a test fails: then the screenshots are not to be trusted.
(cd Packages/AnnotatorKit && ANNOTATOR_SNAPSHOT_DIR="$out" swift test >"$out/tests.log" 2>&1) || {
  tail -20 "$out/tests.log" >&2
  exit 1
}

cp "$out/review-marked-light.png" docs/review-window.png
cp "$out/review-marked-dark.png" docs/review-window-dark.png
cp "$out/welcome-light.png" docs/first-review.png
cp "$out/history.png" docs/history.png
cp "$out/plan-changes.png" docs/plan-changes.png
echo "Redrew the screenshots in docs/. Every window, in light and dark, is in $out"
