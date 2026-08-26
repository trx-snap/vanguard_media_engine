// VGStreamingOfflineBackgroundSessionHandler.swift
// Phase 4C6H3F — iOS Offline HLS Package Background URLSession Recovery Substrate
//
// Package-owned singleton that bridges the UIApplicationDelegate background
// URLSession relaunch callback
// (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`)
// to VGStreamingOfflineAssetManager's background AVAssetDownloadURLSession
// (identifier: com.connects.vanguard.offlinehls).
//
// Ownership: this type owns ONLY the pending completion-handler bookkeeping.
// It does not own AVAssetDownloadURLSession, offline HLS lifecycle state, or
// the on-disk catalog — those remain owned by VGStreamingOfflineAssetManager
// and VGStreamingOfflineAssetCatalog respectively.
//
// Scope: only the offline HLS identifier owned by
// VGStreamingOfflineAssetManager is accepted here. Any other identifier
// (including VGStreamingCacheManager's "com.connects.vanguard.streamingcache",
// which has no relaunch-reconciliation hook of its own) is treated as
// unknown, per contract: unknown identifiers return `false` and retain no
// handler, so a stray identifier is never left stuck undrained.

import Foundation

final class VGStreamingOfflineBackgroundSessionHandler {

    static let shared = VGStreamingOfflineBackgroundSessionHandler()

    /// The only background URLSession identifier this handler accepts and
    /// retains a completion handler for. Mirrors
    /// VGStreamingOfflineAssetManager's private `sessionIdentifier` constant.
    static let offlineHlsIdentifier = "com.connects.vanguard.offlinehls"

    /// Pending completion handlers keyed by session identifier. Accessed and
    /// mutated exclusively on the main queue so storage and draining are
    /// trivially serialized against each other.
    private var pendingCompletionHandlers: [String: () -> Void] = [:]

    private init() {}

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Called by `VanguardMediaEnginePlugin.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// Returns `false` (and retains nothing) for any identifier this package
    /// does not own, so the caller can correctly report "did not handle" up
    /// the FlutterPluginAppLifeCycleDelegate chain for other plugins/the host
    /// app to process.
    ///
    /// For the owned identifier, stores `completionHandler` and asynchronously
    /// wakes VGStreamingOfflineAssetManager so it can reconnect to the
    /// relaunched background session and reconcile persisted state — all off
    /// the main thread, so this call itself never blocks.
    @discardableResult
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == Self.offlineHlsIdentifier else {
            return false
        }

        onMain { [weak self] in
            self?.pendingCompletionHandlers[identifier] = completionHandler
        }

        // Reconciliation itself is fully asynchronous (dispatched onto the
        // manager's own worker queue) — this call returns immediately.
        VGStreamingOfflineAssetManager.shared.wakeForBackgroundRelaunch()

        return true
    }

    /// Called by VGStreamingOfflineAssetManager's
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` delegate
    /// callback once the OS has delivered all queued background session
    /// events to the app.
    ///
    /// Drains (removes + invokes) the stored completion handler for
    /// `identifier` exactly once, on the main queue, per Apple's documented
    /// contract for `-application:handleEventsForBackgroundURLSession:completionHandler:`.
    /// A no-op when no handler is pending — the common case where the
    /// process was never relaunched via that callback (e.g. plain foreground
    /// launch, or a background session whose events all arrived before
    /// termination).
    func drainCompletionHandler(forIdentifier identifier: String) {
        onMain { [weak self] in
            guard let self = self,
                  let handler = self.pendingCompletionHandlers.removeValue(forKey: identifier)
            else { return }
            handler()
        }
    }
}
