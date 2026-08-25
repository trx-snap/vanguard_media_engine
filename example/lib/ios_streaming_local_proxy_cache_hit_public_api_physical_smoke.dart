// Vanguard iOS True-DAG Phase 4C6H2B: iOS local proxy disk read-through cache storage & cache-hit proof.
//
// Sequentially verifies AVPlayer HLS playback with local proxy disk cache enabled:
//   1. Initial Clear: Clears playback cache via VGStreamingCacheClient.clear() to start from
//      a deterministic empty cache state (asserting pass, state=="cleared", afterBytes==0).
//   2. First Pass: Opens HLS stream with VGPlaybackCacheOptions(cacheEnabled: true).
//      Polls until frames render, cache size > 0, and raw contains proxyCacheMisses > 0.
//   3. Second Pass: Reopens same HLS stream with cache enabled.
//      Polls until frames render, cache size > 0, and raw contains proxyCacheHits > 0 & proxyCacheBytesRead > 0.
//   4. Final Cleanup: Clears playback cache even on failure.
//
// Invariants & Platform Truth:
// - Physical iOS device execution target.
// - Uses only public Dart APIs from package:vanguard_media_engine/vanguard_media_engine.dart.
// - Every async operation uses bounded timeout.
// - Guaranteed cleanup in finally blocks.
// - Does not claim full offline playback or zero network fetches (HLS manifests intentionally uncached).
// - Emits structured log markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _kHlsTestUri = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const int _kInitialWidth = 640;
const int _kInitialHeight = 360;
const Duration _kOperationTimeout = Duration(seconds: 25);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeApp());
}

class IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeAppState();
}

