// android_image_optimizer_sink_node_physical_smoke.dart
// Vanguard Media Engine -- P5-IMAGE-OPTIMIZER-SINK-NODE-A
// Physical smoke test for platform-neutral ImageOptimizerSinkNode logical
// DAG sink node. Diagnostic-only: no decoded pixels, Bitmap/ImageDecoder
// lifecycle, JPEG/PNG/HEIC encoder lifecycle, output file/path/fd, GPU
// texture/sampler/lifecycle, Android lifecycle, or product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_image_optimizer_sink_node_smoke.dart';

void main() {
  runApp(const AndroidImageOptimizerSinkNodePhysicalSmokeApp());
}

class AndroidImageOptimizerSinkNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidImageOptimizerSinkNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidImageOptimizerSinkNodePhysicalSmokeApp> createState() =>
      _AndroidImageOptimizerSinkNodePhysicalSmokeAppState();
}

class _AndroidImageOptimizerSinkNodePhysicalSmokeAppState
    extends State<AndroidImageOptimizerSinkNodePhysicalSmokeApp> {
  String _status = 'Running ImageOptimizerSinkNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kImageOptimizerSinkNodeStartMarker);

    VGImageOptimizerSinkNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGImageOptimizerSinkNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGImageOptimizerSinkNodeSmokeRunner',
      'slice': 'P5-IMAGE-OPTIMIZER-SINK-NODE-A',
      'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kImageOptimizerSinkNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kImageOptimizerSinkNodePassMarker
          : kImageOptimizerSinkNodeFailMarker,
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL: $topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
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
