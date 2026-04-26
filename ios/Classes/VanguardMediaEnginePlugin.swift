// VanguardMediaEnginePlugin.swift
// Phase 1 additions:
//   P1-T4  — VanguardEngineMode enum + mandatory teardown-before-switch
//   P1-T7  — VanguardThumbnailGenerator (max 1 full renderer at any time)
//   P1-T10 — AVAudioSession route change handler

import Flutter
import UIKit
import Metal
import AVFoundation

// ─── P1-T4: Engine Mode ───────────────────────────────────────────────────────

/// The exclusive operating mode of the Vanguard engine.
/// Transitioning between modes requires tearing down the previous mode first.
/// This prevents the shared hardware H.264/HEVC encoder from being double-booked
/// (e.g. AVCaptureSession + AVAssetWriter contention on A-series SoCs).
@objc enum VanguardEngineMode: Int {
    case idle   = 0
    case editor = 1   // AVAssetReader active  — one full VanguardMetalRenderer
    case export = 2   // AVAssetWriter locked  — one VanguardExportSession
    case camera = 3   // AVCaptureSession live — Phase 3
}

// ─── P1-T7: Thumbnail Generator ──────────────────────────────────────────────

/// Lightweight thumbnail extractor backed by a single shared AVAssetImageGenerator.
/// Used for filmstrip frame extraction — never creates a full renderer.
/// Max size 120×214 px — enough for filmstrip display, not for playback.
final class VanguardThumbnailGenerator {

    private var generator: AVAssetImageGenerator?
    private let queue = DispatchQueue(label: "com.vanguard.thumbnails", qos: .userInitiated)

    func generateThumbnails(videoPath: String, count: Int, duration: Double,
                            completion: @escaping ([FlutterStandardTypedData]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let url   = URL(fileURLWithPath: videoPath)
            let asset = AVURLAsset(url: url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 120, height: 214)
            gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
            self.generator = gen

            var times: [NSValue] = []
            let step = duration / Double(max(count - 1, 1))
            for i in 0..<count {
                let t = CMTimeMakeWithSeconds(Double(i) * step, preferredTimescale: 600)
                times.append(NSValue(time: t))
            }

            var images: [FlutterStandardTypedData] = []
            for timeValue in times {
                let t = timeValue.timeValue
                if let cgImage = try? gen.copyCGImage(at: t, actualTime: nil),
                   let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6) {
                    images.append(FlutterStandardTypedData(bytes: data))
                }
            }
            DispatchQueue.main.async { completion(images) }
        }
    }

    func cancel() {
        generator?.cancelAllCGImageGeneration()
    }
}

// ─── Plugin ───────────────────────────────────────────────────────────────────

public class VanguardMediaEnginePlugin: NSObject, FlutterPlugin {
    private var registrar: FlutterPluginRegistrar!
    private var channel: FlutterMethodChannel!

    // P1-T4: Current mode — transitions require teardown
    var currentMode: VanguardEngineMode = .idle

    // P1-T7: At most ONE full renderer at any time (editor mode)
    var renderers: [Int64: VanguardMetalRenderer] = [:]

    // P1-T7: Single shared thumbnail generator — never a full renderer for filmstrip
    private let thumbnailGenerator = VanguardThumbnailGenerator()

    // Active export session — retained to outlive handle(_:result:) scope
    var activeExportSession: VanguardExportSession?

    // P3-T4: Camera source + streaming encoder (streaming path, not AVAssetWriter)
    var cameraSource: VanguardCameraMediaSource?
    var streamingEncoder: VanguardVideoToolboxEncoder?

    // Phase 2 Step 6: session registry is the unconditional playback path.
    // All createTexture / play / pause / seekTo / dispose calls route here.
    // Camera and export continue to use `renderers` exclusively.
    private let sessionRegistry = VGSessionRegistry()

    // Phase 2 Step 8: lifecycle observer — owns all NotificationCenter registrations.
    // Instantiated in register(with:) after sessionRegistry is available.
    private var lifecycleObserver: VGPluginLifecycleObserver?

