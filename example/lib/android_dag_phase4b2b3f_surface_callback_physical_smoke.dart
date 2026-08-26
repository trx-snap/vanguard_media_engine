// Vanguard Android True-DAG Phase 4B2B3F: Diagnostic physical smoke entrypoint
// proving real Flutter/Android SurfaceProducer background reset callbacks for DAG
// texture playback by using the native diagnostic route.
//
// Scenario:
//   1. Copy bundled clip_B.mov to a temporary file.
//   2. createAndroidDagPhase4B1BPlaybackControlSmoke with temp clip_B.mov path;
//      assert pass == true, valid textureId >= 0, state Prepared.
//   3. Display Texture(textureId: activeTextureId) in the UI; wait 150ms.
//   4. getAndroidDagPhase4B2B3SurfaceLifecycleStatus; capture baseline counts
//      (baselineRealCleanupCount, baselineRealAvailableCount); assert pass == true
//      and disposed != true.
//   5. playAndroidDagPhase4B1BPlaybackControlSmoke with frameBudget: 6;
//      assert pass == true and renderedFrames >= 6.
//   6. Print ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_READY_FOR_ADB_HOME marker.
//   7. Wait up to 60s for real OS lifecycle background -> resume transitions.
//   8. After resumed, wait 1500ms, then poll getAndroidDagPhase4B2B3SurfaceLifecycleStatus
//      every 250ms for up to 10s until cleanup/available counts incremented,
//      surfaceLost == false, valid sessionId, and state in [Paused, Prepared, Playing].
//   9. playAndroidDagPhase4B1BPlaybackControlSmoke again with frameBudget: 6;
//      assert pass == true and renderedFrames increased.
//  10. Dispose session; assert pass == true.
//  11. Print JSON payload and pass/fail verdict, then exit(0/1).
//
// Proof boundary: real_android_background_surfaceproducer_cleanup_available_callbacks

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeApp());
}

class AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeApp> createState() =>
      _AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeAppState();
}

