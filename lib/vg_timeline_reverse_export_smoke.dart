// vg_timeline_reverse_export_smoke.dart
// vanguard_media_engine -- P5-REVERSE-EXPORT-EXACT-GLES-ROUTE (parent backlog
// item P5-REVERSE-SIDECAR / reverse export parity):
// Android production `exportTimeline` narrow reversed-video export smoke
// model.
//
// Pure Dart typed model + lane runner over the REAL production
// `exportTimeline` MethodChannel route (the same route
// VanguardTimelineExporter.exportDraft invokes) -- follows the shape of
// vg_timeline_transition_export_smoke.dart, but a positive (success) lane
// here expects renderBackend == 'gles': reversed-clip video export has no
// native Vulkan render route in this slice.
// AndroidTimelineVulkanVideoEncoder fails closed defensively with
// vulkan_reverse_not_supported if it ever receives a reversed clip;
// AndroidExportRenderBackendSelector resolves a plain reversed hard-cut
// scope to GLES instead, which renders it via
// AndroidTimelineVideoEncoder.renderReversedClipIntoEncoder.
//
// Contract mirrored from AndroidTimelineExportSession /
// AndroidExportRenderBackendSelector / AndroidTimelineVideoEncoder /
// AndroidTimelineVulkanVideoEncoder / AndroidTimelineAudioOverlapAdmission:
//   - accepted: local video clips only, speed == 1.0, trimEnd > trimStart,
//     one or more hard-cut clips (no transitions) that may be forward or
//     reversed, with an optional per-clip colorMatrix applied through the
//     same GLES 2D draw path a still-image clip uses;
//   - a reversed clip is hard-cut concatenated exactly like a forward clip
//     -- there is no overlap-shortening in this slice, so expected duration
//     is simply the sum of every clip's trim window;
//   - isReversed=true on a non-video (image) clip fails closed with
//     INVALID_ARG (message contains both "isReversed" and "video");
//   - a reversed clip alongside any transition, or any clip-level Beauty V2,
//     fails closed with UNSUPPORTED_EXPORT_FEATURE before pass-1 -- there is
//     no positive production shape for those combinations in this slice;
//   - P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS: a hard-cut, zero-rotation
//     reversed video clip alongside timeline overlays is a supported
//     production shape -- it routes through the same GLES overlay route
//     (renderBackend == 'gles') a still-image clip with overlays already
//     uses;
//   - P5-REVERSE-AUDIO-SIDECAR-EXPORT: a reversed hard-cut timeline
//     carrying draft.audioSidecar tracks is admitted -- not blanket-
//     rejected -- when every track's timing fits the reversed timeline's
//     total duration (AndroidTimelineAudioOverlapAdmission, the same gate
//     P5-TRANSITION-AUDIO-SIDECAR-EXPORT uses). A track whose timing
//     doesn't fit still fails closed with INVALID_ARG rather than muxing
//     desynchronized audio;
//   - a reversed clip with non-zero rotation metadata also fails closed
//     with UNSUPPORTED_EXPORT_FEATURE (not exercised by this Dart-only
//     model's lanes, since the harness never emits clip rotation metadata).
// No product/editor UI, no iOS, no streaming/cache.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The production MethodChannel error code for a fail-closed feature.
const String unsupportedExportFeatureCode = 'UNSUPPORTED_EXPORT_FEATURE';

/// The production MethodChannel error code for a malformed/invalid argument.
const String invalidArgExportCode = 'INVALID_ARG';

/// Render backend wire value a positive reversed-clip export lane must
/// report -- reversed clips never route through Vulkan in this slice.
const String expectedReverseRenderBackend = 'gles';

/// Message token the production route embeds when a reversed clip's
/// mediaKind is not 'video'.
const String reversedClipIsReversedToken = 'isReversed';

/// Message token the production route embeds alongside
/// [reversedClipIsReversedToken] for the same mediaKind-mismatch failure.
const String reversedClipVideoToken = 'video';

/// Message token for a reversed clip alongside a non-empty transition list.
const String reversedClipsWithTransitionsToken =
    'reversed clips with transitions';

/// Message token for a reversed clip alongside clip-level Beauty V2.
const String reversedClipsWithBeautyToken = 'reversed clips with Beauty V2';

