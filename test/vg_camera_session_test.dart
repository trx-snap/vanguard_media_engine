// vg_camera_session_test.dart
// Vanguard Media Engine — Phase 6D.4
//
// Pure Dart unit tests for VGCameraSession, VGRecordingStats, and
// VGPhotoCaptureResult using a mock method channel. No Flutter engine or
// native code required — runs in pub test.
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
//   CS-7  takePhotoResult() returns typed VGPhotoCaptureResult
//   RS-1  VGRecordingStats.fromMap — path key normalisation
//   RS-2  VGRecordingStats.fromMap — numeric string coercion
//   PC-1  VGPhotoCaptureResult.fromPath — canonical path
//   PC-2  VGPhotoCaptureResult.fromPath — empty string
//   PC-3  VGPhotoCaptureResult.fromMap — canonical keys
//   PC-4  VGPhotoCaptureResult.fromMap — alternative path keys
//   PC-5  VGPhotoCaptureResult.fromMap — alternative width/height/size/format keys
//   PC-6  VGPhotoCaptureResult.fromMap — numeric string coercion
//   PC-7  VGPhotoCaptureResult.fromMap — missing keys default safely
//   PC-8  VGPhotoCaptureResult.toJson — canonical keys
//   PC-9  VGPhotoCaptureResult.toString — includes filePath and dimensions
//   PC-10 VGPhotoCaptureResult — equality and hashCode
//   PC-11 VGPhotoCaptureResult — raw map is defensively copied
//   PC-12 VGPhotoCaptureResult.fromMap — prefers primary key over alternative

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_camera_session.dart';
import 'package:vanguard_media_engine/vg_dual_camera_descriptor.dart';
import 'package:vanguard_media_engine/vg_filter_spec.dart';
import 'package:vanguard_media_engine/vg_graph_transaction.dart';
import 'package:vanguard_media_engine/vg_live_preview_config.dart';
import 'package:vanguard_media_engine/vg_preset_descriptor.dart';
import 'package:vanguard_media_engine/vg_recording_stats.dart';
import 'package:vanguard_media_engine/vg_photo_capture_result.dart';
import 'package:vanguard_media_engine/vg_multicam_recording_stats.dart';

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
      .setMockMethodCallHandler(const MethodChannel('vanguard_media_engine'), (
        MethodCall call,
      ) async {
        _log.add(call);
        return _responses[call.method];
      });
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
      expect(() => VGCameraSession.create(), throwsA(isA<StateError>()));
    });

    test('throws StateError when native returns negative id', () async {
      _responses['startCamera'] = -1;
      expect(() => VGCameraSession.create(), throwsA(isA<StateError>()));
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

    test(
      'calling dispose() three times fires stopCamera exactly once',
      () async {
        _responses['startCamera'] = 11;
        final session = await VGCameraSession.create();

        await session.dispose();
        await session.dispose();
        await session.dispose();

        expect(_callCount('stopCamera'), equals(1));
      },
    );

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
      expect(
        json.keys.toSet(),
        equals({'filePath', 'droppedFrames', 'totalFrames', 'dropRate'}),
      );
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

  // ── CS-7: takePhotoResult returns typed VGPhotoCaptureResult ──────────────

  group('VGCameraSession.takePhotoResult returns VGPhotoCaptureResult', () {
    test(
      'wraps mocked bare path in typed result with correct filePath',
      () async {
        _responses['startCamera'] = 21;
        _responses['takePhoto'] = '/var/mobile/Caches/snap_001.jpg';

        final session = await VGCameraSession.create();
        final result = await session.takePhotoResult(
          '/var/mobile/Caches/snap_001.jpg',
        );

        expect(result, isA<VGPhotoCaptureResult>());
        expect(
          result.filePath,
          equals('/var/mobile/Caches/snap_001.jpg'),
          reason: 'filePath must equal the path returned by the native handler',
        );
        // Metadata defaults (native does not return these today).
        expect(result.width, equals(0));
        expect(result.height, equals(0));
        expect(result.sizeBytes, equals(0));
        expect(result.format, equals('jpeg'));
        // raw contains at minimum the filePath key.
        expect(
          result.raw['filePath'],
          equals('/var/mobile/Caches/snap_001.jpg'),
        );

        await session.dispose();
      },
    );

    test('raw map is populated from fromPath synthetic map', () async {
      _responses['startCamera'] = 22;
      _responses['takePhoto'] = '/var/mobile/Caches/snap_002.jpg';

      final session = await VGCameraSession.create();
      final result = await session.takePhotoResult(
        '/var/mobile/Caches/snap_002.jpg',
      );

      expect(result.raw.containsKey('filePath'), isTrue);
      expect(result.raw['filePath'], equals('/var/mobile/Caches/snap_002.jpg'));

      await session.dispose();
    });

    test('takePhotoResult after dispose throws StateError', () async {
      _responses['startCamera'] = 23;
      final session = await VGCameraSession.create();
      await session.dispose();

      expect(
        () => session.takePhotoResult('/tmp/snap.jpg'),
        throwsA(isA<StateError>()),
        reason: 'takePhotoResult delegates to takePhoto which guards dispose',
      );
    });
  });

  // ── PC-1 to PC-12: VGPhotoCaptureResult unit tests ────────────────────────

  group('VGPhotoCaptureResult.fromPath', () {
    test('PC-1: canonical path sets all fields correctly', () {
      final res = VGPhotoCaptureResult.fromPath('/var/mobile/img.jpg');
      expect(res.filePath, equals('/var/mobile/img.jpg'));
      expect(res.width, equals(0));
      expect(res.height, equals(0));
      expect(res.sizeBytes, equals(0));
      expect(res.format, equals('jpeg'));
      expect(res.raw['filePath'], equals('/var/mobile/img.jpg'));
    });

    test('PC-2: empty string path — format is empty, not jpeg', () {
      final res = VGPhotoCaptureResult.fromPath('');
      expect(res.filePath, isEmpty);
      expect(res.width, equals(0));
      expect(res.height, equals(0));
      expect(res.sizeBytes, equals(0));
      expect(res.format, isEmpty);
      expect(res.raw['filePath'], isEmpty);
    });
  });

  group('VGPhotoCaptureResult.fromMap', () {
    test('PC-3: canonical keys are read correctly', () {
      final res = VGPhotoCaptureResult.fromMap({
        'filePath': '/var/mobile/img.jpg',
        'width': 1920,
        'height': 1080,
        'sizeBytes': 2048,
        'format': 'png',
      });
      expect(res.filePath, equals('/var/mobile/img.jpg'));
      expect(res.width, equals(1920));
      expect(res.height, equals(1080));
      expect(res.sizeBytes, equals(2048));
      expect(res.format, equals('png'));
    });

    test('PC-4: alternative path keys — path and outputPath', () {
      final res1 = VGPhotoCaptureResult.fromMap({'path': '/path/1.jpg'});
      expect(res1.filePath, equals('/path/1.jpg'));

      final res2 = VGPhotoCaptureResult.fromMap({'outputPath': '/path/2.jpg'});
      expect(res2.filePath, equals('/path/2.jpg'));
    });

    test('PC-5: alternative width/height/size/format keys', () {
      final res = VGPhotoCaptureResult.fromMap({
        'imageWidth': 640,
        'imageHeight': 480,
        'fileSize': 1024,
        'imageFormat': 'webp',
      });
      expect(res.width, equals(640));
      expect(res.height, equals(480));
      expect(res.sizeBytes, equals(1024));
      expect(res.format, equals('webp'));
    });

    test('PC-6: numeric string coercion', () {
      final res = VGPhotoCaptureResult.fromMap({
        'width': '1280',
        'height': '720',
        'sizeBytes': '500000',
      });
      expect(res.width, equals(1280));
      expect(res.height, equals(720));
      expect(res.sizeBytes, equals(500000));
    });

    test('PC-7: missing keys default safely to 0 / empty', () {
      final res = VGPhotoCaptureResult.fromMap({});
      expect(res.filePath, isEmpty);
      expect(res.width, equals(0));
      expect(res.height, equals(0));
      expect(res.sizeBytes, equals(0));
      expect(res.format, isEmpty);
    });

    test('PC-12: prefers primary key over alternative key', () {
      final res = VGPhotoCaptureResult.fromMap({
        'filePath': 'primary.jpg',
        'path': 'alternative.jpg',
        'width': 100,
        'imageWidth': 200,
      });
      expect(res.filePath, equals('primary.jpg'));
      expect(res.width, equals(100));
    });
  });

  group('VGPhotoCaptureResult value semantics', () {
    test('PC-8: toJson returns canonical keys and values', () {
      final res = VGPhotoCaptureResult(
        filePath: '/var/mobile/img.jpg',
        width: 100,
        height: 200,
        sizeBytes: 300,
        format: 'gif',
        raw: const {},
      );
      expect(
        res.toJson(),
        equals({
          'filePath': '/var/mobile/img.jpg',
          'width': 100,
          'height': 200,
          'sizeBytes': 300,
          'format': 'gif',
        }),
      );
    });

    test('PC-9: toString includes filePath and dimensions', () {
      final res = VGPhotoCaptureResult(
        filePath: '/var/mobile/img.jpg',
        width: 1920,
        height: 1080,
        sizeBytes: 12345,
        format: 'jpeg',
        raw: const {},
      );
      final s = res.toString();
      expect(s, contains('/var/mobile/img.jpg'));
      expect(s, contains('1920x1080'));
    });

    test('PC-10: equality and hashCode match on same typed fields', () {
      final a = VGPhotoCaptureResult(
        filePath: 'img.jpg',
        width: 10,
        height: 20,
        sizeBytes: 30,
        format: 'jpeg',
        raw: const {},
      );
      // raw differs — equality ignores raw.
      final b = VGPhotoCaptureResult(
        filePath: 'img.jpg',
        width: 10,
        height: 20,
        sizeBytes: 30,
        format: 'jpeg',
        raw: const {'extra': 1},
      );
      final c = VGPhotoCaptureResult(
        filePath: 'other.jpg',
        width: 10,
        height: 20,
        sizeBytes: 30,
        format: 'jpeg',
        raw: const {},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test(
      'PC-11: raw map is a defensive copy — mutations do not affect result',
      () {
        final source = <String, dynamic>{'filePath': 'a.jpg', 'width': 10};
        final res = VGPhotoCaptureResult.fromMap(source);
        source['width'] = 999;
        expect(res.raw['width'], equals(10));
      },
    );
  });

  // ── Phase 6C.2A: transaction dispatch ──────────────────────────────────────
  //
  // Acceptance criteria:
  //   TX-1   newTransaction() returns empty VGGraphTransaction
  //   TX-2   newTransaction() makes zero calls to mock channel
  //   TX-3   prepareTransaction() invokes builder and returns committed payload
  //   TX-4   prepareTransaction() clamps values through descriptors
  //   TX-5   prepareTransaction() makes zero calls to mock channel
  //   TX-6   prepareTransaction() propagates ArgumentError for invalid params
  //   TX-7   applyTransaction() with preset-only payload dispatches applyGraphTransaction
  //   TX-8   applyTransaction() with empty payload makes zero channel calls
  //   TX-9   applyTransaction() propagates PlatformException from native
  //   TX-10  applyTransaction() with hot-only payload still dispatches to channel

  group('VGCameraSession — transaction ergonomics (Phase 6C.1C)', () {
    // These tests do not require a real native session.  We call the transaction
    // helpers directly on a synthetically constructed session instance.
    // The mock channel is already installed via setUp(_installMock).

    // Build a session by going through the real create() path so we have a
    // valid VGCameraSession without reflection.
    Future<VGCameraSession> makeSession(int textureId) async {
      _responses['startCamera'] = textureId;
      return VGCameraSession.create();
    }

    test(
      'TX-1  newTransaction() returns an empty VGGraphTransaction',
      () async {
        final session = await makeSession(100);
        final tx = session.newTransaction();
        expect(tx, isA<VGGraphTransaction>());
        expect(tx.isEmpty, isTrue);
        expect(tx.hasHotParameters, isFalse);
        expect(tx.hasWarmParameters, isFalse);
        expect(tx.requiresRebuild, isFalse);
        await session.dispose();
      },
    );

    test(
      'TX-2  newTransaction() makes zero calls to the mock method channel',
      () async {
        final session = await makeSession(101);
        _log.clear(); // reset after create()
        session.newTransaction();
        expect(
          _log,
          isEmpty,
          reason: 'newTransaction() must not invoke any method channel',
        );
        await session.dispose();
      },
    );

    test(
      'TX-3  prepareTransaction() invokes builder and returns committed payload',
      () async {
        final session = await makeSession(102);
        final payload = session.prepareTransaction((tx) {
          tx.setParameter('beauty', 'intensity', 0.7);
          tx.setParameter('lut', 'intensity', 0.3);
        });
        expect(payload, isA<VGGraphTransactionPayload>());
        expect(payload.isEmpty, isFalse);
        expect(payload.parameterUpdates.containsKey('beauty'), isTrue);
        expect(payload.parameterUpdates.containsKey('lut'), isTrue);
        expect(payload.parameterUpdates['beauty']!['intensity'], 0.7);
        expect(payload.parameterUpdates['lut']!['intensity'], 0.3);
        expect(payload.hasHotParameters, isTrue);
        await session.dispose();
      },
    );

    test(
      'TX-4  prepareTransaction() clamps values through descriptor bounds',
      () async {
        final session = await makeSession(103);
        final payload = session.prepareTransaction((tx) {
          tx.setParameter('beauty', 'intensity', 9.9); // max 1.0
        });
        expect(
          payload.parameterUpdates['beauty']!['intensity'],
          equals(1.0),
          reason: 'Values above max must be clamped to max by the descriptor',
        );
        await session.dispose();
      },
    );

    test(
      'TX-5  prepareTransaction() makes zero calls to the mock method channel',
      () async {
        final session = await makeSession(104);
        _log.clear(); // reset after create()
        session.prepareTransaction((tx) {
          tx.setParameter('beauty', 'intensity', 0.5);
        });
        expect(
          _log,
          isEmpty,
          reason: 'prepareTransaction() must not invoke any method channel',
        );
        await session.dispose();
      },
    );

    test(
      'TX-6  prepareTransaction() propagates ArgumentError for unknown params',
      () async {
        final session = await makeSession(105);
        expect(
          () => session.prepareTransaction((tx) {
            tx.setParameter('ghostEffect', 'intensity', 0.5);
          }),
          throwsArgumentError,
          reason:
              'Unknown effect type must throw ArgumentError from the transaction',
        );
        await session.dispose();
      },
    );

    test(
      'TX-7  applyTransaction() with preset-only payload dispatches applyGraphTransaction once',
      () async {
        final session = await makeSession(106);
        // Build a preset-only payload (requiresRebuild=true, parameterUpdates empty).
        final preset = VGPresetDescriptor(
          id: 'test-preset',
          name: 'Test Preset',
          filterStack: [VGFilterSpecs.beauty(intensity: 0.6)],
        );
        final payload = session.prepareTransaction((tx) {
          tx.applyPreset(preset);
        });
        expect(payload.requiresRebuild, isTrue);
        expect(payload.parameterUpdates, isEmpty);

        _log.clear(); // reset after create() + prepareTransaction()
        // Mock returns null (success) for applyGraphTransaction.
        _responses['applyGraphTransaction'] = null;
        await session.applyTransaction(payload);

        expect(
          _log,
          hasLength(1),
          reason:
              'applyTransaction() must invoke applyGraphTransaction exactly once',
        );
        expect(
          _log.first.method,
          equals('applyGraphTransaction'),
          reason: 'The dispatched method must be applyGraphTransaction',
        );
        expect(
          _log.first.arguments,
          equals(payload.toJson()),
          reason: 'The dispatched arguments must equal payload.toJson()',
        );
        await session.dispose();
      },
    );

    test(
      'TX-8  applyTransaction() with empty payload makes zero channel calls',
      () async {
        final session = await makeSession(107);
        // An empty transaction: no preset, no parameters.
        final tx = VGGraphTransaction();
        final emptyPayload = tx.commit();
        expect(emptyPayload.isEmpty, isTrue);

        _log.clear(); // reset after create()
        await session.applyTransaction(emptyPayload);

        expect(
          _log,
          isEmpty,
          reason:
              'applyTransaction() with an empty payload must not invoke any '
              'method channel — it is a Dart-side no-op',
        );
        await session.dispose();
      },
    );

    test(
      'TX-9  applyTransaction() propagates PlatformException from native',
      () async {
        final session = await makeSession(108);
        final preset = VGPresetDescriptor(
          id: 'bad-preset',
          name: 'Bad Preset',
          filterStack: [VGFilterSpecs.beauty(intensity: 0.5)],
        );
        final payload = session.prepareTransaction((tx) {
          tx.applyPreset(preset);
        });

        // Mock native rejecting with UNSUPPORTED_TRANSACTION_POLICY.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('vanguard_media_engine'),
              (MethodCall call) async {
                _log.add(call);
                if (call.method == 'applyGraphTransaction') {
                  throw PlatformException(
                    code: 'UNSUPPORTED_TRANSACTION_POLICY',
                    message:
                        'In-place parameter updates are not yet supported.',
                  );
                }
                return _responses[call.method];
              },
            );

        expect(
          () async => session.applyTransaction(payload),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'UNSUPPORTED_TRANSACTION_POLICY',
            ),
          ),
          reason:
              'applyTransaction() must propagate PlatformException thrown by native',
        );
        await session.dispose();
      },
    );

    test(
      'TX-10 applyTransaction() with hot-only payload still dispatches to channel',
      () async {
        // Dart dispatches unconditionally for non-empty payloads.
        // Policy rejection is owned by the native side, not Dart.
        final session = await makeSession(109);
        final payload = session.prepareTransaction((tx) {
          tx.setParameter('beauty', 'intensity', 0.8); // hot policy
        });
        expect(payload.hasHotParameters, isTrue);
        expect(payload.parameterUpdates, isNotEmpty);

        _log.clear(); // reset after create() + prepareTransaction()
        _responses['applyGraphTransaction'] = null;
        await session.applyTransaction(payload);

        expect(
          _log,
          hasLength(1),
          reason:
              'Dart must dispatch applyGraphTransaction even for hot-policy payloads; '
              'native is responsible for rejecting unsupported policies',
        );
        expect(_log.first.method, equals('applyGraphTransaction'));
        await session.dispose();
      },
    );

    // ── Phase 6C.2B: hot parameter routing ─────────────────────────────────
    //
    // TX-11: hot-only beauty.intensity dispatches exactly once to channel.
    // TX-12: warm param (beauty.radius) dispatches, mock rejects UNSUPPORTED_TRANSACTION_POLICY.
    // TX-13: unknown effect (lut.intensity) dispatches, mock rejects UNSUPPORTED_TRANSACTION_POLICY.
    //
    // Dart does NOT locally filter by policy — that is native's responsibility.
    // These tests verify Dart dispatch shape and PlatformException propagation.

    test(
      'TX-11 applyTransaction() with hot beauty.intensity dispatches once with correct payload',
      () async {
        final session = await makeSession(110);
        // Construct a hot-only beauty.intensity payload.
        final payload = session.prepareTransaction((tx) {
          tx.setParameter('beauty', 'intensity', 0.65); // hot policy
        });
        expect(payload.hasHotParameters, isTrue);
        expect(payload.requiresRebuild, isFalse);
        expect(
          payload.parameterUpdates,
          equals({
            'beauty': {'intensity': 0.65},
          }),
        );

        _log.clear();
        _responses['applyGraphTransaction'] = null; // mock: native succeeds
        await session.applyTransaction(payload);

        expect(
          _log,
          hasLength(1),
          reason:
              'applyTransaction() must dispatch applyGraphTransaction exactly once',
        );
        expect(_log.first.method, equals('applyGraphTransaction'));
        // Payload must carry parameterUpdates with beauty.intensity.
        final dispatched = _log.first.arguments as Map;
        expect(dispatched['requiresRebuild'], isFalse);
        expect(
          (dispatched['parameterUpdates'] as Map)['beauty'],
          equals({'intensity': 0.65}),
          reason: 'parameterUpdates must carry beauty.intensity = 0.65',
        );
        await session.dispose();
      },
    );

    test('TX-12 applyTransaction() with warm param (beauty.radius) dispatches and '
        'propagates UNSUPPORTED_TRANSACTION_POLICY from native', () async {
      final session = await makeSession(111);
      // beauty.radius has warm policy — Dart will still dispatch it;
      // native is expected to reject with UNSUPPORTED_TRANSACTION_POLICY.
      final payload = session.prepareTransaction((tx) {
        tx.setParameter('beauty', 'radius', 3.0); // warm policy
      });
      expect(payload.hasWarmParameters, isTrue);
      expect(payload.requiresRebuild, isFalse);

      // Install a mock that rejects the channel call with the expected error.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('vanguard_media_engine'),
            (MethodCall call) async {
              _log.add(call);
              if (call.method == 'applyGraphTransaction') {
                throw PlatformException(
                  code: 'UNSUPPORTED_TRANSACTION_POLICY',
                  message:
                      "applyHotParameterUpdates: only 'intensity' is a supported "
                      'hot parameter for beauty in Phase 6C.2B.',
                );
              }
              return _responses[call.method];
            },
          );

      await expectLater(
        () async => session.applyTransaction(payload),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'UNSUPPORTED_TRANSACTION_POLICY',
          ),
        ),
        reason:
            'applyTransaction() must propagate UNSUPPORTED_TRANSACTION_POLICY '
            'from the native channel for warm parameters',
      );

      // Confirm Dart dispatched the channel call.
      expect(
        _log.where((c) => c.method == 'applyGraphTransaction').length,
        equals(1),
        reason:
            'Dart must have dispatched applyGraphTransaction before rejection',
      );
      await session.dispose();
    });

    test('TX-13 applyTransaction() with unknown effect (lut.intensity) dispatches and '
        'propagates UNSUPPORTED_TRANSACTION_POLICY from native', () async {
      final session = await makeSession(112);
      // lut.intensity has hot policy in the catalog, but native currently
      // only supports beauty.intensity. Dart dispatches; native rejects.
      final payload = session.prepareTransaction((tx) {
        tx.setParameter(
          'lut',
          'intensity',
          0.5,
        ); // hot policy, but unsupported by 6C.2B native
      });
      expect(payload.hasHotParameters, isTrue);
      expect(payload.requiresRebuild, isFalse);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('vanguard_media_engine'),
            (MethodCall call) async {
              _log.add(call);
              if (call.method == 'applyGraphTransaction') {
                throw PlatformException(
                  code: 'UNSUPPORTED_TRANSACTION_POLICY',
                  message:
                      "applyHotParameterUpdates: only {beauty:{intensity}} is supported "
                      'in Phase 6C.2B.',
                );
              }
              return _responses[call.method];
            },
          );

      await expectLater(
        () async => session.applyTransaction(payload),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'UNSUPPORTED_TRANSACTION_POLICY',
          ),
        ),
        reason:
            'applyTransaction() must propagate UNSUPPORTED_TRANSACTION_POLICY '
            'from the native channel for unsupported effect types',
      );

      expect(
        _log.where((c) => c.method == 'applyGraphTransaction').length,
        equals(1),
        reason:
            'Dart must have dispatched applyGraphTransaction before rejection',
      );
      await session.dispose();
    });
  });

  // ── MC-1 to MC-3: VGCameraSession.isMultiCamSupported ─────────────────────
  //
  // Acceptance criteria:
  //   MC-1  isMultiCamSupported() invokes 'isMultiCamSupported' on the channel
  //   MC-2  returns true when native returns true
  //   MC-3  returns false when native returns false
  //   MC-4  returns false (not throws) on PlatformException
  //   MC-5  isMultiCamSupported() is callable without an active camera session

  group('VGCameraSession.isMultiCamSupported', () {
    test('MC-1: dispatches isMultiCamSupported to the method channel', () async {
      _responses['isMultiCamSupported'] = true;

      await VGCameraSession.isMultiCamSupported();

      expect(
        _callCount('isMultiCamSupported'),
        equals(1),
        reason: 'isMultiCamSupported() must invoke the channel exactly once',
      );
    });

    test('MC-2: returns true when native responds true', () async {
      _responses['isMultiCamSupported'] = true;

      final result = await VGCameraSession.isMultiCamSupported();

      expect(
        result,
        isTrue,
        reason: 'must return true when native returns true',
      );
    });

    test('MC-3: returns false when native responds false', () async {
      _responses['isMultiCamSupported'] = false;

      final result = await VGCameraSession.isMultiCamSupported();

      expect(
        result,
        isFalse,
        reason: 'must return false when native returns false',
      );
    });

    test(
      'MC-4: returns false (does not throw) on PlatformException',
      () async {
        // Simulate Android where the handler is absent (FlutterMethodNotImplemented).
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('vanguard_media_engine'),
          (MethodCall call) async {
            if (call.method == 'isMultiCamSupported') {
              throw PlatformException(
                code: 'NOT_IMPLEMENTED',
                message: 'isMultiCamSupported not available on this platform',
              );
            }
            return _responses[call.method];
          },
        );

        final result = await VGCameraSession.isMultiCamSupported();

        expect(
          result,
          isFalse,
          reason:
              'must return false gracefully on PlatformException (e.g. Android)',
        );

        // Restore standard mock after this test.
        _installMock();
      },
    );

    test(
      'MC-5: callable as a static method without an active camera session',
      () async {
        // This test deliberately does NOT call VGCameraSession.create().
        // The method is static and must work at any lifecycle point.
        _responses['isMultiCamSupported'] = false;

        // Should complete without error.
        final result = await VGCameraSession.isMultiCamSupported();
        expect(result, isFalse);
      },
    );
  });

  // ── DS-1 to DS-7: VGCameraSession.getMultiCamDeviceSets ───────────────────
  //
  // Acceptance criteria:
  //   DS-1  dispatches 'getMultiCamDeviceSets' to the method channel
  //   DS-2  returns parsed device sets when native responds with valid data
  //   DS-3  device maps preserve uniqueId, localizedName, position, deviceType
  //   DS-4  returns empty list when native responds with empty list
  //   DS-5  returns empty list when native responds with null
  //   DS-6  returns empty list (does not throw) on PlatformException
  //   DS-7  callable as static method without an active camera session

  group('VGCameraSession.getMultiCamDeviceSets', () {
    // Canonical mock device set used across tests.
    final kMockDeviceSets = [
      [
        {
          'uniqueId': 'AVCaptureDevice-Front-001',
          'localizedName': 'Front Camera',
          'position': 'front',
          'deviceType': 'builtInTrueDepthCamera',
          'modelId': 'iPhone16,2',
          'manufacturer': 'Apple Inc.',
        },
        {
          'uniqueId': 'AVCaptureDevice-Back-001',
          'localizedName': 'Back Camera',
          'position': 'back',
          'deviceType': 'builtInWideAngleCamera',
          'modelId': 'iPhone16,2',
          'manufacturer': 'Apple Inc.',
        },
      ],
      [
        {
          'uniqueId': 'AVCaptureDevice-Front-001',
          'localizedName': 'Front Camera',
          'position': 'front',
          'deviceType': 'builtInTrueDepthCamera',
          'modelId': 'iPhone16,2',
          'manufacturer': 'Apple Inc.',
        },
        {
          'uniqueId': 'AVCaptureDevice-Back-Ultra-001',
          'localizedName': 'Back Ultra Wide Camera',
          'position': 'back',
          'deviceType': 'builtInUltraWideCamera',
          'modelId': 'iPhone16,2',
          'manufacturer': 'Apple Inc.',
        },
      ],
    ];

    test('DS-1: dispatches getMultiCamDeviceSets to the method channel',
        () async {
      _responses['getMultiCamDeviceSets'] = kMockDeviceSets;

      await VGCameraSession.getMultiCamDeviceSets();

      expect(
        _callCount('getMultiCamDeviceSets'),
        equals(1),
        reason:
            'getMultiCamDeviceSets() must invoke the channel exactly once',
      );
    });

    test('DS-2: returns parsed device sets when native responds with valid data',
        () async {
      _responses['getMultiCamDeviceSets'] = kMockDeviceSets;

      final result = await VGCameraSession.getMultiCamDeviceSets();

      expect(
        result.length,
        equals(2),
        reason: 'must return 2 device sets matching mock data',
      );
      expect(
        result[0].length,
        equals(2),
        reason: 'first set must contain 2 devices',
      );
      expect(
        result[1].length,
        equals(2),
        reason: 'second set must contain 2 devices',
      );
    });

    test(
        'DS-3: device maps preserve uniqueId, localizedName, position, '
        'and deviceType', () async {
      _responses['getMultiCamDeviceSets'] = kMockDeviceSets;

      final result = await VGCameraSession.getMultiCamDeviceSets();

      final firstDevice = result[0][0];
      expect(
        firstDevice['uniqueId'],
        equals('AVCaptureDevice-Front-001'),
        reason: 'uniqueId must be preserved',
      );
      expect(
        firstDevice['localizedName'],
        equals('Front Camera'),
        reason: 'localizedName must be preserved',
      );
      expect(
        firstDevice['position'],
        equals('front'),
        reason: 'position must be preserved',
      );
      expect(
        firstDevice['deviceType'],
        equals('builtInTrueDepthCamera'),
        reason: 'deviceType must be preserved',
      );

      final secondDevice = result[0][1];
      expect(
        secondDevice['position'],
        equals('back'),
        reason: 'back position must be preserved',
      );
      expect(
        secondDevice['deviceType'],
        equals('builtInWideAngleCamera'),
        reason: 'builtInWideAngleCamera deviceType must be preserved',
      );
    });

    test('DS-4: returns empty list when native responds with empty list',
        () async {
      _responses['getMultiCamDeviceSets'] = <Object?>[];

      final result = await VGCameraSession.getMultiCamDeviceSets();

      expect(
        result,
        isEmpty,
        reason: 'must return empty list when native returns empty list '
            '(device does not support MultiCam)',
      );
    });

    test('DS-5: returns empty list when native responds with null', () async {
      _responses['getMultiCamDeviceSets'] = null;

      final result = await VGCameraSession.getMultiCamDeviceSets();

      expect(
        result,
        isEmpty,
        reason: 'must return empty list gracefully when native returns null',
      );
    });

    test(
      'DS-6: returns empty list (does not throw) on PlatformException',
      () async {
        // Simulate Android where the handler is absent.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('vanguard_media_engine'),
          (MethodCall call) async {
            if (call.method == 'getMultiCamDeviceSets') {
              throw PlatformException(
                code: 'NOT_IMPLEMENTED',
                message: 'getMultiCamDeviceSets not available on Android',
              );
            }
            return _responses[call.method];
          },
        );

        final result = await VGCameraSession.getMultiCamDeviceSets();

        expect(
          result,
          isEmpty,
          reason:
              'must return empty list gracefully on PlatformException (e.g. Android)',
        );

        // Restore standard mock after this test.
        _installMock();
      },
    );

    test(
      'DS-7: callable as a static method without an active camera session',
      () async {
        // This test deliberately does NOT call VGCameraSession.create().
        // The method is static and must work at any lifecycle point.
        _responses['getMultiCamDeviceSets'] = <Object?>[];

        // Should complete without error.
        final result = await VGCameraSession.getMultiCamDeviceSets();
        expect(result, isEmpty);
      },
    );
  });

  // ── MC-3: VGCameraSession.measureMultiCamHardwareCost ─────────────────────
  //
  // Tests for the non-running MultiCam hardware cost diagnostic.
  // Confirms the channel dispatch, argument passing, result parsing,
  // and null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  group('VGCameraSession.measureMultiCamHardwareCost', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    test(
      'MC3-1 dispatches channel method with frontDeviceId and backDeviceId',
      () async {
        _responses['measureMultiCamHardwareCost'] = <Object?, Object?>{
          'hardwareCost': 0.72,
          'isWithinBudget': true,
        };

        await VGCameraSession.measureMultiCamHardwareCost(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1);
        expect(_log.first.method, 'measureMultiCamHardwareCost');
        expect(_log.first.arguments['frontDeviceId'], kFrontId);
        expect(_log.first.arguments['backDeviceId'],  kBackId);
      },
    );

    test(
      'MC3-2 parses valid native response into VGMultiCamCostReport',
      () async {
        _responses['measureMultiCamHardwareCost'] = <Object?, Object?>{
          'hardwareCost': 0.72,
          'isWithinBudget': true,
        };

        final report = await VGCameraSession.measureMultiCamHardwareCost(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull);
        expect(report!.hardwareCost, closeTo(0.72, 0.0001));
        expect(report.isWithinBudget, isTrue);
      },
    );

    test(
      'MC3-3 returns null on PlatformException',
      () async {
        _responses['measureMultiCamHardwareCost'] = PlatformException(
          code: 'UNSUPPORTED',
          message: 'MultiCam not available on Android',
        );

        final report = await VGCameraSession.measureMultiCamHardwareCost(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull);
      },
    );

    test(
      'MC3-4 returns null on null native response',
      () async {
        _responses['measureMultiCamHardwareCost'] = null;

        final report = await VGCameraSession.measureMultiCamHardwareCost(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull);
      },
    );

    test(
      'MC3-5 VGMultiCamCostReport.fromMap returns within budget for hardwareCost <= 1.0',
      () {
        final report = VGMultiCamCostReport.fromMap(<Object?, Object?>{
          'hardwareCost': 0.72,
          'isWithinBudget': true,
        });

        expect(report, isNotNull);
        expect(report!.hardwareCost, closeTo(0.72, 0.0001));
        expect(report.isWithinBudget, isTrue);
      },
    );

    test(
      'MC3-6 VGMultiCamCostReport.fromMap returns not within budget for hardwareCost > 1.0',
      () {
        final report = VGMultiCamCostReport.fromMap(<Object?, Object?>{
          'hardwareCost': 1.23,
          'isWithinBudget': false,
        });

        expect(report, isNotNull);
        expect(report!.hardwareCost, closeTo(1.23, 0.0001));
        expect(report.isWithinBudget, isFalse);
      },
    );
  });

  // ── MC-4: VGCameraSession.runMultiCamStreamingDiagnostic ──────────────────
  //
  // Tests for the running MultiCam streaming diagnostic.
  // Confirms channel dispatch, argument passing, result parsing,
  // FPS computation, and null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  group('VGCameraSession.runMultiCamStreamingDiagnostic', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    test(
      'MC4-1 runMultiCamStreamingDiagnostic dispatches channel method with frontDeviceId and backDeviceId',
      () async {
        _responses['runMultiCamStreamingDiagnostic'] = <Object?, Object?>{
          'frontFramesReceived':    90,
          'backFramesReceived':     87,
          'peakSystemPressureCost': 0.42,
          'hardwareCost':           0.50,
          'durationSeconds':        3.01,
        };

        await VGCameraSession.runMultiCamStreamingDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1);
        expect(_log.first.method, 'runMultiCamStreamingDiagnostic');
        expect(_log.first.arguments['frontDeviceId'], kFrontId);
        expect(_log.first.arguments['backDeviceId'],  kBackId);
      },
    );

    test(
      'MC4-2 runMultiCamStreamingDiagnostic parses valid native response into VGMultiCamStreamingReport',
      () async {
        _responses['runMultiCamStreamingDiagnostic'] = <Object?, Object?>{
          'frontFramesReceived':    90,
          'backFramesReceived':     87,
          'peakSystemPressureCost': 0.42,
          'hardwareCost':           0.50,
          'durationSeconds':        3.01,
        };

        final report = await VGCameraSession.runMultiCamStreamingDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull);
        expect(report!.frontFramesReceived,    90);
        expect(report.backFramesReceived,      87);
        expect(report.peakSystemPressureCost,  closeTo(0.42, 0.0001));
        expect(report.hardwareCost,            closeTo(0.50, 0.0001));
        expect(report.durationSeconds,         closeTo(3.01, 0.001));
      },
    );

    test(
      'MC4-3 runMultiCamStreamingDiagnostic returns null on PlatformException',
      () async {
        _responses['runMultiCamStreamingDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before running MultiCam streaming diagnostic',
        );

        final report = await VGCameraSession.runMultiCamStreamingDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull);
      },
    );

    test(
      'MC4-4 runMultiCamStreamingDiagnostic returns null on null native response',
      () async {
        _responses['runMultiCamStreamingDiagnostic'] = null;

        final report = await VGCameraSession.runMultiCamStreamingDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull);
      },
    );

    test(
      'MC4-5 VGMultiCamStreamingReport.fromMap computes FPS correctly',
      () {
        final report = VGMultiCamStreamingReport.fromMap(<Object?, Object?>{
          'frontFramesReceived':    90,
          'backFramesReceived':     60,
          'peakSystemPressureCost': 0.30,
          'hardwareCost':           0.50,
          'durationSeconds':        3.0,
        });

        expect(report, isNotNull);
        // frontFPS = 90 / 3.0 = 30.0
        expect(report!.frontFPS, closeTo(30.0, 0.001));
        // backFPS = 60 / 3.0 = 20.0
        expect(report.backFPS, closeTo(20.0, 0.001));
      },
    );

    test(
      'MC4-6 VGMultiCamStreamingReport.fromMap returns null for missing frontFramesReceived',
      () {
        final report = VGMultiCamStreamingReport.fromMap(<Object?, Object?>{
          // frontFramesReceived intentionally omitted
          'backFramesReceived':     87,
          'peakSystemPressureCost': 0.42,
          'hardwareCost':           0.50,
          'durationSeconds':        3.01,
        });

        expect(report, isNull);
      },
    );
  });

  // ── MC-5: VGCameraSession.runMultiCamSyncDiagnostic ───────────────────────
  //
  // Tests for the synchronized frame-pair diagnostic using
  // AVCaptureDataOutputSynchronizer.
  //
  // Confirms channel dispatch, argument passing, full result parsing,
  // derived getter computation (pairedFPS, drift milliseconds), and
  // null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  //
  // Acceptance criteria:
  //   MC5-1  dispatches 'runMultiCamSyncDiagnostic' with frontDeviceId and backDeviceId
  //   MC5-2  parses valid native response into VGMultiCamSyncReport
  //   MC5-3  returns null on PlatformException
  //   MC5-4  returns null on null native response
  //   MC5-5  fromMap computes derived pairedFPS, drift ms, threshold ms correctly
  //   MC5-6  fromMap returns null for missing pairedFramesReceived
  group('VGCameraSession.runMultiCamSyncDiagnostic', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    // Canonical valid response — mirrors the revised native return dictionary.
    const kValidResponse = <Object?, Object?>{
      'pairedFramesReceived':    86,
      'frontFramesReceived':     91,
      'backFramesReceived':      89,
      'unmatchedFrontFrames':    5,
      'unmatchedBackFrames':     3,
      'maxDriftSeconds':         0.008,
      'averageDriftSeconds':     0.002,
      'peakSystemPressureCost':  0.49,
      'hardwareCost':            0.50,
      'durationSeconds':         3.02,
      'pairingThresholdSeconds': 1.0 / 30.0,
    };

    test(
      'MC5-1 runMultiCamSyncDiagnostic dispatches channel method with frontDeviceId and backDeviceId',
      () async {
        _responses['runMultiCamSyncDiagnostic'] = kValidResponse;

        await VGCameraSession.runMultiCamSyncDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1,
            reason: 'runMultiCamSyncDiagnostic must invoke the channel exactly once');
        expect(_log.first.method, 'runMultiCamSyncDiagnostic',
            reason: 'channel method name must be runMultiCamSyncDiagnostic');
        expect(_log.first.arguments['frontDeviceId'], kFrontId,
            reason: 'frontDeviceId must be forwarded to the channel');
        expect(_log.first.arguments['backDeviceId'],  kBackId,
            reason: 'backDeviceId must be forwarded to the channel');
      },
    );

    test(
      'MC5-2 runMultiCamSyncDiagnostic parses valid native response into VGMultiCamSyncReport',
      () async {
        _responses['runMultiCamSyncDiagnostic'] = kValidResponse;

        final report = await VGCameraSession.runMultiCamSyncDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull,
            reason: 'must return a non-null VGMultiCamSyncReport for a valid native map');
        expect(report!.pairedFramesReceived,  86);
        expect(report.frontFramesReceived,    91);
        expect(report.backFramesReceived,     89);
        expect(report.unmatchedFrontFrames,    5);
        expect(report.unmatchedBackFrames,     3);
        expect(report.maxDriftSeconds,     closeTo(0.008, 0.000001));
        expect(report.averageDriftSeconds, closeTo(0.002, 0.000001));
        expect(report.peakSystemPressureCost, closeTo(0.49, 0.0001));
        expect(report.hardwareCost,           closeTo(0.50, 0.0001));
        expect(report.durationSeconds,        closeTo(3.02, 0.001));
        expect(report.pairingThresholdSeconds,
            closeTo(1.0 / 30.0, 0.000001));
      },
    );

    test(
      'MC5-3 runMultiCamSyncDiagnostic returns null on PlatformException',
      () async {
        _responses['runMultiCamSyncDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before running MultiCam sync diagnostic',
        );

        final report = await VGCameraSession.runMultiCamSyncDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null (not rethrow) when native throws PlatformException');
      },
    );

    test(
      'MC5-4 runMultiCamSyncDiagnostic returns null on null native response',
      () async {
        _responses['runMultiCamSyncDiagnostic'] = null;

        final report = await VGCameraSession.runMultiCamSyncDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null when native responds with null '
                '(e.g. iOS < 13, device not found, or not authorized)');
      },
    );

    test(
      'MC5-5 VGMultiCamSyncReport.fromMap computes derived FPS and drift/threshold milliseconds correctly',
      () {
        // pairedFPS              = 86 / 3.02 ≈ 28.48
        // maxDriftMilliseconds   = 0.008 * 1000 = 8.0 ms
        // avgDriftMilliseconds   = 0.002 * 1000 = 2.0 ms
        // thresholdMilliseconds  = (1/30) * 1000 ≈ 33.33 ms
        final report = VGMultiCamSyncReport.fromMap(kValidResponse);

        expect(report, isNotNull);
        expect(
          report!.pairedFPS,
          closeTo(86.0 / 3.02, 0.001),
          reason: 'pairedFPS must equal pairedFramesReceived / durationSeconds',
        );
        expect(
          report.maxDriftMilliseconds,
          closeTo(8.0, 0.0001),
          reason: 'maxDriftMilliseconds must equal maxDriftSeconds * 1000',
        );
        expect(
          report.averageDriftMilliseconds,
          closeTo(2.0, 0.0001),
          reason: 'averageDriftMilliseconds must equal averageDriftSeconds * 1000',
        );
        expect(
          report.pairingThresholdMilliseconds,
          closeTo(1000.0 / 30.0, 0.001),
          reason: 'pairingThresholdMilliseconds must equal pairingThresholdSeconds * 1000',
        );
      },
    );

    test(
      'MC5-6 VGMultiCamSyncReport.fromMap returns null for missing pairedFramesReceived',
      () {
        final map = Map<Object?, Object?>.from(kValidResponse)
          ..remove('pairedFramesReceived');
        final report = VGMultiCamSyncReport.fromMap(map);

        expect(report, isNull,
            reason: 'fromMap must return null when pairedFramesReceived is missing');
      },
    );
  });

  // ── MC-7: VGCameraSession.runMultiCamSourceLifecycleDiagnostic ───────────
  //
  // Tests for the production MultiCam media source lifecycle diagnostic that
  // uses VanguardMultiCamMediaSource + VanguardMultiCamFramePairer (MC-6).
  //
  // Confirms channel dispatch, argument passing, full result parsing,
  // and null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  //
  // Acceptance criteria:
  //   MC7-1  dispatches 'runMultiCamSourceLifecycleDiagnostic' with
  //          frontDeviceId and backDeviceId
  //   MC7-2  parses valid native response into VGMultiCamSyncReport
  //   MC7-3  returns null on PlatformException
  //   MC7-4  returns null on null native response
  group('VGCameraSession.runMultiCamSourceLifecycleDiagnostic', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    // Canonical valid response — mirrors physical-device MC-5/MC-7 results.
    // Shape is identical to VGMultiCamSyncReport native dictionary.
    const kValidResponse = <Object?, Object?>{
      'pairedFramesReceived':    85,
      'frontFramesReceived':     91,
      'backFramesReceived':      85,
      'unmatchedFrontFrames':    6,
      'unmatchedBackFrames':     0,
      'maxDriftSeconds':         0.020586,
      'averageDriftSeconds':     0.020428,
      'peakSystemPressureCost':  0.4955,
      'hardwareCost':            0.5000,
      'durationSeconds':         3.22,
      'pairingThresholdSeconds': 1.0 / 30.0,
    };

    test(
      'MC7-1 runMultiCamSourceLifecycleDiagnostic dispatches channel method with frontDeviceId and backDeviceId',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = kValidResponse;

        await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1,
            reason: 'runMultiCamSourceLifecycleDiagnostic must invoke the channel exactly once');
        expect(_log.first.method, 'runMultiCamSourceLifecycleDiagnostic',
            reason: 'channel method name must be runMultiCamSourceLifecycleDiagnostic');
        expect(_log.first.arguments['frontDeviceId'], kFrontId,
            reason: 'frontDeviceId must be forwarded to the channel');
        expect(_log.first.arguments['backDeviceId'],  kBackId,
            reason: 'backDeviceId must be forwarded to the channel');
      },
    );

    test(
      'MC7-2 runMultiCamSourceLifecycleDiagnostic parses valid native response into VGMultiCamSyncReport',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = kValidResponse;

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull,
            reason: 'must return a non-null VGMultiCamSyncReport for a valid native map');
        expect(report!.pairedFramesReceived,  85);
        expect(report.frontFramesReceived,    91);
        expect(report.backFramesReceived,     85);
        expect(report.unmatchedFrontFrames,    6);
        expect(report.unmatchedBackFrames,     0);
        expect(report.maxDriftSeconds,     closeTo(0.020586, 0.000001));
        expect(report.averageDriftSeconds, closeTo(0.020428, 0.000001));
        expect(report.peakSystemPressureCost, closeTo(0.4955, 0.0001));
        expect(report.hardwareCost,           closeTo(0.5000, 0.0001));
        expect(report.durationSeconds,        closeTo(3.22, 0.001));
        expect(report.pairingThresholdSeconds,
            closeTo(1.0 / 30.0, 0.000001));
      },
    );

    test(
      'MC7-3 runMultiCamSourceLifecycleDiagnostic returns null on PlatformException',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before running MultiCam source lifecycle diagnostic',
        );

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null (not rethrow) when native throws PlatformException');
      },
    );

    test(
      'MC7-4 runMultiCamSourceLifecycleDiagnostic returns null on null native response',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = null;

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null when native responds with null '
                '(e.g. iOS < 13, device not found, or not authorized)');
      },
    );
  });

  // ── MC-8: VGMultiCamSyncReport MC-8 optional field parsing ───────────────
  //
  // Tests for the paired-frame buffer lifecycle additions in MC-8.
  // Verifies that:
  //   - MC-8 buffer fields parse correctly from a full native map.
  //   - MC-5/MC-7 native maps (no MC-8 fields) parse to safe defaults (0/false).
  //   - PlatformException still returns null after MC-8 field additions.
  //   - Null native response still returns null.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  //
  // Acceptance criteria:
  //   MC8-1  parses all MC-8 delegate verification fields
  //   MC8-2  uses safe defaults when MC-8 fields are absent
  //   MC8-3  returns null on PlatformException (MC-8 field addition regression)
  //   MC8-4  returns null on null native response (MC-8 field addition regression)
  group('VGCameraSession.runMultiCamSourceLifecycleDiagnostic (MC-8 fields)', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    // Canonical MC-7 base map (no MC-8 fields) — used to verify safe defaults.
    const kMC7BaseResponse = <Object?, Object?>{
      'pairedFramesReceived':    85,
      'frontFramesReceived':     91,
      'backFramesReceived':      85,
      'unmatchedFrontFrames':    6,
      'unmatchedBackFrames':     0,
      'maxDriftSeconds':         0.020586,
      'averageDriftSeconds':     0.020428,
      'peakSystemPressureCost':  0.4955,
      'hardwareCost':            0.5000,
      'durationSeconds':         3.22,
      'pairingThresholdSeconds': 1.0 / 30.0,
    };

    // Full MC-8 response including all buffer verification fields.
    const kMC8FullResponse = <Object?, Object?>{
      'pairedFramesReceived':         85,
      'frontFramesReceived':          91,
      'backFramesReceived':           85,
      'unmatchedFrontFrames':         6,
      'unmatchedBackFrames':          0,
      'maxDriftSeconds':              0.020586,
      'averageDriftSeconds':          0.020428,
      'peakSystemPressureCost':       0.4955,
      'hardwareCost':                 0.5000,
      'durationSeconds':              3.22,
      'pairingThresholdSeconds':      1.0 / 30.0,
      // MC-8 additions:
      'delegatePairedFramesReceived': 85,
      'frontBufferWidth':             1080,
      'frontBufferHeight':            1920,
      'backBufferWidth':              1080,
      'backBufferHeight':             1920,
      'buffersValid':                 true,
    };

    test(
      'MC8-1 runMultiCamSourceLifecycleDiagnostic parses MC-8 delegate verification fields',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = kMC8FullResponse;

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull,
            reason: 'must return non-null VGMultiCamSyncReport for a full MC-8 native map');

        // Existing MC-7 fields must still parse correctly.
        expect(report!.pairedFramesReceived, 85);
        expect(report.frontFramesReceived,   91);
        expect(report.backFramesReceived,    85);

        // MC-8 buffer verification fields.
        expect(report.delegatePairedFramesReceived, 85,
            reason: 'delegatePairedFramesReceived must match native value');
        expect(report.frontBufferWidth,  1080,
            reason: 'frontBufferWidth must parse from native map');
        expect(report.frontBufferHeight, 1920,
            reason: 'frontBufferHeight must parse from native map');
        expect(report.backBufferWidth,   1080,
            reason: 'backBufferWidth must parse from native map');
        expect(report.backBufferHeight,  1920,
            reason: 'backBufferHeight must parse from native map');
        expect(report.buffersValid, isTrue,
            reason: 'buffersValid must be true when native reports valid buffers');
      },
    );

    test(
      'MC8-2 VGMultiCamSyncReport.fromMap uses safe defaults for absent MC-8 fields',
      () {
        // Parse a map with the MC-5/MC-7 shape only — no MC-8 fields present.
        final report = VGMultiCamSyncReport.fromMap(kMC7BaseResponse);

        expect(report, isNotNull,
            reason: 'fromMap must succeed for MC-5/MC-7 maps (backward compatibility)');

        // Existing required fields parse normally.
        expect(report!.pairedFramesReceived, 85);
        expect(report.durationSeconds, closeTo(3.22, 0.001));

        // MC-8 fields must default to safe zero/false values.
        expect(report.delegatePairedFramesReceived, 0,
            reason: 'delegatePairedFramesReceived must default to 0 when absent');
        expect(report.frontBufferWidth,  0,
            reason: 'frontBufferWidth must default to 0 when absent');
        expect(report.frontBufferHeight, 0,
            reason: 'frontBufferHeight must default to 0 when absent');
        expect(report.backBufferWidth,   0,
            reason: 'backBufferWidth must default to 0 when absent');
        expect(report.backBufferHeight,  0,
            reason: 'backBufferHeight must default to 0 when absent');
        expect(report.buffersValid, isFalse,
            reason: 'buffersValid must default to false when absent');
      },
    );

    test(
      'MC8-3 runMultiCamSourceLifecycleDiagnostic returns null on PlatformException with MC-8 fields',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before running MultiCam source lifecycle diagnostic',
        );

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null (not rethrow) when native throws PlatformException '
                '(regression: MC-8 field additions must not affect error handling)');
      },
    );

    test(
      'MC8-4 runMultiCamSourceLifecycleDiagnostic returns null on null native response with MC-8 fields',
      () async {
        _responses['runMultiCamSourceLifecycleDiagnostic'] = null;

        final report = await VGCameraSession.runMultiCamSourceLifecycleDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null when native responds with null '
                '(regression: MC-8 field additions must not affect null handling)');
      },
    );
  });

  // ── MC-9: VGMultiCamRenderReport.fromMap ─────────────────────────────────
  //
  // Unit tests for the VGMultiCamRenderReport value type introduced in MC-9.
  // Verifies fromMap parsing, int/double coercion, null handling for missing
  // fields, renderedFPS computation, equality, hashCode, and toString.
  //
  // These are pure Dart tests — no native code, no channel calls.
  //
  // Acceptance criteria:
  //   MC9R-1  parses complete map with all fields
  //   MC9R-2  parses int values for double fields (int-to-double coercion)
  //   MC9R-3  returns null for null map
  //   MC9R-4  returns null for missing renderedFrames (required field)
  //   MC9R-5  returns null for missing averageRenderMs (required double field)
  //   MC9R-6  returns null for missing pairedFramesReceived (capture-side field)
  //   MC9R-7  returns null for missing durationSeconds
  //   MC9R-8  renderedFPS returns 0.0 when durationSeconds is 0
  //   MC9R-9  renderedFPS computes correctly
  //   MC9R-10 equality: two identical reports are equal
  //   MC9R-11 equality: different renderedFrames are not equal
  //   MC9R-12 hashCode matches for equal reports
  //   MC9R-13 toString includes renderedFrames and averageRenderMs
  //   MC9R-14 toString includes output dimensions
  group('VGMultiCamRenderReport.fromMap', () {
    // Canonical valid native response map (mirrors expected native output).
    const kValidRenderResponse = <Object?, Object?>{
      'renderedFrames':        78,
      'droppedRenderFrames':   7,
      'averageRenderMs':       12.34,
      'peakRenderMs':          28.91,
      'outputWidth':           1080,
      'outputHeight':          1920,
      'pairedFramesReceived':  85,
      'frontFramesReceived':   90,
      'backFramesReceived':    85,
      'peakSystemPressureCost': 0.51,
      'hardwareCost':          0.50,
      'durationSeconds':       3.21,
    };

    test(
      'MC9R-1 parses complete map with all fields',
      () {
        final report = VGMultiCamRenderReport.fromMap(kValidRenderResponse);

        expect(report, isNotNull,
            reason: 'must return non-null for a complete valid map');
        expect(report!.renderedFrames,       78);
        expect(report.droppedRenderFrames,    7);
        expect(report.averageRenderMs,        closeTo(12.34, 0.0001));
        expect(report.peakRenderMs,           closeTo(28.91, 0.0001));
        expect(report.outputWidth,            1080);
        expect(report.outputHeight,           1920);
        expect(report.pairedFramesReceived,   85);
        expect(report.frontFramesReceived,    90);
        expect(report.backFramesReceived,     85);
        expect(report.peakSystemPressureCost, closeTo(0.51, 0.0001));
        expect(report.hardwareCost,           closeTo(0.50, 0.0001));
        expect(report.durationSeconds,        closeTo(3.21, 0.001));
      },
    );

    test(
      'MC9R-2 parses int values for double fields (int-to-double coercion)',
      () {
        // Native may send integer values for double fields.
        const map = <Object?, Object?>{
          'renderedFrames':        78,
          'droppedRenderFrames':   7,
          'averageRenderMs':       12,    // int instead of double
          'peakRenderMs':          28,    // int instead of double
          'outputWidth':           1080,
          'outputHeight':          1920,
          'pairedFramesReceived':  85,
          'frontFramesReceived':   90,
          'backFramesReceived':    85,
          'peakSystemPressureCost': 0,   // int instead of double
          'hardwareCost':          0,    // int instead of double
          'durationSeconds':       3,    // int instead of double
        };
        final report = VGMultiCamRenderReport.fromMap(map);

        expect(report, isNotNull,
            reason: 'must parse int values for double fields without error');
        expect(report!.averageRenderMs,        closeTo(12.0, 0.0001));
        expect(report.peakRenderMs,            closeTo(28.0, 0.0001));
        expect(report.peakSystemPressureCost,  closeTo(0.0, 0.0001));
        expect(report.hardwareCost,            closeTo(0.0, 0.0001));
        expect(report.durationSeconds,         closeTo(3.0, 0.001));
      },
    );

    test(
      'MC9R-3 returns null for null map',
      () {
        final report = VGMultiCamRenderReport.fromMap(null);
        expect(report, isNull,
            reason: 'fromMap must return null when map is null');
      },
    );

    test(
      'MC9R-4 returns null for missing renderedFrames',
      () {
        final map = Map<Object?, Object?>.from(kValidRenderResponse)
          ..remove('renderedFrames');
        final report = VGMultiCamRenderReport.fromMap(map);
        expect(report, isNull,
            reason: 'fromMap must return null when renderedFrames is absent');
      },
    );

    test(
      'MC9R-5 returns null for missing averageRenderMs',
      () {
        final map = Map<Object?, Object?>.from(kValidRenderResponse)
          ..remove('averageRenderMs');
        final report = VGMultiCamRenderReport.fromMap(map);
        expect(report, isNull,
            reason: 'fromMap must return null when averageRenderMs is absent');
      },
    );

    test(
      'MC9R-6 returns null for missing pairedFramesReceived',
      () {
        final map = Map<Object?, Object?>.from(kValidRenderResponse)
          ..remove('pairedFramesReceived');
        final report = VGMultiCamRenderReport.fromMap(map);
        expect(report, isNull,
            reason: 'fromMap must return null when pairedFramesReceived is absent');
      },
    );

    test(
      'MC9R-7 returns null for missing durationSeconds',
      () {
        final map = Map<Object?, Object?>.from(kValidRenderResponse)
          ..remove('durationSeconds');
        final report = VGMultiCamRenderReport.fromMap(map);
        expect(report, isNull,
            reason: 'fromMap must return null when durationSeconds is absent');
      },
    );

    test(
      'MC9R-8 renderedFPS returns 0.0 when durationSeconds is 0',
      () {
        const map = <Object?, Object?>{
          'renderedFrames':        50,
          'droppedRenderFrames':   5,
          'averageRenderMs':       10.0,
          'peakRenderMs':          20.0,
          'outputWidth':           1080,
          'outputHeight':          1920,
          'pairedFramesReceived':  55,
          'frontFramesReceived':   60,
          'backFramesReceived':    55,
          'peakSystemPressureCost': 0.50,
          'hardwareCost':          0.50,
          'durationSeconds':       0.0,  // zero duration
        };
        final report = VGMultiCamRenderReport.fromMap(map);
        expect(report, isNotNull);
        expect(
          report!.renderedFPS,
          closeTo(0.0, 0.0001),
          reason: 'renderedFPS must be 0.0 when durationSeconds is 0',
        );
      },
    );

    test(
      'MC9R-9 renderedFPS computes correctly',
      () {
        // renderedFPS = 78 / 3.21 ≈ 24.30
        final report = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        expect(report, isNotNull);
        expect(
          report!.renderedFPS,
          closeTo(78.0 / 3.21, 0.001),
          reason: 'renderedFPS must equal renderedFrames / durationSeconds',
        );
      },
    );

    test(
      'MC9R-10 equality: two identical reports are equal',
      () {
        final r1 = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        final r2 = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        expect(r1, isNotNull);
        expect(r2, isNotNull);
        expect(r1, equals(r2),
            reason: 'two reports parsed from the same map must be equal');
      },
    );

    test(
      'MC9R-11 equality: different renderedFrames are not equal',
      () {
        final r1 = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        final map2 = Map<Object?, Object?>.from(kValidRenderResponse)
          ..['renderedFrames'] = 50;
        final r2 = VGMultiCamRenderReport.fromMap(map2);
        expect(r1, isNotNull);
        expect(r2, isNotNull);
        expect(r1, isNot(equals(r2)),
            reason: 'reports with different renderedFrames must not be equal');
      },
    );

    test(
      'MC9R-12 hashCode matches for equal reports',
      () {
        final r1 = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        final r2 = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        expect(r1, isNotNull);
        expect(r2, isNotNull);
        expect(r1.hashCode, equals(r2.hashCode),
            reason: 'equal reports must have the same hashCode');
      },
    );

    test(
      'MC9R-13 toString includes renderedFrames and averageRenderMs',
      () {
        final report = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        expect(report, isNotNull);
        final s = report.toString();
        expect(s, contains('renderedFrames: 78'),
            reason: 'toString must include renderedFrames');
        expect(s, contains('averageRenderMs'),
            reason: 'toString must include averageRenderMs');
      },
    );

    test(
      'MC9R-14 toString includes output dimensions',
      () {
        final report = VGMultiCamRenderReport.fromMap(kValidRenderResponse);
        expect(report, isNotNull);
        final s = report.toString();
        expect(s, contains('1080'),
            reason: 'toString must include output width');
        expect(s, contains('1920'),
            reason: 'toString must include output height');
      },
    );
  });

  // ── MC-9: VGCameraSession.runMultiCamRenderDiagnostic ────────────────────
  //
  // Tests for the MC-9 offscreen MultiCam render diagnostic channel route.
  // Confirms channel dispatch, argument passing, result parsing, and
  // null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  //
  // Acceptance criteria:
  //   MC9-1  dispatches 'runMultiCamRenderDiagnostic' with frontDeviceId and backDeviceId
  //   MC9-2  parses valid native response into VGMultiCamRenderReport
  //   MC9-3  returns null when required native map field is missing
  //   MC9-4  handles int-to-double conversion for render timing fields
  //   MC9-5  uses exact channel method name 'runMultiCamRenderDiagnostic'
  //   MC9-6  passes frontDeviceId and backDeviceId
  group('VGCameraSession.runMultiCamRenderDiagnostic', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    // Canonical valid response — mirrors expected native merged metrics map.
    const kValidResponse = <Object?, Object?>{
      'renderedFrames':        78,
      'droppedRenderFrames':   7,
      'averageRenderMs':       12.34,
      'peakRenderMs':          28.91,
      'outputWidth':           1080,
      'outputHeight':          1920,
      'pairedFramesReceived':  85,
      'frontFramesReceived':   90,
      'backFramesReceived':    85,
      'peakSystemPressureCost': 0.51,
      'hardwareCost':          0.50,
      'durationSeconds':       3.21,
    };

    test(
      'MC9-1 dispatches runMultiCamRenderDiagnostic with frontDeviceId and backDeviceId',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = kValidResponse;

        await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1,
            reason: 'runMultiCamRenderDiagnostic must invoke the channel exactly once');
        expect(_log.first.method, 'runMultiCamRenderDiagnostic',
            reason: 'channel method name must be exactly runMultiCamRenderDiagnostic');
        expect(_log.first.arguments['frontDeviceId'], kFrontId,
            reason: 'frontDeviceId must be forwarded to the channel');
        expect(_log.first.arguments['backDeviceId'],  kBackId,
            reason: 'backDeviceId must be forwarded to the channel');
      },
    );

    test(
      'MC9-2 parses valid native response into VGMultiCamRenderReport',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = kValidResponse;

        final report = await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull,
            reason: 'must return a non-null VGMultiCamRenderReport for a valid native map');
        expect(report!.renderedFrames,        78);
        expect(report.droppedRenderFrames,     7);
        expect(report.averageRenderMs,         closeTo(12.34, 0.0001));
        expect(report.peakRenderMs,            closeTo(28.91, 0.0001));
        expect(report.outputWidth,             1080);
        expect(report.outputHeight,            1920);
        expect(report.pairedFramesReceived,    85);
        expect(report.frontFramesReceived,     90);
        expect(report.backFramesReceived,      85);
        expect(report.peakSystemPressureCost,  closeTo(0.51, 0.0001));
        expect(report.hardwareCost,            closeTo(0.50, 0.0001));
        expect(report.durationSeconds,         closeTo(3.21, 0.001));
      },
    );

    test(
      'MC9-3 returns null when required native map field is missing',
      () async {
        // Remove a required field to trigger fromMap null return.
        final map = Map<Object?, Object?>.from(kValidResponse)
          ..remove('renderedFrames');
        _responses['runMultiCamRenderDiagnostic'] = map;

        final report = await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null when required field renderedFrames is missing');
      },
    );

    test(
      'MC9-4 handles int-to-double conversion for render timing fields',
      () async {
        // Native may return int for averageRenderMs / peakRenderMs.
        final map = Map<Object?, Object?>.from(kValidResponse)
          ..['averageRenderMs'] = 12    // int
          ..['peakRenderMs']    = 28;   // int
        _responses['runMultiCamRenderDiagnostic'] = map;

        final report = await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNotNull,
            reason: 'must handle int values for averageRenderMs and peakRenderMs');
        expect(report!.averageRenderMs, closeTo(12.0, 0.0001));
        expect(report.peakRenderMs,     closeTo(28.0, 0.0001));
      },
    );

    test(
      'MC9-5 uses exact channel method name runMultiCamRenderDiagnostic',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = kValidResponse;

        await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(
          _log.first.method,
          'runMultiCamRenderDiagnostic',
          reason: 'channel method name must be exactly runMultiCamRenderDiagnostic '
              '(not runMultiCamRendererDiagnostic or any other variant)',
        );
      },
    );

    test(
      'MC9-6 returns null on PlatformException (e.g. CAMERA_ACTIVE or Android)',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before running MultiCam render diagnostic',
        );

        final report = await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(report, isNull,
            reason: 'must return null (not rethrow) on PlatformException');
      },
    );
  });

  // ── MC-10: VGMultiCamRenderTextureSession ─────────────────────────────────
  //
  // Tests for VGMultiCamRenderTextureSession.fromMap parsing and equality.
  //
  // Acceptance criteria:
  //   MC10-11 fromMap parses a complete valid map
  //   MC10-12 fromMap returns null when textureId is missing
  //   MC10-13 fromMap returns null when textureId is null
  //   MC10-14 fromMap defaults outputWidth/outputHeight to 0 when absent
  //   MC10-15 fromMap accepts double outputWidth/outputHeight (int coercion)
  //   MC10-16 equality and hashCode
  //   MC10-17 toString includes textureId and output dimensions
  group('VGMultiCamRenderTextureSession', () {
    const kValidSessionMap = <Object?, Object?>{
      'textureId':    42,
      'outputWidth':  1080,
      'outputHeight': 1920,
    };

    test('MC10-11 fromMap parses a complete valid map', () {
      final s = VGMultiCamRenderTextureSession.fromMap(kValidSessionMap);
      expect(s, isNotNull,
          reason: 'must parse valid map with all fields');
      expect(s!.textureId,    42);
      expect(s.outputWidth,   1080);
      expect(s.outputHeight,  1920);
    });

    test('MC10-12 fromMap returns null when textureId is missing', () {
      final map = Map<Object?, Object?>.from(kValidSessionMap)..remove('textureId');
      final s = VGMultiCamRenderTextureSession.fromMap(map);
      expect(s, isNull,
          reason: 'textureId is required — must return null when absent');
    });

    test('MC10-13 fromMap returns null when map is null', () {
      final s = VGMultiCamRenderTextureSession.fromMap(null);
      expect(s, isNull, reason: 'null input must yield null output');
    });

    test('MC10-14 fromMap defaults outputWidth/outputHeight to 0 when absent', () {
      const map = <Object?, Object?>{'textureId': 7};
      final s = VGMultiCamRenderTextureSession.fromMap(map);
      expect(s, isNotNull);
      expect(s!.outputWidth,  0,
          reason: 'outputWidth must default to 0 when not present');
      expect(s.outputHeight, 0,
          reason: 'outputHeight must default to 0 when not present');
    });

    test('MC10-15 fromMap coerces double outputWidth/outputHeight to int', () {
      const map = <Object?, Object?>{
        'textureId':    5,
        'outputWidth':  1080.0,
        'outputHeight': 1920.0,
      };
      final s = VGMultiCamRenderTextureSession.fromMap(map);
      expect(s, isNotNull);
      expect(s!.outputWidth,  1080);
      expect(s.outputHeight,  1920);
    });

    test('MC10-16 equality and hashCode', () {
      const a = VGMultiCamRenderTextureSession(
          textureId: 1, outputWidth: 1080, outputHeight: 1920);
      const b = VGMultiCamRenderTextureSession(
          textureId: 1, outputWidth: 1080, outputHeight: 1920);
      const c = VGMultiCamRenderTextureSession(
          textureId: 2, outputWidth: 1080, outputHeight: 1920);
      expect(a == b, isTrue,
          reason: 'identical field values must be equal');
      expect(a.hashCode == b.hashCode, isTrue,
          reason: 'equal objects must have same hashCode');
      expect(a == c, isFalse,
          reason: 'different textureId must not be equal');
    });

    test('MC10-17 toString includes textureId and output dimensions', () {
      const s = VGMultiCamRenderTextureSession(
          textureId: 99, outputWidth: 1080, outputHeight: 1920);
      final str = s.toString();
      expect(str, contains('99'),     reason: 'textureId must appear in toString');
      expect(str, contains('1080'),   reason: 'outputWidth must appear in toString');
      expect(str, contains('1920'),   reason: 'outputHeight must appear in toString');
    });
  });

  // ── MC-10: VGCameraSession.startMultiCamRenderDiagnostic ─────────────────
  //
  // Tests for the MC-10 live Flutter texture diagnostic — start channel route.
  // Confirms channel dispatch, argument passing, result parsing, and
  // null-safety fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  //
  // Acceptance criteria:
  //   MC10-1  dispatches 'startMultiCamRenderDiagnostic' with frontDeviceId and backDeviceId
  //   MC10-2  parses valid response map into VGMultiCamRenderTextureSession
  //   MC10-3  returns null when native returns null (source init failed / iOS<13)
  //   MC10-4  returns null on PlatformException (CAMERA_ACTIVE, ALREADY_RUNNING, etc.)
  //   MC10-5  uses exact channel method name 'startMultiCamRenderDiagnostic'
  group('VGCameraSession.startMultiCamRenderDiagnostic', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    const kValidStartResponse = <Object?, Object?>{
      'textureId':    42,
      'outputWidth':  0,
      'outputHeight': 0,
    };

    test(
      'MC10-1 dispatches startMultiCamRenderDiagnostic with frontDeviceId and backDeviceId',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = kValidStartResponse;

        await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1,
            reason: 'startMultiCamRenderDiagnostic must invoke the channel exactly once');
        expect(_log.first.method, 'startMultiCamRenderDiagnostic',
            reason: 'channel method name must be exactly startMultiCamRenderDiagnostic');
        expect(_log.first.arguments['frontDeviceId'], kFrontId,
            reason: 'frontDeviceId must be forwarded to the channel');
        expect(_log.first.arguments['backDeviceId'],  kBackId,
            reason: 'backDeviceId must be forwarded to the channel');
      },
    );

    test(
      'MC10-2 parses valid response map into VGMultiCamRenderTextureSession',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = kValidStartResponse;

        final session = await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNotNull,
            reason: 'must return non-null VGMultiCamRenderTextureSession for valid map');
        expect(session!.textureId,    42);
        expect(session.outputWidth,   0);
        expect(session.outputHeight,  0);
      },
    );

    test(
      'MC10-3 returns null when native returns null (iOS<13 or init failed)',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = null;

        final session = await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNull,
            reason: 'null native response must yield null session');
      },
    );

    test(
      'MC10-4 returns null on PlatformException (CAMERA_ACTIVE)',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before starting MultiCam render diagnostic',
        );

        final session = await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNull,
            reason: 'must return null (not rethrow) on PlatformException CAMERA_ACTIVE');
      },
    );

    test(
      'MC10-4b returns null on PlatformException (ALREADY_RUNNING)',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = PlatformException(
          code: 'ALREADY_RUNNING',
          message: 'A MultiCam render diagnostic is already running',
        );

        final session = await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNull,
            reason: 'must return null (not rethrow) on PlatformException ALREADY_RUNNING');
      },
    );

    test(
      'MC10-5 uses exact channel method name startMultiCamRenderDiagnostic',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = kValidStartResponse;

        await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(
          _log.first.method,
          'startMultiCamRenderDiagnostic',
          reason: 'channel method name must be exactly startMultiCamRenderDiagnostic '
              '(not startMultiCamRendererDiagnostic or any other variant)',
        );
      },
    );
  });

  // ── MC-10: VGCameraSession.stopMultiCamRenderDiagnostic ──────────────────
  //
  // Tests for the MC-10 live Flutter texture diagnostic — stop channel route.
  // Confirms channel dispatch, no-args contract, result parsing, and
  // null-safety fallbacks.
  //
  // Acceptance criteria:
  //   MC10-6  dispatches 'stopMultiCamRenderDiagnostic' with no arguments
  //   MC10-7  parses valid response into VGMultiCamRenderReport
  //   MC10-8  returns null when native returns null (no diagnostic running)
  //   MC10-9  returns null on PlatformException
  //   MC10-10 uses exact channel method name 'stopMultiCamRenderDiagnostic'
  group('VGCameraSession.stopMultiCamRenderDiagnostic', () {
    // Canonical valid stop response — mirrors native merged metrics map.
    const kValidStopResponse = <Object?, Object?>{
      'renderedFrames':        78,
      'droppedRenderFrames':   7,
      'averageRenderMs':       12.34,
      'peakRenderMs':          28.91,
      'outputWidth':           1080,
      'outputHeight':          1920,
      'pairedFramesReceived':  85,
      'frontFramesReceived':   90,
      'backFramesReceived':    85,
      'peakSystemPressureCost': 0.51,
      'hardwareCost':          0.50,
      'durationSeconds':       5.10,
    };

    test(
      'MC10-6 dispatches stopMultiCamRenderDiagnostic with no arguments',
      () async {
        _responses['stopMultiCamRenderDiagnostic'] = kValidStopResponse;

        await VGCameraSession.stopMultiCamRenderDiagnostic();

        expect(_log.length, 1,
            reason: 'stopMultiCamRenderDiagnostic must invoke the channel exactly once');
        expect(_log.first.method, 'stopMultiCamRenderDiagnostic',
            reason: 'channel method name must be exactly stopMultiCamRenderDiagnostic');
        expect(_log.first.arguments, isNull,
            reason: 'stopMultiCamRenderDiagnostic must send no arguments');
      },
    );

    test(
      'MC10-7 parses valid response into VGMultiCamRenderReport',
      () async {
        _responses['stopMultiCamRenderDiagnostic'] = kValidStopResponse;

        final report = await VGCameraSession.stopMultiCamRenderDiagnostic();

        expect(report, isNotNull,
            reason: 'must return non-null VGMultiCamRenderReport for valid response');
        expect(report!.renderedFrames,       78);
        expect(report.droppedRenderFrames,   7);
        expect(report.averageRenderMs,       closeTo(12.34, 0.0001));
        expect(report.peakRenderMs,          closeTo(28.91, 0.0001));
        expect(report.outputWidth,           1080);
        expect(report.outputHeight,          1920);
        expect(report.pairedFramesReceived,  85);
        expect(report.frontFramesReceived,   90);
        expect(report.backFramesReceived,    85);
        expect(report.peakSystemPressureCost, closeTo(0.51, 0.0001));
        expect(report.hardwareCost,          closeTo(0.50, 0.0001));
        expect(report.durationSeconds,       closeTo(5.10, 0.001));
      },
    );

    test(
      'MC10-8 returns null when native returns null (no active diagnostic)',
      () async {
        _responses['stopMultiCamRenderDiagnostic'] = null;

        final report = await VGCameraSession.stopMultiCamRenderDiagnostic();

        expect(report, isNull,
            reason: 'null native response must yield null (no active diagnostic)');
      },
    );

    test(
      'MC10-9 returns null on PlatformException',
      () async {
        _responses['stopMultiCamRenderDiagnostic'] = PlatformException(
          code: 'INTERNAL_ERROR',
          message: 'Unexpected failure during stop',
        );

        final report = await VGCameraSession.stopMultiCamRenderDiagnostic();

        expect(report, isNull,
            reason: 'must return null (not rethrow) on PlatformException');
      },
    );

    test(
      'MC10-10 uses exact channel method name stopMultiCamRenderDiagnostic',
      () async {
        _responses['stopMultiCamRenderDiagnostic'] = kValidStopResponse;

        await VGCameraSession.stopMultiCamRenderDiagnostic();

        expect(
          _log.first.method,
          'stopMultiCamRenderDiagnostic',
          reason: 'channel method name must be exactly stopMultiCamRenderDiagnostic '
              '(not stopMultiCamRendererDiagnostic or any other variant)',
        );
      },
    );
  });

  // ── MC-12: Layout config forwarding ──────────────────────────────────────
  //
  // Tests that the optional config parameter is forwarded correctly on both
  // runMultiCamRenderDiagnostic and startMultiCamRenderDiagnostic.
  //
  // Acceptance criteria covered:
  //   MC12-1  runMultiCamRenderDiagnostic omits 'config' key when config is null
  //   MC12-2  runMultiCamRenderDiagnostic forwards config.toMap() when config is provided
  //   MC12-3  startMultiCamRenderDiagnostic omits 'config' key when config is null
  //   MC12-4  startMultiCamRenderDiagnostic forwards config.toMap() when config is provided
  //   MC12-5  default VGLivePreviewConfig produces expected layout keys
  //   MC12-6  splitScreen VGLivePreviewConfig produces layoutMode 'splitScreen'
  group('MC-12 layout config forwarding', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';
    const kValidRunResponse = <Object?, Object?>{
      'renderedFrames': 10, 'droppedRenderFrames': 0,
      'averageRenderMs': 10.0, 'peakRenderMs': 15.0,
      'outputWidth': 1080, 'outputHeight': 1920,
      'pairedFramesReceived': 10, 'frontFramesReceived': 10,
      'backFramesReceived': 10, 'peakSystemPressureCost': 0.3,
      'hardwareCost': 0.3, 'durationSeconds': 3.0,
    };
    const kValidStartResponse = <Object?, Object?>{'textureId': 42};

    test(
      'MC12-1 runMultiCamRenderDiagnostic omits config key when config is null',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = kValidRunResponse;

        await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.first.arguments.containsKey('config'), isFalse,
            reason: 'no config key must be present when config==null');
      },
    );

    test(
      'MC12-2 runMultiCamRenderDiagnostic forwards config.toMap() when config is provided',
      () async {
        _responses['runMultiCamRenderDiagnostic'] = kValidRunResponse;
        const config = VGLivePreviewConfig(
          layoutMode: VGDualCameraLayoutMode.splitScreen,
        );

        await VGCameraSession.runMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
          config: config,
        );

        final args = _log.first.arguments as Map;
        expect(args.containsKey('config'), isTrue,
            reason: 'config map must be forwarded to the channel');
        final configMap = args['config'] as Map;
        expect(configMap['layoutMode'], 'splitScreen',
            reason: 'layoutMode must be serialized as the wire string');
      },
    );

    test(
      'MC12-3 startMultiCamRenderDiagnostic omits config key when config is null',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = kValidStartResponse;

        await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.first.arguments.containsKey('config'), isFalse,
            reason: 'no config key must be present when config==null');
      },
    );

    test(
      'MC12-4 startMultiCamRenderDiagnostic forwards config.toMap() when config is provided',
      () async {
        _responses['startMultiCamRenderDiagnostic'] = kValidStartResponse;
        const config = VGLivePreviewConfig(
          pipLayout: VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft),
        );

        await VGCameraSession.startMultiCamRenderDiagnostic(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
          config: config,
        );

        final args = _log.first.arguments as Map;
        expect(args.containsKey('config'), isTrue,
            reason: 'config map must be forwarded to the channel');
        final pip = (args['config'] as Map)['pipLayout'] as Map;
        expect(pip['anchor'], 'topLeft',
            reason: 'topLeft anchor must serialize to the wire string topLeft');
      },
    );

    test(
      'MC12-5 default VGLivePreviewConfig produces layoutMode pip',
      () {
        const config = VGLivePreviewConfig();
        final map = config.toMap();
        expect(map['layoutMode'], 'pip');
        final pip = map['pipLayout'] as Map;
        expect(pip['anchor'], 'bottomRight');
      },
    );

    test(
      'MC12-6 splitScreen VGLivePreviewConfig produces layoutMode splitScreen',
      () {
        const config = VGLivePreviewConfig(
          layoutMode: VGDualCameraLayoutMode.splitScreen,
        );
        expect(config.toMap()['layoutMode'], 'splitScreen');
      },
    );
  });

  // ── MC-13: VGCameraSession.startMultiCamPreview ──────────────────────────
  //
  // Tests for the MC-13 production-facing MultiCam preview API — start route.
  // Confirms correct channel method name, argument forwarding, config
  // forwarding, no-config case, and null/error fallbacks.
  //
  // These are pure Dart / mock-channel tests — no native code runs.
  // The existing MC-10 diagnostic tests remain unchanged.
  //
  // Acceptance criteria:
  //   MC13-1  startMultiCamPreview invokes method channel name 'startMultiCamPreview'
  //   MC13-2  startMultiCamPreview forwards frontDeviceId and backDeviceId
  //   MC13-3  startMultiCamPreview forwards config.toMap() when config is provided
  //   MC13-4  startMultiCamPreview works without config (no 'config' key in args)
  //   MC13-5  stopMultiCamPreview invokes method channel name 'stopMultiCamPreview'
  //   MC13-6  stopMultiCamPreview parses VGMultiCamRenderReport from response
  //   MC13-7  existing diagnostic tests remain unaffected (verified by MC10/MC12 groups above)
  group('VGCameraSession.startMultiCamPreview (MC-13)', () {
    const kFrontId = 'AVCaptureDevice-Front-001';
    const kBackId  = 'AVCaptureDevice-Back-002';

    const kValidPreviewStartResponse = <Object?, Object?>{
      'textureId':    77,
      'outputWidth':  1080,
      'outputHeight': 1920,
    };

    test(
      'MC13-1 startMultiCamPreview invokes the channel with method name startMultiCamPreview',
      () async {
        _responses['startMultiCamPreview'] = kValidPreviewStartResponse;

        await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.length, 1,
            reason: 'startMultiCamPreview must invoke the channel exactly once');
        expect(
          _log.first.method,
          'startMultiCamPreview',
          reason: 'channel method name must be exactly startMultiCamPreview '
              '(not startMultiCamRenderDiagnostic or any other variant)',
        );
      },
    );

    test(
      'MC13-2 startMultiCamPreview forwards frontDeviceId and backDeviceId',
      () async {
        _responses['startMultiCamPreview'] = kValidPreviewStartResponse;

        await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(_log.first.arguments['frontDeviceId'], kFrontId,
            reason: 'frontDeviceId must be forwarded to the channel');
        expect(_log.first.arguments['backDeviceId'], kBackId,
            reason: 'backDeviceId must be forwarded to the channel');
      },
    );

    test(
      'MC13-3 startMultiCamPreview forwards config.toMap() when config is provided',
      () async {
        _responses['startMultiCamPreview'] = kValidPreviewStartResponse;
        const config = VGLivePreviewConfig(
          layoutMode: VGDualCameraLayoutMode.splitScreen,
        );

        await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
          config: config,
        );

        final args = _log.first.arguments as Map;
        expect(args.containsKey('config'), isTrue,
            reason: 'config map must be forwarded when config is provided');
        final configMap = args['config'] as Map;
        expect(configMap['layoutMode'], 'splitScreen',
            reason: 'layoutMode must be serialised as the wire string');
      },
    );

    test(
      'MC13-4 startMultiCamPreview omits config key when config is null',
      () async {
        _responses['startMultiCamPreview'] = kValidPreviewStartResponse;

        await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(
          (_log.first.arguments as Map).containsKey('config'),
          isFalse,
          reason: 'no config key must be present when config is not supplied',
        );
      },
    );

    test(
      'MC13-4b startMultiCamPreview returns typed VGMultiCamRenderTextureSession',
      () async {
        _responses['startMultiCamPreview'] = kValidPreviewStartResponse;

        final session = await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNotNull,
            reason: 'must return non-null session for a valid map response');
        expect(session!.textureId,    77);
        expect(session.outputWidth,   1080);
        expect(session.outputHeight,  1920);
      },
    );

    test(
      'MC13-4c startMultiCamPreview returns null on PlatformException (CAMERA_ACTIVE)',
      () async {
        _responses['startMultiCamPreview'] = PlatformException(
          code: 'CAMERA_ACTIVE',
          message: 'Stop camera preview before starting MultiCam preview',
        );

        final session = await VGCameraSession.startMultiCamPreview(
          frontDeviceId: kFrontId,
          backDeviceId: kBackId,
        );

        expect(session, isNull,
            reason: 'must return null (not rethrow) on PlatformException');
      },
    );
  });

  // ── MC-13: VGCameraSession.stopMultiCamPreview ───────────────────────────
  group('VGCameraSession.stopMultiCamPreview (MC-13)', () {
    const kValidPreviewStopResponse = <Object?, Object?>{
      'renderedFrames':        92,
      'droppedRenderFrames':   4,
      'averageRenderMs':       11.5,
      'peakRenderMs':          22.3,
      'outputWidth':           1080,
      'outputHeight':          1920,
      'pairedFramesReceived':  96,
      'frontFramesReceived':   100,
      'backFramesReceived':    96,
      'peakSystemPressureCost': 0.48,
      'hardwareCost':          0.47,
      'durationSeconds':       6.20,
    };

    test(
      'MC13-5 stopMultiCamPreview invokes the channel with method name stopMultiCamPreview',
      () async {
        _responses['stopMultiCamPreview'] = kValidPreviewStopResponse;

        await VGCameraSession.stopMultiCamPreview();

        expect(_log.length, 1,
            reason: 'stopMultiCamPreview must invoke the channel exactly once');
        expect(
          _log.first.method,
          'stopMultiCamPreview',
          reason: 'channel method name must be exactly stopMultiCamPreview '
              '(not stopMultiCamRenderDiagnostic or any other variant)',
        );
        expect(_log.first.arguments, isNull,
            reason: 'stopMultiCamPreview must send no arguments');
      },
    );

    test(
      'MC13-6 stopMultiCamPreview parses VGMultiCamRenderReport from response',
      () async {
        _responses['stopMultiCamPreview'] = kValidPreviewStopResponse;

        final report = await VGCameraSession.stopMultiCamPreview();

        expect(report, isNotNull,
            reason: 'must return non-null VGMultiCamRenderReport for valid response');
        expect(report!.renderedFrames,        92);
        expect(report.droppedRenderFrames,    4);
        expect(report.averageRenderMs,        closeTo(11.5,  0.001));
        expect(report.peakRenderMs,           closeTo(22.3,  0.001));
        expect(report.outputWidth,            1080);
        expect(report.outputHeight,           1920);
        expect(report.pairedFramesReceived,   96);
        expect(report.frontFramesReceived,    100);
        expect(report.backFramesReceived,     96);
        expect(report.peakSystemPressureCost, closeTo(0.48, 0.001));
        expect(report.hardwareCost,           closeTo(0.47, 0.001));
        expect(report.durationSeconds,        closeTo(6.20, 0.01));
      },
    );

    test(
      'MC13-6b stopMultiCamPreview returns null when native returns null',
      () async {
        _responses['stopMultiCamPreview'] = null;

        final report = await VGCameraSession.stopMultiCamPreview();

        expect(report, isNull,
            reason: 'null native response must yield null (no active preview)');
      },
    );

    test(
      'MC13-6c stopMultiCamPreview returns null on PlatformException',
      () async {
        _responses['stopMultiCamPreview'] = PlatformException(
          code: 'INTERNAL_ERROR',
          message: 'Unexpected failure during stop',
        );

        final report = await VGCameraSession.stopMultiCamPreview();

        expect(report, isNull,
            reason: 'must return null (not rethrow) on PlatformException');
      },
    );
  });

  // ── MC-15: takeMultiCamPhoto ───────────────────────────────────────────────
  //
  // Acceptance criteria:
  //   MC15-1  takeMultiCamPhoto invokes channel 'takeMultiCamPhoto' with the correct path argument
  //   MC15-2  takeMultiCamPhoto returns a populated VGPhotoCaptureResult on a valid native map
  //   MC15-3  takeMultiCamPhoto returns null when native returns null
  //   MC15-4  takeMultiCamPhoto returns null (not rethrow) on PlatformException

  group('VGCameraSession.takeMultiCamPhoto (MC-15)', () {
    const kPhotoPath = '/tmp/mc15_multicam_photo_001.jpg';

    const kValidPhotoResponse = <Object?, Object?>{
      'filePath':  kPhotoPath,
      'width':     1080,
      'height':    1920,
      'sizeBytes': 512000,
      'format':    'jpeg',
    };

    test(
      'MC15-1 takeMultiCamPhoto invokes channel with method name takeMultiCamPhoto and correct path',
      () async {
        _responses['takeMultiCamPhoto'] = kValidPhotoResponse;

        await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

        expect(_callCount('takeMultiCamPhoto'), equals(1),
            reason: 'must fire exactly one takeMultiCamPhoto channel call');
        final call = _log.firstWhere((c) => c.method == 'takeMultiCamPhoto');
        expect(call.arguments['path'], equals(kPhotoPath),
            reason: 'must forward path as {path: ...} argument map');
      },
    );

    test(
      'MC15-2 takeMultiCamPhoto returns populated VGPhotoCaptureResult from valid native map',
      () async {
        _responses['takeMultiCamPhoto'] = kValidPhotoResponse;

        final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

        expect(result, isNotNull,
            reason: 'must return non-null VGPhotoCaptureResult for valid native map');
        expect(result!.filePath,  equals(kPhotoPath));
        expect(result.width,      equals(1080));
        expect(result.height,     equals(1920));
        expect(result.sizeBytes,  equals(512000));
        expect(result.format,     equals('jpeg'));
      },
    );

    test(
      'MC15-3 takeMultiCamPhoto returns null when native returns null',
      () async {
        _responses['takeMultiCamPhoto'] = null;

        final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

        expect(result, isNull,
            reason: 'null native response must yield null — preview not active or no frame');
      },
    );

    test(
      'MC15-4 takeMultiCamPhoto returns null (does not rethrow) on PlatformException',
      () async {
        _responses['takeMultiCamPhoto'] = PlatformException(
          code: 'NOT_RUNNING',
          message: 'MultiCam preview is not running',
        );

        final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

        expect(result, isNull,
            reason: 'PlatformException must be caught and null returned, not rethrown');
      },
    );
  });

  // ── MC-17/MC-20: startMultiCamRecording / stopMultiCamRecording ─────────────
  //
  // Acceptance criteria:
  //   MC17-1  startMultiCamRecording invokes channel 'startMultiCamRecording' with correct path
  //   MC17-2  startMultiCamRecording returns true on native success (true)
  //   MC17-3  startMultiCamRecording returns false on PlatformException
  //   MC17-4  stopMultiCamRecording invokes channel 'stopMultiCamRecording' and parses result map
  //   MC17-5  stopMultiCamRecording returns null when native returns null
  //   MC17-6  stopMultiCamRecording returns null (not rethrow) on PlatformException

  group('VGCameraSession.startMultiCamRecording / stopMultiCamRecording (MC-17)', () {
    const kVideoPath = '/tmp/mc17_multicam_video_001.mp4';

    const kValidStopResponse = <Object?, Object?>{
      'filePath':                    kVideoPath,
      'durationSeconds':             10.5,
      'width':                       1080,
      'height':                      1920,
      'framesOffered':               315,
      'framesAppended':              315,
      'framesDroppedWriterNotReady': 0,
      'writerStatus':                2,   // AVAssetWriterStatusCompleted
      'fileSizeBytes':               15728640,
    };

    test(
      'MC17-1 startMultiCamRecording invokes channel with method name and correct path',
      () async {
        _responses['startMultiCamRecording'] = true;

        await VGCameraSession.startMultiCamRecording(kVideoPath);

        expect(_callCount('startMultiCamRecording'), equals(1),
            reason: 'must fire exactly one startMultiCamRecording channel call');
        final call = _log.firstWhere((c) => c.method == 'startMultiCamRecording');
        expect(call.arguments['path'], equals(kVideoPath),
            reason: 'must forward path as {path: ...} argument map');
      },
    );

    test(
      'MC17-2 startMultiCamRecording returns true when native returns true',
      () async {
        _responses['startMultiCamRecording'] = true;

        final ok = await VGCameraSession.startMultiCamRecording(kVideoPath);

        expect(ok, isTrue,
            reason: 'must return true when native responds with true');
      },
    );

    test(
      'MC17-3 startMultiCamRecording returns false (does not rethrow) on PlatformException',
      () async {
        _responses['startMultiCamRecording'] = PlatformException(
          code: 'NOT_RUNNING',
          message: 'MultiCam preview is not running',
        );

        final ok = await VGCameraSession.startMultiCamRecording(kVideoPath);

        expect(ok, isFalse,
            reason: 'PlatformException must be caught and false returned, not rethrown');
      },
    );

    test(
      'MC17-4 stopMultiCamRecording invokes channel and returns typed VGMultiCamRecordingStats',
      () async {
        _responses['stopMultiCamRecording'] = kValidStopResponse;

        final result = await VGCameraSession.stopMultiCamRecording();

        expect(_callCount('stopMultiCamRecording'), equals(1),
            reason: 'must fire exactly one stopMultiCamRecording channel call');
        expect(result, isNotNull,
            reason: 'must return non-null typed result for valid native response');
        expect(result, isA<VGMultiCamRecordingStats>());
        expect(result!.filePath,                    equals(kVideoPath));
        expect(result.durationSeconds,              equals(10.5));
        expect(result.width,                        equals(1080));
        expect(result.height,                       equals(1920));
        expect(result.framesOffered,                equals(315));
        expect(result.framesAppended,               equals(315));
        expect(result.framesDroppedWriterNotReady,  equals(0));
        expect(result.writerStatus,                 equals(2));
        expect(result.fileSizeBytes,                equals(15728640));
      },
    );

    test(
      'MC17-5 stopMultiCamRecording returns null when native returns null',
      () async {
        _responses['stopMultiCamRecording'] = null;

        final result = await VGCameraSession.stopMultiCamRecording();

        expect(result, isNull,
            reason: 'null native response must yield null typed result');
      },
    );

    test(
      'MC17-6 stopMultiCamRecording returns null (does not rethrow) on PlatformException',
      () async {
        _responses['stopMultiCamRecording'] = PlatformException(
          code: 'NOT_RECORDING',
          message: 'No recording is currently active',
        );

        final result = await VGCameraSession.stopMultiCamRecording();

        expect(result, isNull,
            reason: 'PlatformException must be caught and null typed result returned, not rethrown');
      },
    );
  });
}
