// vg_camera2_concurrent_ingest_smoke_test.dart
// vanguard_media_engine — P3-CAM-CONCURRENT: Android Camera2 dual-camera
// concurrent PRIVATE AHardwareBuffer ingest smoke foundation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'decision': 'ingested',
  'reasons': const <String>[],
  'apiLevel': 34,
  'hasCameraPermission': true,
  'selectedCameraIds': const ['0', '1'],
  'openedCameraCount': 2,
  'configuredSessionCount': 2,
  'capturedFrameCount': 2,
  'nativeIngestPassCount': 2,
  'syncFenceAwaitedCount': 2,
  'syncFenceClosedCount': 2,
  'nativeCreateRaw': 'status=PASS;sessionId=test-session-123',
  'nativeDestroyRaw': 'status=PASS;sessionId=test-session-123',
  'events': const [
    'isConcurrentSessionConfigurationSupported:true',
    'nativeCreate:status=PASS;sessionId=test-session-123',
    'openCameraRequested:0',
    'openCameraRequested:1',
    'onOpened:0',
    'onOpened:1',
    'createCaptureSessionRequested:0',
    'createCaptureSessionRequested:1',
    'onConfigured:0',
    'onConfigured:1',
    'repeatingRequestStarted:0',
    'repeatingRequestStarted:1',
    'onImageAvailable:0',
    'onImageAvailable:1',
    'nativeIngest:0:status=PASS',
    'nativeIngest:1:status=PASS',
    'nativeDestroy:status=PASS;sessionId=test-session-123',
  ],
  'diagnostics': const {'testKey': 'testVal'},
  'proofBoundary':
      'android_camera2_dual_camera_concurrent_private_ahardwarebuffer_ingest_validation_'
      'no_pip_no_split_no_compositor_no_recording_no_export',
  'durationMs': 450,
  if (overrides != null) ...overrides,
};

