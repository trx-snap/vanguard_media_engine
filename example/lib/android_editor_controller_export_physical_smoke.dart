// android_editor_controller_export_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit K
// Android public VGEditorController export pipeline and preflight readiness physical smoke proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

bool _isValidEmptyRoiSidecar(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return false;
    final sidecar = VGROISidecar.fromJson(decoded);
    return sidecar.version == 1 &&
        sidecar.sourceType == 'export' &&
        sidecar.platform == 'android' &&
        sidecar.coordinateSpace == 'export_output_normalized' &&
        sidecar.recordingSessionId == 'android-empty-export' &&
        sidecar.coverage.coveragePercent == 0.0 &&
        sidecar.coverage.missingIntervals.isEmpty &&
        sidecar.samples.isEmpty &&
        sidecar.finalized == true;
  } catch (_) {
    return false;
  }
}

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf('/');
  final lastDot = videoPath.lastIndexOf('.');
  if (lastDot <= lastSeparator) {
    return '$videoPath.roi.json';
  }
  return '${videoPath.substring(0, lastDot)}.roi.json';
}

void main() {
  runApp(const AndroidEditorControllerExportPhysicalSmokeApp());
}

class AndroidEditorControllerExportPhysicalSmokeApp extends StatefulWidget {
  const AndroidEditorControllerExportPhysicalSmokeApp({super.key});

  @override
  State<AndroidEditorControllerExportPhysicalSmokeApp> createState() =>
      _AndroidEditorControllerExportPhysicalSmokeAppState();
}

