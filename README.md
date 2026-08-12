# FFmpeg4chan

A minimal FFmpeg build system for iOS that transcodes 4chan media files
that iOS cannot play natively into formats AVFoundation understands.

**Adds ~3–6 MB to your IPA.** Builds from FFmpeg `master` on a weekly
schedule so you always ship the latest decoder fixes.

---

## How it works

iOS cannot play WebM or OGG files. This library transcodes them on-device
to formats iOS handles natively, using Apple's own hardware encoders
(VideoToolbox for H.264, AudioToolbox for AAC — no libx264 bundled).

```
URLSession.downloadTask()        ← download any 4chan file
         ↓
file extension check
  .webm  →  FFmpeg  →  .mp4     VP8/VP9 + Vorbis/Opus  →  H.264 + AAC
  .ogg   →  FFmpeg  →  .m4a     Vorbis                 →  AAC
  else   →  save as-is          MP4, MP3, FLAC, GIF, images are iOS-native
         ↓
AVPlayer / AVAudioPlayer
```

URLSession handles all downloading. FFmpeg only touches the two formats iOS
can't play. Everything else goes straight to disk.

---

## Codec scope

| Module | Type | Purpose |
|---|---|---|
| `matroska` | demuxer | WebM + MKV container |
| `ogg` | demuxer | OGG container |
| `vp8`, `vp9` | decoder | WebM video |
| `vorbis`, `opus` | decoder | WebM + OGG audio |
| `h264_videotoolbox` | encoder | Apple hardware H.264 |
| `aac_at` | encoder | Apple hardware AAC |
| `mp4`, `ipod` | muxer | iOS-compatible video output |
| `m4a` | muxer | iOS-compatible audio output |
| `file` | protocol | Local file I/O only |

Everything else — H.264 decode, HEVC, AAC decode, MP3, subtitle codecs,
network protocols, filters, encoders — is disabled at compile time via
`--disable-everything`. The binary contains only what is listed above.

---

## Requirements

### Local builds
- macOS 13 or later
- Xcode 15 or later with Command Line Tools (`xcode-select --install`)
- Git

