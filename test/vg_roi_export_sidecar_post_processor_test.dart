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

  // ---------------------------------------------------------------------------
  // 6. processTimeline - Multi-Clip Timeline Composition (Phase 5-Unit N)
  // ---------------------------------------------------------------------------
  group('processTimeline multi-clip timeline composition', () {
    const sentinelContent =
        '{"sentinel":"pre_existing_timeline_fallback_must_remain"}';

    test(
      'two valid clips compose into single export_output_normalized sidecar with second clip shifted by clip1 duration',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
          durationSeconds: 5.0,
        );

        final clip1Video = File('${tempDir.path}/clip1.mov');
        await clip1Video.writeAsBytes([1, 2, 3]);
        final clip1BoxA = VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2);
        final clip1BoxB = VGROIBox(x: 0.2, y: 0.2, w: 0.3, h: 0.3);
        final clip1Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          durationMs: 5000,
          samples: [
            _makeSample(
              timestampMs: 500,
              framePtsMs: 500,
              recordingRelativeMs: 500,
              box: clip1BoxA,
            ),
            _makeSample(
              timestampMs: 1500,
              framePtsMs: 1500,
              recordingRelativeMs: 1500,
              box: clip1BoxB,
            ),
          ],
        );
        final clip1SidecarFile = File('${tempDir.path}/clip1.roi.json');
        await clip1SidecarFile.writeAsString(jsonEncode(clip1Sidecar.toJson()));

        final clip2Video = File('${tempDir.path}/clip2.mov');
        await clip2Video.writeAsBytes([4, 5, 6]);
        final clip2BoxC = VGROIBox(x: 0.3, y: 0.3, w: 0.4, h: 0.4);
        final clip2BoxD = VGROIBox(x: 0.4, y: 0.4, w: 0.5, h: 0.5);
        final clip2Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          durationMs: 5000,
          samples: [
            _makeSample(
              timestampMs: 1500,
              framePtsMs: 1500,
              recordingRelativeMs: 1500,
              box: clip2BoxC,
            ),
            _makeSample(
              timestampMs: 2500,
              framePtsMs: 2500,
              recordingRelativeMs: 2500,
              box: clip2BoxD,
            ),
            // Sample outside trim window [1.0, 4.0] (at 4500ms) will be dropped
            _makeSample(
              timestampMs: 4500,
              framePtsMs: 4500,
              recordingRelativeMs: 4500,
              box: VGROIBox(x: 0.5, y: 0.5, w: 0.2, h: 0.2),
            ),
          ],
        );
        final clip2SidecarFile = File('${tempDir.path}/clip2.roi.json');
        await clip2SidecarFile.writeAsString(jsonEncode(clip2Sidecar.toJson()));

        final clip1 = VGClipDescriptor(
          id: 'clip_1',
          sourcePath: clip1Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0, // 2000ms output duration
        );
        final clip2 = VGClipDescriptor(
          id: 'clip_2',
          sourcePath: clip2Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 1.0,
          trimEndSeconds: 4.0, // 3000ms output duration
        );

        final outputVideoPath = '${tempDir.path}/timeline_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/timeline_out.roi.json';

        // Pre-create native empty fallback sidecar
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(
          '{"version":1,"nativeEmpty":true}',
        );

        final processed = await VGRoiExportSidecarPostProcessor.processTimeline(
          clips: [clip1, clip2],
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          exportDurationSeconds: 5.0,
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
        expect(resultSidecar.videoIdentity.durationMs, equals(5000));
        expect(resultSidecar.finalized, isTrue);

        // 4 surviving samples (2 from clip1, 2 from clip2)
        expect(resultSidecar.samples.length, equals(4));

        // Clip 1 samples: timestamps 500ms, 1500ms
        expect(resultSidecar.samples[0].timestampMs, equals(500));
        expect(resultSidecar.samples[0].framePtsMs, equals(500));
        expect(resultSidecar.samples[0].recordingRelativeMs, equals(500));
        _expectBoxCloseTo(resultSidecar.samples[0].box, clip1BoxA);

        expect(resultSidecar.samples[1].timestampMs, equals(1500));
        expect(resultSidecar.samples[1].framePtsMs, equals(1500));
        expect(resultSidecar.samples[1].recordingRelativeMs, equals(1500));
        _expectBoxCloseTo(resultSidecar.samples[1].box, clip1BoxB);

        // Clip 2 samples: trimmed by 1000ms -> (500ms, 1500ms), then shifted by clip1 duration (+2000ms) -> (2500ms, 3500ms)
        expect(resultSidecar.samples[2].timestampMs, equals(2500));
        expect(resultSidecar.samples[2].framePtsMs, equals(2500));
        expect(resultSidecar.samples[2].recordingRelativeMs, equals(2500));
        _expectBoxCloseTo(resultSidecar.samples[2].box, clip2BoxC);

        expect(resultSidecar.samples[3].timestampMs, equals(3500));
        expect(resultSidecar.samples[3].framePtsMs, equals(3500));
        expect(resultSidecar.samples[3].recordingRelativeMs, equals(3500));
        _expectBoxCloseTo(resultSidecar.samples[3].box, clip2BoxD);

        // No temp residue
        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'first clip valid + second clip missing or malformed source sidecar still writes valid samples and shifts third valid clip correctly',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
          durationSeconds: 5.0,
        );

        // Clip 1: valid sidecar with sample at 800ms
        final clip1Video = File('${tempDir.path}/c1.mov');
        await clip1Video.writeAsBytes([1, 2]);
        final clip1Box = VGROIBox(x: 0.15, y: 0.15, w: 0.3, h: 0.3);
        final clip1Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 800,
              framePtsMs: 800,
              recordingRelativeMs: 800,
              box: clip1Box,
            ),
          ],
        );
        final clip1SidecarFile = File('${tempDir.path}/c1.roi.json');
        await clip1SidecarFile.writeAsString(jsonEncode(clip1Sidecar.toJson()));

        // Clip 2: malformed sidecar
        final clip2Video = File('${tempDir.path}/c2.mov');
        await clip2Video.writeAsBytes([3, 4]);
        final clip2SidecarFile = File('${tempDir.path}/c2.roi.json');
        await clip2SidecarFile.writeAsString('{not valid json at all!');

        // Clip 3: valid sidecar with sample at 1500ms (trimmed by 500ms to 1000ms)
        final clip3Video = File('${tempDir.path}/c3.mov');
        await clip3Video.writeAsBytes([5, 6]);
        final clip3Box = VGROIBox(x: 0.35, y: 0.35, w: 0.25, h: 0.25);
        final clip3Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 1500,
              framePtsMs: 1500,
              recordingRelativeMs: 1500,
              box: clip3Box,
            ),
          ],
        );
        final clip3SidecarFile = File('${tempDir.path}/c3.roi.json');
        await clip3SidecarFile.writeAsString(jsonEncode(clip3Sidecar.toJson()));

        final clip1 = VGClipDescriptor(
          id: 'c1',
          sourcePath: clip1Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0, // 2000ms
        );
        final clip2 = VGClipDescriptor(
          id: 'c2',
          sourcePath: clip2Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 3.0, // 3000ms
        );
        final clip3 = VGClipDescriptor(
          id: 'c3',
          sourcePath: clip3Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.5,
          trimEndSeconds: 2.5, // 2000ms
        );

        final outputVideoPath = '${tempDir.path}/partial_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/partial_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString('{"version":1,"native":true}');

        final processed = await VGRoiExportSidecarPostProcessor.processTimeline(
          clips: [clip1, clip2, clip3],
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          exportDurationSeconds: 7.0,
        );

        expect(processed, isTrue);

        final outputSidecarFile = File(exportRoiSidecarPath);
        final decoded = jsonDecode(await outputSidecarFile.readAsString());
        final resultSidecar = VGROISidecar.fromJson(decoded);

        expect(
          resultSidecar.coordinateSpace,
          equals('export_output_normalized'),
        );
        expect(resultSidecar.videoIdentity.width, equals(720));
        expect(resultSidecar.videoIdentity.height, equals(1280));
        expect(resultSidecar.videoIdentity.durationMs, equals(7000));
        expect(resultSidecar.samples.length, equals(2));

        // Sample from clip 1 at 800ms
        expect(resultSidecar.samples[0].timestampMs, equals(800));
        _expectBoxCloseTo(resultSidecar.samples[0].box, clip1Box);

        // Sample from clip 3 at (1500 - 500) + 2000 (clip1) + 3000 (clip2) = 6000ms
        expect(resultSidecar.samples[1].timestampMs, equals(6000));
        expect(resultSidecar.samples[1].framePtsMs, equals(6000));
        expect(resultSidecar.samples[1].recordingRelativeMs, equals(6000));
        _expectBoxCloseTo(resultSidecar.samples[1].box, clip3Box);

        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'all source sidecars missing/malformed returns false and preserves pre-existing fallback sidecar content',
      () async {
        mockInspectMedia();

        final clip1Video = File('${tempDir.path}/all_broken1.mov');
        await clip1Video.writeAsBytes([1, 2]);
        // Clip 1 sidecar missing entirely

        final clip2Video = File('${tempDir.path}/all_broken2.mov');
        await clip2Video.writeAsBytes([3, 4]);
        final clip2SidecarFile = File('${tempDir.path}/all_broken2.roi.json');
        await clip2SidecarFile.writeAsString(
          '{"invalid_sidecar_missing_fields":true}',
        );

        final clip1 = VGClipDescriptor(
          id: 'b1',
          sourcePath: clip1Video.path,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        );
        final clip2 = VGClipDescriptor(
          id: 'b2',
          sourcePath: clip2Video.path,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        );

        final outputVideoPath = '${tempDir.path}/all_broken_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/all_broken_out.roi.json';

        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinelContent);

        final processed = await VGRoiExportSidecarPostProcessor.processTimeline(
          clips: [clip1, clip2],
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          exportDurationSeconds: 4.0,
        );

        expect(processed, isFalse);

        // Pre-existing fallback content preserved
        final currentContent = await nativeEmptySidecar.readAsString();
        expect(currentContent, equals(sentinelContent));

        final tempFile = File('$exportRoiSidecarPath.vgroitmp');
        expect(tempFile.existsSync(), isFalse);
      },
    );

    test(
      'invalid global inputs return false and preserve fallback sidecar',
      () async {
        mockInspectMedia();

        final clipVideo = File('${tempDir.path}/valid_clip.mov');
        await clipVideo.writeAsBytes([1, 2]);
        final clipSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 500,
              framePtsMs: 500,
              recordingRelativeMs: 500,
            ),
          ],
        );
        final clipSidecarFile = File('${tempDir.path}/valid_clip.roi.json');
        await clipSidecarFile.writeAsString(jsonEncode(clipSidecar.toJson()));

        final clip = VGClipDescriptor(
          id: 'valid_clip_id',
          sourcePath: clipVideo.path,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        );

        final outputVideoPath = '${tempDir.path}/guard_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/guard_out.roi.json';
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinelContent);

        // 1. Non-positive canvasWidth
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 0,
            canvasHeight: 1280,
            exportDurationSeconds: 2.0,
          ),
          isFalse,
        );
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        // 2. Non-positive canvasHeight
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: -1280,
            exportDurationSeconds: 2.0,
          ),
          isFalse,
        );
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        // 3. Invalid exportDurationSeconds (0, negative, NaN, infinite)
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: 0.0,
          ),
          isFalse,
        );
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: -2.0,
          ),
          isFalse,
        );
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: double.nan,
          ),
          isFalse,
        );
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: double.infinity,
          ),
          isFalse,
        );
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        // 4. Mismatched exportRoiSidecarPath
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: [clip],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: '${tempDir.path}/wrong_name.roi.json',
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: 2.0,
          ),
          isFalse,
        );
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );

        // 5. Empty clips list
        expect(
          await VGRoiExportSidecarPostProcessor.processTimeline(
            clips: const [],
            outputVideoPath: outputVideoPath,
            exportRoiSidecarPath: exportRoiSidecarPath,
            canvasWidth: 720,
            canvasHeight: 1280,
            exportDurationSeconds: 2.0,
          ),
          isFalse,
        );
        expect(
          await nativeEmptySidecar.readAsString(),
          equals(sentinelContent),
        );
      },
    );

    test(
      'clip with empty samples sidecar is handled without failing the rest of the timeline',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
          durationSeconds: 5.0,
        );

        // Clip 1: valid sidecar with 0 samples (cursor still advances)
        final clip1Video = File('${tempDir.path}/empty_samples.mov');
        await clip1Video.writeAsBytes([1, 2]);
        final clip1Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: const [],
        );
        final clip1SidecarFile = File('${tempDir.path}/empty_samples.roi.json');
        await clip1SidecarFile.writeAsString(jsonEncode(clip1Sidecar.toJson()));

        final clip1 = VGClipDescriptor(
          id: 'empty_samples_clip',
          sourcePath: clip1Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        );

        // Clip 2: valid clip with samples
        final clip2Video = File('${tempDir.path}/valid2.mov');
        await clip2Video.writeAsBytes([3, 4]);
        final clip2Sidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 500,
              framePtsMs: 500,
              recordingRelativeMs: 500,
            ),
          ],
        );
        final clip2SidecarFile = File('${tempDir.path}/valid2.roi.json');
        await clip2SidecarFile.writeAsString(jsonEncode(clip2Sidecar.toJson()));

        final clip2 = VGClipDescriptor(
          id: 'valid_clip_2',
          sourcePath: clip2Video.path,
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 2.0,
        );

        final outputVideoPath = '${tempDir.path}/empty_samples_out.mp4';
        final exportRoiSidecarPath =
            '${tempDir.path}/empty_samples_out.roi.json';

        final processed = await VGRoiExportSidecarPostProcessor.processTimeline(
          clips: [clip1, clip2],
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          exportDurationSeconds: 4.0,
        );

        expect(processed, isTrue);

        final outputSidecarFile = File(exportRoiSidecarPath);
        final decoded = jsonDecode(await outputSidecarFile.readAsString());
        final resultSidecar = VGROISidecar.fromJson(decoded);

        expect(resultSidecar.samples.length, equals(1));
        // Clip 2 sample shifted past clip 1 output duration (2000ms) -> 2500ms
        expect(resultSidecar.samples[0].timestampMs, equals(2500));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 7. Explicit sourceRoiSidecarPath and Transform Forwarding (Phase 5-Unit O)
  // ---------------------------------------------------------------------------
  group('Explicit sourceRoiSidecarPath and Transform Forwarding (Phase 5-Unit O)', () {
    test(
      'explicit non-adjacent sidecar path maps successfully when no adjacent sidecar exists',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/no_adjacent_source.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        // Explicit sidecar located in a separate subdirectory/name
        final explicitSubdir = Directory('${tempDir.path}/custom_sidecars')
          ..createSync(recursive: true);
        final explicitSidecarFile = File(
          '${explicitSubdir.path}/explicit_source.roi.json',
        );

        final box = VGROIBox(x: 0.15, y: 0.25, w: 0.35, h: 0.45);
        final sample = _makeSample(
          timestampMs: 1200,
          framePtsMs: 1200,
          recordingRelativeMs: 1200,
          box: box,
        );
        final sourceSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [sample],
        );
        await explicitSidecarFile.writeAsString(
          jsonEncode(sourceSidecar.toJson()),
        );

        // Verify that NO adjacent sidecar exists
        final adjacentSidecarFile = File(
          '${tempDir.path}/no_adjacent_source.roi.json',
        );
        expect(adjacentSidecarFile.existsSync(), isFalse);

        final outputVideoPath = '${tempDir.path}/explicit_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/explicit_out.roi.json';
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString('{"version":1,"native":true}');

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          sourceRoiSidecarPath: explicitSidecarFile.path,
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
        expect(resultSidecar.samples.length, equals(1));
        _expectBoxCloseTo(resultSidecar.samples[0].box, box);

        expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
      },
    );

    test(
      'explicit missing path fails closed and does NOT fall back to valid adjacent sidecar',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/has_adjacent.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        // Create a valid adjacent sidecar
        final adjacentSidecarFile = File(
          '${tempDir.path}/has_adjacent.roi.json',
        );
        final adjacentSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 500,
              framePtsMs: 500,
              recordingRelativeMs: 500,
              box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            ),
          ],
        );
        await adjacentSidecarFile.writeAsString(
          jsonEncode(adjacentSidecar.toJson()),
        );

        final outputVideoPath = '${tempDir.path}/fail_closed_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/fail_closed_out.roi.json';
        const sentinel = '{"sentinel":"fallback_sidecar_must_remain"}';
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinel);

        // Point to a non-existent explicit path
        final nonExistentExplicitPath =
            '${tempDir.path}/does_not_exist_explicit.roi.json';

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          sourceRoiSidecarPath: nonExistentExplicitPath,
        );

        // Must fail closed (return false) and leave native sidecar intact
        expect(processed, isFalse);
        expect(await nativeEmptySidecar.readAsString(), equals(sentinel));
        expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
      },
    );

    test(
      'explicit malformed path fails closed and does NOT fall back to valid adjacent sidecar',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/has_adjacent_mal.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        // Create a valid adjacent sidecar
        final adjacentSidecarFile = File(
          '${tempDir.path}/has_adjacent_mal.roi.json',
        );
        final adjacentSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 500,
              framePtsMs: 500,
              recordingRelativeMs: 500,
              box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            ),
          ],
        );
        await adjacentSidecarFile.writeAsString(
          jsonEncode(adjacentSidecar.toJson()),
        );

        // Create a malformed explicit sidecar
        final malformedExplicitFile = File(
          '${tempDir.path}/malformed_explicit.roi.json',
        );
        await malformedExplicitFile.writeAsString('{not valid json at all!');

        final outputVideoPath = '${tempDir.path}/fail_mal_out.mp4';
        final exportRoiSidecarPath = '${tempDir.path}/fail_mal_out.roi.json';
        const sentinel = '{"sentinel":"fallback_sidecar_must_remain"}';
        final nativeEmptySidecar = File(exportRoiSidecarPath);
        await nativeEmptySidecar.writeAsString(sentinel);

        final processed = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          sourceRoiSidecarPath: malformedExplicitFile.path,
        );

        expect(processed, isFalse);
        expect(await nativeEmptySidecar.readAsString(), equals(sentinel));
        expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
      },
    );

    test(
      'transform parameters are forwarded and affect output ROI box',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
        );

        final sourceVideoFile = File('${tempDir.path}/transform_src.mov');
        await sourceVideoFile.writeAsBytes([1, 2, 3]);

        final box = VGROIBox(x: 0.2, y: 0.2, w: 0.4, h: 0.4);
        final sourceSidecar = _makeSourceSidecar(
          coordinateSpace: 'display_source_normalized',
          width: 1080,
          height: 1920,
          samples: [
            _makeSample(
              timestampMs: 1000,
              framePtsMs: 1000,
              recordingRelativeMs: 1000,
              box: box,
            ),
          ],
        );
        final sidecarFile = File('${tempDir.path}/transform_src.roi.json');
        await sidecarFile.writeAsString(jsonEncode(sourceSidecar.toJson()));

        // Pass 1: Identity transform
        final outPathIdentity = '${tempDir.path}/out_identity.mp4';
        final exportSidecarIdentity = '${tempDir.path}/out_identity.roi.json';
        await File(exportSidecarIdentity).writeAsString('{"version":1}');

        final processedIdentity = await VGRoiExportSidecarPostProcessor.process(
          sourceVideoPath: sourceVideoFile.path,
          outputVideoPath: outPathIdentity,
          exportRoiSidecarPath: exportSidecarIdentity,
          canvasWidth: 1080,
          canvasHeight: 1920,
          scaleX: 1.0,
          scaleY: 1.0,
          rotation: 0.0,
          translationX: 0.0,
          translationY: 0.0,
        );
        expect(processedIdentity, isTrue);

        final identityDecoded = jsonDecode(
          await File(exportSidecarIdentity).readAsString(),
        );
        final identitySidecar = VGROISidecar.fromJson(identityDecoded);
        final identityBox = identitySidecar.samples.first.box!;

        // Pass 2: Scaled and translated transform
        final outPathTransformed = '${tempDir.path}/out_transformed.mp4';
        final exportSidecarTransformed =
            '${tempDir.path}/out_transformed.roi.json';
        await File(exportSidecarTransformed).writeAsString('{"version":1}');

        final processedTransformed =
            await VGRoiExportSidecarPostProcessor.process(
              sourceVideoPath: sourceVideoFile.path,
              outputVideoPath: outPathTransformed,
              exportRoiSidecarPath: exportSidecarTransformed,
              canvasWidth: 1080,
              canvasHeight: 1920,
              scaleX: 1.5,
              scaleY: 1.5,
              translationX: 50.0,
              translationY: -30.0,
              rotation: 0.0,
            );
        expect(processedTransformed, isTrue);

        final transformedDecoded = jsonDecode(
          await File(exportSidecarTransformed).readAsString(),
        );
        final transformedSidecar = VGROISidecar.fromJson(transformedDecoded);
        final transformedBox = transformedSidecar.samples.first.box!;

        // The transformed box must differ from the identity box
        expect(
          transformedBox.x != identityBox.x ||
              transformedBox.y != identityBox.y ||
              transformedBox.w != identityBox.w ||
              transformedBox.h != identityBox.h,
          isTrue,
        );
      },
    );

    test(
      'processTimeline multi-clip uses each clip’s own explicit sidecar path and transform',
      () async {
        mockInspectMedia(
          width: 1080,
          height: 1920,
          displayWidth: 1080,
          displayHeight: 1920,
          durationSeconds: 5.0,
        );

        final clip1Video = File('${tempDir.path}/mc_explicit_c1.mov');
        await clip1Video.writeAsBytes([1, 2, 3]);
        final clip1ExplicitSidecar = File('${tempDir.path}/custom_c1.roi.json');
        final clip1Box = VGROIBox(x: 0.1, y: 0.1, w: 0.3, h: 0.3);
        await clip1ExplicitSidecar.writeAsString(
          jsonEncode(
            _makeSourceSidecar(
              coordinateSpace: 'display_source_normalized',
              width: 1080,
              height: 1920,
              samples: [
                _makeSample(
                  timestampMs: 600,
                  framePtsMs: 600,
                  recordingRelativeMs: 600,
                  box: clip1Box,
                ),
              ],
            ).toJson(),
          ),
        );

        final clip2Video = File('${tempDir.path}/mc_explicit_c2.mov');
        await clip2Video.writeAsBytes([4, 5, 6]);
        final clip2ExplicitSidecar = File('${tempDir.path}/custom_c2.roi.json');
        final clip2Box = VGROIBox(x: 0.2, y: 0.2, w: 0.4, h: 0.4);
        await clip2ExplicitSidecar.writeAsString(
          jsonEncode(
            _makeSourceSidecar(
              coordinateSpace: 'display_source_normalized',
              width: 1080,
              height: 1920,
              samples: [
                _makeSample(
                  timestampMs: 800,
                  framePtsMs: 800,
                  recordingRelativeMs: 800,
                  box: clip2Box,
                ),
              ],
            ).toJson(),
          ),
        );

        // Neither clip has an adjacent sidecar
        expect(
          File('${tempDir.path}/mc_explicit_c1.roi.json').existsSync(),
          isFalse,
        );
        expect(
          File('${tempDir.path}/mc_explicit_c2.roi.json').existsSync(),
          isFalse,
        );

        final clip1 = VGClipDescriptor(
          id: 'mc_c1',
          sourcePath: clip1Video.path,
          sourceRoiSidecarPath: clip1ExplicitSidecar.path,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 3.0,
        );

        final clip2 = VGClipDescriptor(
          id: 'mc_c2',
          sourcePath: clip2Video.path,
          sourceRoiSidecarPath: clip2ExplicitSidecar.path,
          durationSeconds: 4.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 4.0,
          transform: const VGClipTransformDescriptor(
            scaleX: 1.5,
            scaleY: 1.5,
            translationX: 20.0,
            translationY: 10.0,
          ),
        );

        final outputVideoPath = '${tempDir.path}/mc_explicit_timeline.mp4';
        final exportRoiSidecarPath =
            '${tempDir.path}/mc_explicit_timeline.roi.json';
        await File(exportRoiSidecarPath).writeAsString('{"version":1}');

        final processed = await VGRoiExportSidecarPostProcessor.processTimeline(
          clips: [clip1, clip2],
          outputVideoPath: outputVideoPath,
          exportRoiSidecarPath: exportRoiSidecarPath,
          canvasWidth: 720,
          canvasHeight: 1280,
          exportDurationSeconds: 7.0,
        );

        expect(processed, isTrue);

        final outputSidecarFile = File(exportRoiSidecarPath);
        final decoded = jsonDecode(await outputSidecarFile.readAsString());
        final resultSidecar = VGROISidecar.fromJson(decoded);

        expect(resultSidecar.samples.length, equals(2));
        // Sample 1 from clip 1 at 600ms
        expect(resultSidecar.samples[0].timestampMs, equals(600));
        _expectBoxCloseTo(resultSidecar.samples[0].box, clip1Box);

        // Sample 2 from clip 2 at 800ms + 3000ms (clip 1 output duration) = 3800ms
        expect(resultSidecar.samples[1].timestampMs, equals(3800));
        // Clip 2's box should be transformed (not identical to raw clip2Box)
        final clip2MappedBox = resultSidecar.samples[1].box!;
        expect(
          clip2MappedBox.w != clip2Box.w || clip2MappedBox.h != clip2Box.h,
          isTrue,
        );

        expect(File('$exportRoiSidecarPath.vgroitmp').existsSync(), isFalse);
      },
    );
  });
}
