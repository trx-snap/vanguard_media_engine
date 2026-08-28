// Copyright (c) Connects -- Vanguard Phase 2-Unit AF.
// Public Dart Admission-Driven Export Execution Client tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

VGClipDescriptor _makeClip({
  String id = 'clip-1',
  String sourcePath = '/data/user/0/cache/input.mov',
  double durationSeconds = 10.0,
  double trimStartSeconds = 0.0,
  double trimEndSeconds = 10.0,
}) {
  return VGClipDescriptor(
    id: id,
    sourcePath: sourcePath,
    mediaKind: VGMediaKind.video,
    startTimeSeconds: 0.0,
    durationSeconds: durationSeconds,
    trimStartSeconds: trimStartSeconds,
    trimEndSeconds: trimEndSeconds,
    speed: 1.0,
  );
}

VGEditorDraft _makeDraft({
  String id = 'draft-1',
  List<VGClipDescriptor>? clips,
  int canvasWidth = 1080,
  int canvasHeight = 1920,
  int fps = 30,
}) {
  return VGEditorDraft(
    id: id,
    clips: clips ?? [_makeClip()],
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    fps: fps,
  );
}

VGEditorExportAdmissionReport _makeAdmissionReport({
  required VGEditorExportRouteMode routeMode,
  required String reason,
  VGEditorDraft? draft,
  bool passthroughDecisionAttempted = false,
  VGPassthroughRemuxDecisionReport? passthroughDecisionReport,
}) {
  final testDraft = draft ?? _makeDraft();
  final readiness = const VGEditorExportReadinessEvaluator().evaluate(
    draft: testDraft,
  );
  return VGEditorExportAdmissionReport(
    routeMode: routeMode,
    reason: reason,
    exportReadinessReport: readiness,
    passthroughDecisionReport: passthroughDecisionReport,
    passthroughDecisionAttempted: passthroughDecisionAttempted,
  );
}