### GitHub Actions
- A GitHub repository with Actions enabled
- `GITHUB_TOKEN` write permissions for releases (configured automatically
  for Actions in public repos; see [setup](#github-setup) for private repos)

---

## GitHub Setup

### 1. Create a new repository

Go to [github.com/new](https://github.com/new) and create a repository.
Name it something like `FFmpeg4chan` or `ffmpeg-ios-4chan`.
You can make it private — Actions and Releases both work on private repos.

### 2. Add the files

Clone your new repo and copy in the project files:

```bash
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>

# Copy in the project files
cp /path/to/build-ffmpeg-4chan.sh .
cp /path/to/run-local.sh .
cp /path/to/Package.swift .
cp /path/to/CLAUDE.md .
mkdir -p .github/workflows
cp /path/to/build-ffmpeg.yml .github/workflows/
```

### 3. Add a .gitignore

```bash
cat > .gitignore << 'EOF'
.build/
output/
*.xcframework
*.zip
*.sha256
EOF
```

### 4. Configure Actions permissions

In your repo on GitHub:
1. Go to **Settings → Actions → General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Check **Allow GitHub Actions to create and approve pull requests**
4. Click **Save**

This allows the workflow to publish GitHub Releases.

### 5. Push

```bash
git add .
git commit -m "Initial FFmpeg4chan build system"
git push origin main
```

### 6. Run the workflow manually (first build)

1. Go to your repo on GitHub
2. Click the **Actions** tab
3. Select **Build FFmpeg (4chan transcode)** from the left sidebar
4. Click **Run workflow → Run workflow**

The first build takes ~45–60 minutes. When it completes:
- A GitHub Release is published with `FFmpeg4chan.xcframework.zip` and
  `FFmpeg4chan.xcframework.zip.sha256` as assets
- The build log (expand the **Print Package.swift snippet** step) shows
  the exact `url` and `checksum` to paste into `Package.swift`

### 7. Update Package.swift

Open `Package.swift` and replace the placeholder values:

```swift
.binaryTarget(
    name: "FFmpeg4chan",
    url: "https://github.com/<your-username>/<your-repo>/releases/download/<tag>/FFmpeg4chan.xcframework.zip",
    checksum: "<sha256-from-build-log>"
)
```

Commit and push. Downstream SPM consumers will resolve the new version on
next package update.

---

## Local builds

Use the local build for iterating on codec flags without burning CI minutes.

```bash
# Make the scripts executable (only needed once)
chmod +x build-ffmpeg-4chan.sh run-local.sh

# Run the build (~45–60 minutes on a modern Mac)
./run-local.sh
```

Output lands in `./output/`:
```
output/
  FFmpeg4chan.xcframework       ← point Package.swift path target here
  FFmpeg4chan.xcframework.zip
  FFmpeg4chan.xcframework.zip.sha256
```

**While iterating locally**, use a `path`-based `binaryTarget` in your app's
`Package.swift` so you don't need a published release:

```swift
.binaryTarget(
    name: "FFmpeg4chan",
    path: "./output/FFmpeg4chan.xcframework"
)
```

Switch back to a `url`-based target before shipping.

---

## Adding to your iOS app

### Via Swift Package Manager (Xcode)

1. In Xcode: **File → Add Package Dependencies**
2. Enter your repo URL: `https://github.com/<your-username>/<your-repo>`
3. Select the version rule you want (exact version recommended for binary targets)
4. Add **FFmpeg4chan** to your app target

### Via Package.swift (if your app is also SPM-based)

```swift
dependencies: [
    .package(url: "https://github.com/<your-username>/<your-repo>", from: "<tag>")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["FFmpeg4chan"]
    )
]
```

---

## Using FFmpeg in your app

FFmpeg4chan exposes the standard FFmpeg C API. A minimal Swift transcode
call looks like this (you will need a bridging header or a separate C/ObjC
wrapper module to call the C API cleanly from Swift):

```swift
import FFmpeg4chan

func needsTranscode(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "webm" || ext == "ogg"
}

func outputURL(for inputURL: URL) -> URL {
    let ext = inputURL.pathExtension.lowercased()
    let outExt = ext == "ogg" ? "m4a" : "mp4"
    return inputURL.deletingPathExtension().appendingPathExtension(outExt)
}
```

> For a complete Swift/ObjC FFmpeg transcode wrapper, see the FFmpeg
> iOS integration guides at [ffmpeg.org](https://ffmpeg.org/documentation.html).
> The C API entry points you need are `avformat_open_input`,
> `avcodec_find_decoder`, `avcodec_find_encoder_by_name` (`h264_videotoolbox`
> / `aac_at`), and `avformat_write_header` / `av_interleaved_write_frame`.

---

## Known limitations

- **Intel Mac simulator (x86_64):** `h264_videotoolbox` and `aac_at` are
  Apple system encoders not available on Intel simulator slices. Transcoding
  will fail on the x86_64 simulator. Always test on a real device or an
  Apple Silicon Mac running the arm64 simulator.

- **Odd video resolutions:** `h264_videotoolbox` requires dimensions that
  are multiples of 16. Some 4chan WebM files have odd resolutions and will
  produce an error. Add a `scale=trunc(iw/16)*16:trunc(ih/16)*16` filter
  if you hit this. This requires enabling `--enable-filter=scale` and
  `--enable-filter=format` in `ENABLE_FLAGS` in `build-ffmpeg-4chan.sh`.

- **Build breaks after FFmpeg upstream changes:** `verify_flags()` will
  catch this and fail with a clear error message listing which codec/muxer
  names changed. Update `ENABLE_FLAGS` in `build-ffmpeg-4chan.sh` and re-run.

---

## Scheduled builds

The GitHub Actions workflow runs automatically every **Tuesday at 06:00 UTC**,
cloning the latest FFmpeg `master` and publishing a new release if the build
succeeds. Each release tag embeds the FFmpeg commit SHA so you can always
trace exactly which upstream commit shipped.

You still need to manually update `Package.swift` with the new release URL
and checksum after each automated build — SPM binary targets pin to an
explicit checksum and will not auto-update.

---

## License

FFmpeg is licensed under the **LGPL 2.1** (with the configuration used here —
no GPL-only components like libx264 are enabled). Your app must comply with
LGPL requirements, which for a static-linked iOS framework means you must:

1. Provide a way for users to relink with a modified FFmpeg (the standard
   approach is to publish your build scripts — which this repo already does)
2. State in your app that FFmpeg is used and link to its license

See [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html) for full details.
The `h264_videotoolbox` and `aac_at` encoders are Apple system APIs and carry
no additional licensing requirements.
