// Vanguard Android True-DAG Phase 4B1B: Diagnostic physical playback control smoke.
//
// Route:
//   MediaExtractor/MediaCodec -> ImageReader/HardwareBuffer ->
//   native DAG generation-aware evaluation -> VulkanBackend render ->
//   Flutter TextureRegistry texture.
//
// Smoke lifecycle sequence:
//   1. Copy bundled clip_B.mov to temp file.
//   2. Create control session -> display Texture(textureId).
//   3. Play 6 frames -> Pause.
//   4. Seek to targetUs = (durationUs > 0 ? min(500000, max(0, durationUs / 3)) : 0).
//   5. Verify seek PTS >= targetUs if targetUs > 0.
//   6. Resume / play 6 more frames.
//   7. Dispose session.
//   8. Print ANDROID_DAG_PHASE4B1B_JSON:<json> and PASS/FAIL.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagPhase4B1BPlaybackControlSmokeApp());
}

class AndroidDagPhase4B1BPlaybackControlSmokeApp extends StatefulWidget {
  const AndroidDagPhase4B1BPlaybackControlSmokeApp({super.key});

  @override
  State<AndroidDagPhase4B1BPlaybackControlSmokeApp> createState() =>
      _AndroidDagPhase4B1BPlaybackControlSmokeAppState();
}

