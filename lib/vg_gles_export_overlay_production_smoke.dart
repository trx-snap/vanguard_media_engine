// vg_gles_export_overlay_production_smoke.dart
// vanguard_media_engine - P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A:
// Verification harness for production AndroidTimelineVideoEncoder routing
// GLES overlay compositing via VanguardNativeBridge on caller-current context.
//
// Pure Dart typed model + invocation wrapper over the native
// `runAndroidDagPhase5GlesExportOverlayProductionSmoke` MethodChannel route.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decision produced by the native Phase 5 GLES export overlay production smoke harness.
enum VGGlesExportOverlayProductionSmokeDecision {
  /// All native GLES export overlay production gates passed.
  pass,

  /// One or more native gates failed.
  fail,

  /// The route is not available on this platform/plugin build.
  unsupported,

  /// Unhandled exception in harness or malformed native result.
  harnessException;

  /// Maps a raw status string to the matching enum value, falling back to
  /// [harnessException] for unrecognised/missing values.
  static VGGlesExportOverlayProductionSmokeDecision fromRaw(Object? raw) {
    if (raw is! String) {
      return VGGlesExportOverlayProductionSmokeDecision.harnessException;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'pass') {
      return VGGlesExportOverlayProductionSmokeDecision.pass;
    }
    if (normalized == 'fail') {
      return VGGlesExportOverlayProductionSmokeDecision.fail;
    }
    if (normalized == 'unsupported') {
      return VGGlesExportOverlayProductionSmokeDecision.unsupported;
    }
    if (normalized == 'harnessexception' || normalized == 'harness_exception') {
      return VGGlesExportOverlayProductionSmokeDecision.harnessException;
    }
    for (final value in VGGlesExportOverlayProductionSmokeDecision.values) {
      if (value.name == raw) return value;
    }
    return VGGlesExportOverlayProductionSmokeDecision.harnessException;
  }
}

/// Typed report returned by
/// [VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke],
/// mirroring the native harness's result map.
@immutable
class VGGlesExportOverlayProductionSmokeReport {
  const VGGlesExportOverlayProductionSmokeReport({
    required this.pass,
    required this.decision,
    required this.status,
    required this.marker,
    required this.proofBoundary,
    required this.failureReason,
    required this.gates,
    required this.details,
    required this.raw,
  });

  /// Canonical proof boundary string emitted by the native harness.
  static const String proofBoundaryConstant =
      'production_android_timeline_gles_overlay_export_forced_encoder_route_a';

  /// Canonical PASS marker emitted by the native harness.
  static const String passMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_PASS';

  /// Canonical FAIL marker emitted by the native harness.
  static const String failMarker =
      'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_FAIL';

  /// Setup and input validation gate keys.
  static const List<String> validationGateKeys = <String>[
    'inputValidationOk',
    'sourceMetadataOk',
  ];

  /// Production encode gate keys (baseline and overlay lanes).
  static const List<String> encodeGateKeys = <String>[
    'baselineEncodeOk',
    'overlayEncodeOk',
    'overlayFrameCountOk',
  ];

  /// Pixel proof gate keys (frame extraction and RGB delta assertion).
  static const List<String> pixelGateKeys = <String>[
    'frameExtractOk',
    'pixelDeltaOk',
  ];

  /// Fail-closed rejection gate keys (missing bridge, still-image input).
  static const List<String> failClosedGateKeys = <String>[
    'missingBridgeRejectedOk',
    'stillImageRejectedOk',
  ];

  /// Resource cleanup gate keys.
  static const List<String> cleanupGateKeys = <String>['cleanupOk'];

  /// Canonical route verification gate keys.
  static const List<String> canonicalGateKeys = <String>['canonical'];

  /// All gate keys in exact native emission order.
  static const List<String> allGateKeys = <String>[
    ...validationGateKeys,
    ...encodeGateKeys,
    ...pixelGateKeys,
    ...failClosedGateKeys,
    ...cleanupGateKeys,
    ...canonicalGateKeys,
  ];

  /// Primary success flag emitted by the native harness.
  final bool pass;

  /// The parsed decision.
  final VGGlesExportOverlayProductionSmokeDecision decision;

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

  /// Free-form diagnostic details emitted by the native harness.
  final Map<String, Object?> details;

  /// Raw native result string when available.
  final String raw;

  bool _gate(String key) => gates[key] == true;

  // -- Input validation & metadata gates -------------------------------------

  /// Whether inputs (videoPath, stickerPath, outputDir, nativeBridge) were valid.
  bool get inputValidationPass => _gate('inputValidationOk');

  /// Whether video source metadata (width, height, duration) was valid.
  bool get sourceMetadataPass => _gate('sourceMetadataOk');

