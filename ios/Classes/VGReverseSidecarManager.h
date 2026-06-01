// VGReverseSidecarManager.h
// vanguard_media_engine — Phase 7.20A
//
// Thread-safe singleton manager for reverse-playback sidecar assets.
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.20 — REAL-TIME REVERSE PREVIEW ARCHITECTURE (DEC-155)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Problem: Phase 7.19 reverse preview used synchronous AVAssetImageGenerator
// inside the compositor pull loop, blocking the serial pull queue for 5–150ms
// per frame. This caused clock drift and visible stuttering (RR-157).
//
// Strategy A (Reverse Sidecar Asset):
//   Transcode the reversed clip segment offline to an All-Intra forward-playable
//   temporary .mov file. The compositor then uses a standard forward-sequential
//   AVAssetReader on the sidecar — the same highly optimized path used for all
//   forward clips. This completely eliminates the synchronous blocking bottleneck.
//
// This file: public interface (7.20A).
// VGTimelineCompositorNode.m modification: 7.20C (deferred).
// VanguardMediaEnginePlugin.swift modification: 7.20B (deferred).
//
// ── Orientation contract ─────────────────────────────────────────────────────
// The sidecar transcoder applies AVMutableVideoComposition orientation baking
// during the forward decode pass, producing orientation-normalized output pixels.
// The output .mov has identity preferredTransform on its video track.
// IMPORTANT (7.20C): The compositor MUST NOT apply the source clip's preferredTransform
// again when reading the sidecar — doing so would double-rotate the output.
// The sidecar reader should be built with isReversed=NO and no additional
// orientation processing (orientation is pre-baked into sidecar pixels).
//
// ── Memory budget ────────────────────────────────────────────────────────────
// The MVP transcoder (7.20A) uses a memory-bounded in-memory accumulation
// strategy. Decoded CVPixelBuffer frames are held in a NSMutableArray and
// written to AVAssetWriter in reverse order. Hard limits:
//   kVGSidecarMaxFrameCount     — max decoded frames (default: 300)
//   kVGSidecarMaxEstimatedBytes — max estimated raw pixel bytes (default: 160 MB)
// Clips exceeding either limit fail with VGReverseSidecarStateFailed and
// errorMessage = kVGSidecarErrorFrameBudgetExceeded.
// Future slices may add a disk-backed chunked transcoder for longer clips.
//
// ── Thread safety ───────────────────────────────────────────────────────────
// All public methods are safe to call from any thread.
// Completions are delivered on the sidecar serial background queue.
// Callers should dispatch to their preferred queue if needed.
//
// ── Sidecar lifecycle ────────────────────────────────────────────────────────
// Sidecar files are stored in NSTemporaryDirectory()/VGReverseSidecars/.
// iOS may evict this directory when disk space is low. Callers must handle
// a sidecar file disappearing between readiness and use (re-transcode if needed).
//
// ── Export isolation ────────────────────────────────────────────────────────
// The sidecar manager is for PREVIEW only. The export compositor (VGExportScheduler
// + VGTimelineExportHelper) must NOT use sidecars; it already uses AVAssetImageGenerator
// for exact frame accuracy, which is correct for export quality. 7.20C enforces
// this via an isPreview guard in _buildReaderForClipIndex:.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Error constants ──────────────────────────────────────────────────────────

/// Sidecar error strings returned in VGReverseSidecarStatus.errorMessage.
extern NSString *const kVGSidecarErrorFrameBudgetExceeded;
extern NSString *const kVGSidecarErrorMissingSourceFile;
extern NSString *const kVGSidecarErrorNoVideoTrack;
extern NSString *const kVGSidecarErrorInvalidTrimRange;
extern NSString *const kVGSidecarErrorReaderCreationFailed;
extern NSString *const kVGSidecarErrorWriterCreationFailed;
extern NSString *const kVGSidecarErrorAdaptorCreationFailed;
extern NSString *const kVGSidecarErrorAppendFailed;
extern NSString *const kVGSidecarErrorFinishWritingFailed;
extern NSString *const kVGSidecarErrorCancelled;

// ─── VGReverseSidecarState ────────────────────────────────────────────────────

/// Lifecycle state of a single reverse sidecar asset.
///
/// State transitions:
///
///   [ idle ] ──(prepareSidecar)──► [ preparing ]
///   [ preparing ] ──(success)──► [ ready ]
///   [ preparing ] ──(error)──► [ failed ]
///   [ preparing/ready ] ──(invalidate/params changed)──► [ invalidated ]
///   [ invalidated ] ──(cleanup complete)──► [ idle ]
///   [ failed ] ──(retry via prepareSidecar)──► [ preparing ]
///
/// - idle: No sidecar task has been started for this clipId.
/// - preparing: Background transcode is currently in progress.
/// - ready: Sidecar file exists and is ready for compositor use.
/// - failed: A non-cancellation error occurred during transcoding.
/// - invalidated: Clip parameters changed or sidecar was explicitly invalidated.
///                The stale sidecar file is deleted and the state returns to idle
///                after cleanup. Callers observing invalidated should re-trigger
///                prepareSidecar if the clip is still reversed.
typedef NS_ENUM(NSInteger, VGReverseSidecarState) {
    VGReverseSidecarStateIdle        = 0,
    VGReverseSidecarStatePreparing   = 1,
    VGReverseSidecarStateReady       = 2,
    VGReverseSidecarStateFailed      = 3,
    VGReverseSidecarStateInvalidated = 4,
};

// ─── VGReverseSidecarStatus ───────────────────────────────────────────────────

