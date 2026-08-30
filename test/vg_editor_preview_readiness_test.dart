// vg_editor_preview_readiness_test.dart
// Vanguard Media Engine — Phase 7.8P-Android Unit Tests

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const evaluator = VGEditorPreviewReadinessEvaluator();

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
    VGAudioSidecarPlan? audioSidecarPlan,
  }) {
    return VGEditorDraft(
      id: 'draft-001',
      clips: [clip ?? makePlainVideoClip()],
      transitions: transitions,
      overlays: overlays,
      audioSidecarPlan: audioSidecarPlan,
    );
  }

  group('VGEditorPreviewReadinessEvaluator', () {
    test('single plain video draft evaluates as ready', () {
      final draft = makeSingleClipDraft();
      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.ready);
      expect(report.isReady, isTrue);
      expect(report.isBlocked, isFalse);
      expect(report.canUseAndroidEditorPlaybackRoute, isTrue);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['clipCount'], 1);
      expect(report.diagnostics['transitionCount'], 0);
      expect(report.diagnostics['overlayCount'], 0);
      expect(report.diagnostics['issueCount'], 0);
      expect(report.diagnostics['hasAudioSidecarPlan'], isFalse);
    });

    test('static evaluateDraft delegates identically', () {
      final draft = makeSingleClipDraft();
      final report = VGEditorPreviewReadinessEvaluator.evaluateDraft(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.ready);
      expect(report.canUseAndroidEditorPlaybackRoute, isTrue);
      expect(report.issues, isEmpty);
    });

    test('plain multi-clip video draft evaluates as ready', () {
      final clip1 = makePlainVideoClip(id: 'clip-1');
      final clip2 = makePlainVideoClip(id: 'clip-2', startTimeSeconds: 10.0);
      final draft = VGEditorDraft(id: 'draft-multi', clips: [clip1, clip2]);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.ready);
      expect(report.isReady, isTrue);
      expect(report.isBlocked, isFalse);
      expect(report.canUseAndroidEditorPlaybackRoute, isTrue);
      expect(report.issues, isEmpty);
      expect(report.diagnostics['clipCount'], 2);
      expect(report.diagnostics['issueCount'], 0);
    });

    test(
      'non-video media kinds evaluate as blocked with unsupportedMediaKind',
      () {
        final imageClip = makePlainVideoClip(
          id: 'clip-img',
          sourcePath: '/path/to/photo.jpg',
          mediaKind: VGMediaKind.image,
        );
        final draft = makeSingleClipDraft(clip: imageClip);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
        final issue = report.issues.firstWhere(
          (i) =>
              i.code == VGEditorPreviewReadinessIssueCode.unsupportedMediaKind,
        );
        expect(issue.clipId, 'clip-img');
        expect(issue.message, contains('only video clips are supported'));
      },
    );

    test('transitions block readiness with transitionsPresent issue', () {
      final clip1 = makePlainVideoClip(id: 'c1');
      final clip2 = makePlainVideoClip(id: 'c2', startTimeSeconds: 10.0);
      const transition = VGTransitionDescriptor(
        id: 'tr-1',
        type: VGTransitionType.dissolve,
        durationSeconds: 1.0,
        fromClipId: 'c1',
        toClipId: 'c2',
      );
      final draft = VGEditorDraft(
        id: 'draft-tr',
        clips: [clip1, clip2],
        transitions: [transition],
      );

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      expect(
        report.issues.any(
          (i) => i.code == VGEditorPreviewReadinessIssueCode.transitionsPresent,
        ),
        isTrue,
      );
      expect(report.diagnostics['transitionCount'], 1);
    });

    test('overlays block readiness with overlaysPresent issue', () {
      final overlay = VGOverlayDescriptor(
        id: 'ov-1',
        type: VGOverlayType.text,
        textContent: 'Sample Title',
        startTimeSeconds: 1.0,
        durationSeconds: 3.0,
      );
      final draft = makeSingleClipDraft(overlays: [overlay]);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.overlaysPresent,
      );
      expect(issue.message, contains('1 overlay(s)'));
      expect(report.diagnostics['overlayCount'], 1);
    });

    test(
      'supported music audio sidecar plan is ready and does not emit audioSidecarPresent',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'bgm-1',
              url: '/path/to/music.aac',
              startTime: 0.0,
              duration: 10.0,
              role: 'music',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.ready);
        expect(report.canUseAndroidEditorPlaybackRoute, isTrue);
        expect(report.issues, isEmpty);
        expect(
          report.issues.any(
            (i) =>
                i.code == VGEditorPreviewReadinessIssueCode.audioSidecarPresent,
          ),
          isFalse,
        );
        expect(report.diagnostics['hasAudioSidecarPlan'], isTrue);
        expect(report.diagnostics['audioSidecarTrackCount'], 1);
        expect(report.diagnostics['audioSidecarAddedLaneCount'], 1);
      },
    );

    test(
      'valid sidecar with one music, one sfx, one voiceover, and one derived original track is ready',
      () {
        final clip = makePlainVideoClip(
          id: 'clip-1',
          sourcePath: '/path/to/video.mp4',
        );
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'music-1',
              url: '/path/to/music.aac',
              startTime: 0.0,
              duration: 5.0,
              role: 'music',
            ),
            VGAudioSidecarTrack(
              trackId: 'sfx-1',
              url: '/path/to/sfx.aac',
              startTime: 5.0,
              duration: 2.0,
              role: 'sfx',
            ),
            VGAudioSidecarTrack(
              trackId: 'voiceover-1',
              url: '/path/to/vo.aac',
              startTime: 0.0,
              duration: 10.0,
              role: 'voiceover',
            ),
            VGAudioSidecarTrack(
              trackId: 'original-clip-1',
              url: '/path/to/video.mp4',
              startTime: 0.0,
              duration: 10.0,
              role: 'original',
            ),
          ],
        );
        final draft = VGEditorDraft(
          id: 'draft-sidecar',
          clips: [clip],
          audioSidecarPlan: plan,
        );

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.ready);
        expect(report.issues, isEmpty);
        expect(report.diagnostics['audioSidecarTrackCount'], 4);
        expect(report.diagnostics['audioSidecarAddedLaneCount'], 2);
        expect(report.diagnostics['audioSidecarVoiceoverLaneCount'], 1);
        expect(report.diagnostics['audioSidecarOriginalTrackCount'], 1);
      },
    );

    test(
      'same-lane touching endpoints (music [0,2) and sfx [2,3)) are ready',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'music-1',
              url: '/path/to/music.aac',
              startTime: 0.0,
              duration: 2.0,
              role: 'music',
            ),
            VGAudioSidecarTrack(
              trackId: 'sfx-1',
              url: '/path/to/sfx.aac',
              startTime: 2.0,
              duration: 1.0,
              role: 'sfx',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.ready);
        expect(report.issues, isEmpty);
      },
    );

    test('cross-lane overlap between music/sfx and voiceover is ready', () {
      final plan = VGAudioSidecarPlan(
        tracks: const [
          VGAudioSidecarTrack(
            trackId: 'music-1',
            url: '/path/to/music.aac',
            startTime: 0.0,
            duration: 10.0,
            role: 'music',
          ),
          VGAudioSidecarTrack(
            trackId: 'voiceover-1',
            url: '/path/to/vo.aac',
            startTime: 1.0,
            duration: 3.0,
            role: 'voiceover',
          ),
        ],
      );
      final draft = makeSingleClipDraft(audioSidecarPlan: plan);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.ready);
      expect(report.issues, isEmpty);
    });

    test(
      'unsupported string audio sidecar role blocks readiness with unsupportedAudioSidecarRole',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'unknown-1',
              url: '/path/to/track.aac',
              startTime: 0.0,
              duration: 5.0,
              role: 'ambience',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode.unsupportedAudioSidecarRole,
          ),
          isTrue,
        );
      },
    );

    test(
      'null audio sidecar role blocks readiness with unsupportedAudioSidecarRole',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'unknown-2',
              url: '/path/to/track.aac',
              startTime: 0.0,
              duration: 5.0,
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode.unsupportedAudioSidecarRole,
          ),
          isTrue,
        );
      },
    );

    test(
      'more than 8 tracks in the added (music/sfx) lane blocks readiness with audioSidecarLaneCapacityExceeded',
      () {
        final tracks = List<VGAudioSidecarTrack>.generate(
          9,
          (i) => VGAudioSidecarTrack(
            trackId: 'music-$i',
            url: '/path/to/music-$i.aac',
            startTime: i * 1.0,
            duration: 1.0,
            role: 'music',
          ),
        );
        final plan = VGAudioSidecarPlan(tracks: tracks);
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode
                    .audioSidecarLaneCapacityExceeded,
          ),
          isTrue,
        );
      },
    );

    test(
      'more than 8 tracks in the voiceover lane blocks readiness with audioSidecarLaneCapacityExceeded',
      () {
        final tracks = List<VGAudioSidecarTrack>.generate(
          9,
          (i) => VGAudioSidecarTrack(
            trackId: 'voiceover-$i',
            url: '/path/to/voiceover-$i.aac',
            startTime: i * 1.0,
            duration: 1.0,
            role: 'voiceover',
          ),
        );
        final plan = VGAudioSidecarPlan(tracks: tracks);
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode
                    .audioSidecarLaneCapacityExceeded,
          ),
          isTrue,
        );
      },
    );

    test(
      'overlapping music/sfx same-lane tracks block readiness with audioSidecarLaneOverlap',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'music-1',
              url: '/path/to/music.aac',
              startTime: 0.0,
              duration: 5.0,
              role: 'music',
            ),
            VGAudioSidecarTrack(
              trackId: 'sfx-1',
              url: '/path/to/sfx.aac',
              startTime: 4.0,
              duration: 2.0,
              role: 'sfx',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode.audioSidecarLaneOverlap,
          ),
          isTrue,
        );
      },
    );

    test(
      'duplicate user-added track id across lanes blocks readiness with duplicateAudioSidecarTrackId',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'dup-1',
              url: '/path/to/music.aac',
              startTime: 0.0,
              duration: 5.0,
              role: 'music',
            ),
            VGAudioSidecarTrack(
              trackId: 'dup-1',
              url: '/path/to/vo.aac',
              startTime: 0.0,
              duration: 5.0,
              role: 'voiceover',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode.duplicateAudioSidecarTrackId,
          ),
          isTrue,
        );
      },
    );

    test(
      'original track URL not matching any clip sourcePath blocks readiness with invalidAudioSidecarTrack',
      () {
        final plan = VGAudioSidecarPlan(
          tracks: const [
            VGAudioSidecarTrack(
              trackId: 'original-clip-1',
              url: '/path/to/unrelated.mp4',
              startTime: 0.0,
              duration: 10.0,
              role: 'original',
            ),
          ],
        );
        final draft = makeSingleClipDraft(audioSidecarPlan: plan);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(
          report.issues.any(
            (i) =>
                i.code ==
                VGEditorPreviewReadinessIssueCode.invalidAudioSidecarTrack,
          ),
          isTrue,
        );
      },
    );

    test(
      'negative duration/start/fade/sourceTrimStart or non-finite numeric fields block readiness with invalidAudioSidecarTrack',
      () {
        final invalidTracks = <VGAudioSidecarTrack>[
          const VGAudioSidecarTrack(
            trackId: 'neg-duration',
            url: '/path/to/a.aac',
            startTime: 0.0,
            duration: -1.0,
            role: 'music',
          ),
          const VGAudioSidecarTrack(
            trackId: 'neg-start',
            url: '/path/to/b.aac',
            startTime: -1.0,
            duration: 2.0,
            role: 'music',
          ),
          const VGAudioSidecarTrack(
            trackId: 'neg-fade-in',
            url: '/path/to/c.aac',
            startTime: 0.0,
            duration: 2.0,
            role: 'music',
            fadeInSeconds: -0.5,
          ),
          const VGAudioSidecarTrack(
            trackId: 'neg-fade-out',
            url: '/path/to/d.aac',
            startTime: 0.0,
            duration: 2.0,
            role: 'music',
            fadeOutSeconds: -0.5,
          ),
          const VGAudioSidecarTrack(
            trackId: 'neg-trim',
            url: '/path/to/e.aac',
            startTime: 0.0,
            duration: 2.0,
            role: 'music',
            sourceTrimStartSeconds: -0.5,
          ),
          VGAudioSidecarTrack(
            trackId: 'nonfinite-duration',
            url: '/path/to/f.aac',
            startTime: 0.0,
            duration: double.nan,
            role: 'music',
          ),
        ];

        for (final track in invalidTracks) {
          final plan = VGAudioSidecarPlan(tracks: [track]);
          final draft = makeSingleClipDraft(audioSidecarPlan: plan);

          final report = evaluator.evaluate(draft);

          expect(
            report.decision,
            VGEditorPreviewReadinessDecision.blocked,
            reason: 'track "${track.trackId}" should block readiness',
          );
          expect(
            report.issues.any(
              (i) =>
                  i.code ==
                  VGEditorPreviewReadinessIssueCode.invalidAudioSidecarTrack,
            ),
            isTrue,
            reason:
                'track "${track.trackId}" should emit invalidAudioSidecarTrack',
          );
        }
      },
    );

    test(
      'volume keyframe unsupported curve or out-of-range volume blocks readiness with invalidAudioSidecarTrack',
      () {
        final unsupportedCurveTrack = VGAudioSidecarTrack(
          trackId: 'kf-curve',
          url: '/path/to/a.aac',
          startTime: 0.0,
          duration: 5.0,
          role: 'music',
          volumeKeyframes: const [
            VGAudioVolumeKeyframe(time: 0.0, volume: 0.5, curve: 'easeIn'),
          ],
        );
        final outOfRangeVolumeTrack = VGAudioSidecarTrack(
          trackId: 'kf-range',
          url: '/path/to/b.aac',
          startTime: 0.0,
          duration: 5.0,
          role: 'music',
          volumeKeyframes: const [
            VGAudioVolumeKeyframe(time: 0.0, volume: 1.5),
          ],
        );

        for (final track in [unsupportedCurveTrack, outOfRangeVolumeTrack]) {
          final plan = VGAudioSidecarPlan(tracks: [track]);
          final draft = makeSingleClipDraft(audioSidecarPlan: plan);

          final report = evaluator.evaluate(draft);

          expect(
            report.decision,
            VGEditorPreviewReadinessDecision.blocked,
            reason: 'track "${track.trackId}" should block readiness',
          );
          expect(
            report.issues.any(
              (i) =>
                  i.code ==
                  VGEditorPreviewReadinessIssueCode.invalidAudioSidecarTrack,
            ),
            isTrue,
            reason:
                'track "${track.trackId}" should emit invalidAudioSidecarTrack',
          );
        }
      },
    );

    test(
      'clip spatial transform blocks readiness with clipTransformPresent',
      () {
        final clip = makePlainVideoClip(
          id: 'c-xform',
          transform: const VGClipTransformDescriptor(scaleX: 1.5, scaleY: 1.5),
        );
        final draft = makeSingleClipDraft(clip: clip);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
        final issue = report.issues.firstWhere(
          (i) =>
              i.code == VGEditorPreviewReadinessIssueCode.clipTransformPresent,
        );
        expect(issue.clipId, 'c-xform');
      },
    );

    test(
      'still-image fill mode blocks readiness with stillImageFitOrCropPresent',
      () {
        final clip = makePlainVideoClip(
          id: 'c-fill',
          fitMode: VGStillImageFitMode.fill,
        );
        final draft = makeSingleClipDraft(clip: clip);

        final report = evaluator.evaluate(draft);

        expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
        expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
        final issue = report.issues.firstWhere(
          (i) =>
              i.code ==
              VGEditorPreviewReadinessIssueCode.stillImageFitOrCropPresent,
        );
        expect(issue.clipId, 'c-fill');
      },
    );

    test('crop rect blocks readiness with stillImageFitOrCropPresent', () {
      final clip = makePlainVideoClip(
        id: 'c-crop',
        cropRect: const [0.1, 0.1, 0.8, 0.8],
      );
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code ==
            VGEditorPreviewReadinessIssueCode.stillImageFitOrCropPresent,
      );
      expect(issue.clipId, 'c-crop');
    });

    test('freeze frame blocks readiness with freezeFramePresent', () {
      final clip = makePlainVideoClip(id: 'c-freeze', freezePTS: 2.5);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.freezeFramePresent,
      );
      expect(issue.clipId, 'c-freeze');
    });

    test('reversed clip blocks readiness with reversedClipPresent', () {
      final clip = makePlainVideoClip(id: 'c-rev', isReversed: true);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.reversedClipPresent,
      );
      expect(issue.clipId, 'c-rev');
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

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.dualCameraPresent,
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
          VGSpeedSegmentDescriptor(
            sourceStartTime: 5.0,
            sourceDuration: 5.0,
            speedMultiplier: 0.5,
          ),
        ],
      );
      final clip = makePlainVideoClip(id: 'c-remap', timeRemap: remap);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.timeRemapPresent,
      );
      expect(issue.clipId, 'c-remap');
    });

    test('transform track blocks readiness with transformTrackPresent', () {
      final track = VGTransformTrackDescriptor(
        keyframes: const [
          VGTransformKeyframeDescriptor(timeUs: 0, scaleX: 1.0, scaleY: 1.0),
          VGTransformKeyframeDescriptor(
            timeUs: 2000000,
            scaleX: 2.0,
            scaleY: 2.0,
          ),
        ],
      );
      final clip = makePlainVideoClip(id: 'c-track', transformTrack: track);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) =>
            i.code == VGEditorPreviewReadinessIssueCode.transformTrackPresent,
      );
      expect(issue.clipId, 'c-track');
    });

    test('color matrix blocks readiness with colorMatrixPresent', () {
      final matrix = List<double>.filled(20, 0.0);
      matrix[0] = 1.0;
      matrix[6] = 1.0;
      matrix[12] = 1.0;
      matrix[18] = 1.0;
      final clip = makePlainVideoClip(id: 'c-matrix', colorMatrix: matrix);
      final draft = makeSingleClipDraft(clip: clip);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      final issue = report.issues.firstWhere(
        (i) => i.code == VGEditorPreviewReadinessIssueCode.colorMatrixPresent,
      );
      expect(issue.clipId, 'c-matrix');
    });

    test('multiple issues are aggregated deterministically', () {
      final clip = makePlainVideoClip(
        id: 'c-multi-issue',
        isReversed: true,
        freezePTS: 1.0,
        transform: const VGClipTransformDescriptor(scaleX: 2.0, scaleY: 2.0),
      );
      final overlay = VGOverlayDescriptor(
        id: 'ov-1',
        type: VGOverlayType.text,
        textContent: 'Title',
        startTimeSeconds: 0.0,
        durationSeconds: 2.0,
      );
      final draft = makeSingleClipDraft(clip: clip, overlays: [overlay]);

      final report = evaluator.evaluate(draft);

      expect(report.decision, VGEditorPreviewReadinessDecision.blocked);
      expect(report.canUseAndroidEditorPlaybackRoute, isFalse);
      expect(report.issues.length, 4); // overlays, transform, freeze, reverse
      expect(report.diagnostics['issueCount'], 4);
      expect(report.diagnostics['overlayCount'], 1);
      expect(report.diagnostics['clipCount'], 1);
    });

    test(
      'serialization, equality, and string representations work as expected',
      () {
        const issue = VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.multiClipTimeline,
          message: 'Multiple clips blocked',
          clipId: 'clip-1',
        );

        final issueMap = issue.toMap();
        expect(issueMap['code'], 'multiClipTimeline');
        expect(issueMap['message'], 'Multiple clips blocked');
        expect(issueMap['clipId'], 'clip-1');
        expect(issue.toString(), contains('multiClipTimeline'));

        const sameIssue = VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.multiClipTimeline,
          message: 'Multiple clips blocked',
          clipId: 'clip-1',
        );
        expect(issue, equals(sameIssue));
        expect(issue.hashCode, equals(sameIssue.hashCode));

        const sidecarIssue = VGEditorPreviewReadinessIssue(
          code: VGEditorPreviewReadinessIssueCode.audioSidecarLaneOverlap,
          message: 'Overlapping sidecar tracks',
        );
        final sidecarIssueMap = sidecarIssue.toMap();
        expect(sidecarIssueMap['code'], 'audioSidecarLaneOverlap');
        expect(sidecarIssueMap.containsKey('clipId'), isFalse);
        expect(sidecarIssue.toString(), contains('audioSidecarLaneOverlap'));

        final report = VGEditorPreviewReadinessReport(
          decision: VGEditorPreviewReadinessDecision.blocked,
          issues: [issue],
          diagnostics: {'clipCount': 2, 'issueCount': 1},
        );

        final reportMap = report.toMap();
        expect(reportMap['decision'], 'blocked');
        expect(reportMap['canUseAndroidEditorPlaybackRoute'], isFalse);
        expect((reportMap['issues'] as List).length, 1);
        expect(report.toString(), contains('decision: blocked'));

        final reportReady = VGEditorPreviewReadinessReport(
          decision: VGEditorPreviewReadinessDecision.ready,
          issues: const [],
          diagnostics: {'clipCount': 1, 'issueCount': 0},
        );
        expect(reportReady.canUseAndroidEditorPlaybackRoute, isTrue);
      },
    );
  });
}
