// VanguardFilterNode.h
// Phase 1 — P1-T3: GPU filter chain abstraction
//
// Each node in the filter chain receives a CVPixelBufferRef and returns a
// processed CVPixelBufferRef from the shared pool. The chain is empty in Phase 1
// (zero cost). Phase 4 adds LUT, beauty, and segmentation nodes without changing
// this interface or the renderer.
//
// Rules (enforced by code review, not the compiler):
//   • All implementations MUST be thread-safe and stateless per-frame.
//   • Input buffer is guaranteed Metal-compatible (IOSurface-backed).
//   • Implementations MUST NOT retain input beyond the duration of processBuffer:atTime:device:.
//   • Output MUST come from the renderer's shared CVPixelBufferPool (passed at init).
//   • Processing budget: < 2ms (LUT), < 3ms (beauty), < 5ms (segmentation) on A14.
//   • Combined chain budget: < 8ms on A14. Enforced by testFilterChainFitsGPUBudget.
//   • MANDATORY: async completion blocks MUST capture self as __weak to avoid
//     use-after-free when invalidate races with an in-flight CoreML/Vision request.

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VanguardFilterNode <NSObject>

/// Process a single frame through this filter.
///
/// @param input   Metal-compatible CVPixelBufferRef (do NOT retain beyond this call)
/// @param t       Presentation timestamp — used for time-varying effects
/// @param device  The engine's shared MTLDevice
/// @return        A new Metal-compatible CVPixelBufferRef from the renderer's pool,
///                or the original input if this filter is a passthrough.
///                The caller is responsible for releasing the returned buffer.
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device;

/// Human-readable name for debugging and Instruments annotations.
@property (readonly, nonatomic, copy) NSString *filterName;

/// Whether this filter is currently active. When NO, implementations should
/// return the input buffer directly (passthrough, zero cost).
@property (nonatomic, assign) BOOL enabled;

/// Cancel all in-flight asynchronous requests (CoreML, Vision, Metal async compute)
/// and block until they are safe to release.
///
/// Called by the thermal manager BEFORE removing this node from the filter chain.
/// Implementations using VNCoreMLRequest or VNImageRequestHandler MUST cancel
/// all pending requests held in a thread-safe collection (protected by os_unfair_lock)
/// and nil out those references before returning.
///
/// Thread-safe: may be called from any thread. Must not block for > 10ms.
/// Must NOT allocate. LUT and beauty nodes may provide a no-op.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
