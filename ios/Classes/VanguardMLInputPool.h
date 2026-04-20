// VanguardMLInputPool.h
// Adaptive CVPixelBufferPool for Phase 4 ML inference input frames.
//
// Design contract (validated by P4-IS-1, P4-IS-2, P4-IS-3):
//   - Pool capacity adapts between 4 (normal) and 2 (pressure) based on thermal + pool signals.
//   - Allocation uses kCVPixelBufferPoolAllocationThresholdKey aux attribute to enforce WEAT.
//   - All methods are thread-safe. Pool operations never block the capture callback.

#pragma once
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VanguardMLPoolMode) {
    VanguardMLPoolModeNormal   = 4,   ///< Default: 4 outstanding buffers allowed
    VanguardMLPoolModePressure = 2,   ///< Under pressure: 2 outstanding buffers allowed
};

@interface VanguardMLInputPool : NSObject

/// Current threshold (4 or 2). KVO-observable for pressure signal integration.
@property (atomic, readonly) NSInteger currentThreshold;

/// YES when the last allocation returned kCVReturnWouldExceedAllocationThreshold.
@property (atomic, readonly) BOOL isPressured;

/// Designated initialiser. width/height should match the ML model input resolution (default 256×256).
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Attempt to borrow one pixel buffer from the pool.
/// Returns nil on pool exhaustion (WEAT) — caller should skip this ML frame.
/// The buffer is returned to the pool automatically when its retain count drops to zero.
- (nullable CVPixelBufferRef)borrowBuffer CF_RETURNS_RETAINED;

/// Shrink pool threshold to 2. Called by thermal/pressure signals. No-op if already in pressure mode.
- (void)enterPressureMode;

/// Restore pool threshold to 4. Called when all signals clear (AND-recovery). No-op if already normal.
- (void)exitPressureMode;

/// Invalidate the pool. Safe to call from any thread. After this, borrowBuffer always returns nil.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