class _AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeAppState
    extends State<AndroidDagPhase4B2B3FSurfaceCallbackPhysicalSmokeApp>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android DAG Phase 4B2B3F real SurfaceProducer callback smoke...';
  int? _textureId;

  final List<String> _appLifecycleStates = <String>[];
  final Completer<void> _resumeCompleter = Completer<void>();
  var _readyForLifecycle = false;
  var _backgroundObserved = false;
  var _resumeObserved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runSmoke();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final stateName = state.name;
    _appLifecycleStates.add(stateName);
    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_APP_STATE:$stateName');

    if (_readyForLifecycle) {
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        _backgroundObserved = true;
      } else if (state == AppLifecycleState.resumed && _backgroundObserved) {
        _resumeObserved = true;
        if (!_resumeCompleter.isCompleted) {
          _resumeCompleter.complete();
        }
      }
    }
  }

  Future<void> _runSmoke() async {
    File? tempFile;
    int activeTextureId = -1;
    int videoWidth = 0;
    int videoHeight = 0;
    int videoDurationUs = 0;

    var createPass = false;
    var baselineStatusPass = false;
    var playBeforeHomePass = false;
    var callbackDeltaPass = false;
    var playAfterResumePass = false;
    var disposePass = false;

    var baselineRealCleanupCount = 0;
    var baselineRealAvailableCount = 0;
    var finalRealCleanupCount = 0;
    var finalRealAvailableCount = 0;
    var realCleanupDelta = 0;
    var realAvailableDelta = 0;

    var lastSurfaceLifecycleEvent = '';
    var finalSurfaceLost = false;
    var finalState = '';
    var finalSessionIdPresent = false;

    var renderedFramesBeforeHome = 0;
    var renderedFramesAfterResume = 0;
    var raw = '';

    try {
      // 1. Copy bundled clip_B.mov to temp file
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File(
        '${tempDir.path}/phase4b2b3f_surface_callback_clip_b.mov',
      );
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // Step 1: CREATE
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_CREATE: START');

      final createResponse = await _channel
          .invokeMethod<Object?>(
            'createAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'path': tempFile.path},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'createAndroidDagPhase4B1BPlaybackControlSmoke timed out',
              const Duration(seconds: 30),
            ),
          );
      final createMap = Map<String, dynamic>.from(
        (createResponse as Map?) ?? const <String, dynamic>{},
      );
      createPass = createMap['pass'] == true;
      activeTextureId = (createMap['textureId'] as num?)?.toInt() ?? -1;
      videoWidth = (createMap['width'] as num?)?.toInt() ?? 0;
      videoHeight = (createMap['height'] as num?)?.toInt() ?? 0;
      videoDurationUs = (createMap['durationUs'] as num?)?.toInt() ?? 0;
      final initialState = createMap['state'] as String? ?? '';

      if (!createPass || activeTextureId < 0 || initialState != 'Prepared') {
        throw Exception(
          'Step 1 create failed: pass=$createPass, textureId=$activeTextureId, state=$initialState, raw=${createMap['raw']}',
        );
      }

      // Step 2: Mount Texture in UI
      if (mounted) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Session prepared (textureId=$activeTextureId)';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_CREATE: DONE');

      // Step 3: BASELINE STATUS
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_BASELINE: START');

      final baselineResponse = await _channel
          .invokeMethod<Object?>(
            'getAndroidDagPhase4B2B3SurfaceLifecycleStatus',
            <String, Object>{'textureId': activeTextureId},
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'getAndroidDagPhase4B2B3SurfaceLifecycleStatus baseline timed out',
              const Duration(seconds: 15),
            ),
          );
      final baselineMap = Map<String, dynamic>.from(
        (baselineResponse as Map?) ?? const <String, dynamic>{},
      );
      final baselinePass = baselineMap['pass'] == true;
      final baselineDisposed = baselineMap['disposed'] == true;
      baselineRealCleanupCount =
          (baselineMap['realSurfaceCleanupCallbackCount'] as num?)?.toInt() ??
          0;
      baselineRealAvailableCount =
          (baselineMap['realSurfaceAvailableCallbackCount'] as num?)?.toInt() ??
          0;

      baselineStatusPass = baselinePass && !baselineDisposed;
      if (!baselineStatusPass) {
        throw Exception(
          'Step 3 baseline status failed: pass=$baselinePass, disposed=$baselineDisposed, raw=${baselineMap['raw']}',
        );
      }

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_BASELINE: DONE');

      // Step 4: PLAY BEFORE HOME
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_PLAY_BEFORE_HOME: START',
      );

      final play1Response = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'playAndroidDagPhase4B1BPlaybackControlSmoke before home timed out',
              const Duration(seconds: 30),
            ),
          );
      final play1Map = Map<String, dynamic>.from(
        (play1Response as Map?) ?? const <String, dynamic>{},
      );
      final play1Pass = play1Map['pass'] == true;
      renderedFramesBeforeHome =
          (play1Map['renderedFrames'] as num?)?.toInt() ?? 0;
      playBeforeHomePass = play1Pass && renderedFramesBeforeHome >= 6;

      if (!playBeforeHomePass) {
        throw Exception(
          'Step 4 play before home failed: pass=$play1Pass, renderedFrames=$renderedFramesBeforeHome, raw=${play1Map['raw']}',
        );
      }

      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_PLAY_BEFORE_HOME: DONE',
      );

      // Step 5: READY FOR ADB HOME
      _readyForLifecycle = true;
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_READY_FOR_ADB_HOME');

      if (mounted) {
        setState(() {
          _status = 'Waiting for ADB Home/Resume lifecycle...';
        });
      }

      await _resumeCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException(
          'Real lifecycle transition (background -> resume) timed out after 60s',
          const Duration(seconds: 60),
        ),
      );

      // Step 6: POLL STATUS AFTER RESUME
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_POLL_STATUS: START');

      Map<String, dynamic> finalStatusMap = const <String, dynamic>{};
      final pollStopwatch = Stopwatch()..start();
      while (pollStopwatch.elapsed < const Duration(seconds: 10)) {
        final statusResp = await _channel
            .invokeMethod<Object?>(
              'getAndroidDagPhase4B2B3SurfaceLifecycleStatus',
              <String, Object>{'textureId': activeTextureId},
            )
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException(
                'getAndroidDagPhase4B2B3SurfaceLifecycleStatus poll timed out',
                const Duration(seconds: 5),
              ),
            );
        finalStatusMap = Map<String, dynamic>.from(
          (statusResp as Map?) ?? const <String, dynamic>{},
        );

        final currCleanupCount =
            (finalStatusMap['realSurfaceCleanupCallbackCount'] as num?)
                ?.toInt() ??
            0;
        final currAvailableCount =
            (finalStatusMap['realSurfaceAvailableCallbackCount'] as num?)
                ?.toInt() ??
            0;
        final currSurfaceLost = finalStatusMap['surfaceLost'] == true;
        final currSessionId = finalStatusMap['sessionId'] as String?;
        final currState = finalStatusMap['state'] as String? ?? '';

        final isCleanupDeltaPositive =
            currCleanupCount > baselineRealCleanupCount;
        final isAvailableDeltaPositive =
            currAvailableCount > baselineRealAvailableCount;
        final isSurfaceNotLost = !currSurfaceLost;
        final isSessionIdValid =
            currSessionId != null && currSessionId.isNotEmpty;
        final isStateValid =
            currState == 'Paused' ||
            currState == 'Prepared' ||
            currState == 'Playing';

        if (isCleanupDeltaPositive &&
            isAvailableDeltaPositive &&
            isSurfaceNotLost &&
            isSessionIdValid &&
            isStateValid) {
          break;
        }

        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      finalRealCleanupCount =
          (finalStatusMap['realSurfaceCleanupCallbackCount'] as num?)
              ?.toInt() ??
          0;
      finalRealAvailableCount =
          (finalStatusMap['realSurfaceAvailableCallbackCount'] as num?)
              ?.toInt() ??
          0;
      realCleanupDelta = finalRealCleanupCount - baselineRealCleanupCount;
      realAvailableDelta = finalRealAvailableCount - baselineRealAvailableCount;
      finalSurfaceLost = finalStatusMap['surfaceLost'] == true;
      finalState = finalStatusMap['state'] as String? ?? '';
      final sessionIdVal = finalStatusMap['sessionId'] as String?;
      finalSessionIdPresent = sessionIdVal != null && sessionIdVal.isNotEmpty;
      lastSurfaceLifecycleEvent =
          finalStatusMap['lastSurfaceLifecycleEvent'] as String? ?? '';

      callbackDeltaPass =
          finalStatusMap['pass'] == true &&
          realCleanupDelta > 0 &&
          realAvailableDelta > 0 &&
          !finalSurfaceLost &&
          finalSessionIdPresent &&
          (finalState == 'Paused' ||
              finalState == 'Prepared' ||
              finalState == 'Playing');

      if (!callbackDeltaPass) {
        throw Exception(
          'Step 6 callback delta verification failed: cleanupDelta=$realCleanupDelta, availableDelta=$realAvailableDelta, surfaceLost=$finalSurfaceLost, state=$finalState, sessionId=$sessionIdVal, raw=${finalStatusMap['raw']}',
        );
      }

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_POLL_STATUS: DONE');

      // Step 7: PLAY AFTER RESUME
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_PLAY_AFTER_RESUME: START',
      );

      final play2Response = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'playAndroidDagPhase4B1BPlaybackControlSmoke after resume timed out',
              const Duration(seconds: 30),
            ),
          );
      final play2Map = Map<String, dynamic>.from(
        (play2Response as Map?) ?? const <String, dynamic>{},
      );
      final play2Pass = play2Map['pass'] == true;
      renderedFramesAfterResume =
          (play2Map['renderedFrames'] as num?)?.toInt() ?? 0;
      playAfterResumePass =
          play2Pass && renderedFramesAfterResume > renderedFramesBeforeHome;

      if (!playAfterResumePass) {
        throw Exception(
          'Step 7 play after resume failed: pass=$play2Pass, before=$renderedFramesBeforeHome, after=$renderedFramesAfterResume, raw=${play2Map['raw']}',
        );
      }

      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_STEP_PLAY_AFTER_RESUME: DONE',
      );

      // Step 8: DISPOSE
      final disposeResponse = await _channel
          .invokeMethod<Object?>(
            'disposeAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId},
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'dispose timed out',
              const Duration(seconds: 10),
            ),
          );
      final disposeMap = Map<String, dynamic>.from(
        (disposeResponse as Map?) ?? const <String, dynamic>{},
      );
      disposePass = disposeMap['pass'] == true;

      if (!disposePass) {
        throw Exception('Step 8 dispose failed: raw=${disposeMap['raw']}');
      }

      raw =
          'status=OK;createPass=$createPass;baselineStatusPass=$baselineStatusPass;'
          'playBeforeHomePass=$playBeforeHomePass;backgroundObserved=$_backgroundObserved;'
          'resumeObserved=$_resumeObserved;callbackDeltaPass=$callbackDeltaPass;'
          'cleanupDelta=$realCleanupDelta;availableDelta=$realAvailableDelta;'
          'playAfterResumePass=$playAfterResumePass;disposePass=$disposePass';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_ERROR: $error\n$stack');
      raw = 'status=FAIL;reason=dart_exception:$error';
      if (activeTextureId >= 0 && !disposePass) {
        try {
          final disposeResponse = await _channel
              .invokeMethod<Object?>(
                'disposeAndroidDagPhase4B1BPlaybackControlSmoke',
                <String, Object>{'textureId': activeTextureId},
              )
              .timeout(const Duration(seconds: 10));
          final disposeMap = Map<String, dynamic>.from(
            (disposeResponse as Map?) ?? const <String, dynamic>{},
          );
          disposePass = disposeMap['pass'] == true;
        } catch (_) {}
      }
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }

    final pass =
        createPass &&
        baselineStatusPass &&
        playBeforeHomePass &&
        _backgroundObserved &&
        _resumeObserved &&
        callbackDeltaPass &&
        playAfterResumePass &&
        disposePass;

    final payload = <String, dynamic>{
      'phase': 'Phase4B2B3F',
      'target': 'android_physical_real_surfaceproducer_callbacks',
      'pass': pass,
      'proofBoundary':
          'real_android_background_surfaceproducer_cleanup_available_callbacks',
      'textureId': activeTextureId,
      'width': videoWidth,
      'height': videoHeight,
      'durationUs': videoDurationUs,
      'appLifecycleStates': _appLifecycleStates,
      'backgroundObserved': _backgroundObserved,
      'resumeObserved': _resumeObserved,
      'baselineRealCleanupCallbackCount': baselineRealCleanupCount,
      'baselineRealAvailableCallbackCount': baselineRealAvailableCount,
      'finalRealCleanupCallbackCount': finalRealCleanupCount,
      'finalRealAvailableCallbackCount': finalRealAvailableCount,
      'realCleanupCallbackDelta': realCleanupDelta,
      'realAvailableCallbackDelta': realAvailableDelta,
      'lastSurfaceLifecycleEvent': lastSurfaceLifecycleEvent,
      'finalSurfaceLost': finalSurfaceLost,
      'finalState': finalState,
      'finalSessionIdPresent': finalSessionIdPresent,
      'renderedFramesBeforeHome': renderedFramesBeforeHome,
      'renderedFramesAfterResume': renderedFramesAfterResume,
      'createPass': createPass,
      'baselineStatusPass': baselineStatusPass,
      'playBeforeHomePass': playBeforeHomePass,
      'callbackDeltaPass': callbackDeltaPass,
      'playAfterResumePass': playAfterResumePass,
      'disposePass': disposePass,
      'nonClaims': const <String>[
        'no simulated surface callbacks',
        'no product UI wiring',
        'no ConnectsApp touched',
        'no streaming/cache/RTC claim',
        'no fleet validation',
      ],
      'raw': raw,
    };

    // ignore: avoid_print
    print(
      'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_PHYSICAL_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_PHYSICAL_PASS'
          : 'ANDROID_DAG_PHASE4B2B3F_SURFACE_CALLBACK_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $raw';
      });
    }

    Future<void>.delayed(const Duration(milliseconds: 500), () {
      exit(pass ? 0 : 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_textureId != null && _textureId! >= 0) ...[
                SizedBox(
                  width: 320,
                  height: 240,
                  child: Texture(textureId: _textureId!),
                ),
                const SizedBox(height: 16),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_status, textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
