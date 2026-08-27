import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesShaderQuadPhysicalSmokeApp());
}

class AndroidGlesShaderQuadPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesShaderQuadPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesShaderQuadPhysicalSmokeApp> createState() =>
      _AndroidGlesShaderQuadPhysicalSmokeAppState();
}

class _AndroidGlesShaderQuadPhysicalSmokeAppState
    extends State<AndroidGlesShaderQuadPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Running Android GLES shader quad Unit X physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1XGlesShaderQuadSmoke',
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
        'preAttachShader': 'not_run',
        'preAttachLastError': '',
        'attach': 'exception:${error.runtimeType}',
        'firstShaderQuad': 'not_run',
        'secondShaderQuad': 'not_run',
        'invalidColorShaderQuad': 'not_run',
        'invalidColorLastError': '',
        'clearAfterShader': 'not_run',
        'hasSurfaceAfterShader': false,
        'surfaceKindAfterShader': 'none',
        'widthAfterShader': 0,
        'heightAfterShader': 0,
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'import': 'not_run',
        'renderFrame': 'not_run',
        'proofBoundary': 'gles_window_shader_quad_no_import_no_renderFrame',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final preAttachShader = (payload['preAttachShader'] as String?) ?? '';
    final preAttachLastError = (payload['preAttachLastError'] as String?) ?? '';
    final attach = (payload['attach'] as String?) ?? '';
    final firstShaderQuad = (payload['firstShaderQuad'] as String?) ?? '';
    final secondShaderQuad = (payload['secondShaderQuad'] as String?) ?? '';
    final invalidColorShaderQuad =
        (payload['invalidColorShaderQuad'] as String?) ?? '';
    final invalidColorLastError =
        (payload['invalidColorLastError'] as String?) ?? '';
    final clearAfterShader = (payload['clearAfterShader'] as String?) ?? '';
    final hasSurfaceAfterShader = payload['hasSurfaceAfterShader'] == true;
    final surfaceKindAfterShader =
        (payload['surfaceKindAfterShader'] as String?) ?? '';
    final widthAfterShader =
        (payload['widthAfterShader'] as num?)?.toInt() ?? 0;
    final heightAfterShader =
        (payload['heightAfterShader'] as num?)?.toInt() ?? 0;
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
        preAttachShader == 'rejected_as_expected' &&
        preAttachLastError == 'no_surface_attached' &&
        attach == 'success' &&
        firstShaderQuad == 'success' &&
        secondShaderQuad == 'success' &&
        invalidColorShaderQuad == 'rejected_as_expected' &&
        invalidColorLastError == 'invalid_clear_color' &&
        clearAfterShader == 'success' &&
        hasSurfaceAfterShader &&
        surfaceKindAfterShader == 'window' &&
        widthAfterShader == 64 &&
        heightAfterShader == 64 &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        importResult == 'unavailable' &&
        renderFrameResult == 'unavailable' &&
        proofBoundary == 'gles_window_shader_quad_no_import_no_renderFrame';

    // ignore: avoid_print
    print('ANDROID_GLES_BACKEND_UNIT_X_JSON:${jsonEncode(payload)}');
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_BACKEND_UNIT_X_PHYSICAL_PASS'
          : 'ANDROID_GLES_BACKEND_UNIT_X_PHYSICAL_FAIL',
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
