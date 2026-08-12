#!/usr/bin/env bash
#
# build-ffmpeg-4chan.sh
#
# Builds a minimal FFmpeg.xcframework for iOS that handles the
# download-and-convert pipeline for 4chan media:
#
#   WebM (VP8/VP9 + Vorbis/Opus)  →  MP4 (H.264 + AAC)
#   OGG  (Vorbis)                 →  M4A (AAC)
#
# Everything else 4chan serves (MP4, MP3, FLAC, GIF, images) is downloaded
# as-is via URLSession and played natively by AVFoundation — FFmpeg never
# touches those.
#
# Encoder strategy: uses Apple's own hardware encoder APIs (VideoToolbox for
# H.264, AudioToolbox for AAC) rather than bundling libx264/libfdk_aac.
# Benefits:
#   - No GPL/LGPL complications from bundling encoder libs
#   - Hardware-accelerated on real devices (fast, low battery)
#   - Keeps the FFmpeg binary tiny (~3-5 MB)
#
# ⚠️  Hardware encoder caveat: h264_videotoolbox and aac_at are iOS system
# frameworks. They work on real devices and Apple Silicon simulators (arm64)
# but are limited or unavailable on Intel Mac simulators (x86_64). The
# x86_64 simulator slice is included for UI dev/testing — transcode calls
# will fail gracefully on that slice. Real device builds are unaffected.
#
# Targets:
#   iOS device      — arm64
#   iOS Simulator   — arm64 (Apple Silicon Mac) + x86_64 (Intel Mac)
#
# Fail-loud guarantee: every codec flag is verified against this checkout's
# configure output BEFORE compilation starts. If upstream renames/removes a
# module we abort rather than silently producing a broken or wrong build.
#
# Usage:
#   ./build-ffmpeg-4chan.sh
#
# Output:
#   ./output/FFmpeg4chan.xcframework
#   ./output/FFmpeg4chan.xcframework.zip
#   ./output/FFmpeg4chan.xcframework.zip.sha256
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${ROOT_DIR}/.build"
SRC_DIR="${WORK_DIR}/ffmpeg"
OUT_DIR="${ROOT_DIR}/output"
INTERMEDIATES_DIR="${WORK_DIR}/intermediates"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

IOS_MIN_VERSION="13.0"

# ---------------------------------------------------------------------------
# Input side — demux/decode the formats 4chan serves that iOS cannot play
# ---------------------------------------------------------------------------
INPUT_FLAGS=(
  --enable-demuxer=matroska     # WebM (.webm) container — VP8/VP9 video
  --enable-demuxer=ogg          # OGG (.ogg) container — Vorbis audio

  --enable-decoder=vp8          # WebM video (older boards)
  --enable-decoder=vp9          # WebM video (newer boards, higher quality)
  --enable-decoder=vorbis       # WebM/OGG audio (older)
  --enable-decoder=opus         # WebM audio (newer)

  --enable-parser=vp8           # frame boundary / keyframe detection
  --enable-parser=vp9
  --enable-parser=vorbis
  --enable-parser=opus
)

# ---------------------------------------------------------------------------
# Output side — encode/mux to formats iOS plays natively
# ---------------------------------------------------------------------------
OUTPUT_FLAGS=(
  --enable-muxer=mp4            # output container for video (WebM → MP4)
  --enable-muxer=ipod           # iOS-compatible MP4 variant (correct atom flags)
  --enable-muxer=m4a            # output container for audio-only (OGG → M4A)

  --enable-encoder=h264_videotoolbox  # Apple hardware H.264 (VideoToolbox)
  --enable-encoder=aac_at             # Apple hardware AAC  (AudioToolbox)

  --enable-parser=h264          # needed for correct MP4 output framing
  --enable-parser=aac

  --enable-videotoolbox         # VideoToolbox framework hook
  --enable-audiotoolbox         # AudioToolbox framework hook
)

PROTOCOL_FLAGS=(
  --enable-protocol=file        # local file I/O only — URLSession does the download
)

ENABLE_FLAGS=(
  "${INPUT_FLAGS[@]}"
  "${OUTPUT_FLAGS[@]}"
  "${PROTOCOL_FLAGS[@]}"
)

