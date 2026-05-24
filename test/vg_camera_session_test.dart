// vg_camera_session_test.dart
// Vanguard Media Engine — Phase 6D.3
//
// Pure Dart unit tests for VGCameraSession and VGRecordingStats using a mock
// method channel. No Flutter engine or native code required — runs in pub test.
//
// Pattern mirrors vg_playback_session_test.dart exactly:
//   TestDefaultBinaryMessengerBinding mock on 'vanguard_media_engine'.
//
// Acceptance criteria covered:
//   CS-1  create() → correct sessionId and textureId from startCamera response
//   CS-2  dispose() idempotency — channel fires stopCamera exactly once
//   CS-3  takePhoto() after dispose throws StateError
//   CS-4  stopRecording() after dispose throws StateError
//   CS-5  startRecording() after dispose is a silent no-op
//   CS-6  stopRecording() returns typed VGRecordingStats
//   RS-1  VGRecordingStats.fromMap — path key normalisation
//   RS-2  VGRecordingStats.fromMap — numeric string coercion

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_camera_session.dart';
import 'package:vanguard_media_engine/vg_recording_stats.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mock channel harness
// ─────────────────────────────────────────────────────────────────────────────

/// All method calls recorded by the mock channel during a test.
final List<MethodCall> _log = [];

/// Configurable responses for specific method names.
final Map<String, Object?> _responses = {};

/// Installs a mock handler on the `vanguard_media_engine` channel.
/// Call in setUp().
void _installMock() {
  _log.clear();
  _responses.clear();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (MethodCall call) async {
      _log.add(call);
      return _responses[call.method];
    },
  );
}

