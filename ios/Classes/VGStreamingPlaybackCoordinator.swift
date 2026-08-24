// VGStreamingPlaybackCoordinator.swift
// Phase 4C8A — Native iOS Public Streaming Playback Parity Scaffold
//
// Implements AVPlayer HLS / LL-HLS backend for VGStreamingPlaybackClient
// public Dart routes. Owns FlutterTextureRegistry, session map, AVURLAsset,
// AVPlayerItem, AVPlayer, AVPlayerItemVideoOutput, and a CADisplayLink frame pump.
//
// Threading model:
//   Main thread  — Flutter MethodChannel calls (create/play/pause/seek/stop/
//                  diagnose/dispose) + CADisplayLink callback + KVO callbacks.
//   Background   — none: AVPlayer drives its own networking + decode queues.
//
// Opus P1-A: This coordinator NEVER touches VanguardEngineMode or switchToMode.
//            AVPlayer playback does not contend for camera/editor/export encoder
//            ownership. No cross-wiring with the engine mode state machine.

import AVFoundation
import Flutter
import UIKit

// MARK: - Internal session record

/// Internal per-session state held by VGStreamingPlaybackCoordinator.
private final class VGPlaybackSession {

    // ── Identity ──────────────────────────────────────────────────────────────
    let textureId:  Int64
    let sessionId:  String

    // ── Options (stored for snapshot cold-start before presentationSize) ──────
    let initialWidth:  Int
    let initialHeight: Int
    let formatHint:    String   // "AUTO" | "HLS" | "DASH"
    let networkProfile: String

    // ── AVFoundation objects ──────────────────────────────────────────────────
    let asset:       AVURLAsset
    let item:        AVPlayerItem
    let player:      AVPlayer
    let videoOutput: AVPlayerItemVideoOutput

    // ── Flutter texture ───────────────────────────────────────────────────────
    let texture:   VGPlaybackFlutterTexture
    let registry:  FlutterTextureRegistry

    // ── Display link ──────────────────────────────────────────────────────────
    var displayLink: CADisplayLink?

    // ── State ─────────────────────────────────────────────────────────────────
    var state: String = "opening"   // "opening"|"buffering"|"playing"|"paused"|
                                    // "seeking"|"idle"|"ended"|"failed"

    // ── Metrics ───────────────────────────────────────────────────────────────
    var renderedFrames: Int = 0
    var decodedFrames:  Int = 0

    // ── KVO tokens ────────────────────────────────────────────────────────────
    var statusObservation:       NSKeyValueObservation?
    var playerStatusObservation: NSKeyValueObservation?

    // ── Disposed guard ────────────────────────────────────────────────────────
    var disposed = false

    init(
        textureId:      Int64,
        sessionId:      String,
        initialWidth:   Int,
        initialHeight:  Int,
        formatHint:     String,
        networkProfile: String,
        asset:          AVURLAsset,
        item:           AVPlayerItem,
        player:         AVPlayer,
        videoOutput:    AVPlayerItemVideoOutput,
        texture:        VGPlaybackFlutterTexture,
        registry:       FlutterTextureRegistry
    ) {
        self.textureId      = textureId
        self.sessionId      = sessionId
        self.initialWidth   = initialWidth
        self.initialHeight  = initialHeight
        self.formatHint     = formatHint
        self.networkProfile = networkProfile
        self.asset          = asset
        self.item           = item
        self.player         = player
        self.videoOutput    = videoOutput
        self.texture        = texture
        self.registry       = registry
    }
}

// MARK: - Flutter texture producer

/// Minimal FlutterTexture implementor that retains the latest pixel buffer from AVPlayerItemVideoOutput.
///
/// Buffer lifecycle:
///   - `update(pixelBuffer:)` is set under `lock` from the display-link callback.
///   - `copyPixelBuffer()` is called by Flutter's raster thread; it retains and returns the
///     current buffer without copying, releasing the previous reference held by Flutter after compositing.
///   - On dispose, `invalidate()` drops the final retained buffer.
final class VGPlaybackFlutterTexture: NSObject, FlutterTexture {

    private let lock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?

