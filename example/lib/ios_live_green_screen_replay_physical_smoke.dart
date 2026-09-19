// Copyright 2026, Connects. All rights reserved.
// ios_live_green_screen_replay_physical_smoke.dart
//
// Minimal diagnostic-only deterministic iOS live green-screen replay harness.
// Replays a previously captured input bundle (metadata.json, background.bgra,
// camera.bgra, mask.r8) through VGDuetPreviewCompositor offline without starting
// the camera or running live segmentation. Two operations are available and
// are selected by which output dart-defines are set:
//   - replay: composites the bundle and encodes the result to one PNG
//     (LIVE_GREENSCREEN_REPLAY_OUTPUT_PATH).
//   - matte stage lab: dumps one PNG per matte refinement stage plus the final
//     composite into a directory (LIVE_GREENSCREEN_REPLAY_STAGE_OUTPUT_DIR) so
//     edge artifacts can be attributed to the stage that introduces them.
// When both are set, both run (replay first). At least one must be set.
//
// Proof boundary:
//   ios_live_greenscreen_deterministic_replay_physical_smoke
//
// Dart-defines:
//   - LIVE_GREENSCREEN_REPLAY_INPUT_DIR (required): path to bundle directory.
//   - LIVE_GREENSCREEN_REPLAY_OUTPUT_PATH (optional*): path to output PNG file.
//   - LIVE_GREENSCREEN_REPLAY_STAGE_OUTPUT_DIR (optional*): directory for the
//     seven stage PNGs (01_raw_mask.png .. 07_final_composite.png).
//     * At least one of OUTPUT_PATH / STAGE_OUTPUT_DIR is required.
//   - LIVE_GREENSCREEN_REPLAY_REFINEMENT_MODE (optional): matte stage lab
//     refinement mode, exactly "s1" (default; the live pipeline), "s4GuidedAlphaR1",
//     or "s5GuidedFilterR1" (diagnostic-only RND candidates; native writes an
//     eighth PNG for whichever candidate is selected: 08_s4_guided_alpha_band.png
//     for s4GuidedAlphaR1, 08_s5_guided_filter_band.png for s5GuidedFilterR1). Any
//     other value fails the harness before any operation runs, and native rejects
//     it with INVALID_ARG as well. This mode is passed to the matte stage lab
//     ONLY; the replay one-PNG path always uses the live S1 composite() regardless
//     of this value.
//   - LIVE_GREENSCREEN_REPLAY_LABEL (optional): diagnostic label string.
//   - LIVE_GREENSCREEN_REPLAY_START_DELAY_SECONDS (optional): delay before replay in seconds (0..60, default 0).
// Relative paths resolve under Directory.systemTemp.
//
// Output markers:
//   IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_SMOKE_START
//   IOS_LIVE_GREENSCREEN_REPLAY_JSON:<json>
//   IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_PASS | IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_FAIL
//
// PASS requires every requested operation to complete and every file it
// reports to exist with a non-zero size (all entries of the native `paths` map
// and `files` list, not only the seven S1 stage names). Existing output files
// are never overwritten (Dart pre-checks; native refuses again).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kReplaySmokeStartMarker =
    'IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_SMOKE_START';
const String kReplaySmokeJsonPrefix = 'IOS_LIVE_GREENSCREEN_REPLAY_JSON:';
const String kReplaySmokePassMarker =
    'IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_PASS';
const String kReplaySmokeFailMarker =
    'IOS_LIVE_GREENSCREEN_REPLAY_PHYSICAL_FAIL';

const String kReplayMethod = 'replayLiveGreenScreenInputBundle';
const String kStageLabMethod = 'runLiveGreenScreenMatteStageLab';
const MethodChannel kChannel = MethodChannel('vanguard_media_engine');

/// Stage PNG map keys expected in the `paths` map returned by [kStageLabMethod]
/// and their stable file names. Mirrors
/// VGLiveGreenScreenReplayDiagnostics.matteStageFiles; every entry must be
/// reported by native and exist non-empty on disk for PASS.
const Map<String, String> kExpectedStageFiles = <String, String>{
  'rawMask': '01_raw_mask.png',
  'aspectFilledMask': '02_aspect_filled_mask.png',
  'postMorphology': '03_post_morphology.png',
  'postFeather': '04_post_feather.png',
  'postTrimap': '05_post_trimap.png',
  'postGuidedEdge': '06_post_guided_edge.png',
  'finalComposite': '07_final_composite.png',
};

/// Default (live pipeline) matte refinement mode.
const String kRefinementModeS1 = 's1';

/// Diagnostic-only RND candidate refinement mode (matte stage lab only).
const String kRefinementModeS4GuidedAlphaR1 = 's4GuidedAlphaR1';

