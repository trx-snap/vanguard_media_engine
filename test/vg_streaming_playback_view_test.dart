// Copyright (c) Connects — Vanguard Phase 4C7Q.
// Public streaming playback texture view widget unit & widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackTextureView widget tests', () {
    testWidgets('renders custom placeholder when textureId is null', (
      WidgetTester tester,
    ) async {
      const snapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        session: null,
        pass: true,
        reason: 'idle',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VGStreamingPlaybackTextureView(
              snapshot: snapshot,
              placeholderBuilder: (context, snap) {
                return const Text('Custom Placeholder');
              },
            ),
          ),
        ),
      );

      expect(find.text('Custom Placeholder'), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
    });

    testWidgets(
      'renders default background box when textureId is null and no placeholderBuilder',
      (WidgetTester tester) async {
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.idle,
          session: null,
          pass: true,
          reason: 'idle',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                backgroundColor: Colors.indigo,
              ),
            ),
          ),
        );

        expect(find.byType(Texture), findsNothing);
        final coloredBoxFinder = find.descendant(
          of: find.byType(VGStreamingPlaybackTextureView),
          matching: find.byType(ColoredBox),
        );
        final coloredBox = tester.widget<ColoredBox>(coloredBoxFinder);
        expect(coloredBox.color, Colors.indigo);
      },
    );

    testWidgets(
      'renders custom error for failed state when errorBuilder provided',
      (WidgetTester tester) async {
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.failed,
          session: null,
          pass: false,
          reason: 'network_timeout',
          lastError: 'HTTP 404',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                errorBuilder: (context, snap) {
                  return Text('Error: ${snap.reason}');
                },
              ),
            ),
          ),
        );

        expect(find.text('Error: network_timeout'), findsOneWidget);
        expect(find.byType(Texture), findsNothing);
      },
    );

    testWidgets(
      'renders custom error for unsupported state when errorBuilder provided',
      (WidgetTester tester) async {
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.unsupported,
          session: null,
          pass: false,
          reason: 'unsupported_platform',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                errorBuilder: (context, snap) {
                  return const Text('Streaming Unsupported');
                },
              ),
            ),
          ),
        );

        expect(find.text('Streaming Unsupported'), findsOneWidget);
        expect(find.byType(Texture), findsNothing);
      },
    );

    testWidgets(
      'falls back to placeholder when failed/unsupported but errorBuilder is null',
      (WidgetTester tester) async {
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.failed,
          session: null,
          pass: false,
          reason: 'error_occurred',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                placeholderBuilder: (context, snap) {
                  return const Text('Fallback Placeholder');
                },
              ),
            ),
          ),
        );

        expect(find.text('Fallback Placeholder'), findsOneWidget);
      },
    );

    testWidgets(
      'renders Texture with expected texture ID when texture is active',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_123',
          textureId: 42,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1920,
          videoHeight: 1080,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        final textureFinder = find.byType(Texture);
        expect(textureFinder, findsOneWidget);
        final textureWidget = tester.widget<Texture>(textureFinder);
        expect(textureWidget.textureId, 42);
      },
    );

    testWidgets(
      'uses video dimensions from session for portrait aspect (1080x1920) without swapping',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_portrait',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1080,
          videoHeight: 1920,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        // Find the SizedBox immediately parent to the Texture
        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 1080.0);
        expect(innerSizedBox.height, 1920.0);
      },
    );

    testWidgets(
      'prefers explicit displayWidth/displayHeight over videoWidth/videoHeight',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_explicit_display',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1920,
          videoHeight: 1080,
          rotationDegrees: 90,
          displayWidth: 1080,
          displayHeight: 1920,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 1080.0);
        expect(innerSizedBox.height, 1920.0);
      },
    );

    testWidgets(
      'swaps effective display dimensions when rotationDegrees is 90 and display dimensions are absent',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_rot90',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1920,
          videoHeight: 1080,
          rotationDegrees: 90,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 1080.0);
        expect(innerSizedBox.height, 1920.0);
      },
    );

    testWidgets(
      'swaps effective display dimensions when rotationDegrees is 270 and display dimensions are absent',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_rot270',
          textureId: 10,
          format: VGStreamingFormatHint.dash,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1280,
          videoHeight: 720,
          rotationDegrees: 270,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 720.0);
        expect(innerSizedBox.height, 1280.0);
      },
    );

    testWidgets(
      'does not swap dimensions when rotationDegrees is 180 and display dimensions are absent',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_rot180',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1920,
          videoHeight: 1080,
          rotationDegrees: 180,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(snapshot: snapshot),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 1920.0);
        expect(innerSizedBox.height, 1080.0);
      },
    );

    testWidgets(
      'uses fallback size when session dimensions are zero or absent',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_nodim',
          textureId: 10,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 0,
          videoHeight: 0,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                fallbackSize: Size(4, 3),
              ),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 4.0);
        expect(innerSizedBox.height, 3.0);
      },
    );

    testWidgets(
      'uses 16x9 default fallback when fallbackSize has non-positive components',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_invalid_fallback',
          textureId: 10,
          format: VGStreamingFormatHint.dash,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 0,
          videoHeight: 0,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                fallbackSize: Size(-10, 0),
              ),
            ),
          ),
        );

        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        final innerSizedBox = sizedBoxes.firstWhere(
          (box) => box.child is Texture,
        );

        expect(innerSizedBox.width, 16.0);
        expect(innerSizedBox.height, 9.0);
      },
    );

    testWidgets(
      'preserves configured BoxFit, Alignment, background color, and clip=false',
      (WidgetTester tester) async {
        const session = VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_opts',
          textureId: 7,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          videoWidth: 1280,
          videoHeight: 720,
          raw: 'status=OK',
          diagnostics: {},
        );
        const snapshot = VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.playing,
          session: session,
          pass: true,
          reason: 'playing',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VGStreamingPlaybackTextureView(
                snapshot: snapshot,
                fit: BoxFit.cover,
                alignment: Alignment.topRight,
                backgroundColor: Colors.teal,
                clip: false,
              ),
            ),
          ),
        );

        final fittedBox = tester.widget<FittedBox>(find.byType(FittedBox));
        expect(fittedBox.fit, BoxFit.cover);
        expect(fittedBox.alignment, Alignment.topRight);

        final coloredBoxFinder = find.descendant(
          of: find.byType(VGStreamingPlaybackTextureView),
          matching: find.byType(ColoredBox),
        );
        final coloredBox = tester.widget<ColoredBox>(coloredBoxFinder);
        expect(coloredBox.color, Colors.teal);

        expect(find.byType(ClipRect), findsNothing);
      },
    );

    testWidgets('wraps content in ClipRect when clip is true', (
      WidgetTester tester,
    ) async {
      const session = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'sess_clip',
        textureId: 7,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        videoWidth: 1280,
        videoHeight: 720,
        raw: 'status=OK',
        diagnostics: {},
      );
      const snapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.playing,
        session: session,
        pass: true,
        reason: 'playing',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VGStreamingPlaybackTextureView(
              snapshot: snapshot,
              clip: true,
            ),
          ),
        ),
      );

      expect(find.byType(ClipRect), findsOneWidget);
    });
  });
}
