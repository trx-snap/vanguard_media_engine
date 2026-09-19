// ios_arkit_person_segmentation_matte_live_physical_smoke.dart
// Vanguard Media Engine — iOS ARKit + ARMatteGenerator live matte preview proof.
//
// Discardable RND physical harness (proofBoundary
// 'ios_arkit_person_segmentation_matte_live_physical_smoke'): invokes the
// diagnostic-only native routes startLiveGreenScreenARKitPreviewProbe /
// stopLiveGreenScreenARKitPreviewProbe directly over
// MethodChannel('vanguard_media_engine'). Not part of the public
// vanguard_media_engine Dart API and not a production green-screen path.
//
// Native side (VGARKitLiveGreenScreenPreviewCoordinator): front camera only,
// ARFaceTrackingConfiguration + .personSegmentation, a full-resolution
// ARMatteGenerator matte per frame (never the raw low-resolution segmentation
// buffer), the locked still-proof display orientation `leftMirrored` applied
// identically to camera and matte, composited over solid teal (#008080) into a
// Flutter texture with one-render-in-flight backpressure.
//
// Flow: start → show Texture(textureId) full screen (BoxFit.cover, portrait,
// never stretched) for IOS_ARKIT_LIVE_HOLD_SECONDS → stop → evaluate the
// native summary → print markers/JSON → exit 0 on pass / 1 on fail.
//
// Dart-defines: IOS_ARKIT_LIVE_HOLD_SECONDS (default 15),
// IOS_ARKIT_LIVE_TARGET_FPS (default 30), IOS_ARKIT_LIVE_WIDTH (default 1080),
// IOS_ARKIT_LIVE_HEIGHT (default 1920).
//
// Non-claims: no export MP4, no image/video background, no audio, no
// production API, no Vision/LiteRT comparison, no automated pixel-quality proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _holdSeconds = int.fromEnvironment(
  'IOS_ARKIT_LIVE_HOLD_SECONDS',
  defaultValue: 15,
);

const int _targetFps = int.fromEnvironment(
  'IOS_ARKIT_LIVE_TARGET_FPS',
  defaultValue: 30,
);

const int _width = int.fromEnvironment(
  'IOS_ARKIT_LIVE_WIDTH',
  defaultValue: 1080,
);

const int _height = int.fromEnvironment(
  'IOS_ARKIT_LIVE_HEIGHT',
  defaultValue: 1920,
);

const String _proofBoundary =
    'ios_arkit_person_segmentation_matte_live_physical_smoke';

/// Watchdog for each native call (start/stop are synchronous natively; the
/// margin covers ARSession start-up and the bounded stop render drain).
const Duration _nativeCallTimeout = Duration(seconds: 15);

