// VGDuetNativeSessionCoordinator.swift
// VG-DUET-SLICE-2: Native session lifecycle and local source ingestion validation.
//
// Responsibilities:
//   - Validates local .mp4/.mov source via AVURLAsset (no camera, no Metal, no recorder).
//   - Manages the Duet session state machine (initialized → recording → paused → stopped).
//   - Enforces single active session invariant.
//   - Threading: probe runs on a serial DispatchQueue; replies always on main thread.
//   - Generates wall-clock-based segment records for lifecycle-only proof output.
//
// Out of scope: AVCaptureSession, Metal, GLES, Vulkan, real media recording,
//               Camera2, GPU compositor, Universal Editor wiring.

import AVFoundation
import Flutter
import Foundation

// MARK: - State machine

enum VGDuetSessionState {
    case initialized
    case recording
    case paused
    case stopped
}

// MARK: - Segment record (wall-clock, lifecycle only)

struct VGDuetSegmentRecord {
    let index: Int
    let durationMs: Int
    let speedMultiplier: Double
    let sourceStartMs: Int
    let sourceEndMs: Int
    let outputStartMs: Int
    let outputEndMs: Int

    func toMap() -> [String: Any] {
        return [
            "segmentIndex":     index,
            "durationMs":       durationMs,
            "speedMultiplier":  speedMultiplier,
            "sourceStartMs":    sourceStartMs,
            "sourceEndMs":      sourceEndMs,
            "outputStartMs":    outputStartMs,
            "outputEndMs":      outputEndMs,
        ]
    }
}

// MARK: - Source probe result

struct VGDuetSourceProbeResult {
    let durationMs: Int
    let hasVideoTrack: Bool
    let hasAudioTrack: Bool
}

// MARK: - Session

final class VGDuetNativeSession {
    let sessionId: String
    let sourceMap: [String: Any]
    let trimWindowMap: [String: Any]

    // Configuration set via update* calls
    var layoutConfigMap: [String: Any]
    var speedMultiplier: Double
    var sourceGain: Double
    var micGain: Double

    // State
    var state: VGDuetSessionState = .initialized

    // Segment tracking (wall-clock)
    private var segments: [VGDuetSegmentRecord] = []
    private var segmentStartWallMs: Int64 = 0
    private var outputCursorMs: Int = 0
    private var sourceCursorMs: Int = 0

    // Trim
    let trimStartMs: Int
    let trimEndMs: Int

    // Source probe result (recorded for descriptor assembly)
    var probeResult: VGDuetSourceProbeResult?

    init(sessionId: String,
         sourceMap: [String: Any],
         trimWindowMap: [String: Any],
         layoutConfigMap: [String: Any],
         speedMultiplier: Double,
         sourceGain: Double,
         micGain: Double,
         trimStartMs: Int,
         trimEndMs: Int) {
        self.sessionId       = sessionId
        self.sourceMap       = sourceMap
        self.trimWindowMap   = trimWindowMap
        self.layoutConfigMap = layoutConfigMap
        self.speedMultiplier = speedMultiplier
        self.sourceGain      = sourceGain
        self.micGain         = micGain
        self.trimStartMs     = trimStartMs
        self.trimEndMs       = trimEndMs
    }

    func startSegment() {
        segmentStartWallMs = Int64(Date().timeIntervalSince1970 * 1000)
    }

    func commitSegment() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let wallMs = max(1, Int(nowMs - segmentStartWallMs))
        let segStartOut = outputCursorMs
        let segEndOut   = outputCursorMs + wallMs
        let segStartSrc = sourceCursorMs
        let segEndSrc   = sourceCursorMs + wallMs

