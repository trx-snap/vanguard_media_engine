// Copyright (c) Connects — Vanguard Phase 1.
// Public Dart backend capability diagnostics surface.
//
// Safe to import on all platforms: catches MissingPluginException and
// returns typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// -----------------------------------------------------------------------------
// Render Backend Enum
// -----------------------------------------------------------------------------

/// Vanguard native rendering backend types.
enum VGRenderBackend {
  /// Vulkan graphics backend (preferred primary path on Android).
  vulkan,

  /// OpenGL ES graphics backend (verified compatibility fallback).
  gles,

  /// No rendering backend is available or operational.
  unavailable;

  /// Parses a [VGRenderBackend] from a raw integer code.
  ///
  /// Mapping:
  /// - `0` -> [VGRenderBackend.vulkan]
  /// - `1` -> [VGRenderBackend.gles]
  /// - `2` -> [VGRenderBackend.unavailable]
  /// - unknown / null -> [VGRenderBackend.unavailable]
  static VGRenderBackend fromRaw(int? raw) {
    return switch (raw) {
      0 => VGRenderBackend.vulkan,
      1 => VGRenderBackend.gles,
      2 => VGRenderBackend.unavailable,
      _ => VGRenderBackend.unavailable,
    };
  }

  /// Defensively parses a [VGRenderBackend] from arbitrary platform values
  /// including [int], [num], or [String].
  static VGRenderBackend fromValue(Object? value) {
    if (value is VGRenderBackend) return value;
    if (value is int) return fromRaw(value);
    if (value is num) return fromRaw(value.toInt());
    if (value is String) {
      final trimmed = value.trim();
      final parsed = int.tryParse(trimmed);
      if (parsed != null) return fromRaw(parsed);
      final lower = trimmed.toLowerCase();
      if (lower == 'vulkan') return VGRenderBackend.vulkan;
      if (lower == 'gles') return VGRenderBackend.gles;
      if (lower == 'unavailable') return VGRenderBackend.unavailable;
    }
    return VGRenderBackend.unavailable;
  }
}

// -----------------------------------------------------------------------------
// Disabled Capability Flags Model
// -----------------------------------------------------------------------------

/// Diagnostic summary flags detailing disabled capabilities and active fallbacks.
///
/// Derived deterministically from platform capability diagnostic telemetry.
@immutable
class VGDisabledCapabilityFlags {
  /// Whether Vulkan rendering is disabled or unavailable.
  final bool isVulkanDisabled;

  /// Whether OpenGL ES rendering is disabled or unsupported.
  final bool isGlesDisabled;

  /// Whether the engine is actively operating in GLES fallback mode instead of Vulkan.
  final bool isGlesFallbackActive;

  /// Whether the GPU driver matched an active driver blacklist rule.
  final bool isGpuDriverBlacklisted;

  /// Whether the Android Vulkan Profile (AVP 2022) compatibility safety gate failed.
  final bool isAvp2022ProfileGateFailed;

  /// Whether GLES ImageReader.PRIVATE AHardwareBuffer direct import is disabled.
  final bool isGlesPrivateAhbImportDisabled;

  /// Whether GLES decoded SurfaceTexture GL_TEXTURE_EXTERNAL_OES rendering is disabled.
  final bool isGlesDecodedSurfaceTextureOesDisabled;

  /// Whether both Vulkan and GLES are unusable, rendering the engine completely unavailable.
  final bool isRenderingUnavailable;

  /// List of canonical feature identifier keys corresponding to currently disabled capabilities.
  final List<String> disabledFeatureKeys;

  const VGDisabledCapabilityFlags({
    required this.isVulkanDisabled,
    required this.isGlesDisabled,
    required this.isGlesFallbackActive,
    required this.isGpuDriverBlacklisted,
    required this.isAvp2022ProfileGateFailed,
    required this.isGlesPrivateAhbImportDisabled,
    required this.isGlesDecodedSurfaceTextureOesDisabled,
    required this.isRenderingUnavailable,
    required this.disabledFeatureKeys,
  });

