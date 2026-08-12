// swift-tools-version:5.9
import PackageDescription

// After each GitHub Actions run, update url + checksum from the build log
// or the .sha256 release asset.
//
// For local iteration (before publishing a release):
//   .binaryTarget(name: "FFmpeg4chan", path: "./output/FFmpeg4chan.xcframework")

let package = Package(
    name: "FFmpeg4chan",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "FFmpeg4chan", targets: ["FFmpeg4chan"])
    ],
    targets: [
        .binaryTarget(
            name: "FFmpeg4chan",
            url: "https://github.com/<your-org>/<your-repo>/releases/download/<tag>/FFmpeg4chan.xcframework.zip",
            checksum: "<paste-sha256-from-build-output>"
        )
    ]
)

// ---------------------------------------------------------------------------
// Usage in your app:
//
// import FFmpeg4chan   (gives you access to the FFmpeg C API)
//
// Transcode pipeline:
//   1. URLSession.downloadTask  → save raw file to disk (any format)
//   2. Check extension:
//        .webm → transcode with FFmpeg: VP8/VP9+Vorbis/Opus → H.264+AAC → .mp4
//        .ogg  → transcode with FFmpeg: Vorbis → AAC → .m4a
//        else  → file is already AVFoundation-compatible, play directly
//   3. AVPlayer / AVAudioPlayer for playback
//
// The encoders h264_videotoolbox and aac_at call iOS system frameworks
// (VideoToolbox / AudioToolbox) — no software encoder is bundled.
// ---------------------------------------------------------------------------
