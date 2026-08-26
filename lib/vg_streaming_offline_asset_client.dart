// Copyright (c) Connects — Vanguard Phase 4C7BI.
// Public streaming offline asset MethodChannel client contract.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing. Pure client wrapper
// around native MethodChannel routes for future offline HLS asset lifecycle
// management without native downloads, playback mutations, filesystem operations,
// or caching policies.

import 'dart:async';

import 'package:flutter/services.dart';

import 'vg_streaming_offline_asset_lifecycle.dart';

export 'vg_streaming_offline_asset_acquisition_plan.dart'
    show
        VGStreamingOfflineAssetAcquisitionPriority,
        VGStreamingOfflineAssetAcquisitionRequest;
export 'vg_streaming_offline_asset_lifecycle.dart'
    show
        VGStreamingOfflineAssetDownloadState,
        VGStreamingOfflineAssetDownloadStatus;
export 'vg_streaming_playback_route_plan.dart'
    show VGStreamingOfflineAssetAvailability, VGStreamingOfflineAssetState;

// ─────────────────────────────────────────────────────────────────────────────
// Typed Result Models & Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Acceptance states for [VGStreamingOfflineAssetClient.startAcquisition].
enum VGStreamingOfflineAssetAcquisitionStartState {
  /// Acquisition task was accepted and queued by the platform downloader.
  accepted,

  /// An acquisition task with the same requestId already exists.
  duplicate,

  /// Request arguments were invalid (e.g. blank URI, invalid scheme, unparseable format).
  invalid,

  /// Acquisition was blocked because available storage headroom is below the required reserve.
  blockedLowStorage,

  /// Storage headroom evaluation encountered a platform error (no task created).
  storageGuardError,

  /// The platform or client does not support native offline asset acquisition.
  unsupported;

  /// Parses a dynamic string or object into a [VGStreamingOfflineAssetAcquisitionStartState].
  static VGStreamingOfflineAssetAcquisitionStartState parse(Object? raw) {
    if (raw == null) {
      return VGStreamingOfflineAssetAcquisitionStartState.invalid;
    }
    if (raw is VGStreamingOfflineAssetAcquisitionStartState) {
      return raw;
    }

    final normalized = raw
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '');

    return switch (normalized) {
      'accepted' => VGStreamingOfflineAssetAcquisitionStartState.accepted,
      'duplicate' => VGStreamingOfflineAssetAcquisitionStartState.duplicate,
      'invalid' => VGStreamingOfflineAssetAcquisitionStartState.invalid,
      'blockedlowstorage' =>
        VGStreamingOfflineAssetAcquisitionStartState.blockedLowStorage,
      'storageguarderror' =>
        VGStreamingOfflineAssetAcquisitionStartState.storageGuardError,
      'unsupported' => VGStreamingOfflineAssetAcquisitionStartState.unsupported,
      _ => VGStreamingOfflineAssetAcquisitionStartState.invalid,
    };
  }
}

/// Result of [VGStreamingOfflineAssetClient.startAcquisition].
class VGStreamingOfflineAssetAcquisitionStartResult {
  /// Engine phase identifier (e.g. `"Phase4C7BI"` or platform phase).
  final String phase;

  /// Whether the acquisition start request was admitted and queued.
  final bool pass;

  /// Identifier of the acquisition request echoed back by the platform.
  final String requestId;

  /// Source key associated with the acquisition request, or `null`.
  final String? sourceKey;

  /// Admission lifecycle start state.
  final VGStreamingOfflineAssetAcquisitionStartState state;

  /// Raw diagnostic summary string from the platform.
  final String raw;

  /// Storage guard evaluation phase identifier, or `null`.
  final String? storageGuardPhase;

  /// Whether the storage headroom guard passed, or `null` if unconstrained.
  final bool? storageGuardPass;

  /// Available bytes on the filesystem at evaluation time, or `null`.
  final int? availableBytes;

