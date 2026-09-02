// vg_timeline_dual_decoder_sync_smoke_test.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC):
// Android True-DAG dual MediaCodec synchronized ingest + Vulkan crossfade
// diagnostic smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_dual_decoder_sync_smoke.dart';

const String _proofBoundary =
    'native_android_dual_mediacodec_imagereader_ahb_to_vulkan_transition_crossfade_diagnostic_only_no_export';
const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineDualDecoderSyncSmoke';

const List<String> _gateKeys = <String>[
  'argumentValidationOk',
  'fixtureFormatOk',
  'dualDecoderSetupOk',
  'leadInClip0Ok',
  'overlapPairAcquireOk',
  'overlapPtsMonotonicOk',
  'transitionProgressOk',
  'nativeImportOk',
  'nativeCrossfadeRenderOk',
  'leadOutClip1Ok',
  'resourceReleaseOk',
];

const String _clip0 = '/data/local/tmp/p5_dual_decoder_sync_clip0.mov';
const String _clip1 = '/data/local/tmp/p5_dual_decoder_sync_clip1.mov';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  for (final key in _gateKeys) key: true,
  'allNativeLanesPass': true,
  'nativeAllLanesPass': true,
  'details': const <String, Object?>{
    'clip0DecoderName': 'c2.exynos.h264.decoder',
    'clip1DecoderName': 'c2.exynos.h264.decoder',
    'clip0Width': 1920,
    'overlapFrames': 3,
    'nativeResults': <Object?>[
      <String, Object?>{
        'pass': true,
        'details': <String, Object?>{
          'deviceName': 'Samsung Xclipse 540',
          'crossfadeCenterRgb': '96,88,80',
          'blendWeightTo': 0.25,
        },
      },
    ],
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineDualDecoderSyncSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineDualDecoderSyncSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

Future<VGTimelineDualDecoderSyncSmokeReport> _run({
  String clip0Path = _clip0,
  String clip1Path = _clip1,
  int? maxFrames,
  int? overlapFrames,
  Duration? timeout,
  MethodChannel? channel,
}) =>
    VGTimelineDualDecoderSyncSmokeReport.runAndroidDagPhase5TimelineDualDecoderSyncSmoke(
      clip0Path: clip0Path,
      clip1Path: clip1Path,
      maxFrames: maxFrames,
      overlapFrames: overlapFrames,
      timeout: timeout,
      channel: channel,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('contract constants', () {
    test('canonical strings, route, arg keys and gate keys are frozen', () {
      expect(
        VGTimelineDualDecoderSyncSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(VGTimelineDualDecoderSyncSmokeReport.passMarker, _passMarker);
      expect(VGTimelineDualDecoderSyncSmokeReport.failMarker, _failMarker);
      expect(VGTimelineDualDecoderSyncSmokeReport.methodName, _method);
      expect(VGTimelineDualDecoderSyncSmokeReport.clip0PathArg, 'clip0Path');
      expect(VGTimelineDualDecoderSyncSmokeReport.clip1PathArg, 'clip1Path');
      expect(VGTimelineDualDecoderSyncSmokeReport.maxFramesArg, 'maxFrames');
      expect(
        VGTimelineDualDecoderSyncSmokeReport.overlapFramesArg,
        'overlapFrames',
      );
      expect(VGTimelineDualDecoderSyncSmokeReport.leadFrames, 2);
      expect(VGTimelineDualDecoderSyncSmokeReport.defaultOverlapFrames, 3);
      expect(VGTimelineDualDecoderSyncSmokeReport.defaultMaxFrames, 60);
      expect(
        VGTimelineDualDecoderSyncSmokeReport.defaultMaxFrames,
        greaterThanOrEqualTo(
          VGTimelineDualDecoderSyncSmokeReport.leadFrames +
              VGTimelineDualDecoderSyncSmokeReport.defaultOverlapFrames,
        ),
      );
      expect(
        VGTimelineDualDecoderSyncSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGTimelineDualDecoderSyncSmokeReport.argumentGateKeys.length, 1);
      expect(VGTimelineDualDecoderSyncSmokeReport.setupGateKeys.length, 2);
      expect(VGTimelineDualDecoderSyncSmokeReport.syncGateKeys.length, 4);
      expect(VGTimelineDualDecoderSyncSmokeReport.nativeGateKeys.length, 2);
      expect(VGTimelineDualDecoderSyncSmokeReport.lifecycleGateKeys.length, 2);
      expect(_gateKeys.toSet().length, _gateKeys.length, reason: 'unique');
    });

    test('proof boundary and markers name the dual decoder sync route', () {
      expect(_proofBoundary, contains('dual_mediacodec'));
      expect(_proofBoundary, contains('ahb_to_vulkan'));
      expect(_proofBoundary, contains('diagnostic_only_no_export'));
      expect(_passMarker, contains('DUAL_DECODER_SYNC'));
      expect(_failMarker, contains('DUAL_DECODER_SYNC'));
      expect(_method, isNot(contains('Export')));
    });
  });

  group('VGTimelineDualDecoderSyncSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.values,
        orderedEquals(const [
          VGTimelineDualDecoderSyncSmokeDecision.pass,
          VGTimelineDualDecoderSyncSmokeDecision.fail,
          VGTimelineDualDecoderSyncSmokeDecision.unsupported,
          VGTimelineDualDecoderSyncSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('pass'),
        VGTimelineDualDecoderSyncSmokeDecision.pass,
      );
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('PASS'),
        VGTimelineDualDecoderSyncSmokeDecision.pass,
      );
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('fail'),
        VGTimelineDualDecoderSyncSmokeDecision.fail,
      );
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineDualDecoderSyncSmokeDecision.unsupported,
      );
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('harnessException'),
        VGTimelineDualDecoderSyncSmokeDecision.harnessException,
      );
      expect(
        VGTimelineDualDecoderSyncSmokeDecision.fromRaw('harness_exception'),
        VGTimelineDualDecoderSyncSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineDualDecoderSyncSmokeDecision.fromRaw(invalid),
          VGTimelineDualDecoderSyncSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineDualDecoderSyncSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineDualDecoderSyncSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      // Lane 0.
      expect(report.argumentValidationPass, isTrue);
      // Lane 1.
      expect(report.fixtureFormatPass, isTrue);
      expect(report.dualDecoderSetupPass, isTrue);
      expect(report.setupPass, isTrue);
      // Lane 2.
      expect(report.leadInClip0Pass, isTrue);
      expect(report.overlapPairAcquirePass, isTrue);
      expect(report.overlapPtsMonotonicPass, isTrue);
      expect(report.transitionProgressPass, isTrue);
      expect(report.syncPass, isTrue);
      // Lane 3.
      expect(report.nativeImportPass, isTrue);
      expect(report.nativeCrossfadeRenderPass, isTrue);
      expect(report.nativePass, isTrue);
      // Lane 4.
      expect(report.leadOutClip1Pass, isTrue);
      expect(report.resourceReleasePass, isTrue);
      expect(report.lifecyclePass, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.details['clip0DecoderName'], 'c2.exynos.h264.decoder');
      expect(report.details['clip0Width'], 1920);
      expect(report.details['nativeResults'], isA<List<Object?>>());

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }
      expect(serialized['allNativeLanesPass'], isTrue);
      expect(serialized['nativeAllLanesPass'], isTrue);

      final roundTrip = VGTimelineDualDecoderSyncSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed sync gate is not a verified pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'overlap_pts_not_monotonic',
        'overlapPtsMonotonicOk': false,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineDualDecoderSyncSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.overlapPtsMonotonicPass, isFalse);
      expect(report.overlapPairAcquirePass, isTrue);
      expect(report.syncPass, isFalse);
      expect(report.setupPass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.lifecyclePass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'overlap_pts_not_monotonic');
      expect(report.isVerifiedPass, isFalse);
    });

    test('every single gate failure flips allNativeLanesPass', () {
      for (final key in _gateKeys) {
        final report = _createSampleReport({key: false});
        expect(report.gates[key], isFalse, reason: key);
        expect(report.allNativeLanesPass, isFalse, reason: key);
        expect(report.isVerifiedPass, isFalse, reason: key);
      }
    });

    test('lane group getters reflect only their own keys', () {
      final argFail = _createSampleReport({'argumentValidationOk': false});
      expect(argFail.argumentValidationPass, isFalse);
      expect(argFail.setupPass, isTrue);
      expect(argFail.syncPass, isTrue);
      expect(argFail.nativePass, isTrue);
      expect(argFail.lifecyclePass, isTrue);

      final setupFail = _createSampleReport({'dualDecoderSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.fixtureFormatPass, isTrue);
      expect(setupFail.dualDecoderSetupPass, isFalse);
      expect(setupFail.syncPass, isTrue);

      final fixtureFail = _createSampleReport({'fixtureFormatOk': false});
      expect(fixtureFail.setupPass, isFalse);
      expect(fixtureFail.nativePass, isTrue);

      final syncFail = _createSampleReport({'transitionProgressOk': false});
      expect(syncFail.syncPass, isFalse);
      expect(syncFail.transitionProgressPass, isFalse);
      expect(syncFail.leadInClip0Pass, isTrue);
      expect(syncFail.setupPass, isTrue);
      expect(syncFail.nativePass, isTrue);

      final leadInFail = _createSampleReport({'leadInClip0Ok': false});
      expect(leadInFail.syncPass, isFalse);
      expect(leadInFail.lifecyclePass, isTrue);

      final pairFail = _createSampleReport({'overlapPairAcquireOk': false});
      expect(pairFail.syncPass, isFalse);
      expect(pairFail.nativePass, isTrue);

      final importFail = _createSampleReport({'nativeImportOk': false});
      expect(importFail.nativePass, isFalse);
      expect(importFail.nativeImportPass, isFalse);
      expect(importFail.nativeCrossfadeRenderPass, isTrue);
      expect(importFail.syncPass, isTrue);

      final renderFail = _createSampleReport({
        'nativeCrossfadeRenderOk': false,
      });
      expect(renderFail.nativePass, isFalse);
      expect(renderFail.lifecyclePass, isTrue);

      final leadOutFail = _createSampleReport({'leadOutClip1Ok': false});
      expect(leadOutFail.lifecyclePass, isFalse);
      expect(leadOutFail.leadOutClip1Pass, isFalse);
      expect(leadOutFail.resourceReleasePass, isTrue);
      expect(leadOutFail.nativePass, isTrue);

      final releaseFail = _createSampleReport({'resourceReleaseOk': false});
      expect(releaseFail.lifecyclePass, isFalse);
      expect(releaseFail.resourceReleasePass, isFalse);
      expect(releaseFail.syncPass, isTrue);
    });

    test('wrong marker fails verified pass even when all gates pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final failMarkerReport = _createSampleReport({'marker': _failMarker});
      expect(failMarkerReport.hasFailMarker, isTrue);
      expect(failMarkerReport.isVerifiedPass, isFalse);

      // Sibling Phase 5 PASS markers must never satisfy this route.
      for (final sibling in const <String>[
        'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER_PHYSICAL_SMOKE_PASS',
        'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_PASS',
        'ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_NATIVE_CROSSFADE_PASS',
      ]) {
        final siblingReport = _createSampleReport({'marker': sibling});
        expect(siblingReport.hasPassMarker, isFalse, reason: sibling);
        expect(siblingReport.isVerifiedPass, isFalse, reason: sibling);
      }
    });

    test('wrong proof boundary fails verified pass', () {
      final report = _createSampleReport({
        'proofBoundary': 'incorrect_proof_boundary',
      });
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.isVerifiedPass, isFalse);

      final siblingBoundaryReport = _createSampleReport({
        'proofBoundary':
            'native_vulkan_timeline_transition_compositor_shader_raster_only_no_decode_no_export',
      });
      expect(siblingBoundaryReport.hasCanonicalProofBoundary, isFalse);
      expect(siblingBoundaryReport.isVerifiedPass, isFalse);
    });

    test('native aggregate disagreement fails verified pass', () {
      final report = _createSampleReport({'allNativeLanesPass': false});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('pass=false with every gate true is not a verified pass', () {
      final report = _createSampleReport({'pass': false, 'status': 'FAIL'});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'nativeAllLanesPass spelling is accepted when allNativeLanesPass is absent',
      () {
        final raw = _createSampleRawMap()..remove('allNativeLanesPass');
        final report = VGTimelineDualDecoderSyncSmokeReport.fromMap(raw);
        expect(report.nativeAllLanesPass, isTrue);
        expect(report.isVerifiedPass, isTrue);

        final rawFalse = _createSampleRawMap({'nativeAllLanesPass': false})
          ..remove('allNativeLanesPass');
        final reportFalse = VGTimelineDualDecoderSyncSmokeReport.fromMap(
          rawFalse,
        );
        expect(reportFalse.nativeAllLanesPass, isFalse);
        expect(reportFalse.isVerifiedPass, isFalse);
      },
    );

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'dualDecoderSetupOk': 'true',
        'leadOutClip1Ok': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.dualDecoderSetupPass, isTrue);
      expect(report.leadOutClip1Pass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>[null, 'not_a_map', 12345, 3.14, []]) {
        final report = VGTimelineDualDecoderSyncSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineDualDecoderSyncSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGTimelineDualDecoderSyncSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineDualDecoderSyncSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.raw, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('native UNSUPPORTED status (no AHB/Vulkan path) is unsupported', () {
      final report = VGTimelineDualDecoderSyncSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
        'marker': _failMarker,
        'proofBoundary': _proofBoundary,
        'failureReason':
            'native_crossfade_failed:vulkan_unsupported:vulkan_ahardwarebuffer_extension_missing',
        for (final key in _gateKeys) key: false,
        'argumentValidationOk': true,
        'fixtureFormatOk': true,
        'dualDecoderSetupOk': true,
        'leadInClip0Ok': true,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
        'details': const <String, Object?>{'unsupported': true},
      });
      expect(
        report.decision,
        VGTimelineDualDecoderSyncSmokeDecision.unsupported,
      );
      expect(report.isUnsupported, isTrue);
      expect(report.isFail, isFalse);
      expect(report.setupPass, isTrue);
      expect(report.nativeImportPass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.failureReason, contains('vulkan_unsupported:'));
      expect(report.details['unsupported'], isTrue);
      expect(report.hasFailMarker, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGTimelineDualDecoderSyncSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _gateKeys) key: true,
        'allNativeLanesPass': true,
      });
      expect(report.decision, VGTimelineDualDecoderSyncSmokeDecision.fail);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGTimelineDualDecoderSyncSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGTimelineDualDecoderSyncSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGTimelineDualDecoderSyncSmokeReport.unsupported(
        'missing_plugin',
      );
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.status, 'UNSUPPORTED');
      expect(unsupported.marker, _failMarker);
      expect(unsupported.proofBoundary, _proofBoundary);
      expect(unsupported.failureReason, 'missing_plugin');
      expect(unsupported.allNativeLanesPass, isFalse);
      expect(unsupported.nativeAllLanesPass, isFalse);
      expect(unsupported.isVerifiedPass, isFalse);
      expect(unsupported.gates.length, _gateKeys.length);
      expect(unsupported.details['reason'], 'missing_plugin');

      final harness = VGTimelineDualDecoderSyncSmokeReport.harnessFailure(
        'timeout',
        extraDetails: const {'error': 'x'},
      );
      expect(harness.pass, isFalse);
      expect(harness.isHarnessException, isTrue);
      expect(harness.status, 'FAIL');
      expect(harness.marker, _failMarker);
      expect(harness.proofBoundary, _proofBoundary);
      expect(harness.failureReason, 'timeout');
      expect(harness.details['error'], 'x');
      expect(harness.allNativeLanesPass, isFalse);
      expect(harness.isVerifiedPass, isFalse);
      for (final key in _gateKeys) {
        expect(harness.gates[key], isFalse, reason: key);
      }
    });
  });

  group('VGTimelineDualDecoderSyncSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGTimelineDualDecoderSyncSmokeReport('));
      expect(a.toString(), contains('marker: $_passMarker'));
    });

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'pass': false},
        {'status': 'FAIL'},
        {'marker': 'other'},
        {'proofBoundary': 'other'},
        {'failureReason': 'x'},
        {'overlapPairAcquireOk': false},
        {'resourceReleaseOk': false},
        {'allNativeLanesPass': false},
        {
          'details': <String, Object?>{'k': 'v'},
        },
        {'raw': '{}'},
      ];
      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)), reason: diff.toString());
      }
    });
  });

  group('MethodChannel runner invocation', () {
    test('invokes the exact route with required args only', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_dual_decoder_sync_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report = await _run(channel: channel);

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{'clip0Path': _clip0, 'clip1Path': _clip1}),
      );
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('forwards optional maxFrames / overlapFrames when supplied', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_dual_decoder_sync_opt_args');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      await _run(channel: channel, maxFrames: 24, overlapFrames: 5);

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.arguments,
        equals(<String, Object?>{
          'clip0Path': _clip0,
          'clip1Path': _clip1,
          'maxFrames': 24,
          'overlapFrames': 5,
        }),
      );
    });

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report = await _run();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(capturedCall!.arguments, isA<Map<Object?, Object?>>());
      expect(report.pass, isTrue);
    });

    test('locally invalid arguments never reach the channel', () async {
      var invocations = 0;
      const channel = MethodChannel('test_dual_decoder_sync_local_invalid');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        invocations++;
        return _createSampleRawMap();
      });

      final emptyClip0 = await _run(channel: channel, clip0Path: '   ');
      expect(emptyClip0.isHarnessException, isTrue);
      expect(emptyClip0.failureReason, 'invalid_argument:clip0Path_empty');
      expect(emptyClip0.isVerifiedPass, isFalse);

      final emptyClip1 = await _run(channel: channel, clip1Path: '');
      expect(emptyClip1.isHarnessException, isTrue);
      expect(emptyClip1.failureReason, 'invalid_argument:clip1Path_empty');

      final zeroMax = await _run(channel: channel, maxFrames: 0);
      expect(zeroMax.isHarnessException, isTrue);
      expect(zeroMax.failureReason, 'invalid_argument:maxFrames_not_positive');
      expect(zeroMax.details['maxFrames'], 0);

      final negativeOverlap = await _run(channel: channel, overlapFrames: -1);
      expect(negativeOverlap.isHarnessException, isTrue);
      expect(
        negativeOverlap.failureReason,
        'invalid_argument:overlapFrames_not_positive',
      );
      expect(negativeOverlap.details['overlapFrames'], -1);

      expect(invocations, 0);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_missing');
      // No handler registered -> MissingPluginException.
      final report = await _run(channel: channel);
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'UNAVAILABLE platform exception yields an unsupported report',
      () async {
        const channel = MethodChannel('test_dual_decoder_sync_unavail');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'UNAVAILABLE',
            message: 'no coordinator',
          );
        });
        final report = await _run(channel: channel);
        expect(report.isUnsupported, isTrue);
        expect(report.failureReason, 'platform_exception:UNAVAILABLE');
        expect(report.isVerifiedPass, isFalse);
      },
    );

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report = await _run(channel: channel);
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'platform_exception:NATIVE_CRASH');
      expect(report.details['code'], 'NATIVE_CRASH');
      expect(report.details['message'], 'Simulated');
      expect(report.isVerifiedPass, isFalse);
    });

    test('timeout yields a harnessException report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report = await _run(
        channel: channel,
        timeout: const Duration(milliseconds: 20),
      );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isVerifiedPass, isFalse);
    });

    test('generic exception yields a harnessException report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report = await _run(channel: channel);
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      // The test messenger surfaces handler throws as a PlatformException
      // with code 'error'; a raw Dart throw maps to 'exception:'.
      expect(
        report.failureReason,
        anyOf(startsWith('platform_exception:'), startsWith('exception:')),
      );
      expect(report.isVerifiedPass, isFalse);
    });

    test('non-map native result yields a harnessException report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_nonmap');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'status=PASS';
      });
      final report = await _run(channel: channel);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'native_result_not_a_map');
      expect(report.details['received'], 'status=PASS');
      expect(report.isVerifiedPass, isFalse);
    });

    test('native UNSUPPORTED payload surfaces as unsupported', () async {
      const channel = MethodChannel('test_dual_decoder_sync_unsup');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'UNSUPPORTED',
          'marker': _failMarker,
          'failureReason':
              'native_crossfade_failed:vulkan_unsupported:vulkan_instance_unavailable:-9',
          'nativeImportOk': false,
          'nativeCrossfadeRenderOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report = await _run(channel: channel);
      expect(report.isUnsupported, isTrue);
      expect(report.nativePass, isFalse);
      expect(report.failureReason, contains('vulkan_unsupported:'));
      expect(report.isVerifiedPass, isFalse);
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_dual_decoder_sync_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason':
              'native_crossfade_failed:crossfade_blend_pixel_mismatch',
          'nativeCrossfadeRenderOk': false,
          'resourceReleaseOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report = await _run(channel: channel);
      expect(report.isFail, isTrue);
      expect(report.nativePass, isFalse);
      expect(report.nativeImportPass, isTrue);
      expect(report.lifecyclePass, isFalse);
      expect(report.syncPass, isTrue);
      expect(
        report.failureReason,
        'native_crossfade_failed:crossfade_blend_pixel_mismatch',
      );
      expect(report.hasFailMarker, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });

    test('coordinator argument rejection is a fail-shaped report', () async {
      const channel = MethodChannel('test_dual_decoder_sync_coord_reject');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'proofBoundary': _proofBoundary,
          'failureReason': 'invalid_argument:clip0_path_not_readable',
          for (final key in _gateKeys) key: false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
          'details': const <String, Object?>{
            'reason': 'invalid_argument:clip0_path_not_readable',
          },
          'raw': '',
        };
      });
      final report = await _run(channel: channel);
      expect(report.isFail, isTrue);
      expect(report.argumentValidationPass, isFalse);
      expect(report.failureReason, startsWith('invalid_argument:'));
      expect(report.hasFailMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
