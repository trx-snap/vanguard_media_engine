// vg_android_multicam_diagnostic_fail_closed_smoke_test.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-DIAGNOSTIC-FAIL-CLOSED-ANDROID-HANDLER:
// Android MultiCam legacy diagnostic routes fail-closed unit and smoke
// contract tests.

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

  const diagnosticMethods = <String>[
    'measureMultiCamHardwareCost',
    'runMultiCamStreamingDiagnostic',
    'runMultiCamSyncDiagnostic',
    'runMultiCamSourceLifecycleDiagnostic',
  ];

  // ---------------------------------------------------------------------------
  // 1. Constants and Proof Boundary Tokens
  // ---------------------------------------------------------------------------
  group('Android MultiCam diagnostic fail-closed constants and markers', () {
    test('proof boundary has exact required string value', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        equals(
          'android_multicam_diagnostic_fail_closed_route_handling_capability_gated_no_camera_open_no_stream_no_sync',
        ),
      );
    });

    test('start marker has exact required token', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedStartMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_START',
        ),
      );
    });

    test('pass marker has exact required token', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedPassMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_PASS',
        ),
      );
    });

    test('fail marker has exact required token', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedFailMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_PHYSICAL_SMOKE_FAIL',
        ),
      );
    });

    test('JSON prefix has exact required token', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedJsonPrefix,
        equals('ANDROID_DAG_PHASE3_MULTICAM_DIAGNOSTIC_FAIL_CLOSED_JSON:'),
      );
    });

    test('allowed error codes are exactly the two fail-closed codes', () {
      expect(
        kAndroidMultiCamDiagnosticFailClosedAllowedErrorCodes,
        equals(<String>[
          'CONCURRENT_NOT_SUPPORTED',
          'CONCURRENT_DIAGNOSTIC_NOT_READY',
        ]),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Report Serialization & Deserialization (toMap / fromMap)
  // ---------------------------------------------------------------------------
  group(
    'VGAndroidMultiCamDiagnosticFailClosedSmokeReport toMap and fromMap',
    () {
      const report = VGAndroidMultiCamDiagnosticFailClosedSmokeReport(
        pass: true,
        proofBoundary: kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        directMeasureCostInvalidArgOk: true,
        directMeasureCostFailClosedOk: true,
        directMeasureCostErrorCode: 'CONCURRENT_NOT_SUPPORTED',
        directStreamingDiagnosticInvalidArgOk: true,
        directStreamingDiagnosticFailClosedOk: true,
        directStreamingDiagnosticErrorCode: 'CONCURRENT_NOT_SUPPORTED',
        directSyncDiagnosticInvalidArgOk: true,
        directSyncDiagnosticFailClosedOk: true,
        directSyncDiagnosticErrorCode: 'CONCURRENT_NOT_SUPPORTED',
        directSourceLifecycleDiagnosticInvalidArgOk: true,
        directSourceLifecycleDiagnosticFailClosedOk: true,
        directSourceLifecycleDiagnosticErrorCode: 'CONCURRENT_NOT_SUPPORTED',
        publicMeasureCostNullOk: true,
        publicStreamingDiagnosticNullOk: true,
        publicSyncDiagnosticNullOk: true,
        publicSourceLifecycleDiagnosticNullOk: true,
        physicalConcurrentCaptureProven: false,
        hardwareCostMeasured: false,
        streamingFramesProven: false,
        syncProven: false,
        sourceLifecycleProven: false,
        cameraOpenedByDiagnosticRoute: false,
        textureAllocated: false,
        productUiWired: false,
        reasons: <String>[
          'multicam_diagnostic_fail_closed_routes_consistent_pass',
        ],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamDiagnosticFailClosedProofBoundary,
        },
      );

      test('toMap and fromMap roundtrip preserves all fields', () {
        final map = report.toMap();
        expect(map['pass'], isTrue);
        expect(
          map['proofBoundary'],
          equals(kAndroidMultiCamDiagnosticFailClosedProofBoundary),
        );
        expect(map['physicalConcurrentCaptureProven'], isFalse);
        expect(map['hardwareCostMeasured'], isFalse);
        expect(map['streamingFramesProven'], isFalse);
        expect(map['syncProven'], isFalse);
        expect(map['sourceLifecycleProven'], isFalse);
        expect(map['cameraOpenedByDiagnosticRoute'], isFalse);
        expect(map['textureAllocated'], isFalse);
        expect(map['productUiWired'], isFalse);
        expect(map['reasons'], isA<List<String>>());
        expect(map['diagnostics'], isA<Map<String, Object?>>());

        final roundtripped =
            VGAndroidMultiCamDiagnosticFailClosedSmokeReport.fromMap(map);
        expect(roundtripped, isNotNull);
        expect(roundtripped, equals(report));
        expect(roundtripped!.hashCode, equals(report.hashCode));
        expect(roundtripped.pass, isTrue);
      });

      test('fromMap returns null on non-map input', () {
        expect(
          VGAndroidMultiCamDiagnosticFailClosedSmokeReport.fromMap(null),
          isNull,
        );
        expect(
          VGAndroidMultiCamDiagnosticFailClosedSmokeReport.fromMap('not_a_map'),
          isNull,
        );
        expect(
          VGAndroidMultiCamDiagnosticFailClosedSmokeReport.fromMap(123),
          isNull,
        );
      });

      test('toString includes key report fields', () {
        final str = report.toString();
        expect(str, contains('pass: true'));
        expect(
          str,
          contains(kAndroidMultiCamDiagnosticFailClosedProofBoundary),
        );
        expect(
          str,
          contains('directMeasureCostErrorCode: CONCURRENT_NOT_SUPPORTED'),
        );
      });
    },
  );

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
        if (diagnosticMethods.contains(call.method)) {
          if (!hasNonBlank(args, 'frontDeviceId') ||
              !hasNonBlank(args, 'backDeviceId')) {
            throw PlatformException(code: 'INVALID_ARG');
          }
          throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
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
            await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();

        expect(report.pass, isTrue);
        expect(report.directMeasureCostInvalidArgOk, isTrue);
        expect(report.directMeasureCostFailClosedOk, isTrue);
        expect(
          report.directMeasureCostErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.directStreamingDiagnosticInvalidArgOk, isTrue);
        expect(report.directStreamingDiagnosticFailClosedOk, isTrue);
        expect(
          report.directStreamingDiagnosticErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.directSyncDiagnosticInvalidArgOk, isTrue);
        expect(report.directSyncDiagnosticFailClosedOk, isTrue);
        expect(
          report.directSyncDiagnosticErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.directSourceLifecycleDiagnosticInvalidArgOk, isTrue);
        expect(report.directSourceLifecycleDiagnosticFailClosedOk, isTrue);
        expect(
          report.directSourceLifecycleDiagnosticErrorCode,
          equals('CONCURRENT_NOT_SUPPORTED'),
        );
        expect(report.publicMeasureCostNullOk, isTrue);
        expect(report.publicStreamingDiagnosticNullOk, isTrue);
        expect(report.publicSyncDiagnosticNullOk, isTrue);
        expect(report.publicSourceLifecycleDiagnosticNullOk, isTrue);
        expect(report.physicalConcurrentCaptureProven, isFalse);
        expect(report.hardwareCostMeasured, isFalse);
        expect(report.streamingFramesProven, isFalse);
        expect(report.syncProven, isFalse);
        expect(report.sourceLifecycleProven, isFalse);
        expect(report.cameraOpenedByDiagnosticRoute, isFalse);
        expect(report.textureAllocated, isFalse);
        expect(report.productUiWired, isFalse);
        expect(
          report.reasons,
          contains('multicam_diagnostic_fail_closed_routes_consistent_pass'),
        );

        // Exactly 3 calls: direct missing-arg lane, direct valid fail-closed lane,
        // and public VGCameraSession wrapper lane.
        expect(
          log
              .map((c) => c.method)
              .where((m) => m == 'measureMultiCamHardwareCost')
              .length,
          3,
        );
      });
    },
  );

  // ---------------------------------------------------------------------------
  // 4. Static MethodChannel Dispatch using Mocks -- Supported, Not Ready
  // ---------------------------------------------------------------------------
  group(
    'Mock channel: supported hardware still fails closed with CONCURRENT_DIAGNOSTIC_NOT_READY',
    () {
      Future<Object?> handler(MethodCall call) async {
        final args = asArgs(call.arguments);
        if (diagnosticMethods.contains(call.method)) {
          if (!hasNonBlank(args, 'frontDeviceId') ||
              !hasNonBlank(args, 'backDeviceId')) {
            throw PlatformException(code: 'INVALID_ARG');
          }
          throw PlatformException(code: 'CONCURRENT_DIAGNOSTIC_NOT_READY');
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
              await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();

          expect(report.pass, isTrue);
          expect(report.directMeasureCostFailClosedOk, isTrue);
          expect(
            report.directMeasureCostErrorCode,
            equals('CONCURRENT_DIAGNOSTIC_NOT_READY'),
          );
          expect(report.directStreamingDiagnosticFailClosedOk, isTrue);
          expect(
            report.directStreamingDiagnosticErrorCode,
            equals('CONCURRENT_DIAGNOSTIC_NOT_READY'),
          );
          expect(report.directSyncDiagnosticFailClosedOk, isTrue);
          expect(
            report.directSyncDiagnosticErrorCode,
            equals('CONCURRENT_DIAGNOSTIC_NOT_READY'),
          );
          expect(report.directSourceLifecycleDiagnosticFailClosedOk, isTrue);
          expect(
            report.directSourceLifecycleDiagnosticErrorCode,
            equals('CONCURRENT_DIAGNOSTIC_NOT_READY'),
          );
          expect(report.physicalConcurrentCaptureProven, isFalse);
          expect(report.hardwareCostMeasured, isFalse);
          expect(report.streamingFramesProven, isFalse);
          expect(report.syncProven, isFalse);
          expect(report.sourceLifecycleProven, isFalse);
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // 5. FAIL Shapes -- broken/fake-success and unrecognized-code handlers
  // ---------------------------------------------------------------------------
  group('Mock channel: FAIL shapes', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'measureMultiCamHardwareCost returning fake success -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'measureMultiCamHardwareCost') {
                // Simulates a broken handler that fakes success instead of
                // failing closed -- the smoke must catch this.
                return <String, Object?>{'systemPressureCost': 0.1};
              }
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            });

        final report =
            await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directMeasureCostInvalidArgOk, isFalse);
        expect(report.directMeasureCostFailClosedOk, isFalse);
      },
    );

    test(
      'runMultiCamStreamingDiagnostic returning unrecognized code -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'runMultiCamStreamingDiagnostic') {
                final args = call.arguments as Map?;
                final front = args?['frontDeviceId'] as String?;
                final back = args?['backDeviceId'] as String?;
                if (front == null ||
                    front.trim().isEmpty ||
                    back == null ||
                    back.trim().isEmpty) {
                  throw PlatformException(code: 'INVALID_ARG');
                }
                throw PlatformException(code: 'SOME_OTHER_CODE');
              }
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            });

        final report =
            await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directStreamingDiagnosticFailClosedOk, isFalse);
        expect(
          report.reasons.any(
            (r) =>
                r.startsWith('direct_streaming_diagnostic_did_not_fail_closed'),
          ),
          isTrue,
        );
      },
    );

    test(
      'runMultiCamSourceLifecycleDiagnostic missing INVALID_ARG rejection -> FAIL',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'runMultiCamSourceLifecycleDiagnostic') {
                // Broken handler: never rejects missing args with
                // INVALID_ARG, always fails closed instead.
                throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
              }
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            });

        final report =
            await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run();

        expect(report.pass, isFalse);
        expect(report.directSourceLifecycleDiagnosticInvalidArgOk, isFalse);
      },
    );
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
            if (diagnosticMethods.contains(call.method)) {
              if (!hasNonBlank(args, 'frontDeviceId') ||
                  !hasNonBlank(args, 'backDeviceId')) {
                throw PlatformException(code: 'INVALID_ARG');
              }
              observedValidIdPairs.add([
                args?['frontDeviceId'] as String?,
                args?['backDeviceId'] as String?,
              ]);
              throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
            }
            throw PlatformException(code: 'CONCURRENT_NOT_SUPPORTED');
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'passes custom device ids through to both direct and public calls',
      () async {
        final report =
            await VGAndroidMultiCamDiagnosticFailClosedSmokeRunner.run(
              runner: const VGAndroidMultiCamDiagnosticFailClosedSmokeRunner(
                frontDeviceId: 'front-cam',
                backDeviceId: 'back-cam',
              ),
            );

        expect(report.pass, isTrue);
        expect(report.diagnostics['frontDeviceId'], equals('front-cam'));
        expect(report.diagnostics['backDeviceId'], equals('back-cam'));
        // Both the direct valid-args calls (4 routes) and the public
        // wrapper calls (4 routes) must have forwarded the exact custom
        // device ids, never a default/placeholder.
        expect(observedValidIdPairs.length, equals(8));
        for (final pair in observedValidIdPairs) {
          expect(pair, equals(<String?>['front-cam', 'back-cam']));
        }
      },
    );
  });
}
