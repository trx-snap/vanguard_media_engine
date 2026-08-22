// Vanguard Android True-DAG Phase 4B2B1: Physical smoke entrypoint proving
// prepare-failure cleanup does not poison the next playback-control session.
//
// Scenario:
//   1. Call createAndroidDagPhase4B1BPlaybackControlSmoke with missing path:
//      /private/tmp/vanguard_phase4b2b1_missing_input.mp4
//   2. Assert invalid create returns pass == false and raw starts with status=FAIL;.
//   3. If textureId is present, call disposeAndroidDagPhase4B1BPlaybackControlSmoke
//      to confirm cleanup (accept pass == false or pass == true).
//   4. Call valid playback-control sequence:
//      create valid session -> play 6 frames -> pause ->
//      seek to 500000us with resumeAfterSeek=false -> play/resume 6 frames -> dispose.
//   5. Assert invalidPreparePass, validCreatePass, play1Pass, pausePass,
//      seekPass, resumePass, disposePass, totalRenderedFrames > 0.
//   6. Print ANDROID_DAG_PHASE4B2B1_JSON:<json> and PASS/FAIL marker.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B2B1PrepareFailureSmokeApp());
}

class AndroidDagPhase4B2B1PrepareFailureSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B2B1PrepareFailureSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B2B1PrepareFailureSmokeApp> createState() =>
      _AndroidDagPhase4B2B1PrepareFailureSmokeAppState();
}

