// vg_duet_camera_session_test.dart
// vanguard_media_engine - P3-CAM-DUET-SESSION-ADMISSION-ROUTE: Pure Dart unit
// tests for VGDuetCameraSession / VGDuetCameraSessionLauncher using a mock
// method channel and an injectable fake capability evaluator. No Flutter
// engine or native code required.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// -----------------------------------------------------------------------------
// Mock channel harness (mirrors vg_camera_session_test.dart exactly)
// -----------------------------------------------------------------------------

final List<MethodCall> _log = [];
final Map<String, Object?> _responses = {};

void _installMock() {
  _log.clear();
  _responses.clear();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('vanguard_media_engine'), (
        MethodCall call,
      ) async {
        _log.add(call);
        return _responses[call.method];
      });
}

void _removeMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        null,
      );
}

int _callCount(String name) => _log.where((c) => c.method == name).length;

// -----------------------------------------------------------------------------
// Fake evaluator -- always returns the injected policy, ignoring the flag.
// -----------------------------------------------------------------------------

class _FixedPolicyEvaluator extends VGDuetDualCameraCapabilityEvaluator {
  _FixedPolicyEvaluator(this.policy);

  final VGDuetDualCameraCapabilityPolicy policy;

  @override
  Future<VGDuetDualCameraCapabilityPolicy> evaluateDevicePolicy({
    bool allowDiagnosticSyntheticMode = false,
    MethodChannel? channel,
  }) async {
    return policy;
  }
}

// -----------------------------------------------------------------------------
// Fixture policies
// -----------------------------------------------------------------------------

const _blockedPolicy = VGDuetDualCameraCapabilityPolicy(
  decision: VGDuetDualCameraCapabilityDecision.blocked,
  reasons: <String>['no_camera'],
  diagnostics: <String, Object?>{},
  isProductionVisible: false,
  isProductionRealDualCamera: false,
  isDiagnosticSyntheticMode: false,
  isPhysicalDualCamera: false,
);

const _productionHiddenPolicy = VGDuetDualCameraCapabilityPolicy(
  decision:
      VGDuetDualCameraCapabilityDecision.productionHiddenSingleCameraFallback,
  reasons: <String>['no_concurrent_camera_combination'],
  diagnostics: <String, Object?>{},
  isProductionVisible: false,
  isProductionRealDualCamera: false,
  isDiagnosticSyntheticMode: false,
  isPhysicalDualCamera: false,
  selectedPrimaryCameraId: '0',
);

const _diagnosticPolicy = VGDuetDualCameraCapabilityPolicy(
  decision: VGDuetDualCameraCapabilityDecision.diagnosticSyntheticSingleCamera,
  reasons: <String>['diagnostic_synthetic_single_camera_enabled'],
  diagnostics: <String, Object?>{},
  isProductionVisible: false,
  isProductionRealDualCamera: false,
  isDiagnosticSyntheticMode: true,
  isPhysicalDualCamera: false,
  selectedPrimaryCameraId: '0',
);

const _productionRealPolicy = VGDuetDualCameraCapabilityPolicy(
  decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
  reasons: <String>['duet_real_concurrent_hardware_validated'],
  diagnostics: <String, Object?>{},
  isProductionVisible: true,
  isProductionRealDualCamera: true,
  isDiagnosticSyntheticMode: false,
  isPhysicalDualCamera: true,
  selectedPrimaryCameraId: '0',
  selectedSecondaryCameraId: '1',
);

