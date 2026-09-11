// Copyright 2026, Connects. All rights reserved.
// Barrel file: exports all public Vanguard Duet contracts (Slice 1).
//
// Pure-Dart Duet foundation — no native implementation in this barrel.
// Universal Editor export integration is deferred to a later slice.

export 'src/duet/vg_duet_source.dart';
export 'src/duet/vg_duet_models.dart'
    show
        VGDuetSize,
        VGDuetPoint,
        VGDuetRect,
        VGDuetInsets,
        VGDuetForegroundTransform,
        VGDuetLayoutMode,
        VGDuetPiPAnchor,
        VGDuetLayoutConfig,
        VGDuetTrimWindow,
        VGDuetSegment,
        VGDuetErrorCode,
        VGDuetException,
        VGDuetPreviewTextureState,
        VGDuetPreviewTexture;
// VGDuetCompositionDescriptor and VGDuetCaptureResult live in the same file
// so that VGDuetCaptureResult.compositionDescriptor can be typed correctly.
export 'src/duet/vg_duet_composition_descriptor.dart'
    show VGDuetCompositionDescriptor, VGDuetCaptureResult;
export 'src/duet/vg_duet_layout_math.dart';
export 'src/duet/vg_duet_export_adapter.dart'
    show VGDuetEditorCompositionNode, VGDuetExportAdapter;
export 'src/duet/vg_duet_platform_interface.dart'
    show VGDuetPlatformInterface, MethodChannelVGDuetPlatform;
export 'src/duet/vg_duet_events.dart'
    show VGDuetEventType, VGDuetEvent, VGDuetEvents;
