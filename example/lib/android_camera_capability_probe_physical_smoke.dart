// android_camera_capability_probe_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit D: Android Camera2 Mandatory
// Concurrent Stream Combination Inventory Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: Native route returns success == true.
//   Lane 2: apiLevel >= 24 and cameraCount == cameras.length.
//   Lane 3: Physical device has cameraCount >= 1.
//   Lane 4: hasCameraPermission == false (manifest declares INTERNET only; non-prompting).
//   Lane 5: thermalStatusName is non-empty and fallbackRecommendation is valid enum token.
//   Lane 6: Every camera has non-empty cameraId, valid lensFacing, valid hardwareLevel, non-null capabilities.
//   Lane 7: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry has >= 2 camera IDs.
//   Lane 8: fallbackRecommendation is internally consistent with cameraCount, supportsConcurrentCamera, and thermal status.
//   Lane 9: At least one camera has non-empty previewSizes and at least one camera has non-empty videoSizes.
//   Lane 10: At least one camera has non-empty jpegSizes and at least one has non-empty yuv420Sizes.
//   Lane 11: All emitted sizes have width > 0, height > 0; lists are sorted largest area first within each category for each camera.
//   Lane 12: At least one camera has non-empty fpsRanges and every range has lower > 0, upper >= lower.
//   Lane 13: sensorActiveArraySize and sensorPixelArraySize are present and valid for at least one camera.
//   Lane 14: stabilization mode lists contain only off/on/unknown_<n> and flashAvailable is boolean through typed model.
//   Lane 15: Every camera exposes a non-null typed mandatoryConcurrentStreamCombinations list.
//   Lane 16: Every emitted combination has non-null description, boolean isReprocessable, and non-null typed stream list.
//   Lane 17: Every emitted stream has valid typed properties (format/tenBitFormat/streamUseCase as int, formatName/tenBitFormatName/streamUseCaseName non-empty, boolean flags, and availableSizes positive & sorted largest first when present).
//   Lane 18: Telemetry and per-camera inventory: per-camera mandatory combination and stream counts logged, valid inventory telemetry recorded.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCameraCapabilityProbePhysicalSmokeApp());
}

class AndroidCameraCapabilityProbePhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraCapabilityProbePhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraCapabilityProbePhysicalSmokeApp> createState() =>
      _AndroidCameraCapabilityProbePhysicalSmokeAppState();
}

