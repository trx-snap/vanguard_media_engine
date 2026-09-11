// vg_duet_vulkan_pixel_proof_smoke.dart
// vanguard_media_engine — DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: Android
// VulkanGreenScreenCompositor synthetic mask-blend pixel proof diagnostic.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDuetVulkanPixelProofSmoke` MethodChannel route.
// Diagnostic-only — validates that the private native Vulkan green-screen
// helper creates its own temporary Vulkan device, uploads synthetic
// background/foreground RGBA8 images and a smaller-resolution R8 mask image,
// fails closed on invalid target/image/mask input before any Vulkan object is
// created, blends alpha 0 (exact background), alpha 255 (exact foreground)
// and fractional alpha (true blend) pixels matching the pure CPU reference
// within the pinned tolerance, releases every temporary Vulkan object, and
// tears itself down. No camera, no decode, no export session, no production
// VulkanBackend mutation, and no production Duet preview/export route. A
// device without a usable Vulkan driver reports status `UNSUPPORTED`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Duet Vulkan green-screen pixel proof
/// smoke harness.
enum VGDuetVulkanPixelProofSmokeDecision {
  /// All native Vulkan green-screen pixel proof gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build, or the device
  /// has no usable Vulkan driver.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGDuetVulkanPixelProofSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGDuetVulkanPixelProofSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGDuetVulkanPixelProofSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGDuetVulkanPixelProofSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGDuetVulkanPixelProofSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGDuetVulkanPixelProofSmokeDecision.harnessException;
    }
    for (final value in VGDuetVulkanPixelProofSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGDuetVulkanPixelProofSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGDuetVulkanPixelProofSmokeReport.runAndroidDuetVulkanPixelProofSmoke],
