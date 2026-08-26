// Copyright (c) Connects — Vanguard Phase 4C6H3G.
// iOS offline HLS persistent catalog cold-relaunch public API physical smoke harness.
//
// Supports a deterministic two-run protocol:
//
// Run 1 (Seed phase):
//   1. Initial Clear: Clears offline asset storage via VGStreamingOfflineAssetClient.clearAssets().
//   2. Query Unavailable: Queries offline asset availability, verifying unavailable/not-playable baseline.
//   3. Start Acquisition: Starts standard HLS acquisition via VGStreamingOfflineAssetClient.startAcquisition().
//   4. Poll Succeeded: Polls getStatus() until download completes with state succeeded and non-null assetUri.
//   5. Query Available: Queries offline asset availability, verifying available state and matching assetUri.
//   6. Emit Seed JSON diagnostic payload.
//   7. Exit 0 cleanly without deleting or clearing the asset, preserving catalog and .movpkg on disk.
//
// Run 2 (Restore phase):
//   1. Query Restored: Cold launch queries restored availability from persistent catalog without starting acquisition.
//   2. Get Status: Queries getStatus() to verify restored catalog state and matching assetUri.
//   3. Open Playback: Evaluates route & preparation planners, opening offline playback via VGStreamingPlaybackClient.open().
//   4. Verify Render: Polls playback status until renderedFrames > 0 and nonzero effective dimensions render.
//   5. Stop Playback: Stops and disposes the active playback session.
//   6. Delete Asset: Deletes the downloaded offline asset via VGStreamingOfflineAssetClient.deleteAsset().
//   7. Verify Deleted: Verifies asset is now unavailable via queryAvailability().
//   8. Final Clear: Clears offline asset storage via VGStreamingOfflineAssetClient.clearAssets().
//   9. Emit Restore JSON diagnostic payload.
//  10. Exit 0 cleanly on success.
//
// Verification Invariants & Boundaries:
// - Standalone Flutter app target for iOS physical devices.
// - Imports public package barrel only (package:vanguard_media_engine/vanguard_media_engine.dart).
// - No direct MethodChannel, private native APIs, or package:flutter/services.dart imports.
// - All asynchronous operations bounded by explicit timeouts.
// - Progress text and periodic timer updates.
// - Emits structured START/DONE/ERROR step lines, JSON diagnostic line, and terminal PASS/FAIL markers.
// - exit(0) on pass, exit(1) on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// Phase selection via environment variable: 'seed' or 'restore'.
const String _kColdPhase = String.fromEnvironment(
  'VG_OFFLINE_COLD_PHASE',
  defaultValue: 'seed',
);

// Standard HLS VOD stream for bounded offline download and playback proof.
const String _kDefaultHlsUri =
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kHlsUri = String.fromEnvironment(
  'VG_IOS_OFFLINE_PLAYBACK_HLS_URI',
  defaultValue: _kDefaultHlsUri,
);

// Stable sourceKey and requestId across seed and restore runs.
const String _kDefaultSourceKey = 'phase4c6h3g_cold_hls';
const String _kSourceKey = String.fromEnvironment(
  'VG_OFFLINE_COLD_SOURCE_KEY',
  defaultValue: _kDefaultSourceKey,
);

const String _kDefaultRequestId = 'phase4c6h3g_cold_hls_req';
const String _kRequestId = String.fromEnvironment(
  'VG_OFFLINE_COLD_REQUEST_ID',
  defaultValue: _kDefaultRequestId,
);

const int _kEstimatedBytes = 65536;
const Duration _kOperationTimeout = Duration(seconds: 20);
const Duration _kDownloadPollTimeout = Duration(minutes: 6);
const Duration _kDownloadPollInterval = Duration(seconds: 1);
const Duration _kPlaybackRenderTimeout = Duration(seconds: 45);
const Duration _kPlaybackPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeApp());
}

class IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeAppState();
}

