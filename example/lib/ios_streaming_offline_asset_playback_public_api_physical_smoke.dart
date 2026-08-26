// Copyright (c) Connects — Vanguard Phase 4C6H3D.
// iOS offline HLS asset playback public API physical smoke harness.
//
// Sequentially verifies:
//   1. Initial Clear: Clears offline asset storage via VGStreamingOfflineAssetClient.clearAssets().
//   2. Start Acquisition: Starts standard HLS acquisition via VGStreamingOfflineAssetClient.startAcquisition().
//   3. Wait Succeeded: Polls getStatus() until download completes with state succeeded and non-null assetUri.
//   4. Query Availability: Queries offline asset availability, verifying available state and matching assetUri.
//   5. Route Planning: Plans playback route via VGStreamingPlaybackRoutePlanner with preferOffline: true.
//   6. Preparation Planning: Evaluates host preparation plan via VGStreamingOfflinePlaybackPreparationPlanner.
//   7. Open Local Asset: Opens offline playback options via VGStreamingPlaybackClient.open().
//   8. Render Verification: Polls playback status until renderedFrames > 0 and dimensions > 0.
//   9. Stop & Dispose: Stops and disposes the active playback session.
//  10. Delete Asset: Deletes the downloaded offline asset via VGStreamingOfflineAssetClient.deleteAsset().
//  11. Final Cleanup: Clears offline asset storage in finally block; failure fails the harness.
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

// Short VOD stream for bounded offline-download and playback proof.
const String _kDefaultHlsUri =
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _kHlsUri = String.fromEnvironment(
  'VG_IOS_OFFLINE_PLAYBACK_HLS_URI',
  defaultValue: _kDefaultHlsUri,
);

const int _kEstimatedBytes = 65536;
const Duration _kOperationTimeout = Duration(seconds: 20);
const Duration _kDownloadPollTimeout = Duration(minutes: 6);
const Duration _kDownloadPollInterval = Duration(seconds: 1);
const Duration _kPlaybackRenderTimeout = Duration(seconds: 45);
const Duration _kPlaybackPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeApp());
}

class IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeAppState();
}

