// vg_timeline_overlay_export_smoke.dart
// vanguard_media_engine -- P5-OVERLAYS-TRANS / P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A:
// Android production `exportTimeline` static sticker overlay smoke proof model.
//
// Pure Dart typed model + lane runner over the REAL production
// `exportTimeline` MethodChannel route (the same route
// VanguardTimelineExporter.exportDraft invokes). There is no parallel
// diagnostic native path: every lane builds an `exportTimeline` argument map
// (draft + request keys) and reads the production result map back
// (`renderBackend`, `path`, `durationSeconds`, `overlayCount`).
//
// Contract:
//   - Proof boundary: `production_exportTimeline_vulkan_static_sticker_overlay_route_a`;
//   - Pass marker: `ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_PASS`;
//   - Fail marker: `ANDROID_TIMELINE_OVERLAY_EXPORT_PHYSICAL_SMOKE_FAIL`;
//   - Structured JSON prefix: `ANDROID_TIMELINE_OVERLAY_EXPORT_JSON:`;
//   - Structured lane prefix: `ANDROID_TIMELINE_OVERLAY_EXPORT_LANE:`;
//   - Claims production routing/fail-closed behavior on Android for static sticker
//     overlays in Route-A, but does not claim text/emoji overlays, animated keyframes,
//     overlay transitions, overlay beauty filter composition, pixel quality, fleet coverage,
//     playback, GLES overlays, app/editor UI, iOS, or streaming/cache;
//   - Validates success lanes: `success == true`, output file exists,
//     `renderBackend == 'vulkan'`, duration within 0.25s tolerance (hard-cut sum of clip
//     trim windows, unaffected by overlay intervals), and `overlayCount` matching
//     expectation when present;
//   - Fail-closed lanes validate PlatformException code and message substrings;
//   - Whole report requires at least one positive lane and all lanes pass.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical proof boundary string.
const String overlayProofBoundary =
    'production_exportTimeline_vulkan_static_sticker_overlay_route_a';

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

/// Fail-closed token for unsupported text overlays in Route-A.
const String textOverlayToken = 'text';

/// Fail-closed token for unsupported emoji overlays in Route-A.
const String emojiOverlayToken = 'emoji';

/// Fail-closed token for unsupported animated keyframe overlays in Route-A.
const String keyframesToken = 'keyframe';

/// Fail-closed token for overlays with transition composition.
const String overlaysWithTransitionToken = 'transition';

/// Fail-closed token for overlays with beauty filter composition.
const String overlaysWithBeautyToken = 'beauty';

/// Fail-closed token for unreadable sticker assets.
const String unreadableAssetToken = 'asset';

/// Default lane IDs for the full Route-A static sticker overlay smoke suite.
const List<String> defaultOverlaySmokeLaneIds = <String>[
  'single_clip_static_sticker_success',
  'multi_layer_z_order_success',
  'time_interval_gating_success',
  'hard_cut_multiclip_success',
  'fail_closed_text_overlay',
  'fail_closed_emoji_overlay',
  'fail_closed_keyframes',
  'fail_closed_overlays_with_transition',
  'fail_closed_overlays_with_beauty',
  'fail_closed_unreadable_asset',
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
  }) : expectsSuccess = true,
       errorCode = null,
       messageContains = null;

  const VGTimelineOverlayExportSmokeExpectation.failClosed({
    required String this.errorCode,
    this.messageContains,
  }) : expectsSuccess = false,
       expectedOverlayCount = null;

  /// True when the lane must produce a successful export output file.
  final bool expectsSuccess;

  /// Optional override for expected overlayCount. If null on success,
  /// the request derives it from the number of overlays in the request.
  final int? expectedOverlayCount;

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
  final int canvasWidth;
  final int canvasHeight;
  final int fps;
  final int bitrateBps;

  /// Expected duration is the hard-cut sum of clip trim windows.
  /// Overlay intervals do not affect timeline duration.
  double get expectedDurationSeconds {
    return clips
        .fold<double>(0.0, (sum, c) => sum + c.durationSeconds)
        .clamp(0.0, double.infinity);
  }

  /// Expected overlay count: expectation override or overlays list length on success.
  int? get expectedOverlayCount =>
      expectation.expectedOverlayCount ??
      (expectation.expectsSuccess ? overlays.length : null);

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

    if (result == null) {
      return VGTimelineOverlayExportSmokeLaneReport(
        laneId: request.laneId,
        pass: false,
        status: 'FAIL',
        failureReason: 'native_returned_null_result',
        expectedSuccess: request.expectation.expectsSuccess,
        expectedDurationSeconds: expectedDuration,
        expectedOverlayCount: expectedOverlays,
      );
    }
    final success = result['success'] == true;
    final path = result['path'] as String?;
    final duration = (result['durationSeconds'] as num?)?.toDouble();
    final backend = result['renderBackend'] as String?;
    final overlayCount = (result['overlayCount'] as num?)?.toInt();

    String? failure;
    if (!request.expectation.expectsSuccess) {
      failure = 'expected_fail_closed_but_export_succeeded';
    } else if (!success) {
      failure = 'result_success_false';
    } else if (path == null || path.isEmpty) {
      failure = 'result_path_missing';
    } else if (!outputExists) {
      failure = 'output_file_missing';
    } else if (backend != 'vulkan') {
      failure = 'render_backend_not_vulkan:${backend ?? 'null'}';
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

/// Builds the default suite of 10 Route-A static sticker overlay smoke requests:
/// 1. `single_clip_static_sticker_success`
/// 2. `multi_layer_z_order_success`
/// 3. `time_interval_gating_success`
/// 4. `hard_cut_multiclip_success`
/// 5. `fail_closed_text_overlay`
/// 6. `fail_closed_emoji_overlay`
/// 7. `fail_closed_keyframes`
/// 8. `fail_closed_overlays_with_transition`
/// 9. `fail_closed_overlays_with_beauty`
/// 10. `fail_closed_unreadable_asset`
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

    // Lane 5: fail_closed_text_overlay
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_text_overlay',
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
          textContent: 'unsupported text overlay',
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
      outputPath: outputPath('fail_closed_text_overlay'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: textOverlayToken,
      ),
    ),

    // Lane 6: fail_closed_emoji_overlay
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_emoji_overlay',
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
          textContent: 'emoji',
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
      outputPath: outputPath('fail_closed_emoji_overlay'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: emojiOverlayToken,
      ),
    ),

    // Lane 7: fail_closed_keyframes
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_keyframes',
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
          id: 'sticker-kf',
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
            <String, Object?>{'time': 0.0, 'scale': 1.0},
            <String, Object?>{'time': 1.0, 'scale': 1.5},
          ],
        ),
      ],
      outputPath: outputPath('fail_closed_keyframes'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: keyframesToken,
      ),
    ),

    // Lane 8: fail_closed_overlays_with_transition
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_overlays_with_transition',
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
      outputPath: outputPath('fail_closed_overlays_with_transition'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: overlaysWithTransitionToken,
      ),
    ),

    // Lane 9: fail_closed_overlays_with_beauty
    VGTimelineOverlayExportSmokeRequest(
      laneId: 'fail_closed_overlays_with_beauty',
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
      outputPath: outputPath('fail_closed_overlays_with_beauty'),
      expectation: const VGTimelineOverlayExportSmokeExpectation.failClosed(
        errorCode: unsupportedExportFeatureCode,
        messageContains: overlaysWithBeautyToken,
      ),
    ),

    // Lane 10: fail_closed_unreadable_asset
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
  ];
}