  /// Whether every validation/metadata gate passed.
  bool get validationPass => validationGateKeys.every(_gate);

  // -- Encode gates -----------------------------------------------------------

  /// Whether baseline encode without overlays succeeded.
  bool get baselineEncodePass => _gate('baselineEncodeOk');

  /// Whether overlay encode succeeded.
  bool get overlayEncodePass => _gate('overlayEncodeOk');

  /// Whether overlay frame count > 0 was verified.
  bool get overlayFrameCountPass => _gate('overlayFrameCountOk');

  /// Whether every encode gate passed.
  bool get encodeGroupPass => encodeGateKeys.every(_gate);

  // -- Pixel proof gates ------------------------------------------------------

  /// Whether mid-frame bitmaps were extracted from baseline and overlay renders.
  bool get frameExtractPass => _gate('frameExtractOk');

  /// Whether meaningful RGB delta was asserted in the overlay region.
  bool get pixelDeltaPass => _gate('pixelDeltaOk');

  /// Whether every pixel proof gate passed.
  bool get pixelPass => pixelGateKeys.every(_gate);

  // -- Fail-closed rejection gates --------------------------------------------

  /// Whether calling overlay encode with null nativeBridge was rejected.
  bool get missingBridgeRejectedPass => _gate('missingBridgeRejectedOk');

  /// Whether calling overlay encode with still-image clip was rejected.
  bool get stillImageRejectedPass => _gate('stillImageRejectedOk');

  /// Whether every fail-closed rejection gate passed.
  bool get failClosedPass => failClosedGateKeys.every(_gate);

  // -- Cleanup gates ----------------------------------------------------------

  /// Whether every generated output file was deleted.
  bool get cleanupPass => _gate('cleanupOk');

  /// Whether cleanup group passed.
  bool get cleanupGroupPass => cleanupGateKeys.every(_gate);

  // -- Canonical route gates --------------------------------------------------

  /// Whether all canonical gates passed.
  bool get canonicalPass => _gate('canonical');

  /// Semantic alias for canonical pass.
  bool get canonical => canonicalPass;

  // -- Aggregates ------------------------------------------------------------

  /// Whether [proofBoundary] matches the canonical proof boundary constant.
  bool get hasCanonicalProofBoundary => proofBoundary == proofBoundaryConstant;

  /// Whether [marker] equals the canonical PASS marker.
  bool get hasPassMarker => marker == passMarker;

  /// Whether [marker] equals the canonical FAIL marker.
  bool get hasFailMarker => marker == failMarker;

  /// Whether every native diagnostic gate passed.
  bool get allGatesPass => allGateKeys.every(_gate);

  /// Full verified pass.
  bool get isPass =>
      pass &&
      decision == VGGlesExportOverlayProductionSmokeDecision.pass &&
      hasCanonicalProofBoundary &&
      hasPassMarker &&
      allGatesPass &&
      canonicalPass;

  /// Semantic alias for [isPass].
  bool get isVerifiedPass => isPass;

  /// Whether decision is fail.
  bool get isFail =>
      decision == VGGlesExportOverlayProductionSmokeDecision.fail;

  /// Whether decision is unsupported.
  bool get isUnsupported =>
      decision == VGGlesExportOverlayProductionSmokeDecision.unsupported;

  /// Whether decision is harnessException.
  bool get isHarnessException =>
      decision == VGGlesExportOverlayProductionSmokeDecision.harnessException;

  static Map<String, bool> _allFalseGates() => Map<String, bool>.unmodifiable(
    <String, bool>{for (final key in allGateKeys) key: false},
  );

