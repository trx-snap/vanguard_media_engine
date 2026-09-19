// ios_arkit_person_segmentation_probe_physical_smoke.dart
// Vanguard Media Engine — iOS ARKit person-segmentation capability probe.
//
// Diagnostic-only RND proof (proofBoundary
// 'ios_arkit_person_segmentation_probe_physical_smoke'): invokes the
// diagnostic-only native route runLiveGreenScreenARKitPersonSegmentationProbe
// directly over MethodChannel('vanguard_media_engine'). Not part of the
// public vanguard_media_engine Dart API. `trackingConfiguration` (dart-define
// IOS_ARKIT_PERSON_SEGMENTATION_TRACKING_CONFIGURATION, default 'world')
// selects which ARKit configuration is actually started this run:
// 'world' → rear-camera ARWorldTrackingConfiguration (default); 'face' →
// front-camera ARFaceTrackingConfiguration. Reports whether this device's
// selected configuration supports the .personSegmentation frame semantic
// and, when supported, the first observed ARFrame.segmentationBuffer
// dimensions/format and coarse timing. Also always reports the static
// capability telemetry for both configurations (worldTrackingSupported /
// personSegmentationSupported / personSegmentationWithDepthSupported /
// faceTrackingSupported / facePersonSegmentationSupported /
// facePersonSegmentationWithDepthSupported); only the selected configuration
// is actually started as a session. Does not exercise the live green-screen
// session, Vision, or LiteRT paths.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _timeoutSeconds = int.fromEnvironment(
  'IOS_ARKIT_PERSON_SEGMENTATION_TIMEOUT_SECONDS',
  defaultValue: 8,
);

const int _maxFrameCount = int.fromEnvironment(
  'IOS_ARKIT_PERSON_SEGMENTATION_MAX_FRAMES',
  defaultValue: 90,
);

const String _rawTrackingConfiguration = String.fromEnvironment(
  'IOS_ARKIT_PERSON_SEGMENTATION_TRACKING_CONFIGURATION',
  defaultValue: 'world',
);

/// Validated at load time: only 'world' or 'face' are accepted so a typo in
/// the dart-define can never silently fall back to 'world'.
final String _trackingConfiguration = _validateTrackingConfiguration(
  _rawTrackingConfiguration,
);

String _validateTrackingConfiguration(String value) {
  if (value != 'world' && value != 'face') {
    throw ArgumentError(
      "IOS_ARKIT_PERSON_SEGMENTATION_TRACKING_CONFIGURATION must be one of "
      "'world', 'face' (got '$value')",
    );
  }
  return value;
}

void main() {
  runApp(const IosArkitPersonSegmentationProbePhysicalSmokeApp());
}

class IosArkitPersonSegmentationProbePhysicalSmokeApp extends StatefulWidget {
  const IosArkitPersonSegmentationProbePhysicalSmokeApp({super.key});

  @override
  State<IosArkitPersonSegmentationProbePhysicalSmokeApp> createState() =>
      _IosArkitPersonSegmentationProbePhysicalSmokeAppState();
}

