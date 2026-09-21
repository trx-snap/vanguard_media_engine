package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenRawTfliteGpuPhaseTelemetry

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// raw_tflite_gpu per-phase latency telemetry.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation telemetry is an independent, reusable capability
// and must not be owned by the Duet multi-input compositor package. The real
// implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenRawTfliteGpuPhaseTelemetry`.
// This alias keeps every existing Duet call site
// (`AndroidDuetRawTfliteGpuPhaseTelemetry()`) source- and binary-compatible
// without Duet owning the telemetry.

internal typealias AndroidDuetRawTfliteGpuPhaseTelemetry = AndroidGreenScreenRawTfliteGpuPhaseTelemetry
