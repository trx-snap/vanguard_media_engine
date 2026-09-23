// Copyright 2026, Connects. All rights reserved.
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/vg_overlay_descriptor.dart';

VGDuetCompositionDescriptor _makeDescriptor({
  VGDuetLayoutMode mode = VGDuetLayoutMode.splitLeftRight,
  bool isSideSwapped = false,
  bool isTopBottomSwapped = false,
  VGDuetPiPAnchor? pipAnchor,
  VGDuetRect? pipNormalizedRect,
  VGDuetForegroundTransform? foregroundTransform,
  VGDuetGreenScreenBackground? greenScreenBackground,
  double initialSpeed = 1.0,
  double sourceAudioGain = 0.8,
  double micAudioGain = 0.6,
  bool sourceAudioMuted = false,
  bool micAudioMuted = false,
  List<VGDuetSegment>? segments,
  List<VGOverlayDescriptor>? overlays,
}) {
  return VGDuetCompositionDescriptor(
    source: VGDuetSource.localFile('/tmp/source.mp4'),
    layoutConfig: VGDuetLayoutConfig(
      mode: mode,
      isSideSwapped: isSideSwapped,
      isTopBottomSwapped: isTopBottomSwapped,
      pipAnchor: pipAnchor,
      pipNormalizedRect: pipNormalizedRect,
      foregroundTransform: foregroundTransform,
      greenScreenBackground: greenScreenBackground,
    ),
    trimWindow: VGDuetTrimWindow(startSeconds: 1.0, endSeconds: 10.0),
    initialSpeed: initialSpeed,
    segments: segments ?? [],
    sourceAudioGain: sourceAudioGain,
    micAudioGain: micAudioGain,
    sourceAudioMuted: sourceAudioMuted,
    micAudioMuted: micAudioMuted,
    overlays: overlays ?? const [],
  );
}

