// Copyright (c) Connects — Vanguard Phase 4C4J.
// Unit tests for public adaptive stream timeline diagnostics client.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGStreamingTimelineDiagnosticsRequest', () {
    test('default constructor creates valid request with frameCount 5', () {
      const request = VGStreamingTimelineDiagnosticsRequest();
      expect(request.frameCount, 5);
      expect(request.toMap(), {'frameCount': 5});
      expect(request.toString(), contains('frameCount=5'));
    });

    test('custom frameCount serializes correctly', () {
      const request = VGStreamingTimelineDiagnosticsRequest(frameCount: 12);
      expect(request.frameCount, 12);
      expect(request.toMap(), {'frameCount': 12});
    });

    test('asserts positive frameCount', () {
      expect(
        () => VGStreamingTimelineDiagnosticsRequest(frameCount: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGStreamingTimelineDiagnosticsRequest(frameCount: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('VGStreamingTimelineDiagnosticsReport', () {
    test('parses complete success map correctly with all 12 invariants', () {
      final report = VGStreamingTimelineDiagnosticsReport.fromMap({
        'pass': true,
        'raw': 'status=OK;allPassed=true',
        'frameCount': 5,
        'sequentialPass': true,
        'duplicatePass': true,
        'outOfOrderPass': true,
        'latePass': true,
        'futurePass': true,
        'futureRetryPass': true,
        'seekRebasePass': true,
        'renditionRebasePass': true,
        'liveOffsetPolicyPass': true,
        'negativeInputPass': true,
        'resetPass': true,
        'initialSnap': {'isStarted': false},
        'sequentialSnap': {'acceptedFrames': 5},
      });

      expect(report.phase, 'Phase4C4J');
      expect(report.pass, true);
      expect(report.frameCount, 5);
      expect(report.sequentialPass, true);
      expect(report.duplicatePass, true);
      expect(report.outOfOrderPass, true);
      expect(report.latePass, true);
      expect(report.futurePass, true);
      expect(report.futureRetryPass, true);
      expect(report.seekRebasePass, true);
      expect(report.renditionRebasePass, true);
      expect(report.liveOffsetPolicyPass, true);
      expect(report.negativeInputPass, true);
      expect(report.resetPass, true);
      expect(report.raw, 'status=OK;allPassed=true');
      expect(report.diagnostics['sequentialSnap']['acceptedFrames'], 5);

      final map = report.toMap();
      expect(map['pass'], true);
      expect(map['sequentialPass'], true);
      expect(map['duplicatePass'], true);
      expect(map['outOfOrderPass'], true);
      expect(map['latePass'], true);
      expect(map['futurePass'], true);
      expect(map['futureRetryPass'], true);
      expect(map['seekRebasePass'], true);
      expect(map['renditionRebasePass'], true);
      expect(map['liveOffsetPolicyPass'], true);
      expect(map['negativeInputPass'], true);
      expect(map['resetPass'], true);
      expect(report.toString(), contains('pass=true'));
    });

    test('false invariant makes report pass evaluate to false', () {
      final invariantKeys = [
        'sequentialPass',
        'duplicatePass',
        'outOfOrderPass',
        'latePass',
        'futurePass',
        'futureRetryPass',
        'seekRebasePass',
        'renditionRebasePass',
        'liveOffsetPolicyPass',
        'negativeInputPass',
        'resetPass',
      ];

      for (final key in invariantKeys) {
        final map = <String, dynamic>{
          'pass': true, // Even if native claims pass == true
          'raw': 'status=PARTIAL',
          'frameCount': 5,
          'sequentialPass': true,
          'duplicatePass': true,
          'outOfOrderPass': true,
          'latePass': true,
          'futurePass': true,
          'futureRetryPass': true,
          'seekRebasePass': true,
          'renditionRebasePass': true,
          'liveOffsetPolicyPass': true,
          'negativeInputPass': true,
          'resetPass': true,
        };
        map[key] = false; // flip single invariant to false

        final report = VGStreamingTimelineDiagnosticsReport.fromMap(map);
        expect(
          report.pass,
          false,
          reason: 'Report pass must be false when $key is false',
        );
      }
    });

    test('parses null map defensively with failure status', () {
      final report = VGStreamingTimelineDiagnosticsReport.fromMap(null);
      expect(report.pass, false);
      expect(report.raw, contains('null_response'));
      expect(report.diagnostics['pass'], false);
    });

    test('failure factory returns expected structure', () {
      final report = VGStreamingTimelineDiagnosticsReport.failure(
        'custom_error',
      );
      expect(report.pass, false);
      expect(report.raw, 'status=FAIL;reason=custom_error');
      expect(report.diagnostics['error'], 'custom_error');
    });

    test('unsupported factory returns non-android status', () {
      final report = VGStreamingTimelineDiagnosticsReport.unsupported();
      expect(report.phase, 'unsupported');
      expect(report.pass, false);
      expect(report.sequentialPass, false);
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.diagnostics['platform'], 'non-android');
    });
  });

  group('VGStreamingTimelineDiagnosticsClient', () {
    const channel = MethodChannel('vanguard_media_engine_test_channel');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'run calls MethodChannel with frameCount and parses successful report',
      () async {
        MethodCall? capturedCall;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              capturedCall = call;
              if (call.method ==
                  'runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke') {
                return {
                  'pass': true,
                  'raw': 'status=OK;allPassed=true',
                  'frameCount': call.arguments['frameCount'],
                  'sequentialPass': true,
                  'duplicatePass': true,
                  'outOfOrderPass': true,
                  'latePass': true,
                  'futurePass': true,
                  'futureRetryPass': true,
                  'seekRebasePass': true,
                  'renditionRebasePass': true,
                  'liveOffsetPolicyPass': true,
                  'negativeInputPass': true,
                  'resetPass': true,
                  'initialSnap': {'isStarted': false},
                  'sequentialSnap': {'acceptedFrames': 7},
                  'midSnap': {'isStarted': true},
                  'resetSnap': {'acceptedFrames': 0},
                };
              }
              throw MissingPluginException();
            });

        final client = VGStreamingTimelineDiagnosticsClient(channel: channel);
        final report = await client.run(
          request: const VGStreamingTimelineDiagnosticsRequest(frameCount: 7),
        );

        expect(
          capturedCall?.method,
          'runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke',
        );
        expect(capturedCall?.arguments, {'frameCount': 7});

        expect(report.pass, true);
        expect(report.frameCount, 7);
        expect(report.sequentialPass, true);
        expect(report.duplicatePass, true);
        expect(report.outOfOrderPass, true);
        expect(report.latePass, true);
        expect(report.futurePass, true);
        expect(report.futureRetryPass, true);
        expect(report.seekRebasePass, true);
        expect(report.renditionRebasePass, true);
        expect(report.liveOffsetPolicyPass, true);
        expect(report.negativeInputPass, true);
        expect(report.resetPass, true);
        expect(report.raw, contains('status=OK'));
      },
    );

    test('run handles invalid/null response without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return null;
          });

      final client = VGStreamingTimelineDiagnosticsClient(channel: channel);
      final report = await client.run();

      expect(report.pass, false);
      expect(report.raw, contains('invalid_response:null'));
    });

    test(
      'run handles MissingPluginException by returning unsupported report',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              throw MissingPluginException();
            });

        final client = VGStreamingTimelineDiagnosticsClient(channel: channel);
        final report = await client.run();

        expect(report.phase, 'unsupported');
        expect(report.pass, false);
        expect(report.raw, contains('UNSUPPORTED'));
      },
    );

    test('run handles generic exception without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw Exception('binder_transaction_failed');
          });

      final client = VGStreamingTimelineDiagnosticsClient(channel: channel);
      final report = await client.run();

      expect(report.pass, false);
      expect(report.raw, contains('binder_transaction_failed'));
    });

    test(
      'callers interact purely through client without raw MethodChannel',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              return {
                'pass': true,
                'raw': 'status=OK',
                'frameCount': 5,
                'sequentialPass': true,
                'duplicatePass': true,
                'outOfOrderPass': true,
                'latePass': true,
                'futurePass': true,
                'futureRetryPass': true,
                'seekRebasePass': true,
                'renditionRebasePass': true,
                'liveOffsetPolicyPass': true,
                'negativeInputPass': true,
                'resetPass': true,
              };
            });

        final client = VGStreamingTimelineDiagnosticsClient(channel: channel);
        final report = await client.run();

        expect(report, isA<VGStreamingTimelineDiagnosticsReport>());
        expect(report.pass, isTrue);
      },
    );
  });
}
