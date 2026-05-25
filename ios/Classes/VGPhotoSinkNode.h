// VGPhotoSinkNode.h
// vanguard_media_engine — Phase 6E.2A / Phase 6E.2B
//
// VGPhotoSinkNode is the graph-aware photo capture terminal sink.
// When wired as a child of VGFanOutSink, it receives processed
// (effects-applied) graph output frames.
//
// Architecture (Graph-Backed Photo Capture):
//   - Conforms to VGFrameSink (extends VGNode). Role: VGNodeRoleSink.
//   - Input port: "video_in" / VGMediaTypeVideo / required.
//   - One-shot arming: armWithURL:completion:error: arms the sink to latch
//     the next processed frame. Only one request may be pending at a time.
//   - Latch: presentEnvelope: checks for a pending request under os_unfair_lock.
//     If armed, it retains the buffer, nils the pending state, and dispatches
//     the completion asynchronously on an internal serial queue.
//   - Cancel: cancelPendingRequestWithError: cancels any pending request and
//     fires the completion with the supplied error.
//   - Invalidation: invalidate cancels any pending request with a session-
//     invalidated error.
//
// Current status — Phase 6E.2B (ARMING / LATCHING):
//   - Included as last child of VGFanOutSink via VGCameraGraphFactory.
//   - presentEnvelope: latches one frame when armed; no-op otherwise.
//   - 6E.2B: completion fires with GRAPH_PHOTO_NOT_YET_ENCODED placeholder.
//   - takePhoto routing is unchanged (still uses raw _latestBuffer path).
//
// Future steps will:
//   6E.2C — Add async JPEG encode/write in the latch completion path.
//   6E.2D — Route takePhotoToURL through the graph path.
//
// PORTABLE: VGFrameSink contract is platform-agnostic.
// PLATFORM: iOS — CoreVideo buffer ownership, os_unfair_lock.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGPhotoSinkNode ──────────────────────────────────────────────────────────

/// Graph terminal sink that receives processed camera frames for photo capture.
///
/// Phase 6E.2B: One-shot arming/latching. presentEnvelope: latches a single
/// frame when armed and dispatches the completion on an internal serial queue.
/// No JPEG encoding or file I/O in this phase — completion fires with a
/// placeholder error (GRAPH_PHOTO_NOT_YET_ENCODED).
@interface VGPhotoSinkNode : NSObject <VGFrameSink>

// ─── Properties ───────────────────────────────────────────────────────────────

/// The synthesized nodeId for this sink.
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Whether the sink is ready to receive frames.
///
/// Always YES after a successful init. Live camera fan-out sinks are not
/// prepared by the scheduler; readiness is established at init time.
@property (atomic, readonly, getter=isReady) BOOL ready;

/// YES if a photo capture request has been armed and not yet completed or cancelled.
@property (atomic, readonly, getter=hasPendingRequest) BOOL pendingRequest;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Designated initializer.
///
/// @param nodeId   Unique graph node identifier. Must not be nil or empty.
/// @return An initialized instance, or nil if nodeId is invalid.
- (nullable instancetype)initWithNodeId:(NSString *)nodeId NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithNodeId:.
- (instancetype)init NS_UNAVAILABLE;

// ─── Phase 6E.2B: One-shot arming API ─────────────────────────────────────────

/// Arms the sink to latch the next processed frame.
///
/// On the next call to presentEnvelope:, the sink will:
///   1. Retain the buffer (CVPixelBufferRetain).
///   2. Clear the pending state (prevents double-completion).
///   3. Dispatch the completion asynchronously on an internal serial queue.
///
/// Returns NO and populates outError if a request is already pending
/// (GRAPH_PHOTO_ALREADY_PENDING).
///
/// Thread-safe: uses os_unfair_lock. May be called from any queue.
///
/// @param path       Destination file path for the photo. Stored for 6E.2C use.
/// @param completion Called with (outputPath, nil) on success or (nil, error) on
///                   failure. Dispatched on an internal serial queue, never on the
///                   graph execution queue.
/// @param outError   On failure, set to a descriptive NSError.
/// @return YES if the request was armed successfully.
- (BOOL)armWithURL:(NSString *)path
        completion:(void (^)(NSString *_Nullable outputPath, NSError *_Nullable error))completion
             error:(NSError *_Nullable *_Nullable)outError;

/// Cancels any pending request with the supplied error.
///
/// Fires the pending completion on the internal serial queue with (nil, error).
/// No-op if no request is pending.
///
/// Thread-safe: uses os_unfair_lock. May be called from any queue.
///
/// @param error The error to deliver to the pending completion.
- (void)cancelPendingRequestWithError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
