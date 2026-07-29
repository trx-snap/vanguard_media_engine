// test/vg_audio_extraction_service_test.dart
// vanguard_media_engine — Phase 10-C Slice T Gate 6A
//
// Unit tests for VGAudioExtractionService and associated Dart bridge.

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');
  late List<MethodCall> capturedCalls;

  setUp(() {
    capturedCalls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    // Reset test override to null to restore production platform detection
    VGAudioExtractionService.debugSetIsIOSOverrideForTesting(null);
    // Remove the mock handler
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<dynamic>? Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCalls.add(call);
          return handler(call);
        });
  }

  group('1. Platform Gating', () {
    test(
      'null override uses the real host platform (unsupported on test host)',
      () {
        // With no override set, should default to Platform.isIOS (which is false on host)
        final result = VGAudioExtractionService.begin(
          operationId: 'op-gate-null',
          sourcePath: '/path/src.mp4',
          outputPath: '/path/out.m4a',
        );
        expect(result, isA<VGAudioExtractionBeginResult>());
        expect(result, isA<VGAudioExtractionBeginUnsupported>());
        expect(capturedCalls, isEmpty);
      },
    );

    test(
      'forced false returns unsupported platform and makes no MethodChannel calls',
      () {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(false);
        final result = VGAudioExtractionService.begin(
          operationId: 'op-gate-false',
          sourcePath: '/path/src.mp4',
          outputPath: '/path/out.m4a',
        );
        expect(result, isA<VGAudioExtractionBeginUnsupported>());
        expect(capturedCalls, isEmpty);
      },
    );
  });

  group('2. Begin Contract', () {
    test(
      'forced iOS returns VGAudioExtractionBeginStarted synchronously',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        setHandler((call) async => {'outputPath': '/path/out.m4a'});

        final result = VGAudioExtractionService.begin(
          operationId: 'op-begin-sync',
          sourcePath: '/path/src.mp4',
          outputPath: '/path/out.m4a',
        );

        expect(result, isA<VGAudioExtractionBeginStarted>());
        final started = result as VGAudioExtractionBeginStarted;
        expect(started.operation, isNotNull);

        // Await terminal operation result to eliminate abandoned async operations.
        await started.operation.result;
      },
    );

    test(
      'omitted trim values are absent from beginMethod channel call arguments',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final argCompleter = Completer<Map<String, dynamic>>();
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            argCompleter.complete(
              Map<String, dynamic>.from(call.arguments as Map),
            );
            return beginCompleter.future;
          }
          return null;
        });

        final result = VGAudioExtractionService.begin(
          operationId: 'op-trim-omitted',
          sourcePath: '/path/src.mp4',
          outputPath: '/path/out.m4a',
        );

        final args = await argCompleter.future;
        expect(capturedCalls.first.method, 'beginAudioExtraction');
        expect(args, {
          'operationId': 'op-trim-omitted',
          'sourcePath': '/path/src.mp4',
          'outputPath': '/path/out.m4a',
        });

        // Clean up pending async operation
        beginCompleter.complete({'outputPath': '/path/out.m4a'});
        await (result as VGAudioExtractionBeginStarted).operation.result;
      },
    );

    test(
      'provided trim values are forwarded unchanged in begin MethodChannel call arguments',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final argCompleter = Completer<Map<String, dynamic>>();
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            argCompleter.complete(
              Map<String, dynamic>.from(call.arguments as Map),
            );
            return beginCompleter.future;
          }
          return null;
        });

        final result = VGAudioExtractionService.begin(
          operationId: 'op-trim-provided',
          sourcePath: '/path/src.mp4',
          outputPath: '/path/out.m4a',
          trimStartSeconds: 12.34,
          trimEndSeconds: 56.78,
        );

        final args = await argCompleter.future;
        expect(capturedCalls.first.method, 'beginAudioExtraction');
        expect(args, {
          'operationId': 'op-trim-provided',
          'sourcePath': '/path/src.mp4',
          'outputPath': '/path/out.m4a',
          'trimStartSeconds': 12.34,
          'trimEndSeconds': 56.78,
        });

        // Clean up pending async operation
        beginCompleter.complete({'outputPath': '/path/out.m4a'});
        await (result as VGAudioExtractionBeginStarted).operation.result;
      },
    );
  });

  group('3. Terminal Results', () {
    test(
      'successful outputPath mapping returns VGAudioExtractionSuccess',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        setHandler((call) async => {'outputPath': '/resolved/path/out.m4a'});

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-success',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        final res = await beginResult.operation.result;
        expect(res, isA<VGAudioExtractionSuccess>());
        expect(
          (res as VGAudioExtractionSuccess).outputPath,
          '/resolved/path/out.m4a',
        );
        expect(res.isSuccess, isTrue);
        expect(res.isFailure, isFalse);
      },
    );

    test(
      'success response without outputPath resolves to internalFailure',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        setHandler((call) async => <String, dynamic>{}); // No outputPath key

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-success-no-path',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        final res = await beginResult.operation.result;
        expect(res, isA<VGAudioExtractionFailure>());
        final fail = res as VGAudioExtractionFailure;
        expect(fail.error, VGAudioExtractionError.internalFailure);
        expect(
          fail.message,
          contains('Native returned success without outputPath'),
        );
        expect(res.isSuccess, isFalse);
        expect(res.isFailure, isTrue);
      },
    );

    test(
      'error code mapping works correctly for every PlatformException',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);

        final codes = {
          'invalidArgument': VGAudioExtractionError.invalidArgument,
          'operationAlreadyExists':
              VGAudioExtractionError.operationAlreadyExists,
          'noAudioTrack': VGAudioExtractionError.noAudioTrack,
          'cancelled': VGAudioExtractionError.cancelled,
          'readFailure': VGAudioExtractionError.readFailure,
          'writeFailure': VGAudioExtractionError.writeFailure,
          'internalFailure': VGAudioExtractionError.internalFailure,
          'someUnknownCode': VGAudioExtractionError.internalFailure,
          'unknown_code_fallback': VGAudioExtractionError.internalFailure,
        };

        for (final entry in codes.entries) {
          setHandler((call) async {
            throw PlatformException(
              code: entry.key,
              message: 'Platform error for ${entry.key}',
            );
          });

          final beginResult =
              VGAudioExtractionService.begin(
                    operationId: 'op-err-${entry.key}',
                    sourcePath: '/path/src.mp4',
                    outputPath: '/path/out.m4a',
                  )
                  as VGAudioExtractionBeginStarted;

          final res = await beginResult.operation.result;
          expect(res, isA<VGAudioExtractionFailure>());
          final fail = res as VGAudioExtractionFailure;
          expect(fail.error, entry.value);
          expect(fail.message, 'Platform error for ${entry.key}');
        }
      },
    );

    test('non-PlatformException maps to internalFailure', () async {
      VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
      setHandler((call) async {
        throw ArgumentError('Some non-platform Dart exception');
      });

      final beginResult =
          VGAudioExtractionService.begin(
                operationId: 'op-non-platform-err',
                sourcePath: '/path/src.mp4',
                outputPath: '/path/out.m4a',
              )
              as VGAudioExtractionBeginStarted;

      final res = await beginResult.operation.result;
      expect(res, isA<VGAudioExtractionFailure>());
      final fail = res as VGAudioExtractionFailure;
      expect(fail.error, VGAudioExtractionError.internalFailure);
      expect(fail.message, contains('Some non-platform Dart exception'));
    });
  });

  group('4. Cancel Contract', () {
    test(
      'cancellationCompleted, alreadyTerminal, and notFound mappings',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final beginCompleters = <String, Completer<Map<String, dynamic>>>{};

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            final opId = call.arguments['operationId'] as String;
            final comp = Completer<Map<String, dynamic>>();
            beginCompleters[opId] = comp;
            return comp.future;
          }
          if (call.method == 'cancelAudioExtraction') {
            return {
              'disposition': call.arguments['operationId']!.contains('notFound')
                  ? 'notFound'
                  : (call.arguments['operationId']!.contains('alreadyTerminal')
                        ? 'alreadyTerminal'
                        : 'cancellationCompleted'),
            };
          }
          return null;
        });

        final cancelMappings = {
          'cancellationCompleted':
              VGAudioExtractionCancelDisposition.cancellationCompleted,
          'alreadyTerminal': VGAudioExtractionCancelDisposition.alreadyTerminal,
          'notFound': VGAudioExtractionCancelDisposition.notFound,
        };

        for (final entry in cancelMappings.entries) {
          capturedCalls.clear();

          final beginResult =
              VGAudioExtractionService.begin(
                    operationId: 'op-cancel-${entry.key}',
                    sourcePath: '/path/src.mp4',
                    outputPath: '/path/out.m4a',
                  )
                  as VGAudioExtractionBeginStarted;

          final disposition = await beginResult.operation.cancel();
          expect(disposition, entry.value);
          expect(capturedCalls.length, 2);
          expect(capturedCalls[1].method, 'cancelAudioExtraction');
          expect(
            capturedCalls[1].arguments['operationId'],
            'op-cancel-${entry.key}',
          );

          // Clean up pending async operation
          beginCompleters['op-cancel-${entry.key}']?.complete({
            'outputPath': '/path/out.m4a',
          });
          await beginResult.operation.result;
        }
      },
    );

    test(
      'cancel response variants (unknown string, null response, missing disposition, non-string) throw cancel exception',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);

        final badResponses = [
          {'disposition': 'unknown_random_string'},
          null,
          <String, dynamic>{}, // missing disposition key
          {'disposition': 123}, // non-string disposition
        ];

        for (var i = 0; i < badResponses.length; i++) {
          final beginCompleter = Completer<Map<String, dynamic>>();
          setHandler((call) async {
            if (call.method == 'beginAudioExtraction') {
              return beginCompleter.future;
            }
            if (call.method == 'cancelAudioExtraction') {
              return badResponses[i];
            }
            return null;
          });

          final beginResult =
              VGAudioExtractionService.begin(
                    operationId: 'op-cancel-bad-$i',
                    sourcePath: '/path/src.mp4',
                    outputPath: '/path/out.m4a',
                  )
                  as VGAudioExtractionBeginStarted;

          expect(
            () => beginResult.operation.cancel(),
            throwsA(
              isA<VGAudioExtractionCancelException>().having(
                (e) => e.error,
                'error',
                VGAudioExtractionError.internalFailure,
              ),
            ),
          );

          // Clean up pending async operation
          beginCompleter.complete({'outputPath': '/path/out.m4a'});
          await beginResult.operation.result;
        }
      },
    );

    test(
      'cancel PlatformException throws VGAudioExtractionCancelException',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            return beginCompleter.future;
          }
          if (call.method == 'cancelAudioExtraction') {
            throw PlatformException(
              code: 'CANCEL_FAILED',
              message: 'Failed to cancel',
            );
          }
          return null;
        });

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-cancel-exception',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        expect(
          () => beginResult.operation.cancel(),
          throwsA(
            isA<VGAudioExtractionCancelException>()
                .having(
                  (e) => e.error,
                  'error',
                  VGAudioExtractionError.internalFailure,
                )
                .having(
                  (e) => e.message,
                  'message',
                  contains('CANCEL_FAILED — Failed to cancel'),
                ),
          ),
        );

        // Clean up pending async operation
        beginCompleter.complete({'outputPath': '/path/out.m4a'});
        await beginResult.operation.result;
      },
    );

    test(
      'cancel-request failure does not complete the operation result',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            return beginCompleter.future;
          }
          if (call.method == 'cancelAudioExtraction') {
            throw PlatformException(
              code: 'CANCEL_FAILED',
              message: 'Failed to cancel',
            );
          }
          return null;
        });

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-cancel-result-intact',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        // Request cancel which fails and throws exception
        try {
          await beginResult.operation.cancel();
          fail('Should have thrown VGAudioExtractionCancelException');
        } catch (e) {
          expect(e, isA<VGAudioExtractionCancelException>());
        }

        // Result future must still be pending (not completed)
        var resultCompleted = false;
        unawaited(
          beginResult.operation.result.then((_) => resultCompleted = true),
        );

        // Wait a microtask queue tick to verify it didn't complete
        await Future<void>.delayed(Duration.zero);
        expect(resultCompleted, isFalse);

        // Now complete the begin call with success and verify result completes normally
        beginCompleter.complete({'outputPath': '/resolved/path/out.m4a'});
        final res = await beginResult.operation.result;
        expect(res, isA<VGAudioExtractionSuccess>());
        expect(
          (res as VGAudioExtractionSuccess).outputPath,
          '/resolved/path/out.m4a',
        );
      },
    );
  });

  group('5. Terminal-Race Semantics', () {
    test(
      'cancellationCompleted does not force a cancelled result when begin completes first',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            return beginCompleter.future;
          }
          if (call.method == 'cancelAudioExtraction') {
            return {'disposition': 'cancellationCompleted'};
          }
          return null;
        });

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-race-success',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        // 1. Resolve begin call with success (simulating exporter completed before/during cancel handling)
        beginCompleter.complete({'outputPath': '/resolved/path/out.m4a'});

        // 2. Perform cancel call
        final disposition = await beginResult.operation.cancel();
        expect(
          disposition,
          VGAudioExtractionCancelDisposition.cancellationCompleted,
        );

        // 3. Operation result must complete with success, not cancelled error
        final res = await beginResult.operation.result;
        expect(res, isA<VGAudioExtractionSuccess>());
        expect(
          (res as VGAudioExtractionSuccess).outputPath,
          '/resolved/path/out.m4a',
        );
      },
    );

    test(
      'cancellationCompleted does not force a cancelled result when begin fails first',
      () async {
        VGAudioExtractionService.debugSetIsIOSOverrideForTesting(true);
        final beginCompleter = Completer<Map<String, dynamic>>();

        setHandler((call) async {
          if (call.method == 'beginAudioExtraction') {
            return beginCompleter.future;
          }
          if (call.method == 'cancelAudioExtraction') {
            return {'disposition': 'cancellationCompleted'};
          }
          return null;
        });

        final beginResult =
            VGAudioExtractionService.begin(
                  operationId: 'op-race-failure',
                  sourcePath: '/path/src.mp4',
                  outputPath: '/path/out.m4a',
                )
                as VGAudioExtractionBeginStarted;

        // 1. Resolve begin call with error
        beginCompleter.completeError(
          PlatformException(code: 'noAudioTrack', message: 'No audio'),
        );

        // 2. Perform cancel call
        final disposition = await beginResult.operation.cancel();
        expect(
          disposition,
          VGAudioExtractionCancelDisposition.cancellationCompleted,
        );

        // 3. Operation result must complete with the actual error, not cancelled
        final res = await beginResult.operation.result;
        expect(res, isA<VGAudioExtractionFailure>());
        expect(
          (res as VGAudioExtractionFailure).error,
          VGAudioExtractionError.noAudioTrack,
        );
      },
    );
  });
}