class _AndroidDagPhase4B2B1PrepareFailureSmokeAppState
    extends State<AndroidDagPhase4B2B1PrepareFailureSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android DAG Phase 4B2B1 prepare failure & playback smoke…';
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

    var invalidPreparePass = false;
    var invalidRaw = '';
    var validCreatePass = false;
    var play1Pass = false;
    var play1RenderedFrames = 0;
    var pausePass = false;
    var seekPass = false;
    const seekTargetUs = 500000;
    var seekRenderedPtsUs = -1;
    var resumePass = false;
    var resumeRenderedFrames = 0;
    var totalRenderedFrames = 0;
    var disposePass = false;
    var raw = '';

    try {
      // 1. Call create with an invalid/missing path.
      // A 10 s timeout converts any future MethodChannel hang into an explicit
      // ANDROID_DAG_PHASE4B2B1_PREPARE_FAILURE_SMOKE_FAIL rather than a silent stall.
      const missingPath = '/private/tmp/vanguard_phase4b2b1_missing_input.mp4';
      final invalidCreateResponse = await _channel
          .invokeMethod<Object?>(
            'createAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'path': missingPath},
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'createAndroidDagPhase4B1BPlaybackControlSmoke timed out for missing path',
              const Duration(seconds: 10),
            ),
          );
      final invalidMap = Map<String, dynamic>.from(
        (invalidCreateResponse as Map?) ?? const <String, dynamic>{},
      );
      final invalidPass = invalidMap['pass'] == true;
      invalidRaw = invalidMap['raw'] as String? ?? '';
      final invalidTextureId = (invalidMap['textureId'] as num?)?.toInt() ?? -1;

      // 2. Assert invalid create returns pass == false and raw starts with status=FAIL;
      invalidPreparePass =
          !invalidPass && invalidRaw.startsWith('status=FAIL;');

      // 3. Cleanup confirmation if textureId is present in failed result
      if (invalidTextureId >= 0) {
        try {
          await _channel
              .invokeMethod<Object?>(
                'disposeAndroidDagPhase4B1BPlaybackControlSmoke',
                <String, Object>{'textureId': invalidTextureId},
              )
              .timeout(const Duration(seconds: 5));
          // Cleanup confirmation only: accept pass == false (session_not_found) or pass == true.
        } catch (_) {}
      }

      if (!invalidPreparePass) {
        throw Exception(
          'Invalid prepare assertion failed: pass=$invalidPass, raw=$invalidRaw',
        );
      }

      // 4. Valid playback-control sequence
      // 4a. Copy bundled clip_B.mov to temp file
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b2b1_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // 4b. Create valid control session
      final createResponse = await _channel
          .invokeMethod<Object?>(
            'createAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'path': tempFile.path},
          )
          .timeout(const Duration(seconds: 30));
      final createMap = Map<String, dynamic>.from(
        (createResponse as Map?) ?? const <String, dynamic>{},
      );
      validCreatePass = createMap['pass'] == true;
      activeTextureId = (createMap['textureId'] as num?)?.toInt() ?? -1;
      videoWidth = (createMap['width'] as num?)?.toInt() ?? 0;
      videoHeight = (createMap['height'] as num?)?.toInt() ?? 0;
      videoDurationUs = (createMap['durationUs'] as num?)?.toInt() ?? 0;
      stateSequence.add(createMap['state'] as String? ?? 'Prepared');

      if (mounted && activeTextureId >= 0) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Valid session prepared (textureId=$activeTextureId)';
        });
      }

      if (!validCreatePass || activeTextureId < 0) {
        throw Exception('Create valid session failed: ${createMap['raw']}');
      }

      // 4c. Play 6 frames
      final play1Response = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(const Duration(seconds: 30));
      final play1Map = Map<String, dynamic>.from(
        (play1Response as Map?) ?? const <String, dynamic>{},
      );
      play1Pass = play1Map['pass'] == true;
      play1RenderedFrames = (play1Map['renderedFrames'] as num?)?.toInt() ?? 0;
      stateSequence.add(play1Map['state'] as String? ?? 'Playing');

      // 4d. Pause playback
      final pauseResponse = await _channel
          .invokeMethod<Object?>(
            'pauseAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId},
          )
          .timeout(const Duration(seconds: 10));
      final pauseMap = Map<String, dynamic>.from(
        (pauseResponse as Map?) ?? const <String, dynamic>{},
      );
      final pauseState = pauseMap['state'] as String?;
      pausePass =
          pauseMap['pass'] == true &&
          (pauseState == null || pauseState == 'Paused');
      stateSequence.add(pauseState ?? 'Paused');

      // 4e. Seek to 500000us with resumeAfterSeek=false
      final seekResponse = await _channel
          .invokeMethod<Object?>(
            'seekAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{
              'textureId': activeTextureId,
              'targetPtsUs': seekTargetUs,
              'resumeAfterSeek': false,
            },
          )
          .timeout(const Duration(seconds: 30));
      final seekMap = Map<String, dynamic>.from(
        (seekResponse as Map?) ?? const <String, dynamic>{},
      );
      seekPass = seekMap['pass'] == true;
      seekRenderedPtsUs = (seekMap['seekRenderedPtsUs'] as num?)?.toInt() ?? -1;
      stateSequence.add(seekMap['state'] as String? ?? 'Paused');

      // 4f. Resume / play 6 more frames
      final resumeResponse = await _channel
          .invokeMethod<Object?>(
            'playAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
          )
          .timeout(const Duration(seconds: 30));
      final resumeMap = Map<String, dynamic>.from(
        (resumeResponse as Map?) ?? const <String, dynamic>{},
      );
      resumePass = resumeMap['pass'] == true;
      totalRenderedFrames = (resumeMap['renderedFrames'] as num?)?.toInt() ?? 0;
      resumeRenderedFrames = totalRenderedFrames - play1RenderedFrames;
      stateSequence.add(resumeMap['state'] as String? ?? 'Playing');

      // 4g. Dispose session
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

      raw =
          'status=OK;invalidPreparePass=$invalidPreparePass;'
          'validCreatePass=$validCreatePass;play1Pass=$play1Pass;'
          'pausePass=$pausePass;seekPass=$seekPass;resumePass=$resumePass;'
          'disposePass=$disposePass;totalRenderedFrames=$totalRenderedFrames';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B2B1_ERROR: $error\n$stack');
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
        invalidPreparePass &&
        validCreatePass &&
        play1Pass &&
        pausePass &&
        seekPass &&
        resumePass &&
        disposePass &&
        totalRenderedFrames > 0;

    final payload = <String, dynamic>{
      'pass': pass,
      'invalidPreparePass': invalidPreparePass,
      'invalidRaw': invalidRaw,
      'validCreatePass': validCreatePass,
      'play1Pass': play1Pass,
      'pausePass': pausePass,
      'seekPass': seekPass,
      'resumePass': resumePass,
      'disposePass': disposePass,
      'totalRenderedFrames': totalRenderedFrames,
      'play1RenderedFrames': play1RenderedFrames,
      'resumeRenderedFrames': resumeRenderedFrames,
      'seekTargetUs': seekTargetUs,
      'seekRenderedPtsUs': seekRenderedPtsUs,
      'textureId': activeTextureId,
      'width': videoWidth,
      'height': videoHeight,
      'durationUs': videoDurationUs,
      'stateSequence': stateSequence,
      'raw': raw,
    };

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B2B1_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B2B1_PREPARE_FAILURE_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4B2B1_PREPARE_FAILURE_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $raw';
      });
    }
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
