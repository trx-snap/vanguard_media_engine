// vg_camera_session_readiness_test.dart
// vanguard_media_engine — Phase 10-C
//
// Unit tests for VGCameraSession prewarm readiness signals.
//
// Coverage:
//   RD-1: isCameraReady returns true when native returns true.
//   RD-2: isCameraReady returns false when native returns false.
//   RD-3: isCameraReady returns false when native returns null.
//   RD-4: isCameraReady returns false when session is disposed.
//   RD-5: isRecordingActive returns true when native returns true.
//   RD-6: isRecordingActive returns false when native returns false.
//   RD-7: isRecordingActive returns false when native returns null.
//   RD-8: isRecordingActive returns false when session is disposed.
//   RD-9: Method names sent over the channel are exactly 'isCameraReady'
//         and 'isRecordingActive'.
//
// Note on disposed-state tests (RD-4, RD-8):
//   VGCameraSession has a private constructor (_) and requires a native round-
//   trip through 'startCamera' to be created. To test disposed state without a
//   running native host we invoke startCamera through the mock handler (returning
//   a synthetic texture ID of 1), then call dispose() through the mock handler,
//   and finally assert that both readiness methods return false.
//   dispose() calls 'stopCamera'; we mock it as a no-op so _disposed is set.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_camera_session.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // ── Helper: create a VGCameraSession backed by a mock channel ───────────────

  /// Creates a session using the mock channel (returns textureId=1 for
  /// startCamera, no-op for stopCamera and stopCamera-related calls).
  Future<VGCameraSession> _makeSession({
    required Future<dynamic> Function(MethodCall call) readinessHandler,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startCamera') return 1; // synthetic textureId
      if (call.method == 'stopCamera') return null;
      return readinessHandler(call);
    });
    return VGCameraSession.create();
  }

  // ── RD-1: isCameraReady true ────────────────────────────────────────────────

  test('RD-1: isCameraReady returns true when native returns true', () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isCameraReady') return true;
      return null;
    });

    final ready = await session.isCameraReady();
    expect(ready, isTrue);
  });

  // ── RD-2: isCameraReady false ───────────────────────────────────────────────

  test('RD-2: isCameraReady returns false when native returns false', () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isCameraReady') return false;
      return null;
    });

    final ready = await session.isCameraReady();
    expect(ready, isFalse);
  });

  // ── RD-3: isCameraReady null ────────────────────────────────────────────────

  test('RD-3: isCameraReady returns false when native returns null', () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isCameraReady') return null;
      return null;
    });

    final ready = await session.isCameraReady();
    expect(ready, isFalse);
  });

  // ── RD-4: isCameraReady after dispose ──────────────────────────────────────

  test('RD-4: isCameraReady returns false when session is disposed', () async {
    final session = await _makeSession(readinessHandler: (call) async {
      // Should not be reached after dispose.
      if (call.method == 'isCameraReady') return true;
      return null;
    });

    await session.dispose();
    final ready = await session.isCameraReady();
    expect(ready, isFalse,
        reason: 'Disposed session must short-circuit to false without '
            'invoking the method channel');
  });

  // ── RD-5: isRecordingActive true ────────────────────────────────────────────

  test('RD-5: isRecordingActive returns true when native returns true',
      () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isRecordingActive') return true;
      return null;
    });

    final active = await session.isRecordingActive();
    expect(active, isTrue);
  });

  // ── RD-6: isRecordingActive false ───────────────────────────────────────────

  test('RD-6: isRecordingActive returns false when native returns false',
      () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isRecordingActive') return false;
      return null;
    });

    final active = await session.isRecordingActive();
    expect(active, isFalse);
  });

  // ── RD-7: isRecordingActive null ────────────────────────────────────────────

  test('RD-7: isRecordingActive returns false when native returns null',
      () async {
    final session = await _makeSession(readinessHandler: (call) async {
      if (call.method == 'isRecordingActive') return null;
      return null;
    });

    final active = await session.isRecordingActive();
    expect(active, isFalse);
  });

  // ── RD-8: isRecordingActive after dispose ───────────────────────────────────

  test('RD-8: isRecordingActive returns false when session is disposed',
      () async {
    final session = await _makeSession(readinessHandler: (call) async {
      // Should not be reached after dispose.
      if (call.method == 'isRecordingActive') return true;
      return null;
    });

    await session.dispose();
    final active = await session.isRecordingActive();
    expect(active, isFalse,
        reason: 'Disposed session must short-circuit to false without '
            'invoking the method channel');
  });

  // ── RD-9: Correct method names sent over the channel ────────────────────────

  test('RD-9: Method names are exactly isCameraReady and isRecordingActive',
      () async {
    final calls = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'startCamera') return 1;
      if (call.method == 'isCameraReady') return false;
      if (call.method == 'isRecordingActive') return false;
      return null;
    });

    final session = await VGCameraSession.create();
    await session.isCameraReady();
    await session.isRecordingActive();

    expect(calls, containsAll(['isCameraReady', 'isRecordingActive']),
        reason: 'Both readiness methods must send the exact expected strings');
    expect(calls.where((m) => m == 'isCameraReady').length, equals(1));
    expect(calls.where((m) => m == 'isRecordingActive').length, equals(1));
  });
}