/// mirroring the native harness's JSON result map.
@immutable
class VGDuetVulkanPixelProofSmokeReport {
  const VGDuetVulkanPixelProofSmokeReport({
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
      'native_vulkan_duet_greenscreen_mask_blend_pixel_proof_synthetic_only_no_camera_no_decode_no_export_no_product';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_FAIL';

  /// Setup gate keys: temporary Vulkan device readiness.
  static const List<String> setupGateKeys = <String>['vulkanCoreReady'];

  /// Synthetic resource upload gate keys (background/foreground/mask images,
  /// offscreen attachment, readback buffer).
  static const List<String> uploadGateKeys = <String>['maskUploadOk'];

  /// Mask-resolution-mismatch + full-image CPU reference parity gate keys.
  static const List<String> parityGateKeys = <String>[
    'maskResolutionMismatchOk',
    'cpuReferenceParityOk',
  ];

  /// Per-alpha-region blend gate keys (alpha 0 / alpha 255 / fractional).
  static const List<String> alphaGateKeys = <String>[
    'alphaZeroPreservesBackgroundOk',
    'alphaFullForegroundOk',
    'alphaFractionalBlendOk',
  ];

  /// Pinned color/format contract + fail-closed validation gate keys.
  static const List<String> contractGateKeys = <String>[
    'colorContractPinnedOk',
  ];

  /// Capability reporting / graceful-fallback gate keys.
  static const List<String> capabilityGateKeys = <String>[
    'capabilityFallbackReportedOk',
  ];

  /// Resource lifecycle / teardown gate keys.
  static const List<String> cleanupGateKeys = <String>['cleanupOk'];

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// All gate keys in exact native emission order.
  static const List<String> allGateKeys = <String>[
    ...setupGateKeys,
    ...uploadGateKeys,
    ...parityGateKeys,
    ...alphaGateKeys,
    ...contractGateKeys,
    ...capabilityGateKeys,
    ...cleanupGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGDuetVulkanPixelProofSmokeDecision decision;

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
  /// name/API version/driver version, output/mask dimensions, color
  /// tolerance, shader source, color contract, blend formula, mismatch
  /// count, first mismatch).
  final Map<String, Object?> details;

  /// Raw JSON string returned by the native C++ smoke function.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Whether the temporary Vulkan device/queue/command pool were created.
  bool get vulkanCoreReadyPass => _gate('vulkanCoreReady');

  /// Whether the setup lane passed.
  bool get setupPass => setupGateKeys.every(_gate);

  // ── Synthetic resource upload ───────────────────────────────────────────

  /// Whether the synthetic background/foreground/mask sampled images, the
  /// offscreen color attachment, and the readback buffer were created and
  /// uploaded.
  bool get maskUploadPass => _gate('maskUploadOk');

  /// Whether the upload lane passed.
  bool get uploadPass => uploadGateKeys.every(_gate);

  // ── Mask resolution + CPU reference parity ──────────────────────────────

  /// Whether the mask resolution (17x19) differed from the output resolution
  /// (64x48) and the blend still matched the CPU reference everywhere.
  bool get maskResolutionMismatchPass => _gate('maskResolutionMismatchOk');

  /// Whether every output pixel matched the pure CPU reference within the
  /// pinned tolerance.
  bool get cpuReferenceParityPass => _gate('cpuReferenceParityOk');

  /// Whether every parity gate passed.
  bool get parityPass => parityGateKeys.every(_gate);

  // ── Alpha region blend ───────────────────────────────────────────────────

  /// Whether pixels mapped to mask alpha 0 exactly reproduced the background.
  bool get alphaZeroPreservesBackgroundPass =>
      _gate('alphaZeroPreservesBackgroundOk');

  /// Whether pixels mapped to mask alpha 255 exactly reproduced the
  /// foreground.
  bool get alphaFullForegroundPass => _gate('alphaFullForegroundOk');

  /// Whether pixels mapped to a fractional mask alpha were a true blend
  /// (matching the CPU reference, and equal to neither pure background nor
  /// pure foreground).
  bool get alphaFractionalBlendPass => _gate('alphaFractionalBlendOk');

  /// Whether every alpha-region gate passed.
  bool get alphaPass => alphaGateKeys.every(_gate);

  // ── Pinned color/format contract ────────────────────────────────────────

  /// Whether the pinned RGBA8_UNORM/R8_UNORM format constants and tolerance
  /// matched, and the helper's fail-closed input validation rejected every
  /// bad target/image/mask-size case before creating any Vulkan object.
  bool get colorContractPinnedPass => _gate('colorContractPinnedOk');

  /// Whether every contract gate passed.
  bool get contractPass => contractGateKeys.every(_gate);

  // ── Capability reporting ─────────────────────────────────────────────────

  /// Whether the harness honestly reported device capability facts when a
  /// Vulkan device was found, or a non-empty fallback reason when the device
  /// was reported `UNSUPPORTED`.
  bool get capabilityFallbackReportedPass =>
      _gate('capabilityFallbackReportedOk');

  /// Whether every capability gate passed.
  bool get capabilityPass => capabilityGateKeys.every(_gate);

  // ── Resource lifecycle & teardown ───────────────────────────────────────

  /// Whether the helper released exactly as many temporary Vulkan objects as
  /// it created, the diagnostic drained its device before destruction, and
  /// every owned Vulkan handle was nulled.
  bool get cleanupPass => _gate('cleanupOk');

  /// Whether every cleanup gate passed.
  bool get resourceLifecyclePass => cleanupGateKeys.every(_gate);

  // ── Canonical route ───────────────────────────────────────────────────────

  /// Whether the canonical route ran against the owned Vulkan target with no
  /// lane skipped or substituted.
  bool get canonicalPass => _gate('canonical');

  /// Semantic alias for canonical pass.
  bool get canonical => canonicalPass;

  // ── Aggregates ────────────────────────────────────────────────────────────

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every native diagnostic gate passed (computed Dart-side from
  /// [gates], independent of [nativeAllLanesPass]).
  bool get allNativeLanesPass => allGateKeys.every(_gate);

  /// Full verified pass: requires pass true, decision pass, proofBoundary
  /// exact, marker exact, nativeAllLanesPass true, all gate keys true, and
  /// canonical true.
  bool get isPass =>
      pass &&
      decision == VGDuetVulkanPixelProofSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      nativeAllLanesPass &&
      allNativeLanesPass &&
      canonicalPass;

  /// Semantic alias for [isPass] matching diagnostic suite conventions.
  bool get isVerifiedPass => isPass;

  /// Convenience getter for whether [decision] is
  /// [VGDuetVulkanPixelProofSmokeDecision.fail].
  bool get isFail => decision == VGDuetVulkanPixelProofSmokeDecision.fail;

  /// Convenience getter for whether [decision] is
  /// [VGDuetVulkanPixelProofSmokeDecision.unsupported].
  bool get isUnsupported =>
      decision == VGDuetVulkanPixelProofSmokeDecision.unsupported;

  /// Convenience getter for whether [decision] is
  /// [VGDuetVulkanPixelProofSmokeDecision.harnessException].
  bool get isHarnessException =>
      decision == VGDuetVulkanPixelProofSmokeDecision.harnessException;

  // ── Constructors for synthesized reports ──────────────────────────────────

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform or
  /// a device without a usable Vulkan driver.
  factory VGDuetVulkanPixelProofSmokeReport.unsupported(String reason) {
    return VGDuetVulkanPixelProofSmokeReport(
      pass: false,
      decision: VGDuetVulkanPixelProofSmokeDecision.unsupported,
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
  factory VGDuetVulkanPixelProofSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGDuetVulkanPixelProofSmokeReport(
      pass: false,
      decision: VGDuetVulkanPixelProofSmokeDecision.harnessException,
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

  /// Parses a report from the raw native map or JSON string. Defensive
  /// against non-map, non-JSON, missing, or malformed fields.
  static VGDuetVulkanPixelProofSmokeReport fromMap(Object? raw) {
    Map<dynamic, dynamic>? map;
    if (raw is Map) {
      map = raw;
    } else if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          map = decoded;
        }
      } catch (_) {
        // Fail closed below.
      }
    }

    if (map == null) {
      return VGDuetVulkanPixelProofSmokeReport.harnessFailure(
        'native_result_not_a_map',
        extraDetails: <String, Object?>{'received': raw?.toString() ?? ''},
      );
    }

    final pass = map['pass'] as bool? ?? false;
    final status = (map['status'] as String?) ?? (pass ? 'PASS' : 'FAIL');
    final marker = (map['marker'] as String?) ?? '';
    final proofBoundary = (map['proofBoundary'] as String?) ?? '';
    final failureReason = (map['failureReason'] as String?) ?? '';
    final rawString = raw is String ? raw : ((map['raw'] as String?) ?? '');

    final gates = <String, bool>{};
    for (final key in allGateKeys) {
      gates[key] = _truthy(map[key]);
    }

    // Native emits both spellings with the same value; accept either.
    final nativeAllLanesPass = map.containsKey('allNativeLanesPass')
        ? _truthy(map['allNativeLanesPass'])
        : _truthy(map['nativeAllLanesPass']);

    final detailsRaw = map['details'];
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
        ? VGDuetVulkanPixelProofSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGDuetVulkanPixelProofSmokeReport(
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

  static VGDuetVulkanPixelProofSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGDuetVulkanPixelProofSmokeDecision.fromRaw(explicitDecision);
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGDuetVulkanPixelProofSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGDuetVulkanPixelProofSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      // pass == false with a PASS status is a contradictory native payload;
      // treat it as a plain failure rather than trusting the status string.
      return VGDuetVulkanPixelProofSmokeDecision.fail;
    }
    return VGDuetVulkanPixelProofSmokeDecision.harnessException;
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

  static const String _method = 'runAndroidDuetVulkanPixelProofSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android Duet VulkanGreenScreenCompositor synthetic
  /// mask-blend pixel proof diagnostic smoke harness.
  ///
  /// [timeout] optionally bounds the invocation. If specified, the future is
  /// wrapped in `.timeout(timeout)` and returns a
  /// [VGDuetVulkanPixelProofSmokeDecision.harnessException] report on
  /// timeout.
  ///
  /// A [MissingPluginException] or a [PlatformException] with code
  /// `UNAVAILABLE`/`UNSUPPORTED`/`UNIMPLEMENTED` yields a
  /// [VGDuetVulkanPixelProofSmokeDecision.unsupported] report; any other
  /// error yields a harness-exception report. This method never throws.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGDuetVulkanPixelProofSmokeReport>
  runAndroidDuetVulkanPixelProofSmoke({
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method);
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGDuetVulkanPixelProofSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGDuetVulkanPixelProofSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGDuetVulkanPixelProofSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGDuetVulkanPixelProofSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGDuetVulkanPixelProofSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGDuetVulkanPixelProofSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGDuetVulkanPixelProofSmokeReport &&
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
      'VGDuetVulkanPixelProofSmokeReport('
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
