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
import 'package:vanguard_media_engine/vg_filter_spec.dart';
import 'package:vanguard_media_engine/vg_graph_transaction.dart';
import 'package:vanguard_media_engine/vg_preset_descriptor.dart';
import 'package:vanguard_media_engine/vg_recording_stats.dart';
import 'package:vanguard_media_engine/vg_photo_capture_result.dart';

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
}
