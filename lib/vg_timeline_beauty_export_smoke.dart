// vg_timeline_beauty_export_smoke.dart
// vanguard_media_engine — P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A:
// Android production `exportTimeline` Beauty V2 smoke proof model.
//
// Pure Dart typed model + lane runner over the REAL production
// `exportTimeline` MethodChannel route (the same route
// VanguardTimelineExporter.exportDraft invokes). There is no parallel
// diagnostic native path: every lane builds an `exportTimeline` argument map
// (draft + request keys) and reads the production result map back
// (`renderBackend`, `path`, `durationSeconds`, `beautyClipCount`, `beautyFrameCount`).
//
// Contract mirrored from AndroidTimelineExportSession /
// AndroidExportRenderBackendSelector / AndroidTimelineVulkanVideoEncoder:
//   - Proof boundary: `production_exportTimeline_vulkan_beauty_v2_route`;
//   - Claims only production routing/fail-closed behavior on Android, not pixel
//     quality, fleet, playback, GLES beauty, transitions+beauty, app/editor UI,
//     iOS, or streaming/cache;
//   - Pass marker: `ANDROID_TIMELINE_BEAUTY_EXPORT_PHYSICAL_SMOKE_PASS`;
//   - Fail marker: `ANDROID_TIMELINE_BEAUTY_EXPORT_PHYSICAL_SMOKE_FAIL`;
//   - JSON prefix: `ANDROID_TIMELINE_BEAUTY_EXPORT_JSON:`;
//   - Lane prefix: `ANDROID_TIMELINE_BEAUTY_EXPORT_LANE:`;
//   - Validates success lanes: `success == true`, output file exists,
//     `renderBackend == 'vulkan'`, duration within 0.25s, `beautyClipCount`
//     equals expected, and `beautyFrameCount` is >0 when
//     `expectedBeautyFrameCountPositive` is true;
//   - Fail-closed lanes validate PlatformException code and message token;
//   - Whole report requires at least one positive lane and all lanes pass.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Canonical proof boundary string.
const String beautyProofBoundary =
    'production_exportTimeline_vulkan_beauty_v2_route';

/// Canonical PASS marker.
const String beautyPassMarker =
    'ANDROID_TIMELINE_BEAUTY_EXPORT_PHYSICAL_SMOKE_PASS';

/// Canonical FAIL marker.
const String beautyFailMarker =
    'ANDROID_TIMELINE_BEAUTY_EXPORT_PHYSICAL_SMOKE_FAIL';

/// Structured JSON log prefix.
const String beautyJsonPrefix = 'ANDROID_TIMELINE_BEAUTY_EXPORT_JSON:';

/// Structured lane log prefix.
const String beautyLanePrefix = 'ANDROID_TIMELINE_BEAUTY_EXPORT_LANE:';

/// The production MethodChannel error code for an unsupported feature.
const String unsupportedExportFeatureCode = 'UNSUPPORTED_EXPORT_FEATURE';

/// The production MethodChannel error code for invalid arguments.
const String invalidArgCode = 'INVALID_ARG';

/// Token carried by fail-closed message when Beauty V2 requires Vulkan.
const String beautyV2RequiresVulkanToken = 'beauty_v2_requires_vulkan';

/// Token carried by fail-closed message when Beauty V2 is used alongside transitions.
const String beautyV2UnsupportedWithTransitionToken =
    'beauty_v2_unsupported_with_transition';

/// Token carried by fail-closed message when beautyIntensity argument is invalid.
const String beautyIntensityToken = 'beautyIntensity';

