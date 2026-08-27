// vg_editor_export_readiness_test.dart
// Vanguard Media Engine — Phase 5-Unit J Unit Tests

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const evaluator = VGEditorExportReadinessEvaluator();

  VGClipDescriptor makePlainVideoClip({
    String id = 'clip-1',
    String sourcePath = '/path/to/video.mp4',
    VGMediaKind mediaKind = VGMediaKind.video,
    double startTimeSeconds = 0.0,
    double durationSeconds = 10.0,
    double trimStartSeconds = 0.0,
    double trimEndSeconds = 10.0,
    double speed = 1.0,
    VGClipTransformDescriptor? transform,
    VGStillImageFitMode fitMode = VGStillImageFitMode.fit,
    List<double>? cropRect,
    double? freezePTS,
    bool isReversed = false,
    VGDualCameraDescriptor? dualCamera,
    VGTimeRemapDescriptor? timeRemap,
    VGTransformTrackDescriptor? transformTrack,
    List<double>? colorMatrix,
  }) {
    return VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: mediaKind,
      startTimeSeconds: startTimeSeconds,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      speed: speed,
      transform: transform,
      fitMode: fitMode,
      cropRect: cropRect,
      freezePTS: freezePTS,
      isReversed: isReversed,
      dualCamera: dualCamera,
      timeRemap: timeRemap,
      transformTrack: transformTrack,
      colorMatrix: colorMatrix,
    );
  }

  VGEditorDraft makeSingleClipDraft({
    VGClipDescriptor? clip,
    List<VGTransitionDescriptor> transitions = const [],
    List<VGOverlayDescriptor> overlays = const [],
    VGCanvasDescriptor? canvas,
    int canvasWidth = 1080,
    int canvasHeight = 1920,
    int fps = 30,
    VGAudioSidecarPlan? audioSidecarPlan,
  }) {
    return VGEditorDraft(
      id: 'draft-001',
      clips: [clip ?? makePlainVideoClip()],
      transitions: transitions,
      overlays: overlays,
      canvas: canvas,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      audioSidecarPlan: audioSidecarPlan,
    );
  }

  group('VGEditorExportReadinessEvaluator', () {
    test('single plain video draft evaluates as ready', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.ready);
      expect(report.isReady, isTrue);
      expect(report.isBlocked, isFalse);
      expect(report.canUseAndroidEditorExportRoute, isTrue);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['clipCount'], 1);
      expect(report.diagnostics['transitionCount'], 0);
      expect(report.diagnostics['overlayCount'], 0);
      expect(report.diagnostics['issueCount'], 0);
      expect(report.diagnostics['resolvedWidth'], 1080);
      expect(report.diagnostics['resolvedHeight'], 1920);
      expect(report.diagnostics['resolvedFps'], 30);
      expect(report.diagnostics['requestedBitrateBps'], isNull);
      expect(report.diagnostics['hasAudioSidecarPlan'], isFalse);
      expect(report.diagnostics['hasTemporalDenoiseRequest'], isFalse);
    });

    test('static evaluateDraft delegates identically', () {
      final draft = makeSingleClipDraft();
      final report = VGEditorExportReadinessEvaluator.evaluateDraft(
        draft: draft,
      );

      expect(report.decision, VGEditorExportReadinessDecision.ready);
      expect(report.canUseAndroidEditorExportRoute, isTrue);
      expect(report.issues, isEmpty);
    });

    test('plain multi-clip video draft evaluates as ready', () {
      final clip1 = makePlainVideoClip(id: 'clip-1');
      final clip2 = makePlainVideoClip(
        id: 'clip-2',
        sourcePath: '/path/to/video2.mp4',
        startTimeSeconds: 10.0,
      );
      final draft = VGEditorDraft(
        id: 'draft-multi',
        clips: [clip1, clip2],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 60,
      );

      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(bitrateBps: 6000000),
      );

      expect(report.decision, VGEditorExportReadinessDecision.ready);
      expect(report.isReady, isTrue);
      expect(report.canUseAndroidEditorExportRoute, isTrue);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['clipCount'], 2);
      expect(report.diagnostics['issueCount'], 0);
      expect(report.diagnostics['resolvedWidth'], 720);
      expect(report.diagnostics['resolvedHeight'], 1280);
      expect(report.diagnostics['resolvedFps'], 60);
      expect(report.diagnostics['requestedBitrateBps'], 6000000);
    });

    test('audio sidecar plan is allowed and reported in diagnostics', () {
      final plan = VGAudioSidecarPlan(
        tracks: const [
          VGAudioSidecarTrack(
            trackId: 'bgm-1',
            url: '/path/to/music.aac',
            startTime: 0.0,
            duration: 10.0,
          ),
        ],
      );
      final draft = makeSingleClipDraft(audioSidecarPlan: plan);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.ready);
      expect(report.canUseAndroidEditorExportRoute, isTrue);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['hasAudioSidecarPlan'], isTrue);
    });

    test('canvas contentMode other than fit blocks readiness', () {
      final fillCanvas = VGCanvasDescriptor(
        width: 1080,
        height: 1920,
        contentMode: VGCanvasContentMode.fill,
      );
      final draft = makeSingleClipDraft(canvas: fillCanvas);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code ==
            VGEditorExportReadinessIssueCode.unsupportedCanvasContentMode,
      );
      expect(issue.message, contains("contentMode 'fill' is not supported"));
    });

    test('odd draft canvas dimensions block readiness', () {
      final draft = makeSingleClipDraft(canvasWidth: 721, canvasHeight: 1280);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code == VGEditorExportReadinessIssueCode.invalidCanvasDimensions,
      );
      expect(issue.message, contains('721x1280'));
    });

    test('odd requested dimensions block readiness', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(width: 721, height: 1280),
      );

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code == VGEditorExportReadinessIssueCode.invalidRequestDimensions,
      );
      expect(issue.message, contains('721x1280'));
    });

    test('null request dimensions resolve to draft canvas dimensions', () {
      final draft = makeSingleClipDraft(canvasWidth: 1080, canvasHeight: 1920);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(),
      );

      expect(report.decision, VGEditorExportReadinessDecision.ready);
      expect(report.diagnostics['resolvedWidth'], 1080);
      expect(report.diagnostics['resolvedHeight'], 1920);
    });

    test('non-positive request fps blocks readiness', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(fps: 0),
      );

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.invalidFps,
      );
      expect(issue.message, contains('fps 0'));
    });

    test('non-positive request bitrate blocks readiness', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(bitrateBps: -1000),
      );

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.invalidBitrate,
      );
      expect(issue.message, contains('-1000'));
    });

    test('temporal denoise request blocks readiness', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(temporalDenoiseEnabled: true),
      );

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code ==
            VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
      );
      expect(issue.message, contains('temporalDenoiseEnabled=true'));
      expect(report.diagnostics['hasTemporalDenoiseRequest'], isTrue);
    });

    test('non-video media kind blocks readiness', () {
      final imageClip = makePlainVideoClip(
        id: 'clip-img',
        sourcePath: '/path/to/photo.jpg',
        mediaKind: VGMediaKind.image,
      );
      final draft = makeSingleClipDraft(clip: imageClip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.unsupportedMediaKind,
      );
      expect(issue.clipId, 'clip-img');
      expect(issue.message, contains('only video clips are supported'));
    });

    test('empty sourcePath blocks readiness with emptySourcePath', () {
      final emptyPathClip = makePlainVideoClip(
        id: 'clip-empty',
        sourcePath: '',
      );
      final draft = makeSingleClipDraft(clip: emptyPathClip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.emptySourcePath,
      );
      expect(issue.clipId, 'clip-empty');
    });

    test('non-local sourcePath blocks readiness with nonLocalSourcePath', () {
      final remoteClip = makePlainVideoClip(
        id: 'clip-remote',
        sourcePath: 'https://example.com/video.mp4',
      );
      final relativeClip = makePlainVideoClip(
        id: 'clip-rel',
        sourcePath: 'relative/path/video.mp4',
      );
      final draft = VGEditorDraft(
        id: 'draft-sources',
        clips: [remoteClip, relativeClip],
      );

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issues = report.issues
          .where(
            (i) =>
                i.code == VGEditorExportReadinessIssueCode.nonLocalSourcePath,
          )
          .toList();
      expect(issues.length, 2);
      expect(issues[0].clipId, 'clip-remote');
      expect(issues[1].clipId, 'clip-rel');
    });

    test(
      'invalid trim range (trimEnd <= trimStart) asserts in descriptor constructor in debug mode',
      () {
        expect(
          () => makePlainVideoClip(
            id: 'clip-bad-trim',
            trimStartSeconds: 5.0,
            trimEndSeconds: 5.0,
          ),
          throwsAssertionError,
        );
      },
    );

    test('unsupported speed blocks readiness with unsupportedSpeed', () {
      final speedClip = makePlainVideoClip(id: 'clip-speed', speed: 2.0);
      final draft = makeSingleClipDraft(clip: speedClip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.unsupportedSpeed,
      );
      expect(issue.clipId, 'clip-speed');
      expect(issue.message, contains('speed 2.0'));
    });

    test('reversed clip blocks readiness with reversedClipPresent', () {
      final revClip = makePlainVideoClip(id: 'clip-rev', isReversed: true);
      final draft = makeSingleClipDraft(clip: revClip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.reversedClipPresent,
      );
      expect(issue.clipId, 'clip-rev');
    });

    test(
      'clip spatial transform blocks readiness with clipTransformPresent',
      () {
        final clip = makePlainVideoClip(
          id: 'c-xform',
          transform: const VGClipTransformDescriptor(scaleX: 1.5, scaleY: 1.5),
        );
        final draft = makeSingleClipDraft(clip: clip);

        final report = evaluator.evaluate(draft: draft);

        expect(report.decision, VGEditorExportReadinessDecision.blocked);
        expect(report.canUseAndroidEditorExportRoute, isFalse);
        final issue = report.issues.firstWhere(
          (i) =>
              i.code == VGEditorExportReadinessIssueCode.clipTransformPresent,
        );
        expect(issue.clipId, 'c-xform');
      },
    );

    test(
      'still-image fit mode and cropRect block with stillImageFitOrCropPresent',
      () {
        final fillClip = makePlainVideoClip(
          id: 'c-fill',
          fitMode: VGStillImageFitMode.fill,
        );
        final cropClip = makePlainVideoClip(
          id: 'c-crop',
          cropRect: const [0.1, 0.1, 0.8, 0.8],
        );
        final draft = VGEditorDraft(
          id: 'draft-fit-crop',
          clips: [fillClip, cropClip],
        );

        final report = evaluator.evaluate(draft: draft);

        expect(report.decision, VGEditorExportReadinessDecision.blocked);
        final issues = report.issues
            .where(
              (i) =>
                  i.code ==
                  VGEditorExportReadinessIssueCode.stillImageFitOrCropPresent,
            )
            .toList();
        expect(issues.length, 2);
        expect(issues[0].clipId, 'c-fill');
        expect(issues[1].clipId, 'c-crop');
      },
    );

    test('freeze frame blocks readiness with freezeFramePresent', () {
      final clip = makePlainVideoClip(id: 'c-freeze', freezePTS: 2.5);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.freezeFramePresent,
      );
      expect(issue.clipId, 'c-freeze');
    });

    test('dual camera blocks readiness with dualCameraPresent', () {
      final primary = makePlainVideoClip(id: 'c-dual');
      final secondary = makePlainVideoClip(
        id: 'c-sec',
        sourcePath: '/path/to/sec.mp4',
      );
      final dualDesc = VGDualCameraDescriptor(
        primaryClip: primary,
        secondaryClip: secondary,
      );
      final clip = makePlainVideoClip(id: 'c-dual', dualCamera: dualDesc);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.dualCameraPresent,
      );
      expect(issue.clipId, 'c-dual');
    });

    test('time remap blocks readiness with timeRemapPresent', () {
      final remap = VGTimeRemapDescriptor(
        segments: const [
          VGSpeedSegmentDescriptor(
            sourceStartTime: 0.0,
            sourceDuration: 5.0,
            speedMultiplier: 2.0,
          ),
        ],
      );
      final clip = makePlainVideoClip(id: 'c-remap', timeRemap: remap);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.timeRemapPresent,
      );
      expect(issue.clipId, 'c-remap');
    });

    test('transform track blocks readiness with transformTrackPresent', () {
      final track = VGTransformTrackDescriptor(
        keyframes: const [
          VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 1.0, scaleY: 1.0),
        ],
      );
      final clip = makePlainVideoClip(id: 'c-track', transformTrack: track);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.transformTrackPresent,
      );
      expect(issue.clipId, 'c-track');
    });

    test('color matrix blocks readiness with colorMatrixPresent', () {
      final matrix = List<double>.filled(20, 0.0);
      final clip = makePlainVideoClip(id: 'c-matrix', colorMatrix: matrix);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorExportReadinessIssueCode.colorMatrixPresent,
      );
      expect(issue.clipId, 'c-matrix');
    });

    test('transitions and overlays block readiness', () {
      final clip1 = makePlainVideoClip(id: 'c1');
      final clip2 = makePlainVideoClip(
        id: 'c2',
        sourcePath: '/path/to/c2.mp4',
        startTimeSeconds: 10.0,
      );
      const transition = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'c1',
        toClipId: 'c2',
      );
      final overlay = VGOverlayDescriptor(
        id: 'ov-1',
        type: VGOverlayType.text,
        textContent: 'Sample Overlay',
        startTimeSeconds: 0.0,
        durationSeconds: 3.0,
      );
      final draft = VGEditorDraft(
        id: 'draft-tr-ov',
        clips: [clip1, clip2],
        transitions: [transition],
        overlays: [overlay],
      );

      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);
      expect(
        report.issues.any(
          (i) => i.code == VGEditorExportReadinessIssueCode.transitionsPresent,
        ),
        isTrue,
      );
      expect(
        report.issues.any(
          (i) => i.code == VGEditorExportReadinessIssueCode.overlaysPresent,
        ),
        isTrue,
      );
      expect(report.diagnostics['transitionCount'], 1);
      expect(report.diagnostics['overlayCount'], 1);
    });

    test('multiple issues are aggregated deterministically in order', () {
      final clip = makePlainVideoClip(
        id: 'c-multi',
        isReversed: true,
        freezePTS: 1.0,
        transform: const VGClipTransformDescriptor(scaleX: 2.0, scaleY: 2.0),
      );
      final overlay = VGOverlayDescriptor(
        id: 'ov-1',
        type: VGOverlayType.text,
        textContent: 'Text',
        startTimeSeconds: 0.0,
        durationSeconds: 2.0,
      );
      final draft = makeSingleClipDraft(
        clip: clip,
        overlays: [overlay],
        canvas: VGCanvasDescriptor(
          width: 1080,
          height: 1920,
          contentMode: VGCanvasContentMode.fill,
        ),
      );

      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(
          width: 721,
          temporalDenoiseEnabled: true,
        ),
      );

      expect(report.decision, VGEditorExportReadinessDecision.blocked);
      expect(report.canUseAndroidEditorExportRoute, isFalse);

      final codes = report.issues.map((i) => i.code).toList();
      expect(codes, [
        VGEditorExportReadinessIssueCode.overlaysPresent,
        VGEditorExportReadinessIssueCode.unsupportedCanvasContentMode,
        VGEditorExportReadinessIssueCode.reversedClipPresent,
        VGEditorExportReadinessIssueCode.clipTransformPresent,
        VGEditorExportReadinessIssueCode.freezeFramePresent,
        VGEditorExportReadinessIssueCode.invalidRequestDimensions,
        VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
      ]);
      expect(report.diagnostics['issueCount'], 7);
      expect(report.diagnostics['overlayCount'], 1);
      expect(report.diagnostics['clipCount'], 1);
      expect(report.diagnostics['hasTemporalDenoiseRequest'], isTrue);
    });

    test(
      'serialization, equality, and string representations work as expected',
      () {
        const issue = VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
          message: 'Temporal denoise not supported',
          clipId: null,
        );

        final issueMap = issue.toMap();
        expect(issueMap['code'], 'unsupportedTemporalDenoise');
        expect(issueMap['message'], 'Temporal denoise not supported');
        expect(issueMap.containsKey('clipId'), isFalse);
        expect(issue.toString(), contains('unsupportedTemporalDenoise'));

        const sameIssue = VGEditorExportReadinessIssue(
          code: VGEditorExportReadinessIssueCode.unsupportedTemporalDenoise,
          message: 'Temporal denoise not supported',
        );
        expect(issue, equals(sameIssue));
        expect(issue.hashCode, equals(sameIssue.hashCode));

        final report = VGEditorExportReadinessReport(
          decision: VGEditorExportReadinessDecision.blocked,
          issues: [issue],
          diagnostics: {'clipCount': 1, 'issueCount': 1},
        );

        final reportMap = report.toMap();
        expect(reportMap['decision'], 'blocked');
        expect(reportMap['canUseAndroidEditorExportRoute'], isFalse);
        expect((reportMap['issues'] as List).length, 1);
        expect(report.toString(), contains('decision: blocked'));

        final reportReady = VGEditorExportReadinessReport(
          decision: VGEditorExportReadinessDecision.ready,
          issues: const [],
          diagnostics: {'clipCount': 1, 'issueCount': 0},
        );
        expect(reportReady.canUseAndroidEditorExportRoute, isTrue);
      },
    );
  });
}