        let rec = VGDuetSegmentRecord(
            index:           segments.count,
            durationMs:      wallMs,
            speedMultiplier: speedMultiplier,
            sourceStartMs:   segStartSrc,
            sourceEndMs:     segEndSrc,
            outputStartMs:   segStartOut,
            outputEndMs:     segEndOut
        )
        segments.append(rec)
        outputCursorMs = segEndOut
        sourceCursorMs = segEndSrc
    }

    func deleteLastSegment() -> Bool {
        guard !segments.isEmpty else { return false }
        let removed = segments.removeLast()
        outputCursorMs = removed.outputStartMs
        sourceCursorMs = removed.sourceStartMs
        return true
    }

    func totalDurationMs() -> Int { outputCursorMs }
    func segmentCount() -> Int { segments.count }

    func buildStopResult() -> [String: Any] {
        let segmentMaps = segments.map { $0.toMap() }
        let descriptor: [String: Any] = [
            "source":           sourceMap,
            "layoutConfig":     layoutConfigMap,
            "trimWindow":       trimWindowMap,
            "initialSpeed":     speedMultiplier,
            "segments":         segmentMaps,
            "sourceAudioGain":  sourceGain,
            "micAudioGain":     micGain,
            "sourceAudioMuted": sourceGain < 0.0001,
            "micAudioMuted":    micGain < 0.0001,
        ]
        return [
            "compositionDescriptor": descriptor,
            "totalDurationMs":       max(1, totalDurationMs()),
            "segmentCount":          max(1, segmentCount()),
            "segmentAssets":         [String](),
            "proofOutputPath":       NSNull(),
        ]
    }
}

// MARK: - Coordinator

/// Owns the single active Duet session and all lifecycle transitions.
/// All public methods are called on the main thread by VGDuetMethodHandler.
/// File probing runs on `probeQueue` and replies on the main thread.
final class VGDuetNativeSessionCoordinator {

    // MARK: Constants

    static let validSpeeds: [Double] = [0.3, 0.5, 1.0, 2.0, 3.0]

    // MARK: State

    private var activeSession: VGDuetNativeSession?
    private var canceledProbeIds = Set<String>()

    // Serial queue for AVURLAsset probing (never blocks main thread)
    private let probeQueue = DispatchQueue(label: "com.connects.vanguard.duet.probe",
                                           qos: .userInitiated)

    // MARK: - initialize