# ---------------------------------------------------------------------------
# Flags applied to ALL configure invocations
# ---------------------------------------------------------------------------
COMMON_FLAGS=(
  --disable-everything          # hard zero baseline — only what's listed above
  --disable-programs
  --disable-doc
  --disable-htmlpages
  --disable-manpages
  --disable-podpages
  --disable-txtpages
  --disable-debug
  --disable-shared
  --enable-static
  --disable-autodetect
  --disable-iconv
  --disable-bzlib
  --disable-zlib
  --disable-lzma
  --disable-sdl2
  --disable-xlib
  --disable-network
  "${ENABLE_FLAGS[@]}"
)

# ---------------------------------------------------------------------------
# 1. Clone latest FFmpeg master
# ---------------------------------------------------------------------------
clone_latest() {
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}" "${INTERMEDIATES_DIR}"
  log "Cloning FFmpeg master..."
  git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git "${SRC_DIR}"
  log "FFmpeg HEAD: $(git -C "${SRC_DIR}" rev-parse HEAD)"
}

# ---------------------------------------------------------------------------
# 2. Verify every flag against this checkout before spending time compiling
# ---------------------------------------------------------------------------
verify_flags() {
  log "Verifying codec flags against this FFmpeg checkout..."

  local missing=()

  for flag in "${ENABLE_FLAGS[@]}"; do
    local stripped="${flag#--enable-}"
    local feature="${stripped%%=*}"   # e.g. demuxer, decoder, encoder
    local value="${stripped#*=}"      # e.g. matroska, vp8

    if [[ "${value}" == "${feature}" ]]; then
      # Bare flag e.g. --enable-videotoolbox
      if ! "${SRC_DIR}/configure" --help 2>&1 | grep -qF -- "--enable-${feature}"; then
        missing+=("--enable-${feature}  (not found in configure --help)")
      fi
    else
      # Component flag e.g. --enable-decoder=vp8
      if ! "${SRC_DIR}/configure" "--list-${feature}s" 2>/dev/null | grep -qx "${value}"; then
        missing+=("--enable-${feature}=${value}  (${value} not in --list-${feature}s)")
      fi
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf '\033[1;31m[FAIL]\033[0m The following flags are no longer valid in this FFmpeg checkout.\n' >&2
    printf 'Upstream likely renamed or removed a codec/muxer/encoder.\n' >&2
    printf 'Update ENABLE_FLAGS in this script before rebuilding:\n\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi

  log "All ${#ENABLE_FLAGS[@]} flags verified OK."
}

# ---------------------------------------------------------------------------
# 3. Build one static library slice
#    $1=arch (arm64|x86_64)  $2=sdk (iphoneos|iphonesimulator)  $3=out prefix
# ---------------------------------------------------------------------------
build_slice() {
  local arch="$1"
  local sdk="$2"
  local out_dir="$3"

  local sdk_path
  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

  local target_triple
  if [[ "${sdk}" == "iphoneos" ]]; then
    target_triple="${arch}-apple-ios${IOS_MIN_VERSION}"
  else
    target_triple="${arch}-apple-ios${IOS_MIN_VERSION}-simulator"
  fi

  local cc
  cc="$(xcrun --sdk "${sdk}" --find clang)"

  local extra_cflags="-arch ${arch} -target ${target_triple} -isysroot ${sdk_path} -mios-version-min=${IOS_MIN_VERSION} -fembed-bitcode"
  local extra_ldflags="-arch ${arch} -target ${target_triple} -isysroot ${sdk_path}"
  # System frameworks for VideoToolbox + AudioToolbox hardware encoders
  extra_ldflags+=" -framework VideoToolbox -framework AudioToolbox -framework CoreFoundation -framework CoreMedia -framework CoreVideo"

  mkdir -p "${out_dir}"
  log "Configuring: arch=${arch} sdk=${sdk}"

  (
    cd "${SRC_DIR}"
    ./configure \
      --prefix="${out_dir}" \
      --target-os=darwin \
      --arch="${arch}" \
      --cc="${cc}" \
      --extra-cflags="${extra_cflags}" \
      --extra-ldflags="${extra_ldflags}" \
      --disable-asm \
      "${COMMON_FLAGS[@]}"
  )

  log "Compiling: arch=${arch} sdk=${sdk} (takes a few minutes)..."
  make -C "${SRC_DIR}" -j"$(sysctl -n hw.logicalcpu)" install
  make -C "${SRC_DIR}" clean
}

