package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// Source-compatible aliases: green-screen background ownership moved to
// greenscreen/AndroidGreenScreenBackground.kt (background/transform/layout/
// surface-contract ownership slice, following segmentation/mask/smoother).
// -----------------------------------------------------------------------------
//
// These aliases exist solely so existing Duet call sites (e.g.
// AndroidDuetPreviewCompositor.kt, AndroidDuetPreviewRenderLoop.kt,
// AndroidDuetSessionCoordinator.kt, AndroidDuetExportSession.kt) keep
// compiling unchanged. Do not add new logic here; the real model, its
// companion `VIDEO` default, and `parse(map)` live in
// greenscreen/AndroidGreenScreenBackground.kt.

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenBackground
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenBackgroundScaleMode
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenBackgroundType

typealias AndroidDuetGreenScreenBackgroundType = AndroidGreenScreenBackgroundType
typealias AndroidDuetBackgroundScaleMode = AndroidGreenScreenBackgroundScaleMode
typealias AndroidDuetGreenScreenBackground = AndroidGreenScreenBackground
