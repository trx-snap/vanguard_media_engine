// Vanguard Android True-DAG Phase 4B2B3: Diagnostic physical smoke entrypoint
// proving real Android OS background/resume playback continuity and post-resume
// renderability for DAG texture playback.
//
// Scenario:
//   1. createAndroidDagPhase4B1BPlaybackControlSmoke with temp clip_B.mov path;
//      assert pass == true, valid textureId, state Prepared.
//   2. Display Texture(textureId: activeTextureId) in the UI.
//   3. playAndroidDagPhase4B1BPlaybackControlSmoke with frameBudget: 6;
//      assert pass and rendered frames >= 6.
//   4. Print ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_READY_FOR_ADB_HOME marker.
//   5. Wait up to 60 seconds for external ADB Home/Resume lifecycle transitions
//      recorded via WidgetsBindingObserver (inactive/paused/hidden/detached -> resumed).
//   6. Wait 1500ms after resumed to allow post-resume playback stabilization.
//   7. playAndroidDagPhase4B1BPlaybackControlSmoke again with frameBudget: 6;
//      assert pass and rendered frames increased.
//   8. Dispose session; assert pass.
//   9. Print JSON payload and pass/fail verdict, then exit(0/1).
//
// Proof boundary: real_android_os_background_resume_playback_continuity

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B2B3RealLifecycleSmokeApp());
}

class AndroidDagPhase4B2B3RealLifecycleSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B2B3RealLifecycleSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B2B3RealLifecycleSmokeApp> createState() =>
      _AndroidDagPhase4B2B3RealLifecycleSmokeAppState();
}

class _AndroidDagPhase4B2B3RealLifecycleSmokeAppState
    extends State<AndroidDagPhase4B2B3RealLifecycleSmokeApp>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4B2B3 real OS lifecycle smoke...';
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
    print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_APP_STATE:$stateName');

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
    var playBeforeHomePass = false;
    var renderedFramesBeforeHome = 0;
    var playAfterResumePass = false;
    var renderedFramesAfterResume = 0;
    var disposePass = false;
    var raw = '';

    try {
      // 1. Copy bundled clip_B.mov to temp file
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b2b3_real_lifecycle_clip_b.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // Step 1: CREATE
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_CREATE: START');

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

      if (mounted) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Session prepared (textureId=$activeTextureId)';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_CREATE: DONE');

      // Step 2: PLAY BEFORE HOME
      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_PLAY_BEFORE_HOME: START',
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
          'Step 2 play before home failed: pass=$play1Pass, renderedFrames=$renderedFramesBeforeHome, raw=${play1Map['raw']}',
        );
      }

      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_PLAY_BEFORE_HOME: DONE',
      );

      // Step 3: READY FOR ADB HOME
      _readyForLifecycle = true;
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_READY_FOR_ADB_HOME');

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

      // Step 4: PLAY AFTER RESUME
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_PLAY_AFTER_RESUME: START',
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
          'Step 4 play after resume failed: pass=$play2Pass, before=$renderedFramesBeforeHome, after=$renderedFramesAfterResume, raw=${play2Map['raw']}',
        );
      }

      // ignore: avoid_print
      print(
        'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_STEP_PLAY_AFTER_RESUME: DONE',
      );

      // Step 5: DISPOSE
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
        throw Exception('Step 5 dispose failed: raw=${disposeMap['raw']}');
      }

      raw =
          'status=OK;createPass=$createPass;playBeforeHomePass=$playBeforeHomePass;'
          'backgroundObserved=$_backgroundObserved;resumeObserved=$_resumeObserved;'
          'playAfterResumePass=$playAfterResumePass;disposePass=$disposePass';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_ERROR: $error\n$stack');
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
        playBeforeHomePass &&
        _backgroundObserved &&
        _resumeObserved &&
        playAfterResumePass &&
        disposePass;

    final payload = <String, dynamic>{
      'phase': 'Phase4B2B3',
      'target': 'android_physical_real_os_lifecycle',
      'pass': pass,
      'textureId': activeTextureId,
      'width': videoWidth,
      'height': videoHeight,
      'durationUs': videoDurationUs,
      'appLifecycleStates': _appLifecycleStates,
      'backgroundObserved': _backgroundObserved,
      'resumeObserved': _resumeObserved,
      'createPass': createPass,
      'playBeforeHomePass': playBeforeHomePass,
      'playAfterResumePass': playAfterResumePass,
      'disposePass': disposePass,
      'renderedFramesBeforeHome': renderedFramesBeforeHome,
      'renderedFramesAfterResume': renderedFramesAfterResume,
      'proofBoundary': 'real_android_os_background_resume_playback_continuity',
      'nonClaims': const <String>[
        'native SurfaceProducer callback firing not asserted by this harness',
        'no simulated callbacks',
        'no simulated surface callbacks',
        'no product UI wiring',
        'no ConnectsApp touched',
        'no streaming/cache/RTC claim',
        'no lock-screen or split-screen proof in this harness',
        'no fleet validation',
      ],
      'raw': raw,
    };

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_PHYSICAL_PASS'
          : 'ANDROID_DAG_PHASE4B2B3_REAL_LIFECYCLE_PHYSICAL_FAIL',
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