/// Message token substring the production route embeds when a reversed
/// timeline's audioSidecar track fails AndroidTimelineAudioOverlapAdmission
/// timing validation (see P5-REVERSE-AUDIO-SIDECAR-EXPORT) -- e.g. an end
/// time past the reversed timeline's total duration.
const String reversedAudioSidecarInvalidTimingToken = 'audioSidecar track';

/// Message token for a reversed clip carrying non-zero rotation metadata.
const String reversedClipsWithRotationToken =
    'reversed clips with rotation metadata';

/// One clip of a smoke draft (wire shape of VGClipDescriptor.toMap(), plus
/// the isReversed/colorMatrix/beautyIntensity keys this slice reads).
@immutable
class VGTimelineReverseExportSmokeClip {
  const VGTimelineReverseExportSmokeClip({
    required this.id,
    required this.sourcePath,
    required this.trimStartSeconds,
    required this.trimEndSeconds,
    this.mediaKind = 'video',
    this.isReversed = false,
    this.colorMatrix,
    this.beautyIntensity,
  });

  final String id;
  final String sourcePath;
  final double trimStartSeconds;
  final double trimEndSeconds;
  final String mediaKind;
  final bool isReversed;
  final List<double>? colorMatrix;
  final double? beautyIntensity;

  /// Trim window length in seconds (never negative).
  double get durationSeconds =>
      (trimEndSeconds - trimStartSeconds).clamp(0.0, double.infinity);

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
      'isReversed': isReversed,
    };
    if (colorMatrix != null) {
      map['colorMatrix'] = colorMatrix;
    }
    if (beautyIntensity != null) {
      map['beautyIntensity'] = beautyIntensity;
    }
    return map;
  }
}

/// One transition entry for a fail-closed "reversed + transitions" lane
/// (wire shape of VGTransitionDescriptor.toMap()) -- this slice never
/// accepts a non-empty transition list alongside a reversed clip, so no
/// positive lane ever carries one.
@immutable
class VGTimelineReverseExportSmokeTransition {
  const VGTimelineReverseExportSmokeTransition({
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

/// One sticker overlay entry for a "reversed + overlays" lane (wire shape of
/// VGOverlayDescriptor.toMap()) -- a hard-cut, zero-rotation reversed video
/// clip alongside a non-empty overlay list is a supported production shape
/// (P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS), so a positive lane may carry one.
@immutable
class VGTimelineReverseExportSmokeOverlay {
  const VGTimelineReverseExportSmokeOverlay({
    required this.id,
    required this.assetPath,
    this.startTimeSeconds = 0.0,
    this.durationSeconds = 1.0,
    this.translationX = 0.0,
    this.translationY = 0.0,
    this.width = 100.0,
    this.height = 100.0,
    this.rotation = 0.0,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.zIndex = 0,
  });

  final String id;
  final String assetPath;
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

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'type': 'sticker',
    'assetPath': assetPath,
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
}

/// One draft.audioSidecar track entry of a reversed hard-cut smoke draft
/// (wire shape of `VGAudioSidecarTrack.toMap()` for the fields this smoke
/// exercises).
///
/// P5-REVERSE-AUDIO-SIDECAR-EXPORT: [startTime]/[duration] are expressed on
/// the reversed timeline's own output basis -- the plain sum of clip trim
/// windows, since reversing a clip's playback direction does not shorten or
/// overlap the timeline the way a transition does. A track admitted by
/// AndroidTimelineAudioOverlapAdmission routes through the existing pass-2
/// mux/mixdown path exactly like a forward hard-cut timeline's audio tracks
/// do; a track whose timing doesn't fit still fails closed with
/// INVALID_ARG.
@immutable
class VGTimelineReverseExportSmokeAudioTrack {
  const VGTimelineReverseExportSmokeAudioTrack({
    required this.trackId,
    required this.url,
    this.startTime = 0.0,
    this.duration = 1.0,
    this.role,
    this.volume = 1.0,
    this.fadeInSeconds = 0.0,
    this.fadeOutSeconds = 0.0,
    this.sourceTrimStart = 0.0,
  });

  final String trackId;
  final String url;
  final double startTime;
  final double duration;
  final String? role;
  final double volume;
  final double fadeInSeconds;
  final double fadeOutSeconds;
  final double sourceTrimStart;

  /// Matches `VGAudioSidecarTrack.toMap()`'s wire keys/omission rules.
  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'trackId': trackId,
      'url': url,
      'startTime': startTime,
      'duration': duration,
      'volume': volume,
    };
    if (role != null) m['role'] = role;
    if (fadeInSeconds != 0.0) m['fadeInSeconds'] = fadeInSeconds;
    if (fadeOutSeconds != 0.0) m['fadeOutSeconds'] = fadeOutSeconds;
    if (sourceTrimStart != 0.0) m['sourceTrimStart'] = sourceTrimStart;
    return m;
  }
}

/// What a lane expects from the production route.
@immutable
class VGTimelineReverseExportSmokeExpectation {
  const VGTimelineReverseExportSmokeExpectation.success()
    : expectsSuccess = true,
      errorCode = null,
      messageContains = null;

