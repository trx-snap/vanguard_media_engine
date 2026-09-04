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
    _timeoutTimer = Timer(const Duration(seconds: 180), () {
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q: TIMEOUT (180s exceeded)');
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
    String? readySidecarPath;

    var lane1Pass = false;
    var lane2Pass = false;
    var orderingProbePass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var readySidecarExists = false;
    var readySidecarHasFtyp = false;
    var cleanupDeletedReadySidecar = false;
    var globalHonestyPass = false;

    final Map<String, dynamic> lane1Map = <String, dynamic>{};
    final Map<String, dynamic> lane2Map = <String, dynamic>{};
    final Map<String, dynamic> probeMap = <String, dynamic>{};
    final Map<String, dynamic> lane3Map = <String, dynamic>{};
    final Map<String, dynamic> lane4Map = <String, dynamic>{};
    Map<String, dynamic>? probeReport;

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
      // Lane 2: Valid bounded sidecar via public VGEditorController
      // Short trim window (0.0..1.0) and small canvas (320x180) to keep proof fast.
      // Assert: one status with clipId, state ready, progress 1.0, sidecarPath non-null.
      // Assert: sidecar file exists, length > 0, header bytes contain ASCII "ftyp"
      // within the first 64 bytes.
      // Then getSidecarStatus for same clipId and assert ready/path/progress remain valid.
      // Record that this proves file creation/readiness, not frame ordering.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE2: START');
      final clipLane2 = VGClipDescriptor(
        id: 'unit-q-clip-lane2',
        mediaKind: VGMediaKind.video,
        sourcePath: sourcePath,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 1.0,
        isReversed: true,
      );
      final draftLane2 = VGEditorDraft(
        id: 'draft-unit-q-lane2',
        clips: [clipLane2],
        canvasWidth: 320,
        canvasHeight: 180,
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
          prepStatus.state == VGReverseSidecarState.ready &&
          prepStatus.progress == 1.0 &&
          prepStatus.sidecarPath != null &&
          prepStatus.errorMessage == null;

      if (!prepPass) {
        throw Exception(
          'Lane 2 failed on prepareReverseSidecars: ${_statusToMap(prepStatus)}',
        );
      }

      readySidecarPath = prepStatus.sidecarPath;
      final sidecarFile = File(readySidecarPath!);
      readySidecarExists = await sidecarFile.exists();
      if (!readySidecarExists) {
        throw Exception(
          'Lane 2 failed: ready sidecar file does not exist at $readySidecarPath',
        );
      }

      final sidecarLength = await sidecarFile.length();
      lane2Map['sidecarLength'] = sidecarLength;
      if (sidecarLength <= 0) {
        throw Exception(
          'Lane 2 failed: ready sidecar file is empty (length: $sidecarLength)',
        );
      }

      final raf = await sidecarFile.open();
      try {
        final headerBytes = await raf.read(64);
        final headerAscii = String.fromCharCodes(headerBytes);
        readySidecarHasFtyp = headerAscii.contains('ftyp');
      } finally {
        await raf.close();
      }

      if (!readySidecarHasFtyp) {
        throw Exception(
          'Lane 2 failed: ready sidecar header does not contain ASCII "ftyp" within first 64 bytes',
        );
      }

      final getStatus = await controllerLane2.getSidecarStatus(
        clipId: 'unit-q-clip-lane2',
      );
      lane2Map['getStatus'] = _statusToMap(getStatus);
      allStatusesObserved.add(_statusToMap(getStatus));

      final getPass =
          getStatus.clipId == 'unit-q-clip-lane2' &&
          getStatus.state == VGReverseSidecarState.ready &&
          getStatus.sidecarPath == readySidecarPath &&
          getStatus.progress == 1.0 &&
          getStatus.errorMessage == null;

      if (!getPass) {
        throw Exception(
          'Lane 2 failed on getSidecarStatus: ${_statusToMap(getStatus)}',
        );
      }

      lane2Map['readySidecarExists'] = readySidecarExists;
      lane2Map['readySidecarHasFtyp'] = readySidecarHasFtyp;
      lane2Map['frameOrderingProof'] =
          'proves file creation/readiness, not frame ordering';
      lane2Pass = true;
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE2_PASS: $lane2Pass');

      // ------------------------------------------------------------------------
      // Lane 2b: Diagnostic reverse frame-ordering probe
      // Direct MethodChannel invoke probeReverseSidecarOrdering with Lane 2
      // ready sidecar and source paths, trim 0..1, frameCount 30, fps 30.
      // Assert:
      //   - pass == true
      //   - reverseWins >= 3
      //   - sidecarPtsMonotonic == true
      //   - sidecarSampleCount >= 30
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_PROBE: START');
      final probeResult = await channel.invokeMapMethod<String, dynamic>(
        'probeReverseSidecarOrdering',
        <String, dynamic>{
          'sourcePath': sourcePath,
          'sidecarPath': readySidecarPath,
          'trimStart': 0.0,
          'trimEnd': 1.0,
          'frameCount': 30,
          'fps': 30,
        },
      );
      probeMap['result'] = probeResult;
      probeReport = probeResult;

      if (probeResult == null) {
        throw Exception('Ordering probe failed: returned null');
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_PROBE_REPORT: $probeResult');

      final probePass = probeResult['pass'] == true;
      final reverseWins = (probeResult['reverseWins'] as num?)?.toInt() ?? 0;
      final sidecarPtsMonotonic = probeResult['sidecarPtsMonotonic'] == true;
      final sidecarSampleCount =
          (probeResult['sidecarSampleCount'] as num?)?.toInt() ?? 0;

      if (!probePass) {
        throw Exception(
          'Ordering probe failed: pass is false, reason: ${probeResult['reason']}',
        );
      }
      if (reverseWins < 3) {
        throw Exception('Ordering probe failed: reverseWins=$reverseWins < 3');
      }
      if (!sidecarPtsMonotonic) {
        throw Exception('Ordering probe failed: sidecarPtsMonotonic is false');
      }
      if (sidecarSampleCount < 30) {
        throw Exception(
          'Ordering probe failed: sidecarSampleCount=$sidecarSampleCount < 30',
        );
      }

      orderingProbePass = true;
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_PROBE_PASS: $orderingProbePass');

      // ------------------------------------------------------------------------
      // Lane 3: Direct MethodChannel invalid/missing-source/bounds edge cases
      // Call prepareReverseSidecars with:
      // 1. invalid trim for clip unit-q-invalid-trim -> SIDECAR_INVALID_TRIM_RANGE
      // 2. missing source for clip unit-q-missing-source -> SIDECAR_MISSING_SOURCE_FILE
      // 3. bounds case trim 0..6 (exceeds 5.0s max) -> SIDECAR_TRIM_WINDOW_TOO_LONG
      // Assert each status has state failed, sidecarPath null, progress 0.0.
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
        <String, Object>{
          'clipId': 'unit-q-bounds-too-long',
          'sourcePath': sourcePath,
          'trimStart': 0.0,
          'trimEnd': 6.0,
          'targetWidth': 1280.0,
          'targetHeight': 720.0,
          'sourceHash': 'hash-bounds-too-long',
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

      if (lane3Statuses.length != 3) {
        throw Exception(
          'Lane 3 failed: expected 3 statuses, got ${lane3Statuses.length}',
        );
      }

      final invalidTrimStatus = lane3Statuses[0];
      final missingSourceStatus = lane3Statuses[1];
      final boundsTooLongStatus = lane3Statuses[2];

      final invalidTrimPass =
          invalidTrimStatus['clipId'] == 'unit-q-invalid-trim' &&
          invalidTrimStatus['state'] == 'failed' &&
          (invalidTrimStatus['progress'] as num?)?.toDouble() == 0.0 &&
          invalidTrimStatus['sidecarPath'] == null &&
          invalidTrimStatus['errorMessage'] == 'SIDECAR_INVALID_TRIM_RANGE';

      final missingSourcePass =
          missingSourceStatus['clipId'] == 'unit-q-missing-source' &&
          missingSourceStatus['state'] == 'failed' &&
          (missingSourceStatus['progress'] as num?)?.toDouble() == 0.0 &&
          missingSourceStatus['sidecarPath'] == null &&
          missingSourceStatus['errorMessage'] == 'SIDECAR_MISSING_SOURCE_FILE';

      final boundsTooLongPass =
          boundsTooLongStatus['clipId'] == 'unit-q-bounds-too-long' &&
          boundsTooLongStatus['state'] == 'failed' &&
          (boundsTooLongStatus['progress'] as num?)?.toDouble() == 0.0 &&
          boundsTooLongStatus['sidecarPath'] == null &&
          boundsTooLongStatus['errorMessage'] == 'SIDECAR_TRIM_WINDOW_TOO_LONG';

      if (invalidTrimPass && missingSourcePass && boundsTooLongPass) {
        lane3Pass = true;
      } else {
        throw Exception(
          'Lane 3 failed: invalidTrimPass=$invalidTrimPass ($invalidTrimStatus), '
          'missingSourcePass=$missingSourcePass ($missingSourceStatus), '
          'boundsTooLongPass=$boundsTooLongPass ($boundsTooLongStatus)',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE3_PASS: $lane3Pass');

      // ------------------------------------------------------------------------
      // Lane 4: Cleanup ownership after ready
      // Call cleanupReverseSidecars after lane 2 ready file exists.
      // Assert cleanup returns ok: true.
      // Assert prior ready sidecar path no longer exists.
      // Call getSidecarStatus for ready clip and assert:
      // state idle, progress 0.0, sidecarPath null, errorMessage null.
      // ------------------------------------------------------------------------
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE4: START');
      if (readySidecarPath == null) {
        throw Exception(
          'Lane 4 failed: readySidecarPath was not set by Lane 2',
        );
      }

      final cleanupResult = await channel.invokeMapMethod<String, dynamic>(
        'cleanupReverseSidecars',
      );
      lane4Map['cleanupResult'] = cleanupResult;
      final cleanupOk = cleanupResult?['ok'] == true;
      if (!cleanupOk) {
        throw Exception(
          'Lane 4 failed: cleanupReverseSidecars did not return ok: true ($cleanupResult)',
        );
      }

      final readyFileStillExists = await File(readySidecarPath!).exists();
      cleanupDeletedReadySidecar = !readyFileStillExists;
      lane4Map['cleanupDeletedReadySidecar'] = cleanupDeletedReadySidecar;
      if (!cleanupDeletedReadySidecar) {
        throw Exception(
          'Lane 4 failed: prior ready sidecar path still exists at $readySidecarPath after cleanup',
        );
      }

      final postCleanupStatus = await channel.invokeMapMethod<String, dynamic>(
        'getSidecarStatus',
        {'clipId': 'unit-q-clip-lane2'},
      );
      lane4Map['postCleanupStatus'] = postCleanupStatus;
      if (postCleanupStatus != null) {
        allStatusesObserved.add(
          postCleanupStatus.map((k, v) => MapEntry(k.toString(), v)),
        );
      }

      final postCleanupPass =
          postCleanupStatus != null &&
          postCleanupStatus['clipId'] == 'unit-q-clip-lane2' &&
          postCleanupStatus['state'] == 'idle' &&
          (postCleanupStatus['progress'] as num?)?.toDouble() == 0.0 &&
          postCleanupStatus['sidecarPath'] == null &&
          postCleanupStatus['errorMessage'] == null;

      if (controllerLane2 != null) {
        final ctrlPostCleanupStatus = await controllerLane2!.getSidecarStatus(
          clipId: 'unit-q-clip-lane2',
        );
        lane4Map['controllerPostCleanupStatus'] = _statusToMap(
          ctrlPostCleanupStatus,
        );
        allStatusesObserved.add(_statusToMap(ctrlPostCleanupStatus));
        final ctrlPostCleanupPass =
            ctrlPostCleanupStatus.clipId == 'unit-q-clip-lane2' &&
            ctrlPostCleanupStatus.state == VGReverseSidecarState.idle &&
            ctrlPostCleanupStatus.progress == 0.0 &&
            ctrlPostCleanupStatus.sidecarPath == null &&
            ctrlPostCleanupStatus.errorMessage == null;
        if (!ctrlPostCleanupPass) {
          throw Exception(
            'Lane 4 failed: controller getSidecarStatus is not idle: ${_statusToMap(ctrlPostCleanupStatus)}',
          );
        }
        await controllerLane2!.disposeAsync();
        controllerLane2!.dispose();
        controllerLane2 = null;
      }

      if (postCleanupPass) {
        lane4Pass = true;
      } else {
        throw Exception(
          'Lane 4 failed: post-cleanup status is not idle: $postCleanupStatus',
        );
      }
      print('ANDROID_REVERSE_SIDECAR_UNIT_Q_LANE4_PASS: $lane4Pass');

      // ------------------------------------------------------------------------
      // Global honesty:
      // - At least one ready observed
      // - No SIDECAR_UNSUPPORTED_ANDROID observed
      // - No non-ready status has a sidecarPath
      // - Include JSON booleans readySidecarExists, readySidecarHasFtyp,
      //   cleanupDeletedReadySidecar, reverseOrderingProven=orderingProbePass
      // ------------------------------------------------------------------------
      var readyObservedCount = 0;
      var unsupportedAndroidCount = 0;
      var nonReadyWithPathCount = 0;

      for (final s in allStatusesObserved) {
        final state = s['state']?.toString();
        final sidecarPath = s['sidecarPath'];
        final errorMessage = s['errorMessage']?.toString();

        if (state == 'ready') {
          readyObservedCount++;
        }
        if (errorMessage == 'SIDECAR_UNSUPPORTED_ANDROID') {
          unsupportedAndroidCount++;
        }
        if (state != 'ready' && sidecarPath != null) {
          nonReadyWithPathCount++;
        }
      }

      globalHonestyPass =
          readyObservedCount >= 1 &&
          unsupportedAndroidCount == 0 &&
          nonReadyWithPathCount == 0 &&
          readySidecarExists &&
          readySidecarHasFtyp &&
          cleanupDeletedReadySidecar &&
          orderingProbePass;

      if (!globalHonestyPass) {
        throw Exception(
          'Global honesty failed: readyObservedCount=$readyObservedCount, '
          'unsupportedAndroidCount=$unsupportedAndroidCount, '
          'nonReadyWithPathCount=$nonReadyWithPathCount, '
          'readySidecarExists=$readySidecarExists, '
          'readySidecarHasFtyp=$readySidecarHasFtyp, '
          'cleanupDeletedReadySidecar=$cleanupDeletedReadySidecar, '
          'orderingProbePass=$orderingProbePass',
        );
      }
      print(
        'ANDROID_REVERSE_SIDECAR_UNIT_Q_GLOBAL_HONESTY_PASS: $globalHonestyPass',
      );
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
      if (readySidecarPath != null) {
        try {
          final f = File(readySidecarPath!);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }

    final allPass =
        lane1Pass &&
        lane2Pass &&
        orderingProbePass &&
        lane3Pass &&
        lane4Pass &&
        globalHonestyPass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      'unit': 'Phase5UnitQ',
      'target': 'android_reverse_sidecar_unit_q_physical',
      'pass': allPass,
      'lanes': <String, dynamic>{
        'lane1_empty_prepare': lane1Map,
        'lane2_valid_bounded_sidecar': lane2Map,
        'lane2b_reverse_ordering_probe': probeMap,
        'lane3_invalid_and_missing_source': lane3Map,
        'lane4_cleanup_ownership': lane4Map,
      },
      'observedStatusCount': allStatusesObserved.length,
      'readySidecarExists': readySidecarExists,
      'readySidecarHasFtyp': readySidecarHasFtyp,
      'cleanupDeletedReadySidecar': cleanupDeletedReadySidecar,
      'reverseOrderingProven': orderingProbePass,
      'probeReport': probeReport,
      'globalHonestyPass': globalHonestyPass,
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
