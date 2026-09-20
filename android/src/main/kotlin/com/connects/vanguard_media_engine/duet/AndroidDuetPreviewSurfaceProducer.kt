package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// Source-compatible aliases: SurfaceProducer ownership moved to
// camera/AndroidPreviewSurfaceProducer.kt (background/transform/layout/
// surface-contract ownership slice, following segmentation/mask/smoother).
// -----------------------------------------------------------------------------
//
// These aliases exist solely so existing Duet call sites (e.g.
// AndroidDuetPreviewCompositor.kt, AndroidDuetSessionCoordinator.kt) keep
// compiling unchanged. Do not add new logic here; the real producer and its
// state machine live in camera/AndroidPreviewSurfaceProducer.kt.

import com.connects.vanguard_media_engine.camera.AndroidPreviewSurfaceProducer
import com.connects.vanguard_media_engine.camera.AndroidPreviewSurfaceState

typealias DuetSurfaceState = AndroidPreviewSurfaceState
typealias AndroidDuetPreviewSurfaceProducer = AndroidPreviewSurfaceProducer
