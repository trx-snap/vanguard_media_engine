// vg_aaudio_node_owned_sink_smoke.dart
// vanguard_media_engine - P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC: Android True-DAG Phase 4
// two-source node-owned closed-loop native audio graph pipeline muted native AAudio callback
// sink diagnostic smoke foundation (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase4AaudioNodeOwnedSinkSmoke` MethodChannel route.
// Diagnostic-only - validates the two-source node-owned closed-loop native audio graph
// pipeline JNI session driven by one real MediaExtractor/MediaCodec decoder track
// plus one Kotlin-synthesized PCM track in lockstep on the shared accepted-frame axis
// feeding a MUTED native AAudio callback sink:
// [Real Decoder (Track 0) + Synthetic (Track 1)] ->
// DecodedAudioPcmSourceNodes (owning ring/writer/provider by composition) ->
// GraphAudioScheduler (auto-discovering providers from graph topology) ->
// AudioMixBusNode -> ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer ->
// owner-thread zero-scale pump -> callback sink AudioSpscAudioRingBuffer -> AAudio data callback.
//
// AAudio is reached exclusively via runtime dlopen/dlsym behind an API >= 26 gate
// (minSdk 24 safe; never direct-linked). The owner-thread pump zero-scales the mixed PCM
// before pushing to the callback sink ring, where the AAudio callback pops-or-silences only.
//
// Honest non-claims (Proof Boundary):
// native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed report returned by
/// [VGAaudioNodeOwnedSinkSmokeReport.runAndroidDagPhase4AaudioNodeOwnedSinkSmoke],
/// mirroring the native Kotlin / C++ smoke coordinator's payload map.
@immutable
class VGAaudioNodeOwnedSinkSmokeReport {
  const VGAaudioNodeOwnedSinkSmokeReport({
    required this.pass,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.details,
    required this.formatProbeOk,
    required this.aaudioRuntimeAvailableOk,
    required this.aaudioSymbolsResolvedOk,
    required this.aaudioStreamOpenOk,
    required this.aaudioConfigOk,
    required this.aaudioStartOk,
    required this.callbackObservedOk,
    required this.mutedOutputOk,
    required this.nodeOwnedRouteDiscoveryOk,
    required this.nodeOwnsRingTrack0Ok,
    required this.nodeOwnsRingTrack1Ok,
    required this.track0IngestOk,
    required this.track1SyntheticIngestOk,
    required this.trackFrameAxisLockstepOk,
    required this.jointDispatchGateOk,
    required this.graphOutputChecksumOk,
    required this.aaudioCallbackAccountingOk,
    required this.seekOk,
    required this.jointTailFlushOk,
    required this.noProviderUnderrunOk,
    required this.noGraphSilenceOk,
    required this.noRingPushShortfallOk,
    required this.zeroNativeSteadyStateAllocationOk,
    required this.ownerThreadOk,
    required this.lifecycleOk,
    required this.canonical,
    required this.sampleRate,
    required this.channelCount,
    required this.pcmEncoding,
    required this.commonBudgetFrames,
    required this.expectedFrameCount,
    required this.totalFramesExtracted,
    required this.framesTruncatedBeyondBudget,
    required this.totalFramesAcceptedTrack0,
    required this.totalFramesAcceptedTrack1,
    required this.totalOutputFramesPumped,
    required this.totalMutedFramesPushed,
    required this.postSeekFramesAccepted,
    required this.seekAcceptedFrame,
    required this.seekSkippedDeadline,
    required this.track1NonZeroSampleCount,
    required this.decoderBenignFormatChangeCount,
    required this.nativeAcceptedChecksumHexTrack0,
    required this.nativeAcceptedChecksumHexTrack1,
    required this.nativeOutputDrainChecksumHex,
    required this.mutedSinkChecksumHex,
    required this.kotlinAcceptedChecksumHexTrack0,
    required this.kotlinAcceptedChecksumHexTrack1,
    required this.kotlinReferenceMixChecksumHex,
    required this.routedSourceId0,
    required this.routedSourceId1,
    required this.dispatchCount,
    required this.nextDispatchFrame,
    required this.coordinatorSilenceCount,
    required this.providerUnderrunEventsTrack0,
    required this.providerUnderrunEventsTrack1,
    required this.providerFramesZeroFilledTrack0,
    required this.providerFramesZeroFilledTrack1,
    required this.providerForwardSkipFramesTrack0,
    required this.providerForwardSkipFramesTrack1,
    required this.providerRewindRejectsTrack0,
    required this.providerRewindRejectsTrack1,
    required this.deviceApiLevel,
    required this.streamSampleRate,
    required this.streamChannelCount,
    required this.streamFormat,
    required this.aaudioChannelCountSymbolFallback,
    required this.callbackInvocationCount,
    required this.callbackFramesRequested,
    required this.callbackFramesServed,
    required this.callbackSilenceFrames,
    required this.callbackShortReads,
    required this.errorCallbackCount,
    required this.finalCallbackCountersCoherent,
    required this.sinkFullWaitCount,
    required this.sinkAvailableReadFramesFinal,
    required this.cancellationPollCount,
    required this.nativeLastStatus,
    required this.maxFramesPerMix,
    required this.lanes,
    required this.metrics,
    required this.raw,
    this.lastError = '',
  });

  /// Canonical method name constant for this diagnostic route.
  static const String methodName =
      'runAndroidDagPhase4AaudioNodeOwnedSinkSmoke';

  /// Canonical pass marker string emitted by the native harness.
  static const String passMarkerConstant =
      'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_PASS';

  /// Canonical fail marker string emitted by the native harness.
  static const String failMarkerConstant =
      'ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_FAIL';

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim';

  /// Expected source node ID for Track 0 in topology.
  static const String expectedSource0NodeId = 'aaudio_node_owned_sink_src0';

  /// Expected source node ID for Track 1 in topology.
  static const String expectedSource1NodeId = 'aaudio_node_owned_sink_src1';

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// Status string (e.g. 'pass', 'fail', or fail-closed reason token).
  final String status;

  /// Diagnostic marker string.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// Failure reason token, if any.
  final String failureReason;

  /// Auxiliary execution details or trace breadcrumbs.
  final String details;

  // ---- Lanes (26 lanes) ---------------------------------------------------

  /// Whether initial audio format probe succeeded (PCM16, 1..2 channels).
  final bool formatProbeOk;

  /// Whether AAudio runtime library is available on device (API >= 26 and dlopen succeeded).
  final bool aaudioRuntimeAvailableOk;

  /// Whether all required AAudio runtime C function symbols resolved dynamically.
  final bool aaudioSymbolsResolvedOk;

  /// Whether AAudio stream opened successfully via dynamic builder.
  final bool aaudioStreamOpenOk;

  /// Whether verified AAudio stream configuration matches requested sample rate and channel count.
  final bool aaudioConfigOk;

  /// Whether AAudio stream started and confirmed in STARTED state.
  final bool aaudioStartOk;

  /// Whether real callback consumption was observed (invocations and served frames > 0).
  final bool callbackObservedOk;

  /// Whether output zero-scaling on owner thread is proven (every pushed frame muted).
  final bool mutedOutputOk;

  /// Whether scheduler auto-discovered both node-owned sources from graph topology.
  final bool nodeOwnedRouteDiscoveryOk;

  /// Whether Track 0 DecodedAudioPcmSourceNode owns the ring/writer/provider triple.
  final bool nodeOwnsRingTrack0Ok;

  /// Whether Track 1 DecodedAudioPcmSourceNode owns the ring/writer/provider triple.
  final bool nodeOwnsRingTrack1Ok;

  /// Whether track 0 real decoder ingest checksum identity holds.
  final bool track0IngestOk;

  /// Whether track 1 synthetic ingest checksum identity holds with non-zero samples.
  final bool track1SyntheticIngestOk;

  /// Whether track 0, track 1, and Kotlin accepted frame counts are in exact lockstep.
  final bool trackFrameAxisLockstepOk;

  /// Whether joint dispatch gate deferred single-track and partial sub-windows correctly.
  final bool jointDispatchGateOk;

  /// Whether native graph mixed output checksum matches Kotlin reference mix before zero-scaling.
  final bool graphOutputChecksumOk;

  /// Whether AAudio callback accounting is coherent across all counters.
  final bool aaudioCallbackAccountingOk;

  /// Whether joint accepted-frame-axis seek re-anchored both tracks with zero discards.
  final bool seekOk;

  /// Whether joint EOS tail flush drained both source rings and output to zero.
  final bool jointTailFlushOk;

  /// Whether no provider underruns or zero-fills occurred on either track.
  final bool noProviderUnderrunOk;

  /// Whether no coordinator silence windows occurred.
  final bool noGraphSilenceOk;

  /// Whether no source, output, or sink ring push shortfalls occurred.
  final bool noRingPushShortfallOk;

  /// Whether ring and scheduler capacities remained constant across dispatches.
  final bool zeroNativeSteadyStateAllocationOk;

