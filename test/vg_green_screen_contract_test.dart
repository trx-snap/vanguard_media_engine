// Copyright 2026, Connects. All rights reserved.
// Unit tests for the generic green-screen export public Dart contract.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_green_screen.dart';

const String _kChannelName = 'vanguard_media_engine';
const String _kExportMethod = 'exportGreenScreenComposition';

/// Test double for [MethodChannel] recording calls and returning stubbed responses.
class _FakeMethodChannel extends Fake implements MethodChannel {
  String? lastMethod;
  dynamic lastArgs;
  dynamic returnValue;
  Object? errorToThrow;

  @override
  String get name => _kChannelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    lastMethod = method;
    lastArgs = arguments;
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    if (returnValue is T?) {
      return returnValue as T?;
    }
    return null;
  }
}

void main() {
  group('VGGreenScreenExportRequest serialization', () {
    test('toMap has exact wire keys/values and fromMap round-trips', () {
      final request = VGGreenScreenExportRequest(
        foregroundVideoPath: '/path/to/fg_clip.mp4',
        background: const VGGreenScreenBackgroundSource.imageFile(
          '/path/to/bg_image.png',
          scaleMode: VGGreenScreenScaleMode.aspectFit,
        ),
        mask: const VGGreenScreenMaskSource.r8FrameFiles(
          <String>['/path/to/mask_000.r8', '/path/to/mask_001.r8'],
          width: 640,
          height: 480,
          rowStrideBytes: 640,
        ),
        outputPath: '/path/to/output_export.mp4',
        targetSize: const VGGreenScreenSize(720, 1280),
        fps: 30,
        videoBitRate: 8000000,
        outputFrameCount: 2,
        foregroundRect: const VGGreenScreenRect(
          x: 10,
          y: 20,
          width: 500,
          height: 600,
        ),
        backgroundRect: const VGGreenScreenRect(
          x: 0,
          y: 50,
          width: 720,
          height: 1200,
        ),
        foregroundRotationDegrees: 90,
        backgroundRotationDegrees: 180,
        foregroundMirrorHorizontal: true,
        backgroundMirrorHorizontal: true,
      );

      final map = request.toMap();

      // Assert exact wire keys and values
      expect(map, <String, dynamic>{
        'foregroundVideoPath': '/path/to/fg_clip.mp4',
        'background': <String, dynamic>{
          'type': 'imageFile',
          'path': '/path/to/bg_image.png',
          'scaleMode': 'aspectFit',
        },
        'mask': <String, dynamic>{
          'type': 'r8FrameFiles',
          'framePaths': <String>[
            '/path/to/mask_000.r8',
            '/path/to/mask_001.r8',
          ],
          'width': 640,
          'height': 480,
          'rowStrideBytes': 640,
        },
        'outputPath': '/path/to/output_export.mp4',
        'targetSize': <String, dynamic>{'width': 720, 'height': 1280},
        'fps': 30,
        'videoBitRate': 8000000,
        'outputFrameCount': 2,
        'foregroundRect': <String, dynamic>{
          'x': 10,
          'y': 20,
          'width': 500,
          'height': 600,
        },
        'backgroundRect': <String, dynamic>{
          'x': 0,
          'y': 50,
          'width': 720,
          'height': 1200,
        },
        'foregroundRotationDegrees': 90,
        'backgroundRotationDegrees': 180,
        'foregroundMirrorHorizontal': true,
        'backgroundMirrorHorizontal': true,
      });

      // fromMap round-trips to equal request
      final restored = VGGreenScreenExportRequest.fromMap(map);
      expect(restored, equals(request));
      expect(restored.hashCode, equals(request.hashCode));
      expect(restored.nominalDuration, equals(request.nominalDuration));
    });
  });

  group('VGGreenScreenExportRequest validation', () {
    VGGreenScreenExportRequest buildValidRequest({
      String foregroundVideoPath = '/path/to/fg.mp4',
      VGGreenScreenBackgroundSource background =
          const VGGreenScreenBackgroundSource.videoFile('/path/to/bg.mp4'),
      VGGreenScreenMaskSource mask =
          const VGGreenScreenMaskSource.constantAlpha(200),
      String outputPath = '/path/to/out.mp4',
      VGGreenScreenSize targetSize = const VGGreenScreenSize(1080, 1920),
      int fps = 30,
      int videoBitRate = 8000000,
      int outputFrameCount = 10,
      VGGreenScreenRect? foregroundRect,
      VGGreenScreenRect? backgroundRect,
      int foregroundRotationDegrees = 0,
      int backgroundRotationDegrees = 0,
      bool foregroundMirrorHorizontal = false,
      bool backgroundMirrorHorizontal = false,
    }) {
      return VGGreenScreenExportRequest(
        foregroundVideoPath: foregroundVideoPath,
        background: background,
        mask: mask,
        outputPath: outputPath,
        targetSize: targetSize,
        fps: fps,
        videoBitRate: videoBitRate,
        outputFrameCount: outputFrameCount,
        foregroundRect: foregroundRect,
        backgroundRect: backgroundRect,
        foregroundRotationDegrees: foregroundRotationDegrees,
        backgroundRotationDegrees: backgroundRotationDegrees,
        foregroundMirrorHorizontal: foregroundMirrorHorizontal,
        backgroundMirrorHorizontal: backgroundMirrorHorizontal,
      );
    }

    test('rejects blank foreground path', () {
      expect(
        () => buildValidRequest(foregroundVideoPath: ''),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(foregroundVideoPath: '   '),
        throwsArgumentError,
      );
    });

    test('rejects blank output path', () {
      expect(() => buildValidRequest(outputPath: ''), throwsArgumentError);
      expect(() => buildValidRequest(outputPath: '   '), throwsArgumentError);
    });

    test('rejects non-cardinal rotation', () {
      expect(
        () => buildValidRequest(foregroundRotationDegrees: 45),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(foregroundRotationDegrees: -90),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(foregroundRotationDegrees: 360),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(backgroundRotationDegrees: 1),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(backgroundRotationDegrees: 271),
        throwsArgumentError,
      );
    });

    test('rejects out-of-bounds rect', () {
      // Exceeds target width (1000 + 100 > 1080)
      expect(
        () => buildValidRequest(
          foregroundRect: const VGGreenScreenRect(
            x: 1000,
            y: 0,
            width: 100,
            height: 100,
          ),
        ),
        throwsArgumentError,
      );
      // Exceeds target height (0 + 1921 > 1920)
      expect(
        () => buildValidRequest(
          foregroundRect: const VGGreenScreenRect(
            x: 0,
            y: 0,
            width: 100,
            height: 1921,
          ),
        ),
        throwsArgumentError,
      );
      // Negative coordinate
      expect(
        () => buildValidRequest(
          foregroundRect: const VGGreenScreenRect(
            x: -1,
            y: 0,
            width: 100,
            height: 100,
          ),
        ),
        throwsArgumentError,
      );
      // Background rect out-of-bounds
      expect(
        () => buildValidRequest(
          backgroundRect: const VGGreenScreenRect(
            x: 0,
            y: 1900,
            width: 100,
            height: 50,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects r8FrameFiles with fewer than outputFrameCount entries', () {
      expect(
        () => buildValidRequest(
          outputFrameCount: 3,
          mask: const VGGreenScreenMaskSource.r8FrameFiles(
            <String>['/mask_0.r8', '/mask_1.r8'],
            width: 64,
            height: 64,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative or too-small rowStrideBytes', () {
      expect(
        () => buildValidRequest(
          outputFrameCount: 1,
          mask: const VGGreenScreenMaskSource.r8FrameFiles(
            <String>['/mask_0.r8'],
            width: 100,
            height: 100,
            rowStrideBytes: -1,
          ),
        ),
        throwsArgumentError,
      );
      // rowStrideBytes > 0 but < width
      expect(
        () => buildValidRequest(
          outputFrameCount: 1,
          mask: const VGGreenScreenMaskSource.r8FrameFiles(
            <String>['/mask_0.r8'],
            width: 100,
            height: 100,
            rowStrideBytes: 99,
          ),
        ),
        throwsArgumentError,
      );
      // rowStrideBytes == 0 (tightly packed) and rowStrideBytes >= width are valid
      expect(
        buildValidRequest(
          outputFrameCount: 1,
          mask: const VGGreenScreenMaskSource.r8FrameFiles(
            <String>['/mask_0.r8'],
            width: 100,
            height: 100,
            rowStrideBytes: 0,
          ),
        ),
        isNotNull,
      );
      expect(
        buildValidRequest(
          outputFrameCount: 1,
          mask: const VGGreenScreenMaskSource.r8FrameFiles(
            <String>['/mask_0.r8'],
            width: 100,
            height: 100,
            rowStrideBytes: 128,
          ),
        ),
        isNotNull,
      );
    });

    test('rejects constantAlpha outside 0..255', () {
      expect(
        () => buildValidRequest(
          mask: const VGGreenScreenMaskSource.constantAlpha(-1),
        ),
        throwsArgumentError,
      );
      expect(
        () => buildValidRequest(
          mask: const VGGreenScreenMaskSource.constantAlpha(256),
        ),
        throwsArgumentError,
      );
      // Valid boundary values
      expect(
        buildValidRequest(mask: const VGGreenScreenMaskSource.constantAlpha(0)),
        isNotNull,
      );
      expect(
        buildValidRequest(
          mask: const VGGreenScreenMaskSource.constantAlpha(255),
        ),
        isNotNull,
      );
    });
  });

  group('Background and mask parsing', () {
    test('fromMap rejects unknown background type', () {
      expect(
        () => VGGreenScreenBackgroundSource.fromMap(<String, dynamic>{
          'type': 'unsupportedBackgroundType',
        }),
        throwsArgumentError,
      );
    });

    test('fromMap rejects unknown mask type', () {
      expect(
        () => VGGreenScreenMaskSource.fromMap(<String, dynamic>{
          'type': 'unsupportedMaskType',
        }),
        throwsArgumentError,
      );
    });

    test(
      'imageFile background with missing scaleMode defaults to aspectFill',
      () {
        final bg = VGGreenScreenBackgroundSource.fromMap(<String, dynamic>{
          'type': 'imageFile',
          'path': '/path/to/bg.png',
        });
        expect(bg, isA<VGGreenScreenImageFileBackground>());
        expect(
          (bg as VGGreenScreenImageFileBackground).scaleMode,
          equals(VGGreenScreenScaleMode.aspectFill),
        );
      },
    );

    test('imageFile background parses explicit scaleMode', () {
      final bg = VGGreenScreenBackgroundSource.fromMap(<String, dynamic>{
        'type': 'imageFile',
        'path': '/path/to/bg.png',
        'scaleMode': 'aspectFit',
      });
      expect(bg, isA<VGGreenScreenImageFileBackground>());
      expect(
        (bg as VGGreenScreenImageFileBackground).scaleMode,
        equals(VGGreenScreenScaleMode.aspectFit),
      );
    });

    test('constantAlpha mask fromMap parses with default width and height', () {
      final mask = VGGreenScreenMaskSource.fromMap(<String, dynamic>{
        'type': 'constantAlpha',
        'alpha': 180,
      });
      expect(mask, isA<VGGreenScreenConstantAlphaMask>());
      final alphaMask = mask as VGGreenScreenConstantAlphaMask;
      expect(alphaMask.alpha, 180);
      expect(alphaMask.width, 64);
      expect(alphaMask.height, 64);
    });

    test('r8FrameFiles mask fromMap parses with default rowStrideBytes 0', () {
      final mask = VGGreenScreenMaskSource.fromMap(<String, dynamic>{
        'type': 'r8FrameFiles',
        'framePaths': <String>['/f0.r8', '/f1.r8'],
        'width': 320,
        'height': 240,
      });
      expect(mask, isA<VGGreenScreenR8FrameFilesMask>());
      final r8Mask = mask as VGGreenScreenR8FrameFilesMask;
      expect(r8Mask.framePaths, <String>['/f0.r8', '/f1.r8']);
      expect(r8Mask.width, 320);
      expect(r8Mask.height, 240);
      expect(r8Mask.rowStrideBytes, 0);
      expect(r8Mask.bytesPerFrame, 320 * 240);
    });
  });

  group('Result parsing and derived properties', () {
    Map<String, dynamic> buildValidResultMap({
      String outputPath = '/data/export_out.mp4',
      num durationMs = 4500,
      num fileSizeBytes = 2048576,
      int renderedFrames = 135,
      int writtenVideoSamples = 135,
      String backgroundSourceType = 'videoFile',
      List<String>? claims,
    }) {
      return <String, dynamic>{
        'outputPath': outputPath,
        'durationMs': durationMs,
        'fileSizeBytes': fileSizeBytes,
        'terminalState': 'success',
        'reason': 'export_completed',
        'fps': 30,
        'outputFrameCount': 135,
        'renderedFrames': renderedFrames,
        'writtenVideoSamples': writtenVideoSamples,
        'maskWidth': 720,
        'maskHeight': 1280,
        'tmpExists': false,
        'backgroundSourceType': backgroundSourceType,
        'backgroundGeneratedFrames': 0,
        'backgroundGeneratedTmpExists': false,
        'backgroundDecoderName': 'c2.android.avc.decoder',
        'backgroundContentWidth': 1080,
        'backgroundContentHeight': 1920,
        'backgroundContainerRotationDegrees': 0,
        'backgroundDecodedFrames': 135,
        'backgroundHeldFrames': 0,
        'backgroundHeldAfterEosFrames': 0,
        'backgroundDroppedFrames': 0,
        'backgroundEosReached': true,
        'foregroundDecoderName': 'c2.android.hevc.decoder',
        'foregroundContentWidth': 720,
        'foregroundContentHeight': 1280,
        'foregroundContainerRotationDegrees': 90,
        'foregroundDecodedFrames': 135,
        'foregroundHeldFrames': 1,
        'foregroundHeldAfterEosFrames': 0,
        'foregroundDroppedFrames': 0,
        'foregroundEosReached': true,
        'claims': claims ?? <String>['hardware_decoder', 'smooth_pairing'],
      };
    }

    test('fromMap parses lane telemetry, claims, and flags correctly', () {
      final map = buildValidResultMap();
      final result = VGGreenScreenExportResult.fromMap(map);

      expect(result.outputPath, '/data/export_out.mp4');
      expect(result.durationMs, 4500);
      expect(result.fileSizeBytes, 2048576);
      expect(result.terminalState, 'success');
      expect(result.reason, 'export_completed');
      expect(result.fps, 30);
      expect(result.outputFrameCount, 135);
      expect(result.renderedFrames, 135);
      expect(result.writtenVideoSamples, 135);
      expect(result.maskWidth, 720);
      expect(result.maskHeight, 1280);
      expect(result.tmpExists, isFalse);
      expect(result.claims, <String>['hardware_decoder', 'smooth_pairing']);

      // Background lane telemetry
      expect(result.background.decoderName, 'c2.android.avc.decoder');
      expect(result.background.contentWidth, 1080);
      expect(result.background.contentHeight, 1920);
      expect(result.background.containerRotationDegrees, 0);
      expect(result.background.decodedFrames, 135);
      expect(result.background.heldFrames, 0);
      expect(result.background.heldAfterEosFrames, 0);
      expect(result.background.droppedFrames, 0);
      expect(result.background.eosReached, isTrue);

      // Foreground lane telemetry
      expect(result.foreground.decoderName, 'c2.android.hevc.decoder');
      expect(result.foreground.contentWidth, 720);
      expect(result.foreground.contentHeight, 1280);
      expect(result.foreground.containerRotationDegrees, 90);
      expect(result.foreground.decodedFrames, 135);
      expect(result.foreground.heldFrames, 1);
      expect(result.foreground.heldAfterEosFrames, 0);
      expect(result.foreground.droppedFrames, 0);
      expect(result.foreground.eosReached, isTrue);
    });

    test('renderedEqualsWritten derived getter reflects frame counts', () {
      final matching = VGGreenScreenExportResult.fromMap(
        buildValidResultMap(renderedFrames: 100, writtenVideoSamples: 100),
      );
      expect(matching.renderedEqualsWritten, isTrue);

      final mismatched = VGGreenScreenExportResult.fromMap(
        buildValidResultMap(renderedFrames: 100, writtenVideoSamples: 99),
      );
      expect(mismatched.renderedEqualsWritten, isFalse);
    });

    test(
      'backgroundGenerated derived getter reflects backgroundSourceType',
      () {
        final videoBg = VGGreenScreenExportResult.fromMap(
          buildValidResultMap(backgroundSourceType: 'videoFile'),
        );
        expect(videoBg.backgroundGenerated, isFalse);

        final imageBg = VGGreenScreenExportResult.fromMap(
          buildValidResultMap(backgroundSourceType: 'imageFile'),
        );
        expect(imageBg.backgroundGenerated, isTrue);

        final solidBg = VGGreenScreenExportResult.fromMap(
          buildValidResultMap(backgroundSourceType: 'solidColor'),
        );
        expect(solidBg.backgroundGenerated, isTrue);
      },
    );

    test('rejects missing or invalid outputPath', () {
      final mapNoPath = buildValidResultMap()..remove('outputPath');
      expect(
        () => VGGreenScreenExportResult.fromMap(mapNoPath),
        throwsArgumentError,
      );

      final mapWrongType = buildValidResultMap()..['outputPath'] = 12345;
      expect(
        () => VGGreenScreenExportResult.fromMap(mapWrongType),
        throwsArgumentError,
      );
    });

    test('rejects missing or non-num durationMs', () {
      final mapNoDuration = buildValidResultMap()..remove('durationMs');
      expect(
        () => VGGreenScreenExportResult.fromMap(mapNoDuration),
        throwsArgumentError,
      );

      final mapWrongType = buildValidResultMap()..['durationMs'] = 'not_a_num';
      expect(
        () => VGGreenScreenExportResult.fromMap(mapWrongType),
        throwsArgumentError,
      );
    });

    test('rejects missing or non-num fileSizeBytes', () {
      final mapNoSize = buildValidResultMap()..remove('fileSizeBytes');
      expect(
        () => VGGreenScreenExportResult.fromMap(mapNoSize),
        throwsArgumentError,
      );

      final mapWrongType = buildValidResultMap()
        ..['fileSizeBytes'] = 'not_a_num';
      expect(
        () => VGGreenScreenExportResult.fromMap(mapWrongType),
        throwsArgumentError,
      );
    });

    test('toMap and fromMap round-trip preserves all properties', () {
      final original = VGGreenScreenExportResult.fromMap(buildValidResultMap());
      final map = original.toMap();
      final roundTripped = VGGreenScreenExportResult.fromMap(map);
      expect(roundTripped, equals(original));
      expect(roundTripped.hashCode, equals(original.hashCode));
    });
  });

  group('MethodChannelVGGreenScreenPlatform success', () {
    test(
      'invokes exportGreenScreenComposition with request.toMap and parses result',
      () async {
        final fakeChannel = _FakeMethodChannel();
        final platform = MethodChannelVGGreenScreenPlatform(
          channel: fakeChannel,
        );

        final request = VGGreenScreenExportRequest(
          foregroundVideoPath: '/storage/emulated/0/fg.mp4',
          background: const VGGreenScreenBackgroundSource.solidColor(
            0xFF00FF00,
          ),
          mask: const VGGreenScreenMaskSource.constantAlpha(255),
          outputPath: '/storage/emulated/0/final.mp4',
          outputFrameCount: 30,
        );

        final expectedResultMap = <String, dynamic>{
          'outputPath': '/storage/emulated/0/final.mp4',
          'durationMs': 1000,
          'fileSizeBytes': 524288,
          'terminalState': 'success',
          'reason': 'export_completed',
          'fps': 30,
          'outputFrameCount': 30,
          'renderedFrames': 30,
          'writtenVideoSamples': 30,
          'maskWidth': 64,
          'maskHeight': 64,
          'tmpExists': false,
          'backgroundSourceType': 'solidColor',
          'backgroundGeneratedFrames': 30,
          'backgroundGeneratedTmpExists': false,
          'backgroundDecoderName': 'c2.android.avc.decoder',
          'backgroundContentWidth': 1080,
          'backgroundContentHeight': 1920,
          'backgroundContainerRotationDegrees': 0,
          'backgroundDecodedFrames': 30,
          'backgroundHeldFrames': 0,
          'backgroundHeldAfterEosFrames': 0,
          'backgroundDroppedFrames': 0,
          'backgroundEosReached': true,
          'foregroundDecoderName': 'c2.android.hevc.decoder',
          'foregroundContentWidth': 1080,
          'foregroundContentHeight': 1920,
          'foregroundContainerRotationDegrees': 0,
          'foregroundDecodedFrames': 30,
          'foregroundHeldFrames': 0,
          'foregroundHeldAfterEosFrames': 0,
          'foregroundDroppedFrames': 0,
          'foregroundEosReached': true,
          'claims': <String>['solid_color_synth'],
        };

        fakeChannel.returnValue = expectedResultMap;

        final result = await platform.exportGreenScreenComposition(
          request: request,
        );

        expect(fakeChannel.lastMethod, equals(_kExportMethod));
        expect(fakeChannel.lastArgs, equals(request.toMap()));
        expect(result.outputPath, equals('/storage/emulated/0/final.mp4'));
        expect(result.durationMs, equals(1000));
        expect(result.fileSizeBytes, equals(524288));
        expect(result.renderedEqualsWritten, isTrue);
        expect(result.backgroundGenerated, isTrue);
        expect(result.claims, equals(<String>['solid_color_synth']));
      },
    );
  });

  group('MethodChannelVGGreenScreenPlatform errors', () {
    late _FakeMethodChannel fakeChannel;
    late MethodChannelVGGreenScreenPlatform platform;
    late VGGreenScreenExportRequest dummyRequest;

    setUp(() {
      fakeChannel = _FakeMethodChannel();
      platform = MethodChannelVGGreenScreenPlatform(channel: fakeChannel);
      dummyRequest = VGGreenScreenExportRequest(
        foregroundVideoPath: '/path/fg.mp4',
        background: const VGGreenScreenBackgroundSource.videoFile(
          '/path/bg.mp4',
        ),
        mask: const VGGreenScreenMaskSource.constantAlpha(255),
        outputPath: '/path/out.mp4',
        outputFrameCount: 1,
      );
    });

    test(
      'maps INVALID_ARG to VGGreenScreenErrorCode.invalidArgument',
      () async {
        const details = <String, dynamic>{'badField': 'targetSize'};
        fakeChannel.errorToThrow = PlatformException(
          code: 'INVALID_ARG',
          message: 'Invalid arguments provided.',
          details: details,
        );

        try {
          await platform.exportGreenScreenComposition(request: dummyRequest);
          fail('Expected VGGreenScreenException');
        } on VGGreenScreenException catch (e) {
          expect(e.code, equals(VGGreenScreenErrorCode.invalidArgument));
          expect(e.message, equals('Invalid arguments provided.'));
          expect(e.details, equals(details));
          expect(e.cause, isA<PlatformException>());
        }
      },
    );

    test('maps export_busy to VGGreenScreenErrorCode.exportBusy', () async {
      const details = <String, dynamic>{'activeSession': 'session-42'};
      fakeChannel.errorToThrow = PlatformException(
        code: 'export_busy',
        message: 'Another green screen export is active.',
        details: details,
      );

      try {
        await platform.exportGreenScreenComposition(request: dummyRequest);
        fail('Expected VGGreenScreenException');
      } on VGGreenScreenException catch (e) {
        expect(e.code, equals(VGGreenScreenErrorCode.exportBusy));
        expect(e.message, equals('Another green screen export is active.'));
        expect(e.details, equals(details));
        expect(e.cause, isA<PlatformException>());
      }
    });

    test(
      'maps composition_failed to VGGreenScreenErrorCode.compositionFailed',
      () async {
        const details = <String, dynamic>{
          'reason': 'surface_decoder_aborted',
          'renderedFrames': 12,
        };
        fakeChannel.errorToThrow = PlatformException(
          code: 'composition_failed',
          message: 'Engine failed during composition.',
          details: details,
        );

        try {
          await platform.exportGreenScreenComposition(request: dummyRequest);
          fail('Expected VGGreenScreenException');
        } on VGGreenScreenException catch (e) {
          expect(e.code, equals(VGGreenScreenErrorCode.compositionFailed));
          expect(e.message, equals('Engine failed during composition.'));
          expect(e.details, equals(details));
          expect(e.cause, isA<PlatformException>());
        }
      },
    );

    test(
      'maps unrecognized PlatformException code to VGGreenScreenErrorCode.unknown',
      () async {
        const details = <String, dynamic>{'extra': 'error_info'};
        fakeChannel.errorToThrow = PlatformException(
          code: 'UNKNOWN_HARDWARE_ERROR',
          message: 'Hardware decoder panic.',
          details: details,
        );

        try {
          await platform.exportGreenScreenComposition(request: dummyRequest);
          fail('Expected VGGreenScreenException');
        } on VGGreenScreenException catch (e) {
          expect(e.code, equals(VGGreenScreenErrorCode.unknown));
          expect(e.message, equals('Hardware decoder panic.'));
          expect(e.details, equals(details));
          expect(e.cause, isA<PlatformException>());
        }
      },
    );

    test(
      'maps null success map to VGGreenScreenErrorCode.compositionFailed',
      () async {
        fakeChannel.returnValue = null;

        try {
          await platform.exportGreenScreenComposition(request: dummyRequest);
          fail('Expected VGGreenScreenException');
        } on VGGreenScreenException catch (e) {
          expect(e.code, equals(VGGreenScreenErrorCode.compositionFailed));
          expect(e.message, contains('returned null result'));
        }
      },
    );
  });
}