void main() {
  group('VGDuetCompositionDescriptor', () {
    // ── Instantiation ────────────────────────────────────────────────────────

    test('constructs with valid splitLeftRight layout', () {
      final d = _makeDescriptor();
      expect(d.layoutConfig.mode, VGDuetLayoutMode.splitLeftRight);
    });

    test('constructs with splitTopBottom layout', () {
      final d = _makeDescriptor(mode: VGDuetLayoutMode.splitTopBottom);
      expect(d.layoutConfig.mode, VGDuetLayoutMode.splitTopBottom);
    });

    test('constructs with greenScreen layout', () {
      final d = _makeDescriptor(mode: VGDuetLayoutMode.greenScreen);
      expect(d.layoutConfig.mode, VGDuetLayoutMode.greenScreen);
    });

    test('constructs with pip layout', () {
      final d = _makeDescriptor(
        mode: VGDuetLayoutMode.pip,
        pipAnchor: VGDuetPiPAnchor.topRight,
        pipNormalizedRect: const VGDuetRect(
          left: 0.63,
          top: 0.05,
          width: 0.35,
          height: 0.35,
        ),
      );
      expect(d.layoutConfig.mode, VGDuetLayoutMode.pip);
      expect(d.layoutConfig.pipAnchor, VGDuetPiPAnchor.topRight);
    });

    // ── Speed validation ─────────────────────────────────────────────────────

    test('accepts all valid speed values', () {
      for (final speed in [0.3, 0.5, 1.0, 2.0, 3.0]) {
        expect(() => _makeDescriptor(initialSpeed: speed), returnsNormally);
      }
    });

    test('throws ArgumentError for invalid speed', () {
      expect(() => _makeDescriptor(initialSpeed: 1.5), throwsArgumentError);
    });

    // ── Gain validation ──────────────────────────────────────────────────────

    test('throws ArgumentError for negative sourceAudioGain', () {
      expect(() => _makeDescriptor(sourceAudioGain: -0.1), throwsArgumentError);
    });

    test('throws ArgumentError for sourceAudioGain > 1.0', () {
      expect(() => _makeDescriptor(sourceAudioGain: 1.01), throwsArgumentError);
    });

    test('accepts boundary gains 0.0 and 1.0', () {
      expect(
        () => _makeDescriptor(sourceAudioGain: 0.0, micAudioGain: 1.0),
        returnsNormally,
      );
    });

    // ── Segments list preservation ───────────────────────────────────────────

    test('preserves segment ordering', () {
      final segs = List.generate(
        3,
        (i) => VGDuetSegment(
          segmentIndex: i,
          durationMs: 1000 * (i + 1),
          speedMultiplier: 1.0,
          sourceStartMs: 0,
          sourceEndMs: 1000,
          outputStartMs: 0,
          outputEndMs: 1000,
        ),
      );
      final d = _makeDescriptor(segments: segs);
      expect(d.segments.map((s) => s.segmentIndex).toList(), [0, 1, 2]);
    });

    // ── copyWith ─────────────────────────────────────────────────────────────

    test('copyWith overrides only named fields', () {
      final d = _makeDescriptor(initialSpeed: 1.0, sourceAudioGain: 0.8);
      final d2 = d.copyWith(initialSpeed: 2.0);
      expect(d2.initialSpeed, 2.0);
      expect(d2.sourceAudioGain, 0.8); // unchanged
    });

    test('copyWith returns new instance', () {
      final d = _makeDescriptor();
      final d2 = d.copyWith();
      expect(d2, equals(d));
      expect(identical(d, d2), isFalse);
    });

    // ── toMap / fromMap round-trip ───────────────────────────────────────────

    test('round-trip splitLeftRight', () {
      final d = _makeDescriptor(mode: VGDuetLayoutMode.splitLeftRight);
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored, equals(d));
    });

    test('round-trip splitTopBottom with swap', () {
      final d = _makeDescriptor(
        mode: VGDuetLayoutMode.splitTopBottom,
        isTopBottomSwapped: true,
      );
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored.layoutConfig.isTopBottomSwapped, isTrue);
    });

    test('round-trip pip with normalized rect', () {
      final d = _makeDescriptor(
        mode: VGDuetLayoutMode.pip,
        pipAnchor: VGDuetPiPAnchor.bottomLeft,
        pipNormalizedRect: const VGDuetRect(
          left: 0.02,
          top: 0.6,
          width: 0.35,
          height: 0.35,
        ),
      );
      final map = d.toMap();
      final restored = VGDuetCompositionDescriptor.fromMap(map);
      expect(restored.layoutConfig.pipAnchor, VGDuetPiPAnchor.bottomLeft);
      expect(
        restored.layoutConfig.pipNormalizedRect?.left,
        closeTo(0.02, 1e-10),
      );
    });

    test('round-trip greenScreen', () {
      final d = _makeDescriptor(mode: VGDuetLayoutMode.greenScreen);
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored.layoutConfig.mode, VGDuetLayoutMode.greenScreen);
    });

    test('round-trip with segments', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 2000,
        speedMultiplier: 0.5,
        sourceStartMs: 0,
        sourceEndMs: 4000,
        outputStartMs: 0,
        outputEndMs: 2000,
      );
      final d = _makeDescriptor(segments: [seg], initialSpeed: 0.5);
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored.segments.length, 1);
      expect(restored.segments.first.speedMultiplier, closeTo(0.5, 0.001));
    });

    test('round-trip preserves audio gains', () {
      final d = _makeDescriptor(sourceAudioGain: 0.7, micAudioGain: 0.4);
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored.sourceAudioGain, closeTo(0.7, 1e-10));
      expect(restored.micAudioGain, closeTo(0.4, 1e-10));
    });

    test('round-trip preserves mute flags', () {
      final d = _makeDescriptor(sourceAudioMuted: true, micAudioMuted: false);
      final restored = VGDuetCompositionDescriptor.fromMap(d.toMap());
      expect(restored.sourceAudioMuted, isTrue);
      expect(restored.micAudioMuted, isFalse);
    });

    // ── Value equality ───────────────────────────────────────────────────────

    test('equal descriptors have equal hashCodes', () {
      final a = _makeDescriptor();
      final b = _makeDescriptor();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('descriptors with different speeds are not equal', () {
      final a = _makeDescriptor(initialSpeed: 1.0);
      final b = _makeDescriptor(initialSpeed: 2.0);
      expect(a, isNot(equals(b)));
    });
  });

  group('VGDuetTrimWindow', () {
    test('valid window', () {
      final tw = VGDuetTrimWindow(startSeconds: 2.0, endSeconds: 10.0);
      expect(tw.durationSeconds, closeTo(8.0, 1e-10));
    });

    test('throws if duration < 1.0 s', () {
      expect(
        () => VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 0.5),
        throwsArgumentError,
      );
    });

    test('throws if endSeconds <= startSeconds', () {
      expect(
        () => VGDuetTrimWindow(startSeconds: 5.0, endSeconds: 5.0),
        throwsArgumentError,
      );
    });

    test('throws if startSeconds < 0', () {
      expect(
        () => VGDuetTrimWindow(startSeconds: -1.0, endSeconds: 5.0),
        throwsArgumentError,
      );
    });

    test('round-trip', () {
      final tw = VGDuetTrimWindow(startSeconds: 1.5, endSeconds: 8.5);
      final r = VGDuetTrimWindow.fromMap(tw.toMap());
      expect(r.startSeconds, closeTo(1.5, 1e-10));
      expect(r.endSeconds, closeTo(8.5, 1e-10));
    });
  });

  group('VGDuetSegment', () {
    test('valid segment', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 1500,
        speedMultiplier: 2.0,
        sourceStartMs: 0,
        sourceEndMs: 750,
        outputStartMs: 0,
        outputEndMs: 1500,
      );
      expect(seg.durationMs, 1500);
      expect(seg.speedMultiplier, closeTo(2.0, 0.001));
    });

    test('throws for invalid speed 1.5', () {
      expect(
        () => VGDuetSegment(
          segmentIndex: 0,
          durationMs: 1000,
          speedMultiplier: 1.5,
          sourceStartMs: 0,
          sourceEndMs: 1000,
          outputStartMs: 0,
          outputEndMs: 1000,
        ),
        throwsArgumentError,
      );
    });

    test('round-trip', () {
      final seg = VGDuetSegment(
        segmentIndex: 1,
        durationMs: 3000,
        speedMultiplier: 3.0,
        sourceStartMs: 500,
        sourceEndMs: 1500,
        outputStartMs: 1000,
        outputEndMs: 4000,
      );
      final r = VGDuetSegment.fromMap(seg.toMap());
      expect(r, equals(seg));
    });
  });

  // ── Fix 1: segments list immutability ─────────────────────────────────────

  group('VGDuetCompositionDescriptor segments immutability (Fix 1)', () {
    test(
      'mutating original list after construction does not affect descriptor',
      () {
        final mutable = <VGDuetSegment>[
          VGDuetSegment(
            segmentIndex: 0,
            durationMs: 1000,
            speedMultiplier: 1.0,
            sourceStartMs: 0,
            sourceEndMs: 1000,
            outputStartMs: 0,
            outputEndMs: 1000,
          ),
        ];
        final d = VGDuetCompositionDescriptor(
          source: VGDuetSource.localFile('/tmp/clip.mp4'),
          layoutConfig: VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.splitLeftRight,
          ),
          trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
          initialSpeed: 1.0,
          segments: mutable,
        );
        mutable.add(
          VGDuetSegment(
            segmentIndex: 1,
            durationMs: 2000,
            speedMultiplier: 1.0,
            sourceStartMs: 0,
            sourceEndMs: 2000,
            outputStartMs: 1000,
            outputEndMs: 3000,
          ),
        );
        // descriptor must still have only 1 segment
        expect(d.segments.length, 1);
      },
    );

    test('descriptor.segments.add throws UnsupportedError', () {
      final d = _makeDescriptor();
      expect(
        () => d.segments.add(
          VGDuetSegment(
            segmentIndex: 0,
            durationMs: 1000,
            speedMultiplier: 1.0,
            sourceStartMs: 0,
            sourceEndMs: 1000,
            outputStartMs: 0,
            outputEndMs: 1000,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  // ── Fix 4: VGDuetLayoutConfig PiP validation at construction ─────────────

  group('VGDuetLayoutConfig PiP validation at construction (Fix 4)', () {
    test(
      'throws ArgumentError for zero-width pipNormalizedRect in PiP mode',
      () {
        expect(
          () => VGDuetLayoutConfig(
            mode: VGDuetLayoutMode.pip,
            pipNormalizedRect: const VGDuetRect(
              left: 0.0,
              top: 0.0,
              width: 0.0,
              height: 0.3,
            ),
          ),
          throwsArgumentError,
        );
      },
    );

    test('throws for pipNormalizedRect.right > 1.0 in PiP mode', () {
      expect(
        () => VGDuetLayoutConfig(
          mode: VGDuetLayoutMode.pip,
          pipNormalizedRect: const VGDuetRect(
            left: 0.9,
            top: 0.0,
            width: 0.5,
            height: 0.3,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('throws for negative left in PiP mode', () {
      expect(
        () => VGDuetLayoutConfig(
          mode: VGDuetLayoutMode.pip,
          pipNormalizedRect: const VGDuetRect(
            left: -0.1,
            top: 0.0,
            width: 0.3,
            height: 0.3,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('does NOT throw for invalid rect when mode is NOT pip', () {
      // pipNormalizedRect validation is only for pip mode
      expect(
        () => VGDuetLayoutConfig(
          mode: VGDuetLayoutMode.splitLeftRight,
          pipNormalizedRect: const VGDuetRect(
            left: -1.0,
            top: -1.0,
            width: 0.0,
            height: 0.0,
          ),
        ),
        returnsNormally,
      );
    });

    test('valid PiP rect does not throw', () {
      expect(
        () => VGDuetLayoutConfig(
          mode: VGDuetLayoutMode.pip,
          pipAnchor: VGDuetPiPAnchor.topRight,
          pipNormalizedRect: const VGDuetRect(
            left: 0.63,
            top: 0.05,
            width: 0.35,
            height: 0.35,
          ),
        ),
        returnsNormally,
      );
    });

    test('fromMap throws on invalid PiP rect', () {
      final invalidMap = {
        'mode': 'pip',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
        'pipNormalizedRect': {
          'left': 0.9,
          'top': 0.0,
          'width': 0.5, // right = 1.4 > 1.0
          'height': 0.3,
        },
      };
      expect(
        () => VGDuetLayoutConfig.fromMap(Map<String, dynamic>.from(invalidMap)),
        throwsArgumentError,
      );
    });
  });

  // ── Fix 3: VGDuetCaptureResult typed compositionDescriptor + unmodifiable ─

  group('VGDuetCaptureResult (Fix 3)', () {
    VGDuetCompositionDescriptor cd() => _makeDescriptor();

    test('compositionDescriptor is typed VGDuetCompositionDescriptor', () {
      final result = VGDuetCaptureResult(
        compositionDescriptor: cd(),
        segmentAssets: ['/tmp/seg0.mp4'],
        totalDurationMs: 5000,
        segmentCount: 1,
      );
      // Compile-time and runtime type check
      expect(result.compositionDescriptor, isA<VGDuetCompositionDescriptor>());
    });

    test('segmentAssets is unmodifiable', () {
      final assets = ['/tmp/seg0.mp4'];
      final result = VGDuetCaptureResult(
        compositionDescriptor: cd(),
        segmentAssets: assets,
        totalDurationMs: 2000,
        segmentCount: 1,
      );
      expect(
        () => result.segmentAssets.add('/tmp/seg1.mp4'),
        throwsUnsupportedError,
      );
    });

    test(
      'mutating original assets list does not affect result.segmentAssets',
      () {
        final assets = ['/tmp/seg0.mp4'];
        final result = VGDuetCaptureResult(
          compositionDescriptor: cd(),
          segmentAssets: assets,
          totalDurationMs: 2000,
          segmentCount: 1,
        );
        assets.add('/tmp/seg1.mp4');
        expect(result.segmentAssets.length, 1);
      },
    );
  });

  // ── Fix 2: VGDuetLayoutConfig.fromMap handles Map<Object?,Object?> ─────────

  group('VGDuetLayoutConfig.fromMap nested Map types (Fix 2)', () {
    test('parses pipNormalizedRect from Map<Object?, Object?>', () {
      final map = <String, dynamic>{
        'mode': 'pip',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
        'pipAnchor': 'bottomLeft',
        // Simulate MethodChannel returning untyped Map
        'pipNormalizedRect': <Object?, Object?>{
          'left': 0.02,
          'top': 0.60,
          'width': 0.35,
          'height': 0.35,
        },
      };

      final cfg = VGDuetLayoutConfig.fromMap(map);
      expect(cfg.mode, VGDuetLayoutMode.pip);
      expect(cfg.pipNormalizedRect?.left, closeTo(0.02, 1e-10));
      expect(cfg.pipNormalizedRect?.width, closeTo(0.35, 1e-10));
      expect(cfg.pipAnchor, VGDuetPiPAnchor.bottomLeft);
    });
  });

  // ── Green-screen foregroundTransform contract ─────────────────────────────

  group('VGDuetLayoutConfig green-screen foregroundTransform', () {
    test(
      'greenScreen descriptor with creatorOverlay round-trips preserving scale, offset, anchor, and equality',
      () {
        final d = _makeDescriptor(
          mode: VGDuetLayoutMode.greenScreen,
          foregroundTransform: VGDuetForegroundTransform.creatorOverlay,
        );
        final map = d.toMap();
        final restored = VGDuetCompositionDescriptor.fromMap(map);

        expect(restored, equals(d));
        final ft = restored.layoutConfig.foregroundTransform;
        expect(ft, isNotNull);
        expect(ft!.scale, closeTo(0.62, 1e-10));
        expect(ft.offset, equals(const VGDuetPoint(0.0, 0.22)));
        expect(ft.anchor, equals(const VGDuetPoint(0.5, 0.5)));
        // creatorOverlay is visually unchanged: rotation defaults to 0.0.
        expect(ft.rotationDegrees, 0.0);
        expect(ft, equals(VGDuetForegroundTransform.creatorOverlay));
      },
    );

    test('identity transform has rotationDegrees 0.0 by default', () {
      expect(VGDuetForegroundTransform.identity.rotationDegrees, 0.0);
    });

    test('greenScreen descriptor with a non-zero rotationDegrees round-trips '
        'preserving scale, offset, anchor, rotation, and equality', () {
      const transform = VGDuetForegroundTransform(
        scale: 0.8,
        offset: VGDuetPoint(0.1, -0.2),
        anchor: VGDuetPoint(0.3, 0.7),
        rotationDegrees: 47.5,
      );
      final d = _makeDescriptor(
        mode: VGDuetLayoutMode.greenScreen,
        foregroundTransform: transform,
      );
      final map = d.toMap();
      final restored = VGDuetCompositionDescriptor.fromMap(map);

      expect(restored, equals(d));
      final ft = restored.layoutConfig.foregroundTransform;
      expect(ft, isNotNull);
      expect(ft!.rotationDegrees, closeTo(47.5, 1e-10));
      expect(ft, equals(transform));
    });

    test(
      'rotationDegrees accepts arbitrary clockwise values including negative '
      'and beyond-360 degrees, and toMap serializes the raw value',
      () {
        for (final degrees in [-450.0, -90.0, 0.0, 180.0, 359.9, 720.5]) {
          final transform = VGDuetForegroundTransform(
            scale: 1.0,
            offset: VGDuetPoint.zero,
            anchor: const VGDuetPoint(0.5, 0.5),
            rotationDegrees: degrees,
          );
          expect(transform.toMap()['rotationDegrees'], degrees);
          final restored = VGDuetForegroundTransform.fromMap(transform.toMap());
          expect(restored.rotationDegrees, closeTo(degrees, 1e-10));
        }
      },
    );

    test('a payload without a rotationDegrees key (pre-rotation contract) '
        'parses rotationDegrees as 0.0', () {
      final map = <String, dynamic>{
        'scale': 0.5,
        'offset': {'x': 0.1, 'y': 0.2},
        'anchor': {'x': 0.3, 'y': 0.4},
        // no 'rotationDegrees' key
      };
      final ft = VGDuetForegroundTransform.fromMap(map);
      expect(ft.rotationDegrees, 0.0);
      expect(ft.scale, closeTo(0.5, 1e-10));
    });

    test('missing, malformed, or non-finite rotationDegrees in fromMap '
        'degrades to 0.0 without throwing', () {
      final malformedValues = <dynamic>[
        null,
        'not_a_number',
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ];
      for (final rawRotation in malformedValues) {
        final map = <String, dynamic>{
          'scale': 0.5,
          'offset': {'x': 0.1, 'y': 0.2},
          'anchor': {'x': 0.3, 'y': 0.4},
          'rotationDegrees': rawRotation,
        };
        expect(() => VGDuetForegroundTransform.fromMap(map), returnsNormally);
        final ft = VGDuetForegroundTransform.fromMap(map);
        expect(
          ft.rotationDegrees,
          0.0,
          reason: 'rotationDegrees $rawRotation should degrade to 0.0',
        );
      }
    });

    test('invalid scale degrading to identity also resets rotationDegrees to '
        '0.0, ignoring any rotation present in the malformed payload', () {
      final map = <String, dynamic>{
        'scale': double.nan,
        'rotationDegrees': 123.0,
      };
      final ft = VGDuetForegroundTransform.fromMap(map);
      expect(ft, equals(VGDuetForegroundTransform.identity));
      expect(ft.rotationDegrees, 0.0);
    });

    test('wrong-type scale (e.g. a String, bool, Map, or List) does not throw '
        'and degrades to 1.0, matching the missing-scale contract', () {
      final wrongTypeScales = <dynamic>[
        'not_a_number',
        true,
        <String, dynamic>{},
        <dynamic>[],
      ];
      for (final rawScale in wrongTypeScales) {
        final map = <String, dynamic>{
          'scale': rawScale,
          'offset': {'x': 0.1, 'y': 0.2},
          'anchor': {'x': 0.3, 'y': 0.4},
        };
        expect(
          () => VGDuetForegroundTransform.fromMap(map),
          returnsNormally,
          reason: 'scale $rawScale should not throw',
        );
        final ft = VGDuetForegroundTransform.fromMap(map);
        // Wrong-type scale falls back to 1.0, which is finite and
        // positive, so it does not force full identity: offset/anchor
        // still parse from the rest of the payload.
        expect(ft.scale, 1.0, reason: 'scale $rawScale should default to 1.0');
        expect(ft.offset, equals(const VGDuetPoint(0.1, 0.2)));
        expect(ft.anchor, equals(const VGDuetPoint(0.3, 0.4)));
      }
    });

    test('a missing scale key defaults to 1.0 (finite and positive), not '
        'identity, when offset/anchor are otherwise present', () {
      final map = <String, dynamic>{
        'offset': {'x': 0.1, 'y': 0.2},
        'anchor': {'x': 0.3, 'y': 0.4},
      };
      final ft = VGDuetForegroundTransform.fromMap(map);
      expect(ft.scale, 1.0);
      expect(ft.offset, equals(const VGDuetPoint(0.1, 0.2)));
    });

    test('wrong-type offset/anchor x or y coordinates do not throw and '
        'degrade to the per-field default (offset -> 0.0, anchor -> 0.5)', () {
      final wrongTypeCoordinates = <dynamic>[
        'not_a_number',
        true,
        <String, dynamic>{},
        <dynamic>[1, 2],
        null,
      ];
      for (final rawCoord in wrongTypeCoordinates) {
        final map = <String, dynamic>{
          'scale': 0.75,
          'offset': {'x': rawCoord, 'y': rawCoord},
          'anchor': {'x': rawCoord, 'y': rawCoord},
        };
        expect(
          () => VGDuetForegroundTransform.fromMap(map),
          returnsNormally,
          reason: 'coordinate $rawCoord should not throw',
        );
        final ft = VGDuetForegroundTransform.fromMap(map);
        expect(ft.offset, equals(VGDuetPoint.zero));
        expect(ft.anchor, equals(const VGDuetPoint(0.5, 0.5)));
      }
    });

    test('equality, hashCode, and toString account for rotationDegrees', () {
      const a = VGDuetForegroundTransform(
        scale: 0.62,
        offset: VGDuetPoint(0.0, 0.22),
        anchor: VGDuetPoint(0.5, 0.5),
        rotationDegrees: 10.0,
      );
      const bSameRotation = VGDuetForegroundTransform(
        scale: 0.62,
        offset: VGDuetPoint(0.0, 0.22),
        anchor: VGDuetPoint(0.5, 0.5),
        rotationDegrees: 10.0,
      );
      const cDifferentRotation = VGDuetForegroundTransform(
        scale: 0.62,
        offset: VGDuetPoint(0.0, 0.22),
        anchor: VGDuetPoint(0.5, 0.5),
        rotationDegrees: 20.0,
      );

      expect(a, equals(bSameRotation));
      expect(a.hashCode, equals(bSameRotation.hashCode));
      expect(a, isNot(equals(cDifferentRotation)));
      expect(a.toString(), contains('rotationDegrees: 10.0'));
      expect(cDifferentRotation.toString(), contains('rotationDegrees: 20.0'));
    });

    test('normalizedRotationDegrees canonicalizes to [0, 360)', () {
      final cases = <double, double>{
        0.0: 0.0,
        90.0: 90.0,
        359.0: 359.0,
        360.0: 0.0,
        720.0: 0.0,
        -90.0: 270.0,
        -360.0: 0.0,
        450.0: 90.0,
      };
      cases.forEach((input, expected) {
        final ft = VGDuetForegroundTransform(
          scale: 1.0,
          offset: VGDuetPoint.zero,
          anchor: const VGDuetPoint(0.5, 0.5),
          rotationDegrees: input,
        );
        expect(
          ft.normalizedRotationDegrees,
          closeTo(expected, 1e-9),
          reason: 'input $input',
        );
      });
    });

    test(
      'greenScreen layout with no foregroundTransform leaves it null after round-trip and does not serialize the key',
      () {
        final d = _makeDescriptor(mode: VGDuetLayoutMode.greenScreen);
        expect(d.layoutConfig.foregroundTransform, isNull);

        final descriptorMap = d.toMap();
        final layoutConfigMap =
            descriptorMap['layoutConfig'] as Map<String, dynamic>;
        expect(layoutConfigMap.containsKey('foregroundTransform'), isFalse);

        final restored = VGDuetCompositionDescriptor.fromMap(descriptorMap);
        expect(restored.layoutConfig.foregroundTransform, isNull);

        final layoutMap = d.layoutConfig.toMap();
        expect(layoutMap.containsKey('foregroundTransform'), isFalse);
        final restoredLayout = VGDuetLayoutConfig.fromMap(layoutMap);
        expect(restoredLayout.foregroundTransform, isNull);
      },
    );

    test(
      'VGDuetLayoutConfig.fromMap with invalid/non-finite/non-positive scale in foregroundTransform does not throw and returns identity',
      () {
        final invalidScales = [
          0.0,
          -1.0,
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ];
        for (final scale in invalidScales) {
          final map = <String, dynamic>{
            'mode': 'greenScreen',
            'foregroundTransform': <String, dynamic>{
              'scale': scale,
              'offset': {'x': 0.1, 'y': 0.2},
              'anchor': {'x': 0.3, 'y': 0.4},
            },
          };

          expect(() => VGDuetLayoutConfig.fromMap(map), returnsNormally);
          final cfg = VGDuetLayoutConfig.fromMap(map);
          expect(
            cfg.foregroundTransform,
            equals(VGDuetForegroundTransform.identity),
            reason: 'Scale $scale should degrade to identity',
          );
        }
      },
    );

    test(
      'VGDuetLayoutConfig.fromMap with valid scale but malformed/missing/non-finite offset/anchor values does not throw and defaults defensively',
      () {
        final testCases = <Map<String, dynamic>>[
          // Missing offset and anchor maps
          {'scale': 0.75},
          // Malformed offset and anchor values (not Map)
          {'scale': 0.75, 'offset': 'invalid_offset', 'anchor': 12345},
          // Non-finite coordinates in offset and anchor
          {
            'scale': 0.75,
            'offset': {'x': double.nan, 'y': double.infinity},
            'anchor': {'x': double.negativeInfinity, 'y': double.nan},
          },
          // Empty coordinate maps
          {
            'scale': 0.75,
            'offset': <String, dynamic>{},
            'anchor': <String, dynamic>{},
          },
        ];

        for (final fgMap in testCases) {
          final map = <String, dynamic>{
            'mode': 'greenScreen',
            'foregroundTransform': fgMap,
          };

          expect(() => VGDuetLayoutConfig.fromMap(map), returnsNormally);
          final cfg = VGDuetLayoutConfig.fromMap(map);
          expect(cfg.foregroundTransform, isNotNull);
          expect(cfg.foregroundTransform!.scale, closeTo(0.75, 1e-10));
          expect(cfg.foregroundTransform!.offset, equals(VGDuetPoint.zero));
          expect(
            cfg.foregroundTransform!.anchor,
            equals(const VGDuetPoint(0.5, 0.5)),
          );
        }
      },
    );
  });

  // ── Green-screen greenScreenBackground contract ───────────────────────────

  group('VGDuetLayoutConfig green-screen greenScreenBackground', () {
    test(
      'greenScreen descriptor with solidColor background round-trips preserving type and color',
      () {
        final d = _makeDescriptor(
          mode: VGDuetLayoutMode.greenScreen,
          greenScreenBackground: const VGDuetGreenScreenBackground.solidColor(
            0xFF123456,
          ),
        );
        final map = d.toMap();
        final restored = VGDuetCompositionDescriptor.fromMap(map);

        expect(restored, equals(d));
        final bg = restored.layoutConfig.greenScreenBackground;
        expect(bg, isNotNull);
        expect(bg!.type, VGDuetGreenScreenBackgroundType.solidColor);
        expect(bg.argbColor, 0xFF123456);
        expect(bg.filePath, isNull);
        expect(bg.scaleMode, isNull);
        expect(
          bg,
          equals(const VGDuetGreenScreenBackground.solidColor(0xFF123456)),
        );
      },
    );

    test(
      'greenScreen descriptor with image background round-trips preserving type, path, and scaleMode',
      () {
        final d = _makeDescriptor(
          mode: VGDuetLayoutMode.greenScreen,
          greenScreenBackground: const VGDuetGreenScreenBackground.imageFile(
            '/path/to/bg.png',
            scaleMode: VGDuetBackgroundScaleMode.aspectFit,
          ),
        );
        final map = d.toMap();
        final restored = VGDuetCompositionDescriptor.fromMap(map);

        expect(restored, equals(d));
        final bg = restored.layoutConfig.greenScreenBackground;
        expect(bg, isNotNull);
        expect(bg!.type, VGDuetGreenScreenBackgroundType.image);
        expect(bg.filePath, '/path/to/bg.png');
        expect(bg.scaleMode, VGDuetBackgroundScaleMode.aspectFit);
        expect(bg.argbColor, isNull);
        expect(
          bg,
          equals(
            const VGDuetGreenScreenBackground.imageFile(
              '/path/to/bg.png',
              scaleMode: VGDuetBackgroundScaleMode.aspectFit,
            ),
          ),
        );
      },
    );

    test(
      'greenScreen descriptor with video background round-trips preserving type',
      () {
        final d = _makeDescriptor(
          mode: VGDuetLayoutMode.greenScreen,
          greenScreenBackground: const VGDuetGreenScreenBackground.video(),
        );
        final map = d.toMap();
        final restored = VGDuetCompositionDescriptor.fromMap(map);

        expect(restored, equals(d));
        final bg = restored.layoutConfig.greenScreenBackground;
        expect(bg, isNotNull);
        expect(bg!.type, VGDuetGreenScreenBackgroundType.video);
        expect(bg.argbColor, isNull);
        expect(bg.filePath, isNull);
        expect(bg.scaleMode, isNull);
        expect(bg, equals(const VGDuetGreenScreenBackground.video()));
      },
    );

    test(
      'greenScreen layout with no greenScreenBackground leaves it null after round-trip and does not serialize the key',
      () {
        final d = _makeDescriptor(mode: VGDuetLayoutMode.greenScreen);
        expect(d.layoutConfig.greenScreenBackground, isNull);

        final descriptorMap = d.toMap();
        final layoutConfigMap =
            descriptorMap['layoutConfig'] as Map<String, dynamic>;
        expect(layoutConfigMap.containsKey('greenScreenBackground'), isFalse);

        final restored = VGDuetCompositionDescriptor.fromMap(descriptorMap);
        expect(restored.layoutConfig.greenScreenBackground, isNull);

        final layoutMap = d.layoutConfig.toMap();
        expect(layoutMap.containsKey('greenScreenBackground'), isFalse);
        final restoredLayout = VGDuetLayoutConfig.fromMap(layoutMap);
        expect(restoredLayout.greenScreenBackground, isNull);
      },
    );
  });

  // ── Creator overlays (Slice 3) ───────────────────────────────────────────

  group('VGDuetCompositionDescriptor creator overlays (Slice 3)', () {
    final textOverlay = VGOverlayDescriptor(
      id: 'text-overlay-1',
      type: VGOverlayType.text,
      startTimeSeconds: 0.0,
      durationSeconds: 5.0,
      translationX: 100.0,
      translationY: 200.0,
      width: 320.0,
      height: 80.0,
      rotation: 0.0,
      scale: 1.0,
      opacity: 1.0,
      zIndex: 0,
      textContent: 'SLICE3',
    );

    final emojiOverlay = VGOverlayDescriptor(
      id: 'emoji-overlay-1',
      type: VGOverlayType.emoji,
      startTimeSeconds: 1.0,
      durationSeconds: 3.5,
      translationX: 150.0,
      translationY: 250.0,
      width: 100.0,
      height: 100.0,
      rotation: 0.5,
      scale: 1.2,
      opacity: 0.9,
      zIndex: 1,
      textContent: '🚀',
    );

    final stickerOverlay = VGOverlayDescriptor(
      id: 'sticker-overlay-1',
      type: VGOverlayType.sticker,
      startTimeSeconds: 0.5,
      durationSeconds: 4.0,
      translationX: 50.0,
      translationY: 50.0,
      width: 150.0,
      height: 150.0,
      rotation: -0.25,
      scale: 0.85,
      opacity: 0.95,
      zIndex: 2,
      assetPath: '/assets/stickers/star.png',
    );

    test(
      'descriptor with text/emoji/sticker creator overlays round-trips via toMap/fromMap',
      () {
        final d = _makeDescriptor(
          overlays: [textOverlay, emojiOverlay, stickerOverlay],
        );
        final map = d.toMap();
        final restored = VGDuetCompositionDescriptor.fromMap(map);

        expect(restored, equals(d));
        expect(restored.overlays.length, 3);
        expect(restored.overlays[0], equals(textOverlay));
        expect(restored.overlays[1], equals(emojiOverlay));
        expect(restored.overlays[2], equals(stickerOverlay));
      },
    );

    test(
      'creator overlays are included in toMap under descriptor["overlays"]',
      () {
        final d = _makeDescriptor(overlays: [textOverlay, stickerOverlay]);
        final map = d.toMap();
        expect(map.containsKey('overlays'), isTrue);
        final rawOverlays = map['overlays'] as List<dynamic>;
        expect(rawOverlays.length, 2);

        final textMap = rawOverlays[0] as Map<String, dynamic>;
        expect(textMap['id'], 'text-overlay-1');
        expect(textMap['type'], 'text');
        expect(textMap['textContent'], 'SLICE3');
        expect(textMap['startTimeSeconds'], 0.0);
        expect(textMap['durationSeconds'], 5.0);
        expect(textMap['translationX'], 100.0);
        expect(textMap['translationY'], 200.0);
        expect(textMap['width'], 320.0);
        expect(textMap['height'], 80.0);
        expect(textMap['rotation'], 0.0);
        expect(textMap['scale'], 1.0);
        expect(textMap['opacity'], 1.0);
        expect(textMap['zIndex'], 0);

        final stickerMap = rawOverlays[1] as Map<String, dynamic>;
        expect(stickerMap['id'], 'sticker-overlay-1');
        expect(stickerMap['type'], 'sticker');
        expect(stickerMap['assetPath'], '/assets/stickers/star.png');
        expect(stickerMap['zIndex'], 2);
      },
    );

    test('creator overlays participate in equality and hashCode', () {
      final a = _makeDescriptor(overlays: [textOverlay, emojiOverlay]);
      final bSame = _makeDescriptor(overlays: [textOverlay, emojiOverlay]);
      final cDifferent = _makeDescriptor(overlays: [textOverlay]);
      final dEmpty = _makeDescriptor(overlays: []);

      expect(a, equals(bSame));
      expect(a.hashCode, equals(bSame.hashCode));
      expect(a, isNot(equals(cDifferent)));
      expect(a, isNot(equals(dEmpty)));
    });

    test('copyWith overrides overlays field', () {
      final d = _makeDescriptor(overlays: [textOverlay]);
      final d2 = d.copyWith(overlays: [emojiOverlay, stickerOverlay]);
      expect(d2.overlays.length, 2);
      expect(d2.overlays[0], equals(emojiOverlay));
      expect(d2.overlays[1], equals(stickerOverlay));
      // original remains unchanged
      expect(d.overlays.length, 1);
      expect(d.overlays[0], equals(textOverlay));
    });

    test('overlays list is unmodifiable and defensively copied', () {
      final mutable = <VGOverlayDescriptor>[textOverlay];
      final d = VGDuetCompositionDescriptor(
        source: VGDuetSource.localFile('/tmp/source.mp4'),
        layoutConfig: VGDuetLayoutConfig(mode: VGDuetLayoutMode.splitLeftRight),
        trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0),
        initialSpeed: 1.0,
        segments: [],
        overlays: mutable,
      );
      // Mutating source list
      mutable.add(emojiOverlay);
      expect(d.overlays.length, 1);
      expect(d.overlays[0], equals(textOverlay));

      // Attempting to modify descriptor's list
      expect(() => d.overlays.add(stickerOverlay), throwsUnsupportedError);
    });

    test(
      'missing/null/wrong-type overlays in fromMap degrade defensively to empty list',
      () {
        final baseMap = _makeDescriptor().toMap();

        // missing overlays key
        final missingMap = Map<String, dynamic>.from(baseMap)
          ..remove('overlays');
        final restoredMissing = VGDuetCompositionDescriptor.fromMap(missingMap);
        expect(restoredMissing.overlays, isEmpty);

        // null overlays
        final nullMap = Map<String, dynamic>.from(baseMap)..['overlays'] = null;
        final restoredNull = VGDuetCompositionDescriptor.fromMap(nullMap);
        expect(restoredNull.overlays, isEmpty);

        // wrong-type string
        final stringMap = Map<String, dynamic>.from(baseMap)
          ..['overlays'] = 'not_a_list';
        final restoredString = VGDuetCompositionDescriptor.fromMap(stringMap);
        expect(restoredString.overlays, isEmpty);

        // wrong-type number
        final numMap = Map<String, dynamic>.from(baseMap)..['overlays'] = 42;
        final restoredNum = VGDuetCompositionDescriptor.fromMap(numMap);
        expect(restoredNum.overlays, isEmpty);
      },
    );

    test('malformed/non-map entries in overlays list are skipped silently', () {
      final baseMap = _makeDescriptor().toMap();
      final mixedList = [
        textOverlay.toMap(),
        'not_a_map',
        null,
        123,
        <dynamic>[],
        emojiOverlay.toMap(),
      ];
      final mixedMap = Map<String, dynamic>.from(baseMap)
        ..['overlays'] = mixedList;
      final restored = VGDuetCompositionDescriptor.fromMap(mixedMap);
      expect(restored.overlays.length, 2);
      expect(restored.overlays[0], equals(textOverlay));
      expect(restored.overlays[1], equals(emojiOverlay));
    });
  });
}