VGCamera2ConcurrentIngestSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGCamera2ConcurrentIngestSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGCamera2ConcurrentIngestSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 15 values in order', () {
      expect(
        VGCamera2ConcurrentIngestSmokeDecision.values,
        orderedEquals(const [
          VGCamera2ConcurrentIngestSmokeDecision.ingested,
          VGCamera2ConcurrentIngestSmokeDecision.unsupportedApi,
          VGCamera2ConcurrentIngestSmokeDecision.permissionRequired,
          VGCamera2ConcurrentIngestSmokeDecision.cameraManagerUnavailable,
          VGCamera2ConcurrentIngestSmokeDecision.concurrentNotSupported,
          VGCamera2ConcurrentIngestSmokeDecision.unsupportedStream,
          VGCamera2ConcurrentIngestSmokeDecision.openDisconnected,
          VGCamera2ConcurrentIngestSmokeDecision.openError,
          VGCamera2ConcurrentIngestSmokeDecision.openTimeout,
          VGCamera2ConcurrentIngestSmokeDecision.sessionConfigurationRejected,
          VGCamera2ConcurrentIngestSmokeDecision.configureTimeout,
          VGCamera2ConcurrentIngestSmokeDecision.frameTimeout,
          VGCamera2ConcurrentIngestSmokeDecision.nativeIngestFailed,
          VGCamera2ConcurrentIngestSmokeDecision.destroyFailed,
          VGCamera2ConcurrentIngestSmokeDecision.harnessException,
        ]),
      );
      expect(VGCamera2ConcurrentIngestSmokeDecision.values.length, equals(15));
    });

    test('fromRaw maps all known valid decision strings', () {
      for (final value in VGCamera2ConcurrentIngestSmokeDecision.values) {
        expect(
          VGCamera2ConcurrentIngestSmokeDecision.fromRaw(value.name),
          equals(value),
        );
      }
    });

    test(
      'fromRaw falls back to harnessException for unknown, non-string, or null values',
      () {
        const invalidValues = <Object?>[
          'unknownDecision',
          '',
          null,
          123,
          3.14,
          true,
          <String>[],
          <String, Object?>{},
        ];
        for (final invalid in invalidValues) {
          expect(
            VGCamera2ConcurrentIngestSmokeDecision.fromRaw(invalid),
            equals(VGCamera2ConcurrentIngestSmokeDecision.harnessException),
          );
        }
      },
    );
  });

  group('VGCamera2ConcurrentIngestSmokeReport fromMap and toMap', () {
    test('pass report parses and round-trips all fields cleanly', () {
      final report = VGCamera2ConcurrentIngestSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(
        report.decision,
        equals(VGCamera2ConcurrentIngestSmokeDecision.ingested),
      );
      expect(report.reasons, isEmpty);
      expect(report.apiLevel, equals(34));
      expect(report.hasCameraPermission, isTrue);
      expect(report.selectedCameraIds, equals(['0', '1']));
      expect(report.openedCameraCount, equals(2));
      expect(report.configuredSessionCount, equals(2));
      expect(report.capturedFrameCount, equals(2));
      expect(report.nativeIngestPassCount, equals(2));
      expect(report.syncFenceAwaitedCount, equals(2));
      expect(report.syncFenceClosedCount, equals(2));
      expect(
        report.nativeCreateRaw,
        equals('status=PASS;sessionId=test-session-123'),
      );
      expect(
        report.nativeDestroyRaw,
        equals('status=PASS;sessionId=test-session-123'),
      );
      expect(report.events.length, equals(17));
      expect(report.diagnostics, equals({'testKey': 'testVal'}));
      expect(
        report.proofBoundary,
        equals(
          'android_camera2_dual_camera_concurrent_private_ahardwarebuffer_ingest_validation_'
          'no_pip_no_split_no_compositor_no_recording_no_export',
        ),
      );
      expect(report.durationMs, equals(450));

      expect(report.isPermissionRequired, isFalse);
      expect(report.isConcurrentUnsupported, isFalse);
      expect(report.isIngested, isTrue);
      expect(report.hasTwoCameraProof, isTrue);
      expect(report.hasNativeProof, isTrue);
      expect(report.hasApi33FenceProof, isTrue);

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], equals('ingested'));
      expect(serialized['apiLevel'], equals(34));
      expect(serialized['hasCameraPermission'], isTrue);
      expect(serialized['selectedCameraIds'], equals(['0', '1']));
      expect(serialized['openedCameraCount'], equals(2));
      expect(serialized['configuredSessionCount'], equals(2));
      expect(serialized['capturedFrameCount'], equals(2));
      expect(serialized['nativeIngestPassCount'], equals(2));
      expect(serialized['syncFenceAwaitedCount'], equals(2));
      expect(serialized['syncFenceClosedCount'], equals(2));
      expect(
        serialized['nativeCreateRaw'],
        equals('status=PASS;sessionId=test-session-123'),
      );
      expect(
        serialized['nativeDestroyRaw'],
        equals('status=PASS;sessionId=test-session-123'),
      );
      expect(serialized['events'], equals(report.events));
      expect(serialized['diagnostics'], equals(report.diagnostics));
      expect(serialized['proofBoundary'], equals(report.proofBoundary));
      expect(serialized['durationMs'], equals(450));

      final roundTrip = VGCamera2ConcurrentIngestSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
    });

    test('lifecycle failure decisions parse coherently', () {
      void check(
        VGCamera2ConcurrentIngestSmokeDecision d,
        List<String> r, {
        Map<String, Object?> ov = const {},
      }) {
        final report = VGCamera2ConcurrentIngestSmokeReport.fromMap(
          _createSampleRawMap({
            'pass': false,
            'decision': d.name,
            'reasons': r,
            ...ov,
          }),
        );
        expect(report.pass, isFalse);
        expect(report.decision, equals(d));
        expect(report.reasons, equals(r));
      }

      check(
        VGCamera2ConcurrentIngestSmokeDecision.unsupportedApi,
        const ['api_below_30'],
        ov: const {'apiLevel': 28},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.permissionRequired,
        const ['camera_permission_absent'],
        ov: const {'hasCameraPermission': false},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.cameraManagerUnavailable,
        const ['camera_manager_unavailable'],
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.concurrentNotSupported,
        const ['no_concurrent_camera_combination'],
      );
      check(VGCamera2ConcurrentIngestSmokeDecision.unsupportedStream, const [
        'no_private_output_sizes:0',
      ]);
      check(
        VGCamera2ConcurrentIngestSmokeDecision.openDisconnected,
        const ['camera_disconnected:0'],
        ov: const {'openedCameraCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.openError,
        const ['camera_open_error:0'],
        ov: const {
          'openedCameraCount': 0,
          'diagnostics': {'errorCode:0': 3},
        },
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.openTimeout,
        const ['camera_open_timeout'],
        ov: const {'openedCameraCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.sessionConfigurationRejected,
        const ['session_configure_failed:0'],
        ov: const {'configuredSessionCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.configureTimeout,
        const ['session_configure_timeout'],
        ov: const {'configuredSessionCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.frameTimeout,
        const ['frame_timeout'],
        ov: const {'capturedFrameCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.nativeIngestFailed,
        const ['native_ingest_failed:1'],
        ov: const {'nativeIngestPassCount': 1},
      );
      check(
        VGCamera2ConcurrentIngestSmokeDecision.destroyFailed,
        const ['native_destroy_failed'],
        ov: const {'nativeDestroyRaw': 'status=FAIL;reason=destroy_error'},
      );
      check(VGCamera2ConcurrentIngestSmokeDecision.harnessException, const [
        'exception:IllegalStateException:failed',
      ]);
    });

    test(
      'fromMap handles malformed non-map inputs by preserving raw in diagnostics and using reason native_result_not_a_map',
      () {
        for (final invalid in [
          null,
          'not_a_map',
          999,
          <Object?>['a', 'b'],
        ]) {
          final report = VGCamera2ConcurrentIngestSmokeReport.fromMap(invalid);
          expect(report.pass, isFalse);
          expect(
            report.decision,
            equals(VGCamera2ConcurrentIngestSmokeDecision.harnessException),
          );
          expect(
            report.reasons,
            equals(const <String>['native_result_not_a_map']),
          );
          expect(report.apiLevel, equals(0));
          expect(report.hasCameraPermission, isFalse);
          expect(report.selectedCameraIds, isEmpty);
          expect(report.openedCameraCount, equals(0));
          expect(report.configuredSessionCount, equals(0));
          expect(report.capturedFrameCount, equals(0));
          expect(report.nativeIngestPassCount, equals(0));
          expect(report.syncFenceAwaitedCount, equals(0));
          expect(report.syncFenceClosedCount, equals(0));
          expect(report.nativeCreateRaw, equals('status=FAIL;reason=not_run'));
          expect(report.nativeDestroyRaw, equals('status=FAIL;reason=not_run'));
          expect(report.events, isEmpty);
          expect(report.diagnostics, equals(<String, Object?>{'raw': invalid}));
          expect(report.proofBoundary, isEmpty);
          expect(report.durationMs, equals(0));
        }
      },
    );

    test(
      'fromMap handles missing/malformed list/map fields defensively producing safe defaults',
      () {
        final report = VGCamera2ConcurrentIngestSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(
          report,
          equals(
            const VGCamera2ConcurrentIngestSmokeReport(
              pass: false,
              decision: VGCamera2ConcurrentIngestSmokeDecision.harnessException,
              reasons: [],
              apiLevel: 0,
              hasCameraPermission: false,
              selectedCameraIds: [],
              openedCameraCount: 0,
              configuredSessionCount: 0,
              capturedFrameCount: 0,
              nativeIngestPassCount: 0,
              syncFenceAwaitedCount: 0,
              syncFenceClosedCount: 0,
              nativeCreateRaw: 'status=FAIL;reason=not_run',
              nativeDestroyRaw: 'status=FAIL;reason=not_run',
              events: [],
              diagnostics: {},
              proofBoundary: '',
              durationMs: 0,
            ),
          ),
        );

        final parsed = VGCamera2ConcurrentIngestSmokeReport.fromMap({
          'pass': true,
          'decision': 'ingested',
          'apiLevel': 34.0,
          'openedCameraCount': 2.0,
          'configuredSessionCount': 2.0,
          'capturedFrameCount': 2.0,
          'nativeIngestPassCount': 2.0,
          'syncFenceAwaitedCount': 2.0,
          'syncFenceClosedCount': 2.0,
          'durationMs': 300.0,
          'reasons': <Object?>['r1', 123, null],
          'selectedCameraIds': <Object?>['0', 1],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        });
        expect(parsed.pass, isTrue);
        expect(parsed.apiLevel, equals(34));
        expect(parsed.openedCameraCount, equals(2));
        expect(parsed.configuredSessionCount, equals(2));
        expect(parsed.capturedFrameCount, equals(2));
        expect(parsed.nativeIngestPassCount, equals(2));
        expect(parsed.syncFenceAwaitedCount, equals(2));
        expect(parsed.syncFenceClosedCount, equals(2));
        expect(parsed.durationMs, equals(300));
        expect(parsed.reasons, equals(['r1', '123']));
        expect(parsed.selectedCameraIds, equals(['0', '1']));
        expect(parsed.events, equals(['e1', '456']));
        expect(parsed.diagnostics, equals({'nested': 'ok'}));

        final parsedBad =
            VGCamera2ConcurrentIngestSmokeReport.fromMap(<Object?, Object?>{
              'reasons': 'not_a_list',
              'selectedCameraIds': 123,
              'events': 'not_events',
              'diagnostics': 'not_a_map',
            });
        expect(parsedBad.reasons, isEmpty);
        expect(parsedBad.selectedCameraIds, isEmpty);
        expect(parsedBad.events, isEmpty);
        expect(parsedBad.diagnostics, isEmpty);
      },
    );
  });

  group('VGCamera2ConcurrentIngestSmokeReport helper getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'permissionRequired',
        }).isPermissionRequired,
        isTrue,
      );
      expect(
        _createSampleReport({'decision': 'ingested'}).isPermissionRequired,
        isFalse,
      );
    });

    test('isConcurrentUnsupported reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'concurrentNotSupported',
        }).isConcurrentUnsupported,
        isTrue,
      );
      expect(
        _createSampleReport({'decision': 'ingested'}).isConcurrentUnsupported,
        isFalse,
      );
    });

    test('isIngested reflects decision strictly', () {
      expect(_createSampleReport({'decision': 'ingested'}).isIngested, isTrue);
      expect(
        _createSampleReport({'decision': 'openError'}).isIngested,
        isFalse,
      );
    });

    test('hasTwoCameraProof requires all 4 dual camera criteria >= 2', () {
      expect(_createSampleReport().hasTwoCameraProof, isTrue);

      expect(
        _createSampleReport({
          'selectedCameraIds': ['0'],
        }).hasTwoCameraProof,
        isFalse,
      );
      expect(
        _createSampleReport({'openedCameraCount': 1}).hasTwoCameraProof,
        isFalse,
      );
      expect(
        _createSampleReport({'configuredSessionCount': 1}).hasTwoCameraProof,
        isFalse,
      );
      expect(
        _createSampleReport({'capturedFrameCount': 1}).hasTwoCameraProof,
        isFalse,
      );
    });

    test(
      'hasNativeProof requires nativeIngestPassCount >= 2 and pass status on create and destroy',
      () {
        expect(_createSampleReport().hasNativeProof, isTrue);

        expect(
          _createSampleReport({'nativeIngestPassCount': 1}).hasNativeProof,
          isFalse,
        );
        expect(
          _createSampleReport({
            'nativeCreateRaw': 'status=FAIL;reason=admission_failed',
          }).hasNativeProof,
          isFalse,
        );
        expect(
          _createSampleReport({
            'nativeDestroyRaw': 'status=FAIL;reason=destroy_failed',
          }).hasNativeProof,
          isFalse,
        );
      },
    );

    test(
      'hasApi33FenceProof evaluates fence counts conditionally based on apiLevel',
      () {
        // API >= 33 requires both fence counts >= 2
        expect(
          _createSampleReport({
            'apiLevel': 34,
            'syncFenceAwaitedCount': 2,
            'syncFenceClosedCount': 2,
          }).hasApi33FenceProof,
          isTrue,
        );
        expect(
          _createSampleReport({
            'apiLevel': 33,
            'syncFenceAwaitedCount': 1,
            'syncFenceClosedCount': 2,
          }).hasApi33FenceProof,
          isFalse,
        );
        expect(
          _createSampleReport({
            'apiLevel': 33,
            'syncFenceAwaitedCount': 2,
            'syncFenceClosedCount': 1,
          }).hasApi33FenceProof,
          isFalse,
        );

        // API < 33 always returns true regardless of fence counts
        expect(
          _createSampleReport({
            'apiLevel': 30,
            'syncFenceAwaitedCount': 0,
            'syncFenceClosedCount': 0,
          }).hasApi33FenceProof,
          isTrue,
        );
        expect(
          _createSampleReport({
            'apiLevel': 31,
            'syncFenceAwaitedCount': 0,
            'syncFenceClosedCount': 0,
          }).hasApi33FenceProof,
          isTrue,
        );
      },
    );
  });

  group('VGCamera2ConcurrentIngestSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      for (final snippet in [
        'VGCamera2ConcurrentIngestSmokeReport(',
        'pass: true',
        'decision: VGCamera2ConcurrentIngestSmokeDecision.ingested',
        'apiLevel: 34',
        'hasCameraPermission: true',
        'selectedCameraIds: [0, 1]',
        'openedCameraCount: 2',
        'configuredSessionCount: 2',
        'capturedFrameCount: 2',
        'nativeIngestPassCount: 2',
        'syncFenceAwaitedCount: 2',
        'syncFenceClosedCount: 2',
        'nativeCreateRaw: status=PASS;sessionId=test-session-123',
        'nativeDestroyRaw: status=PASS;sessionId=test-session-123',
        'durationMs: 450',
      ]) {
        expect(a.toString(), contains(snippet));
      }
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final report1 = _createSampleReport({
          'diagnostics': {'alpha': 1, 'beta': 2, 'gamma': 3},
        });
        final report2 = _createSampleReport({
          'diagnostics': {'gamma': 3, 'alpha': 1, 'beta': 2},
        });

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'pass': false},
        {'decision': 'nativeIngestFailed'},
        {
          'reasons': ['diff_reason'],
        },
        {'apiLevel': 33},
        {'hasCameraPermission': false},
        {
          'selectedCameraIds': ['0', '2'],
        },
        {'openedCameraCount': 1},
        {'configuredSessionCount': 1},
        {'capturedFrameCount': 1},
        {'nativeIngestPassCount': 1},
        {'syncFenceAwaitedCount': 1},
        {'syncFenceClosedCount': 1},
        {'nativeCreateRaw': 'status=FAIL'},
        {'nativeDestroyRaw': 'status=FAIL'},
        {
          'events': ['different_event'],
        },
        {
          'diagnostics': {'other': 'value'},
        },
        {'proofBoundary': 'other_boundary'},
        {'durationMs': 999},
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group(
    'VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke MethodChannel contract',
    () {
      Future<MethodCall> captureCall({
        required Future<VGCamera2ConcurrentIngestSmokeReport> Function(
          MethodChannel channel,
        )
        action,
        Map<String, Object?>? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_concurrent_smoke_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response ?? _createSampleRawMap();
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'invokes runAndroidDagPhase3CameraConcurrentIngestSmoke with default args',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke(
                  channel: channel,
                ),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3CameraConcurrentIngestSmoke'),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
        },
      );

      test('passes custom timeout and custom dimensions', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke(
                timeout: const Duration(seconds: 15),
                maxWidth: 1280,
                maxHeight: 720,
                channel: channel,
              ),
          response: _createSampleRawMap({'durationMs': 500}),
        );

        expect(
          call.method,
          equals('runAndroidDagPhase3CameraConcurrentIngestSmoke'),
        );
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['timeoutMs'], equals(15000));
        expect(arguments['maxWidth'], equals(1280));
        expect(arguments['maxHeight'], equals(720));
      });

      test('uses default vanguard_media_engine channel when omitted', () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap({'durationMs': 320});
        });

        final report =
            await VGCamera2ConcurrentIngestSmokeReport.runAndroidCamera2ConcurrentIngestSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3CameraConcurrentIngestSmoke'),
        );
        expect(report.pass, isTrue);
      });
    },
  );
}
