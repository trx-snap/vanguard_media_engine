// android_reverse_sidecar_unit_q_physical_smoke.dart
// Vanguard Media Engine - Phase 5-Unit Q / Phase 7.20
// Android Reverse Playback Sidecar Lifecycle Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidReverseSidecarUnitQPhysicalSmokeApp());
}

class AndroidReverseSidecarUnitQPhysicalSmokeApp extends StatefulWidget {
  const AndroidReverseSidecarUnitQPhysicalSmokeApp({super.key});

  @override
  State<AndroidReverseSidecarUnitQPhysicalSmokeApp> createState() =>
      _AndroidReverseSidecarUnitQPhysicalSmokeAppState();
}

class _AndroidReverseSidecarUnitQPhysicalSmokeAppState
    extends State<AndroidReverseSidecarUnitQPhysicalSmokeApp> {
  String _status =
      'Initializing Android Reverse Sidecar Unit Q Physical Smoke...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q: TIMEOUT (60s exceeded)');
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_PHYSICAL_FAIL');
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

  Map<String, dynamic> _statusToMap(VGReverseSidecarStatus s) => {
    'clipId': s.clipId,
    'state': s.state.name,
    'sidecarPath': s.sidecarPath,
    'errorMessage': s.errorMessage,
    'progress': s.progress,
  };

  Future<void> _runSmoke() async {
    print('ANDROID_REVERSE_SIDECAR_UNIT_Q: START');
    final runId = 'unit_q_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? fixtureFile;
    VGEditorController? controllerLane2;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var noReadyPass = false;

    final Map<String, dynamic> lane1Map = <String, dynamic>{};
    final Map<String, dynamic> lane2Map = <String, dynamic>{};
    final Map<String, dynamic> lane3Map = <String, dynamic>{};
    final Map<String, dynamic> lane4Map = <String, dynamic>{};

    final List<Map<String, dynamic>> allStatusesObserved = [];

    String? topLevelError;

    const channel = MethodChannel('vanguard_media_engine');

    try {
      // 0. Copy assets/manual_test_clips/clip_B.mov from rootBundle to temp file
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q: Copying clip_B.mov to temp...');
      final clipByteData = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final rawBytes = clipByteData.buffer.asUint8List(
        clipByteData.offsetInBytes,
        clipByteData.lengthInBytes,
      );

      fixtureFile = File('${tempDir.path}/${runId}_clip_B.mov');
      await fixtureFile.writeAsBytes(rawBytes, flush: true);
      final sourcePath = fixtureFile.path;
      print(
        'ANDROID_REVERSE_SIDECAR_UNIT_Q: Source fixture ready at $sourcePath (${rawBytes.length} bytes)',
      );

      // ------------------------------------------------------------------------
      // Lane 1: Direct MethodChannel empty prepare call
      // Proves native route handles empty list: invoke prepareReverseSidecars
      // with {clips: []} and assert result contains empty clips.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE1: START');
      final lane1Result = await channel.invokeMapMethod<String, dynamic>(
        'prepareReverseSidecars',
        {'clips': <Map<String, dynamic>>[]},
      );
      lane1Map['result'] = lane1Result;
      final lane1Clips = lane1Result?['clips'] as List?;
      if (lane1Result != null && lane1Clips != null && lane1Clips.isEmpty) {
        lane1Pass = true;
      } else {
        throw Exception('Lane 1 failed: unexpected result $lane1Result');
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE1_PASS: $lane1Pass');

      // ------------------------------------------------------------------------
      // Lane 2: Public VGEditorController with one reversed clip using readable fixture
      // Call prepareReverseSidecars directly, assert exactly one status:
      // clipId matches, state failed, errorMessage SIDECAR_UNSUPPORTED_ANDROID,
      // progress 0.0, sidecarPath null. Then call getSidecarStatus and assert
      // same failed unsupported status. Dispose controller.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE2: START');
      final clipLane2 = VGClipDescriptor(
        id: 'unit-q-clip-lane2',
        mediaKind: VGMediaKind.video,
        sourcePath: sourcePath,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        isReversed: true,
      );
      final draftLane2 = VGEditorDraft(
        id: 'draft-unit-q-lane2',
        clips: [clipLane2],
        canvasWidth: 1280,
        canvasHeight: 720,
        fps: 30,
      );
      controllerLane2 = VGEditorController(initialDraft: draftLane2);

      final lane2PrepareStatuses = await controllerLane2
          .prepareReverseSidecars();
      if (lane2PrepareStatuses.length != 1) {
        throw Exception(
          'Lane 2 failed: expected 1 status from prepareReverseSidecars, got ${lane2PrepareStatuses.length}',
        );
      }
      final prepStatus = lane2PrepareStatuses.first;
      lane2Map['prepareStatus'] = _statusToMap(prepStatus);
      allStatusesObserved.add(_statusToMap(prepStatus));

      final prepPass =
          prepStatus.clipId == 'unit-q-clip-lane2' &&
          prepStatus.state == VGReverseSidecarState.failed &&
          prepStatus.errorMessage == 'SIDECAR_UNSUPPORTED_ANDROID' &&
          prepStatus.progress == 0.0 &&
          prepStatus.sidecarPath == null;

      final getStatus = await controllerLane2.getSidecarStatus(
        clipId: 'unit-q-clip-lane2',
      );
      lane2Map['getStatus'] = _statusToMap(getStatus);
      allStatusesObserved.add(_statusToMap(getStatus));

      final getPass =
          getStatus.clipId == 'unit-q-clip-lane2' &&
          getStatus.state == VGReverseSidecarState.failed &&
          getStatus.errorMessage == 'SIDECAR_UNSUPPORTED_ANDROID' &&
          getStatus.progress == 0.0 &&
          getStatus.sidecarPath == null;

      await controllerLane2.disposeAsync();
      controllerLane2.dispose();
      controllerLane2 = null;

      if (prepPass && getPass) {
        lane2Pass = true;
      } else {
        throw Exception(
          'Lane 2 failed: prepPass=$prepPass, getPass=$getPass, prepStatus=${_statusToMap(prepStatus)}, getStatus=${_statusToMap(getStatus)}',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE2_PASS: $lane2Pass');

      // ------------------------------------------------------------------------
      // Lane 3: Direct MethodChannel invalid/missing-source edge cases
      // Call prepareReverseSidecars with invalid trim for clip unit-q-invalid-trim
      // and missing source for clip unit-q-missing-source. Assert both statuses
      // state failed, progress 0.0, sidecarPath null, errors
      // SIDECAR_INVALID_TRIM_RANGE and SIDECAR_MISSING_SOURCE_FILE respectively.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE3: START');
      final lane3ClipsPayload = [
        <String, Object>{
          'clipId': 'unit-q-invalid-trim',
          'sourcePath': sourcePath,
          'trimStart': 5.0,
          'trimEnd': 2.0,
          'targetWidth': 1280.0,
          'targetHeight': 720.0,
          'sourceHash': 'hash-invalid-trim',
        },
        <String, Object>{
          'clipId': 'unit-q-missing-source',
          'sourcePath': '/nonexistent/path/for/unit_q_missing_source.mov',
          'trimStart': 0.0,
          'trimEnd': 3.0,
          'targetWidth': 1280.0,
          'targetHeight': 720.0,
          'sourceHash': 'hash-missing-source',
        },
      ];

      final lane3Result = await channel.invokeMapMethod<String, dynamic>(
        'prepareReverseSidecars',
        {'clips': lane3ClipsPayload},
      );
      lane3Map['result'] = lane3Result;
      final lane3Statuses =
          (lane3Result?['clips'] as List?)
              ?.whereType<Map<Object?, Object?>>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList() ??
          [];

      for (final s in lane3Statuses) {
        allStatusesObserved.add(s);
      }

      if (lane3Statuses.length != 2) {
        throw Exception(
          'Lane 3 failed: expected 2 statuses, got ${lane3Statuses.length}',
        );
      }

      final invalidTrimStatus = lane3Statuses[0];
      final missingSourceStatus = lane3Statuses[1];

      final invalidTrimPass =
          invalidTrimStatus['clipId'] == 'unit-q-invalid-trim' &&
          invalidTrimStatus['state'] == 'failed' &&
          invalidTrimStatus['progress'] == 0.0 &&
          invalidTrimStatus['sidecarPath'] == null &&
          invalidTrimStatus['errorMessage'] == 'SIDECAR_INVALID_TRIM_RANGE';

      final missingSourcePass =
          missingSourceStatus['clipId'] == 'unit-q-missing-source' &&
          missingSourceStatus['state'] == 'failed' &&
          missingSourceStatus['progress'] == 0.0 &&
          missingSourceStatus['sidecarPath'] == null &&
          missingSourceStatus['errorMessage'] == 'SIDECAR_MISSING_SOURCE_FILE';

      if (invalidTrimPass && missingSourcePass) {
        lane3Pass = true;
      } else {
        throw Exception(
          'Lane 3 failed: invalidTrimPass=$invalidTrimPass ($invalidTrimStatus), missingSourcePass=$missingSourcePass ($missingSourceStatus)',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE3_PASS: $lane3Pass');

      // ------------------------------------------------------------------------
      // Lane 4: Cleanup ownership
      // Direct MethodChannel cleanup proof by first preparing a missing-source
      // record, call cleanupReverseSidecars, then getSidecarStatus for that clip
      // and assert state idle/progress 0.0.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE4: START');
      // Prepare a record for unit-q-cleanup-probe
      final cleanupPrepResult = await channel.invokeMapMethod<String, dynamic>(
        'prepareReverseSidecars',
        {
          'clips': [
            <String, Object>{
              'clipId': 'unit-q-cleanup-probe',
              'sourcePath': '/nonexistent/path/for/unit_q_cleanup_probe.mov',
              'trimStart': 0.0,
              'trimEnd': 2.0,
              'targetWidth': 1280.0,
              'targetHeight': 720.0,
              'sourceHash': 'hash-cleanup-probe',
            },
          ],
        },
      );
      final preCleanupStatus = await channel.invokeMapMethod<String, dynamic>(
        'getSidecarStatus',
        {'clipId': 'unit-q-cleanup-probe'},
      );
      lane4Map['preCleanupStatus'] = preCleanupStatus;
      if (preCleanupStatus != null) {
        allStatusesObserved.add(
          preCleanupStatus.map((k, v) => MapEntry(k.toString(), v)),
        );
      }

      final preCleanupValid =
          preCleanupStatus != null &&
          preCleanupStatus['clipId'] == 'unit-q-cleanup-probe' &&
          preCleanupStatus['state'] == 'failed';

      if (!preCleanupValid) {
        throw Exception(
          'Lane 4 failed: pre-cleanup record not established: $preCleanupStatus (prepare was $cleanupPrepResult)',
        );
      }

      // Call cleanup
      final cleanupResult = await channel.invokeMapMethod<String, dynamic>(
        'cleanupReverseSidecars',
      );
      lane4Map['cleanupResult'] = cleanupResult;

      // Query status post-cleanup
      final postCleanupStatus = await channel.invokeMapMethod<String, dynamic>(
        'getSidecarStatus',
        {'clipId': 'unit-q-cleanup-probe'},
      );
      lane4Map['postCleanupStatus'] = postCleanupStatus;
      if (postCleanupStatus != null) {
        allStatusesObserved.add(
          postCleanupStatus.map((k, v) => MapEntry(k.toString(), v)),
        );
      }

      final postCleanupPass =
          postCleanupStatus != null &&
          postCleanupStatus['clipId'] == 'unit-q-cleanup-probe' &&
          postCleanupStatus['state'] == 'idle' &&
          postCleanupStatus['progress'] == 0.0 &&
          postCleanupStatus['sidecarPath'] == null &&
          postCleanupStatus['errorMessage'] == null;

      if (postCleanupPass) {
        lane4Pass = true;
      } else {
        throw Exception(
          'Lane 4 failed: post-cleanup status is not idle: $postCleanupStatus',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE4_PASS: $lane4Pass');

      // ------------------------------------------------------------------------
      // Global invariant across all returned statuses:
      // No status has state ready; no sidecarPath is non-null; prepare does not
      // create sidecar output files.
      // ------------------------------------------------------------------------
      var invariantViolations = 0;
      for (final s in allStatusesObserved) {
        final state = s['state']?.toString();
        final sidecarPath = s['sidecarPath'];
        if (state == 'ready' || sidecarPath != null) {
          invariantViolations++;
        }
      }
      noReadyPass =
          (invariantViolations == 0 && allStatusesObserved.isNotEmpty);
      if (!noReadyPass) {
        throw Exception(
          'Global invariant failed: invariantViolations=$invariantViolations, total observed=${allStatusesObserved.length}',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_NO_READY_PASS: $noReadyPass');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q ERROR: $topLevelError');
    } finally {
      if (controllerLane2 != null) {
        try {
          await controllerLane2.disposeAsync();
          controllerLane2.dispose();
        } catch (_) {}
      }
      if (fixtureFile != null) {
        try {
          if (await fixtureFile.exists()) {
            await fixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        noReadyPass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitQ',
      'target': 'android_reverse_sidecar_unit_q_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_empty_prepare': lane1Map,
        'lane2_public_controller_unsupported': lane2Map,
        'lane3_invalid_and_missing_source': lane3Map,
        'lane4_cleanup_ownership': lane4Map,
      },
      'observedStatusCount': allStatusesObserved.length,
      'noReadyPass': noReadyPass,
      'error': topLevelError,
    };

    print('ANDROID_REVERSE_SIDECAR_UNIT_Q_JSON:${jsonEncode(payload)}');
    print(
      allPass
          ? 'ANDROID_REVERSE_SIDECAR_UNIT_Q_PHYSICAL_PASS'
          : 'ANDROID_REVERSE_SIDECAR_UNIT_Q_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(allPass ? 0 : 1);
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
