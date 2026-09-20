package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenSegmentationFrame
import com.connects.vanguard_media_engine.greenscreen.GreenScreenSegmentationMaskFormat

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible aliases onto the neutral
// green-screen segmentation contract.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation/matting is an independent, reusable capability and
// must not be owned by the Duet multi-input compositor package. The real
// contract now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenSegmentationTypes.kt`
// ([AndroidGreenScreenSegmentationFrame], [GreenScreenSegmentationMaskFormat]).
// These aliases keep every existing Duet call site
// (`AndroidDuetSegmentationFrame.copyFrom`/`.adoptOwned`,
// `DuetSegmentationMaskFormat.UINT8_ALPHA`/`.FLOAT32_CONFIDENCE`, etc.)
// source- and binary-compatible without Duet owning the type.

typealias DuetSegmentationMaskFormat = GreenScreenSegmentationMaskFormat

typealias AndroidDuetSegmentationFrame = AndroidGreenScreenSegmentationFrame
