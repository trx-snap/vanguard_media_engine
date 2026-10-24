// VGStreamingPlaybackCoordinator.swift
// Phase 4C8A — Native iOS Public Streaming Playback Parity Scaffold
// Phase 4C8Y — iOS playback network-profile policy parity with Android Phase 4C5B
// LOW_LATENCY live-edge experiment — stay within 2 s of the live edge (VGLiveEdgePolicy)
// LOW_LATENCY startup alignment experiment (Debug or explicit Release opt-in) — VGHLSStartupAlignment
// LOW_LATENCY interruption recovery experiment (same gating) — VGHLSRecovery over VGPlaybackGraph
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
import Network
import UIKit
import os

// MARK: - Network-profile policy (Phase 4C8Y)

/// Maps a raw Dart networkProfile string to the Android Phase 4C5B buffer/bitrate
/// policy and the equivalent AVFoundation knobs for AVPlayerItem and AVPlayer.
///
/// Profiles: AUTO | STABLE | CONSTRAINED | LOW_LATENCY
/// Invalid / unknown raw strings default to AUTO.
///
/// Android Phase 4C5B reference values (AdaptiveStreamingNetworkPolicy.kt L147-215):
///   AUTO        — customPolicyEnabled=false, all buffer/bitrate values nil/default.
///   STABLE      — min/max/start/rebuffer = 15000/50000/2500/5000 ms, no bitrate cap.
///   CONSTRAINED — min/max/start/rebuffer = 25000/60000/5000/8000 ms,
///                  maxVideoBitrate=800000, maxAudioBitrate=96000.
///   LOW_LATENCY — min/max/start/rebuffer = 3000/10000/1000/1500 ms, no bitrate cap.
///
/// iOS LOW_LATENCY additionally prioritises the live edge: a 1.2 s forward buffer,
/// AVPlayer's default waiting to minimise stalls, a configuredTimeOffsetFromLive of
/// 1.2 s and automaticallyPreservesTimeOffsetFromLive, so AVPlayer itself starts
/// and rebuffers at that offset. The coordinator's own live-position seeks
/// (VGLiveEdgePolicy) are disabled by livePositionSeeksEnabled. The other profiles
/// keep AVPlayer's live-offset defaults.
private struct VGStreamingNetworkPolicy {

    // ── Normalised profile ─────────────────────────────────────────────────────
    let profile: String   // "AUTO" | "STABLE" | "CONSTRAINED" | "LOW_LATENCY"
    let raw:     String   // original value passed from Dart (before normalisation)

    // ── Android Phase 4C5B diagnostic fields ──────────────────────────────────
    let customPolicyEnabled:                  Bool
    let minBufferMs:                          Int?
    let maxBufferMs:                          Int?
    let bufferForPlaybackMs:                  Int?
    let bufferForPlaybackAfterRebufferMs:     Int?
    let maxVideoBitrate:                      Int?
    let maxAudioBitrate:                      Int?
    let forceLowestBitrate:                   Bool
    let exceedVideoConstraintsIfNecessary:    Bool

    // ── AVFoundation application fields ───────────────────────────────────────
    let preferredForwardBufferDurationSeconds: Double
    let preferredPeakBitRate:                  Double
    let automaticallyWaitsToMinimizeStalling:  Bool
    /// AVPlayerItem.configuredTimeOffsetFromLive in seconds; nil leaves the default.
    let configuredTimeOffsetFromLiveSeconds:   Double?

    /// Whether the coordinator seeks the session to the live position at playback
    /// start and catches up when it falls behind (VGLiveEdgePolicy).
    var prioritisesLiveEdge: Bool { return configuredTimeOffsetFromLiveSeconds != nil }

    // MARK: Factory

    /// Normalises `rawProfile` to a known profile string (defaulting unknown
    /// values to AUTO) and returns the fully-populated policy for that profile.
    static func make(rawProfile: String) -> VGStreamingNetworkPolicy {
        let known: Set<String> = ["AUTO", "STABLE", "CONSTRAINED", "LOW_LATENCY"]
        let normalised = known.contains(rawProfile) ? rawProfile : "AUTO"
        return VGStreamingNetworkPolicy(profile: normalised, raw: rawProfile)
    }

    private init(profile: String, raw: String) {
        self.profile = profile
        self.raw     = raw

        switch profile {
        case "STABLE":
            customPolicyEnabled                 = true
            minBufferMs                         = 15_000
            maxBufferMs                         = 50_000
            bufferForPlaybackMs                 = 2_500
            bufferForPlaybackAfterRebufferMs    = 5_000
            maxVideoBitrate                     = nil
            maxAudioBitrate                     = nil
            forceLowestBitrate                  = false
            exceedVideoConstraintsIfNecessary   = true
            preferredForwardBufferDurationSeconds = 15.0
            preferredPeakBitRate                = 0.0
            automaticallyWaitsToMinimizeStalling = true
            configuredTimeOffsetFromLiveSeconds = nil

        case "CONSTRAINED":
            customPolicyEnabled                 = true
            minBufferMs                         = 25_000
            maxBufferMs                         = 60_000
            bufferForPlaybackMs                 = 5_000
            bufferForPlaybackAfterRebufferMs    = 8_000
            maxVideoBitrate                     = 800_000
            maxAudioBitrate                     = 96_000
            forceLowestBitrate                  = false
            exceedVideoConstraintsIfNecessary   = true
            preferredForwardBufferDurationSeconds = 25.0
            preferredPeakBitRate                = 896_000.0  // 800000 + 96000
            automaticallyWaitsToMinimizeStalling = true
            configuredTimeOffsetFromLiveSeconds = nil

        case "LOW_LATENCY":
            customPolicyEnabled                 = true
            minBufferMs                         = 3_000
            maxBufferMs                         = 10_000
            bufferForPlaybackMs                 = 1_000
            bufferForPlaybackAfterRebufferMs    = 1_500
            maxVideoBitrate                     = nil
            maxAudioBitrate                     = nil
            forceLowestBitrate                  = false
            exceedVideoConstraintsIfNecessary   = true
            preferredForwardBufferDurationSeconds = 1.2
            preferredPeakBitRate                = 0.0
            automaticallyWaitsToMinimizeStalling = true
            configuredTimeOffsetFromLiveSeconds = 1.2

        default: // AUTO — preserve AVPlayer defaults
            customPolicyEnabled                 = false
            minBufferMs                         = nil
            maxBufferMs                         = nil
            bufferForPlaybackMs                 = nil
            bufferForPlaybackAfterRebufferMs    = nil
            maxVideoBitrate                     = nil
            maxAudioBitrate                     = nil
            forceLowestBitrate                  = false
            exceedVideoConstraintsIfNecessary   = false
            preferredForwardBufferDurationSeconds = 0.0
            preferredPeakBitRate                = 0.0
            automaticallyWaitsToMinimizeStalling = true
            configuredTimeOffsetFromLiveSeconds = nil
        }
    }

    // MARK: AVFoundation application

    /// Applies the policy to `item` immediately after item creation.
    ///
    /// configuredTimeOffsetFromLive (iOS 13+) is where live playback begins after a
    /// live start or a seek to kCMTimePositiveInfinity. The item's
    /// automaticallyPreservesTimeOffsetFromLive is set to true, so AVPlayer seeks
    /// forward on its own after buffering to restore that offset. The coordinator's
    /// own catch-up seeks (VGLiveEdgePolicy) are disabled by livePositionSeeksEnabled.
    func apply(to item: AVPlayerItem) {
        item.preferredForwardBufferDuration = preferredForwardBufferDurationSeconds
        item.preferredPeakBitRate           = preferredPeakBitRate
        if let offsetSeconds = configuredTimeOffsetFromLiveSeconds {
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.configuredTimeOffsetFromLive = CMTime(seconds: offsetSeconds, preferredTimescale: 600)
        }
    }

    /// Applies the policy to `player` immediately after player creation.
    func apply(to player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
    }

    // MARK: Diagnostics map

    /// Returns the full diagnostic map with Android Phase 4C5B keys.
    func diagnosticsMap() -> [String: Any] {
        var map: [String: Any] = [
            "profile":                               profile,
            "customPolicyEnabled":                   customPolicyEnabled,
            "forceLowestBitrate":                    forceLowestBitrate,
            "exceedVideoConstraintsIfNecessary":     exceedVideoConstraintsIfNecessary,
            "preferredForwardBufferDurationSeconds": preferredForwardBufferDurationSeconds,
            "preferredPeakBitRate":                  preferredPeakBitRate,
            "automaticallyWaitsToMinimizeStalling":  automaticallyWaitsToMinimizeStalling,
            "raw":                                   raw,
        ]
        // Optional Int fields — include as NSNull when nil so Dart sees them as null.
        map["minBufferMs"]                      = minBufferMs.map { $0 as Any } ?? NSNull()
        map["maxBufferMs"]                      = maxBufferMs.map { $0 as Any } ?? NSNull()
        map["bufferForPlaybackMs"]              = bufferForPlaybackMs.map { $0 as Any } ?? NSNull()
        map["bufferForPlaybackAfterRebufferMs"] = bufferForPlaybackAfterRebufferMs.map { $0 as Any } ?? NSNull()
        map["maxVideoBitrate"]                  = maxVideoBitrate.map { $0 as Any } ?? NSNull()
        map["maxAudioBitrate"]                  = maxAudioBitrate.map { $0 as Any } ?? NSNull()
        map["configuredTimeOffsetFromLiveSeconds"] = configuredTimeOffsetFromLiveSeconds.map { $0 as Any } ?? NSNull()
        return map
    }
}

