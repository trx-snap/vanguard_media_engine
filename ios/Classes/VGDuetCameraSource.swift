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
// PTS-pairing history:
//   Besides the latest-frame slot, the source keeps a short ring of the most recent frames
//   (historyCapacity = 8, ~0.27 s at 30 fps), each holding its OWN +1 retain plus the frame's
//   presentation timestamp. snapshotRetained(near:maxDeltaSeconds:) lets the render loop
//   pull the camera frame closest to a segmentation mask's source PTS instead of the newest
//   frame, so the keyed foreground and the mask describe the same instant (no motion voids).
//   History entries are released when evicted (oldest first, outside the lock) or in stop().
//
// Frame observer seam:
//   setFrameObserver installs an optional observer invoked synchronously on the capture queue
//   for every delivered frame, OUTSIDE the lock, BEFORE the callback-owned retain is released.
//   The observer does NOT receive a retain; it must act synchronously (the segmenter retains
//   internally as needed). The observer is snapshotted under lock, then called outside the lock.
//
// Threading:
//   - start/stop are main-thread lifecycle calls.
//   - snapshotRetained() is thread-safe (guarded by _lock); may be called from main or renderQueue.
//   - The video callback fires on an AVFoundation capture queue (not main).

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock

// MARK: -

final class VGDuetCameraSource {

    // MARK: - Private state

    /// Guards _latestBuffer, _history, _running, and _frameObserver from concurrent
    /// callback vs. stop() / snapshot reads.
    private var _lock = os_unfair_lock_s()

    /// The most recently arrived camera frame. Retained by us; released on swap or stop.
    private var _latestBuffer: CVPixelBuffer?

    /// Maximum number of recent frames kept for PTS pairing (see file header).
    private static let historyCapacity = 8

    /// One PTS-pairing history entry. `buffer` carries its own +1 retain, independent
    /// of the _latestBuffer slot retain, released on eviction or stop().
    private struct HistoryEntry {
        let buffer: CVPixelBuffer
        let pts: CMTime
    }

    /// Recent frames, oldest first, at most `historyCapacity` entries. Guarded by _lock.
    private var _history: [HistoryEntry] = []

    /// True after start() and before stop(). Guarded by _lock for the callback path;
    /// only mutated on the main thread by start/stop callers.
    private var _running = false

    /// The underlying camera source. Nilled out in stop().
    private var _source: VanguardCameraMediaSource?

    /// Ordered AVCaptureSession presets (rawValues, e.g.
    /// AVCaptureSession.Preset.iFrame960x540.rawValue) requested by the caller.
    /// The first preset the session supports wins. Empty preserves the existing
    /// default (1080p-first) camera behavior.
    private let _sessionPresets: [String]

    /// Optional observer invoked on the capture queue for every delivered frame.
    /// Snapshotted under _lock but called outside it. Cleared in stop().
    private var _frameObserver: ((_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) -> Void)?

    // MARK: - Init / deinit

    /// - Parameter sessionPreset: an AVCaptureSession.Preset rawValue (e.g.
    ///   AVCaptureSession.Preset.hd1280x720.rawValue) to request a specific
    ///   capture resolution. Nil (the default) preserves the existing
    ///   1080p-first camera behavior. Equivalent to `init(sessionPresets:)`
    ///   with a one-element list.
    init(sessionPreset: String? = nil) {
        _sessionPresets = sessionPreset.map { [$0] } ?? []
    }

    /// - Parameter sessionPresets: ordered AVCaptureSession.Preset rawValues to
    ///   try in turn; the first one the session supports is applied (e.g.
    ///   [iFrame960x540, hd1280x720]). When none is supported — or the list is
    ///   empty — the source uses its existing 1080p-first default.
    init(sessionPresets: [String]) {
        _sessionPresets = sessionPresets
    }

    deinit {
        stop()
    }

    // MARK: - Public API (main thread)

    /// The AVCaptureSession preset actually applied by the underlying source
    /// (the first supported requested preset, or the 1080p/720p default).
    /// Nil before start() and after stop(). Diagnostic read; main thread.
    var selectedSessionPreset: String? {
        return _source?.selectedSessionPreset
    }

    /// Install (or replace) a frame observer.  The observer is called synchronously on
    /// the AVFoundation capture queue for every delivered frame, outside _lock, before the
    /// callback-owned retain is released.  The observer must NOT retain the pixelBuffer;
    /// it should submit synchronously (the segmenter retains internally if needed).
    /// Pass nil to clear.  Safe to call while running.
    func setFrameObserver(_ observer: ((_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) -> Void)?) {
        os_unfair_lock_lock(&_lock)
        _frameObserver = observer
        os_unfair_lock_unlock(&_lock)
    }