class _AndroidDagPhase4B1BPlaybackControlSmokeAppState
    extends State<AndroidDagPhase4B1BPlaybackControlSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Phase 4B1B playback control smoke…';
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
    var play1Pass = false;
    var play1RenderedFrames = 0;
    var pausePass = false;
    var seekPass = false;
    var seekTargetUs = 0;
    var seekRenderedPtsUs = -1;
    var resumePass = false;
    var resumeRenderedFrames = 0;
    var totalRenderedFrames = 0;
    var disposePass = false;
    String? play1NativeRenderStatus;
    String? seekNativeRenderStatus;
    String? resumeNativeRenderStatus;
    String raw = '';

    try {
      // 1. Copy clip_B.mov to temp file
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b1b_clip_b_smoke.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      // 2. Create control session
      final createResponse = await _channel.invokeMethod<Object?>(
        'createAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{'path': tempFile.path},
      );
      final createMap = Map<String, dynamic>.from(createResponse! as Map);
      createPass = createMap['pass'] == true;
      activeTextureId = (createMap['textureId'] as num?)?.toInt() ?? -1;
      videoWidth = (createMap['width'] as num?)?.toInt() ?? 0;
      videoHeight = (createMap['height'] as num?)?.toInt() ?? 0;
      videoDurationUs = (createMap['durationUs'] as num?)?.toInt() ?? 0;
      stateSequence.add(createMap['state'] as String? ?? 'Prepared');

      if (mounted && activeTextureId >= 0) {
        setState(() {
          _textureId = activeTextureId;
          _status = 'Session prepared (textureId=$activeTextureId)';
        });
      }

      if (!createPass || activeTextureId < 0) {
        throw Exception('Create session failed: ${createMap['raw']}');
      }

      // 3. Play 6 frames
      final play1Response = await _channel.invokeMethod<Object?>(
        'playAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
      );
      final play1Map = Map<String, dynamic>.from(play1Response! as Map);
      play1Pass = play1Map['pass'] == true;
      play1RenderedFrames = (play1Map['renderedFrames'] as num?)?.toInt() ?? 0;
      play1NativeRenderStatus = play1Map['lastNativeRenderStatus'] as String?;
      stateSequence.add(play1Map['state'] as String? ?? 'Playing');

      // 4. Pause playback
      final pauseResponse = await _channel.invokeMethod<Object?>(
        'pauseAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{'textureId': activeTextureId},
      );
      final pauseMap = Map<String, dynamic>.from(pauseResponse! as Map);
      final pauseState = pauseMap['state'] as String?;
      pausePass =
          pauseMap['pass'] == true &&
          (pauseState == null || pauseState == 'Paused');
      stateSequence.add(pauseState ?? 'Paused');

      // 5. Seek target calculation
      seekTargetUs = videoDurationUs <= 0
          ? 0
          : min(500000, max(0, videoDurationUs ~/ 3));

      final seekResponse = await _channel.invokeMethod<Object?>(
        'seekAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{
          'textureId': activeTextureId,
          'targetPtsUs': seekTargetUs,
          'resumeAfterSeek': false,
        },
      );
      final seekMap = Map<String, dynamic>.from(seekResponse! as Map);
      seekPass = seekMap['pass'] == true;
      seekRenderedPtsUs = (seekMap['seekRenderedPtsUs'] as num?)?.toInt() ?? -1;
      seekNativeRenderStatus = seekMap['seekNativeRenderStatus'] as String?;
      stateSequence.add(seekMap['state'] as String? ?? 'Paused');

      // 6. Resume / play 6 more frames
      final resumeResponse = await _channel.invokeMethod<Object?>(
        'playAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{'textureId': activeTextureId, 'frameBudget': 6},
      );
      final resumeMap = Map<String, dynamic>.from(resumeResponse! as Map);
      resumePass = resumeMap['pass'] == true;
      totalRenderedFrames = (resumeMap['renderedFrames'] as num?)?.toInt() ?? 0;
      resumeRenderedFrames = totalRenderedFrames - play1RenderedFrames;
      resumeNativeRenderStatus = resumeMap['lastNativeRenderStatus'] as String?;
      stateSequence.add(resumeMap['state'] as String? ?? 'Playing');

      // 7. Dispose session
      final disposeResponse = await _channel.invokeMethod<Object?>(
        'disposeAndroidDagPhase4B1BPlaybackControlSmoke',
        <String, Object>{'textureId': activeTextureId},
      );
      final disposeMap = Map<String, dynamic>.from(disposeResponse! as Map);
      disposePass = disposeMap['pass'] == true;
      stateSequence.add(disposeMap['state'] as String? ?? 'Disposed');

      raw =
          'status=OK;createPass=$createPass;play1Pass=$play1Pass;'
          'pausePass=$pausePass;seekPass=$seekPass;resumePass=$resumePass;'
          'disposePass=$disposePass';
    } catch (error, stack) {
      // ignore: avoid_print
      print('ANDROID_DAG_PHASE4B1B_ERROR: $error\n$stack');
      raw = 'status=FAIL;reason=dart_exception:$error';
      if (activeTextureId >= 0 && !disposePass) {
        try {
          final disposeResponse = await _channel.invokeMethod<Object?>(
            'disposeAndroidDagPhase4B1BPlaybackControlSmoke',
            <String, Object>{'textureId': activeTextureId},
          );
          final disposeMap = Map<String, dynamic>.from(disposeResponse! as Map);
          disposePass = disposeMap['pass'] == true;
          stateSequence.add(disposeMap['state'] as String? ?? 'Disposed');
        } catch (_) {}
      }
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }

    final seekPtsValid =
        seekTargetUs == 0 || (seekRenderedPtsUs >= seekTargetUs);

    // Multinode DAG execution-plan telemetry: at least one native render status
    // from play1/seek/resume must show the planner ran over the two-node
    // playback presentation graph (one source + one sink).
    bool hasMultinodePlanTelemetry(String? status) =>
        status != null &&
        status.contains('planNodeCount=2') &&
        status.contains('planSinkCount=1');
    final multinodePlanTelemetryPass =
        hasMultinodePlanTelemetry(play1NativeRenderStatus) ||
        hasMultinodePlanTelemetry(seekNativeRenderStatus) ||
        hasMultinodePlanTelemetry(resumeNativeRenderStatus);

    final pass =
        createPass &&
        play1Pass &&
        play1RenderedFrames >= 6 &&
        pausePass &&
        seekPass &&
        seekPtsValid &&
        resumePass &&
        resumeRenderedFrames >= 6 &&
        totalRenderedFrames >= (play1RenderedFrames + 6) &&
        disposePass &&
        multinodePlanTelemetryPass;

    final payload = <String, dynamic>{
      'pass': pass,
      'textureId': activeTextureId,
      'width': videoWidth,
      'height': videoHeight,
      'durationUs': videoDurationUs,
      'stateSequence': stateSequence,
      'play1RenderedFrames': play1RenderedFrames,
      'seekTargetUs': seekTargetUs,
      'seekRenderedPtsUs': seekRenderedPtsUs,
      'resumeRenderedFrames': resumeRenderedFrames,
      'totalRenderedFrames': totalRenderedFrames,
      'disposePass': disposePass,
      'play1NativeRenderStatus': play1NativeRenderStatus,
      'seekNativeRenderStatus': seekNativeRenderStatus,
      'resumeNativeRenderStatus': resumeNativeRenderStatus,
      'multinodePlanTelemetryPass': multinodePlanTelemetryPass,
      'raw': raw,
    };

    // ignore: avoid_print
    print('ANDROID_DAG_PHASE4B1B_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_DAG_PHASE4B1B_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4B1B_PHYSICAL_SMOKE_FAIL',
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
