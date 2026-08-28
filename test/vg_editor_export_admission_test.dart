// Copyright (c) Connects -- Vanguard Phase 2-Unit AC.
// Public Export Route Admission Planner & Decision Adapter Dart tests.

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

VGPassthroughRemuxDecisionReport _makeFakePassthroughDecisionReport({
  bool canPassthroughRemux = true,
  String reason = 'ready',
  VGEditorDraft? draft,
  VGPassthroughRemuxCapabilityReport? capabilityReport,
  bool capabilityProbeAttempted = true,
  String proofBoundary = VGPassthroughRemuxDecisionReport.expectedProofBoundary,
  Map<String, bool>? nonClaims,
  Map<String, Object?>? diagnostics,
}) {
  final evaluatedDraft = draft ?? _makeDraft();
  final preflight = const VGPassthroughRemuxEvaluator().evaluate(
    draft: evaluatedDraft,
  );
  return VGPassthroughRemuxDecisionReport(
    canPassthroughRemux: canPassthroughRemux,
    reason: reason,
    preflightReport: preflight,
    capabilityReport: capabilityReport ?? _makeFakeCapabilityReport(),
    capabilityProbeAttempted: capabilityProbeAttempted,
    proofBoundary: proofBoundary,
    nonClaims: nonClaims ?? VGPassthroughRemuxDecisionReport.standardNonClaims,
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

  group('VGEditorExportAdmissionReport', () {
    test(
      'standard getters, proofBoundary, nonClaims, and toMap verify correctly',
      () {
        final draft = _makeDraft();
        final readiness = const VGEditorExportReadinessEvaluator().evaluate(
          draft: draft,
        );
        final passthrough = _makeFakePassthroughDecisionReport(draft: draft);

        final report = VGEditorExportAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          exportReadinessReport: readiness,
          passthroughDecisionReport: passthrough,
          passthroughDecisionAttempted: true,
        );

        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.reason, equals('passthrough_ready'));
        expect(report.usePassthroughRemux, isTrue);
        expect(report.useRenderExport, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
        expect(report.proofBoundaryMatches, isTrue);
        expect(
          report.proofBoundary,
          equals(
            'export_route_admission_planner_composite_advisory_no_exporttimeline_bypass',
          ),
        );
        expect(report.diagnosticNonClaimsHold, isTrue);

        final map = report.toMap();
        expect(map['routeMode'], equals('passthroughRemux'));
        expect(map['reason'], equals('passthrough_ready'));
        expect(map['usePassthroughRemux'], isTrue);
        expect(map['useRenderExport'], isFalse);
        expect(map['isBlocked'], isFalse);
        expect(map['passthroughDecisionAttempted'], isTrue);
        expect(
          map['proofBoundary'],
          equals(
            'export_route_admission_planner_composite_advisory_no_exporttimeline_bypass',
          ),
        );
        expect(map['proofBoundaryMatches'], isTrue);
        expect(map['diagnosticNonClaimsHold'], isTrue);
        expect(map['exportReadinessReport'], isA<Map<String, Object?>>());
        expect(map['passthroughDecisionReport'], isA<Map<String, Object?>>());
        expect(map['nonClaims'], isA<Map<String, bool>>());
        expect(
          report.toString(),
          contains('VGEditorExportAdmissionReport(routeMode: passthroughRemux'),
        );
      },
    );

    test(
      'diagnosticNonClaimsHold detects mutated true keys, missing keys, and empty map',
      () {
        final draft = _makeDraft();
        final readiness = const VGEditorExportReadinessEvaluator().evaluate(
          draft: draft,
        );

        // Mutated key set to true
        final violatedReport = VGEditorExportAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
          exportReadinessReport: readiness,
          passthroughDecisionAttempted: false,
          nonClaims: const <String, bool>{
            'productionExportTimelineBypass': true, // Violated
            'mediaMuxerStarted': false,
            'mediaCodecAllocated': false,
            'samplesRead': false,
            'outputFileWritten': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        );
        expect(violatedReport.diagnosticNonClaimsHold, isFalse);

        // Empty nonClaims
        final emptyReport = VGEditorExportAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
          exportReadinessReport: readiness,
          passthroughDecisionAttempted: false,
          nonClaims: const <String, bool>{},
        );
        expect(emptyReport.diagnosticNonClaimsHold, isFalse);

        // Missing a required key
        final missingKeyReport = VGEditorExportAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
          exportReadinessReport: readiness,
          passthroughDecisionAttempted: false,
          nonClaims: const <String, bool>{
            'productionExportTimelineBypass': false,
            'mediaMuxerStarted': false,
            'mediaCodecAllocated': false,
            'samplesRead': false,
            'outputFileWritten': false,
            'cppPassthroughRemuxSinkNode': false,
            // 'connectAppTouched' missing
          },
        );
        expect(missingKeyReport.diagnosticNonClaimsHold, isFalse);
      },
    );

    test('proofBoundaryMatches detects mismatch', () {
      final draft = _makeDraft();
      final readiness = const VGEditorExportReadinessEvaluator().evaluate(
        draft: draft,
      );

      final mismatched = VGEditorExportAdmissionReport(
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_ready',
        exportReadinessReport: readiness,
        passthroughDecisionAttempted: false,
        proofBoundary: 'invalid_proof_boundary_token',
      );
      expect(mismatched.proofBoundaryMatches, isFalse);
    });

    test('equality and hashCode verify correctly', () {
      final draft = _makeDraft();
      final readiness = const VGEditorExportReadinessEvaluator().evaluate(
        draft: draft,
      );

      final report1 = VGEditorExportAdmissionReport(
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_ready',
        exportReadinessReport: readiness,
        passthroughDecisionAttempted: false,
      );
      final report2 = VGEditorExportAdmissionReport(
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_ready',
        exportReadinessReport: readiness,
        passthroughDecisionAttempted: false,
      );

      expect(report1, equals(report2));
      expect(report1.hashCode, equals(report2.hashCode));
    });
  });

  group('VGEditorExportAdmissionPlanner', () {
    test(
      '1. passthrough ready: valid single clip + supported AB report -> passthroughRemux',
      () async {
        var probeCalls = 0;
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                probeCalls++;
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: true,
                  reason: 'ready',
                  draft: draft,
                );
              },
        );

        final draft = _makeDraft();
        final report = await planner.evaluate(
          draft: draft,
          request: const VGEditorExportRequest(
            outputPath: '/data/user/0/cache/out.mp4',
          ),
        );

        expect(probeCalls, equals(1));
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.reason, equals('passthrough_ready'));
        expect(report.usePassthroughRemux, isTrue);
        expect(report.useRenderExport, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(report.exportReadinessReport.isReady, isTrue);
      },
    );

    test(
      '2. multi-clip render fallback: plain multi-clip draft -> renderExport',
      () async {
        var probeCalls = 0;
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                probeCalls++;
                return const VGPassthroughRemuxDecisionPlanner().evaluate(
                  draft: draft,
                  request: request,
                );
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

        expect(probeCalls, equals(1));
        expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
        expect(report.reason, equals('render_export_ready'));
        expect(report.usePassthroughRemux, isFalse);
        expect(report.useRenderExport, isTrue);
        expect(report.isBlocked, isFalse);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
        expect(report.passthroughDecisionReport!.isBlocked, isTrue);
        expect(report.exportReadinessReport.isReady, isTrue);
      },
    );

    test(
      '3. Unit J blocked skips probe: transitions present -> blocked',
      () async {
        var probeCalls = 0;
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                probeCalls++;
                return _makeFakePassthroughDecisionReport(draft: draft);
              },
        );

        final transitionDraft = _makeDraft(
          transitions: [
            VGTransitionDescriptor(
              id: 't1',
              type: VGTransitionType.dissolve,
              durationSeconds: 1.0,
            ),
          ],
        );

        final report = await planner.evaluate(draft: transitionDraft);

        expect(probeCalls, equals(0));
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('export_blocked'));
        expect(report.usePassthroughRemux, isFalse);
        expect(report.useRenderExport, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.passthroughDecisionAttempted, isFalse);
        expect(report.passthroughDecisionReport, isNull);
        expect(report.exportReadinessReport.isBlocked, isTrue);
        expect(
          report.exportReadinessReport.issues.any(
            (i) =>
                i.code == VGEditorExportReadinessIssueCode.transitionsPresent,
          ),
          isTrue,
        );
      },
    );

    test(
      '3b. Unit J blocked skips probe: empty clips or speed != 1.0 -> blocked',
      () async {
        var probeCalls = 0;
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                probeCalls++;
                return _makeFakePassthroughDecisionReport(draft: draft);
              },
        );

        final speedDraft = _makeDraft(clips: [_makeClip(speed: 2.0)]);

        final report = await planner.evaluate(draft: speedDraft);

        expect(probeCalls, equals(0));
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('export_blocked'));
        expect(report.isBlocked, isTrue);
        expect(report.passthroughDecisionAttempted, isFalse);
        expect(report.passthroughDecisionReport, isNull);
      },
    );

    test(
      '4. missing/unreadable capability blocks: fileExists == false -> blocked source_unavailable',
      () async {
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: false,
                  reason: 'capability_ineligible:file_not_found',
                  draft: draft,
                  capabilityReport: _makeFakeCapabilityReport(
                    canPassthroughRemux: false,
                    fileExists: false,
                    fileReadable: false,
                    reason: 'file_not_found',
                  ),
                );
              },
        );

        final draft = _makeDraft(
          clips: [_makeClip(sourcePath: '/missing/clip.mp4')],
        );

        final report = await planner.evaluate(draft: draft);

        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('export_blocked:source_unavailable'));
        expect(report.isBlocked, isTrue);
        expect(report.usePassthroughRemux, isFalse);
        expect(report.useRenderExport, isFalse);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
        expect(
          report.passthroughDecisionReport!.capabilityReport!.fileExists,
          isFalse,
        );
      },
    );

    test(
      '4b. missing/unreadable capability blocks: fileReadable == false -> blocked source_unavailable',
      () async {
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: false,
                  reason: 'capability_ineligible:file_unreadable',
                  draft: draft,
                  capabilityReport: _makeFakeCapabilityReport(
                    canPassthroughRemux: false,
                    fileExists: true,
                    fileReadable: false,
                    reason: 'file_unreadable',
                  ),
                );
              },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('export_blocked:source_unavailable'));
        expect(report.isBlocked, isTrue);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
        expect(
          report.passthroughDecisionReport!.capabilityReport!.fileReadable,
          isFalse,
        );
      },
    );

    test(
      '5. unsupported-but-readable capability render fallback -> renderExport',
      () async {
        final planner = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: false,
                  reason: 'capability_ineligible:unsupported_video',
                  draft: draft,
                  capabilityReport: _makeFakeCapabilityReport(
                    canPassthroughRemux: false,
                    fileExists: true,
                    fileReadable: true,
                    reason: 'unsupported_video',
                    video: const VGPassthroughRemuxTrackCapability(
                      trackIndex: 0,
                      mime: 'video/x-custom',
                      supported: false,
                      reason: 'unsupported_mime',
                    ),
                  ),
                );
              },
        );

        final report = await planner.evaluate(draft: _makeDraft());

        expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
        expect(report.reason, equals('render_export_ready'));
        expect(report.useRenderExport, isTrue);
        expect(report.usePassthroughRemux, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.passthroughDecisionAttempted, isTrue);
        expect(report.passthroughDecisionReport, isNotNull);
      },
    );

    test('6. thrown probe render fallback with error diagnostics', () async {
      final planner = VGEditorExportAdmissionPlanner(
        passthroughDecisionProbe:
            ({required draft, request = const VGEditorExportRequest()}) async {
              throw StateError('Simulated passthrough decision probe failure');
            },
      );

      final report = await planner.evaluate(draft: _makeDraft());

      expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
      expect(
        report.reason,
        equals('render_export_ready:passthrough_exception'),
      );
      expect(report.useRenderExport, isTrue);
      expect(report.usePassthroughRemux, isFalse);
      expect(report.isBlocked, isFalse);
      expect(report.passthroughDecisionAttempted, isTrue);
      expect(report.passthroughDecisionReport, isNull);
      expect(
        report.diagnostics['error'],
        contains('Simulated passthrough decision probe failure'),
      );
      expect(report.proofBoundaryMatches, isTrue);
      expect(report.diagnosticNonClaimsHold, isTrue);
    });

    test(
      '7. proofBoundary mismatch or nonClaims violation in AB report -> renderExport fallback',
      () async {
        // Proof boundary mismatch
        final plannerMismatch = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: true,
                  proofBoundary: 'unexpected_proof_token',
                  draft: draft,
                );
              },
        );

        final reportMismatch = await plannerMismatch.evaluate(
          draft: _makeDraft(),
        );
        expect(
          reportMismatch.routeMode,
          equals(VGEditorExportRouteMode.renderExport),
        );
        expect(reportMismatch.reason, equals('render_export_ready'));

        // Non-claims violation
        final plannerViolation = VGEditorExportAdmissionPlanner(
          passthroughDecisionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return _makeFakePassthroughDecisionReport(
                  canPassthroughRemux: true,
                  nonClaims: const <String, bool>{
                    'mediaMuxerStarted': true,
                    'mediaCodecAllocated': false,
                    'samplesRead': false,
                    'outputFileWritten': false,
                    'productionExportTimelineBypass': false,
                    'cppPassthroughRemuxSinkNode': false,
                    'connectAppTouched': false,
                  },
                  draft: draft,
                );
              },
        );

        final reportViolation = await plannerViolation.evaluate(
          draft: _makeDraft(),
        );
        expect(
          reportViolation.routeMode,
          equals(VGEditorExportRouteMode.renderExport),
        );
        expect(reportViolation.reason, equals('render_export_ready'));
      },
    );

    test('8. evaluateDraft static convenience executes identically', () async {
      var calls = 0;
      final report = await VGEditorExportAdmissionPlanner.evaluateDraft(
        draft: _makeDraft(),
        passthroughDecisionProbe:
            ({required draft, request = const VGEditorExportRequest()}) async {
              calls++;
              return _makeFakePassthroughDecisionReport(draft: draft);
            },
      );

      expect(calls, equals(1));
      expect(
        report.routeMode,
        equals(VGEditorExportRouteMode.passthroughRemux),
      );
      expect(report.reason, equals('passthrough_ready'));
      expect(report.usePassthroughRemux, isTrue);
    });

    test('9. default planner integrates with MethodChannel probe', () async {
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

      const defaultPlanner = VGEditorExportAdmissionPlanner();
      final report = await defaultPlanner.evaluate(draft: _makeDraft());

      expect(
        report.routeMode,
        equals(VGEditorExportRouteMode.passthroughRemux),
      );
      expect(report.reason, equals('passthrough_ready'));
      expect(report.usePassthroughRemux, isTrue);
      expect(report.passthroughDecisionAttempted, isTrue);
      expect(report.passthroughDecisionReport, isNotNull);
      expect(
        report.passthroughDecisionReport!.capabilityReport!.extractorOpened,
        isTrue,
      );
    });
  });
}