/// Immutable snapshot of a sidecar clip's state.
///
/// @note sidecarPath is non-nil only when state == VGReverseSidecarStateReady.
/// @note errorMessage is non-nil only when state == VGReverseSidecarStateFailed.
/// @note progress is in [0.0, 1.0]; valid only during VGReverseSidecarStatePreparing.
@interface VGReverseSidecarStatus : NSObject

/// Current lifecycle state of this sidecar.
@property (nonatomic, readonly) VGReverseSidecarState state;

/// Absolute path to the ready sidecar .mov file.
/// Non-nil only when state == VGReverseSidecarStateReady.
@property (nonatomic, readonly, nullable) NSString *sidecarPath;

/// Human-readable error description.
/// Non-nil only when state == VGReverseSidecarStateFailed.
@property (nonatomic, readonly, nullable) NSString *errorMessage;

/// Transcode progress in [0.0, 1.0].
/// 0.0 when idle/failed/invalidated. 1.0 when ready.
/// Updated periodically during VGReverseSidecarStatePreparing.
@property (nonatomic, readonly) double progress;

@end

// ─── VGReverseSidecarManager ──────────────────────────────────────────────────

/// Thread-safe singleton manager for reverse-playback sidecar assets.
///
/// ## Usage (7.20B, 7.20C)
///
/// ```objc
/// [[VGReverseSidecarManager sharedManager]
///     prepareSidecarForClipId:clip.clipId
///                  sourcePath:clip.sourceURL
///                   trimStart:clip.trimStartSeconds
///                     trimEnd:clip.trimEndSeconds
///                  targetSize:_targetRenderSize
///                  sourceHash:hash
///                  completion:^(VGReverseSidecarStatus *status) {
///     if (status.state == VGReverseSidecarStateReady) {
///         // Notify compositor to rebuild reader using status.sidecarPath
///     }
/// }];
/// ```
///
/// ## Sidecar identity (sourceHash)
///
/// The `sourceHash` parameter identifies a unique (sourcePath, trimStart, trimEnd,
/// targetSize) combination. If a ready sidecar already exists for the same hash
/// and the same clipId, the completion fires immediately with the existing ready
/// status — no re-transcoding occurs.
///
/// If a different hash exists for the same clipId (e.g. the clip was re-trimmed),
/// the stale sidecar is automatically invalidated and deleted, and a new transcode
/// begins.
///
/// ## Export isolation
///
/// Export compositors MUST NOT use this manager. The export path uses
/// AVAssetImageGenerator for per-frame exact accuracy. The sidecar transcoder
/// produces All-Intra H.264 at preview bitrate — incorrect for export quality.
///
/// ## Thread safety
///
/// All methods acquire an internal os_unfair_lock before accessing shared state.
/// Completions are delivered on the internal serial transcode queue.
@interface VGReverseSidecarManager : NSObject

/// Returns the shared singleton manager.
+ (instancetype)sharedManager;

- (instancetype)init NS_UNAVAILABLE;

// ─── Query ────────────────────────────────────────────────────────────────────

/// Returns a snapshot of the current sidecar status for the given clipId.
///
/// If no record exists for clipId, returns a status with state == idle.
/// Thread-safe.
- (VGReverseSidecarStatus *)statusForClipId:(NSString *)clipId;

// ─── Prepare ─────────────────────────────────────────────────────────────────

/// Begins background transcoding of a reverse sidecar for the given clip.
///
/// @param clipId       Stable clip identifier from the timeline descriptor.
/// @param sourcePath   Absolute path to the original source video file.
/// @param trimStart    Trim window start in source-asset seconds (>= 0).
/// @param trimEnd      Trim window end in source-asset seconds (> trimStart).
/// @param targetSize   Canvas render size. Used to aspect-fit and scale the output.
///                     Pass CGSizeZero to use the source track's natural size.
/// @param sourceHash   Hash string uniquely identifying (sourcePath+trimStart+
///                     trimEnd+targetSize). Must be stable across calls for the
///                     same logical clip state. The manager uses this to detect
///                     stale sidecars requiring re-transcoding.
/// @param completion   Called with the final status once the transcode completes
///                     (success or failure) or if the request short-circuits
///                     (already ready). Delivered on the internal serial queue.
///
/// Behavior:
///   - If the current status for clipId is already ready AND the sourceHash matches,
///     the completion fires synchronously on the internal queue with the ready status.
///   - If the current status for clipId is preparing with the same sourceHash,
///     the completion is appended to the existing in-flight task (coalesced).
///   - If the sourceHash differs from the stored hash (stale), the existing record
///     is invalidated and a new transcode task is started.
///   - If clipId is idle or failed, a new transcode task is started.
///
/// Thread-safe.
- (void)prepareSidecarForClipId:(NSString *)clipId
                     sourcePath:(NSString *)sourcePath
                       trimStart:(double)trimStart
                         trimEnd:(double)trimEnd
                      targetSize:(CGSize)targetSize
                      sourceHash:(NSString *)sourceHash
                      completion:(void (^)(VGReverseSidecarStatus *status))completion;

// ─── Invalidate / Cleanup ─────────────────────────────────────────────────────

/// Cancels any in-flight transcode for clipId, deletes its sidecar file,
/// and resets the state to idle.
///
/// If no record exists for clipId, this is a no-op.
/// Thread-safe.
- (void)invalidateSidecarForClipId:(NSString *)clipId;

/// Cancels all in-flight transcodes, deletes all sidecar files, and resets
/// all clip states to idle.
///
/// Call from disposeTimeline and updateTimeline (full timeline replacement).
/// Thread-safe.
- (void)cleanupAllSidecars;

@end

NS_ASSUME_NONNULL_END
