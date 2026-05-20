// VGCameraGraphSession.h
// vanguard_media_engine — Phase 6A-2
//
// VGCameraGraphSession manages the lifecycle of the V2 camera media graph session.
// It instantiates the graph components, coordinates preparation, manages execution
// state, wires up delegates, and handles thread-safe, idempotent teardown.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VanguardCameraMediaSource;
@class VanguardMetalRenderer;

@interface VGCameraGraphSession : NSObject

/// Designated initializer.
///
/// Builds, validates, and plans the camera graph via VGCameraGraphFactory.
/// Allocates the execution context and the V2 plan-driven scheduler.
/// Wires the scheduler as the renderer's frame delegate and starts the scheduler.
///
/// @param source   The camera media source. Must not be nil.
/// @param renderer The Metal renderer. Must not be nil.
/// @param outError On failure, set to a descriptive NSError.
/// @return An initialized graph session instance, or nil if creation failed.
- (nullable instancetype)initWithSource:(VanguardCameraMediaSource *)source
                               renderer:(VanguardMetalRenderer *)renderer
                                  error:(NSError * _Nullable * _Nullable)outError NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Invalidates and tears down the graph session.
///
/// Idempotent. Clears the renderer's frame delegate to prevent any further frame callbacks
/// from reaching the scheduler, invalidates the scheduler, transitions the context
/// state, and releases retained graph resources.
- (void)invalidate;

/// Rebuilds the camera graph with the given filter chain and swaps the active
/// scheduler.
///
/// Phase 6A-3A structural proof only:
/// - intended for unit-level graph rebuild/hot-swap validation
/// - not yet exposed to Flutter/Dart
/// - not yet product-proven for live camera filter effects
///
/// Uses build-then-swap:
/// 1. constructs a new graph via VGCameraGraphFactory
/// 2. creates a new VGGraphSchedulerV2
/// 3. wires the fan_out_sink
/// 4. starts the new scheduler
/// 5. swaps renderer.frameDelegate to the new scheduler
///
/// The old scheduler is NOT invalidated because it shares the underlying camera
/// source. Invalidating it would stop the shared AVCaptureSession.
///
/// Thread-safe: serialized internally via a dedicated dispatch queue.
/// No-op after invalidate has been called.
///
/// @param filterChain Ordered list of filter nodes. nil or empty means
///                    passthrough graph.
- (void)setCameraFilterChain:(nullable NSArray *)filterChain;

/// Constructs filter nodes from Dart/plugin specs and applies them to the camera graph.
///
/// Validates all specs atomically before constructing any nodes.
/// If any spec fails validation the method returns NO and does NOT mutate the graph.
///
/// Supported:
///   - "beauty" (V1 only — no beautyVersion key, or beautyVersion:1).
///
/// Known but unsupported (returns UNSUPPORTED_FILTER_TYPE):
///   - "beauty" with beautyVersion:2
///   - "lut"
///   - "segmentation"
///
/// Unknown (returns UNKNOWN_FILTER):
///   - Any type string not in {beauty, lut, segmentation}.
///
/// Resource unavailable (returns UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT):
///   - _sessionPool is NULL or metalDevice is nil at call time.
///
/// Empty specs array clears the filter chain (passthrough). Returns YES.
///
/// Validation is atomic: the graph is mutated only when every spec passes.
///
/// @param specs    Array of filter spec dictionaries. Each must contain "type" (NSString).
///                 Optional keys: "parameters" (NSDictionary), "enabled" (NSNumber/BOOL).
/// @param outError On failure, set to an NSError whose domain is the error code string:
///                   "UNKNOWN_FILTER"
///                   "UNSUPPORTED_FILTER_TYPE"
///                   "UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT"
/// @return YES on success (filter chain applied or cleared), NO on any validation failure.
- (BOOL)setCameraFilterChainFromSpecs:(NSArray<NSDictionary *> *)specs
                                error:(NSError * _Nullable * _Nullable)outError;

/// Static helper mapping the compile-time feature flag VG_USE_CAMERA_GRAPH to a runtime check.
+ (BOOL)isGraphModeEnabled;

@end

NS_ASSUME_NONNULL_END
