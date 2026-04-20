// VanguardMLInputPool.m
#import "VanguardMLInputPool.h"
#import <os/lock.h>

@implementation VanguardMLInputPool {
    CVPixelBufferPoolRef _pool;        // nullable after invalidate
    os_unfair_lock       _lock;
    NSInteger            _threshold;   // 4 or 2
    BOOL                 _pressured;
    BOOL                 _invalidated;
    NSInteger            _width;
    NSInteger            _height;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Init / Dealloc
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height {
    self = [super init];
    if (!self) return nil;
    _width     = width;
    _height    = height;
    _lock      = OS_UNFAIR_LOCK_INIT;
    _threshold = VanguardMLPoolModeNormal;
    _pressured = NO;
    _pool      = [self _createPool];
    return self;
}

- (void)dealloc {
    [self invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Public API
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)currentThreshold {
    os_unfair_lock_lock(&_lock);
    NSInteger t = _threshold;
    os_unfair_lock_unlock(&_lock);
    return t;
}

- (BOOL)isPressured {
    os_unfair_lock_lock(&_lock);
    BOOL p = _pressured;
    os_unfair_lock_unlock(&_lock);
    return p;
}

- (nullable CVPixelBufferRef)borrowBuffer {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferPoolRef pool = _pool;
    NSInteger threshold       = _threshold;
    os_unfair_lock_unlock(&_lock);

    if (!pool) return nil;   // invalidated

    NSDictionary *aux = @{ (id)kCVPixelBufferPoolAllocationThresholdKey: @(threshold) };
    CVPixelBufferRef buffer = NULL;
    CVReturn ret = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, (__bridge CFDictionaryRef)aux, &buffer);

    os_unfair_lock_lock(&_lock);
    _pressured = (ret == kCVReturnWouldExceedAllocationThreshold);
    os_unfair_lock_unlock(&_lock);

    if (ret != kCVReturnSuccess) { return nil; }
    return buffer;    // caller owns; ARC/CF releases return it to pool
}

- (void)enterPressureMode {
    os_unfair_lock_lock(&_lock);
    if (!_invalidated && _threshold != VanguardMLPoolModePressure) {
        _threshold = VanguardMLPoolModePressure;
        os_unfair_lock_unlock(&_lock);
        // Recreate pool at same dimensions; existing outstanding buffers drain naturally.
        CVPixelBufferPoolRef newPool = [self _createPool];
        os_unfair_lock_lock(&_lock);
        CVPixelBufferPoolRef old = _pool;
        _pool = newPool;
        os_unfair_lock_unlock(&_lock);
        if (old) CVPixelBufferPoolRelease(old);
    } else {
        os_unfair_lock_unlock(&_lock);
    }
}

- (void)exitPressureMode {
    os_unfair_lock_lock(&_lock);
    if (!_invalidated && _threshold != VanguardMLPoolModeNormal) {
        _threshold = VanguardMLPoolModeNormal;
        _pressured = NO;
        os_unfair_lock_unlock(&_lock);
        CVPixelBufferPoolRef newPool = [self _createPool];
        os_unfair_lock_lock(&_lock);
        CVPixelBufferPoolRef old = _pool;
        _pool = newPool;
        os_unfair_lock_unlock(&_lock);
        if (old) CVPixelBufferPoolRelease(old);
    } else {
        os_unfair_lock_unlock(&_lock);
    }
}

- (void)invalidate {
    os_unfair_lock_lock(&_lock);
    _invalidated = YES;
    CVPixelBufferPoolRef pool = _pool;
    _pool = NULL;
    os_unfair_lock_unlock(&_lock);
    if (pool) CVPixelBufferPoolRelease(pool);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Private
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferPoolRef)_createPool {
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @0
    };
    NSDictionary *bufAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:    @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:              @(_width),
        (id)kCVPixelBufferHeightKey:             @(_height),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{}
    };
    CVPixelBufferPoolRef pool = NULL;
    CVReturn ret = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)bufAttrs,
        &pool);
    if (ret != kCVReturnSuccess) {
        NSLog(@"[VanguardMLInputPool] CVPixelBufferPoolCreate failed: %d", ret);
        return NULL;
    }
    return pool;
}

@end
