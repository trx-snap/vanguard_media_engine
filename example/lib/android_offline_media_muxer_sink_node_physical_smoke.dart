// android_offline_media_muxer_sink_node_physical_smoke.dart
// Vanguard Media Engine -- P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A
// Physical smoke test for platform-neutral OfflineMediaMuxerSinkNode logical
// DAG sink. Diagnostic-only: no android.media.MediaMuxer/MediaCodec/
// PlatformCodecAdapter ownership, no file IO, no rendering, no product/
// editor code.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_offline_media_muxer_sink_node_smoke.dart';

void main() {
  runApp(const AndroidOfflineMediaMuxerSinkNodePhysicalSmokeApp());
}

class AndroidOfflineMediaMuxerSinkNodePhysicalSmokeApp extends StatefulWidget {
  const AndroidOfflineMediaMuxerSinkNodePhysicalSmokeApp({super.key});

  @override
  State<AndroidOfflineMediaMuxerSinkNodePhysicalSmokeApp> createState() =>
      _AndroidOfflineMediaMuxerSinkNodePhysicalSmokeAppState();
}

class _AndroidOfflineMediaMuxerSinkNodePhysicalSmokeAppState
    extends State<AndroidOfflineMediaMuxerSinkNodePhysicalSmokeApp> {
  String _status = 'Running OfflineMediaMuxerSinkNode physical smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(kOfflineMediaMuxerSinkNodeStartMarker);

    VGOfflineMediaMuxerSinkNodeSmokeReport? report;
    String? topLevelError;

    try {
      const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner();
      report = await runner.runSmoke();
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('SMOKE_ERROR: $topLevelError');
    }

    final pass = (topLevelError == null) && (report?.pass == true);

    final payload = <String, dynamic>{
      'unit': 'VGOfflineMediaMuxerSinkNodeSmokeRunner',
      'slice': 'P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A',
      'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
      'pass': pass,
      'report': report?.toMap(),
      'error': topLevelError,
    };

    print('$kOfflineMediaMuxerSinkNodeJsonPrefix${jsonEncode(payload)}');
    print(
      pass
          ? kOfflineMediaMuxerSinkNodePassMarker
          : kOfflineMediaMuxerSinkNodeFailMarker,
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
