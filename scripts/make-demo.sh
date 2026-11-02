#!/bin/sh
# Redraws the demo in docs/ from the window tests: the storyboard in
# DemoVideoTests.swift replays a review on the real window and writes frames,
# and ffmpeg turns them into docs/demo.mp4 (for uploading to GitHub's editor)
# and docs/demo.gif (shown inline from the repo). Needs ffmpeg.
#
#     scripts/make-demo.sh
set -e
cd "$(dirname "$0")/.."

out=$(mktemp -d)
(cd Packages/CalloutKit && CALLOUT_DEMO_DIR="$out/frames" swift test --filter DemoVideoTests >"$out/tests.log" 2>&1) || {
  tail -20 "$out/tests.log" >&2
  exit 1
}

# The frames list holds each picture once, with how long it shows. fps=30 spreads that out.
frames="-loglevel error -y -f concat -safe 0 -i $out/frames/frames.txt"
ffmpeg $frames -vf "fps=30,scale=1280:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset veryslow -crf 22 -movflags +faststart docs/demo.mp4
# A GIF came out half the size of an animated WebP of the same frames.
ffmpeg $frames -vf "fps=25,scale=1280:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "Redrew docs/demo.mp4 and docs/demo.gif. The frames are in $out/frames"
