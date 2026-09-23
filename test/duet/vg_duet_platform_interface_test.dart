// Copyright 2026, Connects. All rights reserved.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_export.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_platform_interface.dart';
import 'package:vanguard_media_engine/vg_overlay_descriptor.dart';

const _channelName = 'vanguard_media_engine';
const _sessionId = 'test-session-001';

/// Records the last method call name and arguments.
class _FakeMethodChannel extends Fake implements MethodChannel {
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

void main() {
  late _FakeMethodChannel fakeChannel;
  late MethodChannelVGDuetPlatform platform;

  setUp(() {
    fakeChannel = _FakeMethodChannel();
    platform = MethodChannelVGDuetPlatform(channel: fakeChannel);
  });

  group('MethodChannelVGDuetPlatform method names', () {
    test('initializeSession calls initializeDuetSession', () async {
      fakeChannel.returnValue = 'session-abc';
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 10.0);
      await platform.initializeSession(source: src, trimWindow: trim);
      expect(fakeChannel.lastMethod, 'initializeDuetSession');
    });

    test('initializeSession payload contains source and trimWindow', () async {
      fakeChannel.returnValue = 'session-abc';
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 2.0, endSeconds: 12.0);
      await platform.initializeSession(source: src, trimWindow: trim);
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect((args['source'] as Map)['filePath'], '/tmp/clip.mp4');
      expect((args['trimWindow'] as Map)['startSeconds'], closeTo(2.0, 1e-10));
    });

    test('updateLayout calls updateDuetLayout with sessionId', () async {
      final config = VGDuetLayoutConfig(mode: VGDuetLayoutMode.pip);
      await platform.updateLayout(sessionId: _sessionId, layoutConfig: config);
      expect(fakeChannel.lastMethod, 'updateDuetLayout');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
      expect((args['layoutConfig'] as Map)['mode'], 'pip');
    });

    test('setRecordingSpeed calls setDuetRecordingSpeed', () async {
      await platform.setRecordingSpeed(sessionId: _sessionId, speed: 2.0);
      expect(fakeChannel.lastMethod, 'setDuetRecordingSpeed');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
      expect(args['speed'], closeTo(2.0, 1e-10));
    });

    test('setAudioMixGains calls setDuetAudioMixGains', () async {
      await platform.setAudioMixGains(
        sessionId: _sessionId,
        sourceGain: 0.7,
        micGain: 0.5,
      );
      expect(fakeChannel.lastMethod, 'setDuetAudioMixGains');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sourceGain'], closeTo(0.7, 1e-10));
      expect(args['micGain'], closeTo(0.5, 1e-10));
    });

    test('startRecording calls startDuetRecording', () async {
      await platform.startRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'startDuetRecording');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
    });

