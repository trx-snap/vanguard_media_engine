// VGCameraGraphSession.h
// vanguard_media_engine — Phase 6A-2
//
// VGCameraGraphSession manages the lifecycle of the V2 camera media graph session.
// It instantiates the graph components, coordinates preparation, manages execution
// state, wires up delegates, and handles thread-safe, idempotent teardown.
//
// Two ingress modes (fixed at init, identical graph/filter/recording/photo
// behaviour in both):
//   - renderer mode (initWithSource:renderer:error:): the session is the
//     VanguardMetalRenderer's frameDelegate and graph output reaches the
//     Flutter texture through VGRendererSinkAdapter.
//   - graph-only mode (initWithSource:processedFrameReceiver:error:): no
//     VanguardMetalRenderer is created and no Flutter texture is registered.
//     The session installs the camera source's video callback itself and the
//     graph output (post filter chain, e.g. VGGreenScreenFilterNode alpha
//     frames) is delivered to a VanguardCameraFrameReceiver via
//     VGPlatformViewSinkAdapter. Used by consumers that composite the
//     processed stream themselves (Duet foreground provider).
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

/// Graph-only designated initializer (no Flutter renderer, no texture).
///
/// Builds, validates, and plans the camera graph via VGCameraGraphFactory with
/// NO VGRendererSinkAdapter: the VGFanOutSink fans out to a
/// VGPlatformViewSinkAdapter wrapping @c receiver (first child) plus the
/// recording and photo sinks. No VanguardMetalRenderer is instantiated and no
/// Flutter texture is registered.
///
/// Ingress: the session installs @c source's video callback itself (before the
/// scheduler starts and before the caller starts the source). Each callback
/// buffer arrives +1 retained (VanguardCameraMediaSource contract); the session
/// forwards it through the same async didReceiveRawFrame: boundary as renderer
/// mode and releases the callback-owned retain exactly once. No GPU rotation
/// is applied: the caller must have locked the source orientation before
/// starting it.
///
/// Egress: graph-processed frames (after the committed filter chain) reach
/// @c receiver's onFrame:pts: at +0 on the graph execution queue
/// (com.vanguard.cameraGraphExecution). The receiver must retain what it keeps.
/// The receiver is held WEAKLY (VGPlatformViewSinkAdapter contract) and must
/// outlive the session.
///
/// Every other public method (filter chain, recording, photo, hot updates,
/// diagnostics, invalidate) behaves exactly as in renderer mode.
///
/// @param source   The camera media source. Must not be nil. Must not have
///                 been started yet (callback is installed here).
/// @param receiver Processed-frame consumer. Must not be nil.
/// @param outError On failure, set to a descriptive NSError.
/// @return An initialized graph session instance, or nil if creation failed.
///         On failure the source's video callback is left untouched.
///
/// Convenience wrapper for -initWithSource:processedFrameReceiver:initialFilterSpecs:error:
/// with nil initial specs (plain passthrough graph-only session).
- (nullable instancetype)initWithSource:(VanguardCameraMediaSource *)source
                 processedFrameReceiver:(id<VanguardCameraFrameReceiver>)receiver
                                  error:(NSError * _Nullable * _Nullable)outError;

/// Graph-only designated initializer with an initial filter chain built into the
/// graph BEFORE the scheduler (and therefore the camera source) starts.
///
/// Identical to -initWithSource:processedFrameReceiver:error: in every respect
/// except: when @c initialFilterSpecs is non-nil/non-empty, the specs are
/// validated and the corresponding filter nodes constructed using the same
/// policy as -setCameraFilterChainFromSpecs:error:, and that chain is what the
/// initial VGCameraGraphFactory graph build uses — i.e. the very first frame
/// the scheduler dispatches (scheduler start calls the camera source's
/// startProducing, which starts the underlying AVCaptureSession) already
/// passes through the requested filter chain. There is no window in which an
/// unfiltered frame can reach @c receiver.
///
/// This is all-or-nothing: if @c initialFilterSpecs fails validation or the
/// required pool/Metal device resources are unavailable, initialization fails
/// entirely (no graph, no camera start, source callback left untouched) rather
/// than falling back to an unkeyed/passthrough graph. -hasActiveFilters and
/// -activeFilterSpecs reflect the committed initial specs only after the
/// entire graph (including scheduler creation) has succeeded.
///
/// @param source             The camera media source. Must not be nil. Must
///                           not have been started yet.
/// @param receiver           Processed-frame consumer. Must not be nil.
/// @param initialFilterSpecs Optional filter specs (same contract as
///                           -setCameraFilterChainFromSpecs:error:) to build
///                           into the graph at construction time. nil or empty
///                           means passthrough, identical to
///                           -initWithSource:processedFrameReceiver:error:.
/// @param outError           On failure, set to a descriptive NSError.
/// @return An initialized graph session instance, or nil if creation failed.
///         On failure the source's video callback is left untouched.
- (nullable instancetype)initWithSource:(VanguardCameraMediaSource *)source
                 processedFrameReceiver:(id<VanguardCameraFrameReceiver>)receiver
                     initialFilterSpecs:(nullable NSArray<NSDictionary *> *)initialFilterSpecs
                                  error:(NSError * _Nullable * _Nullable)outError NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── Phase [Beauty-Still]: Active filter state for offline still export ───────

