// vg_multicam_spatial_vulkan_render_smoke.dart
// vanguard_media_engine - P3-MULTICAM-NODE (sub-slice SPATIAL-VULKAN-RENDER):
// Android True-DAG VulkanMultiCamSpatialCompositor two-texture layout raster/readback
// diagnostic smoke foundation.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke` MethodChannel route.
// Diagnostic-only -- validates that the private native Vulkan spatial helper
// fails closed on invalid parameters/rectangles, rasterizes compositor-owned
// top/bottom split, left/right split, PiP top-left, and PiP free-floating layouts
// (from ComputeMultiCamLayout) as well as partial coverage into the expected
// offscreen pixel ownership using the existing AOT passthrough SPIR-V, and
// releases every temporary Vulkan object.
// No camera open, no GLES, no OES/AHardwareBuffer import, no opacity, no corner
// radius, no recording, no export, no production VulkanBackend mutation, and
// no product/editor UI. A device without a usable Vulkan driver reports
// `UNSUPPORTED` rather than crashing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 3 MultiCam spatial Vulkan render smoke
/// harness.
enum VGMultiCamSpatialVulkanRenderSmokeDecision {
  /// All native Vulkan spatial composite assertions and readback checks passed.
  pass,

  /// One or more native spatial Vulkan gates failed.
  fail,

