// vg_image_optimizer_test.dart
// vanguard_media_engine — Phase 10-C / 10-D Image Optimization & Enhancement.
//
// Unit tests for VanguardImageOptimizer and supporting value types.
//
// Coverage (IO-1 through IO-33):
//   IO-1:  optimizeImage sends method name 'optimizeImage'.
//   IO-2:  request.toMap() includes sourcePath.
//   IO-3:  optional fields are omitted from the map when null/default-bool.
//   IO-4:  all optional fields appear in the map when set.
//   IO-5:  successful native map returns VGImageOptimizationResult.
//   IO-6:  null native response throws StateError (null result).
//   IO-7:  native failure map (success=false) throws StateError.
//   IO-8:  PlatformException propagates unchanged (code preserved).
//   IO-9:  VGImageOptimizationResult.fromMap returns null for missing field.
//   IO-10: request serializes maxWidth.
//   IO-11: request serializes maxHeight.
//   IO-12: request serializes maxLongEdge (contract key, not maxLongEdgePx).
//   IO-13: request serializes fileSizeTargetBytes.
//   IO-14: request serializes stripMetadata=false.
//   IO-15: request serializes normalizeOrientation=false.
//   IO-16: request serializes colorPolicy and destinationIntent.
//   IO-17: request serializes quality (not jpegQuality).
//   IO-18: stripMetadata defaults to true.
//   IO-19: normalizeOrientation defaults to true.
//   IO-20: all three resize bounds serialize independently.
//
// Phase 10-D enhancement coverage:
//   IO-21: request without enhancement omits 'enhancementConfig' key.
//   IO-22: VGImageEnhancementConfig(enabled:false) serializes 'enabled'=false.
//   IO-23: VGImageEnhancementConfig(enabled:true, mode:conservative) serializes
//          'enabled'=true and 'mode'='conservative' in enhancementConfig.
//   IO-24: explicit denoise params override appears in enhancementConfig.denoise.
//   IO-25: explicit sharpen params override appears in enhancementConfig.sharpen.
//   IO-26: VGImageDenoiseConfig.toMap omits null fields.
//   IO-27: VGImageSharpenConfig.toMap omits null fields.
//   IO-28: VGImageEnhancementConfig off/disabled toMap returns map with enabled=false.
//   IO-29: balanced mode serializes 'mode'='balanced'.
//   IO-30: VGImageEnhancementConfig equality: same params are equal.
//   IO-31: VGImageEnhancementConfig equality: different params are not equal.
//   IO-32: VGImageDenoiseConfig equality and hashCode.
//   IO-33: VGImageSharpenConfig equality and hashCode.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_image_optimizer.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');
  late List<MethodCall> capturedCalls;

  setUp(() {
    capturedCalls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<dynamic> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      capturedCalls.add(call);
      return handler(call);
    });
  }

  // Minimal valid request — only sourcePath.
  VGImageOptimizationRequest makeRequest() {
    return const VGImageOptimizationRequest(
      sourcePath: '/tmp/test_source.jpg',
    );
  }

  // Full request with every optional field set.
  VGImageOptimizationRequest makeFullRequest() {
    return const VGImageOptimizationRequest(
      sourcePath: '/tmp/test_source.jpg',
      outputPath: '/tmp/test_output.jpg',
      maxWidth: 1920,
      maxHeight: 1440,
      maxLongEdge: 1080,
      fileSizeTargetBytes: 200000,
      quality: 0.82,
      format: 'jpeg',
      stripMetadata: false,
      normalizeOrientation: false,
      colorPolicy: 'sdr_rec709',
      destinationIntent: 'story',
    );
  }

  // Minimal valid native success response.
  Map<String, dynamic> makeSuccessResponse() {
    return {
      'success': true,
      'outputPath': '/tmp/vg_img_opt_result.jpg',
      'width': 1080,
      'height': 810,
      'fileSizeBytes': 185000,
      'format': 'jpeg',
    };
  }

  // ── IO-1 ──────────────────────────────────────────────────────────────────────
  test('IO-1: optimizeImage sends method name optimizeImage', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    expect(capturedCalls.first.method, 'optimizeImage');
  });

  // ── IO-2 ──────────────────────────────────────────────────────────────────────
  test('IO-2: request.toMap() includes sourcePath at the top level', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    final args = capturedCalls.first.arguments as Map;
    expect(args['sourcePath'], '/tmp/test_source.jpg');
  });

  // ── IO-3 ──────────────────────────────────────────────────────────────────────
  test('IO-3: null optional fields are absent; bool defaults are present', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: makeRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    final args = capturedCalls.first.arguments as Map;

    // Null optional fields must be absent.
    expect(args.containsKey('outputPath'), isFalse);
    expect(args.containsKey('maxWidth'), isFalse);
    expect(args.containsKey('maxHeight'), isFalse);
    expect(args.containsKey('maxLongEdge'), isFalse);
    expect(args.containsKey('fileSizeTargetBytes'), isFalse);
    expect(args.containsKey('quality'), isFalse);
    expect(args.containsKey('format'), isFalse);
    expect(args.containsKey('colorPolicy'), isFalse);
    expect(args.containsKey('destinationIntent'), isFalse);

    // Non-nullable bools must always be present.
    expect(args.containsKey('stripMetadata'), isTrue);
    expect(args['stripMetadata'], isTrue);
    expect(args.containsKey('normalizeOrientation'), isTrue);
    expect(args['normalizeOrientation'], isTrue);
  });

  // ── IO-4 ──────────────────────────────────────────────────────────────────────
  test('IO-4: all optional fields appear in the map when set', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: makeFullRequest(),
      channel: channel,
    );

    expect(capturedCalls.length, 1);
    final args = capturedCalls.first.arguments as Map;

    expect(args['sourcePath'], '/tmp/test_source.jpg');
    expect(args['outputPath'], '/tmp/test_output.jpg');
    expect(args['maxWidth'], 1920);
    expect(args['maxHeight'], 1440);
    expect(args['maxLongEdge'], 1080);
    expect(args['fileSizeTargetBytes'], 200000);
    expect(args['quality'], closeTo(0.82, 0.0001));
    expect(args['format'], 'jpeg');
    expect(args['stripMetadata'], false);
    expect(args['normalizeOrientation'], false);
    expect(args['colorPolicy'], 'sdr_rec709');
    expect(args['destinationIntent'], 'story');
  });

  // ── IO-5 ──────────────────────────────────────────────────────────────────────
  test(
    'IO-5: successful native map returns VGImageOptimizationResult with correct fields',
    () async {
      setHandler((call) async => makeSuccessResponse());

      final result = await VanguardImageOptimizer.optimizeImage(
        request: makeRequest(),
        channel: channel,
      );

      expect(result.outputPath, '/tmp/vg_img_opt_result.jpg');
      expect(result.width, 1080);
      expect(result.height, 810);
      expect(result.fileSizeBytes, 185000);
      expect(result.format, 'jpeg');
    },
  );

  // ── IO-6 ──────────────────────────────────────────────────────────────────────
  test(
    'IO-6: null native response throws StateError with expected message',
    () async {
      setHandler((call) async => null);

      expect(
        () => VanguardImageOptimizer.optimizeImage(
          request: makeRequest(),
          channel: channel,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('native returned null result'),
          ),
        ),
      );
    },
  );

  // ── IO-7 ──────────────────────────────────────────────────────────────────────
  test(
    'IO-7: native failure map (success=false) throws StateError with expected message',
    () async {
      setHandler(
        (call) async => <String, dynamic>{
          'success': false,
          'outputPath': '',
          'width': 0,
          'height': 0,
          'fileSizeBytes': 0,
          'format': 'jpeg',
        },
      );

      expect(
        () => VanguardImageOptimizer.optimizeImage(
          request: makeRequest(),
          channel: channel,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('native returned failure result'),
          ),
        ),
      );
    },
  );

  // ── IO-8 ──────────────────────────────────────────────────────────────────────
  test('IO-8: PlatformException propagates unchanged (code preserved)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'IMAGE_OPTIMIZER_FAILED',
        message: 'Native image optimizer failed',
      );
    });

    expect(
      () => VanguardImageOptimizer.optimizeImage(
        request: makeRequest(),
        channel: channel,
      ),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'IMAGE_OPTIMIZER_FAILED',
        ),
      ),
    );
  });

  // ── IO-9 ──────────────────────────────────────────────────────────────────────
  test(
    'IO-9: VGImageOptimizationResult.fromMap returns null for missing required field',
    () {
      // Missing 'outputPath'.
      final map = <Object?, Object?>{
        'success': true,
        'width': 1080,
        'height': 810,
        'fileSizeBytes': 185000,
        'format': 'jpeg',
        // 'outputPath' intentionally absent
      };
      final result = VGImageOptimizationResult.fromMap(map);
      expect(result, isNull);
    },
  );

  // ── IO-10 ─────────────────────────────────────────────────────────────────────
  test('IO-10: request serializes maxWidth under key "maxWidth"', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        maxWidth: 1080,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['maxWidth'], 1080);
    expect(args.containsKey('maxHeight'), isFalse);
    expect(args.containsKey('maxLongEdge'), isFalse);
  });

  // ── IO-11 ─────────────────────────────────────────────────────────────────────
  test('IO-11: request serializes maxHeight under key "maxHeight"', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        maxHeight: 1080,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['maxHeight'], 1080);
    expect(args.containsKey('maxWidth'), isFalse);
    expect(args.containsKey('maxLongEdge'), isFalse);
  });

  // ── IO-12 ─────────────────────────────────────────────────────────────────────
  test('IO-12: request serializes maxLongEdge under key "maxLongEdge"', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        maxLongEdge: 1920,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['maxLongEdge'], 1920);
    // Must NOT use old key name.
    expect(args.containsKey('maxLongEdgePx'), isFalse);
    expect(args.containsKey('maxWidth'), isFalse);
    expect(args.containsKey('maxHeight'), isFalse);
  });

  // ── IO-13 ─────────────────────────────────────────────────────────────────────
  test('IO-13: request serializes fileSizeTargetBytes', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        fileSizeTargetBytes: 200000,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['fileSizeTargetBytes'], 200000);
  });

  // ── IO-14 ─────────────────────────────────────────────────────────────────────
  test('IO-14: request serializes stripMetadata=false', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        stripMetadata: false,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['stripMetadata'], false);
  });

  // ── IO-15 ─────────────────────────────────────────────────────────────────────
  test('IO-15: request serializes normalizeOrientation=false', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        normalizeOrientation: false,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['normalizeOrientation'], false);
  });

  // ── IO-16 ─────────────────────────────────────────────────────────────────────
  test('IO-16: request serializes colorPolicy and destinationIntent', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        colorPolicy: 'sdr_rec709',
        destinationIntent: 'story',
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['colorPolicy'], 'sdr_rec709');
    expect(args['destinationIntent'], 'story');
  });

  // ── IO-17 ─────────────────────────────────────────────────────────────────────
  test('IO-17: request serializes quality under key "quality" (not jpegQuality)', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        quality: 0.75,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['quality'], closeTo(0.75, 0.0001));
    // Must NOT use old key name.
    expect(args.containsKey('jpegQuality'), isFalse);
  });

  // ── IO-18 ─────────────────────────────────────────────────────────────────────
  test('IO-18: stripMetadata defaults to true', () {
    const request = VGImageOptimizationRequest(sourcePath: '/tmp/src.jpg');
    expect(request.stripMetadata, isTrue);
    final map = request.toMap();
    expect(map['stripMetadata'], isTrue);
  });

  // ── IO-19 ─────────────────────────────────────────────────────────────────────
  test('IO-19: normalizeOrientation defaults to true', () {
    const request = VGImageOptimizationRequest(sourcePath: '/tmp/src.jpg');
    expect(request.normalizeOrientation, isTrue);
    final map = request.toMap();
    expect(map['normalizeOrientation'], isTrue);
  });

  // ── IO-20 ─────────────────────────────────────────────────────────────────────
  test('IO-20: all three resize bounds serialize independently and correctly', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        maxWidth: 1440,
        maxHeight: 1080,
        maxLongEdge: 1920,
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    expect(args['maxWidth'], 1440);
    expect(args['maxHeight'], 1080);
    expect(args['maxLongEdge'], 1920);
    // No old key name.
    expect(args.containsKey('maxLongEdgePx'), isFalse);
  });
  // ── IO-21 ─────────────────────────────────────────────────────────────────
  test(
    'IO-21: request without enhancement omits enhancementConfig key',
    () async {
      setHandler((call) async => makeSuccessResponse());

      await VanguardImageOptimizer.optimizeImage(
        request: makeRequest(),
        channel: channel,
      );

      final args = capturedCalls.first.arguments as Map;
      expect(args.containsKey('enhancementConfig'), isFalse);
    },
  );

  // ── IO-22 ─────────────────────────────────────────────────────────────────
  test(
    'IO-22: disabled enhancement serializes enabled=false in enhancementConfig',
    () async {
      setHandler((call) async => makeSuccessResponse());

      await VanguardImageOptimizer.optimizeImage(
        request: const VGImageOptimizationRequest(
          sourcePath: '/tmp/src.jpg',
          enhancement: VGImageEnhancementConfig(
            enabled: false,
            mode: VGImageEnhancementMode.off,
          ),
        ),
        channel: channel,
      );

      final args = capturedCalls.first.arguments as Map;
      expect(args.containsKey('enhancementConfig'), isTrue);
      final enh = args['enhancementConfig'] as Map;
      expect(enh['enabled'], false);
      expect(enh['mode'], 'off');
    },
  );

  // ── IO-23 ─────────────────────────────────────────────────────────────────
  test(
    'IO-23: enabled conservative enhancement serializes correctly in enhancementConfig',
    () async {
      setHandler((call) async => makeSuccessResponse());

      await VanguardImageOptimizer.optimizeImage(
        request: const VGImageOptimizationRequest(
          sourcePath: '/tmp/src.jpg',
          enhancement: VGImageEnhancementConfig(
            enabled: true,
            mode: VGImageEnhancementMode.conservative,
          ),
        ),
        channel: channel,
      );

      final args = capturedCalls.first.arguments as Map;
      expect(args.containsKey('enhancementConfig'), isTrue);
      final enh = args['enhancementConfig'] as Map;
      expect(enh['enabled'], true);
      expect(enh['mode'], 'conservative');
      expect(enh['target'], 'derivativeOnly');
      // No explicit denoise/sharpen overrides — sub-keys must be absent.
      expect(enh.containsKey('denoise'), isFalse);
      expect(enh.containsKey('sharpen'), isFalse);
    },
  );

  // ── IO-24 ─────────────────────────────────────────────────────────────────
  test(
    'IO-24: explicit denoise params appear in enhancementConfig.denoise',
    () async {
      setHandler((call) async => makeSuccessResponse());

      await VanguardImageOptimizer.optimizeImage(
        request: const VGImageOptimizationRequest(
          sourcePath: '/tmp/src.jpg',
          enhancement: VGImageEnhancementConfig(
            enabled: true,
            mode: VGImageEnhancementMode.conservative,
            denoise: VGImageDenoiseConfig(noiseLevel: 0.03, sharpness: 0.55),
          ),
        ),
        channel: channel,
      );

      final args = capturedCalls.first.arguments as Map;
      final enh = args['enhancementConfig'] as Map;
      expect(enh.containsKey('denoise'), isTrue);
      final d = enh['denoise'] as Map;
      expect(d['noiseLevel'], closeTo(0.03, 0.0001));
      expect(d['sharpness'], closeTo(0.55, 0.0001));
    },
  );

  // ── IO-25 ─────────────────────────────────────────────────────────────────
  test(
    'IO-25: explicit sharpen params appear in enhancementConfig.sharpen',
    () async {
      setHandler((call) async => makeSuccessResponse());

      await VanguardImageOptimizer.optimizeImage(
        request: const VGImageOptimizationRequest(
          sourcePath: '/tmp/src.jpg',
          enhancement: VGImageEnhancementConfig(
            enabled: true,
            mode: VGImageEnhancementMode.conservative,
            sharpen: VGImageSharpenConfig(intensity: 0.20, radius: 0.80),
          ),
        ),
        channel: channel,
      );

      final args = capturedCalls.first.arguments as Map;
      final enh = args['enhancementConfig'] as Map;
      expect(enh.containsKey('sharpen'), isTrue);
      final s = enh['sharpen'] as Map;
      expect(s['intensity'], closeTo(0.20, 0.0001));
      expect(s['radius'], closeTo(0.80, 0.0001));
    },
  );

  // ── IO-26 ─────────────────────────────────────────────────────────────────
  test('IO-26: VGImageDenoiseConfig.toMap omits null fields', () {
    // Only noiseLevel supplied — sharpness must be absent.
    const d1 = VGImageDenoiseConfig(noiseLevel: 0.02);
    final m1 = d1.toMap();
    expect(m1.containsKey('noiseLevel'), isTrue);
    expect(m1.containsKey('sharpness'), isFalse);

    // Only sharpness supplied — noiseLevel must be absent.
    const d2 = VGImageDenoiseConfig(sharpness: 0.4);
    final m2 = d2.toMap();
    expect(m2.containsKey('noiseLevel'), isFalse);
    expect(m2.containsKey('sharpness'), isTrue);

    // Neither supplied — both absent.
    const d3 = VGImageDenoiseConfig();
    final m3 = d3.toMap();
    expect(m3.isEmpty, isTrue);
  });

  // ── IO-27 ─────────────────────────────────────────────────────────────────
  test('IO-27: VGImageSharpenConfig.toMap omits null fields', () {
    // Only intensity supplied.
    const s1 = VGImageSharpenConfig(intensity: 0.15);
    final m1 = s1.toMap();
    expect(m1.containsKey('intensity'), isTrue);
    expect(m1.containsKey('radius'), isFalse);

    // Only radius supplied.
    const s2 = VGImageSharpenConfig(radius: 0.65);
    final m2 = s2.toMap();
    expect(m2.containsKey('intensity'), isFalse);
    expect(m2.containsKey('radius'), isTrue);

    // Neither supplied — both absent.
    const s3 = VGImageSharpenConfig();
    final m3 = s3.toMap();
    expect(m3.isEmpty, isTrue);
  });

  // ── IO-28 ─────────────────────────────────────────────────────────────────
  test(
    'IO-28: VGImageEnhancementConfig disabled/off toMap returns enabled=false map',
    () {
      // Default-constructed (off).
      const ec = VGImageEnhancementConfig();
      final m = ec.toMap();
      expect(m, isNotNull);
      expect(m!['enabled'], false);
      expect(m['mode'], 'off');

      // Explicitly enabled=false.
      const ec2 = VGImageEnhancementConfig(
        enabled: false,
        mode: VGImageEnhancementMode.conservative,
      );
      final m2 = ec2.toMap();
      expect(m2!['enabled'], false);
    },
  );

  // ── IO-29 ─────────────────────────────────────────────────────────────────
  test('IO-29: balanced mode serializes mode=balanced', () async {
    setHandler((call) async => makeSuccessResponse());

    await VanguardImageOptimizer.optimizeImage(
      request: const VGImageOptimizationRequest(
        sourcePath: '/tmp/src.jpg',
        enhancement: VGImageEnhancementConfig(
          enabled: true,
          mode: VGImageEnhancementMode.balanced,
        ),
      ),
      channel: channel,
    );

    final args = capturedCalls.first.arguments as Map;
    final enh = args['enhancementConfig'] as Map;
    expect(enh['enabled'], true);
    expect(enh['mode'], 'balanced');
  });

  // ── IO-30 ─────────────────────────────────────────────────────────────────
  test('IO-30: VGImageEnhancementConfig equality: same params are equal', () {
    const a = VGImageEnhancementConfig(
      enabled: true,
      mode: VGImageEnhancementMode.conservative,
      denoise: VGImageDenoiseConfig(noiseLevel: 0.02, sharpness: 0.4),
      sharpen: VGImageSharpenConfig(intensity: 0.15, radius: 0.65),
    );
    const b = VGImageEnhancementConfig(
      enabled: true,
      mode: VGImageEnhancementMode.conservative,
      denoise: VGImageDenoiseConfig(noiseLevel: 0.02, sharpness: 0.4),
      sharpen: VGImageSharpenConfig(intensity: 0.15, radius: 0.65),
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
  });

  // ── IO-31 ─────────────────────────────────────────────────────────────────
  test('IO-31: VGImageEnhancementConfig equality: different params are not equal', () {
    const a = VGImageEnhancementConfig(
      enabled: true,
      mode: VGImageEnhancementMode.conservative,
    );
    const b = VGImageEnhancementConfig(
      enabled: true,
      mode: VGImageEnhancementMode.balanced,
    );
    expect(a, isNot(equals(b)));
  });

  // ── IO-32 ─────────────────────────────────────────────────────────────────
  test('IO-32: VGImageDenoiseConfig equality and hashCode', () {
    const a = VGImageDenoiseConfig(noiseLevel: 0.02, sharpness: 0.4);
    const b = VGImageDenoiseConfig(noiseLevel: 0.02, sharpness: 0.4);
    const c = VGImageDenoiseConfig(noiseLevel: 0.04);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  // ── IO-33 ─────────────────────────────────────────────────────────────────
  test('IO-33: VGImageSharpenConfig equality and hashCode', () {
    const a = VGImageSharpenConfig(intensity: 0.15, radius: 0.65);
    const b = VGImageSharpenConfig(intensity: 0.15, radius: 0.65);
    const c = VGImageSharpenConfig(intensity: 0.30);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });
}
