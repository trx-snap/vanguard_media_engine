import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesMixedTextureCompositorPhysicalSmokeApp());
}

class AndroidGlesMixedTextureCompositorPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesMixedTextureCompositorPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesMixedTextureCompositorPhysicalSmokeApp> createState() =>
      _AndroidGlesMixedTextureCompositorPhysicalSmokeAppState();
}

class _AndroidGlesMixedTextureCompositorPhysicalSmokeAppState
    extends State<AndroidGlesMixedTextureCompositorPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES mixed external/OES two-texture compositor Unit AT physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ATGlesMixedTextureCompositorSmoke',
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
        'bufferADescribe': 'not_run',
        'bufferAFormat': 0,
        'bufferAUsage': 0,
        'bufferAStride': 0,
        'bufferAFill': 'not_run',
        'bufferBDescribe': 'not_run',
        'bufferBFormat': 0,
        'bufferBUsage': 0,
        'bufferBStride': 0,
        'bufferBFill': 'not_run',
        'ycbcrBufferADescribe': 'not_run',
        'ycbcrBufferAFormat': 0,
        'ycbcrBufferAUsage': 0,
        'ycbcrFormatAIs420888': false,
        'ycbcrBufferBDescribe': 'not_run',
        'ycbcrBufferBFormat': 0,
        'ycbcrBufferBUsage': 0,
        'ycbcrFormatBIs420888': false,
        'preInitDiagnosticComposite': 'not_run',
        'preInitLastError': '',
        'initialize': 'not_run',
        'attach': 'not_run',
        'hasSurfaceAfterAttach': false,
        'surfaceKindAfterAttach': 'none',
        'widthAfterAttach': 0,
        'heightAfterAttach': 0,
        'importBufferA': 'not_run',
        'handleA': 0,
        'targetA': 0,
        'importBufferB': 'not_run',
        'handleB': 0,
        'targetB': 0,
        'importYcbcrA': 'not_run',
        'handleYcbcrA': 0,
        'targetYcbcrA': 0,
        'importYcbcrB': 'not_run',
        'handleYcbcrB': 0,
        'targetYcbcrB': 0,
        'distinctHandles': false,
        'invalidWeightDiagnosticComposite': 'not_run',
        'invalidWeightLastError': '',
        'twoDTwoDComposite': 'not_run',
        'twoDTwoDCenterRead': 'not_run',
        'twoDTwoDCenterR': 0,
        'twoDTwoDCenterG': 0,
        'twoDTwoDCenterB': 0,
        'twoDTwoDCenterA': 0,
        'twoDTwoDWeight05CenterPixelMatches': false,
        'oesTwoDComposite': 'not_run',
        'oesTwoDCenterRead': 'not_run',
        'oesTwoDCenterR': 0,
        'oesTwoDCenterG': 0,
        'oesTwoDCenterB': 0,
        'oesTwoDCenterA': 0,
        'twoDOesComposite': 'not_run',
        'twoDOesCenterRead': 'not_run',
        'twoDOesCenterR': 0,
        'twoDOesCenterG': 0,
        'twoDOesCenterB': 0,
        'twoDOesCenterA': 0,
        'oesOesComposite': 'not_run',
        'oesOesCenterRead': 'not_run',
        'oesOesCenterR': 0,
        'oesOesCenterG': 0,
        'oesOesCenterB': 0,
        'oesOesCenterA': 0,
        'releaseBufferA': 'not_run',
        'releaseBufferAFence': -1,
        'hasAAfterRelease': false,
        'releaseBufferB': 'not_run',
        'releaseBufferBFence': -1,
        'hasBAfterRelease': false,
        'releaseYcbcrA': 'not_run',
        'releaseYcbcrAFence': -1,
        'hasYcbcrAAfterRelease': false,
        'releaseYcbcrB': 'not_run',
        'releaseYcbcrBFence': -1,
        'hasYcbcrBAfterRelease': false,
        'postReleaseDiagnosticComposite': 'not_run',
        'postReleaseLastError': '',
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_mixed_texture_compositor_oes_permutation_foundation_no_color_conversion_no_product',
        'lastError': 'exception:${error.runtimeType}',
      };
    }

    final passFlag = payload['pass'] == true;
    final ycbcrAllocation = (payload['ycbcrAllocation'] as String?) ?? '';
    final clientVersion = (payload['clientVersion'] as num?)?.toInt() ?? 0;
    final vendor = (payload['vendor'] as String?) ?? '';
    final renderer = (payload['renderer'] as String?) ?? '';
    final version = (payload['version'] as String?) ?? '';
    final bufferADescribe = (payload['bufferADescribe'] as String?) ?? '';
    final bufferAFormat = (payload['bufferAFormat'] as num?)?.toInt() ?? 0;
    final bufferAUsage = (payload['bufferAUsage'] as num?)?.toInt() ?? 0;
    final bufferAStride = (payload['bufferAStride'] as num?)?.toInt() ?? 0;
    final bufferAFill = (payload['bufferAFill'] as String?) ?? '';
    final bufferBDescribe = (payload['bufferBDescribe'] as String?) ?? '';
    final bufferBFormat = (payload['bufferBFormat'] as num?)?.toInt() ?? 0;
    final bufferBUsage = (payload['bufferBUsage'] as num?)?.toInt() ?? 0;
    final bufferBStride = (payload['bufferBStride'] as num?)?.toInt() ?? 0;
    final bufferBFill = (payload['bufferBFill'] as String?) ?? '';
    final ycbcrBufferADescribe =
        (payload['ycbcrBufferADescribe'] as String?) ?? '';
    final ycbcrBufferAFormat =
        (payload['ycbcrBufferAFormat'] as num?)?.toInt() ?? 0;
    final ycbcrBufferAUsage =
        (payload['ycbcrBufferAUsage'] as num?)?.toInt() ?? 0;
    final ycbcrFormatAIs420888 = payload['ycbcrFormatAIs420888'] == true;
    final ycbcrBufferBDescribe =
        (payload['ycbcrBufferBDescribe'] as String?) ?? '';
    final ycbcrBufferBFormat =
        (payload['ycbcrBufferBFormat'] as num?)?.toInt() ?? 0;
    final ycbcrBufferBUsage =
        (payload['ycbcrBufferBUsage'] as num?)?.toInt() ?? 0;
    final ycbcrFormatBIs420888 = payload['ycbcrFormatBIs420888'] == true;
    final preInitDiagnosticComposite =
        (payload['preInitDiagnosticComposite'] as String?) ?? '';
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
    final importBufferA = (payload['importBufferA'] as String?) ?? '';
    final handleA = (payload['handleA'] as num?)?.toInt() ?? 0;
    final targetA = (payload['targetA'] as num?)?.toInt() ?? 0;
    final importBufferB = (payload['importBufferB'] as String?) ?? '';
    final handleB = (payload['handleB'] as num?)?.toInt() ?? 0;
    final targetB = (payload['targetB'] as num?)?.toInt() ?? 0;
    final importYcbcrA = (payload['importYcbcrA'] as String?) ?? '';
    final handleYcbcrA = (payload['handleYcbcrA'] as num?)?.toInt() ?? 0;
    final targetYcbcrA = (payload['targetYcbcrA'] as num?)?.toInt() ?? 0;
    final importYcbcrB = (payload['importYcbcrB'] as String?) ?? '';
    final handleYcbcrB = (payload['handleYcbcrB'] as num?)?.toInt() ?? 0;
    final targetYcbcrB = (payload['targetYcbcrB'] as num?)?.toInt() ?? 0;
    final distinctHandles = payload['distinctHandles'] == true;
    final invalidWeightDiagnosticComposite =
        (payload['invalidWeightDiagnosticComposite'] as String?) ?? '';
    final invalidWeightLastError =
        (payload['invalidWeightLastError'] as String?) ?? '';
    final twoDTwoDComposite = (payload['twoDTwoDComposite'] as String?) ?? '';
    final twoDTwoDCenterRead = (payload['twoDTwoDCenterRead'] as String?) ?? '';
    final twoDTwoDCenterR = (payload['twoDTwoDCenterR'] as num?)?.toInt() ?? 0;
    final twoDTwoDCenterG = (payload['twoDTwoDCenterG'] as num?)?.toInt() ?? 0;
    final twoDTwoDCenterB = (payload['twoDTwoDCenterB'] as num?)?.toInt() ?? 0;
    final twoDTwoDCenterA = (payload['twoDTwoDCenterA'] as num?)?.toInt() ?? 0;
    final twoDTwoDWeight05CenterPixelMatches =
        payload['twoDTwoDWeight05CenterPixelMatches'] == true;
    final oesTwoDComposite = (payload['oesTwoDComposite'] as String?) ?? '';
    final oesTwoDCenterRead = (payload['oesTwoDCenterRead'] as String?) ?? '';
    final oesTwoDCenterR = (payload['oesTwoDCenterR'] as num?)?.toInt() ?? 0;
    final oesTwoDCenterG = (payload['oesTwoDCenterG'] as num?)?.toInt() ?? 0;
    final oesTwoDCenterB = (payload['oesTwoDCenterB'] as num?)?.toInt() ?? 0;
    final oesTwoDCenterA = (payload['oesTwoDCenterA'] as num?)?.toInt() ?? 0;
    final twoDOesComposite = (payload['twoDOesComposite'] as String?) ?? '';
    final twoDOesCenterRead = (payload['twoDOesCenterRead'] as String?) ?? '';
    final twoDOesCenterR = (payload['twoDOesCenterR'] as num?)?.toInt() ?? 0;
    final twoDOesCenterG = (payload['twoDOesCenterG'] as num?)?.toInt() ?? 0;
    final twoDOesCenterB = (payload['twoDOesCenterB'] as num?)?.toInt() ?? 0;
    final twoDOesCenterA = (payload['twoDOesCenterA'] as num?)?.toInt() ?? 0;
    final oesOesComposite = (payload['oesOesComposite'] as String?) ?? '';
    final oesOesCenterRead = (payload['oesOesCenterRead'] as String?) ?? '';
    final oesOesCenterR = (payload['oesOesCenterR'] as num?)?.toInt() ?? 0;
    final oesOesCenterG = (payload['oesOesCenterG'] as num?)?.toInt() ?? 0;
    final oesOesCenterB = (payload['oesOesCenterB'] as num?)?.toInt() ?? 0;
    final oesOesCenterA = (payload['oesOesCenterA'] as num?)?.toInt() ?? 0;
    final releaseBufferA = (payload['releaseBufferA'] as String?) ?? '';
    final releaseBufferAFence =
        (payload['releaseBufferAFence'] as num?)?.toInt() ?? -1;
    final hasAAfterRelease = payload['hasAAfterRelease'] == true;
    final releaseBufferB = (payload['releaseBufferB'] as String?) ?? '';
    final releaseBufferBFence =
        (payload['releaseBufferBFence'] as num?)?.toInt() ?? -1;
    final hasBAfterRelease = payload['hasBAfterRelease'] == true;
    final releaseYcbcrA = (payload['releaseYcbcrA'] as String?) ?? '';
    final releaseYcbcrAFence =
        (payload['releaseYcbcrAFence'] as num?)?.toInt() ?? -1;
    final hasYcbcrAAfterRelease = payload['hasYcbcrAAfterRelease'] == true;
    final releaseYcbcrB = (payload['releaseYcbcrB'] as String?) ?? '';
    final releaseYcbcrBFence =
        (payload['releaseYcbcrBFence'] as num?)?.toInt() ?? -1;
    final hasYcbcrBAfterRelease = payload['hasYcbcrBAfterRelease'] == true;
    final postReleaseDiagnosticComposite =
        (payload['postReleaseDiagnosticComposite'] as String?) ?? '';
    final postReleaseLastError =
        (payload['postReleaseLastError'] as String?) ?? '';
    final detach = (payload['detach'] as String?) ?? '';
    final surfaceKindAfterDetach =
        (payload['surfaceKindAfterDetach'] as String?) ?? '';
    final shutdown = (payload['shutdown'] as String?) ?? '';
    final idempotentShutdown = (payload['idempotentShutdown'] as String?) ?? '';
    final proofBoundary = (payload['proofBoundary'] as String?) ?? '';
    final lastError = (payload['lastError'] as String?) ?? '';

    final isPass =
        passFlag &&
        ycbcrAllocation == 'success' &&
        clientVersion >= 2 &&
        vendor.isNotEmpty &&
        renderer.isNotEmpty &&
        version.isNotEmpty &&
        bufferADescribe == 'success' &&
        bufferAFormat == 1 &&
        bufferAUsage > 0 &&
        bufferAStride >= 64 &&
        bufferAFill == 'success' &&
        bufferBDescribe == 'success' &&
        bufferBFormat == 1 &&
        bufferBUsage > 0 &&
        bufferBStride >= 64 &&
        bufferBFill == 'success' &&
        ycbcrBufferADescribe == 'success' &&
        ycbcrBufferAFormat == 35 &&
        ycbcrBufferAUsage > 0 &&
        ycbcrFormatAIs420888 &&
        ycbcrBufferBDescribe == 'success' &&
        ycbcrBufferBFormat == 35 &&
        ycbcrBufferBUsage > 0 &&
        ycbcrFormatBIs420888 &&
        preInitDiagnosticComposite == 'rejected_as_expected' &&
        preInitLastError == 'backend_not_initialized' &&
        initialize == 'success' &&
        attach == 'success' &&
        hasSurfaceAfterAttach &&
        surfaceKindAfterAttach == 'window' &&
        widthAfterAttach == 64 &&
        heightAfterAttach == 64 &&
        importBufferA == 'success' &&
        handleA > 0 &&
        targetA == 0x0DE1 &&
        importBufferB == 'success' &&
        handleB > 0 &&
        targetB == 0x0DE1 &&
        importYcbcrA == 'success' &&
        handleYcbcrA > 0 &&
        targetYcbcrA == 0x8D65 &&
        importYcbcrB == 'success' &&
        handleYcbcrB > 0 &&
        targetYcbcrB == 0x8D65 &&
        distinctHandles &&
        invalidWeightDiagnosticComposite == 'rejected_as_expected' &&
        invalidWeightLastError ==
            'gles_two_texture_compositor_invalid_weight' &&
        twoDTwoDComposite == 'success' &&
        twoDTwoDCenterRead == 'success' &&
        twoDTwoDCenterR >= 100 &&
        twoDTwoDCenterR <= 155 &&
        twoDTwoDCenterG < 50 &&
        twoDTwoDCenterB >= 100 &&
        twoDTwoDCenterB <= 155 &&
        twoDTwoDCenterA > 200 &&
        twoDTwoDWeight05CenterPixelMatches &&
        oesTwoDComposite == 'success' &&
        oesTwoDCenterRead == 'success' &&
        twoDOesComposite == 'success' &&
        twoDOesCenterRead == 'success' &&
        oesOesComposite == 'success' &&
        oesOesCenterRead == 'success' &&
        releaseBufferA == 'success' &&
        releaseBufferAFence >= -1 &&
        !hasAAfterRelease &&
        releaseBufferB == 'success' &&
        releaseBufferBFence >= -1 &&
        !hasBAfterRelease &&
        releaseYcbcrA == 'success' &&
        releaseYcbcrAFence >= -1 &&
        !hasYcbcrAAfterRelease &&
        releaseYcbcrB == 'success' &&
        releaseYcbcrBFence >= -1 &&
        !hasYcbcrBAfterRelease &&
        postReleaseDiagnosticComposite == 'rejected_as_expected' &&
        postReleaseLastError == 'invalid_buffer_handle' &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_mixed_texture_compositor_oes_permutation_foundation_no_color_conversion_no_product' &&
        (lastError.isEmpty || lastError == 'none');

    // ignore: avoid_print
    print(
      'ANDROID_GLES_MIXED_TEXTURE_COMPOSITOR_UNIT_AT_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_MIXED_TEXTURE_COMPOSITOR_UNIT_AT_PHYSICAL_PASS'
          : 'ANDROID_GLES_MIXED_TEXTURE_COMPOSITOR_UNIT_AT_PHYSICAL_FAIL',
    );

    // Keep unused local variables referenced for smoke debug telemetry.
    assert(
      oesTwoDCenterR >= 0 &&
          oesTwoDCenterG >= 0 &&
          oesTwoDCenterB >= 0 &&
          oesTwoDCenterA >= 0 &&
          twoDOesCenterR >= 0 &&
          twoDOesCenterG >= 0 &&
          twoDOesCenterB >= 0 &&
          twoDOesCenterA >= 0 &&
          oesOesCenterR >= 0 &&
          oesOesCenterG >= 0 &&
          oesOesCenterB >= 0 &&
          oesOesCenterA >= 0,
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