class _IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeAppState
    extends State<IosStreamingOfflineAssetPlaybackPublicApiPhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6H3D iOS offline playback smoke…';
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
    final suffix = DateTime.now().millisecondsSinceEpoch;

    final sourceKey = 'phase4c6h3d_hls';
    final requestId = 'phase4c6h3d_hls_$suffix';

    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6H3D',
      'target': 'ios_physical',
      'suffix': suffix,
      'hlsUri': _kHlsUri,
    };

    bool allPass = false;
    bool acquisitionAccepted = false;
    bool assetObserved = false;
    bool assetDeleted = false;
    VGStreamingPlaybackSession? activePlaybackSession;
    Uri? observedAssetUri;

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Initial clearAssets() baseline
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_INITIAL_CLEAR: START');
      _updateStatus('Step 1/10: Initial clearAssets() baseline…');

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
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_INITIAL_CLEAR: DONE '
        '(pass=${initialClear.pass}, state=${initialClear.state.name})',
      );

      if (!initialClear.pass ||
          (initialClear.state != VGStreamingOfflineAssetCommandState.cleared &&
              initialClear.state !=
                  VGStreamingOfflineAssetCommandState.notFoundOrTerminal)) {
        throw Exception(
          'Step 1 initial clearAssets() failed: pass=${initialClear.pass}, '
          'state=${initialClear.state.name}, raw=${initialClear.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: startAcquisition() for HLS
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_START_ACQUISITION: START',
      );
      _updateStatus('Step 2/10: Starting HLS asset acquisition…');

      final acquisitionReq = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: requestId,
        sourceKey: sourceKey,
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
                  startResult.requestId == requestId));

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
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_START_ACQUISITION: DONE '
        '(pass=${startResult.pass}, state=${startResult.state.name})',
      );

      if (!startPass) {
        throw Exception(
          'Step 2 startAcquisition() failed: pass=${startResult.pass}, '
          'state=${startResult.state.name}, raw=${startResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Poll getStatus() until succeeded with non-null assetUri
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_WAIT_SUCCEEDED: START');
      _updateStatus('Step 3/10: Waiting for HLS download completion…');

      final downloadStart = DateTime.now();
      final downloadDeadline = downloadStart.add(_kDownloadPollTimeout);
      VGStreamingOfflineAssetDownloadStatus? finalDownloadStatus;

      while (DateTime.now().isBefore(downloadDeadline)) {
        final status = await offlineClient
            .getStatus(requestId: requestId, sourceKey: sourceKey)
            .timeout(_kOperationTimeout);

        if (status.state == VGStreamingOfflineAssetDownloadState.failed ||
            status.state == VGStreamingOfflineAssetDownloadState.cancelled ||
            status.state == VGStreamingOfflineAssetDownloadState.expired ||
            status.state == VGStreamingOfflineAssetDownloadState.unsupported ||
            status.state == VGStreamingOfflineAssetDownloadState.notFound) {
          throw Exception(
            'Step 3 download encountered terminal failure state: ${status.state.name}, '
            'errorCode=${status.errorCode}, errorMessage=${status.errorMessage}, '
            'raw=${status.diagnostics}',
          );
        }

        if (status.state == VGStreamingOfflineAssetDownloadState.succeeded) {
          if (status.assetUri == null) {
            throw Exception(
              'Step 3 download reported succeeded but assetUri is null: '
              'raw=${status.diagnostics}',
            );
          }
          finalDownloadStatus = status;
          observedAssetUri = status.assetUri;
          assetObserved = true;
          break;
        }

        _updateStatus(
          'Step 3/10: Downloading HLS asset (${status.state.name}, '
          '${status.bytesDownloaded} bytes)…',
        );

        await Future<void>.delayed(_kDownloadPollInterval);
      }

      if (finalDownloadStatus == null || observedAssetUri == null) {
        throw Exception(
          'Step 3 timed out waiting for succeeded download of "$requestId"',
        );
      }

      final downloadDurationMs = DateTime.now()
          .difference(downloadStart)
          .inMilliseconds;
      diagMap['download'] = <String, dynamic>{
        'state': finalDownloadStatus.state.name,
        'assetUri': observedAssetUri.toString(),
        'bytesDownloaded': finalDownloadStatus.bytesDownloaded,
        'totalBytes': finalDownloadStatus.totalBytes,
        'downloadDurationMs': downloadDurationMs,
        'diagnostics': finalDownloadStatus.diagnostics,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_WAIT_SUCCEEDED: DONE '
        '(state=${finalDownloadStatus.state.name}, assetUri=$observedAssetUri, '
        'bytes=${finalDownloadStatus.bytesDownloaded}, durationMs=$downloadDurationMs)',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: queryAvailability() for sourceKey
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_QUERY_AVAILABILITY: START',
      );
      _updateStatus('Step 4/10: Querying offline asset availability…');

      final queryResult = await offlineClient
          .queryAvailability(sourceKeys: [sourceKey])
          .timeout(_kOperationTimeout);
      final hlsAvailability = queryResult.assets
          .where((a) => a.sourceKey == sourceKey)
          .firstOrNull;

      diagMap['queryAvailability'] = <String, dynamic>{
        'pass': queryResult.pass,
        'assetsCount': queryResult.assets.length,
        'state': hlsAvailability?.state.name,
        'isPlayableOffline': hlsAvailability?.isPlayableOffline,
        'assetUri': hlsAvailability?.assetUri?.toString(),
        'downloadedBytes': hlsAvailability?.downloadedBytes,
        'raw': queryResult.raw,
      };

      if (!queryResult.pass ||
          hlsAvailability == null ||
          !hlsAvailability.isPlayableOffline ||
          hlsAvailability.state != VGStreamingOfflineAssetState.available ||
          hlsAvailability.assetUri == null) {
        throw Exception(
          'Step 4 queryAvailability failed: pass=${queryResult.pass}, '
          'state=${hlsAvailability?.state.name}, '
          'isPlayableOffline=${hlsAvailability?.isPlayableOffline}, '
          'assetUri=${hlsAvailability?.assetUri}, raw=${queryResult.raw}',
        );
      }

      if (hlsAvailability.assetUri != observedAssetUri) {
        throw Exception(
          'Step 4 assetUri mismatch: observed=$observedAssetUri, '
          'query=${hlsAvailability.assetUri}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_QUERY_AVAILABILITY: DONE '
        '(pass=${queryResult.pass}, state=${hlsAvailability.state.name}, '
        'isPlayable=${hlsAvailability.isPlayableOffline}, assetUri=${hlsAvailability.assetUri})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: VGStreamingPlaybackRoutePlanner evaluation
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_ROUTE_PLAN: START');
      _updateStatus('Step 5/10: Planning streaming route for offline asset…');

      final sourceDescriptor = VGStreamingSourceDescriptor(
        key: sourceKey,
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
          'Step 5 playbackDecision.canOpenPlayback is false: ${playbackDecision.decision}',
        );
      }

      final routePlan = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: playbackDecision,
          preferOffline: true,
          allowNetworkFallback: true,
          offlineAssetsBySourceKey: {sourceKey: hlsAvailability},
        ),
      );

      diagMap['routePlan'] = <String, dynamic>{
        'mode': routePlan.mode.name,
        'decision': routePlan.decision,
        'selectedKey': routePlan.selectedKey,
        'canOpenWithCurrentPlaybackClient':
            routePlan.canOpenWithCurrentPlaybackClient,
        'requiresOfflineAssetPlayback': routePlan.requiresOfflineAssetPlayback,
        'hasPlaybackOptions': routePlan.playbackOptions != null,
        'playbackUri': routePlan.playbackOptions?.uri.toString(),
        'hasCacheOptions': routePlan.playbackOptions?.cacheOptions != null,
        'hasHttpHeaders': routePlan.playbackOptions?.httpHeaders != null,
        'warnings': routePlan.warnings,
        'diagnostics': routePlan.diagnostics,
      };

      if (routePlan.mode != VGStreamingPlaybackRouteMode.offlineAsset ||
          routePlan.decision != 'offline_asset_ready' ||
          routePlan.playbackOptions == null ||
          routePlan.playbackOptions!.uri != hlsAvailability.assetUri ||
          !routePlan.canOpenWithCurrentPlaybackClient ||
          routePlan.requiresOfflineAssetPlayback ||
          routePlan.playbackOptions!.cacheOptions != null ||
          routePlan.playbackOptions!.httpHeaders != null) {
        throw Exception(
          'Step 5 route plan assertion failed: mode=${routePlan.mode.name}, '
          'decision=${routePlan.decision}, '
          'canOpenWithCurrentPlaybackClient=${routePlan.canOpenWithCurrentPlaybackClient}, '
          'requiresOfflineAssetPlayback=${routePlan.requiresOfflineAssetPlayback}, '
          'playbackUri=${routePlan.playbackOptions?.uri}, '
          'cacheOptions=${routePlan.playbackOptions?.cacheOptions}, '
          'httpHeaders=${routePlan.playbackOptions?.httpHeaders}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_ROUTE_PLAN: DONE '
        '(mode=${routePlan.mode.name}, decision=${routePlan.decision}, '
        'canOpen=${routePlan.canOpenWithCurrentPlaybackClient})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: VGStreamingOfflinePlaybackPreparationPlanner evaluation
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_PREPARATION_PLAN: START',
      );
      _updateStatus('Step 6/10: Evaluating offline playback preparation plan…');

      final prepPlan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
        VGStreamingOfflinePlaybackPreparationRequest(
          playbackDecision: playbackDecision,
          sourceSet: VGStreamingSourceSet(sources: [sourceDescriptor]),
          preferOffline: true,
          allowNetworkFallback: true,
          offlineAssetsBySourceKey: {sourceKey: hlsAvailability},
        ),
      );

      diagMap['preparationPlan'] = <String, dynamic>{
        'action': prepPlan.action.name,
        'canOpenNow': prepPlan.canOpenNow,
        'canOpenWithCurrentPlaybackClient':
            prepPlan.canOpenWithCurrentPlaybackClient,
        'requiresOfflineAssetPlayback': prepPlan.requiresOfflineAssetPlayback,
        'shouldAcquireOfflineAsset': prepPlan.shouldAcquireOfflineAsset,
        'selectedKey': prepPlan.selectedKey,
        'routeMode': prepPlan.routePlan.mode.name,
        'warnings': prepPlan.warnings,
        'diagnostics': prepPlan.diagnostics,
      };

      if (prepPlan.action !=
              VGStreamingOfflinePlaybackPreparationAction.openOfflineAsset ||
          !prepPlan.canOpenNow ||
          !prepPlan.canOpenWithCurrentPlaybackClient ||
          prepPlan.requiresOfflineAssetPlayback ||
          prepPlan.routePlan.mode !=
              VGStreamingPlaybackRouteMode.offlineAsset) {
        throw Exception(
          'Step 6 preparation plan assertion failed: action=${prepPlan.action.name}, '
          'canOpenNow=${prepPlan.canOpenNow}, '
          'canOpenWithCurrentPlaybackClient=${prepPlan.canOpenWithCurrentPlaybackClient}, '
          'requiresOfflineAssetPlayback=${prepPlan.requiresOfflineAssetPlayback}, '
          'routeMode=${prepPlan.routePlan.mode.name}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_PREPARATION_PLAN: DONE '
        '(action=${prepPlan.action.name}, canOpenNow=${prepPlan.canOpenNow})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 7: Open local offline asset with VGStreamingPlaybackClient
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_OPEN_LOCAL_ASSET: START',
      );
      _updateStatus(
        'Step 7/10: Opening local offline asset in playback client…',
      );

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
          'Step 7 open local asset failed: pass=${session.pass}, '
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
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_OPEN_LOCAL_ASSET: DONE '
        '(pass=${session.pass}, textureId=${session.textureId})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 8: Poll playback status until frames and dimensions render
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_RENDER_STATUS: START');
      _updateStatus('Step 8/10: Polling playback frames & dimensions…');

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
            'Step 8 playback encountered invalid/failed state: ${status.state.name}, '
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
          'Step 8/10: Polling playback (frames=${status.renderedFrames}, '
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
          'Step 8 playback render verification timed out: '
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
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_RENDER_STATUS: DONE '
        '(renderedFrames=${renderedStatus.renderedFrames}, state=${renderedStatus.state.name}, '
        'dims=${renderedStatus.effectiveDisplayWidth}x${renderedStatus.effectiveDisplayHeight}, '
        'durationMs=$renderDurationMs)',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 9: Stop & dispose playback session
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_STOP_DISPOSE: START');
      _updateStatus('Step 9/10: Stopping & disposing playback session…');

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
          'Step 9 stop failed: stopPass=${stopRes.pass}, '
          'stopState=${stopRes.state.name}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_STOP_DISPOSE: DONE '
        '(stopState=${stopRes.state.name})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 10: Delete offline asset
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_DELETE_ASSET: START');
      _updateStatus('Step 10/10: Deleting offline asset…');

      final deleteResult = await offlineClient
          .deleteAsset(requestId: requestId, sourceKey: sourceKey)
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
          'Step 10 deleteAsset() failed: pass=${deleteResult.pass}, '
          'state=${deleteResult.state.name}, raw=${deleteResult.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_DELETE_ASSET: DONE '
        '(pass=${deleteResult.pass}, state=${deleteResult.state.name})',
      );

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
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

      // If failure occurred before completion, attempt cancellation if acquisition was accepted
      if (!allPass && acquisitionAccepted && !assetObserved) {
        try {
          final cancelRes = await offlineClient
              .cancelAcquisition(requestId)
              .timeout(_kOperationTimeout);
          diagMap['cleanupCancel'] = <String, dynamic>{
            'pass': cancelRes.pass,
            'state': cancelRes.state.name,
          };
        } catch (cancelErr) {
          diagMap['cleanupCancel'] = <String, dynamic>{
            'pass': false,
            'error': cancelErr.toString(),
          };
        }
      }

      // If asset was accepted/observed and not yet deleted, attempt deletion
      if ((acquisitionAccepted || assetObserved) && !assetDeleted) {
        try {
          final cleanupDelete = await offlineClient
              .deleteAsset(requestId: requestId, sourceKey: sourceKey)
              .timeout(_kOperationTimeout);
          diagMap['cleanupDelete'] = <String, dynamic>{
            'pass': cleanupDelete.pass,
            'state': cleanupDelete.state.name,
          };
        } catch (delErr) {
          diagMap['cleanupDelete'] = <String, dynamic>{
            'pass': false,
            'error': delErr.toString(),
          };
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 11: Final clearAssets() cleanup
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_FINAL_CLEAR: START');
      _updateStatus('Final clearAssets() cleanup…');

      try {
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
          allPass = false;
          diagMap['error'] ??= 'Final clearAssets() failed';
          // ignore: avoid_print
          print(
            'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_FINAL_CLEAR: FAILED '
            '(pass=${finalClear.pass}, state=${finalClear.state.name})',
          );
        } else {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_FINAL_CLEAR: DONE '
            '(pass=${finalClear.pass}, state=${finalClear.state.name})',
          );
        }
      } catch (clearError) {
        allPass = false;
        diagMap['finalClear'] = <String, dynamic>{
          'pass': false,
          'error': clearError.toString(),
        };
        diagMap['error'] ??= clearError.toString();
        // ignore: avoid_print
        print(
          'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_STEP_FINAL_CLEAR: ERROR ($clearError)',
        );
      }
    }

    diagMap['pass'] = allPass;

    // ignore: avoid_print
    print(
      'IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );

    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL: ${diagMap['error']}';
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
                  'Elapsed: ${_elapsedSeconds}s',
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
