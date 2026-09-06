// vg_timeline_overlay_export_smoke.dart
// vanguard_media_engine -- P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A / P5-GLES-EXPORT-TRANSITION-OVERLAYS:
// Android production `exportTimeline` static sticker, text, and emoji overlay smoke proof model.
//
// Pure Dart typed model + lane runner over the REAL production
// `exportTimeline` MethodChannel route (the same route
// VanguardTimelineExporter.exportDraft invokes). There is no parallel
// diagnostic native path: every lane builds an `exportTimeline` argument map
// (draft + request keys) and reads the production result map back
// (`renderBackend`, `path`, `durationSeconds`, `overlayCount`).
//
// Contract:
//   - Proof boundary: `production_exportTimeline_vulkan_overlay_and_forced_gles_transition_overlay_route_a`
//     (covering production Vulkan overlay export and forced GLES transition-overlay route);
//   - Pass marker: `ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_PASS`;
//   - Fail marker: `ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_FAIL`;
//   - Structured JSON prefix: `ANDROID_TIMELINE_OVERLAY_EXPORT_JSON:`;
//   - Structured lane prefix: `ANDROID_TIMELINE_OVERLAY_EXPORT_LANE:`;
//   - Claims production routing/fail-closed behavior on Android for static sticker,
//     text, and emoji overlays in Route-A (P5-OVERLAYS-TEXT-PRODUCTION-EXPORT,
//     P5-OVERLAYS-EMOJI-PRODUCTION-EXPORT), including
//     dynamic keyframed spatial transforms (P5-OVERLAYS-DYNAMIC-KEYFRAME-EXPORT),
//     overlay compositing on all supported Vulkan transition overlap frames
//     (dissolve, crossfade, slideLeft, slideRight, slideUp, slideDown,
//     wipeLeft, wipeRight, wipeUp, wipeDown) under P5-OVERLAYS-ALL-SUPPORTED-TRANSITION-DIRECTIONS-PROOF
//     (closing unproved transition directions/types under P5-OVERLAYS-TRANS),
//     overlays alongside clip-level Beauty V2 on both transition-overlap frames
//     (P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY) and solo frames
//     (P5-OVERLAYS-BEAUTY-SOLO), forced GLES transition-overlay export
//     (P5-GLES-EXPORT-TRANSITION-OVERLAYS), forced GLES hard-cut
//     overlay+Beauty V2 solo export (P5-GLES-EXPORT-BEAUTY-OVERLAYS), and
//     forced GLES all-video transition scopes combining clip-level Beauty V2
//     and timeline overlays together (P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS);
//   - Unsupported transition types (e.g. fade) fail closed elsewhere because
//     fade-through-black semantics are unsupported;
//   - Strict non-claims: GLES overlay export outside supported forced
//     transition-overlap, forced hard-cut beauty-solo, and forced
//     all-video zero-rotation transition+overlay+Beauty scopes
//     (reversed, still-image+Beauty, colorMatrix Beauty, and hard-cut rotated
//     Beauty in GLES remain excluded/fail closed; existing rotated transition
//     support is separate), realtime playback overlay compositing,
//     app/editor/ConnectsApp/product/iOS/streaming/cache, fleet coverage beyond
//     SM-A566B (tested device), or pixel-quality typography/emoji glyph
//     guarantees;
//   - Validates success lanes: `success == true`, output file exists,
//     `renderBackend == expectedRenderBackend` (`'vulkan'` by default or `'gles'` for forced GLES lanes),
//     duration within 0.25s tolerance (transition-aware:
//     clip trim-window sum minus non-hard-cut transition overlap durations, unaffected
//     by overlay intervals), `overlayCount`/`transitionCount` matching expectation when
//     present, `renderedOverlayFrameCount` meeting a lane's minimum when specified
//     (proves overlay compositing during transition overlap frames), and
//     `beautyClipCount`/`beautyFrameCount` matching a lane's expectation (an exact
//     match on clip count, zero by default; a lower bound on frame count for a lane
//     that expects clip-level Beauty V2);
//   - Fail-closed lanes validate PlatformException code and message substrings;
//   - Whole report requires at least one positive lane and all lanes pass.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical proof boundary string.
const String overlayProofBoundary =
    'production_exportTimeline_vulkan_overlay_and_forced_gles_transition_overlay_route_a';

/// Canonical PASS marker.
const String overlayPassMarker =
    'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_PASS';

/// Canonical FAIL marker.
const String overlayFailMarker =
    'ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_FAIL';

/// Structured JSON log prefix.
const String overlayJsonPrefix = 'ANDROID_TIMELINE_OVERLAY_EXPORT_JSON:';

/// Structured lane log prefix.
const String overlayLanePrefix = 'ANDROID_TIMELINE_OVERLAY_EXPORT_LANE:';

/// The production MethodChannel error code for an unsupported feature.
const String unsupportedExportFeatureCode = 'UNSUPPORTED_EXPORT_FEATURE';

/// The production MethodChannel error code for invalid arguments.
const String invalidArgCode = 'INVALID_ARG';

/// The production MethodChannel error code for an unreadable file asset.
const String fileUnreadableCode = 'FILE_UNREADABLE';

/// Message-substring token identifying text overlay content in Route-A.
const String textOverlayToken = 'text';

/// Fail-closed token for unsupported emoji overlays in Route-A.
const String emojiOverlayToken = 'emoji';

/// Fail-closed token for unsupported animated keyframe overlays in Route-A.
const String keyframesToken = 'keyframe';

/// Fail-closed token for unreadable sticker assets.
const String unreadableAssetToken = 'asset';

/// Default lane IDs for the full Route-A static sticker, text, and emoji overlay smoke suite,
/// including forced-GLES transition+overlay proof lanes (P5-GLES-EXPORT-TRANSITION-OVERLAYS)
/// and the forced-GLES transition+overlay+Beauty V2 combined proof lane
/// (P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS).
const List<String> defaultOverlaySmokeLaneIds = <String>[
  'single_clip_static_sticker_success',
  'multi_layer_z_order_success',
  'time_interval_gating_success',
  'hard_cut_multiclip_success',
  'single_clip_dynamic_keyframe_success',
  'text_overlay_success',
  'emoji_overlay_success',
  'fail_closed_malformed_keyframes',
  'overlays_with_transition_dissolve_success',
  'overlays_with_transition_slide_left_success',
  'overlays_with_transition_wipe_right_success',
  'overlays_with_transition_crossfade_success',
  'overlays_with_transition_slide_right_success',
  'overlays_with_transition_slide_up_success',
  'overlays_with_transition_slide_down_success',
  'overlays_with_transition_wipe_left_success',
  'overlays_with_transition_wipe_up_success',
  'overlays_with_transition_wipe_down_success',
  'overlays_with_beauty_transition_overlap_success',
  'overlays_with_beauty_solo_success',
  'fail_closed_unreadable_asset',
  'forced_gles_overlays_with_transition_dissolve_success',
  'forced_gles_overlays_with_transition_wipe_right_success',
  'forced_gles_overlays_with_beauty_solo_success',
  'forced_gles_overlays_with_beauty_transition_success',
];