class _AndroidEditorControllerExportPhysicalSmokeAppState
    extends State<AndroidEditorControllerExportPhysicalSmokeApp> {
  String _status =
      'Initializing Android VGEditorController export physical smoke…';
  VGEditorValue? _editorValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_EDITOR_CONTROLLER_EXPORT_PHYSICAL_SMOKE: START');
    await Future<void>.delayed(const Duration(seconds: 1));

    final runId = 'unit_k_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? tempSourceFile;
    File? tempOutputFile;
    File? tempSidecarFile;
    String? tempOutPath;
    String? expectedSidecarPath;

    VGEditorController? cleanupController;
    StreamSubscription<double>? ptsSubscription;
    final List<double> ptsValues = <double>[];

    var sourcePrepared = false;
    var readinessPass = false;
    var initPass = false;
    var playbackPass = false;
    var exportPass = false;
    var resultPass = false;
    var sidecarPass = false;
    var inspectPass = false;
    var disposePass = false;
    var cleanupPass = false;

    int? textureId;
    int? renderWidth;
    int? renderHeight;
    double? firstPositivePts;
    VGEditorExportResult? exportResult;
    MediaInfo? outMediaInfo;
    String? errorMessage;

    try {
      // ── Step 1: Prepare Source Media ──────────────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_SOURCE_PREPARE: START');
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      tempSourceFile = File('${tempDir.path}/${runId}_source_clip_B.mov');
      final rawBytes = clipBytes.buffer.asUint8List(
        clipBytes.offsetInBytes,
        clipBytes.lengthInBytes,
      );
      await tempSourceFile.writeAsBytes(
        Uint8List.fromList(rawBytes),
        flush: true,
      );

      final sourceInfo = await VanguardMediaPreparer.inspectMedia(
        tempSourceFile.path,
      );
      sourcePrepared =
          sourceInfo != null && sourceInfo.hasVideo && sourceInfo.hasAudio;

      if (!sourcePrepared) {
        throw Exception(
          'Source preparation failed: sourceInfo=$sourceInfo, '
          'hasVideo=${sourceInfo?.hasVideo}, hasAudio=${sourceInfo?.hasAudio}',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_SOURCE_PREPARE: DONE (${rawBytes.length} bytes, duration=${sourceInfo.durationSeconds}s)',
      );

      // ── Step 2: Build Draft & Request, Preflight with Evaluator ───────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_READINESS: START');
      tempOutPath = '${tempDir.path}/${runId}_exported.mp4';
      tempOutputFile = File(tempOutPath);
      expectedSidecarPath = sidecarPathForVideoPath(tempOutPath);
      tempSidecarFile = File(expectedSidecarPath);

      final clip = VGClipDescriptor(
        id: 'unit_k_clip_1',
        mediaKind: VGMediaKind.video,
        sourcePath: tempSourceFile.path,
        durationSeconds: 5.5,
        trimStartSeconds: 0.0,
        trimEndSeconds: 2.5,
        startTimeSeconds: 0.0,
      );

      final draft = VGEditorDraft(
        id: 'unit_k_draft',
        clips: [clip],
        canvasWidth: 720,
        canvasHeight: 1280,
        fps: 30,
        canvas: VGCanvasDescriptor(
          width: 720,
          height: 1280,
          contentMode: VGCanvasContentMode.fit,
        ),
      );

      final request = VGEditorExportRequest(
        outputPath: tempOutPath,
        width: 720,
        height: 1280,
        fps: 30,
        bitrateBps: 4000000,
      );

      final readinessReport = VGEditorExportReadinessEvaluator.evaluateDraft(
        draft: draft,
        request: request,
      );

      readinessPass =
          readinessReport.canUseAndroidEditorExportRoute &&
          readinessReport.decision == VGEditorExportReadinessDecision.ready &&
          readinessReport.issues.isEmpty &&
          readinessReport.diagnostics['resolvedWidth'] == 720 &&
          readinessReport.diagnostics['resolvedHeight'] == 1280 &&
          readinessReport.diagnostics['resolvedFps'] == 30;

      if (!readinessPass) {
        throw Exception(
          'Readiness preflight failed: decision=${readinessReport.decision.name}, '
          'canUse=${readinessReport.canUseAndroidEditorExportRoute}, '
          'issues=${readinessReport.issues}, diagnostics=${readinessReport.diagnostics}',
        );
      }
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_READINESS: DONE');

      // ── Step 3: Instantiate & Initialize Controller ───────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_INIT: START');
      final controller = VGEditorController(initialDraft: draft);
      cleanupController = controller;

      ptsSubscription = controller.ptsStream.listen((pts) {
        ptsValues.add(pts);
      });

      await controller.initialize().timeout(const Duration(seconds: 20));

      textureId = controller.textureId;
      renderWidth = controller.renderWidth;
      renderHeight = controller.renderHeight;

      initPass =
          controller.isReady &&
          textureId != null &&
          textureId >= 0 &&
          renderWidth != null &&
          renderWidth > 0 &&
          renderHeight != null &&
          renderHeight > 0;

      if (!initPass) {
        throw Exception(
          'Controller initialization failed: isReady=${controller.isReady}, '
          'textureId=$textureId, renderWidth=$renderWidth, renderHeight=$renderHeight',
        );
      }

      if (mounted) {
        setState(() {
          _editorValue = controller.value;
          _status =
              'Initialized: textureId=$textureId (${renderWidth}x$renderHeight)';
        });
      }
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_INIT: DONE');

      // ── Step 4: Playback and Wait for Positive PTS ────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_PLAYBACK: START');
      final positivePtsCompleter = Completer<double>();
      final playSub = controller.ptsStream.listen((pts) {
        if (pts > 0.0 && !positivePtsCompleter.isCompleted) {
          positivePtsCompleter.complete(pts);
        }
      });

      await controller.play();
      final isPlayingAfterPlay = controller.isPlaying;
      if (!isPlayingAfterPlay) {
        throw Exception('Play failed: controller.isPlaying is false');
      }

      firstPositivePts = await positivePtsCompleter.future
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'No positive PTS received within 10s of play',
            ),
          )
          .whenComplete(() => playSub.cancel());

      playbackPass = isPlayingAfterPlay && firstPositivePts > 0.0;

      if (!playbackPass) {
        throw Exception(
          'Playback verification failed: isPlaying=$isPlayingAfterPlay, firstPositivePts=$firstPositivePts',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_PLAYBACK: DONE (firstPositivePts=$firstPositivePts, isPlaying=${controller.isPlaying})',
      );

      // ── Step 5: Export Timeline while Playing ─────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_EXPORT: START');
      if (mounted) {
        setState(() {
          _status = 'Exporting timeline via controller.export()...';
        });
      }

      exportResult = await controller
          .export(request)
          .timeout(const Duration(seconds: 90));

      exportPass = !controller.isExporting && !controller.isPlaying;

      if (!exportPass) {
        throw Exception(
          'Export state assertion failed: isExporting=${controller.isExporting}, isPlaying=${controller.isPlaying}',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_EXPORT: DONE (path=${exportResult.path}, duration=${exportResult.durationSeconds}s)',
      );

      // ── Step 6: Verify Export Result ──────────────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_VERIFY_RESULT: START');
      final outExists = await tempOutputFile.exists();
      final outBytes = outExists ? await tempOutputFile.length() : 0;
      final pathMatch = exportResult.path == tempOutPath;
      final dimsMatch =
          (exportResult.width == null || exportResult.width == 720) &&
          (exportResult.height == null || exportResult.height == 1280) &&
          (exportResult.fps == null || exportResult.fps == 30);
      final durationValid = exportResult.durationSeconds > 0;

      resultPass =
          outExists && outBytes > 0 && pathMatch && dimsMatch && durationValid;

      if (!resultPass) {
        throw Exception(
          'Export result verification failed: outExists=$outExists, outBytes=$outBytes, '
          'pathMatch=$pathMatch, dimsMatch=$dimsMatch, durationValid=$durationValid',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_VERIFY_RESULT: DONE (bytes=$outBytes, duration=${exportResult.durationSeconds})',
      );

      // ── Step 7: Verify Sidecar ────────────────────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_VERIFY_SIDECAR: START');
      final sidecarPathMatch =
          exportResult.exportRoiSidecarPath == expectedSidecarPath ||
          exportResult.exportRoiSidecarPath ==
              sidecarPathForVideoPath(tempOutPath);
      final sidecarExists = await tempSidecarFile.exists();
      final sidecarContent = sidecarExists
          ? await tempSidecarFile.readAsString()
          : '';
      final sidecarContentExact = _isValidEmptyRoiSidecar(sidecarContent);

      sidecarPass = sidecarPathMatch && sidecarExists && sidecarContentExact;

      if (!sidecarPass) {
        throw Exception(
          'Sidecar verification failed: sidecarPathMatch=$sidecarPathMatch '
          '(resultSidecar=${exportResult.exportRoiSidecarPath}, expected=$expectedSidecarPath), '
          'sidecarExists=$sidecarExists, sidecarContentExact=$sidecarContentExact (content="$sidecarContent")',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_VERIFY_SIDECAR: DONE (sidecarPath=$expectedSidecarPath)',
      );

      // ── Step 8: Inspect Output Media ──────────────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_INSPECT_OUTPUT: START');
      outMediaInfo = await VanguardMediaPreparer.inspectMedia(tempOutPath);

      final mediaHasVideo = outMediaInfo != null && outMediaInfo.hasVideo;
      final mediaHasAudio = outMediaInfo != null && outMediaInfo.hasAudio;
      final mediaDimsValid =
          outMediaInfo != null &&
          outMediaInfo.width == 720 &&
          outMediaInfo.height == 1280 &&
          (outMediaInfo.encodedWidth == 0 ||
              outMediaInfo.encodedWidth == 720) &&
          (outMediaInfo.encodedHeight == 0 ||
              outMediaInfo.encodedHeight == 1280) &&
          (outMediaInfo.displayWidth == 0 ||
              outMediaInfo.displayWidth == 720) &&
          (outMediaInfo.displayHeight == 0 ||
              outMediaInfo.displayHeight == 1280);
      final mediaNoRotation =
          outMediaInfo != null &&
          (!outMediaInfo.hasRotationTransform ||
              outMediaInfo.rotationDegrees == 0 ||
              outMediaInfo.rotationDegrees == null);
      final mediaDurationValid =
          outMediaInfo != null && outMediaInfo.durationSeconds > 0;

      inspectPass =
          mediaHasVideo &&
          mediaHasAudio &&
          mediaDimsValid &&
          mediaNoRotation &&
          mediaDurationValid;

      if (!inspectPass) {
        throw Exception(
          'Output media inspection failed: hasVideo=$mediaHasVideo, hasAudio=$mediaHasAudio, '
          'dimsValid=$mediaDimsValid, noRotation=$mediaNoRotation, '
          'durationValid=$mediaDurationValid, info=$outMediaInfo',
        );
      }
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_INSPECT_OUTPUT: DONE (duration=${outMediaInfo.durationSeconds}s, '
        'dims=${outMediaInfo.width}x${outMediaInfo.height}, audioCodec=${outMediaInfo.audioCodec})',
      );

      // ── Step 9: Dispose Controller ────────────────────────────────────────
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_DISPOSE: START');
      await controller.disposeAsyncConfirmed().timeout(
        const Duration(seconds: 5),
      );
      controller.dispose();
      cleanupController = null;
      disposePass = true;
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_DISPOSE: DONE');
    } catch (e, st) {
      errorMessage = '$e';
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_ERROR: $e\n$st');
    } finally {
      print('ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_CLEANUP: START');
      await ptsSubscription?.cancel();
      if (cleanupController != null) {
        try {
          await cleanupController.disposeAsyncConfirmed();
        } catch (_) {}
        cleanupController.dispose();
      }
      if (tempSourceFile != null && await tempSourceFile.exists()) {
        try {
          await tempSourceFile.delete();
        } catch (_) {}
      }
      if (tempOutputFile != null && await tempOutputFile.exists()) {
        try {
          await tempOutputFile.delete();
        } catch (_) {}
      }
      if (tempSidecarFile != null && await tempSidecarFile.exists()) {
        try {
          await tempSidecarFile.delete();
        } catch (_) {}
      }
      if (tempOutPath != null) {
        final vgtmpFile = File('$tempOutPath.vgtmp');
        if (await vgtmpFile.exists()) {
          try {
            await vgtmpFile.delete();
          } catch (_) {}
        }
        final vgroitmpFile = File('$expectedSidecarPath.vgroitmp');
        if (await vgroitmpFile.exists()) {
          try {
            await vgroitmpFile.delete();
          } catch (_) {}
        }
      }

      final sourceClean =
          tempSourceFile == null || !tempSourceFile.existsSync();
      final outputClean =
          tempOutputFile == null || !tempOutputFile.existsSync();
      final sidecarClean =
          tempSidecarFile == null || !tempSidecarFile.existsSync();
      cleanupPass = sourceClean && outputClean && sidecarClean;
      print(
        'ANDROID_EDITOR_CONTROLLER_EXPORT_STEP_CLEANUP: DONE (cleanupPass=$cleanupPass)',
      );
    }

    final overallPass =
        sourcePrepared &&
        readinessPass &&
        initPass &&
        playbackPass &&
        exportPass &&
        resultPass &&
        sidecarPass &&
        inspectPass &&
        disposePass &&
        cleanupPass;

    final jsonSummary = <String, dynamic>{
      'pass': overallPass,
      'sourcePrepared': sourcePrepared,
      'readinessPass': readinessPass,
      'initPass': initPass,
      'playbackPass': playbackPass,
      'exportPass': exportPass,
      'resultPass': resultPass,
      'sidecarPass': sidecarPass,
      'inspectPass': inspectPass,
      'disposePass': disposePass,
      'cleanupPass': cleanupPass,
      'textureId': textureId,
      'renderWidth': renderWidth,
      'renderHeight': renderHeight,
      'firstPositivePts': firstPositivePts,
      'exportDurationSeconds': exportResult?.durationSeconds,
      'exportOutputPath': exportResult?.path,
      'exportRoiSidecarPath': exportResult?.exportRoiSidecarPath,
      'inspectMediaDuration': outMediaInfo?.durationSeconds,
      'inspectMediaAudioCodec': outMediaInfo?.audioCodec,
      'error': errorMessage,
    };

    print(
      'ANDROID_EDITOR_CONTROLLER_EXPORT_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(jsonSummary)}',
    );

    print(
      overallPass
          ? 'ANDROID_EDITOR_CONTROLLER_EXPORT_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_EDITOR_CONTROLLER_EXPORT_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass
            ? 'PASS: Android VGEditorController export pipeline and preflight readiness verified.'
            : 'FAIL: $errorMessage';
      });
    }

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