# ---------------------------------------------------------------------------
# 4. Build all slices and assemble xcframework
# ---------------------------------------------------------------------------
build_xcframework() {
  local device_arm64="${INTERMEDIATES_DIR}/device-arm64"
  local sim_arm64="${INTERMEDIATES_DIR}/sim-arm64"
  local sim_x86_64="${INTERMEDIATES_DIR}/sim-x86_64"
  local sim_fat="${INTERMEDIATES_DIR}/sim-fat"

  build_slice arm64  iphoneos        "${device_arm64}"
  build_slice arm64  iphonesimulator "${sim_arm64}"
  build_slice x86_64 iphonesimulator "${sim_x86_64}"

  log "Merging simulator slices (arm64 + x86_64) with lipo..."
  mkdir -p "${sim_fat}/lib"

  local libs=()
  while IFS= read -r -d '' f; do
    libs+=("$(basename "${f}")")
  done < <(find "${device_arm64}/lib" -name "*.a" -print0)

  for libname in "${libs[@]}"; do
    lipo -create \
      "${sim_arm64}/lib/${libname}" \
      "${sim_x86_64}/lib/${libname}" \
      -output "${sim_fat}/lib/${libname}"
  done

  cp -R "${device_arm64}/include" "${sim_fat}/include"

  local fw_device="${INTERMEDIATES_DIR}/device.framework"
  local fw_sim="${INTERMEDIATES_DIR}/simulator.framework"

  assemble_framework "${device_arm64}" "${fw_device}"
  assemble_framework "${sim_fat}"      "${fw_sim}"

  log "Creating XCFramework..."
  rm -rf "${OUT_DIR}/FFmpeg4chan.xcframework"
  mkdir -p "${OUT_DIR}"

  xcodebuild -create-xcframework \
    -framework "${fw_device}" \
    -framework "${fw_sim}" \
    -output "${OUT_DIR}/FFmpeg4chan.xcframework"

  log "XCFramework built: ${OUT_DIR}/FFmpeg4chan.xcframework"
}

# ---------------------------------------------------------------------------
# Helper: flatten all libav*.a into a single .framework bundle
# ---------------------------------------------------------------------------
assemble_framework() {
  local prefix="$1"
  local fw_path="$2"
  local fw_name="FFmpeg4chan"

  rm -rf "${fw_path}"
  mkdir -p "${fw_path}/Headers"

  local all_archives=()
  while IFS= read -r -d '' f; do
    all_archives+=("${f}")
  done < <(find "${prefix}/lib" -name "*.a" -print0)

  # libtool avoids symbol duplication issues that plain `ar` has on macOS
  libtool -static -o "${fw_path}/${fw_name}" "${all_archives[@]}"

  cp -R "${prefix}/include/"* "${fw_path}/Headers/"

  cat > "${fw_path}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>  <string>${fw_name}</string>
  <key>CFBundleIdentifier</key> <string>org.ffmpeg.${fw_name}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key>    <string>1.0</string>
  <key>MinimumOSVersion</key>   <string>${IOS_MIN_VERSION}</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# 5. Package for SPM
# ---------------------------------------------------------------------------
package() {
  cd "${OUT_DIR}"
  log "Zipping xcframework..."
  rm -f FFmpeg4chan.xcframework.zip
  zip -r -y -q FFmpeg4chan.xcframework.zip FFmpeg4chan.xcframework

  log "Computing SPM checksum..."
  swift package compute-checksum FFmpeg4chan.xcframework.zip > FFmpeg4chan.xcframework.zip.sha256 \
    || shasum -a 256 FFmpeg4chan.xcframework.zip | awk '{print $1}' > FFmpeg4chan.xcframework.zip.sha256

  log ""
  log "✅ Build complete."
  log "   xcframework : ${OUT_DIR}/FFmpeg4chan.xcframework"
  log "   zip         : ${OUT_DIR}/FFmpeg4chan.xcframework.zip"
  log "   checksum    : $(cat FFmpeg4chan.xcframework.zip.sha256)"
}

main() {
  clone_latest
  verify_flags
  build_xcframework
  package
}

main "$@"