/// Diagnostic-only RND candidate refinement mode (matte stage lab only).
const String kRefinementModeS5GuidedFilterR1 = 's5GuidedFilterR1';

/// Exact refinement mode strings accepted by native
/// (VGDuetPreviewCompositor.GreenScreenRefinementMode raw values).
const List<String> kAcceptedRefinementModes = <String>[
  kRefinementModeS1,
  kRefinementModeS4GuidedAlphaR1,
  kRefinementModeS5GuidedFilterR1,
];

/// Extra stage PNG native writes only for [kRefinementModeS4GuidedAlphaR1];
/// pre-checked for collisions here, then verified via the reported paths.
const String kS4BandStageFile = '08_s4_guided_alpha_band.png';

/// Extra stage PNG native writes only for [kRefinementModeS5GuidedFilterR1];
/// pre-checked for collisions here, then verified via the reported paths.
const String kS5BandStageFile = '08_s5_guided_filter_band.png';

const String kRawInputDir = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_INPUT_DIR',
  defaultValue: '',
);

const String kRawOutputPath = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_OUTPUT_PATH',
  defaultValue: '',
);

const String kRawStageOutputDir = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_STAGE_OUTPUT_DIR',
  defaultValue: '',
);

const String kReplayLabel = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_LABEL',
  defaultValue: 'replay_diagnostic',
);

const String kRawRefinementMode = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_REFINEMENT_MODE',
  defaultValue: kRefinementModeS1,
);

const String kRawStartDelaySeconds = String.fromEnvironment(
  'LIVE_GREENSCREEN_REPLAY_START_DELAY_SECONDS',
  defaultValue: '0',
);

/// Parses and clamps the start delay in seconds to 0..60 (default 0).
int parseStartDelaySeconds(String raw) {
  final parsed = int.tryParse(raw.trim()) ?? 0;
  return parsed.clamp(0, 60);
}

/// Validates the refinement mode dart-define: an empty value means the default
/// [kRefinementModeS1]; anything not in [kAcceptedRefinementModes] is rejected
/// (exact match, no trimming beyond surrounding whitespace, no case folding).
String parseRefinementMode(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kRefinementModeS1;
  if (!kAcceptedRefinementModes.contains(trimmed)) {
    throw ArgumentError(
      'LIVE_GREENSCREEN_REPLAY_REFINEMENT_MODE must be one of '
      '${kAcceptedRefinementModes.join(', ')} (got "$trimmed")',
    );
  }
  return trimmed;
}

