// android_greenscreen_production_export_physical_smoke.dart
// Vanguard Media Engine — ANDROID-GREENSCREEN-PRODUCTION-EXPORT: diagnostic-only
// physical proof of the generic Android green-screen export engine
// (AndroidGreenScreenExportEngine) on unequal input timing. The native harness
// generates two deterministic fixture clips (background faster than the output
// clock, foreground slower and shorter), exports through the engine on a fixed
// output clock with a procedural R8 mask ladder, decodes the produced MP4, and
// asserts per-frame center pixels plus hold/drop telemetry and tmp cleanup.
//
// The engine is caller-agnostic (Duet, live meeting/calling, going live,
// camera). Never touches Duet sessions, ConnectsApp, or the Universal Editor.
//
// Dart responsibilities:
//   - Create a unique output path under Directory.systemTemp.
//   - Invoke MethodChannel('vanguard_media_engine').invokeMethod(
//       'runAndroidGreenScreenProductionExportSmoke',
//       {'outputPath': outputPath, 'width': 360, 'height': 640},
//     )
//   - Print ANDROID_GREENSCREEN_PRODUCTION_EXPORT_SMOKE_START
//   - Print ANDROID_GREENSCREEN_PRODUCTION_EXPORT_JSON:<json>
//   - Print ANDROID_GREENSCREEN_PRODUCTION_EXPORT_PHYSICAL_PASS or ..._PHYSICAL_FAIL
//
// Claims: generic_green_screen_export_engine_boundary,
// fixed_output_clock_two_input_frame_pairing, input_eos_hold_last_frame_telemetry,
// superseded_input_frame_drop_telemetry, deterministic_decoded_pixel_mp4_proof,
// rendered_equals_written_samples, clean_tmp_cleanup.
//
// Non-claims: no live camera, no ML matte, no GPU-resident mask path, no audio,
// no A/V sync, no realtime clock, no production Duet wiring, no ConnectsApp or
// Universal Editor wiring, fixed offline frame clock only.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _startMarker = 'ANDROID_GREENSCREEN_PRODUCTION_EXPORT_SMOKE_START';
const String _jsonPrefix = 'ANDROID_GREENSCREEN_PRODUCTION_EXPORT_JSON:';
const String _passMarker = 'ANDROID_GREENSCREEN_PRODUCTION_EXPORT_PHYSICAL_PASS';
const String _failMarker = 'ANDROID_GREENSCREEN_PRODUCTION_EXPORT_PHYSICAL_FAIL';
const String _errorPrefix = 'ANDROID_GREENSCREEN_PRODUCTION_EXPORT_ERROR: ';

void main() {
  runApp(const AndroidGreenScreenProductionExportSmokeApp());
}

class AndroidGreenScreenProductionExportSmokeApp extends StatefulWidget {
  const AndroidGreenScreenProductionExportSmokeApp({super.key});

  @override
  State<AndroidGreenScreenProductionExportSmokeApp> createState() =>
      _AndroidGreenScreenProductionExportSmokeAppState();
}

class _AndroidGreenScreenProductionExportSmokeAppState
    extends State<AndroidGreenScreenProductionExportSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android green-screen production export smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(_startMarker);

    Map<String, dynamic> payload;
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath =
        '${tempDir.path}/greenscreen_production_export_$timestamp.mp4';

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidGreenScreenProductionExportSmoke',
        <String, Object>{'outputPath': outputPath, 'width': 360, 'height': 640},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print('$_errorPrefix$error\n$stack');
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception:$error',
        'proofBoundary':
            'android_greenscreen_export_engine_unequal_input_timing_decoded_pixel_proof',
        'outputPath': outputPath,
        'outputSize': 0,
        'tmpExists': false,
        'renderedFrames': 0,
        'writtenVideoSamples': 0,
        'renderedEqualsWritten': false,
        'backgroundDroppedFrames': 0,
        'foregroundHeldFrames': 0,
        'perFramePixelResults': <dynamic>[],
      };
    }

    final pass = payload['pass'] == true;
    final outputPathReported = payload['outputPath'] as String? ?? outputPath;

    // Best-effort cleanup of any lingering output/tmp file on failure; the
    // native engine already handles its own atomic .tmp write / rename /
    // delete, this is just defense-in-depth for the Dart-visible path.
    if (!pass) {
      for (final candidate in <String>[
        outputPathReported,
        '$outputPath.tmp',
        outputPath,
      ]) {
        try {
          final f = File(candidate);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }

    print('$_jsonPrefix${jsonEncode(payload)}');
    print(pass ? _passMarker : _failMarker);

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS\nPath: $outputPathReported\n'
                  'renderedFrames=${payload['renderedFrames']} '
                  'writtenVideoSamples=${payload['writtenVideoSamples']}\n'
                  'backgroundDroppedFrames=${payload['backgroundDroppedFrames']} '
                  'foregroundHeldFrames=${payload['foregroundHeldFrames']}'
            : 'FAIL: ${payload['reason']}';
      });
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
