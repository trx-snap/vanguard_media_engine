// VGSessionRegistry.swift
// Vanguard Media Engine — Phase 2, Step 5
//
// Thread-safe registry that bridges the Flutter plugin with VanguardGraphRuntime.
// Phase 2 lifts the Phase 1 single-active-session constraint: multiple runtimes
// may coexist simultaneously. Audio arbitration is coordinated through
// VGResourceAllocator via the promoteToActiveAudio API.
//
// Thread-safety model:
//   A single NSLock (`_lock`) serialises ALL reads and writes to both maps.
//   The lock is held only for map operations — never across blocking I/O,
//   async prepare callbacks, or audio transitions — to prevent priority inversion.
//
//   A dedicated serial queue (`_promotionQueue`) serialises audio promotion
//   transactions end-to-end so concurrent promotions cannot interleave.
//
// Constraints honoured:
//   C-2 — Production wiring is controlled by the plugin; registry is additive.
//   C-4 — Zero opportunistic fixes.
//   C-6 — VanguardMetalRenderer and camera/export files untouched.

import Flutter
import Foundation

// MARK: - VGSessionRegistry

/// Thread-safe registry of active `VanguardGraphRuntime` sessions.
///
/// Phase 2: supports multiple coexistent sessions. createSession() no longer
/// evicts previous runtimes. Audio promotion is available via
/// promoteToActiveAudio(sessionId:completion:).
@objc public final class VGSessionRegistry: NSObject {

    // ── Singleton ─────────────────────────────────────────────────────────────

    /// Process-wide shared instance.
    @objc public static let shared = VGSessionRegistry()

    // ── Private state ─────────────────────────────────────────────────────────

    /// Serialises all map reads and writes.
    /// Never held across blocking calls (prepare, dispose, promotion I/O).
    private let _lock = NSLock()

    /// Primary map: sessionId → VanguardGraphRuntime.
    private var _sessions: [String: VanguardGraphRuntime] = [:]
    /// Reverse map: textureId → sessionId.
    private var _textureIds: [Int64: String] = [:]

    /// Serial queue for audio promotion transactions.
    /// Ensures demotion → slot-acquire → activation cannot interleave.
    private let _promotionQueue = DispatchQueue(
        label: "com.vanguard.session_registry.promotion",
        qos: .userInitiated
    )

    // ── Init ──────────────────────────────────────────────────────────────────

    /// Use `VGSessionRegistry.shared`. Direct instantiation is allowed only
    /// in tests that need an isolated registry without shared state.
    public override init() {
        super.init()
    }

    // MARK: - createSession

