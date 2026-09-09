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