/// Resolves relative paths under [Directory.systemTemp.path].
String? resolvePath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  var normalized = trimmed;
  while (normalized.length > 1 &&
      (normalized.endsWith('/') || normalized.endsWith(r'\'))) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  final isAbsolute = normalized.startsWith('/') ||
      (Platform.isWindows &&
          (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(normalized) ||
              normalized.startsWith(r'\\')));

  if (isAbsolute) {
    return normalized;
  }
  return '${Directory.systemTemp.path}/$normalized';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LiveGreenScreenReplaySmokeApp());
}

class LiveGreenScreenReplaySmokeApp extends StatefulWidget {
  const LiveGreenScreenReplaySmokeApp({super.key});

  @override
  State<LiveGreenScreenReplaySmokeApp> createState() =>
      _LiveGreenScreenReplaySmokeAppState();
}

class _LiveGreenScreenReplaySmokeAppState
    extends State<LiveGreenScreenReplaySmokeApp> {
  String _status = 'Starting deterministic replay harness...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runDiagnostics();
    });
  }

  void _setStatus(String status) {
    if (mounted) {
      setState(() {
        _status = status;
      });
    }
  }

  /// Replay operation: composite the bundle to a single PNG at [outputPath].
  Future<Map<String, dynamic>> _invokeReplay(
    String inputDir,
    String outputPath,
  ) async {
    // Ensure parent directory of output path exists.
    final outputFile = File(outputPath);
    final parentDir = outputFile.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    if (await outputFile.exists()) {
      throw FileSystemException(
        'Output file already exists; overwriting refused for determinism',
        outputPath,
      );
    }

    _setStatus('Invoking $kReplayMethod...');

    final raw = await kChannel.invokeMapMethod<String, dynamic>(
      kReplayMethod,
      <String, Object?>{
        'inputDir': inputDir,
        'outputPath': outputPath,
        'label': kReplayLabel,
      },
    );

    if (raw == null) {
      throw StateError('$kReplayMethod returned null');
    }

    if (!await outputFile.exists() || await outputFile.length() == 0) {
      throw StateError(
        'Replay completed but output file is missing or empty at $outputPath',
      );
    }

    return raw;
  }

  /// Matte stage lab operation: dump every matte refinement stage plus the
  /// final composite as PNGs under [stageOutputDir] using [refinementMode].
  /// Verifies that native echoed the requested mode, reported all seven
  /// expected stage keys with the stable file names, and that EVERY file it
  /// reports (all `paths` entries and all `files` names, eight for S4) exists
  /// non-empty.
  Future<Map<String, dynamic>> _invokeStageLab(
    String inputDir,
    String stageOutputDir,
    String refinementMode,
  ) async {
    final stageDir = Directory(stageOutputDir);
    if (await stageDir.exists()) {
      final collisionCandidates = <String>[
        ...kExpectedStageFiles.values,
        if (refinementMode == kRefinementModeS4GuidedAlphaR1) kS4BandStageFile,
        if (refinementMode == kRefinementModeS5GuidedFilterR1) kS5BandStageFile,
      ];
      for (final fileName in collisionCandidates) {
        final candidate = File('$stageOutputDir/$fileName');
        if (await candidate.exists()) {
          throw FileSystemException(
            'Stage output file already exists; overwriting refused for determinism',
            candidate.path,
          );
        }
      }
    }

    _setStatus('Invoking $kStageLabMethod (refinementMode=$refinementMode)...');

    final raw = await kChannel.invokeMapMethod<String, dynamic>(
      kStageLabMethod,
      <String, Object?>{
        'inputDir': inputDir,
        'outputDir': stageOutputDir,
        'label': kReplayLabel,
        'refinementMode': refinementMode,
      },
    );

    if (raw == null) {
      throw StateError('$kStageLabMethod returned null');
    }

    final echoedMode = raw['refinementMode'];
    if (echoedMode != refinementMode) {
      throw StateError(
        '$kStageLabMethod echoed refinementMode "$echoedMode" but '
        '"$refinementMode" was requested',
      );
    }

    final rawPaths = raw['paths'];
    if (rawPaths is! Map) {
      throw StateError('$kStageLabMethod result is missing the "paths" map');
    }
    final rawFiles = raw['files'];
    if (rawFiles is! List) {
      throw StateError('$kStageLabMethod result is missing the "files" list');
    }

    // 1. The seven S1 stage keys must always be present with their stable names.
    for (final entry in kExpectedStageFiles.entries) {
      final reported = rawPaths[entry.key];
      if (reported is! String || reported.isEmpty) {
        throw StateError(
          '$kStageLabMethod did not report a path for stage "${entry.key}"',
        );
      }
      if (!reported.endsWith('/${entry.value}')) {
        throw StateError(
          'Stage "${entry.key}" path "$reported" does not end with the stable '
          'file name "${entry.value}"',
        );
      }
    }

    // 2. Every path native reports (seven for s1, eight for S4, or more if a
    //    future mode adds taps) must exist non-empty; never assume only seven.
    for (final entry in rawPaths.entries) {
      final key = entry.key;
      final reported = entry.value;
      if (reported is! String || reported.isEmpty) {
        throw StateError(
          '$kStageLabMethod reported a non-string/empty path for stage "$key"',
        );
      }
      final stageFile = File(reported);
      if (!await stageFile.exists() || await stageFile.length() == 0) {
        throw StateError(
          'Stage "$key" file is missing or empty at $reported',
        );
      }
    }

    // 3. Every file name in the reported `files` list must be backed by a
    //    reported path and exist non-empty under the stage output directory.
    if (rawFiles.length != rawPaths.length) {
      throw StateError(
        '$kStageLabMethod reported ${rawFiles.length} files but '
        '${rawPaths.length} paths',
      );
    }
    for (final fileName in rawFiles) {
      if (fileName is! String || fileName.isEmpty) {
        throw StateError(
          '$kStageLabMethod reported a non-string/empty entry in "files"',
        );
      }
      final backedByPath = rawPaths.values
          .whereType<String>()
          .any((p) => p.endsWith('/$fileName'));
      if (!backedByPath) {
        throw StateError(
          'Reported file "$fileName" has no matching entry in "paths"',
        );
      }
      final stageFile = File('$stageOutputDir/$fileName');
      if (!await stageFile.exists() || await stageFile.length() == 0) {
        throw StateError(
          'Reported file "$fileName" is missing or empty under $stageOutputDir',
        );
      }
    }

    return raw;
  }

  Future<void> _runDiagnostics() async {
    print(kReplaySmokeStartMarker);

    bool pass = false;
    String? failureMessage;
    Map<String, dynamic>? replayResult;
    Map<String, dynamic>? stageLabResult;

    final resolvedInputDir = resolvePath(kRawInputDir);
    final resolvedOutputPath = resolvePath(kRawOutputPath);
    final resolvedStageOutputDir = resolvePath(kRawStageOutputDir);
    final startDelaySeconds = parseStartDelaySeconds(kRawStartDelaySeconds);
    String? refinementMode;

    final wantReplay = resolvedOutputPath != null && resolvedOutputPath.isNotEmpty;
    final wantStageLab =
        resolvedStageOutputDir != null && resolvedStageOutputDir.isNotEmpty;
    final requestedOperations = <String>[
      if (wantReplay) 'replay',
      if (wantStageLab) 'stageLab',
    ];

    try {
      // Validate the mode before any operation runs so an invalid value can
      // never leave a replay PNG behind and then fail on the lab.
      refinementMode = parseRefinementMode(kRawRefinementMode);

      if (resolvedInputDir == null || resolvedInputDir.isEmpty) {
        throw ArgumentError(
          'Missing required dart-define LIVE_GREENSCREEN_REPLAY_INPUT_DIR',
        );
      }
      if (!wantReplay && !wantStageLab) {
        throw ArgumentError(
          'Provide LIVE_GREENSCREEN_REPLAY_OUTPUT_PATH (replay), '
          'LIVE_GREENSCREEN_REPLAY_STAGE_OUTPUT_DIR (matte stage lab), or both',
        );
      }

      if (startDelaySeconds > 0) {
        _setStatus('Waiting ${startDelaySeconds}s before replay...');
        await Future<void>.delayed(Duration(seconds: startDelaySeconds));
      }

      final inputDirectory = Directory(resolvedInputDir);
      if (!await inputDirectory.exists()) {
        throw FileSystemException(
          'Input bundle directory does not exist',
          resolvedInputDir,
        );
      }

      if (wantReplay) {
        replayResult = await _invokeReplay(resolvedInputDir, resolvedOutputPath);
      }

      if (wantStageLab) {
        stageLabResult = await _invokeStageLab(
          resolvedInputDir,
          resolvedStageOutputDir,
          refinementMode,
        );
      }

      pass = true;
    } catch (e, st) {
      pass = false;
      failureMessage = '$e\n$st';
      print('REPLAY_ERROR: $e\n$st');
    } finally {
      final payload = <String, Object?>{
        'pass': pass,
        'label': kReplayLabel,
        'startDelaySeconds': startDelaySeconds,
        'inputDir': resolvedInputDir,
        'outputPath': resolvedOutputPath,
        'stageOutputDir': resolvedStageOutputDir,
        'refinementModeRaw': kRawRefinementMode,
        'refinementMode': refinementMode,
        'requestedOperations': requestedOperations,
        'replayResult': replayResult,
        'stageLabResult': stageLabResult,
        'error': failureMessage,
        'proofBoundary':
            'ios_live_greenscreen_deterministic_replay_physical_smoke',
        'claims': <String>[
          'offline deterministic replay of a captured live green-screen input bundle through VGDuetPreviewCompositor',
          'replay (when LIVE_GREENSCREEN_REPLAY_OUTPUT_PATH is set): composited output written to one PNG',
          'matte stage lab (when LIVE_GREENSCREEN_REPLAY_STAGE_OUTPUT_DIR is set): raw mask, aspect-filled mask, post morphology, post feather, post trimap, post guided edge, and final composite PNGs written with stable names',
          'matte stage lab refinement mode (LIVE_GREENSCREEN_REPLAY_REFINEMENT_MODE, default s1) is validated against the exact native allowlist before any operation and echoed back by native; s4GuidedAlphaR1 additionally reports 08_s4_guided_alpha_band.png, s5GuidedFilterR1 additionally reports 08_s5_guided_filter_band.png',
          'pass requires every requested operation to complete and every reported file (all native paths/files entries, not only seven) to exist with non-zero size',
          'camera and live segmenter were not started; no existing output file was overwritten',
        ],
        'nonClaims': <String>[
          'diagnostic only: offline visual inspection of compositor matte stages and constants; no production tuning',
          'refinement mode is a matte-stage-lab-only diagnostic input; the replay one-PNG path always uses the live S1 composite() and ignores LIVE_GREENSCREEN_REPLAY_REFINEMENT_MODE',
          's4GuidedAlphaR1 and s5GuidedFilterR1 are RND candidates only: neither changes the live production default (composite() always runs S1) and no visual-quality claim is made for either',
          'no live camera capture, AVCaptureSession, or live ML segmentation proof',
          'no automated pixel quality assertion; file presence and non-zero size only',
        ],
      };

      print('$kReplaySmokeJsonPrefix${jsonEncode(payload)}');
      print(pass ? kReplaySmokePassMarker : kReplaySmokeFailMarker);

      _setStatus(pass ? 'PASS' : 'FAIL');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF0C1929),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'iOS Live Green Screen Replay',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
