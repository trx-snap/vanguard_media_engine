// android_timeline_live_filter_chain_physical_smoke.dart
// Vanguard Android Phase 10-C-3N: Timeline Live Filter-Chain Control Guard Bridge Physical Smoke Test.
//
// Proves Android public VGTimelineLiveControls and native AndroidTimelineLiveControlCoordinator guard route:
//   - Lane 1: TextureId rejection ordering with no active timeline (INVALID_ARG before NO_TIMELINE)
//   - Lane 2: Filters shape rejection with no active timeline (INVALID_ARG before NO_TIMELINE)
//   - Lane 3: NO_TIMELINE when no timeline is active
//   - Lane 4: Active timeline creation and playback (positive PTS observation)
//   - Lane 5: STALE_TIMELINE while active
//   - Lane 6: Empty-list success while active (route reachability & no-filter postcondition)
//   - Lane 7: UNKNOWN_FILTER ordering & stale precedes unknown
//   - Lane 8: Known filter capability fail-closed (UNSUPPORTED_TIMELINE_FEATURE) and all-disabled success
//   - Lane 9: Playback non-disruption during live filter update
//   - Lane 10: Dispose lifecycle transition to NO_TIMELINE

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidTimelineLiveFilterChainPhysicalSmokeApp());
}

class AndroidTimelineLiveFilterChainPhysicalSmokeApp extends StatefulWidget {
  const AndroidTimelineLiveFilterChainPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineLiveFilterChainPhysicalSmokeApp> createState() =>
      _AndroidTimelineLiveFilterChainPhysicalSmokeAppState();
}

