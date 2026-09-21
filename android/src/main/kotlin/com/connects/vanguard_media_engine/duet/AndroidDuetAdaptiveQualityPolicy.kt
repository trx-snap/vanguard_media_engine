package com.connects.vanguard_media_engine.duet

import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenAdaptiveQualityPolicy

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Source-compatible alias onto the neutral green-screen
// adaptive quality-tier policy.
// -----------------------------------------------------------------------------
//
// GreenScreen adaptive quality policy (pacing, thermal adaptation, inference-
// budget monitoring) is an independent, reusable capability and must not be
// owned by the Duet multi-input compositor package. The real implementation
// now lives in
// `com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenAdaptiveQualityPolicy`.
// This alias keeps every existing Duet call site
// (`AndroidDuetAdaptiveQualityPolicy(context)`) source- and binary-compatible
// without Duet owning the policy. Note: the neutral implementation now uses
// its own self-contained `GreenScreenSegmentationQuality` enum internally
// instead of the duet-owned `DuetSegmentationQuality`; every existing caller
// of `.currentQuality` only ever reads `.key` (verified), so this is
// source-compatible in practice. `DuetSegmentationQuality` itself remains
// defined in AndroidDuetGreenScreenCapability.kt, unaffected by this alias.

typealias AndroidDuetAdaptiveQualityPolicy = AndroidGreenScreenAdaptiveQualityPolicy