  /// Whether foreign thread operations were rejected with wrong_owner_thread.
  final bool ownerThreadOk;

  /// Whether session lifecycle creation, start, and destroy were idempotent.
  final bool lifecycleOk;

  /// Canonical pass indicator.
  final bool canonical;

  // ---- Metrics (46 metrics) -----------------------------------------------

  /// Resolved sampling rate in Hz.
  final int sampleRate;

  /// Resolved channel count (1 or 2).
  final int channelCount;

  /// Resolved PCM encoding (AudioFormat.ENCODING_PCM_16BIT = 2).
  final int pcmEncoding;

  /// Common frame budget L calculated as round(durationSec * sampleRate).
  final int commonBudgetFrames;

  /// Expected frame count configured on both node-owned source nodes.
  final int expectedFrameCount;

  /// Total frames extracted from MediaExtractor.
  final int totalFramesExtracted;

  /// Extracted frames truncated beyond the common budget L (explicit non-claim).
  final int framesTruncatedBeyondBudget;

  /// Total frames accepted on Track 0 (real decoder).
  final int totalFramesAcceptedTrack0;

  /// Total frames accepted on Track 1 (synthetic generator).
  final int totalFramesAcceptedTrack1;

  /// Total output frames pumped from graph output ring to muted sink ring.
  final int totalOutputFramesPumped;

  /// Total zero-scaled muted frames pushed into callback sink ring.
  final int totalMutedFramesPushed;

  /// Frames accepted after the joint seek boundary.
  final int postSeekFramesAccepted;

  /// Accepted frame index at which joint seek re-anchoring occurred (-1 if skipped).
  final int seekAcceptedFrame;

  /// Whether seek was skipped due to internal deadline margin.
  final bool seekSkippedDeadline;

  /// Non-zero synthetic PCM sample count generated for track 1.
  final int track1NonZeroSampleCount;

  /// Count of benign repeated format change events observed.
  final int decoderBenignFormatChangeCount;

  /// 64-bit hexadecimal checksum computed on native track 0 accepted side.
  final String nativeAcceptedChecksumHexTrack0;

  /// 64-bit hexadecimal checksum computed on native track 1 accepted side.
  final String nativeAcceptedChecksumHexTrack1;

  /// 64-bit hexadecimal checksum computed on native graph mixed output before zero-scale.
  final String nativeOutputDrainChecksumHex;

  /// 64-bit hexadecimal checksum computed on muted sink push (must be 0000000000000000).
  final String mutedSinkChecksumHex;

  /// 64-bit hexadecimal checksum computed on Kotlin track 0 accepted side.
  final String kotlinAcceptedChecksumHexTrack0;

  /// 64-bit hexadecimal checksum computed on Kotlin track 1 accepted side.
  final String kotlinAcceptedChecksumHexTrack1;

  /// 64-bit hexadecimal checksum computed on Kotlin reference mix side.
  final String kotlinReferenceMixChecksumHex;

  /// Auto-discovered source node ID for Track 0.
  final String routedSourceId0;

  /// Auto-discovered source node ID for Track 1.
  final String routedSourceId1;

  /// Total dispatch cycles executed during the run.
  final int dispatchCount;

  /// Next dispatch frame index.
  final int nextDispatchFrame;

  /// Coordinator silence windows count (must be 0).
  final int coordinatorSilenceCount;

  /// Provider underrun events count on track 0 (must be 0).
  final int providerUnderrunEventsTrack0;

  /// Provider underrun events count on track 1 (must be 0).
  final int providerUnderrunEventsTrack1;

  /// Provider frames zero-filled count on track 0 (must be 0).
  final int providerFramesZeroFilledTrack0;

  /// Provider frames zero-filled count on track 1 (must be 0).
  final int providerFramesZeroFilledTrack1;

  /// Provider forward skip frames count on track 0 (must be 0).
  final int providerForwardSkipFramesTrack0;

  /// Provider forward skip frames count on track 1 (must be 0).
  final int providerForwardSkipFramesTrack1;

  /// Provider rewind frame rejects count on track 0 (must be 0).
  final int providerRewindRejectsTrack0;

  /// Provider rewind frame rejects count on track 1 (must be 0).
  final int providerRewindRejectsTrack1;

  /// Android device SDK / API level reported by native bridge.
  final int deviceApiLevel;

  /// Configured AAudio stream sample rate.
  final int streamSampleRate;

  /// Configured AAudio stream channel count.
  final int streamChannelCount;

  /// Configured AAudio stream format (AAUDIO_FORMAT_PCM_I16 = 1).
  final int streamFormat;

  /// Whether fallback symbol resolution was used for AAudio channel count.
  final bool aaudioChannelCountSymbolFallback;

  /// Total AAudio data callback invocations observed.
  final int callbackInvocationCount;

  /// Total PCM frames requested across all data callback invocations.
  final int callbackFramesRequested;

  /// Total muted PCM frames served across all data callback invocations.
  final int callbackFramesServed;

  /// Total silence/zero-fill frames served when callback sink ring underran.
  final int callbackSilenceFrames;

  /// Number of callback invocations where fewer frames were available than requested.
  final int callbackShortReads;

  /// Total error callback invocations observed (must be 0).
  final int errorCallbackCount;

  /// Whether final callback counters reported post-close are coherent.
  final bool finalCallbackCountersCoherent;

  /// Number of times owner-thread pump parked waiting for callback sink ring space.
  final int sinkFullWaitCount;

  /// Available read frames remaining in sink ring at final snapshot.
  final int sinkAvailableReadFramesFinal;

  /// Cancellation poll count across driver execution loops.
  final int cancellationPollCount;

  /// Last native status string snapshot.
  final String nativeLastStatus;

  /// Maximum frames rendered per mix dispatch cycle.
  final int maxFramesPerMix;

  // ---- Raw & Nested Maps --------------------------------------------------

  /// Nested lanes map emitted by native smoke execution.
  final Map<String, Object?> lanes;

  /// Key/value metrics map emitted by native smoke execution.
  final Map<String, Object?> metrics;

  /// Map of raw string outputs emitted by native smoke execution.
  final Map<String, String> raw;

  /// Last error string from native execution, if any.
  final String lastError;

  // ---- Getters ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] matches the canonical pass marker constant.
  bool get hasPassMarker => marker == passMarkerConstant;

  /// Whether [marker] matches the canonical fail marker constant.
  bool get hasFailMarker => marker == failMarkerConstant;

  /// Whether the muted sink checksum is all-zeros and [mutedOutputOk] holds.
  bool get mutedSinkIsZero =>
      mutedSinkChecksumHex == '0000000000000000' && mutedOutputOk;

  /// Whether AAudio callback accounting is fully coherent and non-zero.
  bool get callbackAccountingCoherent =>
      finalCallbackCountersCoherent &&
      callbackInvocationCount > 0 &&
      callbackFramesServed > 0 &&
      callbackFramesRequested == callbackFramesServed + callbackSilenceFrames &&
      aaudioCallbackAccountingOk;

  /// Whether Kotlin accepted and native accepted checksums match for both tracks,
  /// Kotlin reference mix matches native output drain checksum, all are non-empty,
  /// mix checksum is non-zero, and [track0IngestOk], [track1SyntheticIngestOk],
  /// and [graphOutputChecksumOk] hold.
  bool get checksumsMatch =>
      kotlinAcceptedChecksumHexTrack0.isNotEmpty &&
      nativeAcceptedChecksumHexTrack0.isNotEmpty &&
      kotlinAcceptedChecksumHexTrack0 == nativeAcceptedChecksumHexTrack0 &&
      kotlinAcceptedChecksumHexTrack1.isNotEmpty &&
      nativeAcceptedChecksumHexTrack1.isNotEmpty &&
      kotlinAcceptedChecksumHexTrack1 == nativeAcceptedChecksumHexTrack1 &&
      kotlinReferenceMixChecksumHex.isNotEmpty &&
      nativeOutputDrainChecksumHex.isNotEmpty &&
      kotlinReferenceMixChecksumHex == nativeOutputDrainChecksumHex &&
      kotlinReferenceMixChecksumHex != '0000000000000000' &&
      track0IngestOk &&
      track1SyntheticIngestOk &&
      graphOutputChecksumOk;

