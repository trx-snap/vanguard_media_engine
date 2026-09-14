// Copyright 2026, Connects. All rights reserved.
// Barrel file: exports the public generic green-screen export contracts.
//
// Caller-agnostic (Duet, live meeting/calling, going live, camera, Universal
// Editor). Pure Dart except the injectable MethodChannel in the platform
// implementation. No app or editor wiring lives here.

export 'src/green_screen/vg_green_screen_models.dart'
    show
        VGGreenScreenSize,
        VGGreenScreenRect,
        VGGreenScreenScaleMode,
        VGGreenScreenBackgroundSource,
        VGGreenScreenVideoFileBackground,
        VGGreenScreenSolidColorBackground,
        VGGreenScreenImageFileBackground,
        VGGreenScreenMaskSource,
        VGGreenScreenConstantAlphaMask,
        VGGreenScreenR8FrameFilesMask,
        VGGreenScreenExportRequest,
        VGGreenScreenLaneTelemetry,
        VGGreenScreenExportResult,
        VGGreenScreenErrorCode,
        VGGreenScreenException;
export 'src/green_screen/vg_green_screen_platform_interface.dart'
    show VGGreenScreenPlatformInterface, MethodChannelVGGreenScreenPlatform;