  /// Estimated/requested bytes for this asset, or `null`.
  final int? requestedBytes;

  /// Minimum required free headroom reserve in bytes, or `null`.
  final int? minimumFreeBytes;

  /// Projected available bytes after acquisition, or `null`.
  final int? projectedAvailableBytes;

  const VGStreamingOfflineAssetAcquisitionStartResult({
    required this.phase,
    required this.pass,
    required this.requestId,
    this.sourceKey,
    required this.state,
    required this.raw,
    this.storageGuardPhase,
    this.storageGuardPass,
    this.availableBytes,
    this.requestedBytes,
    this.minimumFreeBytes,
    this.projectedAvailableBytes,
  });

  /// Constructs a start result from a platform response dictionary.
  factory VGStreamingOfflineAssetAcquisitionStartResult.fromMap(
    String requestId,
    Map<Object?, Object?> m, {
    String? sourceKey,
  }) {
    final state = VGStreamingOfflineAssetAcquisitionStartState.parse(
      m['state'],
    );
    final parsedReqId = m['requestId']?.toString() ?? requestId;
    final parsedSourceKey = m['sourceKey']?.toString() ?? sourceKey;

    final rawMinFree =
        (m['minimumFreeBytes'] ?? m['minimumFreeBytesAfterPrewarm']) as num?;
    final minFree = rawMinFree?.toInt();

    final avail = (m['availableBytes'] as num?)?.toInt();
    final req = ((m['requestedBytes'] ?? m['estimatedBytes']) as num?)?.toInt();
    final proj = (m['projectedAvailableBytes'] as num?)?.toInt();

    return VGStreamingOfflineAssetAcquisitionStartResult(
      phase: m['phase'] as String? ?? 'Phase4C7BI',
      pass: m['pass'] as bool? ?? false,
      requestId: parsedReqId,
      sourceKey: parsedSourceKey,
      state: state,
      raw: m['raw'] as String? ?? '',
      storageGuardPhase: m['storageGuardPhase'] as String?,
      storageGuardPass: m['storageGuardPass'] as bool?,
      availableBytes: avail,
      requestedBytes: req,
      minimumFreeBytes: minFree,
      projectedAvailableBytes: proj,
    );
  }

  /// Returned when the native plugin is missing or unsupported on the current platform.
  factory VGStreamingOfflineAssetAcquisitionStartResult.unsupported(
    String requestId, {
    String? sourceKey,
  }) => VGStreamingOfflineAssetAcquisitionStartResult(
    phase: 'unsupported',
    pass: false,
    requestId: requestId,
    sourceKey: sourceKey,
    state: VGStreamingOfflineAssetAcquisitionStartState.unsupported,
    raw: 'status=UNSUPPORTED;platform=unsupported',
  );

  @override
  String toString() =>
      'VGStreamingOfflineAssetAcquisitionStartResult(phase=$phase, pass=$pass, '
      'requestId=$requestId, sourceKey=$sourceKey, state=${state.name}, '
      'storageGuardPass=$storageGuardPass, availableBytes=$availableBytes)';
}

/// Lifecycle states of an offline asset command (cancel, delete, clear).
enum VGStreamingOfflineAssetCommandState {
  /// Cancellation was requested and acknowledged for an active task.
  cancelRequested,

  /// The specified offline asset bundle was deleted from local disk.
  deleted,

  /// All offline asset bundles were cleared from local disk.
  cleared,

  /// Specified asset task was not found or had already reached a terminal state.
  notFoundOrTerminal,

  /// Specified asset or request was not found in catalog or storage.
  notFound,

  /// Command parameters were invalid (e.g. blank identifier).
  invalid,

  /// Command is unsupported on the current platform.
  unsupported;

  /// Parses a dynamic string or object into a [VGStreamingOfflineAssetCommandState].
  static VGStreamingOfflineAssetCommandState parse(Object? raw) {
    if (raw == null) {
      return VGStreamingOfflineAssetCommandState.unsupported;
    }
    if (raw is VGStreamingOfflineAssetCommandState) {
      return raw;
    }

    final normalized = raw
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '');

