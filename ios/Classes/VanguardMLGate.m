// VanguardMLGate.m
// Phase 4

#import "VanguardMLGate.h"
#include <stdatomic.h>
#import <Accelerate/Accelerate.h>

// Minimum intervals per thermal tier (best-effort floor, not rate guarantee)
static const NSTimeInterval kIntervalNominal  = 0.100;  // ≤10fps
static const NSTimeInterval kIntervalFair     = 0.200;  // ≤5fps
static const NSTimeInterval kIntervalSerious  = 0.500;  // ≤2fps

// ML input buffer dimensions
static const size_t kMLInputWidth  = 256;
static const size_t kMLInputHeight = 256;

@implementation VanguardMLGate {
    dispatch_queue_t                  _mlQueue;
    CVPixelBufferPoolRef              _inputPool;
    __weak id<VanguardMLGateDelegate> _delegate;

    // Gate 2: time-based minimum interval
    NSTimeInterval                    _lastSubmitTime;
    NSTimeInterval                    _minimumInterval;

    // Gate 3: concurrent submission guard
    _Atomic(int32_t)                  _mlBusy;

    // Thermal state (independent signal)
    NSProcessInfoThermalState         _thermalState;

    // Pool pressure (secondary signal — steps interval up)
    BOOL                              _poolPressured;
}

@synthesize modelState = _modelState;

- (instancetype)initWithMLQueue:(dispatch_queue_t)mlQueue
                      inputPool:(CVPixelBufferPoolRef)inputPool
                       delegate:(id<VanguardMLGateDelegate>)delegate {
    self = [super init];
    if (!self) return nil;
    _mlQueue         = mlQueue;
    _inputPool       = inputPool;
    CVPixelBufferPoolRetain(_inputPool);
    _delegate        = delegate;
    _minimumInterval = kIntervalNominal;
    _thermalState    = NSProcessInfoThermalStateNominal;
    atomic_store(&_mlBusy, 0);
    _modelState      = VanguardMLModelStateUnloaded;
    return self;
}

- (void)dealloc {
    CVPixelBufferPoolRelease(_inputPool);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Signal Inputs
// ─────────────────────────────────────────────────────────────────────────────

- (void)updateThermalState:(NSProcessInfoThermalState)state {
    _thermalState    = state;
    _minimumInterval = [self _intervalForThermal:state poolPressure:_poolPressured];
    NSLog(@"[VanguardMLGate] Thermal → %ld, interval=%.0fms",
          (long)state, _minimumInterval * 1000.0);
}

- (void)noteMLPoolPressure {
    _poolPressured   = YES;
    _minimumInterval = [self _intervalForThermal:_thermalState poolPressure:YES];
    NSLog(@"[VanguardMLGate] Pool pressure → interval=%.0fms", _minimumInterval * 1000.0);
}

- (void)noteMLPoolRecovered {
    _poolPressured   = NO;
    _minimumInterval = [self _intervalForThermal:_thermalState poolPressure:NO];
    NSLog(@"[VanguardMLGate] Pool recovered → interval=%.0fms", _minimumInterval * 1000.0);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Frame Offering (called from _captureQueue)
// ─────────────────────────────────────────────────────────────────────────────

- (void)offerFrame:(CVPixelBufferRef)buffer pts:(CMTime)pts {
    // Gate 0: model ready?
    if (self.modelState != VanguardMLModelStateReady) return;

    // Gate 1: thermal floor (Critical = fully paused)
    if (_thermalState == NSProcessInfoThermalStateCritical) return;

    // Gate 2: minimum interval (best-effort)
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastSubmitTime < _minimumInterval) return;

    // Gate 3: not already running (non-blocking)
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_mlBusy, &expected, 1)) return;

    // Gate 4: allocate ML input buffer from pool
    CVPixelBufferRef scaled = NULL;
    CVReturn poolRet = CVPixelBufferPoolCreatePixelBuffer(nil, _inputPool, &scaled);
    if (poolRet != kCVReturnSuccess) {
        // Pool exhausted — release gate, let pressure window handle escalation
        atomic_store(&_mlBusy, 0);
        return;
    }

    _lastSubmitTime = now;
    CVPixelBufferRetain(buffer);

    // Scale BGRA 4-channel from capture resolution → kMLInputWidth × kMLInputHeight
    // vImage resize is CPU but happens on _mlQueue, never on capture or render queues
    dispatch_async(_mlQueue, ^{
        [self _scaleBuffer:buffer intoScaled:scaled pts:pts];
        CVPixelBufferRelease(buffer);
    });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Private
// ─────────────────────────────────────────────────────────────────────────────

- (void)_scaleBuffer:(CVPixelBufferRef)src
         intoScaled:(CVPixelBufferRef)dst
                pts:(CMTime)pts {

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    void*  srcBase   = CVPixelBufferGetBaseAddress(src);
    size_t srcWidth  = CVPixelBufferGetWidth(src);
    size_t srcHeight = CVPixelBufferGetHeight(src);
    size_t srcStride = CVPixelBufferGetBytesPerRow(src);

    void*  dstBase   = CVPixelBufferGetBaseAddress(dst);
    size_t dstStride = CVPixelBufferGetBytesPerRow(dst);

    vImage_Buffer srcBuf = { srcBase, srcHeight, srcWidth, srcStride };
    vImage_Buffer dstBuf = { dstBase, kMLInputHeight, kMLInputWidth, dstStride };

    // BGRA → BGRA scale (vImageScale_ARGB8888 works for any 4-channel 8-bit format)
    vImage_Error err = vImageScale_ARGB8888(&srcBuf, &dstBuf, NULL, kvImageEdgeExtend);

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);

    if (err != kvImageNoError) {
        NSLog(@"[VanguardMLGate] vImageScale error: %ld", err);
        CVPixelBufferRelease(dst);
        atomic_store(&_mlBusy, 0);
        return;
    }

    // Deliver to inference
    id<VanguardMLGateDelegate> delegate = _delegate;
    [delegate mlGateDidAcceptFrame:dst pts:pts];  // delegate releases dst

    atomic_store(&_mlBusy, 0);
}

- (NSTimeInterval)_intervalForThermal:(NSProcessInfoThermalState)thermal
                         poolPressure:(BOOL)pool {
    NSTimeInterval base;
    switch (thermal) {
        case NSProcessInfoThermalStateNominal: base = kIntervalNominal; break;
        case NSProcessInfoThermalStateFair:    base = kIntervalFair;    break;
        default:                               base = kIntervalSerious; break;
    }
    return pool ? base * 2.0 : base;  // pool pressure doubles the floor
}

@end
