// android_stream_source_node_physical_smoke.dart
// Vanguard Media Engine -- P6-STREAM-SOURCE-NODE-A
// Physical smoke test for platform-neutral StreamSourceNode logical DAG source.
// Diagnostic-only: no Path A Media3/ExoPlayer or Path B WebRTC/LiveKit
// session, no RealtimeOutputAdapter egress, no decoder/frame buffer
// ownership, no rendering, no product/editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_stream_source_node_smoke.dart';

void main() {
  runApp(const AndroidStreamSourceNodePhysicalSmokeApp());
}

class AndroidStreamSourceNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamSourceNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamSourceNodePhysicalSmokeApp> createState() =>
      _AndroidStreamSourceNodePhysicalSmokeAppState();
}

class _AndroidStreamSourceNodePhysicalSmokeAppState
    extends State<AndroidStreamSourceNodePhysicalSmokeApp> {
  String _status = 'Running StreamSourceNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kStreamSourceNodeStartMarker);

    VGStreamSourceNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGStreamSourceNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGStreamSourceNodeSmokeRunner',
      'slice': 'P6-STREAM-SOURCE-NODE-A',
      'proofBoundary': kStreamSourceNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kStreamSourceNodeJsonPrefix${jsonEncode(payload)}');
    print(pass ? kStreamSourceNodePassMarker : kStreamSourceNodeFailMarker);

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