  /// The route is not available on this platform/plugin build, or the device
  /// has no usable Vulkan driver.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGMultiCamSpatialVulkanRenderSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException;
    }
    for (final value in VGMultiCamSpatialVulkanRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGMultiCamSpatialVulkanRenderSmokeReport {
  const VGMultiCamSpatialVulkanRenderSmokeReport({
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.gates,
    required this.nativeAllLanesPass,
    required this.details,
    required this.raw,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'native_multicam_spatial_vulkan_two_texture_layout_render_readback_only_no_gles_no_camera_no_oes_no_opacity_no_corner_radius_no_recording_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_FAIL';

  /// Setup gate keys (Vulkan scratch context & synthetic image creation).
  static const List<String> setupGateKeys = <String>[
    'vulkanSetupOk',
    'syntheticImportOk',
  ];

  /// Parameter validation gate keys (fail-closed, no Vulkan objects created).
  static const List<String> paramValidationGateKeys = <String>[
    'invalidArgumentRejectedOk',
    'invalidRectRejectedOk',
  ];

  /// Spatial layout composite render gate keys.
  static const List<String> spatialLayoutGateKeys = <String>[
    'topBottomSplitOk',
    'leftRightSplitOk',
    'pipTopLeftOk',
    'pipFreeFloatingOk',
    'partialCoverageSentinelOk',
  ];

  /// Resource lifecycle gate keys (helper temporaries released, diagnostic
  /// Vulkan objects destroyed after a device drain).
  static const List<String> resourceLifecycleGateKeys = <String>[
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// All gate keys in native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...paramValidationGateKeys,
    ...spatialLayoutGateKeys,
    ...resourceLifecycleGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGMultiCamSpatialVulkanRenderSmokeDecision decision;

  /// Raw status string (`PASS`, `FAIL`, `UNSUPPORTED`, ...).
  final String status;

  /// PASS/FAIL marker string emitted by the native harness.
  final String marker;

  /// Proof boundary string proving execution of the verified harness.
  final String proofBoundary;

  /// First failure reason reported by the native harness, empty on pass.
  final String failureReason;

  /// Per-gate boolean results keyed by gate name.
  final Map<String, bool> gates;

  /// Native aggregate flag (`allNativeLanesPass`, mirrored as
  /// `nativeAllLanesPass` by the native harness).
  final bool nativeAllLanesPass;

  /// Free-form diagnostic details emitted by the native harness (device
  /// name/API version, per-layout probe RGB values, checksums, mismatch counts,
  /// helper temporary-object counts).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ---- Setup & Import ------------------------------------------------------

  /// Whether the temporary Vulkan device, queue, and command pool were initialized.
  bool get vulkanSetupPass => _gate('vulkanSetupOk');

  /// Whether synthetic sampled images, color attachment, and readback buffer were created.
  bool get syntheticImportPass => _gate('syntheticImportOk');

  /// Whether all setup and synthetic import gates passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ---- Parameter Validation ------------------------------------------------

  /// Whether null handles, zero dimensions, and undersized readback buffers were rejected.
  bool get invalidArgumentRejectedPass => _gate('invalidArgumentRejectedOk');

  /// Whether out-of-bounds, negative, zero-size, or overflowing layout rects were rejected.
  bool get invalidRectRejectedPass => _gate('invalidRectRejectedOk');

  /// Whether all parameter validation gates passed.
  bool get paramValidationPass => paramValidationGateKeys.every(_gate);

  // ---- Spatial Layouts -----------------------------------------------------

  /// Whether top/bottom split layout render and readback pixel ownership assertions passed.
  bool get topBottomSplitPass => _gate('topBottomSplitOk');

  /// Whether left/right split layout render and readback pixel ownership assertions passed.
  bool get leftRightSplitPass => _gate('leftRightSplitOk');

  /// Whether top-left PiP layout render and readback pixel ownership assertions passed.
  bool get pipTopLeftPass => _gate('pipTopLeftOk');

  /// Whether free-floating PiP layout render and readback pixel ownership assertions passed.
  bool get pipFreeFloatingPass => _gate('pipFreeFloatingOk');

  /// Whether partial coverage clear sentinel check passed without scissor bleed.
  bool get partialCoverageSentinelPass => _gate('partialCoverageSentinelOk');

  /// Whether all spatial layout render gates passed.
  bool get spatialLayoutPass => spatialLayoutGateKeys.every(_gate);

  // ---- Resource Lifecycle --------------------------------------------------

  /// Whether the helper released exactly as many temporary Vulkan objects as
  /// it created (and created none on validation-only failure paths).
  bool get helperResourcesReleasedPass => _gate('helperResourcesReleasedOk');

  /// Whether the diagnostic drained its device and nulled every Vulkan handle
  /// it owned during teardown.
  bool get diagnosticTeardownPass => _gate('diagnosticTeardownOk');

  /// Whether all resource lifecycle gates passed.
  bool get resourceLifecyclePass => resourceLifecycleGateKeys.every(_gate);

  // ---- Aggregates ----------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every native diagnostic gate passed (computed Dart-side from
  /// [gates], independent of [nativeAllLanesPass]).
  bool get allNativeLanesPass => allGateKeys.every(_gate);

  /// Full verified pass: native pass flag, every gate, native aggregate,
  /// canonical PASS marker, canonical proof boundary, and empty failure reason
  /// all agree.
  bool get isVerifiedPass =>
      pass &&
      isPass &&
      allNativeLanesPass &&
      nativeAllLanesPass &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.pass].
  bool get isPass =>
      decision == VGMultiCamSpatialVulkanRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.fail].
  bool get isFail =>
      decision == VGMultiCamSpatialVulkanRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException;

  // ---- Constructors for synthesized reports --------------------------------

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGMultiCamSpatialVulkanRenderSmokeReport.unsupported(String reason) {
    return VGMultiCamSpatialVulkanRenderSmokeReport(
      pass: false,
      decision: VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      nativeAllLanesPass: false,
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
    );
  }

  /// A fail-shaped report for a harness-level failure (timeout, exception,
  /// malformed native payload).
  factory VGMultiCamSpatialVulkanRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGMultiCamSpatialVulkanRenderSmokeReport(
      pass: false,
      decision: VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      nativeAllLanesPass: false,
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        ...extraDetails,
      }),
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
    );
  }

  static bool _truthy(Object? value) =>
      value == true || (value is String && value == 'true');

  /// Parses a report from the raw native map. Defensive against non-map,
  /// missing, or malformed fields.
  static VGMultiCamSpatialVulkanRenderSmokeReport fromMap(Object? raw) {
    if (raw is! Map) {
      return VGMultiCamSpatialVulkanRenderSmokeReport.harnessFailure(
        'native_result_not_a_map',
        extraDetails: <String, Object?>{'received': raw?.toString() ?? ''},
      );
    }

    final pass = raw['pass'] as bool? ?? false;
    final status = (raw['status'] as String?) ?? (pass ? 'PASS' : 'FAIL');
    final marker = (raw['marker'] as String?) ?? '';
    final proofBoundary = (raw['proofBoundary'] as String?) ?? '';
    final failureReason = (raw['failureReason'] as String?) ?? '';
    final rawString = (raw['raw'] as String?) ?? '';

    final gates = <String, bool>{};
    for (final key in allGateKeys) {
      gates[key] = _truthy(raw[key]);
    }

    // Native emits both spellings with the same value; accept either.
    final nativeAllLanesPass = raw.containsKey('allNativeLanesPass')
        ? _truthy(raw['allNativeLanesPass'])
        : _truthy(raw['nativeAllLanesPass']);

    final detailsRaw = raw['details'];
    final details = <String, Object?>{};
    if (detailsRaw is Map) {
      for (final entry in detailsRaw.entries) {
        final k = entry.key?.toString();
        if (k != null) {
          details[k] = entry.value;
        }
      }
    }

    final decision = pass
        ? VGMultiCamSpatialVulkanRenderSmokeDecision.pass
        : _decisionFromStatus(status, raw['decision']);

    return VGMultiCamSpatialVulkanRenderSmokeReport(
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      gates: Map<String, bool>.unmodifiable(gates),
      nativeAllLanesPass: nativeAllLanesPass,
      details: Map<String, Object?>.unmodifiable(details),
      raw: rawString,
    );
  }

  static VGMultiCamSpatialVulkanRenderSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGMultiCamSpatialVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGMultiCamSpatialVulkanRenderSmokeDecision.fail;
    }
    return VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException;
  }

  /// Serializes the report back to a map (round-trips through [fromMap]).
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'decision': decision.name,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      for (final key in allGateKeys) key: gates[key] == true,
      'allNativeLanesPass': nativeAllLanesPass,
      'nativeAllLanesPass': nativeAllLanesPass,
      'details': Map<String, Object?>.from(details),
      'raw': raw,
    };
  }

  static const String _method =
      'runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 3 MultiCam VulkanMultiCamSpatialCompositor
  /// two-texture layout diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.harnessException] report
  /// on timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields an
  /// [VGMultiCamSpatialVulkanRenderSmokeDecision.unsupported] report; any
  /// other error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiCamSpatialVulkanRenderSmokeReport>
  runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGMultiCamSpatialVulkanRenderSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGMultiCamSpatialVulkanRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGMultiCamSpatialVulkanRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGMultiCamSpatialVulkanRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGMultiCamSpatialVulkanRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGMultiCamSpatialVulkanRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGMultiCamSpatialVulkanRenderSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        mapEquals(other.gates, gates) &&
        other.nativeAllLanesPass == nativeAllLanesPass &&
        mapEquals(other.details, details) &&
        other.raw == raw;
  }

  @override
  int get hashCode => Object.hash(
    pass,
    decision,
    status,
    marker,
    proofBoundary,
    failureReason,
    _stableMapHash(gates),
    nativeAllLanesPass,
    _stableMapHash(details),
    raw,
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGMultiCamSpatialVulkanRenderSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'nativeAllLanesPass: $nativeAllLanesPass, '
      'details: $details)';
}
