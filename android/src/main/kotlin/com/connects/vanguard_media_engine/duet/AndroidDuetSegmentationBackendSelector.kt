package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenImageProxyBackendSelector

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// ImageProxy backend ladder selector.
// -----------------------------------------------------------------------------
//
// GreenScreen's ImageProxy backend ladder (mediapipe_cpu -> mlkit -> none/PiP,
// with raw_tflite_gpu as a debug/smoke opt-in rung) is an independent,
// reusable capability and must not be owned by the Duet multi-input
// compositor package. The real implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenImageProxyBackendSelector`.
// This alias keeps every existing Duet call site
// (`AndroidDuetSegmentationBackendSelector(context, ...)`, `.primaryBackendId()`,
// `.nextBackendId(id)`, `.supports(id)`, `.createBackend(id)`,
// `.MEDIAPIPE_MODEL_ALLOWLIST`, `.RAW_TFLITE_GPU_MODEL_ALLOWLIST`,
// `.TFLITE_GPU_MODEL_ASSET_PATH`) source- and binary-compatible without Duet
// owning the ladder.

typealias AndroidDuetSegmentationBackendSelector = AndroidGreenScreenImageProxyBackendSelector
