// VGHLSLatencyRecorder.swift
// Per-session HLS latency samples and live-position seek records in iOS unified logging.
//
// Once a second, writes one line per playback session with the age of the
// player head: sample wall time minus AVPlayerItem.currentDate(). That date is
// the playlist's EXT-X-PROGRAM-DATE-TIME at the current playback position, so
// the age is egress-timeline-to-player-head only. It is not camera
// capture-to-glass and it is not proof that a frame was presented. Its absolute
// value is only as good as the publisher and device wall-clock sync.
//
// The age is signed and never clamped. When currentDate() is nil the line says
// "unavailable"; no other metric stands in for it. The playback URL, headers and
// tokens are never part of a sample.
//
// Each sample is followed by hls_latency_detail, which carries the complete
// observation and coordinator snapshot of that same reading in numbered parts. The
// two records share a sampleId. The detail and the seek records list each valid
// seekable range as one token, seekableRange<i>Ms=<startMs>..<endMs>, up to eight
// ranges, with any further ranges counted in seekableRangesOmitted.
//
// Seek records: the coordinator brackets each live-position seek, and each public
// seek on a LOW_LATENCY session, with beginSeek and completeSeek. They write
// hls_seek_requested (the state just before the AVPlayer seek call) and
// hls_seek_completed (the state when the completion reached the main queue),
// matched by sessionId and opId, plus hls_seek_abandoned for a record that never
// completed. A finished=false completion is not a landing, so it carries no
// deltas. Every value that is missing, indefinite, invalid or nonfinite is
// written as "unavailable"; nothing is estimated or clamped. The operation id is
// diagnostic only: it never takes part in seek arbitration or playback state.
// Copied-frame counts are AVPlayerItemVideoOutput evidence, not GPU presentation.
//
// Threading: main thread only, including every AVPlayer property read and all
// diagnostic state. start(), stop(), beginSeek and completeSeek are called by
// VGStreamingPlaybackCoordinator, which owns the session and its lifecycle.
//
// The coordinator starts a recorder in Debug builds only; Release builds emit no
// samples and no seek records.
//
// Retrieval: open Console.app, select the connected iPhone in the sidebar, and
// filter by subsystem "com.vanguard.engine" and category "hls-latency".

import AVFoundation
import Foundation
import os

/// Why a seek was issued. Diagnostic label only; it never drives playback.
enum VGHLSSeekReason: String {
    case user
    case initialLiveEdge
    case catchUpLiveEdge
}

/// Value-only copy of the coordinator state a seek record reports. The coordinator
/// builds it on the main thread through the recorder's `diagnostics` closure, so
/// the recorder never touches the session itself.
struct VGHLSDiagnosticSnapshot {
    let networkProfile:         String
    let sessionState:           String
    let initialSeekPending:     Bool
    let initialSeekDecided:     Bool
    let initialSeekIssued:      Bool
    let liveSeekInFlight:       Bool
    let catchUpArmed:           Bool
    let consecutiveHighSamples: Int
    let catchUpSeekCount:       Int
    let copiedPixelBufferCount: Int
    let lastCopiedItemTimeMs:   Int?

    /// Neutral values for a session that has gone away.
    static let unavailable = VGHLSDiagnosticSnapshot(
        networkProfile:         "unavailable",
        sessionState:           "unavailable",
        initialSeekPending:     false,
        initialSeekDecided:     false,
        initialSeekIssued:      false,
        liveSeekInFlight:       false,
        catchUpArmed:           false,
        consecutiveHighSamples: 0,
        catchUpSeekCount:       0,
        copiedPixelBufferCount: 0,
        lastCopiedItemTimeMs:   nil
    )
}

final class VGHLSLatencyRecorder {

    // .notice is the lowest level the unified log writes to disk by default.
    private static let logger = Logger(subsystem: "com.vanguard.engine", category: "hls-latency")
    private static let sampleIntervalSeconds: TimeInterval = 1.0

    /// Seek records kept at once; beyond this the oldest is abandoned.
    private static let maxPendingSeeks = 32
    /// Unified logging truncates long messages (about 1 KB), so a seek record is
    /// split into numbered parts of at most this many bytes. Every part repeats the
    /// event, sessionId, opId and reason.
    private static let maxRecordLineBytes = 700
    /// Seekable ranges listed individually in a record; the rest are only counted.
    private static let maxReportedSeekableRanges = 8