class _IosArkitPersonSegmentationProbePhysicalSmokeAppState
    extends State<IosArkitPersonSegmentationProbePhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  String _status = 'Initializing ARKit person-segmentation probe…';
  Map<String, dynamic>? _resultMap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProbe();
    });
  }

  Future<void> _runProbe() async {
    print('IOS_ARKIT_PERSON_SEGMENTATION_PROBE_INVOKE '
        'timeoutSeconds=$_timeoutSeconds maxFrameCount=$_maxFrameCount '
        'trackingConfiguration=$_trackingConfiguration');

    Map<String, dynamic>? resultMap;
    String? topLevelError;
    var pass = false;

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runLiveGreenScreenARKitPersonSegmentationProbe',
        <String, Object>{
          'timeoutSeconds': _timeoutSeconds,
          'maxFrameCount': _maxFrameCount,
          'trackingConfiguration': _trackingConfiguration,
        },
      ).timeout(Duration(seconds: _timeoutSeconds + 10));

      if (response == null || response is! Map) {
        throw Exception(
          'runLiveGreenScreenARKitPersonSegmentationProbe returned invalid response: $response',
        );
      }

      resultMap = Map<String, dynamic>.from(response);
      pass = resultMap['pass'] == true;
    } on TimeoutException catch (te) {
      topLevelError = 'Watchdog timeout waiting for native probe: $te';
      print('IOS_ARKIT_PERSON_SEGMENTATION_PROBE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('IOS_ARKIT_PERSON_SEGMENTATION_PROBE_ERROR: $topLevelError');
    } finally {
      final payload = <String, dynamic>{
        'proofBoundary': 'ios_arkit_person_segmentation_probe_physical_smoke',
        'pass': pass,
        'timeoutSeconds': _timeoutSeconds,
        'maxFrameCount': _maxFrameCount,
        'result': resultMap,
        'error': topLevelError,
      };

      print('IOS_ARKIT_PERSON_SEGMENTATION_PROBE_JSON:${jsonEncode(payload)}');

      // Compact single-line marker (no claims arrays) so Flutter logs don't
      // truncate the critical fields before they reach the console.
      final compactPayload = <String, dynamic>{
        'pass': pass,
        'trackingConfiguration':
            resultMap?['trackingConfiguration'] ?? _trackingConfiguration,
        'activeTrackingUsesFrontCamera':
            resultMap?['activeTrackingUsesFrontCamera'],
        'supported': resultMap?['supported'],
        'worldTrackingSupported': resultMap?['worldTrackingSupported'],
        'personSegmentationSupported':
            resultMap?['personSegmentationSupported'],
        'personSegmentationWithDepthSupported':
            resultMap?['personSegmentationWithDepthSupported'],
        'faceTrackingSupported': resultMap?['faceTrackingSupported'],
        'facePersonSegmentationSupported':
            resultMap?['facePersonSegmentationSupported'],
        'facePersonSegmentationWithDepthSupported':
            resultMap?['facePersonSegmentationWithDepthSupported'],
        'frameCount': resultMap?['frameCount'],
        'maskCount': resultMap?['maskCount'],
        'segmentationBufferWidth': resultMap?['segmentationBufferWidth'],
        'segmentationBufferHeight': resultMap?['segmentationBufferHeight'],
        'segmentationPixelFormat': resultMap?['segmentationPixelFormat'],
        'capturedImageWidth': resultMap?['capturedImageWidth'],
        'capturedImageHeight': resultMap?['capturedImageHeight'],
        'firstMaskLatencyMs': resultMap?['firstMaskLatencyMs'],
        'averageFrameIntervalMs': resultMap?['averageFrameIntervalMs'],
        'failureReason': resultMap?['failureReason'],
      };
      print(
        'IOS_ARKIT_PERSON_SEGMENTATION_PROBE_COMPACT_JSON:'
        '${jsonEncode(compactPayload)}',
      );

      print(
        pass
            ? 'IOS_ARKIT_PERSON_SEGMENTATION_PROBE_PASS'
            : 'IOS_ARKIT_PERSON_SEGMENTATION_PROBE_FAIL',
      );

      if (mounted) {
        setState(() {
          _resultMap = resultMap;
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _resultMap;
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'ARKit Person-Segmentation Probe',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                ),
                const SizedBox(height: 12),
                if (result != null)
                  Text(
                    'trackingConfiguration=${result['trackingConfiguration']} '
                    'activeTrackingUsesFrontCamera=${result['activeTrackingUsesFrontCamera']}\n'
                    'supported=${result['supported']} '
                    'worldTrackingSupported=${result['worldTrackingSupported']}\n'
                    'personSegmentationSupported=${result['personSegmentationSupported']}\n'
                    'personSegmentationWithDepthSupported=${result['personSegmentationWithDepthSupported']}\n'
                    'faceTrackingSupported=${result['faceTrackingSupported']}\n'
                    'facePersonSegmentationSupported=${result['facePersonSegmentationSupported']}\n'
                    'facePersonSegmentationWithDepthSupported=${result['facePersonSegmentationWithDepthSupported']}\n'
                    'frameCount=${result['frameCount']} maskCount=${result['maskCount']}\n'
                    'segmentationBuffer=${result['segmentationBufferWidth']}x${result['segmentationBufferHeight']} '
                    'pixelFormat=${result['segmentationPixelFormat']}\n'
                    'capturedImage=${result['capturedImageWidth']}x${result['capturedImageHeight']}\n'
                    'firstMaskLatencyMs=${result['firstMaskLatencyMs']} '
                    'averageFrameIntervalMs=${result['averageFrameIntervalMs']}\n'
                    'failureReason=${result['failureReason']}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
