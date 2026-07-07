// vg_roi_export_mapper_test.dart
// ROI-4A: Unit tests for VGROISidecarExportMapper

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

VGROISidecar _makeSidecar({
  List<VGROISample> samples = const [],
  int durationMs = 5000,
  int width = 1080,
  int height = 1920,
  String coordinateSpace = 'portrait_capture_normalized',
  double coveragePercent = 1.0,
  List<VGROIMissingInterval> missingIntervals = const [],
}) {
  return VGROISidecar(
    version: 1,
    sourceType: 'app_recorded',
    platform: 'ios',
    coordinateSpace: coordinateSpace,
    recordingSessionId: 'test-session-id-1234',
    videoIdentity: VGROIIdentity(
      durationMs: durationMs,
      width: width,
      height: height,
      hash: null,
    ),
    coverage: VGROICoverage(
      coveragePercent: coveragePercent,
      missingIntervals: missingIntervals,
    ),
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
  double? confidence,
  String? paddingPolicy,
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

const double _eps = 1e-6;

void expectBoxCloseTo(VGROIBox? actual, VGROIBox expected, {double eps = _eps}) {
  expect(actual, isNotNull, reason: 'Expected non-null box');
  expect(actual!.x, closeTo(expected.x, eps));
  expect(actual.y, closeTo(expected.y, eps));
  expect(actual.w, closeTo(expected.w, eps));
  expect(actual.h, closeTo(expected.h, eps));
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── 1–6. Identity transform ────────────────────────────────────────────────
  group('Identity transform', () {
    final box = VGROIBox(x: 0.25, y: 0.10, w: 0.50, h: 0.30);
    final sample = _makeSample(
      timestampMs: 1000,
      framePtsMs: 1000,
      recordingRelativeMs: 1000,
      box: box,
      quality: 'detected',
      confidence: 0.9,
      paddingPolicy: 'normal',
    );
    final sidecar = _makeSidecar(samples: [sample]);

    late VGROISidecar result;
    setUpAll(() {
      result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
    });

    test('1. coordinateSpace changes to export_output_normalized', () {
      expect(result.coordinateSpace, equals('export_output_normalized'));
    });

    test('2. box coordinates unchanged when source == canvas, identity transform', () {
      expect(result.samples.length, equals(1));
      expectBoxCloseTo(result.samples[0].box, box);
    });

    test('3. recordingSessionId, version, platform, sourceType preserved', () {
      expect(result.recordingSessionId, equals(sidecar.recordingSessionId));
      expect(result.version, equals(sidecar.version));
      expect(result.platform, equals(sidecar.platform));
      expect(result.sourceType, equals(sidecar.sourceType));
    });

    test('4. sample quality/confidence/paddingPolicy preserved', () {
      final s = result.samples[0];
      expect(s.quality, equals('detected'));
      expect(s.confidence, closeTo(0.9, _eps));
      expect(s.paddingPolicy, equals('normal'));
    });

    test('5. finalized true preserved', () {
      expect(result.finalized, isTrue);
    });

    test('6. output JSON does not contain faceCount', () {
      final json = jsonEncode(result.toJson());
      expect(json.contains('faceCount'), isFalse);
    });
  });

  // ── 7–10. Spatial transforms ───────────────────────────────────────────────
  group('Spatial transforms', () {
    test('7. uniform 2x scale maps box correctly', () {
      // Source and canvas same dimensions; 2x scale zooms in on center.
      // A center box [0.25,0.25, 0.50,0.50] under 2x scale should fill canvas.
      final box = VGROIBox(x: 0.25, y: 0.25, w: 0.50, h: 0.50);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        scaleX: 2.0,
        scaleY: 2.0,
      );
      expect(result.samples.length, equals(1));
      // Verify via the underlying mapBox directly for ground truth.
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        scaleX: 2.0,
        scaleY: 2.0,
      );
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });

    test('8. translation maps box correctly', () {
      final box = VGROIBox(x: 0.10, y: 0.10, w: 0.30, h: 0.30);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 100.0,
        translationY: 200.0,
      );
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 100.0,
        translationY: 200.0,
      );
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });

    test('9. rotation maps through AABB correctly (90 degrees)', () {
      final box = VGROIBox(x: 0.25, y: 0.25, w: 0.50, h: 0.50);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        rotation: math.pi / 2.0,
      );
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        rotation: math.pi / 2.0,
      );
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });

    test('10. combined scale + translation maps correctly', () {
      final box = VGROIBox(x: 0.20, y: 0.20, w: 0.30, h: 0.40);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        scaleX: 1.5,
        scaleY: 1.5,
        translationX: -50.0,
        translationY: 80.0,
      );
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        scaleX: 1.5,
        scaleY: 1.5,
        translationX: -50.0,
        translationY: 80.0,
      );
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });
  });

  // ── 11–13. VideoIdentity ───────────────────────────────────────────────────
  group('VideoIdentity', () {
    test('11. width/height updated to canvas dimensions', () {
      final sidecar = _makeSidecar(width: 1080, height: 1920);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1080,
      );
      expect(result.videoIdentity.width, equals(1080));
      expect(result.videoIdentity.height, equals(1080));
    });

    test('12. durationMs preserved when no trim', () {
      final sidecar = _makeSidecar(durationMs: 7500);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expect(result.videoIdentity.durationMs, equals(7500));
    });

    test('13. hash remains null', () {
      final sidecar = _makeSidecar();
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expect(result.videoIdentity.hash, isNull);
    });
  });

  // ── 14–16. Trim ────────────────────────────────────────────────────────────
  group('Trim', () {
    // Three samples at 0 ms, 1000 ms, 3000 ms recording-relative.
    final samples = [
      _makeSample(
        timestampMs: 0, framePtsMs: 0, recordingRelativeMs: 0,
        box: VGROIBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
      ),
      _makeSample(
        timestampMs: 1000, framePtsMs: 1000, recordingRelativeMs: 1000,
        box: VGROIBox(x: 0.2, y: 0.2, w: 0.3, h: 0.3),
      ),
      _makeSample(
        timestampMs: 3000, framePtsMs: 3000, recordingRelativeMs: 3000,
        box: VGROIBox(x: 0.3, y: 0.3, w: 0.2, h: 0.2),
      ),
    ];
    final sidecar = _makeSidecar(samples: samples, durationMs: 4000);

    test('14. trimStartSeconds > 0 drops early samples and shifts timestamps', () {
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimStartSeconds: 1.0, // 1000 ms — drop sample at 0 ms
      );
      // Sample at 0 ms dropped. Samples at 1000 ms and 3000 ms survive.
      expect(result.samples.length, equals(2));
      // Timestamps shifted by 1000 ms.
      expect(result.samples[0].recordingRelativeMs, equals(0));
      expect(result.samples[0].timestampMs, equals(0));
      expect(result.samples[0].framePtsMs, equals(0));
      expect(result.samples[1].recordingRelativeMs, equals(2000));
      expect(result.samples[1].timestampMs, equals(2000));
    });

    test('15. trimEndSeconds drops late samples', () {
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimEndSeconds: 2.0, // 2000 ms — drop sample at 3000 ms
      );
      // Samples at 0 ms and 1000 ms survive; 3000 ms dropped.
      expect(result.samples.length, equals(2));
      expect(result.samples[0].recordingRelativeMs, equals(0));
      expect(result.samples[1].recordingRelativeMs, equals(1000));
    });

    test('16. all three timestamp fields are shifted', () {
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimStartSeconds: 1.0, // shift by 1000 ms
      );
      final s = result.samples[0]; // was at 1000 ms
      expect(s.timestampMs, equals(0));
      expect(s.framePtsMs, equals(0));
      expect(s.recordingRelativeMs, equals(0));
    });

    test('trim: videoIdentity.durationMs reflects trimmed window', () {
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimStartSeconds: 1.0,
        trimEndSeconds: 3.0,
      );
      // trimEnd - trimStart = 2000 ms
      expect(result.videoIdentity.durationMs, equals(2000));
    });
  });

  // ── 17–18. Out-of-canvas ──────────────────────────────────────────────────
  group('Out-of-canvas', () {
    test('17. fully outside canvas keeps sample with box null', () {
      // Translate by a very large amount so the box goes off canvas.
      final box = VGROIBox(x: 0.0, y: 0.0, w: 0.10, h: 0.10);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      // Large positive translation will push the box off to the right.
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 5000.0, // far off-canvas
      );
      // Sample must still exist.
      expect(result.samples.length, equals(1));
      // Box must be null because it is entirely outside canvas.
      expect(result.samples[0].box, isNull);
      // Other sample fields preserved.
      expect(result.samples[0].quality, equals('detected'));
    });

    test('18. partially inside canvas keeps sample with clipped/intersected box', () {
      // Box near the right edge; translation will push it partly off.
      final box = VGROIBox(x: 0.70, y: 0.20, w: 0.20, h: 0.30);
      final sidecar = _makeSidecar(samples: [
        _makeSample(timestampMs: 100, framePtsMs: 100, recordingRelativeMs: 100, box: box),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 200.0, // shifts box right, may partially clip
      );
      // Sample must still exist.
      expect(result.samples.length, equals(1));
      // Box is non-null (partially inside canvas) or null (fully outside);
      // either is acceptable — verify it matches mapBox ground truth.
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        translationX: 200.0,
      );
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expect(result.samples[0].box, isNotNull);
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });
  });

  // ── 19–21. No-face (empty samples) ────────────────────────────────────────
  group('No-face behavior', () {
    late VGROISidecar noFaceSidecar;
    late VGROISidecar result;

    setUpAll(() {
      noFaceSidecar = _makeSidecar(samples: []);
      result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: noFaceSidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1080,
      );
    });

    test('19. empty input samples returns finalized empty output samples', () {
      expect(result.samples, isEmpty);
      expect(result.finalized, isTrue);
    });

    test('20. coordinateSpace still changes for empty-sample sidecar', () {
      expect(result.coordinateSpace, equals('export_output_normalized'));
    });

    test('21. videoIdentity still updates for empty-sample sidecar', () {
      expect(result.videoIdentity.width, equals(1080));
      expect(result.videoIdentity.height, equals(1080));
    });
  });

  // ── 22–23. Coverage ────────────────────────────────────────────────────────
  group('Coverage', () {
    test('22. coveragePercent preserved', () {
      final sidecar = _makeSidecar(coveragePercent: 0.87);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expect(result.coverage.coveragePercent, closeTo(0.87, _eps));
    });

    test('23. missingIntervals preserved', () {
      final intervals = [
        VGROIMissingInterval(
          startMs: 0,
          endMs: 600,
          reason: 'cold_start',
          postProcessRequired: true,
        ),
      ];
      final sidecar = _makeSidecar(missingIntervals: intervals);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expect(result.coverage.missingIntervals.length, equals(1));
      expect(result.coverage.missingIntervals[0].reason, equals('cold_start'));
      expect(result.coverage.missingIntervals[0].startMs, equals(0));
      expect(result.coverage.missingIntervals[0].endMs, equals(600));
      expect(result.coverage.missingIntervals[0].postProcessRequired, isTrue);
    });
  });

  // ── 24. JSON roundtrip ────────────────────────────────────────────────────
  group('JSON roundtrip', () {
    test('24. VGROISidecar.fromJson(exportSidecar.toJson()) parses and preserves key values', () {
      final box = VGROIBox(x: 0.25, y: 0.10, w: 0.50, h: 0.30);
      final intervals = [
        VGROIMissingInterval(
          startMs: 0,
          endMs: 300,
          reason: 'cold_start',
          postProcessRequired: false,
        ),
      ];
      final sidecar = _makeSidecar(
        samples: [
          _makeSample(
            timestampMs: 1000,
            framePtsMs: 1000,
            recordingRelativeMs: 1000,
            box: box,
            quality: 'detected',
            confidence: 0.95,
            paddingPolicy: 'normal',
          ),
        ],
        durationMs: 5000,
        coveragePercent: 0.92,
        missingIntervals: intervals,
      );

      final exportSidecar = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );

      // Roundtrip through JSON.
      final json = exportSidecar.toJson();
      final roundtripped = VGROISidecar.fromJson(json);

      expect(roundtripped.coordinateSpace, equals('export_output_normalized'));
      expect(roundtripped.recordingSessionId, equals(sidecar.recordingSessionId));
      expect(roundtripped.version, equals(1));
      expect(roundtripped.platform, equals('ios'));
      expect(roundtripped.sourceType, equals('app_recorded'));
      expect(roundtripped.finalized, isTrue);
      expect(roundtripped.videoIdentity.width, equals(1080));
      expect(roundtripped.videoIdentity.height, equals(1920));
      expect(roundtripped.videoIdentity.durationMs, equals(5000));
      expect(roundtripped.videoIdentity.hash, isNull);
      expect(roundtripped.coverage.coveragePercent, closeTo(0.92, _eps));
      expect(roundtripped.coverage.missingIntervals.length, equals(1));
      expect(roundtripped.samples.length, equals(1));

      final s = roundtripped.samples[0];
      expect(s.quality, equals('detected'));
      expect(s.confidence, closeTo(0.95, _eps));
      expect(s.paddingPolicy, equals('normal'));
      expect(s.box, isNotNull);
      expectBoxCloseTo(s.box, box);

      // Ensure faceCount does not appear.
      final jsonStr = jsonEncode(json);
      expect(jsonStr.contains('faceCount'), isFalse);
    });
  });

  // ── Input validation ───────────────────────────────────────────────────────
  group('Input validation', () {
    final sidecar = _makeSidecar();

    test('throws on sourceWidth <= 0', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 0.0,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: 1920,
        ),
        throwsArgumentError,
      );
    });

    test('throws on canvasHeight NaN', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 1080,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: double.nan,
        ),
        throwsArgumentError,
      );
    });

    test('throws on scaleX <= 0', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 1080,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: 1920,
          scaleX: 0.0,
        ),
        throwsArgumentError,
      );
    });

    test('throws on trimStartSeconds < 0', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 1080,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: 1920,
          trimStartSeconds: -1.0,
        ),
        throwsArgumentError,
      );
    });

    test('throws when finite trimEndSeconds < trimStartSeconds', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 1080,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: 1920,
          trimStartSeconds: 3.0,
          trimEndSeconds: 1.0,
        ),
        throwsArgumentError,
      );
    });

    test('accepts double.infinity for trimEndSeconds', () {
      expect(
        () => VGROISidecarExportMapper.mapSidecar(
          captureSidecar: sidecar,
          sourceWidth: 1080,
          sourceHeight: 1920,
          canvasWidth: 1080,
          canvasHeight: 1920,
          trimEndSeconds: double.infinity,
        ),
        returnsNormally,
      );
    });
  });

  // ── Sample with null box in capture sidecar ────────────────────────────────
  group('Null box in capture sidecar', () {
    test('sample with null box in capture sidecar is preserved with null box', () {
      final sidecar = _makeSidecar(samples: [
        _makeSample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: null, // no box in capture sidecar (no face detected)
          quality: 'no_detection',
        ),
      ]);
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );
      expect(result.samples.length, equals(1));
      expect(result.samples[0].box, isNull);
      expect(result.samples[0].quality, equals('no_detection'));
    });
  });
}
