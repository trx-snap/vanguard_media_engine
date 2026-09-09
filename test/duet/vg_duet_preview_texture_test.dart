// Copyright 2026, Connects. All rights reserved.
// VG-DUET-SLICE-4A: Dart tests for preview texture lifecycle seam.
//
// Validated scope: serialization, channel payload encoding, returned texture
// parsing, detach route, and invalid native map handling.
//
// Explicitly NOT validated here:
//   - Native runtime rendering or pixel buffer production.
//   - Surface availability timing (platform-specific).
//   - Flutter Texture widget integration.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_platform_interface.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

const _sessionId = 'test-session-4a';
const _channelName = 'vanguard_media_engine';

class _FakeChannel extends Fake implements MethodChannel {
  String? lastMethod;
  dynamic lastArgs;
  dynamic returnValue;

  @override
  String get name => _channelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    lastMethod = method;
    lastArgs = arguments;
    if (returnValue is T?) return returnValue as T?;
    return null;
  }
}

// Minimal valid native reply for attachDuetPreviewTexture.
Map<String, dynamic> _validNativeReply({
  int textureId = 7,
  double width = 1080.0,
  double height = 1920.0,
  String state = 'surfaceAvailable',
  Map<String, dynamic>? layoutRects,
}) {
  return <String, dynamic>{
    'textureId': textureId,
    'width': width,
    'height': height,
    'state': state,
    if (layoutRects != null) 'layoutRects': layoutRects,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('VGDuetPreviewTextureState', () {
    test('enum values have expected names', () {
      expect(
        VGDuetPreviewTextureState.attachedWaitingSurface.name,
        'attachedWaitingSurface',
      );
      expect(
        VGDuetPreviewTextureState.surfaceAvailable.name,
        'surfaceAvailable',
      );
      expect(VGDuetPreviewTextureState.surfaceLost.name, 'surfaceLost');
      expect(VGDuetPreviewTextureState.detached.name, 'detached');
    });

    test('all four states are present', () {
      expect(VGDuetPreviewTextureState.values.length, 4);
    });
  });

  group('VGDuetPreviewTexture.toMap', () {
    test('round-trips textureId, size, state without layoutRects', () {
      final tex = VGDuetPreviewTexture(
        textureId: 42,
        size: const VGDuetSize(1920, 1080),
        state: VGDuetPreviewTextureState.surfaceAvailable,
      );
      final map = tex.toMap();
      expect(map['textureId'], 42);
      expect(map['width'], closeTo(1920.0, 1e-10));
      expect(map['height'], closeTo(1080.0, 1e-10));
      expect(map['state'], 'surfaceAvailable');
      expect(map.containsKey('layoutRects'), isFalse);
    });

    test('includes layoutRects when present', () {
      final tex = VGDuetPreviewTexture(
        textureId: 1,
        size: const VGDuetSize(1080, 1920),
        state: VGDuetPreviewTextureState.surfaceAvailable,
        layoutRects: {
          'source': const VGDuetRect(left: 0, top: 0, width: 540, height: 1920),
          'camera': const VGDuetRect(
            left: 540,
            top: 0,
            width: 540,
            height: 1920,
          ),
        },
      );
      final map = tex.toMap();
      expect(map['layoutRects'], isA<Map>());
    });
  });

  group('VGDuetPreviewTexture.fromMap', () {
    test('parses valid native reply', () {
      final tex = VGDuetPreviewTexture.fromMap(_validNativeReply());
      expect(tex.textureId, 7);
      expect(tex.size.width, closeTo(1080.0, 1e-10));
      expect(tex.size.height, closeTo(1920.0, 1e-10));
      expect(tex.state, VGDuetPreviewTextureState.surfaceAvailable);
      expect(tex.layoutRects, isNull);
    });

    test('accepts num textureId (e.g. double from platform codecs)', () {
      final tex = VGDuetPreviewTexture.fromMap(
        _validNativeReply(textureId: 0)..['textureId'] = 3.0,
      );
      expect(tex.textureId, 3);
    });

    test('parses attachedWaitingSurface state string', () {
      final tex = VGDuetPreviewTexture.fromMap(
        _validNativeReply(state: 'attachedWaitingSurface'),
      );
      expect(tex.state, VGDuetPreviewTextureState.attachedWaitingSurface);
    });

    test('parses surfaceLost state string', () {
      final tex = VGDuetPreviewTexture.fromMap(
        _validNativeReply(state: 'surfaceLost'),
      );
      expect(tex.state, VGDuetPreviewTextureState.surfaceLost);
    });

    test('throws VGDuetException for unknown state string', () {
      expect(
        () => VGDuetPreviewTexture.fromMap(
          _validNativeReply(state: 'unknownFutureState'),
        ),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });

    test('throws VGDuetException when state is missing (null)', () {
      final m = _validNativeReply()..remove('state');
      expect(
        () => VGDuetPreviewTexture.fromMap(m),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });

    test('parses layoutRects when present', () {
      final tex = VGDuetPreviewTexture.fromMap(
        _validNativeReply(
          layoutRects: {
            'source': {
              'left': 0.0,
              'top': 0.0,
              'width': 540.0,
              'height': 1920.0,
            },
            'camera': {
              'left': 540.0,
              'top': 0.0,
              'width': 540.0,
              'height': 1920.0,
            },
          },
        ),
      );
      expect(tex.layoutRects, isNotNull);
      expect(tex.layoutRects!['source']!.left, closeTo(0.0, 1e-10));
      expect(tex.layoutRects!['camera']!.left, closeTo(540.0, 1e-10));
    });

    test('throws VGDuetException when textureId is missing', () {
      expect(
        () => VGDuetPreviewTexture.fromMap({
          'width': 1080.0,
          'height': 1920.0,
          'state': 'surfaceAvailable',
        }),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });

    test('throws VGDuetException when width/height are missing', () {
      expect(
        () => VGDuetPreviewTexture.fromMap({
          'textureId': 1,
          'state': 'surfaceAvailable',
        }),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });

    test('throws VGDuetException when textureId has wrong type (string)', () {
      expect(
        () => VGDuetPreviewTexture.fromMap({
          'textureId': 'not-an-int',
          'width': 1080.0,
          'height': 1920.0,
          'state': 'surfaceAvailable',
        }),
        throwsA(isA<VGDuetException>()),
      );
    });
  });

  group('VGDuetPreviewTexture equality', () {
    test('equal when all fields match without layoutRects', () {
      const a = VGDuetPreviewTexture(
        textureId: 1,
        size: VGDuetSize(1080, 1920),
        state: VGDuetPreviewTextureState.surfaceAvailable,
      );
      const b = VGDuetPreviewTexture(
        textureId: 1,
        size: VGDuetSize(1080, 1920),
        state: VGDuetPreviewTextureState.surfaceAvailable,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('not equal when textureId differs', () {
      const a = VGDuetPreviewTexture(
        textureId: 1,
        size: VGDuetSize(1080, 1920),
        state: VGDuetPreviewTextureState.surfaceAvailable,
      );
      const b = VGDuetPreviewTexture(
        textureId: 2,
        size: VGDuetSize(1080, 1920),
        state: VGDuetPreviewTextureState.surfaceAvailable,
      );
      expect(a, isNot(equals(b)));
    });
  });

  // ── Platform interface channel tests ─────────────────────────────────────────

  group('MethodChannelVGDuetPlatform.attachPreviewTexture', () {
    late _FakeChannel fakeChannel;
    late MethodChannelVGDuetPlatform platform;

    setUp(() {
      fakeChannel = _FakeChannel();
      platform = MethodChannelVGDuetPlatform(channel: fakeChannel);
    });

    test('calls attachDuetPreviewTexture method name', () async {
      fakeChannel.returnValue = _validNativeReply();
      await platform.attachPreviewTexture(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'attachDuetPreviewTexture');
    });

    test('sends sessionId and canvasSize in payload', () async {
      fakeChannel.returnValue = _validNativeReply();
      const size = VGDuetSize(1280, 720);
      await platform.attachPreviewTexture(
        sessionId: _sessionId,
        canvasSize: size,
      );
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
      final cs = args['canvasSize'] as Map;
      expect(cs['width'], closeTo(1280.0, 1e-10));
      expect(cs['height'], closeTo(720.0, 1e-10));
    });

    test('includes layoutConfig in payload when provided', () async {
      fakeChannel.returnValue = _validNativeReply();
      final config = VGDuetLayoutConfig(mode: VGDuetLayoutMode.splitLeftRight);
      await platform.attachPreviewTexture(
        sessionId: _sessionId,
        layoutConfig: config,
      );
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args.containsKey('layoutConfig'), isTrue);
      expect((args['layoutConfig'] as Map)['mode'], 'splitLeftRight');
    });

    test('returns VGDuetPreviewTexture with correct textureId', () async {
      fakeChannel.returnValue = _validNativeReply(textureId: 99);
      final tex = await platform.attachPreviewTexture(sessionId: _sessionId);
      expect(tex.textureId, 99);
      expect(tex.state, VGDuetPreviewTextureState.surfaceAvailable);
    });

    test('throws VGDuetException when native returns null', () async {
      fakeChannel.returnValue = null;
      expect(
        () => platform.attachPreviewTexture(sessionId: _sessionId),
        throwsA(isA<VGDuetException>()),
      );
    });

    test('wraps PlatformException in VGDuetException', () async {
      final throwingChannel = _ThrowingChannel(
        PlatformException(code: 'composition_failed', message: 'no session'),
      );
      final p = MethodChannelVGDuetPlatform(channel: throwingChannel);
      expect(
        () => p.attachPreviewTexture(sessionId: _sessionId),
        throwsA(
          isA<VGDuetException>().having(
            (e) => e.code,
            'code',
            VGDuetErrorCode.compositionFailed,
          ),
        ),
      );
    });
  });

  group('MethodChannelVGDuetPlatform.detachPreviewTexture', () {
    late _FakeChannel fakeChannel;
    late MethodChannelVGDuetPlatform platform;

    setUp(() {
      fakeChannel = _FakeChannel();
      platform = MethodChannelVGDuetPlatform(channel: fakeChannel);
    });

    test('calls detachDuetPreviewTexture method name', () async {
      fakeChannel.returnValue = null;
      await platform.detachPreviewTexture(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'detachDuetPreviewTexture');
    });

    test('sends sessionId in payload', () async {
      fakeChannel.returnValue = null;
      await platform.detachPreviewTexture(sessionId: _sessionId);
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
    });

    test('completes normally without return value', () async {
      fakeChannel.returnValue = null;
      await expectLater(
        platform.detachPreviewTexture(sessionId: _sessionId),
        completes,
      );
    });

    test('wraps PlatformException in VGDuetException', () async {
      final throwingChannel = _ThrowingChannel(
        PlatformException(code: 'session_not_found', message: 'no session'),
      );
      final p = MethodChannelVGDuetPlatform(channel: throwingChannel);
      expect(
        () => p.detachPreviewTexture(sessionId: _sessionId),
        throwsA(isA<VGDuetException>()),
      );
    });
  });
}

// ── Helper: fake channel that always throws ───────────────────────────────────

class _ThrowingChannel extends Fake implements MethodChannel {
  final PlatformException exception;
  _ThrowingChannel(this.exception);

  @override
  String get name => 'vanguard_media_engine';

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    throw exception;
  }
}
