// VanguardMetalRenderer.h
// Phase 1: Renderer refactored to use id<VanguardMediaSource>
// All AVFoundation decode logic removed — renderer is GPU-only.

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Flutter/Flutter.h>
#import <Metal/Metal.h>
// P4-4: VGFrameEnvelope is a plain-C struct (ADR-001) — the canonical
// inter-node frame unit. Quoted-path import (not <UMF/...> framework style)
// matching the established pattern in VanguardLUTFilterNode.h and other
// vanguard filter node headers. Must be outside NS_ASSUME_NONNULL_BEGIN
// (Clang module requirement: no #include inside assume_nonnull pragma).
#import "VGFrameEnvelope.h"
// P4-5: VGFrameDelegate is the UMF protocol adopted by VGGraphScheduler.
// Quoted-path import outside NS_ASSUME_NONNULL_BEGIN (same rationale as above).
#import "VGFrameDelegate.h"

NS_ASSUME_NONNULL_BEGIN

// Forward-declare the protocols so the public header is self-contained.
// Full definitions are in VanguardMediaSource.h and VanguardFilterNode.h —
// imported directly in VanguardMetalRenderer.m where the full types are needed.
@protocol VanguardMediaSource;
@protocol VanguardFilterNode;
// P3-3 TRANSITIONAL — remove in Phase 4 (DEC-50, RR-31)
// VGMetalFilterNode is the UMF protocol for runtime-owned filter nodes.
// The renderer temporarily executes the runtime-owned chain here because it
// still owns the source video callback, frame pull state, and texture
// lifecycle.
@protocol VGMetalFilterNode;

@interface VanguardMetalRenderer : NSObject <FlutterTexture>

/// Designated initialiser — renderer only.
/// @param source          The media source providing decoded frames.
/// @param registry        Flutter texture registry for GPU texture display.
/// @param channel         Method channel for onPlaybackComplete /
/// onNodeDurationProbed callbacks.
- (instancetype)initWithSource:(id<VanguardMediaSource>)source
               textureRegistry:(id<FlutterTextureRegistry>)registry
                 methodChannel:(FlutterMethodChannel *)channel
    NS_DESIGNATED_INITIALIZER;

/// Convenience initialiser for backward-compat — creates a
/// VanguardFileMediaSource internally.
/// @param videoPath       Local file path.
- (instancetype)initWithVideoPath:(NSString *)videoPath
                  textureRegistry:(id<FlutterTextureRegistry>)registry
                    methodChannel:(FlutterMethodChannel *)channel;

- (instancetype)init NS_UNAVAILABLE;

// ─── Playback Control ──────────────────────────────────────────────────────

- (void)play;
- (void)pause;
- (void)seek:(double)seconds; // Renamed from seekToTime: for API consistency

// ─── Speed Control (P1-T5) ────────────────────────────────────────────────

/// Sets the playback rate on both the renderer's _timeProvider and the source.
/// Must always be called on the main thread (CADisplayLink fires on main).
- (void)setPlaybackRate:(double)rate;

// ─── Filter Chain (P1-T3) ─────────────────────────────────────────────────

/// The GPU filter chain applied to each frame before display.
/// Empty array in Phase 1 — zero cost. Phase 4 populates with
/// LUT/beauty/segmentation.
@property(nonatomic, strong) NSArray<id<VanguardFilterNode>> *filterChain;

/// Set to NO to bypass all filter chain processing (thermal degradation path).
@property(nonatomic, assign) BOOL filterChainEnabled;

/// P5: Safe filter chain replacement that calls invalidate on every node being
/// removed BEFORE the chain is swapped. The swap itself is performed as a
/// dispatch_barrier on the video decode queue — no frame can be processed
/// during the swap.
///
/// Callers (e.g. thermal manager) MUST use this instead of assigning
/// filterChain directly whenever nodes are being REMOVED from the chain.
/// Thread-safe: may be called from any thread.
- (void)replaceFilterChain:(NSArray<id<VanguardFilterNode>> *)newChain;

/// P3-3 TRANSITIONAL — remove in Phase 4 (DEC-50, RR-31).
///
/// Sets the runtime-owned UMF filter chain. When non-nil and non-empty, this
/// chain is executed via VGMetalFilterNode.processEnvelope:device: INSTEAD of
/// the legacy VanguardFilterNode chain. This prevents double filtering.
///
/// Swap safety: uses the same dispatch_barrier_async on videoDecodeQueue as
/// replaceFilterChain:. Arrays are copied defensively before the barrier.
///
/// Called exclusively by VanguardGraphRuntime.setFilterChain:. Do NOT add
/// further callers — doing so triggers the RR-31 monitor condition.
///
/// Pass nil or empty array to revert to legacy filter chain behaviour.
/// Thread-safe: may be called from any thread.
- (void)setRuntimeFilterChain:(nullable NSArray<id<VGMetalFilterNode>> *)chain;