    return switch (normalized) {
      'cancelrequested' ||
      'cancelled' ||
      'canceled' => VGStreamingOfflineAssetCommandState.cancelRequested,
      'deleted' => VGStreamingOfflineAssetCommandState.deleted,
      'cleared' => VGStreamingOfflineAssetCommandState.cleared,
      'notfoundorterminal' =>
        VGStreamingOfflineAssetCommandState.notFoundOrTerminal,
      'notfound' => VGStreamingOfflineAssetCommandState.notFound,
      'invalid' => VGStreamingOfflineAssetCommandState.invalid,
      'unsupported' => VGStreamingOfflineAssetCommandState.unsupported,
      _ => VGStreamingOfflineAssetCommandState.unsupported,
    };
  }
}

/// Result of an offline asset management command ([VGStreamingOfflineAssetClient.cancelAcquisition],
/// [VGStreamingOfflineAssetClient.deleteAsset], [VGStreamingOfflineAssetClient.clearAssets]).
class VGStreamingOfflineAssetCommandResult {
  /// Engine phase identifier (e.g. `"Phase4C7BI"` or platform phase).
  final String phase;

  /// Whether the command completed without fatal error.
  final bool pass;

  /// Command execution lifecycle state.
  final VGStreamingOfflineAssetCommandState state;

  /// Target request identifier, or `null`.
  final String? requestId;

  /// Target source descriptor key, or `null`.
  final String? sourceKey;

  /// Total disk bytes freed by the operation, or `null` if unmeasured.
  final int? freedBytes;

  /// Number of asset bundles removed by the operation, or `null` if unmeasured.
  final int? removedCount;

  /// Raw diagnostic summary string from the platform.
  final String raw;

  const VGStreamingOfflineAssetCommandResult({
    required this.phase,
    required this.pass,
    required this.state,
    this.requestId,
    this.sourceKey,
    this.freedBytes,
    this.removedCount,
    required this.raw,
  });

  /// Constructs a command result from a platform response dictionary.
  factory VGStreamingOfflineAssetCommandResult.fromMap(
    Map<Object?, Object?> m, {
    String? requestId,
    String? sourceKey,
  }) {
    final state = VGStreamingOfflineAssetCommandState.parse(m['state']);
    final parsedReqId = m['requestId']?.toString() ?? requestId;
    final parsedSourceKey = m['sourceKey']?.toString() ?? sourceKey;

    final rawFreed = (m['freedBytes'] ?? m['beforeBytes']) as num?;
    final freedBytes = (rawFreed != null && rawFreed >= 0)
        ? rawFreed.toInt()
        : null;

    final rawRemoved = (m['removedCount'] ?? m['removedResourceCount']) as num?;
    final removedCount = (rawRemoved != null && rawRemoved >= 0)
        ? rawRemoved.toInt()
        : null;

    return VGStreamingOfflineAssetCommandResult(
      phase: m['phase'] as String? ?? 'Phase4C7BI',
      pass: m['pass'] as bool? ?? false,
      state: state,
      requestId: parsedReqId,
      sourceKey: parsedSourceKey,
      freedBytes: freedBytes,
      removedCount: removedCount,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is missing or unsupported on the current platform.
  factory VGStreamingOfflineAssetCommandResult.unsupported({
    String? requestId,
    String? sourceKey,
  }) => VGStreamingOfflineAssetCommandResult(
    phase: 'unsupported',
    pass: false,
    state: VGStreamingOfflineAssetCommandState.unsupported,
    requestId: requestId,
    sourceKey: sourceKey,
    raw: 'status=UNSUPPORTED;platform=unsupported',
  );

  @override
  String toString() =>
      'VGStreamingOfflineAssetCommandResult(phase=$phase, pass=$pass, '
      'state=${state.name}, requestId=$requestId, sourceKey=$sourceKey, '
      'freedBytes=$freedBytes, removedCount=$removedCount)';
}

/// Result of [VGStreamingOfflineAssetClient.queryAvailability].
class VGStreamingOfflineAssetAvailabilityResult {
  /// Engine phase identifier (e.g. `"Phase4C7BI"` or platform phase).
  final String phase;

  /// Whether the query operation succeeded.
  final bool pass;

  /// List of resolved offline asset availability descriptors.
  final List<VGStreamingOfflineAssetAvailability> assets;

  /// Raw diagnostic summary string from the platform.
  final String raw;

  VGStreamingOfflineAssetAvailabilityResult({
    required this.phase,
    required this.pass,
    List<VGStreamingOfflineAssetAvailability> assets = const [],
    required this.raw,
  }) : assets = List.unmodifiable(assets);

  /// Constructs an availability result from a platform response dictionary.
  factory VGStreamingOfflineAssetAvailabilityResult.fromMap(
    Map<Object?, Object?> m,
  ) {
    final rawAssets = m['assets'];
    final parsedAssets = <VGStreamingOfflineAssetAvailability>[];

    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is Map) {
          parsedAssets.add(_parseAvailability(item.cast<Object?, Object?>()));
        }
      }
    }