class _IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeAppState
    extends
        State<IosStreamingOfflineAssetColdRelaunchPublicApiPhysicalSmokeApp> {
  String _status =
      'Initializing Phase 4C6H3G iOS cold relaunch smoke ($_kColdPhase)…';
  int _elapsedSeconds = 0;
  int? _textureId;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsedSeconds++;
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  void _updateStatus(String msg) {
    if (mounted) {
      setState(() {
        _status = msg;
      });
    }
  }

  Future<void> _runSmoke() async {
    // Allow Flutter host connection to settle.
    await Future<void>.delayed(const Duration(seconds: 1));

    final offlineClient = VGStreamingOfflineAssetClient();
    final playbackClient = VGStreamingPlaybackClient();

    if (_kColdPhase == 'seed') {
      await _runSeedPhase(offlineClient);
    } else if (_kColdPhase == 'restore') {
      await _runRestorePhase(offlineClient, playbackClient);
    } else {
      final errorMsg =
          'Unknown VG_OFFLINE_COLD_PHASE: "$_kColdPhase" (expected "seed" or "restore")';
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_ERROR: $errorMsg');
      final diagMap = <String, dynamic>{
        'phase': 'Phase4C6H3G',
        'stage': _kColdPhase,
        'target': 'ios_physical',
        'pass': false,
        'error': errorMsg,
        'backgroundWakeClaimed': false,
      };
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_JSON:${jsonEncode(diagMap)}');
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_FAIL');
      if (mounted) {
        setState(() {
          _status = 'FAIL: $errorMsg';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Run 1: Seed Phase
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _runSeedPhase(
    VGStreamingOfflineAssetClient offlineClient,
  ) async {
    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6H3G',
      'stage': 'seed',
      'target': 'ios_physical',
      'sourceKey': _kSourceKey,
      'requestId': _kRequestId,
      'hlsUri': _kHlsUri,
      'backgroundWakeClaimed': false,
    };

    bool allPass = false;
    bool acquisitionAccepted = false;
    bool assetObserved = false;
    Uri? observedAssetUri;

    try {
      // ───────────────────────────────────────────────────────────────────────
      // Step 1: Initial clearAssets() baseline
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_STEP_INITIAL_CLEAR: START');
      _updateStatus('Seed Step 1/5: Initial clearAssets() baseline…');

      final initialClear = await offlineClient.clearAssets().timeout(
        _kOperationTimeout,
      );
      diagMap['initialClear'] = <String, dynamic>{
        'pass': initialClear.pass,
        'state': initialClear.state.name,
        'freedBytes': initialClear.freedBytes,
        'removedCount': initialClear.removedCount,
        'raw': initialClear.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_SEED_STEP_INITIAL_CLEAR: DONE '
        '(pass=${initialClear.pass}, state=${initialClear.state.name})',
      );

      if (!initialClear.pass ||
          (initialClear.state != VGStreamingOfflineAssetCommandState.cleared &&
              initialClear.state !=
                  VGStreamingOfflineAssetCommandState.notFoundOrTerminal)) {
        throw Exception(
          'Seed Step 1 initial clearAssets() failed: pass=${initialClear.pass}, '
          'state=${initialClear.state.name}, raw=${initialClear.raw}',
        );
      }

      // ───────────────────────────────────────────────────────────────────────
      // Step 2: queryAvailability() baseline (unavailable)
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_STEP_QUERY_UNAVAILABLE: START');
      _updateStatus(
        'Seed Step 2/5: queryAvailability() baseline (unavailable)…',
      );

      final initialQuery = await offlineClient
          .queryAvailability(sourceKeys: [_kSourceKey])
          .timeout(_kOperationTimeout);
      final initialAvailability = initialQuery.assets
          .where((a) => a.sourceKey == _kSourceKey)
          .firstOrNull;

      diagMap['queryUnavailable'] = <String, dynamic>{
        'pass': initialQuery.pass,
        'assetsCount': initialQuery.assets.length,
        'state': initialAvailability?.state.name,
        'isPlayableOffline': initialAvailability?.isPlayableOffline,
        'raw': initialQuery.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_SEED_STEP_QUERY_UNAVAILABLE: DONE '
        '(pass=${initialQuery.pass}, state=${initialAvailability?.state.name})',
      );

      if (!initialQuery.pass ||
          (initialAvailability != null &&
              (initialAvailability.isPlayableOffline ||
                  (initialAvailability.state !=
                          VGStreamingOfflineAssetState.unavailable &&
                      initialAvailability.state !=
                          VGStreamingOfflineAssetState.unknown)))) {
        throw Exception(
          'Seed Step 2 queryAvailability baseline failed: pass=${initialQuery.pass}, '
          'state=${initialAvailability?.state.name}, isPlayableOffline=${initialAvailability?.isPlayableOffline}',
        );
      }

      // ───────────────────────────────────────────────────────────────────────
      // Step 3: startAcquisition() for HLS
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_STEP_START_ACQUISITION: START');
      _updateStatus('Seed Step 3/5: Starting HLS asset acquisition…');

      final acquisitionReq = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: _kRequestId,
        sourceKey: _kSourceKey,
        uri: Uri.parse(_kHlsUri),
        formatHint: VGStreamingFormatHint.hls,
        requireLlHlsTags: false,
        estimatedBytes: _kEstimatedBytes,
      );

      final startResult = await offlineClient
          .startAcquisition(acquisitionReq, minimumFreeBytes: 0)
          .timeout(_kOperationTimeout);

      final startPass =
          startResult.pass &&
          (startResult.state ==
                  VGStreamingOfflineAssetAcquisitionStartState.accepted ||
              (startResult.state ==
                      VGStreamingOfflineAssetAcquisitionStartState.duplicate &&
                  startResult.requestId == _kRequestId));

      if (startResult.pass) {
        acquisitionAccepted = true;
      }

      diagMap['startAcquisition'] = <String, dynamic>{
        'pass': startResult.pass,
        'state': startResult.state.name,
        'requestId': startResult.requestId,
        'sourceKey': startResult.sourceKey,
        'storageGuardPass': startResult.storageGuardPass,
        'raw': startResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_SEED_STEP_START_ACQUISITION: DONE '
        '(pass=${startResult.pass}, state=${startResult.state.name})',
      );

      if (!startPass) {
        throw Exception(
          'Seed Step 3 startAcquisition() failed: pass=${startResult.pass}, '
          'state=${startResult.state.name}, raw=${startResult.raw}',
        );
      }

      // ───────────────────────────────────────────────────────────────────────
      // Step 4: Poll getStatus() until succeeded with non-null assetUri
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_STEP_POLL_SUCCEEDED: START');
      _updateStatus('Seed Step 4/5: Waiting for HLS download completion…');

      final downloadStart = DateTime.now();
      final downloadDeadline = downloadStart.add(_kDownloadPollTimeout);
      VGStreamingOfflineAssetDownloadStatus? finalDownloadStatus;

      while (DateTime.now().isBefore(downloadDeadline)) {
        final status = await offlineClient
            .getStatus(requestId: _kRequestId, sourceKey: _kSourceKey)
            .timeout(_kOperationTimeout);

        if (status.state == VGStreamingOfflineAssetDownloadState.failed ||
            status.state == VGStreamingOfflineAssetDownloadState.cancelled ||
            status.state == VGStreamingOfflineAssetDownloadState.expired ||
            status.state == VGStreamingOfflineAssetDownloadState.unsupported ||
            status.state == VGStreamingOfflineAssetDownloadState.notFound ||
            status.state == VGStreamingOfflineAssetDownloadState.unknown) {
          throw Exception(
            'Seed Step 4 download encountered terminal failure state: ${status.state.name}, '
            'errorCode=${status.errorCode}, errorMessage=${status.errorMessage}, '
            'raw=${status.diagnostics}',
          );
        }

        if (status.state == VGStreamingOfflineAssetDownloadState.succeeded) {
          if (status.assetUri == null) {
            throw Exception(
              'Seed Step 4 download reported succeeded but assetUri is null: '
              'raw=${status.diagnostics}',
            );
          }
          finalDownloadStatus = status;
          observedAssetUri = status.assetUri;
          assetObserved = true;
          break;
        }

        _updateStatus(
          'Seed Step 4/5: Downloading HLS asset (${status.state.name}, '
          '${status.bytesDownloaded} bytes)…',
        );

        await Future<void>.delayed(_kDownloadPollInterval);
      }

      if (finalDownloadStatus == null || observedAssetUri == null) {
        throw Exception(
          'Seed Step 4 timed out waiting for succeeded download of "$_kRequestId"',
        );
      }

      final downloadDurationMs = DateTime.now()
          .difference(downloadStart)
          .inMilliseconds;
      diagMap['download'] = <String, dynamic>{
        'state': finalDownloadStatus.state.name,
        'assetUri': observedAssetUri.toString(),
        'hasAssetUri': true,
        'bytesDownloaded': finalDownloadStatus.bytesDownloaded,
        'totalBytes': finalDownloadStatus.totalBytes,
        'downloadDurationMs': downloadDurationMs,
        'diagnostics': finalDownloadStatus.diagnostics,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_SEED_STEP_POLL_SUCCEEDED: DONE '
        '(state=${finalDownloadStatus.state.name}, assetUri=$observedAssetUri, '
        'bytes=${finalDownloadStatus.bytesDownloaded}, durationMs=$downloadDurationMs)',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 5: queryAvailability() confirming available
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_STEP_QUERY_AVAILABLE: START');
      _updateStatus('Seed Step 5/5: Querying offline asset availability…');

      final queryResult = await offlineClient
          .queryAvailability(sourceKeys: [_kSourceKey])
          .timeout(_kOperationTimeout);
      final hlsAvailability = queryResult.assets
          .where((a) => a.sourceKey == _kSourceKey)
          .firstOrNull;

      diagMap['queryAvailable'] = <String, dynamic>{
        'pass': queryResult.pass,
        'assetsCount': queryResult.assets.length,
        'state': hlsAvailability?.state.name,
        'isPlayableOffline': hlsAvailability?.isPlayableOffline,
        'assetUri': hlsAvailability?.assetUri?.toString(),
        'hasAssetUri': hlsAvailability?.assetUri != null,
        'downloadedBytes': hlsAvailability?.downloadedBytes,
        'raw': queryResult.raw,
      };

      if (!queryResult.pass ||
          hlsAvailability == null ||
          !hlsAvailability.isPlayableOffline ||
          hlsAvailability.state != VGStreamingOfflineAssetState.available ||
          hlsAvailability.assetUri == null) {
        throw Exception(
          'Seed Step 5 queryAvailability failed: pass=${queryResult.pass}, '
          'state=${hlsAvailability?.state.name}, '
          'isPlayableOffline=${hlsAvailability?.isPlayableOffline}, '
          'assetUri=${hlsAvailability?.assetUri}, raw=${queryResult.raw}',
        );
      }

      if (hlsAvailability.assetUri != observedAssetUri) {
        throw Exception(
          'Seed Step 5 assetUri mismatch: observed=$observedAssetUri, '
          'query=${hlsAvailability.assetUri}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_SEED_STEP_QUERY_AVAILABLE: DONE '
        '(pass=${queryResult.pass}, state=${hlsAvailability.state.name}, '
        'isPlayable=${hlsAvailability.isPlayableOffline}, assetUri=${hlsAvailability.assetUri})',
      );

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_ERROR: $error\n$stack');
      diagMap['error'] = error.toString();
      allPass = false;
    } finally {
      // IMPORTANT: Seed phase must NOT delete or clear the asset on success.
      // Clean up only if seed failed prematurely to prevent leaving broken state.
      if (!allPass && acquisitionAccepted && !assetObserved) {
        try {
          final cancelRes = await offlineClient
              .cancelAcquisition(_kRequestId)
              .timeout(_kOperationTimeout);
          diagMap['cleanupCancel'] = <String, dynamic>{
            'pass': cancelRes.pass,
            'state': cancelRes.state.name,
          };
        } catch (_) {}
      }
      if (!allPass && acquisitionAccepted) {
        try {
          await offlineClient
              .deleteAsset(requestId: _kRequestId, sourceKey: _kSourceKey)
              .timeout(_kOperationTimeout);
        } catch (_) {}
      }
    }

    diagMap['pass'] = allPass;

    // ignore: avoid_print
    print('IOS_STREAMING_OFFLINE_COLD_SEED_JSON:${jsonEncode(diagMap)}');

    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_SEED_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass ? 'SEED PASS' : 'SEED FAIL: ${diagMap['error']}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(allPass ? 0 : 1);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Run 2: Restore Phase
  // ═══════════════════════════════════════════════════════════════════════════
  Future<void> _runRestorePhase(
    VGStreamingOfflineAssetClient offlineClient,
    VGStreamingPlaybackClient playbackClient,
  ) async {
    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6H3G',
      'stage': 'restore',
      'target': 'ios_physical',
      'sourceKey': _kSourceKey,
      'requestId': _kRequestId,
      'hlsUri': _kHlsUri,
      'backgroundWakeClaimed': false,
    };

    bool allPass = false;
    bool assetDeleted = false;
    VGStreamingPlaybackSession? activePlaybackSession;
    VGStreamingOfflineAssetAvailability? restoredAvailability;

    try {
      // ───────────────────────────────────────────────────────────────────────
      // Step 1: queryAvailability() to query restored offline asset
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_QUERY_RESTORED: START');
      _updateStatus('Restore Step 1/8: Querying restored offline asset…');

      final queryResult = await offlineClient
          .queryAvailability(sourceKeys: [_kSourceKey])
          .timeout(_kOperationTimeout);
      final foundAvailability = queryResult.assets
          .where((a) => a.sourceKey == _kSourceKey)
          .firstOrNull;

      diagMap['queryRestored'] = <String, dynamic>{
        'pass': queryResult.pass,
        'assetsCount': queryResult.assets.length,
        'state': foundAvailability?.state.name,
        'isPlayableOffline': foundAvailability?.isPlayableOffline,
        'assetUri': foundAvailability?.assetUri?.toString(),
        'hasAssetUri': foundAvailability?.assetUri != null,
        'downloadedBytes': foundAvailability?.downloadedBytes,
        'raw': queryResult.raw,
      };

      if (!queryResult.pass ||
          foundAvailability == null ||
          !foundAvailability.isPlayableOffline ||
          foundAvailability.state != VGStreamingOfflineAssetState.available ||
          foundAvailability.assetUri == null) {
        throw Exception(
          'Restore Step 1 queryAvailability failed to find restored asset: '
          'pass=${queryResult.pass}, state=${foundAvailability?.state.name}, '
          'isPlayableOffline=${foundAvailability?.isPlayableOffline}, '
          'assetUri=${foundAvailability?.assetUri}, raw=${queryResult.raw}',
        );
      }

      restoredAvailability = foundAvailability;

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_QUERY_RESTORED: DONE '
        '(pass=${queryResult.pass}, state=${restoredAvailability.state.name}, '
        'isPlayable=${restoredAvailability.isPlayableOffline}, assetUri=${restoredAvailability.assetUri})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 2: getStatus() for restored asset
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_GET_STATUS: START');
      _updateStatus('Restore Step 2/8: Getting restored asset status…');

      final statusResult = await offlineClient
          .getStatus(requestId: _kRequestId, sourceKey: _kSourceKey)
          .timeout(_kOperationTimeout);

      diagMap['getStatus'] = <String, dynamic>{
        'requestId': statusResult.requestId,
        'sourceKey': statusResult.sourceKey,
        'state': statusResult.state.name,
        'assetUri': statusResult.assetUri?.toString(),
        'hasAssetUri': statusResult.assetUri != null,
        'bytesDownloaded': statusResult.bytesDownloaded,
        'totalBytes': statusResult.totalBytes,
        'diagnostics': statusResult.diagnostics,
      };

      if (statusResult.state !=
              VGStreamingOfflineAssetDownloadState.succeeded ||
          statusResult.assetUri == null) {
        throw Exception(
          'Restore Step 2 getStatus failed: state=${statusResult.state.name}, '
          'assetUri=${statusResult.assetUri}, diagnostics=${statusResult.diagnostics}',
        );
      }

      if (statusResult.assetUri != restoredAvailability.assetUri) {
        throw Exception(
          'Restore Step 2 assetUri mismatch: statusUri=${statusResult.assetUri}, '
          'queryUri=${restoredAvailability.assetUri}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_GET_STATUS: DONE '
        '(state=${statusResult.state.name}, assetUri=${statusResult.assetUri}, bytes=${statusResult.bytesDownloaded})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 3: Open playback of restored asset via route/preparation planners
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_OPEN_PLAYBACK: START');
      _updateStatus('Restore Step 3/8: Opening playback for restored asset…');

      final sourceDescriptor = VGStreamingSourceDescriptor(
        key: _kSourceKey,
        uri: Uri.parse(_kHlsUri),
        initialWidth: 1280,
        initialHeight: 720,
        formatHint: VGStreamingFormatHint.hls,
        autoPlay: true,
        cacheOptions: null,
      );

      const preflightReport = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'preflight_passed',
        requestedNetworkProfile: 'STABLE',
        recommendedNetworkProfile: 'STABLE',
        recommendedNetworkPolicy: <String, Object?>{'profile': 'STABLE'},
        totalReports: 1,
        passedReports: 1,
        failedReports: 0,
        warnings: <String>['advisory_preflight_info'],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: true,
        playbackMutation: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: 'status=OK',
        diagnostics: <String, Object?>{},
      );

      final playbackDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: VGStreamingSourceSet(sources: [sourceDescriptor]),
          preflightReport: preflightReport,
        ),
      );

      if (!playbackDecision.canOpenPlayback) {
        throw Exception(
          'Restore Step 3 playbackDecision.canOpenPlayback is false: ${playbackDecision.decision}',
        );
      }

      final routePlan = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: playbackDecision,
          preferOffline: true,
          allowNetworkFallback: true,
          offlineAssetsBySourceKey: {_kSourceKey: restoredAvailability},
        ),
      );

      final prepPlan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
        VGStreamingOfflinePlaybackPreparationRequest(
          playbackDecision: playbackDecision,
          sourceSet: VGStreamingSourceSet(sources: [sourceDescriptor]),
          preferOffline: true,
          allowNetworkFallback: true,
          offlineAssetsBySourceKey: {_kSourceKey: restoredAvailability},
        ),
      );

      diagMap['routePlan'] = <String, dynamic>{
        'mode': routePlan.mode.name,
        'decision': routePlan.decision,
        'selectedKey': routePlan.selectedKey,
        'canOpenWithCurrentPlaybackClient':
            routePlan.canOpenWithCurrentPlaybackClient,
        'requiresOfflineAssetPlayback': routePlan.requiresOfflineAssetPlayback,
        'playbackUri': routePlan.playbackOptions?.uri.toString(),
      };

      diagMap['preparationPlan'] = <String, dynamic>{
        'action': prepPlan.action.name,
        'canOpenNow': prepPlan.canOpenNow,
        'canOpenWithCurrentPlaybackClient':
            prepPlan.canOpenWithCurrentPlaybackClient,
        'requiresOfflineAssetPlayback': prepPlan.requiresOfflineAssetPlayback,
        'selectedKey': prepPlan.selectedKey,
        'routeMode': prepPlan.routePlan.mode.name,
      };

      if (routePlan.mode != VGStreamingPlaybackRouteMode.offlineAsset ||
          routePlan.decision != 'offline_asset_ready' ||
          routePlan.playbackOptions == null ||
          routePlan.playbackOptions!.uri != restoredAvailability.assetUri ||
          !routePlan.canOpenWithCurrentPlaybackClient ||
          prepPlan.action !=
              VGStreamingOfflinePlaybackPreparationAction.openOfflineAsset ||
          !prepPlan.canOpenNow ||
          !prepPlan.canOpenWithCurrentPlaybackClient) {
        throw Exception(
          'Restore Step 3 route/preparation plan assertion failed: '
          'routeMode=${routePlan.mode.name}, decision=${routePlan.decision}, '
          'prepAction=${prepPlan.action.name}, canOpenNow=${prepPlan.canOpenNow}',
        );
      }

      final session = await playbackClient
          .open(routePlan.playbackOptions!)
          .timeout(_kOperationTimeout);
      activePlaybackSession = session;

      diagMap['openSession'] = <String, dynamic>{
        'pass': session.pass,
        'textureId': session.textureId,
        'state': session.state.name,
        'raw': session.raw,
      };

      if (!session.pass || session.textureId < 0) {
        throw Exception(
          'Restore Step 3 open local asset failed: pass=${session.pass}, '
          'textureId=${session.textureId}, raw=${session.raw}',
        );
      }

      if (mounted) {
        setState(() {
          _textureId = session.textureId;
        });
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_OPEN_PLAYBACK: DONE '
        '(pass=${session.pass}, textureId=${session.textureId})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 4: Poll playback status until frames and dimensions render
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_VERIFY_RENDER: START');
      _updateStatus('Restore Step 4/8: Polling playback frames & dimensions…');

      final renderStart = DateTime.now();
      final renderDeadline = renderStart.add(_kPlaybackRenderTimeout);
      VGStreamingPlaybackSession? renderedStatus;

      while (DateTime.now().isBefore(renderDeadline)) {
        final status = await playbackClient
            .getStatus(session)
            .timeout(_kOperationTimeout);

        if (status.state == VGStreamingPlaybackState.failed ||
            status.state == VGStreamingPlaybackState.surfaceLost ||
            status.state == VGStreamingPlaybackState.unsupported) {
          throw Exception(
            'Restore Step 4 playback encountered invalid/failed state: ${status.state.name}, '
            'raw=${status.raw}',
          );
        }

        if (status.renderedFrames > 0 &&
            status.effectiveDisplayWidth > 0 &&
            status.effectiveDisplayHeight > 0) {
          renderedStatus = status;
          break;
        }

        _updateStatus(
          'Restore Step 4/8: Polling playback (frames=${status.renderedFrames}, '
          'dims=${status.effectiveDisplayWidth}x${status.effectiveDisplayHeight}, '
          'state=${status.state.name})…',
        );

        await Future<void>.delayed(_kPlaybackPollInterval);
      }

      if (renderedStatus == null) {
        final lastStatus = await playbackClient
            .getStatus(session)
            .timeout(_kOperationTimeout);
        throw Exception(
          'Restore Step 4 playback render verification timed out: '
          'renderedFrames=${lastStatus.renderedFrames}, '
          'state=${lastStatus.state.name}, '
          'effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
          'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, '
          'raw=${lastStatus.raw}',
        );
      }

      final renderDurationMs = DateTime.now()
          .difference(renderStart)
          .inMilliseconds;
      diagMap['playbackRender'] = <String, dynamic>{
        'pass': true,
        'textureId': renderedStatus.textureId,
        'renderedFrames': renderedStatus.renderedFrames,
        'state': renderedStatus.state.name,
        'displayWidth': renderedStatus.displayWidth,
        'displayHeight': renderedStatus.displayHeight,
        'effectiveDisplayWidth': renderedStatus.effectiveDisplayWidth,
        'effectiveDisplayHeight': renderedStatus.effectiveDisplayHeight,
        'rotationDegrees': renderedStatus.rotationDegrees,
        'durationMs': renderedStatus.durationMs,
        'positionMs': renderedStatus.positionMs,
        'bufferedPositionMs': renderedStatus.bufferedPositionMs,
        'bufferedPercent': renderedStatus.bufferedPercent,
        'renderDurationMs': renderDurationMs,
        'raw': renderedStatus.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_VERIFY_RENDER: DONE '
        '(renderedFrames=${renderedStatus.renderedFrames}, state=${renderedStatus.state.name}, '
        'dims=${renderedStatus.effectiveDisplayWidth}x${renderedStatus.effectiveDisplayHeight}, '
        'durationMs=$renderDurationMs)',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 5: Stop & dispose playback session
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_STOP_PLAYBACK: START');
      _updateStatus('Restore Step 5/8: Stopping & disposing playback session…');

      final stopRes = await playbackClient
          .stop(session)
          .timeout(_kOperationTimeout);
      await playbackClient.dispose(session).timeout(_kOperationTimeout);
      activePlaybackSession = null;

      if (mounted) {
        setState(() {
          _textureId = null;
        });
      }

      diagMap['playbackCleanup'] = <String, dynamic>{
        'stopPass': stopRes.pass,
        'stopState': stopRes.state.name,
      };

      if (!stopRes.pass || stopRes.state != VGStreamingPlaybackState.idle) {
        throw Exception(
          'Restore Step 5 stop failed: stopPass=${stopRes.pass}, '
          'stopState=${stopRes.state.name}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_STOP_PLAYBACK: DONE '
        '(stopState=${stopRes.state.name})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 6: Delete offline asset
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_DELETE_ASSET: START');
      _updateStatus('Restore Step 6/8: Deleting offline asset…');

      final deleteResult = await offlineClient
          .deleteAsset(requestId: _kRequestId, sourceKey: _kSourceKey)
          .timeout(_kOperationTimeout);
      assetDeleted = true;

      diagMap['deleteAsset'] = <String, dynamic>{
        'pass': deleteResult.pass,
        'state': deleteResult.state.name,
        'requestId': deleteResult.requestId,
        'sourceKey': deleteResult.sourceKey,
        'freedBytes': deleteResult.freedBytes,
        'removedCount': deleteResult.removedCount,
        'raw': deleteResult.raw,
      };

      if (!deleteResult.pass ||
          (deleteResult.state != VGStreamingOfflineAssetCommandState.deleted &&
              deleteResult.state !=
                  VGStreamingOfflineAssetCommandState.notFoundOrTerminal)) {
        throw Exception(
          'Restore Step 6 deleteAsset() failed: pass=${deleteResult.pass}, '
          'state=${deleteResult.state.name}, raw=${deleteResult.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_DELETE_ASSET: DONE '
        '(pass=${deleteResult.pass}, state=${deleteResult.state.name})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 7: Verify asset deleted via queryAvailability()
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_VERIFY_DELETED: START');
      _updateStatus('Restore Step 7/8: Verifying asset deleted…');

      final postDeleteQuery = await offlineClient
          .queryAvailability(sourceKeys: [_kSourceKey])
          .timeout(_kOperationTimeout);
      final postDeleteAvailability = postDeleteQuery.assets
          .where((a) => a.sourceKey == _kSourceKey)
          .firstOrNull;

      diagMap['verifyDeleted'] = <String, dynamic>{
        'pass': postDeleteQuery.pass,
        'assetsCount': postDeleteQuery.assets.length,
        'state': postDeleteAvailability?.state.name,
        'isPlayableOffline': postDeleteAvailability?.isPlayableOffline,
        'raw': postDeleteQuery.raw,
      };

      if (!postDeleteQuery.pass ||
          (postDeleteAvailability != null &&
              (postDeleteAvailability.isPlayableOffline ||
                  (postDeleteAvailability.state !=
                          VGStreamingOfflineAssetState.unavailable &&
                      postDeleteAvailability.state !=
                          VGStreamingOfflineAssetState.unknown)))) {
        throw Exception(
          'Restore Step 7 verify deleted failed: pass=${postDeleteQuery.pass}, '
          'state=${postDeleteAvailability?.state.name}, '
          'isPlayableOffline=${postDeleteAvailability?.isPlayableOffline}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_VERIFY_DELETED: DONE '
        '(pass=${postDeleteQuery.pass}, state=${postDeleteAvailability?.state.name})',
      );

      // ───────────────────────────────────────────────────────────────────────
      // Step 8: Final clearAssets() cleanup
      // ───────────────────────────────────────────────────────────────────────
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_FINAL_CLEAR: START');
      _updateStatus('Restore Step 8/8: Final clearAssets() cleanup…');

      final finalClear = await offlineClient.clearAssets().timeout(
        _kOperationTimeout,
      );
      final finalClearPass =
          finalClear.pass &&
          (finalClear.state == VGStreamingOfflineAssetCommandState.cleared ||
              finalClear.state ==
                  VGStreamingOfflineAssetCommandState.notFoundOrTerminal);

      diagMap['finalClear'] = <String, dynamic>{
        'pass': finalClearPass,
        'state': finalClear.state.name,
        'freedBytes': finalClear.freedBytes,
        'removedCount': finalClear.removedCount,
        'raw': finalClear.raw,
      };

      if (!finalClearPass) {
        throw Exception(
          'Restore Step 8 final clearAssets() failed: pass=${finalClear.pass}, '
          'state=${finalClear.state.name}, raw=${finalClear.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_COLD_RESTORE_STEP_FINAL_CLEAR: DONE '
        '(pass=${finalClear.pass}, state=${finalClear.state.name})',
      );

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_ERROR: $error\n$stack');
      diagMap['error'] = error.toString();
      allPass = false;
    } finally {
      // Best-effort cleanup for playback session if still open
      if (activePlaybackSession != null &&
          activePlaybackSession.textureId >= 0) {
        try {
          await playbackClient
              .stop(activePlaybackSession)
              .timeout(_kOperationTimeout);
        } catch (_) {}
        try {
          await playbackClient
              .dispose(activePlaybackSession)
              .timeout(_kOperationTimeout);
        } catch (_) {}
        activePlaybackSession = null;
      }

      // If asset was not deleted yet, attempt deletion
      if (!assetDeleted) {
        try {
          final cleanupDelete = await offlineClient
              .deleteAsset(requestId: _kRequestId, sourceKey: _kSourceKey)
              .timeout(_kOperationTimeout);
          diagMap['cleanupDelete'] = <String, dynamic>{
            'pass': cleanupDelete.pass,
            'state': cleanupDelete.state.name,
          };
        } catch (_) {}
      }

      // If allPass was not reached, attempt a final clear
      if (!allPass) {
        try {
          await offlineClient.clearAssets().timeout(_kOperationTimeout);
        } catch (_) {}
      }
    }

    diagMap['pass'] = allPass;

    // ignore: avoid_print
    print('IOS_STREAMING_OFFLINE_COLD_RESTORE_JSON:${jsonEncode(diagMap)}');

    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_COLD_RESTORE_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'RESTORE PASS'
            : 'RESTORE FAIL: ${diagMap['error']}';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_textureId != null) ...[
                  SizedBox(
                    width: 320,
                    height: 180,
                    child: Texture(textureId: _textureId!),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 12),
                Text(
                  'Phase: $_kColdPhase | Elapsed: ${_elapsedSeconds}s',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