    /// Called from the display-link callback with a newly pulled BGRA buffer.
    /// Thread-safe; retains `buffer` and releases the previous one.
    func update(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        _latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    /// Called by Flutter's compositor raster thread.
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        let buf = _latestPixelBuffer
        lock.unlock()
        guard let buf = buf else { return nil }
        return Unmanaged.passRetained(buf)
    }

    /// Drops the retained buffer. Call on dispose to release GPU memory.
    func invalidate() {
        lock.lock()
        _latestPixelBuffer = nil
        lock.unlock()
    }
}

// MARK: - CADisplayLink weak proxy
//
// CADisplayLink retains its target strongly, which would create a retain cycle:
//   coordinator → session.displayLink → coordinator (via target).
// VGDisplayLinkProxy holds only a *weak* reference to the real coordinator and
// forwards the selector, so the display link cannot prevent deallocation of
// VGStreamingPlaybackCoordinator.

private final class VGDisplayLinkProxy: NSObject {
    weak var coordinator: VGStreamingPlaybackCoordinator?

    init(coordinator: VGStreamingPlaybackCoordinator) {
        self.coordinator = coordinator
    }

    @objc func displayLinkFired(_ sender: CADisplayLink) {
        coordinator?.displayLinkFired(sender)
    }
}

// MARK: - Coordinator

/// Phase 4C8A public streaming playback coordinator.
///
/// - Owned by `VanguardMediaEnginePlugin` as a single lazy instance.
/// - Receives thin-routed calls from the plugin's `handle(_:result:)` guard block.
/// - All entry points must be called on the main thread (Flutter MethodChannel guarantee).
final class VGStreamingPlaybackCoordinator {

    // MARK: Dependencies

    private let textureRegistry: FlutterTextureRegistry

    // MARK: Session map (main thread only)

    private var sessions: [Int64: VGPlaybackSession] = [:]
    private var sessionCounter: Int = 0

    // MARK: Init

    init(textureRegistry: FlutterTextureRegistry) {
        self.textureRegistry = textureRegistry
    }

    deinit {
        disposeAll()
    }

    // MARK: - Route: create

    func create(args: [String: Any]?, result: @escaping FlutterResult) {
        // ── 1. Parse arguments defensively ────────────────────────────────────
        let uriStr         = (args?["uri"]            as? String) ?? ""
        // Accept NSNumber (Dart int/double codec) or plain Swift Int.
        let initialWidth: Int = {
            let raw = args?["initialWidth"]
            return (raw as? NSNumber)?.intValue ?? (raw as? Int) ?? 0
        }()
        let initialHeight: Int = {
            let raw = args?["initialHeight"]
            return (raw as? NSNumber)?.intValue ?? (raw as? Int) ?? 0
        }()
        let formatHint     = ((args?["formatHint"]    as? String) ?? "AUTO").uppercased()
        let networkProfile = ((args?["networkProfile"] as? String) ?? "AUTO").uppercased()
        let httpHeaders    = args?["httpHeaders"]   as? [String: String]
        let autoPlay       = args?["autoPlay"]      as? Bool ?? true
        // Accept NSNumber or Int for startPositionMs — mirrors seek/dispose defensive style.
        let startPositionMs: Int? = {
            guard let raw = args?["startPositionMs"] else { return nil }
            if let n = raw as? NSNumber { return n.intValue }
            if let i = raw as? Int      { return i }
            return nil
        }()

        // ── 2. Validate required fields ───────────────────────────────────────
        guard !uriStr.isEmpty else {
            result(failureMap(raw: "invalid_args;reason=uri_empty", state: "failed", textureId: -1))
            return
        }
        guard initialWidth > 0 else {
            result(failureMap(raw: "invalid_args;reason=initialWidth_not_positive", state: "failed", textureId: -1))
            return
        }
        guard initialHeight > 0 else {
            result(failureMap(raw: "invalid_args;reason=initialHeight_not_positive", state: "failed", textureId: -1))
            return
        }

        // ── 3. DASH rejection — typed map, not FlutterError ───────────────────
        let isDashHint = (formatHint == "DASH")
        let isDashUri  = uriStr.lowercased().hasSuffix(".mpd")
        if isDashHint || isDashUri {
            result([
                "pass":      false,
                "phase":     "Phase4C8A",
                "sessionId": "",
                "textureId": Int64(-1),
                "format":    "DASH",
                "state":     "failed",
                "durationMs":                    Int(-1),
                "positionMs":                    Int(0),
                "bufferedPositionMs":             Int(0),
                "bufferedPercent":               Int(0),
                "videoWidth":                    Int(0),
                "videoHeight":                   Int(0),
                "rotationDegrees":               Int(0),
                "displayWidth":                  Int(0),
                "displayHeight":                 Int(0),
                "renderedFrames":                Int(0),
                "decodedFrames":                 Int(0),
                "playbackCacheEnabled":           false,
                "playbackCacheTelemetryAttached": false,
                "playbackCacheBytesRead":         Int(0),
                "playbackCacheSizeBytes":         Int(0),
                "playbackCacheIgnoredCount":      Int(0),
                "raw": "unsupported_format;format=DASH;platform=ios;phase=Phase4C8A"
            ] as [String: Any])
            return
        }

        // ── 4. Resolve URL ────────────────────────────────────────────────────
        guard let url = URL(string: uriStr) else {
            result(failureMap(raw: "invalid_uri;uri=\(uriStr)", state: "failed", textureId: -1))
            return
        }

        // ── 5. Build AVURLAsset with optional HTTP headers ─────────────────────
        var assetOptions: [String: Any] = [:]
        if let headers = httpHeaders, !headers.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)

