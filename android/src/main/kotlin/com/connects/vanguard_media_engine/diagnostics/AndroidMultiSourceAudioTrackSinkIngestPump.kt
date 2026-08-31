package com.connects.vanguard_media_engine.diagnostics

import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidMultiSourceAudioTrackSinkIngestPump (P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK) ─
//
// Two-source lockstep ingest engine for the P4-AUDIO-GRAPH-TRANSPORT-CLOCK
// sub-slice K multi-source AudioTrack sink smoke. Owns:
//   - the track-0 decoded-PCM sub-chunk copy out of the driver's slice
//     buffers (the driver owns the codec/extractor lifecycle and has
//     already released the codec output buffer),
//   - the track-1 synthetic PCM generation on the shared accepted-frame
//     axis, with an EXPLICIT generator re-anchor at the joint seek's
//     accepted frame A,
//   - the joint dispatch / joint tail-flush step calls against the native
//     session,
//   - the Kotlin reference-mix checksum model (clamp16(s0 + s1) with
//     c = c * 31 + (sample & 0xFFFF), mirroring the native unit-gain
//     int32-accumulate-then-clamp mix bus) plus per-track accepted
//     checksums,
//   - the two-track contribution counters,
//   - the common frame budget L truncation (lossless within [0, L) only;
//     truncation beyond the budget is an explicit non-claim).
//
// This pump NEVER reads the output ring itself and never calls any drain
// entry point: every dispatched window is handed back to the driver through
// [readWindowThroughSink] / [drainOutputThroughSink] so the driver owns
// every read -> AudioTrack.write step of the sink run.
//
// Lockstep invariant: for every real (track 0) frame chunk, exactly the
// same frame count of synthetic (track 1) PCM is ingested; the two accepted
// totals return to exactly equal at every stable chunk boundary. When
// neither ring can accept, the make-room machine dispatches drained joint
// pair windows through the sink and retries under a bounded budget.
class AndroidMultiSourceAudioTrackSinkIngestPump(
    private val session: AndroidMultiSourceAudioGraphPipelineNativeSession,
    private val channelCount: Int,
    maxFramesPerMix: Int,
    sourceRingCapacityFrames: Int,
    private val commonBudgetFrames: Long,
    private val pollCancellation: () -> Unit,
    private val readWindowThroughSink: (Long) -> Unit,
    private val drainOutputThroughSink: () -> Unit,
) {
    class FailClosed(val reason: String) : Exception(reason)

    companion object {
        private const val MAX_CHUNK_RETRIES = 128
        private const val MAX_STEP_RETRIES = 8
    }

    private val bytesPerFrame = 2 * channelCount
    private val mfpm = maxFramesPerMix.toLong()
    private val srcCap = sourceRingCapacityFrames.toLong()

    // One reused direct lockstep chunk buffer per track (at most one mix
    // window each); native reads them at byte offset 0.
    private val chunk0: ByteBuffer = ByteBuffer
        .allocateDirect(maxFramesPerMix * bytesPerFrame)
        .order(ByteOrder.LITTLE_ENDIAN)
    private val chunk1: ByteBuffer = ByteBuffer
        .allocateDirect(maxFramesPerMix * bytesPerFrame)
        .order(ByteOrder.LITTLE_ENDIAN)

    // Kotlin reference model state on the shared accepted-frame axis,
    // streamed BEFORE each chunk crosses into native (lossless lockstep
    // ingest may compact the buffers).
    var kotlinFramesAccepted = 0L
        private set
    var framesTruncatedBeyondBudget = 0L
        private set
    private var kotlinTrack0Checksum = 0L
    private var kotlinTrack1Checksum = 0L
    private var kotlinMixedChecksum = 0L

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

    val kotlinAcceptedChecksumHexTrack0: String
        get() = String.format("%016x", kotlinTrack0Checksum)
    val kotlinAcceptedChecksumHexTrack1: String
        get() = String.format("%016x", kotlinTrack1Checksum)
    val kotlinReferenceMixChecksumHex: String
        get() = String.format("%016x", kotlinMixedChecksum)

    // Deterministic, non-silent, low-amplitude (|v| <= 504) synthetic
    // sample on the shared accepted-frame axis; identical to the
    // multi-source graph-pipeline slice so the mix model stays comparable.
    private fun syntheticSample(frameIndex: Long, channel: Int): Int =
        ((frameIndex * 7L + channel * 3L) % 1009L).toInt() - 504

    // ── Lockstep ingest ─────────────────────────────────────────────────────

    // Copies one codec output chunk ([sizeBytes] at [offsetBytes] of
    // [outBuf]) into direct buffers before the driver releases the codec
    // buffer: the first slice lands in the reused [scratch], bounded
    // temporaries only when the chunk overflows it. No JNI runs in here.
    fun copyCodecChunk(
        outBuf: ByteBuffer,
        offsetBytes: Int,
        sizeBytes: Int,
        scratch: ByteBuffer,
    ): List<Pair<ByteBuffer, Int>> {
        val sliceCapBytes = scratch.capacity()
        val slices = ArrayList<Pair<ByteBuffer, Int>>()
        var sliceOffset = offsetBytes
        var remainingBytes = sizeBytes
        while (remainingBytes > 0) {
            val sliceBytes = minOf(remainingBytes, sliceCapBytes)
            val dst = if (slices.isEmpty()) {
                scratch
            } else {
                ByteBuffer.allocateDirect(sliceBytes).order(ByteOrder.LITTLE_ENDIAN)
            }
            outBuf.position(sliceOffset)
            outBuf.limit(sliceOffset + sliceBytes)
            dst.clear()
            dst.put(outBuf)
            slices.add(dst to sliceBytes / bytesPerFrame)
            sliceOffset += sliceBytes
            remainingBytes -= sliceBytes
        }
        return slices
    }

    // Feeds one decoded slice of [sliceFrames] frames (byte offset 0 of
    // [slice]) through the lockstep rig in sub-chunks of at most one mix
    // window, truncating losslessly at the common budget L.
    fun ingestDecodedSlice(slice: ByteBuffer, sliceFrames: Int) {
        var offsetFrames = 0
        while (offsetFrames < sliceFrames) {
            pollCancellation()
            val budgetLeft = commonBudgetFrames - kotlinFramesAccepted
            if (budgetLeft <= 0L) {
                framesTruncatedBeyondBudget += (sliceFrames - offsetFrames).toLong()
                return
            }
            val take = minOf(
                (sliceFrames - offsetFrames).toLong(),
                mfpm,
                budgetLeft,
            ).toInt()
            ingestLockstepSubChunk(slice, offsetFrames, take)
            offsetFrames += take
        }
    }

    // One lockstep sub-chunk: copies the real frames to chunk0, synthesizes
    // the identical frame count into chunk1 at the generator cursor,
    // streams the reference checksums, then hands both to native.
    private fun ingestLockstepSubChunk(slice: ByteBuffer, sliceFrameOffset: Int, frames: Int) {
        if (syntheticGeneratorNextFrame != kotlinFramesAccepted) {
            throw FailClosed("synthetic_generator_cursor_divergence")
        }
        slice.limit((sliceFrameOffset + frames) * bytesPerFrame)
        slice.position(sliceFrameOffset * bytesPerFrame)
        chunk0.clear()
        chunk0.put(slice)
        val base = syntheticGeneratorNextFrame
        val sampleCount = frames * channelCount
        for (i in 0 until sampleCount) {
            val s0 = chunk0.getShort(i * 2).toInt()
            val s1 = syntheticSample(base + (i / channelCount), i % channelCount)
            chunk1.putShort(i * 2, s1.toShort())
            if (s0 != 0) track0NonZeroSampleCount += 1
            if (s1 != 0) track1NonZeroSampleCount += 1
            kotlinTrack0Checksum = kotlinTrack0Checksum * 31L + (s0.toLong() and 0xFFFFL)
            kotlinTrack1Checksum = kotlinTrack1Checksum * 31L + (s1.toLong() and 0xFFFFL)
            var acc = s0 + s1
            if (acc > 32767) acc = 32767 else if (acc < -32768) acc = -32768
            kotlinMixedChecksum = kotlinMixedChecksum * 31L + (acc.toLong() and 0xFFFFL)
        }
        ingestLockstepChunkThroughSink(frames)
        kotlinFramesAccepted += frames
        syntheticGeneratorNextFrame += frames
    }

    // Lossless lockstep ingest of one chunk with the make-room machine:
    // track 1 always catches track 0 up first, and when neither ring
    // accepts anything a drained joint pair window is dispatched THROUGH
    // THE SINK to free space; bounded retries fail closed.
    private fun ingestLockstepChunkThroughSink(frames: Int) {
        if (frames <= 0 || frames.toLong() > mfpm) throw FailClosed("lockstep_chunk_size_invalid")
        var remaining0 = frames
        var remaining1 = frames
        var retries = 0
        while (remaining0 > 0 || remaining1 > 0) {
            pollCancellation()
            if (++retries > MAX_CHUNK_RETRIES) {
                throw FailClosed("multi_source_makeroom_budget_exhausted")
            }
            var progressed = false
            if (remaining1 > remaining0) {
                val want = remaining1 - remaining0
                val r = session.ingestTrackOnce(1, chunk1, want)
                if (r.framesAccepted > 0L) {
                    compactRemainder(chunk1, r.framesAccepted.toInt(), remaining1)
                    remaining1 -= r.framesAccepted.toInt()
                    progressed = true
                }
            } else if (remaining0 > 0) {
                val r = session.ingestTrackOnce(0, chunk0, remaining0)
                if (r.framesAccepted > 0L) {
                    compactRemainder(chunk0, r.framesAccepted.toInt(), remaining0)
                    remaining0 -= r.framesAccepted.toInt()
                    progressed = true
                }
            }
            if (!progressed && (remaining0 > 0 || remaining1 > 0)) {
                if (minOf(
                        session.sourceAvailableReadFramesTrack0,
                        session.sourceAvailableReadFramesTrack1,
                    ) < mfpm
                ) {
                    throw FailClosed("ring_full_without_dispatchable_pair")
                }
                if (!stepJointWindowThroughSink()) throw FailClosed("makeroom_step_deferred")
            }
        }
        if (session.totalFramesAcceptedTrack0 != session.totalFramesAcceptedTrack1) {
            throw FailClosed("track_frame_axis_divergence_after_chunk")
        }
    }

    // ── Joint dispatch / tail flush through the sink ────────────────────────

    // One joint dispatch attempt: dispatch_ok windows are read+written by
    // the driver, output backpressure drains through the AudioTrack, and
    // deferred_insufficient_joint_source returns false (normal while
    // awaiting more lockstep ingest).
    fun stepJointWindowThroughSink(): Boolean {
        var retries = 0
        while (true) {
            pollCancellation()
            if (++retries > MAX_STEP_RETRIES) throw FailClosed("step_retry_budget_exhausted")
            when (val s = session.stepJointWindow()) {
                "dispatch_ok" -> {
                    readWindowThroughSink(mfpm)
                    return true
                }
                "output_backpressure" -> drainOutputThroughSink()
                "deferred_insufficient_joint_source" -> return false
                else -> throw FailClosed("pump_step_status_$s")
            }
        }
    }

    // Drives the closed loop while both source rings hold a full window.
    fun pumpWhileJointWindows() {
        var guard = 0
        val budget = (srcCap / mfpm) + 4
        while (minOf(
                session.sourceAvailableReadFramesTrack0,
                session.sourceAvailableReadFramesTrack1,
            ) >= mfpm
        ) {
            pollCancellation()
            if (++guard > budget) throw FailClosed("pump_budget_exhausted")
            if (!stepJointWindowThroughSink()) break
        }
    }

    // Joint boundary flush through the sink: both writers EOS together,
    // then a tail-flush loop that reads every rendered window through the
    // driver's sink path and terminates only on tail_flush_complete.
    // Afterwards the output ring must be fully read (0) and both source
    // rings empty (0) — a residual mismatch would already have failed
    // closed natively with tail_flush_track_length_mismatch.
    fun flushTailAtEosThroughSink() {
        session.setEosBothTracks()
        var budget = 0
        val tailBudget = (srcCap / mfpm) + 8
        while (true) {
            pollCancellation()
            if (++budget > tailBudget) throw FailClosed("tail_flush_budget_exhausted")
            val step = session.stepTailWindow()
            when (step.status) {
                "dispatch_ok", "tail_flush_partial_window" -> {
                    if (step.framesRendered <= 0L) throw FailClosed("tail_flush_rendered_zero")
                    readWindowThroughSink(step.framesRendered)
                }
                "tail_flush_complete" -> break
                "output_backpressure" -> drainOutputThroughSink()
                else -> throw FailClosed("tail_flush_step_status_${step.status}")
            }
        }
        drainOutputThroughSink()
        if (session.outputAvailableReadFrames != 0L) {
            throw FailClosed("tail_flush_output_not_drained")
        }
        if (session.sourceAvailableReadFramesTrack0 != 0L ||
            session.sourceAvailableReadFramesTrack1 != 0L
        ) {
            throw FailClosed("tail_flush_source_not_empty")
        }
    }

    // ── Seek support ────────────────────────────────────────────────────────

    // EXPLICIT synthetic generator re-anchor at the joint seek's accepted
    // frame A; the reference model cursor must already sit exactly there.
    fun reanchorSyntheticGenerator(acceptedFrame: Long) {
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
        val nativeDrainChecksumMatchesSinkOk: Boolean,
        val twoTrackContributionOk: Boolean,
    )

    // Fail-closed with distinct tokens. The one checksum identity chain
    // this slice asserts is kotlinReferenceMix == nativeOutputDrain ==
    // kotlinSink; per-track checksums are compared only within this run
    // (never against any previous slice's checksum value), and the mix
    // must differ from both single tracks (two-track contribution).
    fun verifyReferenceModel(kotlinSinkChecksumHex: String): ModelVerdict {
        val lockstepOk =
            session.totalFramesAcceptedTrack0 == session.totalFramesAcceptedTrack1 &&
                session.totalFramesAcceptedTrack0 == kotlinFramesAccepted
        if (!lockstepOk) throw FailClosed("track_frame_axis_divergence")
        val mixedAccountingOk =
            session.totalOutputFramesDrained == session.totalFramesAcceptedTrack0
        if (!mixedAccountingOk) throw FailClosed("mixed_frame_accounting_mismatch")
        if (kotlinAcceptedChecksumHexTrack0 != session.nativeAcceptedChecksumHexTrack0) {
            throw FailClosed("track0_checksum_identity_mismatch")
        }
        if (kotlinAcceptedChecksumHexTrack1 != session.nativeAcceptedChecksumHexTrack1) {
            throw FailClosed("track1_checksum_identity_mismatch")
        }
        val mixHex = kotlinReferenceMixChecksumHex
        val referenceOk = mixHex == session.nativeOutputDrainChecksumHex
        if (!referenceOk) throw FailClosed("reference_mix_checksum_mismatch")
        val sinkOk = session.nativeOutputDrainChecksumHex == kotlinSinkChecksumHex
        if (!sinkOk) throw FailClosed("native_drain_sink_checksum_mismatch")
        val contributionOk = track1NonZeroSampleCount > 0L &&
            mixHex != session.nativeAcceptedChecksumHexTrack0 &&
            mixHex != session.nativeAcceptedChecksumHexTrack1
        if (!contributionOk) throw FailClosed("two_track_contribution_not_observed")
        return ModelVerdict(
            trackFrameAxisLockstepOk = lockstepOk,
            mixedOutputFrameAccountingOk = mixedAccountingOk,
            referenceMixChecksumOk = referenceOk,
            nativeDrainChecksumMatchesSinkOk = sinkOk,
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
