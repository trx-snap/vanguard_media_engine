// android_export_progress_unit_t_physical_smoke.dart
// Vanguard Media Engine — Android Real onExportProgress Telemetry Parity (Phase 5-Unit T)
// ignore_for_file: avoid_print

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
// ignore: implementation_imports
import "package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart";
import "package:vanguard_media_engine/vanguard_media_engine.dart";

String sidecarPathForVideoPath(String videoPath) {
  final lastSeparator = videoPath.lastIndexOf("/");
  final lastDot = videoPath.lastIndexOf(".");
  if (lastDot <= lastSeparator) {
    return "$videoPath.roi.json";
  }
  return "${videoPath.substring(0, lastDot)}.roi.json";
}

void main() {
  runApp(const AndroidExportProgressUnitTPhysicalSmokeApp());
}

class AndroidExportProgressUnitTPhysicalSmokeApp extends StatefulWidget {
  const AndroidExportProgressUnitTPhysicalSmokeApp({super.key});

  @override
  State<AndroidExportProgressUnitTPhysicalSmokeApp> createState() =>
      _AndroidExportProgressUnitTPhysicalSmokeAppState();
}

class _AndroidExportProgressUnitTPhysicalSmokeAppState
    extends State<AndroidExportProgressUnitTPhysicalSmokeApp> {
  String _status =
      "Initializing Android Export Progress Unit T Physical Smoke...";
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      print("ANDROID_EXPORT_PROGRESS_UNIT_T: TIMEOUT (120s exceeded)");
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_PHYSICAL_FAIL");
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSmoke());
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    print("ANDROID_EXPORT_PROGRESS_UNIT_T_START");
    print(
      "DEVICE: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} locale=${Platform.localeName}",
    );

    final runId = "unit_t_${DateTime.now().millisecondsSinceEpoch}";
    final tempDir = Directory.systemTemp;

    // Track all owned files for thorough cleanup
    final ownedFiles = <File>[];

    Map<String, dynamic>? lane1Results;
    Map<String, dynamic>? lane2Results;
    Map<String, dynamic>? lane3Results;
    Map<String, dynamic>? lane4Results;
    final cleanupObservations = <String, dynamic>{};

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    String? topLevelError;

    try {
      // Step 1: Copy still image asset to a unique temp file
      print("ANDROID_EXPORT_PROGRESS_UNIT_T: Loading asset fixtures...");
      final stillByteData = await rootBundle.load(
        "assets/manual_test_clips/still_C.png",
      );
      final rawStillBytes = stillByteData.buffer.asUint8List(
        stillByteData.offsetInBytes,
        stillByteData.lengthInBytes,
      );
      final tempStillSourceFile = File(
        "${tempDir.path}/${runId}_source_still_C.png",
      );
      ownedFiles.add(tempStillSourceFile);
      await tempStillSourceFile.writeAsBytes(
        Uint8List.fromList(rawStillBytes),
        flush: true,
      );
      final stillSourcePath = tempStillSourceFile.path;
      print(
        "ANDROID_EXPORT_PROGRESS_UNIT_T: Still image ready at $stillSourcePath (${rawStillBytes.length} bytes)",
      );

      // Step 2: Copy video asset fixture for Lane 4 passthrough
      final clipBByteData = await rootBundle.load(
        "assets/manual_test_clips/clip_B.mov",
      );
      final rawClipBBytes = clipBByteData.buffer.asUint8List(
        clipBByteData.offsetInBytes,
        clipBByteData.lengthInBytes,
      );
      final tempClipBSourceFile = File(
        "${tempDir.path}/${runId}_source_clip_B.mov",
      );
      ownedFiles.add(tempClipBSourceFile);
      await tempClipBSourceFile.writeAsBytes(
        Uint8List.fromList(rawClipBBytes),
        flush: true,
      );
      final clipBSourcePath = tempClipBSourceFile.path;
      print(
        "ANDROID_EXPORT_PROGRESS_UNIT_T: Video clip ready at $clipBSourcePath (${rawClipBBytes.length} bytes)",
      );

      // ─── Lane 1: Normal export with onProgress on local still timeline ─────
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE1: START");
      final lane1OutputPath = "${tempDir.path}/${runId}_lane1_out.mp4";
      final lane1OutputFile = File(lane1OutputPath);
      final lane1SidecarFile = File(sidecarPathForVideoPath(lane1OutputPath));
      ownedFiles.add(lane1OutputFile);
      ownedFiles.add(lane1SidecarFile);

      try {
        final lane1Draft = VGEditorDraft(
          id: "${runId}_lane1_draft",
          clips: [
            VGClipDescriptor(
              id: "${runId}_lane1_clip",
              mediaKind: VGMediaKind.image,
              sourcePath: stillSourcePath,
              durationSeconds: 2.0,
              trimStartSeconds: 0.0,
              trimEndSeconds: 2.0,
            ),
          ],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final lane1Progress = <double>[];
        final lane1Result = await VanguardTimelineExporter.exportDraft(
          draft: lane1Draft,
          request: VGEditorExportRequest(
            outputPath: lane1OutputPath,
            width: 720,
            height: 1280,
            fps: 30,
            bitrateBps: 2000000,
          ),
          onProgress: (p) => lane1Progress.add(p),
        );

        final outExists = await lane1OutputFile.exists();
        final outSize = outExists ? await lane1OutputFile.length() : 0;

        // Progress sequence assertions
        final isNonEmpty = lane1Progress.isNotEmpty;
        var isMonotonic = true;
        for (var i = 1; i < lane1Progress.length; i++) {
          if (lane1Progress[i] < lane1Progress[i - 1]) {
            isMonotonic = false;
            break;
          }
        }

        final count085 = lane1Progress
            .where((p) => (p - 0.85).abs() < 1e-5)
            .length;
        final count098 = lane1Progress
            .where((p) => (p - 0.98).abs() < 1e-5)
            .length;
        final count100 = lane1Progress
            .where((p) => (p - 1.0).abs() < 1e-5)
            .length;
        final finalIs100 =
            lane1Progress.isNotEmpty && (lane1Progress.last - 1.0).abs() < 1e-5;

        final sampledProgressCount = lane1Progress
            .where((p) => p < 0.85)
            .length;

        lane1Pass =
            lane1Result.path.isNotEmpty &&
            lane1Result.durationSeconds > 0 &&
            outExists &&
            outSize > 0 &&
            isNonEmpty &&
            isMonotonic &&
            count085 == 1 &&
            count098 == 1 &&
            count100 == 1 &&
            finalIs100;

        lane1Results = {
          "pass": lane1Pass,
          "resultPath": lane1Result.path,
          "durationSeconds": lane1Result.durationSeconds,
          "outputSizeBytes": outSize,
          "totalProgressEvents": lane1Progress.length,
          "sampledPass1Events": sampledProgressCount,
          "isMonotonic": isMonotonic,
          "count085": count085,
          "count098": count098,
          "count100": count100,
          "finalProgress": lane1Progress.isNotEmpty ? lane1Progress.last : null,
          "progressSequence": lane1Progress
              .map((p) => double.parse(p.toStringAsFixed(4)))
              .toList(),
        };

        if (lane1Pass) {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE1: PASS (events=${lane1Progress.length}, sampled=$sampledProgressCount, 0.85=$count085, 0.98=$count098, 1.0=$count100)",
          );
          print("LANE1_PASS");
        } else {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE1: FAIL results=$lane1Results",
          );
        }
      } catch (e, st) {
        print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE1: ERROR $e\n$st");
        lane1Results = {"pass": false, "error": "$e"};
      }

      // ─── Lane 2: Cancel mid-pass-1 & recovery export ───────────────────────
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: START");
      final lane2OutputPath = "${tempDir.path}/${runId}_lane2_out.mp4";
      final lane2OutputFile = File(lane2OutputPath);
      final lane2SidecarFile = File(sidecarPathForVideoPath(lane2OutputPath));
      ownedFiles.add(lane2OutputFile);
      ownedFiles.add(lane2SidecarFile);

      final lane2TinyOutputPath = "${tempDir.path}/${runId}_lane2_tiny_out.mp4";
      final lane2TinyOutputFile = File(lane2TinyOutputPath);
      final lane2TinySidecarFile = File(
        sidecarPathForVideoPath(lane2TinyOutputPath),
      );
      ownedFiles.add(lane2TinyOutputFile);
      ownedFiles.add(lane2TinySidecarFile);

      try {
        final lane2LongDraft = VGEditorDraft(
          id: "${runId}_lane2_draft",
          clips: [
            VGClipDescriptor(
              id: "${runId}_lane2_clip",
              mediaKind: VGMediaKind.image,
              sourcePath: stillSourcePath,
              durationSeconds: 8.0, // 240 frames at 30fps — plenty of time
              trimStartSeconds: 0.0,
              trimEndSeconds: 8.0,
            ),
          ],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final lane2Progress = <double>[];
        final firstProgressCompleter = Completer<void>();

        final cancelExportFuture = VanguardTimelineExporter.exportDraft(
          draft: lane2LongDraft,
          request: VGEditorExportRequest(
            outputPath: lane2OutputPath,
            width: 720,
            height: 1280,
            fps: 30,
            bitrateBps: 2000000,
          ),
          onProgress: (p) {
            lane2Progress.add(p);
            if (!firstProgressCompleter.isCompleted) {
              firstProgressCompleter.complete();
            }
          },
        );

        // Wait for first progress or bounded timeout
        await firstProgressCompleter.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );

        // Cancel the in-flight export via plugin channel call
        print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: Calling cancelExport...");
        await const MethodChannel(
          "vanguard_media_engine",
        ).invokeMethod<void>("cancelExport");

        var cancelObserved = false;
        String? cancelErrorCode;
        try {
          await cancelExportFuture;
        } on PlatformException catch (pe) {
          cancelErrorCode = pe.code;
          if (pe.code == "EXPORT_CANCELLED") {
            cancelObserved = true;
          }
        }

        // Assert no 0.85, 0.98, or 1.0 checkpoints after cancel
        final has085 = lane2Progress.any((p) => (p - 0.85).abs() < 1e-5);
        final has098 = lane2Progress.any((p) => (p - 0.98).abs() < 1e-5);
        final has100 = lane2Progress.any((p) => (p - 1.0).abs() < 1e-5);

        // Wait 300ms and assert no late progress arrived
        final countAtCancel = lane2Progress.length;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final countAfterWait = lane2Progress.length;
        final noLateProgress = countAtCancel == countAfterWait;

        // Run recovery tiny export to prove lock cleared only after terminal callback
        print(
          "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: Running recovery export...",
        );
        final recoveryDraft = VGEditorDraft(
          id: "${runId}_lane2_recovery_draft",
          clips: [
            VGClipDescriptor(
              id: "${runId}_lane2_recovery_clip",
              mediaKind: VGMediaKind.image,
              sourcePath: stillSourcePath,
              durationSeconds: 1.0,
              trimStartSeconds: 0.0,
              trimEndSeconds: 1.0,
            ),
          ],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final recoveryResult = await VanguardTimelineExporter.exportDraft(
          draft: recoveryDraft,
          request: VGEditorExportRequest(
            outputPath: lane2TinyOutputPath,
            width: 720,
            height: 1280,
            fps: 30,
            bitrateBps: 2000000,
          ),
        );

        final recoveryExists = await lane2TinyOutputFile.exists();
        final recoverySize = recoveryExists
            ? await lane2TinyOutputFile.length()
            : 0;

        lane2Pass =
            cancelObserved &&
            !has085 &&
            !has098 &&
            !has100 &&
            noLateProgress &&
            recoveryResult.path.isNotEmpty &&
            recoveryResult.durationSeconds > 0 &&
            recoveryExists &&
            recoverySize > 0;

        lane2Results = {
          "pass": lane2Pass,
          "cancelObserved": cancelObserved,
          "cancelErrorCode": cancelErrorCode,
          "progressEventsBeforeCancel": countAtCancel,
          "progressEventsAfterWait": countAfterWait,
          "noLateProgress": noLateProgress,
          "has085": has085,
          "has098": has098,
          "has100": has100,
          "recoveryResultPath": recoveryResult.path,
          "recoveryDurationSeconds": recoveryResult.durationSeconds,
          "recoveryOutputSizeBytes": recoverySize,
          "progressSequence": lane2Progress
              .map((p) => double.parse(p.toStringAsFixed(4)))
              .toList(),
        };

        if (lane2Pass) {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: PASS (cancelled=$cancelObserved, events=$countAtCancel, recoverySize=$recoverySize)",
          );
          print("LANE2_PASS");
        } else {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: FAIL results=$lane2Results",
          );
        }
      } catch (e, st) {
        print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE2: ERROR $e\n$st");
        lane2Results = {"pass": false, "error": "$e"};
      }

      // ─── Lane 3: Concurrent rejection + listener stack ─────────────────────
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE3: START");
      final lane3OutputPathA = "${tempDir.path}/${runId}_lane3_out_a.mp4";
      final lane3OutputFileA = File(lane3OutputPathA);
      final lane3SidecarFileA = File(sidecarPathForVideoPath(lane3OutputPathA));
      ownedFiles.add(lane3OutputFileA);
      ownedFiles.add(lane3SidecarFileA);

      final lane3OutputPathB = "${tempDir.path}/${runId}_lane3_out_b.mp4";
      final lane3OutputFileB = File(lane3OutputPathB);
      final lane3SidecarFileB = File(sidecarPathForVideoPath(lane3OutputPathB));
      ownedFiles.add(lane3OutputFileB);
      ownedFiles.add(lane3SidecarFileB);

      try {
        final draft3LongA = VGEditorDraft(
          id: "${runId}_lane3_draft_a",
          clips: [
            VGClipDescriptor(
              id: "${runId}_lane3_clip_a",
              mediaKind: VGMediaKind.image,
              sourcePath: stillSourcePath,
              durationSeconds: 4.0,
              trimStartSeconds: 0.0,
              trimEndSeconds: 4.0,
            ),
          ],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final draft3B = VGEditorDraft(
          id: "${runId}_lane3_draft_b",
          clips: [
            VGClipDescriptor(
              id: "${runId}_lane3_clip_b",
              mediaKind: VGMediaKind.image,
              sourcePath: stillSourcePath,
              durationSeconds: 1.0,
              trimStartSeconds: 0.0,
              trimEndSeconds: 1.0,
            ),
          ],
          canvasWidth: 720,
          canvasHeight: 1280,
          fps: 30,
        );

        final progressEventsA = <double>[];
        final progressEventsB = <double>[];
        final completerA = Completer<void>();

        // Start long export A with listener A
        final futureA = VanguardTimelineExporter.exportDraft(
          draft: draft3LongA,
          request: VGEditorExportRequest(
            outputPath: lane3OutputPathA,
            width: 720,
            height: 1280,
            fps: 30,
            bitrateBps: 2000000,
          ),
          onProgress: (p) {
            progressEventsA.add(p);
            if (!completerA.isCompleted) {
              completerA.complete();
            }
          },
        );

        // Wait for export A to start emitting progress
        await completerA.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );

        // While export A is active, attempt export B with listener B
        var rejectedB = false;
        String? errorCodeB;
        try {
          await VanguardTimelineExporter.exportDraft(
            draft: draft3B,
            request: VGEditorExportRequest(
              outputPath: lane3OutputPathB,
              width: 720,
              height: 1280,
              fps: 30,
              bitrateBps: 2000000,
            ),
            onProgress: (p) => progressEventsB.add(p),
          );
        } on PlatformException catch (pe) {
          errorCodeB = pe.code;
          if (pe.code == "EXPORT_IN_PROGRESS") {
            rejectedB = true;
          }
        }

        // Wait for export A to finish
        final resultA = await futureA;
        final outExistsA = await lane3OutputFileA.exists();
        final outSizeA = outExistsA ? await lane3OutputFileA.length() : 0;

        final hasTerminal100A =
            progressEventsA.isNotEmpty &&
            (progressEventsA.last - 1.0).abs() < 1e-5;

        lane3Pass =
            rejectedB &&
            resultA.path.isNotEmpty &&
            resultA.durationSeconds > 0 &&
            outExistsA &&
            outSizeA > 0 &&
            hasTerminal100A;

        lane3Results = {
          "pass": lane3Pass,
          "rejectedB": rejectedB,
          "errorCodeB": errorCodeB,
          "eventsBCount": progressEventsB.length,
          "resultAPath": resultA.path,
          "resultADurationSeconds": resultA.durationSeconds,
          "outputSizeBytesA": outSizeA,
          "eventsACount": progressEventsA.length,
          "hasTerminal100A": hasTerminal100A,
          "finalProgressA": progressEventsA.isNotEmpty
              ? progressEventsA.last
              : null,
          "progressSequenceA": progressEventsA
              .map((p) => double.parse(p.toStringAsFixed(4)))
              .toList(),
        };

        if (lane3Pass) {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE3: PASS (rejectedB=$rejectedB, eventsA=${progressEventsA.length}, terminalA=$hasTerminal100A)",
          );
          print("LANE3_PASS");
        } else {
          print(
            "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE3: FAIL results=$lane3Results",
          );
        }
      } catch (e, st) {
        print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE3: ERROR $e\n$st");
        lane3Results = {"pass": false, "error": "$e"};
      }

      // ─── Lane 4: exportPassthroughRemux no-progress sanity ─────────────────
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE4: START");
      final lane4OutputPath = "${tempDir.path}/${runId}_lane4_out.mp4";
      final lane4OutputFile = File(lane4OutputPath);
      final lane4SidecarFile = File(sidecarPathForVideoPath(lane4OutputPath));
      ownedFiles.add(lane4OutputFile);
      ownedFiles.add(lane4SidecarFile);

      try {
        final progressEvents4 = <double>[];
        final sub4 = VanguardChannelDispatcher.instance.registerExportListener(
          (p) => progressEvents4.add(p),
        );

        try {
          final result4 = await const MethodChannel("vanguard_media_engine")
              .invokeMapMethod<String, dynamic>(
                "exportPassthroughRemux",
                <String, Object?>{
                  "sourcePath": clipBSourcePath,
                  "outputPath": lane4OutputPath,
                },
              );

          final outExists4 = await lane4OutputFile.exists();
          final outSize4 = outExists4 ? await lane4OutputFile.length() : 0;
          final result4Success = result4?["success"] == true;

          // Passthrough remux must NOT emit any export progress events
          final noProgressEmitted = progressEvents4.isEmpty;

          lane4Pass =
              result4Success && outExists4 && outSize4 > 0 && noProgressEmitted;

          lane4Results = {
            "pass": lane4Pass,
            "resultSuccess": result4Success,
            "outputSizeBytes": outSize4,
            "progressEventsCount": progressEvents4.length,
            "noProgressEmitted": noProgressEmitted,
          };

          if (lane4Pass) {
            print(
              "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE4: PASS (events=${progressEvents4.length}, outSize=$outSize4)",
            );
            print("LANE4_PASS");
          } else {
            print(
              "ANDROID_EXPORT_PROGRESS_UNIT_T_LANE4: FAIL results=$lane4Results",
            );
          }
        } finally {
          VanguardChannelDispatcher.instance.unregisterExportListener(sub4);
        }
      } catch (e, st) {
        print("ANDROID_EXPORT_PROGRESS_UNIT_T_LANE4: ERROR $e\n$st");
        lane4Results = {"pass": false, "error": "$e"};
      }
    } catch (e, st) {
      topLevelError = "$e\n$st";
      print("ANDROID_EXPORT_PROGRESS_UNIT_T: TOP-LEVEL ERROR: $topLevelError");
    } finally {
      // Clean all owned temp files
      print("ANDROID_EXPORT_PROGRESS_UNIT_T: Cleaning owned temp files...");
      var cleanedCount = 0;
      var failedCleanCount = 0;
      for (final file in ownedFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
            cleanedCount++;
          }
        } catch (e) {
          failedCleanCount++;
        }
      }
      cleanupObservations["ownedFilesTargeted"] = ownedFiles.length;
      cleanupObservations["filesCleaned"] = cleanedCount;
      cleanupObservations["failedCleanCount"] = failedCleanCount;
      print(
        "ANDROID_EXPORT_PROGRESS_UNIT_T: Cleaned $cleanedCount files ($failedCleanCount errors)",
      );
    }

    final allPass =
        lane1Pass &&
        lane2Pass &&
        lane3Pass &&
        lane4Pass &&
        (topLevelError == null);

    final payload = <String, dynamic>{
      "unit": "AndroidExportProgressUnitT",
      "target": "android_physical",
      "pass": allPass,
      "lanes": <String, dynamic>{
        "lane1_normal_export_progress":
            lane1Results ?? {"pass": false, "error": "not run"},
        "lane2_cancel_and_recovery":
            lane2Results ?? {"pass": false, "error": "not run"},
        "lane3_concurrent_rejection_stack":
            lane3Results ?? {"pass": false, "error": "not run"},
        "lane4_passthrough_remux_no_progress":
            lane4Results ?? {"pass": false, "error": "not run"},
      },
      "cleanup": cleanupObservations,
      "error": topLevelError,
    };

    print("ANDROID_EXPORT_PROGRESS_UNIT_T_JSON:${jsonEncode(payload)}");
    if (allPass) {
      print("PHYSICAL_PASS");
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_PHYSICAL_PASS");
    } else {
      print("ANDROID_EXPORT_PROGRESS_UNIT_T_PHYSICAL_FAIL");
    }

    if (mounted) {
      setState(() {
        _status = allPass ? "PASS" : "FAIL";
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
