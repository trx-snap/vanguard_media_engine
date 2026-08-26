// Vanguard iOS True-DAG Phase 4C6H3C: Offline HLS foreground lifecycle public API physical smoke test.
//
// Sequentially verifies:
//   1. Initial Clear: Clears offline asset storage via VGStreamingOfflineAssetClient.clearAssets().
//   2. Availability Check: Queries availability for HLS key, asserting pass and unavailable/not playable.
//   3. DASH Rejection: Attempts DASH acquisition start, asserting pass false and unsupported (dash_offline_deferred).
//   4. LL-HLS Rejection: Attempts LL-HLS acquisition start, asserting pass false and unsupported (low_latency_offline_constrained).
//   5. HLS Start: Starts standard HLS acquisition, asserting pass true and state accepted (AVAssetDownloadTask created).
//   6. Immediate Status: getStatus() immediately after accepted returns active/terminal state (queued/running/succeeded/cancelled).
//   7. SourceKey Fallback: getStatus() with missing requestId falls back to sourceKey and returns tracked record.
//   8. Cancellation: cancelAcquisition() on active task returns pass true and cancelRequested.
//   9. Cancellation Polling: Polls getStatus() up to 15s until task reaches cancelled (or succeeded).
//  10. Missing Cancellation: cancelAcquisition() on missing requestId returns pass true and notFoundOrTerminal.
//  11. Deletion: deleteAsset() by sourceKey returns pass true and deleted/notFoundOrTerminal.
//  12. Final Availability: queryAvailability() confirms asset is unavailable/not playable.
//  13. Final Cleanup: Clears offline asset storage in finally block; failure fails the harness.
//
// Verification Invariants & Boundaries:
// - Standalone Flutter app target for iOS physical devices.
// - Imports public package barrel only (package:vanguard_media_engine/vanguard_media_engine.dart).
// - No direct MethodChannel or package:flutter/services.dart imports.
// - Timeouts on every asynchronous operation.
// - Progress text and periodic timer updates.
// - Emits structured START/DONE/ERROR step lines, JSON diagnostic line, and terminal PASS/FAIL markers.
// - exit(0) on pass, exit(1) on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kHlsUri =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';
const String _kDashUri =
    'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd';
const String _kLlHlsUri =
    'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8';

const int _kEstimatedBytes = 65536;
const Duration _kOperationTimeout = Duration(seconds: 15);
const Duration _kPollTimeout = Duration(seconds: 15);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeApp());
}

class IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeAppState();
}

