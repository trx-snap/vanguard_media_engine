// vg_roi_export_sidecar_post_processor_test.dart
// Vanguard Media Engine — Phase 5-Unit M
// Unit tests for VGRoiExportSidecarPostProcessor.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/roi/vg_roi_export_sidecar_post_processor.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const double _eps = 1e-6;

void _expectBoxCloseTo(
  VGROIBox? actual,
  VGROIBox expected, {
  double eps = _eps,
}) {
  expect(actual, isNotNull, reason: 'Expected non-null box');
  expect(actual!.x, closeTo(expected.x, eps));
  expect(actual.y, closeTo(expected.y, eps));
  expect(actual.w, closeTo(expected.w, eps));
  expect(actual.h, closeTo(expected.h, eps));
}

VGROISidecar _makeSourceSidecar({
  required String coordinateSpace,
  required int width,
  required int height,
  int durationMs = 5000,
  List<VGROISample> samples = const [],
}) {
  return VGROISidecar(
    version: 1,
    sourceType: 'app_recorded',
    platform: 'android',
    coordinateSpace: coordinateSpace,
    recordingSessionId: 'source-session-test-id',
    videoIdentity: VGROIIdentity(
      durationMs: durationMs,
      width: width,
      height: height,
      hash: null,
    ),
    coverage: VGROICoverage(coveragePercent: 1.0, missingIntervals: const []),
    samples: samples,
    finalized: true,
  );
}

