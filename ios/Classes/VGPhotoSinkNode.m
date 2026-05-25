// VGPhotoSinkNode.m
// vanguard_media_engine — Phase 6E.2A / Phase 6E.2B
//
// Phase 6E.2B: One-shot arming/latching API.
// presentEnvelope: latches one processed frame when armed, retains the buffer,
// and dispatches the completion asynchronously on _photoQueue.
// In this phase the completion fires with a placeholder error
// (GRAPH_PHOTO_NOT_YET_ENCODED) — no JPEG encoding or file I/O is present.
// Phase 6E.2C will replace the placeholder with CIContext JPEG encode/write.

#import "VGPhotoSinkNode.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

@implementation VGPhotoSinkNode {
    NSString *_nodeId;
    BOOL _ready;

    // Phase 6E.2B: One-shot request state, guarded by _requestLock.
    os_unfair_lock _requestLock;
    NSString *_pendingPath;
    void (^_pendingCompletion)(NSString *_Nullable, NSError *_Nullable);

    // Phase 6E.2B: Serial queue for completion dispatch.
    // Never dispatches on _graphExecutionQueue or _sessionQueue.
    dispatch_queue_t _photoQueue;
}

// ─── Initializers ─────────────────────────────────────────────────────────────

- (nullable instancetype)initWithNodeId:(NSString *)nodeId {
    if (nodeId == nil || nodeId.length == 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        // Live camera fan-out sinks are not prepared by the scheduler;
        // this skeleton has no async setup — mark ready immediately.
        _ready = YES;
        _requestLock = OS_UNFAIR_LOCK_INIT;
        _pendingPath = nil;
        _pendingCompletion = nil;
        _photoQueue = dispatch_queue_create("com.vanguard.photoCapture",
                                            dispatch_queue_attr_make_with_qos_class(
                                                DISPATCH_QUEUE_SERIAL,
                                                QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

// ─── VGNode Protocol Identity ─────────────────────────────────────────────────

- (NSString *)nodeId {
    return _nodeId;
}

- (NSString *)nodeClass {
    return @"VGPhotoSinkNode";
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleSink;
}

// ─── VGNode Protocol Ports ────────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"
                    mediaType:VGMediaTypeVideo
                     required:YES],
    ];
}

// ─── VGNode Protocol Lifecycle ────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    NSParameterAssert(completion != nil);
    // No resources to initialize. Mark ready and complete immediately.
    _ready = YES;
    completion(nil);
}

- (void)invalidate {
    _ready = NO;
    // Cancel any pending photo request. Idempotent — no-op when no request pending.
    NSError *cancelError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                               code:4
                                           userInfo:@{
        NSLocalizedDescriptionKey: @"Session invalidated"
    }];
    [self cancelPendingRequestWithError:cancelError];
}

// ─── VGNode Protocol Format Negotiation ───────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink has no output ports to negotiate.
    return nil;
}

// ─── VGFrameSink Protocol Frame Presentation ──────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Fast path: no pending request → return immediately.
    // os_unfair_lock on the uncontended path is ~1ns (single atomic instruction).
    os_unfair_lock_lock(&_requestLock);

    if (!_pendingCompletion) {
        os_unfair_lock_unlock(&_requestLock);
        return;
    }

    // ── Latch: snapshot and nil the pending state under lock ───────────────
    // Once we nil _pendingCompletion, no subsequent latch, cancel, or timeout
    // can fire the completion again — prevents double-completion.
    void (^completion)(NSString *_Nullable, NSError *_Nullable) = _pendingCompletion;
    NSString *path = _pendingPath;
    _pendingCompletion = nil;
    _pendingPath = nil;

    // Retain the buffer so it outlives this synchronous presentEnvelope: call.
    // The graph runtime owns the envelope at +0; our retain creates +1 for
    // the async block on _photoQueue.
    CVPixelBufferRef processedBuffer = envelope.payload.videoBuffer;
    if (processedBuffer) {
        CVPixelBufferRetain(processedBuffer);
    }

    os_unfair_lock_unlock(&_requestLock);

    // ── Dispatch completion asynchronously on _photoQueue ──────────────────
    // Never blocks _graphExecutionQueue. In 6E.2C this block will encode
    // the retained buffer to JPEG and write to `path` before calling completion.
    dispatch_async(_photoQueue, ^{
        if (processedBuffer) {
            // Phase 6E.2B: Placeholder — buffer latched but encoding not yet
            // implemented. Release the buffer and fire a placeholder error.
            // 6E.2C will replace this block with CIContext JPEG encode/write.
            CVPixelBufferRelease(processedBuffer);
        }

        NSError *placeholderError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                        code:99
                                                    userInfo:@{
            NSLocalizedDescriptionKey: @"GRAPH_PHOTO_NOT_YET_ENCODED: "
                                       "Frame latched but JPEG encoding is not implemented "
                                       "until Phase 6E.2C."
        }];
        completion(nil, placeholderError);
    });
}

// ─── Phase 6E.2B: One-shot arming API ─────────────────────────────────────────

- (BOOL)armWithURL:(NSString *)path
        completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion
             error:(NSError *_Nullable *_Nullable)outError {
    if (!path || path.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                            code:1
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"armWithURL: path must not be nil or empty."
            }];
        }
        return NO;
    }
    if (!completion) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                            code:2
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"armWithURL: completion must not be nil."
            }];
        }
        return NO;
    }

    os_unfair_lock_lock(&_requestLock);

    if (_pendingCompletion) {
        os_unfair_lock_unlock(&_requestLock);
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                            code:3
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"GRAPH_PHOTO_ALREADY_PENDING: "
                                           "A photo capture request is already in flight."
            }];
        }
        return NO;
    }

    _pendingPath = [path copy];
    _pendingCompletion = [completion copy];

    os_unfair_lock_unlock(&_requestLock);
    return YES;
}

- (void)cancelPendingRequestWithError:(NSError *)error {
    os_unfair_lock_lock(&_requestLock);

    void (^completion)(NSString *_Nullable, NSError *_Nullable) = _pendingCompletion;
    _pendingCompletion = nil;
    _pendingPath = nil;

    os_unfair_lock_unlock(&_requestLock);

    if (completion) {
        dispatch_async(_photoQueue, ^{
            completion(nil, error);
        });
    }
}

// ─── State ────────────────────────────────────────────────────────────────────

- (BOOL)isReady {
    return _ready;
}

- (BOOL)hasPendingRequest {
    os_unfair_lock_lock(&_requestLock);
    BOOL pending = (_pendingCompletion != nil);
    os_unfair_lock_unlock(&_requestLock);
    return pending;
}

@end
