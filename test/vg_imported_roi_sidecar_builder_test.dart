// vg_imported_roi_sidecar_builder_test.dart
// ROI-5E.1 Unit Tests: VGImportedROISidecarBuilder

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Returns a minimal valid [MediaInfo] with display dimensions and 'valid'
/// orientation status — safe defaults for most tests.
MediaInfo _makeMediaInfo({
  int displayWidth  = 720,
  int displayHeight = 1280,
  int encodedWidth  = 720,
  int encodedHeight = 1280,
  double durationSeconds = 10.0,
  String orientationStatus = 'valid',
  int? rotationDegrees = 0,
}) {
  return MediaInfo(
    kind:                 MediaKind.video,
    container:            'mp4',
    videoCodec:           'h264',
    audioCodec:           'aac',
    width:                encodedWidth,
    height:               encodedHeight,
    durationSeconds:      durationSeconds,
    bitrateKbps:          1000,
    fps:                  30.0,
    fileSizeBytes:        1_000_000,
    hasVideo:             true,
    hasAudio:             true,
    isHDR:                false,
    hasMoovAtFront:       true,
    hasRotationTransform: rotationDegrees != 0,
    hasEmbeddedMetadata:  false,
    encodedWidth:         encodedWidth,
    encodedHeight:        encodedHeight,
    displayWidth:         displayWidth,
    displayHeight:        displayHeight,
    rotationDegrees:      rotationDegrees,
    orientationStatus:    orientationStatus,
  );
}

/// Returns a minimal valid face scan evidence map matching the given frame size.
Map<String, dynamic> _makeEvidence({
  int frameWidth  = 720,
  int frameHeight = 1280,
  double actualTimeSeconds = 0.033,
  List<Map<String, dynamic>> faces = const [],
}) {
  return {
    'frameWidth':         frameWidth,
    'frameHeight':        frameHeight,
    'faceCount':          faces.length,
    'faces':              faces,
    'actualTimeSeconds':  actualTimeSeconds,
    'requestedTimeSeconds': 0.0,
    'method':             'VNDetectFaceRectanglesRequest',
    'frameExtractionMethod': 'AVAssetImageGenerator',
    'visionOrientation':  'up',
    'coordinateSpace':    'displayTopLeftNormalizedAndPixels',
  };
}

/// Returns a well-formed face map as returned by the native iOS plugin.
Map<String, dynamic> _makeFace({
  int index = 0,
  double normalizedX = 0.2,
  double normalizedY = 0.15,
  double normalizedWidth = 0.3,
  double normalizedHeight = 0.4,
  double visionX = 0.2,
  double visionY = 0.45,
  double visionWidth = 0.3,
  double visionHeight = 0.4,
  bool clamped = false,
}) {
  return {
    'index':            index,
    'normalizedX':      normalizedX,
    'normalizedY':      normalizedY,
    'normalizedWidth':  normalizedWidth,
    'normalizedHeight': normalizedHeight,
    'visionX':          visionX,
    'visionY':          visionY,
    'visionWidth':      visionWidth,
    'visionHeight':     visionHeight,
    'pixelX':           (normalizedX * 720).round().toDouble(),
    'pixelY':           (normalizedY * 1280).round().toDouble(),
    'pixelWidth':       (normalizedWidth * 720).round().toDouble(),
    'pixelHeight':      (normalizedHeight * 1280).round().toDouble(),
    'clamped':          clamped,
  };
}

