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
// Current status — Phase 6E.2C (JPEG ENCODE / WRITE):
//   - Included as last child of VGFanOutSink via VGCameraGraphFactory.
//   - presentEnvelope: latches one frame when armed; no-op otherwise.
//   - 6E.2C: completion encodes the latched CVPixelBuffer to JPEG via a
//     persistent CIContext and writes atomically to the requested path.
//   - takePhoto routing is unchanged (still uses raw _latestBuffer path).
//
// Error codes (domain: "VGPhotoSinkNode"):
//   1  GRAPH_PHOTO_INVALID_PATH        — path is nil or empty
//   2  GRAPH_PHOTO_NIL_COMPLETION      — completion block is nil (arming)
//   3  GRAPH_PHOTO_ALREADY_PENDING     — duplicate arm while request in flight
//   4  GRAPH_PHOTO_SESSION_INVALIDATED — session torn down during latch
//   5  GRAPH_PHOTO_TIMEOUT             — no frame within 3 s (session timeout)
//   6  GRAPH_PHOTO_ENCODE_FAILED       — CIContext JPEG encoding returned nil
//   7  GRAPH_PHOTO_WRITE_FAILED        — NSData atomic write to path failed
//   8  GRAPH_PHOTO_NULL_BUFFER         — envelope contained null CVPixelBuffer
//
// Future steps will:
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
/// Phase 6E.2C: One-shot arming/latching with real JPEG encode/write.
/// presentEnvelope: latches a single frame when armed, retains the
/// CVPixelBuffer, and dispatches JPEG encoding + atomic file write on an
/// internal serial queue (_photoQueue). The persistent CIContext is allocated
/// once at init and reused for every capture.
///
/// Apple CIImage lazy-evaluation: the CVPixelBuffer must remain retained until
/// JPEGRepresentationOfImage:colorSpace:options: returns. It is released exactly
/// once after encoding completes (or on each early-error exit path).
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
