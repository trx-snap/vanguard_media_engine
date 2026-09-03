package com.connects.vanguard_media_engine.audio_playback_graph

import java.util.concurrent.atomic.AtomicLong

// ── VanguardRealtimePlaybackPresentationClock (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION, Y7) ─
//
// Read-only DOWNSTREAM presentation clock over the Y6f sink observations.
// One writer (the sink thread that owns the AudioTrack and its getTimestamp
// poll point) feeds it epoch opens/closes, valid AudioTimestamp samples and
// "timestamp unavailable" ticks; any thread may take a diagnostic
// [Snapshot]. It is a diagnostic foundation only:
//   - it never controls native pacing, write size, sleeps, drain gating,
//     transport commands, checksums, underrun handling or product UI. It
//     has no callback / listener surface; the only outputs are the
//     [Outcome] token returned to the writer and the any-thread snapshot.
//   - publication is lock-free: @Volatile primitive fields guarded by a
//     seqlock-style sequence counter (odd = write in flight). The writer
//     allocates nothing in steady state (enum tokens are preallocated, all
//     state is primitive); the reader allocates its own Snapshot.
//   - epoch model = one writer-declared segment of AudioTrack instance
//     frames with its own base offset (Y7: epoch 0 = initial play, epoch 1
//     = synthetic dead-object recreation; Y8a: a bounded pause closes the
//     epoch and reopens epoch+1 based at the last published position; Y9:
//     one forward seek closes the epoch at the park, the writer flushes the
//     instance and reopens epoch+1 based at the seek target, a deliberate
//     base-offset discontinuity the writer publishes as telemetry). The
//     clock itself has no seek/flush/reanchor API: every base comes from
//     the writer through [epochOpened], and a base below the published
//     position is still clamped and counted, never trusted. A base AHEAD
//     of the published position is published immediately as the epoch's
//     opening position (a deliberate, counted forward discontinuity: the
//     writer declared that instance frame 0 of the new epoch maps to
//     `base`, so the position can never be below it); a base equal to the
//     published position (Y8a pause reopen) changes nothing.
//   - per epoch the unsigned-32 framePosition is unwrapped (one positive
//     wrap tolerated, strict regression fails closed via
//     [Outcome.REJECTED_FRAME_REGRESSION] and latches the FAULTED state).
//     continuousFrames = epochBaseOffset + unwrappedFrame; continuity across
//     epochs comes from base-offset accumulation only, never from comparing
//     raw positions of different epochs.
//   - getTimestamp() == false is NON-terminal: with a valid anchor in the
//     open epoch the position is extrapolated from the anchor's nanoTime
//     with the caller-supplied System.nanoTime() value, bounded by
//     [extrapolationHorizonNs]; past the horizon the clock publishes STALE
//     and holds the last published position instead of fabricating one.
//   - the published position never decreases (an anchor landing below an
//     earlier extrapolation is clamped and counted, never published as a
//     regression).
//   - positionUs = continuousFrames * 1_000_000 / sampleRate. No HAL /
//     output latency, A/V sync, drift correction or availability SLA claim.
class VanguardRealtimePlaybackPresentationClock(
    val sampleRate: Int,
    val extrapolationHorizonNs: Long = DEFAULT_EXTRAPOLATION_HORIZON_NS,
) {

    // Provenance of the published position.
    //   ANCHORED     : last update was a valid timestamp sample.
    //   EXTRAPOLATED : last update was an unavailable tick within the horizon.
    //   STALE        : unavailable tick past the horizon (position held).
    //   RESET        : no valid anchor in the current epoch (initial state,
    //                  right after an epoch open / close, or an unavailable
    //                  tick before the first anchor of the epoch).
    enum class Provenance { ANCHORED, EXTRAPOLATED, STALE, RESET }

    // Result token of every writer call. ACCEPTED_* never mutate the fault
    // latch; REJECTED_FRAME_REGRESSION latches it (every later update is
    // REJECTED_FAULTED). The writer decides what to do with a rejection; the
    // clock itself never throws.
    enum class Outcome {
        ACCEPTED_EPOCH_OPENED,
        ACCEPTED_EPOCH_CLOSED,
        ACCEPTED_ANCHORED,
        ACCEPTED_EXTRAPOLATED,
        ACCEPTED_STALE,
        ACCEPTED_NO_ANCHOR,
        REJECTED_OFF_WRITER_THREAD,
        REJECTED_FAULTED,
        REJECTED_INVALID_EPOCH,
        REJECTED_EPOCH_ALREADY_OPEN,
        REJECTED_EPOCH_ORDER,
        REJECTED_NO_OPEN_EPOCH,
        REJECTED_EPOCH_MISMATCH,
        REJECTED_BASE_INVALID,
        REJECTED_RAW_OUT_OF_RANGE,
        REJECTED_FRAME_REGRESSION,
        ;

        val accepted: Boolean get() = ordinal <= ACCEPTED_NO_ANCHOR.ordinal
    }

    // Any-thread, immutable diagnostic view. `consistent` is false only when
    // the reader could not observe a quiescent publication within
    // [SNAPSHOT_MAX_ATTEMPTS] (never expected at the Y6f poll cadence).
    data class Snapshot(
        val consistent: Boolean,
        val sequence: Long,
        val provenance: Provenance,
        val epochId: Int,
        val epochOpen: Boolean,
        val epochBaseOffsetFrames: Long,
        val positionFrames: Long,
        val positionUs: Long,
        val anchorContinuousFrames: Long,
        val anchorNanoTime: Long,
        val lastRawFrame: Long,
        val lastUnwrappedFrame: Long,
        val lastHead: Long,
        val publishedAtNs: Long,
        val lastAgeNs: Long,
        val sampleRate: Int,
        val extrapolationHorizonNs: Long,
        val faulted: Boolean,
        val lastOutcome: Outcome,
        val updateCount: Long,
        val timestampSuccessCount: Long,
        val timestampUnavailableCount: Long,
        val anchoredCount: Long,
        val extrapolatedCount: Long,
        val staleCount: Long,
        val noAnchorCount: Long,
        val resetCount: Long,
        val epochOpenCount: Int,
        val epochCloseCount: Int,
        val wrapCount: Long,
        val regressionCount: Long,
        val rejectedCount: Long,
        val anchorClampCount: Long,
        val baseClampCount: Long,
        val baseAdvanceCount: Long,
        val lastBaseAdvanceFrames: Long,
        val negativeAgeCount: Long,
        val nanoTimeNonMonotonicCount: Long,
        val maxExtrapolatedAgeNs: Long,
        val minStaleAgeNs: Long,
        val maxExtrapolatedAdvanceFrames: Long,
        val staleAdvanceFrames: Long,
        val monotonicViolationCount: Long,
        val offWriterThreadCalls: Long,
        val snapshotCallsFromWriterThread: Long,
        val snapshotCallsFromOtherThreads: Long,
        val writerThreadId: Long,
    )

    companion object {
        const val DEFAULT_EXTRAPOLATION_HORIZON_NS = 250_000_000L
        const val EPOCH_NONE = -1
        const val FRAME_WRAP_MODULUS = 0x1_0000_0000L
        const val FRAME_WRAP_FORWARD_MAX = 0x8000_0000L
        const val WRITER_UNBOUND = -1L
        private const val SNAPSHOT_MAX_ATTEMPTS = 64

        fun framesToUs(frames: Long, sampleRate: Int): Long =
            if (sampleRate <= 0) 0L else frames * 1_000_000L / sampleRate
    }

    // ── Publication sequence (odd while a write is in flight) ──────────────

    private val sequence = AtomicLong(0L)

    // ── Published state (@Volatile primitives; written by the writer only) ──

    @Volatile private var provenance = Provenance.RESET
    @Volatile private var epochId = EPOCH_NONE
    @Volatile private var epochOpen = false
    @Volatile private var epochBaseOffsetFrames = 0L
    @Volatile private var positionFrames = 0L
    @Volatile private var anchorContinuousFrames = -1L
    @Volatile private var anchorNanoTime = -1L
    @Volatile private var lastRawFrame = -1L
    @Volatile private var lastUnwrappedFrame = -1L
    @Volatile private var lastHead = -1L
    @Volatile private var publishedAtNs = -1L
    @Volatile private var lastAgeNs = -1L
    @Volatile private var faulted = false
    @Volatile private var lastOutcome = Outcome.ACCEPTED_EPOCH_CLOSED
    @Volatile private var updateCount = 0L
    @Volatile private var timestampSuccessCount = 0L
    @Volatile private var timestampUnavailableCount = 0L
    @Volatile private var anchoredCount = 0L
    @Volatile private var extrapolatedCount = 0L
    @Volatile private var staleCount = 0L
    @Volatile private var noAnchorCount = 0L
    @Volatile private var resetCount = 0L
    @Volatile private var epochOpenCount = 0
    @Volatile private var epochCloseCount = 0
    @Volatile private var wrapCount = 0L
    @Volatile private var regressionCount = 0L
    @Volatile private var rejectedCount = 0L
    @Volatile private var anchorClampCount = 0L
    @Volatile private var baseClampCount = 0L
    // Epoch opens whose base was ahead of the published position (Y9 seek).
    @Volatile private var baseAdvanceCount = 0L
    @Volatile private var lastBaseAdvanceFrames = 0L
    @Volatile private var negativeAgeCount = 0L
    @Volatile private var nanoTimeNonMonotonicCount = 0L
    @Volatile private var maxExtrapolatedAgeNs = -1L
    @Volatile private var minStaleAgeNs = -1L
    @Volatile private var maxExtrapolatedAdvanceFrames = 0L
    @Volatile private var staleAdvanceFrames = 0L
    // Assertion counter: the publication path clamps, so this stays zero.
    @Volatile private var monotonicViolationCount = 0L
    @Volatile private var writerThreadId = WRITER_UNBOUND

    // Writer-thread-confined unwrap state (never read by snapshot()).
    private var epochWrapSeen = false
    private var epochHasAnchor = false

    // Counters that any thread may bump (atomics only; never a lock).
    private val offWriterThreadCalls = AtomicLong(0L)
    private val snapshotCallsFromWriterThread = AtomicLong(0L)
    private val snapshotCallsFromOtherThreads = AtomicLong(0L)

    // ── Writer API (single writer: the sink thread) ────────────────────────

    // Binds the calling thread as the only writer. Idempotent for the same
    // thread; a second thread is rejected and counted.
    fun bindWriterThread(): Boolean {
        val me = Thread.currentThread().id
        val bound = writerThreadId
        if (bound == WRITER_UNBOUND) {
            writerThreadId = me
            return true
        }
        if (bound == me) return true
        offWriterThreadCalls.incrementAndGet()
        return false
    }

    val boundWriterThreadId: Long get() = writerThreadId

    private fun onWriterThread(): Boolean {
        val bound = writerThreadId
        if (bound == WRITER_UNBOUND) {
            writerThreadId = Thread.currentThread().id
            return true
        }
        if (bound == Thread.currentThread().id) return true
        offWriterThreadCalls.incrementAndGet()
        return false
    }

    private fun beginPublish(): Long {
        val s = sequence.get() + 1L
        sequence.set(s)
        return s
    }

    private fun endPublish(s: Long, outcome: Outcome): Outcome {
        lastOutcome = outcome
        updateCount++
        if (!outcome.accepted) rejectedCount++
        sequence.set(s + 1L)
        return outcome
    }

    // Opens [epoch] with the continuous-frame base offset [baseFrame] (the
    // caller's stream position at the open, e.g. frames written to the sink
    // so far). Epochs must be strictly increasing; a base below the last
    // published position is clamped up (monotonic guarantee) and counted; a
    // base ahead of it is published at once as the epoch's opening position
    // (forward discontinuity, counted in baseAdvanceCount) so a reader sees
    // the writer-declared position (e.g. the Y9 seek target) before the
    // first anchor of the epoch lands. Provenance is RESET either way: the
    // opening position is declared by the writer, not measured.
    fun epochOpened(epoch: Int, baseFrame: Long, nowNs: Long): Outcome {
        if (!onWriterThread()) return Outcome.REJECTED_OFF_WRITER_THREAD
        val s = beginPublish()
        if (faulted) return endPublish(s, Outcome.REJECTED_FAULTED)
        if (epoch < 0) return endPublish(s, Outcome.REJECTED_INVALID_EPOCH)
        if (epochOpen) return endPublish(s, Outcome.REJECTED_EPOCH_ALREADY_OPEN)
        if (epoch <= epochId) return endPublish(s, Outcome.REJECTED_EPOCH_ORDER)
        if (baseFrame < 0L) return endPublish(s, Outcome.REJECTED_BASE_INVALID)
        var base = baseFrame
        val current = positionFrames
        if (base < current) {
            base = current
            baseClampCount++
        } else if (base > current) {
            baseAdvanceCount++
            lastBaseAdvanceFrames = base - current
            publishPosition(base, isAnchor = false)
        }
        epochId = epoch
        epochOpen = true
        epochOpenCount++
        epochBaseOffsetFrames = base
        anchorContinuousFrames = -1L
        anchorNanoTime = -1L
        lastRawFrame = -1L
        lastUnwrappedFrame = -1L
        lastHead = -1L
        lastAgeNs = -1L
        epochWrapSeen = false
        epochHasAnchor = false
        publishedAtNs = nowNs
        provenance = Provenance.RESET
        resetCount++
        return endPublish(s, Outcome.ACCEPTED_EPOCH_OPENED)
    }

    // Closes the open epoch: the anchor dies with the AudioTrack instance;
    // the published position is held and provenance becomes RESET.
    fun epochClosed(epoch: Int, nowNs: Long): Outcome {
        if (!onWriterThread()) return Outcome.REJECTED_OFF_WRITER_THREAD
        val s = beginPublish()
        if (!epochOpen) return endPublish(s, Outcome.REJECTED_NO_OPEN_EPOCH)
        if (epoch != epochId) return endPublish(s, Outcome.REJECTED_EPOCH_MISMATCH)
        epochOpen = false
        epochCloseCount++
        anchorContinuousFrames = -1L
        anchorNanoTime = -1L
        epochHasAnchor = false
        publishedAtNs = nowNs
        provenance = Provenance.RESET
        resetCount++
        return endPublish(s, Outcome.ACCEPTED_EPOCH_CLOSED)
    }

    // A valid AudioTimestamp sample of the open epoch. [rawUnsigned32Frame]
    // is framePosition normalized to [0, 2^32); [nanoTime] is the sample's
    // CLOCK_MONOTONIC presentation time (System.nanoTime base).
    fun observeTimestamp(epoch: Int, rawUnsigned32Frame: Long, nanoTime: Long): Outcome {
        if (!onWriterThread()) return Outcome.REJECTED_OFF_WRITER_THREAD
        val s = beginPublish()
        if (faulted) return endPublish(s, Outcome.REJECTED_FAULTED)
        if (!epochOpen) return endPublish(s, Outcome.REJECTED_NO_OPEN_EPOCH)
        if (epoch != epochId) return endPublish(s, Outcome.REJECTED_EPOCH_MISMATCH)
        if (rawUnsigned32Frame < 0L || rawUnsigned32Frame >= FRAME_WRAP_MODULUS) {
            return endPublish(s, Outcome.REJECTED_RAW_OUT_OF_RANGE)
        }
        timestampSuccessCount++
        val unwrapped: Long
        if (!epochHasAnchor) {
            unwrapped = rawUnsigned32Frame
        } else {
            val last = lastRawFrame
            val delta = rawUnsigned32Frame - last
            if (delta >= 0L) {
                unwrapped = rawUnsigned32Frame + (if (epochWrapSeen) FRAME_WRAP_MODULUS else 0L)
            } else {
                val forward = rawUnsigned32Frame + FRAME_WRAP_MODULUS - last
                if (!epochWrapSeen && forward > 0L && forward < FRAME_WRAP_FORWARD_MAX) {
                    epochWrapSeen = true
                    wrapCount++
                    unwrapped = rawUnsigned32Frame + FRAME_WRAP_MODULUS
                } else {
                    regressionCount++
                    faulted = true
                    return endPublish(s, Outcome.REJECTED_FRAME_REGRESSION)
                }
            }
            if (nanoTime < anchorNanoTime) nanoTimeNonMonotonicCount++
        }
        val continuous = epochBaseOffsetFrames + unwrapped
        epochHasAnchor = true
        lastRawFrame = rawUnsigned32Frame
        lastUnwrappedFrame = unwrapped
        anchorContinuousFrames = continuous
        anchorNanoTime = nanoTime
        lastAgeNs = 0L
        publishedAtNs = nanoTime
        publishPosition(continuous, isAnchor = true)
        provenance = Provenance.ANCHORED
        anchoredCount++
        return endPublish(s, Outcome.ACCEPTED_ANCHORED)
    }

    // getTimestamp() returned false at the poll point (non-terminal). With
    // an anchor in the open epoch: extrapolate by (nowNs - anchorNanoTime)
    // up to the horizon, else hold the position and publish STALE. Without
    // an anchor: RESET stays (nothing to extrapolate from). [playbackHead]
    // is recorded as telemetry only; it never becomes a position.
    fun observeTimestampUnavailable(epoch: Int, playbackHead: Long, nowNs: Long): Outcome {
        if (!onWriterThread()) return Outcome.REJECTED_OFF_WRITER_THREAD
        val s = beginPublish()
        if (faulted) return endPublish(s, Outcome.REJECTED_FAULTED)
        if (!epochOpen) return endPublish(s, Outcome.REJECTED_NO_OPEN_EPOCH)
        if (epoch != epochId) return endPublish(s, Outcome.REJECTED_EPOCH_MISMATCH)
        timestampUnavailableCount++
        lastHead = playbackHead
        publishedAtNs = nowNs
        if (!epochHasAnchor) {
            lastAgeNs = -1L
            provenance = Provenance.RESET
            noAnchorCount++
            return endPublish(s, Outcome.ACCEPTED_NO_ANCHOR)
        }
        var age = nowNs - anchorNanoTime
        if (age < 0L) {
            negativeAgeCount++
            age = 0L
        }
        lastAgeNs = age
        return if (age <= extrapolationHorizonNs) {
            val advance = age * sampleRate / 1_000_000_000L
            val before = positionFrames
            publishPosition(anchorContinuousFrames + advance, isAnchor = false)
            val published = positionFrames - before
            if (published > maxExtrapolatedAdvanceFrames) maxExtrapolatedAdvanceFrames = published
            if (age > maxExtrapolatedAgeNs) maxExtrapolatedAgeNs = age
            provenance = Provenance.EXTRAPOLATED
            extrapolatedCount++
            endPublish(s, Outcome.ACCEPTED_EXTRAPOLATED)
        } else {
            // Hold: no fabricated position past the horizon.
            if (minStaleAgeNs < 0L || age < minStaleAgeNs) minStaleAgeNs = age
            provenance = Provenance.STALE
            staleCount++
            endPublish(s, Outcome.ACCEPTED_STALE)
        }
    }

    private fun publishPosition(candidate: Long, isAnchor: Boolean) {
        val current = positionFrames
        if (candidate < current) {
            if (isAnchor) anchorClampCount++
            // Held at `current`; monotonicity is preserved by construction.
            return
        }
        positionFrames = candidate
        if (positionFrames < current) monotonicViolationCount++
    }

    // ── Reader API (any thread; allocates one Snapshot) ────────────────────

    fun snapshot(): Snapshot {
        val me = Thread.currentThread().id
        if (me == writerThreadId) snapshotCallsFromWriterThread.incrementAndGet() else snapshotCallsFromOtherThreads.incrementAndGet()
        var attempts = 0
        while (true) {
            val s0 = sequence.get()
            if (s0 and 1L == 0L) {
                val snap = readFields(s0, consistent = true)
                if (sequence.get() == s0) return snap
                if (++attempts >= SNAPSHOT_MAX_ATTEMPTS) return snap.copy(consistent = false)
            } else if (++attempts >= SNAPSHOT_MAX_ATTEMPTS) {
                return readFields(s0, consistent = false)
            }
            Thread.yield()
        }
    }

    private fun readFields(seq: Long, consistent: Boolean): Snapshot {
        val frames = positionFrames
        return Snapshot(
            consistent = consistent,
            sequence = seq,
            provenance = provenance,
            epochId = epochId,
            epochOpen = epochOpen,
            epochBaseOffsetFrames = epochBaseOffsetFrames,
            positionFrames = frames,
            positionUs = framesToUs(frames, sampleRate),
            anchorContinuousFrames = anchorContinuousFrames,
            anchorNanoTime = anchorNanoTime,
            lastRawFrame = lastRawFrame,
            lastUnwrappedFrame = lastUnwrappedFrame,
            lastHead = lastHead,
            publishedAtNs = publishedAtNs,
            lastAgeNs = lastAgeNs,
            sampleRate = sampleRate,
            extrapolationHorizonNs = extrapolationHorizonNs,
            faulted = faulted,
            lastOutcome = lastOutcome,
            updateCount = updateCount,
            timestampSuccessCount = timestampSuccessCount,
            timestampUnavailableCount = timestampUnavailableCount,
            anchoredCount = anchoredCount,
            extrapolatedCount = extrapolatedCount,
            staleCount = staleCount,
            noAnchorCount = noAnchorCount,
            resetCount = resetCount,
            epochOpenCount = epochOpenCount,
            epochCloseCount = epochCloseCount,
            wrapCount = wrapCount,
            regressionCount = regressionCount,
            rejectedCount = rejectedCount,
            anchorClampCount = anchorClampCount,
            baseClampCount = baseClampCount,
            baseAdvanceCount = baseAdvanceCount,
            lastBaseAdvanceFrames = lastBaseAdvanceFrames,
            negativeAgeCount = negativeAgeCount,
            nanoTimeNonMonotonicCount = nanoTimeNonMonotonicCount,
            maxExtrapolatedAgeNs = maxExtrapolatedAgeNs,
            minStaleAgeNs = minStaleAgeNs,
            maxExtrapolatedAdvanceFrames = maxExtrapolatedAdvanceFrames,
            staleAdvanceFrames = staleAdvanceFrames,
            monotonicViolationCount = monotonicViolationCount,
            offWriterThreadCalls = offWriterThreadCalls.get(),
            snapshotCallsFromWriterThread = snapshotCallsFromWriterThread.get(),
            snapshotCallsFromOtherThreads = snapshotCallsFromOtherThreads.get(),
            writerThreadId = writerThreadId,
        )
    }
}
