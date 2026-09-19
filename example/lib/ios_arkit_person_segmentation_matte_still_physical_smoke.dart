// ios_arkit_person_segmentation_matte_still_physical_smoke.dart
// Vanguard Media Engine — iOS ARKit + ARMatteGenerator still-image matte proof.
//
// Diagnostic-only RND proof (proofBoundary
// 'ios_arkit_person_segmentation_matte_still_physical_smoke'): invokes the
// diagnostic-only native route
// runLiveGreenScreenARKitPersonSegmentationMatteStillProbe directly over
// MethodChannel('vanguard_media_engine'). Not part of the public
// vanguard_media_engine Dart API. `trackingConfiguration` (dart-define
// IOS_ARKIT_MATTE_STILL_TRACKING_CONFIGURATION, default 'face') selects which
// ARKit configuration is started this run: 'face' → front-camera
// ARFaceTrackingConfiguration (default, the physical harness's preferred
// configuration); 'world' → rear-camera ARWorldTrackingConfiguration.
//
// The native route captures one ARFrame with a non-nil segmentationBuffer,
// generates a full-resolution alpha matte with ARMatteGenerator (never the
// raw low-resolution segmentation buffer), composites the captured camera
// image over solid teal using that matte, and writes a single raw
// sensor-space PNG (`outputPath`). It additionally writes one
// display-orientation candidate PNG per mode (raw, left, right,
// leftMirrored, rightMirrored) from the same camera image and matte
// (`displayOrientationCandidates`) and reports the locked RND still-proof
// display selection (`selectedDisplayOrientationMode` /
// `selectedDisplayOrientationCandidate` /
// `selectedDisplayOrientationCandidateFailure`; 'face' → 'leftMirrored',
// chosen on device 2026-09-18 as upright portrait with the natural
// front-camera/selfie mirror; 'right' stays the upright non-mirrored /
// export-style alternative).
//
// What is shown is chosen by dart-define IOS_ARKIT_MATTE_STILL_DISPLAY_MODE:
// 'selected' (default) shows only the native selected candidate for the whole
// IOS_ARKIT_MATTE_STILL_HOLD_SECONDS window and fails closed (exit 1,
// IOS_ARKIT_MATTE_STILL_PROBE_FAIL) when the native run passed but no selected
// candidate is available; 'matrix' cycles every returned candidate
// sequentially, splitting the hold window evenly (BoxFit.contain, never
// stretched) with an overlay naming mode and index, for diagnostics; 'raw'
// shows only the raw sensor-space `outputPath` composite. Exits 0 on pass /
// 1 on fail after the hold. Still-frame RND display lock only; does not
// exercise the live green-screen session, Vision, or LiteRT paths.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _timeoutSeconds = int.fromEnvironment(
  'IOS_ARKIT_MATTE_STILL_TIMEOUT_SECONDS',
  defaultValue: 8,
);

const int _maxFrameCount = int.fromEnvironment(
  'IOS_ARKIT_MATTE_STILL_MAX_FRAMES',
  defaultValue: 90,
);

const int _holdSeconds = int.fromEnvironment(
  'IOS_ARKIT_MATTE_STILL_HOLD_SECONDS',
  defaultValue: 20,
);

/// Floor for how long each display candidate stays on screen when the hold
/// window is split across candidates, so a short hold never flashes them.
const int _minCandidateDwellMs = 1000;

const String _rawTrackingConfiguration = String.fromEnvironment(
  'IOS_ARKIT_MATTE_STILL_TRACKING_CONFIGURATION',
  defaultValue: 'face',
);

/// Validated at load time: only 'face' or 'world' are accepted so a typo in
/// the dart-define can never silently fall back to 'face'.
final String _trackingConfiguration = _validateTrackingConfiguration(
  _rawTrackingConfiguration,
);

String _validateTrackingConfiguration(String value) {
  if (value != 'face' && value != 'world') {
    throw ArgumentError(
      "IOS_ARKIT_MATTE_STILL_TRACKING_CONFIGURATION must be one of "
      "'face', 'world' (got '$value')",
    );
  }
  return value;
}

const String _displayModeSelected = 'selected';
const String _displayModeMatrix = 'matrix';
const String _displayModeRaw = 'raw';