// MARK: - Live-edge policy (LOW_LATENCY)

/// The LOW_LATENCY experiment: stay within catchUpThresholdSeconds of the live edge,
/// accepting an occasional visible jump over continued high latency. The offset is
/// the valid seekable range's end minus the playhead, sampled about once a second
/// from the display link while the session plays a confirmed live item; two
/// consecutive samples over the threshold issue one seek to the live position
/// (kCMTimePositiveInfinity, which AVPlayer resolves to configuredTimeOffsetFromLive
/// behind the latest content), and nothing more until that seek completes and a
/// sample at or under reArmThresholdSeconds re-arms it. This is a playback policy;
/// it does not show that AVPlayer requested or negotiated LL-HLS.
private enum VGLiveEdgePolicy {
    static let sampleIntervalSeconds:   CFTimeInterval = 1.0
    static let catchUpThresholdSeconds: Double = 2.0
    static let reArmThresholdSeconds:   Double = 1.5
    static let consecutiveSamples:      Int = 2

    /// Experiment switch for the two coordinator seeks to the live position: the
    /// initial seek and the catch-up seek. false issues neither: the initial seek is
    /// decided as skipped (never pending, issued or retried), the sampler still runs
    /// but issues and counts no catch-up, and the only live positioning is AVPlayer's
    /// own live start at configuredTimeOffsetFromLive. true restores both seeks.
    static let livePositionSeeksEnabled: Bool = false
}

// MARK: - AVPlayer time-control status

private extension AVPlayer.TimeControlStatus {
    /// The session state this status stands for; nil for a status this build does
    /// not know, which leaves the state as it is.
    var vgSessionState: String? {
        switch self {
        case .playing:                      return "playing"
        case .waitingToPlayAtSpecifiedRate: return "buffering"
        case .paused:                       return "paused"
        @unknown default:                   return nil
        }
    }

    /// Diagnostic label reported in the snapshot.
    var vgLabel: String {
        switch self {
        case .playing:                      return "playing"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .paused:                       return "paused"
        @unknown default:                   return "unknown"
        }
    }
}

// MARK: - Internal session record

/// Internal per-session state held by VGStreamingPlaybackCoordinator.
private final class VGPlaybackSession {

    // ── Identity ──────────────────────────────────────────────────────────────
    let textureId:  Int64
    let sessionId:  String

    // ── Options (stored for snapshot cold-start before presentationSize) ──────
    let initialWidth:   Int
    let initialHeight:  Int
    let formatHint:     String   // "AUTO" | "HLS" | "DASH"
    let networkProfile: String   // normalised profile string from VGStreamingNetworkPolicy

    // ── Network policy (Phase 4C8Y) ───────────────────────────────────────────
    let networkPolicy: VGStreamingNetworkPolicy

    // ── AVFoundation graph ────────────────────────────────────────────────────
    /// The current asset/item/player/videoOutput. Replaced whole by an interruption
    /// recovery (VGHLSRecovery); the public identity above never changes.
    var graph: VGPlaybackGraph
    /// What the graph was built from, so a replacement is built the same way.
    let sourceURL:          URL
    let sourceAssetOptions: [String: Any]?
    var asset:       AVURLAsset              { return graph.asset }
    var item:        AVPlayerItem            { return graph.item }
    var player:      AVPlayer                { return graph.player }
    var videoOutput: AVPlayerItemVideoOutput { return graph.videoOutput }

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

    // ── Playback-health diagnostics (session-scoped, monotonic) ──────────────
    // AVPlayerItemPlaybackStalled notifications and AVPlayerItemVideoOutput copy
    // evidence. Times are CACurrentMediaTime() seconds. None of this proves that
    // a frame was composited or visible on screen.
    var playbackStalledCount:         Int = 0
    var lastPlaybackStalledAt:        CFTimeInterval? = nil
    var copiedPixelBufferCount:       Int = 0
    var lastCopiedItemTimeMs:         Int? = nil
    var lastCopiedItemTimeAdvancedAt: CFTimeInterval? = nil

    // ── KVO / notification tokens (current graph) ─────────────────────────────
    var statusObservation:       NSKeyValueObservation?
    var playerStatusObservation: NSKeyValueObservation?
    var timeControlStatusObservation: NSKeyValueObservation?
    var playedToEndToken:        NSObjectProtocol?
    var playbackStalledToken:    NSObjectProtocol?

    // ── Latency sampling (unified log) ────────────────────────────────────────
    var latencyRecorder: VGHLSLatencyRecorder?

    // ── Startup alignment and recovery (Debug / Release opt-in, LOW_LATENCY; main thread) ──
    /// Owns the current attempt's timing and native effects; the coordinator owns
    /// intent, the public state and the routes. Nil once ended or cancelled.
    var startupAlignment: VGHLSStartupAlignment?
    /// Eligibility, the generation, the phase and the attempt history; the
    /// coordinator feeds it events and acts on its decisions.
    var recoveryPolicy = VGHLSRecoveryPolicy(eligible: false)
    /// Watches ordinary fallback playback for an unowned pause; nil while a helper
    /// exists or outside the fallback phase.
    var fallbackObserver: VGHLSFallbackInterruptionObserver?
    /// The last valid presentation size and rotation, kept across a replacement
    /// until the fresh item reports its own.
    var cachedVideoWidth:      Int? = nil
    var cachedVideoHeight:     Int? = nil
    var cachedRotationDegrees: Int? = nil
    /// Whether the caller's last control asked for playback (play or autoPlay)
    /// rather than a pause, stop, end or failure.
    var intendedPlaying: Bool = false
    /// Session-scoped and kept across graph replacements: a buffer was copied from
    /// a ready live item while playback was intended and AVPlayer reported playing.
    /// A poster frame of a paused item never sets it. Read by the manual-pause policy.
    var hasStartedLivePlayback: Bool = false
    /// Advanced by every control and terminal transition; a seek completion that
    /// finds another epoch leaves the state alone.
    var controlEpoch: Int = 0
    /// The state the first of overlapping seeks returns to; cleared by the completion
    /// that applies it and retired by every other control or terminal transition.
    var seekReturnState: String? = nil

    // ── Live-edge policy (LOW_LATENCY only; main thread) ─────────────────────
    // See VGLiveEdgePolicy and VGStreamingPlaybackCoordinator.sampleLiveEdge.
    /// Armed at the first playback start; cleared once the initial seek is issued
    /// or the item proves not to be live.
    var liveEdgeInitialSeekPending: Bool = false
    /// True once the initial seek was issued, ruled out, or pre-empted by a caller
    /// start position, so pause/resume and later Play calls never repeat it.
    var liveEdgeInitialSeekDecided: Bool = false
    var liveEdgeInitialSeekIssued:  Bool = false
    /// A live-position seek was issued and has not completed; nothing else is issued.
    var liveEdgeSeekInFlight:       Bool = false
    /// Cleared by a catch-up seek; set again by a sample at or under the re-arm threshold.
    var liveEdgeCatchUpArmed:       Bool = true
    var liveEdgeHighOffsetSamples:  Int  = 0
    var liveEdgeCatchUpSeekCount:   Int  = 0
    var lastLiveEdgeSampleAt:       CFTimeInterval? = nil

    // ── Disposed guard ────────────────────────────────────────────────────────
    var disposed = false

    // ── Proxy route (Phase 4C6H2A) ────────────────────────────────────────────
    /// Non-nil when playback is routed through VGStreamingLocalProxyServer.
    var proxyRouteId: String? = nil
    /// Whether cache/proxy was requested by the Dart caller.
    var playbackCacheEnabled: Bool = false
    /// True once a proxy route is successfully attached and telemetry is live.
    var playbackCacheTelemetryAttached: Bool = false
    /// Non-zero when proxy setup failed and direct playback is used as fallback.
    var playbackCacheIgnoredCount: Int = 0

