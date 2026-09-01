package com.connects.vanguard_media_engine.diagnostics

import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump (P4
// True-DAG sub-slice X4) ────────────────────────────────────────────────────
//
// Two-source lockstep ingest engine for the multi-source realtime-clock
// async runtime queue smoke. Ports the sub-slice K pump's lockstep source
// generation, synthetic sample, reference-mix checksum model, and explicit
// synthetic-generator re-anchor — and deliberately DELETES every step /
// native-dispatch path K had: in X4 only the NATIVE WORKER dispatches, so
// this pump never calls (and the X4 wrapper never exposes) any
// step/dispatch method. Owns:
//   - the track-1 synthetic PCM generation on the shared accepted-frame
//     axis, with an EXPLICIT generator re-anchor at the joint seek's
//     accepted frame A,
//   - the Kotlin reference-mix checksum model (clamp16(s0 + s1) with
//     c = c * 31 + (sample & 0xFFFF), mirroring the native unit-gain
//     int32-accumulate-then-clamp mix bus) plus per-track accepted
//     checksums, streamed BEFORE each chunk crosses into native,
//   - the two-track contribution counters,
//   - the lockstep make-room machine: when neither node-owned source ring
//     accepts anything in steady state, available OUTPUT is drained to the
//     driver's muted AudioTrack sink and the pump sleeps briefly — the
//     async worker then frees source space on its own realtime pace. The
//     retry budget is TIME-based only ([pollCancellation] throws past the
//     run deadline); there is no iteration cap.
//
// Prefill phases (pre-start / post-seek) run with drains forbidden (the
// pending output ack must survive until the fill quota is met): a stalled
// sub-chunk is latched (already checksummed, partially ingested) and the
// un-staged slice remainder is compacted to byte offset 0 and returned to
// the driver, which starts/re-anchors the native session and then completes
// the latched chunk with drains allowed. No decoded frame handed to this
// pump is ever dropped.
//
// Lockstep invariant: for every real (track 0) frame chunk, exactly the
// same frame count of synthetic (track 1) PCM is ingested; the two native
// accepted totals return to exactly equal at every completed chunk
// boundary.
class AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump(
    private val session: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession,
    private val channelCount: Int,
    maxFramesPerMix: Int,
    private val pollCancellation: () -> Unit,
    private val drainOutputToSink: () -> Long,
    // X5 (dynamic-gain-envelope mode) only: per-(track, accepted frame)
    // effective gain of the native scheduler/mix-bus envelope path,
    // replicated exactly (integer-us floor pts on window-aligned full mix
    // windows, double interpolation, single truncating quantization). Null
    // keeps the X4 unit-gain clamp16(s0 + s1) reference model bit-exact.
    private val envelopeGainModel: ((track: Int, frameIndex: Long) -> Double)? = null,
) {
    class FailClosed(val reason: String) : Exception(reason)

    companion object {
        private const val MAKEROOM_SLEEP_MS = 2L
    }

    private val bytesPerFrame = 2 * channelCount
    private val mfpm = maxFramesPerMix

    // One reused direct lockstep chunk buffer per track (at most one mix
    // window each); native reads them at byte offset 0.
    private val chunk0: ByteBuffer = ByteBuffer
        .allocateDirect(maxFramesPerMix * bytesPerFrame)
        .order(ByteOrder.LITTLE_ENDIAN)
    private val chunk1: ByteBuffer = ByteBuffer
        .allocateDirect(maxFramesPerMix * bytesPerFrame)
        .order(ByteOrder.LITTLE_ENDIAN)

    // Kotlin reference model state on the shared accepted-frame axis.
    // kotlinFramesAccepted counts COMPLETED lockstep chunks only; a
    // stalled (latched) chunk's frames are visible via [framesCommitted]
    // because their checksums are already streamed.
    var kotlinFramesAccepted = 0L
        private set
    private var kotlinTrack0Checksum = 0L
    private var kotlinTrack1Checksum = 0L
    private var kotlinMixedChecksum = 0L

    // Latched pending sub-chunk after a no-drain stall: remaining
    // un-ingested frames per track (compacted to offset 0 of each chunk
    // buffer) and the chunk's total frame count.
    private var pendingFrames0 = 0
    private var pendingFrames1 = 0
    private var pendingChunkFrames = 0

    // Two-track contribution counters.
    var track0NonZeroSampleCount = 0L
        private set
    var track1NonZeroSampleCount = 0L
        private set

    // Synthetic generator cursor on the shared accepted-frame axis. The
    // sample function is pure in the frame index, but the seek protocol
    // still requires an EXPLICIT re-anchor at accepted frame A (verified
    // against the reference model cursor).
    private var syntheticGeneratorNextFrame = 0L
    var generatorReanchorCount = 0L
        private set

    val hasPendingChunk: Boolean get() = pendingChunkFrames > 0
    val framesCommitted: Long get() = kotlinFramesAccepted + pendingChunkFrames

    val kotlinTrack0AcceptedChecksumHex: String
        get() = String.format("%016x", kotlinTrack0Checksum)
    val kotlinTrack1AcceptedChecksumHex: String
        get() = String.format("%016x", kotlinTrack1Checksum)
    val kotlinReferenceMixChecksumHex: String
        get() = String.format("%016x", kotlinMixedChecksum)

    // Deterministic, non-silent, low-amplitude (|v| <= 504) synthetic
    // sample on the shared accepted-frame axis; identical to the
    // multi-source pipeline slices so the mix model stays comparable.
    private fun syntheticSample(frameIndex: Long, channel: Int): Int =
        ((frameIndex * 7L + channel * 3L) % 1009L).toInt() - 504

    // ── Lockstep ingest ─────────────────────────────────────────────────────

    // Feeds one decoded slice of [sliceFrames] frames (byte offset 0 of
    // [slice]) through the lockstep rig in sub-chunks of at most one mix
    // window. With [allowDrain] false (prefill phases) a writer stall
    // latches the in-flight sub-chunk, compacts the untouched slice
    // remainder to byte offset 0, and returns that remainder's frame
    // count; with [allowDrain] true the make-room machine guarantees 0 is
    // returned (or the run deadline fails closed).
    fun ingestDecodedSlice(slice: ByteBuffer, sliceFrames: Int, allowDrain: Boolean): Int {
        if (sliceFrames <= 0) throw FailClosed("slice_frame_count_invalid")
        if (hasPendingChunk && !finishPendingChunk(allowDrain)) {
            return sliceFrames
        }
        var offsetFrames = 0
        while (offsetFrames < sliceFrames) {
            pollCancellation()
            val take = minOf(sliceFrames - offsetFrames, mfpm)
            stageLockstepSubChunk(slice, offsetFrames, take)
            offsetFrames += take
            if (!finishPendingChunk(allowDrain)) {
                val remaining = sliceFrames - offsetFrames
                if (remaining > 0) compactRemainder(slice, offsetFrames, sliceFrames)
                return remaining
            }
        }
        return 0
    }

    // Completes a latched pending sub-chunk once drains are permitted
    // (called by the driver right after the start/seek output ack is
    // consumed). No-op when nothing is latched.
    fun completePendingLockstep() {
        if (!hasPendingChunk) return
        if (!finishPendingChunk(allowDrain = true)) {
            throw FailClosed("pending_lockstep_not_completable")
        }
    }

    // One lockstep sub-chunk: copies the real frames to chunk0, synthesizes
    // the identical frame count into chunk1 at the generator cursor, and
    // streams the reference checksums BEFORE any JNI call (lossless
    // lockstep ingest may compact the chunk buffers).
    private fun stageLockstepSubChunk(slice: ByteBuffer, sliceFrameOffset: Int, frames: Int) {
        if (hasPendingChunk) throw FailClosed("stage_over_pending_chunk")
        if (syntheticGeneratorNextFrame != kotlinFramesAccepted) {
            throw FailClosed("synthetic_generator_cursor_divergence")
        }
        slice.limit((sliceFrameOffset + frames) * bytesPerFrame)
        slice.position(sliceFrameOffset * bytesPerFrame)
        chunk0.clear()
        chunk0.put(slice)
        slice.clear()
        val base = syntheticGeneratorNextFrame
        val sampleCount = frames * channelCount
        val envelope = envelopeGainModel
        for (i in 0 until sampleCount) {
            val s0 = chunk0.getShort(i * 2).toInt()
            val frame = base + (i / channelCount)
            val s1 = syntheticSample(frame, i % channelCount)
            chunk1.putShort(i * 2, s1.toShort())
            if (s0 != 0) track0NonZeroSampleCount += 1
            if (s1 != 0) track1NonZeroSampleCount += 1
            // Per-track RAW accepted checksums stay envelope-free in both
            // modes: envelopes shape only the mixed output.
            kotlinTrack0Checksum = kotlinTrack0Checksum * 31L + (s0.toLong() and 0xFFFFL)
            kotlinTrack1Checksum = kotlinTrack1Checksum * 31L + (s1.toLong() and 0xFFFFL)
            var acc = if (envelope == null) {
                s0 + s1
            } else {
                // AudioMixBusNode parity: each sample is scaled by its
                // track's effective gain with ONE truncating double->int
                // quantization, accumulated in integer, clamped only at
                // the final int16 output stage below.
                (s0.toDouble() * envelope(0, frame)).toInt() +
                    (s1.toDouble() * envelope(1, frame)).toInt()
            }
            if (acc > 32767) acc = 32767 else if (acc < -32768) acc = -32768
            kotlinMixedChecksum = kotlinMixedChecksum * 31L + (acc.toLong() and 0xFFFFL)
        }
        pendingFrames0 = frames
        pendingFrames1 = frames
        pendingChunkFrames = frames
    }

    // Lossless lockstep ingest of the latched chunk: track 1 always
    // catches track 0 up first so the two accepted totals converge, and
    // when neither ring accepts anything the make-room machine drains
    // available output to the driver's muted AudioTrack sink (steady state
    // only) and sleeps briefly; the async worker then frees source space
    // on its own realtime pace. Returns false (chunk stays latched) on a
    // no-drain stall.
    private fun finishPendingChunk(allowDrain: Boolean): Boolean {
        while (pendingFrames0 > 0 || pendingFrames1 > 0) {
            pollCancellation()
            var progressed = false
            if (pendingFrames1 > pendingFrames0) {
                val want = pendingFrames1 - pendingFrames0
                val r = session.ingestTrackOnce(1, chunk1, want)
                if (r.framesAccepted > 0L) {
                    compactRemainder(chunk1, r.framesAccepted.toInt(), pendingFrames1)
                    pendingFrames1 -= r.framesAccepted.toInt()
                    progressed = true
                }
            } else {
                // pendingFrames0 >= pendingFrames1 and at least one is
                // positive, so pendingFrames0 > 0 here.
                val r = session.ingestTrackOnce(0, chunk0, pendingFrames0)
                if (r.framesAccepted > 0L) {
                    compactRemainder(chunk0, r.framesAccepted.toInt(), pendingFrames0)
                    pendingFrames0 -= r.framesAccepted.toInt()
                    progressed = true
                }
            }
            if (!progressed) {
                if (!allowDrain) return false
                // Never a native step/dispatch call: only drain what the
                // native worker already pushed, then yield. The deadline
                // inside pollCancellation() is the only retry budget.
                if (drainOutputToSink() == 0L) {
                    Thread.sleep(MAKEROOM_SLEEP_MS)
                }
            }
        }
        kotlinFramesAccepted += pendingChunkFrames
        syntheticGeneratorNextFrame += pendingChunkFrames
        pendingChunkFrames = 0
        if (session.totalFramesAcceptedTrack0 != session.totalFramesAcceptedTrack1) {
            throw FailClosed("track_frame_axis_divergence_after_chunk")
        }
        return true
    }

    // ── Seek support ────────────────────────────────────────────────────────

    // EXPLICIT synthetic generator re-anchor at the joint seek's accepted
    // frame A; the reference model cursor must already sit exactly there
    // and no latched chunk may straddle the boundary.
    fun reanchorSyntheticGenerator(acceptedFrame: Long) {
        if (hasPendingChunk) throw FailClosed("generator_reanchor_with_pending_chunk")
        if (acceptedFrame != kotlinFramesAccepted) {
            throw FailClosed("generator_reanchor_frame_mismatch")
        }
        syntheticGeneratorNextFrame = acceptedFrame
        generatorReanchorCount += 1
    }

    // ── End-of-run reference-model verdict ──────────────────────────────────

    data class ModelVerdict(
        val trackFrameAxisLockstepOk: Boolean,
        val mixedOutputFrameAccountingOk: Boolean,
        val referenceMixChecksumOk: Boolean,
        val nativeReadChecksumMatchesSinkOk: Boolean,
        val twoTrackContributionOk: Boolean,
    )

    // Fail-closed with distinct tokens. The checksum identity chain this
    // slice asserts is: per-track kotlin accepted == native accepted, and
    // kotlinReferenceMix == nativeOutputRead == kotlinSink; the mix must
    // differ from both single-track checksums with a non-silent synthetic
    // track (two-track contribution).
    fun verifyReferenceModel(kotlinSinkChecksumHex: String): ModelVerdict {
        if (hasPendingChunk) throw FailClosed("verify_with_pending_chunk")
        val lockstepOk =
            session.totalFramesAcceptedTrack0 == session.totalFramesAcceptedTrack1 &&
                session.totalFramesAcceptedTrack0 == kotlinFramesAccepted
        if (!lockstepOk) throw FailClosed("track_frame_axis_divergence")
        val mixedAccountingOk =
            session.totalOutputFramesRead == session.totalFramesAcceptedTrack0
        if (!mixedAccountingOk) throw FailClosed("mixed_frame_accounting_mismatch")
        if (kotlinTrack0AcceptedChecksumHex != session.nativeAcceptedChecksumHexTrack0) {
            throw FailClosed("track0_checksum_identity_mismatch")
        }
        if (kotlinTrack1AcceptedChecksumHex != session.nativeAcceptedChecksumHexTrack1) {
            throw FailClosed("track1_checksum_identity_mismatch")
        }
        val mixHex = kotlinReferenceMixChecksumHex
        val referenceOk = mixHex == session.nativeOutputReadChecksumHex
        if (!referenceOk) throw FailClosed("reference_mix_checksum_mismatch")
        val sinkOk = session.nativeOutputReadChecksumHex == kotlinSinkChecksumHex
        if (!sinkOk) throw FailClosed("native_read_sink_checksum_mismatch")
        val contributionOk = track1NonZeroSampleCount > 0L &&
            mixHex != session.nativeAcceptedChecksumHexTrack0 &&
            mixHex != session.nativeAcceptedChecksumHexTrack1
        if (!contributionOk) throw FailClosed("two_track_contribution_not_observed")
        return ModelVerdict(
            trackFrameAxisLockstepOk = lockstepOk,
            mixedOutputFrameAccountingOk = mixedAccountingOk,
            referenceMixChecksumOk = referenceOk,
            nativeReadChecksumMatchesSinkOk = sinkOk,
            twoTrackContributionOk = contributionOk,
        )
    }

    // ── Internals ───────────────────────────────────────────────────────────

    // Unwritten frames move to byte offset 0 so retries always read from
    // the buffer start, exactly like the graph-pipeline sessions.
    private fun compactRemainder(buf: ByteBuffer, acceptedFrames: Int, totalFrames: Int) {
        buf.position(acceptedFrames * bytesPerFrame)
        buf.limit(totalFrames * bytesPerFrame)
        buf.compact()
    }
}