const List<String> _nonClaims = <String>[
  'No export MP4 is produced.',
  'No image or video background: solid teal only.',
  'No audio.',
  'Not a production API: diagnostic-only routes over a discardable RND coordinator.',
  'No Vision/LiteRT comparison.',
  'No automated pixel-quality proof: visual inspection of the live texture is the proof.',
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

void main() {
  print('IOS_ARKIT_LIVE_PREVIEW_CONFIG '
      'holdSeconds=$_holdSeconds targetFps=$_targetFps '
      'width=$_width height=$_height '
      'trackingConfiguration=face orientationMode=leftMirrored background=teal');
  runApp(const IosArkitPersonSegmentationMatteLivePhysicalSmokeApp());
}

class IosArkitPersonSegmentationMatteLivePhysicalSmokeApp
    extends StatefulWidget {
  const IosArkitPersonSegmentationMatteLivePhysicalSmokeApp({super.key});

  @override
  State<IosArkitPersonSegmentationMatteLivePhysicalSmokeApp> createState() =>
      _IosArkitPersonSegmentationMatteLivePhysicalSmokeAppState();
}

class _IosArkitPersonSegmentationMatteLivePhysicalSmokeAppState
    extends State<IosArkitPersonSegmentationMatteLivePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  String _status = 'Initializing ARKit live matte preview…';
  int? _textureId;
  int _textureWidth = _width;
  int _textureHeight = _height;
  Map<String, dynamic>? _startMap;
  Map<String, dynamic>? _stopMap;
  List<String> _failureReasons = const <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _run();
    });
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method,
    Map<String, Object?> args,
  ) async {
    final response =
        await _channel.invokeMethod<Object?>(method, args).timeout(
              _nativeCallTimeout,
            );
    if (response == null || response is! Map) {
      throw StateError('$method returned invalid response: $response');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<void> _run() async {
    Map<String, dynamic>? startMap;
    Map<String, dynamic>? stopMap;
    String? startError;
    String? stopError;
    String? sessionId;
    int? textureId;
    final failureReasons = <String>[];

    print('IOS_ARKIT_LIVE_PREVIEW_START '
        'width=$_width height=$_height targetFps=$_targetFps '
        'holdSeconds=$_holdSeconds');

    // ---- start ---------------------------------------------------------
    try {
      startMap = await _invokeMap(
        'startLiveGreenScreenARKitPreviewProbe',
        <String, Object?>{
          'width': _width,
          'height': _height,
          'targetFps': _targetFps,
          'trackingConfiguration': 'face',
        },
      );
      sessionId = _asNonEmptyString(startMap['sessionId']);
      textureId = _asInt(startMap['textureId']);
      if (textureId == null) {
        failureReasons.add(
          'start_missing_texture_id: '
          '${_asNonEmptyString(startMap['failureReason']) ?? 'native start returned no textureId'}',
        );
      }
    } on TimeoutException catch (te) {
      startError = 'Watchdog timeout waiting for native start: $te';
    } on PlatformException catch (pe) {
      startError = 'PlatformException(${pe.code}): ${pe.message}';
    } catch (e, st) {
      startError = '$e\n$st';
    }
    if (startError != null) {
      failureReasons.add('start_failed: $startError');
      print('IOS_ARKIT_LIVE_PREVIEW_ERROR: $startError');
    }

    final started = startError == null && textureId != null;
    if (started) {
      final width = _asInt(startMap?['width']) ?? _width;
      final height = _asInt(startMap?['height']) ?? _height;
      print('IOS_ARKIT_LIVE_PREVIEW_STARTED '
          'sessionId=$sessionId textureId=$textureId '
          'width=$width height=$height '
          'videoFormat=${startMap?['videoFormatWidth']}x${startMap?['videoFormatHeight']}'
          '@${startMap?['videoFormatFramesPerSecond']}');
      if (mounted) {
        setState(() {
          _startMap = startMap;
          _textureId = textureId;
          _textureWidth = width;
          _textureHeight = height;
          _status = 'LIVE — holding ${_holdSeconds}s';
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
      try {
        stopMap = await _invokeMap(
          'stopLiveGreenScreenARKitPreviewProbe',
          // null sessionId arrives natively as NSNull and is treated as absent.
          <String, Object?>{'sessionId': sessionId},
        );
      } on TimeoutException catch (te) {
        stopError = 'Watchdog timeout waiting for native stop: $te';
      } on PlatformException catch (pe) {
        stopError = 'PlatformException(${pe.code}): ${pe.message}';
      } catch (e, st) {
        stopError = '$e\n$st';
      }
      if (stopError != null) {
        failureReasons.add('stop_failed: $stopError');
        print('IOS_ARKIT_LIVE_PREVIEW_ERROR: $stopError');
      }
    }

    // ---- evaluate -----------------------------------------------------
    if (started) {
      if (stopMap == null) {
        if (stopError == null) failureReasons.add('stop_summary_missing');
      } else {
        _evaluateStopSummary(stopMap, failureReasons);
      }
    }

    // ---- markers ------------------------------------------------------
    final summary = stopMap;
    print('IOS_ARKIT_LIVE_PREVIEW_FIRST_MASK '
        'firstMaskLatencyMs=${summary?['firstMaskLatencyMs']} '
        'maskCount=${summary?['maskCount']} '
        'rawSegmentationBuffer=${summary?['rawSegmentationBufferWidth']}x${summary?['rawSegmentationBufferHeight']} '
        'source=native_stop_summary');
    print('IOS_ARKIT_LIVE_PREVIEW_CADENCE '
        'frameCount=${summary?['frameCount']} '
        'publishedFrames=${summary?['publishedFrames']} '
        'droppedBusyFrames=${summary?['droppedBusyFrames']} '
        'skippedNoMaskFrames=${summary?['skippedNoMaskFrames']} '
        'throttledFrames=${summary?['throttledFrames']} '
        'droppedPoolExhaustedFrames=${summary?['droppedPoolExhaustedFrames']} '
        'avgFrameIntervalMs=${summary?['avgFrameIntervalMs']} '
        'effectiveFps=${summary?['effectiveFps']} '
        'targetFps=$_targetFps '
        'runDurationMs=${summary?['runDurationMs']}');
    print('IOS_ARKIT_LIVE_PREVIEW_TELEMETRY '
        'avgMatteGenerationMs=${summary?['avgMatteGenerationMs']} '
        'p95MatteGenerationMs=${summary?['p95MatteGenerationMs']} '
        'avgCompositeMs=${summary?['avgCompositeMs']} '
        'p95CompositeMs=${summary?['p95CompositeMs']} '
        'capturedImage=${summary?['capturedImageWidth']}x${summary?['capturedImageHeight']} '
        'matte=${summary?['matteWidth']}x${summary?['matteHeight']} '
        'videoFormat=${summary?['videoFormatWidth']}x${summary?['videoFormatHeight']}'
        '@${summary?['videoFormatFramesPerSecond']} '
        'interruptionCount=${summary?['interruptionCount']} '
        'renderFailureCount=${summary?['renderFailureCount']} '
        'stopRenderDrainTimedOut=${summary?['stopRenderDrainTimedOut']}');
    print('IOS_ARKIT_LIVE_PREVIEW_STOP '
        'sessionId=${summary?['sessionId'] ?? sessionId} '
        'textureId=${summary?['textureId'] ?? textureId} '
        'nativePass=${summary?['pass']} '
        'failureReason=${summary?['failureReason']} '
        'stopError=$stopError');

    final pass = failureReasons.isEmpty && started && stopMap != null;

    final payload = <String, dynamic>{
      'proofBoundary': _proofBoundary,
      'pass': pass,
      'nativeStartSucceeded': started,
      'nativeStopPass': stopMap?['pass'],
      'sessionId': summary?['sessionId'] ?? sessionId,
      'textureId': summary?['textureId'] ?? textureId,
      'width': summary?['width'] ?? _width,
      'height': summary?['height'] ?? _height,
      'targetFps': summary?['targetFps'] ?? _targetFps,
      'holdSeconds': _holdSeconds,
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
      'avgFrameIntervalMs': summary?['avgFrameIntervalMs'],
      'effectiveFps': summary?['effectiveFps'],
      'avgMatteGenerationMs': summary?['avgMatteGenerationMs'],
      'p95MatteGenerationMs': summary?['p95MatteGenerationMs'],
      'avgCompositeMs': summary?['avgCompositeMs'],
      'p95CompositeMs': summary?['p95CompositeMs'],
      'failureReason': summary?['failureReason'],
      'harnessFailureReasons': failureReasons,
      'startError': startError,
      'stopError': stopError,
      'nonClaims': _nonClaims,
      'startResult': startMap,
      'stopResult': stopMap,
    };
    print('IOS_ARKIT_LIVE_PREVIEW_JSON:${jsonEncode(payload)}');
    print(pass ? 'IOS_ARKIT_LIVE_PREVIEW_PASS' : 'IOS_ARKIT_LIVE_PREVIEW_FAIL');

    if (mounted) {
      setState(() {
        _textureId = null; // texture is unregistered natively after stop
        _stopMap = stopMap;
        _failureReasons = failureReasons;
        _status = pass ? 'PASS' : 'FAIL';
      });
    }
    // Brief dwell so the final status panel is visible on device before exit.
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(pass ? 0 : 1);
  }

  /// Contract pass criteria over the native stop summary. Each violation is
  /// appended to [failureReasons] so the JSON explains exactly what failed.
  void _evaluateStopSummary(
    Map<String, dynamic> summary,
    List<String> failureReasons,
  ) {
    if (summary['pass'] != true) {
      failureReasons.add('native_stop_pass_false');
    }
    if (summary['proofBoundary'] != _proofBoundary) {
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
    if (summary['orientationMode'] != 'leftMirrored') {
      failureReasons.add(
        'orientation_mode_not_left_mirrored: ${summary['orientationMode']}',
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
    if (_asInt(summary['droppedBusyFrames']) == null) {
      failureReasons.add('dropped_busy_frames_missing');
    }
    if (_asInt(summary['skippedNoMaskFrames']) == null) {
      failureReasons.add('skipped_no_mask_frames_missing');
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
                        'ARKit Live Matte Preview (RND) — $_status',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'face / front camera / leftMirrored / teal\n'
                        'canvas=${_textureWidth}x$_textureHeight targetFps=$_targetFps '
                        'hold=${_holdSeconds}s\n'
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
