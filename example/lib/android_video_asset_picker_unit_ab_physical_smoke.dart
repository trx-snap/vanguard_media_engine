// android_video_asset_picker_unit_ab_physical_smoke.dart
// Vanguard Media Engine — Phase 5-Unit AB / Phase 10F-Slice 2B / UMF V2 Slice 2B
// Android Photo/Video Gallery Asset Picker Bridge Parity Physical Smoke Test.

// ignore_for_file: avoid_print

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter/services.dart"
    show MethodChannel, PlatformException, rootBundle;
import "package:vanguard_media_engine/vanguard_media_engine.dart";

void main() {
  runApp(const AndroidVideoAssetPickerUnitABPhysicalSmokeApp());
}

class AndroidVideoAssetPickerUnitABPhysicalSmokeApp extends StatefulWidget {
  const AndroidVideoAssetPickerUnitABPhysicalSmokeApp({super.key});

  @override
  State<AndroidVideoAssetPickerUnitABPhysicalSmokeApp> createState() =>
      _AndroidVideoAssetPickerUnitABPhysicalSmokeAppState();
}

class _AndroidVideoAssetPickerUnitABPhysicalSmokeAppState
    extends State<AndroidVideoAssetPickerUnitABPhysicalSmokeApp> {
  String _status =
      "Initializing Android Video Asset Picker Physical Smoke (Unit AB)...";
  Timer? _timeoutTimer;

  static const MethodChannel _rawChannel = MethodChannel(
    "vanguard_media_engine",
  );

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 90), () {
      print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: TIMEOUT (90s exceeded)");
      print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_PHYSICAL_FAIL");
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
    print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: START");
    final runId = "unit_ab_${DateTime.now().millisecondsSinceEpoch}";
    final stagedTempPath =
        "${Directory.systemTemp.path}/unit_ab_seed_$runId.mov";

    File? stagedTempFile;
    final List<File> createdCacheFiles = [];

    String? currentPermissionStatus;
    bool pass = false;
    String? failureReason;
    final Map<String, dynamic> resultsLog = {};

    try {
      // Query current permission status
      final rawStatus = await _rawChannel.invokeMethod<String>(
        "checkPhotoLibraryPermission",
      );
      currentPermissionStatus = rawStatus;
      print(
        "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Initial checkPhotoLibraryPermission = $rawStatus",
      );
      resultsLog["initial_permission_status"] = rawStatus;

      if (rawStatus == "notDetermined") {
        // ── Phase A: No-permission / notDetermined phase ─────────────────────
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Running Phase A (notDetermined)",
        );

        // 1. checkPhotoLibraryPermission returns notDetermined from attached Activity
        if (rawStatus != "notDetermined") {
          throw Exception("Expected notDetermined, got $rawStatus");
        }

        // 2. fetchPhotoVideos returns empty list without throwing
        final List<dynamic>? videos = await _rawChannel
            .invokeListMethod<dynamic>("fetchPhotoVideos");
        if (videos == null || videos.isNotEmpty) {
          throw Exception(
            "Expected empty list for fetchPhotoVideos under notDetermined, got: $videos",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: fetchPhotoVideos returned empty list",
        );

        // 3. fetchPhotoVideoThumbnail with invalid non-content id throws INVALID_ARGUMENT
        bool thumbThrewInvalidArgument = false;
        try {
          await _rawChannel.invokeMethod<Uint8List>(
            "fetchPhotoVideoThumbnail",
            <String, dynamic>{
              "id": "invalid_non_content_id",
              "width": 240,
              "height": 135,
            },
          );
        } on PlatformException catch (pe) {
          if (pe.code == "INVALID_ARGUMENT") {
            thumbThrewInvalidArgument = true;
          } else {
            throw Exception(
              "Expected INVALID_ARGUMENT from thumbnail, got ${pe.code}: ${pe.message}",
            );
          }
        }
        if (!thumbThrewInvalidArgument) {
          throw Exception(
            "fetchPhotoVideoThumbnail with invalid id did not throw INVALID_ARGUMENT",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: fetchPhotoVideoThumbnail rejected invalid ID with INVALID_ARGUMENT",
        );

        // 4. exportPhotoVideo with invalid non-content id throws INVALID_ARGUMENT
        bool exportThrewInvalidArgument = false;
        try {
          await _rawChannel.invokeMethod<String>(
            "exportPhotoVideo",
            <String, dynamic>{"id": "invalid_non_content_id"},
          );
        } on PlatformException catch (pe) {
          if (pe.code == "INVALID_ARGUMENT") {
            exportThrewInvalidArgument = true;
          } else {
            throw Exception(
              "Expected INVALID_ARGUMENT from export, got ${pe.code}: ${pe.message}",
            );
          }
        }
        if (!exportThrewInvalidArgument) {
          throw Exception(
            "exportPhotoVideo with invalid id did not throw INVALID_ARGUMENT",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: exportPhotoVideo rejected invalid ID with INVALID_ARGUMENT",
        );

        // 5. cancelExportPhotoVideo for an unknown id returns true
        final bool? cancelUnknown = await _rawChannel.invokeMethod<bool>(
          "cancelExportPhotoVideo",
          <String, dynamic>{"id": "unknown_asset_id_999"},
        );
        if (cancelUnknown != true) {
          throw Exception(
            "cancelExportPhotoVideo for unknown ID expected true, got $cancelUnknown",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: cancelExportPhotoVideo returned true for unknown ID",
        );

        // Note: Do not call requestPhotoLibraryPermission or presentLimitedLibraryPicker here (avoids OS UI).
        pass = true;
        print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_NOT_DETERMINED_PASS");
      } else if (rawStatus == "authorized") {
        // ── Phase B: Authorized phase ─────────────────────────────────────────
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Running Phase B (authorized)",
        );

        // 1. checkPhotoLibraryPermission returns authorized
        if (rawStatus != "authorized") {
          throw Exception("Expected authorized, got $rawStatus");
        }

        // 2. Stage clip_B.mov to app temp and seed MediaStore via VanguardEngine.saveVideoToPhotoLibrary
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Loading fixture assets/manual_test_clips/clip_B.mov",
        );
        final byteData = await rootBundle.load(
          "assets/manual_test_clips/clip_B.mov",
        );
        stagedTempFile = File(stagedTempPath);
        await stagedTempFile.writeAsBytes(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
          flush: true,
        );
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Staged seed fixture (${await stagedTempFile.length()} bytes) at $stagedTempPath",
        );

        final bool saved = await VanguardEngine.saveVideoToPhotoLibrary(
          stagedTempPath,
        );
        if (!saved) {
          throw Exception(
            "VanguardEngine.saveVideoToPhotoLibrary failed to seed MediaStore",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: VanguardEngine.saveVideoToPhotoLibrary succeeded",
        );

        // 3. Retry fetchPhotoVideos(limit: 20, offset: 0) for up to 10s until at least one asset is returned
        List<dynamic> assets = [];
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 10000) {
          final List<dynamic>? queried = await _rawChannel
              .invokeListMethod<dynamic>("fetchPhotoVideos", <String, dynamic>{
                "limit": 20,
                "offset": 0,
              });
          if (queried != null && queried.isNotEmpty) {
            assets = queried;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        stopwatch.stop();

        if (assets.isEmpty) {
          throw Exception(
            "fetchPhotoVideos returned empty list after 10s of retries following seed save",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: fetchPhotoVideos returned ${assets.length} assets in ${stopwatch.elapsedMilliseconds}ms",
        );

        final firstAsset = assets.first;
        if (firstAsset is! Map) {
          throw Exception("Asset item is not a Map: $firstAsset");
        }
        final assetMap = Map<String, dynamic>.from(firstAsset);
        final String? chosenId = assetMap["id"] as String?;
        if (chosenId == null || !chosenId.startsWith("content://")) {
          throw Exception(
            "Asset ID must be non-null and start with content://, got: $chosenId",
          );
        }
        final num? durationSec = assetMap["durationSeconds"] as num?;
        if (durationSec == null || durationSec < 0) {
          throw Exception(
            "Asset durationSeconds must be numeric >= 0, got: $durationSec",
          );
        }
        if (assetMap.containsKey("pixelWidth") &&
            assetMap["pixelWidth"] != null &&
            assetMap["pixelWidth"] is! num) {
          throw Exception("pixelWidth is present but not numeric");
        }
        if (assetMap.containsKey("pixelHeight") &&
            assetMap["pixelHeight"] != null &&
            assetMap["pixelHeight"] is! num) {
          throw Exception("pixelHeight is present but not numeric");
        }
        if (assetMap.containsKey("creationTimestampMs") &&
            assetMap["creationTimestampMs"] != null &&
            assetMap["creationTimestampMs"] is! num) {
          throw Exception("creationTimestampMs is present but not numeric");
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Validated chosen asset ID=$chosenId duration=${durationSec}s",
        );

        // 4. Verify paging with fetchPhotoVideos(limit: 1, offset: 0) and (limit: 1, offset: 1)
        final List<dynamic>? paged1 = await _rawChannel
            .invokeListMethod<dynamic>("fetchPhotoVideos", <String, dynamic>{
              "limit": 1,
              "offset": 0,
            });
        if (paged1 == null || paged1.length > 1) {
          throw Exception(
            "fetchPhotoVideos(limit: 1, offset: 0) returned unexpected length: ${paged1?.length}",
          );
        }
        final List<dynamic>? paged2 = await _rawChannel
            .invokeListMethod<dynamic>("fetchPhotoVideos", <String, dynamic>{
              "limit": 1,
              "offset": 1,
            });
        if (paged2 == null) {
          throw Exception(
            "fetchPhotoVideos(limit: 1, offset: 1) returned null",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Paging verified (page0 len=${paged1.length}, page1 len=${paged2.length})",
        );

        // 5. fetchPhotoVideoThumbnail returns non-empty JPEG-like bytes
        final Uint8List? thumbBytes = await _rawChannel.invokeMethod<Uint8List>(
          "fetchPhotoVideoThumbnail",
          <String, dynamic>{"id": chosenId, "width": 240, "height": 135},
        );
        if (thumbBytes == null || thumbBytes.isEmpty) {
          throw Exception(
            "fetchPhotoVideoThumbnail returned empty/null bytes for $chosenId",
          );
        }
        if (thumbBytes.length >= 2 &&
            (thumbBytes[0] != 0xFF || thumbBytes[1] != 0xD8)) {
          throw Exception("Thumbnail bytes do not start with JPEG SOI marker");
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: fetchPhotoVideoThumbnail returned ${thumbBytes.length} JPEG bytes",
        );

        // Issue two same-id thumbnail futures concurrently
        final thumbFuture1 = _rawChannel.invokeMethod<Uint8List>(
          "fetchPhotoVideoThumbnail",
          <String, dynamic>{"id": chosenId, "width": 240, "height": 135},
        );
        final thumbFuture2 = _rawChannel.invokeMethod<Uint8List>(
          "fetchPhotoVideoThumbnail",
          <String, dynamic>{"id": chosenId, "width": 240, "height": 135},
        );
        final concurrentThumbResults = await Future.wait([
          thumbFuture1,
          thumbFuture2,
        ]);
        final hasValidConcurrentThumb = concurrentThumbResults.any(
          (b) => b != null && b.isNotEmpty,
        );
        if (!hasValidConcurrentThumb) {
          throw Exception(
            "Neither concurrent thumbnail request returned non-empty bytes",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Concurrent thumbnail requests completed cleanly without error",
        );

        // 6. exportPhotoVideo for chosen id returns local app-cache path
        final String? exportPath = await _rawChannel.invokeMethod<String>(
          "exportPhotoVideo",
          <String, dynamic>{"id": chosenId},
        );
        if (exportPath == null || exportPath.isEmpty) {
          throw Exception("exportPhotoVideo returned empty path");
        }
        final exportedFile = File(exportPath);
        createdCacheFiles.add(exportedFile);
        if (!await exportedFile.exists()) {
          throw Exception("Exported file does not exist at $exportPath");
        }
        final exportLength = await exportedFile.length();
        if (exportLength <= 0) {
          throw Exception("Exported file is empty (0 bytes) at $exportPath");
        }
        final exportExt = exportPath.split(".").last.toLowerCase();
        if (!["mp4", "mov", "m4v"].contains(exportExt)) {
          throw Exception(
            "Exported file extension '$exportExt' not one of mp4/mov/m4v",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: exportPhotoVideo succeeded: path=$exportPath size=$exportLength ext=$exportExt",
        );

        // 7. Start an export and immediately call cancelExportPhotoVideo
        final exportCancelFuture = _rawChannel.invokeMethod<String>(
          "exportPhotoVideo",
          <String, dynamic>{"id": chosenId},
        );
        final cancelFuture = _rawChannel.invokeMethod<bool>(
          "cancelExportPhotoVideo",
          <String, dynamic>{"id": chosenId},
        );
        final cancelResult = await cancelFuture;
        if (cancelResult != true) {
          throw Exception(
            "cancelExportPhotoVideo returned $cancelResult, expected true",
          );
        }

        try {
          final outcomePath = await exportCancelFuture;
          if (outcomePath != null) {
            final outcomeFile = File(outcomePath);
            createdCacheFiles.add(outcomeFile);
            if (await outcomeFile.exists() && await outcomeFile.length() > 0) {
              print(
                "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Export completed before cancel took effect (valid file at $outcomePath)",
              );
            }
          }
        } on PlatformException catch (pe) {
          if (pe.code == "EXPORT_CANCELLED") {
            print(
              "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Export successfully caught cancellation with EXPORT_CANCELLED",
            );
          } else {
            throw Exception(
              "Unexpected error on cancelled export: ${pe.code}: ${pe.message}",
            );
          }
        }

        // 8. Invalid non-content id still throws INVALID_ARGUMENT for thumbnail and export
        bool thumbInvalidThrows = false;
        try {
          await _rawChannel.invokeMethod<Uint8List>(
            "fetchPhotoVideoThumbnail",
            <String, dynamic>{
              "id": "file:///not/content/uri",
              "width": 240,
              "height": 135,
            },
          );
        } on PlatformException catch (pe) {
          if (pe.code == "INVALID_ARGUMENT") thumbInvalidThrows = true;
        }
        if (!thumbInvalidThrows) {
          throw Exception(
            "fetchPhotoVideoThumbnail with non-content URI did not throw INVALID_ARGUMENT",
          );
        }

        bool exportInvalidThrows = false;
        try {
          await _rawChannel.invokeMethod<String>(
            "exportPhotoVideo",
            <String, dynamic>{"id": "file:///not/content/uri"},
          );
        } on PlatformException catch (pe) {
          if (pe.code == "INVALID_ARGUMENT") exportInvalidThrows = true;
        }
        if (!exportInvalidThrows) {
          throw Exception(
            "exportPhotoVideo with non-content URI did not throw INVALID_ARGUMENT",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Invalid non-content id properly rejected with INVALID_ARGUMENT",
        );

        pass = true;
        print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_AUTHORIZED_PASS");
        print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_PHYSICAL_PASS");
      } else if (rawStatus == "limited") {
        // ── Phase C: Limited status phase ────────────────────────────────────
        print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Running Phase C (limited)");

        // 1. checkPhotoLibraryPermission returns limited
        if (rawStatus != "limited") {
          throw Exception("Expected limited, got $rawStatus");
        }

        // 2. fetchPhotoVideos(limit: 2) does not throw
        final List<dynamic>? limitedVideos = await _rawChannel
            .invokeListMethod<dynamic>("fetchPhotoVideos", <String, dynamic>{
              "limit": 2,
            });
        if (limitedVideos == null) {
          throw Exception("fetchPhotoVideos(limit: 2) returned null");
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: fetchPhotoVideos(limit: 2) succeeded under limited (count=${limitedVideos.length})",
        );

        // 3. cancelExportPhotoVideo for an unknown id returns true
        final bool? cancelRes = await _rawChannel.invokeMethod<bool>(
          "cancelExportPhotoVideo",
          <String, dynamic>{"id": "unknown_limited_id"},
        );
        if (cancelRes != true) {
          throw Exception(
            "cancelExportPhotoVideo for unknown ID expected true under limited, got $cancelRes",
          );
        }
        print(
          "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: cancelExportPhotoVideo returned true under limited",
        );

        // Note: Do not call presentLimitedLibraryPicker (avoids OS UI).
        pass = true;
        print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_LIMITED_STATUS_PASS");
      } else {
        throw Exception(
          "Unexpected permission status returned by checkPhotoLibraryPermission: $rawStatus",
        );
      }
    } catch (e, st) {
      pass = false;
      failureReason = "$e\n$st";
      print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: ERROR: $e");
      print(st);
      print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_PHYSICAL_FAIL");
    } finally {
      // Clean up staged fixture file
      if (stagedTempFile != null && await stagedTempFile.exists()) {
        try {
          await stagedTempFile.delete();
          print(
            "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Deleted staged fixture ${stagedTempFile.path}",
          );
        } catch (e) {
          print(
            "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Warning deleting staged fixture: $e",
          );
        }
      }
      // Clean up exported cache files
      for (final f in createdCacheFiles) {
        if (await f.exists()) {
          try {
            await f.delete();
            print(
              "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Deleted exported cache file ${f.path}",
            );
          } catch (e) {
            print(
              "ANDROID_VIDEO_ASSET_PICKER_UNIT_AB: Warning deleting exported cache file: $e",
            );
          }
        }
      }
    }

    final payload = <String, dynamic>{
      "unit": "Phase5UnitAB_Phase10FSlice2B_UMFV2Slice2B",
      "target": "android_video_asset_picker_unit_ab_physical_smoke",
      "pass": pass,
      "status": currentPermissionStatus,
      "error": failureReason,
      "log": resultsLog,
    };
    print("ANDROID_VIDEO_ASSET_PICKER_UNIT_AB_JSON:${jsonEncode(payload)}");

    if (mounted) {
      setState(() {
        _status = pass ? "PASS ($currentPermissionStatus)" : "FAIL";
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(pass ? 0 : 1);
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
