// vg_timeline_transition_export_smoke.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (PRODUCTION-EXPORT-ROUTE):
// Android production `exportTimeline` compositor-owned clip overlap
// transition proof smoke model.
//
// Pure Dart typed model + lane runner over the REAL production
// `exportTimeline` MethodChannel route (the same route
// VanguardTimelineExporter.exportDraft invokes). There is no parallel
// diagnostic native path: every lane builds an `exportTimeline` argument map
// (draft + request keys) and reads the production result map back
// (`renderBackend`, `path`, `durationSeconds`, `transitionCount`).
//
// The draft is built here from raw wire maps rather than VGEditorDraft so
// that every transition wire type the native parser supports
// (dissolve/crossfade, slideLeft/Right/Up/Down, wipeLeft/Right/Up/Down) can
// be exercised -- the typed VGTransitionType enum only spells `none`,
// `fade`, `dissolve`. The wire shape is exactly VGEditorDraft.toMap() /
// VGClipDescriptor.toMap() / VGTransitionDescriptor.toMap() for the keys the
// native session reads.
//
// Contract mirrored from AndroidTimelineTransitionDescriptor /
// AndroidTimelineExportSession:
//   - supported non-hard-cut types: [supportedTransitionWireNames];
//   - `fade` (and any unknown type) fails closed with
//     UNSUPPORTED_EXPORT_FEATURE -- it is never mapped to dissolve/hard cut;
//   - a transition timeline that cannot be routed to Vulkan fails closed
//     with UNSUPPORTED_EXPORT_FEATURE carrying `transitions_require_vulkan`;
//   - a successful transition export reports renderBackend == 'vulkan' and
//     an overlap-shortened duration: sum(clip trim windows) - sum(transition
//     durations), within [durationToleranceSeconds].
// No product/editor UI, no iOS, no streaming/cache.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Transition wire names accepted by the native production parser for a
/// compositor-owned overlap transition (case-insensitive natively).
const List<String> supportedTransitionWireNames = <String>[
  'dissolve',
  'crossfade',
  'slideLeft',
  'slideRight',
  'slideUp',
  'slideDown',
  'wipeLeft',
  'wipeRight',
  'wipeUp',
  'wipeDown',
];

/// Wire name of a hard cut (accepted and dropped natively).
const String hardCutTransitionWireName = 'none';

/// Wire names that must fail closed natively (never remapped).
const List<String> failClosedTransitionWireNames = <String>['fade'];

/// The production MethodChannel error code for a fail-closed feature.
const String unsupportedExportFeatureCode = 'UNSUPPORTED_EXPORT_FEATURE';

/// Reason token carried by the fail-closed message when a transition
/// timeline cannot be routed to the Vulkan backend.
const String transitionsRequireVulkanReason = 'transitions_require_vulkan';

/// Classification of a transition wire name against the native contract.
enum VGTimelineTransitionExportWireKind {
  /// Accepted and rendered as an overlap.
  supported,

  /// `none`: accepted, dropped, no overlap.
  hardCut,

  /// Rejected with UNSUPPORTED_EXPORT_FEATURE.
  unsupported;

  /// Classifies [wireName] (trimmed, case-insensitive like the native parser).
  static VGTimelineTransitionExportWireKind classify(String wireName) {
    final normalized = wireName.trim().toLowerCase();
    if (normalized == hardCutTransitionWireName) {
      return VGTimelineTransitionExportWireKind.hardCut;
    }
    for (final supported in supportedTransitionWireNames) {
      if (supported.toLowerCase() == normalized) {
        return VGTimelineTransitionExportWireKind.supported;
      }
    }
    return VGTimelineTransitionExportWireKind.unsupported;
  }
}

/// One clip of a smoke draft (wire shape of VGClipDescriptor.toMap()).
@immutable
class VGTimelineTransitionExportSmokeClip {
  const VGTimelineTransitionExportSmokeClip({
    required this.id,
    required this.sourcePath,
    required this.trimStartSeconds,
    required this.trimEndSeconds,
    this.mediaKind = 'video',
  });

  final String id;
  final String sourcePath;
  final double trimStartSeconds;
  final double trimEndSeconds;
  final String mediaKind;

  /// Trim window length in seconds (never negative).
  double get durationSeconds =>
      (trimEndSeconds - trimStartSeconds).clamp(0.0, double.infinity);

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'sourcePath': sourcePath,
    'mediaKind': mediaKind,
    'startTimeSeconds': 0.0,
    'durationSeconds': durationSeconds,
    'trimStartSeconds': trimStartSeconds,
    'trimEndSeconds': trimEndSeconds,
    'speed': 1.0,
  };
}