class _IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeAppState
    extends State<IosStreamingLocalProxyCacheHitPublicApiPhysicalSmokeApp> {
  final VGStreamingCacheClient _cacheClient = VGStreamingCacheClient();
  final VGStreamingPlaybackClient _playbackClient = VGStreamingPlaybackClient();
  String _status = 'Bootstrapping iOS streaming cache hit smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  int _extractNumericRawToken(String raw, String key) {
    final match = RegExp('$key=(\\d+)').firstMatch(raw);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 0;
    }
    return 0;
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C6H2B',
      'target': 'ios_physical',
      'offlinePlaybackClaimed': false,
      'zeroNetworkFetchClaimed': false,
    };
    bool allPass = false;
    bool diskStoreObserved = false;
    bool diskHitObserved = false;

    VGStreamingPlaybackSession? firstFinalStatus;
    VGStreamingPlaybackSession? secondFinalStatus;

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 1: Initial deterministic cache clear
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_INITIAL_CLEAR: START');
      if (mounted) {
        setState(() {
          _status = 'Clearing playback cache for deterministic baseline…';
        });
      }

      final initialClear = await _cacheClient.clear().timeout(_kControlTimeout);
      results['initialClear'] = <String, dynamic>{
        'pass': initialClear.pass,
        'state': initialClear.state,
        'cacheAvailable': initialClear.cacheAvailable,
        'beforeBytes': initialClear.beforeBytes,
        'afterBytes': initialClear.afterBytes,
        'removedResourceCount': initialClear.removedResourceCount,
        'failedResourceCount': initialClear.failedResourceCount,
        'raw': initialClear.raw,
      };

      if (!initialClear.pass ||
          initialClear.state != 'cleared' ||
          !initialClear.cacheAvailable ||
          initialClear.failedResourceCount != 0 ||
          initialClear.afterBytes != 0) {
        throw Exception(
          'Initial cache clear failed acceptance: pass=${initialClear.pass}, '
          'state=${initialClear.state}, cacheAvailable=${initialClear.cacheAvailable}, '
          'failedCount=${initialClear.failedResourceCount}, afterBytes=${initialClear.afterBytes}, '
          'raw=${initialClear.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_INITIAL_CLEAR: DONE (beforeBytes=${initialClear.beforeBytes}, afterBytes=${initialClear.afterBytes})',
      );

      // ═══════════════════════════════════════════════════════════════════════
      // Step 2: First Pass - Local proxy playback with disk cache storage
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening first HLS playback (caching to disk)…';
        });
      }

      final firstSession = await _playbackClient
          .open(
            VGStreamingPlaybackOptions(
              uri: Uri.parse(_kHlsTestUri),
              initialWidth: _kInitialWidth,
              initialHeight: _kInitialHeight,
              formatHint: VGStreamingFormatHint.hls,
              networkProfile: VGStreamingNetworkProfile.constrained,
              autoPlay: true,
              cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
            ),
          )
          .timeout(_kOperationTimeout);

      if (!firstSession.pass || firstSession.textureId < 0) {
        throw Exception(
          'First HLS open failed: pass=${firstSession.pass}, textureId=${firstSession.textureId}, raw=${firstSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_OPEN: DONE (textureId=${firstSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = firstSession.textureId;
          _status =
              'First HLS playback active (textureId=${firstSession.textureId})…';
        });
      }

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_STATUS: START');
        final firstDeadline = DateTime.now().add(_kOperationTimeout);

        while (DateTime.now().isBefore(firstDeadline)) {
          final status = await _playbackClient
              .getStatus(firstSession)
              .timeout(_kControlTimeout);

          final misses = _extractNumericRawToken(
            status.raw,
            'proxyCacheMisses',
          );
          if (status.renderedFrames > 0 &&
              status.effectiveDisplayWidth > 0 &&
              status.effectiveDisplayHeight > 0 &&
              status.state != VGStreamingPlaybackState.failed &&
              status.state != VGStreamingPlaybackState.surfaceLost &&
              status.state != VGStreamingPlaybackState.unsupported &&
              status.playbackCacheEnabled == true &&
              status.playbackCacheTelemetryAttached == true &&
              status.playbackCacheIgnoredCount == 0 &&
              status.playbackCacheSizeBytes > 0 &&
              misses > 0) {
            firstFinalStatus = status;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (firstFinalStatus == null) {
          final lastStatus = await _playbackClient
              .getStatus(firstSession)
              .timeout(_kControlTimeout);
          throw Exception(
            'First HLS cache storage verification timed out: '
            'renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, '
            'dims=${lastStatus.effectiveDisplayWidth}x${lastStatus.effectiveDisplayHeight}, '
            'playbackCacheEnabled=${lastStatus.playbackCacheEnabled}, '
            'playbackCacheTelemetryAttached=${lastStatus.playbackCacheTelemetryAttached}, '
            'playbackCacheIgnoredCount=${lastStatus.playbackCacheIgnoredCount}, '
            'playbackCacheSizeBytes=${lastStatus.playbackCacheSizeBytes}, '
            'raw=${lastStatus.raw}',
          );
        }

        final firstMisses = _extractNumericRawToken(
          firstFinalStatus.raw,
          'proxyCacheMisses',
        );
        final firstHits = _extractNumericRawToken(
          firstFinalStatus.raw,
          'proxyCacheHits',
        );
        final firstCacheBytesRead = _extractNumericRawToken(
          firstFinalStatus.raw,
          'proxyCacheBytesRead',
        );

        diskStoreObserved =
            firstFinalStatus.playbackCacheSizeBytes > 0 && firstMisses > 0;

        results['firstPass'] = <String, dynamic>{
          'pass': true,
          'textureId': firstFinalStatus.textureId,
          'renderedFrames': firstFinalStatus.renderedFrames,
          'state': firstFinalStatus.state.name,
          'effectiveDisplayWidth': firstFinalStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': firstFinalStatus.effectiveDisplayHeight,
          'playbackCacheEnabled': firstFinalStatus.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              firstFinalStatus.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes': firstFinalStatus.playbackCacheSizeBytes,
          'playbackCacheBytesRead': firstFinalStatus.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              firstFinalStatus.playbackCacheIgnoredCount,
          'proxyCacheMisses': firstMisses,
          'proxyCacheHits': firstHits,
          'proxyCacheBytesRead': firstCacheBytesRead,
          'raw': firstFinalStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_STATUS: DONE '
          '(renderedFrames=${firstFinalStatus.renderedFrames}, '
          'cacheSizeBytes=${firstFinalStatus.playbackCacheSizeBytes}, '
          'proxyCacheMisses=$firstMisses, proxyCacheHits=$firstHits)',
        );
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_DISPOSE: START');
        if (firstSession.textureId >= 0) {
          await _playbackClient.dispose(firstSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FIRST_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Step 3: Second Pass - Local proxy playback with disk cache hit
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening second HLS playback (verifying cache hit)…';
        });
      }

      final secondSession = await _playbackClient
          .open(
            VGStreamingPlaybackOptions(
              uri: Uri.parse(_kHlsTestUri),
              initialWidth: _kInitialWidth,
              initialHeight: _kInitialHeight,
              formatHint: VGStreamingFormatHint.hls,
              networkProfile: VGStreamingNetworkProfile.constrained,
              autoPlay: true,
              cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
            ),
          )
          .timeout(_kOperationTimeout);

      if (!secondSession.pass || secondSession.textureId < 0) {
        throw Exception(
          'Second HLS open failed: pass=${secondSession.pass}, textureId=${secondSession.textureId}, raw=${secondSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_OPEN: DONE (textureId=${secondSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = secondSession.textureId;
          _status =
              'Second HLS playback active (textureId=${secondSession.textureId})…';
        });
      }

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_STATUS: START');
        final secondDeadline = DateTime.now().add(_kOperationTimeout);

        while (DateTime.now().isBefore(secondDeadline)) {
          final status = await _playbackClient
              .getStatus(secondSession)
              .timeout(_kControlTimeout);

          final hits = _extractNumericRawToken(status.raw, 'proxyCacheHits');
          final bytesRead = _extractNumericRawToken(
            status.raw,
            'proxyCacheBytesRead',
          );
          if (status.renderedFrames > 0 &&
              status.effectiveDisplayWidth > 0 &&
              status.effectiveDisplayHeight > 0 &&
              status.state != VGStreamingPlaybackState.failed &&
              status.state != VGStreamingPlaybackState.surfaceLost &&
              status.state != VGStreamingPlaybackState.unsupported &&
              status.playbackCacheEnabled == true &&
              status.playbackCacheTelemetryAttached == true &&
              status.playbackCacheIgnoredCount == 0 &&
              status.playbackCacheSizeBytes > 0 &&
              hits > 0 &&
              bytesRead > 0) {
            secondFinalStatus = status;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (secondFinalStatus == null) {
          final lastStatus = await _playbackClient
              .getStatus(secondSession)
              .timeout(_kControlTimeout);
          throw Exception(
            'Second HLS cache hit verification timed out: '
            'renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, '
            'dims=${lastStatus.effectiveDisplayWidth}x${lastStatus.effectiveDisplayHeight}, '
            'playbackCacheEnabled=${lastStatus.playbackCacheEnabled}, '
            'playbackCacheTelemetryAttached=${lastStatus.playbackCacheTelemetryAttached}, '
            'playbackCacheIgnoredCount=${lastStatus.playbackCacheIgnoredCount}, '
            'playbackCacheSizeBytes=${lastStatus.playbackCacheSizeBytes}, '
            'playbackCacheBytesRead=${lastStatus.playbackCacheBytesRead}, '
            'raw=${lastStatus.raw}',
          );
        }

        final secondHits = _extractNumericRawToken(
          secondFinalStatus.raw,
          'proxyCacheHits',
        );
        final secondMisses = _extractNumericRawToken(
          secondFinalStatus.raw,
          'proxyCacheMisses',
        );
        final secondCacheBytesRead = _extractNumericRawToken(
          secondFinalStatus.raw,
          'proxyCacheBytesRead',
        );

        diskHitObserved = secondHits > 0 && secondCacheBytesRead > 0;

        results['secondPass'] = <String, dynamic>{
          'pass': true,
          'textureId': secondFinalStatus.textureId,
          'renderedFrames': secondFinalStatus.renderedFrames,
          'state': secondFinalStatus.state.name,
          'effectiveDisplayWidth': secondFinalStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': secondFinalStatus.effectiveDisplayHeight,
          'playbackCacheEnabled': secondFinalStatus.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              secondFinalStatus.playbackCacheTelemetryAttached,
          'playbackCacheSizeBytes': secondFinalStatus.playbackCacheSizeBytes,
          'playbackCacheBytesRead': secondFinalStatus.playbackCacheBytesRead,
          'playbackCacheIgnoredCount':
              secondFinalStatus.playbackCacheIgnoredCount,
          'proxyCacheHits': secondHits,
          'proxyCacheMisses': secondMisses,
          'proxyCacheBytesRead': secondCacheBytesRead,
          'raw': secondFinalStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_STATUS: DONE '
          '(renderedFrames=${secondFinalStatus.renderedFrames}, '
          'cacheSizeBytes=${secondFinalStatus.playbackCacheSizeBytes}, '
          'proxyCacheHits=$secondHits, proxyCacheBytesRead=$secondCacheBytesRead)',
        );
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_DISPOSE: START');
        if (secondSession.textureId >= 0) {
          await _playbackClient
              .dispose(secondSession)
              .timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_SECOND_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      allPass = diskStoreObserved && diskHitObserved;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_PHYSICAL_ERROR: $error\n$stack',
      );
      results['error'] = error.toString();
      allPass = false;
    } finally {
      // ═══════════════════════════════════════════════════════════════════════
      // Step 4: Final cleanup
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FINAL_CLEAR: START');
      try {
        final finalClear = await _cacheClient.clear().timeout(_kControlTimeout);
        results['finalClear'] = <String, dynamic>{
          'pass': finalClear.pass,
          'state': finalClear.state,
          'cacheAvailable': finalClear.cacheAvailable,
          'beforeBytes': finalClear.beforeBytes,
          'afterBytes': finalClear.afterBytes,
          'removedResourceCount': finalClear.removedResourceCount,
          'failedResourceCount': finalClear.failedResourceCount,
          'raw': finalClear.raw,
        };
        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FINAL_CLEAR: DONE '
          '(pass=${finalClear.pass}, state=${finalClear.state}, beforeBytes=${finalClear.beforeBytes}, afterBytes=${finalClear.afterBytes})',
        );
      } catch (clearError) {
        results['finalClear'] = <String, dynamic>{
          'pass': false,
          'error': clearError.toString(),
        };
        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_STEP_FINAL_CLEAR: ERROR ($clearError)',
        );
      }
    }

    results['pass'] = allPass;
    results['diskStoreObserved'] = diskStoreObserved;
    results['diskHitObserved'] = diskHitObserved;
    results['firstRaw'] = firstFinalStatus?.raw ?? '';
    results['secondRaw'] = secondFinalStatus?.raw ?? '';

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_CACHE_HIT_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (First: stored=${firstFinalStatus?.playbackCacheSizeBytes}B, misses=${_extractNumericRawToken(firstFinalStatus?.raw ?? '', 'proxyCacheMisses')}; Second: hits=${_extractNumericRawToken(secondFinalStatus?.raw ?? '', 'proxyCacheHits')}, read=${_extractNumericRawToken(secondFinalStatus?.raw ?? '', 'proxyCacheBytesRead')}B)'
            : 'FAIL: ${results['error']}';
      });
    }

    await Future<void>.delayed(const Duration(seconds: 1));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 180,
                  child: Texture(textureId: _textureId!),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
