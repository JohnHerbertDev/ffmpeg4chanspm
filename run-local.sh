#!/usr/bin/env bash
# run-local.sh — manual entry point for local builds / iteration.
# Requires: macOS, Xcode + command line tools, git, swift.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for tool in xcodebuild git clang libtool lipo; do
  command -v "${tool}" >/dev/null 2>&1 \
    || { echo "Missing: ${tool}. Install Xcode and Xcode Command Line Tools."; exit 1; }
done

echo "Starting FFmpeg 4chan transcode build..."
./build-ffmpeg-4chan.sh

echo ""
echo "While iterating locally, use a path-based binaryTarget in Package.swift:"
echo "  .binaryTarget(name: \"FFmpeg4chan\", path: \"./output/FFmpeg4chan.xcframework\")"
echo ""
echo "Transcode pipeline reminder:"
echo "  WebM (VP8/VP9 + Vorbis/Opus) → MP4 (h264_videotoolbox + aac_at)"
echo "  OGG  (Vorbis)                → M4A (aac_at)"
echo "  Everything else              → URLSession download, AVFoundation playback"