  /// Derives disabled capability flags deterministically from backend capability fields.
  factory VGDisabledCapabilityFlags.fromDiagnostics({
    required bool vulkanSupported,
    required bool glesSupported,
    required VGRenderBackend selectedBackend,
    required String fallbackReason,
    required String profileGateStatus,
    required String blacklistStatus,
    required bool glesPrivateAhbImportSupported,
    required bool glesDecodedSurfaceTextureOesSupported,
    bool pass = false,
  }) {
    final lowerBlacklist = blacklistStatus.toLowerCase().trim();
    final lowerFallback = fallbackReason.toLowerCase().trim();
    final isGpuDriverBlacklisted =
        (lowerBlacklist.contains('blacklisted') &&
            !lowerBlacklist.contains('not_blacklisted') &&
            !lowerBlacklist.contains('not_evaluated')) ||
        lowerFallback.contains('blacklisted');

    final lowerProfile = profileGateStatus.toLowerCase().trim();
    final isAvp2022ProfileGatePassed =
        lowerProfile == 'avp2022_partial_pass' ||
        lowerProfile == 'avp2022_pass' ||
        lowerProfile == 'pass' ||
        lowerProfile == 'passed';
    final isAvp2022ProfileGateFailed =
        lowerProfile.contains('fail') ||
        lowerProfile.contains('exception') ||
        (!isAvp2022ProfileGatePassed &&
            lowerProfile.isNotEmpty &&
            lowerProfile != 'not_evaluated' &&
            lowerProfile != 'unverified' &&
            lowerProfile != 'none' &&
            lowerProfile != 'unsupported' &&
            lowerProfile != 'unsupported_platform');

    final isVulkanDisabled =
        !vulkanSupported || selectedBackend != VGRenderBackend.vulkan;
    final isGlesDisabled = !glesSupported;
    final isGlesFallbackActive = selectedBackend == VGRenderBackend.gles;
    final isGlesPrivateAhbImportDisabled = !glesPrivateAhbImportSupported;
    final isGlesDecodedSurfaceTextureOesDisabled =
        !glesDecodedSurfaceTextureOesSupported;
    final isRenderingUnavailable =
        selectedBackend == VGRenderBackend.unavailable ||
        (!vulkanSupported && !glesSupported);

    final keys = <String>[];
    if (isVulkanDisabled) keys.add('vulkan');
    if (isGlesDisabled) keys.add('gles');
    if (isGlesFallbackActive) keys.add('gles_fallback');
    if (isGpuDriverBlacklisted) keys.add('gpu_driver_blacklisted');
    if (isAvp2022ProfileGateFailed) keys.add('avp2022_profile_gate_failed');
    if (isGlesPrivateAhbImportDisabled) keys.add('gles_private_ahb_import');
    if (isGlesDecodedSurfaceTextureOesDisabled) {
      keys.add('gles_decoded_surface_texture_oes');
    }
    if (isRenderingUnavailable) keys.add('rendering_unavailable');

    return VGDisabledCapabilityFlags(
      isVulkanDisabled: isVulkanDisabled,
      isGlesDisabled: isGlesDisabled,
      isGlesFallbackActive: isGlesFallbackActive,
      isGpuDriverBlacklisted: isGpuDriverBlacklisted,
      isAvp2022ProfileGateFailed: isAvp2022ProfileGateFailed,
      isGlesPrivateAhbImportDisabled: isGlesPrivateAhbImportDisabled,
      isGlesDecodedSurfaceTextureOesDisabled:
          isGlesDecodedSurfaceTextureOesDisabled,
      isRenderingUnavailable: isRenderingUnavailable,
      disabledFeatureKeys: List<String>.unmodifiable(keys),
    );
  }

