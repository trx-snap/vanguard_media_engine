// VGCameraGraphSession.h
// vanguard_media_engine — Phase 6A-2
//
// VGCameraGraphSession manages the lifecycle of the V2 camera media graph session.
// It instantiates the graph components, coordinates preparation, manages execution
// state, wires up delegates, and handles thread-safe, idempotent teardown.
//

#pragma once

#import <Foundation/Foundation.h>
#import "VanguardCameraMediaSource.h"  // VanguardCameraFrameReceiver

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

// ─── Phase 6E.1D: Graph-backed recording control ─────────────────────────────

/// Enables or disables the graph-backed recording path.
///
/// When YES:
///   - VGRecordingSinkNode.enabled is set to YES (sink starts forwarding frames).
///   - source.graphRecordingEnabled is set to YES (raw video append path is gated).
///   Sink is enabled FIRST so there is no window where the raw path is off
///   but the graph path is not yet ready.
///
/// When NO:
///   - source.graphRecordingEnabled is set to NO FIRST (raw path resumes
///     immediately, preventing zero-coverage windows).
///   - VGRecordingSinkNode.enabled is then set to NO.
///
/// If the recording sink node is not found in the current node map when enabling,
/// the source flag is NOT set (raw recording fallback is preserved silently).
///
/// Thread-safe: uses dispatch_sync on the internal _sessionQueue.
/// MUST NOT be called from _sessionQueue — doing so will deadlock.
/// No-op after invalidate has been called.
- (void)setRecordingEnabled:(BOOL)enabled;

// ─── Phase 6E.2B: Graph-backed photo capture ─────────────────────────────────

/// Arms the graph photo sink to capture the next processed frame.
///
/// Resolves "camera_photo_sink" from the current node map and calls
/// armWithURL:completion:error: on it. If the session is invalidated,
/// the sink is missing, or a request is already pending, returns NO
/// and populates outError.
///
/// A 3-second timeout is scheduled via dispatch_after on the internal
/// session queue. If no frame is latched within 3s, the pending request
/// is cancelled with GRAPH_PHOTO_TIMEOUT.
///
/// Thread-safe: serialized via dispatch_sync on _sessionQueue.
/// MUST NOT be called from _sessionQueue — doing so will deadlock.
///
/// Phase 6E.2B only: the completion fires with a placeholder error
/// (GRAPH_PHOTO_NOT_YET_ENCODED). Not yet routed from Swift.
///
/// @param path       Destination file path for the photo.
/// @param completion Called with (outputPath, nil) on success or (nil, error).
///                   Dispatched on VGPhotoSinkNode's internal serial queue.
/// @param outError   On failure, set to a descriptive NSError.
/// @return YES if the photo capture request was armed successfully.
- (BOOL)armPhotoCapture:(NSString *)path
             completion:(void (^)(NSString *_Nullable outputPath, NSError *_Nullable error))completion
                  error:(NSError *_Nullable *_Nullable)outError;

// ─── POC2: Platform View graph delivery ──────────────────────────────────────

/// Wires a VanguardCameraFrameReceiver (typically VanguardCameraPlatformView) as
/// a second child of the VGFanOutSink so graph-processed frames (including
/// Beauty V2 output) are delivered to the MTKView PlatformView.
///
/// Behaviour:
///   - Creates a VGPlatformViewSinkAdapter wrapping the receiver.
///   - Triggers a graph rebuild via setCameraFilterChain: (preserving the
///     current filter chain) so the two-child VGFanOutSink is installed.
///   - POC1 raw direct forwarding is disabled on the camera source
///     (platformViewRawForwardingEnabled = NO) to prevent double delivery.
///
/// Returns YES on success, NO if the session is invalidated or rebuild fails.
///
/// Thread-safe: serialized on _sessionQueue.
///
/// POC2 ONLY — Remove before Phase 7 / production.
- (BOOL)connectPlatformViewReceiver:(id<VanguardCameraFrameReceiver>)receiver;

@end

NS_ASSUME_NONNULL_END
