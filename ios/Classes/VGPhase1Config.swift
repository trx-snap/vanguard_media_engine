// VGPhase1Config.swift
// TEMPORARY — Feature flag for Phase 1B rollout. Deleted in Phase 2.

/// Phase 1B runtime feature flags.
///
/// All flags default to `false` so the legacy production path is active
/// until an explicit opt-in is made during controlled rollout.
enum VGPhase1Config {

    /// Routes `createTexture` / `createImageTexture` through `VGSessionRegistry`
    /// and `VanguardGraphRuntime` when `true`.
    /// `false` (default) keeps the legacy `renderers` dictionary path active.
    ///
    /// Set to `true` only for Phase 1B integration testing.
    /// This flag and the entire file are deleted in Phase 2.
    static let useGraphRuntime: Bool = false
}
