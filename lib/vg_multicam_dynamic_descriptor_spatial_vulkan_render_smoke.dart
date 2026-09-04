// vg_multicam_dynamic_descriptor_spatial_vulkan_render_smoke.dart
// vanguard_media_engine - P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG diagnostic proving that a caller-supplied Dart layout
// descriptor's primitive fields drive native Vulkan spatial rendering via
// ComputeMultiCamLayout(), mirroring the existing static Vulkan two-texture
// spatial route's synchronous, self-contained-resource shape and the
// existing GLES dynamic-descriptor route's strict
// layoutMode/pipAnchor/splitDirection string resolution policy.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke`
// MethodChannel route. Each invocation sends exactly one
// [VGMultiCamDynamicDescriptorSpatialRenderInput.toMap] descriptor as the
// MethodChannel arguments -- never cornerRadius/opacity, which native
// hard-sets to 0.0/1.0 -- and native creates and destroys its own temporary
// VkInstance/VkDevice/VkQueue/VkCommandPool and synthetic solid red/blue
// RGBA8 sampled images for that single call. A `layoutMode: "pip"`
// descriptor renders a "pip"/anchor render (red primary full canvas, blue
// secondary PiP rect); a `layoutMode: "splitScreen"` descriptor renders a
// split-screen render (red on one side, blue on the other). An unrecognized
// layoutMode/pipAnchor/splitDirection string is rejected before any Vulkan
// object is created -- proven by the `descriptorRejectedBeforeVulkanOk` gate
// and zero/not_run detail entries -- exactly like the GLES sibling route
// fails closed before any AHardwareBuffer import or GLES work begins.
//
// No camera open, no GLES, no OES/AHardwareBuffer import, no opacity, no
// corner radius, no recording, no export, no production VulkanBackend
// mutation, and no product/editor UI. A device without a usable Vulkan
// driver reports `UNSUPPORTED` rather than crashing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_dual_camera_descriptor.dart'
    show
        VGDualCameraLayoutModeExtension,
        VGPiPAnchorExtension,
        VGSplitScreenDirectionExtension;
import 'vg_multicam_dynamic_descriptor_spatial_render_smoke.dart'
    show VGMultiCamDynamicDescriptorSpatialRenderInput;

/// Decision produced by the native Phase 3 MultiCam dynamic-descriptor
/// spatial Vulkan render smoke harness.
enum VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision {
  /// All native descriptor-parse/layout/render/readback assertions passed.
  pass,

  /// One or more native gates failed, including an expected fail-closed
  /// rejection of a malformed/unknown descriptor.
  fail,

  /// The route is not available on this platform/plugin build, or the
  /// device has no usable Vulkan driver.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision fromRaw(
    Object? raw,
  ) {
    if (raw is! String) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .harnessException;
    }
    for (final value
        in VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
        .harnessException;
  }
}

