# FFmpeg4chan — CLAUDE.md

Project context for Claude Code. Read this before touching any file.

---

## What this project is

A build system that compiles a **minimal FFmpeg** from source into an
`XCFramework` for iOS, containing only the codecs needed to transcode
4chan media files that iOS/AVFoundation cannot play natively.

This is **not** a playback library. FFmpeg here is a transcode step only.
Actual playback is handled by AVFoundation after conversion.

---

## The transcode pipeline

```
URLSession.downloadTask()        ← download any 4chan file (raw bytes, no FFmpeg)
         ↓
file extension / MIME check
  .webm  →  FFmpeg  →  .mp4     VP8/VP9 + Vorbis/Opus  →  H.264 + AAC
  .ogg   →  FFmpeg  →  .m4a     Vorbis                 →  AAC
  else   →  save as-is          MP4/MP3/FLAC/GIF/images are AVFoundation-native
         ↓
AVPlayer / AVAudioPlayer         ← all output is now iOS-native
```

URLSession handles all downloading. FFmpeg is never used for network I/O.

---

## Codec scope — why these and nothing else

| Module | Type | Reason included |
|---|---|---|
| `matroska` | demuxer | WebM is a strict subset of Matroska |
| `ogg` | demuxer | OGG audio container |
| `vp8` | decoder | WebM video, older boards |
| `vp9` | decoder | WebM video, newer/higher quality |
| `vorbis` | decoder | WebM + OGG audio, older |
| `opus` | decoder | WebM audio, newer |
| `vp8/vp9/vorbis/opus` | parsers | Frame boundary + keyframe detection |
| `h264_videotoolbox` | encoder | Apple hardware H.264 — no libx264 bundled |
| `aac_at` | encoder | Apple hardware AAC — no libfdk_aac bundled |
| `h264/aac` | parsers | Correct output container framing |
| `mp4` | muxer | Output container for video |
| `ipod` | muxer | iOS-compatible MP4 atom flags (use this, not plain mp4, for AVFoundation) |
| `m4a` | muxer | Output container for audio-only |
| `videotoolbox` | hw accel | VideoToolbox framework hook |
| `audiotoolbox` | hw accel | AudioToolbox framework hook |
| `file` | protocol | Local file I/O only |

**Do not add encoders or decoders beyond this list without updating this file.**
Every addition increases binary size and app review surface area.

---

## Encoder strategy

Encoders use **Apple hardware APIs only** (`h264_videotoolbox`, `aac_at`).

- No libx264 → no GPL licensing complications
- No libfdk_aac → no additional license requirements  
- Hardware-accelerated on device → fast, low battery drain
- Both are iOS system frameworks; FFmpeg calls them, they are not bundled

⚠️ **Intel simulator (x86_64) caveat**: `h264_videotoolbox` and `aac_at`
are unavailable or severely limited on x86_64 simulator slices. The x86_64
slice is included for UI layout testing only. Always test transcoding on a
real device or Apple Silicon Mac simulator (arm64).

⚠️ **Resolution constraint**: `h264_videotoolbox` requires output dimensions
to be multiples of 16. Some 4chan WebM files have odd resolutions. Add a
`scale` filter if you hit `invalid pixel format` errors:
- Enable `--enable-filter=scale` and `--enable-filter=format` in `ENABLE_FLAGS`
- Apply `vf scale=trunc(iw/16)*16:trunc(ih/16)*16` before the video encoder

---

## Build targets

| Slice | SDK | Arch |
|---|---|---|
| iOS device | `iphoneos` | `arm64` |
| iOS Simulator (Apple Silicon) | `iphonesimulator` | `arm64` |
| iOS Simulator (Intel Mac) | `iphonesimulator` | `x86_64` |

Minimum deployment target: **iOS 13.0**

---

## Files

```
build-ffmpeg-4chan.sh          Core build script — clone, verify, compile, package
run-local.sh                   Local wrapper with preflight tool checks
.github/workflows/
  build-ffmpeg.yml             GitHub Actions: weekly + manual trigger, publishes release
Package.swift                  SPM package — update url+checksum after each CI run
output/                        Build artifacts (gitignored)
  FFmpeg4chan.xcframework
  FFmpeg4chan.xcframework.zip
  FFmpeg4chan.xcframework.zip.sha256
.build/                        Intermediate build files (gitignored)
```

---

## Build system behaviour

### Fail-loud guarantee
`verify_flags()` in `build-ffmpeg-4chan.sh` runs `./configure --list-decoders`
(and equivalent for demuxers, encoders, muxers, protocols) against the freshly
cloned FFmpeg checkout **before any compilation starts**. If any flag in
`ENABLE_FLAGS` is no longer recognised, the script aborts with a clear error
listing which flags broke. This prevents silent unstripped or broken builds.

If `verify_flags()` fails after a routine update:
1. Check the FFmpeg changelog / `configure --list-decoders` manually
2. Find the new name for the renamed/split module
3. Update `ENABLE_FLAGS` in `build-ffmpeg-4chan.sh`
4. Re-run

### `--disable-asm` is intentional
FFmpeg's NEON assembly is disabled for cross-compilation reliability across
Xcode versions. Once you confirm end-to-end builds work, remove `--disable-asm`
from `build_slice()` for a ~10–20% decode speed improvement.

### `ipod` muxer vs `mp4` muxer
Always use `ipod` (not `mp4`) as the output muxer for video files destined
for AVFoundation. The `ipod` muxer sets the `isom`/`iso2` compatible brands
and moves the `moov` atom before `mdat`, which AVFoundation requires to begin
playback before the full file is read.

---

## CI / GitHub Actions

Workflow: `.github/workflows/build-ffmpeg.yml`
- Runs weekly (Tuesday 06:00 UTC) + on manual dispatch
- Uses `macos-15` runner with `Xcode_16`
- Fails the job if `verify_flags()` or compilation fails → no release published
- On success: publishes a GitHub Release with `.zip` and `.sha256` assets
- Build log prints the exact `Package.swift` snippet to paste

After each successful CI run:
1. Copy the `url` and `checksum` from the build log
2. Update `Package.swift` in this repo
3. Commit — SPM consumers will pick up the new build on next resolve

---

## SPM integration

**Remote (production):**
```swift
.binaryTarget(
    name: "FFmpeg4chan",
    url: "https://github.com/<org>/<repo>/releases/download/<tag>/FFmpeg4chan.xcframework.zip",
    checksum: "<sha256>"
)
```

**Local (during development / iterating on codec flags):**
```swift
.binaryTarget(
    name: "FFmpeg4chan",
    path: "./output/FFmpeg4chan.xcframework"
)
```

---

## Known gotchas

- **`--disable-autodetect` is critical.** Without it, FFmpeg's configure will
  silently enable codecs based on whatever libraries happen to be installed on
  the build machine, producing non-reproducible and potentially over-fat builds.

- **`libtool` not `ar`** is used to merge static archives. On macOS, `ar` can
  produce archives with duplicate symbols when merging multiple `.a` files from
  FFmpeg's split library structure (`libavcodec`, `libavformat`, etc.). `libtool
  -static` handles this correctly.

- **Build order matters for `make clean`.** The script calls `make clean` after
  each slice install to reset FFmpeg's in-tree build artifacts before configuring
  the next architecture. Do not remove these `clean` calls or subsequent slices
  will pick up artifacts from the previous arch.

- **`-fembed-bitcode`** is included in `extra_cflags`. Remove this if you target
  iOS 17+ only (Apple deprecated bitcode in Xcode 14; it's a no-op on newer
  toolchains but harmless).
