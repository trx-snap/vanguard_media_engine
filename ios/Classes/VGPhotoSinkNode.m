// VGPhotoSinkNode.m
// vanguard_media_engine — Phase 6E.2A / Phase 6E.2B / Phase 6E.2C
//
// Phase 6E.2C: Real async JPEG encode/write on _photoQueue.
// presentEnvelope: latches one processed frame when armed, retains the buffer,
// and dispatches the completion asynchronously on _photoQueue.
// On _photoQueue: CIContext JPEG encoding and atomic NSData file write.
//
// Apple CIImage lazy-evaluation contract (developer.apple.com/documentation/coreimage):
//   CIImage does not render pixel data until a CIContext rendering call.
//   CVPixelBuffer MUST remain alive until JPEGRepresentationOfImage:colorSpace:options:
//   returns — do NOT release the buffer immediately after CIImage creation.
//
// Buffer retain/release contract:
//   - presentEnvelope: retains processedBuffer under _requestLock.
//   - _photoQueue block keeps processedBuffer alive through CIImage init AND
//     through JPEGRepresentationOfImage:. Released exactly once after
//     JPEGRepresentationOfImage: returns (or on early-exit error paths).

#import "VGPhotoSinkNode.h"
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
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

    // Phase 6E.2C: Persistent CIContext for JPEG encoding.
    // Created once at init; reused for every capture to avoid repeated
    // Metal pipeline initialization overhead.
    CIContext *_ciContext;
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
        // Phase 6E.2C: Create the persistent CIContext once.
        // contextWithOptions:nil selects the Metal GPU backend on iOS 9+.
        // Reusing a single context avoids repeated Metal pipeline allocation.
        _ciContext = [CIContext contextWithOptions:nil];
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

    // ── Dispatch JPEG encode/write asynchronously on _photoQueue ───────────
    // Never blocks _graphExecutionQueue. presentEnvelope: has already retained
    // processedBuffer (+1). The async block owns that retain and is responsible
    // for exactly one CVPixelBufferRelease across all exit paths.
    //
    // Buffer lifetime rule (Apple CIImage lazy-evaluation):
    //   processedBuffer MUST stay alive until JPEGRepresentationOfImage:
    //   returns. Do NOT release immediately after CIImage creation.
    dispatch_async(_photoQueue, ^{
        @autoreleasepool {
            // ── Guard: null buffer ───────────────────────────────────────────
            if (!processedBuffer) {
                NSError *error = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                     code:8
                                                 userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"GRAPH_PHOTO_NULL_BUFFER: "
                        "Latched frame envelope contained a null pixel buffer."
                }];
                completion(nil, error);
                return;
            }

            // ── Guard: invalid/empty path ────────────────────────────────────
            if (!path || path.length == 0) {
                CVPixelBufferRelease(processedBuffer);
                NSError *error = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                     code:1
                                                 userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"GRAPH_PHOTO_INVALID_PATH: "
                        "Destination path is nil or empty."
                }];
                completion(nil, error);
                return;
            }

            NSURL *fileURL = [NSURL fileURLWithPath:path];

            // ── Step 1: Wrap CVPixelBuffer in a CIImage ──────────────────────
            // CIImage is lazily evaluated — no pixel data is read here.
            // processedBuffer must remain retained until after encoding (below).
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:processedBuffer];

            // ── Step 2: Resolve color space ──────────────────────────────────
            // Use the image's own color space when available (preserves
            // Display P3 / sRGB tags). Fall back to DeviceRGB if absent.
            // ownedCS tracks whether we must release the fallback space.
            CGColorSpaceRef cs = ciImage.colorSpace;
            BOOL ownedCS = NO;
            if (!cs) {
                cs = CGColorSpaceCreateDeviceRGB();
                ownedCS = YES;
            }

            // ── Step 3: JPEG encode ──────────────────────────────────────────
            // kCGImageDestinationLossyCompressionQuality @0.9 matches the raw
            // capture path in VanguardCameraMediaSource.takePhotoToURL:.
            // JPEGRepresentationOfImage: triggers CIContext rendering — the
            // CIImage lazy recipe is evaluated and processedBuffer is consumed.
            // processedBuffer MUST still be valid at this point.
            NSDictionary *options = @{
                (id)kCGImageDestinationLossyCompressionQuality: @0.9,
            };
            NSData *jpegData = [self->_ciContext
                JPEGRepresentationOfImage:ciImage
                               colorSpace:cs
                                  options:options];

            // Release pixel buffer now — CIContext rendering is complete.
            // This is the one and only CVPixelBufferRelease for the retained +1.
            CVPixelBufferRelease(processedBuffer);

            // Release any fallback color space we created.
            if (ownedCS) {
                CGColorSpaceRelease(cs);
            }

            // ── Step 4: Guard: encoding failure ─────────────────────────────
            if (!jpegData) {
                NSError *error = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                     code:6
                                                 userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"GRAPH_PHOTO_ENCODE_FAILED: "
                        "CIContext JPEGRepresentationOfImage returned nil."
                }];
                completion(nil, error);
                return;
            }

            // ── Step 5: Atomic file write ────────────────────────────────────
            // NSDataWritingAtomic writes to a temp file first and renames;
            // the destination is never left in a partial state.
            NSError *writeError = nil;
            BOOL written = [jpegData writeToURL:fileURL
                                        options:NSDataWritingAtomic
                                          error:&writeError];
            if (!written) {
                NSMutableDictionary *ui = [NSMutableDictionary dictionaryWithCapacity:2];
                ui[NSLocalizedDescriptionKey] =
                    [NSString stringWithFormat:
                        @"GRAPH_PHOTO_WRITE_FAILED: Failed to write JPEG to %@",
                        path];
                if (writeError) {
                    ui[NSUnderlyingErrorKey] = writeError;
                }
                NSError *error = [NSError errorWithDomain:@"VGPhotoSinkNode"
                                                     code:7
                                                 userInfo:[ui copy]];
                completion(nil, error);
                return;
            }

            // ── Success ──────────────────────────────────────────────────────
            completion(path, nil);
        }
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
