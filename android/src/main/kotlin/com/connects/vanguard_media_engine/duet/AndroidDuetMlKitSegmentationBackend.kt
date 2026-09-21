package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMlKitSegmentationBackend

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// ML Kit Selfie Segmentation backend.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation is an independent, reusable capability and must
// not be owned by the Duet multi-input compositor package. The real
// implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMlKitSegmentationBackend`.
// This alias keeps every existing Duet call site
// (`AndroidDuetMlKitSegmentationBackend()`) source- and binary-compatible
// without Duet owning the backend.

typealias AndroidDuetMlKitSegmentationBackend = AndroidGreenScreenMlKitSegmentationBackend