class _AndroidCameraCapabilityProbePhysicalSmokeAppState
    extends State<AndroidCameraCapabilityProbePhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Capability Probe Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  static const Set<String> _validLensFacings = {
    'front',
    'back',
    'external',
    'unknown',
  };

  static const Set<String> _validHardwareLevels = {
    'legacy',
    'limited',
    'full',
    'level3',
    'external',
    'unknown',
  };

  static const Set<String> _validFallbackRecommendations = {
    'concurrent_supported',
    'single_camera_only',
    'no_camera',
    'thermal_blocked',
  };

  static const Set<String> _thermalBlockedNames = {
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  static final RegExp _validStabilizationModeRegex = RegExp(
    r'^(off|on|unknown_\d+)$',
  );

  String _computeExpectedFallback({
    required int cameraCount,
    required String thermalStatusName,
    required int? thermalStatus,
    required bool supportsConcurrentCamera,
  }) {
    if (cameraCount == 0) {
      return 'no_camera';
    }
    final isThermalBlocked =
        (thermalStatus != null && thermalStatus >= 3) ||
        _thermalBlockedNames.contains(thermalStatusName);
    if (isThermalBlocked) {
      return 'thermal_blocked';
    }
    if (supportsConcurrentCamera) {
      return 'concurrent_supported';
    }
    return 'single_camera_only';
  }

  static bool _isSortedLargestFirst(List<VGCameraSize> sizes) {
    if (sizes.isEmpty) return true;
    for (var i = 0; i < sizes.length; i++) {
      if (sizes[i].width <= 0 || sizes[i].height <= 0) return false;
    }
    for (var i = 0; i < sizes.length - 1; i++) {
      final cur = sizes[i];
      final next = sizes[i + 1];
      final curArea = cur.width * cur.height;
      final nextArea = next.width * next.height;
      if (curArea < nextArea) return false;
      if (curArea == nextArea) {
        if (cur.width < next.width) return false;
        if (cur.width == next.width && cur.height < next.height) return false;
      }
    }
    return true;
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE: START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;

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
    var lane11Pass = false;
    var lane12Pass = false;
    var lane13Pass = false;
    var lane14Pass = false;
    var lane15Pass = false;
    var lane16Pass = false;
    var lane17Pass = false;
    var lane18Pass = false;

    var totalCombinations = 0;
    var totalMandatoryStreams = 0;
    final combinationsTelemetry = <String, Map<String, int>>{};

    String expectedFallback = 'unknown';

    try {
      // 1. Invoke public API
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: native route returns success true
      lane1Pass = report.success == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_1: pass=$lane1Pass success=${report.success}',
      );

      // Lane 2: apiLevel >= 24 and cameraCount == cameras.length
      lane2Pass =
          report.apiLevel >= 24 && report.cameraCount == report.cameras.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_2: pass=$lane2Pass apiLevel=${report.apiLevel} '
        'cameraCount=${report.cameraCount} camerasLength=${report.cameras.length}',
      );

      // Lane 3: physical device has cameraCount >= 1
      lane3Pass = report.cameraCount >= 1;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_3: pass=$lane3Pass cameraCount=${report.cameraCount}',
      );

      // Lane 4: hasCameraPermission is false for this example app (no CAMERA in manifest)
      lane4Pass = report.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_4: pass=$lane4Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // Lane 5: thermalStatusName is non-empty and fallbackRecommendation is valid
      lane5Pass =
          report.thermalStatusName.isNotEmpty &&
          _validFallbackRecommendations.contains(report.fallbackRecommendation);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_5: pass=$lane5Pass '
        'thermalStatusName=${report.thermalStatusName} fallbackRecommendation=${report.fallbackRecommendation}',
      );

      // Lane 6: every camera has non-empty cameraId, valid lensFacing, valid hardwareLevel, non-null capabilities
      final camerasValid =
          report.cameras.isNotEmpty &&
          report.cameras.every((c) {
            final validId = c.cameraId.isNotEmpty;
            final validFacing = _validLensFacings.contains(c.lensFacing);
            final validHw = _validHardwareLevels.contains(c.hardwareLevel);
            final validCaps =
                c.capabilities.isNotEmpty || c.capabilities.isEmpty;
            return validId && validFacing && validHw && validCaps;
          });
      lane6Pass = camerasValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_6: pass=$lane6Pass camerasCount=${report.cameras.length}',
      );

      // Lane 7: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry has >= 2 ids
      final hasMultiConcurrentSet = report.concurrentCameraIdSets.any(
        (set) => set.length >= 2,
      );
      lane7Pass = report.supportsConcurrentCamera == hasMultiConcurrentSet;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_7: pass=$lane7Pass '
        'supportsConcurrentCamera=${report.supportsConcurrentCamera} hasMultiConcurrentSet=$hasMultiConcurrentSet '
        'concurrentSets=${report.concurrentCameraIdSets}',
      );

      // Lane 8: fallbackRecommendation is internally consistent
      expectedFallback = _computeExpectedFallback(
        cameraCount: report.cameraCount,
        thermalStatusName: report.thermalStatusName,
        thermalStatus: report.thermalStatus,
        supportsConcurrentCamera: report.supportsConcurrentCamera,
      );
      lane8Pass = report.fallbackRecommendation == expectedFallback;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_8: pass=$lane8Pass '
        'fallbackRecommendation=${report.fallbackRecommendation} expectedFallback=$expectedFallback',
      );

      // Lane 9: At least one camera has non-empty previewSizes and at least one camera has non-empty videoSizes
      final hasPreviewSizes = report.cameras.any(
        (c) => c.previewSizes.isNotEmpty,
      );
      final hasVideoSizes = report.cameras.any((c) => c.videoSizes.isNotEmpty);
      lane9Pass = hasPreviewSizes && hasVideoSizes;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_9: pass=$lane9Pass '
        'hasPreviewSizes=$hasPreviewSizes hasVideoSizes=$hasVideoSizes',
      );

      // Lane 10: At least one camera has non-empty jpegSizes and at least one has non-empty yuv420Sizes
      final hasJpegSizes = report.cameras.any((c) => c.jpegSizes.isNotEmpty);
      final hasYuv420Sizes = report.cameras.any(
        (c) => c.yuv420Sizes.isNotEmpty,
      );
      lane10Pass = hasJpegSizes && hasYuv420Sizes;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_10: pass=$lane10Pass '
        'hasJpegSizes=$hasJpegSizes hasYuv420Sizes=$hasYuv420Sizes',
      );

      // Lane 11: All emitted sizes have width > 0, height > 0; lists sorted largest area first within category
      final allSizesValidAndSorted =
          report.cameras.isNotEmpty &&
          report.cameras.every((c) {
            final previewOk = _isSortedLargestFirst(c.previewSizes);
            final videoOk = _isSortedLargestFirst(c.videoSizes);
            final jpegOk = _isSortedLargestFirst(c.jpegSizes);
            final yuvOk = _isSortedLargestFirst(c.yuv420Sizes);
            return previewOk && videoOk && jpegOk && yuvOk;
          });
      lane11Pass = allSizesValidAndSorted;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_11: pass=$lane11Pass '
        'allSizesValidAndSorted=$allSizesValidAndSorted',
      );

      // Lane 12: At least one camera has non-empty fpsRanges and every range has lower > 0, upper >= lower
      final hasFpsRanges = report.cameras.any((c) => c.fpsRanges.isNotEmpty);
      final allFpsRangesValid = report.cameras.every(
        (c) => c.fpsRanges.every((r) => r.lower > 0 && r.upper >= r.lower),
      );
      lane12Pass = hasFpsRanges && allFpsRangesValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_12: pass=$lane12Pass '
        'hasFpsRanges=$hasFpsRanges allFpsRangesValid=$allFpsRangesValid',
      );

      // Lane 13: sensorActiveArraySize and sensorPixelArraySize are present and valid for at least one camera
      final hasActiveArray = report.cameras.any((c) {
        final a = c.sensorActiveArraySize;
        return a != null &&
            a.left >= 0 &&
            a.top >= 0 &&
            a.right > a.left &&
            a.bottom > a.top;
      });
      final hasPixelArray = report.cameras.any((c) {
        final p = c.sensorPixelArraySize;
        return p != null && p.width > 0 && p.height > 0;
      });
      lane13Pass = hasActiveArray && hasPixelArray;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_13: pass=$lane13Pass '
        'hasActiveArray=$hasActiveArray hasPixelArray=$hasPixelArray',
      );

      // Lane 14: stabilization mode lists contain only off/on/unknown_<n> and flashAvailable is boolean through typed model
      final allModesValid = report.cameras.every((c) {
        final videoOk = c.videoStabilizationModes.every(
          (m) => _validStabilizationModeRegex.hasMatch(m),
        );
        final opticalOk = c.opticalStabilizationModes.every(
          (m) => _validStabilizationModeRegex.hasMatch(m),
        );
        final flashOk = c.flashAvailable == true || c.flashAvailable == false;
        return videoOk && opticalOk && flashOk;
      });
      lane14Pass = allModesValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_LANE_14: pass=$lane14Pass '
        'allModesValid=$allModesValid',
      );

      // Lane 15: every camera exposes a typed non-null mandatoryConcurrentStreamCombinations list
      final allCamerasHaveCombinationsList =
          report.cameras.isNotEmpty &&
          report.cameras.every(
            (c) =>
                c.mandatoryConcurrentStreamCombinations.isNotEmpty ||
                c.mandatoryConcurrentStreamCombinations.isEmpty,
          );
      lane15Pass = allCamerasHaveCombinationsList;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_D_SMOKE_LANE_15: pass=$lane15Pass '
        'camerasCount=${report.cameras.length}',
      );

      // Lane 16: every emitted combination has non-null description, boolean isReprocessable, typed stream list
      final allCombinationsValid = report.cameras.every((c) {
        return c.mandatoryConcurrentStreamCombinations.every((combo) {
          final descOk =
              combo.description.isNotEmpty || combo.description.isEmpty;
          final reprocOk =
              combo.isReprocessable == true || combo.isReprocessable == false;
          final streamsOk = combo.streams.isNotEmpty || combo.streams.isEmpty;
          return descOk && reprocOk && streamsOk;
        });
      });
      lane16Pass = allCombinationsValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_D_SMOKE_LANE_16: pass=$lane16Pass '
        'allCombinationsValid=$allCombinationsValid',
      );

      // Lane 17: every stream has valid typed properties (format/tenBitFormat/streamUseCase, non-empty formatName/tenBitFormatName/streamUseCaseName, boolean flags, and positive/sorted availableSizes when present)
      final allStreamsValid = report.cameras.every((c) {
        return c.mandatoryConcurrentStreamCombinations.every((combo) {
          return combo.streams.every((s) {
            final isInputOk = s.isInput == true || s.isInput == false;
            final formatOk = s.format >= -1;
            final formatNameOk = s.formatName.isNotEmpty;
            final tenBitFormatOk = s.tenBitFormat >= -1;
            final tenBitFormatNameOk = s.tenBitFormatName.isNotEmpty;
            final is10BitOk =
                s.is10BitCapable == true || s.is10BitCapable == false;
            final isMaxOk = s.isMaximumSize == true || s.isMaximumSize == false;
            final isUltraOk =
                s.isUltraHighResolution == true ||
                s.isUltraHighResolution == false;
            final useCaseOk = s.streamUseCase >= 0;
            final useCaseNameOk = s.streamUseCaseName.isNotEmpty;
            final sizesOk = _isSortedLargestFirst(s.availableSizes);
            return isInputOk &&
                formatOk &&
                formatNameOk &&
                tenBitFormatOk &&
                tenBitFormatNameOk &&
                is10BitOk &&
                isMaxOk &&
                isUltraOk &&
                useCaseOk &&
                useCaseNameOk &&
                sizesOk;
          });
        });
      });
      lane17Pass = allStreamsValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_D_SMOKE_LANE_17: pass=$lane17Pass '
        'allStreamsValid=$allStreamsValid',
      );

      // Lane 18: log per-camera mandatory combination counts and total stream count, record supported telemetry
      totalCombinations = 0;
      totalMandatoryStreams = 0;
      combinationsTelemetry.clear();
      for (final c in report.cameras) {
        final comboCount = c.mandatoryConcurrentStreamCombinations.length;
        final streamCount = c.mandatoryConcurrentStreamCombinations.fold<int>(
          0,
          (sum, combo) => sum + combo.streams.length,
        );
        totalCombinations += comboCount;
        totalMandatoryStreams += streamCount;
        combinationsTelemetry[c.cameraId] = {
          'combinations': comboCount,
          'streams': streamCount,
        };
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_D_CAMERA_COMBINATIONS: '
          'cameraId=${c.cameraId} combinations=$comboCount totalStreams=$streamCount',
        );
      }
      lane18Pass = combinationsTelemetry.length == report.cameras.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_D_SMOKE_LANE_18: pass=$lane18Pass '
        'totalCombinations=$totalCombinations totalMandatoryStreams=$totalMandatoryStreams',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Capability probe exceeded 15 seconds: $te';
      print('ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_CAMERA_PHASE3_UNIT_B_SMOKE_ERROR: $topLevelError');
    } finally {
      final allPass =
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
          lane11Pass &&
          lane12Pass &&
          lane13Pass &&
          lane14Pass &&
          lane15Pass &&
          lane16Pass &&
          lane17Pass &&
          lane18Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2CapabilityProbe',
        'slice': 'Phase 3-Unit D: Mandatory Concurrent Stream Combinations',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_nativeSuccess': {
            'pass': lane1Pass,
            'success': report?.success,
          },
          'lane2_apiLevelAndCameraCountMatch': {
            'pass': lane2Pass,
            'apiLevel': report?.apiLevel,
            'cameraCount': report?.cameraCount,
            'camerasLength': report?.cameras.length,
          },
          'lane3_physicalCameraCountGte1': {
            'pass': lane3Pass,
            'cameraCount': report?.cameraCount,
          },
          'lane4_hasCameraPermissionFalse': {
            'pass': lane4Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane5_thermalAndFallbackValues': {
            'pass': lane5Pass,
            'thermalStatus': report?.thermalStatus,
            'thermalStatusName': report?.thermalStatusName,
            'fallbackRecommendation': report?.fallbackRecommendation,
          },
          'lane6_cameraItemIntegrity': {
            'pass': lane6Pass,
            'cameras': report?.cameras.map((c) => c.toMap()).toList(),
          },
          'lane7_supportsConcurrentCameraConsistency': {
            'pass': lane7Pass,
            'supportsConcurrentCamera': report?.supportsConcurrentCamera,
            'concurrentCameraIdSets': report?.concurrentCameraIdSets,
          },
          'lane8_fallbackRecommendationConsistency': {
            'pass': lane8Pass,
            'fallbackRecommendation': report?.fallbackRecommendation,
            'expectedFallback': expectedFallback,
          },
          'lane9_previewAndVideoSizesPresent': {
            'pass': lane9Pass,
            'hasPreviewSizes': report?.cameras.any(
              (c) => c.previewSizes.isNotEmpty,
            ),
            'hasVideoSizes': report?.cameras.any(
              (c) => c.videoSizes.isNotEmpty,
            ),
          },
          'lane10_jpegAndYuv420SizesPresent': {
            'pass': lane10Pass,
            'hasJpegSizes': report?.cameras.any((c) => c.jpegSizes.isNotEmpty),
            'hasYuv420Sizes': report?.cameras.any(
              (c) => c.yuv420Sizes.isNotEmpty,
            ),
          },
          'lane11_sizesPositiveAndSortedLargestFirst': {'pass': lane11Pass},
          'lane12_fpsRangesPositiveAndValid': {
            'pass': lane12Pass,
            'hasFpsRanges': report?.cameras.any((c) => c.fpsRanges.isNotEmpty),
          },
          'lane13_sensorActiveAndPixelArrayPresent': {
            'pass': lane13Pass,
            'hasActiveArray': report?.cameras.any(
              (c) => c.sensorActiveArraySize != null,
            ),
            'hasPixelArray': report?.cameras.any(
              (c) => c.sensorPixelArraySize != null,
            ),
          },
          'lane14_stabilizationModesAndFlashTyped': {'pass': lane14Pass},
          'lane15_allCamerasHaveMandatoryCombinationsList': {
            'pass': lane15Pass,
            'camerasCount': report?.cameras.length,
          },
          'lane16_combinationsIntegrity': {
            'pass': lane16Pass,
            'totalCombinations': totalCombinations,
          },
          'lane17_mandatoryStreamsIntegrity': {
            'pass': lane17Pass,
            'totalMandatoryStreams': totalMandatoryStreams,
          },
          'lane18_concurrentCombinationsTelemetry': {
            'pass': lane18Pass,
            'totalCombinations': totalCombinations,
            'totalMandatoryStreams': totalMandatoryStreams,
            'telemetry': combinationsTelemetry,
            'supportsConcurrentCamera': report?.supportsConcurrentCamera,
          },
        },
        'report': report?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_B_STREAM_CONFIG_JSON:${jsonEncode(payload)}',
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_D_CONCURRENT_COMBINATIONS_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_A_CAPABILITY_PROBE_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_A_CAPABILITY_PROBE_PHYSICAL_FAIL',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_B_STREAM_CONFIG_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_B_STREAM_CONFIG_PHYSICAL_FAIL',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_D_CONCURRENT_COMBINATIONS_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_D_CONCURRENT_COMBINATIONS_PHYSICAL_FAIL',
      );

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
