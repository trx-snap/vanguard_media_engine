// android_timeline_overlay_text_rasterizer_physical_smoke.dart
// Vanguard Media Engine — P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC:
// Android True-DAG AndroidTimelineOverlayTextRasterizer helper proof
// diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report validationPass == true (blank overlay id, blank text,
//           zero/negative dimensions, NaN width, oversized dimensions fail closed).
//   Lane 2: smoke report backgroundPass == true (rasterize 320x96 with background
//           box, rowStride 1280, direct buffer 122880, nonZeroAlpha > 0, whiteLike > 0).
//   Lane 3: smoke report transparentPass == true (rasterize 320x96 with transparent
//           background, direct buffer, corner alpha 0 or transparent pixels > 0, whiteLike > 0).
//   Lane 4: smoke report packingPass == true (direct native-order buffer, RGBA byte
//           order sanity from white text and black background, zero position drift).
//   Lane 5: smoke report isPass == true && allNativeLanesPass == nativeAllLanesPass
//           && canonical && canonical PASS marker && canonical proof boundary &&
//           toMap() round-trips.
//
// Target / proof boundary:
//   android_kotlin_text_overlay_rasterizer_rgba_buffer_diagnostic_only_no_export_no_native_no_jni_no_product
//   Kotlin text overlay rasterizer helper only. No export session wiring, no
//   native C++, no JNI, and no product/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_text_rasterizer_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER';

void main() {
  runApp(const AndroidTimelineOverlayTextRasterizerPhysicalSmokeApp());
}

class AndroidTimelineOverlayTextRasterizerPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidTimelineOverlayTextRasterizerPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineOverlayTextRasterizerPhysicalSmokeApp> createState() =>
      _AndroidTimelineOverlayTextRasterizerPhysicalSmokeAppState();
}

class _AndroidTimelineOverlayTextRasterizerPhysicalSmokeAppState
    extends State<AndroidTimelineOverlayTextRasterizerPhysicalSmokeApp> {
  String _status =
      'Initializing AndroidTimelineOverlayTextRasterizer Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    VGTimelineOverlayTextRasterizerSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;

    try {
      report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      lane1Pass = report.validationPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass validationPass=${report.validationPass} '
        'status=${report.status} failureReason=${report.failureReason} '
        'validationErrorsChecked=${report.details['validationErrorsChecked']} '
        'validationErrorsFound=${report.details['validationErrorsFound']}',
      );

      lane2Pass = report.backgroundPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass backgroundPass=${report.backgroundPass} '
        'bgWidth=${report.details['bgWidth']} '
        'bgHeight=${report.details['bgHeight']} '
        'bgRowStrideBytes=${report.details['bgRowStrideBytes']} '
        'bgCapacity=${report.details['bgCapacity']} '
        'bgNonZeroAlphaPixels=${report.details['bgNonZeroAlphaPixels']} '
        'bgWhiteLikePixels=${report.details['bgWhiteLikePixels']} '
        'bgBlackBackgroundPixels=${report.details['bgBlackBackgroundPixels']}',
      );

      lane3Pass = report.transparentPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass transparentPass=${report.transparentPass} '
        'transCornerAlpha=${report.details['transCornerAlpha']} '
        'transTransparentAlphaPixels=${report.details['transTransparentAlphaPixels']} '
        'transWhiteLikePixels=${report.details['transWhiteLikePixels']}',
      );

      lane4Pass = report.packingPass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass packingPass=${report.packingPass} '
        'bgBufferDirect=${report.details['bgBufferDirect']} '
        'transBufferDirect=${report.details['transBufferDirect']} '
        'bgBufferOrder=${report.details['bgBufferOrder']} '
        'bgBufferPosition=${report.details['bgBufferPosition']} '
        'transBufferPosition=${report.details['transBufferPosition']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineOverlayTextRasterizerSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane5Pass =
          report.isPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.canonical &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass isPass=${report.isPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'canonical=${report.canonical} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: text overlay rasterizer smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidTimelineOverlayTextRasterizerSmokeHarness',
        'slice': 'P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC',
        'target':
            VGTimelineOverlayTextRasterizerSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_validation': {
            'pass': lane1Pass,
            'validationPass': report?.validationPass,
          },
          'lane2_background': {
            'pass': lane2Pass,
            'backgroundPass': report?.backgroundPass,
          },
          'lane3_transparent': {
            'pass': lane3Pass,
            'transparentPass': report?.transparentPass,
          },
          'lane4_packing': {
            'pass': lane4Pass,
            'packingPass': report?.packingPass,
          },
          'lane5_telemetry': {
            'pass': lane5Pass,
            'isPass': report?.isPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
            'canonical': report?.canonical,
            'marker': report?.marker,
            'proofBoundary': report?.proofBoundary,
          },
        },
        'smokeReport': report?.toMap(),
        'error': topLevelError,
      };

      print('${_logPrefix}_JSON:${jsonEncode(payload)}');
      print(allPass ? _passMarker : _failMarker);

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