    return VGStreamingOfflineAssetAvailabilityResult(
      phase: m['phase'] as String? ?? 'Phase4C7BI',
      pass: m['pass'] as bool? ?? false,
      assets: parsedAssets,
      raw: m['raw'] as String? ?? '',
    );
  }

  /// Returned when the native plugin is missing or unsupported on the current platform.
  factory VGStreamingOfflineAssetAvailabilityResult.unsupported() =>
      VGStreamingOfflineAssetAvailabilityResult(
        phase: 'unsupported',
        pass: false,
        assets: const [],
        raw: 'status=UNSUPPORTED;platform=unsupported',
      );

  static VGStreamingOfflineAssetAvailability _parseAvailability(
    Map<Object?, Object?> map,
  ) {
    final rawSourceKey = map['sourceKey']?.toString().trim();
    final sourceKey = (rawSourceKey != null && rawSourceKey.isNotEmpty)
        ? rawSourceKey
        : 'unknown_source';

    final rawState = map['state']?.toString().trim().toLowerCase();
    final state = switch (rawState) {
      'available' => VGStreamingOfflineAssetState.available,
      'unavailable' => VGStreamingOfflineAssetState.unavailable,
      'stale' => VGStreamingOfflineAssetState.stale,
      'expired' => VGStreamingOfflineAssetState.expired,
      'unsupported' => VGStreamingOfflineAssetState.unsupported,
      _ => VGStreamingOfflineAssetState.unknown,
    };

    final rawUri = map['assetUri']?.toString().trim();
    final assetUri = (rawUri != null && rawUri.isNotEmpty)
        ? Uri.tryParse(rawUri)
        : null;

    final rawDownloaded = (map['downloadedBytes'] as num?)?.toInt();
    final downloadedBytes = (rawDownloaded != null && rawDownloaded >= 0)
        ? rawDownloaded
        : null;

    final rawExpires = (map['expiresAtUnixMs'] as num?)?.toInt();
    final expiresAtUnixMs = (rawExpires != null && rawExpires >= 0)
        ? rawExpires
        : null;

    final reason = map['reason']?.toString();

    return VGStreamingOfflineAssetAvailability(
      sourceKey: sourceKey,
      state: state,
      assetUri: assetUri,
      downloadedBytes: downloadedBytes,
      expiresAtUnixMs: expiresAtUnixMs,
      reason: reason,
    );
  }

  @override
  String toString() =>
      'VGStreamingOfflineAssetAvailabilityResult(phase=$phase, pass=$pass, '
      'assetsCount=${assets.length}, raw=$raw)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Client Contract
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 4C7BI: Public Dart MethodChannel client contract for streaming offline asset lifecycle.
///
/// Encapsulates platform `MethodChannel` interaction, parameter serialization,
/// and typed error handling for offline HLS asset acquisition and storage operations.
///
/// Safe to import on all platforms: methods catch [MissingPluginException] and return
/// typed unsupported results instead of crashing.
///
/// Pure lifecycle client: does NOT perform native downloads, local filesystem I/O,
/// ABR arbitration, playback mutations, caching policies, or DASH downloads directly.
class VGStreamingOfflineAssetClient {
  VGStreamingOfflineAssetClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Requests background acquisition of an eligible streaming asset for offline storage.
  ///
  /// - [request]: validated acquisition request containing URI, source key, format, priority, and budget.
  /// - [minimumFreeBytes]: optional storage headroom reserve in bytes required after acquisition.
  Future<VGStreamingOfflineAssetAcquisitionStartResult> startAcquisition(
    VGStreamingOfflineAssetAcquisitionRequest request, {
    int? minimumFreeBytes,
  }) async {
    try {
      final args = <String, Object?>{
        ...request.toArgs(),
        if (minimumFreeBytes != null) 'minimumFreeBytes': minimumFreeBytes,
      };

      final raw = await _channel.invokeMethod<Object?>(
        'startStreamingOfflineAssetAcquisition',
        args,
      );

      if (raw is! Map) {
        return VGStreamingOfflineAssetAcquisitionStartResult.unsupported(
          request.requestId,
          sourceKey: request.sourceKey,
        );
      }

      return VGStreamingOfflineAssetAcquisitionStartResult.fromMap(
        request.requestId,
        raw.cast<Object?, Object?>(),
        sourceKey: request.sourceKey,
      );
    } on MissingPluginException {
      return VGStreamingOfflineAssetAcquisitionStartResult.unsupported(
        request.requestId,
        sourceKey: request.sourceKey,
      );
    }
  }