    init(
        textureId:          Int64,
        sessionId:          String,
        initialWidth:       Int,
        initialHeight:      Int,
        formatHint:         String,
        networkPolicy:      VGStreamingNetworkPolicy,
        graph:              VGPlaybackGraph,
        sourceURL:          URL,
        sourceAssetOptions: [String: Any]?,
        texture:            VGPlaybackFlutterTexture,
        registry:           FlutterTextureRegistry
    ) {
        self.textureId          = textureId
        self.sessionId          = sessionId
        self.initialWidth       = initialWidth
        self.initialHeight      = initialHeight
        self.formatHint         = formatHint
        self.networkProfile     = networkPolicy.profile
        self.networkPolicy      = networkPolicy
        self.graph              = graph
        self.sourceURL          = sourceURL
        self.sourceAssetOptions = sourceAssetOptions
        self.texture            = texture
        self.registry           = registry
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

    // Diagnostic-only cumulative counters, guarded by `lock`. They record Flutter
    // copyPixelBuffer() callback activity; they do not prove GPU composition or
    // visible display.
    private var _copyPixelBufferRequestCount: Int = 0
    private var _copyPixelBufferReturnedCount: Int = 0

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
        _copyPixelBufferRequestCount += 1
        let buf = _latestPixelBuffer
        if buf != nil { _copyPixelBufferReturnedCount += 1 }
        lock.unlock()
        guard let buf = buf else { return nil }
        return Unmanaged.passRetained(buf)
    }

    /// Thread-safe snapshot of cumulative copyPixelBuffer() request and
    /// non-nil-return counts (diagnostic only).
    func callbackCounters() -> (requests: Int, returned: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_copyPixelBufferRequestCount, _copyPixelBufferReturnedCount)
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
        let formatHint      = ((args?["formatHint"]    as? String) ?? "AUTO").uppercased()
        let rawNetworkProfile = ((args?["networkProfile"] as? String) ?? "AUTO").uppercased().trimmingCharacters(in: .whitespaces)
        let networkPolicy   = VGStreamingNetworkPolicy.make(rawProfile: rawNetworkProfile)
        let httpHeaders     = args?["httpHeaders"]   as? [String: String]
        let autoPlay        = args?["autoPlay"]      as? Bool ?? true
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

        // ── 4a. Parse cache/proxy options (Phase 4C6H2A) ─────────────────────
        let cacheEnabled: Bool = {
            // cacheOptions is a nested dict; support both flat and nested forms.
            if let cacheOpts = args?["cacheOptions"] as? [String: Any] {
                return cacheOpts["cacheEnabled"] as? Bool ?? false
            }
            return args?["cacheEnabled"] as? Bool ?? false
        }()

        // ── 5. Build AVURLAsset — proxy route when cacheEnabled && HLS/AUTO ──
        // DASH is already rejected above; HLS/AUTO are eligible.
        // If proxy setup fails, fall back to direct URL (playback must not fail).
        var assetURL = url
        var assetOptions: [String: Any] = [:]
        var sessionProxyRouteId: String? = nil
        var sessionCacheTelemetry = false
        var sessionCacheIgnored = 0

        if cacheEnabled {
            do {
                let route = try VGStreamingLocalProxyServer.shared.proxiedURL(
                    for:            url,
                    headers:        httpHeaders,
                    formatHint:     formatHint,
                    networkProfile: networkPolicy.profile
                )
                assetURL = route.proxyURL
                sessionProxyRouteId = route.routeId
                sessionCacheTelemetry = true
                // Do NOT attach httpHeaders to AVURLAsset when proxied;
                // the proxy owns upstream headers.
            } catch {
                // Proxy setup failed — fall back to direct origin URL.
                assetURL = url
                if let headers = httpHeaders, !headers.isEmpty {
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
                }
                sessionCacheIgnored = 1
            }
        } else {
            // Cache not requested — direct playback with caller headers on AVURLAsset.
            if let headers = httpHeaders, !headers.isEmpty {
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
        }

        // ── 6–7. Build the graph: asset, output, item, player (Phase 4C8Y policy) ──
        let sourceAssetOptions: [String: Any]? = assetOptions.isEmpty ? nil : assetOptions
        let graph = VGPlaybackGraph.build(
            url:               assetURL,
            assetOptions:      sourceAssetOptions,
            applyItemPolicy:   { networkPolicy.apply(to: $0) },
            applyPlayerPolicy: { networkPolicy.apply(to: $0) }
        )

        // ── 8. Register Flutter texture ───────────────────────────────────────
        let texture   = VGPlaybackFlutterTexture()
        let textureId = textureRegistry.register(texture)

        // ── 9. Assign session identity ────────────────────────────────────────
        sessionCounter += 1
        let sessionId = "ios-4c8a-\(textureId)-\(sessionCounter)"

        // ── 10. Build and store session record ────────────────────────────────
        let session = VGPlaybackSession(
            textureId:          textureId,
            sessionId:          sessionId,
            initialWidth:       initialWidth,
            initialHeight:      initialHeight,
            formatHint:         formatHint,
            networkPolicy:      networkPolicy,
            graph:              graph,
            sourceURL:          assetURL,
            sourceAssetOptions: sourceAssetOptions,
            texture:            texture,
            registry:           textureRegistry
        )
        // ── Phase 4C6H2A: populate proxy state on session ─────────────────────
        session.playbackCacheEnabled          = cacheEnabled
        session.proxyRouteId                  = sessionProxyRouteId
        session.playbackCacheTelemetryAttached = sessionCacheTelemetry
        session.playbackCacheIgnoredCount     = sessionCacheIgnored
        sessions[textureId] = session

        // ── 11. Observe the graph and start latency sampling (Debug only) ─────
        attachGraphObservers(session: session, generation: 1)
        installLatencyRecorder(session: session)

        // ── 11b. LOW_LATENCY startup alignment and recovery eligibility ──────
        // Active in Debug builds and explicit Release opt-in builds
        // (VG_HLS_STARTUP_ALIGNMENT_EXPERIMENT). Only when the coordinator's own
        // live-position seeks are disabled, the caller chose no start position
        // (that position is kept) and playback is direct: a proxy route that
        // failed to attach still counts as direct. The attempt itself starts with
        // the first playback intent, and a ready item with a definite duration
        // skips it and rules out recovery. Other profiles and unflagged Release
        // builds never attempt one and never reconstruct.
        let alignmentEligible: Bool
        #if DEBUG || VG_HLS_STARTUP_ALIGNMENT_EXPERIMENT
        let hasExplicitStartPosition = startPositionMs.map { $0 >= 0 } ?? false
        alignmentEligible = networkPolicy.profile == "LOW_LATENCY"
            && !VGLiveEdgePolicy.livePositionSeeksEnabled
            && !hasExplicitStartPosition
            && sessionProxyRouteId == nil
        #else
        alignmentEligible = false
        #endif
        session.recoveryPolicy = VGHLSRecoveryPolicy(eligible: alignmentEligible)

        // ── 12. Install display link ──────────────────────────────────────────
        installDisplayLink(session: session)

        // ── 13. Initial seek if requested ─────────────────────────────────────
        if let ms = startPositionMs, ms >= 0 {
            let seekTime = CMTimeMakeWithSeconds(Double(ms) / 1000.0, preferredTimescale: 600)
            graph.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            // The caller's start position takes precedence over the live-edge policy's
            // initial seek; the catch-up still applies once playing.
            session.liveEdgeInitialSeekDecided = true
        }

        // ── 14. Auto-play ─────────────────────────────────────────────────────
        if autoPlay {
            session.intendedPlaying = true
            graph.player.play()
            session.state = "buffering"
            armInitialLiveEdgeSeek(session: session)
            startStartupAlignmentIfEligible(session: session)
        } else {
            session.state = "opening"
        }

        // ── 15. Return snapshot ───────────────────────────────────────────────
        result(snapshot(session: session))
    }

    // MARK: - Route: play

    func play(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        // The retained observation first: a queued unowned pause or interruption is
        // applied now, so the policy sees it before it answers this Play. A Play
        // during an attempt is answered with a snapshot and interrupts nothing; an
        // armed or manually paused session in the background keeps its permission
        // and stays paused; in the foreground it is rebuilt by this one Play.
        session.startupAlignment?.refreshExternalState()
        session.fallbackObserver?.refreshExternalState()
        let applicationActive = UIApplication.shared.applicationState == .active
        switch applyRecovery(session, .explicitPlay(applicationActive: applicationActive)) {
        case .snapshotOnly:
            switch session.recoveryPolicy.phase {
            case .armed, .manuallyPaused:
                logRecovery("playDeferred", session: session, ["applicationActive=\(applicationActive)"])
            default:
                break
            }
            result(snapshot(session: session))
            return
        case .reconstruct(let generation):
            reconstructGraph(session: session, generation: generation)
            result(snapshot(session: session))
            return
        case .ordinaryPlay, .startAlignment, .none:
            break
        }
        session.intendedPlaying = true
        session.controlEpoch += 1
        session.seekReturnState = nil
        session.player.play()
        if session.state == "seeking" {
            // A Play supersedes a pending seek: the state follows the player again and
            // the seek's completion, now on an older epoch, is ignored.
            session.state = nativeRunningState(session: session) ?? "buffering"
        } else if session.state == "paused" || session.state == "idle" || session.state == "opening" {
            session.state = "buffering"
        }
        resumeDisplayLink(session: session)
        // The first Play of a session created without autoPlay is its initial playback
        // start; once decided, this is a no-op for every later resume.
        armInitialLiveEdgeSeek(session: session)
        startStartupAlignmentIfEligible(session: session)
        result(snapshot(session: session))
    }

