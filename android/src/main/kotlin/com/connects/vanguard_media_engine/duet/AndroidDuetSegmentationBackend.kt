package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenImageProxySegmentationBackend
import com.connects.vanguard_media_engine.greenscreen.GreenScreenSegmentationFailureReason
import com.connects.vanguard_media_engine.greenscreen.GreenScreenSegmentationOutcome

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible aliases onto the neutral
// green-screen ImageProxy segmentation backend contract.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation/matting is an independent, reusable capability and
// must not be owned by the Duet multi-input compositor package. The real
// contract now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenImageProxySegmentationBackend.kt`
// (interface) and `AndroidGreenScreenSegmentationTypes.kt` (outcome / failure
// reason). These aliases keep every existing Duet call site
// (`AndroidDuetSegmentationBackend`, `DuetSegmentationOutcome.Mask/.GpuMask/
// .Skipped/.Failure`, `DuetSegmentationFailureReason.*`) source- and
// binary-compatible without Duet owning the contract.

typealias DuetSegmentationOutcome = GreenScreenSegmentationOutcome

typealias DuetSegmentationFailureReason = GreenScreenSegmentationFailureReason

typealias AndroidDuetSegmentationBackend = AndroidGreenScreenImageProxySegmentationBackend