/// One clip of a smoke draft. Accepts raw [beautyIntensity] (Object?) so invalid
/// lanes (e.g. negative numbers, out-of-range, or malformed types) can be represented.
@immutable
class VGTimelineBeautyExportSmokeClip {
  const VGTimelineBeautyExportSmokeClip({
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

  /// Raw beauty intensity value; null means no beauty applied.
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

/// Optional transition of a smoke draft.
@immutable
class VGTimelineBeautyExportSmokeTransition {
  const VGTimelineBeautyExportSmokeTransition({
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

/// What a lane expects from the production route.
@immutable
class VGTimelineBeautyExportSmokeExpectation {
  const VGTimelineBeautyExportSmokeExpectation.success({
    this.expectedBeautyClipCount,
    this.expectedBeautyFrameCountPositive = true,
  }) : expectsSuccess = true,
       errorCode = null,
       messageContains = null;

  const VGTimelineBeautyExportSmokeExpectation.failClosed({
    required String this.errorCode,
    this.messageContains,
  }) : expectsSuccess = false,
       expectedBeautyClipCount = 0,
       expectedBeautyFrameCountPositive = false;

  /// True when the lane must produce an output file.
  final bool expectsSuccess;

  /// Optional override for expected beautyClipCount. If null, request derives it
  /// from the number of clips with non-null beautyIntensity.
  final int? expectedBeautyClipCount;

  /// True when beautyFrameCount must be > 0 on success.
  final bool expectedBeautyFrameCountPositive;

  /// Required PlatformException code for a fail-closed lane.
  final String? errorCode;

  /// Optional substring the fail-closed message must contain.
  final String? messageContains;
}

/// One lane: a complete `exportTimeline` request plus its expectation.
@immutable
class VGTimelineBeautyExportSmokeRequest {
  const VGTimelineBeautyExportSmokeRequest({
    required this.laneId,
    required this.clips,
    required this.outputPath,
    required this.expectation,
    this.transitions = const <VGTimelineBeautyExportSmokeTransition>[],
    this.canvasWidth = 720,
    this.canvasHeight = 1280,
    this.fps = 30,
    this.bitrateBps = 4000000,
  });

  final String laneId;
  final List<VGTimelineBeautyExportSmokeClip> clips;
  final List<VGTimelineBeautyExportSmokeTransition> transitions;
  final String outputPath;
  final VGTimelineBeautyExportSmokeExpectation expectation;
  final int canvasWidth;
  final int canvasHeight;
  final int fps;
  final int bitrateBps;

  /// Expected output duration in seconds.
  double get expectedDurationSeconds {
    final clipSum = clips.fold<double>(
      0.0,
      (sum, c) => sum + c.durationSeconds,
    );
    final transitionSum = transitions.fold<double>(
      0.0,
      (sum, t) => sum + t.durationSeconds,
    );
    return (clipSum - transitionSum).clamp(0.0, double.infinity);
  }

  /// Expected beauty clip count: expectation override or count of clips with beauty.
  int get expectedBeautyClipCount =>
      expectation.expectedBeautyClipCount ??
      clips.where((c) => c.hasBeauty).length;

  /// Whether beautyFrameCount is expected to be > 0.
  bool get expectedBeautyFrameCountPositive =>
      expectation.expectedBeautyFrameCountPositive;

  /// The exact `exportTimeline` argument map matching the production shape.
  Map<String, Object?> toExportTimelineArguments() => <String, Object?>{
    'draft': <String, Object?>{
      'id': 'vg-beauty-export-smoke-$laneId',
      'clips': clips.map((c) => c.toMap()).toList(),
      'transitions': transitions.map((t) => t.toMap()).toList(),
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'fps': fps,
      'overlays': const <Object?>[],
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
class VGTimelineBeautyExportSmokeLaneReport {
  const VGTimelineBeautyExportSmokeLaneReport({
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
    this.beautyClipCount,
    this.beautyFrameCount,
    this.expectedBeautyClipCount,
    this.expectedBeautyFrameCountPositive,
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
  final int? beautyClipCount;
  final int? beautyFrameCount;
  final int? expectedBeautyClipCount;
  final bool? expectedBeautyFrameCountPositive;
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
  factory VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
    VGTimelineBeautyExportSmokeRequest request,
    Map<Object?, Object?>? result, {
    required bool outputExists,
  }) {
    final expectedDuration = request.expectedDurationSeconds;
    final expectedClips = request.expectedBeautyClipCount;
    final expectPositiveFrames = request.expectedBeautyFrameCountPositive;

    if (result == null) {
      return VGTimelineBeautyExportSmokeLaneReport(
        laneId: request.laneId,
        pass: false,
        status: 'FAIL',
        failureReason: 'native_returned_null_result',
        expectedSuccess: request.expectation.expectsSuccess,
        expectedDurationSeconds: expectedDuration,
        expectedBeautyClipCount: expectedClips,
        expectedBeautyFrameCountPositive: expectPositiveFrames,
      );
    }
    final success = result['success'] == true;
    final path = result['path'] as String?;
    final duration = (result['durationSeconds'] as num?)?.toDouble();
    final backend = result['renderBackend'] as String?;
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
    } else if (backend != 'vulkan') {
      failure = 'render_backend_not_vulkan:${backend ?? 'null'}';
    } else if (duration == null) {
      failure = 'result_duration_missing';
    } else if ((duration - expectedDuration).abs() >
        VGTimelineBeautyExportSmokeReport.durationToleranceSeconds) {
      failure =
          'duration_mismatch:measured=${duration.toStringAsFixed(3)}:'
          'expected=${expectedDuration.toStringAsFixed(3)}';
    } else if (beautyClipCount == null || beautyClipCount != expectedClips) {
      failure =
          'beauty_clip_count_mismatch:reported=$beautyClipCount:expected=$expectedClips';
    } else if (expectPositiveFrames &&
        (beautyFrameCount == null || beautyFrameCount <= 0)) {
      failure = 'beauty_frame_count_not_positive:reported=$beautyFrameCount';
    }

    final pass = failure == null;
    return VGTimelineBeautyExportSmokeLaneReport(
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
      beautyClipCount: beautyClipCount,
      beautyFrameCount: beautyFrameCount,
      expectedBeautyClipCount: expectedClips,
      expectedBeautyFrameCountPositive: expectPositiveFrames,
    );
  }

  /// Evaluates a production PlatformException against [request]'s
  /// fail-closed expectation.
  factory VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
    VGTimelineBeautyExportSmokeRequest request,
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
    return VGTimelineBeautyExportSmokeLaneReport(
      laneId: request.laneId,
      pass: pass,
      status: pass ? 'PASS' : 'FAIL',
      failureReason: failure ?? '',
      expectedSuccess: expectation.expectsSuccess,
      expectedDurationSeconds: request.expectedDurationSeconds,
      expectedBeautyClipCount: request.expectedBeautyClipCount,
      expectedBeautyFrameCountPositive:
          request.expectedBeautyFrameCountPositive,
      errorCode: exception.code,
      errorMessage: exception.message,
    );
  }

  /// A lane that encountered an unexpected exception.
  factory VGTimelineBeautyExportSmokeLaneReport.harnessException(
    VGTimelineBeautyExportSmokeRequest request,
    Object error,
  ) => VGTimelineBeautyExportSmokeLaneReport(
    laneId: request.laneId,
    pass: false,
    status: 'FAIL',
    failureReason: 'harness_exception:$error',
    expectedSuccess: request.expectation.expectsSuccess,
    expectedDurationSeconds: request.expectedDurationSeconds,
    expectedBeautyClipCount: request.expectedBeautyClipCount,
    expectedBeautyFrameCountPositive: request.expectedBeautyFrameCountPositive,
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
    'beautyClipCount': beautyClipCount,
    'beautyFrameCount': beautyFrameCount,
    'expectedBeautyClipCount': expectedBeautyClipCount,
    'expectedBeautyFrameCountPositive': expectedBeautyFrameCountPositive,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  /// Parses a map produced by [toMap].
  static VGTimelineBeautyExportSmokeLaneReport fromMap(
    Map<Object?, Object?> map,
  ) {
    return VGTimelineBeautyExportSmokeLaneReport(
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
      beautyClipCount: (map['beautyClipCount'] as num?)?.toInt(),
      beautyFrameCount: (map['beautyFrameCount'] as num?)?.toInt(),
      expectedBeautyClipCount: (map['expectedBeautyClipCount'] as num?)
          ?.toInt(),
      expectedBeautyFrameCountPositive:
          map['expectedBeautyFrameCountPositive'] as bool?,
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }
}

/// Whole-run verdict over every lane.
@immutable
class VGTimelineBeautyExportSmokeReport {
  const VGTimelineBeautyExportSmokeReport({required this.lanes});

  /// Canonical proof boundary string.
  static const String proofBoundary = beautyProofBoundary;

  /// Canonical PASS marker.
  static const String passMarker = beautyPassMarker;

  /// Canonical FAIL marker.
  static const String failMarker = beautyFailMarker;

  /// Allowed |measured - expected| duration for a positive lane.
  static const double durationToleranceSeconds = 0.25;

  final List<VGTimelineBeautyExportSmokeLaneReport> lanes;

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
  static VGTimelineBeautyExportSmokeReport fromMap(Map<Object?, Object?> map) {
    final rawLanes = map['lanes'];
    final lanes = <VGTimelineBeautyExportSmokeLaneReport>[];
    if (rawLanes is List) {
      for (final raw in rawLanes) {
        if (raw is Map<Object?, Object?>) {
          lanes.add(VGTimelineBeautyExportSmokeLaneReport.fromMap(raw));
        } else if (raw is Map) {
          lanes.add(
            VGTimelineBeautyExportSmokeLaneReport.fromMap(
              raw.map((k, v) => MapEntry<Object?, Object?>(k, v)),
            ),
          );
        }
      }
    }
    return VGTimelineBeautyExportSmokeReport(lanes: lanes);
  }
}

/// Runs smoke lanes through the real production `exportTimeline` route.
class VGTimelineBeautyExportSmokeRunner {
  const VGTimelineBeautyExportSmokeRunner({
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
  Future<VGTimelineBeautyExportSmokeLaneReport> runLane(
    VGTimelineBeautyExportSmokeRequest request,
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
      return VGTimelineBeautyExportSmokeLaneReport.fromExportResult(
        request,
        result,
        outputExists: exists,
      );
    } on PlatformException catch (e) {
      return VGTimelineBeautyExportSmokeLaneReport.fromPlatformException(
        request,
        e,
      );
    } on MissingPluginException catch (e) {
      return VGTimelineBeautyExportSmokeLaneReport.harnessException(
        request,
        'missing_plugin:$e',
      );
    } on TimeoutException catch (e) {
      return VGTimelineBeautyExportSmokeLaneReport.harnessException(
        request,
        'timeout:$e',
      );
    } catch (e) {
      return VGTimelineBeautyExportSmokeLaneReport.harnessException(request, e);
    }
  }

  /// Runs every lane sequentially.
  Future<VGTimelineBeautyExportSmokeReport> run(
    List<VGTimelineBeautyExportSmokeRequest> requests,
  ) async {
    final lanes = <VGTimelineBeautyExportSmokeLaneReport>[];
    for (final request in requests) {
      lanes.add(await runLane(request));
    }
    return VGTimelineBeautyExportSmokeReport(lanes: lanes);
  }
}
