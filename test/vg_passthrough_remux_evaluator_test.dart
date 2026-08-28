// vg_passthrough_remux_evaluator_test.dart
// Vanguard Media Engine — Phase 2-Unit W Unit Tests

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const evaluator = VGPassthroughRemuxEvaluator();

  VGClipDescriptor makePlainVideoClip({
    String id = 'clip-1',
    String sourcePath = '/data/user/0/com.connects.vanguard/cache/clip1.mp4',
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

  VGEditorDraft makeDraft({
    List<VGClipDescriptor>? clips,
    VGClipDescriptor? singleClip,
    List<VGTransitionDescriptor> transitions = const [],
    List<VGOverlayDescriptor> overlays = const [],
    VGCanvasDescriptor? canvas,
    int canvasWidth = 1080,
    int canvasHeight = 1920,
    int fps = 30,
    VGAudioSidecarPlan? audioSidecarPlan,
  }) {
    return VGEditorDraft(
      id: 'draft-test',
      clips: clips ?? [singleClip ?? makePlainVideoClip()],
      transitions: transitions,
      overlays: overlays,
      canvas: canvas,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      fps: fps,
      audioSidecarPlan: audioSidecarPlan,
    );
  }

  group('VGPassthroughRemuxEvaluator', () {
    test('single unmodified video clip evaluates as eligible', () {
      final draft = makeDraft();
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.eligible);
      expect(report.isEligible, isTrue);
      expect(report.isIneligible, isFalse);
      expect(report.canUseAndroidPassthroughRemux, isTrue);
      expect(report.issues, isEmpty);
      expect(
        report.proofBoundary,
        VGPassthroughRemuxEvaluator.proofBoundaryToken,
      );
      expect(
        report.diagnostics['proofBoundary'],
        VGPassthroughRemuxEvaluator.proofBoundaryToken,
      );
      expect(report.diagnostics['clipCount'], 1);
      expect(report.diagnostics['transitionCount'], 0);
      expect(report.diagnostics['overlayCount'], 0);
      expect(report.diagnostics['issueCount'], 0);
      expect(report.diagnostics['resolvedWidth'], 1080);
      expect(report.diagnostics['resolvedHeight'], 1920);
      expect(report.diagnostics['resolvedFps'], 30);
      expect(report.diagnostics['requestHasOutputPath'], isFalse);
      expect(report.diagnostics['resolvedContainerFormat'], 'mp4_default');
      expect(report.diagnostics['hasAudioSidecarPlan'], isFalse);
      expect(report.diagnostics['hasTemporalDenoiseRequest'], isFalse);

      final nonClaims = report.diagnostics['nonClaims'] as Map<String, bool>;
      expect(nonClaims['nativeMuxExecuted'], isFalse);
      expect(nonClaims['mediaExtractorOpened'], isFalse);
      expect(nonClaims['mediaMuxerStarted'], isFalse);
      expect(nonClaims['sourceFileRead'], isFalse);
      expect(nonClaims['outputFileWritten'], isFalse);
      expect(nonClaims['codecAllocated'], isFalse);
    });

    test('static evaluateDraft delegates identically', () {
      final draft = makeDraft();
      final report = VGPassthroughRemuxEvaluator.evaluateDraft(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.eligible);
      expect(report.canUseAndroidPassthroughRemux, isTrue);
      expect(report.issues, isEmpty);
    });

    test('multi-clip draft is ineligible with multiClip issue', () {
      final clip1 = makePlainVideoClip(
        id: 'c1',
        durationSeconds: 5.0,
        trimEndSeconds: 5.0,
      );
      final clip2 = makePlainVideoClip(
        id: 'c2',
        sourcePath: '/data/user/0/com.connects.vanguard/cache/clip2.mp4',
        durationSeconds: 5.0,
        trimEndSeconds: 5.0,
      );
      final draft = makeDraft(clips: [clip1, clip2]);
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(report.canUseAndroidPassthroughRemux, isFalse);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.multiClip,
        ),
        isTrue,
      );
    });

    test('transitions present in draft causes ineligible', () {
      final clip1 = makePlainVideoClip(
        id: 'c1',
        durationSeconds: 5.0,
        trimEndSeconds: 5.0,
      );
      final clip2 = makePlainVideoClip(
        id: 'c2',
        sourcePath: '/data/c2.mp4',
        durationSeconds: 5.0,
        trimEndSeconds: 5.0,
      );
      final draft = makeDraft(
        clips: [clip1, clip2],
        transitions: const [
          VGTransitionDescriptor(
            id: 't1',
            type: VGTransitionType.dissolve,
            durationSeconds: 1.0,
            fromClipId: 'c1',
            toClipId: 'c2',
          ),
        ],
      );
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.transitionsPresent,
        ),
        isTrue,
      );
    });

    test('overlays present in draft causes ineligible', () {
      final draft = makeDraft(
        overlays: [
          VGOverlayDescriptor(
            id: 'ov-1',
            type: VGOverlayType.text,
            textContent: 'Title',
            startTimeSeconds: 0.0,
            durationSeconds: 2.0,
          ),
        ],
      );
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.overlaysPresent,
        ),
        isTrue,
      );
    });

    test(
      'canvas contentMode fill is ineligible while fit or null is eligible',
      () {
        final fillCanvas = VGCanvasDescriptor(
          width: 1080,
          height: 1920,
          contentMode: VGCanvasContentMode.fill,
        );
        final draftFill = makeDraft(canvas: fillCanvas);
        final reportFill = evaluator.evaluate(draft: draftFill);
        expect(reportFill.decision, VGPassthroughRemuxDecision.ineligible);
        expect(
          reportFill.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.unsupportedCanvasContentMode,
          ),
          isTrue,
        );

        final fitCanvas = VGCanvasDescriptor(
          width: 1080,
          height: 1920,
          contentMode: VGCanvasContentMode.fit,
        );
        final draftFit = makeDraft(canvas: fitCanvas);
        final reportFit = evaluator.evaluate(draft: draftFit);
        expect(reportFit.decision, VGPassthroughRemuxDecision.eligible);
      },
    );

    test('odd draft canvas dimensions block eligibility', () {
      final draft = makeDraft(canvasWidth: 1081, canvasHeight: 1920);
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.invalidCanvasDimensions,
        ),
        isTrue,
      );
    });

    test('non-positive request fps blocks eligibility', () {
      final draft = makeDraft(fps: 30);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(fps: 0),
      );

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.invalidFps,
        ),
        isTrue,
      );
    });

    test('request dimension override matching canvas is allowed', () {
      final draft = makeDraft(canvasWidth: 1080, canvasHeight: 1920);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(width: 1080, height: 1920),
      );

      expect(report.decision, VGPassthroughRemuxDecision.eligible);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['resolvedWidth'], 1080);
      expect(report.diagnostics['resolvedHeight'], 1920);
    });

    test('request dimension override differing from canvas is ineligible', () {
      final draft = makeDraft(canvasWidth: 1080, canvasHeight: 1920);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(width: 720, height: 1280),
      );

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) =>
              i.code ==
              VGPassthroughRemuxIssueCode.incompatibleOutputDimensions,
        ),
        isTrue,
      );
    });

    test('request fps override matching canvas is allowed', () {
      final draft = makeDraft(fps: 30);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(fps: 30),
      );

      expect(report.decision, VGPassthroughRemuxDecision.eligible);
      expect(report.issues, isEmpty);
    });

    test('request fps override differing from canvas is ineligible', () {
      final draft = makeDraft(fps: 30);
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(fps: 60),
      );

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.invalidFps,
        ),
        isTrue,
      );
    });

    test('request bitrate override is ineligible', () {
      final draft = makeDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(bitrateBps: 8000000),
      );

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) =>
              i.code == VGPassthroughRemuxIssueCode.unsupportedBitrateOverride,
        ),
        isTrue,
      );
    });

    test('request temporal denoise is ineligible', () {
      final draft = makeDraft();
      final report = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(temporalDenoiseEnabled: true),
      );

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) =>
              i.code == VGPassthroughRemuxIssueCode.unsupportedTemporalDenoise,
        ),
        isTrue,
      );
      expect(report.diagnostics['hasTemporalDenoiseRequest'], isTrue);
    });

    test('draft with audio sidecar plan is ineligible', () {
      final draft = makeDraft(
        audioSidecarPlan: VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'bgm-1',
              url: '/data/bgm.m4a',
              startTime: 0.0,
              duration: 10.0,
            ),
          ],
        ),
      );
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.audioSidecarPlanPresent,
        ),
        isTrue,
      );
      expect(report.diagnostics['hasAudioSidecarPlan'], isTrue);
    });

    test('non-video media kind is ineligible', () {
      final imageClip = makePlainVideoClip(
        id: 'img-1',
        sourcePath: '/data/image.jpg',
        mediaKind: VGMediaKind.image,
      );
      final draft = makeDraft(singleClip: imageClip);
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.unsupportedMediaKind,
        ),
        isTrue,
      );
    });

    test('empty or non-local source path is ineligible', () {
      final emptyClip = makePlainVideoClip(id: 'c-empty', sourcePath: '');
      final draftEmpty = makeDraft(singleClip: emptyClip);
      final reportEmpty = evaluator.evaluate(draft: draftEmpty);
      expect(
        reportEmpty.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.emptySourcePath,
        ),
        isTrue,
      );

      final remoteClip = makePlainVideoClip(
        id: 'c-remote',
        sourcePath: 'https://example.com/video.mp4',
      );
      final draftRemote = makeDraft(singleClip: remoteClip);
      final reportRemote = evaluator.evaluate(draft: draftRemote);
      expect(
        reportRemote.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.nonLocalSourcePath,
        ),
        isTrue,
      );

      final relClip = makePlainVideoClip(
        id: 'c-rel',
        sourcePath: 'relative/file.mp4',
      );
      final draftRel = makeDraft(singleClip: relClip);
      final reportRel = evaluator.evaluate(draft: draftRel);
      expect(
        reportRel.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.nonLocalSourcePath,
        ),
        isTrue,
      );
    });

    test(
      'trimmed clip (trimStart > 0 or trimEnd < duration) is ineligible',
      () {
        final trimmedStartClip = makePlainVideoClip(
          id: 'c-trim-start',
          durationSeconds: 10.0,
          trimStartSeconds: 1.0,
          trimEndSeconds: 10.0,
        );
        final draftStart = makeDraft(singleClip: trimmedStartClip);
        final reportStart = evaluator.evaluate(draft: draftStart);
        expect(
          reportStart.issues.any(
            (i) => i.code == VGPassthroughRemuxIssueCode.trimmedClip,
          ),
          isTrue,
        );

        final trimmedEndClip = makePlainVideoClip(
          id: 'c-trim-end',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 9.0,
        );
        final draftEnd = makeDraft(singleClip: trimmedEndClip);
        final reportEnd = evaluator.evaluate(draft: draftEnd);
        expect(
          reportEnd.issues.any(
            (i) => i.code == VGPassthroughRemuxIssueCode.trimmedClip,
          ),
          isTrue,
        );
      },
    );

    test('non-zero timeline start is ineligible', () {
      final offsetClip = makePlainVideoClip(
        id: 'c-offset',
        startTimeSeconds: 2.0,
      );
      final draft = makeDraft(singleClip: offsetClip);
      final report = evaluator.evaluate(draft: draft);

      expect(report.decision, VGPassthroughRemuxDecision.ineligible);
      expect(
        report.issues.any(
          (i) => i.code == VGPassthroughRemuxIssueCode.nonZeroTimelineStart,
        ),
        isTrue,
      );
    });

    test('per-clip modifications are all blocked', () {
      final speedClip = makePlainVideoClip(id: 'c-spd', speed: 1.5);
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: speedClip))
            .issues
            .any((i) => i.code == VGPassthroughRemuxIssueCode.unsupportedSpeed),
        isTrue,
      );

      final revClip = makePlainVideoClip(id: 'c-rev', isReversed: true);
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: revClip))
            .issues
            .any(
              (i) => i.code == VGPassthroughRemuxIssueCode.reversedClipPresent,
            ),
        isTrue,
      );

      final xformClip = makePlainVideoClip(
        id: 'c-xf',
        transform: const VGClipTransformDescriptor(scaleX: 1.1, scaleY: 1.1),
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: xformClip))
            .issues
            .any(
              (i) => i.code == VGPassthroughRemuxIssueCode.clipTransformPresent,
            ),
        isTrue,
      );

      final cropClip = makePlainVideoClip(
        id: 'c-crop',
        cropRect: const [0.1, 0.1, 0.8, 0.8],
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: cropClip))
            .issues
            .any(
              (i) =>
                  i.code ==
                  VGPassthroughRemuxIssueCode.stillImageFitOrCropPresent,
            ),
        isTrue,
      );

      final freezeClip = makePlainVideoClip(id: 'c-frz', freezePTS: 1.0);
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: freezeClip))
            .issues
            .any(
              (i) => i.code == VGPassthroughRemuxIssueCode.freezeFramePresent,
            ),
        isTrue,
      );

      final dualClip = makePlainVideoClip(
        id: 'c-dual',
        dualCamera: VGDualCameraDescriptor(
          primaryClip: makePlainVideoClip(id: 'pri'),
          secondaryClip: makePlainVideoClip(
            id: 'sec',
            sourcePath: '/data/sec.mp4',
          ),
        ),
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: dualClip))
            .issues
            .any(
              (i) => i.code == VGPassthroughRemuxIssueCode.dualCameraPresent,
            ),
        isTrue,
      );

      final remapClip = makePlainVideoClip(
        id: 'c-remap',
        timeRemap: VGTimeRemapDescriptor(
          segments: const [
            VGSpeedSegmentDescriptor(
              sourceStartTime: 0.0,
              sourceDuration: 5.0,
              speedMultiplier: 2.0,
            ),
          ],
        ),
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: remapClip))
            .issues
            .any((i) => i.code == VGPassthroughRemuxIssueCode.timeRemapPresent),
        isTrue,
      );

      final trackClip = makePlainVideoClip(
        id: 'c-trk',
        transformTrack: VGTransformTrackDescriptor(
          keyframes: const [
            VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 1.0, scaleY: 1.0),
          ],
        ),
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: trackClip))
            .issues
            .any(
              (i) =>
                  i.code == VGPassthroughRemuxIssueCode.transformTrackPresent,
            ),
        isTrue,
      );

      final matrixClip = makePlainVideoClip(
        id: 'c-mat',
        colorMatrix: List<double>.filled(20, 0.0),
      );
      expect(
        evaluator
            .evaluate(draft: makeDraft(singleClip: matrixClip))
            .issues
            .any(
              (i) => i.code == VGPassthroughRemuxIssueCode.colorMatrixPresent,
            ),
        isTrue,
      );
    });

    test('output extensions mp4 and m4v are allowed case-insensitively', () {
      final draft = makeDraft();

      final reportMp4Lower = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(outputPath: '/out/target.mp4'),
      );
      expect(reportMp4Lower.decision, VGPassthroughRemuxDecision.eligible);
      expect(reportMp4Lower.diagnostics['resolvedContainerFormat'], 'mp4');
      expect(reportMp4Lower.diagnostics['requestHasOutputPath'], isTrue);

      final reportMp4Upper = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(outputPath: '/out/target.MP4'),
      );
      expect(reportMp4Upper.decision, VGPassthroughRemuxDecision.eligible);
      expect(reportMp4Upper.diagnostics['resolvedContainerFormat'], 'mp4');

      final reportM4vLower = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(outputPath: '/out/target.m4v'),
      );
      expect(reportM4vLower.decision, VGPassthroughRemuxDecision.eligible);
      expect(reportM4vLower.diagnostics['resolvedContainerFormat'], 'm4v');

      final reportM4vUpper = evaluator.evaluate(
        draft: draft,
        request: const VGEditorExportRequest(outputPath: '/out/target.M4V'),
      );
      expect(reportM4vUpper.decision, VGPassthroughRemuxDecision.eligible);
      expect(reportM4vUpper.diagnostics['resolvedContainerFormat'], 'm4v');
    });

    test(
      'unsupported output extensions or missing extension are ineligible',
      () {
        final draft = makeDraft();

        final reportMov = evaluator.evaluate(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/out/target.mov'),
        );
        expect(reportMov.decision, VGPassthroughRemuxDecision.ineligible);
        expect(
          reportMov.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.incompatibleContainerFormat,
          ),
          isTrue,
        );
        expect(reportMov.diagnostics['resolvedContainerFormat'], 'unsupported');

        final reportNoExt = evaluator.evaluate(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/out/target_file'),
        );
        expect(reportNoExt.decision, VGPassthroughRemuxDecision.ineligible);
        expect(
          reportNoExt.issues.any(
            (i) =>
                i.code ==
                VGPassthroughRemuxIssueCode.incompatibleContainerFormat,
          ),
          isTrue,
        );
      },
    );

    test(
      'toMap, equality, and hash code work stably across issues and reports',
      () {
        const issue = VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.unsupportedBitrateOverride,
          message: 'Bitrate override is not supported',
          clipId: 'c1',
        );
        final issueMap = issue.toMap();
        expect(issueMap['code'], 'unsupportedBitrateOverride');
        expect(issueMap['message'], 'Bitrate override is not supported');
        expect(issueMap['clipId'], 'c1');
        expect(issue.toString(), contains('unsupportedBitrateOverride'));

        const issueSame = VGPassthroughRemuxIssue(
          code: VGPassthroughRemuxIssueCode.unsupportedBitrateOverride,
          message: 'Bitrate override is not supported',
          clipId: 'c1',
        );
        expect(issue, equals(issueSame));
        expect(issue.hashCode, equals(issueSame.hashCode));

        final report = VGPassthroughRemuxReport(
          decision: VGPassthroughRemuxDecision.ineligible,
          issues: [issue],
          diagnostics: {'clipCount': 1, 'proofBoundary': 'test_token'},
        );

        final reportMap = report.toMap();
        expect(reportMap['decision'], 'ineligible');
        expect(reportMap['isEligible'], isFalse);
        expect(reportMap['isIneligible'], isTrue);
        expect(reportMap['canUseAndroidPassthroughRemux'], isFalse);
        expect(reportMap['proofBoundary'], 'test_token');
        expect((reportMap['issues'] as List).length, 1);
        expect(report.toString(), contains('decision: ineligible'));
      },
    );
  });
}