  /// Deserializes a [VGDisabledCapabilityFlags] defensively from a map.
  factory VGDisabledCapabilityFlags.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);
    final isVulkanDisabled = _asBool(stringMap['isVulkanDisabled']);
    final isGlesDisabled = _asBool(stringMap['isGlesDisabled']);
    final isGlesFallbackActive = _asBool(stringMap['isGlesFallbackActive']);
    final isGpuDriverBlacklisted = _asBool(stringMap['isGpuDriverBlacklisted']);
    final isAvp2022ProfileGateFailed = _asBool(
      stringMap['isAvp2022ProfileGateFailed'],
    );
    final isGlesPrivateAhbImportDisabled = _asBool(
      stringMap['isGlesPrivateAhbImportDisabled'],
    );
    final isGlesDecodedSurfaceTextureOesDisabled = _asBool(
      stringMap['isGlesDecodedSurfaceTextureOesDisabled'],
    );
    final isRenderingUnavailable = _asBool(stringMap['isRenderingUnavailable']);

    final rawKeys = stringMap['disabledFeatureKeys'];
    final List<String> disabledFeatureKeys;
    if (rawKeys is Iterable) {
      disabledFeatureKeys = List<String>.unmodifiable(
        rawKeys.map((e) => e.toString()),
      );
    } else {
      final keys = <String>[];
      if (isVulkanDisabled) keys.add('vulkan');
      if (isGlesDisabled) keys.add('gles');
      if (isGlesFallbackActive) keys.add('gles_fallback');
      if (isGpuDriverBlacklisted) keys.add('gpu_driver_blacklisted');
      if (isAvp2022ProfileGateFailed) keys.add('avp2022_profile_gate_failed');
      if (isGlesPrivateAhbImportDisabled) keys.add('gles_private_ahb_import');
      if (isGlesDecodedSurfaceTextureOesDisabled) {
        keys.add('gles_decoded_surface_texture_oes');
      }
      if (isRenderingUnavailable) keys.add('rendering_unavailable');
      disabledFeatureKeys = List<String>.unmodifiable(keys);
    }

    return VGDisabledCapabilityFlags(
      isVulkanDisabled: isVulkanDisabled,
      isGlesDisabled: isGlesDisabled,
      isGlesFallbackActive: isGlesFallbackActive,
      isGpuDriverBlacklisted: isGpuDriverBlacklisted,
      isAvp2022ProfileGateFailed: isAvp2022ProfileGateFailed,
      isGlesPrivateAhbImportDisabled: isGlesPrivateAhbImportDisabled,
      isGlesDecodedSurfaceTextureOesDisabled:
          isGlesDecodedSurfaceTextureOesDisabled,
      isRenderingUnavailable: isRenderingUnavailable,
      disabledFeatureKeys: disabledFeatureKeys,
    );
  }

  /// Serializes to a standard JSON-compatible map format.
  Map<String, Object?> toMap() => <String, Object?>{
    'isVulkanDisabled': isVulkanDisabled,
    'isGlesDisabled': isGlesDisabled,
    'isGlesFallbackActive': isGlesFallbackActive,
    'isGpuDriverBlacklisted': isGpuDriverBlacklisted,
    'isAvp2022ProfileGateFailed': isAvp2022ProfileGateFailed,
    'isGlesPrivateAhbImportDisabled': isGlesPrivateAhbImportDisabled,
    'isGlesDecodedSurfaceTextureOesDisabled':
        isGlesDecodedSurfaceTextureOesDisabled,
    'isRenderingUnavailable': isRenderingUnavailable,
    'disabledFeatureKeys': disabledFeatureKeys,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGDisabledCapabilityFlags &&
        other.isVulkanDisabled == isVulkanDisabled &&
        other.isGlesDisabled == isGlesDisabled &&
        other.isGlesFallbackActive == isGlesFallbackActive &&
        other.isGpuDriverBlacklisted == isGpuDriverBlacklisted &&
        other.isAvp2022ProfileGateFailed == isAvp2022ProfileGateFailed &&
        other.isGlesPrivateAhbImportDisabled ==
            isGlesPrivateAhbImportDisabled &&
        other.isGlesDecodedSurfaceTextureOesDisabled ==
            isGlesDecodedSurfaceTextureOesDisabled &&
        other.isRenderingUnavailable == isRenderingUnavailable &&
        listEquals(other.disabledFeatureKeys, disabledFeatureKeys);
  }

  @override
  int get hashCode => Object.hash(
    isVulkanDisabled,
    isGlesDisabled,
    isGlesFallbackActive,
    isGpuDriverBlacklisted,
    isAvp2022ProfileGateFailed,
    isGlesPrivateAhbImportDisabled,
    isGlesDecodedSurfaceTextureOesDisabled,
    isRenderingUnavailable,
    Object.hashAll(disabledFeatureKeys),
  );

  @override
  String toString() =>
      'VGDisabledCapabilityFlags(isVulkanDisabled: $isVulkanDisabled, '
      'isGlesDisabled: $isGlesDisabled, '
      'isGlesFallbackActive: $isGlesFallbackActive, '
      'isGpuDriverBlacklisted: $isGpuDriverBlacklisted, '
      'isAvp2022ProfileGateFailed: $isAvp2022ProfileGateFailed, '
      'isGlesPrivateAhbImportDisabled: $isGlesPrivateAhbImportDisabled, '
      'isGlesDecodedSurfaceTextureOesDisabled: $isGlesDecodedSurfaceTextureOesDisabled, '
      'isRenderingUnavailable: $isRenderingUnavailable, '
      'disabledFeatureKeys: $disabledFeatureKeys)';
}