  /// A fail-shaped report for a route that is unavailable on this platform.
  factory VGGlesExportOverlayProductionSmokeReport.unsupported(String reason) {
    return VGGlesExportOverlayProductionSmokeReport(
      pass: false,
      decision: VGGlesExportOverlayProductionSmokeDecision.unsupported,
      status: 'UNSUPPORTED',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
      }),
      raw: '{"pass":false,"status":"UNSUPPORTED","failureReason":"$reason"}',
    );
  }

  /// A fail-shaped report for a harness-level failure.
  factory VGGlesExportOverlayProductionSmokeReport.harnessFailure(
    String reason, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    return VGGlesExportOverlayProductionSmokeReport(
      pass: false,
      decision: VGGlesExportOverlayProductionSmokeDecision.harnessException,
      status: 'FAIL',
      marker: failMarker,
      proofBoundary: proofBoundaryConstant,
      failureReason: reason,
      gates: _allFalseGates(),
      details: Map<String, Object?>.unmodifiable(<String, Object?>{
        'reason': reason,
        ...extraDetails,
      }),
      raw: '{"pass":false,"status":"FAIL","failureReason":"$reason"}',
    );
  }

  static bool _truthy(Object? value) =>
      value == true || (value is String && value == 'true');

  /// Parses a report from the raw native map or JSON string. Defensive against
  /// non-map, non-JSON, missing, or malformed fields.
  static VGGlesExportOverlayProductionSmokeReport fromMap(Object? raw) {
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
      return VGGlesExportOverlayProductionSmokeReport.harnessFailure(
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
        ? VGGlesExportOverlayProductionSmokeDecision.pass
        : _decisionFromStatus(status, map['decision']);

    return VGGlesExportOverlayProductionSmokeReport(
      pass: pass,
      decision: decision,
      status: status,
      marker: marker,
      proofBoundary: proofBoundary,
      failureReason: failureReason,
      gates: Map<String, bool>.unmodifiable(gates),
      details: Map<String, Object?>.unmodifiable(details),
      raw: rawString,
    );
  }

  static VGGlesExportOverlayProductionSmokeDecision _decisionFromStatus(
    String status,
    Object? explicitDecision,
  ) {
    if (explicitDecision is String) {
      return VGGlesExportOverlayProductionSmokeDecision.fromRaw(
        explicitDecision,
      );
    }
    final normalized = status.trim().toLowerCase();
    if (normalized == 'unsupported') {
      return VGGlesExportOverlayProductionSmokeDecision.unsupported;
    }
    if (normalized == 'fail') {
      return VGGlesExportOverlayProductionSmokeDecision.fail;
    }
    if (normalized == 'pass') {
      return VGGlesExportOverlayProductionSmokeDecision.fail;
    }
    return VGGlesExportOverlayProductionSmokeDecision.harnessException;
  }

  /// Serializes the report back to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'decision': decision.name,
      'status': status,
      'marker': marker,
      'proofBoundary': proofBoundary,
      'failureReason': failureReason,
      for (final key in allGateKeys) key: gates[key] == true,
      'details': Map<String, Object?>.from(details),
      'raw': raw,
    };
  }

  static const String _method =
      'runAndroidDagPhase5GlesExportOverlayProductionSmoke';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// MethodChannel route name owned by this smoke.
  static String get methodName => _method;

  /// Invokes the Android Phase 5 GLES export overlay production smoke harness.
  static Future<VGGlesExportOverlayProductionSmokeReport>
  runAndroidDagPhase5GlesExportOverlayProductionSmoke({
    required String videoPath,
    required String stickerPath,
    required String outputDir,
    Duration? timeout,
    MethodChannel? channel,
  }) async {
    final ch = channel ?? _defaultChannel;
    try {
      final future = ch.invokeMethod<Object?>(_method, <String, Object?>{
        'videoPath': videoPath,
        'stickerPath': stickerPath,
        'outputDir': outputDir,
      });
      final raw = timeout != null
          ? await future.timeout(timeout)
          : await future;
      return VGGlesExportOverlayProductionSmokeReport.fromMap(raw);
    } on TimeoutException catch (te) {
      return VGGlesExportOverlayProductionSmokeReport.harnessFailure(
        'timeout',
        extraDetails: <String, Object?>{'error': te.toString()},
      );
    } on MissingPluginException catch (mpe) {
      return VGGlesExportOverlayProductionSmokeReport.unsupported(
        'missing_plugin:${mpe.message ?? ''}',
      );
    } on PlatformException catch (pe) {
      final code = pe.code.trim().toUpperCase();
      if (code == 'UNAVAILABLE' ||
          code == 'UNSUPPORTED' ||
          code == 'UNIMPLEMENTED') {
        return VGGlesExportOverlayProductionSmokeReport.unsupported(
          'platform_exception:${pe.code}',
        );
      }
      return VGGlesExportOverlayProductionSmokeReport.harnessFailure(
        'platform_exception:${pe.code}',
        extraDetails: <String, Object?>{
          'code': pe.code,
          'message': pe.message ?? '',
        },
      );
    } catch (e) {
      return VGGlesExportOverlayProductionSmokeReport.harnessFailure(
        'exception:$e',
        extraDetails: <String, Object?>{'error': e.toString()},
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGGlesExportOverlayProductionSmokeReport &&
        other.pass == pass &&
        other.decision == decision &&
        other.status == status &&
        other.marker == marker &&
        other.proofBoundary == proofBoundary &&
        other.failureReason == failureReason &&
        mapEquals(other.gates, gates) &&
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
    _stableMapHash(details),
    raw,
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGGlesExportOverlayProductionSmokeReport('
      'pass: $pass, '
      'decision: $decision, '
      'status: $status, '
      'marker: $marker, '
      'proofBoundary: $proofBoundary, '
      'failureReason: $failureReason, '
      'gates: $gates, '
      'details: $details)';
}
