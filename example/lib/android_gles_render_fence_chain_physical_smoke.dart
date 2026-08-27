import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesRenderFenceChainPhysicalSmokeApp());
}

class AndroidGlesRenderFenceChainPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesRenderFenceChainPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesRenderFenceChainPhysicalSmokeApp> createState() =>
      _AndroidGlesRenderFenceChainPhysicalSmokeAppState();
}

class _AndroidGlesRenderFenceChainPhysicalSmokeAppState
    extends State<AndroidGlesRenderFenceChainPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES render frame fence chain Unit AM physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1AMGlesRenderFenceChainSmoke',
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
        'attach': 'not_run',
        'hasSurfaceAfterAttach': false,
        'import': 'not_run',
        'handle': 0,
        'hasAfterImport': false,
        'renderFrame': 'not_run',
        'eglCurrentDisplayOk': false,
        'symbolsResolved': false,
        'nativeFenceSyncCreate': 'not_run',
        'glFlushOk': false,
        'dupNativeFenceFd': -1,
        'fdOpenBeforeClose': false,
        'waitOutcome': 'not_run',
        'waitSignaled': false,
        'closeResult': 'not_run',
        'fdClosedAfterClose': false,
        'destroySync': 'not_run',
        'releaseBuffer': 'not_run',
        'releaseFence': -1,
        'hasAfterRelease': false,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_renderFrame_native_fence_chain_release_fence_optional_no_yuv_no_product',
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
    final attach = payload['attach'];
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final import = payload['import'];
    final handle = (payload['handle'] as num?)?.toInt() ?? 0;
    final hasAfterImport = payload['hasAfterImport'] == true;
    final renderFrame = payload['renderFrame'];
    final eglCurrentDisplayOk = payload['eglCurrentDisplayOk'] == true;
    final symbolsResolved = payload['symbolsResolved'] == true;
    final nativeFenceSyncCreate = payload['nativeFenceSyncCreate'];
    final glFlushOk = payload['glFlushOk'] == true;
    final dupNativeFenceFd =
        (payload['dupNativeFenceFd'] as num?)?.toInt() ?? -1;
    final fdOpenBeforeClose = payload['fdOpenBeforeClose'] == true;
    final waitOutcome = (payload['waitOutcome'] as String?) ?? '';
    final waitSignaled = payload['waitSignaled'] == true;
    final closeResult = payload['closeResult'];
    final fdClosedAfterClose = payload['fdClosedAfterClose'] == true;
    final destroySync = payload['destroySync'];
    final releaseBuffer = payload['releaseBuffer'];
    final releaseFence = (payload['releaseFence'] as num?)?.toInt() ?? -1;
    final hasAfterRelease = payload['hasAfterRelease'] == true;
    final detach = payload['detach'];
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final shutdown = payload['shutdown'];
    final idempotentShutdown = payload['idempotentShutdown'];
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

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
        (attach == 'success' || attach == true) &&
        hasSurfaceAfterAttach &&
        (import == 'success' || import == true) &&
        handle > 0 &&
        hasAfterImport &&
        (renderFrame == 'success' || renderFrame == true) &&
        eglCurrentDisplayOk &&
        symbolsResolved &&
        (nativeFenceSyncCreate == 'success' || nativeFenceSyncCreate == true) &&
        glFlushOk &&
        dupNativeFenceFd >= 0 &&
        fdOpenBeforeClose &&
        waitOutcome == 'signaled' &&
        waitSignaled &&
        (closeResult == 'success' || closeResult == true) &&
        fdClosedAfterClose &&
        (destroySync == 'success' || destroySync == true) &&
        (releaseBuffer == 'success' || releaseBuffer == true) &&
        releaseFence >= -1 &&
        !hasAfterRelease &&
        (detach == 'success' || detach == true) &&
        (surfaceKindAfterDetach == 'offscreen' ||
            surfaceKindAfterDetach == 'none') &&
        (shutdown == 'success' || shutdown == true) &&
        (idempotentShutdown == 'success' || idempotentShutdown == true) &&
        proofBoundary ==
            'gles_renderFrame_native_fence_chain_release_fence_optional_no_yuv_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_RENDER_FENCE_CHAIN_UNIT_AM_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_RENDER_FENCE_CHAIN_UNIT_AM_PHYSICAL_PASS'
          : 'ANDROID_GLES_RENDER_FENCE_CHAIN_UNIT_AM_PHYSICAL_FAIL',
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