/// Returns YES when one or more filter specs are actively installed in the live
/// camera graph (i.e. a successful setCameraFilterChainFromSpecs: committed them).
/// Returns NO when no filters are active, specs were never set, or the session
/// has been invalidated.
/// Thread-safe: serialized on _sessionQueue.
@property (nonatomic, readonly) BOOL hasActiveFilters;

/// Immutable snapshot of the filter spec dictionaries actively running in the
/// live camera graph. Returns nil when no filters are active or session is invalidated.
/// Each spec dictionary is a deep copy of the original (including nested parameters).
/// Thread-safe: serialized on _sessionQueue.
@property (nonatomic, copy, readonly, nullable) NSArray<NSDictionary *> *activeFilterSpecs;

/// Invalidates and tears down the graph session.
///
/// Idempotent. Clears the renderer's frame delegate (renderer mode) or replaces
/// the source's video callback with a balancing release-only callback
/// (graph-only mode) to prevent any further frame callbacks from reaching the
/// scheduler, invalidates the scheduler, transitions the context state, and
/// releases retained graph resources. Does NOT stop the camera source.
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
///   - "beauty" (V1: no beautyVersion key or beautyVersion:1; V2: beautyVersion:2,
///     optionally faceAwareEnabled — see the implementation for the V2 path).
///   - "greenScreen" — live solid-background green screen as a camera graph
///     filter (VGGreenScreenFilterNode). iOS-first MVP: solid background only.
///     Required parameters:
///       "backgroundType" (NSString) — must be "solidColor"
///       "argb"           (NSNumber) — integer 0xAARRGGBB, 0 … 0xFFFFFFFF
///                                     (alpha byte ignored; background is opaque)
///     Optional: "enabled" (NSNumber/BOOL, default YES).
///     Malformed parameters (missing dictionary, missing/non-string
///     backgroundType, missing/non-number/out-of-range argb) return
///     INVALID_GREEN_SCREEN_FILTER_SPEC. A well-formed backgroundType other
///     than "solidColor" returns UNSUPPORTED_FILTER_TYPE. Neither mutates the graph.
///     The node is a plain transform node: it owns no camera, ARSession or
///     texture registration, applies no rotation/mirroring, and fails open to
///     the input frame on any per-frame failure. Matte quality is MVP-level
///     (Vision FAST person matte with S1 edge refinement; no temporal
///     smoothing) — see VGGreenScreenFilterNode.h. Read-only telemetry for
///     the active node is available via -greenScreenDiagnosticsSnapshot.
///
/// Known but unsupported (returns UNSUPPORTED_FILTER_TYPE):
///   - "lut"
///   - "segmentation" — the old mask-store composite type. It remains deferred
///     and is deliberately NOT repurposed for green screen; "greenScreen" is a
///     separate type.
///
/// Unknown (returns UNKNOWN_FILTER):
///   - Any type string not in {beauty, lut, segmentation, greenScreen}.
///
/// Resource unavailable (returns UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT):
///   - _sessionPool is NULL or metalDevice is nil at call time.
///
/// Empty specs array clears the filter chain (passthrough). Returns YES.
///
/// Validation is atomic: the graph is mutated only when every spec passes.
/// Recording sink, photo sink and platform-view fan-out behaviour across the
/// resulting graph swap is unchanged (see setCameraFilterChain:).
///
/// @param specs    Array of filter spec dictionaries. Each must contain "type" (NSString).
///                 Optional keys: "parameters" (NSDictionary), "enabled" (NSNumber/BOOL).
/// @param outError On failure, set to an NSError whose domain is the error code string:
///                   "UNKNOWN_FILTER"
///                   "UNSUPPORTED_FILTER_TYPE"
///                   "INVALID_GREEN_SCREEN_FILTER_SPEC"
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

// ─── Phase 6C.2B: In-place hot parameter updates ─────────────────────────────

/// Applies in-place hot parameter updates to active camera graph filter nodes.
///
/// Phase 6C.2B scope: supports ONLY the following payload shape:
///   { "beauty": { "intensity": <number [0.0, 1.0]> } }
///
/// Any other effect type, parameter name, or payload shape is rejected with
/// UNSUPPORTED_TRANSACTION_POLICY.  If no active beauty filter is found in the
/// current filter chain, returns NO with HOT_UPDATE_FAIL.
///
/// Threading:
///   - Safe to call from the main/plugin thread.
///   - MUST NOT be called from `_sessionQueue` — doing so will deadlock.
///   - Internally serializes node lookup and intensity write via dispatch_sync
///     on `_sessionQueue`, preventing races with graph rebuild and teardown.
///
/// @param updates   Parameter update dictionary shaped as:
///                    { effectType (NSString*): { paramName (NSString*): value (NSNumber*) } }
/// @param outError  On failure, set to a descriptive NSError whose domain is
///                  one of: "UNSUPPORTED_TRANSACTION_POLICY", "HOT_UPDATE_FAIL",
///                  "VGCameraGraphSession".
/// @return YES on success (intensity applied to all active beauty nodes), NO on
///         any validation or session failure.
- (BOOL)applyHotParameterUpdates:(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)updates
                            error:(NSError * _Nullable * _Nullable)outError;

