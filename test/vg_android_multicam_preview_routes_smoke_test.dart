// vg_android_multicam_preview_routes_smoke_test.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER:
// Android startMultiCamPreview/stopMultiCamPreview fail-closed route unit and
// smoke contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 1. Constants and Proof Boundary Tokens
  // ---------------------------------------------------------------------------
  group('Android MultiCam preview fail-closed routes constants and markers', () {
    test('proof boundary has exact required string value', () {
      expect(
        kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        equals(
          'android_multicam_preview_fail_closed_route_handling_capability_gated_no_camera_open_no_texture_no_capture',
        ),
      );
    });

    test('start marker has exact required token', () {
      expect(
        kAndroidMultiCamPreviewRoutesFailClosedStartMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_START',
        ),
      );
    });

    test('pass marker has exact required token', () {
      expect(
        kAndroidMultiCamPreviewRoutesFailClosedPassMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_PASS',
        ),
      );
    });

    test('fail marker has exact required token', () {
      expect(
        kAndroidMultiCamPreviewRoutesFailClosedFailMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_PHYSICAL_SMOKE_FAIL',
        ),
      );
    });

    test('JSON prefix has exact required token', () {
      expect(
        kAndroidMultiCamPreviewRoutesFailClosedJsonPrefix,
        equals('ANDROID_DAG_PHASE3_MULTICAM_PREVIEW_FAIL_CLOSED_ROUTES_JSON:'),
      );
    });

    test('allowed start error codes are exactly the two fail-closed codes', () {
      expect(
        kAndroidMultiCamPreviewFailClosedAllowedStartErrorCodes,
        equals(<String>[
          'CONCURRENT_NOT_SUPPORTED',
          'CONCURRENT_PREVIEW_NOT_READY',
        ]),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Report Serialization & Deserialization (toMap / fromMap)
  // ---------------------------------------------------------------------------
  group('VGAndroidMultiCamPreviewRoutesSmokeReport toMap and fromMap', () {
    test('toMap and fromMap roundtrip preserves all fields', () {
      const report = VGAndroidMultiCamPreviewRoutesSmokeReport(
        pass: true,
        proofBoundary: kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        directStopIdempotentOk: true,
        directInvalidArgOk: true,
        directStartFailClosedOk: true,
        directStartErrorCode: 'CONCURRENT_NOT_SUPPORTED',
        publicStartNullOk: true,
        publicStopNullOk: true,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: <String>[
          'multicam_preview_fail_closed_routes_consistent_pass',
        ],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
          'directStartErrorCode': 'CONCURRENT_NOT_SUPPORTED',
        },
      );

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(
        map['proofBoundary'],
        equals(kAndroidMultiCamPreviewRoutesFailClosedProofBoundary),
      );
      expect(map['directStopIdempotentOk'], isTrue);
      expect(map['directInvalidArgOk'], isTrue);
      expect(map['directStartFailClosedOk'], isTrue);
      expect(map['directStartErrorCode'], equals('CONCURRENT_NOT_SUPPORTED'));
      expect(map['publicStartNullOk'], isTrue);
      expect(map['publicStopNullOk'], isTrue);
      expect(map['physicalConcurrentCaptureProven'], isFalse);
      expect(map['textureAllocated'], isFalse);
      expect(map['cameraOpenedByMultiCamRoute'], isFalse);
      expect(map['renderProven'], isFalse);
      expect(map['recordingExportProven'], isFalse);
      expect(map['productUiWired'], isFalse);
      expect(map['reasons'], isA<List<String>>());
      expect(map['diagnostics'], isA<Map<String, Object?>>());

      final roundtripped = VGAndroidMultiCamPreviewRoutesSmokeReport.fromMap(
        map,
      );
      expect(roundtripped, isNotNull);
      expect(roundtripped, equals(report));
      expect(roundtripped!.hashCode, equals(report.hashCode));
      expect(roundtripped.pass, isTrue);
    });

    test('fromMap returns null on non-map input', () {
      expect(VGAndroidMultiCamPreviewRoutesSmokeReport.fromMap(null), isNull);
      expect(
        VGAndroidMultiCamPreviewRoutesSmokeReport.fromMap('not_a_map'),
        isNull,
      );
      expect(VGAndroidMultiCamPreviewRoutesSmokeReport.fromMap(123), isNull);
    });

    test('toString includes key report fields', () {
      const report = VGAndroidMultiCamPreviewRoutesSmokeReport(
        pass: false,
        proofBoundary: kAndroidMultiCamPreviewRoutesFailClosedProofBoundary,
        directStopIdempotentOk: true,
        directInvalidArgOk: false,
        directStartFailClosedOk: true,
        directStartErrorCode: 'CONCURRENT_PREVIEW_NOT_READY',
        publicStartNullOk: true,
        publicStopNullOk: true,
        physicalConcurrentCaptureProven: false,
        textureAllocated: false,
        cameraOpenedByMultiCamRoute: false,
        renderProven: false,
        recordingExportProven: false,
        productUiWired: false,
        reasons: <String>['direct_start_invalid_arg_not_rejected: code=null'],
        diagnostics: <String, Object?>{},
      );

      final str = report.toString();
      expect(str, contains('pass: false'));
      expect(
        str,
        contains(kAndroidMultiCamPreviewRoutesFailClosedProofBoundary),
      );
      expect(str, contains('directInvalidArgOk: false'));
      expect(
        str,
        contains('directStartErrorCode: CONCURRENT_PREVIEW_NOT_READY'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Static MethodChannel Dispatch using Mocks -- Unsupported Hardware
  // ---------------------------------------------------------------------------
  group(
    'Mock channel: unsupported hardware fails closed with CONCURRENT_NOT_SUPPORTED',
    () {
      const channel = MethodChannel('vanguard_media_engine');
      final log = <MethodCall>[];

      Map<String, Object?>? asArgs(Object? raw) {
        if (raw is Map) return Map<String, Object?>.from(raw);
        return null;
      }

      setUp(() {
        log.clear();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              log.add(call);
              if (call.method == 'stopMultiCamPreview') {
                return null;
              }
              if (call.method == 'startMultiCamPreview') {
                final args = asArgs(call.arguments);
                final front = args?['frontDeviceId'] as String?;
                final back = args?['backDeviceId'] as String?;
                if (front == null ||
                    front.trim().isEmpty ||
                    back == null ||
                    back.trim().isEmpty) {
                  throw PlatformException(
                    code: 'INVALID_ARG',
                    message: 'startMultiCamPreview requires device ids',
                  );
                }
                throw PlatformException(
                  code: 'CONCURRENT_NOT_SUPPORTED',
                  message:
                      'No concurrent camera combination supports these ids',
                );
              }
              return null;
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test('runs all lanes and passes for unsupported hardware', () async {
        final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();

        expect(report.pass, isTrue);
        expect(report.directStopIdempotentOk, isTrue);
        expect(report.directInvalidArgOk, isTrue);
        expect(report.directStartFailClosedOk, isTrue);
        expect(report.directStartErrorCode, equals('CONCURRENT_NOT_SUPPORTED'));
        expect(report.publicStartNullOk, isTrue);
        expect(report.publicStopNullOk, isTrue);
        expect(report.physicalConcurrentCaptureProven, isFalse);
        expect(report.textureAllocated, isFalse);
        expect(report.cameraOpenedByMultiCamRoute, isFalse);
        expect(report.renderProven, isFalse);
        expect(report.recordingExportProven, isFalse);
        expect(report.productUiWired, isFalse);
        expect(
          report.reasons,
          contains('multicam_preview_fail_closed_routes_consistent_pass'),
        );

        final calledMethods = log.map((c) => c.method).toList();
        expect(
          calledMethods.where((m) => m == 'stopMultiCamPreview').length,
          2,
        );
        expect(
          calledMethods.where((m) => m == 'startMultiCamPreview').length,
          3,
        );
      });
    },
  );

  // ---------------------------------------------------------------------------
  // 4. Static MethodChannel Dispatch using Mocks -- Supported Hardware, Not Ready
  // ---------------------------------------------------------------------------
  group(
    'Mock channel: supported hardware still fails closed with CONCURRENT_PREVIEW_NOT_READY',
    () {
      const channel = MethodChannel('vanguard_media_engine');

      Map<String, Object?>? asArgs(Object? raw) {
        if (raw is Map) return Map<String, Object?>.from(raw);
        return null;
      }

      setUp(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'stopMultiCamPreview') {
                return null;
              }
              if (call.method == 'startMultiCamPreview') {
                final args = asArgs(call.arguments);
                final front = args?['frontDeviceId'] as String?;
                final back = args?['backDeviceId'] as String?;
                if (front == null ||
                    front.trim().isEmpty ||
                    back == null ||
                    back.trim().isEmpty) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                // Hardware reports a matching concurrent combo, but there is no
                // production concurrent-preview lifecycle owner -- must still
                // fail closed, never return a fake texture/session.
                throw PlatformException(code: 'CONCURRENT_PREVIEW_NOT_READY');
              }
              return null;
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test(
        'runs all lanes and passes for supported-but-not-ready hardware',
        () async {
          final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();

          expect(report.pass, isTrue);
          expect(report.directStartFailClosedOk, isTrue);
          expect(
            report.directStartErrorCode,
            equals('CONCURRENT_PREVIEW_NOT_READY'),
          );
          expect(report.publicStartNullOk, isTrue);
          expect(report.publicStopNullOk, isTrue);
          expect(report.physicalConcurrentCaptureProven, isFalse);
          expect(report.textureAllocated, isFalse);
          expect(report.cameraOpenedByMultiCamRoute, isFalse);
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // 5. FAIL Shapes
  // ---------------------------------------------------------------------------
  group('Mock channel: FAIL shapes', () {
    const channel = MethodChannel('vanguard_media_engine');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('start returning fake success (no error) -> FAIL', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'stopMultiCamPreview') return null;
            if (call.method == 'startMultiCamPreview') {
              // Simulates a broken handler that fakes success instead of
              // failing closed -- the smoke must catch this.
              return <String, Object?>{'textureId': 42};
            }
            return null;
          });

      final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();

      expect(report.pass, isFalse);
      expect(report.directInvalidArgOk, isFalse);
      expect(report.directStartFailClosedOk, isFalse);
      // The public API only returns null on PlatformException, so a fake
      // success surfaces as a non-null public result -- not proven "ok".
      expect(report.publicStartNullOk, isFalse);
    });

    test('stop that throws is not idempotent -> FAIL', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'stopMultiCamPreview') {
              throw PlatformException(code: 'UNEXPECTED_STOP_FAILURE');
            }
            if (call.method == 'startMultiCamPreview') {
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            }
            return null;
          });

      final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();

      expect(report.pass, isFalse);
      expect(report.directStopIdempotentOk, isFalse);
      expect(
        report.reasons.any((r) => r.startsWith('direct_stop_not_idempotent')),
        isTrue,
      );
    });

    test('unrecognized start error code -> FAIL', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'stopMultiCamPreview') return null;
            if (call.method == 'startMultiCamPreview') {
              final args = call.arguments as Map?;
              final front = args?['frontDeviceId'] as String?;
              if (front == null || front.trim().isEmpty) {
                throw PlatformException(code: 'INVALID_ARG');
              }
              throw PlatformException(code: 'SOME_OTHER_CODE');
            }
            return null;
          });

      final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run();

      expect(report.pass, isFalse);
      expect(report.directStartFailClosedOk, isFalse);
      expect(report.directStartErrorCode, equals('SOME_OTHER_CODE'));
    });
  });

  // ---------------------------------------------------------------------------
  // 6. Custom device ids via constructor
  // ---------------------------------------------------------------------------
  group('Custom frontDeviceId/backDeviceId', () {
    const channel = MethodChannel('vanguard_media_engine');
    final log = <MethodCall>[];
    final observedValidIdPairs = <List<String?>>[];

    setUp(() {
      log.clear();
      observedValidIdPairs.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            log.add(call);
            if (call.method == 'stopMultiCamPreview') return null;
            if (call.method == 'startMultiCamPreview') {
              final args = call.arguments as Map?;
              final front = args?['frontDeviceId'] as String?;
              final back = args?['backDeviceId'] as String?;
              if (front == null ||
                  front.trim().isEmpty ||
                  back == null ||
                  back.trim().isEmpty) {
                throw PlatformException(code: 'INVALID_ARG');
              }
              observedValidIdPairs.add([front, back]);
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'passes custom device ids through to both direct and public calls',
      () async {
        final report = await VGAndroidMultiCamPreviewRoutesSmokeRunner.run(
          runner: const VGAndroidMultiCamPreviewRoutesSmokeRunner(
            frontDeviceId: 'front-cam',
            backDeviceId: 'back-cam',
          ),
        );

        expect(report.pass, isTrue);
        expect(report.diagnostics['frontDeviceId'], equals('front-cam'));
        expect(report.diagnostics['backDeviceId'], equals('back-cam'));
        // Both the direct valid-args call and the public start call must have
        // forwarded the exact custom device ids, never a default/placeholder.
        expect(observedValidIdPairs.length, equals(2));
        for (final pair in observedValidIdPairs) {
          expect(pair, equals(<String?>['front-cam', 'back-cam']));
        }
      },
    );
  });
}
