import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidGlesTwoTextureCompositorPhysicalSmokeApp());
}

class AndroidGlesTwoTextureCompositorPhysicalSmokeApp extends StatefulWidget {
  const AndroidGlesTwoTextureCompositorPhysicalSmokeApp({super.key});

  @override
  State<AndroidGlesTwoTextureCompositorPhysicalSmokeApp> createState() =>
      _AndroidGlesTwoTextureCompositorPhysicalSmokeAppState();
}

class _AndroidGlesTwoTextureCompositorPhysicalSmokeAppState
    extends State<AndroidGlesTwoTextureCompositorPhysicalSmokeApp> {
  static const _channel = MethodChannel('vanguard_media_engine');
  String _status =
      'Running Android GLES two-texture compositor RGBA blend foundation Unit AS physical smoke...';

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    Map<String, dynamic> payload;
    try {
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke',
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
        'ycbcrBufferDescribe': 'not_run',
        'ycbcrBufferFormat': 0,
        'ycbcrBufferUsage': 0,
        'ycbcrFormatIs420888': false,
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
        'distinctHandles': false,
        'importYcbcr': 'not_run',
        'handleYcbcr': 0,
        'targetYcbcr': 0,
        'unsupportedTargetDiagnosticComposite': 'not_run',
        'unsupportedTargetLastError': '',
        'releaseYcbcr': 'not_run',
        'releaseYcbcrFence': -1,
        'hasYcbcrAfterRelease': false,
        'invalidWeightDiagnosticComposite': 'not_run',
        'invalidWeightLastError': '',
        'weight0DiagnosticComposite': 'not_run',
        'weight0CenterRead': 'not_run',
        'weight0CenterR': 0,
        'weight0CenterG': 0,
        'weight0CenterB': 0,
        'weight0CenterA': 0,
        'weight0CenterPixelMatches': false,
        'weight1DiagnosticComposite': 'not_run',
        'weight1CenterRead': 'not_run',
        'weight1CenterR': 0,
        'weight1CenterG': 0,
        'weight1CenterB': 0,
        'weight1CenterA': 0,
        'weight1CenterPixelMatches': false,
        'weight05DiagnosticComposite': 'not_run',
        'weight05CenterRead': 'not_run',
        'weight05CenterR': 0,
        'weight05CenterG': 0,
        'weight05CenterB': 0,
        'weight05CenterA': 0,
        'weight05CenterPixelMatches': false,
        'presentComposite': 'not_run',
        'presentCompositeLastError': '',
        'releaseBufferA': 'not_run',
        'releaseBufferAFence': -1,
        'hasAAfterRelease': false,
        'releaseBufferB': 'not_run',
        'releaseBufferBFence': -1,
        'hasBAfterRelease': false,
        'postReleaseDiagnosticComposite': 'not_run',
        'postReleaseLastError': '',
        'detach': 'not_run',
        'surfaceKindAfterDetach': 'none',
        'shutdown': 'not_run',
        'idempotentShutdown': 'not_run',
        'proofBoundary':
            'gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product',
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
    final ycbcrBufferDescribe =
        (payload['ycbcrBufferDescribe'] as String?) ?? '';
    final ycbcrBufferFormat =
        (payload['ycbcrBufferFormat'] as num?)?.toInt() ?? 0;
    final ycbcrBufferUsage =
        (payload['ycbcrBufferUsage'] as num?)?.toInt() ?? 0;
    final ycbcrFormatIs420888 = payload['ycbcrFormatIs420888'] == true;
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
    final distinctHandles = payload['distinctHandles'] == true;
    final importYcbcr = (payload['importYcbcr'] as String?) ?? '';
    final handleYcbcr = (payload['handleYcbcr'] as num?)?.toInt() ?? 0;
    final targetYcbcr = (payload['targetYcbcr'] as num?)?.toInt() ?? 0;
    final unsupportedTargetDiagnosticComposite =
        (payload['unsupportedTargetDiagnosticComposite'] as String?) ?? '';
    final unsupportedTargetLastError =
        (payload['unsupportedTargetLastError'] as String?) ?? '';
    final releaseYcbcr = (payload['releaseYcbcr'] as String?) ?? '';
    final releaseYcbcrFence =
        (payload['releaseYcbcrFence'] as num?)?.toInt() ?? -1;
    final hasYcbcrAfterRelease = payload['hasYcbcrAfterRelease'] == true;
    final invalidWeightDiagnosticComposite =
        (payload['invalidWeightDiagnosticComposite'] as String?) ?? '';
    final invalidWeightLastError =
        (payload['invalidWeightLastError'] as String?) ?? '';
    final weight0DiagnosticComposite =
        (payload['weight0DiagnosticComposite'] as String?) ?? '';
    final weight0CenterRead = (payload['weight0CenterRead'] as String?) ?? '';
    final weight0CenterR = (payload['weight0CenterR'] as num?)?.toInt() ?? 0;
    final weight0CenterG = (payload['weight0CenterG'] as num?)?.toInt() ?? 0;
    final weight0CenterB = (payload['weight0CenterB'] as num?)?.toInt() ?? 0;
    final weight0CenterA = (payload['weight0CenterA'] as num?)?.toInt() ?? 0;
    final weight0CenterPixelMatches =
        payload['weight0CenterPixelMatches'] == true;
    final weight1DiagnosticComposite =
        (payload['weight1DiagnosticComposite'] as String?) ?? '';
    final weight1CenterRead = (payload['weight1CenterRead'] as String?) ?? '';
    final weight1CenterR = (payload['weight1CenterR'] as num?)?.toInt() ?? 0;
    final weight1CenterG = (payload['weight1CenterG'] as num?)?.toInt() ?? 0;
    final weight1CenterB = (payload['weight1CenterB'] as num?)?.toInt() ?? 0;
    final weight1CenterA = (payload['weight1CenterA'] as num?)?.toInt() ?? 0;
    final weight1CenterPixelMatches =
        payload['weight1CenterPixelMatches'] == true;
    final weight05DiagnosticComposite =
        (payload['weight05DiagnosticComposite'] as String?) ?? '';
    final weight05CenterRead = (payload['weight05CenterRead'] as String?) ?? '';
    final weight05CenterR = (payload['weight05CenterR'] as num?)?.toInt() ?? 0;
    final weight05CenterG = (payload['weight05CenterG'] as num?)?.toInt() ?? 0;
    final weight05CenterB = (payload['weight05CenterB'] as num?)?.toInt() ?? 0;
    final weight05CenterA = (payload['weight05CenterA'] as num?)?.toInt() ?? 0;
    final weight05CenterPixelMatches =
        payload['weight05CenterPixelMatches'] == true;
    final presentComposite = (payload['presentComposite'] as String?) ?? '';
    final presentCompositeLastError =
        (payload['presentCompositeLastError'] as String?) ?? '';
    final releaseBufferA = (payload['releaseBufferA'] as String?) ?? '';
    final releaseBufferAFence =
        (payload['releaseBufferAFence'] as num?)?.toInt() ?? -1;
    final hasAAfterRelease = payload['hasAAfterRelease'] == true;
    final releaseBufferB = (payload['releaseBufferB'] as String?) ?? '';
    final releaseBufferBFence =
        (payload['releaseBufferBFence'] as num?)?.toInt() ?? -1;
    final hasBAfterRelease = payload['hasBAfterRelease'] == true;
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
        ycbcrBufferDescribe == 'success' &&
        ycbcrBufferFormat == 35 &&
        ycbcrBufferUsage > 0 &&
        ycbcrFormatIs420888 &&
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
        distinctHandles &&
        importYcbcr == 'success' &&
        handleYcbcr > 0 &&
        targetYcbcr == 0x8D65 &&
        unsupportedTargetDiagnosticComposite == 'rejected_as_expected' &&
        unsupportedTargetLastError ==
            'gles_two_texture_compositor_unsupported_texture_target' &&
        releaseYcbcr == 'success' &&
        releaseYcbcrFence >= -1 &&
        !hasYcbcrAfterRelease &&
        invalidWeightDiagnosticComposite == 'rejected_as_expected' &&
        invalidWeightLastError ==
            'gles_two_texture_compositor_invalid_weight' &&
        weight0DiagnosticComposite == 'success' &&
        weight0CenterRead == 'success' &&
        weight0CenterR > 200 &&
        weight0CenterG < 50 &&
        weight0CenterB < 50 &&
        weight0CenterA > 200 &&
        weight0CenterPixelMatches &&
        weight1DiagnosticComposite == 'success' &&
        weight1CenterRead == 'success' &&
        weight1CenterR < 50 &&
        weight1CenterG < 50 &&
        weight1CenterB > 200 &&
        weight1CenterA > 200 &&
        weight1CenterPixelMatches &&
        weight05DiagnosticComposite == 'success' &&
        weight05CenterRead == 'success' &&
        weight05CenterR >= 100 &&
        weight05CenterR <= 155 &&
        weight05CenterG < 50 &&
        weight05CenterB >= 100 &&
        weight05CenterB <= 155 &&
        weight05CenterA > 200 &&
        weight05CenterPixelMatches &&
        presentComposite == 'success' &&
        (presentCompositeLastError.isEmpty ||
            presentCompositeLastError == 'none') &&
        releaseBufferA == 'success' &&
        releaseBufferAFence >= -1 &&
        !hasAAfterRelease &&
        releaseBufferB == 'success' &&
        releaseBufferBFence >= -1 &&
        !hasBAfterRelease &&
        postReleaseDiagnosticComposite == 'rejected_as_expected' &&
        postReleaseLastError == 'invalid_buffer_handle' &&
        detach == 'success' &&
        surfaceKindAfterDetach == 'offscreen' &&
        shutdown == 'success' &&
        idempotentShutdown == 'success' &&
        proofBoundary ==
            'gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product';

    // ignore: avoid_print
    print(
      'ANDROID_GLES_TWO_TEXTURE_COMPOSITOR_UNIT_AS_JSON:${jsonEncode(payload)}',
    );
    // ignore: avoid_print
    print(
      isPass
          ? 'ANDROID_GLES_TWO_TEXTURE_COMPOSITOR_UNIT_AS_PHYSICAL_PASS'
          : 'ANDROID_GLES_TWO_TEXTURE_COMPOSITOR_UNIT_AS_PHYSICAL_FAIL',
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