/// Removes the mock handler. Call in tearDown().
void _removeMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Counts recorded calls with [name].
int _callCount(String name) => _log.where((c) => c.method == name).length;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_installMock);
  tearDown(_removeMock);

  // ── CS-1: create() ──────────────────────────────────────────────────────────

  group('VGCameraSession.create', () {
    test(
      'returns sessionId camera-<id> and textureId matching startCamera response',
      () async {
        // Arrange: native startCamera returns texture id 7.
        _responses['startCamera'] = 7;

        // Act
        final session = await VGCameraSession.create(
          position: VGCameraPosition.back,
          fps: 30,
        );

        // Assert
        expect(
          session.textureId,
          equals(7),
          reason: 'textureId must match the int returned by startCamera',
        );
        expect(
          session.sessionId,
          equals('camera-7'),
          reason: 'sessionId is synthesised as camera-<textureId>',
        );
        expect(
          _callCount('startCamera'),
          equals(1),
          reason: 'create() must fire exactly one startCamera call',
        );

        await session.dispose();
      },
    );

    test('forwards position=front as native position int 2', () async {
      _responses['startCamera'] = 3;
      final session = await VGCameraSession.create(
        position: VGCameraPosition.front,
      );
      final call = _log.firstWhere((c) => c.method == 'startCamera');
      expect(
        call.arguments['position'],
        equals(2),
        reason: 'VGCameraPosition.front must map to native position 2',
      );
      await session.dispose();
    });

    test('forwards position=back as native position int 1', () async {
      _responses['startCamera'] = 4;
      final session = await VGCameraSession.create(
        position: VGCameraPosition.back,
      );
      final call = _log.firstWhere((c) => c.method == 'startCamera');
      expect(
        call.arguments['position'],
        equals(1),
        reason: 'VGCameraPosition.back must map to native position 1',
      );
      await session.dispose();
    });

    test('throws StateError when native returns null', () async {
      _responses['startCamera'] = null;
      expect(
        () => VGCameraSession.create(),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError when native returns negative id', () async {
      _responses['startCamera'] = -1;
      expect(
        () => VGCameraSession.create(),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── CS-2: dispose idempotency ───────────────────────────────────────────────

  group('VGCameraSession.dispose idempotency', () {
    test('calling dispose() twice fires stopCamera exactly once', () async {
      _responses['startCamera'] = 10;
      final session = await VGCameraSession.create();

      await session.dispose();
      await session.dispose(); // second call must be a no-op

      expect(
        _callCount('stopCamera'),
        equals(1),
        reason:
            'dispose() must be idempotent: stopCamera fires exactly once '
            'regardless of how many times dispose() is called',
      );
    });

    test('calling dispose() three times fires stopCamera exactly once',
        () async {
      _responses['startCamera'] = 11;
      final session = await VGCameraSession.create();

      await session.dispose();
      await session.dispose();
      await session.dispose();

      expect(_callCount('stopCamera'), equals(1));
    });

    test('isDisposed is false before dispose and true after', () async {
      _responses['startCamera'] = 12;
      final session = await VGCameraSession.create();
      expect(session.isDisposed, isFalse);
      await session.dispose();
      expect(session.isDisposed, isTrue);
    });
  });

  // ── CS-3: takePhoto after dispose throws ────────────────────────────────────

  group('VGCameraSession.takePhoto after dispose', () {
    test('throws StateError — not a silent no-op', () async {
      _responses['startCamera'] = 20;
      final session = await VGCameraSession.create();
      await session.dispose();
      _log.clear();

      expect(
        () => session.takePhoto('/tmp/a.jpg'),
        throwsA(isA<StateError>()),
        reason: 'takePhoto on a disposed session must throw StateError',
      );
      expect(
        _callCount('takePhoto'),
        equals(0),
        reason: 'No takePhoto channel call must fire after dispose',
      );
    });
  });

  // ── CS-4: stopRecording after dispose throws ────────────────────────────────

  group('VGCameraSession.stopRecording after dispose', () {
    test('throws StateError — not a silent no-op', () async {
      _responses['startCamera'] = 30;
      final session = await VGCameraSession.create();
      await session.dispose();
      _log.clear();

      expect(
        () => session.stopRecording(),
        throwsA(isA<StateError>()),
        reason: 'stopRecording on a disposed session must throw StateError',
      );
      expect(
        _callCount('stopRecording'),
        equals(0),
        reason: 'No stopRecording channel call must fire after dispose',
      );
    });
  });

  // ── CS-5: startRecording after dispose is a silent no-op ───────────────────

  group('VGCameraSession.startRecording after dispose', () {
    test('does NOT invoke the channel', () async {
      _responses['startCamera'] = 40;
      final session = await VGCameraSession.create();
      await session.dispose();
      _log.clear();

      // Must not throw and must not fire the channel.
      await session.startRecording('/tmp/a.mp4');

      expect(
        _callCount('startRecording'),
        equals(0),
        reason:
            'startRecording on a disposed session must be a silent no-op: '
            'return type is void so StateError would be a contract change',
      );
    });
  });

  // ── CS-6: stopRecording returns typed VGRecordingStats ─────────────────────

  group('VGCameraSession.stopRecording returns VGRecordingStats', () {
    test('maps on-device smoke result to typed fields', () async {
      _responses['startCamera'] = 50;
      _responses['stopRecording'] = {
        'filePath': '/tmp/out.mp4',
        'droppedFrames': 0,
        'totalFrames': 346,
        'dropRate': 0.0,
      };

      final session = await VGCameraSession.create();
      final stats = await session.stopRecording();

      expect(stats, isA<VGRecordingStats>());
      expect(stats.filePath, equals('/tmp/out.mp4'));
      expect(stats.droppedFrames, equals(0));
      expect(stats.totalFrames, equals(346));
      expect(stats.dropRate, closeTo(0.0, 1e-9));
      // raw map is preserved
      expect(stats.raw['totalFrames'], equals(346));

      await session.dispose();
    });

    test('handles null native response gracefully — empty stats', () async {
      _responses['startCamera'] = 51;
      _responses['stopRecording'] = null;

      final session = await VGCameraSession.create();
      final stats = await session.stopRecording();

      expect(stats.filePath, isEmpty);
      expect(stats.droppedFrames, equals(0));
      expect(stats.totalFrames, equals(0));
      expect(stats.dropRate, closeTo(0.0, 1e-9));

      await session.dispose();
    });
  });

  // ── RS-1: VGRecordingStats.fromMap path key normalisation ──────────────────

  group('VGRecordingStats.fromMap — path key normalisation', () {
    test('reads filePath key', () {
      final stats = VGRecordingStats.fromMap({
        'filePath': '/tmp/video_a.mp4',
        'droppedFrames': 0,
        'totalFrames': 100,
        'dropRate': 0.0,
      });
      expect(stats.filePath, equals('/tmp/video_a.mp4'));
    });

    test('reads path key when filePath is absent', () {
      final stats = VGRecordingStats.fromMap({
        'path': '/tmp/video_b.mp4',
        'droppedFrames': 0,
        'totalFrames': 50,
        'dropRate': 0.0,
      });
      expect(stats.filePath, equals('/tmp/video_b.mp4'));
    });

    test('reads outputPath key when filePath and path are absent', () {
      final stats = VGRecordingStats.fromMap({
        'outputPath': '/tmp/video_c.mp4',
        'droppedFrames': 0,
        'totalFrames': 50,
        'dropRate': 0.0,
      });
      expect(stats.filePath, equals('/tmp/video_c.mp4'));
    });

    test('prefers filePath over path when both present', () {
      final stats = VGRecordingStats.fromMap({
        'filePath': '/tmp/primary.mp4',
        'path': '/tmp/secondary.mp4',
        'droppedFrames': 0,
        'totalFrames': 10,
        'dropRate': 0.0,
      });
      expect(stats.filePath, equals('/tmp/primary.mp4'));
    });

    test('returns empty string when no path key is present', () {
      final stats = VGRecordingStats.fromMap({
        'droppedFrames': 0,
        'totalFrames': 10,
        'dropRate': 0.0,
      });
      expect(stats.filePath, isEmpty);
    });
  });

  // ── RS-2: VGRecordingStats.fromMap numeric string coercion ─────────────────

  group('VGRecordingStats.fromMap — numeric string coercion', () {
    test('parses droppedFrames, totalFrames, dropRate from strings', () {
      final stats = VGRecordingStats.fromMap({
        'filePath': '/tmp/d.mp4',
        'droppedFrames': '2',
        'totalFrames': '100',
        'dropRate': '0.02',
      });
      expect(stats.droppedFrames, equals(2));
      expect(stats.totalFrames, equals(100));
      expect(stats.dropRate, closeTo(0.02, 1e-9));
    });

    test('normalises framesDropped key for droppedFrames', () {
      final stats = VGRecordingStats.fromMap({
        'framesDropped': 5,
        'totalFrames': 200,
        'dropRate': 0.025,
      });
      expect(stats.droppedFrames, equals(5));
    });

    test('normalises framesTotal key for totalFrames', () {
      final stats = VGRecordingStats.fromMap({
        'droppedFrames': 0,
        'framesTotal': 300,
        'dropRate': 0.0,
      });
      expect(stats.totalFrames, equals(300));
    });

    test('normalises frameDropRate key for dropRate', () {
      final stats = VGRecordingStats.fromMap({
        'droppedFrames': 1,
        'totalFrames': 50,
        'frameDropRate': 0.02,
      });
      expect(stats.dropRate, closeTo(0.02, 1e-9));
    });

    test('defaults all numerics to 0 / 0.0 when keys are absent', () {
      final stats = VGRecordingStats.fromMap({'filePath': '/tmp/e.mp4'});
      expect(stats.droppedFrames, equals(0));
      expect(stats.totalFrames, equals(0));
      expect(stats.dropRate, closeTo(0.0, 1e-9));
    });

    test('handles double value for droppedFrames by truncating', () {
      final stats = VGRecordingStats.fromMap({
        'droppedFrames': 3.9,
        'totalFrames': 100,
        'dropRate': 0.039,
      });
      // double.toInt() truncates toward zero — 3.9 → 3.
      expect(stats.droppedFrames, equals(3));
    });
  });

  // ── RS-3: VGRecordingStats value semantics ──────────────────────────────────

  group('VGRecordingStats value semantics', () {
    test('toJson produces canonical keys', () {
      final stats = VGRecordingStats.fromMap({
        'path': '/tmp/f.mp4',
        'dropped': 2,
        'framesTotal': 100,
        'frameDropRate': 0.02,
      });
      final json = stats.toJson();
      expect(json.keys.toSet(),
          equals({'filePath', 'droppedFrames', 'totalFrames', 'dropRate'}));
      expect(json['filePath'], equals('/tmp/f.mp4'));
      expect(json['droppedFrames'], equals(2));
      expect(json['totalFrames'], equals(100));
      expect(json['dropRate'], closeTo(0.02, 1e-9));
    });

    test('toString includes filePath and frame counts', () {
      final stats = VGRecordingStats(
        filePath: '/tmp/g.mp4',
        droppedFrames: 1,
        totalFrames: 200,
        dropRate: 0.005,
        raw: const {},
      );
      final s = stats.toString();
      expect(s, contains('/tmp/g.mp4'));
      expect(s, contains('1'));
      expect(s, contains('200'));
    });

    test('raw map is a defensive copy — mutations do not affect stats', () {
      final source = <String, dynamic>{
        'filePath': '/tmp/h.mp4',
        'droppedFrames': 0,
        'totalFrames': 10,
        'dropRate': 0.0,
      };
      final stats = VGRecordingStats.fromMap(source);
      // Mutate source after creation.
      source['filePath'] = '/tmp/mutated.mp4';
      // stats.raw must still hold the original value.
      expect(stats.raw['filePath'], equals('/tmp/h.mp4'));
    });
  });
}
