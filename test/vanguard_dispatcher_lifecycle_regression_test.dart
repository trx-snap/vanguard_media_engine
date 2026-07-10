// vanguard_dispatcher_lifecycle_regression_test.dart
// Vanguard Media Engine — Dispatcher Lifecycle Regression Tests
//
// Coverage:
//   DREG-1: VanguardChannelDispatcher.instance is accessible from the internal
//           src path (confirms the dispatcher is importable to its own
//           consumers but not forced through the public barrel).
//   DREG-2: After VGEditorController.initialize(), the dispatcher has a live
//           timeline subscription for the returned textureId and delivers
//           onTimelineFrame callbacks to the controller.
//   DREG-3: After VGEditorController.dispose(), the timeline subscription is
//           unregistered — onTimelineFrame callbacks are no longer delivered.
//   DREG-4: After VanguardTimelineExporter.exportDraft() completes, the
//           export subscription is unregistered — stale progress callbacks
//           are not delivered.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Internal src import — correct for within-package consumers and tests.
import 'package:vanguard_media_engine/src/channel/vanguard_channel_dispatcher.dart';

import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';
import 'package:vanguard_media_engine/vg_editor_export_request.dart';
import 'package:vanguard_media_engine/vg_timeline_exporter.dart';

const _kChannel = MethodChannel('vanguard_media_engine');

Future<void> _invokeNative(String method, [dynamic arguments]) async {
  final codec = const StandardMethodCodec();
  final data = codec.encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('vanguard_media_engine', data, (ByteData? reply) {});
}

void _setMockHandler(Future<Object?> Function(String method, dynamic args) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kChannel, (call) => handler(call.method, call.arguments));
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kChannel, null);
}

VGEditorDraft _makeDraft() => VGEditorDraft(
      id: 'dreg-draft',
      clips: [
        VGClipDescriptor(
          id: 'clip-dreg',
          sourcePath: '/tmp/dreg.mp4',
          durationSeconds: 5.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 5.0,
        ),
      ],
      canvasWidth: 1080,
      canvasHeight: 1920,
      fps: 30,
    );

VGEditorExportRequest _makeExportRequest() => const VGEditorExportRequest(
      outputPath: '/tmp/dreg_out.mp4',
      bitrateBps: 8000000,
    );

Map<String, dynamic> _exportSuccessResponse() => {
      'success': true,
      'path': '/tmp/dreg_out.mp4',
      'durationSeconds': 5.0,
      'width': 1080,
      'height': 1920,
      'fps': 30,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    VanguardChannelDispatcher.instance.resetForTesting();
  });

  tearDown(() {
    _clearMockHandler();
    VanguardChannelDispatcher.instance.resetForTesting();
  });

  // DREG-1 ────────────────────────────────────────────────────────────────────

  test('DREG-1: VanguardChannelDispatcher.instance is accessible via src path', () {
    // If this compiles, the src import path is valid.
    // The dispatcher must NOT be imported via the public barrel.
    final dispatcher = VanguardChannelDispatcher.instance;
    expect(dispatcher, isNotNull);
    // Starts idle — handler only registered on first consumer.
    expect(dispatcher.isHandlerRegistered, isFalse);
    // No timeline listener exists before any controller is initialized.
    expect(dispatcher.hasTimelineListenerForTesting(42), isFalse,
        reason: 'No timeline listener must exist in a freshly-reset dispatcher');
    // No export listener exists before any export is started.
    expect(dispatcher.hasExportListenerForTesting, isFalse,
        reason: 'No export listener must exist in a freshly-reset dispatcher');
  });

  // DREG-2 ────────────────────────────────────────────────────────────────────

  test(
    'DREG-2: VGEditorController.initialize() registers a live dispatcher subscription',
    () async {
      const kTextureId = 77;
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {'textureId': kTextureId, 'width': 1080, 'height': 1920};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _makeDraft());
      await controller.initialize();

      expect(controller.value.isReady, isTrue);
      expect(controller.value.textureId, kTextureId);

      double? receivedPts;
      controller.addListener(() {
        receivedPts = controller.value.currentPTS;
      });

      await _invokeNative('onTimelineFrame', {
        'textureId': kTextureId,
        'pts': 2.5,
        'generation': 1,
      });

      expect(receivedPts, closeTo(2.5, 0.001),
          reason: 'onTimelineFrame must reach controller via dispatcher');

      controller.dispose();
    },
  );

  // DREG-3 ────────────────────────────────────────────────────────────────────

  test(
    'DREG-3: VGEditorController.dispose() unregisters the dispatcher subscription',
    () async {
      const kTextureId = 88;
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {'textureId': kTextureId, 'width': 1080, 'height': 1920};
        }
        if (method == 'disposeTimeline') return null;
        return null;
      });

      final controller = VGEditorController(initialDraft: _makeDraft());
      await controller.initialize();

      // Direct state assertion: subscription registered for kTextureId.
      expect(
        VanguardChannelDispatcher.instance
            .hasTimelineListenerForTesting(kTextureId),
        isTrue,
        reason: 'Timeline listener must be registered for kTextureId after initialize()',
      );

      controller.dispose();

      // Direct state assertion: subscription cleared after dispose.
      expect(
        VanguardChannelDispatcher.instance
            .hasTimelineListenerForTesting(kTextureId),
        isFalse,
        reason: 'Timeline listener must be cleared for kTextureId after dispose()',
      );

      // Behavioral check: injecting a frame callback must complete silently
      // (no active listener for kTextureId — dispatcher drops it).
      await expectLater(
        _invokeNative('onTimelineFrame', {
          'textureId': kTextureId,
          'pts': 3.0,
          'generation': 2,
        }),
        completes,
        reason: 'Dispatcher must silently drop callbacks for unregistered '
            'textureId after controller dispose',
      );
    },
  );

  // DREG-4 ────────────────────────────────────────────────────────────────────

  test(
    'DREG-4: VanguardTimelineExporter.exportDraft() releases export subscription on completion',
    () async {
      _setMockHandler((method, args) async {
        if (method == 'exportTimeline') return _exportSuccessResponse();
        return null;
      });

      await VanguardTimelineExporter.exportDraft(
        draft: _makeDraft(),
        request: _makeExportRequest(),
        channel: _kChannel,
      );

      // Direct state assertion: export slot released by the finally block.
      expect(
        VanguardChannelDispatcher.instance.hasExportListenerForTesting,
        isFalse,
        reason: 'Export listener must be cleared after exportDraft() completes',
      );

      // Behavioral check: the slot is free — a freshly registered listener
      // receives events.
      var progressReceived = false;
      final sub = VanguardChannelDispatcher.instance.registerExportListener(
        (progress) => progressReceived = true,
      );

      await _invokeNative('onExportProgress', 0.5);

      expect(progressReceived, isTrue,
          reason:
              'Freshly registered listener must receive event — confirming the '
              'exporter released the slot in its finally block');

      VanguardChannelDispatcher.instance.unregisterExportListener(sub);
    },
  );
}