  /// Whether all native diagnostic lanes passed according to the P4 AAudio node-owned
  /// callback sink diagnostic verification contract.
  bool get allNativeLanesPass {
    if (!pass) return false;
    if (!hasCanonicalProofBoundary) return false;
    if (status.toLowerCase() != 'pass') return false;
    if (!hasPassMarker) return false;
    if (!formatProbeOk) return false;
    if (!aaudioRuntimeAvailableOk) return false;
    if (!aaudioSymbolsResolvedOk) return false;
    if (!aaudioStreamOpenOk) return false;
    if (!aaudioConfigOk) return false;
    if (!aaudioStartOk) return false;
    if (!callbackObservedOk) return false;
    if (!mutedOutputOk) return false;
    if (!nodeOwnedRouteDiscoveryOk) return false;
    if (!nodeOwnsRingTrack0Ok) return false;
    if (!nodeOwnsRingTrack1Ok) return false;
    if (!track0IngestOk) return false;
    if (!track1SyntheticIngestOk) return false;
    if (!trackFrameAxisLockstepOk) return false;
    if (!jointDispatchGateOk) return false;
    if (!graphOutputChecksumOk) return false;
    if (!aaudioCallbackAccountingOk) return false;
    if (seekSkippedDeadline) {
      // seekOk may be false only when seek was skipped due to deadline margin
    } else {
      if (!seekOk) return false;
      if (postSeekFramesAccepted <= 0) return false;
      if (seekAcceptedFrame < 0) return false;
    }
    if (!jointTailFlushOk) return false;
    if (!noProviderUnderrunOk) return false;
    if (!noGraphSilenceOk) return false;
    if (!noRingPushShortfallOk) return false;
    if (!zeroNativeSteadyStateAllocationOk) return false;
    if (!ownerThreadOk) return false;
    if (!lifecycleOk) return false;
    if (!canonical) return false;
    if (sampleRate <= 0) return false;
    if (channelCount < 1 || channelCount > 2) return false;
    if (pcmEncoding != 2) return false;
    if (commonBudgetFrames <= 0) return false;
    if (expectedFrameCount <= 0 || expectedFrameCount != commonBudgetFrames) {
      return false;
    }
    if (routedSourceId0 != expectedSource0NodeId) return false;
    if (routedSourceId1 != expectedSource1NodeId) return false;
    if (totalFramesAcceptedTrack0 <= 0) return false;
    if (totalFramesAcceptedTrack1 <= 0) return false;
    if (totalFramesAcceptedTrack0 != totalFramesAcceptedTrack1) return false;
    if (totalOutputFramesPumped <= 0) return false;
    if (totalOutputFramesPumped != totalFramesAcceptedTrack0) return false;
    if (totalMutedFramesPushed != totalOutputFramesPumped) return false;
    if (track1NonZeroSampleCount <= 0) return false;
    if (dispatchCount < 50) return false;
    if (providerUnderrunEventsTrack0 != 0) return false;
    if (providerUnderrunEventsTrack1 != 0) return false;
    if (providerFramesZeroFilledTrack0 != 0) return false;
    if (providerFramesZeroFilledTrack1 != 0) return false;
    if (providerForwardSkipFramesTrack0 != 0) return false;
    if (providerForwardSkipFramesTrack1 != 0) return false;
    if (providerRewindRejectsTrack0 != 0) return false;
    if (providerRewindRejectsTrack1 != 0) return false;
    if (coordinatorSilenceCount != 0) return false;
    if (!checksumsMatch) return false;
    if (!mutedSinkIsZero) return false;
    if (!callbackAccountingCoherent) return false;
    if (lastError.isNotEmpty && lastError != 'none' && lastError != 'null') {
      return false;
    }
    return true;
  }

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGAaudioNodeOwnedSinkSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return const VGAaudioNodeOwnedSinkSmokeReport(
        pass: false,
        status: 'fail',
        marker: failMarkerConstant,
        proofBoundary: '',
        failureReason: 'native_result_not_a_map',
        details: '',
        formatProbeOk: false,
        aaudioRuntimeAvailableOk: false,
        aaudioSymbolsResolvedOk: false,
        aaudioStreamOpenOk: false,
        aaudioConfigOk: false,
        aaudioStartOk: false,
        callbackObservedOk: false,
        mutedOutputOk: false,
        nodeOwnedRouteDiscoveryOk: false,
        nodeOwnsRingTrack0Ok: false,
        nodeOwnsRingTrack1Ok: false,
        track0IngestOk: false,
        track1SyntheticIngestOk: false,
        trackFrameAxisLockstepOk: false,
        jointDispatchGateOk: false,
        graphOutputChecksumOk: false,
        aaudioCallbackAccountingOk: false,
        seekOk: false,
        jointTailFlushOk: false,
        noProviderUnderrunOk: false,
        noGraphSilenceOk: false,
        noRingPushShortfallOk: false,
        zeroNativeSteadyStateAllocationOk: false,
        ownerThreadOk: false,
        lifecycleOk: false,
        canonical: false,
        sampleRate: 0,
        channelCount: 0,
        pcmEncoding: 0,
        commonBudgetFrames: 0,
        expectedFrameCount: 0,
        totalFramesExtracted: 0,
        framesTruncatedBeyondBudget: 0,
        totalFramesAcceptedTrack0: 0,
        totalFramesAcceptedTrack1: 0,
        totalOutputFramesPumped: 0,
        totalMutedFramesPushed: 0,
        postSeekFramesAccepted: 0,
        seekAcceptedFrame: -1,
        seekSkippedDeadline: false,
        track1NonZeroSampleCount: 0,
        decoderBenignFormatChangeCount: 0,
        nativeAcceptedChecksumHexTrack0: '',
        nativeAcceptedChecksumHexTrack1: '',
        nativeOutputDrainChecksumHex: '',
        mutedSinkChecksumHex: '',
        kotlinAcceptedChecksumHexTrack0: '',
        kotlinAcceptedChecksumHexTrack1: '',
        kotlinReferenceMixChecksumHex: '',
        routedSourceId0: '',
        routedSourceId1: '',
        dispatchCount: 0,
        nextDispatchFrame: -1,
        coordinatorSilenceCount: 0,
        providerUnderrunEventsTrack0: 0,
        providerUnderrunEventsTrack1: 0,
        providerFramesZeroFilledTrack0: 0,
        providerFramesZeroFilledTrack1: 0,
        providerForwardSkipFramesTrack0: 0,
        providerForwardSkipFramesTrack1: 0,
        providerRewindRejectsTrack0: 0,
        providerRewindRejectsTrack1: 0,
        deviceApiLevel: 0,
        streamSampleRate: 0,
        streamChannelCount: 0,
        streamFormat: 0,
        aaudioChannelCountSymbolFallback: false,
        callbackInvocationCount: 0,
        callbackFramesRequested: 0,
        callbackFramesServed: 0,
        callbackSilenceFrames: 0,
        callbackShortReads: 0,
        errorCallbackCount: 0,
        finalCallbackCountersCoherent: false,
        sinkFullWaitCount: 0,
        sinkAvailableReadFramesFinal: -1,
        cancellationPollCount: 0,
        nativeLastStatus: '',
        maxFramesPerMix: 0,
        lanes: <String, Object?>{
          'formatProbeOk': false,
          'aaudioRuntimeAvailableOk': false,
          'aaudioSymbolsResolvedOk': false,
          'aaudioStreamOpenOk': false,
          'aaudioConfigOk': false,
          'aaudioStartOk': false,
          'callbackObservedOk': false,
          'mutedOutputOk': false,
          'nodeOwnedRouteDiscoveryOk': false,
          'nodeOwnsRingTrack0Ok': false,
          'nodeOwnsRingTrack1Ok': false,
          'track0IngestOk': false,
          'track1SyntheticIngestOk': false,
          'trackFrameAxisLockstepOk': false,
          'jointDispatchGateOk': false,
          'graphOutputChecksumOk': false,
          'aaudioCallbackAccountingOk': false,
          'seekOk': false,
          'jointTailFlushOk': false,
          'noProviderUnderrunOk': false,
          'noGraphSilenceOk': false,
          'noRingPushShortfallOk': false,
          'zeroNativeSteadyStateAllocationOk': false,
          'ownerThreadOk': false,
          'lifecycleOk': false,
          'canonical': false,
        },
        metrics: <String, Object?>{
          'status': 'FAIL',
          'reason': 'native_result_not_a_map',
        },
        raw: <String, String>{'reason': 'native_result_not_a_map'},
        lastError: 'native_result_not_a_map',
      );
    }

    final rawMapInput = raw['raw'];
    final parsedRaw = <String, String>{};
    if (rawMapInput is Map) {
      for (final entry in rawMapInput.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && v != null) {
          parsedRaw[k] = v;
        }
      }
    } else if (rawMapInput is String && rawMapInput.isNotEmpty) {
      for (final part in rawMapInput.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          final k = part.substring(0, eq).trim();
          final v = part.substring(eq + 1).trim();
          if (k.isNotEmpty) {
            parsedRaw[k] = v;
          }
        }
      }
    }

    final lanesRaw = raw['lanes'];
    final parsedLanes = <String, Object?>{};
    if (lanesRaw is Map) {
      for (final entry in lanesRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedLanes[k] = entry.value;
        }
      }
    }

    final metricsRaw = raw['metrics'];
    final parsedMetrics = <String, Object?>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          parsedMetrics[k] = entry.value;
        }
      }
    }

    bool parseBool(String key, [bool defaultValue = false]) {
      final v =
          parsedLanes[key] ?? raw[key] ?? parsedMetrics[key] ?? parsedRaw[key];
      if (v is bool) {
        return v;
      }
      if (v is String) {
        final lower = v.trim().toLowerCase();
        if (lower == 'true' ||
            lower == 'pass' ||
            lower == 'ok' ||
            lower == 'success') {
          return true;
        }
        if (lower == 'false' || lower == 'fail') {
          return false;
        }
      }
      return defaultValue;
    }

    int parseInt(String key, [int defaultValue = 0]) {
      final v =
          parsedMetrics[key] ?? raw[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? defaultValue;
      return defaultValue;
    }

    String parseString(String key, [String defaultValue = '']) {
      final v =
          raw[key] ?? parsedMetrics[key] ?? parsedLanes[key] ?? parsedRaw[key];
      if (v != null) return v.toString();
      return defaultValue;
    }

    final pass = parseBool(
      'pass',
      parsedRaw['status']?.toLowerCase() == 'pass',
    );
    final status = parseString('status', pass ? 'pass' : 'fail');
    final marker = parseString(
      'marker',
      pass ? passMarkerConstant : failMarkerConstant,
    );
    final proofBoundary = parseString('proofBoundary');
    final failureReason = parseString(
      'failureReason',
      parsedRaw['reason'] ?? '',
    );
    final details = parseString('details');

    final formatProbeOk = parseBool('formatProbeOk');
    final aaudioRuntimeAvailableOk = parseBool('aaudioRuntimeAvailableOk');
    final aaudioSymbolsResolvedOk = parseBool('aaudioSymbolsResolvedOk');
    final aaudioStreamOpenOk = parseBool('aaudioStreamOpenOk');
    final aaudioConfigOk = parseBool('aaudioConfigOk');
    final aaudioStartOk = parseBool('aaudioStartOk');
    final callbackObservedOk = parseBool('callbackObservedOk');
    final mutedOutputOk = parseBool('mutedOutputOk');
    final nodeOwnedRouteDiscoveryOk = parseBool('nodeOwnedRouteDiscoveryOk');
    final nodeOwnsRingTrack0Ok = parseBool('nodeOwnsRingTrack0Ok');
    final nodeOwnsRingTrack1Ok = parseBool('nodeOwnsRingTrack1Ok');
    final track0IngestOk = parseBool('track0IngestOk');
    final track1SyntheticIngestOk = parseBool('track1SyntheticIngestOk');
    final trackFrameAxisLockstepOk = parseBool(
      'trackFrameAxisLockstepOk',
      parseBool('track0IngestOk') && parseBool('track1SyntheticIngestOk'),
    );
    final jointDispatchGateOk = parseBool('jointDispatchGateOk');
    final graphOutputChecksumOk = parseBool('graphOutputChecksumOk');
    final aaudioCallbackAccountingOk = parseBool('aaudioCallbackAccountingOk');
    final seekOk = parseBool('seekOk');
    final jointTailFlushOk = parseBool('jointTailFlushOk');
    final noProviderUnderrunOk = parseBool('noProviderUnderrunOk');
    final noGraphSilenceOk = parseBool('noGraphSilenceOk');
    final noRingPushShortfallOk = parseBool('noRingPushShortfallOk');
    final zeroNativeSteadyStateAllocationOk = parseBool(
      'zeroNativeSteadyStateAllocationOk',
    );
    final ownerThreadOk = parseBool('ownerThreadOk');
    final lifecycleOk = parseBool('lifecycleOk');
    final canonical = parseBool('canonical', pass);

    final sampleRate = parseInt('sampleRate');
    final channelCount = parseInt('channelCount');
    final pcmEncoding = parseInt('pcmEncoding');
    final commonBudgetFrames = parseInt('commonBudgetFrames');
    final expectedFrameCount = parseInt('expectedFrameCount');
    final totalFramesExtracted = parseInt('totalFramesExtracted');
    final framesTruncatedBeyondBudget = parseInt('framesTruncatedBeyondBudget');
    final totalFramesAcceptedTrack0 = parseInt('totalFramesAcceptedTrack0');
    final totalFramesAcceptedTrack1 = parseInt('totalFramesAcceptedTrack1');
    final totalOutputFramesPumped = parseInt('totalOutputFramesPumped');
    final totalMutedFramesPushed = parseInt('totalMutedFramesPushed');
    final postSeekFramesAccepted = parseInt('postSeekFramesAccepted');
    final seekAcceptedFrame = parseInt('seekAcceptedFrame', -1);
    final seekSkippedDeadline = parseBool('seekSkippedDeadline');
    final track1NonZeroSampleCount = parseInt('track1NonZeroSampleCount');
    final decoderBenignFormatChangeCount = parseInt(
      'decoderBenignFormatChangeCount',
    );
    final nativeAcceptedChecksumHexTrack0 = parseString(
      'nativeAcceptedChecksumHexTrack0',
    );
    final nativeAcceptedChecksumHexTrack1 = parseString(
      'nativeAcceptedChecksumHexTrack1',
    );
    final nativeOutputDrainChecksumHex = parseString(
      'nativeOutputDrainChecksumHex',
    );
    final mutedSinkChecksumHex = parseString('mutedSinkChecksumHex');
    final kotlinAcceptedChecksumHexTrack0 = parseString(
      'kotlinAcceptedChecksumHexTrack0',
    );
    final kotlinAcceptedChecksumHexTrack1 = parseString(
      'kotlinAcceptedChecksumHexTrack1',
    );
    final kotlinReferenceMixChecksumHex = parseString(
      'kotlinReferenceMixChecksumHex',
    );
    final routedSourceId0 = parseString('routedSourceId0');
    final routedSourceId1 = parseString('routedSourceId1');
    final dispatchCount = parseInt('dispatchCount');
    final nextDispatchFrame = parseInt('nextDispatchFrame', -1);
    final coordinatorSilenceCount = parseInt('coordinatorSilenceCount');
    final providerUnderrunEventsTrack0 = parseInt(
      'providerUnderrunEventsTrack0',
    );
    final providerUnderrunEventsTrack1 = parseInt(
      'providerUnderrunEventsTrack1',
    );
    final providerFramesZeroFilledTrack0 = parseInt(
      'providerFramesZeroFilledTrack0',
    );
    final providerFramesZeroFilledTrack1 = parseInt(
      'providerFramesZeroFilledTrack1',
    );
    final providerForwardSkipFramesTrack0 = parseInt(
      'providerForwardSkipFramesTrack0',
    );
    final providerForwardSkipFramesTrack1 = parseInt(
      'providerForwardSkipFramesTrack1',
    );
    final providerRewindRejectsTrack0 = parseInt('providerRewindRejectsTrack0');
    final providerRewindRejectsTrack1 = parseInt('providerRewindRejectsTrack1');
    final deviceApiLevel = parseInt('deviceApiLevel');
    final streamSampleRate = parseInt('streamSampleRate');
    final streamChannelCount = parseInt('streamChannelCount');
    final streamFormat = parseInt('streamFormat');
    final aaudioChannelCountSymbolFallback = parseBool(
      'aaudioChannelCountSymbolFallback',
    );
    final callbackInvocationCount = parseInt('callbackInvocationCount');
    final callbackFramesRequested = parseInt('callbackFramesRequested');
    final callbackFramesServed = parseInt('callbackFramesServed');
    final callbackSilenceFrames = parseInt('callbackSilenceFrames');
    final callbackShortReads = parseInt('callbackShortReads');
    final errorCallbackCount = parseInt('errorCallbackCount');
    final finalCallbackCountersCoherent = parseBool(
      'finalCallbackCountersCoherent',
    );
    final sinkFullWaitCount = parseInt('sinkFullWaitCount');
    final sinkAvailableReadFramesFinal = parseInt(
      'sinkAvailableReadFramesFinal',
      -1,
    );
    final cancellationPollCount = parseInt('cancellationPollCount');
    final nativeLastStatus = parseString('nativeLastStatus');
    final maxFramesPerMix = parseInt('maxFramesPerMix', 256);

    final lastError = parseString(
      'lastError',
      failureReason.isNotEmpty ? failureReason : (pass ? '' : status),
    );

    final finalLanes = <String, Object?>{
      'formatProbeOk': formatProbeOk,
      'aaudioRuntimeAvailableOk': aaudioRuntimeAvailableOk,
      'aaudioSymbolsResolvedOk': aaudioSymbolsResolvedOk,
      'aaudioStreamOpenOk': aaudioStreamOpenOk,
      'aaudioConfigOk': aaudioConfigOk,
      'aaudioStartOk': aaudioStartOk,
      'callbackObservedOk': callbackObservedOk,
      'mutedOutputOk': mutedOutputOk,
      'nodeOwnedRouteDiscoveryOk': nodeOwnedRouteDiscoveryOk,
      'nodeOwnsRingTrack0Ok': nodeOwnsRingTrack0Ok,
      'nodeOwnsRingTrack1Ok': nodeOwnsRingTrack1Ok,
      'track0IngestOk': track0IngestOk,
      'track1SyntheticIngestOk': track1SyntheticIngestOk,
      'trackFrameAxisLockstepOk': trackFrameAxisLockstepOk,
      'jointDispatchGateOk': jointDispatchGateOk,
      'graphOutputChecksumOk': graphOutputChecksumOk,
      'aaudioCallbackAccountingOk': aaudioCallbackAccountingOk,
      'seekOk': seekOk,
      'jointTailFlushOk': jointTailFlushOk,
      'noProviderUnderrunOk': noProviderUnderrunOk,
      'noGraphSilenceOk': noGraphSilenceOk,
      'noRingPushShortfallOk': noRingPushShortfallOk,
      'zeroNativeSteadyStateAllocationOk': zeroNativeSteadyStateAllocationOk,
      'ownerThreadOk': ownerThreadOk,
      'lifecycleOk': lifecycleOk,
      'canonical': canonical,
      ...parsedLanes,
    };

    final finalMetrics = <String, Object?>{
      'sampleRate': sampleRate,
      'channelCount': channelCount,
      'pcmEncoding': pcmEncoding,
      'commonBudgetFrames': commonBudgetFrames,
      'expectedFrameCount': expectedFrameCount,
      'totalFramesExtracted': totalFramesExtracted,
      'framesTruncatedBeyondBudget': framesTruncatedBeyondBudget,
      'totalFramesAcceptedTrack0': totalFramesAcceptedTrack0,
      'totalFramesAcceptedTrack1': totalFramesAcceptedTrack1,
      'totalOutputFramesPumped': totalOutputFramesPumped,
      'totalMutedFramesPushed': totalMutedFramesPushed,
      'postSeekFramesAccepted': postSeekFramesAccepted,
      'seekAcceptedFrame': seekAcceptedFrame,
      'seekSkippedDeadline': seekSkippedDeadline,
      'track1NonZeroSampleCount': track1NonZeroSampleCount,
      'decoderBenignFormatChangeCount': decoderBenignFormatChangeCount,
      'nativeAcceptedChecksumHexTrack0': nativeAcceptedChecksumHexTrack0,
      'nativeAcceptedChecksumHexTrack1': nativeAcceptedChecksumHexTrack1,
      'nativeOutputDrainChecksumHex': nativeOutputDrainChecksumHex,
      'mutedSinkChecksumHex': mutedSinkChecksumHex,
      'kotlinAcceptedChecksumHexTrack0': kotlinAcceptedChecksumHexTrack0,
      'kotlinAcceptedChecksumHexTrack1': kotlinAcceptedChecksumHexTrack1,
      'kotlinReferenceMixChecksumHex': kotlinReferenceMixChecksumHex,
      'routedSourceId0': routedSourceId0,
      'routedSourceId1': routedSourceId1,
      'dispatchCount': dispatchCount,
      'nextDispatchFrame': nextDispatchFrame,
      'coordinatorSilenceCount': coordinatorSilenceCount,
      'providerUnderrunEventsTrack0': providerUnderrunEventsTrack0,
      'providerUnderrunEventsTrack1': providerUnderrunEventsTrack1,
      'providerFramesZeroFilledTrack0': providerFramesZeroFilledTrack0,
      'providerFramesZeroFilledTrack1': providerFramesZeroFilledTrack1,
      'providerForwardSkipFramesTrack0': providerForwardSkipFramesTrack0,
      'providerForwardSkipFramesTrack1': providerForwardSkipFramesTrack1,
      'providerRewindRejectsTrack0': providerRewindRejectsTrack0,
      'providerRewindRejectsTrack1': providerRewindRejectsTrack1,
      'deviceApiLevel': deviceApiLevel,
      'streamSampleRate': streamSampleRate,
      'streamChannelCount': streamChannelCount,
      'streamFormat': streamFormat,
      'aaudioChannelCountSymbolFallback': aaudioChannelCountSymbolFallback,
      'callbackInvocationCount': callbackInvocationCount,
      'callbackFramesRequested': callbackFramesRequested,
      'callbackFramesServed': callbackFramesServed,
      'callbackSilenceFrames': callbackSilenceFrames,
      'callbackShortReads': callbackShortReads,
      'errorCallbackCount': errorCallbackCount,
      'finalCallbackCountersCoherent': finalCallbackCountersCoherent,
      'sinkFullWaitCount': sinkFullWaitCount,
      'sinkAvailableReadFramesFinal': sinkAvailableReadFramesFinal,
      'cancellationPollCount': cancellationPollCount,
      'nativeLastStatus': nativeLastStatus,
      'maxFramesPerMix': maxFramesPerMix,
      ...parsedMetrics,
    };

    return VGAaudioNodeOwnedSinkSmokeReport(
      pass: pass,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      details: details,
      formatProbeOk: formatProbeOk,
      aaudioRuntimeAvailableOk: aaudioRuntimeAvailableOk,
      aaudioSymbolsResolvedOk: aaudioSymbolsResolvedOk,
      aaudioStreamOpenOk: aaudioStreamOpenOk,
      aaudioConfigOk: aaudioConfigOk,
      aaudioStartOk: aaudioStartOk,
      callbackObservedOk: callbackObservedOk,
      mutedOutputOk: mutedOutputOk,
      nodeOwnedRouteDiscoveryOk: nodeOwnedRouteDiscoveryOk,
      nodeOwnsRingTrack0Ok: nodeOwnsRingTrack0Ok,
      nodeOwnsRingTrack1Ok: nodeOwnsRingTrack1Ok,
      track0IngestOk: track0IngestOk,
      track1SyntheticIngestOk: track1SyntheticIngestOk,
      trackFrameAxisLockstepOk: trackFrameAxisLockstepOk,
      jointDispatchGateOk: jointDispatchGateOk,
      graphOutputChecksumOk: graphOutputChecksumOk,
      aaudioCallbackAccountingOk: aaudioCallbackAccountingOk,
      seekOk: seekOk,
      jointTailFlushOk: jointTailFlushOk,
      noProviderUnderrunOk: noProviderUnderrunOk,
      noGraphSilenceOk: noGraphSilenceOk,
      noRingPushShortfallOk: noRingPushShortfallOk,
      zeroNativeSteadyStateAllocationOk: zeroNativeSteadyStateAllocationOk,
      ownerThreadOk: ownerThreadOk,
      lifecycleOk: lifecycleOk,
      canonical: canonical,
      sampleRate: sampleRate,
      channelCount: channelCount,
      pcmEncoding: pcmEncoding,
      commonBudgetFrames: commonBudgetFrames,
      expectedFrameCount: expectedFrameCount,
      totalFramesExtracted: totalFramesExtracted,
      framesTruncatedBeyondBudget: framesTruncatedBeyondBudget,
      totalFramesAcceptedTrack0: totalFramesAcceptedTrack0,
      totalFramesAcceptedTrack1: totalFramesAcceptedTrack1,
      totalOutputFramesPumped: totalOutputFramesPumped,
      totalMutedFramesPushed: totalMutedFramesPushed,
      postSeekFramesAccepted: postSeekFramesAccepted,
      seekAcceptedFrame: seekAcceptedFrame,
      seekSkippedDeadline: seekSkippedDeadline,
      track1NonZeroSampleCount: track1NonZeroSampleCount,
      decoderBenignFormatChangeCount: decoderBenignFormatChangeCount,
      nativeAcceptedChecksumHexTrack0: nativeAcceptedChecksumHexTrack0,
      nativeAcceptedChecksumHexTrack1: nativeAcceptedChecksumHexTrack1,
      nativeOutputDrainChecksumHex: nativeOutputDrainChecksumHex,
      mutedSinkChecksumHex: mutedSinkChecksumHex,
      kotlinAcceptedChecksumHexTrack0: kotlinAcceptedChecksumHexTrack0,
      kotlinAcceptedChecksumHexTrack1: kotlinAcceptedChecksumHexTrack1,
      kotlinReferenceMixChecksumHex: kotlinReferenceMixChecksumHex,
      routedSourceId0: routedSourceId0,
      routedSourceId1: routedSourceId1,
      dispatchCount: dispatchCount,
      nextDispatchFrame: nextDispatchFrame,
      coordinatorSilenceCount: coordinatorSilenceCount,
      providerUnderrunEventsTrack0: providerUnderrunEventsTrack0,
      providerUnderrunEventsTrack1: providerUnderrunEventsTrack1,
      providerFramesZeroFilledTrack0: providerFramesZeroFilledTrack0,
      providerFramesZeroFilledTrack1: providerFramesZeroFilledTrack1,
      providerForwardSkipFramesTrack0: providerForwardSkipFramesTrack0,
      providerForwardSkipFramesTrack1: providerForwardSkipFramesTrack1,
      providerRewindRejectsTrack0: providerRewindRejectsTrack0,
      providerRewindRejectsTrack1: providerRewindRejectsTrack1,
      deviceApiLevel: deviceApiLevel,
      streamSampleRate: streamSampleRate,
      streamChannelCount: streamChannelCount,
      streamFormat: streamFormat,
      aaudioChannelCountSymbolFallback: aaudioChannelCountSymbolFallback,
      callbackInvocationCount: callbackInvocationCount,
      callbackFramesRequested: callbackFramesRequested,
      callbackFramesServed: callbackFramesServed,
      callbackSilenceFrames: callbackSilenceFrames,
      callbackShortReads: callbackShortReads,
      errorCallbackCount: errorCallbackCount,
      finalCallbackCountersCoherent: finalCallbackCountersCoherent,
      sinkFullWaitCount: sinkFullWaitCount,
      sinkAvailableReadFramesFinal: sinkAvailableReadFramesFinal,
      cancellationPollCount: cancellationPollCount,
      nativeLastStatus: nativeLastStatus,
      maxFramesPerMix: maxFramesPerMix,
      lanes: Map<String, Object?>.unmodifiable(finalLanes),
      metrics: Map<String, Object?>.unmodifiable(finalMetrics),
      raw: Map<String, String>.unmodifiable(parsedRaw),
      lastError: lastError,
    );
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      'details': details,
      'lanes': Map<String, Object?>.from(lanes),
      'metrics': Map<String, Object?>.from(metrics),
      'raw': Map<String, String>.from(raw),
      'lastError': lastError,
    };
  }

  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  static VGAaudioNodeOwnedSinkSmokeReport _makeErrorFallbackReport({
    required String reason,
    required String details,
    required String lastError,
  }) {
    final lanes = <String, Object?>{
      'formatProbeOk': false,
      'aaudioRuntimeAvailableOk': false,
      'aaudioSymbolsResolvedOk': false,
      'aaudioStreamOpenOk': false,
      'aaudioConfigOk': false,
      'aaudioStartOk': false,
      'callbackObservedOk': false,
      'mutedOutputOk': false,
      'nodeOwnedRouteDiscoveryOk': false,
      'nodeOwnsRingTrack0Ok': false,
      'nodeOwnsRingTrack1Ok': false,
      'track0IngestOk': false,
      'track1SyntheticIngestOk': false,
      'trackFrameAxisLockstepOk': false,
      'jointDispatchGateOk': false,
      'graphOutputChecksumOk': false,
      'aaudioCallbackAccountingOk': false,
      'seekOk': false,
      'jointTailFlushOk': false,
      'noProviderUnderrunOk': false,
      'noGraphSilenceOk': false,
      'noRingPushShortfallOk': false,
      'zeroNativeSteadyStateAllocationOk': false,
      'ownerThreadOk': false,
      'lifecycleOk': false,
      'canonical': false,
    };
    final metrics = <String, Object?>{
      'sampleRate': 0,
      'channelCount': 0,
      'pcmEncoding': 0,
      'commonBudgetFrames': 0,
      'expectedFrameCount': 0,
      'totalFramesExtracted': 0,
      'framesTruncatedBeyondBudget': 0,
      'totalFramesAcceptedTrack0': 0,
      'totalFramesAcceptedTrack1': 0,
      'totalOutputFramesPumped': 0,
      'totalMutedFramesPushed': 0,
      'postSeekFramesAccepted': 0,
      'seekAcceptedFrame': -1,
      'seekSkippedDeadline': false,
      'track1NonZeroSampleCount': 0,
      'decoderBenignFormatChangeCount': 0,
      'nativeAcceptedChecksumHexTrack0': '',
      'nativeAcceptedChecksumHexTrack1': '',
      'nativeOutputDrainChecksumHex': '',
      'mutedSinkChecksumHex': '',
      'kotlinAcceptedChecksumHexTrack0': '',
      'kotlinAcceptedChecksumHexTrack1': '',
      'kotlinReferenceMixChecksumHex': '',
      'routedSourceId0': '',
      'routedSourceId1': '',
      'dispatchCount': 0,
      'nextDispatchFrame': -1,
      'coordinatorSilenceCount': 0,
      'providerUnderrunEventsTrack0': 0,
      'providerUnderrunEventsTrack1': 0,
      'providerFramesZeroFilledTrack0': 0,
      'providerFramesZeroFilledTrack1': 0,
      'providerForwardSkipFramesTrack0': 0,
      'providerForwardSkipFramesTrack1': 0,
      'providerRewindRejectsTrack0': 0,
      'providerRewindRejectsTrack1': 0,
      'deviceApiLevel': 0,
      'streamSampleRate': 0,
      'streamChannelCount': 0,
      'streamFormat': 0,
      'aaudioChannelCountSymbolFallback': false,
      'callbackInvocationCount': 0,
      'callbackFramesRequested': 0,
      'callbackFramesServed': 0,
      'callbackSilenceFrames': 0,
      'callbackShortReads': 0,
      'errorCallbackCount': 0,
      'finalCallbackCountersCoherent': false,
      'sinkFullWaitCount': 0,
      'sinkAvailableReadFramesFinal': -1,
      'cancellationPollCount': 0,
      'nativeLastStatus': '',
      'maxFramesPerMix': 0,
      'status': 'FAIL',
      'reason': reason,
      if (details.isNotEmpty) 'details': details,
    };
    return VGAaudioNodeOwnedSinkSmokeReport(
      pass: false,
      status: 'fail',
      marker: failMarkerConstant,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      details: details,
      formatProbeOk: false,
      aaudioRuntimeAvailableOk: false,
      aaudioSymbolsResolvedOk: false,
      aaudioStreamOpenOk: false,
      aaudioConfigOk: false,
      aaudioStartOk: false,
      callbackObservedOk: false,
      mutedOutputOk: false,
      nodeOwnedRouteDiscoveryOk: false,
      nodeOwnsRingTrack0Ok: false,
      nodeOwnsRingTrack1Ok: false,
      track0IngestOk: false,
      track1SyntheticIngestOk: false,
      trackFrameAxisLockstepOk: false,
      jointDispatchGateOk: false,
      graphOutputChecksumOk: false,
      aaudioCallbackAccountingOk: false,
      seekOk: false,
      jointTailFlushOk: false,
      noProviderUnderrunOk: false,
      noGraphSilenceOk: false,
      noRingPushShortfallOk: false,
      zeroNativeSteadyStateAllocationOk: false,
      ownerThreadOk: false,
      lifecycleOk: false,
      canonical: false,
      sampleRate: 0,
      channelCount: 0,
      pcmEncoding: 0,
      commonBudgetFrames: 0,
      expectedFrameCount: 0,
      totalFramesExtracted: 0,
      framesTruncatedBeyondBudget: 0,
      totalFramesAcceptedTrack0: 0,
      totalFramesAcceptedTrack1: 0,
      totalOutputFramesPumped: 0,
      totalMutedFramesPushed: 0,
      postSeekFramesAccepted: 0,
      seekAcceptedFrame: -1,
      seekSkippedDeadline: false,
      track1NonZeroSampleCount: 0,
      decoderBenignFormatChangeCount: 0,
      nativeAcceptedChecksumHexTrack0: '',
      nativeAcceptedChecksumHexTrack1: '',
      nativeOutputDrainChecksumHex: '',
      mutedSinkChecksumHex: '',
      kotlinAcceptedChecksumHexTrack0: '',
      kotlinAcceptedChecksumHexTrack1: '',
      kotlinReferenceMixChecksumHex: '',
      routedSourceId0: '',
      routedSourceId1: '',
      dispatchCount: 0,
      nextDispatchFrame: -1,
      coordinatorSilenceCount: 0,
      providerUnderrunEventsTrack0: 0,
      providerUnderrunEventsTrack1: 0,
      providerFramesZeroFilledTrack0: 0,
      providerFramesZeroFilledTrack1: 0,
      providerForwardSkipFramesTrack0: 0,
      providerForwardSkipFramesTrack1: 0,
      providerRewindRejectsTrack0: 0,
      providerRewindRejectsTrack1: 0,
      deviceApiLevel: 0,
      streamSampleRate: 0,
      streamChannelCount: 0,
      streamFormat: 0,
      aaudioChannelCountSymbolFallback: false,
      callbackInvocationCount: 0,
      callbackFramesRequested: 0,
      callbackFramesServed: 0,
      callbackSilenceFrames: 0,
      callbackShortReads: 0,
      errorCallbackCount: 0,
      finalCallbackCountersCoherent: false,
      sinkFullWaitCount: 0,
      sinkAvailableReadFramesFinal: -1,
      cancellationPollCount: 0,
      nativeLastStatus: '',
      maxFramesPerMix: 0,
      lanes: Map<String, Object?>.unmodifiable(lanes),
      metrics: Map<String, Object?>.unmodifiable(metrics),
      raw: Map<String, String>.unmodifiable(<String, String>{
        'status': 'FAIL',
        'reason': reason,
      }),
      lastError: lastError,
    );
  }

  /// Invokes the Android True-DAG Phase 4 two-source (real decoder + synthetic)
  /// node-owned closed-loop native audio graph pipeline muted native AAudio callback
  /// sink diagnostic proof smoke harness.
  ///
  /// [sourcePath] path to the source audio/video media file (required).
  /// [durationSec] duration in seconds to process (default 0.6, clamped [0.5, 1.0]).
  /// [seekTargetSec] seek target position in seconds (default 0.25).
  /// [sourceRingCapacityFrames] capacity of source rings in frames (default 8192).
  /// [outputRingCapacityFrames] capacity of output ring in frames (default 4096).
  /// [sinkRingCapacityFrames] capacity of callback sink ring in frames (default 65536).
  /// [maxFramesPerMix] max frames per mix dispatch cycle (default 256).
  /// [timeout] optionally bounds the invocation; deadlineMs is passed to Kotlin (default 45s).
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGAaudioNodeOwnedSinkSmokeReport>
  runAndroidDagPhase4AaudioNodeOwnedSinkSmoke({
    required String sourcePath,
    double durationSec = 0.6,
    double seekTargetSec = 0.25,
    int sourceRingCapacityFrames = 8192,
    int outputRingCapacityFrames = 4096,
    int sinkRingCapacityFrames = 65536,
    int maxFramesPerMix = 256,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    final effectiveDeadlineMs = timeout?.inMilliseconds ?? 45000;
    final args = <String, Object?>{
      'sourcePath': sourcePath,
      'durationSec': durationSec,
      'seekTargetSec': seekTargetSec,
      'sourceRingCapacityFrames': sourceRingCapacityFrames,
      'outputRingCapacityFrames': outputRingCapacityFrames,
      'sinkRingCapacityFrames': sinkRingCapacityFrames,
      'maxFramesPerMix': maxFramesPerMix,
      'deadlineMs': effectiveDeadlineMs,
    };
    try {
      final future = ch.invokeMethod<Object?>(methodName, args);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGAaudioNodeOwnedSinkSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return _makeErrorFallbackReport(
        reason: 'timeout',
        details: te.toString(),
        lastError: 'timeout: $te',
      );
    } on PlatformException catch (pe) {
      return _makeErrorFallbackReport(
        reason: 'platform_exception:${pe.code}',
        details: pe.message ?? '',
        lastError: 'platform_exception:${pe.code}:${pe.message}',
      );
    } catch (e) {
      return _makeErrorFallbackReport(
        reason: 'exception:$e',
        details: e.toString(),
        lastError: 'exception:$e',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAaudioNodeOwnedSinkSmokeReport &&
        other.pass == pass &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        other.details == details &&
        other.formatProbeOk == formatProbeOk &&
        other.aaudioRuntimeAvailableOk == aaudioRuntimeAvailableOk &&
        other.aaudioSymbolsResolvedOk == aaudioSymbolsResolvedOk &&
        other.aaudioStreamOpenOk == aaudioStreamOpenOk &&
        other.aaudioConfigOk == aaudioConfigOk &&
        other.aaudioStartOk == aaudioStartOk &&
        other.callbackObservedOk == callbackObservedOk &&
        other.mutedOutputOk == mutedOutputOk &&
        other.nodeOwnedRouteDiscoveryOk == nodeOwnedRouteDiscoveryOk &&
        other.nodeOwnsRingTrack0Ok == nodeOwnsRingTrack0Ok &&
        other.nodeOwnsRingTrack1Ok == nodeOwnsRingTrack1Ok &&
        other.track0IngestOk == track0IngestOk &&
        other.track1SyntheticIngestOk == track1SyntheticIngestOk &&
        other.trackFrameAxisLockstepOk == trackFrameAxisLockstepOk &&
        other.jointDispatchGateOk == jointDispatchGateOk &&
        other.graphOutputChecksumOk == graphOutputChecksumOk &&
        other.aaudioCallbackAccountingOk == aaudioCallbackAccountingOk &&
        other.seekOk == seekOk &&
        other.jointTailFlushOk == jointTailFlushOk &&
        other.noProviderUnderrunOk == noProviderUnderrunOk &&
        other.noGraphSilenceOk == noGraphSilenceOk &&
        other.noRingPushShortfallOk == noRingPushShortfallOk &&
        other.zeroNativeSteadyStateAllocationOk ==
            zeroNativeSteadyStateAllocationOk &&
        other.ownerThreadOk == ownerThreadOk &&
        other.lifecycleOk == lifecycleOk &&
        other.canonical == canonical &&
        other.sampleRate == sampleRate &&
        other.channelCount == channelCount &&
        other.pcmEncoding == pcmEncoding &&
        other.commonBudgetFrames == commonBudgetFrames &&
        other.expectedFrameCount == expectedFrameCount &&
        other.totalFramesExtracted == totalFramesExtracted &&
        other.framesTruncatedBeyondBudget == framesTruncatedBeyondBudget &&
        other.totalFramesAcceptedTrack0 == totalFramesAcceptedTrack0 &&
        other.totalFramesAcceptedTrack1 == totalFramesAcceptedTrack1 &&
        other.totalOutputFramesPumped == totalOutputFramesPumped &&
        other.totalMutedFramesPushed == totalMutedFramesPushed &&
        other.postSeekFramesAccepted == postSeekFramesAccepted &&
        other.seekAcceptedFrame == seekAcceptedFrame &&
        other.seekSkippedDeadline == seekSkippedDeadline &&
        other.track1NonZeroSampleCount == track1NonZeroSampleCount &&
        other.decoderBenignFormatChangeCount ==
            decoderBenignFormatChangeCount &&
        other.nativeAcceptedChecksumHexTrack0 ==
            nativeAcceptedChecksumHexTrack0 &&
        other.nativeAcceptedChecksumHexTrack1 ==
            nativeAcceptedChecksumHexTrack1 &&
        other.nativeOutputDrainChecksumHex == nativeOutputDrainChecksumHex &&
        other.mutedSinkChecksumHex == mutedSinkChecksumHex &&
        other.kotlinAcceptedChecksumHexTrack0 ==
            kotlinAcceptedChecksumHexTrack0 &&
        other.kotlinAcceptedChecksumHexTrack1 ==
            kotlinAcceptedChecksumHexTrack1 &&
        other.kotlinReferenceMixChecksumHex == kotlinReferenceMixChecksumHex &&
        other.routedSourceId0 == routedSourceId0 &&
        other.routedSourceId1 == routedSourceId1 &&
        other.dispatchCount == dispatchCount &&
        other.nextDispatchFrame == nextDispatchFrame &&
        other.coordinatorSilenceCount == coordinatorSilenceCount &&
        other.providerUnderrunEventsTrack0 == providerUnderrunEventsTrack0 &&
        other.providerUnderrunEventsTrack1 == providerUnderrunEventsTrack1 &&
        other.providerFramesZeroFilledTrack0 ==
            providerFramesZeroFilledTrack0 &&
        other.providerFramesZeroFilledTrack1 ==
            providerFramesZeroFilledTrack1 &&
        other.providerForwardSkipFramesTrack0 ==
            providerForwardSkipFramesTrack0 &&
        other.providerForwardSkipFramesTrack1 ==
            providerForwardSkipFramesTrack1 &&
        other.providerRewindRejectsTrack0 == providerRewindRejectsTrack0 &&
        other.providerRewindRejectsTrack1 == providerRewindRejectsTrack1 &&
        other.deviceApiLevel == deviceApiLevel &&
        other.streamSampleRate == streamSampleRate &&
        other.streamChannelCount == streamChannelCount &&
        other.streamFormat == streamFormat &&
        other.aaudioChannelCountSymbolFallback ==
            aaudioChannelCountSymbolFallback &&
        other.callbackInvocationCount == callbackInvocationCount &&
        other.callbackFramesRequested == callbackFramesRequested &&
        other.callbackFramesServed == callbackFramesServed &&
        other.callbackSilenceFrames == callbackSilenceFrames &&
        other.callbackShortReads == callbackShortReads &&
        other.errorCallbackCount == errorCallbackCount &&
        other.finalCallbackCountersCoherent == finalCallbackCountersCoherent &&
        other.sinkFullWaitCount == sinkFullWaitCount &&
        other.sinkAvailableReadFramesFinal == sinkAvailableReadFramesFinal &&
        other.cancellationPollCount == cancellationPollCount &&
        other.nativeLastStatus == nativeLastStatus &&
        other.maxFramesPerMix == maxFramesPerMix &&
        mapEquals(other.lanes, lanes) &&
        mapEquals(other.metrics, metrics) &&
        mapEquals(other.raw, raw) &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hashAll([
    pass,
    status,
    marker,
    proofBoundary,
    failureReason,
    details,
    formatProbeOk,
    aaudioRuntimeAvailableOk,
    aaudioSymbolsResolvedOk,
    aaudioStreamOpenOk,
    aaudioConfigOk,
    aaudioStartOk,
    callbackObservedOk,
    mutedOutputOk,
    nodeOwnedRouteDiscoveryOk,
    nodeOwnsRingTrack0Ok,
    nodeOwnsRingTrack1Ok,
    track0IngestOk,
    track1SyntheticIngestOk,
    trackFrameAxisLockstepOk,
    jointDispatchGateOk,
    graphOutputChecksumOk,
    aaudioCallbackAccountingOk,
    seekOk,
    jointTailFlushOk,
    noProviderUnderrunOk,
    noGraphSilenceOk,
    noRingPushShortfallOk,
    zeroNativeSteadyStateAllocationOk,
    ownerThreadOk,
    lifecycleOk,
    canonical,
    sampleRate,
    channelCount,
    pcmEncoding,
    commonBudgetFrames,
    expectedFrameCount,
    totalFramesExtracted,
    framesTruncatedBeyondBudget,
    totalFramesAcceptedTrack0,
    totalFramesAcceptedTrack1,
    totalOutputFramesPumped,
    totalMutedFramesPushed,
    postSeekFramesAccepted,
    seekAcceptedFrame,
    seekSkippedDeadline,
    track1NonZeroSampleCount,
    decoderBenignFormatChangeCount,
    nativeAcceptedChecksumHexTrack0,
    nativeAcceptedChecksumHexTrack1,
    nativeOutputDrainChecksumHex,
    mutedSinkChecksumHex,
    kotlinAcceptedChecksumHexTrack0,
    kotlinAcceptedChecksumHexTrack1,
    kotlinReferenceMixChecksumHex,
    routedSourceId0,
    routedSourceId1,
    dispatchCount,
    nextDispatchFrame,
    coordinatorSilenceCount,
    providerUnderrunEventsTrack0,
    providerUnderrunEventsTrack1,
    providerFramesZeroFilledTrack0,
    providerFramesZeroFilledTrack1,
    providerForwardSkipFramesTrack0,
    providerForwardSkipFramesTrack1,
    providerRewindRejectsTrack0,
    providerRewindRejectsTrack1,
    deviceApiLevel,
    streamSampleRate,
    streamChannelCount,
    streamFormat,
    aaudioChannelCountSymbolFallback,
    callbackInvocationCount,
    callbackFramesRequested,
    callbackFramesServed,
    callbackSilenceFrames,
    callbackShortReads,
    errorCallbackCount,
    finalCallbackCountersCoherent,
    sinkFullWaitCount,
    sinkAvailableReadFramesFinal,
    cancellationPollCount,
    nativeLastStatus,
    maxFramesPerMix,
    _stableMapHash(lanes),
    _stableMapHash(metrics),
    _stableMapHash(raw),
    lastError,
  ]);

  static int _stableMapHash(Map<dynamic, dynamic> map) {
    final sortedKeys = map.keys.map((k) => k.toString()).toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAaudioNodeOwnedSinkSmokeReport('
      'pass: $pass, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'formatProbeOk: $formatProbeOk, '
      'aaudioRuntimeAvailableOk: $aaudioRuntimeAvailableOk, '
      'aaudioSymbolsResolvedOk: $aaudioSymbolsResolvedOk, '
      'aaudioStreamOpenOk: $aaudioStreamOpenOk, '
      'aaudioConfigOk: $aaudioConfigOk, '
      'aaudioStartOk: $aaudioStartOk, '
      'callbackObservedOk: $callbackObservedOk, '
      'mutedOutputOk: $mutedOutputOk, '
      'nodeOwnedRouteDiscoveryOk: $nodeOwnedRouteDiscoveryOk, '
      'nodeOwnsRingTrack0Ok: $nodeOwnsRingTrack0Ok, '
      'nodeOwnsRingTrack1Ok: $nodeOwnsRingTrack1Ok, '
      'track0IngestOk: $track0IngestOk, '
      'track1SyntheticIngestOk: $track1SyntheticIngestOk, '
      'trackFrameAxisLockstepOk: $trackFrameAxisLockstepOk, '
      'jointDispatchGateOk: $jointDispatchGateOk, '
      'graphOutputChecksumOk: $graphOutputChecksumOk, '
      'aaudioCallbackAccountingOk: $aaudioCallbackAccountingOk, '
      'seekOk: $seekOk, '
      'jointTailFlushOk: $jointTailFlushOk, '
      'noProviderUnderrunOk: $noProviderUnderrunOk, '
      'noGraphSilenceOk: $noGraphSilenceOk, '
      'noRingPushShortfallOk: $noRingPushShortfallOk, '
      'zeroNativeSteadyStateAllocationOk: $zeroNativeSteadyStateAllocationOk, '
      'ownerThreadOk: $ownerThreadOk, '
      'lifecycleOk: $lifecycleOk, '
      'canonical: $canonical, '
      'sampleRate: $sampleRate, '
      'channelCount: $channelCount, '
      'pcmEncoding: $pcmEncoding, '
      'commonBudgetFrames: $commonBudgetFrames, '
      'expectedFrameCount: $expectedFrameCount, '
      'totalFramesExtracted: $totalFramesExtracted, '
      'framesTruncatedBeyondBudget: $framesTruncatedBeyondBudget, '
      'totalFramesAcceptedTrack0: $totalFramesAcceptedTrack0, '
      'totalFramesAcceptedTrack1: $totalFramesAcceptedTrack1, '
      'totalOutputFramesPumped: $totalOutputFramesPumped, '
      'totalMutedFramesPushed: $totalMutedFramesPushed, '
      'postSeekFramesAccepted: $postSeekFramesAccepted, '
      'seekAcceptedFrame: $seekAcceptedFrame, '
      'seekSkippedDeadline: $seekSkippedDeadline, '
      'track1NonZeroSampleCount: $track1NonZeroSampleCount, '
      'decoderBenignFormatChangeCount: $decoderBenignFormatChangeCount, '
      'nativeAcceptedChecksumHexTrack0: $nativeAcceptedChecksumHexTrack0, '
      'nativeAcceptedChecksumHexTrack1: $nativeAcceptedChecksumHexTrack1, '
      'nativeOutputDrainChecksumHex: $nativeOutputDrainChecksumHex, '
      'mutedSinkChecksumHex: $mutedSinkChecksumHex, '
      'kotlinAcceptedChecksumHexTrack0: $kotlinAcceptedChecksumHexTrack0, '
      'kotlinAcceptedChecksumHexTrack1: $kotlinAcceptedChecksumHexTrack1, '
      'kotlinReferenceMixChecksumHex: $kotlinReferenceMixChecksumHex, '
      'routedSourceId0: $routedSourceId0, '
      'routedSourceId1: $routedSourceId1, '
      'dispatchCount: $dispatchCount, '
      'nextDispatchFrame: $nextDispatchFrame, '
      'coordinatorSilenceCount: $coordinatorSilenceCount, '
      'providerUnderrunEventsTrack0: $providerUnderrunEventsTrack0, '
      'providerUnderrunEventsTrack1: $providerUnderrunEventsTrack1, '
      'providerFramesZeroFilledTrack0: $providerFramesZeroFilledTrack0, '
      'providerFramesZeroFilledTrack1: $providerFramesZeroFilledTrack1, '
      'providerForwardSkipFramesTrack0: $providerForwardSkipFramesTrack0, '
      'providerForwardSkipFramesTrack1: $providerForwardSkipFramesTrack1, '
      'providerRewindRejectsTrack0: $providerRewindRejectsTrack0, '
      'providerRewindRejectsTrack1: $providerRewindRejectsTrack1, '
      'deviceApiLevel: $deviceApiLevel, '
      'streamSampleRate: $streamSampleRate, '
      'streamChannelCount: $streamChannelCount, '
      'streamFormat: $streamFormat, '
      'aaudioChannelCountSymbolFallback: $aaudioChannelCountSymbolFallback, '
      'callbackInvocationCount: $callbackInvocationCount, '
      'callbackFramesRequested: $callbackFramesRequested, '
      'callbackFramesServed: $callbackFramesServed, '
      'callbackSilenceFrames: $callbackSilenceFrames, '
      'callbackShortReads: $callbackShortReads, '
      'errorCallbackCount: $errorCallbackCount, '
      'finalCallbackCountersCoherent: $finalCallbackCountersCoherent, '
      'sinkFullWaitCount: $sinkFullWaitCount, '
      'sinkAvailableReadFramesFinal: $sinkAvailableReadFramesFinal, '
      'cancellationPollCount: $cancellationPollCount, '
      'nativeLastStatus: $nativeLastStatus, '
      'maxFramesPerMix: $maxFramesPerMix, '
      'lanes: $lanes, '
      'metrics: $metrics, '
      'raw: $raw, '
      'lastError: $lastError)';
}
