// ios_arkit_person_segmentation_matte_capture_replay_physical_smoke.dart
// Vanguard Media Engine — iOS ARKit live matte capture bundle + deterministic
// replay / matte stage dump (RND quality-science harness).
//
// Discardable RND physical harness (proofBoundary
// 'ios_arkit_person_segmentation_matte_capture_replay_physical_smoke'): drives
// the diagnostic-only native routes startLiveGreenScreenARKitPreviewProbe /
// stopLiveGreenScreenARKitPreviewProbe (with the optional one-shot replay
// bundle capture), replayLiveGreenScreenInputBundle and
// runLiveGreenScreenMatteStageLab directly over
// MethodChannel('vanguard_media_engine'). Not part of the public
// vanguard_media_engine Dart API and not a production green-screen path.
//
// Purpose: freeze one correct ARKit (ARMatteGenerator, full resolution,
// leftMirrored, aspect-filled) camera + matte baseline bundle from a live
// front-camera frame and render its deterministic replay PNG and matte
// stage PNGs across requested refinement modes (s1, s4GuidedAlphaR1,
// s5GuidedFilterR1) for same-capture offline A/B quality-science inspection.
//
// Flow:
//   1. unique run root under Directory.systemTemp (or
//      IOS_ARKIT_CAPTURE_REPLAY_ROOT_DIR): <root>/vg_arkit_live_capture_<epoch>_<id>/
//      with bundle/, replay.png and stages_<mode>/
//   2. start the ARKit live preview probe with captureBundleOutputDir +
//      captureBundleLabel
//   3. show Texture(textureId) full screen for the hold
//   4. stop; require native pass=true, captureBundleCaptured=true, and the four
//      bundle files (metadata.json, background.bgra, camera.bgra, mask.r8)
//      present and non-empty
//   5. replayLiveGreenScreenInputBundle → replay.png
//   6. runLiveGreenScreenMatteStageLab (once per requested refinement mode)
//      → stage PNGs in <runRoot>/stages_<mode>
//   7. verify every reported output file exists non-empty
//   8. print JSON and exit 0 on pass / 1 on fail
//
// Dart-defines: IOS_ARKIT_CAPTURE_REPLAY_HOLD_SECONDS (default 5),
// IOS_ARKIT_CAPTURE_REPLAY_TARGET_FPS (default 30),
// IOS_ARKIT_CAPTURE_REPLAY_WIDTH (default 1080),
// IOS_ARKIT_CAPTURE_REPLAY_HEIGHT (default 1920),
// IOS_ARKIT_CAPTURE_REPLAY_ROOT_DIR (default '' = Directory.systemTemp),
// IOS_ARKIT_CAPTURE_REPLAY_LABEL (default 'arkit_live_capture_replay'),
// IOS_ARKIT_CAPTURE_REPLAY_CAPTURE_AFTER_FRAMES (default 45),
// IOS_ARKIT_CAPTURE_REPLAY_DISPLAY_ORIENTATION (default 'leftMirrored',
// either 'leftMirrored' or 'right'),
// IOS_ARKIT_CAPTURE_REPLAY_REFINEMENT_MODES (default 's1', comma-separated subset
// of s1, s4GuidedAlphaR1, s5GuidedFilterR1),
// IOS_ARKIT_CAPTURE_REPLAY_EMIT_PNG_BASE64 (default false).
//
// Markers: IOS_ARKIT_CAPTURE_REPLAY_CONFIG, IOS_ARKIT_CAPTURE_REPLAY_START,
// IOS_ARKIT_CAPTURE_REPLAY_CAPTURED, IOS_ARKIT_CAPTURE_REPLAY_REPLAY_DONE,
// IOS_ARKIT_CAPTURE_REPLAY_STAGE_LAB_DONE,
// IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_BEGIN,
// IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_CHUNK,
// IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_END,
// IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_EXPORT_DONE,
// IOS_ARKIT_CAPTURE_REPLAY_LIVE_TELEMETRY,
// IOS_ARKIT_CAPTURE_REPLAY_JSON:<json>,
// IOS_ARKIT_CAPTURE_REPLAY_PASS / IOS_ARKIT_CAPTURE_REPLAY_FAIL.
//
// Non-claims: no production promotion, no tuning constants, no TikTok parity
// claim, no visual metric comparison; no export MP4, no image/video
// background, no audio, no Vision/LiteRT comparison; base64 PNG stdout emission
// is a physical diagnostic transport workaround when devicectl artifact copying
// fails, not a quality claim.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _holdSeconds = int.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_HOLD_SECONDS',
  defaultValue: 5,
);

const int _targetFps = int.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_TARGET_FPS',
  defaultValue: 30,
);

const int _width = int.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_WIDTH',
  defaultValue: 1080,
);

const int _height = int.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_HEIGHT',
  defaultValue: 1920,
);

/// Optional run-root override; empty means Directory.systemTemp.
const String _rootDirOverride = String.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_ROOT_DIR',
  defaultValue: '',
);

/// Label passed to the native capture, replay, and stage lab.
const String _label = String.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_LABEL',
  defaultValue: 'arkit_live_capture_replay',
);

/// Number of successfully composited published frames before capturing the
/// replay bundle (warmup gate to avoid capturing un-converged face segmentation).
const int _captureAfterFrames = int.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_CAPTURE_AFTER_FRAMES',
  defaultValue: 45,
);

/// Display orientation mode for ARKit live preview probe and replay capture.
/// Defaults to 'leftMirrored' (selfie mirror); 'right' gives upright non-mirrored.
const String _displayOrientation = String.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_DISPLAY_ORIENTATION',
  defaultValue: 'leftMirrored',
);

const Set<String> kAcceptedDisplayOrientations = <String>{
  'leftMirrored',
  'right',
};

/// Optional opt-in flag to emit generated replay and stage PNG artifacts to
/// stdout in base64 chunks. Transport workaround when Apple devicectl /
/// CoreDevice file copying fails.
const bool _emitPngBase64 = bool.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_EMIT_PNG_BASE64',
  defaultValue: false,
);

/// Chunk size (in base64 characters) when emitting PNG artifacts to stdout.
/// Kept bounded to fit safely within platform logging line buffers.
const int _artifactChunkSize = 700;

const String _proofBoundary =
    'ios_arkit_person_segmentation_matte_capture_replay_physical_smoke';

