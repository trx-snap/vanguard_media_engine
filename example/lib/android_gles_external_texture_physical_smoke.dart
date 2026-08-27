import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesExternalTexturePhysicalSmokeApp());
}

class AndroidGlesExternalTexturePhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesExternalTexturePhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesExternalTexturePhysicalSmokeApp> createState() =>
      _AndroidGlesExternalTexturePhysicalSmokeAppState();
}

class _AndroidGlesExternalTexturePhysicalSmokeAppState
    extends State<AndroidGlesExternalTexturePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation Unit AR physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ARGlesExternalTextureSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'ycbcrAllocation': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'rgbaBufferDescribe': 'not_run',
        'rgbaBufferFormat': 0,
        'rgbaBufferUsage': 0,
        'ycbcrBufferDescribe': 'not_run',
        'ycbcrBufferFormat': 0,
        'ycbcrBufferUsage': 0,
        'ycbcrFormatIs420888': false,
        'initialize': 'not_run',
        'attach': 'not_run',
        'hasSurfaceAfterAttach': false,
        'surfaceKindAfterAttach': 'none',
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'ycbcrImport': 'not_run',
        'ycbcrHandle': 0,
        'ycbcrDescWidth': 0,
        'ycbcrDescHeight': 0,
        'ycbcrDescLayers': 0,
        'ycbcrDescFormat': 0,
        'ycbcrDescUsageSampled': false,
        'hasYcbcrAfterImport': false,
        'ycbcrTextureTarget': 0,
        'diagnosticRender': 'not_run',
        'diagnosticRenderLastError': '',
        'centerRead': 'not_run',
        'centerReadLastError': '',
        'renderFrame': 'not_run',
        'renderFrameLastError': '',
        'releaseYcbcr': 'not_run',
        'releaseYcbcrFence': -1,
        'hasYcbcrAfterRelease': false,
        'rgbaPostImport': 'not_run',
        'rgbaPostHandle': 0,
        'rgbaPostDescWidth': 0,
        'rgbaPostDescHeight': 0,
        'rgbaPostDescLayers': 0,
        'rgbaPostDescFormat': 0,
        'rgbaPostDescUsageSampled': false,
        'hasRgbaPostAfterImport': false,
        'rgbaPostTextureTarget': 0,
        'rgbaPostRelease': 'not_run',
        'rgbaPostReleaseFence': -1,
        'hasRgbaPostAfterRelease': false,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final ycbcrAllocation = (payload['ycbcrAllocation'] as String?) ?? '';
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final rgbaBufferDescribe = (payload['rgbaBufferDescribe'] as String?) ?? '';
    final rgbaBufferFormat =
        (payload['rgbaBufferFormat'] as num?)?.toInt() ?? 0;
    final rgbaBufferUsage = (payload['rgbaBufferUsage'] as num?)?.toInt() ?? 0;
    final ycbcrBufferDescribe =
        (payload['ycbcrBufferDescribe'] as String?) ?? '';
    final ycbcrBufferFormat =
        (payload['ycbcrBufferFormat'] as num?)?.toInt() ?? 0;
    final ycbcrBufferUsage =
        (payload['ycbcrBufferUsage'] as num?)?.toInt() ?? 0;
    final ycbcrFormatIs420888 = payload['ycbcrFormatIs420888'] == true;
    final initialize = (payload['initialize'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final surfaceKindAfterAttach =
        (payload['surfaceKindAfterAttach'] as String?) ?? '';
    final widthAfterAttach =
        (payload['widthAfterAttach'] as num?)?.toInt() ?? 0;
    final heightAfterAttach =
        (payload['heightAfterAttach'] as num?)?.toInt() ?? 0;
    final ycbcrImport = (payload['ycbcrImport'] as String?) ?? '';
    final ycbcrHandle = (payload['ycbcrHandle'] as num?)?.toInt() ?? 0;
    final ycbcrDescWidth = (payload['ycbcrDescWidth'] as num?)?.toInt() ?? 0;
    final ycbcrDescHeight = (payload['ycbcrDescHeight'] as num?)?.toInt() ?? 0;
    final ycbcrDescLayers = (payload['ycbcrDescLayers'] as num?)?.toInt() ?? 0;
    final ycbcrDescFormat = (payload['ycbcrDescFormat'] as num?)?.toInt() ?? 0;
    final ycbcrDescUsageSampled = payload['ycbcrDescUsageSampled'] == true;
    final hasYcbcrAfterImport = payload['hasYcbcrAfterImport'] == true;
    final ycbcrTextureTarget =
        (payload['ycbcrTextureTarget'] as num?)?.toInt() ?? 0;
    final diagnosticRender = (payload['diagnosticRender'] as String?) ?? '';
    final diagnosticRenderLastError =
        (payload['diagnosticRenderLastError'] as String?) ?? '';
    final centerRead = (payload['centerRead'] as String?) ?? '';
    final centerReadLastError =
        (payload['centerReadLastError'] as String?) ?? '';
    final renderFrame = (payload['renderFrame'] as String?) ?? '';
    final renderFrameLastError =
        (payload['renderFrameLastError'] as String?) ?? '';
    final releaseYcbcr = (payload['releaseYcbcr'] as String?) ?? '';
    final releaseYcbcrFence =
        (payload['releaseYcbcrFence'] as num?)?.toInt() ?? -1;
    final hasYcbcrAfterRelease = payload['hasYcbcrAfterRelease'] == true;
    final rgbaPostImport = (payload['rgbaPostImport'] as String?) ?? '';
    final rgbaPostHandle = (payload['rgbaPostHandle'] as num?)?.toInt() ?? 0;
    final rgbaPostDescWidth =
        (payload['rgbaPostDescWidth'] as num?)?.toInt() ?? 0;
    final rgbaPostDescHeight =
        (payload['rgbaPostDescHeight'] as num?)?.toInt() ?? 0;
    final rgbaPostDescLayers =
        (payload['rgbaPostDescLayers'] as num?)?.toInt() ?? 0;
    final rgbaPostDescFormat =
        (payload['rgbaPostDescFormat'] as num?)?.toInt() ?? 0;
    final rgbaPostDescUsageSampled =
        payload['rgbaPostDescUsageSampled'] == true;
    final hasRgbaPostAfterImport = payload['hasRgbaPostAfterImport'] == true;
    final rgbaPostTextureTarget =
        (payload['rgbaPostTextureTarget'] as num?)?.toInt() ?? 0;
    final rgbaPostRelease = (payload['rgbaPostRelease'] as String?) ?? '';
    final rgbaPostReleaseFence =
        (payload['rgbaPostReleaseFence'] as num?)?.toInt() ?? -1;
    final hasRgbaPostAfterRelease = payload['hasRgbaPostAfterRelease'] == true;
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        ycbcrAllocation == 'success' &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        rgbaBufferDescribe == 'success' &&
        rgbaBufferFormat == 1 &&
        rgbaBufferUsage > 0 &&
        ycbcrBufferDescribe == 'success' &&
        ycbcrBufferFormat == 35 &&
        ycbcrBufferUsage > 0 &&
        ycbcrFormatIs420888 &&
        initialize == 'success' &&
        attach == 'success' &&
        hasSurfaceAfterAttach &&
        surfaceKindAfterAttach == 'window' &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        ycbcrImport == 'success' &&
        ycbcrHandle > 0 &&
        ycbcrDescWidth == 64 &&
        ycbcrDescHeight == 64 &&
        ycbcrDescLayers == 1 &&
        ycbcrDescFormat == 35 &&
        ycbcrDescUsageSampled &&
        hasYcbcrAfterImport &&
        ycbcrTextureTarget == 0x8D65 &&
        diagnosticRender == 'success' &&
        (diagnosticRenderLastError.isEmpty ||
            diagnosticRenderLastError == 'none') &&
        centerRead == 'success' &&
        (centerReadLastError.isEmpty || centerReadLastError == 'none') &&
        renderFrame == 'success' &&
        (renderFrameLastError.isEmpty || renderFrameLastError == 'none') &&
        releaseYcbcr == 'success' &&
        releaseYcbcrFence >= -1 &&
        !hasYcbcrAfterRelease &&
        rgbaPostImport == 'success' &&
        rgbaPostHandle > 0 &&
        rgbaPostDescWidth == 64 &&
        rgbaPostDescHeight == 64 &&
        rgbaPostDescLayers == 1 &&
        rgbaPostDescFormat == 1 &&
        rgbaPostDescUsageSampled &&
        hasRgbaPostAfterImport &&
        rgbaPostTextureTarget == 0x0DE1 &&
        rgbaPostRelease == 'success' &&
        rgbaPostReleaseFence >= -1 &&
        !hasRgbaPostAfterRelease &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode';

    // ignore: avoid_print
    print('ANDROID_GLES_EXTERNAL_TEXTURE_UNIT_AR_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_EXTERNAL_TEXTURE_UNIT_AR_PHYSICAL_PASS'
          : 'ANDROID_GLES_EXTERNAL_TEXTURE_UNIT_AR_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = isPass ? 'PASS' : 'FAIL';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(body: Center(child: Text(_status))),
    );
  }
}
