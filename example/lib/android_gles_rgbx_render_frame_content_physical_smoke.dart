import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesRgbxRenderFrameContentPhysicalSmokeApp());
}

class AndroidGlesRgbxRenderFrameContentPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesRgbxRenderFrameContentPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesRgbxRenderFrameContentPhysicalSmokeApp> createState() =>
      _AndroidGlesRgbxRenderFrameContentPhysicalSmokeAppState();
}

class _AndroidGlesRgbxRenderFrameContentPhysicalSmokeAppState
    extends State<AndroidGlesRgbxRenderFrameContentPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES RGBX AHardwareBuffer renderFrame content readback Unit AF physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke',
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
        'formatIsRgbx': false,
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
        'descriptorFormatIsRgbx': false,
        'descriptorUsageSampled': false,
        'hasAfterImport': false,
        'invalidHandleDiagnosticRender': 'not_run',
        'invalidHandleLastError': '',
        'identityDiagnosticRender': 'not_run',
        'identityDiagnosticLastError': '',
        'identityCenterRead': 'not_run',
        'identityCenterReadLastError': '',
        'identityCenterR': 0,
        'identityCenterG': 0,
        'identityCenterB': 0,
        'identityCenterA': 0,
        'identityCenterPixelMatches': false,
        'rot90DiagnosticRender': 'not_run',
        'rot90DiagnosticLastError': '',
        'rot90CenterRead': 'not_run',
        'rot90CenterReadLastError': '',
        'rot90CenterR': 0,
        'rot90CenterG': 0,
        'rot90CenterB': 0,
        'rot90CenterA': 0,
        'rot90CenterPixelMatches': false,
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
            'gles_renderFrame_rgbx_texture_content_readback_no_swap_no_yuv_no_fence_no_product',
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
    final formatIsRgbx = payload['formatIsRgbx'] == true;
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
    final descriptorFormatIsRgbx = payload['descriptorFormatIsRgbx'] == true;
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
    final identityCenterRead = (payload['identityCenterRead'] as String?) ?? '';
    final identityCenterReadLastError =
        (payload['identityCenterReadLastError'] as String?) ?? '';
    final identityCenterR = (payload['identityCenterR'] as num?)?.toInt() ?? 0;
    final identityCenterG = (payload['identityCenterG'] as num?)?.toInt() ?? 0;
    final identityCenterB = (payload['identityCenterB'] as num?)?.toInt() ?? 0;
    final identityCenterA = (payload['identityCenterA'] as num?)?.toInt() ?? 0;
    final identityCenterPixelMatches =
        payload['identityCenterPixelMatches'] == true;
    final rot90DiagnosticRender =
        (payload['rot90DiagnosticRender'] as String?) ?? '';
    final rot90DiagnosticLastError =
        (payload['rot90DiagnosticLastError'] as String?) ?? '';
    final rot90CenterRead = (payload['rot90CenterRead'] as String?) ?? '';
    final rot90CenterReadLastError =
        (payload['rot90CenterReadLastError'] as String?) ?? '';
    final rot90CenterR = (payload['rot90CenterR'] as num?)?.toInt() ?? 0;
    final rot90CenterG = (payload['rot90CenterG'] as num?)?.toInt() ?? 0;
    final rot90CenterB = (payload['rot90CenterB'] as num?)?.toInt() ?? 0;
    final rot90CenterA = (payload['rot90CenterA'] as num?)?.toInt() ?? 0;
    final rot90CenterPixelMatches = payload['rot90CenterPixelMatches'] == true;
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

    final identityCenterColorMatch =
        (identityCenterR - 19).abs() <= 8 &&
        (identityCenterG - 151).abs() <= 8 &&
        (identityCenterB - 213).abs() <= 8 &&
        identityCenterA >= 240;

    final rot90CenterColorMatch =
        (rot90CenterR - 19).abs() <= 8 &&
        (rot90CenterG - 151).abs() <= 8 &&
        (rot90CenterB - 213).abs() <= 8 &&
        rot90CenterA >= 240;

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
        bufferFormat == 2 &&
        formatIsRgbx &&
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
        descriptorFormat == 2 &&
        descriptorFormatIsRgbx &&
        descriptorUsageSampled &&
        hasAfterImport &&
        invalidHandleDiagnosticRender == 'rejected_as_expected' &&
        invalidHandleLastError == 'invalid_buffer_handle' &&
        identityDiagnosticRender == 'success' &&
        (identityDiagnosticLastError.isEmpty ||
            identityDiagnosticLastError == 'none') &&
        identityCenterRead == 'success' &&
        (identityCenterReadLastError.isEmpty ||
            identityCenterReadLastError == 'none') &&
        identityCenterPixelMatches &&
        identityCenterColorMatch &&
        rot90DiagnosticRender == 'success' &&
        (rot90DiagnosticLastError.isEmpty ||
            rot90DiagnosticLastError == 'none') &&
        rot90CenterRead == 'success' &&
        (rot90CenterReadLastError.isEmpty ||
            rot90CenterReadLastError == 'none') &&
        rot90CenterPixelMatches &&
        rot90CenterColorMatch &&
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
            'gles_renderFrame_rgbx_texture_content_readback_no_swap_no_yuv_no_fence_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RGBX_RENDERFRAME_CONTENT_UNIT_AF_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RGBX_RENDERFRAME_CONTENT_UNIT_AF_PHYSICAL_PASS'
          : 'ANDROID_GLES_RGBX_RENDERFRAME_CONTENT_UNIT_AF_PHYSICAL_FAIL',
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