VGROISample _makeSample({
  required int timestampMs,
  required int framePtsMs,
  required int recordingRelativeMs,
  VGROIBox? box,
  String quality = 'detected',
  double? confidence = 0.9,
  String? paddingPolicy = 'normal',
}) {
  return VGROISample(
    timestampMs: timestampMs,
    framePtsMs: framePtsMs,
    recordingRelativeMs: recordingRelativeMs,
    box: box,
    quality: quality,
    confidence: confidence,
    paddingPolicy: paddingPolicy,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('vg_roi_post_proc_test_');
  });

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  void mockInspectMedia({
    int width = 1920,
    int height = 1080,
    int displayWidth = 1080,
    int displayHeight = 1920,
    double durationSeconds = 5.0,
    bool hasVideo = true,
    bool hasAudio = true,
  }) {
    binaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectMedia') {
        return <String, dynamic>{
          'kind': 'video',
          'container': 'mov',
          'videoCodec': 'h264',
          'audioCodec': 'aac',
          'width': width,
          'height': height,
          'encodedWidth': width,
          'encodedHeight': height,
          'displayWidth': displayWidth,
          'displayHeight': displayHeight,
          'durationSeconds': durationSeconds,
          'bitrateKbps': 4000,
          'fps': 30.0,
          'fileSizeBytes': 2048,
          'hasVideo': hasVideo,
          'hasAudio': hasAudio,
          'isHDR': false,
          'hasMoovAtFront': false,
          'hasRotationTransform': true,
          'hasEmbeddedMetadata': false,
          'rotationDegrees': 90,
          'orientationStatus': 'valid',
        };
      }
      return null;
    });
  }

  // ---------------------------------------------------------------------------
  // 1. display_source_normalized timeline mapping
  // ---------------------------------------------------------------------------
  group('display_source_normalized timeline mapping', () {
    test(
      'uses mediaInfo.displayWidth/displayHeight as source and passed canvas dimensions as output',
      () async {
        // Source video has raw encoded width: 1920, height: 1080, but
        // display orientation displayWidth: 1080, displayHeight: 1920 (9:16).
        mockInspectMedia(
          width: 1920,
          height: 1080,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/clip_source.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3, 4]);

        final box = VGROIBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4);
        final sample = _makeSample(
          timestampMs: 1000,
          framePtsMs: 1000,
          recordingRelativeMs: 1000,
          box: box,
        );
        final sourceSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [sample],
        );
        final sourceSidecarFile = File('${tempDir.path}/clip_source.roi.json');
        await sourceSidecarFile.writeAsString(
          jsonEncode(sourceSidecar.toJson()),
        );

        final outputVideoPath = '${tempDir.path}/exported_timeline.mp4';
        final exportRoiSidecarPath =
            '${tempDir.path}/exported_timeline.roi.json';

        // Pre-create a native empty sidecar file at exportRoiSidecarPath
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(
          '{"version":1,"nativeEmpty":true}',
        );

        // Canvas is 720x1280 (same 9:16 aspect ratio).
        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          passthroughPreservesSourceGeometry: false,
        );

        expect(processed, isTrue);

        final outputSidecarFile = File(exportRoiSidecarPath);
        expect(outputSidecarFile.existsSync(), isTrue);

        final decoded = jsonDecode(await outputSidecarFile.readAsString());
        final resultSidecar = VGROISidecar.fromJson(decoded);

        expect(
          resultSidecar.coordinateSpace,
          equals('export_output_normalized'),
        );
        expect(resultSidecar.videoIdentity.width, equals(720));
        expect(resultSidecar.videoIdentity.height, equals(1280));
        expect(resultSidecar.samples.length, equals(1));
        _expectBoxCloseTo(resultSidecar.samples[0].box, box);

        // No temp residue
        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 2. passthroughPreservesSourceGeometry
  // ---------------------------------------------------------------------------
  group('passthroughPreservesSourceGeometry', () {
    test(
      'passthroughPreservesSourceGeometry true ignores encoded canvas args and emits videoIdentity displayWidth/displayHeight for display_source_normalized',
      () async {
        // Encoded track is 1920x1080, display is 1080x1920.
        mockInspectMedia(
          width: 1920,
          height: 1080,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/passthrough_in.mov');
        await sourceVideoFile.writeAsBytes([10, 20, 30, 40]);

        final box = VGROIBox(x: 0.25, y: 0.15, w: 0.50, h: 0.35);
        final sample = _makeSample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: box,
        );
        final sourceSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [sample],
        );
        final sourceSidecarFile = File(
          '${tempDir.path}/passthrough_in.roi.json',
        );
        await sourceSidecarFile.writeAsString(
          jsonEncode(sourceSidecar.toJson()),
        );

        final outputVideoPath = '${tempDir.path}/passthrough_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/passthrough_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString('{"version":1,"native":true}');

        // Canvas passed contains encoded track dimensions (1920x1080), but
        // passthroughPreservesSourceGeometry is true.
        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 1920,
          canvasHeight: 1080,
          passthroughPreservesSourceGeometry: true,
        );

        expect(processed, isTrue);

        final outputSidecarFile = File(exportRoiSidecarPath);
        final decoded = jsonDecode(await outputSidecarFile.readAsString());
        final resultSidecar = VGROISidecar.fromJson(decoded);

        expect(
          resultSidecar.coordinateSpace,
          equals('export_output_normalized'),
        );
        // videoIdentity must match display geometry (1080x1920), ignoring encoded args (1920x1080)
        expect(resultSidecar.videoIdentity.width, equals(1080));
        expect(resultSidecar.videoIdentity.height, equals(1920));
        expect(resultSidecar.samples.length, equals(1));
        _expectBoxCloseTo(resultSidecar.samples[0].box, box);

        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 3. Malformed / Missing Source Sidecar Fail-Closed
  // ---------------------------------------------------------------------------
  group('Malformed / Missing source sidecar fail-closed', () {
    const sentinelContent =
        '{"sentinel":"pre_existing_empty_sidecar_must_remain"}';

    test(
      'malformed JSON source sidecar leaves pre-existing final sidecar contents unchanged and removes temp',
      () async {
        mockInspectMedia();

        final sourceVideoFile = File('${tempDir.path}/broken_json.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        final sourceSidecarFile = File('${tempDir.path}/broken_json.roi.json');
        await sourceSidecarFile.writeAsString('{not valid json at all!');

        final outputVideoPath = '${tempDir.path}/broken_json_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/broken_json_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinelContent);

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
        );

        expect(processed, isFalse);

        // Pre-existing sidecar unchanged
        final currentContent = await nativeEmptySidecar.readAsString();
        expect(currentContent, equals(sentinelContent));

        // Temp file does not exist
        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'malformed VGROISidecar fields leave pre-existing final sidecar contents unchanged and removes temp',
      () async {
        mockInspectMedia();

        final sourceVideoFile = File('${tempDir.path}/bad_fields.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        // Missing required fields like coordinateSpace / videoIdentity
        final sourceSidecarFile = File('${tempDir.path}/bad_fields.roi.json');
        await sourceSidecarFile.writeAsString('{"version":1,"invalid":true}');

        final outputVideoPath = '${tempDir.path}/bad_fields_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/bad_fields_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinelContent);

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
        );

        expect(processed, isFalse);
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'missing source sidecar returns false and leaves pre-existing final sidecar untouched',
      () async {
        mockInspectMedia();

        final sourceVideoFile = File('${tempDir.path}/no_sidecar.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        // Do NOT create source sidecar file

        final outputVideoPath = '${tempDir.path}/no_sidecar_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/no_sidecar_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinelContent);

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
        );

        expect(processed, isFalse);
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 4. Trimming and Spatial Mapping
  // ---------------------------------------------------------------------------
  group('Trimming and spatial mapping', () {
    test('single-clip trim window correctly trims and shifts samples', () async {
      mockInspectMedia(
        width: 1080,
        height: 1920,
        displayWidth: 1080,
        displayHeight: 1920,
      );

      final sourceVideoFile = File('${tempDir.path}/trim_source.mov');
      await sourceVideoFile.writeAsBytes([1, 2, 3]);

      final samples = [
        _makeSample(
          timestampMs: 0,
          framePtsMs: 0,
          recordingRelativeMs: 0,
          box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
        ),
        _makeSample(
          timestampMs: 1000,
          framePtsMs: 1000,
          recordingRelativeMs: 1000,
          box: VGROIBox(x: 0.2, y: 0.2, w: 0.3, h: 0.3),
        ),
        _makeSample(
          timestampMs: 2500,
          framePtsMs: 2500,
          recordingRelativeMs: 2500,
          box: VGROIBox(x: 0.3, y: 0.3, w: 0.4, h: 0.4),
        ),
        _makeSample(
          timestampMs: 4000,
          framePtsMs: 4000,
          recordingRelativeMs: 4000,
          box: VGROIBox(x: 0.4, y: 0.4, w: 0.5, h: 0.5),
        ),
      ];

      final sourceSidecar = _makeSourceSidecar(
        coordinateSpace: 'display_source_normalized',
        width: 1080,
        height: 1920,
        durationMs: 5000,
        samples: samples,
      );
      final sourceSidecarFile = File('${tempDir.path}/trim_source.roi.json');
      await sourceSidecarFile.writeAsString(jsonEncode(sourceSidecar.toJson()));

      final outputVideoPath = '${tempDir.path}/trim_out.mp4';
      final exportRoiSidecarPath = '${tempDir.path}/trim_out.roi.json';

      final processed = await VGRoiExportSidecarPostProcessor.process(
        sourceVideoPath: sourceVideoFile.path,
        outputVideoPath: outputVideoPath,
        exportRoiSidecarPath: exportRoiSidecarPath,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimStartSeconds: 0.5, // 500ms
        trimEndSeconds: 3.0, // 3000ms
      );

      expect(processed, isTrue);

      final outputSidecarFile = File(exportRoiSidecarPath);
      final decoded = jsonDecode(await outputSidecarFile.readAsString());
      final resultSidecar = VGROISidecar.fromJson(decoded);

      // Samples at 0ms and 4000ms dropped. Samples at 1000ms and 2500ms survive.
      expect(resultSidecar.samples.length, equals(2));
      expect(resultSidecar.samples[0].timestampMs, equals(500));
      expect(resultSidecar.samples[0].framePtsMs, equals(500));
      expect(resultSidecar.samples[0].recordingRelativeMs, equals(500));

      expect(resultSidecar.samples[1].timestampMs, equals(2000));
      expect(resultSidecar.samples[1].framePtsMs, equals(2000));
      expect(resultSidecar.samples[1].recordingRelativeMs, equals(2000));

      expect(resultSidecar.videoIdentity.durationMs, equals(2500));
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Guardrails and Invalid Inputs
  // ---------------------------------------------------------------------------
  group('Guardrails and invalid inputs', () {
    test('non-positive canvasWidth or canvasHeight returns false', () async {
      mockInspectMedia();

      final sourceVideoFile = File('${tempDir.path}/guard_dims.mov');
      await sourceVideoFile.writeAsBytes([1, 2]);

      final sourceSidecar = _makeSourceSidecar(
        coordinateSpace: 'display_source_normalized',
        width: 1080,
        height: 1920,
      );
      final sourceSidecarFile = File('${tempDir.path}/guard_dims.roi.json');
      await sourceSidecarFile.writeAsString(jsonEncode(sourceSidecar.toJson()));

      expect(
        await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: '${tempDir.path}/out.mp4',
          exportRoiSidecarPath: '${tempDir.path}/out.roi.json',
          canvasWidth: 0,
          canvasHeight: 1920,
        ),
        isFalse,
      );

      expect(
        await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: '${tempDir.path}/out.mp4',
          exportRoiSidecarPath: '${tempDir.path}/out.roi.json',
          canvasWidth: 1080,
          canvasHeight: -100,
        ),
        isFalse,
      );
    });

    test('mismatched exportRoiSidecarPath returns false', () async {
      mockInspectMedia();

      final sourceVideoFile = File('${tempDir.path}/mismatch.mov');
      await sourceVideoFile.writeAsBytes([1, 2]);

      final sourceSidecar = _makeSourceSidecar(
        coordinateSpace: 'display_source_normalized',
        width: 1080,
        height: 1920,
      );
      final sourceSidecarFile = File('${tempDir.path}/mismatch.roi.json');
      await sourceSidecarFile.writeAsString(jsonEncode(sourceSidecar.toJson()));

      // outputVideoPath -> mismatch_out.roi.json, but exportRoiSidecarPath passed is different
      final processed = await VGRoiExportSidecarPostProcessor.process(
        sourceVideoPath: sourceVideoFile.path,
        outputVideoPath: '${tempDir.path}/mismatch_out.mp4',
        exportRoiSidecarPath: '${tempDir.path}/different_destination.roi.json',
        canvasWidth: 1080,
        canvasHeight: 1920,
      );

      expect(processed, isFalse);
    });

    test('inspectMedia returning null returns false', () async {
      // Handler returning null for inspectMedia
      binaryMessenger.setMockMethodCallHandler(channel, (call) async => null);

      final sourceVideoFile = File('${tempDir.path}/uninspectable.mov');
      await sourceVideoFile.writeAsBytes([1, 2]);

      final sourceSidecar = _makeSourceSidecar(
        coordinateSpace: 'display_source_normalized',
        width: 1080,
        height: 1920,
      );
      final sourceSidecarFile = File('${tempDir.path}/uninspectable.roi.json');
      await sourceSidecarFile.writeAsString(jsonEncode(sourceSidecar.toJson()));

      final processed = await VGRoiExportSidecarPostProcessor.process(
        sourceVideoPath: sourceVideoFile.path,
        outputVideoPath: '${tempDir.path}/uninspectable_out.mp4',
        exportRoiSidecarPath: '${tempDir.path}/uninspectable_out.roi.json',
        canvasWidth: 1080,
        canvasHeight: 1920,
      );

      expect(processed, isFalse);
    });
  });
}
