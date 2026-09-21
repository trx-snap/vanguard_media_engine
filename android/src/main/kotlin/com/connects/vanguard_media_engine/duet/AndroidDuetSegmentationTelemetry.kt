package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenSegmentationTelemetry

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// segmentation completion telemetry.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation telemetry is an independent, reusable capability
// and must not be owned by the Duet multi-input compositor package. The real
// implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenSegmentationTelemetry`.
// This alias keeps every existing Duet call site
// (`AndroidDuetSegmentationTelemetry()`) source- and binary-compatible
// without Duet owning the telemetry.

internal typealias AndroidDuetSegmentationTelemetry = AndroidGreenScreenSegmentationTelemetry
