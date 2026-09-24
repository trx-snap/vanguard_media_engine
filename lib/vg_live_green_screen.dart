// Copyright 2026, Connects. All rights reserved.
// Barrel file: exports the public generic live green-screen contracts.
//
// Caller-agnostic (live meeting/calling, going live, camera, Universal
// Editor). Separate from the offline export barrel (vg_green_screen.dart) and
// from Duet. Pure Dart except the injectable MethodChannel in the platform
// implementation. No app or editor wiring lives here. Android first; iOS is
// deferred.

export 'src/green_screen/vg_live_green_screen_models.dart'
    show
        VGLiveGreenScreenForegroundTransform,
        VGLiveGreenScreenConfig,
        VGLiveGreenScreenSession,
        VGLiveGreenScreenRecordingResult,
        VGLiveGreenScreenPhotoResult,
        VGLiveGreenScreenErrorCode,
        VGLiveGreenScreenException;
export 'src/green_screen/vg_live_green_screen_platform_interface.dart'
    show
        VGLiveGreenScreenPlatformInterface,
        MethodChannelVGLiveGreenScreenPlatform;
export 'src/green_screen/vg_live_green_screen_events.dart'
    show
        VGLiveGreenScreenEventType,
        VGLiveGreenScreenEvent,
        VGLiveGreenScreenEvents;
