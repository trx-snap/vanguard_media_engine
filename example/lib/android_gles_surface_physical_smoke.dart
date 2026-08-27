import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesSurfacePhysicalSmokeApp());
}

class AndroidGlesSurfacePhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesSurfacePhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesSurfacePhysicalSmokeApp> createState() =>
      _AndroidGlesSurfacePhysicalSmokeAppState();
}

class _AndroidGlesSurfacePhysicalSmokeAppState
    extends State<AndroidGlesSurfacePhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android GLES surface Unit V physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1VGlesSurfaceSmoke',
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
        'initialSurfaceKind': 'none',
        'firstAttach': 'exception:${error.runtimeType}',
        'hasSurfaceAfterAttach': false,
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'doubleAttach': 'not_run',
        'doubleAttachLastError': '',
        'resize': 'not_run',
        'resizeLastError': '',
        'hasSurfaceAfterResize': false,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'widthAfterDetach': 0,
        'heightAfterDetach': 0,
        'reattach': 'not_run',
        'finalDetach': 'not_run',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'import': 'not_run',
        'renderFrame': 'not_run',
        'proofBoundary': 'gles_window_surface_attach_detach_no_render',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final initialSurfaceKind = (payload['initialSurfaceKind'] as String?) ?? '';
    final firstAttach = (payload['firstAttach'] as String?) ?? '';
    final hasSurfaceAfterAttach = payload['hasSurfaceAfterAttach'] == true;
    final widthAfterAttach =
        (payload['widthAfterAttach'] as num?)?.toInt() ?? 0;
    final heightAfterAttach =
        (payload['heightAfterAttach'] as num?)?.toInt() ?? 0;
    final doubleAttach = (payload['doubleAttach'] as String?) ?? '';
    final doubleAttachLastError =
        (payload['doubleAttachLastError'] as String?) ?? '';
    final resize = (payload['resize'] as String?) ?? '';
    final resizeLastError = (payload['resizeLastError'] as String?) ?? '';
    final hasSurfaceAfterResize = payload['hasSurfaceAfterResize'] == true;
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final widthAfterDetach =
        (payload['widthAfterDetach'] as num?)?.toInt() ?? 0;
    final heightAfterDetach =
        (payload['heightAfterDetach'] as num?)?.toInt() ?? 0;
    final reattach = (payload['reattach'] as String?) ?? '';
    final finalDetach = (payload['finalDetach'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final importResult = (payload['import'] as String?) ?? '';
    final renderFrameResult = (payload['renderFrame'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';

    final isPass =
        passFlag &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        initialSurfaceKind == 'offscreen' &&
        firstAttach == 'success' &&
        hasSurfaceAfterAttach &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        doubleAttach == 'rejected_as_expected' &&
        doubleAttachLastError == 'surface_already_attached' &&
        resize == 'rejected_as_expected' &&
        resizeLastError == 'resize_requires_reattach' &&
        hasSurfaceAfterResize &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        widthAfterDetach == 0 &&
        heightAfterDetach == 0 &&
        reattach == 'success' &&
        finalDetach == 'success' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        importResult == 'unavailable' &&
        renderFrameResult == 'unavailable' &&
        proofBoundary == 'gles_window_surface_attach_detach_no_render';

    // ignore: avoid_print
    print('ANDROID_GLES_BACKEND_UNIT_V_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_BACKEND_UNIT_V_PHYSICAL_PASS'
          : 'ANDROID_GLES_BACKEND_UNIT_V_PHYSICAL_FAIL',
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