void main() {
  // ── Group 1: Happy path ────────────────────────────────────────────────────

  group('VGImportedROISidecarBuilder — happy path', () {
    test('Single face produces valid sidecar with correct schema fields', () {
      final info = _makeMediaInfo();
      final face = _makeFace();
      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'test-session-abc',
        videoHash: 'sha256-abc123',
      );

      expect(sidecar, isNotNull);

      // ── ROI-5D contract: schema fields ────────────────────────────────────
      expect(sidecar!.version, equals(1));
      expect(sidecar.sourceType, equals('imported_gallery'));
      expect(sidecar.coordinateSpace, equals('display_source_normalized'));
      expect(sidecar.platform, equals('ios'));
      expect(sidecar.finalized, isTrue);

      // ── recordingSessionId ────────────────────────────────────────────────
      expect(sidecar.recordingSessionId, equals('test-session-abc'));

      // ── videoIdentity: display-oriented dimensions ─────────────────────────
      expect(sidecar.videoIdentity.width, equals(720));
      expect(sidecar.videoIdentity.height, equals(1280));
      expect(sidecar.videoIdentity.hash, equals('sha256-abc123'));
      expect(sidecar.videoIdentity.durationMs, equals(10000)); // 10.0s

      // ── Single sample ─────────────────────────────────────────────────────
      expect(sidecar.samples.length, equals(1));

      final sample = sidecar.samples.first;
      expect(sample.quality, equals('detected'));
      expect(sample.box, isNotNull);
      expect(sample.confidence, isNull); // Not provided by VNDetectFaceRectanglesRequest

      // ── Timing: mapped from actualTimeSeconds = 0.033s → 33ms ───────────
      expect(sample.timestampMs, equals(33));
      expect(sample.framePtsMs, equals(33));
      expect(sample.recordingRelativeMs, equals(33));

      // ── Box coordinates match the single face ─────────────────────────────
      expect(sample.box!.x, closeTo(0.2, 1e-9));
      expect(sample.box!.y, closeTo(0.15, 1e-9));
      expect(sample.box!.w, closeTo(0.3, 1e-9));
      expect(sample.box!.h, closeTo(0.4, 1e-9));
    });

    test('No faces produces sidecar with null box and quality=missing', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence(faces: []);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'test-no-face',
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.samples.length, equals(1));

      final sample = sidecar.samples.first;
      expect(sample.box, isNull);
      expect(sample.quality, equals('missing'));
    });

    test('Sidecar roundtrips JSON losslessly', () {
      final info = _makeMediaInfo();
      final face = _makeFace();
      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'roundtrip-session',
      )!;

      final json = sidecar.toJson();
      final rebuilt = VGROISidecar.fromJson(json);

      expect(rebuilt.version, equals(sidecar.version));
      expect(rebuilt.sourceType, equals('imported_gallery'));
      expect(rebuilt.coordinateSpace, equals('display_source_normalized'));
      expect(rebuilt.samples.length, equals(1));
      expect(rebuilt.samples.first.box, equals(sidecar.samples.first.box));
      expect(rebuilt.finalized, isTrue);
    });

    test('Auto-generated session ID is non-empty when not provided', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence();

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.recordingSessionId, isNotEmpty);
      // Must not look like a file path.
      expect(sidecar.recordingSessionId, isNot(contains('/')));
    });

    test('Platform defaults to ios', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence();

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'platform-test',
      );

      expect(sidecar!.platform, equals('ios'));
    });
  });

  // ── Group 2: Largest-face selection ───────────────────────────────────────

  group('VGImportedROISidecarBuilder — largest-face selection', () {
    test('Selects the largest face by normalized area', () {
      final info = _makeMediaInfo();

      // face0: small (0.1 × 0.1 = 0.01 area)
      final faceSmall = _makeFace(
        index: 0,
        normalizedX: 0.1,
        normalizedY: 0.1,
        normalizedWidth: 0.1,
        normalizedHeight: 0.1,
      );

      // face1: large (0.4 × 0.5 = 0.20 area) — should be selected
      final faceLarge = _makeFace(
        index: 1,
        normalizedX: 0.3,
        normalizedY: 0.2,
        normalizedWidth: 0.4,
        normalizedHeight: 0.5,
      );

      final evidence = _makeEvidence(faces: [faceSmall, faceLarge]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'largest-face-test',
      )!;

      final box = sidecar.samples.first.box!;
      expect(box.x, closeTo(0.3, 1e-9));
      expect(box.y, closeTo(0.2, 1e-9));
      expect(box.w, closeTo(0.4, 1e-9));
      expect(box.h, closeTo(0.5, 1e-9));
    });

    test('Selects largest among three faces', () {
      final info = _makeMediaInfo();

      final face0 = _makeFace(index: 0,
          normalizedX: 0.05, normalizedY: 0.05,
          normalizedWidth: 0.1, normalizedHeight: 0.1);       // area 0.01

      final face1 = _makeFace(index: 1,
          normalizedX: 0.2, normalizedY: 0.2,
          normalizedWidth: 0.2, normalizedHeight: 0.25);       // area 0.05

      final face2 = _makeFace(index: 2,
          normalizedX: 0.3, normalizedY: 0.1,
          normalizedWidth: 0.35, normalizedHeight: 0.45);      // area 0.1575 — largest

      final evidence = _makeEvidence(faces: [face0, face1, face2]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'three-faces-test',
      )!;

      final box = sidecar.samples.first.box!;
      expect(box.x, closeTo(0.3, 1e-9));
      expect(box.y, closeTo(0.1, 1e-9));
      expect(box.w, closeTo(0.35, 1e-9));
      expect(box.h, closeTo(0.45, 1e-9));
    });
  });

  // ── Group 3: Orientation gate ─────────────────────────────────────────────

  group('VGImportedROISidecarBuilder — orientation gate', () {
    for (final blockedStatus in ['validMirrored', 'ambiguous', 'noVideoTrack']) {
      test('Returns null for orientationStatus = "$blockedStatus"', () {
        final info = _makeMediaInfo(orientationStatus: blockedStatus);
        final evidence = _makeEvidence(faces: [_makeFace()]);

        final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
          mediaInfo: info,
          faceScanEvidence: evidence,
          recordingSessionId: 'blocked-orientation-test',
        );

        expect(sidecar, isNull,
            reason: 'orientationStatus "$blockedStatus" must block sidecar generation');
      });
    }

    test('Succeeds for orientationStatus = "valid"', () {
      final info = _makeMediaInfo(orientationStatus: 'valid');
      final evidence = _makeEvidence(faces: [_makeFace()]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'valid-orientation-test',
      );

      expect(sidecar, isNotNull);
    });
  });

  // ── Group 4: Frame dimension mismatch gate ───────────────────────────────

  group('VGImportedROISidecarBuilder — frame dimension gate', () {
    test('Returns null when frameWidth does not match displayWidth', () {
      final info = _makeMediaInfo(displayWidth: 720, displayHeight: 1280);
      final evidence = _makeEvidence(
        frameWidth: 1080, // mismatched
        frameHeight: 1280,
        faces: [_makeFace()],
      );

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'width-mismatch-test',
      );

      expect(sidecar, isNull);
    });

    test('Returns null when frameHeight does not match displayHeight', () {
      final info = _makeMediaInfo(displayWidth: 720, displayHeight: 1280);
      final evidence = _makeEvidence(
        frameWidth: 720,
        frameHeight: 1920, // mismatched
        faces: [_makeFace()],
      );

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'height-mismatch-test',
      );

      expect(sidecar, isNull);
    });

    test('Returns null when displayWidth is zero', () {
      final info = _makeMediaInfo(displayWidth: 0, displayHeight: 1280);
      final evidence = _makeEvidence(frameWidth: 0, frameHeight: 1280);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'zero-width-test',
      );

      expect(sidecar, isNull);
    });

    test('Returns null when displayHeight is zero', () {
      final info = _makeMediaInfo(displayWidth: 720, displayHeight: 0);
      final evidence = _makeEvidence(frameWidth: 720, frameHeight: 0);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'zero-height-test',
      );

      expect(sidecar, isNull);
    });
  });

  // ── Group 5: Missing required evidence keys ────────────────────────────────

  group('VGImportedROISidecarBuilder — missing evidence keys', () {
    test('Returns null when frameWidth is missing', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence();
      evidence.remove('frameWidth');

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'missing-fw-test',
      );

      expect(sidecar, isNull);
    });

    test('Returns null when frameHeight is missing', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence();
      evidence.remove('frameHeight');

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'missing-fh-test',
      );

      expect(sidecar, isNull);
    });

    test('Returns null when actualTimeSeconds is missing', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence();
      evidence.remove('actualTimeSeconds');

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'missing-time-test',
      );

      expect(sidecar, isNull);
    });
  });

  // ── Group 6: Float drift clamping ─────────────────────────────────────────

  group('VGImportedROISidecarBuilder — float drift clamping', () {
    test('Sub-epsilon overshoot on x+w is clamped and accepted', () {
      final info = _makeMediaInfo();

      // x=0.7, w=0.3: (x+w)=1.0 — exact, no overshoot
      // Simulate sub-epsilon drift: w is 1.0e-10 over 0.3 → x+w = 1.0 + 1e-10
      // After clamping w = min(0.3 + 1e-10, 1.0 - 0.7) = 0.3 → accepted.
      final face = _makeFace(
        normalizedX: 0.7,
        normalizedY: 0.1,
        normalizedWidth: 0.3 + 1e-10, // sub-epsilon overshoot
        normalizedHeight: 0.2,
      );

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'drift-clamp-test',
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNotNull);
    });

    test('Significant overshoot beyond 5% threshold produces null box', () {
      final info = _makeMediaInfo();

      // x=0.2, w=0.86 → x+w = 1.06, which is > 1.0 + 0.05 threshold → rejected.
      final face = _makeFace(
        normalizedX: 0.2,
        normalizedY: 0.1,
        normalizedWidth: 0.86,   // 1.06 total — strictly exceeds 5% threshold
        normalizedHeight: 0.2,
      );

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'rejection-test',
      );

      // Sidecar still built, but box must be null (wrong ROI worse than missing).
      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNull);
      expect(sidecar.samples.first.quality, equals('missing'));
    });

    test('Negative normalizedX beyond 5% threshold produces null box', () {
      final info = _makeMediaInfo();

      final face = _makeFace(
        normalizedX: -0.1,  // significantly out of bounds
        normalizedY: 0.1,
        normalizedWidth: 0.3,
        normalizedHeight: 0.4,
      );

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'negative-x-test',
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNull);
    });

    test('Face with NaN coordinate produces null box, not exception', () {
      final info = _makeMediaInfo();

      final face = <String, dynamic>{
        'index': 0,
        'normalizedX':      double.nan,
        'normalizedY':      0.1,
        'normalizedWidth':  0.3,
        'normalizedHeight': 0.4,
        'visionX': 0.0, 'visionY': 0.0, 'visionWidth': 0.3, 'visionHeight': 0.4,
        'clamped': false,
      };

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'nan-test',
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNull);
    });
  });

  // ── Group 7: Timing correctness ───────────────────────────────────────────

  group('VGImportedROISidecarBuilder — timing', () {
    test('actualTimeSeconds = 0.0 maps to timestampMs = 0', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence(actualTimeSeconds: 0.0, faces: [_makeFace()]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'timing-zero',
      )!;

      expect(sidecar.samples.first.timestampMs, equals(0));
      expect(sidecar.samples.first.framePtsMs, equals(0));
      expect(sidecar.samples.first.recordingRelativeMs, equals(0));
    });

    test('actualTimeSeconds = 0.033 maps to timestampMs = 33', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence(actualTimeSeconds: 0.033, faces: [_makeFace()]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'timing-33ms',
      )!;

      expect(sidecar.samples.first.timestampMs, equals(33));
    });

    test('actualTimeSeconds = 1.5 maps to timestampMs = 1500', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence(actualTimeSeconds: 1.5, faces: [_makeFace()]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'timing-1500ms',
      )!;

      expect(sidecar.samples.first.timestampMs, equals(1500));
    });

    test('Duration from MediaInfo.durationSeconds takes precedence', () {
      final info = _makeMediaInfo(durationSeconds: 15.5);
      final evidence = _makeEvidence(actualTimeSeconds: 0.033);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'duration-from-mediainfo',
      )!;

      expect(sidecar.videoIdentity.durationMs, equals(15500));
    });

    test('Duration falls back to actualTimeSeconds when durationSeconds <= 0', () {
      final info = _makeMediaInfo(durationSeconds: -1.0);
      final evidence = _makeEvidence(actualTimeSeconds: 2.5);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'duration-fallback',
      )!;

      // Fallback: 2.5s → 2500ms
      expect(sidecar.videoIdentity.durationMs, equals(2500));
    });
  });

  // ── Group 8: videoIdentity dimensions ────────────────────────────────────

  group('VGImportedROISidecarBuilder — videoIdentity dimensions', () {
    test('Landscape video: videoIdentity uses displayWidth > displayHeight', () {
      // Landscape: encoded 1920×1080 with 90° transform → display 1080×1920? No.
      // Landscape portrait: encoded 1280×720 no rotation.
      final info = _makeMediaInfo(
        encodedWidth: 1280, encodedHeight: 720,
        displayWidth: 1280, displayHeight: 720,
        rotationDegrees: 0,
      );
      final evidence = _makeEvidence(
        frameWidth: 1280, frameHeight: 720,
        faces: [_makeFace()],
      );

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'landscape-test',
      )!;

      expect(sidecar.videoIdentity.width, equals(1280));
      expect(sidecar.videoIdentity.height, equals(720));
    });

    test('Portrait video rotated 90°: videoIdentity uses swapped display dimensions', () {
      // Encoded 1080×1920, 90° rotation → display 1080×1920 after swap.
      // Actually 90° rotation: encoded 1920×1080 → display 1080×1920.
      final info = _makeMediaInfo(
        encodedWidth: 1920, encodedHeight: 1080,
        displayWidth: 1080, displayHeight: 1920,
        rotationDegrees: 90,
      );
      final evidence = _makeEvidence(
        frameWidth: 1080, frameHeight: 1920,
        faces: [_makeFace()],
      );

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'portrait-rotated-90-test',
      )!;

      // Must use display (not encoded) dimensions.
      expect(sidecar.videoIdentity.width, equals(1080));
      expect(sidecar.videoIdentity.height, equals(1920));
    });
  });

  // ── Group 9: Coverage metadata ────────────────────────────────────────────

  group('VGImportedROISidecarBuilder — coverage metadata', () {
    test('Coverage is 1.0 with no missing intervals', () {
      final info = _makeMediaInfo();
      final evidence = _makeEvidence(faces: [_makeFace()]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'coverage-test',
      )!;

      expect(sidecar.coverage.coveragePercent, equals(1.0));
      expect(sidecar.coverage.missingIntervals, isEmpty);
    });
  });

  // ── Group 10: Degenerate / edge boxes ────────────────────────────────────

  group('VGImportedROISidecarBuilder — degenerate box rejection', () {
    test('Face with zero normalizedWidth produces null box', () {
      final info = _makeMediaInfo();

      final face = _makeFace(
        normalizedX: 0.1,
        normalizedY: 0.1,
        normalizedWidth: 0.0,  // zero width — degenerate
        normalizedHeight: 0.3,
      );

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'zero-width-box',
      );

      // Sidecar still built, but box is null.
      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNull);
    });

    test('Face missing normalizedX key produces null box', () {
      final info = _makeMediaInfo();

      final face = <String, dynamic>{
        'index': 0,
        // normalizedX intentionally missing
        'normalizedY':      0.1,
        'normalizedWidth':  0.3,
        'normalizedHeight': 0.4,
        'clamped': false,
      };

      final evidence = _makeEvidence(faces: [face]);

      final sidecar = VGImportedROISidecarBuilder.buildSingleSample(
        mediaInfo: info,
        faceScanEvidence: evidence,
        recordingSessionId: 'missing-nx-test',
      );

      expect(sidecar, isNotNull);
      expect(sidecar!.samples.first.box, isNull);
    });
  });
}
