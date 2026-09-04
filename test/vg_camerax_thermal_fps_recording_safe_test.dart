// vg_camerax_thermal_fps_recording_safe_test.dart
// vanguard_media_engine -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-RECORDING-SAFE Dart
// contract tests: model parsing, telemetry serialization, MethodChannel
// dispatch, and pure helper invariants for mid-recording CameraX thermal AE
// target FPS actuation. Pure Dart-side tests -- device-free.

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

/// Pure helper to identify if an error from startRecording is caused by
/// missing/denied RECORD_AUDIO permission or SecurityException.
bool isRecordAudioPermissionBlocker(Object error) {
  if (error is PlatformException) {
    final code = error.code.toUpperCase();
    final message = (error.message ?? '').toUpperCase();
    final details = (error.details?.toString() ?? '').toUpperCase();
    if (code.contains('PERMISSION') ||
        code.contains('SECURITY') ||
        message.contains('RECORD_AUDIO') ||
        message.contains('PERMISSION') ||
        message.contains('SECURITYEXCEPTION') ||
        details.contains('RECORD_AUDIO') ||
        details.contains('PERMISSION')) {
      return true;
    }
  }
  final str = error.toString().toUpperCase();
  return str.contains('RECORD_AUDIO') ||
      str.contains('SECURITYEXCEPTION') ||
      (str.contains('PERMISSION') && str.contains('AUDIO'));
}

/// Pure helper to verify if the given bytes begin with an MP4 ftyp box header.
/// In ISO BMFF / MP4, bytes 4..7 contain the ASCII string "ftyp".
bool hasMp4FtypHeader(List<int> bytes) {
  if (bytes.length < 8) return false;
  final asciiString = ascii.decode(
    bytes.sublist(0, 64 < bytes.length ? 64 : bytes.length),
    allowInvalid: true,
  );
  return asciiString.contains('ftyp');
}

