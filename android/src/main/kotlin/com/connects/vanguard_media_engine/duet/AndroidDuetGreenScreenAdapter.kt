package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenFilterNode

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// CameraX filter node.
// -----------------------------------------------------------------------------
//
// The CameraX/ImageProxy green-screen analyzer and backend ladder is an
// independent, reusable capability and must not be owned by the Duet
// multi-input compositor package. The real implementation (the single
// CameraX `ImageAnalysis.Analyzer` that owns drop-stale, lazy backend open,
// temporal smoothing, telemetry, and degrade/fallback) now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenFilterNode`.
// This alias keeps every existing Duet call site
// (`AndroidDuetGreenScreenAdapter(selector, initialBackendId, onMask, onGpuMask,
// onDegraded, onFallback)`, `.start()`, `.stop()`, `.currentBackendId`,
// `.isDegraded`, `.isTerminal`, `.degradedUserMessage(...)`) source- and
// binary-compatible without Duet owning the analyzer.

typealias AndroidDuetGreenScreenAdapter = AndroidGreenScreenFilterNode
