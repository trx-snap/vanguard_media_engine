// VGDuetPreviewTexture.swift
// VG-DUET-SLICE-4A: Flutter texture seam for true Duet preview.
//
// This class registers a surface slot with the Flutter texture registry.
// It intentionally does NOT start a render loop, allocate GLES/Metal contexts,
// or decode frames.  It is a lifecycle seam only.
//
// State machine:
//   Registration → surfaceAvailable (iOS: registration suffices as a proxy for
//   surface readiness; a future compositor slice can downgrade to
//   attachedWaitingSurface if a CALayer hook is added).
//   invalidate() → detached (texture unregistered; copyPixelBuffer returns nil).

import CoreVideo
import Flutter
import Foundation

// MARK: - VGDuetPreviewTexture

/// FlutterTexture implementor for the Duet preview seam.
///
/// Thread-safety: `update(pixelBuffer:)` and `copyPixelBuffer()` are both
/// guarded by `lock`, matching the pattern in VGPlaybackFlutterTexture.
/// `invalidate()` must be called before unregistering from the texture registry.
final class VGDuetPreviewTexture: NSObject, FlutterTexture {

    // MARK: - State

    private let lock = NSLock()

    /// Latest pixel buffer supplied by a future renderer.
    /// Always nil in Slice 4A (no render loop yet).
    private var _latestPixelBuffer: CVPixelBuffer?

    private var _invalidated = false

    // MARK: - FlutterTexture

    /// Called by Flutter's raster thread to composite the latest frame.
    /// Returns nil when no frame has been submitted (Slice 4A always returns nil).
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard !_invalidated, let buf = _latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buf)
    }

    // MARK: - Future renderer hook

    /// Supply a new pixel buffer from a future compositor.
    /// Thread-safe; safe to call from any thread.
    func update(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        _latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    // MARK: - Still-photo snapshot (VG-LIVE-GREENSCREEN-PHOTO)

    /// Returns a strong (+1, ARC-owned) reference to the most recently supplied
    /// composited pixel buffer, or nil when no frame has been supplied yet or
    /// the texture was invalidated.
    ///
    /// The lock is held only for the invalidation check and the retain (a
    /// pointer read), never across encoding. The retain keeps the buffer out
    /// of its pool for as long as the caller holds the reference: a later
    /// `update(pixelBuffer:)` only replaces the stored pointer and never
    /// mutates the pixels of the buffer returned here, so the caller may
    /// encode the snapshot on any thread. ARC releases the reference when the
    /// caller's last strong reference goes away (there is no manual
    /// CVPixelBufferRelease in Swift), so every caller path releases it by
    /// letting the local go out of scope.
    func latestPixelBufferRetained() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !_invalidated, let buf = _latestPixelBuffer else { return nil }
        return buf
    }

    // MARK: - Teardown

    /// Drops the retained pixel buffer and marks the texture as detached.
    /// Call before unregistering from the Flutter texture registry.
    func invalidate() {
        lock.lock()
        _invalidated = true
        _latestPixelBuffer = nil
        lock.unlock()
    }
}
