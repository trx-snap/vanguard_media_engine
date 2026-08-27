import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesWindowPresentPhysicalSmokeApp());
}

class AndroidGlesWindowPresentPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesWindowPresentPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesWindowPresentPhysicalSmokeApp> createState() =>
      _AndroidGlesWindowPresentPhysicalSmokeAppState();
}

class _AndroidGlesWindowPresentPhysicalSmokeAppState
    extends State<AndroidGlesWindowPresentPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES window present Unit W physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1WGlesWindowPresentSmoke',
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
        'preAttachPresent': 'not_run',
        'preAttachLastError': '',
        'attach': 'exception:${error.runtimeType}',
        'firstPresent': 'not_run',
        'secondPresent': 'not_run',
        'invalidColorPresent': 'not_run',
        'invalidColorLastError': '',
        'hasSurfaceAfterPresent': false,
        'surfaceKindAfterPresent': 'none',
        'widthAfterPresent': 0,
        'heightAfterPresent': 0,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'import': 'not_run',
        'renderFrame': 'not_run',
        'proofBoundary': 'gles_window_clear_swap_no_import_no_renderFrame',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final preAttachPresent = (payload['preAttachPresent'] as String?) ?? '';
    final preAttachLastError = (payload['preAttachLastError'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final firstPresent = (payload['firstPresent'] as String?) ?? '';
    final secondPresent = (payload['secondPresent'] as String?) ?? '';
    final invalidColorPresent =
        (payload['invalidColorPresent'] as String?) ?? '';
    final invalidColorLastError =
        (payload['invalidColorLastError'] as String?) ?? '';
    final hasSurfaceAfterPresent = payload['hasSurfaceAfterPresent'] == true;
    final surfaceKindAfterPresent =
        (payload['surfaceKindAfterPresent'] as String?) ?? '';
    final widthAfterPresent =
        (payload['widthAfterPresent'] as num?)?.toInt() ?? 0;
    final heightAfterPresent =
        (payload['heightAfterPresent'] as num?)?.toInt() ?? 0;
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
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
        preAttachPresent == 'rejected_as_expected' &&
        preAttachLastError == 'no_surface_attached' &&
        attach == 'success' &&
        firstPresent == 'success' &&
        secondPresent == 'success' &&
        invalidColorPresent == 'rejected_as_expected' &&
        invalidColorLastError == 'invalid_clear_color' &&
        hasSurfaceAfterPresent &&
        surfaceKindAfterPresent == 'window' &&
        widthAfterPresent == 64 &&
        heightAfterPresent == 64 &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        importResult == 'unavailable' &&
        renderFrameResult == 'unavailable' &&
        proofBoundary == 'gles_window_clear_swap_no_import_no_renderFrame';

    // ignore: avoid_print
    print('ANDROID_GLES_BACKEND_UNIT_W_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_BACKEND_UNIT_W_PHYSICAL_PASS'
          : 'ANDROID_GLES_BACKEND_UNIT_W_PHYSICAL_FAIL',
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