    /// What a completion needs from the moment its seek was requested.
    private struct PendingSeek {
        let operationId:        UInt64
        let reason:             VGHLSSeekReason
        let requestedAtSeconds: CFTimeInterval
        let playheadMs:         Int?
        let ageMs:              Int?
        let copiedFrames:       Int
    }

    /// One reading of the player: the record tokens plus the values the seek deltas
    /// and the periodic hls_latency line use.
    private struct Observation {
        let tokens:                    [String]
        let playheadMs:                Int?
        let ageMs:                     Int?
        let copiedFrames:              Int
        let sampleUtc:                 String
        let itemUtc:                   String
        let timeControl:               String
        let requestedRate:             String
        let effectiveTimebaseRate:     String
        let contiguousForwardBufferMs: Int?
        let lastCopiedItemTimeMs:      Int?
        let liveSeekInFlight:          Bool
    }

    private let sessionId:   String
    private let player:      AVPlayer
    private let item:        AVPlayerItem
    private let stallCount:  () -> Int
    private let diagnostics: () -> VGHLSDiagnosticSnapshot

    private let utcFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private var timer: Timer?
    private var pending: [PendingSeek] = []
    private var nextOperationId: UInt64 = 0
    private var nextSampleId = 0
    private var stopped = false

    /// `stallCount` reads the session's cumulative AVPlayerItemPlaybackStalled count.
    /// `diagnostics` returns a value-only copy of the coordinator's session state;
    /// it must capture the session weakly and return neutral values once it is gone.
    init(
        sessionId:   String,
        player:      AVPlayer,
        item:        AVPlayerItem,
        stallCount:  @escaping () -> Int,
        diagnostics: @escaping () -> VGHLSDiagnosticSnapshot
    ) {
        self.sessionId   = sessionId
        self.player      = player
        self.item        = item
        self.stallCount  = stallCount
        self.diagnostics = diagnostics
    }

    deinit {
        timer?.invalidate()
    }