// ─── Memory Pressure ──────────────────────────────────────────────────────

- (void)handleMemoryPressure;

/// Synchronous dispose: tears down GPU state immediately.
/// Use this for hot-reload / dealloc paths where async completion is not
/// needed.
- (void)dispose;

/// Async dispose: performs synchronous GPU teardown, then enqueues a sentinel
/// block onto the source's decodeQueue. Calls `completion` on the main thread
/// ONLY after the decodeQueue is fully drained (all AVAssetReader
/// copyNextSampleBuffer calls and cancelReading have finished). This prevents
/// T2 from starting while T1's mediaserverd hardware decoder session is still
/// live.
- (void)disposeAsync:(dispatch_block_t)completion;

/// Unregisters the Flutter texture from the registry.
/// Must be called on the main thread AFTER result(nil) has been sent to Dart.
/// Separated from -dispose so that -dispose can complete synchronously on
/// _prepareQueue without blocking on Flutter's raster-thread latch.
- (void)doUnregisterTexture;

// ─── Flutter Texture ──────────────────────────────────────────────────────

@property(readonly, nonatomic) int64_t textureId;
@property(readonly, nonatomic) double videoDuration;

/// Phase A1-S1: Exposes the renderer's CVPixelBufferPool for pool backfill.
/// Used by VanguardMediaEnginePlugin._createImageRenderer to wire the pool
/// into VanguardImageProcessor after initWithSource: returns.
/// Never NULL after a successful initWithSource: call (pool creation is
/// performed unconditionally in _setupPixelBufferPoolFromSource:).
/// Caller MUST NOT release this reference — the renderer owns the pool
/// lifetime.
@property(readonly, nonatomic, nullable) CVPixelBufferPoolRef pixelBufferPool;

/// P4-4: GPU-sink entry point. Not called in P4-4 — additive, dormant until
/// P4-5 wires it from VGGraphScheduler.
///
/// Accepts a pre-processed VGFrameEnvelope and performs renderer-sink work
/// only (RR-36 renderer side):
///   1. Asserts envelope.payload.videoBuffer != NULL (debug guard, catches
///      RR-36 ownership violations from a future scheduler).
///   2. Retains the incoming CVPixelBuffer before storing (RR-36 ownership
///      rule — correct for both source-owned and scheduler-produced buffers).
///   3. Swaps it into _latestPixelBuffer under os_unfair_lock.
///   4. Releases the previous _latestPixelBuffer.
///   5. Dispatches textureFrameAvailable: to the main queue, exactly as the
///      _onVideoFrame: tail does.
///
/// Does NOT: execute filters, query clock, pull frames, interact with
/// scheduler, make timing decisions, or clear _isFetchingFrame.
///
/// Thread-safe: may be called from any thread.
- (void)presentEnvelope:(VGFrameEnvelope)envelope;

/// P4-5: Frame delegate — set by VanguardGraphRuntime to wire the scheduler
/// as the active frame-processing path.
///
/// When non-nil, _onVideoFrame: forwards the raw frame to the delegate and
/// returns immediately (no filter execution in the renderer).
/// When nil, the legacy filter path runs unchanged (camera / export).
///
/// Weak reference: the runtime owns the scheduler; the renderer must not
/// extend the scheduler's lifetime.
@property(nonatomic, weak, nullable) id<VGFrameDelegate> frameDelegate;

/// G-02: Diagnostic read of the native masterClock in seconds.
/// Delegates to the media source's masterClock (AVAudioTime path if audio is
/// active; wall-clock fallback otherwise). Used by the A/V sync integration
/// test.
@property(readonly, nonatomic) double currentTimeSeconds;

// ─── Test Accessors ───────────────────────────────────────────────────────

@property(readonly, nonatomic) int outputTextureWidth;
@property(readonly, nonatomic) int outputTextureHeight;

/// G-02-T3: Forwards to the underlying
/// VanguardFileMediaSource.seekPreviewPaused. When YES, all
/// AVAssetImageGenerator calls are suppressed so no internal AVFoundation XPC
/// dispatch can block the main thread during the critical settle / measurement
/// window.
@property(nonatomic) BOOL seekPreviewPaused;

@end

NS_ASSUME_NONNULL_END
