// android_image_texture_source_node_physical_smoke.dart
// Vanguard Media Engine -- P5-IMAGE-TEXTURE-SOURCE-NODE-A
// Physical smoke test for platform-neutral ImageTextureSourceNode logical
// DAG source. Diagnostic-only: no decoded pixels, GL/Vulkan texture
// handle/sampler, file IO, Android Bitmap/ImageDecoder/NDK decoder handle
// ownership, no rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_image_texture_source_node_smoke.dart';

void main() {
  runApp(const AndroidImageTextureSourceNodePhysicalSmokeApp());
}

class AndroidImageTextureSourceNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidImageTextureSourceNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidImageTextureSourceNodePhysicalSmokeApp> createState() =>
      _AndroidImageTextureSourceNodePhysicalSmokeAppState();
}

class _AndroidImageTextureSourceNodePhysicalSmokeAppState
    extends State<AndroidImageTextureSourceNodePhysicalSmokeApp> {
  String _status = 'Running ImageTextureSourceNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kImageTextureSourceNodeStartMarker);

    VGImageTextureSourceNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGImageTextureSourceNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGImageTextureSourceNodeSmokeRunner',
      'slice': 'P5-IMAGE-TEXTURE-SOURCE-NODE-A',
      'proofBoundary': kImageTextureSourceNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kImageTextureSourceNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kImageTextureSourceNodePassMarker
          : kImageTextureSourceNodeFailMarker,
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
