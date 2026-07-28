// vg_editor_controller_teardown_test.dart
// Vanguard Media Engine — Phase 10-C Slice D teardown fix
//
// Focused tests verifying exact-once `disposeTimeline` dispatch and
// future-joining behaviour introduced in the Slice D teardown correction.
//
// Tests:
//   TD-1  repeated disposeAsync() sends one native request
//   TD-2  repeated disposeAsync() joins the same future
//   TD-3  disposeAsync() followed by dispose() sends one request
//   TD-4  dispose() alone sends one request
//   TD-5  commands are rejected immediately after dispose() is called
//   TD-6  repeated disposeAsyncConfirmed() returns identical future and dispatches once
//   TD-7  disposeAsyncConfirmed() -> disposeAsync() shares dispatch; confirmed propagates error while best-effort completes
//   TD-8  disposeAsync() -> disposeAsyncConfirmed() shares dispatch; best-effort completes while confirmed propagates error
//   TD-9  dispose() -> disposeAsyncConfirmed() shares dispatch; confirmed joins raw future and propagates error

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

VGClipDescriptor _clip({String id = 'clip-A', double trimEnd = 5.0}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture.mp4',
      durationSeconds: 5.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

VGEditorDraft _draft() => VGEditorDraft(
  id: 'draft-td',
  clips: [
    _clip(id: 'clip-A'),
    _clip(id: 'clip-B'),
  ],
);

// ── Channel mock ──────────────────────────────────────────────────────────────

/// Records disposeTimeline call counts and optionally blocks resolution.
class _MockChannel {
  int disposeCount = 0;
  Completer<void>? _blockCompleter;

  void install({bool block = false, bool throwException = false}) {
    if (block) {
      _blockCompleter = Completer<void>();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('vanguard_media_engine'),
          (call) async {
            if (call.method == 'disposeTimeline') {
              disposeCount++;
              if (_blockCompleter != null) {
                await _blockCompleter!.future;
              }
              if (throwException) {
                throw PlatformException(
                  code: 'TEARDOWN_FAILED',
                  message: 'Mock native teardown error',
                );
              }
              return null;
            }
            return null;
          },
        );
  }

  void completeBlock() => _blockCompleter?.complete();

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('vanguard_media_engine'),
          null,
        );
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGEditorController — Exact-Once Teardown', () {
    late _MockChannel mock;

    setUp(() {
      mock = _MockChannel();
    });

    tearDown(() {
      mock.uninstall();
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TD-1: repeated disposeAsync() sends one native request
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-1  repeated disposeAsync() sends exactly one disposeTimeline',
      () async {
        mock.install();
        final controller = VGEditorController(initialDraft: _draft());

        await controller.disposeAsync();
        await controller.disposeAsync();
        await controller.disposeAsync();
        controller.dispose();

        expect(
          mock.disposeCount,
          equals(1),
          reason: 'disposeTimeline must be sent exactly once',
        );
      },
    );

    // ─────────────────────────────────────────────────────────────────────────
    // TD-2: repeated disposeAsync() joins the same future (identical identity)
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-2  repeated disposeAsync() returns the same future instance',
      () async {
        mock.install(block: true);
        final controller = VGEditorController(initialDraft: _draft());

        final f1 = controller.disposeAsync();
        final f2 = controller.disposeAsync();
        final f3 = controller.disposeAsync();

        expect(
          identical(f1, f2),
          isTrue,
          reason: 'Second call must return the cached future',
        );
        expect(
          identical(f1, f3),
          isTrue,
          reason: 'Third call must return the cached future',
        );

        mock.completeBlock();
        await f1;

        expect(mock.disposeCount, equals(1));
        controller.dispose();
      },
    );

    // ─────────────────────────────────────────────────────────────────────────
    // TD-3: disposeAsync() followed by dispose() sends one request
    // ─────────────────────────────────────────────────────────────────────────

    test('TD-3  unawaited disposeAsync() followed by dispose() '
        'sends exactly one disposeTimeline', () async {
      mock.install();
      final controller = VGEditorController(initialDraft: _draft());

      // Deliberately not awaited — mirrors the playground's dispose() pattern.
      // ignore: unawaited_futures
      controller.disposeAsync();
      controller.dispose();

      // Drain the microtask queue so the fire-and-forget future executes.
      await Future<void>.delayed(Duration.zero);

      expect(
        mock.disposeCount,
        equals(1),
        reason:
            'dispose() must not send a second disposeTimeline when '
            'disposeAsync() already dispatched one',
      );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TD-4: dispose() alone sends one native request
    // ─────────────────────────────────────────────────────────────────────────

    test('TD-4  dispose() alone sends exactly one disposeTimeline', () async {
      mock.install();
      final controller = VGEditorController(initialDraft: _draft());

      controller.dispose();

      // Allow the fire-and-forget future to complete.
      await Future<void>.delayed(Duration.zero);

      expect(
        mock.disposeCount,
        equals(1),
        reason:
            'dispose() without a prior disposeAsync() must send exactly '
            'one disposeTimeline request',
      );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TD-5: commands throw StateError after dispose()
    // ─────────────────────────────────────────────────────────────────────────

    test('TD-5  commands throw StateError after dispose()', () async {
      mock.install();
      final controller = VGEditorController(initialDraft: _draft());

      controller.dispose();

      await expectLater(
        controller.initialize(),
        throwsA(isA<StateError>()),
        reason: 'initialize() must throw after dispose()',
      );
      await expectLater(
        controller.play(),
        throwsA(isA<StateError>()),
        reason: 'play() must throw after dispose()',
      );
      await expectLater(
        controller.pause(),
        throwsA(isA<StateError>()),
        reason: 'pause() must throw after dispose()',
      );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // TD-6: repeated disposeAsyncConfirmed() returns identical future and dispatches once
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-6  repeated disposeAsyncConfirmed() returns identical future and dispatches once',
      () async {
        mock.install(block: true);
        final controller = VGEditorController(initialDraft: _draft());

        final f1 = controller.disposeAsyncConfirmed();
        final f2 = controller.disposeAsyncConfirmed();
        final f3 = controller.disposeAsyncConfirmed();

        expect(identical(f1, f2), isTrue);
        expect(identical(f1, f3), isTrue);

        mock.completeBlock();
        await f1;

        expect(mock.disposeCount, equals(1));
        controller.dispose();
      },
    );

    // ─────────────────────────────────────────────────────────────────────────
    // TD-7: disposeAsyncConfirmed() -> disposeAsync() shares dispatch; confirmed propagates error while best-effort completes
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-7  disposeAsyncConfirmed() -> disposeAsync() shares dispatch; confirmed propagates error while best-effort completes',
      () async {
        mock.install(throwException: true);
        final controller = VGEditorController(initialDraft: _draft());

        final fConfirmed = controller.disposeAsyncConfirmed();
        final fBestEffort = controller.disposeAsync();

        await expectLater(fConfirmed, throwsA(isA<PlatformException>()));
        await expectLater(fBestEffort, completes);

        expect(mock.disposeCount, equals(1));
        controller.dispose();
      },
    );

    // ─────────────────────────────────────────────────────────────────────────
    // TD-8: disposeAsync() -> disposeAsyncConfirmed() shares dispatch; best-effort completes while confirmed propagates error
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-8  disposeAsync() -> disposeAsyncConfirmed() shares dispatch; best-effort completes while confirmed propagates error',
      () async {
        mock.install(throwException: true);
        final controller = VGEditorController(initialDraft: _draft());

        final fBestEffort = controller.disposeAsync();
        final fConfirmed = controller.disposeAsyncConfirmed();

        await expectLater(fBestEffort, completes);
        await expectLater(fConfirmed, throwsA(isA<PlatformException>()));

        expect(mock.disposeCount, equals(1));
        controller.dispose();
      },
    );

    // ─────────────────────────────────────────────────────────────────────────
    // TD-9: dispose() -> disposeAsyncConfirmed() shares dispatch; confirmed joins raw future and propagates error
    // ─────────────────────────────────────────────────────────────────────────

    test(
      'TD-9  dispose() -> disposeAsyncConfirmed() shares dispatch; confirmed joins raw future and propagates error',
      () async {
        mock.install(throwException: true);
        final controller = VGEditorController(initialDraft: _draft());

        controller.dispose();
        final fConfirmed = controller.disposeAsyncConfirmed();

        await expectLater(fConfirmed, throwsA(isA<PlatformException>()));

        expect(mock.disposeCount, equals(1));
      },
    );
  });
}