// -----------------------------------------------------------------------------
// Capability Report Model
// -----------------------------------------------------------------------------

/// Diagnostic report containing comprehensive GPU backend capabilities,
/// active renderer selection, and derived disabled-capability flags.
@immutable
class VGBackendCapabilityReport {
  /// Whether the capability probe passed nominal verification criteria.
  final bool pass;

  /// Whether Vulkan rendering and required device extensions are supported.
  final bool vulkanSupported;

  /// Whether OpenGL ES rendering is supported.
  final bool glesSupported;

  /// The currently selected active rendering backend.
  final VGRenderBackend selectedBackend;

  /// Root-cause classification or fallback reason (e.g. 'none', 'blacklisted_gpu_driver').
  final String fallbackReason;

  /// GPU vendor name or identifier string (e.g. 'Qualcomm', 'ARM').
  final String gpuVendor;

  /// GPU renderer or device name string (e.g. 'Adreno (TM) 740').
  final String gpuRenderer;

  /// Numeric GPU vendor ID.
  final int vendorId;

  /// Numeric GPU device ID.
  final int deviceId;

  /// Vulkan API version code supported by the device.
  final int apiVersion;

  /// Vulkan driver version number reported by device properties.
  final int vulkanDriverVersion;

  /// Status of the Android Vulkan Profile (AVP 2022) safety gate evaluation.
  final String profileGateStatus;

  /// Status of the GPU driver blacklist check.
  final String blacklistStatus;

  /// Preferred decoded frame ingestion path (e.g. 'vulkan_primary', 'gles_surface_texture_oes').
  final String decodedFramePreferredPath;

  /// Whether GLES decoded SurfaceTexture OES rendering is supported.
  final bool glesDecodedSurfaceTextureOesSupported;

  /// Whether GLES private AHardwareBuffer import is supported.
  final bool glesPrivateAhbImportSupported;

  /// Detailed status string for GLES private AHB import capability.
  final String glesPrivateAhbImportStatus;

  /// Active decoded frame fallback policy for GLES rendering.
  final String glesDecodedFallbackPolicy;

  /// Structured disabled capability flags and active fallbacks.
  final VGDisabledCapabilityFlags disabledFlags;

  /// Complete raw diagnostic telemetry map from native probe.
  final Map<String, Object?> diagnostics;

  const VGBackendCapabilityReport({
    required this.pass,
    required this.vulkanSupported,
    required this.glesSupported,
    required this.selectedBackend,
    required this.fallbackReason,
    required this.gpuVendor,
    required this.gpuRenderer,
    required this.vendorId,
    required this.deviceId,
    required this.apiVersion,
    required this.vulkanDriverVersion,
    required this.profileGateStatus,
    required this.blacklistStatus,
    required this.decodedFramePreferredPath,
    required this.glesDecodedSurfaceTextureOesSupported,
    required this.glesPrivateAhbImportSupported,
    required this.glesPrivateAhbImportStatus,
    required this.glesDecodedFallbackPolicy,
    required this.disabledFlags,
    required this.diagnostics,
  });

