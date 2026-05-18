// VGImageExportSession.h
// vanguard_media_engine — Phase 5D-3
//
// VGImageExportSession is the top-level integration point for the Phase 5D
// still-image offline pull-mode export pipeline.
//
// Architecture:
//   - Accepts VanguardImageMediaSource + optional filterChain + VGImageExportProfile
//     + output URL.
//   - Wraps the source in VGImageSourceAdapter.
//   - Creates VGImageEncoderSinkNode (ImageIO-backed still encoder).
//   - Builds a VGGraphDescriptor inline (source → transforms → sink).
//   - Validates graph with VGGraphValidator.
//   - Plans graph with VGGraphPlanner.
//   - Creates VGGraphExecutionContext (clock=nil for pull-mode).
//   - Prepares all nodes via dispatch_group (async barrier — VGNode contract).
//   - Pulls exactly one frame via VGFrameRequest from the source node.
//   - Walks the planned transform chain once (in topological order).
//   - Delivers the final processed envelope to VGImageEncoderSinkNode
//     via presentEnvelope:.
//   - Finalizes the sink; returns VGImageExportManifest.
//   - Completion fires exactly once.
//
// Single-use:
//   - startWithCompletion: may be called once. Second call is a no-op.
//   - cancel is safe from any thread at any time.
//   - dealloc invalidates nodes as a safety net.
//
// Threading:
//   - startWithCompletion: may be called from any thread.
//   - Export runs on a private serial dispatch queue.
//   - Completion fires on that private queue (background).
//   - No deadlock: export queue ≠ calling thread.
//
// Buffer ownership:
//   - VGImageSourceAdapter.pullFrame: returns a +1 CVPixelBufferRef via
//     copyRawBuffer (verified: VanguardImageMediaSource.m line 334).
//   - VGImageExportSession owns the buffer from pullFrame: through the
//     transform chain until presentEnvelope: returns.
//   - Each transform that returns a new buffer replaces the owned reference;
//     the prior buffer is released.
//   - presentEnvelope: is a borrowed call (+0). Sink does not retain the buffer.
//   - CVPixelBufferRelease is called after presentEnvelope: returns.
//
// Graph contract:
//   - clockPolicy = VGClockPolicyPull
//   - sink edge admissionPolicy = VGSinkAdmissionPolicyNeverDrop
//   - filterChain is nil for a direct source-to-sink graph.
//
// Forbidden:
//   - No VGGraphSchedulerV2
//   - No VGExportScheduler
//   - No VanguardFileMediaSource
//   - No VanguardGraphRuntime
//   - No VanguardMetalRenderer
//   - No VGFrameDelegate / didReceiveRawFrame
//   - No Flutter/Dart bridge
//   - No UI code
//   - No camera/streaming/playback coupling
//
// Phase 5D-3: Full single-frame pull-mode image export. No audio. No video.
// PORTABLE: Export session contract is platform-agnostic.
// PLATFORM: ImageIO, CoreVideo (via VGImageEncoderSinkNode).

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGImageExportProfile.h>
#import <UMF/VGImageExportManifest.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration.
@class VanguardImageMediaSource;

// ─── VGImageExportSession ─────────────────────────────────────────────────────
/// Single-use offline still-image export session for the V2 pull-mode pipeline.
///
/// Wires VGImageSourceAdapter → optional VGLegacyFilterAdapter chain →
/// VGImageEncoderSinkNode for a complete single-frame still-image export.
///
/// Call startWithCompletion: to begin. Completion fires exactly once.
/// Call cancel to abort; completion fires with a cancellation error.
@interface VGImageExportSession : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the image export session.
///
/// Does NOT start export — call startWithCompletion: to begin.
///
/// @param source      The image media source. Must be non-nil. The source
///                    is wrapped in a VGImageSourceAdapter internally.
/// @param filterChain Optional ordered array of id<VGMetalFilterNode>
///                    (or VGLegacyFilterAdapter-compatible objects) to insert
///                    between source and sink. Pass nil for a direct
///                    source-to-sink graph.
/// @param profile     Image export configuration (format, quality, policies).
/// @param outputURL   Destination file URL. Parent directory must exist.
///                    Any existing file at this URL is deleted before export.
- (instancetype)initWithSource:(VanguardImageMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                       profile:(VGImageExportProfile *)profile
                     outputURL:(NSURL *)outputURL NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithSource:filterChain:profile:outputURL:.
- (instancetype)init NS_UNAVAILABLE;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES while the export is in progress (after startWithCompletion:, before completion).
@property (nonatomic, readonly, getter=isExporting) BOOL exporting;

/// YES after cancel has been called (even before any in-flight work acknowledges it).
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;

/// YES after the completion block has been fired exactly once.
@property (nonatomic, readonly, getter=isFinished) BOOL finished;

// ─── Export control ───────────────────────────────────────────────────────────

/// Start the export asynchronously.
///
/// Builds the inline pull graph, validates, plans, prepares all nodes
/// (via async dispatch_group barrier), pulls one frame, walks the transform
/// chain, presents to the encoder sink, finalizes, and fires completion
/// exactly once.
///
/// On success: manifest is non-nil, error is nil.
/// On failure: manifest is nil, error describes the failure.
/// Completion fires on a background queue.
///
/// Single-use: if startWithCompletion: has already been called (or cancelled
/// before start), this method is a no-op and does not fire completion again.
- (void)startWithCompletion:(void (^)(VGImageExportManifest * _Nullable manifest,
                                      NSError * _Nullable error))completion;

/// Cancel the export. Atomic. Safe from any thread at any time.
///
/// If export has not yet started: marks the session cancelled so that a
/// subsequent startWithCompletion: call fires completion with a cancellation
/// error.
///
/// If export is in progress: sets the cancellation flag; the export loop checks
/// this flag at each step and fires completion with a cancellation error.
///
/// If export has finished: no-op.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