    func initializeSession(
        sourceMap:       [String: Any],
        trimWindowMap:   [String: Any],
        layoutConfigMap: [String: Any],
        speed:           Double,
        sourceGain:      Double,
        micGain:         Double,
        reply:           @escaping (String?, FlutterError?) -> Void
    ) {
        assert(Thread.isMainThread)

        if activeSession != nil {
            reply(nil, FlutterError(
                code:    "session_conflict",
                message: "A Duet session is already active. Dispose it before initializing a new one.",
                details: nil))
            return
        }

        guard let trimStartSec = (trimWindowMap["startSeconds"] as? NSNumber)?.doubleValue,
              let trimEndSec   = (trimWindowMap["endSeconds"]   as? NSNumber)?.doubleValue else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: trimWindow is missing startSeconds/endSeconds.",
                details: nil))
            return
        }

        let trimStartMs = Int(trimStartSec * 1000)
        let trimEndMs   = Int(trimEndSec   * 1000)

        guard let filePath = (sourceMap["filePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: source.filePath is empty or missing.",
                details: nil))
            return
        }

        guard Self.isValidSpeed(speed) else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: speed \(speed) is not one of \(Self.validSpeeds).",
                details: nil))
            return
        }
        guard sourceGain >= 0.0 && sourceGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "initializeDuetSession: sourceGain must be in [0.0, 1.0].", details: nil))
            return
        }
        guard micGain >= 0.0 && micGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "initializeDuetSession: micGain must be in [0.0, 1.0].", details: nil))
            return
        }

        let sessionId = UUID().uuidString
        let session = VGDuetNativeSession(
            sessionId:       sessionId,
            sourceMap:       sourceMap,
            trimWindowMap:   trimWindowMap,
            layoutConfigMap: layoutConfigMap,
            speedMultiplier: speed,
            sourceGain:      sourceGain,
            micGain:         micGain,
            trimStartMs:     trimStartMs,
            trimEndMs:       trimEndMs
        )
        // Optimistically store; cleared if probe fails or is cancelled
        activeSession = session

        let capturedFilePath    = filePath
        let capturedTrimStartMs = trimStartMs
        let capturedTrimEndMs   = trimEndMs

        probeQueue.async { [weak self] in
            guard let self = self else { return }

            let probeResult = Self.probeSource(filePath: capturedFilePath)

            DispatchQueue.main.async {
                // Cancelled by disposeSession while probe was in-flight
                if self.canceledProbeIds.contains(sessionId) {
                    self.canceledProbeIds.remove(sessionId)
                    // Do not reply — dispose already replied
                    return
                }

                switch probeResult {
                case .failure(let msg):
                    self.activeSession = nil
                    reply(nil, FlutterError(code: "source_invalid", message: msg, details: nil))

                case .success(let probe):
                    if let err = Self.validateTrimWindow(
                        trimStartMs:      capturedTrimStartMs,
                        trimEndMs:        capturedTrimEndMs,
                        sourceDurationMs: probe.durationMs
                    ) {
                        self.activeSession = nil
                        reply(nil, FlutterError(code: "source_invalid", message: err, details: nil))
                        return
                    }
                    session.probeResult = probe
                    reply(sessionId, nil)
                }
            }
        }
    }

    // MARK: - updateLayout

    func updateLayout(sessionId: String, layoutConfigMap: [String: Any], reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("updateDuetLayout", current: "stopped")); return
        default: break
        }
        if let modeName = layoutConfigMap["mode"] as? String, modeName == "pip",
           let rectMap  = layoutConfigMap["pipNormalizedRect"] as? [String: Any] {
            if let err = Self.validatePipRect(rectMap) {
                reply(nil, FlutterError(code: "source_invalid", message: err, details: nil)); return
            }
        }
        session.layoutConfigMap = layoutConfigMap
        reply(nil, nil)
    }

    // MARK: - setRecordingSpeed

    func setRecordingSpeed(sessionId: String, speed: Double, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("setDuetRecordingSpeed", current: "stopped")); return
        default: break
        }
        guard Self.isValidSpeed(speed) else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetRecordingSpeed: speed \(speed) is not one of \(Self.validSpeeds).", details: nil)); return
        }
        session.speedMultiplier = speed
        reply(nil, nil)
    }

    // MARK: - setAudioMixGains

    func setAudioMixGains(sessionId: String, sourceGain: Double, micGain: Double, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("setDuetAudioMixGains", current: "stopped")); return
        default: break
        }
        guard sourceGain >= 0.0 && sourceGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetAudioMixGains: sourceGain must be in [0.0, 1.0].", details: nil)); return
        }
        guard micGain >= 0.0 && micGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetAudioMixGains: micGain must be in [0.0, 1.0].", details: nil)); return
        }
        session.sourceGain = sourceGain
        session.micGain    = micGain
        reply(nil, nil)
    }

    // MARK: - startRecording

    func startRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .initialized else {
            reply(nil, invalidState("startDuetRecording", current: stateName(session.state), expected: "initialized")); return
        }
        session.state = .recording
        session.startSegment()
        reply(nil, nil)
    }

    // MARK: - pauseRecording

    func pauseRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .recording else {
            reply(nil, invalidState("pauseDuetRecording", current: stateName(session.state), expected: "recording")); return
        }
        session.commitSegment()
        session.state = .paused
        reply(nil, nil)
    }

    // MARK: - resumeRecording

    func resumeRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .paused else {
            reply(nil, invalidState("resumeDuetRecording", current: stateName(session.state), expected: "paused")); return
        }
        session.state = .recording
        session.startSegment()
        reply(nil, nil)
    }

    // MARK: - deleteLastSegment

    func deleteLastSegment(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("deleteLastDuetSegment", current: "stopped")); return
        default: break
        }
        _ = session.deleteLastSegment()
        reply(nil, nil)
    }

    // MARK: - stopRecording

    func stopRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .recording:
            session.commitSegment()
        case .paused:
            break
        default:
            reply(nil, invalidState("stopDuetRecording", current: stateName(session.state), expected: "recording or paused")); return
        }
        session.state = .stopped
        activeSession = nil
        let resultMap = session.buildStopResult()
        reply(resultMap, nil)
    }

    // MARK: - disposeSession (idempotent)

    func disposeSession(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        if let session = activeSession, session.sessionId == sessionId {
            canceledProbeIds.insert(sessionId)
            activeSession = nil
        }
        reply(nil, nil)
    }

    // MARK: - disposeAll (called from detachFromEngine)

    func disposeAll() {
        if let session = activeSession {
            canceledProbeIds.insert(session.sessionId)
        }
        activeSession = nil
    }

    // MARK: - Private helpers

    private func resolveActiveSession(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) -> VGDuetNativeSession? {
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, FlutterError(
                code:    "session_not_found",
                message: "No active Duet session with id '\(sessionId)'.",
                details: nil))
            return nil
        }
        return session
    }

    private func invalidState(_ route: String, current: String, expected: String? = nil) -> FlutterError {
        let msg = expected == nil
            ? "\(route): operation not valid in state '\(current)'."
            : "\(route): invalid state transition — current state is '\(current)', expected '\(expected!)'."
        return FlutterError(code: "invalid_state", message: msg, details: nil)
    }

    private func stateName(_ state: VGDuetSessionState) -> String {
        switch state {
        case .initialized: return "initialized"
        case .recording:   return "recording"
        case .paused:      return "paused"
        case .stopped:     return "stopped"
        }
    }

    // MARK: - Source probing (static, off-main)

    static func probeSource(filePath: String) -> Result<VGDuetSourceProbeResult, String> {
        let lower = filePath.lowercased()
        guard lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") else {
            return .failure("Source file must be .mp4 or .mov (got '\(filePath)')")
        }

        let url: URL
        if filePath.hasPrefix("file://") {
            guard let u = URL(string: filePath) else {
                return .failure("Invalid file:// URL: '\(filePath)'")
            }
            url = u
        } else {
            url = URL(fileURLWithPath: filePath)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("Source file does not exist at path: '\(url.path)'")
        }

        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = asset.duration
        guard duration.isValid && !duration.isIndefinite && duration.seconds > 0 else {
            return .failure("Source file has zero or invalid duration: '\(filePath)'")
        }
        let durationMs = Int(duration.seconds * 1000)

        let videoTracks = asset.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            return .failure("Source file has no video track: '\(filePath)'")
        }

        let hasAudioTrack = !asset.tracks(withMediaType: .audio).isEmpty

        return .success(VGDuetSourceProbeResult(
            durationMs:    durationMs,
            hasVideoTrack: true,
            hasAudioTrack: hasAudioTrack
        ))
    }

    static func validateTrimWindow(trimStartMs: Int, trimEndMs: Int, sourceDurationMs: Int) -> String? {
        if trimStartMs < 0 {
            return "Trim start must be >= 0 (got \(trimStartMs) ms)."
        }
        if trimEndMs <= trimStartMs {
            return "Trim end (\(trimEndMs) ms) must be > trim start (\(trimStartMs) ms)."
        }
        if (trimEndMs - trimStartMs) < 1000 {
            return "Trim window duration must be >= 1.0 s (got \(trimEndMs - trimStartMs) ms)."
        }
        if trimStartMs >= sourceDurationMs {
            return "Trim start (\(trimStartMs) ms) must be < source duration (\(sourceDurationMs) ms)."
        }
        if trimEndMs > sourceDurationMs {
            return "Trim end (\(trimEndMs) ms) exceeds source duration (\(sourceDurationMs) ms)."
        }
        return nil
    }

    static func isValidSpeed(_ speed: Double) -> Bool {
        let epsilon = 0.001
        return validSpeeds.contains(where: { abs($0 - speed) < epsilon })
    }

    static func validatePipRect(_ rectMap: [String: Any]) -> String? {
        guard let left   = (rectMap["left"]   as? NSNumber)?.doubleValue,
              let top    = (rectMap["top"]    as? NSNumber)?.doubleValue,
              let width  = (rectMap["width"]  as? NSNumber)?.doubleValue,
              let height = (rectMap["height"] as? NSNumber)?.doubleValue else {
            return "PiP rect is missing required fields (left, top, width, height)."
        }
        if left < 0 || top < 0 || width <= 0 || height <= 0 {
            return "PiP rect has invalid values (left=\(left), top=\(top), w=\(width), h=\(height))."
        }
        if left + width > 1.0 || top + height > 1.0 {
            return "PiP rect exceeds canvas bounds (right=\(left + width), bottom=\(top + height))."
        }
        return nil
    }
}