  /// Queries current download or storage status for an acquisition task or stored offline asset.
  ///
  /// - [requestId]: unique acquisition task identifier (must not be empty).
  /// - [sourceKey]: optional source descriptor key for catalog lookup.
  Future<VGStreamingOfflineAssetDownloadStatus> getStatus({
    required String requestId,
    String? sourceKey,
  }) async {
    if (requestId.trim().isEmpty) {
      throw ArgumentError('requestId must not be empty');
    }

    try {
      final args = <String, Object?>{
        'requestId': requestId,
        if (sourceKey != null && sourceKey.trim().isNotEmpty)
          'sourceKey': sourceKey,
      };

      final raw = await _channel.invokeMethod<Object?>(
        'getStreamingOfflineAssetStatus',
        args,
      );

      if (raw is! Map) {
        return _unsupportedDownloadStatus(requestId, sourceKey: sourceKey);
      }

      return VGStreamingOfflineAssetDownloadStatus.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return _unsupportedDownloadStatus(requestId, sourceKey: sourceKey);
    }
  }

  /// Requests cancellation of an in-flight offline asset acquisition task.
  ///
  /// Safe and idempotent if the task does not exist or has already completed.
  ///
  /// - [requestId]: identifier of the acquisition task to cancel (must not be empty).
  Future<VGStreamingOfflineAssetCommandResult> cancelAcquisition(
    String requestId,
  ) async {
    if (requestId.trim().isEmpty) {
      throw ArgumentError('requestId must not be empty');
    }

    try {
      final raw = await _channel.invokeMethod<Object?>(
        'cancelStreamingOfflineAssetAcquisition',
        {'requestId': requestId},
      );

      if (raw is! Map) {
        return VGStreamingOfflineAssetCommandResult.unsupported(
          requestId: requestId,
        );
      }

      return VGStreamingOfflineAssetCommandResult.fromMap(
        raw.cast<Object?, Object?>(),
        requestId: requestId,
      );
    } on MissingPluginException {
      return VGStreamingOfflineAssetCommandResult.unsupported(
        requestId: requestId,
      );
    }
  }

