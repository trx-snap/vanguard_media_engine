// VGVideoExportSession.h
// vanguard_media_engine — Phase 5C-5
//
// VGVideoExportSession is the top-level integration point for the Phase 5C
// offline pull-mode video export pipeline.
//
// Architecture:
//   - Accepts AVAsset + VGExportProfile + output URL + optional filter chain.
//   - Creates VGVideoEncoderSinkNode (encoder + AVAssetWriter).
//   - Builds export graph via VGExportGraphFactory.
//   - Creates VGGraphExecutionContext (clock=nil for pull-mode).
//   - Prepares all nodes via dispatch_group (async barrier — VGNode contract).
//   - Creates VGExportScheduler (pull loop on private serial queue).
//   - Sets scheduler.sink = sinkNode (weak; session retains sinkNode strongly).
//   - Starts export; on EOS: finalizeExportWithError: → VGExportManifest.
//   - On failure/cancel: invalidates sink, returns error.
//
// Single-use:
//   - startWithCompletion: may be called once. Second call is a no-op.
//   - cancel is safe from any thread at any time.
//   - dealloc invalidates the scheduler as a safety net.
//
// Threading:
//   - startWithCompletion: may be called from any thread.
//   - Export runs on VGExportScheduler's private serial queue.
//   - finalizeExportWithError: runs in scheduler.completionHandler (after loop exit).
//   - No deadlock: VT callback queue ≠ export queue ≠ calling thread.
//   - Completion fires on the scheduler/export queue (background).
//
// Forbidden:
//   - No VGGraphSchedulerV2
//   - No VanguardFileMediaSource
//   - No VanguardGraphRuntime
//   - No VanguardMetalRenderer
//   - No VGFrameDelegate / didReceiveRawFrame
//   - No Flutter/Dart bridge
//   - No UI code
//
// Phase 5C-5: Full pipeline integration. No audio. No time remapping.
// PORTABLE: Export session contract is platform-agnostic.
// PLATFORM: AVFoundation, VideoToolbox (via VGVideoEncoderSinkNode).

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UMF/VGExportProfile.h>
#import <UMF/VGExportManifest.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGVideoExportSession ─────────────────────────────────────────────────────
/// Single-use offline video export session for the V2 pull-mode pipeline.
///
/// Wires VGExportGraphFactory → VGExportScheduler → VGVideoEncoderSinkNode
/// for a complete encode-and-mux offline export path.
///
/// Call startWithCompletion: to begin. Completion fires exactly once.
/// Call cancel to abort; completion fires with a cancellation error.
@interface VGVideoExportSession : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the export session.
///
/// Does NOT start encoding — call startWithCompletion: to begin.
///
/// @param asset       Source asset. Must be a local file asset with a video track.
/// @param profile     Encoder configuration (must use VGEncoderUsageOffline).
/// @param outputURL   Destination file URL. Parent directory must exist.
///                    An existing file at this URL will be deleted by the sink
///                    during preparation (Apple: AVAssetWriter cannot overwrite).
/// @param filterChain Optional ordered array of id<VGMetalFilterNode> (or
///                    VGSegmentationNode) to insert between source and sink.
///                    Pass nil for a direct source-to-sink graph.
- (instancetype)initWithAsset:(AVAsset *)asset
                      profile:(VGExportProfile *)profile
                    outputURL:(NSURL *)outputURL
                  filterChain:(nullable NSArray *)filterChain NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithAsset:profile:outputURL:filterChain:.
- (instancetype)init NS_UNAVAILABLE;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES while the export is in progress (after startWithCompletion:, before completion).
@property (nonatomic, readonly, getter=isExporting) BOOL exporting;

/// YES after cancel has been called (even before the scheduler acknowledges it).
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;

/// YES after the completion block has been fired exactly once.
@property (nonatomic, readonly, getter=isFinished) BOOL finished;

// ─── Export control ───────────────────────────────────────────────────────────

/// Start the export asynchronously.
///
/// Builds the pipeline, prepares all nodes (via async dispatch_group barrier),
/// starts the pull-mode scheduler, and fires completion exactly once.
///
/// On success: manifest is non-nil, error is nil.
/// On failure: manifest is nil, error describes the failure.
/// Completion fires on a background queue (the scheduler's export queue).
///
/// Single-use: if startWithCompletion: has already been called (or cancelled
/// before start), this method is a no-op and does not fire completion again.
- (void)startWithCompletion:(void (^)(VGExportManifest * _Nullable manifest,
                                      NSError * _Nullable error))completion;

/// Cancel the export. Atomic. Safe from any thread at any time.
///
/// If export has started: delegates to scheduler.cancelExport. The pull loop
/// exits on its next iteration and fires completion with a cancellation error.
///
/// If export has not yet started: marks the session cancelled so that a
/// subsequent startWithCompletion: call fires completion with a cancellation error.
///
/// If export has finished: no-op.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
