// VanguardGraphScheduler.h
// vanguard_media_engine — Phase 4, P4-2 / P4-5
//
// Concrete scheduler. Implements VGGraphScheduler and VGFrameDelegate.
//
// P4-2: Skeleton lifecycle (start/pause/resume/seekTo/setFilterChain/invalidate).
// P4-5: Frame delegate — receives raw frames from VanguardMetalRenderer,
//       executes filter chain, delivers processed envelope to sink.
//
// Threading:
//   _chainLock (os_unfair_lock) guards _filterChain swap (DEC-54).
//   _invalidated (_Atomic BOOL) makes invalidate idempotent.
//   didReceiveRawFrame: executes on _videoDecodeQueue (source serial queue).
//   _schedulerQueue (serial) created but unused for execution in Phase 4.

#import <Foundation/Foundation.h>
#import "UMF/VGGraphScheduler.h"
#import "VGFrameDelegate.h"

// Forward declaration — avoids circular import. Full type imported in .m.
@class VanguardMetalRenderer;

NS_ASSUME_NONNULL_BEGIN

@interface VanguardGraphScheduler : NSObject <VGGraphScheduler, VGFrameDelegate>

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// P4-5: Renderer sink. Set by VanguardGraphRuntime after prepare.
/// Weak to avoid retain cycle: runtime owns both scheduler and renderer.
@property(nonatomic, weak, nullable) VanguardMetalRenderer *sink;

@end

NS_ASSUME_NONNULL_END
