// VGAudioTimelineLifecycleAdapter.swift
// Vanguard Media Engine — Audio Slice O
//
// Thin adapter that bridges VGAudioLifecycleCoordinator to the plugin's
// authoritative _timelineRuntime.
//
// Design constraints:
//   - Holds only a weak reference to the plugin (no retain cycle).
//   - pauseTimeline() calls _timelinePause() — never _timelinePlay().
//   - recoverPreview calls the existing
//     recoverAudioPreviewAfterSessionTransition(completion:) on the runtime.
//   - Missing runtime → deterministic error completion (no crash, no silent no-op).
//   - No header or umbrella-file modifications required:
//     VanguardGraphRuntime.h and VanguardGraphRuntime+AudioPreview.h are
//     module-visible through the podspec (not in private_header_files).
//
// Threading: all methods must be called on the main thread.

import Foundation

#if VG_USE_V2_GRAPH

// MARK: - Protocol

/// Testable lifecycle seam over the plugin's authoritative timeline runtime.
///
/// Production adapter is VGAudioTimelineLifecycleAdapter.
/// Tests inject a stub that records calls without touching a real runtime.
protocol VGAudioTimelineLifecycle: AnyObject {
    /// Pauses the timeline pull loop. Must never resume it.
    func pauseTimeline()

    /// Recovers the audio preview engine after an AVAudioSession category
    /// transition. Completion fires exactly once on the main queue.
    func recoverPreview(completion: @escaping (Error?) -> Void)
}

// MARK: - Production adapter

/// Production VGAudioTimelineLifecycle implementation.
///
/// Holds a weak reference to VanguardMediaEnginePlugin so that it does not
/// extend the lifetime of the plugin beyond its natural ownership chain.
final class VGAudioTimelineLifecycleAdapter: VGAudioTimelineLifecycle {

    private weak var plugin: VanguardMediaEnginePlugin?

    init(plugin: VanguardMediaEnginePlugin) {
        self.plugin = plugin
    }

    /// Pauses the authoritative timeline via VanguardGraphRuntime._timelinePause().
    ///
    /// No-op when no runtime is installed (e.g. no timeline is currently open).
    /// Never calls _timelinePlay().
    func pauseTimeline() {
        plugin?._timelineRuntime?._timelinePause()
    }

    /// Forwards recovery to the runtime's existing
    /// recoverAudioPreviewAfterSessionTransition(completion:).
    ///
    /// When no runtime is installed, completes immediately with a deterministic
    /// error so the lifecycle coordinator receives a concrete outcome rather than
    /// hanging.
    func recoverPreview(completion: @escaping (Error?) -> Void) {
        guard let runtime = plugin?._timelineRuntime else {
            let err = NSError(
                domain: "VGLifecycleAdapterErrorDomain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "VGAudioTimelineLifecycleAdapter: no active timeline runtime"])
            completion(err)
            return
        }
        runtime.recoverAudioPreviewAfterSessionTransition(completion: completion)
    }
}

#endif // VG_USE_V2_GRAPH