    /// Creates a new graph-runtime session for the given URL.
    ///
    /// Phase 2: does NOT evict any existing session. Multiple runtimes may
    /// coexist. The `desiredAudioRole` is forwarded to `VanguardGraphRuntime`
    /// for allocator arbitration during prepare.
    ///
    /// - Parameters:
    ///   - url:              Local file URL for the media asset.
    ///   - textureRegistry:  Flutter texture registry.
    ///   - methodChannel:    Method channel for playback-event callbacks.
    ///   - desiredAudioRole: Requested audio role. Defaults to `.active`.
    ///   - completion:       Fires once with `(textureId, renderSize)` on success,
    ///                       or `(-1, .zero)` on failure. May fire on any
    ///                       background thread.
    /// - Returns: A stable `sessionId` (UUID string). Returned synchronously
    ///            before prepare fires.
    @objc @discardableResult
    public func createSession(
        url: URL,
        textureRegistry: FlutterTextureRegistry,
        methodChannel: FlutterMethodChannel,
        desiredAudioRole: VGAudioRole = .active,
        completion: @escaping (Int64, CGSize) -> Void
    ) -> String {

        // Generate a stable, unique session identifier.
        let sessionId = UUID().uuidString

        // Construct the runtime — fast, synchronous, no I/O.
        // Phase 2: use the 3-arg designated initialiser to pass the desired role.
        let runtime = VanguardGraphRuntime(
            textureRegistry: textureRegistry,
            methodChannel: methodChannel,
            desiredAudioRole: desiredAudioRole
        )

        // Store the primary map entry immediately so the sessionId is resolvable
        // before prepare completes (callers may query by sessionId while the
        // textureId is still pending).
        _lock.withLock {
            _sessions[sessionId] = runtime
        }

        // Kick off async preparation. The reverse map entry is added atomically
        // under the lock once preparation succeeds.
        runtime.prepare(with: url) { [weak self, weak runtime] textureId, error in
            guard let self, let runtime else {
                completion(-1, .zero)
                return
            }

            if let error {
                NSLog("[VGSessionRegistry] prepare failed for session %@: %@",
                      sessionId, error.localizedDescription)
                // Remove the zombie primary-map entry so it does not accumulate.
                self._lock.withLock {
                    self._sessions.removeValue(forKey: sessionId)
                }
                completion(-1, .zero)
                return
            }

            // Store both map entries atomically. Capture whether the write
            // actually happened — it will NOT happen if the session was evicted
            // (invalidateAll, invalidate(textureId:)) between prepare start and
            // this callback.
            let stored = self._lock.withLock { () -> Bool in
                guard self._sessions[sessionId] === runtime else { return false }
                self._textureIds[textureId] = sessionId
                return true
            }

            if !stored {
                // Session was invalidated during prepare; do not deliver a
                // textureId whose reverse-map entry was never registered.
                completion(-1, .zero)
                return
            }

            // renderSize is valid only after prepare succeeds — safe to read here.
            completion(textureId, runtime.renderSize)
        }

        return sessionId
    }

    // MARK: - Lookups

    /// Returns the runtime for the given textureId, or `nil` if not found.
    /// Thread-safe. Never crashes.
    @objc public func runtime(forTextureId textureId: Int64) -> VanguardGraphRuntime? {
        _lock.withLock {
            guard let sessionId = _textureIds[textureId] else { return nil }
            return _sessions[sessionId]
        }
    }

    /// Returns the runtime for the given sessionId, or `nil` if not found.
    /// Thread-safe. Never crashes.
    @objc public func runtime(forSessionId sessionId: String) -> VanguardGraphRuntime? {
        _lock.withLock {
            _sessions[sessionId]
        }
    }

    // MARK: - Map helpers (Phase 2)

    /// Removes both the reverse and primary map entries for `textureId`.
    /// Returns the removed runtime, or `nil` if not found.
    ///
    /// Does NOT call `invalidate()` on the removed runtime — teardown is the
    /// caller's responsibility. This allows async dispose patterns where the
    /// caller needs the runtime handle to drain before tearing down.
    @objc @discardableResult
    public func removeFromMaps(textureId: Int64) -> VanguardGraphRuntime? {
        _lock.withLock {
            guard let sessionId = _textureIds.removeValue(forKey: textureId) else {
                return nil
            }
            return _sessions.removeValue(forKey: sessionId)
        }
    }

    /// Returns a snapshot array of all currently registered runtimes.
    /// The snapshot is point-in-time consistent under the lock.
    @objc public func allRuntimes() -> [VanguardGraphRuntime] {
        _lock.withLock {
            Array(_sessions.values)
        }
    }

    /// Pauses all runtimes whose `effectiveAudioRole` is `.muted`.
    /// Runtimes with `.active` role are left running.
    @objc public func pauseMutedSessions() {
        let snapshot = allRuntimes()
        for runtime in snapshot where runtime.effectiveAudioRole == .muted {
            runtime.pause()
        }
    }

    // MARK: - Audio promotion (Phase 2)

