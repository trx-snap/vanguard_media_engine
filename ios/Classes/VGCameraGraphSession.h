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

/// Static helper mapping the compile-time feature flag VG_USE_CAMERA_GRAPH to a runtime check.
+ (BOOL)isGraphModeEnabled;

@end

NS_ASSUME_NONNULL_END
