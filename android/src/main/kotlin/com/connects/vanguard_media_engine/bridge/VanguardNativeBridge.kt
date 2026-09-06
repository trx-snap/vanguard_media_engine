package com.connects.vanguard_media_engine.bridge

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.view.Surface
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import com.connects.vanguard_media_engine.codec.PlatformCodecAdapter

class VanguardNativeBridge(
    private val lifecycleObserver: VanguardLifecycleObserver,
    private val diagnostics: VanguardDiagnostics,
    private val codecAdapter: PlatformCodecAdapter?
) {

    companion object {
        init {
            System.loadLibrary("vanguard_media_engine")
        }

        // ── P4 True-DAG V4.3 sub-slice G1: audio decoder ring ingest diagnostic session core ─
        // Native JNI session seam for the future real MediaCodec-to-
        // AudioDecoderRingWriter ingest proof. Kotlin will remain the sole
        // owner of MediaCodec/MediaExtractor; native only accepts
        // already-decoded interleaved little-endian signed PCM16 handed
        // across a direct java.nio.ByteBuffer (data starts at byte offset 0)
        // and feeds it through AudioDecoderRingWriter into an
        // AudioSpscAudioRingBuffer, then drains/verifies on the reader side.
        // Every non-destroy call must run on the session's creating thread
        // (native fails closed with status=wrong_owner_thread otherwise).
        // No native worker threads, no AudioTrack/AAudio/OpenSL/Oboe, no
        // realtime or audible playback, no file IO, no wall-clock reads.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate <= 0, channelCount not in {1,2}, ringCapacityFrames
        // not a power of two in [64, 65536]) or when the 4-live-session
        // registry cap is reached.
        external fun createAudioDecoderRingIngestSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            ringCapacityFrames: Int,
        ): Long

        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestAudioDecoderRingPcm16(
            sessionHandle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        external fun drainAudioDecoderRingIngestSession(
            sessionHandle: Long,
            maxFrames: Int,
        ): String

        external fun requestAudioDecoderRingIngestSeek(
            sessionHandle: Long,
            targetFrame: Long,
        ): String

        external fun setAudioDecoderRingIngestEos(
            sessionHandle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyAudioDecoderRingIngestSmokeSession(
            sessionHandle: Long,
        ): String

        // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: session-scoped closed-loop audio graph pipeline seam ─
        // Step-driven native session over the full diagnostic rig:
        // AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer ->
        // RingBufferAudioSampleProvider -> GraphAudioScheduler ->
        // AudioMixBusNode -> ClockedAudioTransportCoordinator -> output
        // AudioSpscAudioRingBuffer -> consumer drain. Exactly one routed
        // source track at unit gain; Kotlin hands synthetic interleaved
        // little-endian signed PCM16 across a direct java.nio.ByteBuffer and
        // derives every clock tick itself (native never reads a wall clock).
        // Every non-destroy call must run on the session's creating thread
        // (native fails closed with status=wrong_owner_thread otherwise).
        // No native worker threads, no MediaCodec/MediaExtractor, no
        // AudioTrack/AAudio/OpenSL/Oboe, no realtime or audible playback,
        // no file IO. Forward-only seek; writer-local EOS only.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate not in [8000, 192000], channelCount not in {1,2},
        // maxFramesPerMix not in [1, 8192], ring capacities not powers of
        // two in [64, 65536], outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames < 2*maxFramesPerMix) or when the
        // 4-live-session registry cap is reached.
        external fun createAudioGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestAudioGraphPipelinePcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startAudioGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick.
        // flushTail=false requires a full window of source frames
        // (status=deferred_insufficient_source otherwise, with no mutation);
        // flushTail=true (writer EOS required) advances exactly the
        // remaining source frames (tail_flush_partial_window /
        // tail_flush_complete). Every step status reports
        // sourceAvailableReadFrames.
        external fun stepAudioGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainAudioGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE (sub-slice I) output-ring
        // reader: consumes a pending start/seek ack first, then pops up to
        // maxFrames of mixed PCM16 directly into the caller's direct
        // ByteBuffer at byte offset 0 (single pop, no native scratch) so the
        // same buffer can be handed to android.media.AudioTrack.
        // maxFrames == 0 is a legal ack-only read. A single run must pop
        // frames through exactly one of drain/read.
        external fun readAudioGraphPipelineOutputPcm16(
            handle: Long,
            pcmBuffer: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Forward-only seek. Requires a fully drained output ring, an empty
        // source ring, and targetFrame >= the provider's cursor; the caller
        // must drain the output-ring ack next.
        external fun seekAudioGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Writer-local EOS only (cleared by the next successful seek).
        external fun setAudioGraphPipelineEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot, including the fixed-at-construction
        // scratch/storage capacities used to prove zero native steady-state
        // allocation across repeated cycles.
        external fun snapshotAudioGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyAudioGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE: session-scoped two-source closed-loop audio graph pipeline seam ─
        // Step-driven native session over the two-track diagnostic rig:
        // per-track AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer
        // -> RingBufferAudioSampleProvider (track 0 = real-decoder PCM,
        // track 1 = Kotlin-synthesized PCM) -> GraphAudioScheduler ->
        // AudioMixBusNode (multi_source_src0 -> primary_audio_in,
        // multi_source_src1 -> secondary_audio_in, unit gain) ->
        // ClockedAudioTransportCoordinator -> output ring -> consumer drain.
        // The native frame axis is the SHARED ACCEPTED FRAME COUNT (full
        // overlap only): the joint dispatch gate needs a full window on BOTH
        // source rings, the joint tail flush needs BOTH writers EOS with
        // identical residuals, and the one forward seek reanchors BOTH
        // tracks at a single accepted frame cursor. Handles minted here are
        // NOT interchangeable with the one-source graph-pipeline session
        // registry. Every non-destroy call must run on the session's
        // creating thread (native fails closed with
        // status=wrong_owner_thread otherwise). No native worker threads, no
        // MediaCodec/MediaExtractor, no AudioTrack/AAudio/OpenSL/Oboe, no
        // realtime or audible playback, no file IO, no wall-clock reads.

        // Returns an opaque session handle, or 0 on invalid input (same
        // bounds as the one-source seam) or when the two-track route did not
        // resolve exactly (routedSourceCount 2 in src0, src1 order) or the
        // 4-live-session registry cap is reached.
        external fun createMultiSourceAudioGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Per-track producer side; trackIndex must be 0 or 1
        // (status=invalid_track_index otherwise, no mutation). Accepted
        // frames are clamped to min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestMultiSourceAudioGraphPipelinePcm16(
            handle: Long,
            trackIndex: Int,
            pcmBuffer: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startMultiSourceAudioGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick.
        // flushTail=false requires a full window on BOTH source rings
        // (status=deferred_insufficient_joint_source otherwise, with no
        // mutation; no EOS term); flushTail=true requires BOTH writers EOS
        // and identical per-track residuals
        // (tail_flush_track_length_mismatch otherwise, no zero-fill) and
        // advances exactly min(avail0, avail1, maxFramesPerMix) frames
        // (tail_flush_partial_window / tail_flush_complete). Every step
        // status reports both per-track sourceAvailableReadFrames.
        external fun stepMultiSourceAudioGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainMultiSourceAudioGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK (sub-slice K) output-ring
        // reader: consumes a pending start/seek ack first, then pops up to
        // maxFrames of mixed two-track PCM16 directly into the caller's
        // direct ByteBuffer at byte offset 0 (single pop, no native
        // scratch) so the same buffer can be handed to
        // android.media.AudioTrack. maxFrames == 0 is a legal ack-only
        // read. A single run must pop frames through exactly one of
        // drain/read.
        external fun readMultiSourceAudioGraphPipelineOutputPcm16(
            sessionHandle: Long,
            pcmBuffer: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Forward-only joint seek. Requires a fully drained output ring,
        // both source rings empty, and the shared accepted-frame axis
        // intact (track_frame_axis_divergence otherwise); reanchors BOTH
        // tracks at the same accepted frame. The caller must drain the
        // output-ring ack next.
        external fun seekMultiSourceAudioGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Per-track writer-local EOS only (cleared by the next successful
        // seek); trackIndex must be 0 or 1. The joint tail flush requires
        // both tracks EOS together.
        external fun setMultiSourceAudioGraphPipelineEos(
            handle: Long,
            trackIndex: Int,
        ): String

        // Full diagnostic snapshot with Track0/Track1-suffixed per-track
        // keys, the fixed-at-construction scratch/storage capacities used to
        // prove zero native steady-state allocation, and the verbatim proof
        // boundary. Never silently truncated (status=snapshot_overflow fails
        // closed instead).
        external fun snapshotMultiSourceAudioGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyMultiSourceAudioGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-DECODER-SOURCE-NODE-WIRING: session-scoped node-owned-source closed-loop audio graph pipeline seam ─
        // Step-driven native session over the node-owned-transport diagnostic
        // rig: DecodedAudioPcmSourceNode (6-arg constructor) owns its source
        // AudioSpscAudioRingBuffer + AudioDecoderRingWriter +
        // RingBufferAudioSampleProvider triple by composition, and
        // GraphAudioScheduler auto-discovers the provider from graph
        // topology alone (tag-dispatched constructor; no external provider
        // map, no hybrid routing) -> AudioMixBusNode ->
        // ClockedAudioTransportCoordinator -> output ring -> consumer drain.
        // Diagnostic node-owned decoded audio source ring/provider wiring
        // proof only: no production export or pass-2 graph reroute, no
        // product/editor UI, no ConnectsApp, no streaming/cache, no iOS.
        // Kotlin hands synthetic interleaved little-endian signed PCM16
        // across a direct java.nio.ByteBuffer and derives every clock tick
        // itself (native never reads a wall clock). Every non-destroy call
        // must run on the session's creating thread (native fails closed
        // with status=wrong_owner_thread otherwise). No native worker
        // threads, no MediaCodec/MediaExtractor ownership in C++, no
        // AudioTrack/AAudio/OpenSL/Oboe, no realtime/audio-focus/route/
        // dead-object/audible/speaker/latency/glitch claims, no file IO.
        // Handles minted here are NOT interchangeable with any other
        // pipeline session registry. Forward-only seek; writer-local EOS
        // only.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate not in [8000, 192000], channelCount not in {1,2},
        // expectedFrameCount not in [1, 10*sampleRate] — the node's own
        // 10-second timeline-window ceiling, maxFramesPerMix not in
        // [1, 8192], ring capacities not powers of two in [64, 65536],
        // outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames < 2*maxFramesPerMix), when the
        // auto-discovered route did not resolve to exactly the one
        // node-owned source track, or when the 4-live-session registry cap
        // is reached. expectedFrameCount bounds the node's isActiveAt
        // timeline window, so it must cover every frame the caller will
        // dispatch; sourceRingCapacityFrames is the node's explicit
        // ringCapacityFrames constructor argument.
        external fun createNodeOwnedAudioSourceGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Producer side, writing through the NODE-OWNED ring writer.
        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestNodeOwnedAudioSourceGraphPipelinePcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick;
        // the scheduler pulls from the auto-discovered node-owned provider.
        // flushTail=false requires a full window of source frames
        // (status=deferred_insufficient_source otherwise, with no mutation);
        // flushTail=true (writer EOS required) advances exactly the
        // remaining source frames (tail_flush_partial_window /
        // tail_flush_complete). Every step status reports
        // sourceAvailableReadFrames.
        external fun stepNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM.
        external fun drainNodeOwnedAudioSourceGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT (sub-slice O)
        // output-ring reader: consumes a pending start/seek ack first, then
        // pops up to maxFrames of mixed PCM16 from the node-owned pipeline's
        // output ring directly into the caller's direct ByteBuffer at byte
        // offset 0 (single pop, no native scratch) so the same buffer can be
        // handed to android.media.AudioTrack. maxFrames == 0 is a legal
        // ack-only read. A single run must pop frames through exactly one of
        // drain/read.
        external fun readNodeOwnedAudioSourceGraphPipelineOutputPcm16(
            handle: Long,
            pcmBuffer: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Forward-only seek. Requires a fully drained output ring, an empty
        // node-owned source ring, and targetFrame >= the node-owned
        // provider's cursor; the caller must drain the output-ring ack next.
        external fun seekNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // Writer-local EOS only (cleared by the next successful seek).
        external fun setNodeOwnedAudioSourceGraphPipelineEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot including the node-owned-wiring facts
        // (routedSourceCount, routedSourceId0, nodeOwnsRing), provider
        // underrun/skip/rewind metrics, and the fixed-at-construction
        // scratch/storage capacities used to prove zero native steady-state
        // allocation across repeated cycles.
        external fun snapshotNodeOwnedAudioSourceGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE: session-scoped two-source node-owned closed-loop audio graph pipeline seam ─
        // Step-driven native session over the two-track NODE-OWNED-transport
        // diagnostic rig: each DecodedAudioPcmSourceNode (6-arg constructor)
        // owns its source AudioSpscAudioRingBuffer + AudioDecoderRingWriter
        // + RingBufferAudioSampleProvider triple by composition, and
        // GraphAudioScheduler auto-discovers BOTH providers from graph
        // topology alone (tag-dispatched constructor; no external provider
        // map, no hybrid routing) -> AudioMixBusNode
        // (multi_source_node_owned_src0 -> primary_audio_in,
        // multi_source_node_owned_src1 -> secondary_audio_in, unit gain) ->
        // ClockedAudioTransportCoordinator -> output ring -> consumer drain.
        // The native frame axis is the SHARED ACCEPTED FRAME COUNT (full
        // overlap only): the joint dispatch gate needs a full window on BOTH
        // source rings, the joint tail flush needs BOTH writers EOS with
        // identical residuals, the single EOS entry point sets both writers
        // together (no independent EOS), and the one forward seek reanchors
        // BOTH tracks at a single accepted frame cursor. Handles minted here
        // are NOT interchangeable with the external-provider-map
        // multi-source seam or any other pipeline session registry. Every
        // non-destroy call must run on the session's creating thread (native
        // fails closed with status=wrong_owner_thread otherwise). No native
        // worker threads, no MediaCodec/MediaExtractor ownership in C++, no
        // AudioTrack/AAudio/OpenSL/Oboe, no sink-clocked transport, no
        // realtime or audible playback, no file IO, no wall-clock reads.

        // Returns an opaque session handle, or 0 on invalid input (same
        // bounds as the external-provider-map multi-source seam plus
        // expectedFrameCount in [1, 10*sampleRate] — the node's own
        // 10-second timeline-window ceiling), when either source node does
        // not own its transport, when the auto-discovered two-track route
        // did not resolve exactly (routedSourceCount 2 in src0, src1 order),
        // or the 4-live-session registry cap is reached. expectedFrameCount
        // bounds each node's isActiveAt timeline window, so it must cover
        // every frame the caller will dispatch; sourceRingCapacityFrames is
        // each node's explicit ringCapacityFrames constructor argument.
        external fun createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Per-track producer side, writing through that track's NODE-OWNED
        // ring writer; trackIndex must be 0 or 1
        // (status=invalid_track_index otherwise, no mutation). Accepted
        // frames are clamped to min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestMultiSourceNodeOwnedAudioGraphPipelinePcm16(
            handle: Long,
            trackIndex: Int,
            pcmBuffer: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Starts the transport clock at (sysTimeNs, mediaPtsUs) and parks
        // the dispatch cursor awaiting the output ring's seek ack; drain the
        // ack before the first dispatching step.
        external fun startMultiSourceNodeOwnedAudioGraphPipeline(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs tick;
        // the scheduler pulls from the two auto-discovered node-owned
        // providers. flushTail=false requires a full window on BOTH source
        // rings (status=deferred_insufficient_joint_source otherwise, with
        // no mutation; no EOS term); flushTail=true requires BOTH writers
        // EOS and identical per-track residuals
        // (tail_flush_track_length_mismatch otherwise, no zero-fill) and
        // advances exactly min(avail0, avail1, maxFramesPerMix) frames
        // (tail_flush_partial_window / tail_flush_complete). Every step
        // status reports both per-track sourceAvailableReadFrames.
        external fun stepMultiSourceNodeOwnedAudioGraphPipeline(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Output-ring reader side: consumes a pending start/seek ack first,
        // then pops and checksums up to maxFrames of mixed PCM. Consumer
        // drain is the ONLY output read path in this slice (no AudioTrack
        // direct-read route).
        external fun drainMultiSourceNodeOwnedAudioGraphPipelineOutput(
            handle: Long,
            maxFrames: Int,
        ): String

        // Forward-only joint seek. Requires a fully drained output ring,
        // both node-owned source rings empty, and the shared accepted-frame
        // axis intact (track_frame_axis_divergence otherwise); reanchors
        // BOTH tracks at the same accepted frame. The caller must drain the
        // output-ring ack next.
        external fun seekMultiSourceNodeOwnedAudioGraphPipeline(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // JOINT writer-local EOS: one call sets BOTH node-owned writers EOS
        // together (cleared by the next successful seek). There is
        // deliberately no per-track EOS entry point (no independent EOS).
        external fun setMultiSourceNodeOwnedAudioGraphPipelineEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot with Track0/Track1-suffixed per-track
        // keys, the node-owned/auto-discovery evidence (routedSourceCount,
        // routedSourceId0/1, nodeOwnsRingTrack0/1), the
        // fixed-at-construction scratch/storage capacities used to prove
        // zero native steady-state allocation, and the verbatim proof
        // boundary. Never silently truncated (status=snapshot_overflow
        // fails closed instead).
        external fun snapshotMultiSourceNodeOwnedAudioGraphPipeline(
            handle: Long,
        ): String

        // Idempotent erase-once; callable from any thread. Handle 0/unknown
        // returns status=not_found.
        external fun destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: two-source node-owned pipeline with a muted native AAudio callback sink ─
        // Same two-source NODE-OWNED closed-loop graph rig as the
        // multi-source node-owned seam (two DecodedAudioPcmSourceNode
        // 6-arg-constructor nodes owning their ring/writer/provider triples,
        // GraphAudioScheduler auto-discovery, AudioMixBusNode,
        // ClockedAudioTransportCoordinator, output ring), plus a separate
        // sink AudioSpscAudioRingBuffer that feeds a MUTED native AAudio
        // data callback. AAudio is never direct-linked (minSdk 24): start
        // gates on android_get_device_api_level() >= 26, then
        // dlopen("libaaudio.so")/dlsym on the owner thread before opening,
        // failing closed with status=aaudio_unavailable /
        // status=aaudio_symbol_missing:<name>. The owner-thread pump
        // checksums the REAL mixed PCM first, then zero-scales it before it
        // enters the callback sink ring; the data callback only pops
        // already-muted PCM or zero-fills and updates atomic counters (no
        // allocation, no locks, no JNI, no stream lifecycle calls).
        // Handles minted here are NOT interchangeable with any other
        // diagnostic session registry. Every non-destroy call must run on
        // the session's creating thread, and unlike the sibling seams
        // DESTROY IS OWNER-THREAD-ONLY TOO (it performs the AAudio
        // stop/wait/close). Diagnostic sink foundation only: no product
        // playback, no audible-output claim, no audio focus/route/dead
        // object handling, no low-latency/MMAP/EXCLUSIVE, no xrun-freedom
        // or latency/glitch claim, no export/pass-2 reroute, no
        // streaming/cache, no iOS.

        // Returns an opaque session handle, or 0 on invalid input (same
        // bounds as the multi-source node-owned seam plus
        // sinkRingCapacityFrames: power of two in [64, 65536] and >=
        // maxFramesPerMix), when either source node does not own its
        // transport, when the auto-discovered two-track route did not
        // resolve exactly, or when the 4-live-session registry cap is
        // reached. Graph rig only: no AAudio touch until start.
        external fun createAaudioNodeOwnedSinkSmokeSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Int,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            sinkRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Per-track producer side, writing through that track's NODE-OWNED
        // ring writer; trackIndex must be 0 or 1. Accepted frames are
        // clamped to min(frameCount, 8192, framesThatFitInBuffer).
        external fun ingestAaudioNodeOwnedSinkPcm16(
            handle: Long,
            trackIndex: Int,
            pcmBuffer: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // At most once per session. Staged owner-thread AAudio bring-up
        // (runtime API gate, dlopen/dlsym, builder config: output/
        // sampleRate/channelCount/PCM_I16/SHARED/performance NONE/data +
        // error callback, open, actual-config verification failing closed
        // with status=aaudio_config_mismatch), then coordinator start at
        // (sysTimeNs, mediaPtsUs) parking the dispatch cursor awaiting the
        // output ring's seek ack (pump that ack next), then requestStart
        // with a bounded waitForStateChange to STARTED.
        external fun startAaudioNodeOwnedSink(
            handle: Long,
            mediaPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // One bounded dispatch attempt at the caller-derived sysTimeNs
        // tick; identical joint-gate / joint-tail-flush semantics to the
        // multi-source node-owned step seam.
        external fun stepAaudioNodeOwnedSink(
            handle: Long,
            sysTimeNs: Long,
            flushTail: Boolean,
        ): String

        // Owner-thread MUTED-SINK pump, the ONLY output-ring read path in
        // this slice: consumes a pending start/seek ack first, then pops
        // REAL mixed PCM (checksummed as nativeOutputDrainChecksumHex),
        // zero-scales it on the owner thread, and pushes the muted frames
        // into the sink ring feeding the AAudio callback. Pops are clamped
        // to sink write space so no checksummed frame is ever lost.
        // maxFrames == 0 is a legal ack-only call.
        external fun pumpAaudioNodeOwnedSink(
            handle: Long,
            maxFrames: Int,
        ): String

        // Forward-only joint seek on the shared accepted-frame axis
        // (pumped total stands in for the drained total); the sink ring is
        // not gated because it holds only already-muted zeros. The caller
        // must pump the output-ring ack next.
        external fun seekAaudioNodeOwnedSink(
            handle: Long,
            targetPtsUs: Long,
            sysTimeNs: Long,
        ): String

        // JOINT writer-local EOS: one call sets BOTH node-owned writers EOS
        // together (cleared by the next successful seek).
        external fun setAaudioNodeOwnedSinkEos(
            handle: Long,
        ): String

        // Full diagnostic snapshot: two-track node-owned evidence,
        // fixed-at-construction capacities (including the sink ring) for
        // the zero-steady-state-allocation lane, AAudio bring-up facts,
        // callback atomics (mid-run reads may trail an in-flight callback
        // burst; destroy reports the coherent finals), muted-sink evidence,
        // and the verbatim proof boundary. Never silently truncated
        // (status=snapshot_overflow fails closed instead).
        external fun snapshotAaudioNodeOwnedSink(
            handle: Long,
        ): String

        // OWNER-THREAD-ONLY destroy (fails closed with
        // status=wrong_owner_thread from any other thread): performs the
        // AAudio requestStop / bounded waitForStateChange / close on the
        // owner thread, then replies with the coherent final callback
        // counters and erases the handle once (second call / unknown handle
        // returns status=not_found).
        external fun destroyAaudioNodeOwnedSinkSmokeSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-RUNTIME-QUEUE-SCHEDULER: diagnostic async runtime queue/backpressure scheduler session seam ─
        // Session-scoped native seam whose session owns ONE native worker
        // thread: the worker is the sole caller of every AudioClock
        // mutator, every ClockedAudioTransportCoordinator control/dispatch
        // method, and the output ring's producer role. Kotlin control
        // commands (start/pause/resume/seek) only ENQUEUE into a bounded
        // TU-local command queue drained by the worker; command results
        // surface through the mutex-published snapshot mirror. The Kotlin
        // owner thread stays the source-ring producer (ingest/EOS/seek
        // request via the node-owned writer) and the output-ring consumer
        // (read/ack). Every media-time tick is caller-derived /
        // frame-axis synthetic; the worker never reads a wall clock as a
        // media timebase (std::chrono is pacing-only), never touches
        // JNIEnv, and never calls back into Kotlin. No
        // AudioTrack/AAudio/OpenSL/Oboe, no audible output, no realtime
        // claim, no product/editor/app wiring, no streaming/cache, no iOS,
        // no export route changes. Forward-only seek over quiescent rings;
        // writer-local EOS arms a bounded, honestly-reported zero-fill
        // probe lane.

        // Returns an opaque session handle, or 0 on invalid input
        // (sampleRate not in [8000, 192000], channelCount not in {1,2},
        // expectedFrameCount not in (0, 600*sampleRate], maxFramesPerMix
        // not in [1, 8192], ring capacities not powers of two in
        // [64, 65536], outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames < 2*maxFramesPerMix) or when the
        // 4-live-session registry cap is reached. The worker thread starts
        // only after the rig validated.
        external fun createAsyncRuntimeQueueSchedulerSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Long,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Enqueue-only (status=enqueued;commandSeq=N, or already_started /
        // queue_full / not_found / wrong_owner_thread / invalid_args). The
        // worker executes coordinator.start; the caller must then consume
        // the output-ring seek ack via the read entry point before the
        // worker can render its first window.
        external fun startAsyncRuntimeQueueScheduler(
            handle: Long,
            mediaPtsUs: Long,
            syntheticSysTimeNs: Long,
        ): String

        // Enqueue-only; the worker clamps the synthetic tick to its own
        // last tick (never a regression) before calling the coordinator.
        external fun pauseAsyncRuntimeQueueScheduler(
            handle: Long,
            syntheticSysTimeNs: Long,
        ): String

        external fun resumeAsyncRuntimeQueueScheduler(
            handle: Long,
            syntheticSysTimeNs: Long,
        ): String

        // Forward-only, quiescent-only seek (fail closed otherwise): needs
        // every prior command processed, no EOS, an empty source ring, a
        // drained output ring, and no pending seek handshakes. The owner
        // publishes the source writer seek request, the worker consumes
        // the source ack + calls coordinator.seek, and the caller must
        // then consume the output-ring ack via the read entry point.
        external fun seekAsyncRuntimeQueueScheduler(
            handle: Long,
            targetPtsUs: Long,
            syntheticSysTimeNs: Long,
        ): String

        // Owner-thread source-ring producer through the NODE-OWNED writer.
        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer); writer
        // backpressure (ring_full/partial_write) is a reported outcome.
        external fun ingestAsyncRuntimeQueueSchedulerPcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Writer-local EOS; also arms the worker's bounded zero-fill probe
        // lane on the deterministic frame axis (provider zero-fill is
        // reported honestly, never hidden as recovery).
        external fun setAsyncRuntimeQueueSchedulerEos(
            handle: Long,
        ): String

        // Owner-thread output-ring consumer: consumes a pending start/seek
        // ack first (reporting discarded frames), then pops mixed PCM16
        // into the direct ByteBuffer. maxFrames == 0 is a legal ack-only
        // call.
        external fun readAsyncRuntimeQueueSchedulerOutputPcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Owner-thread-only. All coordinator/provider/worker facts come
        // from the worker-published mirror; includes owner/worker thread
        // identity hashes, command enqueue/process counts,
        // ownerDispatchCalls=0, dispatch/backpressure/zero-fill counters,
        // checksums, seek-ack state, join/destroy counts, and the verbatim
        // proof boundary.
        external fun snapshotAsyncRuntimeQueueScheduler(
            handle: Long,
        ): String

        // Any-thread, idempotent erase-once destroy: sets the stop flag,
        // wakes the worker, and JOINS (never detaches) before replying
        // with the race-free final counters. Second call / unknown handle
        // returns status=not_found.
        external fun destroyAsyncRuntimeQueueSchedulerSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-REALTIME-CLOCK-PACING (sub-slice
        // X3) — android_phase4_async_runtime_queue_realtime_clock_jni.cpp.
        // Disjoint session registry/handle space from the X1/X2 scheduler
        // TU. The native worker thread OWNS the monotonic
        // std::chrono::steady_clock render/dispatch timebase: NO entry
        // point below accepts a sysTimeNs/syntheticSysTimeNs argument and
        // Kotlin must never pass a time value into a control command. ────

        // Returns a handle (>0) or 0 on any validation/allocation failure
        // (bad sample rate / channel count, expected frames out of range
        // or not window-aligned, non-power-of-two rings,
        // outputRingCapacityFrames < maxFramesPerMix,
        // sourceRingCapacityFrames <
        // outputRingCapacityFrames + 2*maxFramesPerMix) or when the
        // 4-live-session registry cap is reached. The worker thread starts
        // only after the rig validated.
        external fun createAsyncRuntimeQueueRealtimeClockSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Long,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Enqueue-only, no time argument (status=enqueued;commandSeq=N, or
        // already_started / queue_full / not_found / wrong_owner_thread).
        // The worker reads steady_clock itself and executes
        // coordinator.start(0, now); the caller must then consume the
        // output-ring seek ack via the read entry point before the worker
        // can render its first window.
        external fun startAsyncRuntimeQueueRealtimeClock(
            handle: Long,
        ): String

        // Forward-only, quiescent-only seek with no time argument (fail
        // closed otherwise): needs every prior command processed, no EOS,
        // an empty source ring, a drained output ring, no pending seek
        // handshakes, and a completed native one-second timing window. The
        // owner publishes the source writer seek request, the worker
        // consumes the source ack + calls coordinator.seek(targetPtsUs,
        // fresh steady_clock now), and the caller must then consume the
        // output-ring ack via the read entry point.
        external fun seekAsyncRuntimeQueueRealtimeClock(
            handle: Long,
            targetPtsUs: Long,
        ): String

        // Owner-thread source-ring producer through the NODE-OWNED writer.
        // Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer); writer
        // backpressure (ring_full/partial_write) is a reported outcome.
        external fun ingestAsyncRuntimeQueueRealtimeClockPcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // Writer-local EOS; the X3 driver sets it only after the exact
        // expected timeline completed, so no zero-fill window remains.
        external fun setAsyncRuntimeQueueRealtimeClockEos(
            handle: Long,
        ): String

        // Owner-thread output-ring consumer: consumes a pending start/seek
        // ack first (reporting discarded frames), then pops mixed PCM16
        // into the direct ByteBuffer. maxFrames == 0 is a legal ack-only
        // call.
        external fun readAsyncRuntimeQueueRealtimeClockOutputPcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Owner-thread-only. All coordinator/provider/worker/timing facts
        // come from the worker-published mirror; includes the native
        // one-second timing gate (nativeTimingF0/F1, elapsed,
        // realtimeElapsedOk), the render-cursor backlog bound
        // (maxRenderCursorBacklogUs, realtimeBacklogBoundOk),
        // workerNoFramesDueWaits, the structural
        // noCallerSuppliedNativeTime/workerOwnsMonotonicClock tokens,
        // ownerDispatchCalls=0, checksums, seek-ack state, join/destroy
        // counts, and the verbatim proof boundary.
        external fun snapshotAsyncRuntimeQueueRealtimeClock(
            handle: Long,
        ): String

        // Any-thread, idempotent erase-once destroy: sets the stop flag,
        // wakes the worker, and JOINS (never detaches) before replying
        // with the race-free final counters. Second call / unknown handle
        // returns status=not_found.
        external fun destroyAsyncRuntimeQueueRealtimeClockSession(
            handle: Long,
        ): String

        // ── P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK
        // (sub-slice X4) —
        // android_phase4_async_runtime_queue_multi_source_realtime_clock_jni.cpp.
        // X3's async worker-owned steady_clock render/dispatch timebase
        // composed with the TWO-SOURCE node-owned topology: two
        // DecodedAudioPcmSourceNode instances (6-arg constructor) routed
        // src0 -> primary_audio_in and src1 -> secondary_audio_in, with
        // the GraphAudioScheduler auto-discovering both providers from
        // graph topology only. Disjoint session registry/handle space from
        // every other diagnostic TU. NO entry point below accepts a
        // sysTimeNs argument: Kotlin never passes a time value into a
        // control command, and no step/dispatch entry point exists. ────────

        // Returns a handle (>0) or 0 on any validation/allocation failure
        // (bad sample rate / channel count, expected frames out of range
        // or not window-aligned, non-power-of-two rings,
        // outputRingCapacityFrames < maxFramesPerMix, either source ring
        // below outputRingCapacityFrames + 2*maxFramesPerMix, either node
        // not owning its transport, a route that did not resolve to
        // exactly [src0, src1], or any channel/sample-rate divergence
        // across the rig) or when the 4-live-session registry cap is
        // reached. The worker thread starts only after the rig validated.
        external fun createAsyncRuntimeQueueMultiSourceRealtimeClockSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Long,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // X5 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-DYNAMIC-GAIN-
        // ENVELOPE) envelope-enabled create: identical rig, validation, and
        // registry as the X4 create above, plus session-owned deterministic
        // per-track dynamic AudioGainEnvelope mix params built atomically
        // before the scheduler snapshot / worker start (additionally
        // returns 0 when the proof envelopes fail to build). All other
        // entry points are shared between both modes.
        external fun createAsyncRuntimeQueueMultiSourceRealtimeClockEnvelopeSession(
            sampleRate: Int,
            channelCount: Int,
            expectedFrameCount: Long,
            sourceRingCapacityFrames: Int,
            outputRingCapacityFrames: Int,
            maxFramesPerMix: Int,
        ): Long

        // Enqueue-only, no time argument (status=enqueued;commandSeq=N, or
        // already_started / queue_full / not_found / wrong_owner_thread).
        // The worker reads steady_clock itself and executes
        // coordinator.start(0, now); the caller must then consume the
        // output-ring seek ack via the read entry point before the worker
        // can render its first window.
        external fun startAsyncRuntimeQueueMultiSourceRealtimeClock(
            handle: Long,
        ): String

        // Forward-only, quiescent-only JOINT seek with no time argument
        // (fail closed with distinct per-track tokens otherwise): needs
        // every prior command processed, the shared accepted-frame axis
        // intact (nextDispatchFrame == accepted0 == accepted1), both
        // node-owned source rings empty with settled acks, a drained
        // output ring with a settled ack, no EOS, a completed native
        // one-second timing window, and targetFrame >= each writer's
        // cursor. The owner publishes BOTH writer seek requests; the
        // worker verifies both ring acks are pending, consumes both
        // (requiring both ack frames == target), and calls
        // coordinator.seek(targetPtsUs, fresh steady_clock now); the
        // caller must then consume the output-ring ack via read.
        external fun seekAsyncRuntimeQueueMultiSourceRealtimeClock(
            handle: Long,
            targetPtsUs: Long,
        ): String

        // X15 (P4-AUDIO-ASYNC-RUNTIME-QUEUE-PAUSE-RESUME) diagnostic
        // transport pause: enqueue-only, no time argument
        // (status=enqueued;commandSeq=N, or not_found / wrong_owner_thread /
        // not_started / pause_already_pending_or_paused / queue_full). The
        // worker samples steady_clock itself and executes
        // coordinator.pause(now); while paused it dispatches no frames and
        // publishes paused=true, dispatchCountAtPause /
        // totalFramesPushedAtPause and workerPausedWaits. Not a production
        // presentation pause; no pause/resume SLA, A/V sync, or drift
        // correction claim.
        external fun pauseAsyncRuntimeQueueMultiSourceRealtimeClock(
            handle: Long,
        ): String

        // X15 diagnostic transport resume: enqueue-only, no time argument
        // (status=enqueued;commandSeq=N, or not_found / wrong_owner_thread /
        // not_started / resume_not_paused / queue_full). The worker samples
        // steady_clock itself and executes coordinator.resume(now); the
        // clock continues from the frozen media position and the worker
        // publishes resumeCommandsProcessed, dispatchCountAtResume /
        // totalFramesPushedAtResume, lastPausedIntervalNs and
        // pausedDispatchFrozenOk. A seek while a pause is pending or in
        // effect is rejected (seek_rejected_paused).
        external fun resumeAsyncRuntimeQueueMultiSourceRealtimeClock(
            handle: Long,
        ): String

        // Owner-thread source-ring producer for ONE track through that
        // track's NODE-OWNED writer. Accepted frames are clamped to
        // min(frameCount, 8192, framesThatFitInBuffer); writer
        // backpressure (ring_full/partial_write) is a reported outcome.
        // The Kotlin pump keeps the two accepted totals in lockstep.
        external fun ingestAsyncRuntimeQueueMultiSourceRealtimeClockPcm16(
            handle: Long,
            trackIndex: Int,
            pcm: java.nio.ByteBuffer,
            frameCount: Int,
        ): String

        // JOINT writer-local EOS: sets BOTH node-owned writers together
        // (there is deliberately no per-track EOS route). The X4 driver
        // sets it only after the exact expected timeline completed, so no
        // zero-fill window remains.
        external fun setAsyncRuntimeQueueMultiSourceRealtimeClockEos(
            handle: Long,
        ): String

        // Owner-thread output-ring consumer: consumes a pending start/seek
        // ack first (reporting discarded frames), then pops mixed PCM16
        // into the direct ByteBuffer. maxFrames == 0 is a legal ack-only
        // call. Y18b: the reply additionally carries eosPublished /
        // timelineComplete / totalFramesPushed / expectedFrameCount /
        // eosDrained so a ring-fed production sink consumer can observe
        // EOS-drained natively without any owner-side pre-drain.
        external fun readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16(
            handle: Long,
            pcm: java.nio.ByteBuffer,
            maxFrames: Int,
        ): String

        // Owner-thread-only. All coordinator/provider/worker/timing facts
        // come from the worker-published mirror; includes the native
        // one-second timing gate, the render-cursor backlog bound, the
        // per-track provider poisoning counters
        // (providerFramesZeroFilledTrackN, providerUnderrunEventsTrackN,
        // providerForwardSkipFramesTrackN, providerRewindRejectsTrackN),
        // per-track accepted totals/checksums, the auto-discovery route
        // evidence (routedSourceCount, routedSourceId0/1,
        // nodeOwnsRingTrack0/1), the structural
        // noCallerSuppliedNativeTime/workerOwnsMonotonicClock tokens,
        // ownerDispatchCalls=0, and the verbatim proof boundary. Built via
        // the bounded StatusAppender; overflow fails closed with
        // status=snapshot_overflow.
        external fun snapshotAsyncRuntimeQueueMultiSourceRealtimeClock(
            handle: Long,
        ): String

        // Any-thread, idempotent erase-once destroy: sets the stop flag,
        // wakes the worker, and JOINS (never detaches) before replying
        // with the race-free final counters. Second call / unknown handle
        // returns status=not_found.
        external fun destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession(
            handle: Long,
        ): String

        // ── P6-WEBRTC-INGEST-STREAM-SOURCE-SEAM-A: diagnostic, video-only RTC ──
        // ingest seam from RealtimeVideoInputAdapter/RtcVideoFrameSink into a
        // real vanguard::sources::StreamSourceNode-backed native metadata
        // session. Native keeps a bounded metadata-only queue (width, height,
        // ptsUs, rotationDegrees, mirrored, frameIndex); it never retains a
        // jobject, AHardwareBuffer, JNI global ref, Surface, texture, SDK/
        // session handle, or network state. Proves the transport-neutral
        // WebRTC/LiveKit ingress boundary only: no real WebRTC/LiveKit SDK, no
        // network room/session, no audio, no rendering, no product/editor/app
        // wiring.

        // Returns an opaque session handle, or 0 on invalid input (blank
        // streamId, non-positive width/height, durationUs <= 0,
        // maxQueueCapacity outside [1, 32]) or when the 4-live-session
        // registry cap is reached.
        external fun createStreamSourceRtcIngestSession(
            streamId: String,
            width: Int,
            height: Int,
            durationUs: Long,
            maxQueueCapacity: Int,
        ): Long

        // Transitions IDLE/PAUSED -> STARTED (idempotent if already STARTED).
        // Unknown handle returns status=not_found.
        external fun startStreamSourceRtcIngestSession(handle: Long): String

        // Transitions STARTED -> PAUSED; idempotent no-op from IDLE/PAUSED.
        // Unknown handle returns status=not_found.
        external fun pauseStreamSourceRtcIngestSession(handle: Long): String

        // Ingests primitive video frame metadata only (no pixel buffer, no
        // jobject). Returns a status string Kotlin maps to
        // RtcVideoFrameDeliveryStatus: ACCEPTED, DROPPED_BACKPRESSURE (queue
        // at maxQueueCapacity; never advances acceptedCount/cursor),
        // DROPPED_NOT_READY (session not STARTED), UNSUPPORTED_FORMAT
        // (width/height mismatch vs. session dimensions, or invalid
        // rotationDegrees), or FAILED. Unknown handle returns
        // status=not_found.
        external fun ingestStreamSourceRtcIngestMetadata(
            handle: Long,
            width: Int,
            height: Int,
            ptsUs: Long,
            rotationDegrees: Int,
            mirrored: Boolean,
            frameIndex: Long,
        ): String

        // Drains up to maxEntries queued metadata entries FIFO, freeing queue
        // capacity for subsequent ingest calls. Unknown handle returns
        // status=not_found.
        external fun drainStreamSourceRtcIngestSession(
            handle: Long,
            maxEntries: Int,
        ): String

        // Returns session state/counters and the real StreamSourceNode's
        // identity (id, streamId, kind==kSource, type==kStreamSource) as
        // construction proof. Unknown handle returns status=not_found.
        external fun snapshotStreamSourceRtcIngestSession(handle: Long): String

        // Any-thread, idempotent erase-once destroy. Second call / unknown
        // handle returns status=not_found.
        external fun destroyStreamSourceRtcIngestSession(handle: Long): String

        // ── P6-MEDIA3-INGEST-STREAM-SOURCE-SEAM-A: diagnostic, video-only ──
        // Media3 decoded-frame ingest seam from HttpAdaptiveImageReaderBridge/
        // HttpAdaptiveFrameListener into a real
        // vanguard::sources::StreamSourceNode-backed native metadata session.
        // Native keeps a bounded metadata-only queue (width, height, ptsUs,
        // frameIndex); it never retains a jobject, AHardwareBuffer, JNI
        // global ref, Surface, texture, Media3/ExoPlayer SDK object, or
        // network state. Proves the Media3 decoded-frame ingress boundary
        // only: no ExoPlayer/MediaCodec/ImageReader ownership, no network
        // state, no audio, no rendering, no product/editor/app wiring.

        // Returns an opaque session handle, or 0 on invalid input (blank
        // streamId, non-positive width/height, durationUs <= 0,
        // maxQueueCapacity outside [1, 32]) or when the 4-live-session
        // registry cap is reached.
        external fun createStreamSourceMedia3IngestSession(
            streamId: String,
            width: Int,
            height: Int,
            durationUs: Long,
            maxQueueCapacity: Int,
        ): Long

        // Transitions IDLE/PAUSED -> STARTED (idempotent if already STARTED).
        // Unknown handle returns status=not_found.
        external fun startStreamSourceMedia3IngestSession(handle: Long): String

        // Transitions STARTED -> PAUSED; idempotent no-op from IDLE/PAUSED.
        // Unknown handle returns status=not_found.
        external fun pauseStreamSourceMedia3IngestSession(handle: Long): String

        // Ingests primitive decoded-frame metadata only (no pixel buffer, no
        // jobject). Returns a status string Kotlin maps to
        // RtcVideoFrameDeliveryStatus: ACCEPTED, DROPPED_BACKPRESSURE (queue
        // at maxQueueCapacity; never advances acceptedCount/cursor),
        // DROPPED_NOT_READY (session not STARTED), UNSUPPORTED_FORMAT
        // (width/height mismatch vs. session dimensions, or negative
        // ptsUs/frameIndex), or FAILED. Unknown handle returns
        // status=not_found.
        external fun ingestStreamSourceMedia3IngestMetadata(
            handle: Long,
            width: Int,
            height: Int,
            ptsUs: Long,
            frameIndex: Long,
        ): String

        // Drains up to maxEntries queued metadata entries FIFO, freeing queue
        // capacity for subsequent ingest calls. Unknown handle returns
        // status=not_found.
        external fun drainStreamSourceMedia3IngestSession(
            handle: Long,
            maxEntries: Int,
        ): String

        // Returns session state/counters and the real StreamSourceNode's
        // identity (id, streamId, kind==kSource, type==kStreamSource) as
        // construction proof. Unknown handle returns status=not_found.
        external fun snapshotStreamSourceMedia3IngestSession(handle: Long): String

        // Any-thread, idempotent erase-once destroy. Second call / unknown
        // handle returns status=not_found.
        external fun destroyStreamSourceMedia3IngestSession(handle: Long): String
    }

    external fun probeCapabilities(): BackendCapabilityReport

    // ── P1-GPU-BLACKLIST-NATIVE-RULE-PROOF: native GPU driver blacklist rule
    // evaluator diagnostic. Runs synthetic native lanes against locally
    // constructed rule tables via the reusable EvaluateGpuDriverBlacklist()
    // evaluator (see android_backend_probe.h). Does not read or mutate the
    // production (zero-entry) rule table beyond confirming its size.
    external fun runAndroidDagPhase1GpuBlacklistNativeSmoke(): String

    // -- P1-DAG-MULTINODE-CORE-EXEC-PLAN: bounded engine-only
    // GraphExecutionPlanner diagnostic. Runs synthetic native lanes (deep
    // chain, diamond fan-out/reconvergence, multi-sink, orphan culling,
    // missing-input fail-closed, stale-generation precedence, N>=3-source
    // fan-in, no-active-sink fail-closed, unchanged Graph cycle rejection)
    // against vanguard::graph::BuildGraphExecutionPlan() using TU-local
    // synthetic DAG nodes only. Diagnostic-only: no production timeline
    // playback, no product/editor/app/ConnectsApp wiring, no
    // SurfaceProducer production path.
    external fun runAndroidDagPhase1DagMultinodeExecutionPlanSmoke(): String

    // -- P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE: platform-neutral
    // logical DAG HardwareBufferSourceNode diagnostic. Proves construction
    // validation, identity/port shape, timeline-window semantics, and a
    // real GraphExecutionPlan source->sink pass over TU-local synthetic
    // nodes only. Diagnostic-only: no production AHardwareBuffer ownership,
    // no Camera2/MediaCodec lifecycle, no product/editor/app/ConnectsApp
    // wiring.
    external fun runAndroidDagPhase1HardwareBufferSourceNodeSmoke(): String

    // -- P2-DECODED-MEDIA-FRAME-SOURCE-NODE-A: platform-neutral
    // logical DAG DecodedMediaFrameSourceNode diagnostic. Proves construction
    // validation, identity/port shape, dimension accessors, timeline-window
    // semantics, and a real GraphExecutionPlan source->sink pass using the
    // real DecodedMediaFrameSourceNode against a TU-local diagnostic sink node.
    // Diagnostic-only: no production MediaCodec/
    // MediaExtractor lifecycle, no frame buffer ownership, no Android
    // lifecycle, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke(): String

    // -- P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE: platform-neutral
    // logical DAG PreviewSurfaceSinkNode diagnostic. Proves construction
    // validation, identity/port shape, default timeline semantics, and a
    // real GraphExecutionPlan source->sink pass wiring the real
    // HardwareBufferSourceNode's "kVideoFrame" output into this real sink's
    // "video_in" input, plus missing-input fail-closed and stale-generation
    // rejection. Diagnostic-only: no production TextureRegistry/
    // SurfaceProducer ownership, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke(): String

    // -- P6-STREAM-SOURCE-NODE-A: platform-neutral logical DAG
    // StreamSourceNode diagnostic. Proves construction validation,
    // identity/port shape, streamId/live accessors, dimension accessors,
    // timeline-window semantics, and a real GraphExecutionPlan source->sink
    // pass using the real StreamSourceNode against the real
    // PreviewSurfaceSinkNode. Diagnostic-only: no production Path A Media3/
    // ExoPlayer or Path B WebRTC/LiveKit session, no RealtimeOutputAdapter
    // egress, no decoder/frame buffer ownership, no Android lifecycle, no
    // product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase6StreamSourceNodeSmoke(): String

    // -- P3-CAMERA-FRAME-SOURCE-NODE-A: platform-neutral logical DAG
    // CameraFrameSourceNode diagnostic. Proves construction validation,
    // identity/port shape, cameraId/orientation/mirror/live accessors,
    // dimension accessors, timeline-window semantics, and a real
    // GraphExecutionPlan source->sink pass using the real
    // CameraFrameSourceNode against the real PreviewSurfaceSinkNode.
    // Diagnostic-only: no production Camera2/NDK session or hardware
    // buffer ownership, no Android lifecycle, no product/editor/app/
    // ConnectsApp wiring.
    external fun runAndroidDagPhase3CameraFrameSourceNodeSmoke(): String

    // -- P1-EXTERNAL-SURFACE-SOURCE-NODE-A: platform-neutral logical DAG
    // ExternalSurfaceSourceNode diagnostic. Proves construction validation,
    // identity/port shape, surfaceId/dimension accessors, timeline-window
    // semantics, and a real GraphExecutionPlan source->sink pass using the
    // real ExternalSurfaceSourceNode against the real
    // PreviewSurfaceSinkNode. Diagnostic-only: no production Android
    // Surface/SurfaceTexture/ANativeWindow/AHardwareBuffer/EGL/GLES/Vulkan/
    // JNI resource ownership, no Android lifecycle, no product/editor/app/
    // ConnectsApp wiring.
    external fun runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke(): String

    // -- P5-IMAGE-TEXTURE-SOURCE-NODE-A: platform-neutral logical DAG
    // ImageTextureSourceNode diagnostic. Proves construction validation,
    // identity/port shape, imageId/dimension/orientation accessors,
    // timeline-window semantics, and a real GraphExecutionPlan source->sink
    // pass using the real ImageTextureSourceNode against the real
    // PreviewSurfaceSinkNode. Diagnostic-only: no production decoded
    // pixels, GL/Vulkan texture handle/sampler, file IO, Android Bitmap/
    // ImageDecoder/NDK decoder handle ownership, no Android lifecycle, no
    // product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase5ImageTextureSourceNodeSmoke(): String

    // -- P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A: platform-neutral logical DAG
    // OfflineMediaMuxerSinkNode diagnostic. Proves construction validation,
    // identity/port shape for video-only/audio-only/audio+video track
    // combinations, hasVideo()/hasAudio() accessors, timeline-window
    // semantics, real GraphExecutionPlan source->sink and audio+video->
    // muxer passes using the real HardwareBufferSourceNode and
    // DecodedAudioPcmSourceNode against this real sink, and missing-input
    // fail-closed. Diagnostic-only: no production android.media.MediaMuxer/
    // MediaCodec/PlatformCodecAdapter ownership, no file IO, no Android
    // lifecycle, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke(): String

    // -- P5-SPATIAL-TRANSFORM-NODE-A: platform-neutral logical DAG
    // SpatialTransformNode diagnostic. Proves construction validation,
    // identity/port shape, descriptor/matrix/crop accessors,
    // point-transform math, timeline-window semantics, and a real
    // GraphExecutionPlan source->transform->sink pass wiring the real
    // ImageTextureSourceNode into this node and this node into the real
    // PreviewSurfaceSinkNode. Diagnostic-only: no production renderer/
    // shader/texture/decoder ownership, no Android lifecycle, no product/
    // editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase5SpatialTransformNodeSmoke(): String

    // -- P5-FILTER-NODE-A: platform-neutral logical DAG FilterNode
    // diagnostic. Proves construction validation, identity/port shape,
    // descriptor/colorMatrix/beauty accessors, color-matrix application
    // math, pass-through semantics, timeline-window semantics, and a real
    // GraphExecutionPlan source->filter->sink pass wiring the real
    // ImageTextureSourceNode into this node and this node into the real
    // PreviewSurfaceSinkNode. Diagnostic-only: no production renderer/
    // shader/texture/decoder ownership, no Android lifecycle, no product/
    // editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase5FilterNodeSmoke(): String

    // -- P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A: platform-neutral logical DAG
    // GraphicOverlayCompositorNode diagnostic. Proves construction
    // validation, identity/port shape, descriptor/overlay accessors,
    // overlay active-filtering/zIndex-id-sorting math, timeline-window
    // semantics, and a real GraphExecutionPlan
    // base+overlay0+overlay1->compositor->sink pass wiring three real
    // ImageTextureSourceNode instances into this node and this node into
    // the real PreviewSurfaceSinkNode. Diagnostic-only: no production
    // renderer/PNG decoder/text rasterizer/shader/texture/GPU ownership,
    // no Android lifecycle, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke(): String

    // -- P5-IMAGE-OPTIMIZER-SINK-NODE-A: platform-neutral logical DAG
    // ImageOptimizerSinkNode diagnostic. Proves construction validation,
    // identity/port shape, descriptor/target/quality/format/boolean
    // accessors, timeline-window semantics, a real GraphExecutionPlan
    // source->sink pass wiring the real ImageTextureSourceNode into this
    // real sink, and missing-input fail-closed. Diagnostic-only: no
    // production decoded pixels, Bitmap/ImageDecoder lifecycle, JPEG/PNG/
    // HEIC encoder lifecycle, output file/path/fd, GPU texture/sampler/
    // lifecycle ownership, no Android lifecycle, no product/editor/app/
    // ConnectsApp wiring.
    external fun runAndroidDagPhase5ImageOptimizerSinkNodeSmoke(): String

    // -- P1-DAG-MULTINODE-TOPOLOGY-COMPOSITION: real multi-node DAG topology
    // diagnostic. Proves BuildGraphExecutionPlan() over a real four-node
    // topology - two real HardwareBufferSourceNode instances feeding a real
    // MultiCamCompositorNode's "primary_video_in"/"secondary_video_in" ports,
    // whose "composited_video_out" output feeds a real
    // PreviewSurfaceSinkNode's "video_in" port - with no TU-local Node
    // subclasses. Runs synthetic native lanes only (node port contract,
    // wiring, dependency order, compositor/sink input-binding resolution,
    // orphan culling, missing/inactive secondary-input fail-closed,
    // stale-generation precedence). Diagnostic-only: no rendering, no
    // GPU/pixel/handle transport, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke(): String

    // -- P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT: platform-neutral,
    // non-owning GPU frame token identity/binding contract diagnostic.
    // Proves GpuFrameTokenSession publish/resolve over
    // BuildGraphExecutionPlan()'s ExecutionInputBinding values across the
    // same real four-node topology (two real HardwareBufferSourceNode
    // instances -> real MultiCamCompositorNode -> real
    // PreviewSurfaceSinkNode). Runs synthetic native lanes only (token value
    // contract, descriptor validation, plan resolution, source/compositor/
    // sink token publish and resolve, duplicate-publish fail-closed,
    // stale-generation fail-closed, no-OS-resource-ownership boundary).
    // Diagnostic-only: no OS/GPU resource ownership, no rendering, no GPU
    // transport, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase1DagMultinodeGpuFrameTokenSmoke(): String

    // -- P1-DAG-MULTINODE-EXECUTION-DISPATCHER: bounded platform-neutral
    // graph-layer execution dispatcher diagnostic. Proves
    // GraphExecutionDispatcher's fail-closed pre-checks (empty plan, stale
    // session, executionIndex/position mismatch), per-node GPU-bearing
    // input resolution and output-publish validation, non-GPU binding
    // skipping, and no-rollback mid-plan failure behavior, over the same
    // real four-node topology (two real HardwareBufferSourceNode instances
    // -> real MultiCamCompositorNode -> real PreviewSurfaceSinkNode) used by
    // the routes above. Runs synthetic native lanes only. Diagnostic-only:
    // no Node::execute, no OS/GPU resource ownership, no rendering, no GPU
    // transport, no product/editor/app/ConnectsApp wiring.
    external fun runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke(): String

    external fun runAndroidDagRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    external fun runAndroidDagRenderLoopSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
    ): String

    external fun runAndroidDagPhase3CEvalRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
    ): String

    // ── Phase 4A: MediaCodec decode → ImageReader → native DAG → Vulkan ─────
    external fun createAndroidDagPhase4ADecoderSmokeSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase4ADecoderSmokeFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase4ADecoderSmokeSession(
        sessionId: String,
    ): String

    // ── Phase 4B1A: Texture playback smoke ──────────────────────────────────
    external fun createAndroidDagPhase4B1TexturePlaybackSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase4B1TexturePlaybackFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase4B1TexturePlaybackSession(
        sessionId: String,
    ): String

    // ── Phase 4B1B: Generation-aware texture playback controls ──────────────
    external fun bumpAndroidDagPhase4B1TexturePlaybackGeneration(
        sessionId: String,
    ): String

    external fun renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    // ── Phase 5: MediaCodec encoder input surface smoke ─────────────────────
    external fun createAndroidDagPhase5EncoderSmokeSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase5EncoderSmokeFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidDagPhase5EncoderSmokeSession(
        sessionId: String,
    ): String

    // ── Vulkan-first export: native session seam (create/render/destroy) ────
    external fun createAndroidTimelineVulkanExportSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidTimelineVulkanExportFrame(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    external fun destroyAndroidTimelineVulkanExportSession(
        sessionId: String,
    ): String

    // ── Vulkan-first export: padded/cropped decoder-buffer render seam ──────
    // Renders an aspect-preserving-fit destination sub-rect
    // ([destFitX],[destFitY])-([destFitX]+[destFitWidth],[destFitY]+[destFitHeight])
    // of the [width]x[height] output geometry, sourced from the crop rect
    // ([cropLeft],[cropTop])-([cropRight],[cropBottom]) of [hardwareBuffer],
    // which may be padded larger than the clip's real decoded source extent.
    // Native cross-checks the crop against the AHardwareBuffer's own
    // imported descriptor dimensions, not just the Kotlin-supplied crop
    // rect, and validates the destination rect lies fully within
    // [width]x[height]. [rotationDegrees] must be exactly 0, 90, 180, or 270
    // -- native fails closed before importing or rendering the buffer for
    // any other value. Callers that want the full output extent (no
    // letterbox/pillarbox) pass destFitX=0, destFitY=0, destFitWidth=width,
    // destFitHeight=height.
    // [colorMatrix] (Phase 10), when non-null, must be exactly 20 raw
    // (un-normalized) finite floats -- the same 4x5 row-major
    // ColorFilter.matrix convention as AndroidTimelineVideoEncoder's GLES
    // uniform upload. Native validates the length before importing the
    // buffer and fails closed with "vulkan_color_matrix_invalid:len=N" on
    // mismatch; native normalizes the four additive offset entries (indices
    // 4, 9, 14, 19) by /255.0 exactly once. Null means identity (no filter).
    // [beautyEnabled]/[beautyIntensity] (P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A):
    // when [beautyEnabled] is true, [beautyIntensity] must be finite and in
    // [0.0, 1.0] -- native fails closed with "beauty_v2_invalid_intensity" on
    // any other value (the caller is expected to have already validated this
    // at the Kotlin layer). Native expands the intensity into the full Beauty
    // V2 ramp from the CROPPED SOURCE extent and renders through the
    // Vulkan-only production Beauty V2 chain; a render failure while
    // [beautyEnabled] is reported with reason
    // "beauty_v2_requires_vulkan:vulkan_render_failed" instead of the generic
    // "render_failed".
    external fun renderAndroidTimelineVulkanExportFrameCropped(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cropLeft: Int,
        cropTop: Int,
        cropRight: Int,
        cropBottom: Int,
        rotationDegrees: Int,
        destFitX: Int,
        destFitY: Int,
        destFitWidth: Int,
        destFitHeight: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        colorMatrix: FloatArray?,
        beautyEnabled: Boolean,
        beautyIntensity: Float,
    ): String

    // ── P5-OVERLAYS-TRANS Route-A N7: cropped solo frame + overlay render seam ──
    // Same cropped/rotated/dest-fit/colorMatrix contract as
    // renderAndroidTimelineVulkanExportFrameCropped above, plus zero or more
    // already-placed overlay layers composited on top in the same render.
    // Native owns all overlay placement math -- this call never takes a UV
    // row, scissor rect, imageView, or sampler from Kotlin; only a
    // backend-owned overlay texture handle (see
    // uploadAndroidTimelineVulkanExportOverlayTexture) and its per-overlay
    // geometry. No beauty params on this route.
    // [overlayTextureHandles] is a LongArray of [overlayCount] handles.
    // [overlayGeometry] is a DoubleArray of [overlayCount] * 7 values, 7 per
    // overlay in the caller's draw order (already sorted back-to-front by
    // zIndex/id): x, y, width, height, rotationRadians, scale, opacity, all
    // in output-canvas pixels. Both arrays are ignored (may be null or
    // empty) when [overlayCount] == 0; native fails closed with
    // "invalid_overlay_texture_handles_len" / "invalid_overlay_geometry_len"
    // on a length mismatch when [overlayCount] > 0, and with
    // "invalid_overlay_count" when [overlayCount] is negative or exceeds the
    // native-enforced per-call maximum. A per-overlay handle/descriptor/
    // placement failure fails the whole call closed with a machine-readable
    // "overlay_texture_unknown:index=N" / "invalid_overlay_texture_handle:
    // index=N" / "overlay_descriptor_invalid:index=N:reason=<err>" /
    // "overlay_placement_failed:index=N" reason; a validated-but-not-visible
    // overlay is silently skipped, not an error. "status=OK;..." additionally
    // reports overlayCount and visibleOverlayCount.
    external fun renderAndroidTimelineVulkanExportFrameCroppedWithOverlays(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cropLeft: Int,
        cropTop: Int,
        cropRight: Int,
        cropBottom: Int,
        rotationDegrees: Int,
        destFitX: Int,
        destFitY: Int,
        destFitWidth: Int,
        destFitHeight: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        colorMatrix: FloatArray?,
        overlayTextureHandles: LongArray?,
        overlayGeometry: DoubleArray?,
        overlayCount: Int,
    ): String

    // ── P5-OVERLAYS-BEAUTY-SOLO: cropped solo frame + overlay + beauty render seam ──
    // Same cropped/rotated/dest-fit/colorMatrix/overlay contract as
    // renderAndroidTimelineVulkanExportFrameCroppedWithOverlays above, PLUS
    // the beautyEnabled/beautyIntensity contract from
    // renderAndroidTimelineVulkanExportFrameCropped -- for a solo frame
    // carrying both clip-level Beauty V2 and static sticker overlays at
    // once. When [beautyEnabled] is true, [beautyIntensity] must be finite
    // and in [0.0, 1.0] -- native fails closed with
    // "beauty_v2_invalid_intensity" on any other value. Native expands the
    // intensity into the full Beauty V2 ramp from the CROPPED SOURCE extent
    // and composites the overlays on top of the beautified base frame; a
    // render failure while [beautyEnabled] is reported with reason
    // "beauty_v2_requires_vulkan:vulkan_render_failed" instead of the
    // generic "render_failed". "status=OK;..." additionally reports
    // overlayCount, visibleOverlayCount, and beauty=1/0.
    external fun renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty(
        sessionId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cropLeft: Int,
        cropTop: Int,
        cropRight: Int,
        cropBottom: Int,
        rotationDegrees: Int,
        destFitX: Int,
        destFitY: Int,
        destFitWidth: Int,
        destFitHeight: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        colorMatrix: FloatArray?,
        overlayTextureHandles: LongArray?,
        overlayGeometry: DoubleArray?,
        overlayCount: Int,
        beautyEnabled: Boolean,
        beautyIntensity: Float,
    ): String

    // ── P5-COMPOSITOR-TRANS: production transition frame render seam ────────
    // Renders ONE output frame of a compositor-owned clip overlap transition
    // from TWO decoder HardwareBuffers (outgoing "from" clip, incoming "to"
    // clip) into the existing production Vulkan export session -- the same
    // session/swapchain/activeRenderCount lifecycle as the solo routes above.
    // [transitionTypeCode] is AndroidTimelineTransitionDescriptor.Type.nativeCode
    // (hard cut / 0 is rejected: hard cuts never use this route); [progress]
    // must be finite in [0, 1]. [fromLayerGeometry] / [toLayerGeometry] are
    // IntArray(9): [cropLeft, cropTop, cropRight, cropBottom, rotationDegrees,
    // destFitX, destFitY, destFitWidth, destFitHeight], validated natively
    // exactly like the cropped solo route (crop against the imported buffer
    // descriptor, cardinal rotation, destination rect inside [width]x[height]).
    // [fromColorMatrix] / [toColorMatrix] follow the cropped route's optional
    // 20-element raw colorMatrix contract.
    // [fromBeautyEnabled]/[fromBeautyIntensity] and
    // [toBeautyEnabled]/[toBeautyIntensity] (P5-BEAUTY-V2-TRANSITION-COMP):
    // per-layer optional Beauty V2, following the cropped solo route's
    // beautyEnabled/beautyIntensity contract independently for each layer --
    // when a layer's beautyEnabled is true its beautyIntensity must be finite
    // and in [0.0, 1.0], native fails closed with "beauty_v2_invalid_intensity"
    // before either buffer is imported on any other value, and native expands
    // the intensity into the full Beauty V2 ramp using THAT layer's own
    // cropped source extent (never the output extent), independently of the
    // other layer's beauty state.
    // Native imports both buffers,
    // renders, and releases BOTH imports (closing both release fence fds) on
    // every path after import. The status string always carries a
    // machine-readable reason plus transitionType / progress / frameIndex;
    // "status=OK;..." additionally reports renderedFrames and both release
    // results.
    external fun renderAndroidTimelineVulkanExportTransitionFrame(
        sessionId: String,
        width: Int,
        height: Int,
        transitionTypeCode: Int,
        progress: Double,
        fromHardwareBuffer: HardwareBuffer,
        fromLayerGeometry: IntArray,
        fromColorMatrix: FloatArray?,
        fromBeautyEnabled: Boolean,
        fromBeautyIntensity: Float,
        toHardwareBuffer: HardwareBuffer,
        toLayerGeometry: IntArray,
        toColorMatrix: FloatArray?,
        toBeautyEnabled: Boolean,
        toBeautyIntensity: Float,
        timelinePtsUs: Long,
        frameIndex: Int,
    ): String

    // ── P5-OVERLAYS-TRANSITION-COMP-N2: transition frame + overlays render seam ──
    // Same two-source clip overlap transition contract as
    // renderAndroidTimelineVulkanExportTransitionFrame above -- same session/
    // swapchain/activeRenderCount lifecycle, the same transitionTypeCode/
    // progress/per-layer 9-int geometry/optional colorMatrix/optional
    // per-layer Beauty V2 validation -- plus zero or more already-placed
    // overlay layers composited AFTER the transition's from/to layers in the
    // SAME final render pass, via VulkanBackend's overlay-aware
    // renderTransitionFrame overload. Native owns all overlay placement math,
    // exactly like renderAndroidTimelineVulkanExportFrameCroppedWithOverlays
    // below -- this call never takes a UV row, scissor rect, imageView, or
    // sampler from Kotlin, only a backend-owned overlay texture handle (see
    // uploadAndroidTimelineVulkanExportOverlayTexture) and its per-overlay
    // geometry.
    // [overlayTextureHandles] / [overlayGeometry] / [overlayCount] follow the
    // exact same layout as the solo overlay seam
    // (renderAndroidTimelineVulkanExportFrameCroppedWithOverlays):
    // [overlayTextureHandles] is a LongArray of [overlayCount] handles;
    // [overlayGeometry] is a DoubleArray of [overlayCount] * 7 values, 7 per
    // overlay in the caller's draw order (already sorted back-to-front by
    // zIndex/id): x, y, width, height, rotationRadians, scale, opacity, all
    // in output-canvas pixels. Both arrays are ignored (may be null or
    // empty) when [overlayCount] == 0; native fails closed with
    // "invalid_overlay_texture_handles_len" / "invalid_overlay_geometry_len"
    // on a length mismatch when [overlayCount] > 0, and with
    // "invalid_overlay_count" when [overlayCount] is negative or exceeds the
    // native-enforced per-call maximum. A per-overlay handle/descriptor/
    // placement failure fails the whole call closed with a machine-readable
    // "overlay_texture_unknown:index=N" / "invalid_overlay_texture_handle:
    // index=N" / "overlay_descriptor_invalid:index=N:reason=<err>" /
    // "overlay_placement_failed:index=N" reason; a validated-but-not-visible
    // overlay is silently skipped, not an error.
    // Native imports both buffers and releases BOTH imports (closing both
    // release fence fds) on every path after import, exactly like the solo
    // transition route above. "status=OK;..." additionally reports
    // overlayCount and visibleOverlayCount alongside renderedFrames and both
    // release results.
    external fun renderAndroidTimelineVulkanExportTransitionFrameWithOverlays(
        sessionId: String,
        width: Int,
        height: Int,
        transitionTypeCode: Int,
        progress: Double,
        fromHardwareBuffer: HardwareBuffer,
        fromLayerGeometry: IntArray,
        fromColorMatrix: FloatArray?,
        fromBeautyEnabled: Boolean,
        fromBeautyIntensity: Float,
        toHardwareBuffer: HardwareBuffer,
        toLayerGeometry: IntArray,
        toColorMatrix: FloatArray?,
        toBeautyEnabled: Boolean,
        toBeautyIntensity: Float,
        timelinePtsUs: Long,
        frameIndex: Int,
        overlayTextureHandles: LongArray?,
        overlayGeometry: DoubleArray?,
        overlayCount: Int,
    ): String

    // ── P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N5: backend-owned overlay ──
    // texture store JNI bridge. Direct RGBA8888 ByteBuffer upload/release/clear
    // only -- no asset file/Bitmap decode. Upload is intended for session setup
    // before frame encoding; this sub-slice does not wire overlay draw routing
    // into any render route above.
    // [rgbaBuffer] must be a direct java.nio.ByteBuffer; native reads it from
    // byte index 0 for the buffer's own direct-buffer capacity -- position and
    // limit are ignored. Callers needing an offset must pass a sliced direct
    // buffer (e.g. rgbaBuffer.slice()) so byte index 0 of the slice is the
    // intended start. [rowStrideBytes] of 0 means tightly packed (width * 4);
    // a non-zero value less than width * 4 fails closed with
    // reason=invalid_stride, and a buffer too small to hold
    // [rowStrideBytes] * [height] bytes fails closed with
    // reason=buffer_too_small.
    external fun uploadAndroidTimelineVulkanExportOverlayTexture(
        sessionId: String,
        rgbaBuffer: java.nio.ByteBuffer,
        width: Int,
        height: Int,
        rowStrideBytes: Int,
    ): String

    external fun releaseAndroidTimelineVulkanExportOverlayTexture(
        sessionId: String,
        textureHandle: Long,
    ): String

    // Clearing an already-empty store is a legal no-op (still status=OK).
    external fun clearAndroidTimelineVulkanExportOverlayTextures(
        sessionId: String,
    ): String

    // ── Phase 1-Unit U: Android GLES backend offscreen EGL lifecycle smoke ──
    external fun runAndroidDagPhase1UGlesBackendSmoke(): String

    // ── Phase 1-Unit V: Android GLES backend window-surface attach/detach smoke ──
    external fun runAndroidDagPhase1VGlesSurfaceSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit W: Android GLES backend window-surface clear/swap presentation diagnostic ──
    external fun runAndroidDagPhase1WGlesWindowPresentSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit X: Android GLES backend window-surface shader-quad draw/swap presentation diagnostic ──
    external fun runAndroidDagPhase1XGlesShaderQuadSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit Y: Android GLES backend AHardwareBuffer RGBA import foundation smoke ──
    external fun runAndroidDagPhase1YGlesImportSmoke(
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit Z: Android GLES backend identity renderFrame textured-quad presentation smoke ──
    external fun runAndroidDagPhase1ZGlesRenderFrameSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AB: Android GLES backend diagnostic read-pixels physical smoke ──
    external fun runAndroidDagPhase1ABGlesReadPixelsSmoke(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AC: Android GLES renderFrame texture-content readback physical smoke ──
    external fun runAndroidDagPhase1ACGlesRenderFrameContentSmoke(
        surface: Surface,
        buffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AD: Android GLES renderFrame asymmetric UV mapping physical smoke ──
    external fun runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AE: Android GLES backend AHardwareBuffer acquire-fence wait/close foundation smoke ──
    external fun runAndroidDagPhase1AEGlesAcquireFenceSmoke(
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AF: Android GLES RGBX AHardwareBuffer renderFrame content readback physical smoke ──
    external fun runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AG: Android GLES AHardwareBuffer import guard fail-closed physical smoke ──
    external fun runAndroidDagPhase1AGGlesImportGuardSmoke(
        validBuffer: HardwareBuffer,
        missingUsageBuffer: HardwareBuffer,
        unsupportedFormatBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AH: Android GLES YCBCR_420_888 AHardwareBuffer import guard fail-closed physical proof ──
    external fun runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke(
        validBuffer: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof ──
    external fun runAndroidDagPhase1AIGlesExtensionCapabilitySmoke(): String

    // ── Phase 1-Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof ──
    external fun runAndroidDagPhase1AJGlesNativeFenceFdSmoke(): String

    // ── Phase 1-Unit AK: Android GLES releaseHardwareBuffer live release-fence output physical proof ──
    external fun runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical proof ──
    external fun runAndroidDagPhase1ALGlesReleaseNullFenceSmoke(
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof ──
    external fun runAndroidDagPhase1AMGlesRenderFenceChainSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof ──
    external fun runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AR: Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation physical smoke ──
    external fun runAndroidDagPhase1ARGlesExternalTextureSmoke(
        surface: Surface,
        rgbaBuffer: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AS: Android GLES two-texture compositor RGBA blend foundation smoke ──
    external fun runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        ycbcrBuffer: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AT: Android GLES mixed external/OES two-texture composition foundation physical proof ──
    external fun runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke(
        surface: Surface,
        rgbaBufferA: HardwareBuffer,
        rgbaBufferB: HardwareBuffer,
        ycbcrBufferA: HardwareBuffer,
        ycbcrBufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // ── Phase 1-Unit AV: Android GLES DAG playhead evaluation + multi-frame render smoke ──
    external fun runAndroidDagPhase1AVGlesEvalRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
    ): String

    // ── Phase 1-Unit AX: Android GLES SurfaceProducer texture DAG render smoke ──
    // Phase 1-Unit AY extends this route with a diagnostic-only frameDelayMs
    // (default 0, AX-compatible) used to hold the frame loop open long
    // enough for an active-dispose/cancellation physical proof.
    // Phase 1-Unit AZ extends this route with rotationDegrees (default 0)
    // and mirrorHorizontal (default false) render-transform arguments,
    // preserving AX/AY-compatible defaults.
    external fun runAndroidDagPhase1AXGlesTextureRenderSmoke(
        surface: Surface,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
        frameDelayMs: Int,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    // ── Phase 1-Unit BB: Android GLES SurfaceProducer texture DAG two-source composition & playhead evaluation smoke ──
    // Phase 1-Unit BC extends this route with a diagnostic-only frameDelayMs
    // (default 0, BB-compatible), matching the Unit AY pattern, used to hold
    // the frame loop open long enough for an active-dispose/cancellation
    // physical proof.
    // Phase 1-Unit BD extends this route with independent per-source
    // rotationDegrees/mirrorHorizontal render-transform arguments (default
    // 0 / false, BB/BC-compatible), matching the Unit AZ pattern.
    // Phase 1-Unit BE extends this route with independent per-source
    // sourceKindA/sourceKindB arguments ("2d" or "oes", default "2d",
    // BB/BC/BD-compatible) selecting the target permutation (2D vs OES) for
    // each source's HardwareBuffer import.
    external fun runAndroidDagPhase1BBGlesTextureCompositionDagSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDurationUs: Long,
        frameDelayMs: Int,
        rotationDegreesA: Int,
        mirrorHorizontalA: Boolean,
        rotationDegreesB: Int,
        mirrorHorizontalB: Boolean,
        sourceKindA: String,
        sourceKindB: String,
    ): String

    // ── Phase 1-Unit AW-OES: Android GLES decoded SurfaceTexture/OES DAG render foundation ──
    // Session-based route (create/render/destroy), matching the Phase 4A
    // pattern. Original Phase 1-Unit AW (ImageReader.PRIVATE +
    // AHardwareBuffer import of the decoded frame) remains DEFERRED /
    // VERIFIED_PHYSICAL_FAILURE (`ahb_import_unsupported_format`); this route
    // decodes onto a SurfaceTexture bound to a native-allocated
    // GL_TEXTURE_EXTERNAL_OES texture instead and never imports an
    // AHardwareBuffer.
    external fun createAndroidDagPhase1AWOESSession(
        surface: Surface,
        width: Int,
        height: Int,
    ): String

    external fun renderAndroidDagPhase1AWOESFrame(
        sessionId: String,
        surfaceTexture: SurfaceTexture,
        presentationTimeUs: Long,
        frameIndex: Int,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase1AWOESSession(
        sessionId: String,
    ): String

    // ── P2-CONCURRENT-DEC: Multi-stream concurrent hardware decode ingest ───
    // validation diagnostic. Additive-only: validates sourceNodeId admission and
    // imports/releases an AHardwareBuffer within one JNI call per ingest, with no
    // cross-call buffer retention and no PiP/compositor presentation.
    external fun createAndroidDagPhase2ConcurrentDecodeSession(
        sourceNodeIds: Array<String>,
    ): String

    external fun ingestAndroidDagPhase2ConcurrentDecodeFrame(
        sessionId: String,
        sourceNodeId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timelinePtsUs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase2ConcurrentDecodeSession(
        sessionId: String,
    ): String

    // ── P2-CPP-PASSTHROUGH: PassthroughRemuxSinkNode native foundation ──────
    // validation. Additive-only: validates DAG topology/timeline correctness
    // for a passthrough remux sink ahead of any production remux work. Kotlin
    // remains the sole owner of MediaExtractor/MediaMuxer; native never
    // touches media file IO here.
    external fun createAndroidDagPhase2PassthroughRemuxSinkSession(
        sourceNodeId: String,
        sinkNodeId: String,
        startPtsUs: Long,
        durationUs: Long,
        requiresAudio: Boolean,
    ): String

    external fun validateAndroidDagPhase2PassthroughRemuxSinkSession(
        sessionId: String,
        timelinePtsUs: Long,
        connectVideo: Boolean,
        connectAudio: Boolean,
        processingNodeCount: Int,
    ): String

    external fun destroyAndroidDagPhase2PassthroughRemuxSinkSession(
        sessionId: String,
    ): String

    // ── P2-AUDIO-DEC-BRIDGE: bounded native decoded-PCM audio source bridge ─
    // foundation. Kotlin remains the sole owner of MediaExtractor/MediaCodec
    // OS audio decoding; native only receives already-decoded 16-bit
    // interleaved PCM chunks over a direct java.nio.ByteBuffer and
    // validates/accumulates them as a DAG audio source boundary for future
    // native C++ audio nodes. No file IO, no production mixdown/export route
    // changes.
    external fun createAndroidDagPhase2AudioDecodeBridgeSession(
        sourceNodeId: String,
        sampleRate: Int,
        channelCount: Int,
        expectedFrameCount: Int,
        timelineStartPtsUs: Long,
    ): String

    external fun ingestAndroidDagPhase2AudioDecodeBridgePcm(
        sessionId: String,
        pcm16Buffer: java.nio.ByteBuffer,
        frameCount: Int,
        bufferPtsUs: Long,
        isEndOfStream: Boolean,
    ): String

    external fun validateAndroidDagPhase2AudioDecodeBridgeSession(
        sessionId: String,
    ): String

    external fun destroyAndroidDagPhase2AudioDecodeBridgeSession(
        sessionId: String,
    ): String

    // ── P4-AUDIO-MIXBUS: bounded native PCM16 mix-bus foundation diagnostic ──
    // AudioMixBusNode is platform-neutral C++: no JNI/Android/thread/file IO
    // inside the node itself. Native only mixes already-decoded interleaved
    // PCM16 tracks handed across direct java.nio.ByteBuffers; Kotlin remains
    // the sole owner of MediaExtractor/MediaCodec/AudioTrack. No decoder, no
    // AAC, no export/mixdown route, no realtime playback wiring here.
    external fun createAndroidDagPhase4AudioMixBusSession(
        nodeId: String,
        sampleRate: Int,
        channelCount: Int,
        maxFramesPerMix: Int,
    ): String

    external fun addAndroidDagPhase4AudioMixBusTrack(
        sessionId: String,
        pcm16Buffer: java.nio.ByteBuffer,
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int,
        gain: Double,
    ): String

    external fun mixAndroidDagPhase4AudioMixBusSession(
        sessionId: String,
        framesToMix: Int,
        outBuffer: java.nio.ByteBuffer,
    ): String

    external fun destroyAndroidDagPhase4AudioMixBusSession(
        sessionId: String,
    ): String

    // ── P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION / P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE: N-source True-DAG audio graph export session ─
    // Parameterized native graph export session: one C++ Graph with one
    // AudioMixBusNode ("graph_export_mix") plus up to 8
    // DecodedAudioPcmSourceNode tracks (6-arg node-owned ring/writer/provider
    // constructor, timelineStartPtsUs=0, expectedFrameCount=totalFrames so
    // providers run in lockstep), routed by the auto-discovery
    // GraphAudioScheduler at prepare() over the session-owned mix-params
    // map. The native graph owns per-frame gain/envelope evaluation
    // (AudioGainEnvelope inside AudioMixBusNode) for tracks added via
    // addAndroidDagPhase4AudioGraphExportTrackWithEnvelope; the legacy
    // addAndroidDagPhase4AudioGraphExportTrack verb stays byte-compatible
    // for diagnostics (unit gain, null envelope). Windows render
    // synchronously and contiguously (startFrame must equal the session
    // cursor; no skips/retries/reorders) and any provider zero-fill underrun
    // fails the window closed (source_underrun:<trackId>) — zero-filled
    // audio is corruption for an export session. Non-claims: no byte
    // identity with the prior Kotlin pre-scaling route, no performance
    // claim, no runtime/realtime sink, no AudioTrack/AAudio/OpenSL/Oboe, no
    // MediaCodec/MediaExtractor, no file IO, no native worker threads, no
    // app/editor/product, no streaming/cache, no iOS.

    // Returns status=PASS;sessionId=<id>;proofBoundary=<boundary> or
    // status=FAIL;reason=<token>. sampleRate must be in [8000, 192000],
    // channelCount in 1..2, maxFramesPerMix in 1..8192.
    external fun createAndroidDagPhase4AudioGraphExportSession(
        sampleRate: Int,
        channelCount: Int,
        maxFramesPerMix: Int,
    ): String

    // Legacy diagnostic add verb (byte-compatible): static unit gain, null
    // envelope. Rejected after prepare (session_already_prepared); a 9th
    // track rejects with total_track_count_exceeded:<n>. totalFrames must be
    // in [1, sampleRate * 600] (DecodedAudioPcmSourceNode
    // kMaxExpectedSeconds).
    external fun addAndroidDagPhase4AudioGraphExportTrack(
        sessionId: String,
        trackId: String,
        totalFrames: Long,
    ): String

    // P4-AUDIO-PASS2-NATIVE-GAIN-ENVELOPE production add verb: one atomic
    // call that builds the native AudioGainEnvelope (AudioGainEnvelope::
    // ForTrack over the raw spec params; Kotlin only converts seconds to
    // integer microseconds) BEFORE any graph mutation, then adds/connects
    // the node and registers track + envelope + scheduler mix params
    // together. All times are absolute output-timeline microseconds.
    // keyframeTimesUs/keyframeGains must both be null (static volume/fade
    // path) or both present with identical lengths
    // (envelope_keyframe_array_mismatch otherwise; more than 510 keyframes
    // rejects with envelope_keyframe_count_exceeded:<n>). Envelope build
    // failures reject with envelope_build_<token> and non-finite inputs stay
    // fail-closed. A built keyframe gain outside [0,1] (e.g. negative or
    // above-unity static volume) is rebuilt clamped with exact 0.0/1.0
    // crossing keyframes (envelope_clamp_keyframe_overflow when that cannot
    // fit) and reported via gainClamped=true. Any failure leaves the graph,
    // tracks, envelopes and mix params unmutated. PASS reports
    // gainClamped=<true|false>;envelopeKeyframeCount=<n> in addition to the
    // legacy add fields.
    external fun addAndroidDagPhase4AudioGraphExportTrackWithEnvelope(
        sessionId: String,
        trackId: String,
        totalFrames: Long,
        volume: Double,
        mixGain: Double,
        fadeInUs: Long,
        fadeOutUs: Long,
        trackStartUs: Long,
        trackEndUs: Long,
        keyframeTimesUs: LongArray?,
        keyframeGains: DoubleArray?,
    ): String

    // One-way prepare barrier: freezes topology and constructs the
    // auto-discovery GraphAudioScheduler; fails closed unless every added
    // track routed (routed_source_count_mismatch:<routed>/<requested>).
    external fun prepareAndroidDagPhase4AudioGraphExportSession(
        sessionId: String,
    ): String

    // Allowed only after prepare (session_not_prepared before). Pushes
    // interleaved little-endian signed PCM16 from a direct ByteBuffer at
    // byte offset 0 through the node-owned ring writer; only a full write
    // is accepted (ring_write_<token> + acceptedFrames otherwise).
    external fun ingestAndroidDagPhase4AudioGraphExportTrackPcm(
        sessionId: String,
        trackId: String,
        pcmBuffer: java.nio.ByteBuffer,
        frameCount: Int,
    ): String

    // Contiguous export windows only: startFrame must equal the session
    // cursor (non_contiguous_window:<expected>/<got> otherwise). Scheduler
    // kOk/kSilence are the only PASS results; provider underrun fails
    // closed with source_underrun:<trackId>. frameCount must be in
    // [1, maxFramesPerMix]; outPcmBuffer must be direct with capacity
    // >= frameCount * channelCount * 2 bytes. Every PASS also appends the
    // scheduler envelope telemetry: envelopeApplied, envelopeEvaluations,
    // minEffectiveGain, maxEffectiveGain.
    external fun renderAndroidDagPhase4AudioGraphExportWindow(
        sessionId: String,
        startFrame: Long,
        frameCount: Int,
        outPcmBuffer: java.nio.ByteBuffer,
    ): String

    // Idempotent erase-once; repeated destroy also reports status=PASS.
    external fun destroyAndroidDagPhase4AudioGraphExportSession(
        sessionId: String,
    ): String

    // ── P4-AUDIO-GRAPH-TOPOLOGY: native AudioMixBusNode DAG topology & gated mix ─
    // diagnostic. Pure in-memory C++ graph topology + playhead evaluation gating +
    // synthetic PCM mix micro-proof. Stack-scoped, single-threaded, synchronous.
    // No threads, AudioTrack, AAudio, Oboe, MediaCodec, MediaExtractor, files,
    // Surface, GL, export/muxer, editor playback, or product UI.
    external fun runAndroidDagPhase4AudioGraphTopologySmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK: synchronous graph-edge-routed audio window scheduler proof ─
    // Pure in-memory C++ graph edge routing, exact frame window math, PTS derivation,
    // microsecond drift prevention, timeline gating, mixed PCM checksum verification,
    // silence windows, stale generation rejection, sample rate mismatch rejection,
    // and capacity guard micro-proof. Stack-scoped, single-threaded, synchronous.
    // No AudioTrack, AAudio, Oboe, realtime or audible playback, queues, backpressure,
    // threads, files, MediaCodec, MediaExtractor, export reroute, editor playback,
    // product UI, streaming, or iOS.
    external fun runAndroidDagPhase4AudioGraphTransportClockSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: native SPSC audio ring-buffer transport primitive + diagnostic provider adapter ─
    // SPSC primitive + diagnostic provider only; no realtime/audible playback,
    // no AudioTrack/AAudio/OpenSL/Oboe, no realtime clock ownership,
    // no production decoder writer, no MediaCodec/MediaExtractor,
    // no C++->Kotlin callback, no export reroute, no streaming/cache,
    // no app/editor/product UI, no iOS, does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK
    // or P4-AUDIO-MIXBUS.
    external fun runAndroidDagPhase4AudioRingBufferTransportSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: platform-neutral native AudioClock diagnostic ─
    // Caller-clocked, lock-free monotonic media-position tracker + drift-telemetry native proof.
    // Pure in-memory C++ lock-free monotonic timebase; no AudioTrack/AAudio/OpenSL/Oboe,
    // no audible playback, no production decoder writer, no export reroute, no streaming,
    // no iOS, no product/editor UI, no internal wall-clock read.
    external fun runAndroidDagPhase4AudioClockSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: native ClockedAudioTransportCoordinator diagnostic ─
    // Caller-clocked, clock-driven audio transport coordinator native proof.
    // Pure in-memory C++ proof; no AudioTrack/AAudio/OpenSL/Oboe, no OS callbacks,
    // no production decoder writer, no export reroute, no streaming, no iOS,
    // no product/editor UI, no internal wall-clock read, no threads, no locks,
    // no float timebase, no resample, no speed change, no source provider ring seek,
    // output ring only, unity speed only.
    external fun runAndroidDagPhase4AudioTransportCoordinatorSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: native decoder-to-source-ring ingest seam diagnostic ─
    // Standalone producer-side AudioDecoderRingWriter proof: pushes PCM16 into an
    // AudioSpscAudioRingBuffer via tryPushFrames()/requestSeek() only. Pure in-memory
    // C++ proof; no MediaCodec/MediaExtractor/AudioTrack/AAudio/OpenSL/Oboe, no
    // realtime or audible playback, no OS callbacks, no threads, no locks, no file IO,
    // no export reroute, no streaming, no iOS, no product/editor UI, no
    // DecodedAudioPcmSourceNode wiring, no scheduler integration, no resample.
    // Writer-local EOS only.
    external fun runAndroidDagPhase4AudioDecoderRingWriterSmoke(): String

    // ── P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: closed-loop ingest-to-transport audio graph pipeline integration diagnostic ─
    // AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer(s) ->
    // RingBufferAudioSampleProvider(s) -> GraphAudioScheduler -> AudioMixBusNode ->
    // ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer -> consumer
    // drain, all inside one single-threaded native call. Pure in-memory C++ proof;
    // no MediaCodec/MediaExtractor/AudioTrack/AAudio/OpenSL/Oboe, no realtime or
    // audible playback, no OS callbacks, no threads, no locks, no file IO, no
    // wall-clock read (caller-supplied sysTimeNs only), no resample, no speed change,
    // no export or pass-2 graph reroute, no streaming/cache, no iOS, no
    // product/editor UI. DecodedAudioPcmSourceNode is a topology anchor only (no PCM
    // ingest/retention). Writer-local EOS only.
    external fun runAndroidDagPhase4AudioPipelineIntegrationSmoke(): String

    // ── P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: native AudioMixBusNode timeline-aware per-frame volume envelope diagnostic ─
    // One-shot, stack-scoped, single-threaded, synchronous native proof that
    // the C++ AudioGainEnvelope is a parity port of the Kotlin
    // AndroidAudioVolumeEnvelope rules (normalize / static fade / forTrack
    // fallback / evaluate; linear interpolation only) and that
    // AudioMixBusNode owns per-frame effective-gain math (static gain *
    // envelope gain, single quantization, integer-microsecond floor PTS
    // derivation, fail-before-output envelope validation) while the caller
    // owns the window origin. Honest boundary: no GraphAudioScheduler
    // wiring, no production mixdown change, no export/pass-2 reroute, no
    // runtime queue, no backpressure, no realtime sink, no threads, no
    // AudioTrack/AAudio, no MediaCodec/MediaExtractor, no file IO, no
    // streaming/cache, no iOS, no product/editor UI.
    external fun runAudioMixBusTimelineNativeSmoke(): String

    // ── P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: GraphAudioScheduler per-source gain/envelope wiring diagnostic ─
    // One-shot, stack-scoped, single-threaded, synchronous native proof that
    // GraphAudioScheduler resolves an optional non-owning per-source
    // SourceMixParams map (static gain + AudioGainEnvelope pointer, keyed by
    // source node id) once at construction, populates every
    // AudioMixBusNode::MixTrack with that gain/envelope plus the
    // scheduler-owned window origin (envelopeStartPtsUs = windowPtsUs), and
    // propagates the mix-bus envelope metrics into SchedulerOutput; no
    // params entry stays bit-identical to the prior unit-gain scheduler
    // output, and a window pts that cannot fit positive int64 fails closed.
    // Honest boundary: diagnostic only — no production mixdown change, no
    // export/pass-2 reroute, no runtime queue, no backpressure, no realtime
    // sink, no AudioTrack/AAudio/OpenSL/Oboe, no MediaCodec/MediaExtractor,
    // no file IO, no native worker threads, no app/editor/product, no
    // streaming/cache, no iOS.
    external fun runAndroidDagPhase4AudioSchedulerEnvelopeSmoke(): String

    // ── P3-CAM-CONCURRENT: Camera2 dual-camera concurrent PRIVATE AHardwareBuffer ─
    // ingest validation diagnostic. Kotlin remains the sole owner of Camera2
    // device/session lifecycle (CameraManager.openCamera, CameraCaptureSession);
    // native only validates cameraSourceNodeId admission and imports/releases an
    // AHardwareBuffer within one JNI call per ingest, with no cross-call buffer
    // retention, no Camera2 ownership in C++, and no compositor/PiP/split/
    // recording/export claim. Mirrors the P2-CONCURRENT-DEC registry pattern with
    // P3 camera-specific naming.
    external fun createAndroidDagPhase3CameraConcurrentIngestSession(
        cameraSourceNodeIds: Array<String>,
    ): String

    external fun ingestAndroidDagPhase3CameraConcurrentFrame(
        sessionId: String,
        cameraSourceNodeId: String,
        hardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        cameraTimestampNs: Long,
        frameIndex: Int,
        generationId: Long,
        rotationDegrees: Int,
        mirrorHorizontal: Boolean,
    ): String

    external fun destroyAndroidDagPhase3CameraConcurrentIngestSession(
        sessionId: String,
    ): String

    // ── P3-MULTICAM-NODE: MultiCamCompositorNode native topology + PiP/split ──
    // layout-math foundation diagnostic. Pure in-memory C++ math only: builds
    // MultiCamCompositorNode instances and calls the free ComputeMultiCamLayout()
    // function with synthetic inputs. No threads, no Camera2, no GLES/Vulkan,
    // no file IO, no recording/export claim.
    external fun runAndroidDagPhase3MultiCamCompositorSmoke(): String

    // -- P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-BRIDGE: Dart layout-map --
    // to native MultiCamLayout translation diagnostic. Consumes the primitive
    // fields already parsed out of a Dart VGLivePreviewConfig/
    // VGDualCameraDescriptor layout map (layoutMode, pipLayout.anchor/
    // centerX/centerY/widthFraction/aspectRatio/marginFraction/cornerRadius/
    // opacity, splitLayout.direction/splitRatio), maps each string field to
    // the matching native MultiCam* enum (unknown layoutMode -> PiP, unknown
    // anchor -> bottomRight, unknown split direction -> topBottom), builds a
    // MultiCamLayout, and calls the already-verified
    // MultiCamCompositorNode::computeLayout(). Diagnostic only: proves Dart
    // layout-map consumption into native layout math. No camera open, no
    // concurrent capture, no render, no OES, no recording/export, no
    // product/editor UI, no iOS.
    external fun runAndroidDagPhase3MultiCamDescriptorBridgeSmoke(
        layoutMode: String,
        pipAnchor: String,
        pipCenterX: Double,
        pipCenterY: Double,
        pipWidthFraction: Double,
        pipAspectRatio: Double,
        pipMarginFraction: Double,
        pipCornerRadius: Double,
        pipOpacity: Double,
        splitDirection: String,
        splitRatio: Double,
    ): String

    // ── P3-MULTICAM-NODE: GLES-first spatial multi-texture diagnostic render ──
    // pass physical proof. Render-only: draws two already-imported textures
    // into two independent glViewport-scoped pixel rectangles derived from
    // vanguard::compositors::ComputeMultiCamLayout() (PiP/split layout math),
    // via GlesBackend::diagnosticRenderMultiCamSpatialCompositeForReadback()/
    // diagnosticPresentMultiCamSpatialComposite(). Native fills bufferA solid
    // opaque red and bufferB solid opaque blue; the caller allocates both
    // buffers uninitialized. No camera open, no Vulkan, no OES physical
    // proof, no recording/export, no product UI.
    external fun runAndroidDagPhase3MultiCamSpatialGlesRenderSmoke(
        surface: Surface,
        bufferA: HardwareBuffer,
        bufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // -- P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: bounded OES extension of --
    // the RGBA-only spatial route above. Native fills rgbaBufferA solid
    // opaque red and rgbaBufferB solid opaque blue (caller allocates both
    // uninitialized); ycbcrBufferA/ycbcrBufferB are never CPU-filled and are
    // imported as GL_TEXTURE_EXTERNAL_OES (0x8D65). Exercises 2D+OES,
    // OES+2D, and OES+OES spatial composite lane permutations via the same
    // GlesBackend diagnostic readback/present seams; OES lanes assert
    // render/readback success and resolved texture target only, never
    // deterministic color content. No camera open, no Vulkan, no
    // recording/export, no product UI.
    external fun runAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
        surface: Surface,
        rgbaBufferA: HardwareBuffer,
        rgbaBufferB: HardwareBuffer,
        ycbcrBufferA: HardwareBuffer,
        ycbcrBufferB: HardwareBuffer,
        width: Int,
        height: Int,
    ): String

    // -- P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: combines the --
    // Dart-descriptor-bridge parsing pattern above with the OES spatial
    // render route above it. Native is the sole layout authority: it maps
    // layoutMode/pipAnchor/splitDirection strictly to the matching
    // MultiCam* enum (unrecognized values FAIL CLOSED before any
    // AHardwareBuffer import or GLES work -- no default fallback, unlike
    // runAndroidDagPhase3MultiCamDescriptorBridgeSmoke above), builds a
    // MultiCamLayout (cornerRadiusFractionOfCanvasWidth/opacity hard-set to
    // 0.0/1.0; this route accepts no cornerRadius/opacity parameter at
    // all), calls the already-verified ComputeMultiCamLayout(), converts
    // both normalized rects to GLES pixel viewport rects, then renders:
    // layoutMode "pip" draws rgbaBufferA (deterministic solid red) as
    // primary and ycbcrBufferB (never CPU-filled) as OES secondary;
    // "splitScreen" draws ycbcrBufferA as OES primary and rgbaBufferB
    // (deterministic solid blue) as secondary. Readback sample points are
    // derived from the computed pixel rects, never hardcoded. No camera
    // open, no Vulkan, no recording/export, no product UI.
    external fun runAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
        surface: Surface,
        rgbaBufferA: HardwareBuffer,
        rgbaBufferB: HardwareBuffer,
        ycbcrBufferA: HardwareBuffer,
        ycbcrBufferB: HardwareBuffer,
        width: Int,
        height: Int,
        layoutMode: String,
        pipAnchor: String,
        pipCenterX: Double,
        pipCenterY: Double,
        pipWidthFraction: Double,
        pipAspectRatio: Double,
        pipMarginFraction: Double,
        splitDirection: String,
        splitRatio: Double,
    ): String

    // -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER: one --
    // real Camera2 ImageReader(YUV_420_888) buffer-queue frame (imported as
    // GL_TEXTURE_EXTERNAL_OES, always the primary) plus one synthetic
    // RGBA_8888 HardwareBuffer (native-filled solid opaque blue, imported as
    // GL_TEXTURE_2D, always the secondary), laid out by the same
    // layoutMode/pipAnchor/splitDirection strict-resolution + already-
    // verified ComputeMultiCamLayout() pipeline as the dynamic-descriptor
    // route above, rendered/read-back/presented via the same GlesBackend
    // spatial compositor seams. Unlike that route, primary/secondary texture
    // assignment never depends on layoutMode. Camera-side readback
    // assertions are structural only (resolved OES target, render/readback
    // success) -- never hue/luma/content, since the real camera frame's
    // pixel content is unconstrained; the synthetic secondary additionally
    // asserts deterministic solid blue. No concurrent/dual camera, no
    // Vulkan, no recording/export, no product UI.
    external fun runAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
        surface: Surface,
        cameraYuvBuffer: HardwareBuffer,
        syntheticRgbaBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        layoutMode: String,
        pipAnchor: String,
        pipCenterX: Double,
        pipCenterY: Double,
        pipWidthFraction: Double,
        pipAspectRatio: Double,
        pipMarginFraction: Double,
        splitDirection: String,
        splitRatio: Double,
    ): String

    // ── P3-MULTICAM-NODE (SPATIAL-VULKAN-RENDER): VulkanMultiCamSpatialCompositor ──
    // two-texture spatial layout raster + readback proof diagnostic. Native
    // creates its own temporary VkInstance/VkDevice/VkQueue/VkCommandPool,
    // synthetic solid red (primary) and solid blue (secondary) RGBA8 sampled
    // images, a 64x64 offscreen color attachment and a host-visible readback
    // buffer on the calling thread, evaluates ComputeMultiCamLayout() for
    // top/bottom split, left/right split, PiP top-left and PiP free-floating,
    // renders each through the private Vulkan spatial helper (existing AOT
    // passthrough SPIR-V, opaque paint-over via dynamic viewport/scissor),
    // gates every readback pixel (blue secondary rect, red primary rect,
    // green clear sentinel elsewhere), and destroys everything before
    // returning a JSON object string. Reports status "UNSUPPORTED" (never
    // crashes) when no usable Vulkan device exists. No GLES, no camera open,
    // no OES/AHardwareBuffer import, no opacity, no corner radius, no
    // recording/export, no production VulkanBackend mutation, no product UI.
    external fun runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke(): String

    // -- P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: proves --
    // that a caller-supplied Dart layout descriptor's primitive fields drive
    // native Vulkan spatial rendering via ComputeMultiCamLayout(), combining
    // the strict layoutMode/pipAnchor/splitDirection descriptor-string
    // resolution policy from the GLES dynamic-descriptor route above with
    // the static Vulkan two-texture spatial route above it. Synchronous,
    // single JSON result per call, exactly like
    // runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke: native creates
    // its own temporary VkInstance/VkDevice/VkQueue/VkCommandPool and
    // synthetic solid red/blue RGBA8 sampled images for this one call, then
    // strictly resolves layoutMode/pipAnchor/splitDirection (an unrecognized
    // value is rejected before any Vulkan object is created), builds a
    // MultiCamLayout from the caller's primitives
    // (cornerRadiusFractionOfCanvasWidth/opacity hard-set to 0.0/1.0; this
    // route accepts no cornerRadius/opacity parameter at all), evaluates the
    // already-verified ComputeMultiCamLayout(), converts both viewports to
    // Vulkan pixel rects, and renders (red primary, blue secondary) before
    // destroying everything and returning. Reports status "UNSUPPORTED"
    // (never crashes) when no usable Vulkan device exists. No GLES, no
    // camera open, no OES/AHardwareBuffer import, no opacity, no corner
    // radius, no recording/export, no production VulkanBackend mutation, no
    // product UI.
    external fun runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
        layoutMode: String,
        pipAnchor: String,
        pipCenterX: Double,
        pipCenterY: Double,
        pipWidthFraction: Double,
        pipAspectRatio: Double,
        pipMarginFraction: Double,
        splitDirection: String,
        splitRatio: Double,
    ): String

    // -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER: proves --
    // that one real Camera2 ImageReader(YUV_420_888) buffer-queue frame is
    // held open, imported/sampled through Vulkan (samplerYcbcrConversion for
    // the external-format camera buffer, always the primary), combined with
    // a synthetic solid-blue Vulkan scratch image (never an AHardwareBuffer,
    // always the secondary) via the same layoutMode/pipAnchor/splitDirection
    // strict descriptor-string resolution and already-verified
    // ComputeMultiCamLayout() pipeline as the routes above, rendered/read
    // back via the same VulkanMultiCamSpatialCompositor as the static/
    // dynamic-descriptor Vulkan routes above it. Native creates and destroys
    // its own temporary VkInstance/VkDevice/VkQueue/VkCommandPool for this
    // one call. An unrecognized layoutMode/pipAnchor/splitDirection value is
    // rejected before any Vulkan object is created -- the camera frame is
    // still fully captured by Kotlin first. Camera-side readback assertions
    // are structural only (import succeeded, image/view/sampler non-null,
    // render/readback success, a structural alpha probe) -- never hue/luma/
    // content, since the real camera frame's pixel content is unconstrained;
    // the synthetic secondary additionally asserts deterministic solid blue.
    // Reports status "UNSUPPORTED" (never crashes) when no usable Vulkan/AHB-
    // capable device exists. No GLES/OES, no concurrent/dual camera, no
    // recording/export, no production VulkanBackend mutation, no product UI.
    external fun runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
        cameraYuvBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        layoutMode: String,
        pipAnchor: String,
        pipCenterX: Double,
        pipCenterY: Double,
        pipWidthFraction: Double,
        pipAspectRatio: Double,
        pipMarginFraction: Double,
        splitDirection: String,
        splitRatio: Double,
    ): String

    // ── P5-COMPOSITOR-TRANS (NODE-TOPOLOGY-MATH): VGTimelineCompositorNode ──
    // native topology + timeline clip overlap / transition progress math
    // foundation diagnostic. Pure in-memory C++ math only: builds
    // VGTimelineCompositorNode instances with synthetic clip/transition
    // descriptors and gates EvaluateTimelineComposition() results. Returns a
    // JSON object string. No threads, no MediaCodec, no GLES/Vulkan, no file
    // IO, no export/render claim.
    external fun runAndroidDagPhase5TimelineCompositorSmoke(): String

    // ── P5-COMPOSITOR-TRANS (GLES-RENDER): GlesTimelineTransitionCompositor ──
    // shader/raster proof diagnostic. Native creates its own temporary EGL
    // pbuffer context and synthetic GL_TEXTURE_2D solid-color/quadrant
    // textures on the calling thread, evaluates ComputeTransitionGeometry()
    // for crossfade / slide / wipe / none families, draws each through the
    // private GLES transition helper, reads pixels back, and tears everything
    // down before returning a JSON object string. Must be called from a
    // thread with no EGL context current (the smoke coordinator's executor).
    // No Vulkan, no MediaCodec/decode, no SurfaceTexture/OES frame proof,
    // no export session, no product UI.
    external fun runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(): String

    // ── P5-OVERLAYS-TRANS (GLES-RENDER): GlesOverlayCompositor multi-layer ──
    // overlay shader/raster proof diagnostic. Native creates its own temporary
    // 64x64 EGL pbuffer context and synthetic GL_TEXTURE_2D solid/quadrant/
    // half-alpha textures on the calling thread, hand-builds already-resolved
    // GlesOverlayLayerDescriptor lists (mirroring Dart
    // VGOverlayEvaluatedTransform raster fields), draws each lane through the
    // private GLES overlay helper (mat3 uTransform, float uOpacity,
    // Porter-Duff source-over), reads pixels back, verifies GL_BLEND /
    // viewport / binding restoration, and tears everything down before
    // returning a JSON object string. Must be called from a thread with no
    // EGL context current (the smoke coordinator's executor). No Vulkan, no
    // MediaCodec/decode, no SurfaceTexture/OES frame proof, no keyframe math,
    // no export session, no product UI.
    external fun runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(): String

    // ── P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only seam proving a REAL
    // MediaCodec decode -> SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES frame can
    // still route into the exact same private GlesOverlayCompositor helper
    // exercised by the synthetic-pbuffer diagnostic above. Creates/destroys no
    // EGL context and no caller texture: the caller
    // (AndroidGlesExportOverlaySeamSmokeHarness) must already have its own EGL
    // context current on the calling thread -- with a real decoded OES frame
    // already drawn into it -- before invoking this. Validates
    // dimensions/count/array lengths itself, then forwards already-resolved
    // GlesOverlayLayerDescriptor fields (7 doubles per layer, in order: x, y,
    // width, height, rotation, scale, opacity) to the private helper.
    // overlayCount == 0 is a legal no-op draw (every array argument may then
    // be null). Returns a JSON object string with at least status/pass/
    // failureReason/overlayCount/surfaceWidth/surfaceHeight. Diagnostic only:
    // no production export/session/backend-selector/encoder change.
    external fun drawAndroidDagPhase5GlesExportOverlaySeam(
        textureIds: IntArray?,
        textureTargets: IntArray?,
        geometry: DoubleArray?,
        zIndices: IntArray?,
        overlayCount: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): String

    // ── P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: production native overlay ──
    // composite seam for the narrow GLES-overlay-eligible export route
    // (AndroidTimelineVideoEncoder). Same array/count/surface validation
    // contract, caller-current-context requirement, and private
    // GlesOverlayCompositor::drawOverlays helper as the seam diagnostic
    // above (drawAndroidDagPhase5GlesExportOverlaySeam): creates/destroys no
    // EGL context and no caller texture, and forwards already-resolved
    // GlesOverlayLayerDescriptor fields (7 doubles per layer, in order: x,
    // y, width, height, rotation, scale, opacity) to the same helper.
    // overlayCount == 0 is a legal no-op draw (every array argument may then
    // be null). Unlike the diagnostic seam, this is the production route:
    // it returns a compact "status=OK;overlayCount=N" /
    // "status=FAIL;reason=<reason>" string (the same key=value convention
    // as android_vulkan_export_jni.cpp's production routes), not a JSON
    // object, and carries no diagnostic proofBoundary.
    external fun drawAndroidTimelineGlesExportOverlays(
        textureIds: IntArray?,
        textureTargets: IntArray?,
        geometry: DoubleArray?,
        zIndices: IntArray?,
        overlayCount: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): String

    // ── P5-BEAUTY-V2-GLES-RENDER: GlesBeautyV2Compositor 3-pass bilateral ────
    // beauty smoothing shader/raster + CPU-reference-parity proof diagnostic.
    // Native creates its own temporary 64x64 EGL pbuffer context (OpenGL ES
    // 3.0+ only, no ES2 fallback) and synthetic GL_TEXTURE_2D probe textures
    // on the calling thread, runs the None/Soft/Strong/Max intensity presets
    // through the private GLES beauty helper (blur_h, blur_v, composite:
    // fused highpass, adaptive smoothing gate, tone compression, midtone
    // lift, detail add-back, alpha preservation), reads pixels back,
    // compares against a pure CPU reference that quantizes Pass 1/2
    // intermediates to 8-bit UNORM (mirroring the GL_RGBA8 intermediate
    // FBOs), verifies GL state restoration and per-call resource lifecycle,
    // and tears everything down before returning a JSON object string. Must
    // be called from a thread with no EGL context current (the smoke
    // coordinator's executor). No Vulkan, no MediaCodec/decode, no
    // SurfaceTexture/OES frame proof, no export session, no product UI.
    external fun runAndroidDagPhase5BeautyV2GlesRenderSmoke(): String

    // -- P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: diagnostic-only seam
    // proving a REAL MediaCodec decode -> SurfaceTexture ->
    // GL_TEXTURE_EXTERNAL_OES frame, resolved by the caller to a
    // GL_TEXTURE_2D RGBA8 raster, can still route into the exact same
    // private GlesBeautyV2Compositor::DrawBeautyV2 helper exercised by the
    // synthetic-pbuffer P5-BEAUTY-V2-GLES-RENDER diagnostic above.
    // Creates/destroys no EGL context, texture, or FBO: the caller
    // (AndroidGlesExportBeautySeamSmokeHarness) must already have its own
    // current-verified ES3 EGL context current on the calling thread -- with
    // inputTextureId already holding a resolved GL_RGBA8 raster and
    // targetFbo already created/complete -- before invoking this. Validates
    // dimensions/inputTextureId/targetFbo/intensity itself, then derives the
    // full parameter ramp via ComputeBeautyV2ParametersFromIntensity before
    // calling DrawBeautyV2. Returns a JSON object string with at least
    // status/pass/failureReason/width/height/intensity/proofBoundary.
    // Diagnostic only: no production GLES Beauty export route/session/
    // backend-selector/encoder change.
    external fun drawAndroidDagPhase5GlesExportBeautySeam(
        inputTextureId: Int,
        targetFbo: Int,
        width: Int,
        height: Int,
        intensity: Float,
    ): String

    // -- P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-READINESS: --------------
    // diagnostic-only seam proving two textures already populated with real
    // decoded content can still route into the private
    // GlesTimelineTransitionCompositor::drawTransition helper at a fixed
    // crossfade midpoint (progress 0.5, blendWeightFrom == blendWeightTo ==
    // 0.5, identity crops/viewports). The strengthened caller
    // (AndroidGlesDualOesTransitionSmokeHarness) decodes two clips into two
    // SurfaceTexture-backed GL_TEXTURE_EXTERNAL_OES textures, updateTexImage()
    // s both, then pre-resolves each -- with its SurfaceTexture transform
    // matrix applied -- into its own canvas-sized GL_TEXTURE_2D raster before
    // calling this seam, so the crossfade mix draw only ever receives
    // identity-oriented 2D textures. Creates/destroys no EGL context,
    // SurfaceTexture, MediaCodec, or Java Surface -- the caller must already
    // have both source textures populated and its EGL context current on the
    // calling thread before invoking this. Validates
    // fromTextureId/toTextureId/surfaceWidth/surfaceHeight/progress itself;
    // fromTextureTarget/toTextureTarget are each independently validated to
    // be GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES (matching the compositor's
    // own contract) and are echoed into the returned JSON's details as
    // textureTargetFrom/textureTargetTo. It then draws, reads back a small
    // pixel sample to prove real (non-sentinel, non-black) decoded content
    // was composited, and re-verifies GL state restoration before returning.
    // [fromPtsUs]/[toPtsUs] are echoed into the returned JSON purely for
    // diagnostic telemetry. Diagnostic only: no production GLES transition
    // export route.
    external fun drawAndroidDagPhase5GlesDualOesTransition(
        fromTextureId: Int,
        fromTextureTarget: Int,
        toTextureId: Int,
        toTextureTarget: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
        progress: Double,
        fromPtsUs: Long,
        toPtsUs: Long,
    ): String

    // ── P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: production native ──────
    // transition composite seam for the narrow GLES-transition-eligible export
    // route (AndroidTimelineGlesTransitionVideoEncoder). Same caller-current-
    // context contract as the P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-
    // READINESS diagnostic seam above (drawAndroidDagPhase5GlesDualOesTransition)
    // and the same private GlesTimelineTransitionCompositor::drawTransition
    // helper: creates/destroys no EGL context, SurfaceTexture, MediaCodec, or
    // Java Surface -- the caller must already have both source textures
    // populated (already resolved to GL_TEXTURE_2D rasters via the caller's
    // own OES-to-canvas pre-resolve, matching the diagnostic seam's proven
    // design) and its EGL context current on the calling thread before
    // invoking this, and owns the target surface's frame clear -- this seam
    // never clears the framebuffer itself.
    //
    // [transitionTypeCode] must equal
    // AndroidTimelineTransitionDescriptor.Type.CROSSFADE.nativeCode (1) --
    // this slice only implements a safe crossfade mix draw; any other code
    // (including hard-cut's 0) fails closed before any GL call with a precise
    // unsupported-type reason rather than attempt slide/wipe geometry this
    // route does not yet implement. [progress] is the transition progress in
    // [0.0, 1.0] for this frame (see
    // AndroidTimelineTransitionDescriptor.progressForOverlapFrame).
    //
    // Unlike the diagnostic seam, this production route returns a compact
    // "status=OK;..." / "status=FAIL;reason=<reason>" string (the same
    // key=value convention as android_vulkan_export_jni.cpp's and
    // drawAndroidTimelineGlesExportOverlays's production routes), not a JSON
    // object, and carries no diagnostic proofBoundary.
    external fun drawAndroidTimelineGlesTransitionExportFrame(
        fromTextureId: Int,
        fromTextureTarget: Int,
        toTextureId: Int,
        toTextureTarget: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
        transitionTypeCode: Int,
        progress: Double,
    ): String

    // ── P5-COMPOSITOR-TRANS (VULKAN-RENDER): VulkanTimelineTransitionCompositor ──
    // shader/raster proof diagnostic. Native creates its own temporary
    // VkInstance/VkDevice/VkQueue/VkCommandPool, synthetic RGBA8 sampled images,
    // a 64x64 offscreen color attachment and a host-visible readback buffer on
    // the calling thread, evaluates ComputeTransitionGeometry() for crossfade /
    // slide / wipe / none families, renders each through the private Vulkan
    // transition helper (existing AOT passthrough SPIR-V, fixed-function
    // blending, viewport/scissor placement), reads the pixels back, and
    // destroys everything before returning a JSON object string. Reports
    // status "UNSUPPORTED" (never crashes) when no usable Vulkan device exists.
    // No MediaCodec/decode, no AHardwareBuffer import, no export session, no
    // production VulkanBackend mutation, no product UI.
    external fun runAndroidDagPhase5TimelineTransitionVulkanRenderSmoke(): String

    // ── P5-OVERLAYS-TRANS (VULKAN-RENDER): VulkanOverlayCompositor multi-layer ──
    // overlay shader/raster proof diagnostic. Native creates its own temporary
    // VkInstance/VkDevice/VkQueue/VkCommandPool, synthetic RGBA8 solid/quadrant/
    // half-alpha sampled images with clamp-to-border transparent-black
    // samplers, a 64x64 offscreen color attachment and a host-visible readback
    // buffer on the calling thread, hand-builds already-resolved
    // VulkanOverlayLayerDescriptor lists (mirroring Dart
    // VGOverlayEvaluatedTransform raster fields), renders each lane through the
    // private Vulkan overlay helper (existing AOT passthrough SPIR-V,
    // inverse-UV push-constant placement, per-layer opacity in colour-matrix
    // row 3, fixed-function straight-alpha source-over blending, clear or
    // load-existing render pass), reads the pixels back, proves temporary
    // object created == released, and destroys everything before returning a
    // JSON object string. Reports status "UNSUPPORTED" (never crashes) when no
    // usable Vulkan device exists. No MediaCodec/decode, no AHardwareBuffer
    // import, no keyframe math, no export session, no production VulkanBackend
    // mutation, no product UI.
    external fun runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke(): String

    // ── P5-BEAUTY-V2-VULKAN-RENDER: VulkanBeautyV2Compositor 3-pass bilateral ──
    // beauty smoothing shader/raster + CPU-reference-parity proof diagnostic.
    // Native creates its own temporary VkInstance/VkDevice/VkQueue/
    // VkCommandPool, synthetic RGBA8 sampled source images with
    // clamp-to-edge samplers, a 64x64 offscreen color attachment, and a
    // host-visible readback buffer on the calling thread, runs the
    // None/Soft/Strong/Max intensity presets through the private Vulkan
    // beauty helper (new beauty_v2_blur / beauty_v2_composite fragment
    // shaders reusing the existing AOT passthrough vertex shader: blur_h,
    // blur_v, composite -- fused highpass, adaptive smoothing gate, tone
    // compression, midtone lift, detail add-back, alpha preservation), reads
    // the pixels back, compares against a pure CPU reference that quantizes
    // Pass 1/2 intermediates to 8-bit UNORM (mirroring the
    // VK_FORMAT_R8G8B8A8_UNORM intermediate images), verifies helper
    // temporary object created == released and full diagnostic teardown, and
    // destroys everything before returning a JSON object string. Reports
    // status "UNSUPPORTED" (never crashes) when no usable Vulkan device
    // exists. No MediaCodec/decode, no AHardwareBuffer import, no export
    // session, no production VulkanBackend mutation, no product UI.
    external fun runAndroidDagPhase5BeautyV2VulkanRenderSmoke(): String

    // ── P5-COMPOSITOR-TRANS (DUAL-DECODER-SYNC): dual MediaCodec -> AHB -> Vulkan ──
    // crossfade proof. Kotlin (AndroidTimelineDualDecoderSyncDriver) owns both
    // decoder pipelines and calls this once per overlap frame with one
    // ImageReader.PRIVATE HardwareBuffer from each decoder. Native resolves both
    // to AHardwareBuffer via libandroid, creates a temporary VkDevice with the
    // AHardwareBuffer import extension + samplerYcbcrConversion feature,
    // imports both buffers as sampled images, resolves them to RGBA8 with the
    // existing AOT passthrough SPIR-V, evaluates
    // ComputeTransitionGeometry(kCrossfade, progress), renders through
    // VulkanTimelineTransitionCompositor offscreen (from-only / to-only /
    // blended), reads pixels back, gates the blend arithmetic, and destroys
    // every import/scratch object before returning a JSON object string.
    // Reports status "UNSUPPORTED" (never crashes) when Vulkan or the
    // AHardwareBuffer import path is unavailable. The caller must keep both
    // HardwareBuffers and their Images open until this call returns.
    // Diagnostic only: no export session, no production VulkanBackend
    // mutation, no product UI.
    external fun renderAndroidDagPhase5TimelineDualDecoderSyncCrossfade(
        fromHardwareBuffer: HardwareBuffer,
        fromWidth: Int,
        fromHeight: Int,
        fromFrameIndex: Int,
        fromPtsUs: Long,
        toHardwareBuffer: HardwareBuffer,
        toWidth: Int,
        toHeight: Int,
        toFrameIndex: Int,
        toPtsUs: Long,
        progress: Double,
    ): String

    fun initialize() {
        val report = probeCapabilities()
        diagnostics.logCapabilities(report)
    }
}