    // MARK: - Route: pause

    func pause(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        // What the policy judges is read before this route changes any of it: the
        // generation, whether the item is ready and live, whether this session has
        // played live, and whether a seek is still pending.
        let generation    = session.recoveryPolicy.generation
        let readyLive     = isReadyLive(session)
        let hasPlayedLive = session.hasStartedLivePlayback
        let seekPending   = session.state == "seeking" || session.seekReturnState != nil
        let phaseBefore   = session.recoveryPolicy.phase
        // Ends any alignment attempt and fallback observation before the player is
        // touched; the attempt is never retried. The policy then decides whether this
        // Pause lets one later explicit Play reconstruct.
        invalidateFallbackObserver(session: session)
        cancelStartupAlignment(session: session, reason: "pause")
        applyRecovery(session, .manualPause(generation: generation, readyLive: readyLive,
                                            hasPlayedLive: hasPlayedLive, seekPending: seekPending))
        // One record per Pause the policy weighed; a Pause it ignored logs nothing.
        let weighed: Bool
        switch phaseBefore {
        case .aligning, .aligned, .fallback, .armed, .manuallyPaused, .reconstructing: weighed = true
        case .disqualified(let reason):                                                weighed = reason == "seek"
        default:                                                                       weighed = false
        }
        if weighed {
            let armed: Bool
            if case .manuallyPaused = session.recoveryPolicy.phase { armed = true } else { armed = false }
            logRecovery(armed ? "manualPauseArmed" : "manualPauseDeclined", session: session,
                        ["readyLive=\(readyLive)", "hasPlayedLive=\(hasPlayedLive)", "seekPending=\(seekPending)"])
        }
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
        session.player.pause()
        session.state = "paused"
        // Only a resulting fallback phase gets an observer; it is idle while intent is false.
        installFallbackObserver(session: session)
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

        // The user's chosen position is kept: the alignment attempt ends for this
        // session before the seek. A pause the attempt owned is undone first when
        // playback is still intended, so the seek lands in a playing session; an
        // ordinary paused seek stays paused.
        let ownedPause = disqualifyStartupAlignment(session: session, reason: "seek")
        session.controlEpoch += 1
        if ownedPause, session.intendedPlaying,
           session.player.currentItem === session.item,
           session.player.status != .failed, session.item.status != .failed,
           UIApplication.shared.applicationState == .active {
            session.player.play()
        }

        let prevState = session.state
        let epoch = session.controlEpoch
        // The first of overlapping seeks owns the state to return to; a later one
        // must not return to "seeking".
        if session.state != "seeking" {
            session.seekReturnState = session.state
        }
        session.state = "seeking"
        let seekTime = CMTimeMakeWithSeconds(Double(positionMs) / 1000.0, preferredTimescale: 600)
        // Diagnostic record for LOW_LATENCY sessions only; playback never reads the id.
        let diagnosticOperationId: UInt64? = session.networkProfile == "LOW_LATENCY"
            ? session.latencyRecorder?.beginSeek(reason: .user, target: seekTime)
            : nil
        let generation = session.recoveryPolicy.generation
        let graph = session.graph
        session.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak session, weak graph] finished in
            let callbackArrivalSeconds = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return }
                // A later control or terminal transition owns the state by now; the
                // first of overlapping seeks chose the state to return to.
                if finished, session.controlEpoch == epoch {
                    let returnState = session.seekReturnState ?? prevState
                    session.seekReturnState = nil
                    session.state = (returnState == "playing" || returnState == "buffering" || returnState == "seeking")
                        ? (session.player.timeControlStatus.vgSessionState ?? "buffering")
                        : returnState
                }
                if let operationId = diagnosticOperationId {
                    session.latencyRecorder?.completeSeek(
                        operationId: operationId, finished: finished, callbackArrivalSeconds: callbackArrivalSeconds)
                }
            }
        }
        result(snapshot(session: session))
    }

    // MARK: - Route: stop

    func stop(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let session = resolveSession(args: args, result: result) else { return }
        // Ends any alignment attempt before the player is touched; never retried.
        disqualifyStartupAlignment(session: session, reason: "stop")
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
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
                session.state = nativeRunningState(session: session)
                    ?? ((session.player.rate > 0) ? "playing" : "paused")
            }
            attemptInitialLiveEdgeSeek(session: session)
        case .failed:
            markNativeFailure(session: session, reason: "item_failed")
        default:
            break
        }
    }

    private func handlePlayerStatusChange(session: VGPlaybackSession) {
        if session.player.status == .failed {
            markNativeFailure(session: session, reason: "player_failed")
        }
    }

    /// A native failure: the policy fails first, then the attempt and the fallback
    /// observation end without a resume; failed is final for the session.
    private func markNativeFailure(session: VGPlaybackSession, reason: String) {
        applyRecovery(session, .failed(generation: session.recoveryPolicy.generation))
        cancelStartupAlignment(session: session, reason: reason)
        invalidateFallbackObserver(session: session)
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
        if session.state != "failed", !session.recoveryPolicy.isDisabled {
            logRecovery("failed", session: session, ["reason=\(reason)"])
        }
        session.state = "failed"
    }

    /// Keeps the reported state in step with AVPlayer: waiting is buffering, playing
    /// is playing, and a pause AVPlayer took on its own is paused. Only the running
    /// states move; paused, idle, seeking, ended and failed are owned by the routes
    /// and the other callbacks. The current status is read, not the KVO change, so a
    /// late callback cannot report an older transition.
    private func handleTimeControlStatusChange(session: VGPlaybackSession) {
        guard session.state == "playing" || session.state == "buffering" else { return }
        if let next = nativeRunningState(session: session) {
            session.state = next
        }
    }

    /// AVPlayer's time-control status as a session state, with one exception: a
    /// pause the alignment attempt owns is still reported as buffering.
    private func nativeRunningState(session: VGPlaybackSession) -> String? {
        guard let next = session.player.timeControlStatus.vgSessionState else { return nil }
        if next == "paused", session.startupAlignment?.ownsPause == true { return "buffering" }
        return next
    }

    /// AVPlayerItemDidPlayToEndTime for the current item: ended is final for the
    /// session, and no reconstruction follows.
    private func handlePlayedToEnd(session: VGPlaybackSession) {
        applyRecovery(session, .eof(generation: session.recoveryPolicy.generation))
        cancelStartupAlignment(session: session, reason: "played_to_end")
        invalidateFallbackObserver(session: session)
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
        session.state = "ended"
    }

    /// AVPlayerItemPlaybackStalled for the current item: counted, and forwarded to
    /// an attempt in progress only. A stall in ordinary playback changes nothing else.
    private func handlePlaybackStalled(session: VGPlaybackSession) {
        session.playbackStalledCount += 1
        session.lastPlaybackStalledAt = CACurrentMediaTime()
        session.startupAlignment?.playbackStalled()
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
        let now = CACurrentMediaTime()
        // Pull new pixel buffers for all active sessions.
        for session in sessions.values {
            guard !session.disposed else { continue }

            // The live-edge policy samples here, about once a second per session.
            sampleLiveEdge(session: session, now: now)

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
            // The alignment path starts from an invalid display time, so a copy that
            // leaves it unwritten is never read as time zero.
            var actualItemTime: CMTime = session.startupAlignment != nil ? .invalid : .zero
            guard let pixelBuffer = session.videoOutput.copyPixelBuffer(
                forItemTime: itemTime, itemTimeForDisplay: &actualItemTime
            ) else { continue }
            session.texture.update(pixelBuffer: pixelBuffer)
            session.renderedFrames += 1
            session.decodedFrames  += 1
            session.registry.textureFrameAvailable(session.textureId)
            // Copy evidence only: a buffer left AVPlayerItemVideoOutput. The state is not
            // promoted here; it follows AVPlayer's time-control status.
            session.copiedPixelBufferCount += 1
            let copiedItemTimeMs: Int? = actualItemTime.isNumeric ? Int(actualItemTime.seconds * 1000) : nil
            if copiedItemTimeMs != session.lastCopiedItemTimeMs {
                session.lastCopiedItemTimeMs = copiedItemTimeMs
                session.lastCopiedItemTimeAdvancedAt = CACurrentMediaTime()
            }
            // Live playback history for the manual-pause policy: a copy from a ready
            // live item while intended and natively playing. Never cleared.
            if !session.hasStartedLivePlayback, session.intendedPlaying,
               session.player.timeControlStatus == .playing, isReadyLive(session) {
                session.hasStartedLivePlayback = true
            }
            // Copied-frame evidence for the alignment attempt; it only records here.
            session.startupAlignment?.observeCopiedFrame(
                displayTime: actualItemTime, queryTime: itemTime, hostSeconds: hostSeconds)
        }
    }

    // MARK: - Live-edge policy (LOW_LATENCY)

    /// Arms the one initial seek to the live position at a LOW_LATENCY session's first
    /// playback start and tries it at once. A no-op once decided: issued, ruled out
    /// for a non-live item, pre-empted by a caller start position, or skipped by
    /// VGLiveEdgePolicy.livePositionSeeksEnabled.
    private func armInitialLiveEdgeSeek(session: VGPlaybackSession) {
        guard session.networkPolicy.prioritisesLiveEdge, !session.liveEdgeInitialSeekDecided else { return }
        guard VGLiveEdgePolicy.livePositionSeeksEnabled else {
            // Experiment: skipped and decided; never pending, issued or retried.
            session.liveEdgeInitialSeekDecided = true
            return
        }
        session.liveEdgeInitialSeekPending = true
        attemptInitialLiveEdgeSeek(session: session)
    }

    /// Issues the pending initial seek once the item is ready, confirmed live and has a
    /// valid seekable range, and playback is not paused. A ready item with a definite
    /// duration rules the seek out: VOD is never seeked to an edge. Otherwise it waits
    /// and is tried again by the item-status callback, the next Play and the sampler.
    private func attemptInitialLiveEdgeSeek(session: VGPlaybackSession) {
        guard session.liveEdgeInitialSeekPending, !session.disposed,
              session.item.status == .readyToPlay, session.player.status != .failed else { return }
        guard isLiveItem(session.item) else {
            session.liveEdgeInitialSeekPending = false
            session.liveEdgeInitialSeekDecided = true
            return
        }
        guard session.player.rate > 0, liveSeekableEndSeconds(item: session.item) != nil else { return }
        session.liveEdgeInitialSeekPending = false
        session.liveEdgeInitialSeekDecided = true
        session.liveEdgeInitialSeekIssued  = true
        seekToLivePosition(session: session, reason: .initialLiveEdge)
    }

    /// Samples the live offset for a LOW_LATENCY session: the valid seekable range's
    /// end minus the playhead, once per VGLiveEdgePolicy.sampleIntervalSeconds, only
    /// while the session is playing a ready live item and no live-position seek is in
    /// flight. Two consecutive samples over catchUpThresholdSeconds issue one seek,
    /// which disarms the catch-up until a sample at or under reArmThresholdSeconds.
    /// VOD, an item without a valid live seekable range, paused, waiting or seeking
    /// playback, and a disposed or failed session take no sample, and the consecutive
    /// count starts over after any such gap. A pending initial seek is tried instead.
    /// With VGLiveEdgePolicy.livePositionSeeksEnabled false the samples are still
    /// taken but no seek is issued or counted.
    private func sampleLiveEdge(session: VGPlaybackSession, now: CFTimeInterval) {
        guard session.networkPolicy.prioritisesLiveEdge, !session.disposed else { return }
        if let last = session.lastLiveEdgeSampleAt, now - last < VGLiveEdgePolicy.sampleIntervalSeconds { return }
        session.lastLiveEdgeSampleAt = now
        if session.liveEdgeInitialSeekPending {
            attemptInitialLiveEdgeSeek(session: session)
            return
        }
        guard !session.liveEdgeSeekInFlight else { return }
        let player = session.player
        let item   = session.item
        let positionSeconds = player.currentTime().seconds
        guard session.state == "playing", player.timeControlStatus == .playing,
              player.status != .failed, item.status == .readyToPlay,
              !positionSeconds.isNaN, !positionSeconds.isInfinite,
              let seekableEndSeconds = liveSeekableEndSeconds(item: item) else {
            session.liveEdgeHighOffsetSamples = 0
            return
        }
        let offsetSeconds = max(0.0, seekableEndSeconds - positionSeconds)
        if offsetSeconds <= VGLiveEdgePolicy.reArmThresholdSeconds {
            session.liveEdgeCatchUpArmed = true
        }
        guard offsetSeconds > VGLiveEdgePolicy.catchUpThresholdSeconds else {
            session.liveEdgeHighOffsetSamples = 0
            return
        }
        session.liveEdgeHighOffsetSamples += 1
        // Experiment: the sample is taken, but no catch-up is issued or counted.
        guard VGLiveEdgePolicy.livePositionSeeksEnabled else { return }
        if session.liveEdgeCatchUpArmed && session.liveEdgeHighOffsetSamples >= VGLiveEdgePolicy.consecutiveSamples {
            session.liveEdgeCatchUpArmed = false
            session.liveEdgeCatchUpSeekCount += 1
            seekToLivePosition(session: session, reason: .catchUpLiveEdge)
        }
    }

    /// One seek to the live position: kCMTimePositiveInfinity, which AVPlayer resolves
    /// to configuredTimeOffsetFromLive behind the latest content. The reported state is
    /// left to AVPlayer's time-control status. The completion only clears the in-flight
    /// flag, and is ignored after teardown or a graph replacement. `reason` and the
    /// recorder calls are diagnostic only; the seek itself is unchanged.
    private func seekToLivePosition(session: VGPlaybackSession, reason: VGHLSSeekReason) {
        // Recorded before the flag writes below, so the snapshot still shows the
        // consecutive-high count that triggered a catch-up.
        let diagnosticOperationId = session.latencyRecorder?.beginSeek(reason: reason, target: .positiveInfinity)
        session.liveEdgeSeekInFlight      = true
        session.liveEdgeHighOffsetSamples = 0
        let generation = session.recoveryPolicy.generation
        let graph = session.graph
        session.player.seek(to: .positiveInfinity) { [weak self, weak session, weak graph] finished in
            let callbackArrivalSeconds = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return }
                session.liveEdgeSeekInFlight = false
                if let operationId = diagnosticOperationId {
                    session.latencyRecorder?.completeSeek(
                        operationId: operationId, finished: finished, callbackArrivalSeconds: callbackArrivalSeconds)
                }
            }
        }
    }

    /// Whether the item is live: no definite duration. Meaningful once the item is ready.
    private func isLiveItem(_ item: AVPlayerItem) -> Bool {
        let seconds = item.duration.seconds
        return item.duration.isIndefinite || seconds.isNaN || seconds.isInfinite
    }

    /// The end of the item's valid live seekable range in seconds: the latest finite
    /// end over the seekable ranges with a positive finite duration; nil for an item
    /// that is not live or has no such range.
    private func liveSeekableEndSeconds(item: AVPlayerItem) -> Double? {
        guard isLiveItem(item) else { return nil }
        var maxEndSeconds: Double = -1.0
        for rangeValue in item.seekableTimeRanges {
            let range = rangeValue.timeRangeValue
            let startSeconds = range.start.seconds
            let durSeconds   = range.duration.seconds
            guard !startSeconds.isNaN, !startSeconds.isInfinite,
                  !durSeconds.isNaN, !durSeconds.isInfinite, durSeconds > 0 else { continue }
            let endSeconds = startSeconds + durSeconds
            if !endSeconds.isNaN && !endSeconds.isInfinite && endSeconds > maxEndSeconds {
                maxEndSeconds = endSeconds
            }
        }
        return maxEndSeconds >= 0 ? maxEndSeconds : nil
    }

    // MARK: - Startup alignment and recovery (Debug / Release opt-in, LOW_LATENCY)

    private static let recoveryLogger = Logger(subsystem: "com.vanguard.engine", category: "hls-startup")

    /// Feeds one event to the session's recovery policy and returns its decision.
    @discardableResult
    private func applyRecovery(_ session: VGPlaybackSession,
                               _ event: VGHLSRecoveryPolicy.Event) -> VGHLSRecoveryPolicy.Decision {
        return session.recoveryPolicy.handle(event)
    }

    /// Whether the current item is ready and live: what an interruption needs to
    /// arm a reconstruction.
    private func isReadyLive(_ session: VGPlaybackSession) -> Bool {
        return session.item.status == .readyToPlay && session.player.status != .failed
            && isLiveItem(session.item)
    }

    /// The helper's and the recorder's session id: the public id for generation 1,
    /// "<id>.g<n>" for a rebuilt generation. Diagnostics only; the public id is fixed.
    private func diagnosticSessionId(_ session: VGPlaybackSession) -> String {
        let generation = session.recoveryPolicy.generation
        return generation > 1 ? "\(session.sessionId).g\(generation)" : session.sessionId
    }

    /// One record per recovery transition, in the helper's key=value form; never a
    /// URL or a header.
    private func logRecovery(_ event: String, session: VGPlaybackSession, _ fields: [String] = []) {
        let policy = session.recoveryPolicy
        let line = (["hls-recovery", "event=\(event)", "sessionId=\(session.sessionId)",
                     "generation=\(policy.generation)", "phase=\(policy.phaseName)"] + fields)
            .joined(separator: " ")
        Self.recoveryLogger.notice("\(line, privacy: .public)")
    }

    /// Starts an attempt when the policy allows one: the generation-one attempt at
    /// the session's first playback intent, or the fresh generation's right after a
    /// reconstruction. Debug builds or explicit Release opt-in builds only. The helper
    /// owns the timing and the native effects; its outcomes arrive in
    /// handleStartupAlignmentEvent, possibly synchronously from start().
    private func startStartupAlignmentIfEligible(session: VGPlaybackSession) {
        #if DEBUG || VG_HLS_STARTUP_ALIGNMENT_EXPERIMENT
        guard !session.disposed, session.intendedPlaying, session.startupAlignment == nil else { return }
        let generation = session.recoveryPolicy.generation
        guard case .startAlignment = applyRecovery(session, .beginAlignment(generation: generation)) else { return }
        let graph = session.graph
        let alignment = VGHLSStartupAlignment(
            player:    graph.player,
            item:      graph.item,
            sessionId: diagnosticSessionId(session),
            isCurrentAndIntended: { [weak self, weak session, weak graph] in
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return false }
                return session.intendedPlaying && session.startupAlignment != nil
            },
            isLive: { [weak self, weak graph] in
                guard let self = self, let graph = graph else { return false }
                return self.isLiveItem(graph.item)
            },
            onEvent: { [weak self, weak session, weak graph] event in
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return }
                self.handleStartupAlignmentEvent(session: session, generation: generation, event: event)
            }
        )
        // Assigned, with the policy already aligning, before start() can end synchronously.
        session.startupAlignment = alignment
        alignment.start()
        #endif
    }

    /// Cancels the session's attempt, if any, and forgets it. Returns whether the
    /// attempt owned the player's pause; a cancel delivers no outcome, and the policy
    /// only records it.
    @discardableResult
    private func cancelStartupAlignment(session: VGPlaybackSession, reason: String) -> Bool {
        guard let alignment = session.startupAlignment else { return false }
        session.startupAlignment = nil
        applyRecovery(session, .cancelled(reason: reason, generation: session.recoveryPolicy.generation))
        return alignment.cancel(reason: reason)
    }

    /// A Pause, Stop or Seek: the policy is disqualified first, then the attempt and
    /// the fallback observation end. No reconstruction for the session's life.
    @discardableResult
    private func disqualifyStartupAlignment(session: VGPlaybackSession, reason: String) -> Bool {
        applyRecovery(session, .disqualify(reason: reason))
        invalidateFallbackObserver(session: session)
        return cancelStartupAlignment(session: session, reason: reason)
    }

    private func invalidateFallbackObserver(session: VGPlaybackSession) {
        session.fallbackObserver?.invalidate()
        session.fallbackObserver = nil
    }

    /// Applies one helper outcome: the policy event, then the existing resume or
    /// interruption effects. The helper has already restored its owned overrides.
    private func handleStartupAlignmentEvent(session: VGPlaybackSession, generation: UInt64,
                                             event: VGHLSStartupAlignment.Event) {
        guard session.startupAlignment != nil else { return }
        switch event {
        case .aligned:
            // Playback continues under AVPlayer's own status; nothing to write.
            applyRecovery(session, .aligned(generation: generation))
            if generation > 1 {
                // Copied-frame confirmation on the fresh item, not measured visible latency.
                logRecovery("recoveryAligned", session: session)
            }
        case .ended(let reason, let ownedPause):
            session.startupAlignment = nil
            switch reason.disposition {
            case .externalInterruption:
                // An unowned pause, inactivity, interruption or stall: playback stays
                // paused until the caller plays again; nothing restarts on its own.
                let readyLive = isReadyLive(session)
                session.intendedPlaying = false
                session.controlEpoch += 1
                session.seekReturnState = nil
                session.player.pause()
                session.state = "paused"
                applyRecovery(session, .interrupted(reason: reason, generation: generation, readyLive: readyLive))
                logInterruption(session: session, reason: reason, readyLive: readyLive, source: "helper")
                installFallbackObserver(session: session)
            case .nativeFailure:
                // Failed at once, whether or not the status callbacks have arrived yet.
                markNativeFailure(session: session, reason: "alignment_" + reason.rawValue)
            case .fallback:
                applyRecovery(session, .fallback(reason: reason, generation: generation))
                logRecovery("fallback", session: session, ["reason=\(reason.rawValue)"])
                // Ordinary playback. A pause the attempt owned is undone only for a
                // session still intended to play, still holding its item, foreground and
                // not failed; otherwise the state follows the player as it is now.
                if ownedPause, session.intendedPlaying,
                   session.player.currentItem === session.item,
                   session.player.status != .failed, session.item.status != .failed,
                   UIApplication.shared.applicationState == .active {
                    session.player.play()
                    session.state = "buffering"
                } else if session.state == "playing" || session.state == "buffering",
                          let next = session.player.timeControlStatus.vgSessionState {
                    session.state = next
                }
                installFallbackObserver(session: session)
            }
        }
    }

    /// Logs whether an interruption armed a reconstruction or left the session in
    /// an unarmed fallback.
    private func logInterruption(session: VGPlaybackSession, reason: VGHLSStartupEndReason,
                                 readyLive: Bool, source: String) {
        let armed: Bool
        if case .armed = session.recoveryPolicy.phase { armed = true } else { armed = false }
        logRecovery(armed ? "armed" : "unarmed", session: session,
                    ["reason=\(reason.rawValue)", "readyLive=\(readyLive)", "source=\(source)"])
    }

    /// Observes ordinary fallback playback for an unowned pause. Installed after an
    /// ordinary or an unarmed fallback only, never beside a helper; idle until the
    /// session intends to play, and only for a ready live item of the current graph.
    private func installFallbackObserver(session: VGPlaybackSession) {
        invalidateFallbackObserver(session: session)
        guard !session.disposed, session.startupAlignment == nil,
              case .fallback(let generation) = session.recoveryPolicy.phase else { return }
        let graph = session.graph
        session.fallbackObserver = VGHLSFallbackInterruptionObserver(
            player: graph.player,
            item:   graph.item,
            canObserve: { [weak self, weak session, weak graph] in
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph),
                      session.intendedPlaying, session.startupAlignment == nil, session.fallbackObserver != nil,
                      case .fallback(let current) = session.recoveryPolicy.phase, current == generation
                else { return false }
                return self.isReadyLive(session)
            },
            onInterruption: { [weak self, weak session, weak graph] reason in
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return }
                self.handleFallbackInterruption(session: session, generation: generation, reason: reason)
            }
        )
    }

    /// The fallback observer found the player paused by something other than the
    /// caller: the same effects as a helper interruption, then the policy decides
    /// whether the next explicit Play may reconstruct.
    private func handleFallbackInterruption(session: VGPlaybackSession, generation: UInt64,
                                            reason: VGHLSStartupEndReason) {
        session.fallbackObserver = nil
        let readyLive = isReadyLive(session)
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
        session.player.pause()
        session.state = "paused"
        applyRecovery(session, .interrupted(reason: reason, generation: generation, readyLive: readyLive))
        logInterruption(session: session, reason: reason, readyLive: readyLive, source: "fallback")
        installFallbackObserver(session: session)
    }

    /// Replaces the session's graph for the fresh generation the policy just
    /// entered, in this one main-thread turn, then plays it and starts that
    /// generation's attempt. The public session and texture identities are untouched,
    /// and the texture keeps its last buffer until the fresh item copies one. The
    /// retired graph is never reconnected.
    private func reconstructGraph(session: VGPlaybackSession, generation: UInt64) {
        session.controlEpoch += 1
        session.seekReturnState = nil
        // Cleanup only: the policy has already consumed the permission.
        if let alignment = session.startupAlignment {
            session.startupAlignment = nil
            alignment.cancel(reason: "reconstruct")
        }
        invalidateFallbackObserver(session: session)
        session.latencyRecorder?.stop()
        session.latencyRecorder = nil
        detachGraphObservers(session: session)
        session.graph.retireForReplacement()
        let policy = session.networkPolicy
        session.graph = VGPlaybackGraph.build(
            url:               session.sourceURL,
            assetOptions:      session.sourceAssetOptions,
            applyItemPolicy:   { policy.apply(to: $0) },
            applyPlayerPolicy: { policy.apply(to: $0) }
        )
        attachGraphObservers(session: session, generation: generation)
        installLatencyRecorder(session: session)
        // Per-item bookkeeping starts over; the session-wide counters carry on.
        session.lastCopiedItemTimeMs         = nil
        session.lastCopiedItemTimeAdvancedAt = nil
        session.liveEdgeSeekInFlight         = false
        session.liveEdgeHighOffsetSamples    = 0
        session.lastLiveEdgeSampleAt         = nil
        session.intendedPlaying = true
        session.state = "buffering"
        resumeDisplayLink(session: session)
        session.player.play()
        logRecovery("reconstruct", session: session,
                    ["attempt=\(session.recoveryPolicy.attemptCount)",
                     "trigger=\(session.recoveryPolicy.resumeTrigger?.rawValue ?? "none")"])
        startStartupAlignmentIfEligible(session: session)
    }

    // MARK: - Graph observers and latency sampling

    /// A main-thread hop that runs `body` only for a session still registered, not
    /// disposed, at `generation` and still holding `graph`: a callback queued before
    /// a dispose or a replacement finds out here, where the session map and the
    /// state live.
    private func onMainIfCurrent(_ session: VGPlaybackSession, generation: UInt64, graph: VGPlaybackGraph,
                                 _ body: @escaping (VGStreamingPlaybackCoordinator, VGPlaybackSession) -> Void)
        -> () -> Void {
        return { [weak self, weak session, weak graph] in
            DispatchQueue.main.async {
                guard let self = self, let session = session, let graph = graph,
                      self.isCurrent(session, generation: generation, graph: graph) else { return }
                body(self, session)
            }
        }
    }

    /// Installs the KVO and the two item notifications on the session's current graph.
    private func attachGraphObservers(session: VGPlaybackSession, generation: UInt64) {
        let graph = session.graph
        let onItemStatus   = onMainIfCurrent(session, generation: generation, graph: graph) { $0.handleItemStatusChange(session: $1) }
        let onPlayerStatus = onMainIfCurrent(session, generation: generation, graph: graph) { $0.handlePlayerStatusChange(session: $1) }
        // AVPlayer's own waiting/playing/paused transitions drive the reported state.
        let onTimeControl  = onMainIfCurrent(session, generation: generation, graph: graph) { $0.handleTimeControlStatusChange(session: $1) }
        let onPlayedToEnd  = onMainIfCurrent(session, generation: generation, graph: graph) { $0.handlePlayedToEnd(session: $1) }
        let onStalled      = onMainIfCurrent(session, generation: generation, graph: graph) { $0.handlePlaybackStalled(session: $1) }
        session.statusObservation            = graph.item.observe(\.status, options: [.new]) { _, _ in onItemStatus() }
        session.playerStatusObservation      = graph.player.observe(\.status, options: [.new]) { _, _ in onPlayerStatus() }
        session.timeControlStatusObservation = graph.player.observe(\.timeControlStatus, options: [.new]) { _, _ in onTimeControl() }
        let center = NotificationCenter.default
        session.playedToEndToken     = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: graph.item, queue: nil) { _ in onPlayedToEnd() }
        session.playbackStalledToken = center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: graph.item, queue: nil) { _ in onStalled() }
    }

    /// Removes what attachGraphObservers installed; called before the graph changes.
    private func detachGraphObservers(session: VGPlaybackSession) {
        session.statusObservation?.invalidate()
        session.statusObservation = nil
        session.playerStatusObservation?.invalidate()
        session.playerStatusObservation = nil
        session.timeControlStatusObservation?.invalidate()
        session.timeControlStatusObservation = nil
        let center = NotificationCenter.default
        if let token = session.playedToEndToken { center.removeObserver(token) }
        session.playedToEndToken = nil
        if let token = session.playbackStalledToken { center.removeObserver(token) }
        session.playbackStalledToken = nil
    }

    /// Starts per-session latency sampling on the current graph, Debug builds only:
    /// this coordinator also serves ordinary playback and .notice samples persist to
    /// the device log, so Release builds emit none.
    private func installLatencyRecorder(session: VGPlaybackSession) {
        #if DEBUG
        let latencyRecorder = VGHLSLatencyRecorder(
            sessionId:   diagnosticSessionId(session),
            player:      session.player,
            item:        session.item,
            stallCount:  { [weak session] in session?.playbackStalledCount ?? 0 },
            diagnostics: { [weak session] in
                // Value-only copy for the seek records; neutral once the session is gone.
                guard let session = session else { return .unavailable }
                return VGHLSDiagnosticSnapshot(
                    networkProfile:         session.networkProfile,
                    sessionState:           session.state,
                    initialSeekPending:     session.liveEdgeInitialSeekPending,
                    initialSeekDecided:     session.liveEdgeInitialSeekDecided,
                    initialSeekIssued:      session.liveEdgeInitialSeekIssued,
                    liveSeekInFlight:       session.liveEdgeSeekInFlight,
                    catchUpArmed:           session.liveEdgeCatchUpArmed,
                    consecutiveHighSamples: session.liveEdgeHighOffsetSamples,
                    catchUpSeekCount:       session.liveEdgeCatchUpSeekCount,
                    copiedPixelBufferCount: session.copiedPixelBufferCount,
                    lastCopiedItemTimeMs:   session.lastCopiedItemTimeMs
                )
            }
        )
        latencyRecorder.start()
        session.latencyRecorder = latencyRecorder
        #endif
    }


    // MARK: - Teardown

    private func teardown(session: VGPlaybackSession) {
        guard !session.disposed else { return }
        session.disposed = true
        // Intent, the control epoch and the recovery policy are retired at once, so
        // nothing queued behind this teardown can resume the player, write a state or
        // reconstruct.
        session.intendedPlaying = false
        session.controlEpoch += 1
        session.seekReturnState = nil
        applyRecovery(session, .dispose)

        // The alignment attempt and the fallback observation end next, before the
        // proxy route and the player are touched; no outcome is delivered for a
        // disposed session.
        cancelStartupAlignment(session: session, reason: "dispose")
        invalidateFallbackObserver(session: session)

        // ── Phase 4C6H2A: release proxy route before player cleanup ───────────
        if let routeId = session.proxyRouteId {
            VGStreamingLocalProxyServer.shared.release(routeId: routeId)
        }

        // Invalidate display link.
        session.displayLink?.invalidate()
        session.displayLink = nil

        // Stop latency sampling.
        session.latencyRecorder?.stop()
        session.latencyRecorder = nil

        // Pause player.
        session.player.pause()

        // Remove KVO and NotificationCenter observers for the current graph.
        detachGraphObservers(session: session)

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

        // ── Live offset / seekable range diagnostics ──────────────────────────
        var liveOffsetMs: Int? = nil
        var seekableStartMs: Int? = nil
        var seekableEndMs: Int? = nil

        let isLiveItem = item.duration.isIndefinite || durationSeconds.isNaN || durationSeconds.isInfinite || durationMs == -1
        if isLiveItem {
            var minStartSec: Double = .greatestFiniteMagnitude
            var maxEndSec: Double = -1.0
            var hasValidSeekable = false

            for rangeValue in item.seekableTimeRanges {
                let range = rangeValue.timeRangeValue
                let startSec = range.start.seconds
                let durSec = range.duration.seconds
                if !startSec.isNaN && !startSec.isInfinite && !durSec.isNaN && !durSec.isInfinite && durSec > 0 {
                    let endSec = startSec + durSec
                    if !endSec.isNaN && !endSec.isInfinite {
                        if startSec < minStartSec { minStartSec = startSec }
                        if endSec > maxEndSec { maxEndSec = endSec }
                        hasValidSeekable = true
                    }
                }
            }

            if hasValidSeekable && maxEndSec >= 0 {
                seekableStartMs = max(0, Int(minStartSec * 1000))
                seekableEndMs = max(0, Int(maxEndSec * 1000))
                if !positionSeconds.isNaN && !positionSeconds.isInfinite {
                    let offsetSec = max(0.0, maxEndSec - positionSeconds)
                    liveOffsetMs = Int(offsetSec * 1000)
                }
            }
        }

        // ── Video dimensions + rotation ───────────────────────────────────────
        // The last valid values are kept across a graph replacement until the fresh
        // item reports its own.
        let presentationSize = item.presentationSize
        if presentationSize.width > 0 && presentationSize.height > 0 {
            session.cachedVideoWidth  = Int(presentationSize.width)
            session.cachedVideoHeight = Int(presentationSize.height)
        }

        // Derive rotation from preferred transform of the first video track.
        if let track = item.asset.tracks(withMediaType: .video).first {
            let t       = track.preferredTransform
            let angleRad = atan2(t.b, t.a)
            let degreesRaw = Int((angleRad * 180.0 / .pi).rounded())
            let normalized = ((degreesRaw % 360) + 360) % 360
            switch normalized {
            case  45 ..< 135:  session.cachedRotationDegrees = 90
            case 135 ..< 225:  session.cachedRotationDegrees = 180
            case 225 ..< 315:  session.cachedRotationDegrees = 270
            default:           session.cachedRotationDegrees = 0
            }
        }

        let videoWidth    = session.cachedVideoWidth  ?? session.initialWidth
        let videoHeight   = session.cachedVideoHeight ?? session.initialHeight
        let rotationDeg   = session.cachedRotationDegrees ?? 0
        var displayWidth  = videoWidth
        var displayHeight = videoHeight
        if rotationDeg == 90 || rotationDeg == 270 {
            swap(&displayWidth, &displayHeight)
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

        // ── Network policy diagnostics (Phase 4C8Y) ───────────────────────────
        let policy = session.networkPolicy
        let textureCallbackCounters = session.texture.callbackCounters()

        // ── Playback-health diagnostics ───────────────────────────────────────
        // AVPlayer's own waiting/playing account, the item's buffer flags, stall
        // notifications and AVPlayerItemVideoOutput copy evidence. None of this
        // proves that a frame was composited or visible on screen.
        let now = CACurrentMediaTime()
        let waitingReason: Any = player.reasonForWaitingToPlay.map { reason -> String in
            switch reason {
            case .toMinimizeStalls:        return "toMinimizeStalls"
            case .evaluatingBufferingRate: return "evaluatingBufferingRate"
            case .noItemToPlay:            return "noItemToPlay"
            default:                       return vgSanitizeRawToken(reason.rawValue)
            }
        } ?? NSNull()
        let msSinceLastStall: Any = session.lastPlaybackStalledAt.map { Int((now - $0) * 1000) } ?? NSNull()
        let msSinceCopiedItemTimeAdvanced: Any = session.lastCopiedItemTimeAdvancedAt.map { Int((now - $0) * 1000) } ?? NSNull()

        var map: [String: Any] = [
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
            "liveOffsetMs":                  liveOffsetMs ?? NSNull(),
            "seekableStartMs":               seekableStartMs ?? NSNull(),
            "seekableEndMs":                 seekableEndMs ?? NSNull(),
            // Live-edge policy (LOW_LATENCY only; diagnostic only).
            "liveEdgeInitialSeekIssued":     session.liveEdgeInitialSeekIssued,
            "liveEdgeCatchUpSeekCount":      session.liveEdgeCatchUpSeekCount,
            "liveEdgeSeekInFlight":          session.liveEdgeSeekInFlight,
            "videoWidth":                    videoWidth,
            "videoHeight":                   videoHeight,
            "rotationDegrees":               rotationDeg,
            "displayWidth":                  displayWidth,
            "displayHeight":                 displayHeight,
            "renderedFrames":                session.renderedFrames,
            "decodedFrames":                 session.decodedFrames,
            // Flutter copyPixelBuffer() callback activity (diagnostic only; not proof
            // of GPU composition or visible display).
            "textureCopyPixelBufferRequestCount":  textureCallbackCounters.requests,
            "textureCopyPixelBufferReturnedCount": textureCallbackCounters.returned,
            // Playback-health diagnostics (diagnostic only; not proof of visible
            // presentation).
            "playerTimeControlStatus":       player.timeControlStatus.vgLabel,
            "playerWaitingReason":           waitingReason,
            "isPlaybackBufferEmpty":         item.isPlaybackBufferEmpty,
            "isPlaybackLikelyToKeepUp":      item.isPlaybackLikelyToKeepUp,
            "playbackStalledCount":          session.playbackStalledCount,
            "msSinceLastPlaybackStall":      msSinceLastStall,
            "copiedPixelBufferCount":        session.copiedPixelBufferCount,
            "lastCopiedItemTimeMs":          session.lastCopiedItemTimeMs ?? NSNull(),
            "msSinceCopiedItemTimeAdvanced": msSinceCopiedItemTimeAdvanced,
            "playbackCacheEnabled":           session.playbackCacheEnabled,
            "playbackCacheTelemetryAttached": session.playbackCacheTelemetryAttached,
            "playbackCacheBytesRead":         {
                // Live bytes-fetched counter from the proxy registry (pass-through slice).
                if let routeId = session.proxyRouteId {
                    let m = VGStreamingLocalProxyServer.shared.metrics(routeId: routeId)
                    return m["bytesFetched"] as? Int ?? 0
                }
                return 0
            }(),
            "playbackCacheSizeBytes":         VGStreamingLocalProxyDiskCache.shared.totalCacheSizeBytes(),
            "playbackCacheIgnoredCount":      session.playbackCacheIgnoredCount,
            // Network-profile diagnostics (Phase 4C8Y)
            "networkProfile":                            policy.profile,
            "streamingNetworkProfile":                   policy.profile,
            "streamingNetworkPolicy":                    policy.diagnosticsMap(),
            "preferredForwardBufferDurationSeconds":     policy.preferredForwardBufferDurationSeconds,
            "preferredPeakBitRate":                      policy.preferredPeakBitRate,
            // The player's actual value: an alignment attempt may have changed it.
            "automaticallyWaitsToMinimizeStalling":      player.automaticallyWaitsToMinimizeStalling,
            "raw": "phase=Phase4C8A;sessionId=\(session.sessionId);state=\(stateStr);format=\(formatStr)"
                  + vgRawDiagnosticsSuffix(session: session)
        ]
        return map
    }

    // MARK: - Phase 4C6H2A raw-diagnostics suffix

    /// Builds the semicolon-delimited suffix appended to the `raw` snapshot field.
    ///
    /// Safe rules:
    ///  - No URLs, signed query strings, headers, auth values, cookies, or server addresses.
    ///  - ASCII only; values are stripped of non-ASCII / non-printable bytes.
    ///  - Returns "" when no extra information is available.
    private func vgRawDiagnosticsSuffix(session: VGPlaybackSession) -> String {
        var parts: [String] = []

        // ── Proxy route metrics ───────────────────────────────────────────────
        if let routeId = session.proxyRouteId {
            let m = VGStreamingLocalProxyServer.shared.metrics(routeId: routeId)
            let reqCount   = m["requestCount"] as? Int ?? 0
            let bytesFetch = m["bytesFetched"]  as? Int ?? 0
            parts.append("proxyRequestCount=\(reqCount)")
            parts.append("proxyBytesFetched=\(bytesFetch)")
            // Phase 4C6H2B — disk cache counters (safe numerics only).
            let cacheHits       = m["cacheHitCount"]   as? Int ?? 0
            let cacheMisses     = m["cacheMissCount"]  as? Int ?? 0
            let cacheBytesRead  = m["cacheBytesRead"]  as? Int ?? 0
            parts.append("proxyCacheHits=\(cacheHits)")
            parts.append("proxyCacheMisses=\(cacheMisses)")
            parts.append("proxyCacheBytesRead=\(cacheBytesRead)")
        }
        // Disk size is global (not per-route); always append when non-zero.
        let diskSize = VGStreamingLocalProxyDiskCache.shared.totalCacheSizeBytes()
        if diskSize > 0 {
            parts.append("proxyDiskSizeBytes=\(diskSize)")
        }

        // ── AVPlayerItem error ────────────────────────────────────────────────
        if let itemErr = session.item.error as NSError? {
            parts.append("itemErrorDomain=\(vgSanitizeRawToken(itemErr.domain))")
            parts.append("itemErrorCode=\(itemErr.code)")
        }

        // ── AVPlayer error ────────────────────────────────────────────────────
        if let playerErr = session.player.error as NSError? {
            parts.append("playerErrorDomain=\(vgSanitizeRawToken(playerErr.domain))")
            parts.append("playerErrorCode=\(playerErr.code)")
        }

        // ── AVPlayerItem error-log last entry ─────────────────────────────────
        if let errorLog = session.item.errorLog(),
           let last = errorLog.events.last {
            parts.append("itemErrorLogStatus=\(last.errorStatusCode)")
            let comment = vgSanitizeRawToken(last.errorComment ?? "")
            if !comment.isEmpty {
                parts.append("itemErrorLogComment=\(comment)")
            }
        }

        // ── Startup alignment and recovery (Debug / Release opt-in, LOW_LATENCY) ──
        // The existing keys keep their meaning (the outcome is the last helper's);
        // the generation-one history and the recovery state are separate tokens.
        let recovery = session.recoveryPolicy
        if recovery.initialAttempted {
            parts.append("startupAlignmentPhase=\(vgSanitizeRawToken(session.startupAlignment?.phaseName ?? "none"))")
            parts.append("startupAlignmentOutcome=\(vgSanitizeRawToken(recovery.lastHelperOutcome))")
            parts.append("startupAlignmentOwnsPause=\(session.startupAlignment?.ownsPause ?? false)")
            parts.append("startupInitialOutcome=\(vgSanitizeRawToken(recovery.initialOutcome))")
        }
        if recovery.initialAttempted || !recovery.isDisabled {
            parts.append("recoveryPhase=\(vgSanitizeRawToken(recovery.phaseName))")
            parts.append("recoveryGeneration=\(recovery.generation)")
            parts.append("recoveryAttempts=\(recovery.attemptCount)")
            parts.append("recoveryAligned=\(recovery.alignedCount)")
            parts.append("recoveryTrigger=\(vgSanitizeRawToken(recovery.resumeTrigger?.rawValue ?? "none"))")
        }

        guard !parts.isEmpty else { return "" }
        return ";" + parts.joined(separator: ";")
    }

    /// Strips non-ASCII, non-printable bytes, and semicolons from a token
    /// destined for the raw diagnostic string.  Capped at 80 chars to bound log size.
    private func vgSanitizeRawToken(_ s: String) -> String {
        let sanitized = s.unicodeScalars.compactMap { scalar -> Character? in
            let v = scalar.value
            // Allow printable ASCII (0x20–0x7E) excluding semicolons (0x3B).
            guard v >= 0x20, v <= 0x7E, v != 0x3B else { return nil }
            return Character(scalar)
        }
        let result = String(sanitized.prefix(80))
        return result.isEmpty ? "unknown" : result
    }

    // MARK: - Helpers

    /// Whether `session` is still registered for its texture, not disposed, at
    /// `generation` and still holding `graph`: what every queued callback requires.
    private func isCurrent(_ session: VGPlaybackSession, generation: UInt64, graph: VGPlaybackGraph) -> Bool {
        return !session.disposed && sessions[session.textureId] === session
            && session.recoveryPolicy.generation == generation && session.graph === graph
    }

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
