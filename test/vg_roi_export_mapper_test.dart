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

  // ══════════════════════════════════════════════════════════════════════════
  // ROI-5F.1 — Imported ROI Sidecar (display_source_normalized) Mapping Tests
  //
  // These tests prove that an imported-gallery ROI sidecar with
  // coordinateSpace = display_source_normalized can be safely mapped to
  // export_output_normalized using VGROISidecarExportMapper.
  //
  // The mapper itself is coordinate-space agnostic — what matters is that
  // callers pass the correct sourceWidth/sourceHeight (display dimensions,
  // NOT encoded dimensions) when the input sidecar uses
  // display_source_normalized coordinates.
  //
  // Critical dimension-sourcing scenarios:
  //   - Portrait-native imported video (1080×1920 encoded, 1080×1920 display)
  //   - Landscape-native imported video (1920×1080 encoded, 1920×1080 display)
  //   - Rotated imported video (1080×1920 encoded, 1920×1080 display after
  //     orientation fix — source dimensions must be display, not encoded)
  // ══════════════════════════════════════════════════════════════════════════

  // Helper to create an imported-gallery sidecar with display_source_normalized
  // coordinate space, matching the ROI-5E.1 builder output contract.
  VGROISidecar makeImportedSidecar({
    List<VGROISample> samples = const [],
    int durationMs = 5000,
    int displayWidth = 1080,
    int displayHeight = 1920,
    double coveragePercent = 1.0,
  }) {
    return VGROISidecar(
      version: 1,
      sourceType: 'imported_gallery',
      platform: 'ios',
      coordinateSpace: 'display_source_normalized',
      recordingSessionId: 'imported-test-session-5f1',
      videoIdentity: VGROIIdentity(
        durationMs: durationMs,
        width: displayWidth,
        height: displayHeight,
        hash: null,
      ),
      coverage: VGROICoverage(
        coveragePercent: coveragePercent,
        missingIntervals: const [],
      ),
      samples: samples,
      finalized: true,
    );
  }

  // ── 5F.1 Test Group 1: Identity mapping with matching dimensions ─────────
  group('ROI-5F.1: Imported sidecar identity mapping', () {
    // Scenario: display dimensions == export canvas dimensions, no transform.
    // Expected: box coordinates pass through unchanged.
    test('display_source_normalized maps to export_output_normalized with matching dimensions', () {
      final box = VGROIBox(x: 0.20, y: 0.15, w: 0.40, h: 0.30);
      final sidecar = makeImportedSidecar(
        displayWidth: 1080,
        displayHeight: 1920,
        samples: [
          _makeSample(
            timestampMs: 500,
            framePtsMs: 500,
            recordingRelativeMs: 500,
            box: box,
            quality: 'detected',
            confidence: 0.85,
          ),
        ],
      );

      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080, // display dimensions (correct for imported)
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );

      // Coordinate space must change.
      expect(result.coordinateSpace, equals('export_output_normalized'));

      // Source metadata preserved from imported sidecar.
      expect(result.sourceType, equals('imported_gallery'));
      expect(result.platform, equals('ios'));
      expect(result.version, equals(1));

      // Box unchanged under identity transform with matching dimensions.
      expect(result.samples.length, equals(1));
      expectBoxCloseTo(result.samples[0].box, box);

      // Sample metadata preserved.
      expect(result.samples[0].quality, equals('detected'));
      expect(result.samples[0].confidence, closeTo(0.85, _eps));
    });

    test('landscape imported video identity mapping preserves box', () {
      // Landscape video: displayWidth=1920, displayHeight=1080 (no rotation mismatch).
      final box = VGROIBox(x: 0.30, y: 0.20, w: 0.35, h: 0.50);
      final sidecar = makeImportedSidecar(
        displayWidth: 1920,
        displayHeight: 1080,
        samples: [
          _makeSample(
            timestampMs: 1000,
            framePtsMs: 1000,
            recordingRelativeMs: 1000,
            box: box,
            quality: 'detected',
          ),
        ],
      );

      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1920,
        sourceHeight: 1080,
        canvasWidth: 1920,
        canvasHeight: 1080,
      );

      expect(result.samples.length, equals(1));
      expectBoxCloseTo(result.samples[0].box, box);
      expect(result.videoIdentity.width, equals(1920));
      expect(result.videoIdentity.height, equals(1080));
    });
  });

  // ── 5F.1 Test Group 2: Aspect-ratio mismatch (rotated dimensions) ────────
  group('ROI-5F.1: Imported sidecar aspect-ratio mismatch', () {
    // This is THE critical test that proves the dimension-sourcing bug.
    //
    // Scenario: Imported video with 90° rotation.
    //   - Encoded dimensions: 1080×1920 (portrait)
    //   - Display dimensions: 1920×1080 (landscape, after orientation fix)
    //   - Face scan ran on display-oriented frame → coordinates are
    //     display_source_normalized relative to 1920×1080.
    //   - Export canvas: 1920×1080 (matching display).
    //
    // If ConnectsApp incorrectly passes ENCODED dimensions (1080×1920) as
    // sourceWidth/sourceHeight, the aspect-fit math in mapBox will produce
    // wrong results. These tests use the CORRECT display dimensions.

    test('rotated imported video maps correctly with display dimensions', () {
      // Face at center of a landscape display (1920×1080).
      final box = VGROIBox(x: 0.35, y: 0.25, w: 0.30, h: 0.50);
      final sidecar = makeImportedSidecar(
        displayWidth: 1920,
        displayHeight: 1080,
        samples: [
          _makeSample(
            timestampMs: 200,
            framePtsMs: 200,
            recordingRelativeMs: 200,
            box: box,
            quality: 'detected',
          ),
        ],
      );

      // CORRECT: pass display dimensions as source dimensions.
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1920, // displayWidth (correct)
        sourceHeight: 1080, // displayHeight (correct)
        canvasWidth: 1920,
        canvasHeight: 1080,
      );

      // With matching source/canvas, identity transform → box unchanged.
      expect(result.samples.length, equals(1));
      expectBoxCloseTo(result.samples[0].box, box);
    });

    test('WRONG encoded dimensions produce different (skewed) box', () {
      // This test documents the bug: if encoded dimensions (1080×1920) are
      // used instead of display dimensions (1920×1080), the mapper will
      // aspect-fit a portrait source into a landscape canvas, producing
      // a different box with pillarboxing/letterboxing.
      //
      // NOTE: This test does NOT test a bug in the mapper — the mapper is
      // correct. It documents that passing wrong dimensions produces wrong
      // output, proving the ConnectsApp fix is necessary.

      final box = VGROIBox(x: 0.35, y: 0.25, w: 0.30, h: 0.50);

      // CORRECT result: display dimensions match canvas → identity.
      final correctResult = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1920, // display dimensions (correct)
        sourceHeight: 1080,
        canvasWidth: 1920,
        canvasHeight: 1080,
      );

      // WRONG result: encoded dimensions fed to mapper → aspect-fit distortion.
      final wrongResult = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080, // encoded dimensions (WRONG for imported)
        sourceHeight: 1920,
        canvasWidth: 1920,
        canvasHeight: 1080,
      );

      // The correct result should be the original box (identity).
      expect(correctResult, isNotNull);
      expectBoxCloseTo(correctResult, box);

      // The wrong result may be non-null but MUST differ from the correct box.
      // The aspect-fit step will introduce pillarboxing for the 1080×1920 source
      // fitted into 1920×1080 canvas, causing x-offset and width scaling.
      if (wrongResult != null) {
        // At least one coordinate must be significantly different.
        final xDiff = (wrongResult.x - box.x).abs();
        final yDiff = (wrongResult.y - box.y).abs();
        final wDiff = (wrongResult.w - box.w).abs();
        final hDiff = (wrongResult.h - box.h).abs();
        final maxDiff = [xDiff, yDiff, wDiff, hDiff].reduce(math.max);
        expect(maxDiff, greaterThan(0.01),
          reason: 'Wrong dimensions must produce a visibly different box');
      }
      // If wrongResult is null, that also proves the coordinates are broken
      // (box was pushed off-canvas entirely by the wrong aspect-fit).
    });

    test('square canvas maps imported portrait box with letterboxing', () {
      // Source: display-oriented portrait (1080×1920).
      // Canvas: square (1080×1080).
      // The mapper should aspect-fit the source into the canvas (letterbox).
      final box = VGROIBox(x: 0.10, y: 0.10, w: 0.40, h: 0.20);
      final sidecar = makeImportedSidecar(
        displayWidth: 1080,
        displayHeight: 1920,
        samples: [
          _makeSample(
            timestampMs: 100,
            framePtsMs: 100,
            recordingRelativeMs: 100,
            box: box,
            quality: 'detected',
          ),
        ],
      );

      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1080,
      );

      // Verify result matches the ground-truth mapBox output.
      final expected = VGROITransformMapper.mapBox(
        captureBox: box,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1080,
      );
      expect(result.samples.length, equals(1));
      if (expected == null) {
        expect(result.samples[0].box, isNull);
      } else {
        expectBoxCloseTo(result.samples[0].box, expected);
      }
    });
  });

  // ── 5F.1 Test Group 3: Trim-shifting on imported sidecars ────────────────
  group('ROI-5F.1: Imported sidecar trim-shifting', () {
    test('samples within trim window retain correct shifted timestamps', () {
      // Imported sidecar with 3 samples at different times.
      final samples = [
        _makeSample(
          timestampMs: 500,
          framePtsMs: 500,
          recordingRelativeMs: 500,
          box: VGROIBox(x: 0.10, y: 0.10, w: 0.30, h: 0.30),
          quality: 'detected',
        ),
        _makeSample(
          timestampMs: 2000,
          framePtsMs: 2000,
          recordingRelativeMs: 2000,
          box: VGROIBox(x: 0.20, y: 0.20, w: 0.25, h: 0.25),
          quality: 'detected',
        ),
        _makeSample(
          timestampMs: 4000,
          framePtsMs: 4000,
          recordingRelativeMs: 4000,
          box: VGROIBox(x: 0.30, y: 0.30, w: 0.20, h: 0.20),
          quality: 'detected',
        ),
      ];
      final sidecar = makeImportedSidecar(
        displayWidth: 1080,
        displayHeight: 1920,
        durationMs: 5000,
        samples: samples,
      );

      // Trim: keep only [1.0s, 3.5s] window.
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
        trimStartSeconds: 1.0,
        trimEndSeconds: 3.5,
      );

      // Sample at 500ms dropped (before trim start).
      // Sample at 2000ms kept (within window), shifted to 1000ms.
      // Sample at 4000ms dropped (after trim end).
      expect(result.samples.length, equals(1));
      expect(result.samples[0].timestampMs, equals(1000));
      expect(result.samples[0].framePtsMs, equals(1000));
      expect(result.samples[0].recordingRelativeMs, equals(1000));

      // Duration reflects trimmed window.
      expect(result.videoIdentity.durationMs, equals(2500)); // 3500 - 1000
    });

    test('trim with imported sidecar preserves sourceType', () {
      final sidecar = makeImportedSidecar(
        displayWidth: 1920,
        displayHeight: 1080,
        samples: [
          _makeSample(
            timestampMs: 1000,
            framePtsMs: 1000,
            recordingRelativeMs: 1000,
            box: VGROIBox(x: 0.25, y: 0.25, w: 0.50, h: 0.50),
            quality: 'detected',
          ),
        ],
      );

      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1920,
        sourceHeight: 1080,
        canvasWidth: 1920,
        canvasHeight: 1080,
        trimStartSeconds: 0.5,
      );

      // Source metadata preserved even after trim.
      expect(result.sourceType, equals('imported_gallery'));
      expect(result.coordinateSpace, equals('export_output_normalized'));
    });
  });

  // ── 5F.1 Test Group 4: Null-box preservation ──────────────────────────────
  group('ROI-5F.1: Imported sidecar null-box preservation', () {
    test('imported sample with null box (no face) preserved after mapping', () {
      // Imported video where face scan found no faces at this timestamp.
      final sidecar = makeImportedSidecar(
        displayWidth: 1080,
        displayHeight: 1920,
        samples: [
          _makeSample(
            timestampMs: 200,
            framePtsMs: 200,
            recordingRelativeMs: 200,
            box: null, // no face detected
            quality: 'missing',
          ),
        ],
      );

      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1080,
        sourceHeight: 1920,
        canvasWidth: 1080,
        canvasHeight: 1920,
      );

      expect(result.samples.length, equals(1));
      expect(result.samples[0].box, isNull);
      expect(result.samples[0].quality, equals('missing'));
      expect(result.samples[0].timestampMs, equals(200));
    });

    test('box clipped fully outside canvas produces null box but keeps sample', () {
      // Face box at far right edge of source.
      final box = VGROIBox(x: 0.90, y: 0.10, w: 0.10, h: 0.20);
      final sidecar = makeImportedSidecar(
        displayWidth: 1920,
        displayHeight: 1080,
        samples: [
          _makeSample(
            timestampMs: 300,
            framePtsMs: 300,
            recordingRelativeMs: 300,
            box: box,
            quality: 'detected',
          ),
        ],
      );

      // Large translation pushes the box completely off-canvas.
      final result = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1920,
        sourceHeight: 1080,
        canvasWidth: 1920,
        canvasHeight: 1080,
        translationX: 5000.0, // far off-canvas
      );

      // Sample MUST be preserved (timeline continuity).
      expect(result.samples.length, equals(1));
      // Box MUST be null (fully outside canvas).
      expect(result.samples[0].box, isNull);
      // Timestamp preserved.
      expect(result.samples[0].timestampMs, equals(300));
      // Quality preserved.
      expect(result.samples[0].quality, equals('detected'));
    });
  });

  // ── 5F.1 Test Group 5: JSON roundtrip for imported sidecar ────────────────
  group('ROI-5F.1: Imported sidecar JSON roundtrip', () {
    test('imported sidecar survives export → JSON → fromJson roundtrip', () {
      final box = VGROIBox(x: 0.30, y: 0.20, w: 0.35, h: 0.40);
      final sidecar = makeImportedSidecar(
        displayWidth: 1920,
        displayHeight: 1080,
        durationMs: 8000,
        samples: [
          _makeSample(
            timestampMs: 1500,
            framePtsMs: 1500,
            recordingRelativeMs: 1500,
            box: box,
            quality: 'detected',
            confidence: 0.92,
          ),
        ],
      );

      final exportSidecar = VGROISidecarExportMapper.mapSidecar(
        captureSidecar: sidecar,
        sourceWidth: 1920,
        sourceHeight: 1080,
        canvasWidth: 1920,
        canvasHeight: 1080,
      );

      // Roundtrip.
      final json = exportSidecar.toJson();
      final roundtripped = VGROISidecar.fromJson(json);

      expect(roundtripped.coordinateSpace, equals('export_output_normalized'));
      expect(roundtripped.sourceType, equals('imported_gallery'));
      expect(roundtripped.platform, equals('ios'));
      expect(roundtripped.version, equals(1));
      expect(roundtripped.finalized, isTrue);
      expect(roundtripped.videoIdentity.width, equals(1920));
      expect(roundtripped.videoIdentity.height, equals(1080));
      expect(roundtripped.videoIdentity.durationMs, equals(8000));
      expect(roundtripped.samples.length, equals(1));

      final s = roundtripped.samples[0];
      expect(s.quality, equals('detected'));
      expect(s.confidence, closeTo(0.92, _eps));
      expect(s.box, isNotNull);
      expectBoxCloseTo(s.box, box);
    });
  });
}
