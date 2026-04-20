// VanguardMaskStore.h
// Phase 4 — Thread-safe mask snapshot swap
//
// Single writer (_mlQueue), multiple readers (render queue, health monitor).
// Lock critical section: one pointer assignment — ~5ns. No contention risk.

#import <Foundation/Foundation.h>
#import "VanguardMaskSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

@interface VanguardMaskStore : NSObject

/// Commit a new snapshot from the ML pipeline.
/// Must be called on _mlQueue. Atomically replaces the previous snapshot.
/// Increments internal generation counter.
- (void)commitSnapshot:(VanguardMaskSnapshot *)snapshot;

/// Read the latest snapshot for rendering.
/// Safe to call from any queue. Returns nil if no snapshot committed yet.
- (nullable VanguardMaskSnapshot *)latestSnapshot;

/// Current generation count. Read atomically — safe from any queue.
/// Used by health monitor to detect stalls.
@property (readonly, nonatomic) uint64_t generation;

@end

NS_ASSUME_NONNULL_END