/// One clip of a smoke draft (wire shape of VGClipDescriptor.toMap()).
@immutable
class VGTimelineOverlayExportSmokeClip {
  const VGTimelineOverlayExportSmokeClip({
    required this.id,
    required this.sourcePath,
    required this.trimStartSeconds,
    required this.trimEndSeconds,
    this.mediaKind = 'video',
    this.beautyIntensity,
  });

  final String id;
  final String sourcePath;
  final double trimStartSeconds;
  final double trimEndSeconds;
  final String mediaKind;

  /// Optional beauty intensity for negative testing of overlays + beauty.
  final Object? beautyIntensity;

  /// Trim window length in seconds (never negative).
  double get durationSeconds =>
      (trimEndSeconds - trimStartSeconds).clamp(0.0, double.infinity);

  /// True when this clip requests beauty smoothing.
  bool get hasBeauty => beautyIntensity != null;

  Map<String, Object?> toMap() {
    final map = <String, Object?>{
      'id': id,
      'sourcePath': sourcePath,
      'mediaKind': mediaKind,
      'startTimeSeconds': 0.0,
      'durationSeconds': durationSeconds,
      'trimStartSeconds': trimStartSeconds,
      'trimEndSeconds': trimEndSeconds,
      'speed': 1.0,
    };
    if (beautyIntensity != null) {
      map['beautyIntensity'] = beautyIntensity;
    }
    return map;
  }
}

/// Optional transition of a smoke draft (wire shape of VGTransitionDescriptor.toMap()).
@immutable
class VGTimelineOverlayExportSmokeTransition {
  const VGTimelineOverlayExportSmokeTransition({
    required this.id,
    required this.type,
    required this.durationSeconds,
    required this.fromClipId,
    required this.toClipId,
  });

  final String id;
  final String type;
  final double durationSeconds;
  final String fromClipId;
  final String toClipId;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'type': type,
    'durationSeconds': durationSeconds,
    'fromClipId': fromClipId,
    'toClipId': toClipId,
    'curve': 'linear',
  };
}

/// Static sticker overlay model for Route-A production export smoke testing.
///
/// Wire shape matches VGOverlayDescriptor.toMap().
/// Keyframes must be absent by default.
@immutable
class VGTimelineOverlayExportSmokeOverlay {
  const VGTimelineOverlayExportSmokeOverlay({
    required this.id,
    this.assetPath,
    this.startTimeSeconds = 0.0,
    this.durationSeconds = 0.0,
    this.translationX = 0.0,
    this.translationY = 0.0,
    this.width = 0.0,
    this.height = 0.0,
    this.rotation = 0.0,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.zIndex = 0,
    this.type = 'sticker',
    this.textContent,
    this.keyframes,
  });

  final String id;
  final String? assetPath;
  final double startTimeSeconds;
  final double durationSeconds;
  final double translationX;
  final double translationY;
  final double width;
  final double height;
  final double rotation;
  final double scale;
  final double opacity;
  final int zIndex;
  final String type;
  final String? textContent;

  /// Keyframe track data (absent by default in Route-A static sticker smoke).
  final Object? keyframes;

  /// Returns true when [pts] falls within this overlay's active time range
  /// [startTimeSeconds, startTimeSeconds + durationSeconds).
  bool isActiveAt(double pts) {
    if (pts < 0.0) return false;
    if (durationSeconds <= 0.0) return false;
    return pts >= startTimeSeconds &&
        pts < (startTimeSeconds + durationSeconds);
  }

  /// Serialises this overlay to a JSON-compatible map matching the wire contract.
  /// Keyframes are omitted when null (the default for Route-A static stickers).
  Map<String, Object?> toMap() {
    final map = <String, Object?>{
      'id': id,
      'type': type,
      'startTimeSeconds': startTimeSeconds,
      'durationSeconds': durationSeconds,
      'translationX': translationX,
      'translationY': translationY,
      'width': width,
      'height': height,
      'rotation': rotation,
      'scale': scale,
      'opacity': opacity,
      'zIndex': zIndex,
    };
    if (assetPath != null) {
      map['assetPath'] = assetPath;
    }
    if (textContent != null) {
      map['textContent'] = textContent;
    }
    if (keyframes != null) {
      map['keyframes'] = keyframes;
    }
    return map;
  }