  /// Constructs a [VGBackendCapabilityReport] defensively from a platform map.
  factory VGBackendCapabilityReport.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);
    final pass = _asBool(stringMap['pass']);
    final vulkanSupported = _asBool(stringMap['vulkanSupported']);
    final glesSupported = _asBool(stringMap['glesSupported']);
    final selectedBackend = VGRenderBackend.fromValue(
      stringMap['selectedBackend'],
    );
    final fallbackReason = _asString(stringMap['fallbackReason']);
    final gpuVendor = _asString(stringMap['gpuVendor']);
    final gpuRenderer = _asString(stringMap['gpuRenderer']);
    final vendorId = _asInt(stringMap['vendorId']) ?? 0;
    final deviceId = _asInt(stringMap['deviceId']) ?? 0;
    final apiVersion = _asInt(stringMap['apiVersion']) ?? 0;
    final vulkanDriverVersion = _asInt(stringMap['vulkanDriverVersion']) ?? 0;
    final profileGateStatus = _asString(stringMap['profileGateStatus']);
    final blacklistStatus = _asString(stringMap['blacklistStatus']);
    final decodedFramePreferredPath = _asString(
      stringMap['decodedFramePreferredPath'],
    );
    final glesDecodedSurfaceTextureOesSupported = _asBool(
      stringMap['glesDecodedSurfaceTextureOesSupported'],
    );
    final glesPrivateAhbImportSupported = _asBool(
      stringMap['glesPrivateAhbImportSupported'],
    );
    final glesPrivateAhbImportStatus = _asString(
      stringMap['glesPrivateAhbImportStatus'],
    );
    final glesDecodedFallbackPolicy = _asString(
      stringMap['glesDecodedFallbackPolicy'],
    );

    final rawFlags = stringMap['disabledFlags'];
    final VGDisabledCapabilityFlags disabledFlags;
    if (rawFlags is Map) {
      disabledFlags = VGDisabledCapabilityFlags.fromMap(
        rawFlags.cast<Object?, Object?>(),
      );
    } else {
      disabledFlags = VGDisabledCapabilityFlags.fromDiagnostics(
        vulkanSupported: vulkanSupported,
        glesSupported: glesSupported,
        selectedBackend: selectedBackend,
        fallbackReason: fallbackReason,
        profileGateStatus: profileGateStatus,
        blacklistStatus: blacklistStatus,
        glesPrivateAhbImportSupported: glesPrivateAhbImportSupported,
        glesDecodedSurfaceTextureOesSupported:
            glesDecodedSurfaceTextureOesSupported,
        pass: pass,
      );
    }

    return VGBackendCapabilityReport(
      pass: pass,
      vulkanSupported: vulkanSupported,
      glesSupported: glesSupported,
      selectedBackend: selectedBackend,
      fallbackReason: fallbackReason,
      gpuVendor: gpuVendor,
      gpuRenderer: gpuRenderer,
      vendorId: vendorId,
      deviceId: deviceId,
      apiVersion: apiVersion,
      vulkanDriverVersion: vulkanDriverVersion,
      profileGateStatus: profileGateStatus,
      blacklistStatus: blacklistStatus,
      decodedFramePreferredPath: decodedFramePreferredPath,
      glesDecodedSurfaceTextureOesSupported:
          glesDecodedSurfaceTextureOesSupported,
      glesPrivateAhbImportSupported: glesPrivateAhbImportSupported,
      glesPrivateAhbImportStatus: glesPrivateAhbImportStatus,
      glesDecodedFallbackPolicy: glesDecodedFallbackPolicy,
      disabledFlags: disabledFlags,
      diagnostics: Map<String, Object?>.unmodifiable(stringMap),
    );
  }

  /// Returned when an error, exception, or malformed response occurs.
  factory VGBackendCapabilityReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) {
    final diag = details != null
        ? Map<String, Object?>.from(details)
        : <String, Object?>{};
    diag.putIfAbsent('pass', () => false);
    diag.putIfAbsent('selectedBackend', () => 2);
    diag.putIfAbsent('fallbackReason', () => reason);

    final disabledFlags = VGDisabledCapabilityFlags.fromDiagnostics(
      vulkanSupported: _asBool(diag['vulkanSupported']),
      glesSupported: _asBool(diag['glesSupported']),
      selectedBackend: VGRenderBackend.unavailable,
      fallbackReason: reason,
      profileGateStatus: _asString(
        diag['profileGateStatus'],
        defaultValue: 'probe_exception',
      ),
      blacklistStatus: _asString(
        diag['blacklistStatus'],
        defaultValue: 'not_evaluated',
      ),
      glesPrivateAhbImportSupported: _asBool(
        diag['glesPrivateAhbImportSupported'],
      ),
      glesDecodedSurfaceTextureOesSupported: _asBool(
        diag['glesDecodedSurfaceTextureOesSupported'],
      ),
      pass: false,
    );

    return VGBackendCapabilityReport(
      pass: false,
      vulkanSupported: false,
      glesSupported: false,
      selectedBackend: VGRenderBackend.unavailable,
      fallbackReason: reason,
      gpuVendor: _asString(diag['gpuVendor']),
      gpuRenderer: _asString(diag['gpuRenderer']),
      vendorId: _asInt(diag['vendorId']) ?? 0,
      deviceId: _asInt(diag['deviceId']) ?? 0,
      apiVersion: _asInt(diag['apiVersion']) ?? 0,
      vulkanDriverVersion: _asInt(diag['vulkanDriverVersion']) ?? 0,
      profileGateStatus: _asString(
        diag['profileGateStatus'],
        defaultValue: 'probe_exception',
      ),
      blacklistStatus: _asString(
        diag['blacklistStatus'],
        defaultValue: 'not_evaluated',
      ),
      decodedFramePreferredPath: _asString(
        diag['decodedFramePreferredPath'],
        defaultValue: 'unknown',
      ),
      glesDecodedSurfaceTextureOesSupported: false,
      glesPrivateAhbImportSupported: false,
      glesPrivateAhbImportStatus: _asString(
        diag['glesPrivateAhbImportStatus'],
        defaultValue: 'probe_exception',
      ),
      glesDecodedFallbackPolicy: _asString(
        diag['glesDecodedFallbackPolicy'],
        defaultValue: 'probe_exception',
      ),
      disabledFlags: disabledFlags,
      diagnostics: Map<String, Object?>.unmodifiable(diag),
    );
  }

  /// Returned when native backend capability probing is not available (e.g. non-Android or missing plugin).
  factory VGBackendCapabilityReport.unsupported() {
    const disabledFlags = VGDisabledCapabilityFlags(
      isVulkanDisabled: true,
      isGlesDisabled: true,
      isGlesFallbackActive: false,
      isGpuDriverBlacklisted: false,
      isAvp2022ProfileGateFailed: false,
      isGlesPrivateAhbImportDisabled: true,
      isGlesDecodedSurfaceTextureOesDisabled: true,
      isRenderingUnavailable: true,
      disabledFeatureKeys: <String>[
        'vulkan',
        'gles',
        'gles_private_ahb_import',
        'gles_decoded_surface_texture_oes',
        'rendering_unavailable',
      ],
    );

    return const VGBackendCapabilityReport(
      pass: false,
      vulkanSupported: false,
      glesSupported: false,
      selectedBackend: VGRenderBackend.unavailable,
      fallbackReason: 'unsupported_platform',
      gpuVendor: '',
      gpuRenderer: '',
      vendorId: 0,
      deviceId: 0,
      apiVersion: 0,
      vulkanDriverVersion: 0,
      profileGateStatus: 'unsupported_platform',
      blacklistStatus: 'not_evaluated',
      decodedFramePreferredPath: 'unknown',
      glesDecodedSurfaceTextureOesSupported: false,
      glesPrivateAhbImportSupported: false,
      glesPrivateAhbImportStatus: 'unsupported_platform',
      glesDecodedFallbackPolicy: 'unsupported_platform',
      disabledFlags: disabledFlags,
      diagnostics: <String, Object?>{
        'pass': false,
        'vulkanSupported': false,
        'glesSupported': false,
        'selectedBackend': 2,
        'fallbackReason': 'unsupported_platform',
        'profileGateStatus': 'unsupported_platform',
        'blacklistStatus': 'not_evaluated',
      },
    );
  }

  /// Whether Vulkan is the currently selected rendering backend.
  bool get isVulkanSelected => selectedBackend == VGRenderBackend.vulkan;

  /// Whether OpenGL ES is the currently selected rendering backend.
  bool get isGlesSelected => selectedBackend == VGRenderBackend.gles;

  /// Whether no graphics rendering backend is available.
  bool get isUnavailable => selectedBackend == VGRenderBackend.unavailable;

  /// Whether the Vulkan rendering path is fully usable and selected.
  bool get isVulkanUsable =>
      vulkanSupported && selectedBackend == VGRenderBackend.vulkan;

  /// Whether the GLES rendering path is fully usable and selected.
  bool get isGlesUsable =>
      glesSupported && selectedBackend == VGRenderBackend.gles;

  /// Converts to standard JSON-compatible map format.
  Map<String, Object?> toMap() => <String, Object?>{
    'pass': pass,
    'vulkanSupported': vulkanSupported,
    'glesSupported': glesSupported,
    'selectedBackend': selectedBackend.index,
    'fallbackReason': fallbackReason,
    'gpuVendor': gpuVendor,
    'gpuRenderer': gpuRenderer,
    'vendorId': vendorId,
    'deviceId': deviceId,
    'apiVersion': apiVersion,
    'vulkanDriverVersion': vulkanDriverVersion,
    'profileGateStatus': profileGateStatus,
    'blacklistStatus': blacklistStatus,
    'decodedFramePreferredPath': decodedFramePreferredPath,
    'glesDecodedSurfaceTextureOesSupported':
        glesDecodedSurfaceTextureOesSupported,
    'glesPrivateAhbImportSupported': glesPrivateAhbImportSupported,
    'glesPrivateAhbImportStatus': glesPrivateAhbImportStatus,
    'glesDecodedFallbackPolicy': glesDecodedFallbackPolicy,
    'disabledFlags': disabledFlags.toMap(),
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGBackendCapabilityReport(pass: $pass, '
      'selectedBackend: $selectedBackend, '
      'vulkanSupported: $vulkanSupported, '
      'glesSupported: $glesSupported, '
      'fallbackReason: $fallbackReason, '
      'gpuVendor: $gpuVendor, '
      'gpuRenderer: $gpuRenderer, '
      'profileGateStatus: $profileGateStatus, '
      'blacklistStatus: $blacklistStatus)';
}

// -----------------------------------------------------------------------------
// Public Client
// -----------------------------------------------------------------------------

/// Public diagnostic client for probing Android True-DAG graphics backend capabilities.
///
/// Dispatches native platform route `runAndroidDagPhase2QCapabilityProbe` behind
/// a safe, strongly-typed Dart API.
///
/// Invariants:
/// - Safe to import and call on all platforms; returns typed unsupported reports on non-Android.
/// - Never throws unhandled exceptions; maps [MissingPluginException] to unsupported
///   and [PlatformException]/generic errors to typed failure reports.
/// - Read-only diagnostic probe: creates zero devices, swapchains, or rendering surfaces.
class VGBackendCapabilityClient {
  final MethodChannel _channel;

  VGBackendCapabilityClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  /// Probes device graphics capabilities and returns a structured [VGBackendCapabilityReport].
  Future<VGBackendCapabilityReport> probeBackendCapabilities() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2QCapabilityProbe',
      );
      if (raw is! Map) {
        return VGBackendCapabilityReport.failure(
          'invalid_response:${raw.runtimeType}',
        );
      }
      return VGBackendCapabilityReport.fromMap(raw.cast<Object?, Object?>());
    } on MissingPluginException {
      return VGBackendCapabilityReport.unsupported();
    } on PlatformException catch (e) {
      return VGBackendCapabilityReport.failure(
        'exception:${e.code}:${e.message ?? 'platform_exception'}',
        <String, Object?>{
          'code': e.code,
          'message': e.message,
          'details': e.details,
        },
      );
    } catch (e) {
      return VGBackendCapabilityReport.failure('exception:$e');
    }
  }
}

// -----------------------------------------------------------------------------
// Parsing Helpers
// -----------------------------------------------------------------------------

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.startsWith('0x') || trimmed.startsWith('0X')) {
      return int.tryParse(trimmed.substring(2), radix: 16);
    }
    return int.tryParse(trimmed);
  }
  return null;
}

bool _asBool(Object? value, {bool defaultValue = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.toLowerCase().trim();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  return defaultValue;
}

String _asString(Object? value, {String defaultValue = ''}) {
  if (value is String) return value;
  if (value != null) return value.toString();
  return defaultValue;
}

Map<String, Object?> _defensiveStringMap(Map<Object?, Object?> map) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key?.toString();
    if (key != null) {
      result[key] = entry.value;
    }
  }
  return result;
}
