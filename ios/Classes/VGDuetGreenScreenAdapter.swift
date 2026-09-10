// VGDuetGreenScreenAdapter.swift
// VG-DUET-GREEN-SCREEN: Thin adapter that wires VanguardMLSegmenter + VanguardMaskStore
// into the Duet preview pipeline for person-segmentation keying.
//
// Responsibilities:
//   - Wraps an existing VanguardMLSegmenter + VanguardMaskStore pair; does NOT
//     duplicate segmentation logic.
//   - start(): configures delegate/maskStore, calls loadModelAsync, marks active.
//   - submitFrame(_:presentationTime:): no-op unless active; delegates to segmenter.
//   - latestMaskRetained(maxAgeSeconds:): reads latestSnapshot, rejects stale entries
//     by CACurrentMediaTime – snapshot.timestamp, retains the mask buffer, and returns
//     a +1 Unmanaged the caller MUST release.
//   - invalidate(): deactivates, clears callbacks, calls segmenter.invalidate(). Idempotent.
//   - onSessionFailure: called on main when segmenter enters VanguardMLStateFaulted.
//     Vision fallback readiness is NOT a failure and does NOT fire this callback.
//
// Threading:
//   - start / invalidate must be called on the main thread (coordinator lifecycle).
//   - submitFrame is called on the capture callback queue (AVFoundation serial queue).
//   - latestMaskRetained is called on renderQueue or main thread.
//   - Delegate callbacks from VanguardMLSegmenter arrive on the main queue.
//   - _active is accessed under _lock for the submitFrame hot path;
//     start/invalidate only run on main so they need no lock for their own mutations,
//     but they write _active under _lock to synchronize with the capture-queue reader.

import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os.lock

// MARK: - VGDuetGreenScreenAdapter

final class VGDuetGreenScreenAdapter: NSObject {

    // MARK: - Public seam

    /// Called on the main thread when the segmenter enters VanguardMLStateFaulted.
    /// Vision fallback mode is NOT a failure and does NOT trigger this.
    var onSessionFailure: (() -> Void)?

    // MARK: - Private state

    private let _segmenter: VanguardMLSegmenter
    private let _maskStore: VanguardMaskStore

    /// Guards _active for the capture-queue submitFrame path.
    private var _lock = os_unfair_lock_s()
    private var _active = false

    // MARK: - Init

    init(segmenter: VanguardMLSegmenter = VanguardMLSegmenter(),
         maskStore: VanguardMaskStore   = VanguardMaskStore()) {
        _segmenter = segmenter
        _maskStore = maskStore
        super.init()
    }

    // MARK: - Lifecycle (main thread)

    /// Configure the segmenter and start async model load.
    /// Safe to call multiple times (idempotent after first activation).
    func start() {
        assert(Thread.isMainThread)
        os_unfair_lock_lock(&_lock)
        let alreadyActive = _active
        os_unfair_lock_unlock(&_lock)
        guard !alreadyActive else { return }

        _segmenter.delegate = self
        _segmenter.maskStore = _maskStore
        _segmenter.loadModelAsync()

        os_unfair_lock_lock(&_lock)
        _active = true
        os_unfair_lock_unlock(&_lock)
    }

    /// Deactivate, clear callbacks, and invalidate the underlying segmenter.
    /// Idempotent — safe to call from main terminal paths.
    func invalidate() {
        assert(Thread.isMainThread)

        os_unfair_lock_lock(&_lock)
        _active = false
        os_unfair_lock_unlock(&_lock)

        // Clear delegate to prevent any in-flight completion firing our callback.
        _segmenter.delegate = nil
        onSessionFailure    = nil
        _segmenter.invalidate()
    }

    // MARK: - Frame submission (capture queue)

    /// Submit a camera frame for segmentation inference.
    /// No-op unless the adapter is active. Non-blocking; segmenter drops frames
    /// internally when busy/throttled/faulted.
    func submitFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        os_unfair_lock_lock(&_lock)
        let active = _active
        os_unfair_lock_unlock(&_lock)
        guard active else { return }
        _segmenter.submitFrame(pixelBuffer, presentationTime: presentationTime)
    }

    // MARK: - Mask snapshot retrieval (renderQueue or main thread)

    /// Returns the latest segmentation mask buffer with a +1 manual retain, or nil
    /// when:
    ///   - no snapshot has been committed yet, or
    ///   - the snapshot's timestamp is older than maxAgeSeconds.
    ///
    /// The caller MUST balance the retain (e.g. result?.release()).
    func latestMaskRetained(maxAgeSeconds: TimeInterval = 0.18) -> Unmanaged<CVPixelBuffer>? {
        guard let snapshot = _maskStore.latestSnapshot() else { return nil }

        // Reject stale masks so a frame-level fallback is applied by the compositor
        // rather than compositing a stale mask.
        let age = CACurrentMediaTime() - snapshot.timestamp
        guard age <= maxAgeSeconds else { return nil }

        // Manual retain so the returned Unmanaged has a +1 the caller owns.
        let pb = snapshot.pixelBuffer
        _ = Unmanaged.passUnretained(pb).retain()
        return Unmanaged.passUnretained(pb)
    }
}

// MARK: - VanguardMLSegmenterDelegate

extension VGDuetGreenScreenAdapter: VanguardMLSegmenterDelegate {

    /// Called on the main queue by VanguardMLSegmenter when its state changes.
    /// Explicit selector name matches the ObjC selector used in VanguardMLSegmenter.m:
    /// `segmenterDidTransitionToState:`.
    @objc(segmenterDidTransitionToState:) func segmenterDidTransition(toState state: VanguardMLState) {
        assert(Thread.isMainThread)
        // Vision fallback: VanguardMLStateUnloaded -> VanguardMLStateReady via Vision.
        // This is NOT a failure.  Only the .faulted case triggers the session failure.
        guard state == .faulted else { return }
        onSessionFailure?()
    }

    /// Called on the main queue by the health monitor when the segmenter stalls.
    /// Immediately surfaces the failure so the coordinator can fall back to PiP.
    @objc func segmenterDidStall() {
        assert(Thread.isMainThread)
        DispatchQueue.main.async { [weak self] in
            self?.onSessionFailure?()
        }
    }
}
