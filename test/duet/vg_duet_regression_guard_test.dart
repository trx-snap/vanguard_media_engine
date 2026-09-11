// Copyright 2026, Connects. All rights reserved.
// Regression guard: verifies that existing public classes remain importable
// and unmodified after Duet Slice 1 changes.
//
// This test ONLY imports and references existing types; it does not test
// their behaviour (their own test suites do that).
import 'package:flutter_test/flutter_test.dart';

// Existing classes that must remain accessible.
import 'package:vanguard_media_engine/vg_camera_session.dart'
    show VGCameraSession;
import 'package:vanguard_media_engine/vg_playback_client.dart'
    show VGPlaybackClient;
import 'package:vanguard_media_engine/vg_playback_session.dart'
    show VGPlaybackSession;
import 'package:vanguard_media_engine/vg_editor_draft.dart' show VGEditorDraft;
import 'package:vanguard_media_engine/vg_clip_descriptor.dart'
    show VGClipDescriptor;
import 'package:vanguard_media_engine/vg_timeline_exporter.dart'
    show VanguardTimelineExporter;

// New Duet types that must be importable via the barrel.
import 'package:vanguard_media_engine/vg_duet.dart'
    show
        VGDuetSource,
        VGDuetCompositionDescriptor,
        VGDuetLayoutMode,
        VGDuetPiPAnchor,
        VGDuetLayoutConfig,
        VGDuetTrimWindow,
        VGDuetSegment,
        VGDuetCaptureResult,
        VGDuetLayoutMath,
        VGDuetEditorCompositionNode,
        VGDuetExportAdapter,
        VGDuetPlatformInterface,
        MethodChannelVGDuetPlatform,
        VGDuetException,
        VGDuetErrorCode,
        VGDuetForegroundTransform,
        VGDuetPoint;

void main() {
  group('Regression guard: existing public classes remain importable', () {
    test('VGCameraSession type is accessible', () {
      // We verify the type exists (not constructable without native setup).
      expect(VGCameraSession, isNotNull);
    });

    test('VGPlaybackClient type is accessible', () {
      expect(VGPlaybackClient, isNotNull);
    });

    test('VGPlaybackSession type is accessible', () {
      expect(VGPlaybackSession, isNotNull);
    });

    test('VGEditorDraft type is accessible', () {
      expect(VGEditorDraft, isNotNull);
    });

    test('VGClipDescriptor type is accessible', () {
      expect(VGClipDescriptor, isNotNull);
    });

    test('VanguardTimelineExporter type is accessible', () {
      expect(VanguardTimelineExporter, isNotNull);
    });
  });

  group('Regression guard: new Duet types are importable', () {
    test('VGDuetSource is accessible', () {
      expect(VGDuetSource, isNotNull);
    });

    test('VGDuetCompositionDescriptor is accessible', () {
      expect(VGDuetCompositionDescriptor, isNotNull);
    });

    test('VGDuetLayoutMode values are accessible', () {
      expect(VGDuetLayoutMode.values.length, 4);
      expect(VGDuetLayoutMode.pip, isNotNull);
      expect(VGDuetLayoutMode.splitLeftRight, isNotNull);
      expect(VGDuetLayoutMode.splitTopBottom, isNotNull);
      expect(VGDuetLayoutMode.greenScreen, isNotNull);
    });

    test('VGDuetPiPAnchor values are accessible', () {
      expect(VGDuetPiPAnchor.values.length, 4);
    });

    test('VGDuetLayoutConfig is accessible', () {
      final cfg = VGDuetLayoutConfig(mode: VGDuetLayoutMode.pip);
      expect(cfg.mode, VGDuetLayoutMode.pip);
    });

    test('VGDuetTrimWindow is accessible', () {
      final tw = VGDuetTrimWindow(startSeconds: 0.0, endSeconds: 5.0);
      expect(tw.durationSeconds, closeTo(5.0, 1e-10));
    });

    test('VGDuetSegment is accessible', () {
      final seg = VGDuetSegment(
        segmentIndex: 0,
        durationMs: 1000,
        speedMultiplier: 1.0,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        outputStartMs: 0,
        outputEndMs: 1000,
      );
      expect(seg.durationMs, 1000);
    });

    test('VGDuetLayoutMath is accessible', () {
      expect(VGDuetLayoutMath, isNotNull);
    });

    test('VGDuetEditorCompositionNode is accessible', () {
      expect(VGDuetEditorCompositionNode, isNotNull);
    });

    test('VGDuetExportAdapter is accessible', () {
      expect(VGDuetExportAdapter, isNotNull);
    });

    test('VGDuetPlatformInterface is accessible', () {
      expect(VGDuetPlatformInterface, isNotNull);
    });

    test('MethodChannelVGDuetPlatform is accessible', () {
      final p = MethodChannelVGDuetPlatform();
      expect(p, isA<VGDuetPlatformInterface>());
    });

    test('VGDuetException is accessible and has code', () {
      const ex = VGDuetException(
        code: VGDuetErrorCode.sourceInvalid,
        message: 'test',
      );
      expect(ex.code, VGDuetErrorCode.sourceInvalid);
    });

    test('VGDuetErrorCode has all required values', () {
      expect(VGDuetErrorCode.sourceInvalid, isNotNull);
      expect(VGDuetErrorCode.cameraUnavailable, isNotNull);
      expect(VGDuetErrorCode.segmentationFailed, isNotNull);
      expect(VGDuetErrorCode.compositionFailed, isNotNull);
      expect(VGDuetErrorCode.diskFull, isNotNull);
      expect(VGDuetErrorCode.unknown, isNotNull);
    });

    test('VGDuetCaptureResult is accessible', () {
      expect(VGDuetCaptureResult, isNotNull);
    });

    test('VGDuetForegroundTransform is accessible', () {
      const transform = VGDuetForegroundTransform.creatorOverlay;
      expect(transform.scale, 0.62);
      expect(transform.offset, const VGDuetPoint(0.0, 0.22));
    });
  });
}
