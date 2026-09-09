// Copyright 2026, Connects. All rights reserved.
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_models.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_composition_descriptor.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_export_adapter.dart';

VGDuetCompositionDescriptor _descriptor({
  VGDuetLayoutMode mode = VGDuetLayoutMode.splitLeftRight,
  bool isSideSwapped = false,
  bool isTopBottomSwapped = false,
  VGDuetPiPAnchor? pipAnchor,
  VGDuetRect? pipNormalizedRect,
  double initialSpeed = 1.0,
  List<VGDuetSegment>? segments,
}) => VGDuetCompositionDescriptor(
  source: VGDuetSource.localFile('/tmp/source.mp4'),
  layoutConfig: VGDuetLayoutConfig(
    mode: mode,
    isSideSwapped: isSideSwapped,
    isTopBottomSwapped: isTopBottomSwapped,
    pipAnchor: pipAnchor,
    pipNormalizedRect: pipNormalizedRect,
  ),
  trimWindow: VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 10.0),
  initialSpeed: initialSpeed,
  segments: segments ?? [],
  sourceAudioGain: 0.8,
  micAudioGain: 0.6,
);

void main() {
  group('VGDuetExportAdapter.buildCompositionNode', () {
    test('preserves sourceVideoPath', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
      );
      expect(node.sourceVideoPath, '/tmp/source.mp4');
    });

    test('preserves layoutMode', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(mode: VGDuetLayoutMode.splitTopBottom),
      );
      expect(node.layoutMode, VGDuetLayoutMode.splitTopBottom);
    });

    test('preserves isSideSwapped', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(isSideSwapped: true),
      );
      expect(node.isSideSwapped, isTrue);
    });

    test('preserves isTopBottomSwapped', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(
          mode: VGDuetLayoutMode.splitTopBottom,
          isTopBottomSwapped: true,
        ),
      );
      expect(node.isTopBottomSwapped, isTrue);
    });

    test('preserves pipAnchor', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(
          mode: VGDuetLayoutMode.pip,
          pipAnchor: VGDuetPiPAnchor.bottomRight,
          pipNormalizedRect: const VGDuetRect(
            left: 0.63,
            top: 0.6,
            width: 0.35,
            height: 0.35,
          ),
        ),
      );
      expect(node.pipAnchor, VGDuetPiPAnchor.bottomRight);
    });

    test('preserves trim boundaries', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
      );
      expect(node.trimStartSeconds, closeTo(0.0, 1e-10));
      expect(node.trimEndSeconds, closeTo(10.0, 1e-10));
    });

    test('preserves audio gains', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
      );
      expect(node.sourceAudioGain, closeTo(0.8, 1e-10));
      expect(node.micAudioGain, closeTo(0.6, 1e-10));
    });

    test('preserves segmentAssets', () {
      final assets = ['/tmp/seg0.mp4', '/tmp/seg1.mp4'];
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
        segmentAssets: assets,
      );
      expect(node.segmentAssets, orderedEquals(assets));
    });

    test('empty segmentAssets when null passed', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
        segmentAssets: null,
      );
      expect(node.segmentAssets, isEmpty);
    });

    test('preserves segments', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 2000,
        speedMultiplier: 1.0,
        sourceStartMs: 0,
        sourceEndMs: 2000,
        outputStartMs: 0,
        outputEndMs: 2000,
      );
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(segments: [seg]),
      );
      expect(node.segments.length, 1);
      expect(node.segments.first.durationMs, 2000);
    });
  });

  group('VGDuetEditorCompositionNode.toMap / fromMap', () {
    test('round-trip splitLeftRight', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(mode: VGDuetLayoutMode.splitLeftRight),
        segmentAssets: ['/tmp/seg0.mp4'],
      );
      final map = node.toMap();
      final restored = VGDuetEditorCompositionNode.fromMap(map);
      expect(restored.layoutMode, VGDuetLayoutMode.splitLeftRight);
      expect(restored.sourceVideoPath, node.sourceVideoPath);
      expect(restored.trimStartSeconds, closeTo(node.trimStartSeconds, 1e-10));
      expect(restored.segmentAssets, orderedEquals(node.segmentAssets));
    });

    test('round-trip pip with normalized rect', () {
      const rect = VGDuetRect(left: 0.63, top: 0.05, width: 0.35, height: 0.35);
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(
          mode: VGDuetLayoutMode.pip,
          pipAnchor: VGDuetPiPAnchor.topRight,
          pipNormalizedRect: rect,
        ),
      );
      final restored = VGDuetEditorCompositionNode.fromMap(node.toMap());
      expect(restored.layoutMode, VGDuetLayoutMode.pip);
      expect(restored.pipAnchor, VGDuetPiPAnchor.topRight);
      expect(restored.pipNormalizedRect?.left, closeTo(0.63, 1e-10));
    });

    test('round-trip greenScreen', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(mode: VGDuetLayoutMode.greenScreen),
      );
      final restored = VGDuetEditorCompositionNode.fromMap(node.toMap());
      expect(restored.layoutMode, VGDuetLayoutMode.greenScreen);
    });

    test('toMap contains all required keys', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
      );
      final map = node.toMap();
      expect(map.containsKey('sourceVideoPath'), isTrue);
      expect(map.containsKey('layoutMode'), isTrue);
      expect(map.containsKey('trimStartSeconds'), isTrue);
      expect(map.containsKey('trimEndSeconds'), isTrue);
      expect(map.containsKey('segmentAssets'), isTrue);
      expect(map.containsKey('segments'), isTrue);
      expect(map.containsKey('sourceAudioGain'), isTrue);
      expect(map.containsKey('micAudioGain'), isTrue);
      expect(map.containsKey('sourceAudioMuted'), isTrue);
      expect(map.containsKey('micAudioMuted'), isTrue);
    });
  });

  group('VGDuetEditorCompositionNode validation at construction (Fix 2)', () {
    test('valid node constructs without throwing', () {
      expect(
        () =>
            VGDuetExportAdapter.buildCompositionNode(descriptor: _descriptor()),
        returnsNormally,
      );
    });

    test('throws ArgumentError at construction for sourceAudioGain > 1.0', () {
      expect(
        () => VGDuetEditorCompositionNode(
          sourceVideoPath: '/tmp/clip.mp4',
          layoutMode: VGDuetLayoutMode.splitLeftRight,
          isSideSwapped: false,
          isTopBottomSwapped: false,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.0,
          segmentAssets: [],
          segments: [],
          sourceAudioGain: 1.5, // invalid
          micAudioGain: 0.5,
          sourceAudioMuted: false,
          micAudioMuted: false,
        ),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError at construction for empty sourceVideoPath', () {
      expect(
        () => VGDuetEditorCompositionNode(
          sourceVideoPath: '',
          layoutMode: VGDuetLayoutMode.splitLeftRight,
          isSideSwapped: false,
          isTopBottomSwapped: false,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.0,
          segmentAssets: [],
          segments: [],
          sourceAudioGain: 1.0,
          micAudioGain: 1.0,
          sourceAudioMuted: false,
          micAudioMuted: false,
        ),
        throwsArgumentError,
      );
    });

    // ── Aliasing / unmodifiable ──────────────────────────────────────────────

    test('segmentAssets is unmodifiable after construction', () {
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
        segmentAssets: ['/tmp/seg0.mp4'],
      );
      expect(
        () => node.segmentAssets.add('/tmp/extra.mp4'),
        throwsUnsupportedError,
      );
    });

    test('segments is unmodifiable after construction', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 1000,
        speedMultiplier: 1.0,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        outputStartMs: 0,
        outputEndMs: 1000,
      );
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(segments: [seg]),
      );
      expect(() => node.segments.add(seg), throwsUnsupportedError);
    });

    test('mutating original segmentAssets list does not affect node', () {
      final assets = ['/tmp/seg0.mp4'];
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(),
        segmentAssets: assets,
      );
      assets.add('/tmp/seg1.mp4');
      expect(node.segmentAssets.length, 1);
    });

    test('mutating original segments list does not affect node', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 1000,
        speedMultiplier: 1.0,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        outputStartMs: 0,
        outputEndMs: 1000,
      );
      final mutableSegs = [seg];
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: _descriptor(segments: mutableSegs),
      );
      mutableSegs.add(seg);
      expect(node.segments.length, 1);
    });
  });

  group('VGDuetExportAdapter.toExportPayload', () {
    test('returns a map equivalent to buildCompositionNode().toMap()', () {
      final desc = _descriptor();
      final assets = ['/tmp/seg0.mp4'];
      final payload = VGDuetExportAdapter.toExportPayload(
        descriptor: desc,
        segmentAssets: assets,
      );
      final node = VGDuetExportAdapter.buildCompositionNode(
        descriptor: desc,
        segmentAssets: assets,
      );
      expect(payload, equals(node.toMap()));
    });
  });

  // ── Fix 2: fromMap handles Map<Object?, Object?> nested pip rect ──────────

  group('VGDuetEditorCompositionNode.fromMap nested Map types (Fix 2)', () {
    test('parses pipNormalizedRect from Map<Object?, Object?>', () {
      final map = <String, dynamic>{
        'sourceVideoPath': '/tmp/clip.mp4',
        'layoutMode': 'pip',
        'isSideSwapped': false,
        'isTopBottomSwapped': false,
        'pipAnchor': 'topRight',
        // Simulate MethodChannel returning Map<Object?, Object?>
        'pipNormalizedRect': <Object?, Object?>{
          'left': 0.63,
          'top': 0.05,
          'width': 0.35,
          'height': 0.35,
        },
        'trimStartSeconds': 0.0,
        'trimEndSeconds': 10.0,
        'segmentAssets': <Object?>[],
        'segments': <Object?>[],
        'sourceAudioGain': 1.0,
        'micAudioGain': 1.0,
        'sourceAudioMuted': false,
        'micAudioMuted': false,
      };

      final node = VGDuetEditorCompositionNode.fromMap(map);
      expect(node.pipNormalizedRect?.left, closeTo(0.63, 1e-10));
      expect(node.pipNormalizedRect?.width, closeTo(0.35, 1e-10));
      expect(node.layoutMode, VGDuetLayoutMode.pip);
    });
  });

  // ── Fix 3: PiP right > 1.0 throws at construction ────────────────────────

  group('VGDuetEditorCompositionNode PiP bounds validation (Fix 3)', () {
    test('throws when pipNormalizedRect.right > 1.0 at construction', () {
      expect(
        () => VGDuetEditorCompositionNode(
          sourceVideoPath: '/tmp/clip.mp4',
          layoutMode: VGDuetLayoutMode.pip,
          isSideSwapped: false,
          isTopBottomSwapped: false,
          pipNormalizedRect: const VGDuetRect(
            left: 0.9,
            top: 0.0,
            width: 0.5, // right = 1.4 > 1.0
            height: 0.3,
          ),
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          segmentAssets: [],
          segments: [],
          sourceAudioGain: 1.0,
          micAudioGain: 1.0,
          sourceAudioMuted: false,
          micAudioMuted: false,
        ),
        throwsArgumentError,
      );
    });

    test('throws when pipNormalizedRect.bottom > 1.0 at construction', () {
      expect(
        () => VGDuetEditorCompositionNode(
          sourceVideoPath: '/tmp/clip.mp4',
          layoutMode: VGDuetLayoutMode.pip,
          isSideSwapped: false,
          isTopBottomSwapped: false,
          pipNormalizedRect: const VGDuetRect(
            left: 0.0,
            top: 0.8,
            width: 0.3,
            height: 0.5, // bottom = 1.3 > 1.0
          ),
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          segmentAssets: [],
          segments: [],
          sourceAudioGain: 1.0,
          micAudioGain: 1.0,
          sourceAudioMuted: false,
          micAudioMuted: false,
        ),
        throwsArgumentError,
      );
    });
  });
}
