// VanguardMLGate.h
// Phase 4 — Frame submission gate for the ML pipeline
//
// Implements the 4-gate submission model:
//   Gate 0: ML lifecycle state (must be Ready)
//   Gate 1: Thermal floor (blocked at Critical)
//   Gate 2: Minimum interval (best-effort floor — NOT a rate contract)
//   Gate 3: Concurrent submission guard (one inference at a time)
//   Gate 4: ML input pool availability (IOSurface budget check, inside gate 3)
//
// All five signals have INDEPENDENT degradation authority.
// Recovery requires ALL signals below their thresholds simultaneously.
//
// IMPORTANT: offerFrame:pts: is called from _captureQueue.
// It performs only O(1) gate checks and dispatches to _mlQueue on acceptance.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VanguardMLModelState) {
    VanguardMLModelStateUnloaded = 0,
    VanguardMLModelStateReady    = 1,
    VanguardMLModelStateFaulted  = 2,
};

@protocol VanguardMLGateDelegate <NSObject>
/// Deliver a scaled (256×256 BGRA) pixel buffer for inference.
/// Called on _mlQueue. Callee owns buffer — must release when done.
- (void)mlGateDidAcceptFrame:(CVPixelBufferRef)scaledBuffer pts:(CMTime)pts;
@end

@interface VanguardMLGate : NSObject

/// @param mlQueue   Serial queue where inference runs.
/// @param inputPool Pre-allocated CVPixelBufferPool for ML input buffers (256×256 BGRA).
/// @param delegate  Receives accepted frames on mlQueue.
- (instancetype)initWithMLQueue:(dispatch_queue_t)mlQueue
                      inputPool:(CVPixelBufferPoolRef)inputPool
                       delegate:(id<VanguardMLGateDelegate>)delegate
NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ─── State management ─────────────────────────────────────────────────────

/// Update model state. Thread-safe (atomic write).
@property (atomic, assign) VanguardMLModelState modelState;

// ─── Signal inputs (all have independent authority) ───────────────────────

/// Call when thermalState changes. Thread-safe.
- (void)updateThermalState:(NSProcessInfoThermalState)state;

/// Call from _captureQueue on each frame. O(1) gate checks; dispatches on accept.
- (void)offerFrame:(CVPixelBufferRef)buffer pts:(CMTime)pts;

// ─── Pool pressure callback ───────────────────────────────────────────────

/// Called by VanguardPressureWindow delegate when ML pool is saturated.
/// Reduces minimum interval to shed load (pool shrink handled by VanguardMLInputPool).
- (void)noteMLPoolPressure;
- (void)noteMLPoolRecovered;

@end

NS_ASSUME_NONNULL_END
