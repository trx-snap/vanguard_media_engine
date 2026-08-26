// Copyright (c) Connects — Vanguard Phase 7.8C.
// Public editor texture presentation view widget unit & widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGEditorTextureView widget tests', () {
    VGEditorDraft createDraft({
      int canvasWidth = 1080,
      int canvasHeight = 1920,
    }) {
      return VGEditorDraft(
        id: 'draft-test-1',
        clips: [
          VGClipDescriptor(
            id: 'clip-1',
            sourcePath: '/tmp/test.mp4',
            durationSeconds: 5.0,
            trimEndSeconds: 5.0,
          ),
        ],
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
      );
    }

    testWidgets('renders custom placeholder when textureId is null', (
      WidgetTester tester,
    ) async {
      final draft = createDraft();
      final value = VGEditorValue.initial(draft);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VGEditorTextureView(
              value: value,
              placeholderBuilder: (context) {
                return const Text('Editor Placeholder');
              },
            ),
          ),
        ),
      );

      expect(find.text('Editor Placeholder'), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
    });

    testWidgets(
      'renders default background box when textureId is null and no placeholderBuilder',
      (WidgetTester tester) async {
        final draft = createDraft();
        final value = VGEditorValue.initial(draft);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VGEditorTextureView(
                value: value,
                backgroundColor: Colors.deepPurple,
              ),
            ),
          ),
        );

        expect(find.byType(Texture), findsNothing);
        final coloredBoxFinder = find.descendant(
          of: find.byType(VGEditorTextureView),
          matching: find.byType(ColoredBox),
        );
        final coloredBox = tester.widget<ColoredBox>(coloredBoxFinder);
        expect(coloredBox.color, Colors.deepPurple);
      },
    );

    testWidgets(
      'renders Texture with expected texture ID when texture is active',
      (WidgetTester tester) async {
        final draft = createDraft();
        final value = VGEditorValue(
          draft: draft,
          textureId: 42,
          renderWidth: 1080,
          renderHeight: 1920,
          isReady: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: VGEditorTextureView(value: value)),
          ),
        );

        final textureFinder = find.byType(Texture);
        expect(textureFinder, findsOneWidget);
        final textureWidget = tester.widget<Texture>(textureFinder);
        expect(textureWidget.textureId, 42);
      },
    );

    testWidgets('uses native render dimensions when present and positive', (
      WidgetTester tester,
    ) async {
      final draft = createDraft(canvasWidth: 640, canvasHeight: 360);
      final value = VGEditorValue(
        draft: draft,
        textureId: 10,
        renderWidth: 1080,
        renderHeight: 1920,
        isReady: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VGEditorTextureView(value: value)),
        ),
      );

      final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
      final innerSizedBox = sizedBoxes.firstWhere(
        (box) => box.child is Texture,
      );

      expect(innerSizedBox.width, 1080.0);
      expect(innerSizedBox.height, 1920.0);
    });

    testWidgets(
      'falls back to draft canvas dimensions when native dimensions absent',
      (WidgetTester tester) async {
        final draft = createDraft(canvasWidth: 1280, canvasHeight: 720);
        final value = VGEditorValue(
          draft: draft,
          textureId: 10,
          renderWidth: null,
          renderHeight: null,
          isReady: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: VGEditorTextureView(value: value)),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 1280.0);
        expect(innerSizedBox.height, 720.0);
      },
    );

    testWidgets(
      'honors BoxFit.cover and Alignment.topCenter for immersive callers',
      (WidgetTester tester) async {
        final draft = createDraft();
        final value = VGEditorValue(
          draft: draft,
          textureId: 7,
          renderWidth: 1080,
          renderHeight: 1920,
          isReady: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VGEditorTextureView(
                value: value,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                backgroundColor: Colors.teal,
                clip: false,
              ),
            ),
          ),
        );

        final fittedBox = tester.widget<FittedBox>(find.byType(FittedBox));
        expect(fittedBox.fit, BoxFit.cover);
        expect(fittedBox.alignment, Alignment.topCenter);

        final coloredBoxFinder = find.descendant(
          of: find.byType(VGEditorTextureView),
          matching: find.byType(ColoredBox),
        );
        final coloredBox = tester.widget<ColoredBox>(coloredBoxFinder);
        expect(coloredBox.color, Colors.teal);

        expect(find.byType(ClipRect), findsNothing);
      },
    );

    testWidgets('uses default parameters (fit, alignment, background, clip)', (
      WidgetTester tester,
    ) async {
      final draft = createDraft();
      final value = VGEditorValue(
        draft: draft,
        textureId: 7,
        renderWidth: 1080,
        renderHeight: 1920,
        isReady: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VGEditorTextureView(value: value)),
        ),
      );

      final fittedBox = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fittedBox.fit, BoxFit.contain);
      expect(fittedBox.alignment, Alignment.center);

      final coloredBoxFinder = find.descendant(
        of: find.byType(VGEditorTextureView),
        matching: find.byType(ColoredBox),
      );
      final coloredBox = tester.widget<ColoredBox>(coloredBoxFinder);
      expect(coloredBox.color, Colors.black);

      expect(find.byType(ClipRect), findsOneWidget);
    });

    testWidgets('wraps content in ClipRect when clip is true', (
      WidgetTester tester,
    ) async {
      final draft = createDraft();
      final value = VGEditorValue(
        draft: draft,
        textureId: 7,
        renderWidth: 1080,
        renderHeight: 1920,
        isReady: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VGEditorTextureView(value: value, clip: true)),
        ),
      );

      expect(find.byType(ClipRect), findsOneWidget);
    });

    testWidgets('does not wrap in ClipRect when clip is false', (
      WidgetTester tester,
    ) async {
      final draft = createDraft();
      final value = VGEditorValue(
        draft: draft,
        textureId: 7,
        renderWidth: 1080,
        renderHeight: 1920,
        isReady: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VGEditorTextureView(value: value, clip: false)),
        ),
      );

      expect(find.byType(ClipRect), findsNothing);
    });
  });
}
