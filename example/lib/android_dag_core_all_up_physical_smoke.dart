// Phase 4B2D: Android Core DAG All-Up Physical Smoke Harness.
// Sequences all non-streaming/core DAG diagnostic MethodChannel routes:
// 1. Capability probe (Phase 2Q)
// 2. Multi-frame Vulkan render (Phase 2O2B4)
// 3. DAG graph evaluation + render dispatch (Phase 3C)
// 4. MediaCodec decoder -> ImageReader -> HardwareBuffer -> Vulkan render (Phase 4A)
// 5. Playback clock/state foundation (Phase 4B2A)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagCoreAllUpPhysicalSmokeApp());
}

class AndroidDagCoreAllUpPhysicalSmokeApp extends StatefulWidget {
  const AndroidDagCoreAllUpPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagCoreAllUpPhysicalSmokeApp> createState() =>
      _AndroidDagCoreAllUpPhysicalSmokeAppState();
}

class _AndroidDagCoreAllUpPhysicalSmokeAppState
    extends State<AndroidDagCoreAllUpPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Core All-Up Physical Smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    // -- 1. Capability Probe --------------------------------------------------
    print('ANDROID_DAG_CORE_ALL_UP_STEP_CAPABILITY_PROBE: START');
    Map<String, dynamic> capProbeMap;
    var capProbePass = false;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2QCapabilityProbe',
      );
      capProbeMap = Map<String, dynamic>.from(response! as Map);
      capProbePass = capProbeMap['pass'] == true;
      print('ANDROID_DAG_CORE_ALL_UP_STEP_CAPABILITY_PROBE: DONE');
    } catch (e, st) {
      print('ANDROID_DAG_CORE_ALL_UP_STEP_CAPABILITY_PROBE: ERROR: $e\n$st');
      capProbeMap = <String, dynamic>{'pass': false, 'error': '$e'};
      capProbePass = false;
    }

    // -- 2. Multi-frame Vulkan Render -----------------------------------------
    print('ANDROID_DAG_CORE_ALL_UP_STEP_MULTI_FRAME_RENDER: START');
    Map<String, dynamic> multiFrameMap;
    var multiFramePass = false;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase2O2B4MultiFrameSmoke',
        const <String, Object>{'width': 64, 'height': 64, 'frameCount': 30},
      );
      multiFrameMap = Map<String, dynamic>.from(response! as Map);
      final raw = multiFrameMap['raw']?.toString() ?? '';
      final renderedFrames = (multiFrameMap['renderedFrames'] as num?)?.toInt();
      final passVal = multiFrameMap['pass'] == true;
      final framesOk =
          renderedFrames == 30 ||
          (raw.contains('renderedFrames=30') &&
              raw.contains('renderFrame=success'));
      multiFramePass = passVal && framesOk;
      print('ANDROID_DAG_CORE_ALL_UP_STEP_MULTI_FRAME_RENDER: DONE');
    } catch (e, st) {
      print('ANDROID_DAG_CORE_ALL_UP_STEP_MULTI_FRAME_RENDER: ERROR: $e\n$st');
      multiFrameMap = <String, dynamic>{
        'pass': false,
        'error': '$e',
        'width': 64,
        'height': 64,
        'frameCount': 30,
      };
      multiFramePass = false;
    }

    // -- 3. DAG Graph Evaluation + Render Dispatch ----------------------------
    print('ANDROID_DAG_CORE_ALL_UP_STEP_GRAPH_EVAL_RENDER: START');
    Map<String, dynamic> graphEvalMap;
    var graphEvalPass = false;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase3CEvalRenderSmoke',
        const <String, Object>{
          'width': 64,
          'height': 64,
          'frameCount': 30,
          'frameDurationUs': 33333,
        },
      );
      graphEvalMap = Map<String, dynamic>.from(response! as Map);
      final passVal = graphEvalMap['pass'] == true;
      final frameCount = (graphEvalMap['frameCount'] as num?)?.toInt();
      graphEvalPass = passVal && (frameCount == 30);
      print('ANDROID_DAG_CORE_ALL_UP_STEP_GRAPH_EVAL_RENDER: DONE');
    } catch (e, st) {
      print('ANDROID_DAG_CORE_ALL_UP_STEP_GRAPH_EVAL_RENDER: ERROR: $e\n$st');
      graphEvalMap = <String, dynamic>{
        'pass': false,
        'error': '$e',
        'width': 64,
        'height': 64,
        'frameCount': 30,
      };
      graphEvalPass = false;
    }

    // -- 4. MediaCodec Decoder -> ImageReader -> HardwareBuffer -> Vulkan -----
    print('ANDROID_DAG_CORE_ALL_UP_STEP_DECODER_FRAME_BRIDGE: START');
    Map<String, dynamic> decoderMap;
    var decoderPass = false;
    File? tempFile;
    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempFile = File('${tempDir.path}/phase4b2d_core_all_up_clip_b.mov');
      await tempFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4ADecoderSmoke',
        <String, Object>{'path': tempFile.path, 'frameCount': 10},
      );
      decoderMap = Map<String, dynamic>.from(response! as Map);
      final passVal = decoderMap['pass'] == true;
      final renderedFrames =
          (decoderMap['renderedFrames'] as num?)?.toInt() ?? 0;
      final frameCount = (decoderMap['frameCount'] as num?)?.toInt() ?? 0;
      decoderPass = passVal && renderedFrames >= 1 && frameCount == 10;
      print('ANDROID_DAG_CORE_ALL_UP_STEP_DECODER_FRAME_BRIDGE: DONE');
    } catch (e, st) {
      print(
        'ANDROID_DAG_CORE_ALL_UP_STEP_DECODER_FRAME_BRIDGE: ERROR: $e\n$st',
      );
      decoderMap = <String, dynamic>{
        'pass': false,
        'error': '$e',
        'renderedFrames': 0,
        'frameCount': 10,
      };
      decoderPass = false;
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }

    // -- 5. Playback Clock & State Foundation ---------------------------------
    print('ANDROID_DAG_CORE_ALL_UP_STEP_PLAYBACK_CLOCK_STATE: START');
    Map<String, dynamic> clockStateMap;
    var clockStatePass = false;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4B2AClockStateSmoke',
      );
      clockStateMap = Map<String, dynamic>.from(response! as Map);
      final passVal = clockStateMap['pass'] == true;
      final invalidTransitionPass =
          clockStateMap['invalidTransitionPass'] == true;
      clockStatePass = passVal && invalidTransitionPass;
      print('ANDROID_DAG_CORE_ALL_UP_STEP_PLAYBACK_CLOCK_STATE: DONE');
    } catch (e, st) {
      print(
        'ANDROID_DAG_CORE_ALL_UP_STEP_PLAYBACK_CLOCK_STATE: ERROR: $e\n$st',
      );
      clockStateMap = <String, dynamic>{
        'pass': false,
        'error': '$e',
        'invalidTransitionPass': false,
      };
      clockStatePass = false;
    }

    // -- Aggregate JSON and Verdict -------------------------------------------
    final allPass =
        capProbePass &&
        multiFramePass &&
        graphEvalPass &&
        decoderPass &&
        clockStatePass;

    final aggregatePayload = <String, dynamic>{
      'phase': 'Phase4B2D',
      'target': 'android_physical',
      'pass': allPass,
      'capabilityProbe': capProbeMap,
      'multiFrameRender': multiFrameMap,
      'graphEvalRender': graphEvalMap,
      'decoderFrameBridge': decoderMap,
      'playbackClockState': clockStateMap,
      'nonClaims': const <String>[
        'no product UI wiring',
        'no ConnectsApp touched',
        'no streaming/cache/RTC claim',
        'no texture presentation/control claim',
      ],
    };

    print(
      'ANDROID_DAG_CORE_ALL_UP_PHYSICAL_JSON:${jsonEncode(aggregatePayload)}',
    );
    print(
      allPass
          ? 'ANDROID_DAG_CORE_ALL_UP_PHYSICAL_PASS'
          : 'ANDROID_DAG_CORE_ALL_UP_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