  const VGTimelineReverseExportSmokeExpectation.failClosed({
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
class VGTimelineReverseExportSmokeRequest {
  const VGTimelineReverseExportSmokeRequest({
    required this.laneId,
    required this.clips,
    required this.outputPath,
    required this.expectation,
    this.transitions = const <VGTimelineReverseExportSmokeTransition>[],
    this.overlays = const <VGTimelineReverseExportSmokeOverlay>[],
    this.audioTracks = const <VGTimelineReverseExportSmokeAudioTrack>[],
    this.canvasWidth = 720,
    this.canvasHeight = 1280,
    this.fps = 30,
    this.bitrateBps = 4000000,
  });

  final String laneId;
  final List<VGTimelineReverseExportSmokeClip> clips;
  final String outputPath;
  final VGTimelineReverseExportSmokeExpectation expectation;
  final List<VGTimelineReverseExportSmokeTransition> transitions;
  final List<VGTimelineReverseExportSmokeOverlay> overlays;
  final List<VGTimelineReverseExportSmokeAudioTrack> audioTracks;
  final int canvasWidth;
  final int canvasHeight;
  final int fps;
  final int bitrateBps;

  /// Expected muxed duration for a positive lane: the sum of every clip's
  /// trim window. Reversed clips are hard-cut concatenated exactly like
  /// forward clips -- there is no overlap-shortening in this slice.
  double get expectedDurationSeconds =>
      clips.fold<double>(0.0, (sum, c) => sum + c.durationSeconds);

  /// The exact `exportTimeline` argument map (draft + request keys), matching
  /// the shape VanguardTimelineExporter.exportDraft sends. `audioSidecar` is
  /// present only when [audioTracks] is non-empty, matching
  /// VGEditorDraft.toMap()'s own null-plan omission.
  Map<String, Object?> toExportTimelineArguments() {
    final draft = <String, Object?>{
      'id': 'vg-reverse-export-smoke-$laneId',
      'clips': clips.map((c) => c.toMap()).toList(),
      'transitions': transitions.map((t) => t.toMap()).toList(),
      'canvasWidth': canvasWidth,
      'canvasHeight': canvasHeight,
      'fps': fps,
      'overlays': overlays.map((o) => o.toMap()).toList(),
    };
    if (audioTracks.isNotEmpty) {
      draft['audioSidecar'] = <String, Object?>{
        'tracks': audioTracks.map((t) => t.toMap()).toList(),
      };
    }
    return <String, Object?>{
      'draft': draft,
      'outputPath': outputPath,
      'bitrateBps': bitrateBps,
      'width': canvasWidth,
      'height': canvasHeight,
      'fps': fps,
    };
  }
}

/// Per-lane verdict.
@immutable
class VGTimelineReverseExportSmokeLaneReport {
  const VGTimelineReverseExportSmokeLaneReport({
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
  factory VGTimelineReverseExportSmokeLaneReport.fromExportResult(
    VGTimelineReverseExportSmokeRequest request,
    Map<Object?, Object?>? result, {
    required bool outputExists,
  }) {
    final expected = request.expectedDurationSeconds;
    if (result == null) {
      return VGTimelineReverseExportSmokeLaneReport(
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

    String? failure;
    if (!request.expectation.expectsSuccess) {
      failure = 'expected_fail_closed_but_export_succeeded';
    } else if (!success) {
      failure = 'result_success_false';
    } else if (path == null || path.isEmpty) {
      failure = 'result_path_missing';
    } else if (!outputExists) {
      failure = 'output_file_missing';
    } else if (backend != expectedReverseRenderBackend) {
      failure = 'render_backend_not_gles:${backend ?? 'null'}';
    } else if (duration == null) {
      failure = 'result_duration_missing';
    } else if ((duration - expected).abs() >
        VGTimelineReverseExportSmokeReport.durationToleranceSeconds) {
      failure =
          'duration_mismatch:measured=${duration.toStringAsFixed(3)}:'
          'expected=${expected.toStringAsFixed(3)}';
    }
    final pass = failure == null;
    return VGTimelineReverseExportSmokeLaneReport(
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
    );
  }

  /// Evaluates a production PlatformException against [request]'s
  /// fail-closed expectation.
  factory VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
    VGTimelineReverseExportSmokeRequest request,
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
    return VGTimelineReverseExportSmokeLaneReport(
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
  factory VGTimelineReverseExportSmokeLaneReport.harnessException(
    VGTimelineReverseExportSmokeRequest request,
    Object error,
  ) => VGTimelineReverseExportSmokeLaneReport(
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
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  /// Parses a map produced by [toMap]. Missing/invalid fields fail closed.
  static VGTimelineReverseExportSmokeLaneReport fromMap(
    Map<Object?, Object?> map,
  ) {
    return VGTimelineReverseExportSmokeLaneReport(
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
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }
}

/// Whole-run verdict over every lane.
@immutable
class VGTimelineReverseExportSmokeReport {
  const VGTimelineReverseExportSmokeReport({required this.lanes});

  /// Canonical proof boundary string.
  static const String proofBoundary =
      'production_exportTimeline_gles_reverse_video_route';

  /// Canonical PASS marker.
  static const String passMarker =
      'ANDROID_TIMELINE_REVERSE_EXPORT_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker.
  static const String failMarker =
      'ANDROID_TIMELINE_REVERSE_EXPORT_PHYSICAL_SMOKE_FAIL';

  /// Allowed |measured - expected| duration for a positive lane -- the fixed
  /// frame clock (AndroidTimelineVideoEncoder) makes muxed duration a direct
  /// function of the written sample count, so this mirrors the same
  /// tolerance the transition/overlay smoke models use for seek/window
  /// boundary slack.
  static const double durationToleranceSeconds = 0.25;

  final List<VGTimelineReverseExportSmokeLaneReport> lanes;

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
  static VGTimelineReverseExportSmokeReport fromMap(Map<Object?, Object?> map) {
    final rawLanes = map['lanes'];
    final lanes = <VGTimelineReverseExportSmokeLaneReport>[];
    if (rawLanes is List) {
      for (final raw in rawLanes) {
        if (raw is Map<Object?, Object?>) {
          lanes.add(VGTimelineReverseExportSmokeLaneReport.fromMap(raw));
        } else if (raw is Map) {
          lanes.add(
            VGTimelineReverseExportSmokeLaneReport.fromMap(
              raw.map((k, v) => MapEntry<Object?, Object?>(k, v)),
            ),
          );
        }
      }
    }
    return VGTimelineReverseExportSmokeReport(lanes: lanes);
  }
}

/// Runs smoke lanes through the real production `exportTimeline` route.
class VGTimelineReverseExportSmokeRunner {
  const VGTimelineReverseExportSmokeRunner({
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
  Future<VGTimelineReverseExportSmokeLaneReport> runLane(
    VGTimelineReverseExportSmokeRequest request,
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
      return VGTimelineReverseExportSmokeLaneReport.fromExportResult(
        request,
        result,
        outputExists: exists,
      );
    } on PlatformException catch (e) {
      return VGTimelineReverseExportSmokeLaneReport.fromPlatformException(
        request,
        e,
      );
    } on MissingPluginException catch (e) {
      return VGTimelineReverseExportSmokeLaneReport.harnessException(
        request,
        'missing_plugin:$e',
      );
    } on TimeoutException catch (e) {
      return VGTimelineReverseExportSmokeLaneReport.harnessException(
        request,
        'timeout:$e',
      );
    } catch (e) {
      return VGTimelineReverseExportSmokeLaneReport.harnessException(
        request,
        e,
      );
    }
  }

  /// Runs every lane sequentially (the native route holds a single export
  /// lock; concurrent calls would be rejected with EXPORT_IN_PROGRESS).
  Future<VGTimelineReverseExportSmokeReport> run(
    List<VGTimelineReverseExportSmokeRequest> requests,
  ) async {
    final lanes = <VGTimelineReverseExportSmokeLaneReport>[];
    for (final request in requests) {
      lanes.add(await runLane(request));
    }
    return VGTimelineReverseExportSmokeReport(lanes: lanes);
  }
}