VGPassthroughRemuxExecutionReport _makePassthroughReport({
  bool success = true,
  String sourcePath = '/data/user/0/cache/input.mov',
  String outputPath = '/data/user/0/cache/output.mp4',
  int outputSizeBytes = 1048576,
  String proofBoundary =
      'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
  Map<String, bool>? nonClaims,
  String? errorCode,
  String? errorMessage,
  Map<String, Object?>? diagnostics,
}) {
  return VGPassthroughRemuxExecutionReport(
    success: success,
    path: outputPath,
    outputPath: outputPath,
    sourcePath: sourcePath,
    width: 1080,
    height: 1920,
    rotationDegrees: 0,
    durationSeconds: 10.0,
    videoSamples: 300,
    audioSamples: 440,
    outputSizeBytes: outputSizeBytes,
    hasAudioTrack: true,
    proofBoundary: proofBoundary,
    nonClaims:
        nonClaims ??
        const <String, bool>{
          'mediaCodecAllocated': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
    errorCode: errorCode,
    errorMessage: errorMessage,
    diagnostics: diagnostics ?? const <String, Object?>{},
  );
}

VGEditorExportResult _makeRenderResult({
  String path = '/data/user/0/cache/render_out.mp4',
  double durationSeconds = 10.0,
  int width = 1080,
  int height = 1920,
  int fps = 30,
}) {
  return VGEditorExportResult(
    path: path,
    durationSeconds: durationSeconds,
    width: width,
    height: height,
    fps: fps,
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

  // ---------------------------------------------------------------------------
  // 1. VGEditorAdmissionExportReport
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportReport', () {
    test('constants match expected proof boundary and standard non-claims', () {
      expect(
        VGEditorAdmissionExportReport.expectedProofBoundary,
        equals(
          'admission_export_execution_client_explicit_dispatch_no_controller_no_connectsapp',
        ),
      );
      expect(
        VGEditorAdmissionExportReport.standardNonClaims,
        equals(const <String, bool>{
          'controllerTouched': false,
          'connectAppTouched': false,
          'productionExportTimelineMutated': false,
        }),
      );
    });

    test(
      'getters, route booleans, toMap, and toString for passthrough success',
      () {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );
        final passthroughReport = _makePassthroughReport();

        final report = VGEditorAdmissionExportReport(
          success: true,
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_export_succeeded',
          admissionReport: admissionReport,
          passthroughReport: passthroughReport,
          diagnostics: const <String, Object?>{'telemetry_key': 'abc123'},
        );

        expect(report.success, isTrue);
        expect(report.isFailure, isFalse);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.isPassthrough, isTrue);
        expect(report.isRender, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.reason, equals('passthrough_export_succeeded'));
        expect(report.admissionReport, equals(admissionReport));
        expect(report.passthroughReport, equals(passthroughReport));
        expect(report.renderResult, isNull);
        expect(report.errorCode, isNull);
        expect(report.errorMessage, isNull);
        expect(
          report.proofBoundary,
          equals(VGEditorAdmissionExportReport.expectedProofBoundary),
        );
        expect(report.diagnostics['telemetry_key'], equals('abc123'));

        final map = report.toMap();
        expect(map['success'], isTrue);
        expect(map['routeMode'], equals('passthroughRemux'));
        expect(map['reason'], equals('passthrough_export_succeeded'));
        expect(map['isPassthrough'], isTrue);
        expect(map['isRender'], isFalse);
        expect(map['isBlocked'], isFalse);
        expect(map['isFailure'], isFalse);
        expect(map['admissionReport'], isA<Map<String, Object?>>());
        expect(map['passthroughReport'], isA<Map<String, Object?>>());
        expect(map.containsKey('renderResult'), isFalse);
        expect(map.containsKey('errorCode'), isFalse);
        expect(map.containsKey('errorMessage'), isFalse);
        expect(
          map['proofBoundary'],
          equals(VGEditorAdmissionExportReport.expectedProofBoundary),
        );
        expect(map['diagnostics'], equals(const {'telemetry_key': 'abc123'}));

        final str = report.toString();
        expect(str, contains('success: true'));
        expect(str, contains('routeMode: passthroughRemux'));
        expect(str, contains('passthrough_export_succeeded'));
        expect(
          str,
          contains(
            'admission_export_execution_client_explicit_dispatch_no_controller_no_connectsapp',
          ),
        );
      },
    );

    test('getters, route booleans, toMap for render success', () {
      final admissionReport = _makeAdmissionReport(
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_ready',
      );
      final renderResult = _makeRenderResult();

      final report = VGEditorAdmissionExportReport(
        success: true,
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'render_export_succeeded',
        admissionReport: admissionReport,
        renderResult: renderResult,
      );

      expect(report.success, isTrue);
      expect(report.isFailure, isFalse);
      expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
      expect(report.isPassthrough, isFalse);
      expect(report.isRender, isTrue);
      expect(report.isBlocked, isFalse);
      expect(report.reason, equals('render_export_succeeded'));
      expect(report.passthroughReport, isNull);
      expect(report.renderResult, equals(renderResult));

      final map = report.toMap();
      expect(map['success'], isTrue);
      expect(map['routeMode'], equals('renderExport'));
      expect(map['isRender'], isTrue);
      expect(map['isPassthrough'], isFalse);
      expect(map['isBlocked'], isFalse);
      expect(map['renderResult'], isA<Map<String, Object?>>());
      expect(map.containsKey('passthroughReport'), isFalse);
    });

    test('getters, route booleans, toMap for blocked outcome', () {
      final admissionReport = _makeAdmissionReport(
        routeMode: VGEditorExportRouteMode.blocked,
        reason: 'export_blocked:source_unavailable',
      );

      final report = VGEditorAdmissionExportReport(
        success: false,
        routeMode: VGEditorExportRouteMode.blocked,
        reason: 'admission_blocked:export_blocked:source_unavailable',
        admissionReport: admissionReport,
        errorCode: 'SOURCE_UNAVAILABLE',
        errorMessage: 'Source file missing',
      );

      expect(report.success, isFalse);
      expect(report.isFailure, isTrue);
      expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
      expect(report.isPassthrough, isFalse);
      expect(report.isRender, isFalse);
      expect(report.isBlocked, isTrue);
      expect(
        report.reason,
        equals('admission_blocked:export_blocked:source_unavailable'),
      );
      expect(report.errorCode, equals('SOURCE_UNAVAILABLE'));
      expect(report.errorMessage, equals('Source file missing'));
      expect(report.passthroughReport, isNull);
      expect(report.renderResult, isNull);

      final map = report.toMap();
      expect(map['success'], isFalse);
      expect(map['isFailure'], isTrue);
      expect(map['isBlocked'], isTrue);
      expect(map['errorCode'], equals('SOURCE_UNAVAILABLE'));
      expect(map['errorMessage'], equals('Source file missing'));
      expect(map.containsKey('passthroughReport'), isFalse);
      expect(map.containsKey('renderResult'), isFalse);
    });

    test('diagnostics map is unmodifiable', () {
      final mutableDiagnostics = <String, Object?>{'key': 'initial'};
      final report = VGEditorAdmissionExportReport(
        success: true,
        routeMode: VGEditorExportRouteMode.renderExport,
        reason: 'ok',
        admissionReport: _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'ok',
        ),
        diagnostics: mutableDiagnostics,
      );

      expect(
        () => report.diagnostics['key'] = 'modified',
        throwsUnsupportedError,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. VGEditorAdmissionExportClient: Blocked Route
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Blocked Route', () {
    test(
      'admission blocked returns fail-closed report and invokes no executors',
      () async {
        var passthroughCallCount = 0;
        var renderCallCount = 0;
        var admissionProbeCallCount = 0;

        final blockedAdmissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.blocked,
          reason: 'export_blocked:source_unavailable',
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                admissionProbeCallCount++;
                return blockedAdmissionReport;
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                renderCallCount++;
                return _makeRenderResult();
              },
        );

        final draft = _makeDraft();
        final report = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(admissionProbeCallCount, equals(1));
        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));

        expect(report.success, isFalse);
        expect(report.isFailure, isTrue);
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.isBlocked, isTrue);
        expect(report.isPassthrough, isFalse);
        expect(report.isRender, isFalse);
        expect(
          report.reason,
          equals('admission_blocked:export_blocked:source_unavailable'),
        );
        expect(report.admissionReport, equals(blockedAdmissionReport));
        expect(report.passthroughReport, isNull);
        expect(report.renderResult, isNull);
        expect(
          report.proofBoundary,
          equals(VGEditorAdmissionExportReport.expectedProofBoundary),
        );
        expect(
          report.diagnostics['admissionReport'],
          equals(blockedAdmissionReport.toMap()),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 2b. VGEditorAdmissionExportClient: Admission Probe Failures
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Admission Probe Failures', () {
    test(
      'admission probe PlatformException converts to fail-closed report and invokes no executors',
      () async {
        var passthroughCallCount = 0;
        var renderCallCount = 0;

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                throw PlatformException(
                  code: 'ADMISSION_PROBE_ERROR',
                  message: 'Native capability probe threw error',
                  details: <String, Object?>{'probe': 'failed'},
                );
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                renderCallCount++;
                return _makeRenderResult();
              },
        );

        final draft = _makeDraft();
        final report = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));

        expect(report.success, isFalse);
        expect(report.isFailure, isTrue);
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.isBlocked, isTrue);
        expect(report.isPassthrough, isFalse);
        expect(report.isRender, isFalse);
        expect(report.reason, equals('admission_probe_failed'));
        expect(report.errorCode, equals('ADMISSION_PROBE_ERROR'));
        expect(
          report.errorMessage,
          equals('Native capability probe threw error'),
        );
        expect(report.diagnostics['errorDetails'], equals({'probe': 'failed'}));
        expect(
          report.proofBoundary,
          equals(VGEditorAdmissionExportReport.expectedProofBoundary),
        );

        // Verify minimal blocked admission report
        final admReport = report.admissionReport;
        expect(admReport.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(admReport.reason, equals('admission_probe_failed'));
        expect(admReport.passthroughDecisionAttempted, isFalse);
        expect(
          admReport.proofBoundary,
          equals(VGEditorExportAdmissionReport.expectedProofBoundary),
        );
        expect(admReport.diagnosticNonClaimsHold, isTrue);
      },
    );

    test(
      'admission probe PlatformException with empty code falls back to ADMISSION_PROBE_FAILED',
      () async {
        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                throw PlatformException(
                  code: '',
                  message: 'Empty error code probe exception',
                );
              },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('admission_probe_failed'));
        expect(report.errorCode, equals('ADMISSION_PROBE_FAILED'));
        expect(report.errorMessage, equals('Empty error code probe exception'));
      },
    );

    test(
      'admission probe generic exception converts to fail-closed report with string error message',
      () async {
        var passthroughCallCount = 0;
        var renderCallCount = 0;

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                throw StateError('Probe worker thread died');
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                renderCallCount++;
                return _makeRenderResult();
              },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));

        expect(report.success, isFalse);
        expect(report.isBlocked, isTrue);
        expect(report.routeMode, equals(VGEditorExportRouteMode.blocked));
        expect(report.reason, equals('admission_probe_failed'));
        expect(report.errorCode, equals('ADMISSION_PROBE_FAILED'));
        expect(report.errorMessage, contains('Probe worker thread died'));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 3. VGEditorAdmissionExportClient: Passthrough Missing Output Path
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Passthrough Missing Output Path', () {
    test(
      'null, empty, or whitespace outputPath returns PASSTHROUGH_OUTPUT_PATH_REQUIRED without executor call',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        var passthroughCallCount = 0;
        var renderCallCount = 0;

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                renderCallCount++;
                return _makeRenderResult();
              },
        );

        final draft = _makeDraft();

        // Case A: null outputPath
        final reportNull = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: null),
        );
        expect(reportNull.success, isFalse);
        expect(reportNull.isFailure, isTrue);
        expect(
          reportNull.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(reportNull.isPassthrough, isTrue);
        expect(reportNull.reason, equals('passthrough_output_path_required'));
        expect(
          reportNull.errorCode,
          equals('PASSTHROUGH_OUTPUT_PATH_REQUIRED'),
        );
        expect(
          reportNull.errorMessage,
          equals(
            'request.outputPath must be a non-empty path for the passthrough remux route',
          ),
        );
        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));

        // Case B: empty string
        final reportEmpty = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: ''),
        );
        expect(reportEmpty.success, isFalse);
        expect(
          reportEmpty.errorCode,
          equals('PASSTHROUGH_OUTPUT_PATH_REQUIRED'),
        );
        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));

        // Case C: whitespace only
        final reportWhitespace = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '   \t\n  '),
        );
        expect(reportWhitespace.success, isFalse);
        expect(
          reportWhitespace.errorCode,
          equals('PASSTHROUGH_OUTPUT_PATH_REQUIRED'),
        );
        expect(passthroughCallCount, equals(0));
        expect(renderCallCount, equals(0));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 4. VGEditorAdmissionExportClient: Passthrough Success
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Passthrough Success', () {
    test(
      'valid passthrough remux executes passthrough executor and returns success report',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        VGPassthroughRemuxRequest? capturedPassthroughRequest;
        var renderCallCount = 0;

        final expectedPassthroughReport = _makePassthroughReport(
          sourcePath: '/data/user/0/cache/input.mov',
          outputPath: '/data/user/0/cache/output.mp4',
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            capturedPassthroughRequest = request;
            return expectedPassthroughReport;
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                renderCallCount++;
                return _makeRenderResult();
              },
        );

        final draft = _makeDraft(
          clips: [_makeClip(sourcePath: '/data/user/0/cache/input.mov')],
        );

        final report = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(
            outputPath: '  /data/user/0/cache/output.mp4  ',
          ),
        );

        expect(capturedPassthroughRequest, isNotNull);
        expect(
          capturedPassthroughRequest!.sourcePath,
          equals('/data/user/0/cache/input.mov'),
        );
        expect(
          capturedPassthroughRequest!.outputPath,
          equals('/data/user/0/cache/output.mp4'),
        );
        expect(renderCallCount, equals(0));

        expect(report.success, isTrue);
        expect(report.isFailure, isFalse);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.isPassthrough, isTrue);
        expect(report.isRender, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.reason, equals('passthrough_export_succeeded'));
        expect(report.admissionReport, equals(admissionReport));
        expect(report.passthroughReport, equals(expectedPassthroughReport));
        expect(report.renderResult, isNull);
        expect(report.errorCode, isNull);
        expect(report.errorMessage, isNull);
        expect(
          report.proofBoundary,
          equals(VGEditorAdmissionExportReport.expectedProofBoundary),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 5. VGEditorAdmissionExportClient: Passthrough Fail-Closed
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Passthrough Fail-Closed', () {
    test(
      'passthrough report failure with explicit error code propagates code and message',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final failedPassthroughReport = _makePassthroughReport(
          success: false,
          errorCode: 'FILE_UNREADABLE',
          errorMessage: 'Source file could not be read',
          outputSizeBytes: 0,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async => failedPassthroughReport,
        );

        final draft = _makeDraft();
        final report = await client.export(
          draft: draft,
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.isFailure, isTrue);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.isPassthrough, isTrue);
        expect(report.reason, equals('passthrough_execution_failed'));
        expect(report.errorCode, equals('FILE_UNREADABLE'));
        expect(report.errorMessage, equals('Source file could not be read'));
        expect(report.passthroughReport, equals(failedPassthroughReport));
      },
    );

    test(
      'passthrough report failure with null error code falls back to PASSTHROUGH_EXECUTION_FAILED',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final failedPassthroughReport = _makePassthroughReport(
          success: false,
          errorCode: null,
          errorMessage: null,
          outputSizeBytes: 0,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async => failedPassthroughReport,
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.errorCode, equals('PASSTHROUGH_EXECUTION_FAILED'));
        expect(report.errorMessage, isNull);
        expect(report.reason, equals('passthrough_execution_failed'));
      },
    );

    test(
      'passthrough report success=true but proof boundary mismatch fails closed',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final mismatchedBoundaryReport = _makePassthroughReport(
          success: true,
          proofBoundary: 'unexpected_proof_boundary_token',
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async => mismatchedBoundaryReport,
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.errorCode, equals('PASSTHROUGH_EXECUTION_FAILED'));
        expect(report.reason, equals('passthrough_execution_failed'));
      },
    );

    test(
      'passthrough report success=true but non-claims violated fails closed',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final violatedNonClaimsReport = _makePassthroughReport(
          success: true,
          nonClaims: const <String, bool>{
            'mediaCodecAllocated': true, // Violated non-claim!
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async => violatedNonClaimsReport,
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.errorCode, equals('PASSTHROUGH_EXECUTION_FAILED'));
        expect(report.reason, equals('passthrough_execution_failed'));
      },
    );

    test(
      'passthrough executor PlatformException maps code, message, and details into fail-closed report',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            throw PlatformException(
              code: 'PASSTHROUGH_MUXER_NATIVE_CRASH',
              message: 'MediaMuxer stop failed with error',
              details: <String, Object?>{'exitCode': -1},
            );
          },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.isFailure, isTrue);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.isPassthrough, isTrue);
        expect(report.reason, equals('passthrough_execution_failed'));
        expect(report.errorCode, equals('PASSTHROUGH_MUXER_NATIVE_CRASH'));
        expect(
          report.errorMessage,
          equals('MediaMuxer stop failed with error'),
        );
        expect(report.diagnostics['errorDetails'], equals({'exitCode': -1}));
        expect(report.passthroughReport, isNull);
      },
    );

    test(
      'passthrough executor PlatformException with empty code falls back to PASSTHROUGH_EXECUTION_FAILED',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            throw PlatformException(
              code: '',
              message: 'Empty code passthrough error',
            );
          },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.reason, equals('passthrough_execution_failed'));
        expect(report.errorCode, equals('PASSTHROUGH_EXECUTION_FAILED'));
        expect(report.errorMessage, equals('Empty code passthrough error'));
        expect(report.passthroughReport, isNull);
      },
    );

    test(
      'passthrough executor generic exception maps to PASSTHROUGH_EXECUTION_FAILED with string error message',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.passthroughRemux,
          reason: 'passthrough_ready',
          passthroughDecisionAttempted: true,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            throw StateError('Passthrough runner IO pipe disconnected');
          },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(
          report.routeMode,
          equals(VGEditorExportRouteMode.passthroughRemux),
        );
        expect(report.isPassthrough, isTrue);
        expect(report.reason, equals('passthrough_execution_failed'));
        expect(report.errorCode, equals('PASSTHROUGH_EXECUTION_FAILED'));
        expect(
          report.errorMessage,
          contains('Passthrough runner IO pipe disconnected'),
        );
        expect(report.passthroughReport, isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 6. VGEditorAdmissionExportClient: Render Route Success & Progress
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Render Route Success', () {
    test(
      'render route passes prepared draft, request, forwards progress, and returns success report',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
        );

        VGEditorDraft? capturedRenderDraft;
        VGEditorExportRequest? capturedRenderRequest;
        var passthroughCallCount = 0;
        final progressUpdates = <double>[];

        final expectedRenderResult = _makeRenderResult(
          path: '/data/user/0/cache/rendered.mp4',
          durationSeconds: 15.0,
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                capturedRenderDraft = draft;
                capturedRenderRequest = request;
                onProgress?.call(0.25);
                onProgress?.call(0.75);
                onProgress?.call(1.0);
                return expectedRenderResult;
              },
        );

        final inputDraft = _makeDraft(
          clips: [
            _makeClip(id: 'c1', durationSeconds: 5.0),
            _makeClip(id: 'c2', durationSeconds: 10.0),
          ],
        );

        final exportRequest = const VGEditorExportRequest(
          outputPath: '/data/user/0/cache/rendered.mp4',
          width: 720,
          height: 1280,
          fps: 30,
          bitrateBps: 4000000,
        );

        final report = await client.export(
          draft: inputDraft,
          request: exportRequest,
          onProgress: (p) => progressUpdates.add(p),
        );

        expect(passthroughCallCount, equals(0));
        expect(capturedRenderDraft, isNotNull);
        // Verify audio flattening/composition was applied on disposable draft
        expect(capturedRenderDraft!.audioSidecarPlan, isNotNull);
        expect(capturedRenderRequest, equals(exportRequest));
        expect(progressUpdates, equals([0.25, 0.75, 1.0]));

        expect(report.success, isTrue);
        expect(report.isFailure, isFalse);
        expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
        expect(report.isRender, isTrue);
        expect(report.isPassthrough, isFalse);
        expect(report.isBlocked, isFalse);
        expect(report.reason, equals('render_export_succeeded'));
        expect(report.admissionReport, equals(admissionReport));
        expect(report.renderResult, equals(expectedRenderResult));
        expect(report.passthroughReport, isNull);
        expect(report.errorCode, isNull);
        expect(report.errorMessage, isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 7. VGEditorAdmissionExportClient: Render Route Failures
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient - Render Route Failures', () {
    test(
      'PlatformException maps code, message, and details into fail-closed report',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
        );

        var passthroughCallCount = 0;

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          passthroughExecutor: (request) async {
            passthroughCallCount++;
            return _makePassthroughReport();
          },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                throw PlatformException(
                  code: 'ENCODER_CONFIG_FAILED',
                  message: 'MediaCodec could not configure format',
                  details: <String, Object?>{'width': 4096, 'height': 4096},
                );
              },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(passthroughCallCount, equals(0));
        expect(report.success, isFalse);
        expect(report.isFailure, isTrue);
        expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
        expect(report.isRender, isTrue);
        expect(report.reason, equals('render_export_failed'));
        expect(report.errorCode, equals('ENCODER_CONFIG_FAILED'));
        expect(
          report.errorMessage,
          equals('MediaCodec could not configure format'),
        );
        expect(
          report.diagnostics['errorDetails'],
          equals({'width': 4096, 'height': 4096}),
        );
      },
    );

    test(
      'PlatformException with empty code falls back to RENDER_EXPORT_FAILED',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                throw PlatformException(
                  code: '',
                  message: 'Empty platform error code',
                );
              },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.errorCode, equals('RENDER_EXPORT_FAILED'));
        expect(report.errorMessage, equals('Empty platform error code'));
      },
    );

    test(
      'generic exception maps to RENDER_EXPORT_FAILED with string error message',
      () async {
        final admissionReport = _makeAdmissionReport(
          routeMode: VGEditorExportRouteMode.renderExport,
          reason: 'render_export_ready',
        );

        final client = VGEditorAdmissionExportClient(
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                return admissionReport;
              },
          renderExecutor:
              ({required draft, required request, onProgress}) async {
                throw StateError(
                  'Compositor native pipeline crashed unexpectedly',
                );
              },
        );

        final report = await client.export(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(outputPath: '/data/out.mp4'),
        );

        expect(report.success, isFalse);
        expect(report.routeMode, equals(VGEditorExportRouteMode.renderExport));
        expect(report.reason, equals('render_export_failed'));
        expect(report.errorCode, equals('RENDER_EXPORT_FAILED'));
        expect(
          report.errorMessage,
          contains('Compositor native pipeline crashed unexpectedly'),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 8. Static Convenience: VGEditorAdmissionExportClient.exportDraft
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient.exportDraft Static Helper', () {
    test(
      'dispatches through injected probe, passthrough executor, and render executor',
      () async {
        var admissionCalls = 0;
        var passthroughCalls = 0;

        final report = await VGEditorAdmissionExportClient.exportDraft(
          draft: _makeDraft(),
          request: const VGEditorExportRequest(
            outputPath: '/data/static_out.mp4',
          ),
          admissionProbe:
              ({
                required draft,
                request = const VGEditorExportRequest(),
              }) async {
                admissionCalls++;
                return _makeAdmissionReport(
                  routeMode: VGEditorExportRouteMode.passthroughRemux,
                  reason: 'passthrough_ready',
                  passthroughDecisionAttempted: true,
                );
              },
          passthroughExecutor: (request) async {
            passthroughCalls++;
            return _makePassthroughReport(outputPath: request.outputPath);
          },
        );

        expect(admissionCalls, equals(1));
        expect(passthroughCalls, equals(1));
        expect(report.success, isTrue);
        expect(report.isPassthrough, isTrue);
        expect(report.reason, equals('passthrough_export_succeeded'));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 9. Default Wiring Integration (MethodChannel Mocks)
  // ---------------------------------------------------------------------------
  group('VGEditorAdmissionExportClient Default Wiring Integration', () {
    test(
      'default client wires default AC planner and AE passthrough client over MethodChannel',
      () async {
        final executedCalls = <MethodCall>[];

        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          executedCalls.add(call);
          if (call.method == 'runAndroidPassthroughRemuxCapabilityProbeSmoke') {
            return <Object?, Object?>{
              'canPassthroughRemux': true,
              'reason': 'supported',
              'sourcePath': call.arguments['sourcePath'],
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
          } else if (call.method == 'exportPassthroughRemux') {
            return <Object?, Object?>{
              'success': true,
              'path': call.arguments['outputPath'],
              'outputPath': call.arguments['outputPath'],
              'sourcePath': call.arguments['sourcePath'],
              'width': 1080,
              'height': 1920,
              'rotationDegrees': 0,
              'durationSeconds': 10.0,
              'videoSamples': 300,
              'audioSamples': 440,
              'outputSizeBytes': 2048576,
              'hasAudioTrack': true,
              'proofBoundary':
                  'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
              'nonClaims': <Object?, Object?>{
                'mediaCodecAllocated': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
            };
          }
          return null;
        });

        final defaultClient = VGEditorAdmissionExportClient();
        final draft = _makeDraft(
          clips: [_makeClip(sourcePath: '/data/real_clip.mov')],
        );

        final report = await defaultClient.export(
          draft: draft,
          request: const VGEditorExportRequest(
            outputPath: '/data/real_output.mp4',
          ),
        );

        expect(executedCalls.length, equals(2));
        expect(
          executedCalls[0].method,
          equals('runAndroidPassthroughRemuxCapabilityProbeSmoke'),
        );
        expect(executedCalls[1].method, equals('exportPassthroughRemux'));

        expect(report.success, isTrue);
        expect(report.isPassthrough, isTrue);
        expect(report.reason, equals('passthrough_export_succeeded'));
        expect(report.passthroughReport, isNotNull);
        expect(report.passthroughReport!.outputSizeBytes, equals(2048576));
      },
    );
  });
}
