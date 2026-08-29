// android_audio_playback_unit_y_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit Y / Phase 4-Unit G
// Android Standalone Audio Playback Service Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart"
    show MethodChannel, PlatformException, rootBundle;
import "package:vanguard_media_engine/vanguard_media_engine.dart";

void main() {
  runApp(const AndroidAudioPlaybackUnitYPhysicalSmokeApp());
}

class AndroidAudioPlaybackUnitYPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioPlaybackUnitYPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioPlaybackUnitYPhysicalSmokeApp> createState() =>
      _AndroidAudioPlaybackUnitYPhysicalSmokeAppState();
}

class _AndroidAudioPlaybackUnitYPhysicalSmokeAppState
    extends State<AndroidAudioPlaybackUnitYPhysicalSmokeApp> {
  String _status =
      "Initializing Android Audio Playback Physical Smoke (Unit Y)...";
  Timer? _timeoutTimer;

  static const MethodChannel _rawChannel = MethodChannel(
    "vanguard_media_engine",
  );

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y: TIMEOUT (90s exceeded)");
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_PHYSICAL_FAIL");
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

  Future<void> _runSmoke() async {
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y: START");
    final runId = "unit_y_${DateTime.now().millisecondsSinceEpoch}";
    final tempFilePath =
        "${Directory.systemTemp.path}/unit_y_fixture_$runId.mov";
    File? tempFile;

    var laneAPass = false;
    var laneBPass = false;
    var laneCPass = false;
    var laneDPass = false;
    var laneEPass = false;
    var laneFPass = false;
    var laneGPass = false;
    var laneHPass = false;
    var laneIPass = false;

    Map<String, dynamic> laneAMap = <String, dynamic>{};
    Map<String, dynamic> laneBMap = <String, dynamic>{};
    Map<String, dynamic> laneCMap = <String, dynamic>{};
    Map<String, dynamic> laneDMap = <String, dynamic>{};
    Map<String, dynamic> laneEMap = <String, dynamic>{};
    Map<String, dynamic> laneFMap = <String, dynamic>{};
    Map<String, dynamic> laneGMap = <String, dynamic>{};
    Map<String, dynamic> laneHMap = <String, dynamic>{};
    Map<String, dynamic> laneIMap = <String, dynamic>{};

    String? topLevelError;

    try {
      // Step 1: Copy bundled fixture clip_A.mov to system temp
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y: Staging test fixture to $tempFilePath",
      );
      final byteData = await rootBundle.load(
        "assets/manual_test_clips/clip_A.mov",
      );
      tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y: Staged fixture size=${await tempFile.length()} bytes",
      );

      double loadedDuration = 0.0;

      // ── Lane A: Valid load returns durationSeconds > 0 ──────────────────────
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_A: START (valid load)");
      try {
        loadedDuration = await VGAudioPlaybackService.load(path: tempFilePath);
        laneAPass = loadedDuration > 0.0;
        laneAMap = <String, dynamic>{
          "pass": laneAPass,
          "durationSeconds": loadedDuration,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_A: DONE (pass=$laneAPass, durationSeconds=$loadedDuration)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_A: ERROR: $e\n$st");
        laneAMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneAPass = false;
      }

      // ── Lane B: Play advances position over ~1s ─────────────────────────────
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_B: START (play advances position)",
      );
      try {
        final baselinePos = await VGAudioPlaybackService.getPosition();
        await VGAudioPlaybackService.play();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        final laterPos = await VGAudioPlaybackService.getPosition();

        final delta = laterPos - baselinePos;
        // Expect position to advance by at least 0.2s over 1s interval
        laneBPass = laterPos > baselinePos && delta >= 0.2;
        laneBMap = <String, dynamic>{
          "pass": laneBPass,
          "baselinePos": baselinePos,
          "laterPos": laterPos,
          "delta": delta,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_B: DONE (pass=$laneBPass, baseline=$baselinePos, later=$laterPos, delta=$delta)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_B: ERROR: $e\n$st");
        laneBMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneBPass = false;
      }

      // ── Lane C: Pause freezes position (~500ms apart differ <= 0.25s) ───────
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_C: START (pause freezes position)",
      );
      try {
        await VGAudioPlaybackService.pause();
        final pausePos1 = await VGAudioPlaybackService.getPosition();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final pausePos2 = await VGAudioPlaybackService.getPosition();

        final pauseDelta = (pausePos2 - pausePos1).abs();
        laneCPass = pauseDelta <= 0.25;
        laneCMap = <String, dynamic>{
          "pass": laneCPass,
          "pausePos1": pausePos1,
          "pausePos2": pausePos2,
          "pauseDelta": pauseDelta,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_C: DONE (pass=$laneCPass, pos1=$pausePos1, pos2=$pausePos2, delta=$pauseDelta)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_C: ERROR: $e\n$st");
        laneCMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneCPass = false;
      }

      // ── Lane D: Seek moves position near target (<= 1.0s tolerance) ─────────
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_D: START (seek near target)");
      try {
        final targetSeek = (loadedDuration > 2.0)
            ? (loadedDuration / 2.0)
            : 1.0;
        await VGAudioPlaybackService.seekTo(targetSeek);
        // Bounded wait for seek completion
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final postSeekPos = await VGAudioPlaybackService.getPosition();

        final seekDelta = (postSeekPos - targetSeek).abs();
        laneDPass = seekDelta <= 1.0;
        laneDMap = <String, dynamic>{
          "pass": laneDPass,
          "targetSeek": targetSeek,
          "postSeekPos": postSeekPos,
          "seekDelta": seekDelta,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_D: DONE (pass=$laneDPass, target=$targetSeek, postSeek=$postSeekPos, delta=$seekDelta)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_D: ERROR: $e\n$st");
        laneDMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneDPass = false;
      }

      // ── Lane E: Stop releases/resets (getPosition ~0.0, no-ops do not throw) ─
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_E: START (stop reset/no-op)");
      try {
        await VGAudioPlaybackService.stop();
        final stopPos = await VGAudioPlaybackService.getPosition();

        // Calling play / pause / stop after stop are safe no-ops
        await VGAudioPlaybackService.play();
        await VGAudioPlaybackService.pause();
        await VGAudioPlaybackService.stop();
        final postNoOpPos = await VGAudioPlaybackService.getPosition();

        laneEPass = stopPos.abs() <= 0.05 && postNoOpPos.abs() <= 0.05;
        laneEMap = <String, dynamic>{
          "pass": laneEPass,
          "stopPos": stopPos,
          "postNoOpPos": postNoOpPos,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_E: DONE (pass=$laneEPass, stopPos=$stopPos, postNoOpPos=$postNoOpPos)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_E: ERROR: $e\n$st");
        laneEMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneEPass = false;
      }

      // ── Lane F: Replace load (re-load stops prior, resets position) ─────────
      print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_F: START (replace load)");
      try {
        final d1 = await VGAudioPlaybackService.load(path: tempFilePath);
        await VGAudioPlaybackService.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final d2 = await VGAudioPlaybackService.load(path: tempFilePath);
        final reloadPos = await VGAudioPlaybackService.getPosition();

        laneFPass = d1 > 0.0 && d2 > 0.0 && reloadPos <= 0.2;
        laneFMap = <String, dynamic>{
          "pass": laneFPass,
          "duration1": d1,
          "duration2": d2,
          "reloadPos": reloadPos,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_F: DONE (pass=$laneFPass, d1=$d1, d2=$d2, reloadPos=$reloadPos)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_F: ERROR: $e\n$st");
        laneFMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneFPass = false;
      }

      // ── Lane G: Missing file load throws PlatformException LOAD_FAILED ──────
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_G: START (missing file LOAD_FAILED)",
      );
      try {
        String? caughtErrorCode;
        final missingPath =
            "${Directory.systemTemp.path}/non_existent_unit_y_$runId.mov";
        try {
          await VGAudioPlaybackService.load(path: missingPath);
        } on PlatformException catch (pe) {
          caughtErrorCode = pe.code;
        }

        laneGPass = caughtErrorCode == "LOAD_FAILED";
        laneGMap = <String, dynamic>{
          "pass": laneGPass,
          "caughtErrorCode": caughtErrorCode,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_G: DONE (pass=$laneGPass, caughtErrorCode=$caughtErrorCode)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_G: ERROR: $e\n$st");
        laneGMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneGPass = false;
      }

      // ── Lane H: Raw invalid native args return INVALID_ARG ──────────────────
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_H: START (raw invalid args INVALID_ARG)",
      );
      try {
        String? emptyPathCode;
        try {
          await _rawChannel.invokeMapMethod<String, dynamic>(
            "audioPlayback_load",
            {"path": ""},
          );
        } on PlatformException catch (pe) {
          emptyPathCode = pe.code;
        }

        String? missingSeekCode;
        try {
          await _rawChannel.invokeMethod<void>(
            "audioPlayback_seekTo",
            <String, dynamic>{},
          );
        } on PlatformException catch (pe) {
          missingSeekCode = pe.code;
        }

        String? negativeSeekCode;
        try {
          await _rawChannel.invokeMethod<void>("audioPlayback_seekTo", {
            "seconds": -1.5,
          });
        } on PlatformException catch (pe) {
          negativeSeekCode = pe.code;
        }

        String? missingVolumeCode;
        try {
          await _rawChannel.invokeMethod<void>(
            "audioPlayback_setVolume",
            <String, dynamic>{},
          );
        } on PlatformException catch (pe) {
          missingVolumeCode = pe.code;
        }

        final emptyPathPass = emptyPathCode == "INVALID_ARG";
        final missingSeekPass = missingSeekCode == "INVALID_ARG";
        final negativeSeekPass = negativeSeekCode == "INVALID_ARG";
        final missingVolumePass = missingVolumeCode == "INVALID_ARG";

        laneHPass =
            emptyPathPass &&
            missingSeekPass &&
            negativeSeekPass &&
            missingVolumePass;
        laneHMap = <String, dynamic>{
          "pass": laneHPass,
          "emptyPathCode": emptyPathCode,
          "missingSeekCode": missingSeekCode,
          "negativeSeekCode": negativeSeekCode,
          "missingVolumeCode": missingVolumeCode,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_H: DONE (pass=$laneHPass, empty=$emptyPathCode, missSeek=$missingSeekCode, negSeek=$negativeSeekCode, missVol=$missingVolumeCode)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_H: ERROR: $e\n$st");
        laneHMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneHPass = false;
      }

      // ── Lane I: Raw numeric out-of-range volume calls clamp & succeed ───────
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I: START (raw volume clamp success)",
      );
      try {
        var clampNegPass = false;
        var clampHighPass = false;

        try {
          await _rawChannel.invokeMethod<void>("audioPlayback_setVolume", {
            "volume": -1.0,
          });
          clampNegPass = true;
        } catch (e) {
          print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I: volume -1.0 threw: $e");
        }

        try {
          await _rawChannel.invokeMethod<void>("audioPlayback_setVolume", {
            "volume": 2.0,
          });
          clampHighPass = true;
        } catch (e) {
          print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I: volume 2.0 threw: $e");
        }

        laneIPass = clampNegPass && clampHighPass;
        laneIMap = <String, dynamic>{
          "pass": laneIPass,
          "clampNegPass": clampNegPass,
          "clampHighPass": clampHighPass,
        };
        print(
          "ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I: DONE (pass=$laneIPass, clampNeg=$clampNegPass, clampHigh=$clampHighPass)",
        );
      } catch (e, st) {
        print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I: ERROR: $e\n$st");
        laneIMap = <String, dynamic>{"pass": false, "error": "$e"};
        laneIPass = false;
      }
    } catch (topLevelE, topLevelSt) {
      print(
        "ANDROID_AUDIO_PLAYBACK_UNIT_Y: TOP_LEVEL_ERROR: $topLevelE\n$topLevelSt",
      );
      topLevelError = "$topLevelE";
    } finally {
      // Always cleanup playback and temp files created by this harness
      try {
        await VGAudioPlaybackService.stop();
      } catch (_) {}

      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
          print(
            "ANDROID_AUDIO_PLAYBACK_UNIT_Y: Cleaned up temporary fixture $tempFilePath",
          );
        } catch (e) {
          print(
            "ANDROID_AUDIO_PLAYBACK_UNIT_Y: Warning deleting temp file: $e",
          );
        }
      }
    }

    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_A_PASS: $laneAPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_B_PASS: $laneBPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_C_PASS: $laneCPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_D_PASS: $laneDPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_E_PASS: $laneEPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_F_PASS: $laneFPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_G_PASS: $laneGPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_H_PASS: $laneHPass");
    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_LANE_I_PASS: $laneIPass");

    final allRequiredPass =
        laneAPass &&
        laneBPass &&
        laneCPass &&
        laneDPass &&
        laneEPass &&
        laneFPass &&
        laneGPass &&
        laneHPass &&
        laneIPass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      "unit": "Phase5UnitY_Phase4UnitG",
      "target": "android_audio_playback_physical",
      "pass": allRequiredPass,
      "lanes": <String, dynamic>{
        "laneA_valid_load": laneAMap,
        "laneB_play_advances": laneBMap,
        "laneC_pause_freezes": laneCMap,
        "laneD_seek_target": laneDMap,
        "laneE_stop_reset": laneEMap,
        "laneF_replace_load": laneFMap,
        "laneG_missing_file_load_failed": laneGMap,
        "laneH_raw_invalid_args": laneHMap,
        "laneI_raw_volume_clamp": laneIMap,
      },
      "error": topLevelError,
    };

    print("ANDROID_AUDIO_PLAYBACK_UNIT_Y_JSON:${jsonEncode(payload)}");
    print(
      allRequiredPass
          ? "ANDROID_AUDIO_PLAYBACK_UNIT_Y_PHYSICAL_PASS"
          : "ANDROID_AUDIO_PLAYBACK_UNIT_Y_PHYSICAL_FAIL",
    );

    if (mounted) {
      setState(() {
        _status = allRequiredPass ? "PASS" : "FAIL";
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(allRequiredPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
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
