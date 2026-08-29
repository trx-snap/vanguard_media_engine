// android_gles_export_90_270_fit_geometry_smoke.dart
// Vanguard Media Engine — Android GLES fallback 90/270 non-square fit geometry parity physical proof.
//
// Proof boundary: gles_fallback_export_90_270_fit_geometry_oracle
// Cases tested:
//   1. rot90_pillarbox:  640x360  rot90  -> 1280x720 canvas (expected fit ~405x720)
//   2. rot270_pillarbox: 640x360  rot270 -> 1280x720 canvas (expected fit ~405x720)
//   3. rot90_letterbox:  360x1280 rot90  -> 1280x720 canvas (expected fit 1280x360)

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesExportFitGeometrySmokeApp());
}

class AndroidGlesExportFitGeometrySmokeApp extends StatefulWidget {
  const AndroidGlesExportFitGeometrySmokeApp({super.key});

  @override
  State<AndroidGlesExportFitGeometrySmokeApp> createState() =>
      _AndroidGlesExportFitGeometrySmokeAppState();
}

class _AndroidGlesExportFitGeometrySmokeAppState
    extends State<AndroidGlesExportFitGeometrySmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES export 90/270 fit geometry physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_GLES_EXPORT_90_270_FIT_GEOMETRY_SMOKE: START');
    Map<String, dynamic> payload;

    try {
      final tempDir = Directory.systemTemp;
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidGlesExportFitGeometrySmoke',
        <String, Object>{
          'outputDir': tempDir.path,
          'fps': 30,
          'bitrateBps': 4000000,
        },
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('ANDROID_GLES_EXPORT_90_270_FIT_GEOMETRY_ERROR: $error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception: $error',
        'proofBoundary': 'gles_fallback_export_90_270_fit_geometry_oracle',
        'caseResults': <Map<String, dynamic>>[],
        'allCasesPass': false,
        'glesOnly': true,
        'vulkanSkipped': true,
        'caseCount': 0,
      };
    }

    final passFlag = payload['pass'] == true;
    final allCasesPassFlag = payload['allCasesPass'] == true;
    final proofBoundaryMatch =
        payload['proofBoundary'] ==
        'gles_fallback_export_90_270_fit_geometry_oracle';
    final glesOnly = payload['glesOnly'] == true;
    final vulkanSkipped = payload['vulkanSkipped'] == true;
    final caseCount = (payload['caseCount'] as num?)?.toInt() ?? 0;
    final rawCaseResults = (payload['caseResults'] as List?) ?? <dynamic>[];

    var casesAllValid = (caseCount == 3 && rawCaseResults.length == 3);
    final caseSummaries = <String>[];

    for (final rawCase in rawCaseResults) {
      if (rawCase is! Map) {
        casesAllValid = false;
        continue;
      }
      final c = Map<String, dynamic>.from(rawCase);
      final cName = c['caseName'] as String? ?? 'unknown';
      final cPass = c['casePass'] == true;
      final srcSize = (c['sourceSize'] as num?)?.toInt() ?? 0;
      final outSize = (c['outputSize'] as num?)?.toInt() ?? 0;
      final samples = (c['writtenVideoSamples'] as num?)?.toInt() ?? 0;
      final outW = (c['outputWidth'] as num?)?.toInt() ?? 0;
      final outH = (c['outputHeight'] as num?)?.toInt() ?? 0;
      final nonBlank = c['nonBlank'] == true;
      final fitPass = c['fitRegionOraclePass'] == true;
      final barPass = c['blackBarOraclePass'] == true;
      final edgePass = c['edgeScanPass'] == true;
      final encReason = c['encoderReason'] as String? ?? '';

      final validCase =
          cPass &&
          srcSize > 0 &&
          outSize > 0 &&
          samples > 0 &&
          outW == 1280 &&
          outH == 720 &&
          nonBlank &&
          fitPass &&
          barPass &&
          edgePass &&
          encReason == 'success';

      if (!validCase) {
        casesAllValid = false;
      }

      caseSummaries.add(
        '$cName: pass=$cPass fit=$fitPass bar=$barPass edge=$edgePass '
        'dims=${outW}x$outH samples=$samples outSize=$outSize',
      );
    }

    final pass =
        passFlag &&
        allCasesPassFlag &&
        proofBoundaryMatch &&
        glesOnly &&
        vulkanSkipped &&
        casesAllValid;

    print(
      'ANDROID_GLES_EXPORT_90_270_FIT_GEOMETRY_JSON:${jsonEncode(payload)}',
    );
    print(
      pass
          ? 'ANDROID_GLES_EXPORT_90_270_FIT_GEOMETRY_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_GLES_EXPORT_90_270_FIT_GEOMETRY_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        if (pass) {
          _status =
              'PASS\nBoundary: ${payload['proofBoundary']}\nCases: ${caseSummaries.join('\n')}';
        } else {
          _status =
              'FAIL: ${payload['reason']} (passFlag=$passFlag, allCasesPass=$allCasesPassFlag, boundaryMatch=$proofBoundaryMatch, casesAllValid=$casesAllValid)\n${caseSummaries.join('\n')}';
        }
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
