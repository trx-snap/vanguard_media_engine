package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioTimestamp
import android.media.AudioTrack

// ── AndroidNodeOwnedSinkClockedTimebase ─────────────────────────────────────
// (P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT, sub-slice O of
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS)
//
// Small cohesive Kotlin-only sink-clock target derivation component: turns
// android.media.AudioTrack consumption telemetry into the epoch-relative
// dispatch target frame (sink position + targetLeadFrames) that the
// transport driver converts into a caller-derived sysTimeNs tick for the
// native step call. The AudioTrack is the KOTLIN timebase master after the
// driver's pre-roll/play gate; the C++ AudioClock and
// ClockedAudioTransportCoordinator stay caller-clocked and unchanged, and
// native still never reads a wall clock — System.nanoTime() lives in Kotlin
// only, as the extrapolation anchor between telemetry samples.
//
// Position derivation per sample, always clamped monotonic non-decreasing
// and never beyond the frames written this epoch:
//   - AudioTimestamp when available and valid (nanoTime > 0; raw
//     framePosition baselined per epoch at the first valid sample, because
//     AudioTimestamp.framePosition is not guaranteed to reset across
//     pause()/flush()/openEpoch(); the epoch-relative timestamp frame must
//     be non-negative, non-regressing within the epoch and never ahead of
//     the frames written this epoch): the epoch-relative frame extrapolated
//     by the Kotlin nanoTime delta since the timestamp was taken.
//   - Otherwise playbackHeadPosition (unsigned 32-bit raw counter,
//     epoch-baselined) plus a Kotlin System.nanoTime() anchor captured at
//     the last observed head change while playing.
// A returned AudioTimestamp that violates the validity rules throws
// [Invalid] (the driver fails closed); availability itself is optional and
// only recorded.
//
// Telemetry: timestamp attempts/successes/availability/validity,
// playback-head monotonicity and sample count, last raw head / derived
// position / target frame, target lead, dispatch-lead (drift) bounds and
// max sink lag (frames written but not yet consumed).
//
// Deliberately owns NOTHING with a lifecycle: no MediaCodec, no
// MediaExtractor, no native session, and no AudioTrack ownership — the
// track is borrowed per call and never created/played/paused/flushed/
// released here. Single-caller-thread use only (no synchronization).
class AndroidNodeOwnedSinkClockedTimebase(
    private val sampleRate: Int,
    val targetLeadFrames: Long,
) {
    class Invalid(val reason: String) : Exception(reason)

    companion object {
        private const val NANOS_PER_SECOND = 1_000_000_000L
    }

    private val timestampScratch = AudioTimestamp()

    // ── Epoch state (reset by openEpoch after every AudioTrack flush) ───────
    private var epochOpen = false
    private var epochHeadBaselineRaw = 0L
    private var epochLastRawHead = 0L
    private var lastHeadChangeNanos = 0L
    private var lastTimestampEpochFrames = -1L
    private var epochTimestampBaselineRaw = -1L
    private var lastPositionFramesInternal = 0L

    // ── Telemetry ───────────────────────────────────────────────────────────
    var timestampAttemptCount = 0L
        private set
    var timestampSuccessCount = 0L
        private set
    var timestampAvailable = false
        private set
    var timestampValid = true
        private set
    var headSampleCount = 0L
        private set
    var headMonotonicViolated = false
        private set
    var lastRawHeadEpochFrames = 0L
        private set
    var lastPositionFrames = 0L
        private set
    var lastTargetFrame = 0L
        private set
    var maxSinkLagFrames = 0L
        private set
    var maxDispatchLeadFrames = Long.MIN_VALUE
        private set
    var minDispatchLeadFrames = Long.MAX_VALUE
        private set
    var dispatchCursorSampleCount = 0L
        private set

    init {
        if (sampleRate < 8000 || sampleRate > 192000) {
            throw Invalid("timebase_invalid_sample_rate:$sampleRate")
        }
        if (targetLeadFrames <= 0L) {
            throw Invalid("timebase_invalid_target_lead:$targetLeadFrames")
        }
    }

    // Re-baselines the epoch-relative frame axis from the track's current
    // raw playback head and clears the per-epoch AudioTimestamp baseline
    // (the driver calls this at epoch 0 open and after
    // every pause()/flush() seek boundary). Cross-epoch telemetry
    // (timestamp/lead/lag bounds) deliberately accumulates across the run.
    fun openEpoch(track: AudioTrack) {
        epochHeadBaselineRaw = rawHead(track)
        epochLastRawHead = epochHeadBaselineRaw
        lastHeadChangeNanos = System.nanoTime()
        lastTimestampEpochFrames = -1L
        epochTimestampBaselineRaw = -1L
        lastPositionFramesInternal = 0L
        lastRawHeadEpochFrames = 0L
        lastPositionFrames = 0L
        epochOpen = true
    }

    // One sink-clock sample: validates raw-head monotonicity and the
    // head-vs-written bound, derives the current epoch-relative sink
    // position (AudioTimestamp when available/valid, playback head +
    // nanoTime anchor otherwise), and returns it clamped monotonic
    // non-decreasing and never beyond [framesWrittenThisEpoch].
    fun samplePositionFrames(
        track: AudioTrack,
        framesWrittenThisEpoch: Long,
        played: Boolean,
    ): Long {
        if (!epochOpen) throw Invalid("timebase_epoch_not_open")
        headSampleCount++
        val raw = rawHead(track)
        if (raw < epochLastRawHead) {
            headMonotonicViolated = true
            throw Invalid("sink_playback_head_not_monotonic")
        }
        val nowNanos = System.nanoTime()
        if (raw != epochLastRawHead) {
            lastHeadChangeNanos = nowNanos
        }
        epochLastRawHead = raw
        val headEpoch = raw - epochHeadBaselineRaw
        lastRawHeadEpochFrames = headEpoch
        if (headEpoch > framesWrittenThisEpoch) {
            throw Invalid("sink_playback_head_exceeds_written")
        }

        // Fallback estimate: raw head + Kotlin nanoTime anchor while the
        // head is actually consuming (played and advanced past zero).
        var estimate = headEpoch
        if (played && headEpoch > 0L) {
            estimate = headEpoch +
                (nowNanos - lastHeadChangeNanos) * sampleRate / NANOS_PER_SECOND
        }

        // Conditional AudioTimestamp overlay: preferred when available and
        // valid; availability is recorded, never required.
        if (played) {
            timestampAttemptCount++
            val ok = try {
                track.getTimestamp(timestampScratch)
            } catch (_: Throwable) {
                false
            }
            if (ok) {
                timestampSuccessCount++
                timestampAvailable = true
                val tsRaw = timestampScratch.framePosition
                if (timestampScratch.nanoTime <= 0L) {
                    timestampValid = false
                    throw Invalid("audio_timestamp_nanotime_invalid")
                }
                if (tsRaw < 0L) {
                    timestampValid = false
                    throw Invalid("audio_timestamp_raw_negative")
                }
                // Raw framePosition is not guaranteed to reset across
                // pause()/flush(): the first valid sample of each epoch
                // becomes the epoch timestamp baseline and every timestamp
                // frame below is epoch-relative to it.
                if (epochTimestampBaselineRaw < 0L) {
                    epochTimestampBaselineRaw = tsRaw
                }
                val tsFrames = tsRaw - epochTimestampBaselineRaw
                val violation = when {
                    tsFrames < 0L -> "audio_timestamp_regressed"
                    tsFrames < lastTimestampEpochFrames -> "audio_timestamp_regressed"
                    tsFrames > framesWrittenThisEpoch -> "audio_timestamp_ahead_of_written"
                    else -> null
                }
                if (violation != null) {
                    timestampValid = false
                    throw Invalid(violation)
                }
                lastTimestampEpochFrames = tsFrames
                val tsEstimate = tsFrames +
                    (nowNanos - timestampScratch.nanoTime) * sampleRate / NANOS_PER_SECOND
                if (tsEstimate >= 0L) {
                    estimate = tsEstimate
                }
            }
        }

        val clamped = maxOf(0L, minOf(estimate, framesWrittenThisEpoch))
        lastPositionFramesInternal = maxOf(lastPositionFramesInternal, clamped)
        lastPositionFrames = lastPositionFramesInternal
        val lag = framesWrittenThisEpoch - lastPositionFramesInternal
        if (lag > maxSinkLagFrames) maxSinkLagFrames = lag
        return lastPositionFramesInternal
    }

    // The sink-clocked dispatch target on the epoch-relative frame axis:
    // current sink position + targetLeadFrames.
    fun targetFrame(
        track: AudioTrack,
        framesWrittenThisEpoch: Long,
        played: Boolean,
    ): Long {
        val position = samplePositionFrames(track, framesWrittenThisEpoch, played)
        lastTargetFrame = position + targetLeadFrames
        return lastTargetFrame
    }

    // Records the post-dispatch cursor (epoch-relative) against the last
    // sampled sink position for the drift/lead bounds telemetry: lead =
    // cursor - position, expected in (0, targetLeadFrames].
    fun recordDispatchCursor(epochCursorFrames: Long) {
        dispatchCursorSampleCount++
        val lead = epochCursorFrames - lastPositionFramesInternal
        if (lead > maxDispatchLeadFrames) maxDispatchLeadFrames = lead
        if (lead < minDispatchLeadFrames) minDispatchLeadFrames = lead
    }

    private fun rawHead(track: AudioTrack): Long =
        // playbackHeadPosition wraps as an unsigned 32-bit frame counter.
        track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
}