    /// Start the camera. Idempotent — safe to call while already running.
    /// Creates the source on first call, wires the callback, locks portrait, then starts.
    func start() {
        guard !_running else { return }

        let source: VanguardCameraMediaSource
        if !_sessionPresets.isEmpty {
            source = VanguardCameraMediaSource(position: .front,
                                               frameRate: 30,
                                               preferredSessionPresets: _sessionPresets)
        } else {
            source = VanguardCameraMediaSource(position: .front, frameRate: 30)
        }

        // Portrait lock before start, matching the ordering in VanguardMediaEnginePlugin.swift.
        source.lockPreviewOrientationToPortrait()

        // Wire callback *before* start() so no frame is missed.
        source.setVideoCallback { [weak self] pixelBuffer, pts in
            // pixelBuffer is retained by the caller on our behalf (see .m:682-702).
            // We MUST release it exactly once on every path.
            guard let self = self else {
                // Self gone — balance the extra retain the ObjC layer added.
                Unmanaged.passUnretained(pixelBuffer).release()
                return
            }
            self._deliverFrame(pixelBuffer, pts: pts)
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
    /// Clears the observer and callback first, then stops the source, then drains the
    /// latest-frame slot and the PTS-pairing history.
    func stop() {
        guard _running else { return }

        // 1. Close the gate first so _deliverFrame drops any in-flight frame
        //    that arrives between here and source.stop().
        os_unfair_lock_lock(&_lock)
        _running = false
        _frameObserver = nil   // Clear observer before source.stop()
        os_unfair_lock_unlock(&_lock)

        // 2. Disarm the callback so no new frames arrive after this point.
        if let source = _source {
            // Balance the +1 retain the ObjC layer adds on every delivered frame.
            source.setVideoCallback { pixelBuffer, _ in Unmanaged.passUnretained(pixelBuffer).release() }
            source.stop()
        }

        _source = nil

        // 3. Release the held buffer and the PTS-pairing history under lock.
        os_unfair_lock_lock(&_lock)
        let old = _latestBuffer
        _latestBuffer = nil
        let history = _history
        _history.removeAll()
        os_unfair_lock_unlock(&_lock)

        if let old = old {
            _releasePB(old)
        }
        for entry in history {
            _releasePB(entry.buffer)
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

    /// Returns a *retained* snapshot of the history frame whose presentation timestamp is
    /// numerically closest to `pts`, provided |framePTS − pts| <= `maxDeltaSeconds`; nil
    /// when `pts` is not numeric, the history is empty, or no frame is within the window.
    /// Same +1 ownership contract as `snapshotRetained()`. Thread-safe.
    func snapshotRetained(near pts: CMTime, maxDeltaSeconds: Double) -> Unmanaged<CVPixelBuffer>? {
        return snapshotRetainedWithPTS(near: pts, maxDeltaSeconds: maxDeltaSeconds)?.frame
    }

    /// Same selection and +1 ownership contract as `snapshotRetained(near:maxDeltaSeconds:)`,
    /// additionally reporting the matched frame's own presentation timestamp so callers can
    /// measure the achieved pairing delta (telemetry). Thread-safe.
    func snapshotRetainedWithPTS(near pts: CMTime,
                                 maxDeltaSeconds: Double) -> (frame: Unmanaged<CVPixelBuffer>, pts: CMTime)? {
        guard pts.isNumeric else { return nil }
        let target = CMTimeGetSeconds(pts)

        os_unfair_lock_lock(&_lock)
        var best: HistoryEntry? = nil
        var bestDelta = Double.infinity
        for entry in _history where entry.pts.isNumeric {
            let delta = abs(CMTimeGetSeconds(entry.pts) - target)
            if delta < bestDelta {
                bestDelta = delta
                best = entry
            }
        }
        if bestDelta > maxDeltaSeconds { best = nil }
        if let b = best { _retainPB(b.buffer) }
        os_unfair_lock_unlock(&_lock)

        guard let match = best else { return nil }
        // Manual retain was done above; passUnretained hands the +1 to the caller.
        return (frame: Unmanaged.passUnretained(match.buffer), pts: match.pts)
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
    private func _deliverFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // Acquire lock to check the running gate atomically and snapshot the observer.
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
        // Retain a third, independent copy for the PTS-pairing history and append it
        // as the newest entry; evict (collect) the oldest entries beyond capacity.
        _retainPB(pixelBuffer)
        _history.append(HistoryEntry(buffer: pixelBuffer, pts: pts))
        var evicted: [CVPixelBuffer] = []
        let overflow = _history.count - VGDuetCameraSource.historyCapacity
        if overflow > 0 {
            evicted = _history[0..<overflow].map { $0.buffer }
            _history.removeFirst(overflow)
        }
        // Snapshot the observer under lock (safe: it's only a closure reference copy).
        let observer = _frameObserver
        os_unfair_lock_unlock(&_lock)

        // Release the previous occupant and any evicted history retains
        // (outside lock — no contention needed).
        if let old = old { _releasePB(old) }
        for b in evicted { _releasePB(b) }

        // Invoke observer outside lock, before releasing the callback-owned retain.
        // Observer does NOT receive a retain; it submits synchronously.
        observer?(pixelBuffer, pts)

        // Release the callback-owned retain.
        _releasePB(pixelBuffer)
    }
}
