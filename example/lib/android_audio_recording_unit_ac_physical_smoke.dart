// android_audio_recording_unit_ac_physical_smoke.dart
// Vanguard Media Engine — Phase 4-Unit H / Phase 5-Unit AC
// Android Audio Recording Handler Bridge Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioRecordingUnitAcPhysicalSmokeApp());
}

class AndroidAudioRecordingUnitAcPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioRecordingUnitAcPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioRecordingUnitAcPhysicalSmokeApp> createState() =>
      _AndroidAudioRecordingUnitAcPhysicalSmokeAppState();
}

class _AndroidAudioRecordingUnitAcPhysicalSmokeAppState
    extends State<AndroidAudioRecordingUnitAcPhysicalSmokeApp> {
  String _status =
      'Initializing Android Audio Recording Physical Smoke (Unit AC)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print('ANDROID_AUDIO_RECORDING_UNIT_AC: TIMEOUT (120s exceeded)');
      print('ANDROID_AUDIO_RECORDING_UNIT_AC_PHYSICAL_FAIL');
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
    print('ANDROID_AUDIO_RECORDING_UNIT_AC: START');
    final runId = 'unit_ac_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    final trackedFiles = <File>[];

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

    Map<String, dynamic> lane1Map = <String, dynamic>{};
    Map<String, dynamic> lane2Map = <String, dynamic>{};
    Map<String, dynamic> lane3Map = <String, dynamic>{};
    Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic> lane5Map = <String, dynamic>{};
    Map<String, dynamic> lane6Map = <String, dynamic>{};
    Map<String, dynamic> lane7Map = <String, dynamic>{};
    Map<String, dynamic> lane8Map = <String, dynamic>{};

    VGEditorController? controller;
    String? topLevelError;

    try {
      // ── Stage minimal fixture clip for VGEditorDraft ────────────────────────
      final stagedClipPath = '${tempDir.path}/unit_ac_fixture_$runId.mov';
      final stagedClipFile = File(stagedClipPath);
      trackedFiles.add(stagedClipFile);

      print('ANDROID_AUDIO_RECORDING_UNIT_AC: Staging fixture clip...');
      final byteData = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      await stagedClipFile.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );

      final clip = VGClipDescriptor(
        id: 'unit-ac-clip-$runId',
        mediaKind: VGMediaKind.video,
        sourcePath: stagedClipPath,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
      );
      final draft = VGEditorDraft(
        id: 'draft-unit-ac-$runId',
        clips: [clip],
        canvasWidth: 1080,
        canvasHeight: 1920,
        fps: 30,
      );

      controller = VGEditorController(initialDraft: draft);
      print('ANDROID_AUDIO_RECORDING_UNIT_AC: VGEditorController ready');

      // ── Lane 1: Permission lane ─────────────────────────────────────────────
      print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: START (permission probe)');
      final permProbePath = '${tempDir.path}/unit_ac_perm_probe_$runId.m4a';
      final permProbeFile = File(permProbePath);
      trackedFiles.add(permProbeFile);

      try {
        final probeStart = await controller.startAudioRecording(permProbePath);
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: Permission probe recording briefly, waiting 800ms before stop...',
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final probeStop = await controller.stopAudioRecording();
        lane1Pass = true;
        lane1Map = <String, dynamic>{
          'pass': true,
          'hasPermission': true,
          'probeStartPTS': probeStart.startPTS,
          'probeDuration': probeStop.durationSeconds,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: DONE (pass=true, RECORD_AUDIO granted)',
        );
      } on PlatformException catch (pe) {
        if (pe.code == 'MISSING_PERMISSION') {
          print(
            'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: FATAL: RECORD_AUDIO permission missing! '
            'The test runner must execute with android-physical-smoke-grant-record-audio.',
          );
        }
        lane1Pass = false;
        lane1Map = <String, dynamic>{
          'pass': false,
          'errorCode': pe.code,
          'errorMessage': pe.message,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: ERROR: code=${pe.code}, msg=${pe.message}',
        );
      } catch (e, st) {
        lane1Pass = false;
        lane1Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_1: ERROR: $e\n$st');
      }

      // ── Lane 2: Happy path ──────────────────────────────────────────────────
      print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_2: START (happy path)');
      final happyPath = '${tempDir.path}/unit_ac_happy_$runId.m4a';
      final happyFile = File(happyPath);
      trackedFiles.add(happyFile);

      VGAudioRecordingStartResult? happyStart;
      VGAudioRecordingStopResult? happyStop;
      int happyFileSize = 0;

      try {
        happyStart = await controller.startAudioRecording(happyPath);
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_2: Recording active, waiting 1500ms...',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        happyStop = await controller.stopAudioRecording();

        final exists = happyFile.existsSync();
        happyFileSize = exists ? await happyFile.length() : 0;

        final fileOk = exists && happyFileSize > 3000;
        final startPtsOk = happyStart.startPTS == 0.0;
        final stopPtsOk = happyStop.startPTS == 0.0;
        final durationOk = happyStop.durationSeconds >= 1.0;
        final sessionRestoredOk = happyStop.transitionStatus.sessionRestored;
        final previewRecoveredOk = happyStop.transitionStatus.previewRecovered;
        final activeInputOk =
            happyStart.audioRoute != null &&
            happyStart.audioRoute!.activeInputType.isNotEmpty &&
            happyStart.audioRoute!.activeInputType != 'none';

        lane2Pass =
            fileOk &&
            startPtsOk &&
            stopPtsOk &&
            durationOk &&
            sessionRestoredOk &&
            previewRecoveredOk &&
            activeInputOk;

        lane2Map = <String, dynamic>{
          'pass': lane2Pass,
          'filePath': happyStop.filePath,
          'fileSizeBytes': happyFileSize,
          'startPTS': happyStart.startPTS,
          'stopStartPTS': happyStop.startPTS,
          'durationSeconds': happyStop.durationSeconds,
          'sessionRestored': sessionRestoredOk,
          'previewRecovered': previewRecoveredOk,
          'activeInputType': happyStart.audioRoute?.activeInputType,
          'hasHeadphoneOutput': happyStart.isHeadphonesConnected,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_2: DONE (pass=$lane2Pass, size=$happyFileSize, duration=${happyStop.durationSeconds}s, input=${happyStart.audioRoute?.activeInputType})',
        );
      } catch (e, st) {
        lane2Pass = false;
        lane2Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_2: ERROR: $e\n$st');
      }

      // ── Lane 3: Playback/container lane ─────────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_3: START (playback/container probe)',
      );
      try {
        final loadedDuration = await VGAudioPlaybackService.load(
          path: happyPath,
        );
        final durationOk = loadedDuration > 0.0;

        await VGAudioPlaybackService.play();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final pos = await VGAudioPlaybackService.getPosition();
        await VGAudioPlaybackService.stop();

        lane3Pass = durationOk && pos >= 0.0;
        lane3Map = <String, dynamic>{
          'pass': lane3Pass,
          'loadedDurationSeconds': loadedDuration,
          'playbackPositionSeconds': pos,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_3: DONE (pass=$lane3Pass, loadedDuration=$loadedDuration, pos=$pos)',
        );
      } catch (e, st) {
        lane3Pass = false;
        lane3Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_3: ERROR: $e\n$st');
      }

      // ── Lane 4: Double-start lane ───────────────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_4: START (ALREADY_RECORDING rejection)',
      );
      final doubleStartPath = '${tempDir.path}/unit_ac_double_start_$runId.m4a';
      final doubleStartFile = File(doubleStartPath);
      trackedFiles.add(doubleStartFile);

      final secondPath = '${tempDir.path}/unit_ac_second_$runId.m4a';
      final secondFile = File(secondPath);
      trackedFiles.add(secondFile);

      try {
        await controller.startAudioRecording(doubleStartPath);

        var caughtAlreadyRecording = false;
        try {
          await controller.startAudioRecording(secondPath);
        } on PlatformException catch (pe) {
          if (pe.code == 'ALREADY_RECORDING') {
            caughtAlreadyRecording = true;
          } else {
            print(
              'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_4: Unexpected error code: ${pe.code}',
            );
          }
        }

        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_4: Active recording delay, waiting 1000ms before stop...',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1000));

        final stopRes = await controller.stopAudioRecording();
        final fileProduced =
            doubleStartFile.existsSync() &&
            (await doubleStartFile.length()) > 0;

        lane4Pass = caughtAlreadyRecording && fileProduced;
        lane4Map = <String, dynamic>{
          'pass': lane4Pass,
          'caughtAlreadyRecording': caughtAlreadyRecording,
          'fileProduced': fileProduced,
          'durationSeconds': stopRes.durationSeconds,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_4: DONE (pass=$lane4Pass, caughtAlreadyRecording=$caughtAlreadyRecording, fileProduced=$fileProduced)',
        );
      } catch (e, st) {
        lane4Pass = false;
        lane4Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_4: ERROR: $e\n$st');
      }

      // ── Lane 5: Idle-stop lane ──────────────────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_5: START (NOT_RECORDING rejection)',
      );
      try {
        var caughtNotRecording = false;
        try {
          await controller.stopAudioRecording();
        } on PlatformException catch (pe) {
          if (pe.code == 'NOT_RECORDING') {
            caughtNotRecording = true;
          } else {
            print(
              'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_5: Unexpected error code: ${pe.code}',
            );
          }
        }

        lane5Pass = caughtNotRecording;
        lane5Map = <String, dynamic>{
          'pass': lane5Pass,
          'caughtNotRecording': caughtNotRecording,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_5: DONE (pass=$lane5Pass, caughtNotRecording=$caughtNotRecording)',
        );
      } catch (e, st) {
        lane5Pass = false;
        lane5Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_5: ERROR: $e\n$st');
      }

      // ── Lane 6: Invalid-path lane ───────────────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_6: START (INVALID_ARG rejection)',
      );
      try {
        var caughtInvalidArg = false;
        try {
          await controller.startAudioRecording('');
        } on PlatformException catch (pe) {
          if (pe.code == 'INVALID_ARG') {
            caughtInvalidArg = true;
          } else {
            print(
              'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_6: Unexpected error code: ${pe.code}',
            );
          }
        }

        lane6Pass = caughtInvalidArg;
        lane6Map = <String, dynamic>{
          'pass': lane6Pass,
          'caughtInvalidArg': caughtInvalidArg,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_6: DONE (pass=$lane6Pass, caughtInvalidArg=$caughtInvalidArg)',
        );
      } catch (e, st) {
        lane6Pass = false;
        lane6Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_6: ERROR: $e\n$st');
      }

      // ── Lane 7: Existing-file collision lane ────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_7: START (RECORDING_FAILED collision)',
      );
      final collisionPath = '${tempDir.path}/unit_ac_collision_$runId.m4a';
      final collisionFile = File(collisionPath);
      trackedFiles.add(collisionFile);

      const sentinelContent = 'SENTINEL_DATA_DO_NOT_OVERWRITE_OR_DELETE';

      try {
        await collisionFile.writeAsString(sentinelContent, flush: true);

        var caughtRecordingFailed = false;
        try {
          await controller.startAudioRecording(collisionPath);
        } on PlatformException catch (pe) {
          if (pe.code == 'RECORDING_FAILED') {
            caughtRecordingFailed = true;
          } else {
            print(
              'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_7: Unexpected error code: ${pe.code}',
            );
          }
        }

        final sentinelAfter = collisionFile.existsSync()
            ? await collisionFile.readAsString()
            : null;
        final sentinelIntact = sentinelAfter == sentinelContent;

        lane7Pass = caughtRecordingFailed && sentinelIntact;
        lane7Map = <String, dynamic>{
          'pass': lane7Pass,
          'caughtRecordingFailed': caughtRecordingFailed,
          'sentinelIntact': sentinelIntact,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_7: DONE (pass=$lane7Pass, caughtRecordingFailed=$caughtRecordingFailed, sentinelIntact=$sentinelIntact)',
        );
      } catch (e, st) {
        lane7Pass = false;
        lane7Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_7: ERROR: $e\n$st');
      }

      // ── Lane 8: Consecutive-take lane ───────────────────────────────────────
      print(
        'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_8: START (consecutive takes)',
      );
      final take1Path = '${tempDir.path}/unit_ac_take1_$runId.m4a';
      final take1File = File(take1Path);
      trackedFiles.add(take1File);

      final take2Path = '${tempDir.path}/unit_ac_take2_$runId.m4a';
      final take2File = File(take2Path);
      trackedFiles.add(take2File);

      try {
        // Take 1
        await controller.startAudioRecording(take1Path);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final stop1 = await controller.stopAudioRecording();

        // Take 2
        await controller.startAudioRecording(take2Path);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final stop2 = await controller.stopAudioRecording();

        final exists1 = take1File.existsSync();
        final exists2 = take2File.existsSync();
        final size1 = exists1 ? await take1File.length() : 0;
        final size2 = exists2 ? await take2File.length() : 0;

        final distinctPaths =
            take1Path != take2Path && stop1.filePath != stop2.filePath;
        final bothFilesOk = exists1 && exists2 && size1 > 3000 && size2 > 3000;
        final bothDurationsOk =
            stop1.durationSeconds > 0.0 && stop2.durationSeconds > 0.0;

        lane8Pass = distinctPaths && bothFilesOk && bothDurationsOk;
        lane8Map = <String, dynamic>{
          'pass': lane8Pass,
          'take1Path': stop1.filePath,
          'take1SizeBytes': size1,
          'take1DurationSeconds': stop1.durationSeconds,
          'take2Path': stop2.filePath,
          'take2SizeBytes': size2,
          'take2DurationSeconds': stop2.durationSeconds,
          'distinctPaths': distinctPaths,
        };
        print(
          'ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_8: DONE (pass=$lane8Pass, take1Size=$size1, take2Size=$size2)',
        );
      } catch (e, st) {
        lane8Pass = false;
        lane8Map = <String, dynamic>{'pass': false, 'error': '$e'};
        print('ANDROID_AUDIO_RECORDING_UNIT_AC_LANE_8: ERROR: $e\n$st');
      }
    } catch (e, st) {
      topLevelError = '$e';
      print('ANDROID_AUDIO_RECORDING_UNIT_AC: TOP_LEVEL_ERROR: $e\n$st');
    } finally {
      try {
        controller?.dispose();
      } catch (_) {}

      // Guaranteed cleanup of tracked files
      for (final file in trackedFiles) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    }

    final allPassed =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        lane5Pass &&
        lane6Pass &&
        lane7Pass &&
        lane8Pass &&
        topLevelError == null;

    final summary = <String, dynamic>{
      'runId': runId,
      'allPassed': allPassed,
      'topLevelError': topLevelError,
      'lane1_permission': lane1Map,
      'lane2_happyPath': lane2Map,
      'lane3_playbackContainer': lane3Map,
      'lane4_doubleStart': lane4Map,
      'lane5_idleStop': lane5Map,
      'lane6_invalidPath': lane6Map,
      'lane7_collision': lane7Map,
      'lane8_consecutiveTakes': lane8Map,
    };

    final encoder = const JsonEncoder.withIndent('  ');
    print('ANDROID_AUDIO_RECORDING_UNIT_AC_SUMMARY:');
    print(encoder.convert(summary));

    if (mounted) {
      setState(() {
        _status = allPassed
            ? 'ANDROID_AUDIO_RECORDING_UNIT_AC_PHYSICAL_PASS'
            : 'ANDROID_AUDIO_RECORDING_UNIT_AC_PHYSICAL_FAIL';
      });
    }

    if (allPassed) {
      print('ANDROID_AUDIO_RECORDING_UNIT_AC_PHYSICAL_PASS');
      exit(0);
    } else {
      print('ANDROID_AUDIO_RECORDING_UNIT_AC_PHYSICAL_FAIL');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
