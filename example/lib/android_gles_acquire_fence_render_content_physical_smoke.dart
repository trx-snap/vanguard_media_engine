import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesAcquireFenceRenderContentPhysicalSmokeApp());
}

class AndroidGlesAcquireFenceRenderContentPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidGlesAcquireFenceRenderContentPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesAcquireFenceRenderContentPhysicalSmokeApp> createState() =>
      _AndroidGlesAcquireFenceRenderContentPhysicalSmokeAppState();
}

class _AndroidGlesAcquireFenceRenderContentPhysicalSmokeAppState
    extends State<AndroidGlesAcquireFenceRenderContentPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES acquire-fence import -> renderFrame content Unit AN physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke',
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
        'bufferUsageSampled': false,
        'bufferUsageCpuWrite': false,
        'bufferFill': 'not_run',
        'writeFenceFd': -1,
        'writeFenceWait': 'none',
        'initialize': 'exception:${error.runtimeType}',
        'eglCurrentDisplayOk': false,
        'symbolsResolved': false,
        'acquireFenceCreate': 'not_run',
        'glFlushOk': false,
        'acquireFenceFd': -1,
        'acquireFenceOpenBeforeImport': false,
        'acquireFenceDestroyed': false,
        'attach': 'not_run',
        'hasSurfaceAfterAttach': false,
        'import': 'not_run',
        'acquireFenceClosedAfterImport': false,
        'handle': 0,
        'descriptorWidth': 0,
        'descriptorHeight': 0,
        'descriptorLayers': 0,
        'descriptorFormat': 0,
        'descriptorUsageSampled': false,
        'hasAfterImport': false,
        'diagnosticRender': 'not_run',
        'centerRead': 'not_run',
        'centerR': 0,
        'centerG': 0,
        'centerB': 0,
        'centerA': 0,
        'centerPixelMatches': false,
        'releaseBuffer': 'not_run',
        'releaseFence': -1,
        'hasAfterRelease': false,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final bufferDescribe = payload['bufferDescribe'];
    final bufferWidth = (payload['bufferWidth'] as num?)?.toInt() ?? 0;
    final bufferHeight = (payload['bufferHeight'] as num?)?.toInt() ?? 0;
    final bufferLayers = (payload['bufferLayers'] as num?)?.toInt() ?? 0;
    final bufferFormat = (payload['bufferFormat'] as num?)?.toInt() ?? 0;
    final bufferUsageSampled = payload['bufferUsageSampled'] == true;
    final bufferUsageCpuWrite = payload['bufferUsageCpuWrite'] == true;
    final bufferFill = payload['bufferFill'];
    final writeFenceFd = (payload['writeFenceFd'] as num?)?.toInt() ?? -1;
    final writeFenceWait = (payload['writeFenceWait'] as String?) ?? '';
    final initialize = payload['initialize'];
    final eglCurrentDisplayOk = payload['eglCurrentDisplayOk'] == true;
    final symbolsResolved = payload['symbolsResolved'] == true;
    final acquireFenceCreate = payload['acquireFenceCreate'];
    final glFlushOk = payload['glFlushOk'] == true;
    final acquireFenceFd = (payload['acquireFenceFd'] as num?)?.toInt() ?? -1;
    final acquireFenceOpenBeforeImport =
        payload['acquireFenceOpenBeforeImport'] == true;
    final acquireFenceDestroyed = payload['acquireFenceDestroyed'] == true;
    final attach = payload['attach'];
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final import = payload['import'];
    final acquireFenceClosedAfterImport =
        payload['acquireFenceClosedAfterImport'] == true;
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
    final diagnosticRender = payload['diagnosticRender'];
    final centerRead = payload['centerRead'];
    final centerR = (payload['centerR'] as num?)?.toInt() ?? 0;
    final centerG = (payload['centerG'] as num?)?.toInt() ?? 0;
    final centerB = (payload['centerB'] as num?)?.toInt() ?? 0;
    final centerA = (payload['centerA'] as num?)?.toInt() ?? 0;
    final centerPixelMatches = payload['centerPixelMatches'] == true;
    final releaseBuffer = payload['releaseBuffer'];
    final releaseFence = (payload['releaseFence'] as num?)?.toInt() ?? -1;
    final hasAfterRelease = payload['hasAfterRelease'] == true;
    final detach = payload['detach'];
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final shutdown = payload['shutdown'];
    final idempotentShutdown = payload['idempotentShutdown'];
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final centerColorMatch =
        (centerR - 53).abs() <= 8 &&
        (centerG - 137).abs() <= 8 &&
        (centerB - 219).abs() <= 8 &&
        centerA >= 240;

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        (bufferDescribe == 'success' || bufferDescribe == true) &&
        bufferWidth == 64 &&
        bufferHeight == 64 &&
        bufferLayers == 1 &&
        bufferFormat == 1 &&
        bufferUsageSampled &&
        bufferUsageCpuWrite &&
        (bufferFill == 'success' || bufferFill == true) &&
        writeFenceFd >= -1 &&
        (writeFenceWait == 'signaled' || writeFenceWait == 'none') &&
        (initialize == 'success' || initialize == true) &&
        eglCurrentDisplayOk &&
        symbolsResolved &&
        (acquireFenceCreate == 'success' || acquireFenceCreate == true) &&
        glFlushOk &&
        acquireFenceFd >= 0 &&
        acquireFenceOpenBeforeImport &&
        acquireFenceDestroyed &&
        (attach == 'success' || attach == true) &&
        hasSurfaceAfterAttach &&
        (import == 'success' || import == true) &&
        acquireFenceClosedAfterImport &&
        handle > 0 &&
        descriptorWidth == 64 &&
        descriptorHeight == 64 &&
        descriptorLayers == 1 &&
        descriptorFormat != 0 &&
        descriptorUsageSampled &&
        hasAfterImport &&
        (diagnosticRender == 'success' || diagnosticRender == true) &&
        (centerRead == 'success' || centerRead == true) &&
        centerPixelMatches &&
        centerColorMatch &&
        (releaseBuffer == 'success' || releaseBuffer == true) &&
        releaseFence >= -1 &&
        !hasAfterRelease &&
        (detach == 'success' || detach == true) &&
        (surfaceKindAfterDetach == 'offscreen' ||
            surfaceKindAfterDetach == 'none') &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_ACQUIRE_FENCE_RENDER_CONTENT_UNIT_AN_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_ACQUIRE_FENCE_RENDER_CONTENT_UNIT_AN_PHYSICAL_PASS'
          : 'ANDROID_GLES_ACQUIRE_FENCE_RENDER_CONTENT_UNIT_AN_PHYSICAL_FAIL',
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