    test('pauseRecording calls pauseDuetRecording', () async {
      await platform.pauseRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'pauseDuetRecording');
    });

    test('resumeRecording calls resumeDuetRecording', () async {
      await platform.resumeRecording(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'resumeDuetRecording');
    });

    test('deleteLastSegment calls deleteLastDuetSegment', () async {
      await platform.deleteLastSegment(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'deleteLastDuetSegment');
    });

    test('disposeSession calls disposeDuetSession', () async {
      await platform.disposeSession(sessionId: _sessionId);
      expect(fakeChannel.lastMethod, 'disposeDuetSession');
      final args = fakeChannel.lastArgs as Map<String, dynamic>;
      expect(args['sessionId'], _sessionId);
    });
  });

  group('MethodChannelVGDuetPlatform error handling', () {
    test('initializeSession wraps null return in VGDuetException', () async {
      fakeChannel.returnValue = null;
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0);
      expect(
        () => platform.initializeSession(source: src, trimWindow: trim),
        throwsA(isA<VGDuetException>()),
      );
    });

    test(
      'initializeSession wraps empty sessionId in VGDuetException',
      () async {
        fakeChannel.returnValue = '';
        final src = VGDuetSource.localFile('/tmp/clip.mp4');
        final trim = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0);
        expect(
          () => platform.initializeSession(source: src, trimWindow: trim),
          throwsA(isA<VGDuetException>()),
        );
      },
    );
  });

  // ── Fix 1: stopRecording preserves native segmentCount ────────────────────

  group('stopRecording (Fix 1)', () {
    /// Minimal fake compositionDescriptor map that round-trips through
    /// VGDuetCompositionDescriptor.fromMap.
    Map<String, dynamic> descriptorMap() => {
      'source': {'filePath': '/tmp/source.mp4'},
      'layoutConfig': {
        'mode': 'splitLeftRight',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
      },
      'trimWindow': {'startSeconds': 0.0, 'endSeconds': 10.0},
      'initialSpeed': 1.0,
      'segments': [],
      'sourceAudioGain': 1.0,
      'micAudioGain': 1.0,
      'sourceAudioMuted': false,
      'micAudioMuted': false,
    };

    test(
      'uses native segmentCount when present, ignores top-level segments',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': descriptorMap(),
          'segmentAssets': ['/tmp/seg0.mp4', '/tmp/seg1.mp4', '/tmp/seg2.mp4'],
          'totalDurationMs': 6000,
          'segmentCount': 3, // native-provided; no top-level segments key
        };

        final result = await platform.stopRecording(sessionId: _sessionId);

        expect(result.segmentCount, 3);
        expect(
          result.compositionDescriptor,
          isA<VGDuetCompositionDescriptor>(),
        );
        expect(fakeChannel.lastMethod, 'stopDuetRecording');
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args['sessionId'], _sessionId);
      },
    );

    test(
      'falls back to segmentAssets.length when segmentCount absent',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': descriptorMap(),
          'segmentAssets': ['/tmp/seg0.mp4', '/tmp/seg1.mp4'],
          'totalDurationMs': 4000,
          // no segmentCount key
        };

        final result = await platform.stopRecording(sessionId: _sessionId);
        expect(result.segmentCount, 2);
      },
    );

    test(
      'throws VGDuetException when segmentCount absent and no assets/segments',
      () async {
        fakeChannel.returnValue = {
          'compositionDescriptor': descriptorMap(),
          'segmentAssets': [],
          'totalDurationMs': 1000,
          // no segmentCount, no segments, no assets
        };

        expect(
          () => platform.stopRecording(sessionId: _sessionId),
          throwsA(isA<VGDuetException>()),
        );
      },
    );
  });

  // ── Slice 5B-A: exportDuetComposition ────────────────────────────────────

  group('exportDuetComposition (Slice 5B-A)', () {
    VGDuetCompositionDescriptor makeDescriptor({
      VGDuetGreenScreenBackground? greenScreenBackground,
      List<VGOverlayDescriptor>? overlays,
    }) {
      return VGDuetCompositionDescriptor(
        source: VGDuetSource.localFile('/tmp/source.mp4'),
        layoutConfig: VGDuetLayoutConfig(
          mode: VGDuetLayoutMode.greenScreen,
          foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
          greenScreenBackground: greenScreenBackground,
        ),
        trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
        initialSpeed: 1.0,
        segments: [],
        overlays: overlays ?? const [],
      );
    }

    test('calls exportDuetComposition native method', () async {
      fakeChannel.returnValue = {
        'outputPath': '/tmp/out.mp4',
        'durationMs': 5000,
        'fileSizeBytes': 1024 * 1024,
      };
      await platform.exportDuetComposition(
        descriptor: makeDescriptor(),
        outputPath: '/tmp/out.mp4',
      );
      expect(fakeChannel.lastMethod, 'exportDuetComposition');
    });

    test(
      'payload contains descriptor, outputPath, targetSize, videoBitRate',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 4000,
          'fileSizeBytes': 512000,
        };
        const size = VGDuetSize(720, 1280);
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
          targetSize: size,
          videoBitRate: 4000000,
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args['outputPath'], '/tmp/out.mp4');
        expect((args['targetSize'] as Map)['width'], closeTo(720, 1e-10));
        expect((args['targetSize'] as Map)['height'], closeTo(1280, 1e-10));
        expect(args['videoBitRate'], 4000000);
        // descriptor must include source filePath
        final descMap = args['descriptor'] as Map;
        expect((descMap['source'] as Map)['filePath'], '/tmp/source.mp4');
      },
    );

    test('maps native result to VGDuetExportResult', () async {
      fakeChannel.returnValue = {
        'outputPath': '/data/out.mp4',
        'durationMs': 3000,
        'fileSizeBytes': 800000,
      };
      final result = await platform.exportDuetComposition(
        descriptor: makeDescriptor(),
        outputPath: '/data/out.mp4',
      );
      expect(result, isA<VGDuetExportResult>());
      expect(result.outputPath, '/data/out.mp4');
      expect(result.durationMs, 3000);
      expect(result.fileSizeBytes, 800000);
    });

    test(
      'maps native render-backend metadata onto VGDuetExportResult',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/data/out.mp4',
          'durationMs': 3000,
          'fileSizeBytes': 800000,
          'renderBackend': 'vulkan',
          'preferredRenderBackend': 'vulkan',
          'renderBackendReason': 'vulkan_preferred_and_supported',
          'renderBackendFallbackReason': null,
          'vulkanSupported': true,
          'glesSupported': true,
        };
        final result = await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/data/out.mp4',
        );
        expect(result.renderBackend, 'vulkan');
        expect(result.preferredRenderBackend, 'vulkan');
        expect(result.renderBackendReason, 'vulkan_preferred_and_supported');
        expect(result.renderBackendFallbackReason, isNull);
        expect(result.vulkanSupported, isTrue);
        expect(result.glesSupported, isTrue);
      },
    );

    test(
      'maps native gles fallback metadata onto VGDuetExportResult',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/data/out.mp4',
          'durationMs': 3000,
          'fileSizeBytes': 800000,
          'renderBackend': 'gles',
          'preferredRenderBackend': 'vulkan',
          'renderBackendReason': 'vulkan_preferred_and_supported',
          'renderBackendFallbackReason': 'vulkan_render_failed',
          'vulkanSupported': true,
          'glesSupported': true,
        };
        final result = await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/data/out.mp4',
        );
        expect(result.renderBackend, 'gles');
        expect(result.preferredRenderBackend, 'vulkan');
        expect(result.renderBackendFallbackReason, 'vulkan_render_failed');
      },
    );

    test(
      'default targetSize is 1080x1920 and default bitrate is 8 Mbps',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/x.mp4',
          'durationMs': 2000,
          'fileSizeBytes': 100000,
        };
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/x.mp4',
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect((args['targetSize'] as Map)['width'], closeTo(1080, 1e-10));
        expect((args['targetSize'] as Map)['height'], closeTo(1920, 1e-10));
        expect(args['videoBitRate'], 8000000);
      },
    );

    test('wraps null result in VGDuetException(compositionFailed)', () {
      fakeChannel.returnValue = null; // null triggers VGDuetException
      expect(
        () => platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
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

    test(
      'payload includes greenScreenBackground map when solidColor background is present',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        final desc = makeDescriptor(
          greenScreenBackground: const VGDuetGreenScreenBackground.solidColor(
            0xFF336699,
          ),
        );
        await platform.exportDuetComposition(
          descriptor: desc,
          outputPath: '/tmp/out.mp4',
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        final descMap = args['descriptor'] as Map;
        final layoutMap = descMap['layoutConfig'] as Map;
        expect(layoutMap.containsKey('greenScreenBackground'), isTrue);
        final bgMap = layoutMap['greenScreenBackground'] as Map;
        expect(bgMap['type'], 'solidColor');
        expect(bgMap['argbColor'], 0xFF336699);
      },
    );

    test(
      'payload includes greenScreenBackground map when image background is present',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        final desc = makeDescriptor(
          greenScreenBackground: const VGDuetGreenScreenBackground.imageFile(
            '/path/to/bg.png',
            scaleMode: VGDuetBackgroundScaleMode.aspectFit,
          ),
        );
        await platform.exportDuetComposition(
          descriptor: desc,
          outputPath: '/tmp/out.mp4',
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        final descMap = args['descriptor'] as Map;
        final layoutMap = descMap['layoutConfig'] as Map;
        expect(layoutMap.containsKey('greenScreenBackground'), isTrue);
        final bgMap = layoutMap['greenScreenBackground'] as Map;
        expect(bgMap['type'], 'image');
        expect(bgMap['filePath'], '/path/to/bg.png');
        expect(bgMap['scaleMode'], 'aspectFit');
      },
    );

    test(
      'payload includes greenScreenBackground map when video background is present',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        final desc = makeDescriptor(
          greenScreenBackground: const VGDuetGreenScreenBackground.video(),
        );
        await platform.exportDuetComposition(
          descriptor: desc,
          outputPath: '/tmp/out.mp4',
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        final descMap = args['descriptor'] as Map;
        final layoutMap = descMap['layoutConfig'] as Map;
        expect(layoutMap.containsKey('greenScreenBackground'), isTrue);
        final bgMap = layoutMap['greenScreenBackground'] as Map;
        expect(bgMap['type'], 'video');
      },
    );

    test(
      'payload omits greenScreenBackground map when background is absent',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        final desc = makeDescriptor(greenScreenBackground: null);
        await platform.exportDuetComposition(
          descriptor: desc,
          outputPath: '/tmp/out.mp4',
        );
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        final descMap = args['descriptor'] as Map;
        final layoutMap = descMap['layoutConfig'] as Map;
        expect(layoutMap.containsKey('greenScreenBackground'), isFalse);
      },
    );

    test('VGDuetExportResult toMap/fromMap round-trips', () {
      final r = VGDuetExportResult(
        outputPath: '/tmp/round.mp4',
        durationMs: 7500,
        fileSizeBytes: 2048000,
      );
      final map = r.toMap();
      final r2 = VGDuetExportResult.fromMap(map);
      expect(r2.outputPath, r.outputPath);
      expect(r2.durationMs, r.durationMs);
      expect(r2.fileSizeBytes, r.fileSizeBytes);
      expect(r2.renderBackend, isNull);
      expect(r2.preferredRenderBackend, isNull);
      expect(r2.renderBackendReason, isNull);
      expect(r2.renderBackendFallbackReason, isNull);
      expect(r2.vulkanSupported, isNull);
      expect(r2.glesSupported, isNull);
    });

    test(
      'VGDuetExportResult toMap/fromMap round-trips render-backend metadata',
      () {
        final r = VGDuetExportResult(
          outputPath: '/tmp/round.mp4',
          durationMs: 7500,
          fileSizeBytes: 2048000,
          renderBackend: 'vulkan',
          preferredRenderBackend: 'vulkan',
          renderBackendReason: 'vulkan_preferred_and_supported',
          renderBackendFallbackReason: null,
          vulkanSupported: true,
          glesSupported: false,
        );
        final map = r.toMap();
        final r2 = VGDuetExportResult.fromMap(map);
        expect(r2.renderBackend, 'vulkan');
        expect(r2.preferredRenderBackend, 'vulkan');
        expect(r2.renderBackendReason, 'vulkan_preferred_and_supported');
        expect(r2.renderBackendFallbackReason, isNull);
        expect(r2.vulkanSupported, isTrue);
        expect(r2.glesSupported, isFalse);
        expect(r2, equals(r));
      },
    );

    test('VGDuetExportResult equality', () {
      final r1 = VGDuetExportResult(
        outputPath: '/tmp/eq.mp4',
        durationMs: 1000,
        fileSizeBytes: 512,
      );
      final r2 = VGDuetExportResult(
        outputPath: '/tmp/eq.mp4',
        durationMs: 1000,
        fileSizeBytes: 512,
      );
      expect(r1, equals(r2));
    });

    test(
      'VGDuetExportResult equality distinguishes render-backend metadata',
      () {
        final r1 = VGDuetExportResult(
          outputPath: '/tmp/eq.mp4',
          durationMs: 1000,
          fileSizeBytes: 512,
          renderBackend: 'vulkan',
        );
        final r2 = VGDuetExportResult(
          outputPath: '/tmp/eq.mp4',
          durationMs: 1000,
          fileSizeBytes: 512,
          renderBackend: 'gles',
        );
        expect(r1, isNot(equals(r2)));
      },
    );

    test(
      'exportDuetComposition method-channel args include descriptor["overlays"] proving carriage of creator overlays',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };

        final textOverlay = VGOverlayDescriptor(
          id: 'slice3_text_overlay',
          type: VGOverlayType.text,
          startTimeSeconds: 0.5,
          durationSeconds: 4.0,
          translationX: 100.0,
          translationY: 200.0,
          width: 350.0,
          height: 90.0,
          rotation: 0.15,
          scale: 1.0,
          opacity: 0.95,
          zIndex: 4,
          textContent: 'SLICE3',
        );

        final stickerOverlay = VGOverlayDescriptor(
          id: 'slice3_sticker_overlay',
          type: VGOverlayType.sticker,
          startTimeSeconds: 1.0,
          durationSeconds: 3.0,
          translationX: 40.0,
          translationY: 80.0,
          width: 120.0,
          height: 120.0,
          rotation: -0.3,
          scale: 0.9,
          opacity: 1.0,
          zIndex: 7,
          assetPath: '/tmp/assets/sticker.png',
        );

        final desc = makeDescriptor(overlays: [textOverlay, stickerOverlay]);
        await platform.exportDuetComposition(
          descriptor: desc,
          outputPath: '/tmp/out.mp4',
        );

        expect(fakeChannel.lastMethod, 'exportDuetComposition');
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        final descMap = args['descriptor'] as Map;
        expect(descMap.containsKey('overlays'), isTrue);

        final overlaysList = descMap['overlays'] as List;
        expect(overlaysList.length, 2);

        // Verify text overlay carriage
        final textMap = overlaysList[0] as Map<String, dynamic>;
        expect(textMap['id'], 'slice3_text_overlay');
        expect(textMap['type'], 'text');
        expect(textMap['startTimeSeconds'], closeTo(0.5, 1e-10));
        expect(textMap['durationSeconds'], closeTo(4.0, 1e-10));
        expect(textMap['translationX'], closeTo(100.0, 1e-10));
        expect(textMap['translationY'], closeTo(200.0, 1e-10));
        expect(textMap['width'], closeTo(350.0, 1e-10));
        expect(textMap['height'], closeTo(90.0, 1e-10));
        expect(textMap['rotation'], closeTo(0.15, 1e-10));
        expect(textMap['scale'], closeTo(1.0, 1e-10));
        expect(textMap['opacity'], closeTo(0.95, 1e-10));
        expect(textMap['zIndex'], 4);
        expect(textMap['textContent'], 'SLICE3');

        // Verify sticker overlay carriage
        final stickerMap = overlaysList[1] as Map<String, dynamic>;
        expect(stickerMap['id'], 'slice3_sticker_overlay');
        expect(stickerMap['type'], 'sticker');
        expect(stickerMap['startTimeSeconds'], closeTo(1.0, 1e-10));
        expect(stickerMap['durationSeconds'], closeTo(3.0, 1e-10));
        expect(stickerMap['translationX'], closeTo(40.0, 1e-10));
        expect(stickerMap['translationY'], closeTo(80.0, 1e-10));
        expect(stickerMap['width'], closeTo(120.0, 1e-10));
        expect(stickerMap['height'], closeTo(120.0, 1e-10));
        expect(stickerMap['rotation'], closeTo(-0.3, 1e-10));
        expect(stickerMap['scale'], closeTo(0.9, 1e-10));
        expect(stickerMap['opacity'], closeTo(1.0, 1e-10));
        expect(stickerMap['zIndex'], 7);
        expect(stickerMap['assetPath'], '/tmp/assets/sticker.png');
      },
    );

    test(
      'exportDuetComposition passes segmentAssets through to MethodChannel args when supplied',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        final assets = ['/tmp/seg_0.mp4', '/tmp/seg_1.mp4'];
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
          segmentAssets: assets,
        );
        expect(fakeChannel.lastMethod, 'exportDuetComposition');
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args.containsKey('segmentAssets'), isTrue);
        expect(args['segmentAssets'], equals(assets));
      },
    );

    test(
      'exportDuetComposition passes empty segmentAssets list through to MethodChannel args when supplied',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
          segmentAssets: const [],
        );
        expect(fakeChannel.lastMethod, 'exportDuetComposition');
        final args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args.containsKey('segmentAssets'), isTrue);
        expect(args['segmentAssets'], isEmpty);
      },
    );

    test(
      'exportDuetComposition omits segmentAssets from MethodChannel args when omitted or null',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/tmp/out.mp4',
          'durationMs': 5000,
          'fileSizeBytes': 1024 * 1024,
        };
        // Omitted
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
        );
        var args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args.containsKey('segmentAssets'), isFalse);

        // Explicit null
        await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/tmp/out.mp4',
          segmentAssets: null,
        );
        args = fakeChannel.lastArgs as Map<String, dynamic>;
        expect(args.containsKey('segmentAssets'), isFalse);
      },
    );

    test(
      'exportDuetComposition parses export result when segmentAssets is supplied',
      () async {
        fakeChannel.returnValue = {
          'outputPath': '/data/exported_duet.mp4',
          'durationMs': 4500,
          'fileSizeBytes': 1500000,
          'renderBackend': 'vulkan',
        };
        final result = await platform.exportDuetComposition(
          descriptor: makeDescriptor(),
          outputPath: '/data/exported_duet.mp4',
          segmentAssets: ['/tmp/seg_0.mp4'],
        );
        expect(result, isA<VGDuetExportResult>());
        expect(result.outputPath, '/data/exported_duet.mp4');
        expect(result.durationMs, 4500);
        expect(result.fileSizeBytes, 1500000);
        expect(result.renderBackend, 'vulkan');
      },
    );
  });
}
