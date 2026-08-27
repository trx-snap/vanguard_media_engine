import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesRenderFrameTransformMappingPhysicalSmokeApp());
}

class AndroidGlesRenderFrameTransformMappingPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidGlesRenderFrameTransformMappingPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesRenderFrameTransformMappingPhysicalSmokeApp> createState() =>
      _AndroidGlesRenderFrameTransformMappingPhysicalSmokeAppState();
}

class _AndroidGlesRenderFrameTransformMappingPhysicalSmokeAppState
    extends State<AndroidGlesRenderFrameTransformMappingPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES renderFrame asymmetric UV mapping Unit AD physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke',
        <String, dynamic>{'width': 64, 'height': 64},
      );
      payload = Map<String, dynamic>.from(response! as Map);
    } catch (error) {
      payload = <String, dynamic>{
        'pass': false,
        'raw': 'exception:${error.runtimeType}',
        'clientVersion': 0,
        'vendor': '',
        'renderer': '',
        'version': '',
        'bufferDescribe': 'not_run',
        'bufferWidth': 0,
        'bufferHeight': 0,
        'bufferLayers': 0,
        'bufferFormat': 0,
        'bufferUsage': 0,
        'bufferStride': 0,
        'bufferFill': 'not_run',
        'writeFenceFd': -1,
        'writeFenceWait': 'none',
        'preInitDiagnosticRender': 'not_run',
        'preInitLastError': '',
        'initialize': 'not_run',
        'attach': 'exception:${error.runtimeType}',
        'hasSurfaceAfterAttach': false,
        'surfaceKindAfterAttach': 'none',
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'importBuffer': 'not_run',
        'handle': 0,
        'descriptorWidth': 0,
        'descriptorHeight': 0,
        'descriptorLayers': 0,
        'descriptorFormat': 0,
        'descriptorUsageSampled': false,
        'hasAfterImport': false,
        'invalidHandleDiagnosticRender': 'not_run',
        'invalidHandleLastError': '',
        'identityDiagnosticRender': 'not_run',
        'identityDiagnosticLastError': '',
        'identityColorsDistinct': false,
        'uv00R': 0,
        'uv00G': 0,
        'uv00B': 0,
        'uv00A': 0,
        'uv00Label': 'unknown',
        'uv10R': 0,
        'uv10G': 0,
        'uv10B': 0,
        'uv10A': 0,
        'uv10Label': 'unknown',
        'uv01R': 0,
        'uv01G': 0,
        'uv01B': 0,
        'uv01A': 0,
        'uv01Label': 'unknown',
        'uv11R': 0,
        'uv11G': 0,
        'uv11B': 0,
        'uv11A': 0,
        'uv11Label': 'unknown',
        'identityPass': false,
        'rot90DiagnosticRender': 'not_run',
        'rot90DiagnosticLastError': '',
        'rot90Pass': false,
        'rot180DiagnosticRender': 'not_run',
        'rot180DiagnosticLastError': '',
        'rot180Pass': false,
        'rot270DiagnosticRender': 'not_run',
        'rot270DiagnosticLastError': '',
        'rot270Pass': false,
        'mirror0DiagnosticRender': 'not_run',
        'mirror0DiagnosticLastError': '',
        'mirror0Pass': false,
        'mirror90DiagnosticRender': 'not_run',
        'mirror90DiagnosticLastError': '',
        'mirror90Pass': false,
        'mirror180DiagnosticRender': 'not_run',
        'mirror180DiagnosticLastError': '',
        'mirror180Pass': false,
        'mirror270DiagnosticRender': 'not_run',
        'mirror270DiagnosticLastError': '',
        'mirror270Pass': false,
        'allTransformsPass': false,
        'releaseBuffer': 'not_run',
        'releaseFence': -1,
        'hasAfterRelease': false,
        'postReleaseDiagnosticRender': 'not_run',
        'postReleaseLastError': '',
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'postDetachRead': 'not_run',
        'postDetachLastError': '',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final bufferDescribe = (payload['bufferDescribe'] as String?) ?? '';
    final bufferWidth = (payload['bufferWidth'] as num?)?.toInt() ?? 0;
    final bufferHeight = (payload['bufferHeight'] as num?)?.toInt() ?? 0;
    final bufferLayers = (payload['bufferLayers'] as num?)?.toInt() ?? 0;
    final bufferFormat = (payload['bufferFormat'] as num?)?.toInt() ?? 0;
    final bufferUsage = (payload['bufferUsage'] as num?)?.toInt() ?? 0;
    final bufferStride = (payload['bufferStride'] as num?)?.toInt() ?? 0;
    final bufferFill = (payload['bufferFill'] as String?) ?? '';
    final writeFenceFd = (payload['writeFenceFd'] as num?)?.toInt() ?? -1;
    final writeFenceWait = (payload['writeFenceWait'] as String?) ?? '';
    final preInitDiagnosticRender =
        (payload['preInitDiagnosticRender'] as String?) ?? '';
    final preInitLastError = (payload['preInitLastError'] as String?) ?? '';
    final initialize = (payload['initialize'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final surfaceKindAfterAttach =
        (payload['surfaceKindAfterAttach'] as String?) ?? '';
    final widthAfterAttach =
        (payload['widthAfterAttach'] as num?)?.toInt() ?? 0;
    final heightAfterAttach =
        (payload['heightAfterAttach'] as num?)?.toInt() ?? 0;
    final importBuffer = (payload['importBuffer'] as String?) ?? '';
    final handle = (payload['handle'] as num?)?.toInt() ?? 0;
    final descriptorWidth = (payload['descriptorWidth'] as num?)?.toInt() ?? 0;
    final descriptorHeight =
        (payload['descriptorHeight'] as num?)?.toInt() ?? 0;
    final descriptorLayers =
        (payload['descriptorLayers'] as num?)?.toInt() ?? 0;
    final descriptorFormat =
        (payload['descriptorFormat'] as num?)?.toInt() ?? 0;
    final descriptorUsageSampled = payload['descriptorUsageSampled'] == true;
    final hasAfterImport = payload['hasAfterImport'] == true;
    final invalidHandleDiagnosticRender =
        (payload['invalidHandleDiagnosticRender'] as String?) ?? '';
    final invalidHandleLastError =
        (payload['invalidHandleLastError'] as String?) ?? '';
    final identityDiagnosticRender =
        (payload['identityDiagnosticRender'] as String?) ?? '';
    final identityDiagnosticLastError =
        (payload['identityDiagnosticLastError'] as String?) ?? '';
    final identityColorsDistinct = payload['identityColorsDistinct'] == true;
    final uv00Label = (payload['uv00Label'] as String?) ?? '';
    final uv10Label = (payload['uv10Label'] as String?) ?? '';
    final uv01Label = (payload['uv01Label'] as String?) ?? '';
    final uv11Label = (payload['uv11Label'] as String?) ?? '';
    final identityPass = payload['identityPass'] == true;

    final rot90DiagnosticRender =
        (payload['rot90DiagnosticRender'] as String?) ?? '';
    final rot90DiagnosticLastError =
        (payload['rot90DiagnosticLastError'] as String?) ?? '';
    final rot90Pass = payload['rot90Pass'] == true;

    final rot180DiagnosticRender =
        (payload['rot180DiagnosticRender'] as String?) ?? '';
    final rot180DiagnosticLastError =
        (payload['rot180DiagnosticLastError'] as String?) ?? '';
    final rot180Pass = payload['rot180Pass'] == true;

    final rot270DiagnosticRender =
        (payload['rot270DiagnosticRender'] as String?) ?? '';
    final rot270DiagnosticLastError =
        (payload['rot270DiagnosticLastError'] as String?) ?? '';
    final rot270Pass = payload['rot270Pass'] == true;

    final mirror0DiagnosticRender =
        (payload['mirror0DiagnosticRender'] as String?) ?? '';
    final mirror0DiagnosticLastError =
        (payload['mirror0DiagnosticLastError'] as String?) ?? '';
    final mirror0Pass = payload['mirror0Pass'] == true;

    final mirror90DiagnosticRender =
        (payload['mirror90DiagnosticRender'] as String?) ?? '';
    final mirror90DiagnosticLastError =
        (payload['mirror90DiagnosticLastError'] as String?) ?? '';
    final mirror90Pass = payload['mirror90Pass'] == true;

    final mirror180DiagnosticRender =
        (payload['mirror180DiagnosticRender'] as String?) ?? '';
    final mirror180DiagnosticLastError =
        (payload['mirror180DiagnosticLastError'] as String?) ?? '';
    final mirror180Pass = payload['mirror180Pass'] == true;

    final mirror270DiagnosticRender =
        (payload['mirror270DiagnosticRender'] as String?) ?? '';
    final mirror270DiagnosticLastError =
        (payload['mirror270DiagnosticLastError'] as String?) ?? '';
    final mirror270Pass = payload['mirror270Pass'] == true;

    final allTransformsPass = payload['allTransformsPass'] == true;

    final releaseBuffer = (payload['releaseBuffer'] as String?) ?? '';
    final releaseFence = (payload['releaseFence'] as num?)?.toInt() ?? -1;
    final hasAfterRelease = payload['hasAfterRelease'] == true;
    final postReleaseDiagnosticRender =
        (payload['postReleaseDiagnosticRender'] as String?) ?? '';
    final postReleaseLastError =
        (payload['postReleaseLastError'] as String?) ?? '';
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final postDetachRead = (payload['postDetachRead'] as String?) ?? '';
    final postDetachLastError =
        (payload['postDetachLastError'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final distinctLabels = <String>{uv00Label, uv10Label, uv01Label, uv11Label};
    final validDistinctLabels =
        distinctLabels.length == 4 && !distinctLabels.contains('unknown');

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        bufferDescribe == 'success' &&
        bufferWidth == 64 &&
        bufferHeight == 64 &&
        bufferLayers == 1 &&
        bufferFormat != 0 &&
        bufferUsage > 0 &&
        bufferStride >= 64 &&
        bufferFill == 'success' &&
        writeFenceFd >= -1 &&
        (writeFenceWait == 'none' || writeFenceWait == 'signaled') &&
        preInitDiagnosticRender == 'rejected_as_expected' &&
        preInitLastError == 'backend_not_initialized' &&
        initialize == 'success' &&
        attach == 'success' &&
        hasSurfaceAfterAttach &&
        surfaceKindAfterAttach == 'window' &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        importBuffer == 'success' &&
        handle > 0 &&
        descriptorWidth == 64 &&
        descriptorHeight == 64 &&
        descriptorLayers == 1 &&
        descriptorFormat != 0 &&
        descriptorUsageSampled &&
        hasAfterImport &&
        invalidHandleDiagnosticRender == 'rejected_as_expected' &&
        invalidHandleLastError == 'invalid_buffer_handle' &&
        identityDiagnosticRender == 'success' &&
        (identityDiagnosticLastError.isEmpty ||
            identityDiagnosticLastError == 'none') &&
        identityColorsDistinct &&
        validDistinctLabels &&
        identityPass &&
        rot90DiagnosticRender == 'success' &&
        (rot90DiagnosticLastError.isEmpty ||
            rot90DiagnosticLastError == 'none') &&
        rot90Pass &&
        rot180DiagnosticRender == 'success' &&
        (rot180DiagnosticLastError.isEmpty ||
            rot180DiagnosticLastError == 'none') &&
        rot180Pass &&
        rot270DiagnosticRender == 'success' &&
        (rot270DiagnosticLastError.isEmpty ||
            rot270DiagnosticLastError == 'none') &&
        rot270Pass &&
        mirror0DiagnosticRender == 'success' &&
        (mirror0DiagnosticLastError.isEmpty ||
            mirror0DiagnosticLastError == 'none') &&
        mirror0Pass &&
        mirror90DiagnosticRender == 'success' &&
        (mirror90DiagnosticLastError.isEmpty ||
            mirror90DiagnosticLastError == 'none') &&
        mirror90Pass &&
        mirror180DiagnosticRender == 'success' &&
        (mirror180DiagnosticLastError.isEmpty ||
            mirror180DiagnosticLastError == 'none') &&
        mirror180Pass &&
        mirror270DiagnosticRender == 'success' &&
        (mirror270DiagnosticLastError.isEmpty ||
            mirror270DiagnosticLastError == 'none') &&
        mirror270Pass &&
        allTransformsPass &&
        releaseBuffer == 'success' &&
        releaseFence >= -1 &&
        !hasAfterRelease &&
        postReleaseDiagnosticRender == 'rejected_as_expected' &&
        postReleaseLastError == 'invalid_buffer_handle' &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        postDetachRead == 'rejected_as_expected' &&
        postDetachLastError == 'no_surface_attached' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RENDERFRAME_TRANSFORM_MAPPING_UNIT_AD_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RENDERFRAME_TRANSFORM_MAPPING_UNIT_AD_PHYSICAL_PASS'
          : 'ANDROID_GLES_RENDERFRAME_TRANSFORM_MAPPING_UNIT_AD_PHYSICAL_FAIL',
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