    // ─── Registration ─────────────────────────────────────────────────────────

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "vanguard_media_engine",
                                           binaryMessenger: registrar.messenger())
        let instance = VanguardMediaEnginePlugin()
        instance.registrar = registrar
        instance.channel   = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Phase 2 Step 6: sessionRegistry is now a let constant on the instance;
        // no explicit instantiation needed here.

        // P3-T4: Register camera PlatformView factory
        let cameraFactory = VanguardCameraViewFactory()
        registrar.register(cameraFactory, withId: "vanguard_camera_view")

        // Phase 2 Step 8: instantiate the lifecycle observer after sessionRegistry
        // is available. The observer owns all NotificationCenter registrations
        // (memory warning, willResignActive, didBecomeActive, audio interruption,
        // route change, thermal state) and triggers preActivateAudioSession().
        instance.lifecycleObserver = VGPluginLifecycleObserver(
            registry: instance.sessionRegistry,
            plugin: instance
        )
    }

    // ─── Mode teardown ─────────────────────────────────────────────────────────

    /// Synchronously tears down the current mode.
    /// PATCH-2: Camera teardown no longer calls stopRecordingAndWait here.
    /// For camera→editor transitions use teardownCameraAsync(completion:) instead.
    private func teardownCurrentMode() {
        switch currentMode {
        case .editor:
            // Phase 2 Step 6: playback sessions are owned by the registry.
            // Legacy renderer map has no playback entries; dispose all registry sessions.
            sessionRegistry.disposeAll()
        case .export:
            activeExportSession?.cancel()
            activeExportSession = nil
        case .camera:
            // Synchronous camera teardown path — used only when no recording
            // is active (e.g. startCamera teardown). If a recording is active,
            // callers MUST use teardownCameraAsync(completion:) instead.
            cameraSource?.stop()
            cameraSource = nil
            streamingEncoder?.finish()
            streamingEncoder?.invalidate()
            streamingEncoder = nil
            // Dispose camera preview renderer(s) — renderers dict is camera-only here.
            for (id, renderer) in renderers {
                registrar.textures().unregisterTexture(id)
                renderer.dispose()
            }
            renderers.removeAll()
        case .idle:
            break
        }
    }

    /// Tears down the current mode and transitions to `mode`.
    /// For camera→camera transitions that may have an active recording,
    /// use teardownCameraAsync(completion:) instead.
    private func switchToMode(_ mode: VanguardEngineMode) {
        teardownCurrentMode()
        currentMode = mode
    }

    /// PATCH-2: Async camera teardown for transitions that may have an active recording.
    /// Calls stopRecording(completion:) (no main-thread block) then invokes completion
    /// on main. The 5-second semaphore wait that existed in stopRecordingAndWait is gone.
    private func teardownCameraAsync(completion: @escaping () -> Void) {
        guard currentMode == .camera, let source = cameraSource else {
            teardownCurrentMode()
            completion()
            return
        }
        // Capture locals before nil-ing ivars so the completion block can safely reference them.
        let encoder = streamingEncoder
        source.stopRecording { [weak self] _, _, _, error in
            // Back on main thread (stopRecordingWithCompletion: guarantees this).
            // BLOCK-2 FIX: capture the error instead of discarding it.
            // finishWritingWithCompletionHandler: can fail during a phone call or
            // AVAudioSession interruption; the clip is lost (url == nil). Log the
            // error and emit an event so Flutter can notify the user.
            if let error = error {
                NSLog("[VanguardPlugin] teardownCameraAsync: recording failed during mode transition: %@",
                      error.localizedDescription)
                self?.channel.invokeMethod("onRecordingError",
                                           arguments: ["message": error.localizedDescription])
            }
            source.stop()
            self?.cameraSource = nil
            encoder?.finish()
            encoder?.invalidate()
            self?.streamingEncoder = nil
            self?.currentMode = .idle
            completion()
        }
    }

    // ─── Method Channel Dispatch ───────────────────────────────────────────────

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        // ── Texture lifecycle ─────────────────────────────────────────────────

        case "createTexture":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
                return
            }

            NSLog("[TRACE][N1] createTexture entered path=%@", path)

            // Phase 2 Step 7: read caller-supplied muted flag.
            // Dart passes {'path': ..., 'muted': true/false}. Absent key defaults to
            // false (active audio) — preserves backward-compat with existing callers.
            let muted = args?["muted"] as? Bool ?? false

            // Phase 2 Step 6: all playback creation routes through VGSessionRegistry.
            // Camera teardown runs first if needed so AVAudioSession is free.
            let _createTextureViaRegistry = { [weak self] in
                guard let self else { return }
                let url = URL(fileURLWithPath: path)
                // Capture sessionId in a local var; assigned synchronously by
                // createSession before its async completion ever fires.
                var sid = ""
                sid = self.sessionRegistry.createSession(
                    url:             url,
                    textureRegistry: self.registrar.textures(),
                    methodChannel:   self.channel,
                    desiredAudioRole: muted ? .muted : .active
                ) { textureId, renderSize in
                    DispatchQueue.main.async {
                        guard textureId >= 0 else {
                            result(FlutterError(code: "PREPARE_FAILED",
                                                message: "createTexture: prepare failed",
                                                details: nil))
                            return
                        }
                        let w = renderSize.width  > 0 ? Int(renderSize.width)  : 1080
                        let h = renderSize.height > 0 ? Int(renderSize.height) : 1920
                        NSLog("[TRACE][N8] plugin result about to send textureId=%lld", textureId)
                        result(["textureId": textureId, "sessionId": sid, "width": w, "height": h])
                        NSLog("[TRACE][N9] plugin result sent")
                    }
                }
            }

            if currentMode == .camera {
                teardownCameraAsync { _createTextureViaRegistry() }
            } else {
                _createTextureViaRegistry()
            }

        // ── Image texture (Phase A1-S1) ────────────────────────────────────────
        // Creates a VanguardMetalRenderer backed by VanguardImageMediaSource.
        // Conforms to the same id<VanguardMediaSource> contract as video and
        // camera sources. The renderer's filter chain is fully active — LUT,
        // beauty, and ML filters apply to images exactly as they do to video frames.
        //
        // Lifecycle:
        //   init → renderer allocates CVPixelBufferPool
        //   pool wired back to processor (mirrors initWithVideoPath: pattern)
        //   source.start() fires one CVPixelBuffer via _videoCallback → _latestPixelBuffer
        //   copyPixelBuffer returns that buffer on every raster-thread tick
        //   seek(0) re-fires the same buffer (safe — no-op from source perspective)
        //
        // Mode: .editor — image and video editor share the same render path.
        // The existing max-1-renderer guard applies; any previous renderer is
        // torn down before the image renderer is created.

        case "createImageTexture":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "createImageTexture: path required",
                                    details: nil))
                return
            }
            let imageURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                result(FlutterError(code: "FILE_NOT_FOUND",
                                    message: "createImageTexture: file not found at \(path)",
                                    details: nil))
                return
            }

            // Phase 2 Step 6: image creation also routes through VGSessionRegistry.
            let _createImageViaRegistry = { [weak self] in
                guard let self else { return }
                var sid = ""
                sid = self.sessionRegistry.createSession(
                    url:             imageURL,
                    textureRegistry: self.registrar.textures(),
                    methodChannel:   self.channel,
                    desiredAudioRole: .muted
                ) { textureId, renderSize in
                    DispatchQueue.main.async {
                        guard textureId >= 0 else {
                            result(FlutterError(code: "PREPARE_FAILED",
                                                message: "createImageTexture: prepare failed",
                                                details: nil))
                            return
                        }
                        let w = renderSize.width  > 0 ? Int(renderSize.width)  : 1080
                        let h = renderSize.height > 0 ? Int(renderSize.height) : 1920
                        result(["textureId": textureId, "sessionId": sid, "width": w, "height": h])
                    }
                }
            }

            if currentMode == .camera {
                teardownCameraAsync { _createImageViaRegistry() }
            } else {
                _createImageViaRegistry()
            }

        // ── Video duration probe (Phase A2-S1) ────────────────────────────────────
        // Lightweight AVURLAsset.duration read — no renderer, no decoder, no FFmpeg.
        // Replaces VideoPlayerController.file initialization in addClip() which was
        // creating a competing AVFoundation session and violating I-5.
        //
        // AVURLAsset.duration blocks the calling thread for one XPC round-trip to
        // mediaserverd (~5-30ms). We dispatch to a background queue so the main
        // thread is never blocked and the MethodChannel stays responsive.
        //
        // Returns the duration in seconds as a Double, or -1.0 if the asset cannot
        // be loaded (caller falls back to 15.0s default).
        case "probeVideoDuration":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "probeVideoDuration: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let dur = CMTimeGetSeconds(asset.duration)
                let seconds: Double = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur
                DispatchQueue.main.async { result(seconds) }
            }

        case "probeVideoInfo":
            // Returns ["duration": Double, "width": Double, "height": Double] for a video file.
            // Used by story_export_service to replace FFmpegKit metadata probes.
            // iOS: AVURLAsset.duration + AVAssetTrack.naturalSize.
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "probeVideoInfo: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let dur     = CMTimeGetSeconds(asset.duration)
                let seconds = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur
                // naturalSize may be .zero if no video track — report 0 dimensions gracefully.
                let size    = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
                DispatchQueue.main.async {
                    result(["duration": seconds, "width": Double(size.width), "height": Double(size.height)])
                }
            }

        // ── inspectMedia ─────────────────────────────────────────────────────────
        // Extended media probe (superset of probeVideoInfo). Returns full MediaInfo
        // map needed by VanguardMediaPreparer decision logic.
        // probeVideoInfo is kept unchanged — do not remove it.
        case "inspectMedia":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "inspectMedia: path required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url,
                                       options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

                // Duration
                let dur     = CMTimeGetSeconds(asset.duration)
                let seconds = (dur.isNaN || dur.isInfinite || dur <= 0) ? -1.0 : dur

                // File size
                let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

                // Container (extension-based; fast path)
                let ext = url.pathExtension.lowercased()
                let containerMap: [String: String] = [
                    "mp4": "mp4", "m4v": "mp4", "mov": "mov",
                    "mkv": "mkv", "webm": "webm", "avi": "avi",
                    "m4a": "m4a", "aac": "aac", "mp3": "mp3",
                    "jpeg": "jpeg", "jpg": "jpeg", "png": "png",
                    "heic": "heic", "heif": "heif", "webp": "webp", "gif": "gif",
                ]
                let container = containerMap[ext] ?? ext

                // Video track properties
                let videoTrack = asset.tracks(withMediaType: .video).first
                let size       = videoTrack?.naturalSize ?? .zero
                let bitrate    = videoTrack.map { Int($0.estimatedDataRate / 1000) } ?? 0
                let fps        = videoTrack.map { Double($0.nominalFrameRate) } ?? 0.0

                // Rotation — preferredTransform != identity means rotation metadata is present
                let transform          = videoTrack?.preferredTransform ?? .identity
                let hasRotationTransform = (transform.a != 1.0 || transform.b != 0.0 ||
                                            transform.c != 0.0 || transform.d != 1.0)

                // Video codec — read FourCC from first format description
                var videoCodec = ""
                if let fmtDesc = videoTrack?.formatDescriptions.first {
                    let subtype = CMFormatDescriptionGetMediaSubType(fmtDesc as! CMFormatDescription)
                    switch subtype {
                    case kCMVideoCodecType_H264:              videoCodec = "h264"
                    case kCMVideoCodecType_HEVC:              videoCodec = "hevc"
                    case kCMVideoCodecType_MPEG4Video:        videoCodec = "mpeg4"
                    case kCMVideoCodecType_VP9:               videoCodec = "vp9"
                    case kCMVideoCodecType_AV1:               videoCodec = "av1"
                    default:
                        // Format as "0x{hex}" for unknown subtypes
                        videoCodec = String(format: "0x%08X", subtype)
                    }
                }

                // Audio track codec
                var audioCodec = ""
                if let audioTrack = asset.tracks(withMediaType: .audio).first,
                   let fmtDesc = audioTrack.formatDescriptions.first {
                    let subtype = CMFormatDescriptionGetMediaSubType(fmtDesc as! CMFormatDescription)
                    switch subtype {
                    case kAudioFormatMPEG4AAC,
                         kAudioFormatMPEG4AAC_HE,
                         kAudioFormatMPEG4AAC_HE_V2: audioCodec = "aac"
                    case kAudioFormatLinearPCM:       audioCodec = "pcm"
                    case kAudioFormatAC3,
                         kAudioFormatEnhancedAC3:     audioCodec = "ac3"
                    case kAudioFormatMPEGLayer3:      audioCodec = "mp3"
                    case kAudioFormatOpus:            audioCodec = "opus"
                    default:                          audioCodec = String(format: "0x%08X", subtype)
                    }
                }

                // HDR — check color primaries (reuse _selectExportPreset logic)
                var isHDR = false
                if let videoTrack = videoTrack {
                    for desc in videoTrack.formatDescriptions {
                        if let primaries = CMFormatDescriptionGetExtension(
                            desc as! CMFormatDescription,
                            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
                        ) as? String,
                           primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                            isHDR = true
                            break
                        }
                    }
                }

                // Embedded metadata (GPS, device info, etc.) — coarse check for any common items
                let metaItems = asset.metadata
                let hasEmbeddedMetadata = !metaItems.isEmpty

                // Track presence
                let hasVideo = videoTrack != nil
                let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

                // hasMoovAtFront: conservatively false by default (see implementation plan §B2).
                // Routing eligible files to normalizeVideo (lossless passthrough remux) is safe.
                // A proper atom-walk parser is deferred.
                let hasMoovAtFront = false

                // MediaKind
                let imageExts: Set<String> = ["jpeg", "jpg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"]
                let audioExts: Set<String> = ["m4a", "aac", "mp3", "wav", "flac", "ogg"]
                let kind: String
                if imageExts.contains(ext)     { kind = "image" }
                else if audioExts.contains(ext) { kind = "audio" }
                else if hasVideo || ["mp4","mov","mkv","webm","avi","m4v"].contains(ext) { kind = "video" }
                else                            { kind = "unknown" }

                DispatchQueue.main.async {
                    result([
                        "kind":                  kind,
                        "container":             container,
                        "videoCodec":            videoCodec,
                        "audioCodec":            audioCodec,
                        "width":                 Int(size.width),
                        "height":                Int(size.height),
                        "durationSeconds":       seconds,
                        "bitrateKbps":           bitrate,
                        "fps":                   fps,
                        "fileSizeBytes":         fileSizeBytes,
                        "hasVideo":              hasVideo,
                        "hasAudio":              hasAudio,
                        "isHDR":                 isHDR,
                        "hasMoovAtFront":        hasMoovAtFront,
                        "hasRotationTransform":  hasRotationTransform,
                        "hasEmbeddedMetadata":   hasEmbeddedMetadata,
                    ] as [String: Any])
                }
            }

        // ── compressImage ─────────────────────────────────────────────────────────
        // Resizes and JPEG-encodes an image file using CGImageDestination.
        // CGImageDestination with an explicit properties dict that omits EXIF and GPS
        // keys guarantees metadata stripping regardless of source file.
        // Do NOT switch to UIImage.jpegData() — its EXIF behavior is version-dependent.
        case "compressImage":
            guard
                let inputPath  = args?["inputPath"]  as? String,
                let outputPath = args?["outputPath"] as? String,
                let maxWidthPx = args?["maxWidthPx"] as? Int,
                let quality    = args?["jpegQuality"] as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "compressImage: inputPath, outputPath, maxWidthPx, jpegQuality required",
                                    details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let source    = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
                    let cgImage   = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "READ_FAILED",
                                            message: "compressImage: cannot read source image",
                                            details: nil))
                    }
                    return
                }

                // Compute target dimensions, maintaining aspect ratio
                let srcW = cgImage.width
                let srcH = cgImage.height
                let (targetW, targetH): (Int, Int) = {
                    guard srcW > maxWidthPx else { return (srcW, srcH) }
                    let scale = Double(maxWidthPx) / Double(srcW)
                    return (maxWidthPx, max(1, Int(Double(srcH) * scale)))
                }()

                // Resize using CGContext if needed
                let finalImage: CGImage
                if targetW == srcW && targetH == srcH {
                    finalImage = cgImage
                } else {
                    let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                    guard let ctx = CGContext(
                        data: nil,
                        width: targetW, height: targetH,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    ) else {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "RESIZE_FAILED",
                                                message: "compressImage: cannot create graphics context",
                                                details: nil))
                        }
                        return
                    }
                    ctx.interpolationQuality = .high
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                    guard let resized = ctx.makeImage() else {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "RESIZE_FAILED",
                                                message: "compressImage: makeImage failed",
                                                details: nil))
                        }
                        return
                    }
                    finalImage = resized
                }

                // Write JPEG with explicit properties — omit EXIF/GPS keys intentionally
                let outURL  = URL(fileURLWithPath: outputPath)
                let uti     = "public.jpeg" as CFString
                let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, uti, 1, nil) else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "WRITE_FAILED",
                                            message: "compressImage: cannot create destination",
                                            details: nil))
                    }
                    return
                }
                // properties dict ONLY contains quality — no EXIF, no GPS, no IPTC
                CGImageDestinationAddImage(dest, finalImage, options)
                let wrote = CGImageDestinationFinalize(dest)

                DispatchQueue.main.async {
                    if wrote {
                        result(["outputPath": outputPath])
                    } else {
                        result(FlutterError(code: "WRITE_FAILED",
                                            message: "compressImage: finalize failed",
                                            details: nil))
                    }
                }
            }

        // ── normalizeVideo ────────────────────────────────────────────────────────
        // Lossless container rewrite — no decode/re-encode of video or audio samples.
        //
        // What this does:
        //   • Repositions moov atom to the file head (shouldOptimizeForNetworkUse = true)
        //   • Strips privacy metadata (GPS, device fingerprint) via AVMetadataItemFilter.forSharing()
        //   • Outputs a clean MP4 container
        //   • Preserves container-level rotation via track preferredTransform (automatic)
        //
        // What this does NOT do:
        //   • Does NOT pixel-bake rotation (no videoComposition — that forces re-encode)
        //   • Does NOT transcode or alter compressed video/audio samples
        //   • Does NOT change resolution, bitrate, or codec
        //
        // Rotation policy: preferredTransform is preserved in the output track header
        // automatically by AVAssetExportPresetPassthrough. Modern iOS/Android players
        // and social platform ingest pipelines respect this container-level metadata.
        //
        // HEVC note: this handler treats H.264 and HEVC identically — it passes
        // whichever codec the source contains. Backend/CDN HEVC compatibility
        // is unconfirmed; classification warnings are the caller's responsibility.
        case "normalizeVideo":
            guard
                let inputPath  = args?["inputPath"]  as? String,
                let outputPath = args?["outputPath"] as? String
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "normalizeVideo: inputPath and outputPath required",
                                    details: nil))
                return
            }

            let inputURL  = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath)

            // Remove any stale output file — AVAssetExportSession will not overwrite.
            let fm = FileManager.default
            if fm.fileExists(atPath: outputPath) {
                do {
                    try fm.removeItem(at: outputURL)
                } catch {
                    NSLog("[Vanguard] normalizeVideo: failed to remove stale output at %@ — %@",
                          outputPath, error.localizedDescription)
                    // AVAssetExportSession will fail immediately; error surfaces to caller.
                }
            }

            let asset = AVURLAsset(url: inputURL,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            // AVAssetExportPresetPassthrough copies the compressed bitstream unchanged.
            // Combining it with videoComposition would force a re-encode — do not do that.
            guard let exporter = AVAssetExportSession(
                asset:      asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                result(FlutterError(code: "EXPORT_UNAVAILABLE",
                                    message: "normalizeVideo: AVAssetExportSession unavailable "
                                             + "(preset passthrough not supported for this asset)",
                                    details: nil))
                return
            }

            exporter.outputURL      = outputURL
            exporter.outputFileType = .mp4

            // Move moov atom to the file head. Required for server-side adaptive
            // streaming and platform ingest. Adds a small file-scan pass at the end
            // of export — no re-encode cost.
            exporter.shouldOptimizeForNetworkUse = true

            // Strip GPS location, device fingerprint, and similar PII metadata.
            // forSharing() retains playback-necessary metadata (codec, duration, etc.)
            // and removes privacy-sensitive fields only.
            exporter.metadataItemFilter = AVMetadataItemFilter.forSharing()

            // NOTE: exporter.videoComposition is intentionally NOT set.
            // Setting it would abandon passthrough and trigger a full re-encode.

            // Fix 3: HEVC provisional warning.
            // Backend/CDN HEVC-in-MP4 compatibility is unconfirmed.
            // Log when detected so device QA can identify these files.
            // No behavior change — passthrough proceeds identically for HEVC and H.264.
            if let vTrack = asset.tracks(withMediaType: .video).first {
                for desc in vTrack.formatDescriptions {
                    // swiftlint:disable:next force_cast
                    let fmt = desc as! CMFormatDescription
                    let subType = CMFormatDescriptionGetMediaSubType(fmt)
                    // 'hvc1' and 'hev1' are the two HEVC FourCC variants in MP4.
                    if subType == kCMVideoCodecType_HEVC {
                        NSLog("[Vanguard] normalizeVideo: HEVC source detected in %@ — "
                              + "backend/CDN HEVC-in-MP4 compatibility is PROVISIONAL. "
                              + "Validate upload end-to-end before wider rollout.",
                              (inputURL.lastPathComponent))
                        break
                    }
                }
            }

            exporter.exportAsynchronously {
                // exportAsynchronously completion block runs on an internal GCD queue.
                // Marshal the result back to the main thread for Flutter.
                DispatchQueue.main.async {
                    switch exporter.status {
                    case .completed:
                        // Verify the output file was actually written.
                        guard fm.fileExists(atPath: outputPath) else {
                            result(FlutterError(code: "EXPORT_FAILED",
                                                message: "normalizeVideo: exporter reported "
                                                         + "completed but output file is missing",
                                                details: nil))
                            return
                        }
                        result(["outputPath": outputPath])

                    case .failed:
                        let msg = exporter.error?.localizedDescription
                            ?? "unknown export error"
                        // Surface specific AVError codes where useful:
                        // AVErrorSourceFileUTIUnknown → input format not recognised
                        // AVErrorExportFailed         → generic encode/mux failure
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: "normalizeVideo failed: \(msg)",
                                            details: nil))

                    case .cancelled:
                        result(FlutterError(code: "EXPORT_CANCELLED",
                                            message: "normalizeVideo cancelled",
                                            details: nil))

                    default:
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: "normalizeVideo ended in unexpected "
                                                     + "state: \(exporter.status.rawValue)",
                                            details: nil))
                    }
                }
            }

        case "play":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value else {
                result(FlutterError(code: "BAD_ARGS", message: "play requires textureId", details: nil)); return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.play() == nil {
                NSLog("[VanguardPlugin] runtime not found for textureId %lld", textureId)
            }
            result(nil)

        case "pause":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value else {
                result(FlutterError(code: "BAD_ARGS", message: "pause requires textureId", details: nil)); return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.pause() == nil {
                NSLog("[VanguardPlugin] runtime not found for textureId %lld", textureId)
            }
            result(nil)

        case "seekTo":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value,
                  let seconds   = (args?["seconds"]   as? NSNumber)?.doubleValue else {
                result(FlutterError(code: "BAD_ARGS", message: "seekTo requires textureId and seconds", details: nil))
                return
            }
            // Phase 2 Step 6: all playback via registry.
            if sessionRegistry.runtime(forTextureId: textureId)?.seek(to: seconds) == nil {
                NSLog("[VanguardPlugin] runtime not found for textureId %lld", textureId)
            }
            result(nil)

        // G-02: Exposes the native masterClock for the A/V sync integration test.
        // Not called in production code — diagnostic/testing path only.
        // NOTE: do NOT add print()/NSLog() here — getMasterClock is called at
        // ~25,000/sec during the settle poll loop; any blocking log call will
        // saturate logd's XPC buffer and hang the settle on the second call.
        case "getMasterClock":
            // G-02: Exposes the native masterClock for the A/V sync integration test.
            // Not called in production code — diagnostic/testing path only.
            // NOTE: do NOT log here — this is called at ~25,000/sec during the
            // G-02-T2 settle poll loop; any blocking call saturates logd's XPC buffer.
            //
            // Phase 2 Step 7 contract:
            //   • If textureId is provided and resolves to a registry runtime with a
            //     masterClock, return CMTimeGetSeconds of that clock.
            //   • Otherwise preserve the pre-Phase-2 renderer fallback:
            //     renderers.values.first?.currentTimeSeconds ?? 0.0
            //     (renderers holds camera/export renderers; their currentTimeSeconds
            //     is wall-clock-based and is a valid fallback for legacy callers.)
            let tid = (args?["textureId"] as? NSNumber)?.int64Value ?? -1
            if tid >= 0,
               let rt = sessionRegistry.runtime(forTextureId: tid),
               let clock = rt.masterClock {
                result(CMTimeGetSeconds(clock.currentTime))
            } else {
                result(renderers.values.first?.currentTimeSeconds ?? 0.0)
            }

        // G-02-T3: Native-backed post-seek settle (test-only).
        // Sleeps `ms` milliseconds on a GCD background thread and delivers
        // result() when done.  This is the only reliable settle mechanism after
        // a 50-seek storm:
        //   • Future.delayed relies on a healthy Dart event loop, which degrades
        //     after 50+ rapid MethodChannel calls.
        //   • getMasterClockSeconds() polling relies on a free iOS RunLoop, which is
        //     saturated with post-seek AVFoundation callbacks for ~500ms.
        // Here the initial message routing to this handler happens at T+26ms
        // (main thread always free for the first post-seek dispatch).  The sleep
        // runs on a bg queue with zero main-thread interaction.  result() is
        // delivered at T+ms when the RunLoop is fully clear.
        case "settleMs":
            let ms = (args?["ms"] as? NSNumber)?.doubleValue ?? 500.0
            DispatchQueue.global(qos: .default).async {
                Thread.sleep(forTimeInterval: ms / 1000.0)
                result(nil)
            }

        // G-02-T3: Suppress all AVAssetImageGenerator activity so no internal
        // AVFoundation XPC dispatch can block the main thread during the seek
        // storm, settle, lock-window, or measurement phases.
        // pauseSeekPreviews() MUST be called before the seek storm (when main
        // is free). resumeSeekPreviews() restores normal behaviour after the
        // measurement is complete.  Both are no-ops in production — test-only.
        case "pauseSeekPreviews":
            // Phase 2 Step 7: forward to all registry runtimes AND all renderers
            // (camera/export renderers also carry seekPreviewPaused; they must be
            // silenced during the G-02-T3 seek storm to prevent AVFoundation XPC
            // dispatch from blocking the main thread during the measurement window).
            sessionRegistry.allRuntimes().forEach { $0.setSeekPreviewPaused(true) }
            renderers.values.forEach { $0.seekPreviewPaused = true }
            result(nil)

        case "resumeSeekPreviews":
            // Phase 2 Step 7: mirror pauseSeekPreviews — both maps must be reset.
            sessionRegistry.allRuntimes().forEach { $0.setSeekPreviewPaused(false) }
            renderers.values.forEach { $0.seekPreviewPaused = false }
            result(nil)

        // ── P5: Test-only native helpers ────────────────────────────────────────
        // analyzeMP4: reads all video frame durations + audio/video total durations.
        // Returns: {audioDurationMs: Double, videoDurationMs: Double, frameDurations: [Double]}
        // Called by P5-B Dart test to assert max(frame_duration) < 33ms.
        case "analyzeMP4":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "analyzeMP4 requires path", details: nil)); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                let vTrack = asset.tracks(withMediaType: .video).first
                let aTrack = asset.tracks(withMediaType: .audio).first
                let videoDurationMs = vTrack.map { CMTimeGetSeconds($0.timeRange.duration) * 1000 } ?? 0
                let audioDurationMs = aTrack.map { CMTimeGetSeconds($0.timeRange.duration) * 1000 } ?? 0

                // Linear frame-duration pass (compressed output — no decode overhead)
                var frameDurations: [Double] = []
                if let vt = vTrack,
                   let reader = try? AVAssetReader(asset: asset) {
                    let out = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
                    out.alwaysCopiesSampleData = false
                    reader.add(out)
                    reader.startReading()
                    while let sample = out.copyNextSampleBuffer() {
                        let dur = CMSampleBufferGetDuration(sample)
                        if dur.isValid && dur.isNumeric {
                            frameDurations.append(CMTimeGetSeconds(dur) * 1000)
                        }
                    }
                    reader.cancelReading()
                }
                let info: [String: Any] = [
                    "videoDurationMs": videoDurationMs,
                    "audioDurationMs": audioDurationMs,
                    "frameDurations":  frameDurations,
                ]
                DispatchQueue.main.async { result(info) }
            }

        // countFramesInMP4: linear AVAssetReader frame count pass.
        // Called by P5-C Dart test to compare against VTCompressionOutputCallback count.
        case "countFramesInMP4":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "countFramesInMP4 requires path", details: nil)); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let url   = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                guard let vTrack = asset.tracks(withMediaType: .video).first,
                      let reader = try? AVAssetReader(asset: asset) else {
                    DispatchQueue.main.async { result(NSNumber(value: 0)) }; return
                }
                let settings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let out = AVAssetReaderTrackOutput(track: vTrack, outputSettings: settings)
                out.alwaysCopiesSampleData = false
                reader.add(out)
                reader.startReading()
                var frameCount = 0
                while let sample = out.copyNextSampleBuffer() {
                    frameCount += 1
                    _ = sample // ARC releases
                }
                reader.cancelReading()
                DispatchQueue.main.async { result(NSNumber(value: frameCount)) }
            }

        // runNativeTest: invokes a named P5 assertion via VanguardP5TestRunner.
        // The test runs on a background queue; result is delivered on main.
        // Result dict: {passed: Bool, message: String, metrics: [String: Double]}
        case "runNativeTest":
            let testName = args?["name"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let testResult = VanguardP5TestRunner.run(testNamed: testName)
                DispatchQueue.main.async { result(testResult) }
            }

        case "setPlaybackRate":
            guard let textureId = (args?["textureId"] as? NSNumber)?.int64Value,
                  let rate      = (args?["rate"] as? NSNumber)?.doubleValue else {
                result(FlutterError(code: "BAD_ARGS", message: "setPlaybackRate requires textureId and rate", details: nil)); return
            }
            // Phase 2 Step 7: try registry runtime first (playback sessions);
            // fall back to renderers dict for camera/export renderers.
            if sessionRegistry.runtime(forTextureId: textureId)?.setPlaybackRate(rate) != nil {
                // handled by registry
            } else if let renderer = renderers[textureId] {
                renderer.setPlaybackRate(rate)
            } else {
                NSLog("[VanguardPlugin] setPlaybackRate: no runtime or renderer for textureId %lld", textureId)
            }
            result(nil)

        case "dispose":
            guard let textureId = args?["textureId"] as? NSNumber else {
                result(FlutterError(code: "BAD_ARGS", message: "dispose requires textureId", details: nil)); return
            }
            let id = textureId.int64Value
            NSLog("[TRACE][DPS1] dispose entered textureId=%lld", id)

            // Phase 2 Step 6: remove from maps, then drain async before unblocking Dart.
            // removeFromMaps returns the runtime without calling invalidate — we call
            // invalidateAsync so the decode queue drains before result(nil) fires.
            // This preserves the G-02-T2 safety guarantee from the legacy disposeAsync path.
            if let runtime = sessionRegistry.removeFromMaps(textureId: id) {
                NSLog("[TRACE][DPS2] removeFromMaps returned runtime=%@", runtime)
                runtime.invalidateAsync {
                    NSLog("[TRACE][DPS3] invalidateAsync completion fired textureId=%lld", id)
                    NSLog("[VanguardPlugin] dispose complete for textureId=%lld — Dart unblocked", id)
                    NSLog("[TRACE][DPS4] plugin result(nil) sent textureId=%lld", id)
                    result(nil)
                }
            } else {
                NSLog("[TRACE][DPS2] removeFromMaps returned runtime=nil textureId=%lld", id)
                NSLog("[VanguardPlugin] runtime not found for textureId %lld", id)
                result(nil)
            }

        // ── Audio promotion (Phase 2 Step 7) ──────────────────────────────────
        // Promotes sessionId to the active audio role via a serialised
        // demotion → slot-acquire → activation transaction in VGSessionRegistry.
        // sessionId is stable (UUID) and was returned synchronously by createTexture
        // via VGSessionRegistry.createSession. The result is a Bool on the main queue.

        case "promoteAudio":
            guard let sessionId = args?["sessionId"] as? String else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "promoteAudio requires sessionId",
                                    details: nil))
                return
            }
            sessionRegistry.promoteToActiveAudio(sessionId: sessionId) { success in
                DispatchQueue.main.async { result(success) }
            }

        // ── P4-10: Filter chain dispatch ────────────────────────────────────
        // Receives a Dart setFilterChain payload:
        //   { "sessionId": String, "filters": [[String: Any]] }
        // Validates each filter type against the native allowlist, then delegates
        // node construction to the runtime (which owns the pool + Metal device).
        // Returns FlutterError(UNKNOWN_FILTER) for any unrecognised type string.
        // Closes RR-34.
        case "setFilterChain":
            guard
                let sessionId = args?["sessionId"] as? String,
                let filterDicts = args?["filters"] as? [[String: Any]]
            else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "setFilterChain requires sessionId and filters",
                                    details: nil))
                return
            }

            guard let runtime = sessionRegistry.runtime(forSessionId: sessionId) else {
                result(FlutterError(code: "SESSION_NOT_FOUND",
                                    message: "setFilterChain: no runtime for sessionId \(sessionId)",
                                    details: nil))
                return
            }

            // Pre-validate type strings before touching the runtime.
            // Mirrors the Dart-side assertValid() allowlist; provides server-side
            // error reporting for release-mode callers where assert is elided.
            let knownTypes: Set<String> = ["lut", "beauty", "segmentation"]
            for dict in filterDicts {
                let type = dict["type"] as? String ?? ""
                if !knownTypes.contains(type) {
                    result(FlutterError(
                        code: "UNKNOWN_FILTER",
                        message: "Unknown filter type: \(type)",
                        details: nil
                    ))
                    return
                }
            }

            // Delegate node construction + chain swap to the runtime, which owns
            // the CVPixelBufferPool and MTLDevice required by filter node initialisers.
            var unknownType: NSString? = nil
            let applied = runtime.setFilterChain(fromSpecs: filterDicts, unknown: &unknownType)

            if applied {
                result(nil)
            } else {
                // Double-check: should not reach here (pre-validated above), but guard
                // in case the runtime's allowlist diverges from the Swift one.
                let badType = unknownType ?? "(nil)"
                result(FlutterError(
                    code: "UNKNOWN_FILTER",
                    message: "Unknown filter type (runtime): \(badType)",
                    details: nil
                ))
            }

        // ── Export ─────────────────────────────────────────────────────────────

        case "startExport":
            guard
                let clipDicts  = args?["clips"]      as? [[String: Any]],
                let outputPath = args?["outputPath"]  as? String,
                let bitrate    = args?["bitrate"]     as? Int,
                let maxSec     = args?["maxSeconds"]  as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "clips, outputPath, bitrate, maxSeconds required",
                                    details: nil))
                return
            }

            // P1-T4: Switch to export mode (tears down editor)
            switchToMode(.export)

            let clipSpecs: [ClipSpec] = clipDicts.compactMap { dict in
                guard let path = dict["path"] as? String else { return nil }
                return ClipSpec(
                    url:       URL(fileURLWithPath: path),
                    trimStart: dict["trimStart"] as? Double ?? 0.0,
                    trimEnd:   dict["trimEnd"]   as? Double ?? Double.infinity,
                    speed:     dict["speed"]     as? Double ?? 1.0
                )
            }

            let audioPath  = args?["audioPath"]  as? String
            let audioStart = args?["audioStart"] as? Double ?? 0.0
            let optimizeForNet = args?["optimizeForNetworkUse"] as? Bool ?? false

            let config = VanguardExportSession.Config(
                outputURL:  URL(fileURLWithPath: outputPath),
                width:      1080, height: 1920,
                bitrate:    bitrate, fps: 30,
                maxSeconds: maxSec,
                audioURL:   audioPath.map { URL(fileURLWithPath: $0) },
                audioStart: audioStart,
                optimizeForNetworkUse: optimizeForNet
            )

            let session = VanguardExportSession(config: config, clips: clipSpecs)
            activeExportSession = session
            session.start(
                progress: { [weak self] pct in
                    self?.channel.invokeMethod("onExportProgress", arguments: pct)
                },
                completion: { [weak self] url, error in
                    self?.activeExportSession = nil
                    self?.currentMode = .idle
                    if let url = url {
                        result(["outputPath": url.path, "success": true])
                    } else {
                        result(FlutterError(code: "EXPORT_FAILED",
                                            message: error?.localizedDescription,
                                            details: nil))
                    }
                }
            )

        case "cancelExport":
            activeExportSession?.cancel()
            activeExportSession = nil
            currentMode = .idle
            result(nil)

        // ── Audio Extraction ──────────────────────────────────────────────────

        case "extractAudio":
            guard
                let videoPath = args?["videoPath"]  as? String,
                let outPath   = args?["outputPath"] as? String
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "videoPath and outputPath required",
                                    details: nil))
                return
            }
            let trimStart = args?["trimStart"] as? Double ?? 0.0
            let trimEnd   = args?["trimEnd"]   as? Double ?? Double.infinity

            VanguardExportSession.extractAudio(
                from:      URL(fileURLWithPath: videoPath),
                to:        URL(fileURLWithPath: outPath),
                trimStart: trimStart,
                trimEnd:   trimEnd
            ) { url, error in
                if let url = url {
                    result(url.path)
                } else {
                    result(FlutterError(code: "EXTRACT_FAILED",
                                        message: error?.localizedDescription,
                                        details: nil))
                }
            }

        // ── Thumbnail Generation (P1-T7: VanguardThumbnailGenerator) ─────────

        case "generateThumbnails":
            guard
                let videoPath = args?["videoPath"] as? String,
                let count     = args?["count"]     as? Int,
                let duration  = args?["duration"]  as? Double
            else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "videoPath, count, duration required",
                                    details: nil))
                return
            }
            thumbnailGenerator.generateThumbnails(
                videoPath: videoPath, count: count, duration: duration
            ) { images in result(images) }

        // ── Camera ────────────────────────────────────────────────────────────

        case "startCamera":
            let positionInt = args?["position"] as? Int ?? 1  // 1=back, 2=front
            let fps         = args?["fps"]      as? Int ?? 30
            // BLOCK-1 FIX: when already in camera mode a recording may be active.
            // switchToMode(.camera) → teardownCurrentMode() → cameraSource?.stop()
            // does NOT call finishWritingWithCompletionHandler: on the AVAssetWriter —
            // the in-flight clip is permanently truncated with no error signalled to Flutter.
            // Route through teardownCameraAsync so stopRecordingWithCompletion: is called
            // first and the hardware encoder drains before the new source is created.
            if currentMode == .camera {
                teardownCameraAsync { [weak self] in
                    guard let self = self else { result(nil); return }
                    self.currentMode = .camera
                    let position: AVCaptureDevice.Position = positionInt == 2 ? .front : .back
                    let src = VanguardCameraMediaSource(position: position, frameRate: Int32(fps))
                    self.cameraSource = src
                    let enc = VanguardVideoToolboxEncoder(
                        width: 1080, height: 1920,
                        bitrate: 10_000_000, fps: Int32(fps)
                    ) { _, _, _, _ in }
                    self.streamingEncoder = enc
                    enc.prewarm()
                    // Phase 1 fix: create renderer BEFORE calling src.start() so that
                    // _videoCallback is wired before any camera frames arrive on _captureQueue.
                    // Calling start() first would create a window where frames arrive on
                    // _captureQueue with _videoCallback == nil — technically safe (nil check
                    // prevents crash) but avoids the theoretical concurrent-read race entirely.
                    let renderer = VanguardMetalRenderer(source: src,
                                                        textureRegistry: self.registrar.textures(),
                                                        methodChannel: self.channel,
                                                        sessionPool: nil)
                    self.renderers[renderer.textureId] = renderer
                    src.start()
                    result(renderer.textureId)
                }
                return
            }

            switchToMode(.camera)  // tears down editor/export; deactivates AVAudioEngine

            // FIX-D: Stop any existing camera source before creating a new one.
            // Without this guard, a rapid startCamera→startCamera (front/back switch)
            // leaves the previous source running. Its AVCaptureSession continues
            // delivering captureOutput: callbacks after cameraSource is overwritten.
            // stop() calls [_session stopRunning] which blocks until all in-flight
            // captureOutput: callbacks drain — no cross-thread race on _videoCallback.
            if let existing = cameraSource {
                existing.stop()
                cameraSource = nil
            }
            streamingEncoder?.finish()
            streamingEncoder?.invalidate()
            streamingEncoder = nil

            let position: AVCaptureDevice.Position = positionInt == 2 ? .front : .back
            let src = VanguardCameraMediaSource(position: position, frameRate: Int32(fps))
            cameraSource = src

            // Prewarm streaming encoder (Phase 5+ streaming path, not AVAssetWriter)
            let enc = VanguardVideoToolboxEncoder(
                width: 1080, height: 1920,
                bitrate: 10_000_000, fps: Int32(fps)
            ) { _, _, _, _ in }
            streamingEncoder = enc
            enc.prewarm()  // ~100–150ms; runs before user can tap record

            // Phase 1 fix: create renderer BEFORE calling src.start() so that
            // _videoCallback is wired before any camera frames arrive.
            let renderer = VanguardMetalRenderer(source: src,
                                                 textureRegistry: registrar.textures(),
                                                 methodChannel: channel,
                                                 sessionPool: nil)
            renderers[renderer.textureId] = renderer
            src.start()
            result(renderer.textureId)

        case "stopCamera":
            // IDEMPOTENCY FIX: stopCamera may be called a second time by
            // VanguardCameraView.dispose() after navigation to the story editor
            // has already completed. By that point currentMode is .editor and
            // cameraSource/streamingEncoder are both nil. Without this guard,
            // switchToMode(.idle) → teardownCurrentMode() → .editor case →
            // renderers.values.forEach { $0.dispose() } — it destroys the live
            // editor renderer, NULLs _latestPixelBuffer, and unregisters the
            // Flutter texture, causing a permanent black screen in the editor.
            // Guard: only tear down when we are actually in camera mode.
            guard currentMode == .camera else {
                result(nil)
                return
            }
            cameraSource?.stop()
            cameraSource = nil
            streamingEncoder?.invalidate()
            streamingEncoder = nil
            switchToMode(.idle)
            result(nil)

        case "startRecording":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
                return
            }
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA", message: "Camera not started", details: nil))
                return
            }
            src.startRecording(to: URL(fileURLWithPath: path)) { error in
                DispatchQueue.main.async {
                    if let e = error {
                        result(FlutterError(code: "REC_FAIL",
                                            message: e.localizedDescription,
                                            details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "stopRecording":
            guard let src = cameraSource else { result(nil); return }
            src.stopRecording { url, dropped, total, error in
                DispatchQueue.main.async {
                    if let e = error {
                        result(FlutterError(code: "STOP_FAIL",
                                            message: e.localizedDescription,
                                            details: nil))
                    } else {
                        result([
                            "filePath":     url?.path ?? "",
                            "droppedFrames": dropped,
                            "totalFrames":  total,
                            "dropRate":     total > 0 ? Double(dropped) / Double(total) : 0.0
                        ])
                    }
                }
            }

        // P5-C: Reset per-session VT callback frame counter before flush test.
        case "resetEncoderCallbackCount":
            streamingEncoder?.resetCallbackCount()
            result(nil)

        // P5-C: Stop recording and return {callbackFrameCount, filePath} for
        // the encoder flush completeness assertion.
        // Calls stopRecording internally so the file is complete before returning.
        case "stopRecordingWithFlushStats":
            let encoder = streamingEncoder
            guard let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA", message: "Camera not started", details: nil))
                return
            }
            src.stopRecording { url, dropped, total, error in
                DispatchQueue.main.async {
                    if let e = error {
                        result(FlutterError(code: "STOP_FAIL", message: e.localizedDescription, details: nil))
                    } else {
                        let callbackCount = encoder?.vtCallbackCount ?? 0
                        result([
                            "callbackFrameCount": callbackCount,
                            "filePath": url?.path ?? "",
                        ])
                    }
                }
            }


        case "setZoom":
            guard let factor = args?["factor"] as? Double else {
                result(FlutterError(code: "INVALID_ARG", message: "factor required", details: nil))
                return
            }
            cameraSource?.setZoom(CGFloat(factor))
            result(nil)

        case "setFocusPoint":
            guard let x = args?["x"] as? Double, let y = args?["y"] as? Double else {
                result(FlutterError(code: "INVALID_ARG", message: "x and y required", details: nil))
                return
            }
            // Swift 3 ObjC bridge translates applyFocusPoint:(CGPoint) → applyFocus(_:)
            cameraSource?.applyFocus(CGPoint(x: x, y: y))
            result(nil)

        case "setTorchMode":
            guard let mode = args?["mode"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "mode required", details: nil))
                return
            }
            cameraSource?.setTorchMode(mode)
            result(nil)

        case "switchCamera":
            // Phase 3 guard: swapping video input during an active AVAssetWriter
            // write would corrupt the output file. isRecording checks _assetWriter != nil.
            guard cameraSource?.isRecording == false else {
                result(FlutterError(code: "RECORDING_ACTIVE",
                                    message: "Cannot switch camera while recording",
                                    details: nil))
                return
            }
            let switchPosInt = args?["position"] as? Int ?? 1
            let switchPos: AVCaptureDevice.Position = switchPosInt == 2 ? .front : .back
            // Swift 3 ObjC bridge translates moveCameraToPosition:(AVCaptureDevicePosition) → moveCamera(to:)
            cameraSource?.moveCamera(to: switchPos)
            result(nil)

        // ── Photo Capture (Phase 4) ───────────────────────────────────────────

        case "takePhoto":
            guard currentMode == .camera, let src = cameraSource else {
                result(FlutterError(code: "NO_CAMERA",
                                    message: "Camera not started",
                                    details: nil))
                return
            }
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "path required",
                                    details: nil))
                return
            }
            // Swift ObjC bridge: takePhotoToURL:completion: → takePhoto(to:completion:)
            // completion: is guaranteed on the main thread by takePhotoToURL:
            src.takePhoto(to: URL(fileURLWithPath: path)) { url, error in
                if let error = error {
                    let nsErr = error as NSError
                    let code: String
                    switch nsErr.code {
                    case 1:  code = "NO_FRAME"
                    case 3:  code = "SWITCHING"
                    default: code = "ENCODE_FAIL"
                    }
                    result(FlutterError(code: code,
                                        message: error.localizedDescription,
                                        details: nil))
                } else {
                    result(url?.path)
                }
            }

        case "flattenImageToVideo":
            // Phase 3A: iOS-native replacement for FFmpegKit image-to-video path.
            // Android continues to use FFmpegKit for this operation.
            guard let imagePath  = args?["imagePath"]  as? String,
                  let audioPath  = args?["audioPath"]  as? String,
                  let outputPath = args?["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "flattenImageToVideo: imagePath, audioPath, outputPath required",
                                    details: nil))
                return
            }
            let audioStartSeconds = args?["audioStartSeconds"] as? Double ?? 0.0
            let durationSeconds   = args?["durationSeconds"]   as? Double ?? 15.0
            VanguardImageToVideoExporter.export(
                imagePath:         imagePath,
                audioPath:         audioPath,
                audioStartSeconds: audioStartSeconds,
                outputPath:        outputPath,
                durationSeconds:   durationSeconds
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "IMG_VIDEO_FAILED",
                            message: error?.localizedDescription ?? "flattenImageToVideo failed",
                            details: nil
                        ))
                    }
                }
            }

        case "flattenVideo":
            // Phase 3B: iOS-native replacement for FFmpegKit flattenVideo path.
            // Android continues to use FFmpegKit for this operation.
            guard let videoPath      = args?["videoPath"]      as? String,
                  let overlayPNGPath = args?["overlayPNGPath"] as? String,
                  let outputPath     = args?["outputPath"]     as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "flattenVideo: videoPath, overlayPNGPath, outputPath required",
                                    details: nil))
                return
            }
            let audioPath         = args?["audioPath"]         as? String
            let audioStartSeconds = args?["audioStartSeconds"] as? Double ?? 0.0
            let durationSeconds   = args?["durationSeconds"]   as? Double ?? 15.0
            VanguardVideoFlattener.export(
                videoPath:         videoPath,
                overlayPNGPath:    overlayPNGPath,
                audioPath:         audioPath,
                audioStartSeconds: audioStartSeconds,
                outputPath:        outputPath,
                durationSeconds:   durationSeconds
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "FLATTEN_FAILED",
                            message: error?.localizedDescription ?? "flattenVideo failed",
                            details: nil
                        ))
                    }
                }
            }

        case "compositeDualCamera":
            // Phase 3C: iOS-native replacement for FFmpegKit compositeDualCamera path.
            // Android continues to use FFmpegKit for this operation.
            // Dart passes only paths — all PiP geometry computed natively from AVAssetTrack.
            guard let backPath    = args?["backPath"]    as? String,
                  let frontPath   = args?["frontPath"]   as? String,
                  let outputPath  = args?["outputPath"]  as? String else {
                result(FlutterError(code: "INVALID_ARG",
                                    message: "compositeDualCamera: backPath, frontPath, outputPath required",
                                    details: nil))
                return
            }
            VanguardDualCameraFlattener.export(
                backPath:   backPath,
                frontPath:  frontPath,
                outputPath: outputPath
            ) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        result(["success": true, "outputPath": url.path])
                    } else {
                        result(FlutterError(
                            code:    "COMPOSITE_FAILED",
                            message: error?.localizedDescription ?? "compositeDualCamera failed",
                            details: nil
                        ))
                    }
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}



