// vg_camerax_thermal_fps_bridge_test.dart
// vanguard_media_engine -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE Dart contract
// tests: model parsing (fromMap/toMap/equality) and MethodChannel dispatch
// contract for VGCameraXThermalFpsBridge. Pure Dart-side tests -- no native
// camera hardware involved.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  // ----------------------------------------------------------------------
  // 1. VGCameraXThermalFpsApplyResult
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsApplyResult', () {
    test('fromMap parses a well-formed map', () {
      final result = VGCameraXThermalFpsApplyResult.fromMap(<Object?, Object?>{
        'requestedTargetFps': 24,
        'observedCurrentLower': 30,
        'observedCurrentUpper': 30,
        'selectedLower': 24,
        'selectedUpper': 24,
      });

      expect(result, isNotNull);
      expect(result!.requestedTargetFps, equals(24));
      expect(result.observedCurrentLower, equals(30));
      expect(result.observedCurrentUpper, equals(30));
      expect(result.selectedLower, equals(24));
      expect(result.selectedUpper, equals(24));
    });

    test('fromMap returns null for non-map input', () {
      expect(VGCameraXThermalFpsApplyResult.fromMap('not a map'), isNull);
      expect(VGCameraXThermalFpsApplyResult.fromMap(null), isNull);
    });

    test('fromMap returns null when a required field is missing', () {
      expect(
        VGCameraXThermalFpsApplyResult.fromMap(<Object?, Object?>{
          'requestedTargetFps': 24,
          'observedCurrentLower': 30,
          'observedCurrentUpper': 30,
          'selectedLower': 24,
          // selectedUpper missing
        }),
        isNull,
      );
    });

    test('toMap round-trips through fromMap', () {
      const result = VGCameraXThermalFpsApplyResult(
        requestedTargetFps: 24,
        observedCurrentLower: 30,
        observedCurrentUpper: 30,
        selectedLower: 24,
        selectedUpper: 24,
      );
      final roundTripped = VGCameraXThermalFpsApplyResult.fromMap(
        result.toMap(),
      );
      expect(roundTripped, equals(result));
    });

    test('equality and hashCode are value-based', () {
      const a = VGCameraXThermalFpsApplyResult(
        requestedTargetFps: 24,
        observedCurrentLower: 30,
        observedCurrentUpper: 30,
        selectedLower: 24,
        selectedUpper: 24,
      );
      const b = VGCameraXThermalFpsApplyResult(
        requestedTargetFps: 24,
        observedCurrentLower: 30,
        observedCurrentUpper: 30,
        selectedLower: 24,
        selectedUpper: 24,
      );
      const c = VGCameraXThermalFpsApplyResult(
        requestedTargetFps: 15,
        observedCurrentLower: 30,
        observedCurrentUpper: 30,
        selectedLower: 24,
        selectedUpper: 24,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
    });
  });

  // ----------------------------------------------------------------------
  // 2. VGCameraXThermalFpsDiagnostics
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsDiagnostics', () {
    test('fromMap parses a well-formed map with nulls for optional fields', () {
      final diagnostics =
          VGCameraXThermalFpsDiagnostics.fromMap(<Object?, Object?>{
            'running': false,
            'textureId': null,
            'bindGeneration': 0,
            'bindCount': 0,
            'surfaceRequestCount': 0,
            'cameraProviderIdentity': null,
            'completedCaptureCount': 0,
            'observedAeTargetFpsLower': null,
            'observedAeTargetFpsUpper': null,
            'appliedAeTargetFpsLower': null,
            'appliedAeTargetFpsUpper': null,
            'consecutiveAppliedRangeCompletedCaptures': 0,
            'isRecording': false,
            'isRecordingActive': false,
          });

      expect(diagnostics, isNotNull);
      expect(diagnostics!.running, isFalse);
      expect(diagnostics.textureId, isNull);
      expect(diagnostics.observedAeTargetFpsLower, isNull);
      expect(diagnostics.appliedAeTargetFpsUpper, isNull);
    });

    test('fromMap parses a fully-populated running session map', () {
      final diagnostics =
          VGCameraXThermalFpsDiagnostics.fromMap(<Object?, Object?>{
            'running': true,
            'textureId': 7,
            'bindGeneration': 1,
            'bindCount': 1,
            'surfaceRequestCount': 3,
            'cameraProviderIdentity': 123456,
            'completedCaptureCount': 42,
            'observedAeTargetFpsLower': 24,
            'observedAeTargetFpsUpper': 24,
            'appliedAeTargetFpsLower': 24,
            'appliedAeTargetFpsUpper': 24,
            'consecutiveAppliedRangeCompletedCaptures': 5,
            'isRecording': false,
            'isRecordingActive': false,
          });

      expect(diagnostics, isNotNull);
      expect(diagnostics!.running, isTrue);
      expect(diagnostics.textureId, equals(7));
      expect(diagnostics.bindGeneration, equals(1));
      expect(diagnostics.surfaceRequestCount, equals(3));
      expect(diagnostics.cameraProviderIdentity, equals(123456));
      expect(diagnostics.completedCaptureCount, equals(42));
      expect(diagnostics.observedAeTargetFpsUpper, equals(24));
      expect(diagnostics.appliedAeTargetFpsUpper, equals(24));
      expect(diagnostics.consecutiveAppliedRangeCompletedCaptures, equals(5));
    });

    test('fromMap returns null for non-map input', () {
      expect(VGCameraXThermalFpsDiagnostics.fromMap('not a map'), isNull);
      expect(VGCameraXThermalFpsDiagnostics.fromMap(null), isNull);
    });

    test('toMap round-trips through fromMap', () {
      const diagnostics = VGCameraXThermalFpsDiagnostics(
        running: true,
        textureId: 7,
        bindGeneration: 2,
        bindCount: 2,
        surfaceRequestCount: 5,
        cameraProviderIdentity: 999,
        completedCaptureCount: 10,
        observedAeTargetFpsLower: 24,
        observedAeTargetFpsUpper: 24,
        appliedAeTargetFpsLower: 24,
        appliedAeTargetFpsUpper: 24,
        consecutiveAppliedRangeCompletedCaptures: 2,
        isRecording: false,
        isRecordingActive: false,
      );
      final roundTripped = VGCameraXThermalFpsDiagnostics.fromMap(
        diagnostics.toMap(),
      );
      expect(roundTripped, equals(diagnostics));
    });
  });

  // ----------------------------------------------------------------------
  // 3. VGCameraXThermalFpsBridge MethodChannel Contract
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsBridge', () {
    test(
      'applyAndroidCameraXThermalTargetFps dispatches with targetFps and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'applyAndroidCameraXThermalTargetFps') {
            return <Object?, Object?>{
              'requestedTargetFps': 24,
              'observedCurrentLower': 30,
              'observedCurrentUpper': 30,
              'selectedLower': 24,
              'selectedUpper': 24,
            };
          }
          return null;
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        final result = await bridge.applyAndroidCameraXThermalTargetFps(24);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('applyAndroidCameraXThermalTargetFps'),
        );
        final callArgs = recordedCall!.arguments as Map;
        expect(callArgs['targetFps'], equals(24));

        expect(result.requestedTargetFps, equals(24));
        expect(result.selectedUpper, equals(24));
      },
    );

    test(
      'applyAndroidCameraXThermalTargetFps throws PlatformException on malformed result',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'applyAndroidCameraXThermalTargetFps') {
            return 'unexpected_string_response';
          }
          return null;
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        expect(
          () => bridge.applyAndroidCameraXThermalTargetFps(24),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'BAD_NATIVE_RESULT',
            ),
          ),
        );
      },
    );

    test(
      'applyAndroidCameraXThermalTargetFps propagates native PlatformException',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NO_REDUCTION',
            message:
                'no candidate range strictly below observed current upper 30',
          );
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        expect(
          () => bridge.applyAndroidCameraXThermalTargetFps(60),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'NO_REDUCTION',
            ),
          ),
        );
      },
    );

    test(
      'getAndroidCameraXThermalFpsDiagnostics dispatches and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'getAndroidCameraXThermalFpsDiagnostics') {
            return <Object?, Object?>{
              'running': true,
              'textureId': 3,
              'bindGeneration': 1,
              'bindCount': 1,
              'surfaceRequestCount': 2,
              'cameraProviderIdentity': 555,
              'completedCaptureCount': 8,
              'observedAeTargetFpsLower': 30,
              'observedAeTargetFpsUpper': 30,
              'appliedAeTargetFpsLower': null,
              'appliedAeTargetFpsUpper': null,
              'consecutiveAppliedRangeCompletedCaptures': 0,
              'isRecording': false,
              'isRecordingActive': false,
            };
          }
          return null;
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        final diagnostics = await bridge
            .getAndroidCameraXThermalFpsDiagnostics();

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('getAndroidCameraXThermalFpsDiagnostics'),
        );

        expect(diagnostics.running, isTrue);
        expect(diagnostics.textureId, equals(3));
        expect(diagnostics.surfaceRequestCount, equals(2));
        expect(diagnostics.observedAeTargetFpsUpper, equals(30));
        expect(diagnostics.appliedAeTargetFpsUpper, isNull);
      },
    );

    test(
      'getAndroidCameraXThermalFpsDiagnostics throws PlatformException on malformed result',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAndroidCameraXThermalFpsDiagnostics') {
            return 42;
          }
          return null;
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        expect(
          () => bridge.getAndroidCameraXThermalFpsDiagnostics(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'BAD_NATIVE_RESULT',
            ),
          ),
        );
      },
    );
  });
}