  /// Deserialises from a wire map produced by [toMap].
  static VGTimelineOverlayExportSmokeOverlay? fromMap(
    Map<Object?, Object?>? map,
  ) {
    if (map == null) return null;
    return VGTimelineOverlayExportSmokeOverlay(
      id: map['id'] as String? ?? '',
      assetPath: map['assetPath'] as String?,
      startTimeSeconds: (map['startTimeSeconds'] as num?)?.toDouble() ?? 0.0,
      durationSeconds: (map['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      translationX: (map['translationX'] as num?)?.toDouble() ?? 0.0,
      translationY: (map['translationY'] as num?)?.toDouble() ?? 0.0,
      width: (map['width'] as num?)?.toDouble() ?? 0.0,
      height: (map['height'] as num?)?.toDouble() ?? 0.0,
      rotation: (map['rotation'] as num?)?.toDouble() ?? 0.0,
      scale: (map['scale'] as num?)?.toDouble() ?? 1.0,
      opacity: (map['opacity'] as num?)?.toDouble() ?? 1.0,
      zIndex: (map['zIndex'] as num?)?.toInt() ?? 0,
      type: map['type'] as String? ?? 'sticker',
      textContent: map['textContent'] as String?,
      keyframes: map['keyframes'],
    );
  }
}

/// What a lane expects from the production `exportTimeline` route.
@immutable
class VGTimelineOverlayExportSmokeExpectation {
  const VGTimelineOverlayExportSmokeExpectation.success({
    this.expectedOverlayCount,
    this.expectedTransitionCount,
    this.expectedRenderedOverlayFrameCount,
    this.expectedBeautyClipCount = 0,
    this.expectedBeautyFrameCountMin = 0,
  }) : expectsSuccess = true,
       errorCode = null,
       messageContains = null;

  const VGTimelineOverlayExportSmokeExpectation.failClosed({
    required String this.errorCode,
    this.messageContains,
  }) : expectsSuccess = false,
       expectedOverlayCount = null,
       expectedTransitionCount = null,
       expectedRenderedOverlayFrameCount = null,
       expectedBeautyClipCount = 0,
       expectedBeautyFrameCountMin = 0;

  /// True when the lane must produce a successful export output file.
  final bool expectsSuccess;

  /// Optional override for expected overlayCount. If null on success,
  /// the request derives it from the number of overlays in the request.
  final int? expectedOverlayCount;

  /// Optional override for expected transitionCount. If null on success,
  /// the request derives it from the number of non-hard-cut transitions in
  /// the request.
  final int? expectedTransitionCount;

  /// Minimum acceptable `renderedOverlayFrameCount` for a positive lane that
  /// proves static sticker overlays render during Vulkan transition overlap
  /// frames (P5-OVERLAYS-TRANSITION-COMP-N3). Null means no lower-bound
  /// check -- most lanes carry no transition and do not need this proof.
  final int? expectedRenderedOverlayFrameCount;

  /// Expected clip-level Beauty V2 clip count for a success lane -- an exact
  /// match check against the production `beautyClipCount` result field.
  /// Defaults to 0 so existing overlay-only success lanes still require
  /// zero beauty clips (proving beauty never silently activates on a lane
  /// that never requested it).
  final int expectedBeautyClipCount;

  /// Minimum acceptable production `beautyFrameCount` for a success lane
  /// that expects [expectedBeautyClipCount] > 0 -- a lower-bound check, like
  /// [expectedRenderedOverlayFrameCount], since the exact rendered beauty
  /// frame count can vary with decoder/device timing. When
  /// [expectedBeautyClipCount] is 0, an exact zero check is used instead and
  /// this field is ignored. Defaults to 0.
  final int expectedBeautyFrameCountMin;

  /// Required PlatformException code for a fail-closed lane.
  final String? errorCode;

  /// Optional substring the fail-closed message must contain.
  final String? messageContains;
}

/// One lane: a complete `exportTimeline` request plus its expectation.
@immutable
class VGTimelineOverlayExportSmokeRequest {
  const VGTimelineOverlayExportSmokeRequest({
    required this.laneId,
    required this.clips,
    required this.outputPath,
    required this.expectation,
    this.overlays = const <VGTimelineOverlayExportSmokeOverlay>[],
    this.transitions = const <VGTimelineOverlayExportSmokeTransition>[],
    this.expectedRenderBackend = 'vulkan',
    this.debugForceRenderBackend,
    this.canvasWidth = 720,
    this.canvasHeight = 1280,
    this.fps = 30,
    this.bitrateBps = 4000000,
  });

  final String laneId;
  final List<VGTimelineOverlayExportSmokeClip> clips;
  final List<VGTimelineOverlayExportSmokeOverlay> overlays;
  final List<VGTimelineOverlayExportSmokeTransition> transitions;
  final String outputPath;
  final VGTimelineOverlayExportSmokeExpectation expectation;

  /// The `renderBackend` a successful lane must report. Defaults to `'vulkan'`,
  /// preserving every existing lane's behavior; a GLES proof lane sets this to
  /// `'gles'` alongside [debugForceRenderBackend].
  final String expectedRenderBackend;

  /// Optional top-level `debugForceRenderBackend` export argument. Emitted by
  /// [toExportTimelineArguments] only when non-null and non-empty, and always as a
  /// top-level argument -- never inside `draft`.
  final String? debugForceRenderBackend;

  final int canvasWidth;
  final int canvasHeight;
  final int fps;
  final int bitrateBps;

  /// Expected duration is the clip trim-window sum minus the overlap
  /// durations of any non-hard-cut transitions -- hard-cut/`none` transition
  /// entries subtract nothing. Mirrors
  /// AndroidTimelineTransitionDescriptor.timelineDurationSeconds. Overlay
  /// intervals never affect timeline duration.
  double get expectedDurationSeconds {
    final clipSeconds = clips.fold<double>(
      0.0,
      (sum, c) => sum + c.durationSeconds,
    );
    final overlapSeconds = transitions
        .where((t) => t.type != 'none')
        .fold<double>(0.0, (sum, t) => sum + t.durationSeconds);
    return (clipSeconds - overlapSeconds).clamp(0.0, double.infinity);
  }

  /// Expected overlay count: expectation override or overlays list length on success.
  int? get expectedOverlayCount =>
      expectation.expectedOverlayCount ??
      (expectation.expectsSuccess ? overlays.length : null);

  /// Expected transition count: expectation override or the number of
  /// non-hard-cut transitions in the request on success -- mirrors the
  /// production `transitionCount` result field, which already excludes
  /// hard-cut (`none`) entries (AndroidTimelineTransitionDescriptor.parseList).
  int? get expectedTransitionCount =>
      expectation.expectedTransitionCount ??
      (expectation.expectsSuccess
          ? transitions.where((t) => t.type != 'none').length
          : null);

  /// Helper: returns overlays sorted by [zIndex] ascending, breaking ties by [id] ascending.
  ///
  /// The request itself preserves caller order in [toExportTimelineArguments].
  List<VGTimelineOverlayExportSmokeOverlay> get sortedOverlays {
    final sorted = List<VGTimelineOverlayExportSmokeOverlay>.from(overlays);
    sorted.sort((a, b) {
      final cmp = a.zIndex.compareTo(b.zIndex);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    return sorted;
  }

  /// The exact `exportTimeline` argument map matching the production shape.
  /// Overlays remain in caller order. Transitions are empty by default.
  Map<String, Object?> toExportTimelineArguments() => <String, Object?>{
    'draft': <String, Object?>{
      'id': 'vg-overlay-export-smoke-$laneId',
      'clips': clips.map((c) => c.toMap()).toList(),
      'transitions': transitions.map((t) => t.toMap()).toList(),
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'fps': fps,
      'overlays': overlays.map((o) => o.toMap()).toList(),
    },
    'outputPath': outputPath,
    'bitrateBps': bitrateBps,
    'width': canvasWidth,
    'height': canvasHeight,
    'fps': fps,
    if (debugForceRenderBackend != null && debugForceRenderBackend!.isNotEmpty)
      'debugForceRenderBackend': debugForceRenderBackend,
  };
}

/// Per-lane verdict.
@immutable
class VGTimelineOverlayExportSmokeLaneReport {
  const VGTimelineOverlayExportSmokeLaneReport({
    required this.laneId,
    required this.pass,
    required this.status,
    required this.failureReason,
    required this.expectedSuccess,
    required this.expectedDurationSeconds,
    this.renderBackend,
    this.outputPath,
    this.outputExists = false,
    this.durationSeconds,
    this.overlayCount,
    this.expectedOverlayCount,
    this.transitionCount,
    this.expectedTransitionCount,
    this.renderedOverlayFrameCount,
    this.expectedRenderedOverlayFrameCount,
    this.beautyClipCount,
    this.beautyFrameCount,
    this.expectedBeautyClipCount,
    this.expectedBeautyFrameCountMin,
    this.errorCode,
    this.errorMessage,
  });

  final String laneId;
  final bool pass;

  /// 'PASS' | 'FAIL'.
  final String status;
  final String failureReason;
  final bool expectedSuccess;
  final double expectedDurationSeconds;
  final String? renderBackend;
  final String? outputPath;
  final bool outputExists;
  final double? durationSeconds;
  final int? overlayCount;
  final int? expectedOverlayCount;
  final int? transitionCount;
  final int? expectedTransitionCount;

  /// Count of rendered frames (solo or transition-overlap) that composited
  /// at least one active overlay -- production `renderedOverlayFrameCount`
  /// result field (P5-OVERLAYS-TRANSITION-COMP-N3).
  final int? renderedOverlayFrameCount;
  final int? expectedRenderedOverlayFrameCount;
  final int? beautyClipCount;
  final int? beautyFrameCount;

  /// Expected `beautyClipCount` for this lane -- mirrors
  /// [VGTimelineOverlayExportSmokeExpectation.expectedBeautyClipCount].
  final int? expectedBeautyClipCount;

  /// Expected minimum `beautyFrameCount` for this lane -- mirrors
  /// [VGTimelineOverlayExportSmokeExpectation.expectedBeautyFrameCountMin].
  final int? expectedBeautyFrameCountMin;
  final String? errorCode;
  final String? errorMessage;

  /// Signed measured-minus-expected duration delta, or null without output.
  double? get durationDeltaSeconds {
    final d = durationSeconds;
    if (d == null) return null;
    return d - expectedDurationSeconds;
  }

  /// Evaluates a production success map against [request]. [outputExists]
  /// is the caller's filesystem check of the returned path.
  factory VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
    VGTimelineOverlayExportSmokeRequest request,
    Map<Object?, Object?>? result, {
    required bool outputExists,
  }) {
    final expectedDuration = request.expectedDurationSeconds;
    final expectedOverlays = request.expectedOverlayCount;
    final expectedTransitions = request.expectedTransitionCount;
    final expectedRenderedOverlayFrames =
        request.expectation.expectedRenderedOverlayFrameCount;
    final expectedBeautyClipCount = request.expectation.expectedBeautyClipCount;
    final expectedBeautyFrameCountMin =
        request.expectation.expectedBeautyFrameCountMin;

    if (result == null) {
      return VGTimelineOverlayExportSmokeLaneReport(
        laneId: request.laneId,
        pass: false,
        status: 'FAIL',
        failureReason: 'native_returned_null_result',
        expectedSuccess: request.expectation.expectsSuccess,
        expectedDurationSeconds: expectedDuration,
        expectedOverlayCount: expectedOverlays,
        expectedTransitionCount: expectedTransitions,
        expectedRenderedOverlayFrameCount: expectedRenderedOverlayFrames,
        expectedBeautyClipCount: expectedBeautyClipCount,
        expectedBeautyFrameCountMin: expectedBeautyFrameCountMin,
      );
    }
    final success = result['success'] == true;
    final path = result['path'] as String?;
    final duration = (result['durationSeconds'] as num?)?.toDouble();
    final backend = result['renderBackend'] as String?;
    final overlayCount = (result['overlayCount'] as num?)?.toInt();
    final transitionCount = (result['transitionCount'] as num?)?.toInt();
    final renderedOverlayFrameCount =
        (result['renderedOverlayFrameCount'] as num?)?.toInt();
    final beautyClipCount = (result['beautyClipCount'] as num?)?.toInt();
    final beautyFrameCount = (result['beautyFrameCount'] as num?)?.toInt();

    String? failure;
    if (!request.expectation.expectsSuccess) {
      failure = 'expected_fail_closed_but_export_succeeded';
    } else if (!success) {
      failure = 'result_success_false';
    } else if (path == null || path.isEmpty) {
      failure = 'result_path_missing';
    } else if (!outputExists) {
      failure = 'output_file_missing';
    } else if (backend != request.expectedRenderBackend) {
      failure =
          'render_backend_not_${request.expectedRenderBackend}:${backend ?? 'null'}';
    } else if (duration == null) {
      failure = 'result_duration_missing';
    } else if ((duration - expectedDuration).abs() >
        VGTimelineOverlayExportSmokeReport.durationToleranceSeconds) {
      failure =
          'duration_mismatch:measured=${duration.toStringAsFixed(3)}:'
          'expected=${expectedDuration.toStringAsFixed(3)}';
    } else if (overlayCount != null &&
        expectedOverlays != null &&
        overlayCount != expectedOverlays) {
      failure =
          'overlay_count_mismatch:reported=$overlayCount:'
          'expected=$expectedOverlays';
    } else if (request.expectation.expectedOverlayCount != null &&
        overlayCount == null) {
      failure = 'result_overlay_count_missing';
    } else if (transitionCount != null &&
        expectedTransitions != null &&
        transitionCount != expectedTransitions) {
      failure =
          'transition_count_mismatch:reported=$transitionCount:'
          'expected=$expectedTransitions';
    } else if (expectedTransitions != null && transitionCount == null) {
      failure = 'result_transition_count_missing';
    } else if (expectedRenderedOverlayFrames != null &&
        (renderedOverlayFrameCount == null ||
            renderedOverlayFrameCount < expectedRenderedOverlayFrames)) {
      failure =
          'rendered_overlay_frame_count_too_low:reported=${renderedOverlayFrameCount ?? 'null'}:'
          'expectedAtLeast=$expectedRenderedOverlayFrames';
    } else if (expectedBeautyClipCount > 0 && beautyClipCount == null) {
      failure = 'result_beauty_clip_count_missing';
    } else if (beautyClipCount != null &&
        beautyClipCount != expectedBeautyClipCount) {
      failure =
          'beauty_clip_count_mismatch:reported=$beautyClipCount:'
          'expected=$expectedBeautyClipCount';
    } else if (expectedBeautyClipCount > 0 && beautyFrameCount == null) {
      failure = 'result_beauty_frame_count_missing';
    } else if (beautyFrameCount != null &&
        expectedBeautyClipCount == 0 &&
        beautyFrameCount != 0) {
      failure = 'beauty_frame_count_not_zero:reported=$beautyFrameCount';
    } else if (beautyFrameCount != null &&
        expectedBeautyClipCount > 0 &&
        beautyFrameCount < expectedBeautyFrameCountMin) {
      failure =
          'beauty_frame_count_too_low:reported=$beautyFrameCount:'
          'expectedAtLeast=$expectedBeautyFrameCountMin';
    }

    final pass = failure == null;
    return VGTimelineOverlayExportSmokeLaneReport(
      laneId: request.laneId,
      pass: pass,
      status: pass ? 'PASS' : 'FAIL',
      failureReason: failure ?? '',
      expectedSuccess: request.expectation.expectsSuccess,
      expectedDurationSeconds: expectedDuration,
      renderBackend: backend,
      outputPath: path,
      outputExists: outputExists,
      durationSeconds: duration,
      overlayCount: overlayCount,
      expectedOverlayCount: expectedOverlays,
      transitionCount: transitionCount,
      expectedTransitionCount: expectedTransitions,
      renderedOverlayFrameCount: renderedOverlayFrameCount,
      expectedRenderedOverlayFrameCount: expectedRenderedOverlayFrames,
      beautyClipCount: beautyClipCount,
      beautyFrameCount: beautyFrameCount,
      expectedBeautyClipCount: expectedBeautyClipCount,
      expectedBeautyFrameCountMin: expectedBeautyFrameCountMin,
    );
  }

  /// Evaluates a production PlatformException against [request]'s
  /// fail-closed expectation.
  factory VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
    VGTimelineOverlayExportSmokeRequest request,
    PlatformException exception,
  ) {
    final expectation = request.expectation;
    final message = exception.message ?? '';
    String? failure;
    if (expectation.expectsSuccess) {
      failure = 'unexpected_platform_exception:${exception.code}';
    } else if (exception.code != expectation.errorCode) {
      failure =
          'error_code_mismatch:got=${exception.code}:'
          'expected=${expectation.errorCode}';
    } else if (expectation.messageContains != null &&
        !message.contains(expectation.messageContains!)) {
      failure = 'error_message_missing_token:${expectation.messageContains}';
    }
    final pass = failure == null;
    return VGTimelineOverlayExportSmokeLaneReport(
      laneId: request.laneId,
      pass: pass,
      status: pass ? 'PASS' : 'FAIL',
      failureReason: failure ?? '',
      expectedSuccess: expectation.expectsSuccess,
      expectedDurationSeconds: request.expectedDurationSeconds,
      expectedOverlayCount: request.expectedOverlayCount,
      expectedTransitionCount: request.expectedTransitionCount,
      expectedRenderedOverlayFrameCount:
          expectation.expectedRenderedOverlayFrameCount,
      expectedBeautyClipCount: expectation.expectedBeautyClipCount,
      expectedBeautyFrameCountMin: expectation.expectedBeautyFrameCountMin,
      errorCode: exception.code,
      errorMessage: exception.message,
    );
  }

  /// A lane that encountered an unexpected exception.
  factory VGTimelineOverlayExportSmokeLaneReport.harnessException(
    VGTimelineOverlayExportSmokeRequest request,
    Object error,
  ) => VGTimelineOverlayExportSmokeLaneReport(
    laneId: request.laneId,
    pass: false,
    status: 'FAIL',
    failureReason: 'harness_exception:$error',
    expectedSuccess: request.expectation.expectsSuccess,
    expectedDurationSeconds: request.expectedDurationSeconds,
    expectedOverlayCount: request.expectedOverlayCount,
    expectedTransitionCount: request.expectedTransitionCount,
    expectedRenderedOverlayFrameCount:
        request.expectation.expectedRenderedOverlayFrameCount,
    expectedBeautyClipCount: request.expectation.expectedBeautyClipCount,
    expectedBeautyFrameCountMin:
        request.expectation.expectedBeautyFrameCountMin,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'laneId': laneId,
    'pass': pass,
    'status': status,
    'failureReason': failureReason,
    'expectedSuccess': expectedSuccess,
    'expectedDurationSeconds': expectedDurationSeconds,
    'renderBackend': renderBackend,
    'outputPath': outputPath,
    'outputExists': outputExists,
    'durationSeconds': durationSeconds,
    'durationDeltaSeconds': durationDeltaSeconds,
    'overlayCount': overlayCount,
    'expectedOverlayCount': expectedOverlayCount,
    'transitionCount': transitionCount,
    'expectedTransitionCount': expectedTransitionCount,
    'renderedOverlayFrameCount': renderedOverlayFrameCount,
    'expectedRenderedOverlayFrameCount': expectedRenderedOverlayFrameCount,
    'beautyClipCount': beautyClipCount,
    'beautyFrameCount': beautyFrameCount,
    'expectedBeautyClipCount': expectedBeautyClipCount,
    'expectedBeautyFrameCountMin': expectedBeautyFrameCountMin,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  /// Parses a map produced by [toMap].
  static VGTimelineOverlayExportSmokeLaneReport fromMap(
    Map<Object?, Object?> map,
  ) {
    return VGTimelineOverlayExportSmokeLaneReport(
      laneId: map['laneId'] as String? ?? '',
      pass: map['pass'] == true,
      status: map['status'] as String? ?? 'FAIL',
      failureReason: map['failureReason'] as String? ?? '',
      expectedSuccess: map['expectedSuccess'] == true,
      expectedDurationSeconds:
          (map['expectedDurationSeconds'] as num?)?.toDouble() ?? 0.0,
      renderBackend: map['renderBackend'] as String?,
      outputPath: map['outputPath'] as String?,
      outputExists: map['outputExists'] == true,
      durationSeconds: (map['durationSeconds'] as num?)?.toDouble(),
      overlayCount: (map['overlayCount'] as num?)?.toInt(),
      expectedOverlayCount: (map['expectedOverlayCount'] as num?)?.toInt(),
      transitionCount: (map['transitionCount'] as num?)?.toInt(),
      expectedTransitionCount: (map['expectedTransitionCount'] as num?)
          ?.toInt(),
      renderedOverlayFrameCount: (map['renderedOverlayFrameCount'] as num?)
          ?.toInt(),
      expectedRenderedOverlayFrameCount:
          (map['expectedRenderedOverlayFrameCount'] as num?)?.toInt(),
      beautyClipCount: (map['beautyClipCount'] as num?)?.toInt(),
      beautyFrameCount: (map['beautyFrameCount'] as num?)?.toInt(),
      expectedBeautyClipCount: (map['expectedBeautyClipCount'] as num?)
          ?.toInt(),
      expectedBeautyFrameCountMin: (map['expectedBeautyFrameCountMin'] as num?)
          ?.toInt(),
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }
}

/// Whole-run verdict over every lane.
@immutable
class VGTimelineOverlayExportSmokeReport {
  const VGTimelineOverlayExportSmokeReport({required this.lanes});

  /// Canonical proof boundary string.
  static const String proofBoundary = overlayProofBoundary;

  /// Canonical PASS marker.
  static const String passMarker = overlayPassMarker;

  /// Canonical FAIL marker.
  static const String failMarker = overlayFailMarker;

  /// Allowed |measured - expected| duration for a positive lane.
  static const double durationToleranceSeconds = 0.25;

  final List<VGTimelineOverlayExportSmokeLaneReport> lanes;

  /// PASS only when there is at least one positive (success) lane and every
  /// lane passed.
  bool get pass =>
      lanes.isNotEmpty &&
      lanes.any((l) => l.expectedSuccess) &&
      lanes.every((l) => l.pass);

  String get status => pass ? 'PASS' : 'FAIL';
  String get marker => pass ? passMarker : failMarker;

  /// First failing lane's reason (laneId-prefixed), or empty when passing.
  String get failureReason {
    for (final lane in lanes) {
      if (!lane.pass) return '${lane.laneId}:${lane.failureReason}';
    }
    return '';
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'pass': pass,
    'status': status,
    'marker': marker,
    'proofBoundary': proofBoundary,
    'failureReason': failureReason,
    'laneCount': lanes.length,
    'lanes': lanes.map((l) => l.toMap()).toList(),
  };

  /// Parses a map produced by [toMap].
  static VGTimelineOverlayExportSmokeReport fromMap(Map<Object?, Object?> map) {
    final rawLanes = map['lanes'];
    final lanes = <VGTimelineOverlayExportSmokeLaneReport>[];
    if (rawLanes is List) {
      for (final raw in rawLanes) {
        if (raw is Map<Object?, Object?>) {
          lanes.add(VGTimelineOverlayExportSmokeLaneReport.fromMap(raw));
        } else if (raw is Map) {
          lanes.add(
            VGTimelineOverlayExportSmokeLaneReport.fromMap(
              raw.map((k, v) => MapEntry<Object?, Object?>(k, v)),
            ),
          );
        }
      }
    }
    return VGTimelineOverlayExportSmokeReport(lanes: lanes);
  }
}

/// Runs smoke lanes through the real production `exportTimeline` route.
class VGTimelineOverlayExportSmokeRunner {
  const VGTimelineOverlayExportSmokeRunner({
    this.channel = const MethodChannel('vanguard_media_engine'),
    this.fileExists = _defaultFileExists,
    this.timeout = const Duration(seconds: 120),
  });

  /// Production channel (injectable for tests).
  final MethodChannel channel;

  /// Filesystem existence probe (injectable for tests).
  final bool Function(String path) fileExists;

  /// Per-lane bound on the native call.
  final Duration timeout;

  static bool _defaultFileExists(String path) => File(path).existsSync();

  /// Runs one lane. Never throws: every outcome becomes a lane report.
  Future<VGTimelineOverlayExportSmokeLaneReport> runLane(
    VGTimelineOverlayExportSmokeRequest request,
  ) async {
    try {
      final result = await channel
          .invokeMapMethod<Object?, Object?>(
            'exportTimeline',
            request.toExportTimelineArguments(),
          )
          .timeout(timeout);
      final path = result?['path'] as String?;
      final exists = path != null && path.isNotEmpty && fileExists(path);
      return VGTimelineOverlayExportSmokeLaneReport.fromExportResult(
        request,
        result,
        outputExists: exists,
      );
    } on PlatformException catch (e) {
      return VGTimelineOverlayExportSmokeLaneReport.fromPlatformException(
        request,
        e,
      );
    } on MissingPluginException catch (e) {
      return VGTimelineOverlayExportSmokeLaneReport.harnessException(
        request,
        'missing_plugin:$e',
      );
    } on TimeoutException catch (e) {
      return VGTimelineOverlayExportSmokeLaneReport.harnessException(
        request,
        'timeout:$e',
      );
    } catch (e) {
      return VGTimelineOverlayExportSmokeLaneReport.harnessException(
        request,
        e,
      );
    }
  }

  /// Runs every lane sequentially.
  Future<VGTimelineOverlayExportSmokeReport> run(
    List<VGTimelineOverlayExportSmokeRequest> requests,
  ) async {
    final lanes = <VGTimelineOverlayExportSmokeLaneReport>[];
    for (final request in requests) {
      lanes.add(await runLane(request));
    }
    return VGTimelineOverlayExportSmokeReport(lanes: lanes);
  }
}

/// Private helper to build a 2-clip, 0.5s transition overlay smoke lane with
/// a static sticker active strictly inside the transition overlap window [1.5s, 2.0s).
VGTimelineOverlayExportSmokeRequest _buildOverlayTransitionLane({
  required String laneId,
  required String transitionType,
  required String clipPathA,
  required String clipPathB,
  required String stickerAssetPath,
  required String Function(String) outputPath,
  String expectedRenderBackend = 'vulkan',
  String? debugForceRenderBackend,
}) {
  return VGTimelineOverlayExportSmokeRequest(
    laneId: laneId,
    clips: <VGTimelineOverlayExportSmokeClip>[
      VGTimelineOverlayExportSmokeClip(
        id: 'clip-1',
        sourcePath: clipPathA,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0,
      ),
      VGTimelineOverlayExportSmokeClip(
        id: 'clip-2',
        sourcePath: clipPathB,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.0,
      ),
    ],
    transitions: <VGTimelineOverlayExportSmokeTransition>[
      VGTimelineOverlayExportSmokeTransition(
        id: 'tr-1',
        type: transitionType,
        durationSeconds: 0.5,
        fromClipId: 'clip-1',
        toClipId: 'clip-2',
      ),
    ],
    overlays: <VGTimelineOverlayExportSmokeOverlay>[
      VGTimelineOverlayExportSmokeOverlay(
        id: 'sticker-overlap',
        assetPath: stickerAssetPath,
        startTimeSeconds: 1.5,
        durationSeconds: 0.5,
        translationX: 100.0,
        translationY: 100.0,
        width: 200.0,
        height: 200.0,
        rotation: 0.0,
        scale: 1.0,
        opacity: 1.0,
        zIndex: 0,
        type: 'sticker',
      ),
    ],
    outputPath: outputPath(laneId),
    expectedRenderBackend: expectedRenderBackend,
    debugForceRenderBackend: debugForceRenderBackend,
    expectation: const VGTimelineOverlayExportSmokeExpectation.success(
      expectedOverlayCount: 1,
      expectedTransitionCount: 1,
      expectedRenderedOverlayFrameCount: 10,
      expectedBeautyClipCount: 0,
      expectedBeautyFrameCountMin: 0,
    ),
  );
}

/// Builds the default suite of 25 static sticker, text, and emoji overlay smoke requests,
/// covering Vulkan Route-A, forced GLES transition-overlay scopes (P5-GLES-EXPORT-TRANSITION-OVERLAYS),
/// forced GLES hard-cut overlay+Beauty V2 solo scopes (P5-GLES-EXPORT-BEAUTY-OVERLAYS), and the
/// forced GLES all-video transition scope combining clip-level Beauty V2 and timeline overlays
/// together (P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS):
/// 1. `single_clip_static_sticker_success`
/// 2. `multi_layer_z_order_success`
/// 3. `time_interval_gating_success`
/// 4. `hard_cut_multiclip_success`
/// 5. `single_clip_dynamic_keyframe_success`
/// 6. `text_overlay_success`
/// 7. `emoji_overlay_success`
/// 8. `fail_closed_malformed_keyframes`
/// 9. `overlays_with_transition_dissolve_success`
/// 10. `overlays_with_transition_slide_left_success`
/// 11. `overlays_with_transition_wipe_right_success`
/// 12. `overlays_with_transition_crossfade_success`
/// 13. `overlays_with_transition_slide_right_success`
/// 14. `overlays_with_transition_slide_up_success`
/// 15. `overlays_with_transition_slide_down_success`
/// 16. `overlays_with_transition_wipe_left_success`
/// 17. `overlays_with_transition_wipe_up_success`
/// 18. `overlays_with_transition_wipe_down_success`
/// 19. `overlays_with_beauty_transition_overlap_success`
/// 20. `overlays_with_beauty_solo_success`
/// 21. `fail_closed_unreadable_asset`
/// 22. `forced_gles_overlays_with_transition_dissolve_success`
/// 23. `forced_gles_overlays_with_transition_wipe_right_success`
/// 24. `forced_gles_overlays_with_beauty_solo_success`
/// 25. `forced_gles_overlays_with_beauty_transition_success`
List<VGTimelineOverlayExportSmokeRequest> buildDefaultOverlayExportSmokeSuite({
  String clipPathA = '/data/local/tmp/clip_a.mov',
  String clipPathB = '/data/local/tmp/clip_b.mov',
  String stickerAssetPath = '/data/local/tmp/sticker.png',
  String nonExistentAssetPath = '/data/local/tmp/missing_sticker.png',
  String outputDirectory = '/data/local/tmp',
}) {
  String outputPath(String laneId) => '$outputDirectory/out_$laneId.mp4';

  return <VGTimelineOverlayExportSmokeRequest>[
    // Lane 1: single_clip_static_sticker_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'single_clip_static_sticker_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-1',
          assetPath: stickerAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('single_clip_static_sticker_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
      ),
    ),

    // Lane 2: multi_layer_z_order_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'multi_layer_z_order_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-bg',
          assetPath: stickerAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 50.0,
          translationY: 50.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-fg',
          assetPath: stickerAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 150.0,
          translationY: 150.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 1,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('multi_layer_z_order_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 2,
      ),
    ),

    // Lane 3: time_interval_gating_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'time_interval_gating_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 4.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-gated',
          assetPath: stickerAssetPath,
          startTimeSeconds: 1.0,
          durationSeconds: 1.5,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('time_interval_gating_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
      ),
    ),

    // Lane 4: hard_cut_multiclip_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'hard_cut_multiclip_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-2',
          sourcePath: clipPathB,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      transitions: const <VGTimelineOverlayExportSmokeTransition>[],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-spanning',
          assetPath: stickerAssetPath,
          startTimeSeconds: 1.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('hard_cut_multiclip_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
      ),
    ),

    // Lane 5: single_clip_dynamic_keyframe_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'single_clip_dynamic_keyframe_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-dynamic-kf',
          assetPath: stickerAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 0.2,
          zIndex: 0,
          type: 'sticker',
          keyframes: const <Object?>[
            <String, Object?>{
              'timeSeconds': 0.0,
              'translationX': 100.0,
              'translationY': 100.0,
              'width': 200.0,
              'height': 200.0,
              'rotation': 0.0,
              'scale': 1.0,
              'opacity': 0.2,
              'interpolation': 'easeInOut',
            },
            <String, Object?>{
              'timeSeconds': 2.0,
              'translationX': 300.0,
              'translationY': 300.0,
              'width': 240.0,
              'height': 240.0,
              'rotation': 0.0,
              'scale': 2.0,
              'opacity': 1.0,
              'interpolation': 'linear',
            },
          ],
        ),
      ],
      outputPath: outputPath('single_clip_dynamic_keyframe_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedRenderedOverlayFrameCount: 55,
      ),
    ),

    // Lane 6: text_overlay_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'text_overlay_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: const <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'text-1',
          textContent: 'Route-A text overlay',
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 50.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'text',
        ),
      ],
      outputPath: outputPath('text_overlay_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedRenderedOverlayFrameCount: 55,
      ),
    ),

    // Lane 7: emoji_overlay_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'emoji_overlay_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: const <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'emoji-1',
          textContent: '\u{1F603}',
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 100.0,
          height: 100.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'emoji',
        ),
      ],
      outputPath: outputPath('emoji_overlay_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedRenderedOverlayFrameCount: 55,
      ),
    ),

    // Lane 8: fail_closed_malformed_keyframes
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_malformed_keyframes',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-bad-kf',
          assetPath: stickerAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
          keyframes: const <Object?>[
            <String, Object?>{
              'timeSeconds': 1.0,
              'translationX': 100.0,
              'translationY': 100.0,
              'width': 200.0,
              'height': 200.0,
              'scale': 1.0,
              'opacity': 1.0,
            },
            <String, Object?>{
              'timeSeconds': 0.5,
              'translationX': 150.0,
              'translationY': 150.0,
              'width': 200.0,
              'height': 200.0,
              'scale': 1.0,
              'opacity': 1.0,
            },
          ],
        ),
      ],
      outputPath: outputPath('fail_closed_malformed_keyframes'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: invalidArgCode,
        messageContains: keyframesToken,
      ),
    ),

    // Lane 9: overlays_with_transition_dissolve_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_dissolve_success',
      transitionType: 'dissolve',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 10: overlays_with_transition_slide_left_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_slide_left_success',
      transitionType: 'slideLeft',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 11: overlays_with_transition_wipe_right_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_wipe_right_success',
      transitionType: 'wipeRight',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 12: overlays_with_transition_crossfade_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_crossfade_success',
      transitionType: 'crossfade',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 13: overlays_with_transition_slide_right_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_slide_right_success',
      transitionType: 'slideRight',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 14: overlays_with_transition_slide_up_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_slide_up_success',
      transitionType: 'slideUp',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 15: overlays_with_transition_slide_down_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_slide_down_success',
      transitionType: 'slideDown',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 16: overlays_with_transition_wipe_left_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_wipe_left_success',
      transitionType: 'wipeLeft',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 17: overlays_with_transition_wipe_up_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_wipe_up_success',
      transitionType: 'wipeUp',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 18: overlays_with_transition_wipe_down_success
    _buildOverlayTransitionLane(
      laneId: 'overlays_with_transition_wipe_down_success',
      transitionType: 'wipeDown',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
    ),

    // Lane 19: overlays_with_beauty_transition_overlap_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'overlays_with_beauty_transition_overlap_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-2',
          sourcePath: clipPathB,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
      ],
      transitions: const <VGTimelineOverlayExportSmokeTransition>[
        VGTimelineOverlayExportSmokeTransition(
          id: 'tr-1',
          type: 'dissolve',
          durationSeconds: 0.5,
          fromClipId: 'clip-1',
          toClipId: 'clip-2',
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-beauty-overlap',
          assetPath: stickerAssetPath,
          // Active strictly within the dissolve's INSET output-timeline
          // overlap window: the raw overlap is [1.5s, 2.0s) (see lane 9's
          // comment), and AndroidTimelineExportSession's admission gate
          // insets that window on both ends by max(2.0 / fps, 0.05)s --
          // ~0.067s at this lane's default 30fps -- leaving a safely
          // contained window of roughly [1.567s, 1.933s). An overlay gated
          // to [1.6s, 1.9s), well inside that inset window, proves overlays
          // alongside clip-level Beauty V2 render correctly through the
          // transition-overlap overlay+beauty render seam
          // (P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY) rather than being
          // rejected or silently dropping the beauty/overlay effect.
          startTimeSeconds: 1.6,
          durationSeconds: 0.3,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('overlays_with_beauty_transition_overlap_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedTransitionCount: 1,
        expectedRenderedOverlayFrameCount: 6,
        expectedBeautyClipCount: 2,
        expectedBeautyFrameCountMin: 100,
      ),
    ),

    // Lane 20: overlays_with_beauty_solo_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'overlays_with_beauty_solo_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-solo-beauty',
          assetPath: stickerAssetPath,
          // Active on a solo clip carrying clip-level Beauty V2 without
          // transitions (P5-OVERLAYS-BEAUTY-SOLO). Proves static sticker
          // overlay compositing alongside clip-level Beauty V2 on solo
          // frames via the combined Vulkan export render seam.
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('overlays_with_beauty_solo_success'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedTransitionCount: 0,
        expectedRenderedOverlayFrameCount: 55,
        expectedBeautyClipCount: 1,
        expectedBeautyFrameCountMin: 55,
      ),
    ),

    // Lane 21: fail_closed_unreadable_asset
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_unreadable_asset',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-bad',
          assetPath: nonExistentAssetPath,
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('fail_closed_unreadable_asset'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: fileUnreadableCode,
        messageContains: unreadableAssetToken,
      ),
    ),

    // Lane 22: forced_gles_overlays_with_transition_dissolve_success
    _buildOverlayTransitionLane(
      laneId: 'forced_gles_overlays_with_transition_dissolve_success',
      transitionType: 'dissolve',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
      expectedRenderBackend: 'gles',
      debugForceRenderBackend: 'gles',
    ),

    // Lane 23: forced_gles_overlays_with_transition_wipe_right_success
    _buildOverlayTransitionLane(
      laneId: 'forced_gles_overlays_with_transition_wipe_right_success',
      transitionType: 'wipeRight',
      clipPathA: clipPathA,
      clipPathB: clipPathB,
      stickerAssetPath: stickerAssetPath,
      outputPath: outputPath,
      expectedRenderBackend: 'gles',
      debugForceRenderBackend: 'gles',
    ),

    // Lane 24: forced_gles_overlays_with_beauty_solo_success
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'forced_gles_overlays_with_beauty_solo_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-forced-gles-beauty-solo',
          assetPath: stickerAssetPath,
          // Active for the full solo hard-cut clip duration -- proves the
          // forced production GLES route (P5-GLES-EXPORT-BEAUTY-OVERLAYS)
          // composites a static sticker overlay on top of clip-level
          // Beauty V2 output via
          // AndroidTimelineVideoEncoder.drawAndSubmitBeautyFrame's pre-swap
          // overlay compositing.
          startTimeSeconds: 0.0,
          durationSeconds: 2.0,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath('forced_gles_overlays_with_beauty_solo_success'),
      expectedRenderBackend: 'gles',
      debugForceRenderBackend: 'gles',
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedTransitionCount: 0,
        expectedRenderedOverlayFrameCount: 55,
        expectedBeautyClipCount: 1,
        expectedBeautyFrameCountMin: 55,
      ),
    ),

    // Lane 25: forced_gles_overlays_with_beauty_transition_success
    // Uses the zero-rotation clipPathA fixture for both sides so this lane
    // remains a narrow zero-rotation combined-feature proof, rather than an
    // accidental rotated-input proof (clipPathB carries rotation tags).
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'forced_gles_overlays_with_beauty_transition_success',
      clips: <VGTimelineOverlayExportSmokeClip>[
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-1',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
        VGTimelineOverlayExportSmokeClip(
          id: 'clip-2',
          sourcePath: clipPathA,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
          beautyIntensity: 0.5,
        ),
      ],
      transitions: const <VGTimelineOverlayExportSmokeTransition>[
        VGTimelineOverlayExportSmokeTransition(
          id: 'tr-1',
          type: 'dissolve',
          durationSeconds: 0.5,
          fromClipId: 'clip-1',
          toClipId: 'clip-2',
        ),
      ],
      overlays: <VGTimelineOverlayExportSmokeOverlay>[
        VGTimelineOverlayExportSmokeOverlay(
          id: 'sticker-forced-gles-beauty-transition',
          assetPath: stickerAssetPath,
          // Active strictly within the dissolve's INSET output-timeline
          // overlap window -- same [1.6s, 1.9s) pattern established by
          // overlays_with_beauty_transition_overlap_success (see that lane's
          // comment for the inset-window derivation). Proves the forced
          // production GLES transition route
          // (P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS) composites a static
          // sticker overlay on top of clip-level Beauty V2 output across a
          // non-hard-cut transition, rather than either effect being
          // silently dropped or the scope being rejected.
          startTimeSeconds: 1.6,
          durationSeconds: 0.3,
          translationX: 100.0,
          translationY: 100.0,
          width: 200.0,
          height: 200.0,
          rotation: 0.0,
          scale: 1.0,
          opacity: 1.0,
          zIndex: 0,
          type: 'sticker',
        ),
      ],
      outputPath: outputPath(
        'forced_gles_overlays_with_beauty_transition_success',
      ),
      expectedRenderBackend: 'gles',
      debugForceRenderBackend: 'gles',
      expectation: const VGTimelineOverlayExportSmokeExpectation.success(
        expectedOverlayCount: 1,
        expectedTransitionCount: 1,
        expectedRenderedOverlayFrameCount: 6,
        expectedBeautyClipCount: 2,
        expectedBeautyFrameCountMin: 100,
      ),
    ),
  ];
}