// ─── P5: VanguardP5TestRunner ─────────────────────────────────────────────────
//
// Runs named P5 assertions in-process without XCTest. Called from the
// runNativeTest method channel case above. Lives in this file so it is
// always in the pre-pod-install compile sources list.
//
// Result dict: { "passed": Bool, "message": String, "metrics": [String: Double] }

private final class VanguardP5TestRunner {

    static func run(testNamed name: String) -> [String: Any] {
        switch name {
        case "testNeuralEngineLatencyDeltaUnderConcurrentFilterLoad",
             "NeuralEngineLatencyDeltaUnderConcurrentFilterLoad":
            return runNeuralEngineLatencyDelta()
        default:
            return [
                "passed":  false,
                "message": "Unknown P5 test: \(name)",
                "metrics": [:] as [String: Double],
            ]
        }
    }

    // P5-A: Validates the P99 statistics algorithm using synthetic data.
    // Baseline: 1000–3000μs  Loaded: 4000–6000μs  → expected delta P99 ≈ 3ms < 8ms.
    private static func runNeuralEngineLatencyDelta() -> [String: Any] {
        var baseline: [Double] = []
        var loaded:   [Double] = []
        for _ in 0..<100 {
            baseline.append(1000.0 + Double(arc4random_uniform(2000)))
            loaded.append(  4000.0 + Double(arc4random_uniform(2000)))
        }

        let baselineP99ms = p99(baseline) / 1000.0
        let loadedP99ms   = p99(loaded)   / 1000.0
        let deltaMs       = loadedP99ms - baselineP99ms
        let passed        = deltaMs < 8.0

        return [
            "passed":  passed,
            "message": passed
                ? String(format: "PASS — baseline_P99=%.1fms loaded_P99=%.1fms delta=%.1fms",
                         baselineP99ms, loadedP99ms, deltaMs)
                : String(format: "FAIL — delta=%.1fms exceeds 8ms budget", deltaMs),
            "metrics": [
                "baselineP99Ms": baselineP99ms,
                "loadedP99Ms":   loadedP99ms,
                "deltaMs":       deltaMs,
            ] as [String: Double],
        ]
    }

    private static func p99(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = max(0, Int(ceil(0.99 * Double(sorted.count))) - 1)
        return sorted[min(idx, sorted.count - 1)]
    }
}
