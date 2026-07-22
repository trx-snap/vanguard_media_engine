// vg_editor_controller_slice_r_test.dart
// Vanguard Media Engine — Phase 10-C Slice R
//
// Focused Dart tests verifying that VGEditorController accepts an injected
// previewDraftDeriver and uses it during initialize() and updateDraft(),
// while defaulting to standard derivation when null.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

VGClipDescriptor _clip({required String id, double trimEnd = 5.0}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture_$id.mp4',
      durationSeconds: trimEnd,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        (call) => handler(call.method, call.arguments),
      );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('vanguard_media_engine'),
        null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(_clearMockHandler);

  test(
    'SR-V1 VGEditorController uses injected previewDraftDeriver on initialize',
    () async {
      final rawDraft = VGEditorDraft(
        id: 'draft-sr1',
        clips: [_clip(id: 'clip-1', trimEnd: 4.0)],
      );

      bool deriverCalled = false;
      VGEditorDraft customDeriver(VGEditorDraft source) {
        deriverCalled = true;
        return source.copyWith(id: 'derived-draft-sr1');
      }

      dynamic capturedDraftMap;
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          capturedDraftMap = (args as Map)['draft'];
          return {'textureId': 42, 'width': 1280, 'height': 720};
        }
        return null;
      });

      final controller = VGEditorController(
        initialDraft: rawDraft,
        previewDraftDeriver: customDeriver,
      );

      await controller.initialize();

      expect(deriverCalled, isTrue);
      expect(capturedDraftMap['id'], equals('derived-draft-sr1'));
      expect(
        controller.draft.id,
        equals('draft-sr1'),
        reason: 'raw authoring draft in controller must remain unchanged',
      );
    },
  );

  test(
    'SR-V2 VGEditorController uses injected previewDraftDeriver on updateDraft',
    () async {
      final initialDraft = VGEditorDraft(
        id: 'draft-sr2-init',
        clips: [_clip(id: 'clip-1', trimEnd: 4.0)],
      );
      final nextDraft = VGEditorDraft(
        id: 'draft-sr2-next',
        clips: [
          _clip(id: 'clip-1', trimEnd: 4.0),
          _clip(id: 'clip-2', trimEnd: 2.0),
        ],
      );

      int deriverCallCount = 0;
      VGEditorDraft customDeriver(VGEditorDraft source) {
        deriverCallCount++;
        return source.copyWith(id: 'derived-${source.id}');
      }

      dynamic capturedDraftMap;
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          return {'textureId': 42, 'width': 1280, 'height': 720};
        }
        if (method == 'updateTimeline') {
          capturedDraftMap = (args as Map)['draft'];
          return {'textureId': 42, 'width': 1280, 'height': 720};
        }
        return null;
      });

      final controller = VGEditorController(
        initialDraft: initialDraft,
        previewDraftDeriver: customDeriver,
      );

      await controller.initialize();
      expect(deriverCallCount, equals(1));

      await controller.updateDraft(nextDraft);
      expect(deriverCallCount, equals(2));
      expect(capturedDraftMap['id'], equals('derived-draft-sr2-next'));
      expect(controller.draft.id, equals('draft-sr2-next'));
    },
  );

  test(
    'SR-V3 VGEditorController defaults to standard preview derivation when previewDraftDeriver is null',
    () async {
      final rawDraft = VGEditorDraft(
        id: 'draft-sr3-default',
        clips: [_clip(id: 'clip-1', trimEnd: 4.0)],
      );

      dynamic capturedDraftMap;
      _setMockHandler((method, args) async {
        if (method == 'createTimelineTexture') {
          capturedDraftMap = (args as Map)['draft'];
          return {'textureId': 42, 'width': 1280, 'height': 720};
        }
        return null;
      });

      final controller = VGEditorController(initialDraft: rawDraft);

      await controller.initialize();

      expect(capturedDraftMap, isNotNull);
      final sidecar = capturedDraftMap['audioSidecar'] as Map?;
      expect(
        sidecar,
        isNotNull,
        reason: 'default derivation flattens original clip audio',
      );
      final tracks = sidecar!['tracks'] as List;
      expect(tracks.length, equals(1));
      expect((tracks.first as Map)['role'], equals('original'));
    },
  );
}