const String _rawDisplayMode = String.fromEnvironment(
  'IOS_ARKIT_MATTE_STILL_DISPLAY_MODE',
  defaultValue: _displayModeSelected,
);

/// Validated in [main] before anything runs: 'selected' (default) shows only
/// the native `selectedDisplayOrientationCandidate` and fails closed when it is
/// missing; 'matrix' cycles every returned candidate for diagnostics; 'raw'
/// shows only the raw sensor-space `outputPath` composite.
final String _displayMode = _validateDisplayMode(_rawDisplayMode);

String _validateDisplayMode(String value) {
  if (value != _displayModeSelected &&
      value != _displayModeMatrix &&
      value != _displayModeRaw) {
    throw ArgumentError(
      "IOS_ARKIT_MATTE_STILL_DISPLAY_MODE must be one of "
      "'$_displayModeSelected', '$_displayModeMatrix', '$_displayModeRaw' "
      "(got '$value')",
    );
  }
  return value;
}

/// One display-orientation candidate PNG as reported by the native probe
/// (`displayOrientationCandidates[i]`), or the raw `outputPath` fallback.
class _DisplayCandidate {
  const _DisplayCandidate({
    required this.mode,
    required this.path,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final String mode;
  final String path;
  final int? bytes;
  final int? width;
  final int? height;

  Map<String, dynamic> toCompactJson() => <String, dynamic>{
        'mode': mode,
        'path': path,
        'bytes': bytes,
        'width': width,
        'height': height,
      };
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

String? _asNonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Parses one native candidate map (`{mode, path, bytes, width, height}`);
/// null when `entry` is not a map or lacks a usable `mode`/`path`.
_DisplayCandidate? _parseDisplayCandidate(Object? entry) {
  if (entry is! Map) return null;
  final mode = entry['mode'];
  final path = entry['path'];
  if (mode is! String || path is! String || path.isEmpty) return null;
  return _DisplayCandidate(
    mode: mode,
    path: path,
    bytes: _asInt(entry['bytes']),
    width: _asInt(entry['width']),
    height: _asInt(entry['height']),
  );
}

/// Parses `displayOrientationCandidates` from the native result map. Entries
/// missing a usable `mode`/`path` are skipped. When the key is absent or
/// yields nothing, falls back to a single 'raw' candidate built from
/// `outputPath` so an older native build still displays its one PNG.
List<_DisplayCandidate> _parseDisplayCandidates(Map<String, dynamic>? result) {
  if (result == null) return const <_DisplayCandidate>[];

  final parsed = <_DisplayCandidate>[];
  final rawCandidates = result['displayOrientationCandidates'];
  if (rawCandidates is List) {
    for (final entry in rawCandidates) {
      final candidate = _parseDisplayCandidate(entry);
      if (candidate != null) parsed.add(candidate);
    }
  }
  if (parsed.isNotEmpty) return parsed;

  final outputPath = result['outputPath'];
  if (outputPath is String && outputPath.isNotEmpty) {
    return <_DisplayCandidate>[
      _DisplayCandidate(
        mode: 'raw',
        path: outputPath,
        bytes: _asInt(result['outputBytes']),
        width: _asInt(result['capturedImageWidth']),
        height: _asInt(result['capturedImageHeight']),
      ),
    ];
  }
  return const <_DisplayCandidate>[];
}

/// What this run actually puts on screen, resolved from the native result and
/// [_displayMode]. [harnessFailureReason] is non-null only in 'selected' mode
/// when the native run passed but carried no usable selected candidate: the
/// proof then fails closed instead of silently showing nothing or another
/// candidate.
class _DisplayPlan {
  const _DisplayPlan({required this.shown, this.harnessFailureReason});

  final List<_DisplayCandidate> shown;
  final String? harnessFailureReason;
}

_DisplayPlan _resolveDisplayPlan({
  required bool nativePass,
  required List<_DisplayCandidate> candidates,
  required String? selectedMode,
  required _DisplayCandidate? selectedCandidate,
  required String? selectedCandidateFailure,
}) {
  if (_displayMode == _displayModeMatrix) {
    return _DisplayPlan(shown: candidates);
  }
  if (_displayMode == _displayModeRaw) {
    return _DisplayPlan(
      shown: candidates
          .where((candidate) => candidate.mode == 'raw')
          .take(1)
          .toList(growable: false),
    );
  }
  // 'selected'
  if (selectedCandidate != null) {
    return _DisplayPlan(shown: <_DisplayCandidate>[selectedCandidate]);
  }
  if (!nativePass) {
    // Native already failed; nothing to show and nothing extra to fail.
    return const _DisplayPlan(shown: <_DisplayCandidate>[]);
  }
  final reason = selectedMode == null
      ? 'selected_display_mode_missing'
      : 'selected_display_candidate_missing_$selectedMode';
  return _DisplayPlan(
    shown: const <_DisplayCandidate>[],
    harnessFailureReason:
        '$reason: ${selectedCandidateFailure ?? 'native reported no failure'}',
  );
}

void main() {
  // Force dart-define validation before the widget tree or native route runs
  // so an invalid value throws here rather than mid-run.
  print('IOS_ARKIT_MATTE_STILL_PROBE_CONFIG '
      'displayMode=$_displayMode '
      'trackingConfiguration=$_trackingConfiguration');
  runApp(const IosArkitPersonSegmentationMatteStillPhysicalSmokeApp());
}

class IosArkitPersonSegmentationMatteStillPhysicalSmokeApp
    extends StatefulWidget {
  const IosArkitPersonSegmentationMatteStillPhysicalSmokeApp({super.key});

  @override
  State<IosArkitPersonSegmentationMatteStillPhysicalSmokeApp> createState() =>
      _IosArkitPersonSegmentationMatteStillPhysicalSmokeAppState();
}

class _IosArkitPersonSegmentationMatteStillPhysicalSmokeAppState
    extends State<IosArkitPersonSegmentationMatteStillPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  String _status = 'Initializing ARKit matte still probe…';
  Map<String, dynamic>? _resultMap;
  List<_DisplayCandidate> _shownCandidates = const <_DisplayCandidate>[];
  int _candidateIndex = 0;
  String? _harnessFailureReason;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProbe();
    });
  }

  Future<void> _runProbe() async {
    print('IOS_ARKIT_MATTE_STILL_PROBE_INVOKE '
        'timeoutSeconds=$_timeoutSeconds maxFrameCount=$_maxFrameCount '
        'trackingConfiguration=$_trackingConfiguration '
        'displayMode=$_displayMode '
        'holdSeconds=$_holdSeconds');

    Map<String, dynamic>? resultMap;
    String? topLevelError;
    var pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runLiveGreenScreenARKitPersonSegmentationMatteStillProbe',
        <String, Object>{
          'timeoutSeconds': _timeoutSeconds,
          'maxFrameCount': _maxFrameCount,
          'trackingConfiguration': _trackingConfiguration,
        },
      ).timeout(Duration(seconds: _timeoutSeconds + 10));

      if (response == null || response is! Map) {
        throw Exception(
          'runLiveGreenScreenARKitPersonSegmentationMatteStillProbe '
          'returned invalid response: $response',
        );
      }

      resultMap = Map<String, dynamic>.from(response);
      pass = resultMap['pass'] == true;
    } on TimeoutException catch (te) {
      topLevelError = 'Watchdog timeout waiting for native probe: $te';
      print('IOS_ARKIT_MATTE_STILL_PROBE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('IOS_ARKIT_MATTE_STILL_PROBE_ERROR: $topLevelError');
    } finally {
      final candidates = _parseDisplayCandidates(resultMap);
      final selectedMode =
          _asNonEmptyString(resultMap?['selectedDisplayOrientationMode']);
      final selectedCandidate = _parseDisplayCandidate(
        resultMap?['selectedDisplayOrientationCandidate'],
      );
      final selectedCandidateFailure = _asNonEmptyString(
        resultMap?['selectedDisplayOrientationCandidateFailure'],
      );

      final nativePass = pass;
      final plan = _resolveDisplayPlan(
        nativePass: nativePass,
        candidates: candidates,
        selectedMode: selectedMode,
        selectedCandidate: selectedCandidate,
        selectedCandidateFailure: selectedCandidateFailure,
      );
      final harnessFailureReason = plan.harnessFailureReason;
      if (harnessFailureReason != null) {
        // Fail closed: 'selected' mode with nothing selected is not a proof.
        pass = false;
        print('IOS_ARKIT_MATTE_STILL_PROBE_ERROR: $harnessFailureReason');
      }

      final payload = <String, dynamic>{
        'proofBoundary': 'ios_arkit_person_segmentation_matte_still_physical_smoke',
        'pass': pass,
        'nativePass': nativePass,
        'timeoutSeconds': _timeoutSeconds,
        'maxFrameCount': _maxFrameCount,
        'trackingConfiguration': _trackingConfiguration,
        'displayMode': _displayMode,
        'holdSeconds': _holdSeconds,
        'harnessFailureReason': harnessFailureReason,
        'result': resultMap,
        'error': topLevelError,
      };

      print('IOS_ARKIT_MATTE_STILL_PROBE_JSON:${jsonEncode(payload)}');

      // Compact single-line marker (no claims arrays) so Flutter logs don't
      // truncate the critical fields before they reach the console.
      final compactPayload = <String, dynamic>{
        'pass': pass,
        'nativePass': nativePass,
        'displayMode': _displayMode,
        'harnessFailureReason': harnessFailureReason,
        'trackingConfiguration':
            resultMap?['trackingConfiguration'] ?? _trackingConfiguration,
        'activeTrackingUsesFrontCamera':
            resultMap?['activeTrackingUsesFrontCamera'],
        'outputPath': resultMap?['outputPath'],
        'outputBytes': resultMap?['outputBytes'],
        'frameCount': resultMap?['frameCount'],
        'maskCount': resultMap?['maskCount'],
        'rawSegmentationBufferWidth': resultMap?['rawSegmentationBufferWidth'],
        'rawSegmentationBufferHeight':
            resultMap?['rawSegmentationBufferHeight'],
        'capturedImageWidth': resultMap?['capturedImageWidth'],
        'capturedImageHeight': resultMap?['capturedImageHeight'],
        'matteWidth': resultMap?['matteWidth'],
        'matteHeight': resultMap?['matteHeight'],
        'firstMaskLatencyMs': resultMap?['firstMaskLatencyMs'],
        'averageFrameIntervalMs': resultMap?['averageFrameIntervalMs'],
        'matteGenerationMs': resultMap?['matteGenerationMs'],
        'compositeWriteMs': resultMap?['compositeWriteMs'],
        'failureReason': resultMap?['failureReason'],
        'displayOrientationCandidateModes':
            resultMap?['displayOrientationCandidateModes'],
        'displayOrientationCandidateFailure':
            resultMap?['displayOrientationCandidateFailure'],
        'displayOrientationCandidatesWriteMs':
            resultMap?['displayOrientationCandidatesWriteMs'],
        'displayOrientationCandidates': candidates
            .map((candidate) => candidate.toCompactJson())
            .toList(growable: false),
        'selectedDisplayOrientationMode': selectedMode,
        'selectedDisplayOrientationCandidate':
            selectedCandidate?.toCompactJson(),
        'selectedDisplayOrientationCandidateFailure': selectedCandidateFailure,
        'shownDisplayCandidates': plan.shown
            .map((candidate) => candidate.toCompactJson())
            .toList(growable: false),
      };
      print(
        'IOS_ARKIT_MATTE_STILL_PROBE_COMPACT_JSON:'
        '${jsonEncode(compactPayload)}',
      );

      print(
        pass
            ? 'IOS_ARKIT_MATTE_STILL_PROBE_PASS'
            : 'IOS_ARKIT_MATTE_STILL_PROBE_FAIL',
      );

      if (mounted) {
        setState(() {
          _resultMap = resultMap;
          _shownCandidates = plan.shown;
          _candidateIndex = 0;
          _harnessFailureReason = harnessFailureReason;
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await _holdAndCycleCandidates(plan.shown, selectedMode: selectedMode);
      exit(pass ? 0 : 1);
    }
  }

  /// Shows each planned candidate once, in native order, splitting the hold
  /// window evenly (floored at [_minCandidateDwellMs] per candidate); in
  /// 'selected' and 'raw' modes that is one candidate for the full window.
  /// With no candidates it simply holds the status panel for the full window.
  Future<void> _holdAndCycleCandidates(
    List<_DisplayCandidate> candidates, {
    required String? selectedMode,
  }) async {
    if (candidates.isEmpty) {
      await Future<void>.delayed(Duration(seconds: _holdSeconds));
      return;
    }
    final dwellMs = math.max(
      _minCandidateDwellMs,
      (_holdSeconds * 1000) ~/ candidates.length,
    );
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      if (mounted) {
        setState(() {
          _candidateIndex = i;
        });
      }
      print('IOS_ARKIT_MATTE_STILL_PROBE_DISPLAY_CANDIDATE_SHOW '
          'displayMode=$_displayMode '
          'selected=${_displayMode == _displayModeSelected} '
          'selectedMode=$selectedMode '
          'index=${i + 1}/${candidates.length} mode=${candidate.mode} '
          'size=${candidate.width}x${candidate.height} '
          'bytes=${candidate.bytes} dwellMs=$dwellMs path=${candidate.path}');
      await Future<void>.delayed(Duration(milliseconds: dwellMs));
    }
  }

  /// Bottom overlay text. Makes it unambiguous when the locked selected
  /// candidate (rather than a matrix entry or the raw composite) is on screen.
  String _shownCandidateLabel(_DisplayCandidate? current, int count) {
    if (current == null) {
      final reason = _harnessFailureReason;
      return reason == null
          ? 'candidate: none (displayMode=$_displayMode)'
          : 'candidate: none (displayMode=$_displayMode) — $reason';
    }
    final size = '${current.width}x${current.height}';
    if (_displayMode == _displayModeSelected) {
      return 'SELECTED display candidate mode=${current.mode} $size '
          '(displayMode=selected)';
    }
    if (_displayMode == _displayModeRaw) {
      return 'raw sensor-space candidate mode=${current.mode} $size '
          '(displayMode=raw)';
    }
    return 'matrix candidate ${_candidateIndex + 1}/$count '
        'mode=${current.mode} $size (displayMode=matrix)';
  }

  @override
  Widget build(BuildContext context) {
    final result = _resultMap;
    final outputPath = result?['outputPath'] as String?;
    final candidates = _shownCandidates;
    final _DisplayCandidate? current =
        candidates.isEmpty ? null : candidates[_candidateIndex.clamp(0, candidates.length - 1)];
    final candidateLabel = _shownCandidateLabel(current, candidates.length);

    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              if (current != null)
                Positioned.fill(
                  child: Image.file(
                    File(current.path),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'ARKit Matte Still Probe — $_status',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (result != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'trackingConfiguration=${result['trackingConfiguration']} '
                          'activeTrackingUsesFrontCamera=${result['activeTrackingUsesFrontCamera']}\n'
                          'frameCount=${result['frameCount']} maskCount=${result['maskCount']}\n'
                          'rawSegmentationBuffer=${result['rawSegmentationBufferWidth']}x${result['rawSegmentationBufferHeight']}\n'
                          'capturedImage=${result['capturedImageWidth']}x${result['capturedImageHeight']}\n'
                          'matte=${result['matteWidth']}x${result['matteHeight']}\n'
                          'firstMaskLatencyMs=${result['firstMaskLatencyMs']} '
                          'averageFrameIntervalMs=${result['averageFrameIntervalMs']}\n'
                          'matteGenerationMs=${result['matteGenerationMs']} '
                          'compositeWriteMs=${result['compositeWriteMs']}\n'
                          'outputPath=$outputPath\n'
                          'candidateModes=${result['displayOrientationCandidateModes']}\n'
                          'candidateFailure=${result['displayOrientationCandidateFailure']}\n'
                          'displayMode=$_displayMode '
                          'selectedMode=${result['selectedDisplayOrientationMode']}\n'
                          'selectedFailure=${result['selectedDisplayOrientationCandidateFailure']}\n'
                          'harnessFailureReason=$_harnessFailureReason\n'
                          'failureReason=${result['failureReason']}',
                          style:
                              const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    candidateLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
