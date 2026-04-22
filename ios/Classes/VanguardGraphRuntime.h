// VanguardGraphRuntime.h
// Vanguard Media Engine — Phase 1B, P1B-01
//
// Transitional concrete wrapper around VanguardMetalRenderer + Vanguard source
// classes. Satisfies the VGGraphRuntime public interface frozen in UMF.
//
// PUBLIC INTERFACE — do not modify without a charter update (C-5).
// Internals will be replaced in Phase 2. (C-2: not wired to any production path.)
//
// Depends on: VGGraphRuntime (UMF), VanguardMetalRenderer, VanguardFileMediaSource,
//             VanguardImageMediaSource, VGResourceAllocator.

#import <UMF/VGGraphRuntime.h>
#import <Flutter/Flutter.h>
#import "VanguardPlaybackTypes.h"   // VGAudioRole — required for Phase 2 audio role APIs

NS_ASSUME_NONNULL_BEGIN

/// Concrete transitional graph runtime.
///
/// Designated initialiser requires the Flutter texture registry and method
/// channel that VanguardMetalRenderer needs for GPU texture display and
/// playback-event callbacks. The VGGraphRuntime base class interface
/// (prepareWithURL:completion:, play, pause, seekTo:, invalidate, state,
/// textureId, masterClock) is fully implemented here.
///
/// Thread-safety: matches the contract declared in VGGraphRuntime.h.
///   - prepareWithURL:completion: dispatches all work off the calling thread.
///   - play / pause / seekTo: — main thread only.
///   - invalidate — thread-safe (guarded by _Atomic(BOOL) _invalidated).
@interface VanguardGraphRuntime : VGGraphRuntime

/// Phase 2 designated initialiser — stores the caller's desired audio role.
/// @param registry  Flutter texture registry (owned by the plugin; must outlive this object).
/// @param channel   Method channel for onPlaybackComplete / onNodeDurationProbed callbacks.
/// @param role      Desired audio role. Resolved against VGResourceAllocator during prepare;
///                  actual effective role may be Muted if the slot is already held.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel
                       desiredAudioRole:(VGAudioRole)role NS_DESIGNATED_INITIALIZER;

/// Phase 1 compatible convenience initialiser. Defaults to VGAudioRoleActive.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel;

/// Unavailable — use initWithTextureRegistry:methodChannel: or the three-argument form.
- (instancetype)init NS_UNAVAILABLE;

// ─── Phase 2 audio role properties ───────────────────────────────────────────

/// The audio role requested by the caller at initialisation time.
/// Fixed after init; may differ from effectiveAudioRole after allocator arbitration.
@property (nonatomic, readonly) VGAudioRole desiredAudioRole;

/// The audio role resolved by VGResourceAllocator during prepareWithURL:completion:.
/// Updated in-place by transitionToRole:completion:.
@property (atomic, readonly) VGAudioRole effectiveAudioRole;

/// The natural pixel dimensions of the source.
/// Zero until prepareWithURL:completion: completes successfully.
@property (nonatomic, readonly) CGSize renderSize;

// ─── Phase 2 lifecycle methods ─────────────────────────────────────────────────

/// Transitions this runtime to the given audio role.
/// Acquires or relinquishes the VGResourceAllocator slot as needed.
/// Calls completion YES on success; NO if the allocator denies the request.
/// Dispatched off the calling thread; completion fires on a background queue.
- (void)transitionToRole:(VGAudioRole)role
              completion:(nullable void (^)(BOOL success))completion;

/// Invalidates the runtime then drains pending decode work before calling completion.
/// completion is always delivered on the main queue.
/// Required for G-02-T2 safe teardown.
- (void)invalidateAsync:(dispatch_block_t)completion;

// ─── Phase 2 forwarding methods ────────────────────────────────────────────────

/// Forwards playback rate to the renderer/source.
- (void)setPlaybackRate:(double)rate;

/// Forwards seek-preview pause gate to the source (test-only path).
- (void)setSeekPreviewPaused:(BOOL)paused;

/// Reads seek-preview pause state from the source.
- (BOOL)seekPreviewPaused;

@end

NS_ASSUME_NONNULL_END
