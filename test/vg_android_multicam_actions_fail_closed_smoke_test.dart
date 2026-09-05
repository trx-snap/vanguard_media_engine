// vg_android_multicam_actions_fail_closed_smoke_test.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-MULTICAM-ACTIONS-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam preview/action routes fail-closed unit and smoke contract
// tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');

  Map<String, Object?>? asArgs(Object? raw) {
    if (raw is Map) return Map<String, Object?>.from(raw);
    return null;
  }

  bool hasNonBlank(Map<String, Object?>? args, String key) {
    final value = args?[key];
    return value is String && value.trim().isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // 1. Constants and Proof Boundary Tokens
  // ---------------------------------------------------------------------------
  group('Android MultiCam actions fail-closed constants and markers', () {
    test('proof boundary has exact required string value', () {
      expect(
        kAndroidMultiCamActionsFailClosedProofBoundary,
        equals(
          'android_multicam_actions_fail_closed_route_handling_capability_gated_no_camera_open_no_texture_no_capture',
        ),
      );
    });

    test('start marker has exact required token', () {
      expect(
        kAndroidMultiCamActionsFailClosedStartMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_START',
        ),
      );
    });

    test('pass marker has exact required token', () {
      expect(
        kAndroidMultiCamActionsFailClosedPassMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_PASS',
        ),
      );
    });

    test('fail marker has exact required token', () {
      expect(
        kAndroidMultiCamActionsFailClosedFailMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_PHYSICAL_SMOKE_FAIL',
        ),
      );
    });

    test('JSON prefix has exact required token', () {
      expect(
        kAndroidMultiCamActionsFailClosedJsonPrefix,
        equals('ANDROID_DAG_PHASE3_MULTICAM_ACTIONS_FAIL_CLOSED_JSON:'),
      );
    });

    test(
      'allowed diagnostic error codes are exactly the two fail-closed codes',
      () {
        expect(
          kAndroidMultiCamActionsFailClosedAllowedDiagnosticErrorCodes,
          equals(<String>[
            'CONCURRENT_NOT_SUPPORTED',
            'CONCURRENT_PREVIEW_NOT_READY',
          ]),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 2. Report Serialization & Deserialization (toMap / fromMap)
  // ---------------------------------------------------------------------------
  group('VGAndroidMultiCamActionsFailClosedSmokeReport toMap and fromMap', () {
    const report = VGAndroidMultiCamActionsFailClosedSmokeReport(
      pass: true,
      proofBoundary: kAndroidMultiCamActionsFailClosedProofBoundary,
      directStopPreviewIdempotentOk: true,
      directStopRenderDiagnosticIdempotentOk: true,
      directRunDiagnosticInvalidArgOk: true,
      directStartDiagnosticInvalidArgOk: true,
      directRunDiagnosticFailClosedOk: true,
      directRunDiagnosticErrorCode: 'CONCURRENT_NOT_SUPPORTED',
      directStartDiagnosticFailClosedOk: true,
      directStartDiagnosticErrorCode: 'CONCURRENT_NOT_SUPPORTED',
      directUpdateConfigMissingInvalidArgOk: true,
      directUpdateConfigWithConfigNotRunningOk: true,
      directTakePhotoMissingInvalidArgOk: true,
      directTakePhotoValidPathNotRunningOk: true,
      directStartRecordingMissingInvalidArgOk: true,
      directStartRecordingValidPathNotRunningOk: true,
      directStopRecordingNotRunningOk: true,
      publicRunDiagnosticNullOk: true,
      publicStartDiagnosticNullOk: true,
      publicStopDiagnosticNullOk: true,
      publicTakePhotoNullOk: true,
      publicStartRecordingFalseOk: true,
      publicStopRecordingNullOk: true,
      publicUpdateConfigNoThrowOk: true,
      physicalConcurrentCaptureProven: false,
      textureAllocated: false,
      cameraOpenedByMultiCamRoute: false,
      renderProven: false,
      photoCaptureProven: false,
      recordingExportProven: false,
      productUiWired: false,
      reasons: <String>['multicam_actions_fail_closed_routes_consistent_pass'],
      diagnostics: <String, Object?>{
        'proofBoundary': kAndroidMultiCamActionsFailClosedProofBoundary,
      },
    );

    test('toMap and fromMap roundtrip preserves all fields', () {
      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(
        map['proofBoundary'],
        equals(kAndroidMultiCamActionsFailClosedProofBoundary),
      );
      expect(map['physicalConcurrentCaptureProven'], isFalse);
      expect(map['textureAllocated'], isFalse);
      expect(map['cameraOpenedByMultiCamRoute'], isFalse);
      expect(map['renderProven'], isFalse);
      expect(map['photoCaptureProven'], isFalse);
      expect(map['recordingExportProven'], isFalse);
      expect(map['productUiWired'], isFalse);
      expect(map['reasons'], isA<List<String>>());
      expect(map['diagnostics'], isA<Map<String, Object?>>());

      final roundtripped =
          VGAndroidMultiCamActionsFailClosedSmokeReport.fromMap(map);
      expect(roundtripped, isNotNull);
      expect(roundtripped, equals(report));
      expect(roundtripped!.hashCode, equals(report.hashCode));
      expect(roundtripped.pass, isTrue);
    });

    test('fromMap returns null on non-map input', () {
      expect(
        VGAndroidMultiCamActionsFailClosedSmokeReport.fromMap(null),
        isNull,
      );
      expect(
        VGAndroidMultiCamActionsFailClosedSmokeReport.fromMap('not_a_map'),
        isNull,
      );
      expect(
        VGAndroidMultiCamActionsFailClosedSmokeReport.fromMap(123),
        isNull,
      );
    });

    test('toString includes key report fields', () {
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains(kAndroidMultiCamActionsFailClosedProofBoundary));
      expect(
        str,
        contains('directRunDiagnosticErrorCode: CONCURRENT_NOT_SUPPORTED'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Static MethodChannel Dispatch using Mocks -- Unsupported Hardware
  // ---------------------------------------------------------------------------
  group(
    'Mock channel: unsupported hardware fails closed with CONCURRENT_NOT_SUPPORTED',
    () {
      final log = <MethodCall>[];

      Future<Object?> handler(MethodCall call) async {
        log.add(call);
        final args = asArgs(call.arguments);
        switch (call.method) {
          case 'stopMultiCamPreview':
          case 'stopMultiCamRenderDiagnostic':
            return null;
          case 'runMultiCamRenderDiagnostic':
          case 'startMultiCamRenderDiagnostic':
            if (!hasNonBlank(args, 'frontDeviceId') ||
                !hasNonBlank(args, 'backDeviceId')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
          case 'updateMultiCamPreviewConfig':
            if (args?['config'] is! Map) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'takeMultiCamPhoto':
            if (!hasNonBlank(args, 'path')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'startMultiCamRecording':
            if (!hasNonBlank(args, 'path')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'stopMultiCamRecording':
            throw PlatformException(code: 'NOT_RUNNING');
        }
        return null;
      }

      setUp(() {
        log.clear();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, handler);
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test('runs all lanes and passes for unsupported hardware', () async {
        final report =
            await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

        expect(report.pass, isTrue);
        expect(report.directStopPreviewIdempotentOk, isTrue);
        expect(report.directStopRenderDiagnosticIdempotentOk, isTrue);
        expect(report.directRunDiagnosticInvalidArgOk, isTrue);
        expect(report.directStartDiagnosticInvalidArgOk, isTrue);
        expect(report.directRunDiagnosticFailClosedOk, isTrue);
        expect(
          report.directRunDiagnosticErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.directStartDiagnosticFailClosedOk, isTrue);
        expect(
          report.directStartDiagnosticErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.directUpdateConfigMissingInvalidArgOk, isTrue);
        expect(report.directUpdateConfigWithConfigNotRunningOk, isTrue);
        expect(report.directTakePhotoMissingInvalidArgOk, isTrue);
        expect(report.directTakePhotoValidPathNotRunningOk, isTrue);
        expect(report.directStartRecordingMissingInvalidArgOk, isTrue);
        expect(report.directStartRecordingValidPathNotRunningOk, isTrue);
        expect(report.directStopRecordingNotRunningOk, isTrue);
        expect(report.publicRunDiagnosticNullOk, isTrue);
        expect(report.publicStartDiagnosticNullOk, isTrue);
        expect(report.publicStopDiagnosticNullOk, isTrue);
        expect(report.publicTakePhotoNullOk, isTrue);
        expect(report.publicStartRecordingFalseOk, isTrue);
        expect(report.publicStopRecordingNullOk, isTrue);
        expect(report.publicUpdateConfigNoThrowOk, isTrue);
        expect(report.physicalConcurrentCaptureProven, isFalse);
        expect(report.textureAllocated, isFalse);
        expect(report.cameraOpenedByMultiCamRoute, isFalse);
        expect(report.renderProven, isFalse);
        expect(report.photoCaptureProven, isFalse);
        expect(report.recordingExportProven, isFalse);
        expect(report.productUiWired, isFalse);
        expect(
          report.reasons,
          contains('multicam_actions_fail_closed_routes_consistent_pass'),
        );

        expect(
          log
              .map((c) => c.method)
              .where((m) => m == 'stopMultiCamPreview')
              .length,
          1,
        );
      });
    },
  );

  // ---------------------------------------------------------------------------
  // 4. Static MethodChannel Dispatch using Mocks -- Supported, Not Ready
  // ---------------------------------------------------------------------------
  group(
    'Mock channel: supported hardware still fails closed with CONCURRENT_PREVIEW_NOT_READY',
    () {
      Future<Object?> handler(MethodCall call) async {
        final args = asArgs(call.arguments);
        switch (call.method) {
          case 'stopMultiCamPreview':
          case 'stopMultiCamRenderDiagnostic':
            return null;
          case 'runMultiCamRenderDiagnostic':
          case 'startMultiCamRenderDiagnostic':
            if (!hasNonBlank(args, 'frontDeviceId') ||
                !hasNonBlank(args, 'backDeviceId')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'CONCURRENT_PREVIEW_NOT_READY');
          case 'updateMultiCamPreviewConfig':
            if (args?['config'] is! Map) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'takeMultiCamPhoto':
            if (!hasNonBlank(args, 'path')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'startMultiCamRecording':
            if (!hasNonBlank(args, 'path')) {
              throw PlatformException(code: 'INVALID_ARG');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          case 'stopMultiCamRecording':
            throw PlatformException(code: 'NOT_RUNNING');
        }
        return null;
      }

      setUp(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, handler);
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test(
        'runs all lanes and passes for supported-but-not-ready hardware',
        () async {
          final report =
              await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

          expect(report.pass, isTrue);
          expect(report.directRunDiagnosticFailClosedOk, isTrue);
          expect(
            report.directRunDiagnosticErrorCode,
            equals('CONCURRENT_PREVIEW_NOT_READY'),
          );
          expect(report.directStartDiagnosticFailClosedOk, isTrue);
          expect(
            report.directStartDiagnosticErrorCode,
            equals('CONCURRENT_PREVIEW_NOT_READY'),
          );
          expect(report.physicalConcurrentCaptureProven, isFalse);
          expect(report.textureAllocated, isFalse);
          expect(report.cameraOpenedByMultiCamRoute, isFalse);
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // 5. FAIL Shapes -- broken/fake-success handlers must be caught
  // ---------------------------------------------------------------------------
  group('Mock channel: FAIL shapes', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'runMultiCamRenderDiagnostic returning fake success -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'runMultiCamRenderDiagnostic') {
                // Simulates a broken handler that fakes success instead of
                // failing closed -- the smoke must catch this.
                return <String, Object?>{'reportId': 'fake'};
              }
              if (call.method == 'stopMultiCamPreview' ||
                  call.method == 'stopMultiCamRenderDiagnostic') {
                return null;
              }
              throw PlatformException(code: 'NOT_RUNNING');
            });

        final report =
            await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directRunDiagnosticInvalidArgOk, isFalse);
        expect(report.directRunDiagnosticFailClosedOk, isFalse);
      },
    );

    test(
      'stopMultiCamRenderDiagnostic that throws is not idempotent -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'stopMultiCamPreview') return null;
              if (call.method == 'stopMultiCamRenderDiagnostic') {
                throw PlatformException(code: 'UNEXPECTED_STOP_FAILURE');
              }
              throw PlatformException(code: 'NOT_RUNNING');
            });

        final report =
            await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directStopRenderDiagnosticIdempotentOk, isFalse);
        expect(
          report.reasons.any(
            (r) => r.startsWith('direct_stop_render_diagnostic_not_idempotent'),
          ),
          isTrue,
        );
      },
    );

    test(
      'updateMultiCamPreviewConfig returning fake success -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'stopMultiCamPreview' ||
                  call.method == 'stopMultiCamRenderDiagnostic') {
                return null;
              }
              if (call.method == 'runMultiCamRenderDiagnostic' ||
                  call.method == 'startMultiCamRenderDiagnostic') {
                throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
              }
              if (call.method == 'updateMultiCamPreviewConfig') {
                // Broken handler: fakes success instead of NOT_RUNNING.
                return null;
              }
              throw PlatformException(code: 'NOT_RUNNING');
            });

        final report =
            await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directUpdateConfigWithConfigNotRunningOk, isFalse);
      },
    );

    test('takeMultiCamPhoto returning unrecognized code -> FAIL', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'stopMultiCamPreview' ||
                call.method == 'stopMultiCamRenderDiagnostic') {
              return null;
            }
            if (call.method == 'runMultiCamRenderDiagnostic' ||
                call.method == 'startMultiCamRenderDiagnostic') {
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            }
            if (call.method == 'takeMultiCamPhoto') {
              final args = call.arguments as Map?;
              final path = args?['path'] as String?;
              if (path == null || path.trim().isEmpty) {
                throw PlatformException(code: 'INVALID_ARG');
              }
              throw PlatformException(code: 'SOME_OTHER_CODE');
            }
            throw PlatformException(code: 'NOT_RUNNING');
          });

      final report = await VGAndroidMultiCamActionsFailClosedSmokeRunner.run();

      expect(report.pass, isFalse);
      expect(report.directTakePhotoValidPathNotRunningOk, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 6. Custom device ids via constructor
  // ---------------------------------------------------------------------------
  group('Custom frontDeviceId/backDeviceId', () {
    final observedValidIdPairs = <List<String?>>[];

    setUp(() {
      observedValidIdPairs.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            final args = asArgs(call.arguments);
            switch (call.method) {
              case 'stopMultiCamPreview':
              case 'stopMultiCamRenderDiagnostic':
                return null;
              case 'runMultiCamRenderDiagnostic':
              case 'startMultiCamRenderDiagnostic':
                if (!hasNonBlank(args, 'frontDeviceId') ||
                    !hasNonBlank(args, 'backDeviceId')) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                observedValidIdPairs.add([
                  args?['frontDeviceId'] as String?,
                  args?['backDeviceId'] as String?,
                ]);
                throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
              case 'updateMultiCamPreviewConfig':
                if (args?['config'] is! Map) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                throw PlatformException(code: 'NOT_RUNNING');
              case 'takeMultiCamPhoto':
                if (!hasNonBlank(args, 'path')) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                throw PlatformException(code: 'NOT_RUNNING');
              case 'startMultiCamRecording':
                if (!hasNonBlank(args, 'path')) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                throw PlatformException(code: 'NOT_RUNNING');
              case 'stopMultiCamRecording':
                throw PlatformException(code: 'NOT_RUNNING');
              default:
                throw PlatformException(code: 'NOT_RUNNING');
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'passes custom device ids through to both direct and public calls',
      () async {
        final report = await VGAndroidMultiCamActionsFailClosedSmokeRunner.run(
          runner: const VGAndroidMultiCamActionsFailClosedSmokeRunner(
            frontDeviceId: 'front-cam',
            backDeviceId: 'back-cam',
          ),
        );

        expect(report.pass, isTrue);
        expect(report.diagnostics['frontDeviceId'], equals('front-cam'));
        expect(report.diagnostics['backDeviceId'], equals('back-cam'));
        // Both the direct valid-args calls (run + start) and the public
        // wrapper calls (run + start) must have forwarded the exact custom
        // device ids, never a default/placeholder.
        expect(observedValidIdPairs.length, equals(4));
        for (final pair in observedValidIdPairs) {
          expect(pair, equals(<String?>['front-cam', 'back-cam']));
        }
      },
    );
  });
}