        // ── 6. Build AVPlayerItem + AVPlayerItemVideoOutput ────────────────────
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        let item = AVPlayerItem(asset: asset)
        item.add(videoOutput)

        // ── 7. Build AVPlayer ─────────────────────────────────────────────────
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = (networkProfile != "LOW_LATENCY")

        // ── 8. Register Flutter texture ───────────────────────────────────────
        let texture   = VGPlaybackFlutterTexture()
        let textureId = textureRegistry.register(texture)

        // ── 9. Assign session identity ────────────────────────────────────────
        sessionCounter += 1
        let sessionId = "ios-4c8a-\(textureId)-\(sessionCounter)"

        // ── 10. Build and store session record ────────────────────────────────
        let session = VGPlaybackSession(
            textureId:      textureId,
            sessionId:      sessionId,
            initialWidth:   initialWidth,
            initialHeight:  initialHeight,
            formatHint:     formatHint,
            networkProfile: networkProfile,
            asset:          asset,
            item:           item,
            player:         player,
            videoOutput:    videoOutput,
            texture:        texture,
            registry:       textureRegistry
        )
        sessions[textureId] = session

        // ── 11. Observe item status ───────────────────────────────────────────
        session.statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak session] _, _ in
            guard let self = self, let session = session, !session.disposed else { return }
            DispatchQueue.main.async { self.handleItemStatusChange(session: session) }
        }
        session.playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self, weak session] _, _ in
            guard let self = self, let session = session, !session.disposed else { return }
            DispatchQueue.main.async { self.handlePlayerStatusChange(session: session) }
        }

        // Observe playback-to-end notification for this item.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        // ── 12. Install display link ──────────────────────────────────────────
        installDisplayLink(session: session)

        // ── 13. Initial seek if requested ─────────────────────────────────────
        if let ms = startPositionMs, ms >= 0 {
            let seekTime = CMTimeMakeWithSeconds(Double(ms) / 1000.0, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // ── 14. Auto-play ─────────────────────────────────────────────────────
        if autoPlay {
            player.play()
            session.state = "buffering"
        } else {
            session.state = "opening"
        }

        // ── 15. Return snapshot ───────────────────────────────────────────────
        result(snapshot(session: session))
    }

    // MARK: - Route: play

    func play(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        session.player.play()
        if session.state == "paused" || session.state == "idle" || session.state == "opening" {
            session.state = "buffering"
        }
        resumeDisplayLink(session: session)
        result(snapshot(session: session))
    }

    // MARK: - Route: pause

    func pause(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        session.player.pause()
        session.state = "paused"
        result(snapshot(session: session))
    }

    // MARK: - Route: seek

    func seek(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        guard let rawMs = args?["positionMs"],
              let positionMs = (rawMs as? NSNumber).map({ $0.intValue }) ?? (rawMs as? Int),
              positionMs >= 0 else {
            result(failureMap(
                raw:       "invalid_args;reason=positionMs_missing_or_negative",
                state:     "failed",
                textureId: (args?["textureId"] as? NSNumber)?.int64Value ?? -1
            ))
            return
        }

        let prevState = session.state
        session.state = "seeking"
        let seekTime = CMTimeMakeWithSeconds(Double(positionMs) / 1000.0, preferredTimescale: 600)
        session.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak session] finished in
            guard let session = session, !session.disposed else { return }
            DispatchQueue.main.async {
                if finished {
                    session.state = (prevState == "playing" || prevState == "buffering") ? "buffering" : prevState
                }
            }
        }
        result(snapshot(session: session))
    }

    // MARK: - Route: stop

    func stop(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        session.player.pause()
        session.player.seek(to: .zero)
        session.state = "idle"
        result(snapshot(session: session))
    }

    // MARK: - Route: diagnose

    func diagnose(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        result(snapshot(session: session))
    }

    // MARK: - Route: dispose

    func dispose(args: [String: Any]?, result: @escaping FlutterResult) {
        let rawId     = args?["textureId"] as? NSNumber
        let textureId = rawId?.int64Value ?? -1
        guard textureId >= 0, let session = sessions[textureId] else {
            // Idempotent: already disposed or unknown — return small typed success.
            result([
                "pass":    true,
                "phase":   "Phase4C8A",
                "state":   "disposed",
                "raw":     "dispose_noop;textureId=\(textureId)"
            ] as [String: Any])
            return
        }
        teardown(session: session)
        sessions.removeValue(forKey: textureId)
        result([
            "pass":      true,
            "phase":     "Phase4C8A",
            "sessionId": session.sessionId,
            "textureId": textureId,
            "state":     "disposed",
            "raw":       "disposed;phase=Phase4C8A;textureId=\(textureId)"
        ] as [String: Any])
    }

    // MARK: - disposeAll (plugin detach / deinit path)

    /// Tears down every active session and clears the session map.
    ///
    /// Safe to call multiple times: `teardown` is guarded by `session.disposed`.
    /// Does NOT mutate VanguardEngineMode, AVAudioSession, LiveKit, WebRTC,
    /// cache state, or any other unrelated engine state.
    /// Called by the plugin on engine/plugin detach so that all CADisplayLinks,
    /// KVO observers, and registered Flutter textures are cleaned up even if the
    /// Dart side has not issued individual dispose calls.
    func disposeAll() {
        for session in sessions.values {
            teardown(session: session)
        }
        sessions.removeAll()
    }

    // MARK: - KVO / notification callbacks


    private func handleItemStatusChange(session: VGPlaybackSession) {
        switch session.item.status {
        case .readyToPlay:
            if session.state == "opening" || session.state == "buffering" {
                session.state = (session.player.rate > 0) ? "playing" : "paused"
            }
        case .failed:
            session.state = "failed"
        default:
            break
        }
    }

    private func handlePlayerStatusChange(session: VGPlaybackSession) {
        if session.player.status == .failed {
            session.state = "failed"
        }
    }

    @objc private func playerItemDidPlayToEnd(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              let session = sessions.values.first(where: { $0.item === item }) else { return }
        session.state = "ended"
    }

    // MARK: - Display link

    private func installDisplayLink(session: VGPlaybackSession) {
        // Use VGDisplayLinkProxy as target to prevent CADisplayLink from strongly
        // retaining self (VGStreamingPlaybackCoordinator), which would cause a
        // retain cycle: coordinator → session.displayLink → coordinator.
        let proxy = VGDisplayLinkProxy(coordinator: self)
        let dl = CADisplayLink(target: proxy, selector: #selector(VGDisplayLinkProxy.displayLinkFired(_:)))
        if #available(iOS 15.0, *) {
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
        } else {
            dl.preferredFramesPerSecond = 60
        }
        dl.add(to: .main, forMode: .common)
        session.displayLink = dl
    }

    private func resumeDisplayLink(session: VGPlaybackSession) {
        if let dl = session.displayLink {
            dl.isPaused = false
        } else {
            installDisplayLink(session: session)
        }
    }

    // Called by VGDisplayLinkProxy — internal (not private) so the proxy defined
    // in the same file can call it without exposing the method as public API.
    func displayLinkFired(_ sender: CADisplayLink) {
        // Pull new pixel buffers for all active sessions.
        for session in sessions.values {
            guard !session.disposed else { continue }

            // Convert the display link's host timestamp to the player item's timeline.
            //
            // AVPlayerItemVideoOutput.hasNewPixelBuffer(forItemTime:) and
            // copyPixelBuffer(forItemTime:itemTimeForDisplay:) both expect a CMTime
            // expressed in the AVPlayerItem's timeline, NOT a raw CMClock host time.
            //
            // itemTime(forHostTime:) performs the correct host-time → item-time
            // conversion internally.  We prefer sender.targetTimestamp (the predicted
            // vblank time of the upcoming frame, available iOS 10+) over
            // sender.timestamp (the time the callback fired) because it is closer to
            // the actual display moment and therefore selects the most up-to-date
            // decoded frame.
            let hostSeconds: Double
            if #available(iOS 10.0, *) {
                hostSeconds = sender.targetTimestamp
            } else {
                hostSeconds = sender.timestamp
            }
            let itemTime = session.videoOutput.itemTime(forHostTime: hostSeconds)
            guard itemTime.isValid else { continue }
            guard session.videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { continue }
            var actualItemTime = CMTime.zero
            guard let pixelBuffer = session.videoOutput.copyPixelBuffer(
                forItemTime: itemTime, itemTimeForDisplay: &actualItemTime
            ) else { continue }
            session.texture.update(pixelBuffer: pixelBuffer)
            session.renderedFrames += 1
            session.decodedFrames  += 1
            session.registry.textureFrameAvailable(session.textureId)
            // Promote buffering → playing when frames are arriving.
            if session.state == "buffering" || session.state == "opening" {
                session.state = "playing"
            }
        }
    }


    // MARK: - Teardown

    private func teardown(session: VGPlaybackSession) {
        guard !session.disposed else { return }
        session.disposed = true

        // Invalidate display link.
        session.displayLink?.invalidate()
        session.displayLink = nil

        // Pause player.
        session.player.pause()

        // Remove KVO observers.
        session.statusObservation?.invalidate()
        session.statusObservation = nil
        session.playerStatusObservation?.invalidate()
        session.playerStatusObservation = nil

        // Remove NotificationCenter observer for this specific item.
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: session.item)

        // Remove video output from item.
        session.item.remove(session.videoOutput)

        // Unregister texture and release GPU memory.
        textureRegistry.unregisterTexture(session.textureId)
        session.texture.invalidate()
    }

    // MARK: - Snapshot builder

    /// Builds the full typed snapshot map expected by `VGStreamingPlaybackSession.fromMap`.
    private func snapshot(session: VGPlaybackSession) -> [String: Any] {
        let player = session.player
        let item   = session.item

        // ── Position / duration ───────────────────────────────────────────────
        let positionSeconds = player.currentTime().seconds
        let positionMs: Int = (positionSeconds.isNaN || positionSeconds.isInfinite)
            ? 0 : max(0, Int(positionSeconds * 1000))

        let durationSeconds = item.duration.seconds
        let durationMs: Int = (durationSeconds.isNaN || durationSeconds.isInfinite)
            ? -1 : max(0, Int(durationSeconds * 1000))

        // ── Buffered metrics ──────────────────────────────────────────────────
        var bufferedPositionMs = 0
        var bufferedPercent    = 0
        for rangeValue in item.loadedTimeRanges {
            let range = rangeValue.timeRangeValue
            let endSec = (range.start + range.duration).seconds
            if !endSec.isNaN && !endSec.isInfinite && endSec > positionSeconds {
                bufferedPositionMs = max(bufferedPositionMs, Int(endSec * 1000))
                break
            }
        }
        if durationMs > 0 && bufferedPositionMs > 0 {
            bufferedPercent = min(100, Int(Double(bufferedPositionMs) / Double(durationMs) * 100))
        }

        // ── Video dimensions + rotation ───────────────────────────────────────
        var videoWidth    = session.initialWidth
        var videoHeight   = session.initialHeight
        var rotationDeg   = 0
        var displayWidth  = session.initialWidth
        var displayHeight = session.initialHeight

        let presentationSize = item.presentationSize
        if presentationSize.width > 0 && presentationSize.height > 0 {
            videoWidth    = Int(presentationSize.width)
            videoHeight   = Int(presentationSize.height)
            displayWidth  = videoWidth
            displayHeight = videoHeight
        }

        // Derive rotation from preferred transform of the first video track.
        if let track = item.asset.tracks(withMediaType: .video).first {
            let t       = track.preferredTransform
            let angleRad = atan2(t.b, t.a)
            let degreesRaw = Int((angleRad * 180.0 / .pi).rounded())
            let normalized = ((degreesRaw % 360) + 360) % 360
            switch normalized {
            case  45 ..< 135:  rotationDeg = 90
            case 135 ..< 225:  rotationDeg = 180
            case 225 ..< 315:  rotationDeg = 270
            default:           rotationDeg = 0
            }
            if rotationDeg == 90 || rotationDeg == 270 {
                swap(&displayWidth, &displayHeight)
            }
        }

        // ── Format string ─────────────────────────────────────────────────────
        // AUTO resolves to HLS on AVPlayer; DASH is rejected at create time.
        let formatStr = "HLS"

        // ── State string ──────────────────────────────────────────────────────
        let stateStr: String = {
            if session.disposed { return "disposed" }
            if player.status == .failed || item.status == .failed { return "failed" }
            return session.state
        }()

        let pass = stateStr != "failed" && stateStr != "disposed"

        return [
            "pass":      pass,
            "phase":     "Phase4C8A",
            "sessionId": session.sessionId,
            "textureId": session.textureId,
            "format":    formatStr,
            "state":     stateStr,
            "durationMs":                    durationMs,
            "positionMs":                    positionMs,
            "bufferedPositionMs":             bufferedPositionMs,
            "bufferedPercent":               bufferedPercent,
            "videoWidth":                    videoWidth,
            "videoHeight":                   videoHeight,
            "rotationDegrees":               rotationDeg,
            "displayWidth":                  displayWidth,
            "displayHeight":                 displayHeight,
            "renderedFrames":                session.renderedFrames,
            "decodedFrames":                 session.decodedFrames,
            "playbackCacheEnabled":           false,
            "playbackCacheTelemetryAttached": false,
            "playbackCacheBytesRead":         0,
            "playbackCacheSizeBytes":         0,
            "playbackCacheIgnoredCount":      0,
            "raw": "phase=Phase4C8A;sessionId=\(session.sessionId);state=\(stateStr);format=\(formatStr)"
        ] as [String: Any]
    }

    // MARK: - Helpers

    /// Looks up the session for the `textureId` in `args`.
    /// Returns `nil` and calls `result` with a typed failure map when not found.
    @discardableResult
    private func resolveSession(args: [String: Any]?, result: FlutterResult) -> VGPlaybackSession? {
        let rawId     = args?["textureId"] as? NSNumber
        let textureId = rawId?.int64Value ?? -1
        guard textureId >= 0, let session = sessions[textureId] else {
            result(failureMap(
                raw:       "not_found;textureId=\(textureId);phase=Phase4C8A",
                state:     "failed",
                textureId: textureId
            ))
            return nil
        }
        return session
    }

    /// Builds the minimal typed failure map required by `VGStreamingPlaybackSession.fromMap`.
    private func failureMap(raw: String, state: String, textureId: Int64) -> [String: Any] {
        return [
            "pass":      false,
            "phase":     "Phase4C8A",
            "sessionId": "",
            "textureId": textureId,
            "format":    "HLS",
            "state":     state,
            "durationMs":                    Int(-1),
            "positionMs":                    Int(0),
            "bufferedPositionMs":             Int(0),
            "bufferedPercent":               Int(0),
            "videoWidth":                    Int(0),
            "videoHeight":                   Int(0),
            "rotationDegrees":               Int(0),
            "displayWidth":                  Int(0),
            "displayHeight":                 Int(0),
            "renderedFrames":                Int(0),
            "decodedFrames":                 Int(0),
            "playbackCacheEnabled":           false,
            "playbackCacheTelemetryAttached": false,
            "playbackCacheBytesRead":         Int(0),
            "playbackCacheSizeBytes":         Int(0),
            "playbackCacheIgnoredCount":      Int(0),
            "raw": raw
        ] as [String: Any]
    }
}
