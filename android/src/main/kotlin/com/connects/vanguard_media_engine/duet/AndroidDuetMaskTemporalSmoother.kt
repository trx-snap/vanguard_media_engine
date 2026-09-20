package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMaskTemporalSmoother

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// mask temporal smoother.
// -----------------------------------------------------------------------------
//
// GreenScreen segmentation/matting is an independent, reusable capability and
// must not be owned by the Duet multi-input compositor package. The real
// implementation now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenMaskTemporalSmoother`.
// This alias keeps every existing Duet call site
// (`AndroidDuetMaskTemporalSmoother()`, `.DEFAULT_CURRENT_WEIGHT_Q8`,
// `.DEFAULT_MAX_GAP_MS`, `.smooth(...)`, `.reset()`) source- and
// binary-compatible without Duet owning the type.

typealias AndroidDuetMaskTemporalSmoother = AndroidGreenScreenMaskTemporalSmoother