// ─── UFM green screen: read-only native diagnostics ──────────────────────────

/// Returns the telemetry snapshot of the VGGreenScreenFilterNode currently
/// installed in the live (committed) filter chain — see
/// VGGreenScreenFilterNode.h -diagnosticsSnapshot for the key set — or nil
/// when the session is invalidated or no greenScreen filter is active (never
/// installed, or cleared by an empty setCameraFilterChainFromSpecs:).
///
/// Read-only: does not touch the camera source, the graph, the scheduler, the
/// pool, or any node state. It only scans the committed filter chain for the
/// active greenScreen node and asks that node for its telemetry. No node
/// reference is retained here, so after a filter clear the lookup source is
/// empty and the result is nil (no stale telemetry survives a clear).
///
/// Threading:
///   - Safe to call from the main/plugin thread.
///   - Serialized via dispatch_sync on _sessionQueue, so it is mutually
///     exclusive with graph rebuild, filter clear, and teardown.
///   - MUST NOT be called from _sessionQueue — doing so will deadlock.
- (nullable NSDictionary<NSString *, id> *)greenScreenDiagnosticsSnapshot;

// ─── UFM camera graph: read-only cumulative filter-chain timing ──────────────

/// Returns a read-only snapshot of the cumulative graph/filter-chain execution
/// timing for the currently committed, non-empty filter chain, or nil when
/// the session is invalidated or no non-empty chain is committed.
///
/// Timing boundary: measured on the graph execution queue immediately around
/// the synchronous [scheduler didReceiveRawFrame:] call for every accepted
/// (non-dropped) frame — scheduler traversal + every active filter node +
/// the synchronous sink presentEnvelope: cost. Graph/filter-chain timing,
/// NOT per-node (e.g. Beauty V2-only) timing.
///
/// Keys:
///   proofLevel          NSString  "filterChainTimingV1"
///   activeFilterCount   NSNumber  committed spec count
///   activeFilterTypes   NSArray<NSString *> committed spec "type" strings, in order
///   graphFrameCount     NSNumber  accepted frames timed for the current chain
///   droppedBusyCount    NSNumber  frames dropped by the in-flight backpressure
///                                 guard since the current chain was committed
///   lastGraphTotalMs    NSNumber  (double, ms)
///   meanGraphTotalMs    NSNumber  (double, ms; 0.0 when graphFrameCount is 0)
///   maxGraphTotalMs     NSNumber  (double, ms)
///   timingBoundary      NSString  describes the measurement boundary
///   nonClaims           NSArray<NSString *>
///
/// Statistics reset on every successful filter-chain commit (non-empty or
/// clear).
///
/// Threading: safe to call from the main/plugin thread. Reads the committed
/// spec types via dispatch_sync on _sessionQueue, then the timing aggregates
/// via dispatch_sync on _graphExecutionQueue — sequential, never nested.
/// MUST NOT be called from _sessionQueue or _graphExecutionQueue (deadlock).
- (nullable NSDictionary<NSString *, id> *)filterChainDiagnosticsSnapshot;

// ─── Processed-frame receiver graph delivery ─────────────────────────────────

/// Wires (or replaces) a VanguardCameraFrameReceiver as a child of the
/// VGFanOutSink so graph-processed frames (after the committed filter chain)
/// are delivered to it via VGPlatformViewSinkAdapter at +0 on the graph
/// execution queue.
///
/// Behaviour:
///   - Creates a VGPlatformViewSinkAdapter wrapping the receiver (held weakly).
///   - Rebuilds the graph preserving the current filter chain so the fan-out
///     includes the receiver sink (renderer mode: renderer + receiver +
///     recording + photo; graph-only mode: receiver + recording + photo).
///   - POC1 raw direct forwarding is disabled on the camera source
///     (platformViewRawForwardingEnabled = NO) to prevent double delivery.
///
/// Returns YES on success, NO if the session is invalidated, the receiver is
/// nil, the source/renderer is gone, or the rebuild fails (current graph kept).
///
/// Thread-safe: serialized on _sessionQueue. MUST NOT be called from
/// _sessionQueue (deadlock).
- (BOOL)connectProcessedFrameReceiver:(id<VanguardCameraFrameReceiver>)receiver;

/// POC2-era selector kept for existing callers (VanguardCameraPlatformView /
/// MTKView delivery). Identical to -connectProcessedFrameReceiver:.
- (BOOL)connectPlatformViewReceiver:(id<VanguardCameraFrameReceiver>)receiver;

@end

NS_ASSUME_NONNULL_END

// ─── [Beauty-Still]: Offline still-image helpers ────────────────────────────
// Import the authoritative standalone headers so Swift sees these classes
// through the already-registered VGCameraGraphSession.h umbrella import
// without duplicating @interface definitions.
#import "VGOfflineFilterBundle.h"
#import "VGStillImageFilterFactory.h"