/// Pure helper verifying mid-recording actuation invariants across diagnostics
/// before apply, the apply result, and diagnostics after apply.
bool validateMidRecordingActuation({
  required VGCameraXThermalFpsDiagnostics before,
  required VGCameraXThermalFpsApplyResult apply,
  required VGCameraXThermalFpsDiagnostics during,
}) {
  if (!before.running) return false;
  if (before.observedAeTargetFpsUpper == null) return false;
  final observedBefore = before.observedAeTargetFpsUpper!;

  // Actuation outcome must be APPLIED with recording flags true.
  if (apply.outcome != 'APPLIED') return false;
  if (!apply.recordingActiveAtApply || !apply.isRecordingAtApply) return false;
  if (apply.selectedUpper >= observedBefore) return false;

  // Telemetry during recording must prove hardware effect without rebind.
  if (during.consecutiveAppliedRangeCompletedCaptures < 2) return false;
  if (during.appliedAeTargetFpsUpper != apply.selectedUpper) return false;
  if (during.appliedAeTargetFpsLower != apply.selectedLower) return false;
  if (during.appliedRange != apply.selectedRange) return false;
  if (during.appliedAeTargetFpsUpper! >= observedBefore) return false;
  if (during.observedAeTargetFpsUpper != null &&
      during.observedAeTargetFpsUpper! >= observedBefore) {
    return false;
  }
  if (!during.isRecording || !during.isRecordingActive) return false;

  // No-rebind invariants:
  if (during.textureId != before.textureId) return false;
  if (during.bindGeneration != before.bindGeneration) return false;
  if (during.bindCount != before.bindCount) return false;
  if (during.surfaceRequestCount != before.surfaceRequestCount) return false;
  if (during.cameraProviderIdentity != before.cameraProviderIdentity) {
    return false;
  }

  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  const expectedBridgeProofBoundary =
      'camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product';

  const expectedBridgeNonClaims = <String, bool>{
    'midRecordingActuationProven': false,
    'osThermalListenerWired': false,
    'resolutionReconfigured': false,
    'secondaryCameraTouched': false,
    'realForcedOverheat': false,
    'encoderTouched': false,
    'rendererTouched': false,
    'productUiWired': false,
  };

  // ----------------------------------------------------------------------
  // 1. VGCameraXThermalFpsApplyResult mid-recording shape
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsApplyResult mid-recording shape', () {
    test('fromMap parses a complete mid-recording apply result', () {
      final raw = <Object?, Object?>{
        'requestedTargetFps': 24,
        'observedCurrentLower': 30,
        'observedCurrentUpper': 30,
        'selectedLower': 24,
        'selectedUpper': 24,
        'selectedRange': <Object?, Object?>{'lower': 24, 'upper': 24},
        'observedRangeBefore': <Object?, Object?>{'lower': 30, 'upper': 30},
        'observedRangeAfter': <Object?, Object?>{'lower': 30, 'upper': 30},
        'availableRanges': <Object?>[
          <Object?, Object?>{'lower': 15, 'upper': 15},
          <Object?, Object?>{'lower': 24, 'upper': 24},
          <Object?, Object?>{'lower': 30, 'upper': 30},
        ],
        'bindGeneration': 1,
        'recordingActiveAtApply': true,
        'isRecordingAtApply': true,
        'completedCaptureCountBefore': 12,
        'completedCaptureCountAfter': 13,
        'outcome': 'APPLIED',
        'reasons': <Object?>['APPLIED'],
        'proofBoundary': expectedBridgeProofBoundary,
        'nonClaims': expectedBridgeNonClaims,
      };

      final result = VGCameraXThermalFpsApplyResult.fromMap(raw);
      expect(result, isNotNull);
      expect(result!.requestedTargetFps, equals(24));
      expect(result.observedCurrentLower, equals(30));
      expect(result.observedCurrentUpper, equals(30));
      expect(result.selectedLower, equals(24));
      expect(result.selectedUpper, equals(24));
      expect(
        result.selectedRange,
        equals(const VGCameraXThermalFpsRange(lower: 24, upper: 24)),
      );
      expect(
        result.observedRangeBefore,
        equals(const VGCameraXThermalFpsRange(lower: 30, upper: 30)),
      );
      expect(result.availableRanges.length, equals(3));
      expect(result.bindGeneration, equals(1));
      expect(result.recordingActiveAtApply, isTrue);
      expect(result.isRecordingAtApply, isTrue);
      expect(result.completedCaptureCountBefore, equals(12));
      expect(result.completedCaptureCountAfter, equals(13));
      expect(result.outcome, equals('APPLIED'));
      expect(result.reasons, equals(const <String>['APPLIED']));
      expect(result.proofBoundary, equals(expectedBridgeProofBoundary));
      expect(result.nonClaims, equals(expectedBridgeNonClaims));
    });

    test(
      'toMap round-trips preserving recording flags and proof telemetry',
      () {
        const applyResult = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 20,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 20,
          selectedUpper: 20,
          selectedRange: VGCameraXThermalFpsRange(lower: 20, upper: 20),
          observedRangeBefore: VGCameraXThermalFpsRange(lower: 30, upper: 30),
          observedRangeAfter: VGCameraXThermalFpsRange(lower: 30, upper: 30),
          availableRanges: <VGCameraXThermalFpsRange>[
            VGCameraXThermalFpsRange(lower: 20, upper: 20),
            VGCameraXThermalFpsRange(lower: 30, upper: 30),
          ],
          bindGeneration: 2,
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          completedCaptureCountBefore: 50,
          completedCaptureCountAfter: 51,
          outcome: 'APPLIED',
          reasons: <String>['APPLIED'],
          proofBoundary: expectedBridgeProofBoundary,
          nonClaims: expectedBridgeNonClaims,
        );

        final map = applyResult.toMap();
        expect(map['recordingActiveAtApply'], isTrue);
        expect(map['isRecordingAtApply'], isTrue);
        expect(map['outcome'], equals('APPLIED'));

        final roundTripped = VGCameraXThermalFpsApplyResult.fromMap(map);
        expect(roundTripped, equals(applyResult));
      },
    );

    test(
      'equality differentiates recordingActiveAtApply and isRecordingAtApply',
      () {
        const base = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
        );
        const idleApply = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          recordingActiveAtApply: false,
          isRecordingAtApply: false,
        );

        expect(base == idleApply, isFalse);
        expect(base.hashCode == idleApply.hashCode, isFalse);
      },
    );
  });

  // ----------------------------------------------------------------------
  // 2. VGCameraXThermalFpsDiagnostics mid-recording shape
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsDiagnostics mid-recording shape', () {
    test('fromMap parses a complete mid-recording diagnostics snapshot', () {
      final raw = <Object?, Object?>{
        'running': true,
        'textureId': 4,
        'bindGeneration': 1,
        'bindCount': 1,
        'surfaceRequestCount': 2,
        'cameraProviderIdentity': 98765,
        'completedCaptureCount': 88,
        'observedAeTargetFpsLower': 24,
        'observedAeTargetFpsUpper': 24,
        'appliedAeTargetFpsLower': 24,
        'appliedAeTargetFpsUpper': 24,
        'consecutiveAppliedRangeCompletedCaptures': 5,
        'isRecording': true,
        'isRecordingActive': true,
        'appliedRange': <Object?, Object?>{'lower': 24, 'upper': 24},
        'observedRangeBefore': <Object?, Object?>{'lower': 30, 'upper': 30},
        'observedRangeAfter': <Object?, Object?>{'lower': 24, 'upper': 24},
        'availableRanges': <Object?>[
          <Object?, Object?>{'lower': 24, 'upper': 24},
          <Object?, Object?>{'lower': 30, 'upper': 30},
        ],
        'recordingActiveAtApply': true,
        'isRecordingAtApply': true,
        'completedCaptureCountBefore': 80,
        'completedCaptureCountAfter': 81,
        'outcome': 'APPLIED',
        'reasons': <Object?>['APPLIED'],
        'proofBoundary': expectedBridgeProofBoundary,
        'nonClaims': expectedBridgeNonClaims,
      };

      final diagnostics = VGCameraXThermalFpsDiagnostics.fromMap(raw);
      expect(diagnostics, isNotNull);
      expect(diagnostics!.running, isTrue);
      expect(diagnostics.textureId, equals(4));
      expect(diagnostics.bindGeneration, equals(1));
      expect(diagnostics.bindCount, equals(1));
      expect(diagnostics.surfaceRequestCount, equals(2));
      expect(diagnostics.cameraProviderIdentity, equals(98765));
      expect(diagnostics.completedCaptureCount, equals(88));
      expect(diagnostics.observedAeTargetFpsUpper, equals(24));
      expect(diagnostics.appliedAeTargetFpsUpper, equals(24));
      expect(diagnostics.consecutiveAppliedRangeCompletedCaptures, equals(5));
      expect(diagnostics.isRecording, isTrue);
      expect(diagnostics.isRecordingActive, isTrue);
      expect(diagnostics.recordingActiveAtApply, isTrue);
      expect(diagnostics.isRecordingAtApply, isTrue);
      expect(
        diagnostics.appliedRange,
        equals(const VGCameraXThermalFpsRange(lower: 24, upper: 24)),
      );
      expect(diagnostics.proofBoundary, equals(expectedBridgeProofBoundary));
      expect(diagnostics.nonClaims, equals(expectedBridgeNonClaims));
    });

    test(
      'toMap round-trips preserving active recording and consecutive count',
      () {
        const diag = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 4,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 98765,
          completedCaptureCount: 100,
          observedAeTargetFpsLower: 24,
          observedAeTargetFpsUpper: 24,
          appliedAeTargetFpsLower: 24,
          appliedAeTargetFpsUpper: 24,
          consecutiveAppliedRangeCompletedCaptures: 3,
          isRecording: true,
          isRecordingActive: true,
          appliedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          outcome: 'APPLIED',
        );

        final map = diag.toMap();
        expect(map['isRecording'], isTrue);
        expect(map['isRecordingActive'], isTrue);
        expect(map['consecutiveAppliedRangeCompletedCaptures'], equals(3));

        final roundTripped = VGCameraXThermalFpsDiagnostics.fromMap(map);
        expect(roundTripped, equals(diag));
      },
    );
  });

  // ----------------------------------------------------------------------
  // 3. VGCameraXThermalFpsBridge mid-recording MethodChannel dispatch
  // ----------------------------------------------------------------------
  group('VGCameraXThermalFpsBridge mid-recording MethodChannel dispatch', () {
    test(
      'applyAndroidCameraXThermalTargetFps receives recordingActiveAtApply true',
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
              'selectedRange': <Object?, Object?>{'lower': 24, 'upper': 24},
              'recordingActiveAtApply': true,
              'isRecordingAtApply': true,
              'outcome': 'APPLIED',
              'reasons': <Object?>['APPLIED'],
              'proofBoundary': expectedBridgeProofBoundary,
              'nonClaims': expectedBridgeNonClaims,
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
        expect((recordedCall!.arguments as Map)['targetFps'], equals(24));
        expect(result.recordingActiveAtApply, isTrue);
        expect(result.isRecordingAtApply, isTrue);
        expect(result.outcome, equals('APPLIED'));
        expect(result.selectedUpper, equals(24));
      },
    );

    test(
      'getAndroidCameraXThermalFpsDiagnostics receives isRecordingActive true',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAndroidCameraXThermalFpsDiagnostics') {
            return <Object?, Object?>{
              'running': true,
              'textureId': 10,
              'bindGeneration': 1,
              'bindCount': 1,
              'surfaceRequestCount': 2,
              'cameraProviderIdentity': 777,
              'completedCaptureCount': 40,
              'observedAeTargetFpsLower': 24,
              'observedAeTargetFpsUpper': 24,
              'appliedAeTargetFpsLower': 24,
              'appliedAeTargetFpsUpper': 24,
              'consecutiveAppliedRangeCompletedCaptures': 4,
              'isRecording': true,
              'isRecordingActive': true,
              'recordingActiveAtApply': true,
              'isRecordingAtApply': true,
              'outcome': 'APPLIED',
            };
          }
          return null;
        });

        final bridge = VGCameraXThermalFpsBridge(channel: channel);
        final diagnostics = await bridge
            .getAndroidCameraXThermalFpsDiagnostics();

        expect(diagnostics.running, isTrue);
        expect(diagnostics.isRecording, isTrue);
        expect(diagnostics.isRecordingActive, isTrue);
        expect(diagnostics.consecutiveAppliedRangeCompletedCaptures, equals(4));
        expect(diagnostics.appliedAeTargetFpsUpper, equals(24));
      },
    );
  });

  // ----------------------------------------------------------------------
  // 4. Pure helper assertions
  // ----------------------------------------------------------------------
  group('Pure helper assertions', () {
    test(
      'isRecordAudioPermissionBlocker correctly classifies permission failures',
      () {
        // Direct SecurityException in PlatformException message.
        expect(
          isRecordAudioPermissionBlocker(
            PlatformException(
              code: 'REC_FAIL',
              message:
                  'java.lang.SecurityException: Permission android.permission.RECORD_AUDIO not granted',
            ),
          ),
          isTrue,
        );

        // Code contains PERMISSION.
        expect(
          isRecordAudioPermissionBlocker(
            PlatformException(
              code: 'PERMISSION_DENIED',
              message: 'User denied audio recording',
            ),
          ),
          isTrue,
        );

        // Generic string exception.
        expect(
          isRecordAudioPermissionBlocker(
            Exception('SecurityException: missing RECORD_AUDIO'),
          ),
          isTrue,
        );

        // Non-permission error returns false.
        expect(
          isRecordAudioPermissionBlocker(
            PlatformException(
              code: 'REC_FAIL',
              message: 'Disk full / out of space',
            ),
          ),
          isFalse,
        );
        expect(
          isRecordAudioPermissionBlocker(
            Exception('Video encoder failed to configure'),
          ),
          isFalse,
        );
      },
    );

    test('hasMp4FtypHeader detects valid ftyp box header in byte stream', () {
      // Standard MP4 ftyp box: 4 bytes length, "ftyp" ASCII, major brand "isom".
      final validFtyp = <int>[
        0x00, 0x00, 0x00, 0x20, // box size: 32 bytes
        0x66, 0x74, 0x79, 0x70, // "ftyp"
        0x69, 0x73, 0x6f, 0x6d, // "isom"
        0x00, 0x00, 0x02, 0x00, // minor version
      ];
      expect(hasMp4FtypHeader(validFtyp), isTrue);

      // Header with "moov" box instead of "ftyp".
      final nonFtyp = <int>[
        0x00, 0x00, 0x00, 0x20,
        0x6d, 0x6f, 0x6f, 0x76, // "moov"
        0x69, 0x73, 0x6f, 0x6d,
        0x00, 0x00, 0x02, 0x00,
      ];
      expect(hasMp4FtypHeader(nonFtyp), isFalse);

      // Empty or truncated bytes.
      expect(hasMp4FtypHeader(const <int>[]), isFalse);
      expect(hasMp4FtypHeader(<int>[0, 0, 0]), isFalse);
    });

    test(
      'validateMidRecordingActuation passes when all lanes are coherent',
      () {
        const before = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 10,
          observedAeTargetFpsLower: 30,
          observedAeTargetFpsUpper: 30,
          consecutiveAppliedRangeCompletedCaptures: 0,
          isRecording: false,
          isRecordingActive: false,
        );

        const apply = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          selectedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          outcome: 'APPLIED',
        );

        const during = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 25,
          observedAeTargetFpsLower: 24,
          observedAeTargetFpsUpper: 24,
          appliedAeTargetFpsLower: 24,
          appliedAeTargetFpsUpper: 24,
          appliedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          consecutiveAppliedRangeCompletedCaptures: 3,
          isRecording: true,
          isRecordingActive: true,
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          outcome: 'APPLIED',
        );

        expect(
          validateMidRecordingActuation(
            before: before,
            apply: apply,
            during: during,
          ),
          isTrue,
        );
      },
    );

    test(
      'validateMidRecordingActuation fails if rebind occurred (bindGeneration changed)',
      () {
        const before = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 10,
          observedAeTargetFpsLower: 30,
          observedAeTargetFpsUpper: 30,
          consecutiveAppliedRangeCompletedCaptures: 0,
          isRecording: false,
          isRecordingActive: false,
        );

        const apply = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          selectedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          outcome: 'APPLIED',
        );

        // Rebind advanced bindGeneration to 2 and surfaceRequestCount to 3.
        const rebindDuring = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 2,
          bindCount: 2,
          surfaceRequestCount: 3,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 25,
          observedAeTargetFpsLower: 24,
          observedAeTargetFpsUpper: 24,
          appliedAeTargetFpsLower: 24,
          appliedAeTargetFpsUpper: 24,
          appliedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          consecutiveAppliedRangeCompletedCaptures: 3,
          isRecording: true,
          isRecordingActive: true,
        );

        expect(
          validateMidRecordingActuation(
            before: before,
            apply: apply,
            during: rebindDuring,
          ),
          isFalse,
        );
      },
    );

    test(
      'validateMidRecordingActuation fails if recording was not active at apply',
      () {
        const before = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 10,
          observedAeTargetFpsLower: 30,
          observedAeTargetFpsUpper: 30,
          consecutiveAppliedRangeCompletedCaptures: 0,
          isRecording: false,
          isRecordingActive: false,
        );

        const idleApply = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          selectedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          recordingActiveAtApply: false, // Inactive at apply
          isRecordingAtApply: false,
          outcome: 'APPLIED',
        );

        const during = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 25,
          observedAeTargetFpsLower: 24,
          observedAeTargetFpsUpper: 24,
          appliedAeTargetFpsLower: 24,
          appliedAeTargetFpsUpper: 24,
          appliedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          consecutiveAppliedRangeCompletedCaptures: 3,
          isRecording: true,
          isRecordingActive: true,
        );

        expect(
          validateMidRecordingActuation(
            before: before,
            apply: idleApply,
            during: during,
          ),
          isFalse,
        );
      },
    );

    test(
      'validateMidRecordingActuation fails if consecutiveAppliedRangeCompletedCaptures < 2',
      () {
        const before = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 10,
          observedAeTargetFpsLower: 30,
          observedAeTargetFpsUpper: 30,
          consecutiveAppliedRangeCompletedCaptures: 0,
          isRecording: false,
          isRecordingActive: false,
        );

        const apply = VGCameraXThermalFpsApplyResult(
          requestedTargetFps: 24,
          observedCurrentLower: 30,
          observedCurrentUpper: 30,
          selectedLower: 24,
          selectedUpper: 24,
          selectedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          recordingActiveAtApply: true,
          isRecordingAtApply: true,
          outcome: 'APPLIED',
        );

        // Only 1 consecutive capture observed on applied range.
        const duringOneCapture = VGCameraXThermalFpsDiagnostics(
          running: true,
          textureId: 5,
          bindGeneration: 1,
          bindCount: 1,
          surfaceRequestCount: 2,
          cameraProviderIdentity: 1234,
          completedCaptureCount: 25,
          observedAeTargetFpsLower: 24,
          observedAeTargetFpsUpper: 24,
          appliedAeTargetFpsLower: 24,
          appliedAeTargetFpsUpper: 24,
          appliedRange: VGCameraXThermalFpsRange(lower: 24, upper: 24),
          consecutiveAppliedRangeCompletedCaptures: 1,
          isRecording: true,
          isRecordingActive: true,
        );

        expect(
          validateMidRecordingActuation(
            before: before,
            apply: apply,
            during: duringOneCapture,
          ),
          isFalse,
        );
      },
    );
  });
}