    /// Begins one-second sampling. A second call while running, or a call after
    /// stop(), is a no-op.
    func start() {
        guard timer == nil, !stopped else { return }
        let timer = Timer(timeInterval: Self.sampleIntervalSeconds, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.logSample()
        }
        // .common keeps samples coming while the UI is tracking a touch or scroll.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops sampling and invalidates the timer. Every seek record still pending is
    /// reported as abandoned, and nothing is emitted afterwards. Safe to call more
    /// than once.
    func stop() {
        timer?.invalidate()
        timer = nil
        guard !stopped else { return }
        let abandoned = pending
        pending.removeAll()
        for record in abandoned {
            emitAbandoned(record, because: "recorderStopped")
        }
        stopped = true
    }

    // MARK: - Seek records

    /// Records the state just before an AVPlayer seek and returns the operation id
    /// its completion passes back. After stop() it emits and stores nothing.
    func beginSeek(reason: VGHLSSeekReason, target: CMTime) -> UInt64 {
        nextOperationId += 1
        let operationId = nextOperationId
        guard !stopped else { return operationId }

        if pending.count >= Self.maxPendingSeeks {
            emitAbandoned(pending.removeFirst(), because: "capacity")
        }

        let before = observe()
        emit(
            event: "hls_seek_requested", operationId: operationId, reason: reason,
            tokens: ["target=\(Self.targetText(target))"] + before.tokens
        )
        pending.append(PendingSeek(
            operationId:        operationId,
            reason:             reason,
            requestedAtSeconds: CACurrentMediaTime(),
            playheadMs:         before.playheadMs,
            ageMs:              before.ageMs,
            copiedFrames:       before.copiedFrames
        ))
        return operationId
    }

    /// Records the state when a seek's completion reached the main queue.
    /// `callbackArrivalSeconds` is CACurrentMediaTime() taken when AVPlayer called the
    /// completion, before the dispatch to main. An id that was abandoned, already
    /// completed or never recorded is ignored.
    func completeSeek(operationId: UInt64, finished: Bool, callbackArrivalSeconds: CFTimeInterval) {
        let handledAtSeconds = CACurrentMediaTime()
        guard !stopped,
              let index = pending.firstIndex(where: { $0.operationId == operationId }) else { return }
        let record = pending.remove(at: index)
        let after  = observe()

        // A finished=false seek was superseded and is not a landing, so it has no deltas.
        let playheadDelta: Int? = finished ? Self.difference(after.playheadMs, record.playheadMs) : nil
        let ageDelta:      Int? = finished ? Self.difference(after.ageMs, record.ageMs) : nil
        let copiedDelta:   Int? = finished ? after.copiedFrames - record.copiedFrames : nil

        let tokens: [String] = [
            "finished=\(finished)",
            "callbackDurationMs=\(Self.fixed((callbackArrivalSeconds - record.requestedAtSeconds) * 1000, 1))",
            "mainDispatchDelayMs=\(Self.fixed((handledAtSeconds - callbackArrivalSeconds) * 1000, 1))",
            "playheadDeltaMs=\(Self.value(playheadDelta))",
            "ageDeltaMs=\(Self.value(ageDelta))",
            "copiedFramesDelta=\(Self.value(copiedDelta))",
        ]
        emit(event: "hls_seek_completed", operationId: operationId, reason: record.reason, tokens: tokens + after.tokens)
    }

    private func emitAbandoned(_ record: PendingSeek, because cause: String) {
        let sinceRequestMs = Self.fixed((CACurrentMediaTime() - record.requestedAtSeconds) * 1000, 1)
        emit(
            event: "hls_seek_abandoned", operationId: record.operationId, reason: record.reason,
            tokens: ["abandonReason=\(cause)", "finished=unavailable", "sinceRequestMs=\(sinceRequestMs)"]
        )
    }

    /// Writes one seek record in numbered parts; see emitParts.
    private func emit(event: String, operationId: UInt64, reason: VGHLSSeekReason, tokens: [String]) {
        emitParts(
            prefix: "\(event) sessionId=\(sessionId) opId=\(operationId) reason=\(reason.rawValue)",
            tokens: tokens
        )
    }

    /// Writes `tokens` after `prefix`, split into numbered parts of at most
    /// maxRecordLineBytes so no line nears the unified log's message size limit. Every
    /// part repeats the prefix, and a token is never split across parts.
    private func emitParts(prefix: String, tokens: [String]) {
        // The extra bytes cover the " part=NN/NN" that follows the prefix.
        let budget = Self.maxRecordLineBytes - prefix.utf8.count - 12
        var bodies: [String] = []
        var current = ""
        for token in tokens {
            if !current.isEmpty && current.utf8.count + 1 + token.utf8.count > budget {
                bodies.append(current)
                current = ""
            }
            current += " " + token
        }
        if !current.isEmpty || bodies.isEmpty { bodies.append(current) }
        for (index, body) in bodies.enumerated() {
            let line = "\(prefix) part=\(index + 1)/\(bodies.count)\(body)"
            Self.logger.notice("\(line, privacy: .public)")
        }
    }

    // MARK: - Observation

    /// Reads the player and the coordinator snapshot once, on the main thread.
    private func observe() -> Observation {
        let snapshot   = diagnostics()
        let sampleDate = Date()
        let itemDate   = item.currentDate()

        let playheadSeconds = Self.seconds(player.currentTime())
        let playheadMs      = Self.milliseconds(playheadSeconds)

        let seekable      = Self.validRanges(item.seekableTimeRanges)
        let seekableStart = seekable.map { $0.start }.min()
        let seekableEnd   = seekable.map { $0.end }.max()
        var seekableEndMinusPlayhead: Double? = nil
        if let end = seekableEnd, let playhead = playheadSeconds {
            seekableEndMinusPlayhead = end - playhead
        }

        let sampleUtc = utcFormatter.string(from: sampleDate)
        let itemUtc:  String
        let ageMs:    Int?
        if let itemDate = itemDate {
            itemUtc = utcFormatter.string(from: itemDate)
            ageMs   = Self.milliseconds(sampleDate.timeIntervalSince(itemDate))
        } else {
            itemUtc = "unavailable"
            ageMs   = nil
        }

        let timeControl   = Self.label(for: player.timeControlStatus)
        let requestedRate = Self.fixed(Double(player.rate), 2)
        let effectiveRate = Self.effectiveTimebaseRateText(item)
        let contiguousMs  = contiguousForwardBufferMs(playheadSeconds: playheadSeconds)

        // The seekable summary stays; the per-range tokens follow it.
        let leading: [String] = [
            "playheadMs=\(Self.value(playheadMs))",
            "seekableRanges=\(seekable.count)",
            "seekableStartMs=\(Self.value(Self.milliseconds(seekableStart)))",
            "seekableEndMs=\(Self.value(Self.milliseconds(seekableEnd)))",
            "seekableEndMinusPlayheadMs=\(Self.value(Self.milliseconds(seekableEndMinusPlayhead)))",
        ]
        let trailing: [String] = [
            "sampleUtc=\(sampleUtc)",
            "itemDateUtc=\(itemUtc)",
            "ageMs=\(Self.value(ageMs))",
            "requestedRate=\(requestedRate)",
            "effectiveTimebaseRate=\(effectiveRate)",
            "timeControl=\(timeControl)",
            "waitingReason=\(Self.waitingReasonText(player.reasonForWaitingToPlay))",
            "contiguousForwardBufferMs=\(Self.value(contiguousMs))",
            "configuredLiveOffsetMs=\(Self.value(Self.milliseconds(Self.seconds(item.configuredTimeOffsetFromLive))))",
            "recommendedLiveOffsetMs=\(Self.value(Self.milliseconds(Self.seconds(item.recommendedTimeOffsetFromLive))))",
            "preferredForwardBufferSeconds=\(Self.fixed(item.preferredForwardBufferDuration, 3))",
            "autoPreservesLiveOffset=\(item.automaticallyPreservesTimeOffsetFromLive)",
            "autoWaitsToMinimizeStalling=\(player.automaticallyWaitsToMinimizeStalling)",
            "networkProfile=\(Self.sanitized(snapshot.networkProfile))",
            "sessionState=\(Self.sanitized(snapshot.sessionState))",
            "initialSeekPending=\(snapshot.initialSeekPending)",
            "initialSeekDecided=\(snapshot.initialSeekDecided)",
            "initialSeekIssued=\(snapshot.initialSeekIssued)",
            "liveSeekInFlight=\(snapshot.liveSeekInFlight)",
            "catchUpArmed=\(snapshot.catchUpArmed)",
            "consecutiveHighSamples=\(snapshot.consecutiveHighSamples)",
            "catchUpSeekCount=\(snapshot.catchUpSeekCount)",
            "copiedFrames=\(snapshot.copiedPixelBufferCount)",
            "lastCopiedItemTimeMs=\(Self.value(snapshot.lastCopiedItemTimeMs))",
        ]
        return Observation(
            tokens:                    leading + Self.seekableRangeTokens(seekable) + trailing,
            playheadMs:                playheadMs,
            ageMs:                     ageMs,
            copiedFrames:              snapshot.copiedPixelBufferCount,
            sampleUtc:                 sampleUtc,
            itemUtc:                   itemUtc,
            timeControl:               timeControl,
            requestedRate:             requestedRate,
            effectiveTimebaseRate:     effectiveRate,
            contiguousForwardBufferMs: contiguousMs,
            lastCopiedItemTimeMs:      snapshot.lastCopiedItemTimeMs,
            liveSeekInFlight:          snapshot.liveSeekInFlight
        )
    }

    /// Buffered media ahead of the playhead in the one valid loaded range that
    /// contains it. A disconnected later range does not count; no such range is zero;
    /// an invalid playhead is nil.
    private func contiguousForwardBufferMs(playheadSeconds: Double?) -> Int? {
        guard let playhead = playheadSeconds else { return nil }
        var bufferedEnd: Double? = nil
        for range in Self.validRanges(item.loadedTimeRanges) where range.start <= playhead && playhead < range.end {
            bufferedEnd = max(bufferedEnd ?? range.end, range.end)
        }
        guard let end = bufferedEnd else { return 0 }
        return Self.milliseconds(end - playhead)
    }

    // MARK: - Sample

    private func logSample() {
        guard !stopped else { return }
        nextSampleId += 1
        let sampleId = nextSampleId

        // One observation feeds both records, so the line and its detail agree.
        let observation    = observe()
        let bufferEmpty    = item.isPlaybackBufferEmpty
        let likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        let stalls         = stallCount()

        // `rate` is AVPlayer.rate, the requested rate. The effective rate is the item
        // timebase's, and the copied-frame fields are the progress evidence.
        let ageMs            = Self.value(observation.ageMs)
        let contiguousMs     = Self.value(observation.contiguousForwardBufferMs)
        let copiedItemTimeMs = Self.value(observation.lastCopiedItemTimeMs)

        Self.logger.notice(
            "hls_latency sessionId=\(self.sessionId, privacy: .public) sampleUtc=\(observation.sampleUtc, privacy: .public) itemDateUtc=\(observation.itemUtc, privacy: .public) ageMs=\(ageMs, privacy: .public) timeControl=\(observation.timeControl, privacy: .public) rate=\(observation.requestedRate, privacy: .public) bufferEmpty=\(bufferEmpty) likelyToKeepUp=\(likelyToKeepUp) stalls=\(stalls) effectiveTimebaseRate=\(observation.effectiveTimebaseRate, privacy: .public) contiguousForwardBufferMs=\(contiguousMs, privacy: .public) copiedFrames=\(observation.copiedFrames) copiedItemTimeMs=\(copiedItemTimeMs, privacy: .public) liveSeekInFlight=\(observation.liveSeekInFlight) sampleId=\(sampleId)"
        )
        emitParts(
            prefix: "hls_latency_detail sessionId=\(sessionId) sampleId=\(sampleId)",
            tokens: observation.tokens
        )
    }

    // MARK: - Formatting helpers

    private static func label(for status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .playing:                      return "playing"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .paused:                       return "paused"
        @unknown default:                   return "unknown"
        }
    }

