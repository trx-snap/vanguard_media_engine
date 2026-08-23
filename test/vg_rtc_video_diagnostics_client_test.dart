// Copyright (c) Connects — Vanguard Phase 4C3V.
// Unit tests for public RTC video diagnostics client.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGRtcVideoDiagnosticsRequest', () {
    test('default constructor creates valid request', () {
      const request = VGRtcVideoDiagnosticsRequest();
      expect(request.width, 64);
      expect(request.height, 64);
      expect(request.frameCount, 3);
      expect(request.toMap(), {'width': 64, 'height': 64, 'frameCount': 3});
      expect(request.toString(), contains('width=64'));
    });

    test('custom values serialize correctly', () {
      const request = VGRtcVideoDiagnosticsRequest(
        width: 128,
        height: 256,
        frameCount: 10,
      );
      expect(request.width, 128);
      expect(request.height, 256);
      expect(request.frameCount, 10);
      expect(request.toMap(), {'width': 128, 'height': 256, 'frameCount': 10});
    });

    test('asserts positive width, height, and frameCount', () {
      expect(
        () => VGRtcVideoDiagnosticsRequest(width: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGRtcVideoDiagnosticsRequest(width: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGRtcVideoDiagnosticsRequest(height: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGRtcVideoDiagnosticsRequest(height: -10),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGRtcVideoDiagnosticsRequest(frameCount: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGRtcVideoDiagnosticsRequest(frameCount: -5),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('VGRtcVideoDiagnosticsCheckResult', () {
    test('parses complete map successfully', () {
      final result = VGRtcVideoDiagnosticsCheckResult.fromMap('contract', {
        'pass': true,
        'raw': 'status=OK;frames=3',
        'width': 64,
        'height': 64,
      });
      expect(result.key, 'contract');
      expect(result.pass, true);
      expect(result.raw, 'status=OK;frames=3');
      expect(result.details['width'], 64);
      expect(result.toMap()['pass'], true);
    });

    test('parses null map defensively', () {
      final result = VGRtcVideoDiagnosticsCheckResult.fromMap('adapter', null);
      expect(result.key, 'adapter');
      expect(result.pass, false);
      expect(result.raw, contains('null_response'));
      expect(result.details, isEmpty);
    });

    test('parses partial map without raw field defensively', () {
      final result = VGRtcVideoDiagnosticsCheckResult.fromMap('metadata', {
        'pass': true,
      });
      expect(result.key, 'metadata');
      expect(result.pass, true);
      expect(result.raw, 'status=OK');
    });

    test('failure constructor sets pass to false with custom reason', () {
      final result = VGRtcVideoDiagnosticsCheckResult.failure(
        'backpressure',
        'buffer_overflow',
      );
      expect(result.key, 'backpressure');
      expect(result.pass, false);
      expect(result.raw, 'status=FAIL;reason=buffer_overflow');
      expect(result.details['error'], 'buffer_overflow');
    });

    test('unsupported constructor creates typed unsupported result', () {
      final result = VGRtcVideoDiagnosticsCheckResult.unsupported('validator');
      expect(result.key, 'validator');
      expect(result.pass, false);
      expect(result.raw, contains('UNSUPPORTED'));
    });
  });

  group('VGRtcVideoDiagnosticsReport', () {
    test('report models and getters work correctly', () {
      const contractCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'contract',
        pass: true,
        raw: 'status=OK',
      );
      const adapterCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'adapter',
        pass: true,
        raw: 'status=OK',
      );
      const metadataCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'metadata',
        pass: true,
        raw: 'status=OK',
      );
      const backpressureCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'backpressure',
        pass: true,
        raw: 'status=OK',
      );
      const validatorCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'validator',
        pass: true,
        raw: 'status=OK',
      );
      const egressCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'processedEgress',
        pass: true,
        raw: 'status=OK',
      );
      const jitterCheck = VGRtcVideoDiagnosticsCheckResult(
        key: 'jitterBuffer',
        pass: true,
        raw: 'status=OK',
      );

      final report = VGRtcVideoDiagnosticsReport(
        phase: 'Phase4C3V',
        pass: true,
        videoOnlyBoundaryPreserved: true,
        roomAudioBoundaryPreserved: true,
        transportAgnostic: true,
        checks: {
          'contract': contractCheck,
          'adapter': adapterCheck,
          'metadata': metadataCheck,
          'backpressure': backpressureCheck,
          'validator': validatorCheck,
          'processedEgress': egressCheck,
          'jitterBuffer': jitterCheck,
        },
        raw: 'status=OK',
        diagnostics: {'allPass': true},
      );

      expect(report.phase, 'Phase4C3V');
      expect(report.pass, true);
      expect(report.videoOnlyBoundaryPreserved, true);
      expect(report.roomAudioBoundaryPreserved, true);
      expect(report.transportAgnostic, true);
      expect(report.contract?.pass, true);
      expect(report.adapter?.pass, true);
      expect(report.metadata?.pass, true);
      expect(report.backpressure?.pass, true);
      expect(report.validator?.pass, true);
      expect(report.processedEgress?.pass, true);
      expect(report.jitterBuffer?.pass, true);
      expect(report.toMap()['pass'], true);
      expect(report.toString(), contains('checksCount=7'));
    });

    test('unsupported report factory returns expected values', () {
      final report = VGRtcVideoDiagnosticsReport.unsupported();
      expect(report.phase, 'unsupported');
      expect(report.pass, false);
      expect(report.videoOnlyBoundaryPreserved, false);
      expect(report.roomAudioBoundaryPreserved, false);
      expect(report.transportAgnostic, false);
      expect(report.checks, isEmpty);
      expect(report.raw, contains('UNSUPPORTED'));
    });
  });

  group('VGRtcVideoDiagnosticsClient', () {
    const channel = MethodChannel('vanguard_media_engine_test_channel');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'runAll calls all 7 routes with expected parameters and returns pass',
      () async {
        final methodCalls = <MethodCall>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              methodCalls.add(call);
              switch (call.method) {
                case 'runAndroidDagPhase4C3DRtcContractSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;contract=true',
                    'width': call.arguments['width'],
                    'height': call.arguments['height'],
                    'frameCount': call.arguments['frameCount'],
                  };
                case 'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;adapter=true',
                    'output': {'pass': true},
                    'input': {'pass': true},
                  };
                case 'runAndroidDagPhase4C3KRtcMetadataSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;metadata=true',
                    'timestamp': {'pass': true},
                    'orientation': {'pass': true},
                  };
                case 'runAndroidDagPhase4C3NRtcBackpressureSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;backpressure=true',
                    'droppedFrames': 0,
                  };
                case 'runAndroidDagPhase4C3QRtcFrameValidatorSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;validator=true',
                    'validFrames': 1,
                  };
                case 'runAndroidDagPhase4C3UProcessedVideoEgressSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;egress=true',
                    'egressFrames': 3,
                  };
                case 'runAndroidDagPhase4C4BRtcJitterBufferSmoke':
                  return {
                    'pass': true,
                    'raw': 'status=OK;jitterBuffer=true',
                    'jitterFrames': 3,
                  };
                default:
                  throw MissingPluginException();
              }
            });

        final client = VGRtcVideoDiagnosticsClient(channel: channel);
        const request = VGRtcVideoDiagnosticsRequest(
          width: 128,
          height: 256,
          frameCount: 5,
        );

        final report = await client.runAll(request: request);

        expect(methodCalls.length, 7);
        expect(methodCalls.map((c) => c.method).toList(), [
          'runAndroidDagPhase4C3DRtcContractSmoke',
          'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
          'runAndroidDagPhase4C3KRtcMetadataSmoke',
          'runAndroidDagPhase4C3NRtcBackpressureSmoke',
          'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
          'runAndroidDagPhase4C3UProcessedVideoEgressSmoke',
          'runAndroidDagPhase4C4BRtcJitterBufferSmoke',
        ]);

        // Verify arguments
        expect(methodCalls[0].arguments, {
          'width': 128,
          'height': 256,
          'frameCount': 5,
        });
        expect(methodCalls[1].arguments, {
          'width': 128,
          'height': 256,
          'frameCount': 5,
        });
        expect(methodCalls[2].arguments, isNull);
        expect(methodCalls[3].arguments, isNull);
        expect(methodCalls[4].arguments, {'width': 128, 'height': 256});
        expect(methodCalls[5].arguments, {
          'width': 128,
          'height': 256,
          'frameCount': 5,
        });
        expect(methodCalls[6].arguments, {'frameCount': 5});

        // Verify report
        expect(report.pass, true);
        expect(report.videoOnlyBoundaryPreserved, true);
        expect(report.roomAudioBoundaryPreserved, true);
        expect(report.transportAgnostic, true);
        expect(report.checks.length, 7);
        expect(report.contract?.pass, true);
        expect(report.adapter?.pass, true);
        expect(report.metadata?.pass, true);
        expect(report.backpressure?.pass, true);
        expect(report.validator?.pass, true);
        expect(report.processedEgress?.pass, true);
        expect(report.jitterBuffer?.pass, true);
        expect(report.raw, contains('status=OK'));
        expect(report.diagnostics['pass'], true);
      },
    );

    test(
      'one failing route makes overall pass false while preserving diagnostics',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'runAndroidDagPhase4C3NRtcBackpressureSmoke') {
                return {
                  'pass': false,
                  'raw': 'status=FAIL;reason=queue_overflow',
                };
              }
              return {'pass': true, 'raw': 'status=OK'};
            });

        final client = VGRtcVideoDiagnosticsClient(channel: channel);
        final report = await client.runAll();

        expect(report.pass, false);
        expect(report.contract?.pass, true);
        expect(report.backpressure?.pass, false);
        expect(report.backpressure?.raw, contains('queue_overflow'));
        expect(report.jitterBuffer?.pass, true);
        expect(report.checks.length, 7);
        expect(report.raw, contains('status=FAIL'));
        expect(report.raw, contains('failedChecks=backpressure'));
      },
    );

    test('MissingPluginException returns typed unsupported report', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw MissingPluginException();
          });

      final client = VGRtcVideoDiagnosticsClient(channel: channel);
      final report = await client.runAll();

      expect(report.phase, 'unsupported');
      expect(report.pass, false);
      expect(report.videoOnlyBoundaryPreserved, false);
      expect(report.roomAudioBoundaryPreserved, false);
      expect(report.transportAgnostic, false);
      expect(report.checks, isEmpty);
      expect(report.raw, contains('UNSUPPORTED'));
    });

    test('individual check methods invoke corresponding routes', () async {
      final methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            return {'pass': true, 'raw': 'status=OK'};
          });

      final client = VGRtcVideoDiagnosticsClient(channel: channel);

      final r1 = await client.runContractSmoke(
        width: 32,
        height: 32,
        frameCount: 2,
      );
      expect(r1.pass, true);
      expect(methodCalls.last.method, 'runAndroidDagPhase4C3DRtcContractSmoke');

      final r2 = await client.runAdapterSmoke(
        width: 32,
        height: 32,
        frameCount: 2,
      );
      expect(r2.pass, true);
      expect(
        methodCalls.last.method,
        'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
      );

      final r3 = await client.runMetadataSmoke();
      expect(r3.pass, true);
      expect(methodCalls.last.method, 'runAndroidDagPhase4C3KRtcMetadataSmoke');

      final r4 = await client.runBackpressureSmoke();
      expect(r4.pass, true);
      expect(
        methodCalls.last.method,
        'runAndroidDagPhase4C3NRtcBackpressureSmoke',
      );

      final r5 = await client.runFrameValidatorSmoke(width: 32, height: 32);
      expect(r5.pass, true);
      expect(
        methodCalls.last.method,
        'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
      );

      final r6 = await client.runProcessedVideoEgressSmoke(
        width: 32,
        height: 32,
        frameCount: 2,
      );
      expect(r6.pass, true);
      expect(
        methodCalls.last.method,
        'runAndroidDagPhase4C3UProcessedVideoEgressSmoke',
      );

      final r7 = await client.runJitterBufferSmoke(frameCount: 4);
      expect(r7.pass, true);
      expect(
        methodCalls.last.method,
        'runAndroidDagPhase4C4BRtcJitterBufferSmoke',
      );
    });

    test(
      'individual check methods handle MissingPluginException cleanly',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              throw MissingPluginException();
            });

        final client = VGRtcVideoDiagnosticsClient(channel: channel);
        final r1 = await client.runContractSmoke();
        expect(r1.pass, false);
        expect(r1.raw, contains('UNSUPPORTED'));

        final r2 = await client.runAdapterSmoke();
        expect(r2.pass, false);
        expect(r2.raw, contains('UNSUPPORTED'));

        final r3 = await client.runMetadataSmoke();
        expect(r3.pass, false);
        expect(r3.raw, contains('UNSUPPORTED'));

        final r4 = await client.runBackpressureSmoke();
        expect(r4.pass, false);
        expect(r4.raw, contains('UNSUPPORTED'));

        final r5 = await client.runFrameValidatorSmoke();
        expect(r5.pass, false);
        expect(r5.raw, contains('UNSUPPORTED'));

        final r6 = await client.runProcessedVideoEgressSmoke();
        expect(r6.pass, false);
        expect(r6.raw, contains('UNSUPPORTED'));

        final r7 = await client.runJitterBufferSmoke();
        expect(r7.pass, false);
        expect(r7.raw, contains('UNSUPPORTED'));
      },
    );
  });
}