    /// Promotes `sessionId` to the active audio role using a serialised
    /// promotion transaction: demote incumbent → acquire slot → activate target.
    ///
    /// Each phase is atomic with respect to other promotion calls because all
    /// work runs on the dedicated serial `_promotionQueue`.
    ///
    /// - Parameters:
    ///   - sessionId:  The session to promote.
    ///   - completion: Called with `true` on success, `false` on any failure.
    ///                 Fires on the promotion queue (not the main thread).
    public func promoteToActiveAudio(
        sessionId: String,
        completion: @escaping (Bool) -> Void
    ) {
        _promotionQueue.async { [weak self] in
            guard let self else { completion(false); return }

            // ── P1: Resolve target ───────────────────────────────────────────
            guard let target = self.runtime(forSessionId: sessionId) else {
                NSLog("[VGSessionRegistry] promoteToActiveAudio: session %@ not found", sessionId)
                completion(false)
                return
            }

            // Already at the desired role — nothing to do.
            if target.effectiveAudioRole == .active {
                completion(true)
                return
            }

            // ── P2: Demote incumbent if needed ───────────────────────────────
            let allocator = VGResourceAllocator.sharedInstance()
            if let incumbent = allocator.activeAudioRuntime as? VanguardGraphRuntime,
               incumbent !== target {

                // Block the promotion queue until demotion completes.
                let sema = DispatchSemaphore(value: 0)
                var demotionSucceeded = false
                incumbent.transition(to: .muted) { success in
                    demotionSucceeded = success
                    sema.signal()
                }
                sema.wait()

                if !demotionSucceeded {
                    NSLog("[VGSessionRegistry] promoteToActiveAudio: demotion of incumbent failed")
                    completion(false)
                    return
                }
            }

            // ── P3: Acquire allocator slot ───────────────────────────────────
            let granted = allocator.requestAudioActivation(target)
            if !granted {
                NSLog("[VGSessionRegistry] promoteToActiveAudio: allocator denied slot for session %@",
                      sessionId)
                completion(false)
                return
            }

            // ── P4: Activate target ──────────────────────────────────────────
            let sema = DispatchSemaphore(value: 0)
            var activationSucceeded = false
            target.transition(to: .active) { success in
                activationSucceeded = success
                sema.signal()
            }
            sema.wait()

            if !activationSucceeded {
                // Activation failed — release the slot we just acquired.
                allocator.relinquishAudioActivation(target)
                NSLog("[VGSessionRegistry] promoteToActiveAudio: activation failed for session %@",
                      sessionId)
                completion(false)
                return
            }

            completion(true)
        }
    }

    // MARK: - Invalidation

    /// Invalidates the runtime associated with `textureId` and removes both
    /// map entries atomically. Idempotent.
    @objc public func invalidate(textureId: Int64) {
        let (evicted, sessionId): (VanguardGraphRuntime?, String?) = _lock.withLock {
            guard let sid = _textureIds.removeValue(forKey: textureId) else {
                return (nil, nil)
            }
            let rt = _sessions.removeValue(forKey: sid)
            return (rt, sid)
        }

        if let evicted {
            evicted.invalidate()
        } else if sessionId == nil {
            NSLog("[VGSessionRegistry] invalidate(textureId:) — no session found for textureId %lld",
                  textureId)
        }
    }

    /// Invalidates all active runtimes and clears both maps.
    /// Called during plugin teardown or when the Dart engine is detached.
    @objc public func invalidateAll() {
        let snapshot: [VanguardGraphRuntime] = _lock.withLock {
            let runtimes = Array(_sessions.values)
            _sessions.removeAll()
            _textureIds.removeAll()
            return runtimes
        }
        snapshot.forEach { $0.invalidate() }
    }

    /// Alias for `invalidateAll()` — retained for plugin teardown callsites.
    @objc public func disposeAll() {
        invalidateAll()
    }

    // MARK: - Diagnostics

    /// Number of currently active sessions.
    @objc public var sessionCount: Int {
        _lock.withLock { _sessions.count }
    }

    /// Returns the sessionId associated with `textureId`, or `nil`.
    @objc public func sessionId(forTextureId textureId: Int64) -> String? {
        _lock.withLock { _textureIds[textureId] }
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    /// Executes `body` within a lock/unlock pair and returns its result.
    @discardableResult
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
