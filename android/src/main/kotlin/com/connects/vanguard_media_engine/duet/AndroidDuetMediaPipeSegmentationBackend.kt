package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMediaPipeSegmentationBackend

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// MediaPipe Tasks Vision ImageSegmenter backend.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation is an independent, reusable capability and must
// not be owned by the Duet multi-input compositor package. The real
// implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMediaPipeSegmentationBackend`.
// This alias keeps every existing Duet call site
// (`AndroidDuetMediaPipeSegmentationBackend.gpu(...)`/`.cpu(...)`)
// source- and binary-compatible without Duet owning the backend.

typealias AndroidDuetMediaPipeSegmentationBackend = AndroidGreenScreenMediaPipeSegmentationBackend
