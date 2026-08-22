// Vanguard Android True-DAG Phase 4B2B2: Diagnostic physical smoke entrypoint
// proving Android DAG SurfaceProducer lifecycle diagnostic seams on connected hardware.
//
// Scenario:
//   1. createAndroidDagPhase4B1BPlaybackControlSmoke with temp clip_B.mov path;
//      assert pass == true, valid textureId, state Prepared.
//   2. Display Texture(textureId: textureId) in the UI.
//   3. playAndroidDagPhase4B1BPlaybackControlSmoke with frameBudget: 6;
//      assert pass and rendered frames >= 6.
//   4. simulateAndroidDagPhase4B2B2SurfaceCleanup;
//      assert pass, state SurfaceLost, surfaceLost == true, and sessionId == null.
//   5. Attempt playAndroidDagPhase4B1BPlaybackControlSmoke while lost;
//      assert pass == false and raw contains surface_lost.
//   6. simulateAndroidDagPhase4B2B2SurfaceAvailable;
//      assert pass, state Paused, surfaceLost == false, and sessionId is non-empty.
//   7. playAndroidDagPhase4B1BPlaybackControlSmoke again with frameBudget: 6;
//      assert pass and rendered frames increased.
//   8. seekAndroidDagPhase4B1BPlaybackControlSmoke to targetPtsUs: 500000,
//      resumeAfterSeek: false; assert pass.
//   9. Dispose session; assert pass.
//
// Proof boundary: simulated_surfaceproducer_callback_on_physical_device
// Orientation: deferred (recorded in payload).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B2B2SurfaceLifecycleSmokeApp());
}

class AndroidDagPhase4B2B2SurfaceLifecycleSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B2B2SurfaceLifecycleSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B2B2SurfaceLifecycleSmokeApp> createState() =>
      _AndroidDagPhase4B2B2SurfaceLifecycleSmokeAppState();
}

