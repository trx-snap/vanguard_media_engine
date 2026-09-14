// android_duet_vulkan_greenscreen_export_pixel_proof_physical_smoke.dart
// Vanguard Media Engine — ANDROID-DUET-VULKAN-GREENSCREEN-EXPORT-PIXEL-PROOF:
// diagnostic-only physical proof that the EXISTING Android Vulkan export
// session (android_vulkan_export_jni.cpp's VulkanExportSession registry) can
// render Duet green-screen composition frames into a MediaCodec encoder
// surface, using deterministic background/camera HardwareBuffers plus an
// uploaded R8 alpha mask, then decode the produced MP4 and assert pixels.
//
// Never touches AndroidDuetExportSession or the production Duet preview
// session, never creates a second swapchain owner, and never wires into
// ConnectsApp/Universal Editor.
//
// Dart responsibilities:
//   - Create a unique output path under Directory.systemTemp.
//   - Invoke MethodChannel('vanguard_media_engine').invokeMethod(
//       'runAndroidDuetVulkanGreenScreenExportPixelProofSmoke',
//       {'outputPath': outputPath, 'width': 360, 'height': 640},
//     )
//   - Print ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_SMOKE_START
//   - Print ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_JSON:<json>
//   - Print ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_PHYSICAL_PASS
//     or ..._PHYSICAL_FAIL
//
// Claims: existing_vulkan_export_session_green_screen_render_entrypoint,
// r8_mask_upload_entrypoint, deterministic_decoded_pixel_mp4_proof,
// rendered_equals_written_samples, clean_tmp_cleanup.
//
// Non-claims: no live camera, no ML matte, no persisted camera/mask media,
// no audio, no A/V sync, no ConnectsApp or Universal Editor wiring, no
// static/image background export, synthetic RGBA imports only (external
// YCbCr camera sampling not covered), fixed offline frame clock only.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _startMarker =
    'ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_SMOKE_START';
const String _jsonPrefix =
    'ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_JSON:';
const String _passMarker =
    'ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_PHYSICAL_PASS';
const String _failMarker =
    'ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_PHYSICAL_FAIL';

void main() {
  runApp(const AndroidDuetVulkanGreenScreenExportPixelProofSmokeApp());
}

class AndroidDuetVulkanGreenScreenExportPixelProofSmokeApp
    extends StatefulWidget {
  const AndroidDuetVulkanGreenScreenExportPixelProofSmokeApp({super.key});

  @override
  State<AndroidDuetVulkanGreenScreenExportPixelProofSmokeApp> createState() =>
      _AndroidDuetVulkanGreenScreenExportPixelProofSmokeAppState();
}

class _AndroidDuetVulkanGreenScreenExportPixelProofSmokeAppState
    extends State<AndroidDuetVulkanGreenScreenExportPixelProofSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Initializing Android Duet Vulkan green-screen export pixel proof…';

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
        '${tempDir.path}/duet_vulkan_greenscreen_export_pixel_proof_$timestamp.mp4';

    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDuetVulkanGreenScreenExportPixelProofSmoke',
        <String, Object>{'outputPath': outputPath, 'width': 360, 'height': 640},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error, stack) {
      print(
        'ANDROID_DUET_VULKAN_GREENSCREEN_EXPORT_PIXEL_PROOF_ERROR: $error\n$stack',
      );
      payload = <String, dynamic>{
        'pass': false,
        'reason': 'dart_exception:$error',
        'proofBoundary':
            'android_duet_vulkan_export_session_greenscreen_render_entrypoint_deterministic_decoded_pixel_proof',
        'outputPath': outputPath,
        'outputSize': 0,
        'renderedFrames': 0,
        'writtenVideoSamples': 0,
        'renderedEqualsWritten': false,
        'negativeLanes': <String, dynamic>{},
        'perFramePixelResults': <dynamic>[],
        'interFrameVariationOk': false,
      };
    }

    final pass = payload['pass'] == true;
    final outputPathReported = payload['outputPath'] as String? ?? outputPath;

    // Best-effort cleanup of any lingering output/tmp file on failure; the
    // native harness already handles its own atomic .tmp write / rename /
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
                  'writtenVideoSamples=${payload['writtenVideoSamples']}'
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
