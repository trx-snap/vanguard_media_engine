// VanguardMLSegmenter.h
// CoreML person segmentation model lifecycle and async inference.
//
// State machine (validated by P4-SD-1, P4-SD-2, P4-TH-1):
//   Unloaded → [loadModel] → Ready → [inference loop] → Faulted → [reset]
//
// Inference is fully decoupled from the capture callback:
//   - Capture thread deposits frames into VanguardMLInputPool.
//   - A dedicated serial _mlQueue drains frames and runs model prediction.
//   - Results are published as VanguardMaskSnapshot via VanguardMaskStore (zero-copy swap).
//   - VanguardMLHealthMonitor surfaces stalls; thermal guard suppresses inference during critical state.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@class VanguardMLInputPool;
@class VanguardMaskStore;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VanguardMLState) {
    VanguardMLStateUnloaded = 0,
    VanguardMLStateReady,
    VanguardMLStateFaulted,
};

@protocol VanguardMLSegmenterDelegate <NSObject>
@optional
- (void)segmenterDidTransitionToState:(VanguardMLState)state;
- (void)segmenterDidStall;                         ///< fired by health monitor after 6s silence
@end

@interface VanguardMLSegmenter : NSObject

@property (atomic, readonly) VanguardMLState state;
@property (nonatomic, weak, nullable) id<VanguardMLSegmenterDelegate> delegate;

/// Pool used to obtain pre-sized BGRA input buffers. Segmenter does NOT own the pool.
@property (nonatomic, strong, nullable) VanguardMLInputPool *inputPool;

/// Destination store for published mask snapshots. Segmenter does NOT own the store.
@property (nonatomic, strong, nullable) VanguardMaskStore *maskStore;

/// Minimum seconds between inference submissions (thermal-adaptive). Default 0.1s.
@property (atomic) NSTimeInterval minimumInterval;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Load the bundled CoreML model asynchronously. Calls delegate on main queue.
- (void)loadModelAsync;

/// Submit a captured pixel buffer for inference. Non-blocking; dropped if busy/throttled/faulted.
/// Must be called from the capture callback serial queue only.
- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
  presentationTime:(CMTime)pts;

/// Reset from Faulted state back to Unloaded, then trigger loadModelAsync.
- (void)reset;

/// Stop inference and release model. Safe to call from any thread.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