  /// Deletes a completed offline asset bundle from local storage.
  ///
  /// At least one of [requestId] or [sourceKey] must be provided and non-empty.
  Future<VGStreamingOfflineAssetCommandResult> deleteAsset({
    String? requestId,
    String? sourceKey,
  }) async {
    final hasReqId = requestId != null && requestId.trim().isNotEmpty;
    final hasSourceKey = sourceKey != null && sourceKey.trim().isNotEmpty;

    if (!hasReqId && !hasSourceKey) {
      throw ArgumentError(
        'At least one of requestId or sourceKey must be provided and non-empty',
      );
    }

    try {
      final args = <String, Object?>{
        if (hasReqId) 'requestId': requestId,
        if (hasSourceKey) 'sourceKey': sourceKey,
      };

      final raw = await _channel.invokeMethod<Object?>(
        'deleteStreamingOfflineAsset',
        args,
      );

      if (raw is! Map) {
        return VGStreamingOfflineAssetCommandResult.unsupported(
          requestId: requestId,
          sourceKey: sourceKey,
        );
      }

      return VGStreamingOfflineAssetCommandResult.fromMap(
        raw.cast<Object?, Object?>(),
        requestId: requestId,
        sourceKey: sourceKey,
      );
    } on MissingPluginException {
      return VGStreamingOfflineAssetCommandResult.unsupported(
        requestId: requestId,
        sourceKey: sourceKey,
      );
    }
  }

  /// Clears all downloaded offline asset packages from local storage.
  ///
  /// Safe to call on user logout, privacy purge, or storage cleanup.
  Future<VGStreamingOfflineAssetCommandResult> clearAssets() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'clearStreamingOfflineAssets',
        const <String, Object?>{},
      );

      if (raw is! Map) {
        return VGStreamingOfflineAssetCommandResult.unsupported();
      }

      return VGStreamingOfflineAssetCommandResult.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingOfflineAssetCommandResult.unsupported();
    }
  }

  /// Scans local storage and queries availability records for candidate streaming sources.
  ///
  /// - [sourceKeys]: optional filter of source keys to inspect; if supplied, must be non-empty and contain no blank entries.
  Future<VGStreamingOfflineAssetAvailabilityResult> queryAvailability({
    List<String>? sourceKeys,
  }) async {
    if (sourceKeys != null) {
      if (sourceKeys.isEmpty || sourceKeys.any((k) => k.trim().isEmpty)) {
        throw ArgumentError(
          'sourceKeys, if supplied, must be non-empty and contain no blank entries',
        );
      }
    }

    try {
      final args = <String, Object?>{
        if (sourceKeys != null) 'sourceKeys': sourceKeys,
      };

      final raw = await _channel.invokeMethod<Object?>(
        'queryStreamingOfflineAssetAvailability',
        args,
      );

      if (raw is! Map) {
        return VGStreamingOfflineAssetAvailabilityResult.unsupported();
      }

      return VGStreamingOfflineAssetAvailabilityResult.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingOfflineAssetAvailabilityResult.unsupported();
    }
  }

  static VGStreamingOfflineAssetDownloadStatus _unsupportedDownloadStatus(
    String requestId, {
    String? sourceKey,
  }) {
    return VGStreamingOfflineAssetDownloadStatus(
      requestId: requestId,
      sourceKey: (sourceKey != null && sourceKey.isNotEmpty)
          ? sourceKey
          : 'unknown_source',
      state: VGStreamingOfflineAssetDownloadState.unsupported,
      errorMessage: 'status=UNSUPPORTED;platform=unsupported',
      diagnostics: const <String, Object?>{
        'pass': false,
        'phase': 'unsupported',
        'raw': 'status=UNSUPPORTED;platform=unsupported',
      },
    );
  }
}
