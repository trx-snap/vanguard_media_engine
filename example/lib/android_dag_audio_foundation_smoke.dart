// Android True-DAG Export/Audio Unit B: audio foundation physical smoke.
// Copies the clip_B.mov fixture to a temp file, then invokes the native
// runAndroidDagAudioFoundationSmoke route with videoPath/audioPath both set to
// the copied fixture and outputDir set to the system temp directory. The
// native harness proves both the direct-copy and PCM-mixdown scenarios.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidDagAudioFoundationSmokeApp());
}

class AndroidDagAudioFoundationSmokeApp extends StatefulWidget {
  const AndroidDagAudioFoundationSmokeApp({super.key});

  @override
  State<AndroidDagAudioFoundationSmokeApp> createState() =>
      _AndroidDagAudioFoundationSmokeAppState();
}

class _AndroidDagAudioFoundationSmokeAppState
    extends State<AndroidDagAudioFoundationSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android DAG Audio Foundation Smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> resultMap;
    var pass = false;
    File? fixtureFile;
    try {
      final clipBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      final tempDir = Directory.systemTemp;
      fixtureFile = File('${tempDir.path}/audio_foundation_unit_b_clip_b.mov');
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagAudioFoundationSmoke',
        <String, Object>{
          'videoPath': fixtureFile.path,
          'audioPath': fixtureFile.path,
          'outputDir': tempDir.path,
        },
      );
      resultMap = _deepStringKeyed(response! as Map);
      pass = resultMap['pass'] == true;
    } catch (e, st) {
      print('ANDROID_DAG_AUDIO_FOUNDATION_SMOKE: ERROR: $e\n$st');
      resultMap = <String, dynamic>{'pass': false, 'error': '$e'};
      pass = false;
    } finally {
      if (fixtureFile != null) {
        try {
          if (await fixtureFile.exists()) {
            await fixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'ExportAudioUnitB',
      'target': 'android_physical',
      'pass': pass,
      'result': resultMap,
      'nonClaims': const <String>[
        'no production exportTimeline',
        'no UI/editor wiring',
        'no ConnectsApp touched',
      ],
    };

    print('ANDROID_DAG_AUDIO_FOUNDATION_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_DAG_AUDIO_FOUNDATION_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_AUDIO_FOUNDATION_PHYSICAL_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass ? 'PASS' : 'FAIL';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(pass ? 0 : 1);
  }

  /// Recursively converts platform maps to string-keyed maps so the payload
  /// is JSON-encodable.
  Map<String, dynamic> _deepStringKeyed(Map<Object?, Object?> map) {
    final out = <String, dynamic>{};
    map.forEach((key, value) {
      out['$key'] = value is Map<Object?, Object?>
          ? _deepStringKeyed(value)
          : value;
    });
    return out;
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