class _AndroidTimelineLiveFilterChainPhysicalSmokeAppState
    extends State<AndroidTimelineLiveFilterChainPhysicalSmokeApp> {
  static const MethodChannel _rawChannel = MethodChannel(
    'vanguard_media_engine',
  );

  String _status =
      'Initializing Android timeline live filter-chain physical smoke…';
  VGEditorValue? _editorValue;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN: TIMEOUT (90s exceeded)');
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_PHYSICAL_FAIL');
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<String?> _invokeRawExpectErrorCode(Map<dynamic, dynamic>? args) async {
    try {
      await _rawChannel.invokeMethod<void>('timeline_setFilterChain', args);
      return null;
    } on PlatformException catch (e) {
      return e.code;
    } catch (e) {
      return 'UNEXPECTED_EXCEPTION: $e';
    }
  }

  Future<bool> _invokeRawExpectSuccess(Map<dynamic, dynamic>? args) async {
    try {
      await _rawChannel.invokeMethod<void>('timeline_setFilterChain', args);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _runSmoke() async {
    print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN: START');
    await Future<void>.delayed(const Duration(seconds: 1));

    File? tempClipFile;
    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = [];

    final liveControls = VGTimelineLiveControls();

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;
    var lane10Pass = false;

    Map<String, dynamic> lane1Details = {};
    Map<String, dynamic> lane2Details = {};
    Map<String, dynamic> lane3Details = {};
    Map<String, dynamic> lane4Details = {};
    Map<String, dynamic> lane5Details = {};
    Map<String, dynamic> lane6Details = {};
    Map<String, dynamic> lane7Details = {};
    Map<String, dynamic> lane8Details = {};
    Map<String, dynamic> lane9Details = {};
    Map<String, dynamic> lane10Details = {};

    int activeTextureId = -1;
    String? topLevelError;

    try {
      // ─────────────────────────────────────────────────────────────────────────
      // Lane 1: TextureId rejection ordering with no active timeline
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE1: START');
      final l1Cases = <String, Map<dynamic, dynamic>?>{
        'missing_textureId': {'filters': <dynamic>[]},
        'null_textureId': {'textureId': null, 'filters': <dynamic>[]},
        'string_textureId': {'textureId': '0', 'filters': <dynamic>[]},
        'double_textureId': {'textureId': 0.0, 'filters': <dynamic>[]},
        'bool_textureId': {'textureId': true, 'filters': <dynamic>[]},
        'negative_textureId': {'textureId': -1, 'filters': <dynamic>[]},
      };

      final l1Results = <String, String?>{};
      var l1AllInvalidArg = true;
      for (final entry in l1Cases.entries) {
        final code = await _invokeRawExpectErrorCode(entry.value);
        l1Results[entry.key] = code;
        if (code != 'INVALID_ARG') {
          l1AllInvalidArg = false;
        }
      }

      var l1PublicNegativeThrowsInvalidArg = false;
      try {
        await liveControls.setFilterChain(textureId: -1, filters: []);
      } on PlatformException catch (e) {
        if (e.code == 'INVALID_ARG') {
          l1PublicNegativeThrowsInvalidArg = true;
        }
      } catch (_) {}

      lane1Pass = l1AllInvalidArg && l1PublicNegativeThrowsInvalidArg;
      lane1Details = {
        'rawResults': l1Results,
        'publicNegativeThrowsInvalidArg': l1PublicNegativeThrowsInvalidArg,
        'pass': lane1Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE1_PASS: $lane1Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 2: Filters shape rejection with no active timeline
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE2: START');
      final l2Cases = <String, Map<dynamic, dynamic>?>{
        'missing_filters': {'textureId': 0},
        'null_filters': {'textureId': 0, 'filters': null},
        'string_filters': {'textureId': 0, 'filters': 'not-a-list'},
        'map_filters': {
          'textureId': 0,
          'filters': {'a': 1},
        },
        'list_with_string': {
          'textureId': 0,
          'filters': ['not-a-map'],
        },
        'list_with_int': {
          'textureId': 0,
          'filters': [123],
        },
      };

      final l2Results = <String, String?>{};
      var l2AllInvalidArg = true;
      for (final entry in l2Cases.entries) {
        final code = await _invokeRawExpectErrorCode(entry.value);
        l2Results[entry.key] = code;
        if (code != 'INVALID_ARG') {
          l2AllInvalidArg = false;
        }
      }

      lane2Pass = l2AllInvalidArg;
      lane2Details = {'rawResults': l2Results, 'pass': lane2Pass};
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE2_PASS: $lane2Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 3: NO_TIMELINE when no timeline is active
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE3: START');
      final l3Code0 = await _invokeRawExpectErrorCode({
        'textureId': 0,
        'filters': <dynamic>[],
      });
      final l3Code99 = await _invokeRawExpectErrorCode({
        'textureId': 99,
        'filters': <dynamic>[],
      });
      var l3PublicNoTimeline = false;
      try {
        await liveControls.setFilterChain(textureId: 0, filters: []);
      } on PlatformException catch (e) {
        if (e.code == 'NO_TIMELINE') {
          l3PublicNoTimeline = true;
        }
      } catch (_) {}

      lane3Pass =
          (l3Code0 == 'NO_TIMELINE') &&
          (l3Code99 == 'NO_TIMELINE') &&
          l3PublicNoTimeline;
      lane3Details = {
        'rawCode0': l3Code0,
        'rawCode99': l3Code99,
        'publicCode': l3PublicNoTimeline ? 'NO_TIMELINE' : 'OTHER',
        'pass': lane3Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE3_PASS: $lane3Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 4: Active timeline creation and playback
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE4: START');
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      tempClipFile = File(
        '${tempDir.path}/android_timeline_live_controls_clip.mov',
      );
      final bytesList = clipBytes.buffer.asUint8List(
        clipBytes.offsetInBytes,
        clipBytes.lengthInBytes,
      );
      await tempClipFile.writeAsBytes(bytesList, flush: true);

      final clip = VGClipDescriptor(
        id: 'clip_timeline_live_1',
        mediaKind: VGMediaKind.video,
        sourcePath: tempClipFile.path,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        startTimeSeconds: 0.0,
      );

      final draft = VGEditorDraft(
        id: 'draft_timeline_live_controls_smoke',
        clips: [clip],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );

      final controller = VGEditorController(initialDraft: draft);
      cleanupController = controller;

      ptsSubscription = controller.ptsStream.listen((pts) {
        ptsValues.add(pts);
      });

      await controller.initialize().timeout(const Duration(seconds: 10));

      final createdTextureId = controller.textureId;
      final initOk =
          createdTextureId != null &&
          createdTextureId >= 0 &&
          controller.isReady;
      activeTextureId = createdTextureId ?? -1;

      if (mounted) {
        setState(() {
          _editorValue = controller.value;
          _status = 'Active timeline created (textureId=$activeTextureId)';
        });
      }

      final positivePtsCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts > 0.0 && !positivePtsCompleter.isCompleted) {
          positivePtsCompleter.complete(pts);
        }
      });

      await controller.play();
      final firstPositivePts = await positivePtsCompleter.future
          .timeout(const Duration(seconds: 10))
          .whenComplete(() => playSub.cancel());

      lane4Pass = initOk && (firstPositivePts > 0.0) && controller.isPlaying;
      lane4Details = {
        'textureId': activeTextureId,
        'isReady': controller.isReady,
        'isPlaying': controller.isPlaying,
        'firstPositivePts': firstPositivePts,
        'pass': lane4Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE4_PASS: $lane4Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 5: STALE_TIMELINE while active
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE5: START');
      final staleRawCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId + 1,
        'filters': <dynamic>[],
      });

      var stalePublicCode = '';
      try {
        await liveControls.setFilterChain(
          textureId: activeTextureId + 1,
          filters: [],
        );
      } on PlatformException catch (e) {
        stalePublicCode = e.code;
      } catch (e) {
        stalePublicCode = 'OTHER: $e';
      }

      lane5Pass =
          (staleRawCode == 'STALE_TIMELINE') &&
          (stalePublicCode == 'STALE_TIMELINE');
      lane5Details = {
        'staleTextureId': activeTextureId + 1,
        'rawCode': staleRawCode,
        'publicCode': stalePublicCode,
        'pass': lane5Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE5_PASS: $lane5Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 6: Empty-list success while active
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE6: START');
      var publicEmptySuccess = false;
      try {
        await liveControls.setFilterChain(
          textureId: activeTextureId,
          filters: [],
        );
        publicEmptySuccess = true;
      } catch (_) {
        publicEmptySuccess = false;
      }

      final rawEmptySuccess = await _invokeRawExpectSuccess({
        'textureId': activeTextureId,
        'filters': <dynamic>[],
      });

      lane6Pass = publicEmptySuccess && rawEmptySuccess;
      lane6Details = {
        'publicEmptySuccess': publicEmptySuccess,
        'rawEmptySuccess': rawEmptySuccess,
        'pass': lane6Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE6_PASS: $lane6Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 7: UNKNOWN_FILTER ordering & stale precedes unknown
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE7: START');
      final unknownColorMatrixCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId,
        'filters': [
          {'type': 'colorMatrix', 'enabled': true},
        ],
      });

      final unknownBogusCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId,
        'filters': [
          {'type': 'bogus', 'enabled': false},
        ],
      });

      final staleBeforeUnknownCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId + 1,
        'filters': [
          {'type': 'bogus', 'enabled': false},
        ],
      });

      lane7Pass =
          (unknownColorMatrixCode == 'UNKNOWN_FILTER') &&
          (unknownBogusCode == 'UNKNOWN_FILTER') &&
          (staleBeforeUnknownCode == 'STALE_TIMELINE');

      lane7Details = {
        'unknownColorMatrixCode': unknownColorMatrixCode,
        'unknownBogusCode': unknownBogusCode,
        'staleBeforeUnknownCode': staleBeforeUnknownCode,
        'pass': lane7Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE7_PASS: $lane7Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 8: Known filter capability fail-closed and all-disabled success
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE8: START');
      final enabledLutCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId,
        'filters': [
          {
            'type': 'lut',
            'enabled': true,
            'parameters': {'intensity': 0.8},
          },
        ],
      });

      var publicEnabledLutCode = '';
      try {
        await liveControls.setFilterChain(
          textureId: activeTextureId,
          filters: [VGFilterSpecs.lut(intensity: 0.8)],
        );
      } on PlatformException catch (e) {
        publicEnabledLutCode = e.code;
      } catch (e) {
        publicEnabledLutCode = 'OTHER: $e';
      }

      final disabledLutSuccess = await _invokeRawExpectSuccess({
        'textureId': activeTextureId,
        'filters': [
          {'type': 'lut', 'enabled': false},
        ],
      });

      final allDisabledKnownSuccess = await _invokeRawExpectSuccess({
        'textureId': activeTextureId,
        'filters': [
          {'type': 'lut', 'enabled': false},
          {'type': 'beauty', 'enabled': false},
          {'type': 'segmentation', 'enabled': false},
        ],
      });

      final mixedEnabledCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId,
        'filters': [
          {'type': 'beauty', 'enabled': false},
          {'type': 'lut', 'enabled': true},
        ],
      });

      lane8Pass =
          (enabledLutCode == 'UNSUPPORTED_TIMELINE_FEATURE') &&
          (publicEnabledLutCode == 'UNSUPPORTED_TIMELINE_FEATURE') &&
          disabledLutSuccess &&
          allDisabledKnownSuccess &&
          (mixedEnabledCode == 'UNSUPPORTED_TIMELINE_FEATURE');

      lane8Details = {
        'enabledLutCode': enabledLutCode,
        'publicEnabledLutCode': publicEnabledLutCode,
        'disabledLutSuccess': disabledLutSuccess,
        'allDisabledKnownSuccess': allDisabledKnownSuccess,
        'mixedEnabledCode': mixedEnabledCode,
        'pass': lane8Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE8_PASS: $lane8Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 9: Playback non-disruption
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE9: START');
      if (!controller.isPlaying) {
        await controller.play();
      }

      final ptsBeforeCall = controller.currentPTS;
      final ptsAfterCompleter = Completer<double>();
      final nonDisruptionSub = controller.ptsStream.listen((pts) {
        if (pts > ptsBeforeCall + 0.05 && !ptsAfterCompleter.isCompleted) {
          ptsAfterCompleter.complete(pts);
        }
      });

      // Invoke empty filter update while playback is running
      await liveControls.setFilterChain(
        textureId: activeTextureId,
        filters: [],
      );

      final ptsAfterCall = await ptsAfterCompleter.future
          .timeout(const Duration(seconds: 5))
          .whenComplete(() => nonDisruptionSub.cancel());

      lane9Pass = ptsAfterCall > ptsBeforeCall && controller.isPlaying;
      lane9Details = {
        'ptsBeforeCall': ptsBeforeCall,
        'ptsAfterCall': ptsAfterCall,
        'isPlaying': controller.isPlaying,
        'pass': lane9Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE9_PASS: $lane9Pass');

      // ─────────────────────────────────────────────────────────────────────────
      // Lane 10: Dispose lifecycle
      // ─────────────────────────────────────────────────────────────────────────
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE10: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;

      final postDisposeRawCode = await _invokeRawExpectErrorCode({
        'textureId': activeTextureId,
        'filters': <dynamic>[],
      });

      var postDisposePublicCode = '';
      try {
        await liveControls.setFilterChain(
          textureId: activeTextureId,
          filters: [],
        );
      } on PlatformException catch (e) {
        postDisposePublicCode = e.code;
      } catch (e) {
        postDisposePublicCode = 'OTHER: $e';
      }

      lane10Pass =
          (postDisposeRawCode == 'NO_TIMELINE') &&
          (postDisposePublicCode == 'NO_TIMELINE');
      lane10Details = {
        'formerTextureId': activeTextureId,
        'postDisposeRawCode': postDisposeRawCode,
        'postDisposePublicCode': postDisposePublicCode,
        'pass': lane10Pass,
      };
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_LANE10_PASS: $lane10Pass');
    } catch (e, st) {
      topLevelError = '$e';
      print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_ERROR: $e\n$st');
    } finally {
      await ptsSubscription?.cancel();
      if (cleanupController != null) {
        try {
          await cleanupController.disposeAsyncConfirmed();
        } catch (_) {}
        cleanupController.dispose();
      }
      if (tempClipFile != null && await tempClipFile.exists()) {
        try {
          await tempClipFile.delete();
        } catch (_) {}
      }
    }

    final overallPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        lane7Pass &&
        lane8Pass &&
        lane9Pass &&
        lane10Pass &&
        (topLevelError == null);

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'lane1Pass': lane1Pass,
      'lane2Pass': lane2Pass,
      'lane3Pass': lane3Pass,
      'lane4Pass': lane4Pass,
      'lane5Pass': lane5Pass,
      'lane6Pass': lane6Pass,
      'lane7Pass': lane7Pass,
      'lane8Pass': lane8Pass,
      'lane9Pass': lane9Pass,
      'lane10Pass': lane10Pass,
      'textureId': activeTextureId,
      'lane1Details': lane1Details,
      'lane2Details': lane2Details,
      'lane3Details': lane3Details,
      'lane4Details': lane4Details,
      'lane5Details': lane5Details,
      'lane6Details': lane6Details,
      'lane7Details': lane7Details,
      'lane8Details': lane8Details,
      'lane9Details': lane9Details,
      'lane10Details': lane10Details,
      'nonClaims':
          'This test proves route reachability, error ordering, guard rails, and playback non-disruption. It does NOT assert visual filter evaluation or pixel changes on Android.',
      'error': topLevelError,
    };

    print('ANDROID_TIMELINE_LIVE_FILTER_CHAIN_JSON:${jsonEncode(jsonSummary)}');

    print(
      overallPass
          ? 'ANDROID_TIMELINE_LIVE_FILTER_CHAIN_PHYSICAL_PASS'
          : 'ANDROID_TIMELINE_LIVE_FILTER_CHAIN_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android timeline live filter-chain guard bridge verified across 10 lanes.'
            : 'FAIL: $topLevelError';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(overallPass ? 0 : 1);
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
              if (_editorValue != null)
                SizedBox(
                  height: 360,
                  child: VGEditorTextureView(
                    value: _editorValue!,
                    fit: BoxFit.contain,
                    backgroundColor: Colors.black,
                  ),
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