class _IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeAppState
    extends State<IosStreamingOfflineAssetLifecyclePublicApiPhysicalSmokeApp> {
  String _status = 'Initializing Phase 4C6H3C iOS physical smoke…';
  int _elapsedSeconds = 0;
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

    final client = VGStreamingOfflineAssetClient();
    final suffix = DateTime.now().millisecondsSinceEpoch;

    final hlsSourceKey = 'phase4c6h3c_hls';
    final hlsRequestId = 'phase4c6h3c_hls_$suffix';

    final dashSourceKey = 'phase4c6h3c_dash';
    final dashRequestId = 'phase4c6h3c_dash_$suffix';

    final llHlsSourceKey = 'phase4c6h3c_ll_hls';
    final llHlsRequestId = 'phase4c6h3c_ll_hls_$suffix';

    final missingRequestId = 'missing_$suffix';

    final diagMap = <String, dynamic>{
      'phase': 'Phase4C6H3C',
      'target': 'ios_physical',
      'suffix': suffix,
    };
    bool allPass = false;

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Initial clearAssets()
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_INITIAL_CLEAR: START');
      _updateStatus('Step 1/12: Initial clearAssets() baseline…');

      final initialClear = await client.clearAssets().timeout(
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
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_INITIAL_CLEAR: DONE '
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
      // Step 2: queryAvailability(sourceKeys: ['phase4c6h3c_hls'])
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_QUERY_UNAVAILABLE: START',
      );
      _updateStatus('Step 2/12: queryAvailability baseline (unavailable)…');

      final initialQuery = await client
          .queryAvailability(sourceKeys: [hlsSourceKey])
          .timeout(_kOperationTimeout);
      final hlsInitAvailability = initialQuery.assets
          .where((a) => a.sourceKey == hlsSourceKey)
          .firstOrNull;

      diagMap['initialQuery'] = <String, dynamic>{
        'pass': initialQuery.pass,
        'assetsCount': initialQuery.assets.length,
        'hlsState': hlsInitAvailability?.state.name,
        'hlsPlayable': hlsInitAvailability?.isPlayableOffline,
        'raw': initialQuery.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_QUERY_UNAVAILABLE: DONE '
        '(pass=${initialQuery.pass}, state=${hlsInitAvailability?.state.name})',
      );

      if (!initialQuery.pass ||
          hlsInitAvailability == null ||
          hlsInitAvailability.isPlayableOffline ||
          (hlsInitAvailability.state !=
                  VGStreamingOfflineAssetState.unavailable &&
              hlsInitAvailability.state !=
                  VGStreamingOfflineAssetState.unknown)) {
        throw Exception(
          'Step 2 queryAvailability baseline failed: pass=${initialQuery.pass}, '
          'hlsState=${hlsInitAvailability?.state.name}, isPlayableOffline=${hlsInitAvailability?.isPlayableOffline}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: DASH start request (unsupported)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_DASH_START: START');
      _updateStatus('Step 3/12: DASH acquisition start (expect unsupported)…');

      final dashReq = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: dashRequestId,
        sourceKey: dashSourceKey,
        uri: Uri.parse(_kDashUri),
        formatHint: VGStreamingFormatHint.dash,
        estimatedBytes: _kEstimatedBytes,
      );

      final dashResult = await client
          .startAcquisition(dashReq)
          .timeout(_kOperationTimeout);
      diagMap['dashStart'] = <String, dynamic>{
        'pass': dashResult.pass,
        'state': dashResult.state.name,
        'raw': dashResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_DASH_START: DONE '
        '(pass=${dashResult.pass}, state=${dashResult.state.name}, raw=${dashResult.raw})',
      );

      if (dashResult.pass ||
          dashResult.state !=
              VGStreamingOfflineAssetAcquisitionStartState.unsupported ||
          !dashResult.raw.contains('dash_offline_deferred')) {
        throw Exception(
          'Step 3 DASH start failed: pass=${dashResult.pass}, '
          'state=${dashResult.state.name}, raw=${dashResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: LL-HLS start request (unsupported)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_LL_HLS_START: START');
      _updateStatus(
        'Step 4/12: LL-HLS acquisition start (expect unsupported)…',
      );

      final llHlsReq = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: llHlsRequestId,
        sourceKey: llHlsSourceKey,
        uri: Uri.parse(_kLlHlsUri),
        formatHint: VGStreamingFormatHint.hls,
        requireLlHlsTags: true,
        estimatedBytes: _kEstimatedBytes,
      );

      final llHlsResult = await client
          .startAcquisition(llHlsReq)
          .timeout(_kOperationTimeout);
      diagMap['llHlsStart'] = <String, dynamic>{
        'pass': llHlsResult.pass,
        'state': llHlsResult.state.name,
        'raw': llHlsResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_LL_HLS_START: DONE '
        '(pass=${llHlsResult.pass}, state=${llHlsResult.state.name}, raw=${llHlsResult.raw})',
      );

      if (llHlsResult.pass ||
          llHlsResult.state !=
              VGStreamingOfflineAssetAcquisitionStartState.unsupported ||
          !llHlsResult.raw.contains('low_latency_offline_constrained')) {
        throw Exception(
          'Step 4 LL-HLS start failed: pass=${llHlsResult.pass}, '
          'state=${llHlsResult.state.name}, raw=${llHlsResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 5: HLS start request (accepted)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_HLS_START: START');
      _updateStatus('Step 5/12: HLS acquisition start (expect accepted)…');

      final hlsReq = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: hlsRequestId,
        sourceKey: hlsSourceKey,
        uri: Uri.parse(_kHlsUri),
        formatHint: VGStreamingFormatHint.hls,
        requireLlHlsTags: false,
        estimatedBytes: _kEstimatedBytes,
      );

      final hlsStartResult = await client
          .startAcquisition(hlsReq, minimumFreeBytes: 0)
          .timeout(_kOperationTimeout);
      diagMap['hlsStart'] = <String, dynamic>{
        'pass': hlsStartResult.pass,
        'state': hlsStartResult.state.name,
        'requestId': hlsStartResult.requestId,
        'sourceKey': hlsStartResult.sourceKey,
        'storageGuardPass': hlsStartResult.storageGuardPass,
        'raw': hlsStartResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_HLS_START: DONE '
        '(pass=${hlsStartResult.pass}, state=${hlsStartResult.state.name})',
      );

      if (!hlsStartResult.pass ||
          hlsStartResult.state !=
              VGStreamingOfflineAssetAcquisitionStartState.accepted) {
        throw Exception(
          'Step 5 HLS start failed: pass=${hlsStartResult.pass}, '
          'state=${hlsStartResult.state.name}, raw=${hlsStartResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 6: getStatus() immediately after accepted
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_GET_STATUS: START');
      _updateStatus('Step 6/12: getStatus() immediately after accepted…');

      final immediateStatus = await client
          .getStatus(requestId: hlsRequestId, sourceKey: hlsSourceKey)
          .timeout(_kOperationTimeout);
      diagMap['immediateStatus'] = <String, dynamic>{
        'requestId': immediateStatus.requestId,
        'sourceKey': immediateStatus.sourceKey,
        'state': immediateStatus.state.name,
        'bytesDownloaded': immediateStatus.bytesDownloaded,
        'totalBytes': immediateStatus.totalBytes,
        'raw':
            immediateStatus.diagnostics['raw'] ??
            immediateStatus.errorMessage ??
            '',
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_GET_STATUS: DONE '
        '(state=${immediateStatus.state.name}, bytes=${immediateStatus.bytesDownloaded})',
      );

      final validImmediateStates = <VGStreamingOfflineAssetDownloadState>{
        VGStreamingOfflineAssetDownloadState.queued,
        VGStreamingOfflineAssetDownloadState.running,
        VGStreamingOfflineAssetDownloadState.succeeded,
        VGStreamingOfflineAssetDownloadState.cancelled,
      };

      if (!validImmediateStates.contains(immediateStatus.state) ||
          immediateStatus.state ==
              VGStreamingOfflineAssetDownloadState.notFound ||
          immediateStatus.state ==
              VGStreamingOfflineAssetDownloadState.unsupported ||
          immediateStatus.state ==
              VGStreamingOfflineAssetDownloadState.unknown ||
          immediateStatus.state ==
              VGStreamingOfflineAssetDownloadState.failed) {
        throw Exception(
          'Step 6 getStatus() invalid immediate state: state=${immediateStatus.state.name}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 7: SourceKey fallback getStatus()
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_SOURCE_KEY_FALLBACK: START',
      );
      _updateStatus('Step 7/12: getStatus() sourceKey fallback resolution…');

      final fallbackStatus = await client
          .getStatus(requestId: missingRequestId, sourceKey: hlsSourceKey)
          .timeout(_kOperationTimeout);
      diagMap['sourceKeyFallback'] = <String, dynamic>{
        'requestedId': missingRequestId,
        'sourceKey': fallbackStatus.sourceKey,
        'resolvedRequestId': fallbackStatus.requestId,
        'state': fallbackStatus.state.name,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_SOURCE_KEY_FALLBACK: DONE '
        '(sourceKey=${fallbackStatus.sourceKey}, resolvedId=${fallbackStatus.requestId}, state=${fallbackStatus.state.name})',
      );

      if (fallbackStatus.sourceKey != hlsSourceKey ||
          fallbackStatus.state ==
              VGStreamingOfflineAssetDownloadState.notFound ||
          fallbackStatus.state ==
              VGStreamingOfflineAssetDownloadState.unsupported ||
          fallbackStatus.state ==
              VGStreamingOfflineAssetDownloadState.unknown ||
          fallbackStatus.state == VGStreamingOfflineAssetDownloadState.failed) {
        throw Exception(
          'Step 7 sourceKey fallback getStatus() failed: sourceKey=${fallbackStatus.sourceKey}, '
          'resolvedRequestId=${fallbackStatus.requestId}, state=${fallbackStatus.state.name}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 8: cancelAcquisition() on active task
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_CANCEL: START');
      _updateStatus('Step 8/12: cancelAcquisition() on active task…');

      final cancelResult = await client
          .cancelAcquisition(hlsRequestId)
          .timeout(_kOperationTimeout);
      diagMap['cancelResult'] = <String, dynamic>{
        'pass': cancelResult.pass,
        'state': cancelResult.state.name,
        'requestId': cancelResult.requestId,
        'sourceKey': cancelResult.sourceKey,
        'raw': cancelResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_CANCEL: DONE '
        '(pass=${cancelResult.pass}, state=${cancelResult.state.name})',
      );

      if (!cancelResult.pass ||
          cancelResult.state !=
              VGStreamingOfflineAssetCommandState.cancelRequested) {
        throw Exception(
          'Step 8 cancelAcquisition() failed: pass=${cancelResult.pass}, '
          'state=${cancelResult.state.name}, raw=${cancelResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 9: Poll getStatus() until cancelled (or succeeded)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_POLL_CANCELLED: START');
      _updateStatus('Step 9/12: Polling getStatus() until cancelled…');

      final pollStart = DateTime.now();
      final pollDeadline = pollStart.add(_kPollTimeout);
      VGStreamingOfflineAssetDownloadStatus? finalPollStatus;

      while (DateTime.now().isBefore(pollDeadline)) {
        final status = await client
            .getStatus(requestId: hlsRequestId, sourceKey: hlsSourceKey)
            .timeout(_kOperationTimeout);

        if (status.state == VGStreamingOfflineAssetDownloadState.failed ||
            status.state == VGStreamingOfflineAssetDownloadState.unsupported ||
            status.state == VGStreamingOfflineAssetDownloadState.notFound ||
            status.state == VGStreamingOfflineAssetDownloadState.unknown) {
          throw Exception(
            'Step 9 poll getStatus() encountered invalid/failed state: ${status.state.name}',
          );
        }

        if (status.state == VGStreamingOfflineAssetDownloadState.cancelled ||
            status.state == VGStreamingOfflineAssetDownloadState.succeeded) {
          finalPollStatus = status;
          break;
        }
        await Future<void>.delayed(_kPollInterval);
      }

      if (finalPollStatus == null) {
        throw Exception(
          'Step 9 timed out waiting for cancelled/succeeded state for "$hlsRequestId"',
        );
      }

      final pollDurationMs = DateTime.now()
          .difference(pollStart)
          .inMilliseconds;
      diagMap['pollCancel'] = <String, dynamic>{
        'finalState': finalPollStatus.state.name,
        'pollDurationMs': pollDurationMs,
        'bytesDownloaded': finalPollStatus.bytesDownloaded,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_POLL_CANCELLED: DONE '
        '(finalState=${finalPollStatus.state.name}, durationMs=$pollDurationMs)',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 10: cancelAcquisition() on missing requestId
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_MISSING_CANCEL: START');
      _updateStatus('Step 10/12: cancelAcquisition() on missing requestId…');

      final missingCancelResult = await client
          .cancelAcquisition(missingRequestId)
          .timeout(_kOperationTimeout);
      diagMap['missingCancel'] = <String, dynamic>{
        'pass': missingCancelResult.pass,
        'state': missingCancelResult.state.name,
        'requestId': missingCancelResult.requestId,
        'raw': missingCancelResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_MISSING_CANCEL: DONE '
        '(pass=${missingCancelResult.pass}, state=${missingCancelResult.state.name})',
      );

      if (!missingCancelResult.pass ||
          missingCancelResult.state !=
              VGStreamingOfflineAssetCommandState.notFoundOrTerminal) {
        throw Exception(
          'Step 10 missing cancelAcquisition() failed: pass=${missingCancelResult.pass}, '
          'state=${missingCancelResult.state.name}, raw=${missingCancelResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 11: deleteAsset() by sourceKey
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_DELETE_ASSET: START');
      _updateStatus('Step 11/12: deleteAsset() by sourceKey…');

      final deleteResult = await client
          .deleteAsset(sourceKey: hlsSourceKey)
          .timeout(_kOperationTimeout);
      diagMap['deleteAsset'] = <String, dynamic>{
        'pass': deleteResult.pass,
        'state': deleteResult.state.name,
        'sourceKey': deleteResult.sourceKey,
        'freedBytes': deleteResult.freedBytes,
        'removedCount': deleteResult.removedCount,
        'raw': deleteResult.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_DELETE_ASSET: DONE '
        '(pass=${deleteResult.pass}, state=${deleteResult.state.name})',
      );

      if (!deleteResult.pass ||
          (deleteResult.state != VGStreamingOfflineAssetCommandState.deleted &&
              deleteResult.state !=
                  VGStreamingOfflineAssetCommandState.notFoundOrTerminal)) {
        throw Exception(
          'Step 11 deleteAsset() failed: pass=${deleteResult.pass}, '
          'state=${deleteResult.state.name}, raw=${deleteResult.raw}',
        );
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 12: Final queryAvailability()
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_QUERY: START');
      _updateStatus('Step 12/12: Final queryAvailability() check…');

      final finalQuery = await client
          .queryAvailability(sourceKeys: [hlsSourceKey])
          .timeout(_kOperationTimeout);
      final hlsFinalAvailability = finalQuery.assets
          .where((a) => a.sourceKey == hlsSourceKey)
          .firstOrNull;

      diagMap['finalQuery'] = <String, dynamic>{
        'pass': finalQuery.pass,
        'assetsCount': finalQuery.assets.length,
        'hlsState': hlsFinalAvailability?.state.name,
        'hlsPlayable': hlsFinalAvailability?.isPlayableOffline,
        'raw': finalQuery.raw,
      };

      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_QUERY: DONE '
        '(pass=${finalQuery.pass}, state=${hlsFinalAvailability?.state.name})',
      );

      if (!finalQuery.pass ||
          hlsFinalAvailability == null ||
          hlsFinalAvailability.isPlayableOffline ||
          (hlsFinalAvailability.state !=
                  VGStreamingOfflineAssetState.unavailable &&
              hlsFinalAvailability.state !=
                  VGStreamingOfflineAssetState.unknown)) {
        throw Exception(
          'Step 12 final queryAvailability failed: pass=${finalQuery.pass}, '
          'hlsState=${hlsFinalAvailability?.state.name}, isPlayableOffline=${hlsFinalAvailability?.isPlayableOffline}',
        );
      }

      allPass = true;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      diagMap['error'] = error.toString();
      allPass = false;
    } finally {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 13: Final clearAssets() cleanup
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_CLEAR: START');
      _updateStatus('Final clearAssets() cleanup…');

      try {
        final finalClear = await client.clearAssets().timeout(
          _kOperationTimeout,
        );
        final finalClearPass =
            finalClear.pass &&
            (finalClear.state == VGStreamingOfflineAssetCommandState.cleared ||
                finalClear.state ==
                    VGStreamingOfflineAssetCommandState.notFoundOrTerminal ||
                finalClear.pass);

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
            'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_CLEAR: FAILED '
            '(pass=${finalClear.pass}, state=${finalClear.state.name})',
          );
        } else {
          // ignore: avoid_print
          print(
            'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_CLEAR: DONE '
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
          'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_STEP_FINAL_CLEAR: ERROR ($clearError)',
        );
      }
    }

    diagMap['pass'] = allPass;

    // ignore: avoid_print
    print(
      'IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );

    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_OFFLINE_ASSET_LIFECYCLE_PUBLIC_API_PHYSICAL_FAIL');
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