/// One transition of a smoke draft (wire shape of
/// VGTransitionDescriptor.toMap(), with a raw [type] wire name).
@immutable
class VGTimelineTransitionExportSmokeTransition {
  const VGTimelineTransitionExportSmokeTransition({
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

  VGTimelineTransitionExportWireKind get wireKind =>
      VGTimelineTransitionExportWireKind.classify(type);

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
class VGTimelineTransitionExportSmokeExpectation {
  const VGTimelineTransitionExportSmokeExpectation.success()
    : expectsSuccess = true,
      errorCode = null,
      messageContains = null;

  const VGTimelineTransitionExportSmokeExpectation.failClosed({
    required String this.errorCode,
    this.messageContains,
  }) : expectsSuccess = false;

  /// True when the lane must produce an output file.
  final bool expectsSuccess;

  /// Required PlatformException code for a fail-closed lane.
  final String? errorCode;

  /// Optional substring the fail-closed message must contain.
  final String? messageContains;
}

/// One lane: a complete `exportTimeline` request plus its expectation.
@immutable
class VGTimelineTransitionExportSmokeRequest {
  const VGTimelineTransitionExportSmokeRequest({
    required this.laneId,
    required this.clips,
    required this.transitions,
    required this.outputPath,
    required this.expectation,
    this.canvasWidth = 720,
    this.canvasHeight = 1280,
    this.fps = 30,
    this.bitrateBps = 4000000,
  });

  final String laneId;
  final List<VGTimelineTransitionExportSmokeClip> clips;
  final List<VGTimelineTransitionExportSmokeTransition> transitions;
  final String outputPath;
  final VGTimelineTransitionExportSmokeExpectation expectation;
  final int canvasWidth;
  final int canvasHeight;
  final int fps;
  final int bitrateBps;

  /// Overlap-shortened duration the production route must produce:
  /// sum of clip trim windows minus every supported (non-hard-cut)
  /// transition duration. Unsupported types contribute nothing (they fail
  /// closed before any output exists).
  double get expectedDurationSeconds {
    final clipSum = clips.fold<double>(
      0.0,
      (sum, c) => sum + c.durationSeconds,
    );
    final overlapSum = transitions
        .where(
          (t) => t.wireKind == VGTimelineTransitionExportWireKind.supported,
        )
        .fold<double>(0.0, (sum, t) => sum + t.durationSeconds);
    return (clipSum - overlapSum).clamp(0.0, double.infinity);
  }

  /// Number of supported (overlap) transitions in this request.
  int get supportedTransitionCount => transitions
      .where((t) => t.wireKind == VGTimelineTransitionExportWireKind.supported)
      .length;

  /// The exact `exportTimeline` argument map (draft + request keys), matching
  /// the shape VanguardTimelineExporter.exportDraft sends.
  Map<String, Object?> toExportTimelineArguments() => <String, Object?>{
    'draft': <String, Object?>{
      'id': 'vg-transition-export-smoke-$laneId',
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
class VGTimelineTransitionExportSmokeLaneReport {
  const VGTimelineTransitionExportSmokeLaneReport({
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
    this.transitionCount,
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
  final int? transitionCount;
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
  factory VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
    VGTimelineTransitionExportSmokeRequest request,
    Map<Object?, Object?>? result, {
    required bool outputExists,
  }) {
    final expected = request.expectedDurationSeconds;
    if (result == null) {
      return VGTimelineTransitionExportSmokeLaneReport(
        laneId: request.laneId,
        pass: false,
        status: 'FAIL',
        failureReason: 'native_returned_null_result',
        expectedSuccess: request.expectation.expectsSuccess,
        expectedDurationSeconds: expected,
      );
    }
    final success = result['success'] == true;
    final path = result['path'] as String?;
    final duration = (result['durationSeconds'] as num?)?.toDouble();
    final backend = result['renderBackend'] as String?;
    final transitionCount = (result['transitionCount'] as num?)?.toInt();

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
    } else if ((duration - expected).abs() >
        VGTimelineTransitionExportSmokeReport.durationToleranceSeconds) {
      failure =
          'duration_mismatch:measured=${duration.toStringAsFixed(3)}:'
          'expected=${expected.toStringAsFixed(3)}';
    } else if (transitionCount != null &&
        transitionCount != request.supportedTransitionCount) {
      failure =
          'transition_count_mismatch:reported=$transitionCount:'
          'expected=${request.supportedTransitionCount}';
    }
    final pass = failure == null;
    return VGTimelineTransitionExportSmokeLaneReport(
      laneId: request.laneId,
      pass: pass,
      status: pass ? 'PASS' : 'FAIL',
      failureReason: failure ?? '',
      expectedSuccess: request.expectation.expectsSuccess,
      expectedDurationSeconds: expected,
      renderBackend: backend,
      outputPath: path,
      outputExists: outputExists,
      durationSeconds: duration,
      transitionCount: transitionCount,
    );
  }

  /// Evaluates a production PlatformException against [request]'s
  /// fail-closed expectation.
  factory VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
    VGTimelineTransitionExportSmokeRequest request,
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
    return VGTimelineTransitionExportSmokeLaneReport(
      laneId: request.laneId,
      pass: pass,
      status: pass ? 'PASS' : 'FAIL',
      failureReason: failure ?? '',
      expectedSuccess: expectation.expectsSuccess,
      expectedDurationSeconds: request.expectedDurationSeconds,
      errorCode: exception.code,
      errorMessage: exception.message,
    );
  }

  /// A lane that threw something other than a PlatformException.
  factory VGTimelineTransitionExportSmokeLaneReport.harnessException(
    VGTimelineTransitionExportSmokeRequest request,
    Object error,
  ) => VGTimelineTransitionExportSmokeLaneReport(
    laneId: request.laneId,
    pass: false,
    status: 'FAIL',
    failureReason: 'harness_exception:$error',
    expectedSuccess: request.expectation.expectsSuccess,
    expectedDurationSeconds: request.expectedDurationSeconds,
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
    'transitionCount': transitionCount,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  /// Parses a map produced by [toMap]. Missing/invalid fields fail closed.
  static VGTimelineTransitionExportSmokeLaneReport fromMap(
    Map<Object?, Object?> map,
  ) {
    return VGTimelineTransitionExportSmokeLaneReport(
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
      transitionCount: (map['transitionCount'] as num?)?.toInt(),
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }
}

/// Whole-run verdict over every lane.
@immutable
class VGTimelineTransitionExportSmokeReport {
  const VGTimelineTransitionExportSmokeReport({required this.lanes});

  /// Canonical proof boundary string.
  static const String proofBoundary =
      'production_exportTimeline_vulkan_compositor_transition_overlap_route';

  /// Canonical PASS marker.
  static const String passMarker =
      'ANDROID_TIMELINE_TRANSITION_EXPORT_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker.
  static const String failMarker =
      'ANDROID_TIMELINE_TRANSITION_EXPORT_PHYSICAL_SMOKE_FAIL';

  /// Allowed |measured - expected| duration for a positive lane. Each
  /// window boundary (seek + pts-window membership) may shift by about one
  /// source frame; three boundaries at 30 fps stay well inside this.
  static const double durationToleranceSeconds = 0.25;

  final List<VGTimelineTransitionExportSmokeLaneReport> lanes;

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

  /// Parses a map produced by [toMap]. A malformed `lanes` entry yields an
  /// empty (failing) report.
  static VGTimelineTransitionExportSmokeReport fromMap(
    Map<Object?, Object?> map,
  ) {
    final rawLanes = map['lanes'];
    final lanes = <VGTimelineTransitionExportSmokeLaneReport>[];
    if (rawLanes is List) {
      for (final raw in rawLanes) {
        if (raw is Map<Object?, Object?>) {
          lanes.add(VGTimelineTransitionExportSmokeLaneReport.fromMap(raw));
        } else if (raw is Map) {
          lanes.add(
            VGTimelineTransitionExportSmokeLaneReport.fromMap(
              raw.map((k, v) => MapEntry<Object?, Object?>(k, v)),
            ),
          );
        }
      }
    }
    return VGTimelineTransitionExportSmokeReport(lanes: lanes);
  }
}

/// Runs smoke lanes through the real production `exportTimeline` route.
class VGTimelineTransitionExportSmokeRunner {
  const VGTimelineTransitionExportSmokeRunner({
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
  Future<VGTimelineTransitionExportSmokeLaneReport> runLane(
    VGTimelineTransitionExportSmokeRequest request,
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
      return VGTimelineTransitionExportSmokeLaneReport.fromExportResult(
        request,
        result,
        outputExists: exists,
      );
    } on PlatformException catch (e) {
      return VGTimelineTransitionExportSmokeLaneReport.fromPlatformException(
        request,
        e,
      );
    } on MissingPluginException catch (e) {
      return VGTimelineTransitionExportSmokeLaneReport.harnessException(
        request,
        'missing_plugin:$e',
      );
    } on TimeoutException catch (e) {
      return VGTimelineTransitionExportSmokeLaneReport.harnessException(
        request,
        'timeout:$e',
      );
    } catch (e) {
      return VGTimelineTransitionExportSmokeLaneReport.harnessException(
        request,
        e,
      );
    }
  }

  /// Runs every lane sequentially (the native route holds a single export
  /// lock; concurrent calls would be rejected with EXPORT_IN_PROGRESS).
  Future<VGTimelineTransitionExportSmokeReport> run(
    List<VGTimelineTransitionExportSmokeRequest> requests,
  ) async {
    final lanes = <VGTimelineTransitionExportSmokeLaneReport>[];
    for (final request in requests) {
      lanes.add(await runLane(request));
    }
    return VGTimelineTransitionExportSmokeReport(lanes: lanes);
  }
}
