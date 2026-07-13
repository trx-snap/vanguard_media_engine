// vg_editor_controller_slice_d_test.dart
// Vanguard Media Engine — Phase 10-C Slice D
//
// Focused Dart tests verifying that VGEditorController forwards the
// authoritative `durationSeconds` field through the MethodChannel for
// both createTimelineTexture (initialize) and updateTimeline (updateDraft).
//
// These tests exercise the real VGEditorController MethodChannel path and
// capture the exact payload sent to native. They do NOT reproduce the
// payload-building algorithm internally.
//
// Tests:
//   SD-1  createTimelineTexture forwards durationSeconds
//   SD-2  updateTimeline forwards durationSeconds

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Test fixtures ─────────────────────────────────────────────────────────────

/// Constructs a clip with a controllable trim range so that
/// `draft.durationSeconds` is deterministic and distinct across tests.
VGClipDescriptor _clip({
  required String id,
  double trimEnd = 5.0,
}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture.mp4',
      durationSeconds: trimEnd,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

// ── Mock channel helpers ───────────────────────────────────────────────────────

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (call) => handler(call.method, call.arguments),
  );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(_clearMockHandler);

  // ───────────────────────────────────────────────────────────────────────────
  // SD-1: createTimelineTexture forwards durationSeconds
  // ───────────────────────────────────────────────────────────────────────────

  test('SD-1  createTimelineTexture forwards durationSeconds', () async {
    // Construct an initial draft with a predictable, non-trivial duration.
    // Two clips of 3.0 s each → durationSeconds == 6.0.
    final initialDraft = VGEditorDraft(
      id: 'draft-sd1',
      clips: [
        _clip(id: 'clip-A', trimEnd: 3.0),
        _clip(id: 'clip-B', trimEnd: 3.0),
      ],
    );

    dynamic capturedArgs;

    _setMockHandler((method, args) async {
      if (method == 'createTimelineTexture') {
        capturedArgs = args;
        return {'textureId': 1, 'width': 640, 'height': 360};
      }
      if (method == 'disposeTimeline') return null;
      return null;
    });

    final controller = VGEditorController(initialDraft: initialDraft);
    addTearDown(controller.dispose);

    await controller.initialize();

    // Verify the channel was invoked with the correct method name.
    expect(capturedArgs, isNotNull,
        reason: 'createTimelineTexture must have been called');
    expect(capturedArgs, isA<Map>());

    final argsMap = capturedArgs as Map;

    // Verify draft key is present (regression guard — ensures payload shape).
    expect(argsMap.containsKey('draft'), isTrue,
        reason: 'Payload must contain draft key');

    // Verify the top-level durationSeconds key is present.
    expect(argsMap.containsKey('durationSeconds'), isTrue,
        reason: 'Payload must contain top-level durationSeconds key');

    // Verify the forwarded value exactly matches the draft's computed duration.
    // This fails if the controller sends a stale, zero, or hardcoded value.
    final sentDuration = argsMap['durationSeconds'] as double;
    expect(sentDuration, closeTo(initialDraft.durationSeconds, 0.001),
        reason:
            'durationSeconds in payload must equal initialDraft.durationSeconds; '
            'got $sentDuration, expected ${initialDraft.durationSeconds}');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // SD-2: updateTimeline forwards durationSeconds
  // ───────────────────────────────────────────────────────────────────────────

  test('SD-2  updateTimeline forwards durationSeconds', () async {
    // Initial draft: 3.0 s + 3.0 s = 6.0 s — deliberately different from the
    // updated draft so a stale value cannot produce a false-pass.
    final initialDraft = VGEditorDraft(
      id: 'draft-sd2-initial',
      clips: [
        _clip(id: 'clip-A', trimEnd: 3.0),
        _clip(id: 'clip-B', trimEnd: 3.0),
      ],
    );

    // Updated draft: 4.0 s + 5.0 s = 9.0 s — a distinct total duration.
    final updatedDraft = VGEditorDraft(
      id: 'draft-sd2-updated',
      clips: [
        _clip(id: 'clip-A', trimEnd: 4.0),
        _clip(id: 'clip-B', trimEnd: 5.0),
      ],
    );

    // Sanity: the two durations must differ so neither can false-pass.
    expect(updatedDraft.durationSeconds,
        isNot(closeTo(initialDraft.durationSeconds, 0.001)),
        reason: 'Test fixture must use distinct durations to prevent false-pass');

    dynamic capturedUpdateArgs;

    _setMockHandler((method, args) async {
      switch (method) {
        case 'createTimelineTexture':
          return {'textureId': 2, 'width': 640, 'height': 360};
        case 'updateTimeline':
          capturedUpdateArgs = args;
          return {'textureId': 3, 'width': 640, 'height': 360};
        case 'disposeTimeline':
          return null;
        default:
          return null;
      }
    });

    final controller = VGEditorController(initialDraft: initialDraft);
    addTearDown(controller.dispose);

    // Must be initialised before updateDraft can be called.
    await controller.initialize();

    // Call through the real controller.updateDraft path.
    await controller.updateDraft(updatedDraft);

    // Verify updateTimeline was called and its payload captured.
    expect(capturedUpdateArgs, isNotNull,
        reason: 'updateTimeline must have been called');
    expect(capturedUpdateArgs, isA<Map>());

    final argsMap = capturedUpdateArgs as Map;

    // Verify draft key is present (regression guard).
    expect(argsMap.containsKey('draft'), isTrue,
        reason: 'Payload must contain draft key');

    // Verify the top-level durationSeconds key is present.
    expect(argsMap.containsKey('durationSeconds'), isTrue,
        reason: 'Payload must contain top-level durationSeconds key');

    // Verify the forwarded value matches the updated draft, not the initial one.
    // A stale initial value (6.0) would fail this assertion.
    final sentDuration = argsMap['durationSeconds'] as double;
    expect(sentDuration, closeTo(updatedDraft.durationSeconds, 0.001),
        reason:
            'durationSeconds in payload must equal updatedDraft.durationSeconds; '
            'got $sentDuration, expected ${updatedDraft.durationSeconds}');
  });
}
