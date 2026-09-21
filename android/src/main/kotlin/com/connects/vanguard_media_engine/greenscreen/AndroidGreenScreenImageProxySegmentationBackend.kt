package com.connects.vanguard_media_engine.greenscreen

import androidx.camera.core.ImageProxy

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: ImageProxy-based segmentation backend contract behind the
// single CameraX analyzer facade (AndroidGreenScreenFilterNode).
// -----------------------------------------------------------------------------
//
// Byte-for-byte port of the previous duet-owned contract
// (`com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackend`);
// only the package, interface name, and referenced outcome/failure-reason/
// backend-id types changed (now the neutral `GreenScreenSegmentationOutcome`,
// `GreenScreenSegmentationFailureReason`, and `AndroidGreenScreenSegmentationBackend`
// already defined in AndroidGreenScreenSegmentationTypes.kt). GreenScreen
// segmentation/matting is an independent, reusable capability and must not be
// owned by the Duet multi-input compositor package. The Duet package's
// equivalent identifier (`AndroidDuetSegmentationBackend`) is kept as a
// source-compatible type alias onto this one.
//
// Contract for implementations:
//   - [open] is called once, from the filter node's analysis thread, before the
//     first [segment]. It must block the calling thread until the backend is
//     actually ready (or definitively failed) — implementations that own a
//     dedicated lifecycle thread (e.g. MediaPipe) block the caller on that
//     thread's creation work. It may throw; a throw means "this backend is
//     unavailable" and the caller walks the ladder.
//   - [segment] must invoke [completion] exactly once, synchronously or
//     asynchronously (e.g. on an owned worker thread), and must never close
//     [proxy]. The proxy stays valid until [completion] is invoked; the
//     backend must not touch it afterwards.
//   - [close] is idempotent, never throws, and may be called from any thread
//     (main thread on stop / layout switch / dispose, analysis thread on
//     degradation, or an owned worker thread during its own failure handling).
//     After [close], any late [segment] call must complete with
//     [GreenScreenSegmentationOutcome.Skipped].

interface AndroidGreenScreenImageProxySegmentationBackend {
    /** One of [AndroidGreenScreenSegmentationBackend]'s constants (e.g. `mediapipe_cpu`, `mlkit`). */
    val backendId: String

    /** Loads the segmenter. Called once on the analysis thread; may throw. */
    fun open()

    /**
     * Segments [proxy] captured at [timestampMs] (camera clock, monotonic).
     * Invokes [completion] exactly once; never closes [proxy].
     */
    fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (GreenScreenSegmentationOutcome) -> Unit,
    )

    /** Releases the segmenter. Idempotent; never throws. */
    fun close()
}
