import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesRenderFrameTransformPhysicalSmokeApp());
}

class AndroidGlesRenderFrameTransformPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesRenderFrameTransformPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesRenderFrameTransformPhysicalSmokeApp> createState() =>
      _AndroidGlesRenderFrameTransformPhysicalSmokeAppState();
}

class _AndroidGlesRenderFrameTransformPhysicalSmokeAppState
    extends State<AndroidGlesRenderFrameTransformPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android GLES renderFrame Unit AA physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ZGlesRenderFrameSmoke',
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
        'preInitRender': 'not_run',
        'preInitLastError': '',
        'initialize': 'not_run',
        'importA': 'not_run',
        'handleA': 0,
        'descriptorWidth': 0,
        'descriptorHeight': 0,
        'descriptorLayers': 0,
        'descriptorFormat': 0,
        'descriptorUsageSampled': false,
        'hasAAfterImport': false,
        'preAttachRender': 'not_run',
        'preAttachLastError': '',
        'attach': 'exception:${error.runtimeType}',
        'hasSurfaceAfterAttach': false,
        'surfaceKindAfterAttach': 'none',
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'invalidHandleRender': 'not_run',
        'invalidHandleLastError': '',
        'firstRenderA': 'not_run',
        'firstRenderALastError': '',
        'secondRenderA': 'not_run',
        'hasSurfaceAfterSecond': false,
        'surfaceKindAfterSecond': 'none',
        'widthAfterSecond': 0,
        'heightAfterSecond': 0,
        'importB': 'not_run',
        'handleB': 0,
        'distinctHandles': false,
        'hasBAfterImport': false,
        'renderB': 'not_run',
        'renderBLastError': '',
        'identityTransformRender': 'not_run',
        'nonIdentityTransformRender': 'not_run',
        'nonIdentityTransformLastError': '',
        'hasSurfaceAfterTransform': false,
        'rot180TransformRender': 'not_run',
        'rot180TransformLastError': '',
        'rot270TransformRender': 'not_run',
        'rot270TransformLastError': '',
        'mirrorTransformRender': 'not_run',
        'mirrorTransformLastError': '',
        'hasSurfaceAfterAllTransforms': false,
        'releaseA': 'not_run',
        'releaseAFence': -1,
        'hasAAfterRelease': false,
        'hasBAfterReleaseA': false,
        'releasedHandleRender': 'not_run',
        'releasedHandleLastError': '',
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'postDetachRenderB': 'not_run',
        'postDetachLastError': '',
        'shutdown': 'not_run',
        'hasBAfterShutdown': false,
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final preInitRender = (payload['preInitRender'] as String?) ?? '';
    final preInitLastError = (payload['preInitLastError'] as String?) ?? '';
    final initialize = (payload['initialize'] as String?) ?? '';
    final importA = (payload['importA'] as String?) ?? '';
    final handleA = (payload['handleA'] as num?)?.toInt() ?? 0;
    final descriptorWidth = (payload['descriptorWidth'] as num?)?.toInt() ?? 0;
    final descriptorHeight =
        (payload['descriptorHeight'] as num?)?.toInt() ?? 0;
    final descriptorLayers =
        (payload['descriptorLayers'] as num?)?.toInt() ?? 0;
    final descriptorFormat =
        (payload['descriptorFormat'] as num?)?.toInt() ?? 0;
    final descriptorUsageSampled = payload['descriptorUsageSampled'] == true;
    final hasAAfterImport = payload['hasAAfterImport'] == true;
    final preAttachRender = (payload['preAttachRender'] as String?) ?? '';
    final preAttachLastError = (payload['preAttachLastError'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final surfaceKindAfterAttach =
        (payload['surfaceKindAfterAttach'] as String?) ?? '';
    final widthAfterAttach =
        (payload['widthAfterAttach'] as num?)?.toInt() ?? 0;
    final heightAfterAttach =
        (payload['heightAfterAttach'] as num?)?.toInt() ?? 0;
    final invalidHandleRender =
        (payload['invalidHandleRender'] as String?) ?? '';
    final invalidHandleLastError =
        (payload['invalidHandleLastError'] as String?) ?? '';
    final firstRenderA = (payload['firstRenderA'] as String?) ?? '';
    final secondRenderA = (payload['secondRenderA'] as String?) ?? '';
    final hasSurfaceAfterSecond = payload['hasSurfaceAfterSecond'] == true;
    final surfaceKindAfterSecond =
        (payload['surfaceKindAfterSecond'] as String?) ?? '';
    final widthAfterSecond =
        (payload['widthAfterSecond'] as num?)?.toInt() ?? 0;
    final heightAfterSecond =
        (payload['heightAfterSecond'] as num?)?.toInt() ?? 0;
    final importB = (payload['importB'] as String?) ?? '';
    final handleB = (payload['handleB'] as num?)?.toInt() ?? 0;
    final distinctHandles = payload['distinctHandles'] == true;
    final hasBAfterImport = payload['hasBAfterImport'] == true;
    final renderB = (payload['renderB'] as String?) ?? '';
    final identityTransformRender =
        (payload['identityTransformRender'] as String?) ?? '';
    final nonIdentityTransformRender =
        (payload['nonIdentityTransformRender'] as String?) ?? '';
    final nonIdentityTransformLastError =
        (payload['nonIdentityTransformLastError'] as String?) ?? '';
    final hasSurfaceAfterTransform =
        payload['hasSurfaceAfterTransform'] == true;
    final rot180TransformRender =
        (payload['rot180TransformRender'] as String?) ?? '';
    final rot180TransformLastError =
        (payload['rot180TransformLastError'] as String?) ?? '';
    final rot270TransformRender =
        (payload['rot270TransformRender'] as String?) ?? '';
    final rot270TransformLastError =
        (payload['rot270TransformLastError'] as String?) ?? '';
    final mirrorTransformRender =
        (payload['mirrorTransformRender'] as String?) ?? '';
    final mirrorTransformLastError =
        (payload['mirrorTransformLastError'] as String?) ?? '';
    final hasSurfaceAfterAllTransforms =
        payload['hasSurfaceAfterAllTransforms'] == true;
    final releaseA = (payload['releaseA'] as String?) ?? '';
    final releaseAFence = (payload['releaseAFence'] as num?)?.toInt() ?? 0;
    final hasAAfterRelease = payload['hasAAfterRelease'] == true;
    final hasBAfterReleaseA = payload['hasBAfterReleaseA'] == true;
    final releasedHandleRender =
        (payload['releasedHandleRender'] as String?) ?? '';
    final releasedHandleLastError =
        (payload['releasedHandleLastError'] as String?) ?? '';
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final postDetachRenderB = (payload['postDetachRenderB'] as String?) ?? '';
    final postDetachLastError =
        (payload['postDetachLastError'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final hasBAfterShutdown = payload['hasBAfterShutdown'] == true;
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        preInitRender == 'rejected_as_expected' &&
        preInitLastError == 'backend_not_initialized' &&
        initialize == 'success' &&
        importA == 'success' &&
        handleA > 0 &&
        descriptorWidth == 64 &&
        descriptorHeight == 64 &&
        descriptorLayers == 1 &&
        descriptorFormat != 0 &&
        descriptorUsageSampled &&
        hasAAfterImport &&
        preAttachRender == 'rejected_as_expected' &&
        preAttachLastError == 'no_surface_attached' &&
        attach == 'success' &&
        hasSurfaceAfterAttach &&
        surfaceKindAfterAttach == 'window' &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        invalidHandleRender == 'rejected_as_expected' &&
        invalidHandleLastError == 'invalid_buffer_handle' &&
        firstRenderA == 'success' &&
        secondRenderA == 'success' &&
        hasSurfaceAfterSecond &&
        surfaceKindAfterSecond == 'window' &&
        widthAfterSecond == 64 &&
        heightAfterSecond == 64 &&
        importB == 'success' &&
        handleB > 0 &&
        distinctHandles &&
        hasBAfterImport &&
        renderB == 'success' &&
        identityTransformRender == 'success' &&
        nonIdentityTransformRender == 'success' &&
        (nonIdentityTransformLastError.isEmpty ||
            nonIdentityTransformLastError == 'none') &&
        hasSurfaceAfterTransform &&
        rot180TransformRender == 'success' &&
        (rot180TransformLastError.isEmpty ||
            rot180TransformLastError == 'none') &&
        rot270TransformRender == 'success' &&
        (rot270TransformLastError.isEmpty ||
            rot270TransformLastError == 'none') &&
        mirrorTransformRender == 'success' &&
        (mirrorTransformLastError.isEmpty ||
            mirrorTransformLastError == 'none') &&
        hasSurfaceAfterAllTransforms &&
        releaseA == 'success' &&
        releaseAFence == -1 &&
        !hasAAfterRelease &&
        hasBAfterReleaseA &&
        releasedHandleRender == 'rejected_as_expected' &&
        releasedHandleLastError == 'invalid_buffer_handle' &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        postDetachRenderB == 'rejected_as_expected' &&
        postDetachLastError == 'no_surface_attached' &&
        shutdown == 'success' &&
        !hasBAfterShutdown &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RENDERFRAME_TRANSFORM_UNIT_AA_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RENDERFRAME_TRANSFORM_UNIT_AA_PHYSICAL_PASS'
          : 'ANDROID_GLES_RENDERFRAME_TRANSFORM_UNIT_AA_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = isPass ? 'Unit AA PASS' : 'Unit AA FAIL';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(_status, key: const ValueKey('unit_aa_status_text')),
        ),
      ),
    );
  }
}
