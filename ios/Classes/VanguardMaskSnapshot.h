// VanguardMaskSnapshot.h
// Phase 4 — Immutable segmentation mask value
//
// Produced by VanguardMLSegmenter on _mlQueue.
// Consumed by VanguardSegmentationFilterNode on the render queue.
// Passed by reference (ARC); never mutated after creation.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface VanguardMaskSnapshot : NSObject

/// Alpha mask pixel buffer (kCVPixelFormatType_OneComponent8, usually 256x256).
/// Single-channel: 0 = background, 255 = subject.
/// Always non-nil on a valid snapshot.
@property (readonly, nonatomic) CVPixelBufferRef pixelBuffer;

/// Wall-clock time when this snapshot was committed (CACurrentMediaTime).
/// Used by health monitor only — render loop does NOT gate on this.
@property (readonly, nonatomic) NSTimeInterval timestamp;

/// Monotonic generation counter. Incremented by VanguardMaskStore on each commit.
/// Health monitor detects stalls by checking if this advances.
@property (readonly, nonatomic) uint64_t generation;

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          timestamp:(NSTimeInterval)timestamp
                         generation:(uint64_t)generation NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