    /// nil is the player not waiting; the other labels are AVPlayer's own reasons.
    private static func waitingReasonText(_ reason: AVPlayer.WaitingReason?) -> String {
        guard let reason = reason else { return "none" }
        switch reason {
        case .toMinimizeStalls:        return "toMinimizeStalls"
        case .evaluatingBufferingRate: return "evaluatingBufferingRate"
        case .noItemToPlay:            return "noItemToPlay"
        default:                       return sanitized(reason.rawValue)
        }
    }

    /// The item timebase's effective rate, which is not the requested rate. Unavailable
    /// before the item has a timebase or while the rate is not finite.
    private static func effectiveTimebaseRateText(_ item: AVPlayerItem) -> String {
        guard let timebase = item.timebase else { return "unavailable" }
        return fixed(CMTimebaseGetEffectiveRate(timebase), 3)
    }

    /// Positive infinity is the live position; a missing, indefinite, invalid or
    /// nonfinite target is unavailable.
    private static func targetText(_ target: CMTime) -> String {
        if target.isPositiveInfinity { return "live" }
        guard let ms = milliseconds(seconds(target)) else { return "unavailable" }
        return "\(ms)ms"
    }

    /// Seconds of a valid, finite, non-indefinite CMTime; otherwise nil.
    private static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let value = time.seconds
        return value.isFinite ? value : nil
    }

    /// Whole milliseconds, signed and never clamped; nil for a missing, nonfinite or
    /// implausibly large value.
    private static func milliseconds(_ seconds: Double?) -> Int? {
        guard let seconds = seconds, seconds.isFinite else { return nil }
        let ms = (seconds * 1000).rounded()
        guard abs(ms) < 1.0e15 else { return nil }
        return Int(ms)
    }

    private static func difference(_ later: Int?, _ earlier: Int?) -> Int? {
        guard let later = later, let earlier = earlier else { return nil }
        return later - earlier
    }

    private static func value(_ number: Int?) -> String {
        guard let number = number else { return "unavailable" }
        return String(number)
    }

    private static func fixed(_ number: Double, _ precision: Int) -> String {
        guard number.isFinite else { return "unavailable" }
        return String(format: "%.\(precision)f", number)
    }

    /// The valid seekable or loaded ranges: finite start and positive finite
    /// duration, as (start, end) seconds. Anything else is skipped.
    private static func validRanges(_ values: [NSValue]) -> [(start: Double, end: Double)] {
        var ranges: [(start: Double, end: Double)] = []
        for rangeValue in values {
            let range = rangeValue.timeRangeValue
            guard let start = seconds(range.start),
                  let duration = seconds(range.duration), duration > 0 else { continue }
            let end = start + duration
            guard end.isFinite else { continue }
            ranges.append((start: start, end: end))
        }
        return ranges
    }

    /// One token per valid seekable range, seekableRange<i>Ms=<startMs>..<endMs>, so a
    /// range is never split across record parts and each token stays small. At most
    /// maxReportedSeekableRanges are listed; the rest are counted.
    private static func seekableRangeTokens(_ ranges: [(start: Double, end: Double)]) -> [String] {
        var tokens: [String] = []
        for (index, range) in ranges.prefix(maxReportedSeekableRanges).enumerated() {
            tokens.append("seekableRange\(index)Ms=\(value(milliseconds(range.start)))..\(value(milliseconds(range.end)))")
        }
        if ranges.count > maxReportedSeekableRanges {
            tokens.append("seekableRangesOmitted=\(ranges.count - maxReportedSeekableRanges)")
        }
        return tokens
    }

    /// Printable ASCII only, no spaces or semicolons, at most 60 characters.
    private static func sanitized(_ text: String) -> String {
        let kept = text.unicodeScalars.compactMap { scalar -> Character? in
            let v = scalar.value
            guard v > 0x20, v <= 0x7E, v != 0x3B else { return nil }
            return Character(scalar)
        }
        let result = String(kept.prefix(60))
        return result.isEmpty ? "unknown" : result
    }
}