/// Typed report returned by
/// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke],
/// mirroring the native harness's JSON result map for a single caller-
/// supplied descriptor invocation.
///
/// Deliberately reuses [VGMultiCamDynamicDescriptorSpatialRenderInput]'s
/// nested `VGDualCameraLayoutMode`/`VGPiPAnchor`/`VGSplitScreenDirection`
/// value vocabulary (via [expectedFreeFloatingPipLayoutMode] and friends)
/// instead of duplicating those descriptor enums.
@immutable
class VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport {
  const VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport({
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
      'native_multicam_dynamic_descriptor_spatial_vulkan_render_readback_only_no_gles_no_camera_no_oes_no_ahb_no_opacity_no_corner_radius_no_recording_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_FAIL';

  /// The exact descriptor `layoutMode`/`pipAnchor` values a
  /// [VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip]
  /// descriptor resolves to, reused instead of duplicating the string
  /// literals.
  static String get expectedFreeFloatingPipLayoutMode =>
      VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
          .layoutMode
          .value;
  static String get expectedFreeFloatingPipAnchor =>
      VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
          .pipAnchor
          .value;

  /// The exact descriptor `layoutMode`/`splitDirection` values a
  /// [VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit]
  /// descriptor resolves to, reused instead of duplicating the string
  /// literals.
  static String get expectedLeftRightSplitLayoutMode =>
      VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
          .layoutMode
          .value;
  static String get expectedLeftRightSplitDirection =>
      VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
          .splitDirection
          .value;

  /// Descriptor pass gate keys (strict resolution succeeded).
  static const List<String> descriptorPassGateKeys = <String>[
    'descriptorParseOk',
  ];

  /// Descriptor rejection gate keys (fail-closed rejection proven before any
  /// Vulkan scratch context or resource creation).
  static const List<String> descriptorRejectionGateKeys = <String>[
    'descriptorRejectedBeforeVulkanOk',
  ];

  /// Descriptor resolution gate keys: whether the strict
  /// layoutMode/pipAnchor/splitDirection resolution succeeded, and whether a
  /// failed resolution was proven rejected before any Vulkan work began.
  static const List<String> descriptorGateKeys = <String>[
    ...descriptorPassGateKeys,
    ...descriptorRejectionGateKeys,
  ];

  /// Setup gate keys (Vulkan scratch context & synthetic image creation).
  static const List<String> setupGateKeys = <String>[
    'vulkanSetupOk',
    'syntheticImportOk',
  ];

  /// Render gate keys (normalized-to-pixel-rect conversion & render/readback
  /// pixel ownership).
  static const List<String> renderGateKeys = <String>[
    'layoutConvertOk',
    'renderReadbackOk',
  ];

  /// Resource lifecycle gate keys (helper temporaries released, diagnostic
  /// Vulkan objects destroyed after a device drain).
  static const List<String> resourceLifecycleGateKeys = <String>[
    'helperResourcesReleasedOk',
    'diagnosticTeardownOk',
  ];

  /// Gate keys required to pass for a valid descriptor invocation.
  static const List<String> validPassGateKeys = <String>[
    ...descriptorPassGateKeys,
    ...setupGateKeys,
    ...renderGateKeys,
    ...resourceLifecycleGateKeys,
  ];

  /// All gate keys in native emission order.
  static const List<String> allGateKeys = <String>[
    ...descriptorGateKeys,
    ...setupGateKeys,
    ...renderGateKeys,
    ...resourceLifecycleGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision decision;

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
  /// name/API version, resolved descriptor fields, probe RGB values,
  /// checksums, mismatch counts, helper temporary-object counts).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ---- Descriptor resolution -------------------------------------------

  /// Whether native accepted this call's layoutMode/pipAnchor/
  /// splitDirection strings (fails closed for unrecognized values).
  bool get descriptorParseOk => _gate('descriptorParseOk');

  /// Whether a rejected descriptor was proven rejected before
  /// `VulkanScratch::Setup()` or any other Vulkan object/resource was
  /// created. Only meaningful when [descriptorParseOk] is `false`.
  bool get descriptorRejectedBeforeVulkanOk =>
      _gate('descriptorRejectedBeforeVulkanOk');

  // ---- Setup & Import ------------------------------------------------------

  /// Whether the temporary Vulkan device, queue, and command pool were initialized.
  bool get vulkanSetupPass => _gate('vulkanSetupOk');

  /// Whether synthetic sampled images, color attachment, and readback buffer were created.
  bool get syntheticImportPass => _gate('syntheticImportOk');

  /// Whether all setup and synthetic import gates passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ---- Layout conversion & render/readback ----------------------------------

  /// Whether native's normalized-to-pixel-rect layout conversion succeeded.
  bool get layoutConvertPass => _gate('layoutConvertOk');

  /// Whether this call's render and readback pixel ownership assertions passed.
  bool get renderReadbackPass => _gate('renderReadbackOk');

  /// Whether all render gates passed.
  bool get renderPass => renderGateKeys.every(_gate);

  // ---- Resource Lifecycle --------------------------------------------------

  /// Whether the helper released exactly as many temporary Vulkan objects as
  /// it created.
  bool get helperResourcesReleasedOk => _gate('helperResourcesReleasedOk');

  /// Whether the diagnostic drained its device and nulled every Vulkan handle
  /// it owned during teardown.
  bool get diagnosticTeardownOk => _gate('diagnosticTeardownOk');

  /// Whether all resource lifecycle gates passed.
  bool get resourceLifecyclePass => resourceLifecycleGateKeys.every(_gate);

  // ---- Resolved descriptor fields (from [details]) --------------------------

  /// Resolved layoutMode string for this call, or "" if unresolved.
  String get layoutModeResolved =>
      details['layoutModeResolved'] as String? ?? '';

  /// Resolved pipAnchor string for this call, or "" if unresolved.
  String get pipAnchorResolved => details['pipAnchorResolved'] as String? ?? '';

  /// Resolved splitDirection string for this call, or "" if unresolved.
  String get splitDirectionResolved =>
      details['splitDirectionResolved'] as String? ?? '';

  /// Rejection reason reported when the descriptor was rejected, or "" when
  /// [descriptorParseOk] is `true`.
  String get rejectionReason => details['rejectionReason'] as String? ?? '';

  // ---- Aggregates ----------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every native diagnostic gate required for a valid descriptor
  /// pass succeeded (computed Dart-side from [gates], independent of
  /// [nativeAllLanesPass]).
  ///
  /// Evaluates [validPassGateKeys] and requires
  /// [descriptorRejectedBeforeVulkanOk] to be false.
  bool get allNativeLanesPass =>
      validPassGateKeys.every(_gate) && !descriptorRejectedBeforeVulkanOk;

  /// Full verified pass for a well-formed descriptor: native pass flag,
  /// every gate, native aggregate, canonical PASS marker, canonical proof
  /// boundary, and empty failure reason all agree, and the descriptor was
  /// resolved (not rejected).
  bool get isVerifiedPass =>
      pass &&
      isPass &&
      allNativeLanesPass &&
      nativeAllLanesPass &&
      hasPassMarker &&
      hasCanonicalProofBoundary &&
      failureReason.isEmpty &&
      descriptorParseOk &&
      !descriptorRejectedBeforeVulkanOk &&
      vulkanSetupPass &&
      syntheticImportPass &&
      layoutConvertPass &&
      renderReadbackPass &&
      helperResourcesReleasedOk &&
      diagnosticTeardownOk;

  /// Full verified descriptor rejection for a deliberately malformed/unknown
  /// descriptor: the descriptor was rejected before any Vulkan setup or
  /// resource creation, decision is `fail`, and the canonical FAIL marker
  /// and proof boundary are present. No Vulkan setup/render gate is
  /// expected to have run.
  bool get isVerifiedDescriptorRejection =>
      !pass &&
      isFail &&
      !descriptorParseOk &&
      descriptorRejectedBeforeVulkanOk &&
      !vulkanSetupPass &&
      !syntheticImportPass &&
      !layoutConvertPass &&
      !renderReadbackPass &&
      hasFailMarker &&
      !hasPassMarker &&
      hasCanonicalProofBoundary &&
      rejectionReason.isNotEmpty;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass].
  bool get isPass =>
      decision ==
      VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail].
  bool get isFail =>
      decision ==
      VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision ==
      VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision ==
      VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .harnessException;

  // ---- Constructors for synthesized reports --------------------------------

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.unsupported(
    String reason,
  ) {
    return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport(
      pass: false,
      decision: VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .unsupported,
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
  factory VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport(
      pass: false,
      decision: VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .harnessException,
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
  static VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport fromMap(
    Object? raw,
  ) {
    if (raw is! Map) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
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
        ? VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass
        : _decisionFromStatus(status, raw['decision']);

    return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport(
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

  static VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
  _decisionFromStatus(String status, Object? explicitDecision) {
    if (explicitDecision is String) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
          .unsupported;
    }
    if (normalized == 'fail') {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail;
    }
    return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
        .harnessException;
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
      'runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android True-DAG Phase 3 MultiCam dynamic-descriptor
  /// spatial Vulkan render diagnostic smoke harness for [descriptor].
  ///
  /// Sends exactly [descriptor]'s primitive fields (via
  /// [VGMultiCamDynamicDescriptorSpatialRenderInput.toMap]) as the
  /// MethodChannel arguments -- never cornerRadius/opacity. Native is the
  /// sole layout authority: it strictly resolves layoutMode/pipAnchor/
  /// splitDirection and fails closed before any Vulkan work for an
  /// unrecognized value.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.harnessException]
  /// report on timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`unimplemented` yields an
  /// [VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.unsupported]
  /// report; any other error yields a harness-exception report. This method
  /// never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport>
  runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke({
    required VGMultiCamDynamicDescriptorSpatialRenderInput descriptor,
    Duration? timeout,
    MethodChannel? channel,
  }) {
    return _invoke(descriptor.toMap(), timeout: timeout, channel: channel);
  }

  /// Diagnostic-only escape route for exercising the native fail-closed
  /// rejection path with a descriptor shape the typed
  /// [VGMultiCamDynamicDescriptorSpatialRenderInput] model cannot represent
  /// (e.g. an unrecognized `layoutMode` string) in test and physical smoke
  /// harnesses -- that model's `layoutMode` is a real
  /// [VGDualCameraLayoutModeExtension]-backed enum and so can never itself be
  /// malformed. Sends [rawDescriptor] verbatim as the MethodChannel arguments
  /// instead of a validated descriptor's [toMap].
  ///
  /// Does not widen the public descriptor model -- use
  /// [runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke]
  /// with a real descriptor for all non-diagnostic call sites.
  static Future<VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport>
  runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmokeWithRawDescriptor(
    Map<String, Object?> rawDescriptor, {
    Duration? timeout,
    MethodChannel? channel,
  }) {
    return _invoke(rawDescriptor, timeout: timeout, channel: channel);
  }

  static Future<VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport>
  _invoke(
    Map<String, Object?> arguments, {
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, arguments);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
        raw,
      );
    } on TimeoutException catch (te) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport &&
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
      'VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport('
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
