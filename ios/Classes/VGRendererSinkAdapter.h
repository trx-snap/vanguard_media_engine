// VGRendererSinkAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps VanguardMetalRenderer into the V2 VGFrameSink protocol so it can act
// as a terminal sink node in a VGGraphDescriptor-driven DAG without modifying
// VanguardMetalRenderer.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF).
//   vanguard_media_engine → UMF (one-way dependency, no circular risk).
//
// Renderer lifecycle: VanguardMetalRenderer is lifecycle-managed externally
// by VanguardGraphRuntime (and ultimately the Flutter plugin). This adapter
// stores the renderer as a WEAK reference to avoid extending its lifetime.
// Every call to presentEnvelope: nil-guards the weak reference before use.
//
// Phase 3 stubs:
//   - prepareWithContext:completion: → calls completion(nil) asynchronously.
//     Renderer preparation is performed externally by VanguardGraphRuntime.
//   - invalidate → no-op. Renderer teardown is external.
//   - negotiateFormatForPort:inputFormats: → returns nil.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VanguardMetalRenderer.h,
// imported in the .m file only.
@class VanguardMetalRenderer;

/// Thin V2 adapter wrapping VanguardMetalRenderer as a VGFrameSink.
///
/// presentEnvelope: delegates directly to VanguardMetalRenderer.presentEnvelope:
/// (added in P4-4). This method retains the CVPixelBuffer, swaps it into
/// _latestPixelBuffer under os_unfair_lock, and triggers a texture update.
///
/// The renderer is stored as a weak reference. If the renderer is deallocated
/// before presentEnvelope: is called, the envelope is silently dropped.
@interface VGRendererSinkAdapter : NSObject <VGFrameSink>

/// The wrapped Metal renderer. Stored WEAK — lifecycle managed externally.
@property (nonatomic, weak, readonly, nullable) VanguardMetalRenderer *renderer;

/// Designated initialiser.
/// @param renderer  The VanguardMetalRenderer instance to wrap.
///                  Stored as weak — must outlive any active graph session.
- (instancetype)initWithRenderer:(VanguardMetalRenderer *)renderer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
