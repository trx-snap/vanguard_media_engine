// VGDuetCameraSource.swift
// VG-DUET-CAMERA-INGRESS: Front-camera live preview ingress for the Duet preview engine.
//
// Responsibilities:
//   - Owns a VanguardCameraMediaSource (front, 30 fps). Does NOT record audio, export, or key.
//   - Provides a retained-snapshot slot so the render loop can pull one frame per render tick.
//   - idempotent start/stop lifecycle; deinit always stops.
//
// Ownership contract (CoreFoundation, not ARC):
//   The VanguardCameraMediaSource callback (682-702 in .m) delivers a *retained* CVPixelBuffer.
//   Under _lock we swap it into _latestBuffer, releasing the old value. The callback-owned
//   retain is released exactly once on every path (stored or released directly).
//   snapshotRetained() retains the slot under lock and returns an Unmanaged value; the caller
//   MUST balance with .release() or takeRetainedValue().
//
// Threading:
//   - start/stop are main-thread lifecycle calls.
//   - snapshotRetained() is thread-safe (guarded by _lock); may be called from main or renderQueue.
//   - The video callback fires on an AVFoundation capture queue (not main).

import AVFoundation
import CoreVideo
import Foundation
import os.lock

// MARK: -

final class VGDuetCameraSource {

    // MARK: - Private state

    /// Guards _latestBuffer and _running flag from concurrent callback vs. stop().
    private var _lock = os_unfair_lock_s()

    /// The most recently arrived camera frame. Retained by us; released on swap or stop.
    private var _latestBuffer: CVPixelBuffer?

    /// True after start() and before stop(). Guarded by _lock for the callback path;
    /// only mutated on the main thread by start/stop callers.
    private var _running = false

    /// The underlying camera source. Nilled out in stop().
    private var _source: VanguardCameraMediaSource?

    // MARK: - Init / deinit

    init() {}

    deinit {
        stop()
    }

    // MARK: - Public API (main thread)

    /// Start the camera. Idempotent — safe to call while already running.
    /// Creates the source on first call, wires the callback, locks portrait, then starts.
    func start() {
        guard !_running else { return }

        let source = VanguardCameraMediaSource(position: .front, frameRate: 30)

        // Portrait lock before start, matching the ordering in VanguardMediaEnginePlugin.swift.
        source.lockPreviewOrientationToPortrait()

        // Wire callback *before* start() so no frame is missed.
        source.setVideoCallback { [weak self] pixelBuffer, _ in
            // pixelBuffer is retained by the caller on our behalf (see .m:682-702).
            // We MUST release it exactly once on every path.
            guard let self = self else {
                // Self gone — balance the extra retain the ObjC layer added.
                Unmanaged.passUnretained(pixelBuffer).release()
                return
            }
            self._deliverFrame(pixelBuffer)
        }

        _source = source
        // Set _running under lock before source.start() so _deliverFrame's gate
        // is live before any frame can arrive on the capture queue.
        os_unfair_lock_lock(&_lock)
        _running = true
        os_unfair_lock_unlock(&_lock)
        source.start()
    }

    /// Stop the camera. Idempotent — safe to call multiple times.
    /// Clears the callback first, then stops the source, then drains the latest-frame slot.
    func stop() {
        guard _running else { return }

        // 1. Close the gate first so _deliverFrame drops any in-flight frame
        //    that arrives between here and source.stop().
        os_unfair_lock_lock(&_lock)
        _running = false
        os_unfair_lock_unlock(&_lock)

        // 2. Disarm the callback so no new frames arrive after this point.
        if let source = _source {
            // Balance the +1 retain the ObjC layer adds on every delivered frame.
            source.setVideoCallback { pixelBuffer, _ in Unmanaged.passUnretained(pixelBuffer).release() }
            source.stop()
        }

        _source = nil

        // 3. Release the held buffer under lock.
        os_unfair_lock_lock(&_lock)
        let old = _latestBuffer
        _latestBuffer = nil
        os_unfair_lock_unlock(&_lock)

        if let old = old {
            _releasePB(old)
        }
    }

    /// Returns a *retained* snapshot of the latest camera frame, or nil when no frame has
    /// arrived yet. The caller owns the +1 retain and MUST balance it (e.g. `snap.release()`
    /// or let ARC do it via `takeRetainedValue()`).
    func snapshotRetained() -> Unmanaged<CVPixelBuffer>? {
        os_unfair_lock_lock(&_lock)
        let buf = _latestBuffer
        if let b = buf { _retainPB(b) }
        os_unfair_lock_unlock(&_lock)
        guard let buf = buf else { return nil }
        // Manual retain was done above; passUnretained hands the +1 to the caller
        // without an extra ARC retain, matching the documented "retained" contract.
        return Unmanaged.passUnretained(buf)
    }

    // MARK: - Private

    /// Retain a CVPixelBuffer using Unmanaged (Swift does not expose CVPixelBufferRetain directly).
    @inline(__always)
    private func _retainPB(_ b: CVPixelBuffer) {
        _ = Unmanaged.passUnretained(b).retain()
    }

    /// Release a CVPixelBuffer using Unmanaged (Swift does not expose CVPixelBufferRelease directly).
    @inline(__always)
    private func _releasePB(_ b: CVPixelBuffer) {
        Unmanaged.passUnretained(b).release()
    }

    /// Called on AVFoundation's capture queue. `pixelBuffer` is pre-retained by the ObjC layer.
    private func _deliverFrame(_ pixelBuffer: CVPixelBuffer) {
        // Acquire lock to check the running gate atomically.
        os_unfair_lock_lock(&_lock)
        guard _running else {
            // Stop has already begun — balance the callback-owned retain and bail.
            os_unfair_lock_unlock(&_lock)
            _releasePB(pixelBuffer)
            return
        }
        // Retain a second copy for the slot while still under lock.
        _retainPB(pixelBuffer)
        let old = _latestBuffer
        _latestBuffer = pixelBuffer
        os_unfair_lock_unlock(&_lock)

        // Release the previous occupant (outside lock — no contention needed).
        if let old = old { _releasePB(old) }

        // Release the callback-owned retain.
        _releasePB(pixelBuffer)
    }
}