const _productionRealPolicyMissingIds = VGDuetDualCameraCapabilityPolicy(
  decision: VGDuetDualCameraCapabilityDecision.productionRealDualCamera,
  reasons: <String>['duet_real_concurrent_hardware_validated'],
  diagnostics: <String, Object?>{},
  isProductionVisible: true,
  isProductionRealDualCamera: true,
  isDiagnosticSyntheticMode: false,
  isPhysicalDualCamera: true,
);

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_installMock);
  tearDown(_removeMock);

  group('VGDuetCameraSessionLauncher fail-closed admission', () {
    test(
      'blocked policy returns null and never calls startCamera or startMultiCamPreview',
      () async {
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_blockedPolicy),
        );

        final session = await launcher.startSession();

        expect(session, isNull);
        expect(_callCount('startCamera'), equals(0));
        expect(_callCount('startMultiCamPreview'), equals(0));
      },
    );

    test(
      'productionHiddenSingleCameraFallback policy returns null and never calls startCamera or startMultiCamPreview',
      () async {
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionHiddenPolicy),
        );

        final session = await launcher.startSession();

        expect(session, isNull);
        expect(_callCount('startCamera'), equals(0));
        expect(_callCount('startMultiCamPreview'), equals(0));
      },
    );

    test(
      'blocked/productionHidden fail closed even when allowDiagnosticSyntheticMode is true',
      () async {
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionHiddenPolicy),
        );

        final session = await launcher.startSession(
          allowDiagnosticSyntheticMode: true,
        );

        expect(session, isNull);
        expect(_callCount('startCamera'), equals(0));
        expect(_callCount('startMultiCamPreview'), equals(0));
      },
    );
  });

  group('VGDuetCameraSessionLauncher diagnostic synthetic admission', () {
    test(
      'diagnosticSyntheticSingleCamera policy invokes startCamera once and returns a strictly non-physical wrapper',
      () async {
        _responses['startCamera'] = 9;
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_diagnosticPolicy),
        );

        final session = await launcher.startSession(
          allowDiagnosticSyntheticMode: true,
        );

        expect(session, isNotNull);
        expect(_callCount('startCamera'), equals(1));
        expect(_callCount('startMultiCamPreview'), equals(0));
        expect(session!.textureId, equals(9));
        expect(session.isDiagnosticSyntheticMode, isTrue);
        expect(session.isPhysicalDualCamera, isFalse);
        expect(session.isProductionRealDualCamera, isFalse);
        expect(session.policy.isProductionVisible, isFalse);
        expect(session.singleCameraSession, isNotNull);
        expect(session.multiCamSession, isNull);
      },
    );

    test(
      'dispose calls stopCamera exactly once even when dispose is called repeatedly',
      () async {
        _responses['startCamera'] = 3;
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_diagnosticPolicy),
        );

        final session = await launcher.startSession(
          allowDiagnosticSyntheticMode: true,
        );

        await session!.dispose();
        await session.dispose();
        await session.dispose();

        expect(_callCount('stopCamera'), equals(1));
        expect(_callCount('startMultiCamPreview'), equals(0));
        expect(_callCount('stopMultiCamPreview'), equals(0));
      },
    );

    test(
      'diagnostic single-camera create failure returns null without leaking state',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('vanguard_media_engine'),
              (MethodCall call) async {
                _log.add(call);
                if (call.method == 'startCamera') {
                  throw PlatformException(code: 'NO_CAMERA_PERMISSION');
                }
                return _responses[call.method];
              },
            );

        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_diagnosticPolicy),
        );

        final session = await launcher.startSession(
          allowDiagnosticSyntheticMode: true,
        );

        expect(session, isNull);
        expect(_callCount('startCamera'), equals(1));
        expect(_callCount('stopCamera'), equals(0));
      },
    );
  });

  group('VGDuetCameraSessionLauncher production real dual-camera admission', () {
    test(
      'productionRealDualCamera policy with missing selected camera IDs returns null without calling startMultiCamPreview',
      () async {
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionRealPolicyMissingIds),
        );

        final session = await launcher.startSession();

        expect(session, isNull);
        expect(_callCount('startMultiCamPreview'), equals(0));
        expect(_callCount('startCamera'), equals(0));
      },
    );

    test(
      'productionRealDualCamera policy does not claim success when native startMultiCamPreview returns null',
      () async {
        // No 'startMultiCamPreview' response configured -> mock returns null,
        // matching the real Android gap (native handler absent).
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionRealPolicy),
        );

        final session = await launcher.startSession();

        expect(session, isNull);
        expect(_callCount('startMultiCamPreview'), equals(1));
        expect(_callCount('startCamera'), equals(0));
      },
    );

    test(
      'productionRealDualCamera policy does not claim success when native startMultiCamPreview throws',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('vanguard_media_engine'),
              (MethodCall call) async {
                _log.add(call);
                if (call.method == 'startMultiCamPreview') {
                  throw PlatformException(code: 'CAMERA_ACTIVE');
                }
                return _responses[call.method];
              },
            );

        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionRealPolicy),
        );

        final session = await launcher.startSession();

        expect(session, isNull);
        expect(_callCount('startMultiCamPreview'), equals(1));
      },
    );

    test(
      'productionRealDualCamera policy with a valid multiCamSession returns wrapper with strictly true flags and dispose calls stopMultiCamPreview once and is idempotent',
      () async {
        _responses['startMultiCamPreview'] = <Object?, Object?>{
          'textureId': 42,
          'outputWidth': 1080,
          'outputHeight': 1920,
        };
        final launcher = VGDuetCameraSessionLauncher(
          evaluator: _FixedPolicyEvaluator(_productionRealPolicy),
        );

        final session = await launcher.startSession();

        expect(session, isNotNull);
        expect(_callCount('startMultiCamPreview'), equals(1));
        expect(_callCount('startCamera'), equals(0));
        expect(session!.textureId, equals(42));
        expect(session.isPhysicalDualCamera, isTrue);
        expect(session.isProductionRealDualCamera, isTrue);
        expect(session.isDiagnosticSyntheticMode, isFalse);
        expect(session.multiCamSession, isNotNull);
        expect(session.singleCameraSession, isNull);

        await session.dispose();
        await session.dispose();

        expect(_callCount('stopMultiCamPreview'), equals(1));
        expect(_callCount('stopCamera'), equals(0));
      },
    );
  });
}
