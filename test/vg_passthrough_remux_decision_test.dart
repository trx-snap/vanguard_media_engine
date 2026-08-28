// Copyright (c) Connects -- Vanguard Phase 2-Unit AB.
// Public Passthrough Remux Decision Planner & Composite Readiness Report Dart tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

VGClipDescriptor _makeClip({
  String id = 'clip-1',
  String sourcePath = '/data/user/0/cache/clip.mp4',
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

VGEditorDraft _makeDraft({
  String id = 'draft-1',
  List<VGClipDescriptor>? clips,
  List<VGTransitionDescriptor> transitions = const [],
  List<VGOverlayDescriptor> overlays = const [],
  int canvasWidth = 1080,
  int canvasHeight = 1920,
  int fps = 30,
  VGAudioSidecarPlan? audioSidecarPlan,
}) {
  return VGEditorDraft(
    id: id,
    clips: clips ?? [_makeClip()],
    transitions: transitions,
    overlays: overlays,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    fps: fps,
    audioSidecarPlan: audioSidecarPlan,
  );
}

VGPassthroughRemuxCapabilityReport _makeFakeCapabilityReport({
  bool canPassthroughRemux = true,
  String reason = 'supported',
  String sourcePath = '/data/user/0/cache/clip.mp4',
  bool fileExists = true,
  bool fileReadable = true,
  bool extractorOpened = true,
  int trackCount = 2,
  VGPassthroughRemuxTrackCapability? video =
      const VGPassthroughRemuxTrackCapability(
        trackIndex: 0,
        mime: 'video/avc',
        supported: true,
        reason: 'supported',
        width: 1080,
        height: 1920,
      ),
  VGPassthroughRemuxTrackCapability? audio =
      const VGPassthroughRemuxTrackCapability(
        trackIndex: 1,
        mime: 'audio/mp4a-latm',
        supported: true,
        reason: 'supported',
        channelCount: 2,
        sampleRate: 44100,
      ),
  String proofBoundary =
      'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
  Map<String, bool>? nonClaims,
  Map<String, Object?>? diagnostics,
}) {
  return VGPassthroughRemuxCapabilityReport(
    canPassthroughRemux: canPassthroughRemux,
    reason: reason,
    sourcePath: sourcePath,
    fileExists: fileExists,
    fileReadable: fileReadable,
    extractorOpened: extractorOpened,
    trackCount: trackCount,
    video: video,
    audio: audio,
    proofBoundary: proofBoundary,
    nonClaims:
        nonClaims ??
        const <String, bool>{
          'mediaMuxerStarted': false,
          'mediaCodecAllocated': false,
          'samplesRead': false,
          'outputFileWritten': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
    diagnostics: diagnostics ?? const <String, Object?>{},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('VGPassthroughRemuxDecisionReport', () {
    test('standard getters, proofBoundary, and nonClaims verify correctly', () {
      final draft = _makeDraft();
      final preflight = const VGPassthroughRemuxEvaluator().evaluate(
        draft: draft,
      );
      final cap = _makeFakeCapabilityReport();

      final report = VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: true,
        reason: 'ready',
        preflightReport: preflight,
        capabilityReport: cap,
        capabilityProbeAttempted: true,
      );

      expect(report.isReady, isTrue);
      expect(report.isBlocked, isFalse);
      expect(report.proofBoundaryMatches, isTrue);
      expect(
        report.proofBoundary,
        equals(
          'passthrough_remux_decision_planner_preflight_composite_advisory',
        ),
      );
      expect(report.diagnosticNonClaimsHold, isTrue);
      expect(report.capabilityProbeAttempted, isTrue);
      expect(report.capabilityReport, isNotNull);
      expect(report.preflightReport.isEligible, isTrue);

      final map = report.toMap();
      expect(map['canPassthroughRemux'], isTrue);
      expect(map['reason'], equals('ready'));
      expect(map['isReady'], isTrue);
      expect(map['isBlocked'], isFalse);
      expect(map['capabilityProbeAttempted'], isTrue);
      expect(
        map['proofBoundary'],
        equals(
          'passthrough_remux_decision_planner_preflight_composite_advisory',
        ),
      );
      expect(map['proofBoundaryMatches'], isTrue);
      expect(map['diagnosticNonClaimsHold'], isTrue);
      expect(map['preflightReport'], isA<Map<String, Object?>>());
      expect(map['capabilityReport'], isA<Map<String, Object?>>());
      expect(map['nonClaims'], isA<Map<String, bool>>());
      expect(
        report.toString(),
        contains('VGPassthroughRemuxDecisionReport(canPassthroughRemux: true'),
      );
    });

    test('diagnosticNonClaimsHold detects missing or true keys', () {
      final preflight = const VGPassthroughRemuxEvaluator().evaluate(
        draft: _makeDraft(),
      );

      // Mutated key set to true
      final violatedReport = VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: true,
        reason: 'ready',
        preflightReport: preflight,
        capabilityProbeAttempted: true,
        nonClaims: const <String, bool>{
          'mediaMuxerStarted': true,
          'mediaCodecAllocated': false,
          'samplesRead': false,
          'outputFileWritten': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
      );
      expect(violatedReport.diagnosticNonClaimsHold, isFalse);

      // Empty nonClaims
      final emptyReport = VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: true,
        reason: 'ready',
        preflightReport: preflight,
        capabilityProbeAttempted: true,
        nonClaims: const <String, bool>{},
      );
      expect(emptyReport.diagnosticNonClaimsHold, isFalse);

      // Missing a required key
      final missingKeyReport = VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: true,
        reason: 'ready',
        preflightReport: preflight,
        capabilityProbeAttempted: true,
        nonClaims: const <String, bool>{
          'mediaMuxerStarted': false,
          'mediaCodecAllocated': false,
          'samplesRead': false,
          'outputFileWritten': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          // 'connectAppTouched' missing
        },
      );
      expect(missingKeyReport.diagnosticNonClaimsHold, isFalse);
    });

    test('proofBoundaryMatches detects mismatch', () {
      final preflight = const VGPassthroughRemuxEvaluator().evaluate(
        draft: _makeDraft(),
      );
      final mismatched = VGPassthroughRemuxDecisionReport(
        canPassthroughRemux: true,
        reason: 'ready',
        preflightReport: preflight,
        capabilityProbeAttempted: true,
        proofBoundary: 'invalid_token',
      );
      expect(mismatched.proofBoundaryMatches, isFalse);
    });
  });

  group('VGPassthroughRemuxDecisionPlanner', () {
    test(
      '1. eligible Unit W + supported Unit AA capability => ready, attempted true, proofBoundaryMatches true, nonClaims hold',
      () async {
        var probeCalls = 0;
        String? probedPath;

        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            probeCalls++;
            probedPath = sourcePath;
            return _makeFakeCapabilityReport(sourcePath: sourcePath);
          },
        );

        final draft = _makeDraft();
        final report = await planner.evaluate(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/cache/out.mp4'),
        );

        expect(probeCalls, equals(1));
        expect(probedPath, equals('/data/user/0/cache/clip.mp4'));
        expect(report.canPassthroughRemux, isTrue);
        expect(report.isReady, isTrue);
        expect(report.isBlocked, isFalse);
        expect(report.reason, equals('ready'));
        expect(report.capabilityProbeAttempted, isTrue);
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(report.preflightReport.isEligible, isTrue);
        expect(report.capabilityReport, isNotNull);
        expect(report.capabilityReport!.canPassthroughRemux, isTrue);
        expect(report.diagnostics['sourcePath'], equals(probedPath));
      },
    );

    test(
      '2. multi-clip draft preflight ineligible => blocked, attempted false, probe not called, reason preflight_ineligible',
      () async {
        var probeCalls = 0;
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            probeCalls++;
            return _makeFakeCapabilityReport();
          },
        );

        final multiClipDraft = _makeDraft(
          clips: [
            _makeClip(id: 'c1', durationSeconds: 5.0, trimEndSeconds: 5.0),
            _makeClip(
              id: 'c2',
              startTimeSeconds: 5.0,
              durationSeconds: 5.0,
              trimEndSeconds: 5.0,
            ),
          ],
        );

        final report = await planner.evaluate(draft: multiClipDraft);

        expect(probeCalls, equals(0));
        expect(report.canPassthroughRemux, isFalse);
        expect(report.isReady, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.reason, equals('preflight_ineligible'));
        expect(report.capabilityProbeAttempted, isFalse);
        expect(report.capabilityReport, isNull);
        expect(report.preflightReport.isIneligible, isTrue);
        expect(
          report.preflightReport.issues.any(
            (i) => i.code == VGPassthroughRemuxIssueCode.multiClip,
          ),
          isTrue,
        );
      },
    );

    test(
      '2b. overlays or transitions present => blocked, attempted false, probe not called',
      () async {
        var probeCalls = 0;
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            probeCalls++;
            return _makeFakeCapabilityReport();
          },
        );

        final overlayDraft = _makeDraft(
          overlays: [
            VGOverlayDescriptor(
              id: 'ov1',
              startTimeSeconds: 0.0,
              durationSeconds: 5.0,
            ),
          ],
        );

        final report = await planner.evaluate(draft: overlayDraft);

        expect(probeCalls, equals(0));
        expect(report.canPassthroughRemux, isFalse);
        expect(report.reason, equals('preflight_ineligible'));
        expect(report.capabilityProbeAttempted, isFalse);
        expect(report.capabilityReport, isNull);
      },
    );

    test(
      '3. eligible preflight + missing/unsupported capability failure => blocked, attempted true, reason capability_ineligible',
      () async {
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            return VGPassthroughRemuxCapabilityReport.failure('file_not_found');
          },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.canPassthroughRemux, isFalse);
        expect(report.isReady, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.capabilityProbeAttempted, isTrue);
        expect(report.capabilityReport, isNotNull);
        expect(report.reason, contains('capability_ineligible:file_not_found'));
      },
    );

    test(
      '3b. eligible preflight + unsupported video mime => blocked, reason capability_ineligible:unsupported_video',
      () async {
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            return _makeFakeCapabilityReport(
              canPassthroughRemux: true,
              video: const VGPassthroughRemuxTrackCapability(
                trackIndex: 0,
                mime: 'video/x-unknown',
                supported: false,
                reason: 'unsupported_mime',
              ),
            );
          },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.canPassthroughRemux, isFalse);
        expect(report.capabilityProbeAttempted, isTrue);
        expect(report.reason, contains('capability_ineligible'));
      },
    );

    test(
      '4. eligible preflight + capability native proofBoundary mismatch => blocked',
      () async {
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            return _makeFakeCapabilityReport(
              proofBoundary: 'corrupted_or_unexpected_proof_token',
            );
          },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.canPassthroughRemux, isFalse);
        expect(report.isReady, isFalse);
        expect(report.capabilityProbeAttempted, isTrue);
        expect(
          report.reason,
          equals('capability_ineligible:proof_boundary_mismatch'),
        );
      },
    );

    test(
      '5. eligible preflight + capability nonClaims violation => blocked',
      () async {
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            return _makeFakeCapabilityReport(
              nonClaims: const <String, bool>{
                'mediaMuxerStarted': true, // Violated
                'mediaCodecAllocated': false,
                'samplesRead': false,
                'outputFileWritten': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
            );
          },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.canPassthroughRemux, isFalse);
        expect(report.isReady, isFalse);
        expect(report.capabilityProbeAttempted, isTrue);
        expect(
          report.reason,
          equals('capability_ineligible:non_claims_violation'),
        );
      },
    );

    test(
      '6. injected capabilityProbe throws => blocked, attempted true, reason capability_probe_exception',
      () async {
        final planner = VGPassthroughRemuxDecisionPlanner(
          capabilityProbe: (sourcePath) async {
            throw StateError('Simulated probe I/O failure');
          },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.canPassthroughRemux, isFalse);
        expect(report.isReady, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.capabilityProbeAttempted, isTrue);
        expect(report.capabilityReport, isNull);
        expect(
          report.reason,
          startsWith('capability_probe_exception:Bad state:'),
        );
        expect(report.diagnostics['error'], contains('Simulated probe I/O'));
      },
    );

    test('7. evaluateDraft static convenience executes identically', () async {
      var calls = 0;
      final report = await VGPassthroughRemuxDecisionPlanner.evaluateDraft(
        draft: _makeDraft(),
        capabilityProbe: (sourcePath) async {
          calls++;
          return _makeFakeCapabilityReport(sourcePath: sourcePath);
        },
      );

      expect(calls, equals(1));
      expect(report.canPassthroughRemux, isTrue);
      expect(report.isReady, isTrue);
      expect(report.reason, equals('ready'));
    });

    test('8. default probe uses MethodChannel and parses response', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        if (call.method == 'runAndroidPassthroughRemuxCapabilityProbeSmoke') {
          final args = call.arguments as Map<Object?, Object?>?;
          final sourcePath = args?['sourcePath']?.toString() ?? '';
          return <Object?, Object?>{
            'canPassthroughRemux': true,
            'reason': 'supported',
            'sourcePath': sourcePath,
            'fileExists': true,
            'fileReadable': true,
            'extractorOpened': true,
            'trackCount': 2,
            'video': <Object?, Object?>{
              'trackIndex': 0,
              'mime': 'video/avc',
              'supported': true,
              'reason': 'supported',
              'width': 1080,
              'height': 1920,
            },
            'audio': <Object?, Object?>{
              'trackIndex': 1,
              'mime': 'audio/mp4a-latm',
              'supported': true,
              'reason': 'supported',
              'channelCount': 2,
              'sampleRate': 48000,
            },
            'proofBoundary':
                'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
            'nonClaims': <Object?, Object?>{
              'mediaMuxerStarted': false,
              'mediaCodecAllocated': false,
              'samplesRead': false,
              'outputFileWritten': false,
              'productionExportTimelineBypass': false,
              'cppPassthroughRemuxSinkNode': false,
              'connectAppTouched': false,
            },
          };
        }
        return null;
      });

      const defaultPlanner = VGPassthroughRemuxDecisionPlanner();
      final report = await defaultPlanner.evaluate(draft: _makeDraft());

      expect(report.canPassthroughRemux, isTrue);
      expect(report.isReady, isTrue);
      expect(report.reason, equals('ready'));
      expect(report.capabilityProbeAttempted, isTrue);
      expect(report.capabilityReport, isNotNull);
      expect(report.capabilityReport!.extractorOpened, isTrue);
    });
  });
}