/// The native coordinator is shared with the live harness and reports its own
/// proof boundary; it must be exactly this one.
const String _nativeLiveProofBoundary =
    'ios_arkit_person_segmentation_matte_live_physical_smoke';

/// Default (live pipeline) matte refinement mode.
const String kRefinementModeS1 = 's1';

/// Diagnostic-only RND candidate refinement mode (matte stage lab only).
const String kRefinementModeS4GuidedAlphaR1 = 's4GuidedAlphaR1';

/// Diagnostic-only RND candidate refinement mode (matte stage lab only).
const String kRefinementModeS5GuidedFilterR1 = 's5GuidedFilterR1';

/// Exact refinement mode strings accepted natively
/// (VGDuetPreviewCompositor.GreenScreenRefinementMode raw values).
const List<String> kAcceptedRefinementModes = <String>[
  kRefinementModeS1,
  kRefinementModeS4GuidedAlphaR1,
  kRefinementModeS5GuidedFilterR1,
];

/// Extra stage PNG native writes only for [kRefinementModeS4GuidedAlphaR1];
/// pre-checked for collisions, then verified via the reported paths.
const String kS4BandStageKey = 's4RefinementBand';
const String kS4BandStageFile = '08_s4_guided_alpha_band.png';

/// Extra stage PNG native writes only for [kRefinementModeS5GuidedFilterR1];
/// pre-checked for collisions, then verified via the reported paths.
const String kS5BandStageKey = 's5RefinementBand';
const String kS5BandStageFile = '08_s5_guided_filter_band.png';

/// Comma-separated subset/order of refinement modes to run and compare against
/// the same captured ARKit replay bundle. Defaults to "s1".
const String _rawRefinementModes = String.fromEnvironment(
  'IOS_ARKIT_CAPTURE_REPLAY_REFINEMENT_MODES',
  defaultValue: kRefinementModeS1,
);

/// Validates the refinement modes dart-define: comma-separated subset/order of
/// exactly: s1, s4GuidedAlphaR1, s5GuidedFilterR1. Rejects empty, unknown, or
/// duplicate modes before start.
List<String> parseRefinementModes(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError(
      'IOS_ARKIT_CAPTURE_REPLAY_REFINEMENT_MODES must not be empty',
    );
  }
  final parts = trimmed.split(',');
  final result = <String>[];
  final seen = <String>{};
  for (final part in parts) {
    final mode = part.trim();
    if (mode.isEmpty) {
      throw ArgumentError(
        'IOS_ARKIT_CAPTURE_REPLAY_REFINEMENT_MODES contains an empty mode in "$raw"',
      );
    }
    if (!kAcceptedRefinementModes.contains(mode)) {
      throw ArgumentError(
        'Unknown refinement mode "$mode" in "$raw". Accepted modes: '
        '${kAcceptedRefinementModes.join(', ')}',
      );
    }
    if (!seen.add(mode)) {
      throw ArgumentError(
        'Duplicate refinement mode "$mode" in "$raw"',
      );
    }
    result.add(mode);
  }
  return List<String>.unmodifiable(result);
}

const String _startMethod = 'startLiveGreenScreenARKitPreviewProbe';
const String _stopMethod = 'stopLiveGreenScreenARKitPreviewProbe';
const String _replayMethod = 'replayLiveGreenScreenInputBundle';
const String _stageLabMethod = 'runLiveGreenScreenMatteStageLab';

const MethodChannel _channel = MethodChannel('vanguard_media_engine');

/// Watchdog for the live start/stop calls (synchronous natively; the margin
/// covers ARSession start-up and the bounded stop render drain).
const Duration _liveCallTimeout = Duration(seconds: 15);

/// Watchdog for the offline replay / stage lab calls (synchronous on the
/// platform thread; full-canvas CoreImage renders plus PNG encodes).
const Duration _offlineCallTimeout = Duration(seconds: 90);

/// Bundle files VGLiveGreenScreenReplayDiagnostics.writeReplayInputBundle
/// writes; every one must exist non-empty for PASS.
const List<String> _bundleFiles = <String>[
  'metadata.json',
  'background.bgra',
  'camera.bgra',
  'mask.r8',
];

/// Stage PNG map keys expected in the `paths` map returned by the stage lab
/// for refinementMode s1 and their stable file names (mirrors
/// VGLiveGreenScreenReplayDiagnostics.matteStageFiles).
const Map<String, String> _standardStageFiles = <String, String>{
  'rawMask': '01_raw_mask.png',
  'aspectFilledMask': '02_aspect_filled_mask.png',
  'postMorphology': '03_post_morphology.png',
  'postFeather': '04_post_feather.png',
  'postTrimap': '05_post_trimap.png',
  'postGuidedEdge': '06_post_guided_edge.png',
  'finalComposite': '07_final_composite.png',
};

/// Returns expected stage files and keys for a specific [mode].
Map<String, String> expectedStageFilesForMode(String mode) {
  switch (mode) {
    case kRefinementModeS1:
      return _standardStageFiles;
    case kRefinementModeS4GuidedAlphaR1:
      return <String, String>{
        ..._standardStageFiles,
        kS4BandStageKey: kS4BandStageFile,
      };
    case kRefinementModeS5GuidedFilterR1:
      return <String, String>{
        ..._standardStageFiles,
        kS5BandStageKey: kS5BandStageFile,
      };
    default:
      throw ArgumentError('Unknown refinement mode: $mode');
  }
}

const List<String> _claims = <String>[
  'One replay input bundle (metadata.json, background.bgra, camera.bgra, mask.r8) was captured natively from a successfully composited live ARKit frame at or after the warmup threshold using the identical oriented/aspect-filled camera and matte the live composite blended, at full canvas size with full-canvas sourceRect/cameraRect.',
  'The bundle replays deterministically through replayLiveGreenScreenInputBundle to one PNG and through runLiveGreenScreenMatteStageLab (per requested refinement mode) to one PNG per matte stage, and every reported output file exists non-empty.',
  'Live-preview telemetry (frame cadence, matte/composite timing, drop/skip/throttle counts) for the hold is carried through from the native stop summary.',
];

const List<String> _nonClaims = <String>[
  'No production promotion: diagnostic-only routes over a discardable RND coordinator; no public Dart API is exercised.',
  'No tuning: no visual tuning constants are changed or proposed.',
  'No TikTok parity claim.',
  'No visual metric comparison yet: this only freezes a correct ARKit baseline bundle and renders replay artifacts for inspection.',
  'The captured frame is taken at or after the warmup threshold (default 45 published frames), not a chosen or representative pose.',
  'No export MP4, no image or video background (solid teal only), no audio, no Vision/LiteRT comparison.',
  'Base64 PNG stdout emission is a physical diagnostic transport workaround when devicectl artifact copying fails, not a quality claim.',
];

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return null;
}