class _AndroidDagPhase4B2B2SurfaceLifecycleSmokeAppState
    extends State<AndroidDagPhase4B2B2SurfaceLifecycleSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4B2B2 surface lifecycle smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    File? tempFile;
    int activeTextureId = -1;
    int videoWidth = 0;
    int videoHeight = 0;
    int videoDurationUs = 0;
    final stateSequence = <String>[];

    var createPass = false;
    var playBeforeCleanupPass = false;
    var renderedFramesBeforeCleanup = 0;
    var cleanupPass = false;
    var playWhileLostRejected = false;
    var availablePass = false;
    var playAfterRestorePass = false;
    var renderedFramesAfterRestore = 0;
    var seekAfterRestorePass = false;
    var disposePass = false;
    var raw = '';

    try {
      // 1. Copy bundled clip_B.mov to temp file
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b2b2_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // 1. createAndroidDagPhase4B1BPlaybackControlSmoke
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
      final initialState = createMap['state'] as String? ?? 'Prepared';
      stateSequence.add(initialState);

      if (!createPass || activeTextureId < 0 || initialState != 'Prepared') {
        throw Exception(
          'Step 1 create failed: pass=$createPass, textureId=$activeTextureId, state=$initialState, raw=${createMap['raw']}',
        );
      }

      // 2. Display Texture(textureId: textureId) in the UI
      if (mounted && activeTextureId >= 0) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Session prepared (textureId=$activeTextureId)';
        });
      }

      // 3. playAndroidDagPhase4B1BPlaybackControlSmoke with frameBudget: 6
      final play1Response = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'playAndroidDagPhase4B1BPlaybackControlSmoke step 3 timed out',
              const Duration(seconds: 30),
            ),
          );
      final play1Map = Map<String, dynamic>.from(
        (play1Response as Map?) ?? const <String, dynamic>{},
      );
      final play1Pass = play1Map['pass'] == true;
      renderedFramesBeforeCleanup =
          (play1Map['renderedFrames'] as num?)?.toInt() ?? 0;
      final play1State = play1Map['state'] as String? ?? 'Playing';
      stateSequence.add(play1State);
      playBeforeCleanupPass = play1Pass && renderedFramesBeforeCleanup >= 6;

      if (!playBeforeCleanupPass) {
        throw Exception(
          'Step 3 play failed: pass=$play1Pass, renderedFrames=$renderedFramesBeforeCleanup, raw=${play1Map['raw']}',
        );
      }

      // 4. simulateAndroidDagPhase4B2B2SurfaceCleanup
      final cleanupResponse = await _channel
          .invokeMethod<Object?>(
            'simulateAndroidDagPhase4B2B2SurfaceCleanup',
            <String, Object>{'textureId': activeTextureId},
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'simulateAndroidDagPhase4B2B2SurfaceCleanup timed out',
              const Duration(seconds: 15),
            ),
          );
      final cleanupMap = Map<String, dynamic>.from(
        (cleanupResponse as Map?) ?? const <String, dynamic>{},
      );
      final cleanupMethodPass = cleanupMap['pass'] == true;
      final cleanupState = cleanupMap['state'] as String? ?? '';
      final surfaceLost = cleanupMap['surfaceLost'] == true;
      final cleanupSessionId = cleanupMap['sessionId'];
      stateSequence.add(cleanupState);
      cleanupPass =
          cleanupMethodPass &&
          cleanupState == 'SurfaceLost' &&
          surfaceLost &&
          cleanupSessionId == null;

      if (!cleanupPass) {
        throw Exception(
          'Step 4 cleanup assertion failed: pass=$cleanupMethodPass, state=$cleanupState, surfaceLost=$surfaceLost, sessionId=$cleanupSessionId, raw=${cleanupMap['raw']}',
        );
      }

      // 5. Attempt playAndroidDagPhase4B1BPlaybackControlSmoke while lost
      final playLostResponse = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException(
              'play while lost timed out',
              const Duration(seconds: 15),
            ),
          );
      final playLostMap = Map<String, dynamic>.from(
        (playLostResponse as Map?) ?? const <String, dynamic>{},
      );
      final playLostPass = playLostMap['pass'] == true;
      final playLostRaw = playLostMap['raw'] as String? ?? '';
      playWhileLostRejected =
          !playLostPass && playLostRaw.contains('surface_lost');

      if (!playWhileLostRejected) {
        throw Exception(
          'Step 5 play while lost was not rejected as expected: pass=$playLostPass, raw=$playLostRaw',
        );
      }

      // 6. simulateAndroidDagPhase4B2B2SurfaceAvailable
      final availableResponse = await _channel
          .invokeMethod<Object?>(
            'simulateAndroidDagPhase4B2B2SurfaceAvailable',
            <String, Object>{'textureId': activeTextureId},
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
              'simulateAndroidDagPhase4B2B2SurfaceAvailable timed out',
              const Duration(seconds: 20),
            ),
          );
      final availableMap = Map<String, dynamic>.from(
        (availableResponse as Map?) ?? const <String, dynamic>{},
      );
      final availableMethodPass = availableMap['pass'] == true;
      final availableState = availableMap['state'] as String? ?? '';
      final availableSurfaceLost = availableMap['surfaceLost'] == true;
      final restoredSessionId = availableMap['sessionId'] as String?;
      stateSequence.add(availableState);
      availablePass =
          availableMethodPass &&
          availableState == 'Paused' &&
          !availableSurfaceLost &&
          restoredSessionId != null &&
          restoredSessionId.isNotEmpty;

      if (!availablePass) {
        throw Exception(
          'Step 6 surface available assertion failed: pass=$availableMethodPass, state=$availableState, surfaceLost=$availableSurfaceLost, sessionId=$restoredSessionId, raw=${availableMap['raw']}',
        );
      }

      // 7. playAndroidDagPhase4B1BPlaybackControlSmoke again with frameBudget: 6
      final play2Response = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'play after restore timed out',
              const Duration(seconds: 30),
            ),
          );
      final play2Map = Map<String, dynamic>.from(
        (play2Response as Map?) ?? const <String, dynamic>{},
      );
      final play2Pass = play2Map['pass'] == true;
      renderedFramesAfterRestore =
          (play2Map['renderedFrames'] as num?)?.toInt() ?? 0;
      final play2State = play2Map['state'] as String? ?? 'Playing';
      stateSequence.add(play2State);
      playAfterRestorePass =
          play2Pass && renderedFramesAfterRestore > renderedFramesBeforeCleanup;

      if (!playAfterRestorePass) {
        throw Exception(
          'Step 7 play after restore failed: pass=$play2Pass, before=$renderedFramesBeforeCleanup, after=$renderedFramesAfterRestore, raw=${play2Map['raw']}',
        );
      }

      // 8. seekAndroidDagPhase4B1BPlaybackControlSmoke to targetPtsUs: 500000, resumeAfterSeek: false
      const seekTargetUs = 500000;
      final seekResponse = await _channel
          .invokeMethod<Object?>(
            'seekAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{
              'textureId': activeTextureId,
              'targetPtsUs': seekTargetUs,
              'resumeAfterSeek': false,
            },
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'seek after restore timed out',
              const Duration(seconds: 30),
            ),
          );
      final seekMap = Map<String, dynamic>.from(
        (seekResponse as Map?) ?? const <String, dynamic>{},
      );
      seekAfterRestorePass = seekMap['pass'] == true;
      final seekState = seekMap['state'] as String? ?? 'Paused';
      stateSequence.add(seekState);

      if (!seekAfterRestorePass) {
        throw Exception(
          'Step 8 seek after restore failed: pass=$seekAfterRestorePass, raw=${seekMap['raw']}',
        );
      }

      // 9. Dispose session
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
      stateSequence.add(disposeMap['state'] as String? ?? 'Disposed');

      if (!disposePass) {
        throw Exception('Step 9 dispose failed: raw=${disposeMap['raw']}');
      }

      raw =
          'status=OK;createPass=$createPass;playBeforeCleanupPass=$playBeforeCleanupPass;'
          'cleanupPass=$cleanupPass;playWhileLostRejected=$playWhileLostRejected;'
          'availablePass=$availablePass;playAfterRestorePass=$playAfterRestorePass;'
          'seekAfterRestorePass=$seekAfterRestorePass;disposePass=$disposePass';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B2_ERROR: $error\n$stack');
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
          stateSequence.add(disposeMap['state'] as String? ?? 'Disposed');
        } catch (_) {}
      }
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }

    final pass =
        createPass &&
        playBeforeCleanupPass &&
        cleanupPass &&
        playWhileLostRejected &&
        availablePass &&
        playAfterRestorePass &&
        seekAfterRestorePass &&
        disposePass;

    final payload = <String, dynamic>{
      'pass': pass,
      'textureId': activeTextureId,
      'width': videoWidth,
      'height': videoHeight,
      'durationUs': videoDurationUs,
      'stateSequence': stateSequence,
      'playBeforeCleanupPass': playBeforeCleanupPass,
      'cleanupPass': cleanupPass,
      'playWhileLostRejected': playWhileLostRejected,
      'availablePass': availablePass,
      'playAfterRestorePass': playAfterRestorePass,
      'seekAfterRestorePass': seekAfterRestorePass,
      'disposePass': disposePass,
      'renderedFramesBeforeCleanup': renderedFramesBeforeCleanup,
      'renderedFramesAfterRestore': renderedFramesAfterRestore,
      'orientationDeferred': true,
      'proofBoundary': 'simulated_surfaceproducer_callback_on_physical_device',
      'raw': raw,
    };

    // ignore: avoid_print
    print(
      'ANDROID_DAG_PHASE4B2B2_SURFACE_LIFECYCLE_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B2B2_SURFACE_LIFECYCLE_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4B2B2_SURFACE_LIFECYCLE_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $raw';
      });
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      SystemNavigator.pop();
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
