// Android True-DAG Pass-2 Audio Direct-Copy Failure Graceful Fallback smoke.
// Copies the clip_B.mov fixture to a temp file, then invokes the native
// runAndroidAudioDirectCopyFallbackSmoke route with sourcePath set to the
// copied fixture and outputDir set to the system temp directory. The native
// harness proves eligible direct-copy success, ineligible PCM mixdown
// success, a forced first direct-copy remux failure recovered via PCM
// mixdown fallback, and the empty-sidecar video-only remux path.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidAudioDirectCopyFallbackSmokeApp());
}

class AndroidAudioDirectCopyFallbackSmokeApp extends StatefulWidget {
  const AndroidAudioDirectCopyFallbackSmokeApp({super.key});

  @override
  State<AndroidAudioDirectCopyFallbackSmokeApp> createState() =>
      _AndroidAudioDirectCopyFallbackSmokeAppState();
}

class _AndroidAudioDirectCopyFallbackSmokeAppState
    extends State<AndroidAudioDirectCopyFallbackSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android Audio Direct-Copy Fallback Smoke...';

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
      fixtureFile = File(
        '${tempDir.path}/audio_direct_copy_fallback_smoke_clip_b.mov',
      );
      await fixtureFile.writeAsBytes(
        clipBytes.buffer.asUint8List(
          clipBytes.offsetInBytes,
          clipBytes.lengthInBytes,
        ),
        flush: true,
      );

      final response = await _channel.invokeMethod<Object?>(
        'runAndroidAudioDirectCopyFallbackSmoke',
        <String, Object>{
          'sourcePath': fixtureFile.path,
          'outputDir': tempDir.path,
        },
      );
      resultMap = _deepStringKeyed(response! as Map);

      final forcedFallbackLane =
          resultMap['forcedDirectCopyFailureRecovery'] as Map<String, dynamic>?;
      final recoveredViaMixdown =
          forcedFallbackLane?['recoveredViaMixdown'] == true;

      pass = resultMap['pass'] == true && recoveredViaMixdown;
    } catch (e, st) {
      print('ANDROID_AUDIO_DIRECT_COPY_FALLBACK_SMOKE: ERROR: $e\n$st');
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
      'unit': 'AndroidAudioDirectCopyFallback',
      'target': 'android_physical',
      'pass': pass,
      'result': resultMap,
      'nonClaims': const <String>[
        'no production exportTimeline',
        'no UI/editor wiring',
        'no ConnectsApp touched',
      ],
    };

    print('ANDROID_AUDIO_DIRECT_COPY_FALLBACK_JSON:${jsonEncode(payload)}');
    print(
      pass
          ? 'ANDROID_AUDIO_DIRECT_COPY_FALLBACK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_AUDIO_DIRECT_COPY_FALLBACK_PHYSICAL_SMOKE_FAIL',
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