String? _asNonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, dynamic>? _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

String _stripTrailingSlashes(String path) {
  var out = path;
  while (out.length > 1 && out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// Unique run root: `<root>/vg_arkit_live_capture_<epochMs>_<6 hex>`.
String _makeRunRootPath() {
  final root = _rootDirOverride.trim().isEmpty
      ? Directory.systemTemp.path
      : _rootDirOverride.trim();
  final epoch = DateTime.now().millisecondsSinceEpoch;
  final shortId = Random()
      .nextInt(0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0');
  return '${_stripTrailingSlashes(root)}/vg_arkit_live_capture_${epoch}_$shortId';
}

/// Returns null when [path] exists with a non-zero size, else a reason.
Future<String?> _fileProblem(String path) async {
  final file = File(path);
  if (!await file.exists()) return 'missing';
  final length = await file.length();
  if (length <= 0) return 'empty';
  return null;
}

void main() {
  print('IOS_ARKIT_CAPTURE_REPLAY_CONFIG '
      'holdSeconds=$_holdSeconds targetFps=$_targetFps '
      'width=$_width height=$_height '
      'rootDir=${_rootDirOverride.trim().isEmpty ? 'systemTemp' : _rootDirOverride.trim()} '
      'label=$_label refinementModes=$_rawRefinementModes '
      'refinementMode=$_rawRefinementModes '
      'captureAfterFrames=$_captureAfterFrames '
      'captureBundleAfterPublishedFrames=$_captureAfterFrames '
      'trackingConfiguration=face '
      'displayOrientation=$_displayOrientation '
      'orientationMode=$_displayOrientation background=teal '
      'emitPngBase64=$_emitPngBase64');
  runApp(const IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeApp());
}

class IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeApp
    extends StatefulWidget {
  const IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeApp>
      createState() =>
          _IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeAppState();
}

class _IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeAppState
    extends State<IosArkitPersonSegmentationMatteCaptureReplayPhysicalSmokeApp> {
  String _status = 'Initializing ARKit capture + replay…';
  int? _textureId;
  int _textureWidth = _width;
  int _textureHeight = _height;
  Map<String, dynamic>? _startMap;
  Map<String, dynamic>? _stopMap;
  String _runRoot = '';
  List<String> _failureReasons = const <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _run();
    });
  }

  void _setStatus(String status) {
    if (mounted) {
      setState(() => _status = status);
    }
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method,
    Map<String, Object?> args,
    Duration timeout,
  ) async {
    final response =
        await _channel.invokeMethod<Object?>(method, args).timeout(timeout);
    if (response == null || response is! Map) {
      throw StateError('$method returned invalid response: $response');
    }
    return Map<String, dynamic>.from(response);
  }

  String _describeError(Object error, [StackTrace? stack]) {
    if (error is TimeoutException) return 'Watchdog timeout: $error';
    if (error is PlatformException) {
      return 'PlatformException(${error.code}): ${error.message}';
    }
    return stack == null ? '$error' : '$error\n$stack';
  }

  Future<void> _run() async {
    final failureReasons = <String>[];
    Map<String, dynamic>? startMap;
    Map<String, dynamic>? stopMap;
    Map<String, dynamic>? replayMap;
    String? startError;
    String? stopError;
    String? replayError;
    String? sessionId;
    int? textureId;
    var bundleVerified = false;
    var replayVerified = false;
    var artifactExportVerified = false;
    final exportedArtifactNames = <String>[];
    String? artifactExportError;
    final bundleFileProblems = <String, String>{};

    List<String> requestedRefinementModes = const <String>[];
    try {
      requestedRefinementModes = parseRefinementModes(_rawRefinementModes);
    } catch (e, st) {
      final message = _describeError(e, st);
      failureReasons.add('refinement_modes_invalid: $message');
      print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $message');
    }

    final primaryMode = requestedRefinementModes.isNotEmpty
        ? requestedRefinementModes.first
        : kRefinementModeS1;

    // ---- paths ----------------------------------------------------------
    final runRoot = _makeRunRootPath();
    final bundleDir = '$runRoot/bundle';
    final replayPath = '$runRoot/replay.png';
    final defaultStageOutputDir = '$runRoot/stages_$primaryMode';

    final perModeStageOutputDir = <String, String>{
      for (final mode in requestedRefinementModes)
        mode: '$runRoot/stages_$mode',
    };
    final perModeStagePaths = <String, Map<String, String>>{};
    final perModeStageLabResults = <String, Map<String, dynamic>>{};
    final perModeStageLabErrors = <String, String>{};
    final perModeStageLabVerified = <String, bool>{};

    final stageOutputDir =
        perModeStageOutputDir[primaryMode] ?? defaultStageOutputDir;
    if (mounted) {
      setState(() => _runRoot = runRoot);
    }
    try {
      final rootDir = Directory(runRoot);
      if (await rootDir.exists()) {
        throw FileSystemException(
          'Run root already exists; a fresh unique path is required',
          runRoot,
        );
      }
      // The native bundle writer creates bundleDir itself (and refuses to
      // overwrite); replay needs the parent of replayPath to exist.
      await rootDir.create(recursive: true);
      if (await Directory(bundleDir).exists()) {
        throw FileSystemException(
          'Bundle dir already exists; overwriting refused for determinism',
          bundleDir,
        );
      }
    } catch (e, st) {
      final message = _describeError(e, st);
      failureReasons.add('run_root_setup_failed: $message');
      print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $message');
    }
    if (!kAcceptedDisplayOrientations.contains(_displayOrientation)) {
      final message =
          'displayOrientation must be one of $kAcceptedDisplayOrientations '
          '(got "$_displayOrientation")';
      failureReasons.add('display_orientation_invalid: $message');
      print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $message');
    }
    final setupOk = failureReasons.isEmpty;

    print('IOS_ARKIT_CAPTURE_REPLAY_START '
        'width=$_width height=$_height targetFps=$_targetFps '
        'holdSeconds=$_holdSeconds '
        'displayOrientation=$_displayOrientation '
        'captureBundleAfterPublishedFrames=$_captureAfterFrames '
        'bundleDir=$bundleDir replayPath=$replayPath '
        'stageOutputDir=$stageOutputDir '
        'refinementModes=${requestedRefinementModes.join(',')} label=$_label');

    // ---- start (with capture) --------------------------------------------
    if (setupOk) {
      _setStatus('Starting ARKit live preview + capture…');
      try {
        startMap = await _invokeMap(
          _startMethod,
          <String, Object?>{
            'width': _width,
            'height': _height,
            'targetFps': _targetFps,
            'trackingConfiguration': 'face',
            'displayOrientationMode': _displayOrientation,
            'captureBundleOutputDir': bundleDir,
            'captureBundleLabel': _label,
            'captureBundleAfterPublishedFrames': _captureAfterFrames,
          },
          _liveCallTimeout,
        );
        sessionId = _asNonEmptyString(startMap['sessionId']);
        textureId = _asInt(startMap['textureId']);
        if (textureId == null) {
          failureReasons.add(
            'start_missing_texture_id: '
            '${_asNonEmptyString(startMap['failureReason']) ?? 'native start returned no textureId'}',
          );
        } else if (startMap['captureBundleRequested'] != true) {
          failureReasons.add('start_capture_not_requested_natively');
        } else if (_asInt(startMap['captureBundleAfterPublishedFrames']) !=
            _captureAfterFrames) {
          failureReasons.add(
            'start_capture_after_published_frames_mismatch: '
            '${startMap['captureBundleAfterPublishedFrames']} != $_captureAfterFrames',
          );
        } else if (startMap['orientationMode'] != _displayOrientation) {
          failureReasons.add(
            'start_orientation_mode_mismatch: '
            '${startMap['orientationMode']} != $_displayOrientation',
          );
        }
      } catch (e, st) {
        startError = _describeError(e, st);
      }
      if (startError != null) {
        failureReasons.add('start_failed: $startError');
        print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $startError');
      }
    }

    final started = setupOk && startError == null && textureId != null;
    if (started) {
      final width = _asInt(startMap?['width']) ?? _width;
      final height = _asInt(startMap?['height']) ?? _height;
      print('IOS_ARKIT_CAPTURE_REPLAY_STARTED '
          'sessionId=$sessionId textureId=$textureId '
          'width=$width height=$height '
          'orientationMode=${startMap?['orientationMode']} '
          'videoFormat=${startMap?['videoFormatWidth']}x${startMap?['videoFormatHeight']}'
          '@${startMap?['videoFormatFramesPerSecond']} '
          'captureBundleOutputDir=${startMap?['captureBundleOutputDir']} '
          'captureBundleLabel=${startMap?['captureBundleLabel']} '
          'captureBundleAfterPublishedFrames=${startMap?['captureBundleAfterPublishedFrames']}');
      if (mounted) {
        setState(() {
          _startMap = startMap;
          _textureId = textureId;
          _textureWidth = width;
          _textureHeight = height;
          _status = 'LIVE — capturing, holding ${_holdSeconds}s';
        });
      }
      // ---- hold ---------------------------------------------------------
      await Future<void>.delayed(Duration(seconds: _holdSeconds));
    } else if (mounted) {
      setState(() {
        _startMap = startMap;
        _status = 'START FAILED';
      });
    }

    // ---- stop -----------------------------------------------------------
    // A fail-closed start map (no textureId) retains nothing natively, so a
    // stop is only issued after a started probe.
    if (started) {
      _setStatus('Stopping…');
      try {
        stopMap = await _invokeMap(
          _stopMethod,
          // null sessionId arrives natively as NSNull and is treated as absent.
          <String, Object?>{'sessionId': sessionId},
          _liveCallTimeout,
        );
      } catch (e, st) {
        stopError = _describeError(e, st);
      }
      if (stopError != null) {
        failureReasons.add('stop_failed: $stopError');
        print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $stopError');
      }
      if (mounted) {
        setState(() {
          _textureId = null; // texture is unregistered natively after stop
          _stopMap = stopMap;
        });
      }
    }

    // ---- evaluate live summary + bundle ----------------------------------
    if (started) {
      if (stopMap == null) {
        if (stopError == null) failureReasons.add('stop_summary_missing');
      } else {
        _evaluateStopSummary(stopMap, bundleDir, failureReasons);
        for (final name in _bundleFiles) {
          final problem = await _fileProblem('$bundleDir/$name');
          if (problem != null) bundleFileProblems[name] = problem;
        }
        if (bundleFileProblems.isNotEmpty) {
          failureReasons.add('bundle_files_invalid: $bundleFileProblems');
        }
        bundleVerified = stopMap['pass'] == true &&
            stopMap['captureBundleCaptured'] == true &&
            bundleFileProblems.isEmpty &&
            failureReasons.isEmpty;
      }
    }

    final captureBundle = _asMap(stopMap?['captureBundle']);
    if (bundleVerified) {
      print('IOS_ARKIT_CAPTURE_REPLAY_CAPTURED '
          'bundleDir=$bundleDir label=${captureBundle?['label']} '
          'canvas=${captureBundle?['canvasWidth']}x${captureBundle?['canvasHeight']} '
          'captureBundleFrameIndex=${stopMap?['captureBundleFrameIndex']} '
          'captureBundleAfterPublishedFrames=${stopMap?['captureBundleAfterPublishedFrames']} '
          'captureBundleMs=${stopMap?['captureBundleMs']} '
          'files=${_bundleFiles.join(',')}');
    } else {
      print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: capture bundle not verified '
          '(nativePass=${stopMap?['pass']} '
          'captureBundleCaptured=${stopMap?['captureBundleCaptured']} '
          'captureBundleFailureReason=${stopMap?['captureBundleFailureReason']} '
          'failureReason=${stopMap?['failureReason']} '
          'bundleFileProblems=$bundleFileProblems)');
    }

    // ---- replay ---------------------------------------------------------
    if (bundleVerified) {
      _setStatus('Replaying bundle…');
      try {
        if (await File(replayPath).exists()) {
          throw FileSystemException(
            'Replay output already exists; overwriting refused for determinism',
            replayPath,
          );
        }
        replayMap = await _invokeMap(
          _replayMethod,
          <String, Object?>{
            'inputDir': bundleDir,
            'outputPath': replayPath,
            'label': _label,
          },
          _offlineCallTimeout,
        );
        final reportedPath = _asNonEmptyString(replayMap['path']);
        if (reportedPath == null) {
          throw StateError('$_replayMethod result is missing "path"');
        }
        if (reportedPath != replayPath) {
          throw StateError(
            '$_replayMethod reported path "$reportedPath" but "$replayPath" was requested',
          );
        }
        final problem = await _fileProblem(reportedPath);
        if (problem != null) {
          throw StateError('Replay PNG is $problem at $reportedPath');
        }
        final replayWidth = _asInt(replayMap['width']);
        final replayHeight = _asInt(replayMap['height']);
        if (replayWidth != _width || replayHeight != _height) {
          throw StateError(
            'Replay dimensions ${replayWidth}x$replayHeight differ from canvas ${_width}x$_height',
          );
        }
        replayVerified = true;
      } catch (e, st) {
        replayError = _describeError(e, st);
      }
      if (replayError != null) {
        failureReasons.add('replay_failed: $replayError');
        print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $replayError');
      }
    }
    if (replayVerified) {
      print('IOS_ARKIT_CAPTURE_REPLAY_REPLAY_DONE '
          'replayPath=$replayPath '
          'width=${replayMap?['width']} height=${replayMap?['height']} '
          'bytes=${replayMap?['bytes']}');
    }

    // ---- matte stage lab (per requested refinement mode) -----------------
    if (bundleVerified && requestedRefinementModes.isNotEmpty) {
      for (final mode in requestedRefinementModes) {
        final modeOutputDir = perModeStageOutputDir[mode]!;
        _setStatus('Running matte stage lab ($mode)…');
        try {
          final expectedFiles = expectedStageFilesForMode(mode);
          for (final fileName in expectedFiles.values) {
            if (await File('$modeOutputDir/$fileName').exists()) {
              throw FileSystemException(
                'Stage output file already exists; overwriting refused for determinism',
                '$modeOutputDir/$fileName',
              );
            }
          }
          final labResult = await _invokeMap(
            _stageLabMethod,
            <String, Object?>{
              'inputDir': bundleDir,
              'outputDir': modeOutputDir,
              'label': _label,
              'refinementMode': mode,
            },
            _offlineCallTimeout,
          );
          final modePaths = <String, String>{};
          await _verifyStageLab(
            raw: labResult,
            stageOutputDir: modeOutputDir,
            mode: mode,
            stagePaths: modePaths,
          );
          perModeStageLabResults[mode] = labResult;
          perModeStagePaths[mode] = modePaths;
          perModeStageLabVerified[mode] = true;
          print('IOS_ARKIT_CAPTURE_REPLAY_STAGE_LAB_DONE '
              'stageOutputDir=$modeOutputDir refinementMode=$mode '
              'files=${labResult['files']} '
              'appliedFlags=${labResult['appliedFlags']}');
        } catch (e, st) {
          final error = _describeError(e, st);
          perModeStageLabErrors[mode] = error;
          perModeStageLabVerified[mode] = false;
          failureReasons.add('stage_lab_failed_$mode: $error');
          print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: [$mode] $error');
        }
      }
    }

    final stageLabVerified = bundleVerified &&
        requestedRefinementModes.isNotEmpty &&
        requestedRefinementModes.every(
          (mode) => perModeStageLabVerified[mode] == true,
        );

    // ---- base64 artifact emission (opt-in RND transport workaround) ------
    if (_emitPngBase64) {
      if (replayVerified && stageLabVerified) {
        _setStatus('Emitting PNG artifacts (base64)…');
        try {
          final names = await _emitPngArtifacts(
            replayPath: replayPath,
            requestedRefinementModes: requestedRefinementModes,
            perModeStagePaths: perModeStagePaths,
          );
          exportedArtifactNames.addAll(names);
          artifactExportVerified = true;
        } catch (e, st) {
          artifactExportError = _describeError(e, st);
          failureReasons.add('artifact_emission_failed: $artifactExportError');
          print('IOS_ARKIT_CAPTURE_REPLAY_ERROR: $artifactExportError');
        }
      } else {
        failureReasons.add(
          'artifact_emission_skipped_due_to_unverified_replay_or_stages',
        );
      }
    }

    // ---- markers / JSON --------------------------------------------------
    final summary = stopMap;
    print('IOS_ARKIT_CAPTURE_REPLAY_LIVE_TELEMETRY '
        'frameCount=${summary?['frameCount']} '
        'maskCount=${summary?['maskCount']} '
        'publishedFrames=${summary?['publishedFrames']} '
        'droppedBusyFrames=${summary?['droppedBusyFrames']} '
        'skippedNoMaskFrames=${summary?['skippedNoMaskFrames']} '
        'throttledFrames=${summary?['throttledFrames']} '
        'droppedPoolExhaustedFrames=${summary?['droppedPoolExhaustedFrames']} '
        'effectiveFps=${summary?['effectiveFps']} '
        'avgMatteGenerationMs=${summary?['avgMatteGenerationMs']} '
        'p95MatteGenerationMs=${summary?['p95MatteGenerationMs']} '
        'avgCompositeMs=${summary?['avgCompositeMs']} '
        'p95CompositeMs=${summary?['p95CompositeMs']} '
        'firstMaskLatencyMs=${summary?['firstMaskLatencyMs']} '
        'runDurationMs=${summary?['runDurationMs']} '
        'nativePass=${summary?['pass']} '
        'failureReason=${summary?['failureReason']} '
        'captureBundleAfterPublishedFrames=${summary?['captureBundleAfterPublishedFrames']}');

    final pass = failureReasons.isEmpty &&
        started &&
        bundleVerified &&
        replayVerified &&
        stageLabVerified &&
        (!_emitPngBase64 || artifactExportVerified);

    final legacyStagePaths =
        perModeStagePaths[primaryMode] ?? const <String, String>{};
    final legacyStageLabResult = perModeStageLabResults[primaryMode];
    final legacyStageLabError = perModeStageLabErrors[primaryMode] ??
        (perModeStageLabErrors.isNotEmpty
            ? perModeStageLabErrors.values.first
            : null);

    final payload = <String, dynamic>{
      'proofBoundary': _proofBoundary,
      'pass': pass,
      'config': <String, dynamic>{
        'holdSeconds': _holdSeconds,
        'targetFps': _targetFps,
        'width': _width,
        'height': _height,
        'rootDirOverride': _rootDirOverride,
        'label': _label,
        'refinementModes': requestedRefinementModes,
        'refinementMode': primaryMode,
        'trackingConfiguration': 'face',
        'displayOrientation': _displayOrientation,
        'displayOrientationMode': _displayOrientation,
        'captureAfterFrames': _captureAfterFrames,
        'captureBundleAfterPublishedFrames': _captureAfterFrames,
        'emitPngBase64': _emitPngBase64,
      },
      'runRoot': runRoot,
      'bundleDir': bundleDir,
      'replayPath': replayPath,
      'displayOrientation': _displayOrientation,
      'displayOrientationMode': _displayOrientation,
      'refinementModes': requestedRefinementModes,
      'perModeStageOutputDir': perModeStageOutputDir,
      'perModeStagePaths': perModeStagePaths,
      'perModeStageLabResults': perModeStageLabResults,
      'perModeStageLabErrors': perModeStageLabErrors,
      'perModeStageLabVerified': perModeStageLabVerified,
      'stageOutputDir': stageOutputDir,
      'stagePaths': legacyStagePaths,
      'bundleFiles': _bundleFiles,
      'bundleFileProblems': bundleFileProblems,
      'nativeStartSucceeded': started,
      'nativeStopPass': summary?['pass'],
      'bundleVerified': bundleVerified,
      'replayVerified': replayVerified,
      'stageLabVerified': stageLabVerified,
      'emitPngBase64': _emitPngBase64,
      'artifactExportVerified': artifactExportVerified,
      'exportedArtifactNames': exportedArtifactNames,
      'sessionId': summary?['sessionId'] ?? sessionId,
      'textureId': summary?['textureId'] ?? textureId,
      'captureBundleRequested': summary?['captureBundleRequested'],
      'captureBundleAfterPublishedFrames':
          summary?['captureBundleAfterPublishedFrames'] ?? _captureAfterFrames,
      'captureBundleCaptured': summary?['captureBundleCaptured'],
      'captureBundleFrameIndex': summary?['captureBundleFrameIndex'],
      'captureBundleMs': summary?['captureBundleMs'],
      'captureBundleFailureReason': summary?['captureBundleFailureReason'],
      'captureBundle': captureBundle,
      'liveSummary': <String, dynamic>{
        'proofBoundary': summary?['proofBoundary'],
        'trackingConfiguration': summary?['trackingConfiguration'],
        'activeTrackingUsesFrontCamera':
            summary?['activeTrackingUsesFrontCamera'],
        'orientationMode': summary?['orientationMode'],
        'background': summary?['background'],
        'firstMaskLatencyMs': summary?['firstMaskLatencyMs'],
        'frameCount': summary?['frameCount'],
        'maskCount': summary?['maskCount'],
        'publishedFrames': summary?['publishedFrames'],
        'droppedBusyFrames': summary?['droppedBusyFrames'],
        'skippedNoMaskFrames': summary?['skippedNoMaskFrames'],
        'throttledFrames': summary?['throttledFrames'],
        'droppedPoolExhaustedFrames': summary?['droppedPoolExhaustedFrames'],
        'renderFailureCount': summary?['renderFailureCount'],
        'interruptionCount': summary?['interruptionCount'],
        'avgFrameIntervalMs': summary?['avgFrameIntervalMs'],
        'effectiveFps': summary?['effectiveFps'],
        'avgMatteGenerationMs': summary?['avgMatteGenerationMs'],
        'p95MatteGenerationMs': summary?['p95MatteGenerationMs'],
        'avgCompositeMs': summary?['avgCompositeMs'],
        'p95CompositeMs': summary?['p95CompositeMs'],
        'runDurationMs': summary?['runDurationMs'],
        'capturedImageWidth': summary?['capturedImageWidth'],
        'capturedImageHeight': summary?['capturedImageHeight'],
        'rawSegmentationBufferWidth': summary?['rawSegmentationBufferWidth'],
        'rawSegmentationBufferHeight': summary?['rawSegmentationBufferHeight'],
        'matteWidth': summary?['matteWidth'],
        'matteHeight': summary?['matteHeight'],
        'videoFormatWidth': summary?['videoFormatWidth'],
        'videoFormatHeight': summary?['videoFormatHeight'],
        'videoFormatFramesPerSecond': summary?['videoFormatFramesPerSecond'],
        'stopRenderDrainTimedOut': summary?['stopRenderDrainTimedOut'],
        'failureReason': summary?['failureReason'],
        'captureBundleRequested': summary?['captureBundleRequested'],
        'captureBundleOutputDir': summary?['captureBundleOutputDir'],
        'captureBundleLabel': summary?['captureBundleLabel'],
        'captureBundleAfterPublishedFrames':
            summary?['captureBundleAfterPublishedFrames'],
        'captureBundleCaptured': summary?['captureBundleCaptured'],
        'captureBundleFrameIndex': summary?['captureBundleFrameIndex'],
        'captureBundleMs': summary?['captureBundleMs'],
        'captureBundleFailureReason': summary?['captureBundleFailureReason'],
      },
      'harnessFailureReasons': failureReasons,
      'startError': startError,
      'stopError': stopError,
      'replayError': replayError,
      'stageLabError': legacyStageLabError,
      'artifactExportError': artifactExportError,
      'claims': _claims,
      'nonClaims': _nonClaims,
      'startResult': startMap,
      'stopResult': stopMap,
      'replayResult': replayMap,
      'stageLabResult': legacyStageLabResult,
    };
    print('IOS_ARKIT_CAPTURE_REPLAY_JSON:${jsonEncode(payload)}');
    print(pass ? 'IOS_ARKIT_CAPTURE_REPLAY_PASS' : 'IOS_ARKIT_CAPTURE_REPLAY_FAIL');

    if (mounted) {
      setState(() {
        _failureReasons = failureReasons;
        _status = pass ? 'PASS' : 'FAIL';
      });
    }
    // Brief dwell so the final status panel is visible on device before exit.
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(pass ? 0 : 1);
  }

  /// Contract pass criteria over the native stop summary, including the
  /// capture result. Each violation is appended to [failureReasons].
  void _evaluateStopSummary(
    Map<String, dynamic> summary,
    String bundleDir,
    List<String> failureReasons,
  ) {
    if (summary['pass'] != true) {
      failureReasons.add('native_stop_pass_false');
    }
    if (summary['proofBoundary'] != _nativeLiveProofBoundary) {
      failureReasons.add('proof_boundary_mismatch: ${summary['proofBoundary']}');
    }
    if (summary['trackingConfiguration'] != 'face') {
      failureReasons.add(
        'tracking_configuration_not_face: ${summary['trackingConfiguration']}',
      );
    }
    if (summary['activeTrackingUsesFrontCamera'] != true) {
      failureReasons.add('active_tracking_not_front_camera');
    }
    if (summary['orientationMode'] != _displayOrientation) {
      failureReasons.add(
        'orientation_mode_mismatch: ${summary['orientationMode']} != $_displayOrientation',
      );
    }
    if (summary['background'] != 'teal') {
      failureReasons.add('background_not_teal: ${summary['background']}');
    }
    if (_asInt(summary['textureId']) == null) {
      failureReasons.add('stop_summary_missing_texture_id');
    }
    final publishedFrames = _asInt(summary['publishedFrames']);
    if (publishedFrames == null || publishedFrames <= 0) {
      failureReasons.add('published_frames_not_positive: $publishedFrames');
    }
    if (_asInt(summary['frameCount']) == null ||
        _asInt(summary['maskCount']) == null) {
      failureReasons.add('frame_or_mask_count_missing');
    }
    if (_asDouble(summary['firstMaskLatencyMs']) == null) {
      failureReasons.add('first_mask_latency_missing');
    }
    final failureReason = _asNonEmptyString(summary['failureReason']);
    if (failureReason != null) {
      failureReasons.add('native_failure_reason: $failureReason');
    }

    // Capture contract.
    if (summary['captureBundleRequested'] != true) {
      failureReasons.add('capture_bundle_not_requested_natively');
    }
    final reportedAfterFrames =
        _asInt(summary['captureBundleAfterPublishedFrames']);
    if (reportedAfterFrames != _captureAfterFrames) {
      failureReasons.add(
        'capture_bundle_after_published_frames_mismatch: '
        '$reportedAfterFrames != $_captureAfterFrames',
      );
    }
    if (summary['captureBundleCaptured'] != true) {
      failureReasons.add(
        'capture_bundle_not_captured: ${summary['captureBundleFailureReason']}',
      );
    }
    final captureFrameIndex = _asInt(summary['captureBundleFrameIndex']);
    if (captureFrameIndex != null && captureFrameIndex < _captureAfterFrames) {
      failureReasons.add(
        'capture_bundle_frame_index_before_threshold: '
        '$captureFrameIndex < $_captureAfterFrames',
      );
    }
    final reportedDir = _asNonEmptyString(summary['captureBundleOutputDir']);
    if (reportedDir != bundleDir) {
      failureReasons.add(
        'capture_bundle_output_dir_mismatch: $reportedDir != $bundleDir',
      );
    }
    final captureBundle = _asMap(summary['captureBundle']);
    if (captureBundle == null) {
      failureReasons.add('capture_bundle_result_missing');
    } else {
      final resultPath = _asNonEmptyString(captureBundle['path']) ??
          _asNonEmptyString(captureBundle['outputDir']);
      if (resultPath != bundleDir) {
        failureReasons.add(
          'capture_bundle_result_path_mismatch: $resultPath != $bundleDir',
        );
      }
      if (_asInt(captureBundle['canvasWidth']) != _width ||
          _asInt(captureBundle['canvasHeight']) != _height) {
        failureReasons.add(
          'capture_bundle_canvas_mismatch: '
          '${captureBundle['canvasWidth']}x${captureBundle['canvasHeight']} != ${_width}x$_height',
        );
      }
      if (captureBundle['label'] != _label) {
        failureReasons.add(
          'capture_bundle_label_mismatch: ${captureBundle['label']} != $_label',
        );
      }
      // Full-canvas sourceRect and cameraRect: replay must not re-crop.
      for (final rectKey in const <String>['sourceRect', 'cameraRect']) {
        final rect = _asMap(captureBundle[rectKey]);
        final ok = rect != null &&
            _asDouble(rect['x']) == 0 &&
            _asDouble(rect['y']) == 0 &&
            _asDouble(rect['width']) == _width.toDouble() &&
            _asDouble(rect['height']) == _height.toDouble();
        if (!ok) {
          failureReasons.add('capture_bundle_${rectKey}_not_full_canvas: $rect');
        }
      }
    }
  }

  /// Verifies the stage lab echoed the requested [mode], reported every
  /// expected stage key with its stable file name for that mode, and that
  /// every reported path/file exists non-empty.
  /// Fills [stagePaths] with the reported paths.
  Future<void> _verifyStageLab({
    required Map<String, dynamic> raw,
    required String stageOutputDir,
    required String mode,
    required Map<String, String> stagePaths,
  }) async {
    final echoedMode = raw['refinementMode'];
    if (echoedMode != mode) {
      throw StateError(
        '$_stageLabMethod ($mode) echoed refinementMode "$echoedMode" but '
        '"$mode" was requested',
      );
    }
    final reportedOutputDir = _asNonEmptyString(raw['outputDir']);
    if (reportedOutputDir != stageOutputDir) {
      throw StateError(
        '$_stageLabMethod ($mode) reported outputDir "$reportedOutputDir" but '
        '"$stageOutputDir" was requested',
      );
    }
    final rawPaths = raw['paths'];
    if (rawPaths is! Map) {
      throw StateError(
        '$_stageLabMethod ($mode) result is missing the "paths" map',
      );
    }
    final rawFiles = raw['files'];
    if (rawFiles is! List) {
      throw StateError(
        '$_stageLabMethod ($mode) result is missing the "files" list',
      );
    }

    final expectedFiles = expectedStageFilesForMode(mode);

    // 1. All expected stage keys for this mode with their stable file names.
    for (final entry in expectedFiles.entries) {
      final reported = rawPaths[entry.key];
      if (reported is! String || reported.isEmpty) {
        throw StateError(
          '$_stageLabMethod ($mode) did not report a path for stage "${entry.key}"',
        );
      }
      if (!reported.endsWith('/${entry.value}')) {
        throw StateError(
          'Stage "${entry.key}" path "$reported" for mode "$mode" does not end with the stable '
          'file name "${entry.value}"',
        );
      }
    }

    // 2. Every reported path exists non-empty (never assume only seven).
    for (final entry in rawPaths.entries) {
      final key = '${entry.key}';
      final reported = entry.value;
      if (reported is! String || reported.isEmpty) {
        throw StateError(
          '$_stageLabMethod ($mode) reported a non-string/empty path for stage "$key"',
        );
      }
      final problem = await _fileProblem(reported);
      if (problem != null) {
        throw StateError(
          'Stage "$key" file for mode "$mode" is $problem at $reported',
        );
      }
      stagePaths[key] = reported;
    }

    // 3. Every reported file name is backed by a path and exists non-empty.
    if (rawFiles.length != rawPaths.length) {
      throw StateError(
        '$_stageLabMethod ($mode) reported ${rawFiles.length} files but '
        '${rawPaths.length} paths',
      );
    }
    for (final fileName in rawFiles) {
      if (fileName is! String || fileName.isEmpty) {
        throw StateError(
          '$_stageLabMethod ($mode) reported a non-string/empty entry in "files"',
        );
      }
      final backedByPath =
          stagePaths.values.any((p) => p.endsWith('/$fileName'));
      if (!backedByPath) {
        throw StateError(
          'Reported file "$fileName" for mode "$mode" has no matching entry in "paths"',
        );
      }
      final problem = await _fileProblem('$stageOutputDir/$fileName');
      if (problem != null) {
        throw StateError(
          'Reported file "$fileName" for mode "$mode" is $problem under $stageOutputDir',
        );
      }
    }
  }

  /// Emits replay.png once and all stage PNGs for each requested mode from the
  /// device filesystem to stdout as chunked base64 JSON markers. Throws if any
  /// artifact cannot be read or is empty. Only PNG artifacts are emitted (raw
  /// bundle files are ignored).
  Future<List<String>> _emitPngArtifacts({
    required String replayPath,
    required List<String> requestedRefinementModes,
    required Map<String, Map<String, String>> perModeStagePaths,
  }) async {
    final isSingleS1 = requestedRefinementModes.length == 1 &&
        requestedRefinementModes.first == kRefinementModeS1;

    for (final mode in requestedRefinementModes) {
      final stagePaths = perModeStagePaths[mode];
      if (stagePaths == null) {
        throw StateError(
          'Missing stagePaths for requested refinement mode "$mode"',
        );
      }
      final expectedFiles = expectedStageFilesForMode(mode);
      for (final key in stagePaths.keys) {
        if (!expectedFiles.containsKey(key)) {
          throw StateError(
            'Unexpected stage key "$key" in stagePaths for mode "$mode"',
          );
        }
      }
    }

    final targets = <MapEntry<String, String>>[
      MapEntry('replay.png', replayPath),
    ];

    for (final mode in requestedRefinementModes) {
      final stagePaths = perModeStagePaths[mode]!;
      final expectedFiles = expectedStageFilesForMode(mode);
      for (final entry in expectedFiles.entries) {
        final path = stagePaths[entry.key];
        if (path == null || path.isEmpty) {
          throw StateError(
            'Missing stage path for expected stage "${entry.key}" in mode "$mode"',
          );
        }
        final artifactName = isSingleS1 ? entry.value : '$mode/${entry.value}';
        targets.add(MapEntry(artifactName, path));
      }
    }

    final exportedNames = <String>[];

    for (final target in targets) {
      final name = target.key;
      final path = target.value;

      if (!name.endsWith('.png')) {
        throw StateError(
          'Refusing to emit non-PNG artifact "$name" at "$path"',
        );
      }

      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('Artifact file does not exist', path);
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Artifact file is empty: $path');
      }

      final base64Chars = base64Encode(bytes);
      final totalChars = base64Chars.length;
      final chunks =
          (totalChars + _artifactChunkSize - 1) ~/ _artifactChunkSize;

      print(
        'IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_BEGIN:'
        '${jsonEncode(<String, dynamic>{
          'name': name,
          'path': path,
          'bytes': bytes.length,
          'base64Chars': totalChars,
          'chunkSize': _artifactChunkSize,
          'chunks': chunks,
        })}',
      );

      for (var index = 0; index < chunks; index++) {
        final start = index * _artifactChunkSize;
        final end = (start + _artifactChunkSize > totalChars)
            ? totalChars
            : start + _artifactChunkSize;
        final chunkData = base64Chars.substring(start, end);
        print(
          'IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_CHUNK:'
          '${jsonEncode(<String, dynamic>{
            'name': name,
            'index': index,
            'chunks': chunks,
            'data': chunkData,
          })}',
        );
      }

      print(
        'IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_END:'
        '${jsonEncode(<String, dynamic>{
          'name': name,
        })}',
      );

      exportedNames.add(name);
    }

    print(
      'IOS_ARKIT_CAPTURE_REPLAY_ARTIFACT_EXPORT_DONE:'
      '${jsonEncode(<String, dynamic>{
        'count': exportedNames.length,
        'names': exportedNames,
      })}',
    );

    return exportedNames;
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    final start = _startMap;
    final stop = _stopMap;

    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (textureId != null)
              // Full-screen portrait preview, aspect-fill, never stretched:
              // the texture keeps its native canvas aspect and is cropped.
              Positioned.fill(
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _textureWidth.toDouble(),
                      height: _textureHeight.toDouble(),
                      child: Texture(textureId: textureId),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'ARKit Capture + Replay (RND) — $_status',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'face / front camera / $_displayOrientation / teal\n'
                        'canvas=${_textureWidth}x$_textureHeight targetFps=$_targetFps '
                        'hold=${_holdSeconds}s label=$_label modes=$_rawRefinementModes '
                        'afterFrames=$_captureAfterFrames\n'
                        'runRoot=$_runRoot\n'
                        'sessionId=${start?['sessionId']} textureId=${start?['textureId']}\n'
                        'videoFormat=${start?['videoFormatWidth']}x${start?['videoFormatHeight']}'
                        '@${start?['videoFormatFramesPerSecond']}'
                        '${stop == null ? '' : '\n'
                            'published=${stop['publishedFrames']} '
                            'dropped=${stop['droppedBusyFrames']} '
                            'skipped=${stop['skippedNoMaskFrames']} '
                            'throttled=${stop['throttledFrames']}\n'
                            'effectiveFps=${stop['effectiveFps']} '
                            'matteMs avg/p95=${stop['avgMatteGenerationMs']}/${stop['p95MatteGenerationMs']}\n'
                            'compositeMs avg/p95=${stop['avgCompositeMs']}/${stop['p95CompositeMs']}\n'
                            'captured=${stop['captureBundleCaptured']} '
                            'frameIndex=${stop['captureBundleFrameIndex']} '
                            'captureMs=${stop['captureBundleMs']} '
                            'failureReason=${stop['failureReason']}'}'
                        '${_failureReasons.isEmpty ? '' : '\nharness: ${_failureReasons.join('; ')}'}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
