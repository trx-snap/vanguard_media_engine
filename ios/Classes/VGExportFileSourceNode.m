// VGExportFileSourceNode.m
// vanguard_media_engine — Phase 5C-2
//
// Pull-mode export file source backed by AVAssetReader.
//
// Apple Framework Checks applied:
//   AVAssetReader / AVAssetReaderTrackOutput:
//     - copyNextSampleBuffer: returns +1 CMSampleBufferRef. Caller must CFRelease.
//     - When output is exhausted, returns NULL. Reader status becomes
//       AVAssetReaderStatusCompleted on clean end, AVAssetReaderStatusFailed on error.
//     - alwaysCopiesSampleData = NO: output vends the original decoded buffer
//       directly without an extra copy. Improves performance; buffer is read-only.
//     - Output settings: kCVPixelBufferPixelFormatTypeKey=32BGRA,
//       kCVPixelBufferMetalCompatibilityKey=YES, kCVPixelBufferIOSurfacePropertiesKey=@{}
//       ensure Metal-compatible, IOSurface-backed pixel buffers (same as playback path).
//
//   CMSampleBufferGetImageBuffer:
//     - Returns +0 CVPixelBufferRef. Caller must CVPixelBufferRetain if it wants
//       to hold the buffer past CFRelease(sample). See Apple docs: "The caller does
//       not own the returned buffer and must retain it if the caller needs to
//       reference it after the lifetime of the sample buffer."
//
//   CVPixelBufferRetain / CVPixelBufferRelease:
//     - Standard CF retain/release. Safe from any thread.
//     - Source retains before releasing sample; owns one +1 reference.
//     - Released on next pullFrame: or invalidate.
//
//   seekTo:generation: — rebuilds AVAssetReader with timeRange.
//     AVAssetReader is forward-only; it cannot rewind. Must cancel and recreate.
//
// Buffer ownership (RR-36):
//   _lastDeliveredBuffer is the source's single retained pixel buffer (+1).
//   Released before each new pullFrame: decode. Released on invalidate.
//   VGFrameEnvelope.payload.videoBuffer carries +0 per VGFrameEnvelope.h contract.
//   The buffer remains valid until the next pullFrame: or invalidate because
//   VGExportScheduler runs a single-threaded serial pull loop.
//
// This file does NOT import:
//   VanguardFileMediaSource, VanguardGraphRuntime, VanguardMetalRenderer,
//   VGFrameDelegate, VGVideoEncoderSinkNode, VGExportGraphFactory, AVAssetWriter.
//
// Phase 5C-2: Sequential video-only pull source. No audio. No time remapping.

#import "VGExportFileSourceNode.h"

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGRenderMode.h>

#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <os/log.h>
#include <stdatomic.h>

static os_log_t sFileSourceLog;

// ─────────────────────────────────────────────────────────────────────────────

@implementation VGExportFileSourceNode {
    // ── Asset ─────────────────────────────────────────────────────────────────
    AVAsset            *_asset;
    AVAssetTrack       *_videoTrack;

    // ── Reader (created/recreated in prepareWithContext: and seekTo:generation:)
    AVAssetReader            *_reader;
    AVAssetReaderTrackOutput *_trackOutput;

    // ── Identity (stable after init) ─────────────────────────────────────────
    NSString           *_nodeId;

    // ── Generation (updated on prepareWithContext: and seekTo:generation:) ───
    uint64_t            _generation;

    // ── Buffer ownership (RR-36) ──────────────────────────────────────────────
    // Retained +1 by source. Released before each new pullFrame: decode
    // and on invalidate. Valid during scheduler's frame delivery chain.
    CVPixelBufferRef    _lastDeliveredBuffer;  // nullable; +1

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    atomic_int          _invalidated;  // CAS gate: 0 → 1
}

@synthesize renderSize = _renderSize;
@synthesize sourceFPS  = _sourceFPS;

// Private backing for public readonly properties.
CGSize _renderSize;
double _sourceFPS;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Init
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithAsset:(AVAsset *)asset {
    NSParameterAssert(asset != nil);
    self = [super init];
    if (!self) return nil;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFileSourceLog = os_log_create("com.vanguard.export.file_source",
                                       "VGExportFileSourceNode");
    });

    _asset    = asset;
    _nodeId   = [[NSUUID UUID] UUIDString];
    _invalidated = 0;
    _lastDeliveredBuffer = NULL;
    _generation = 0;

    // Find first video track synchronously (asset is local file).
    NSArray<AVAssetTrack *> *tracks =
        [asset tracksWithMediaType:AVMediaTypeVideo];
    _videoTrack = tracks.firstObject;

    if (_videoTrack) {
        // Compute renderSize by applying preferredTransform to naturalSize.
        CGSize natural  = _videoTrack.naturalSize;
        CGAffineTransform t = _videoTrack.preferredTransform;

        // After applying the transform, width and height may swap (portrait video).
        CGRect rect = CGRectApplyAffineTransform(CGRectMake(0, 0, natural.width, natural.height), t);
        _renderSize = CGSizeMake(fabs(rect.size.width), fabs(rect.size.height));

        // Source FPS — fallback to 30.0 if track reports 0.
        _sourceFPS = _videoTrack.nominalFrameRate > 0 ? _videoTrack.nominalFrameRate : 30.0;
    } else {
        _renderSize = CGSizeZero;
        _sourceFPS  = 30.0;
        os_log_error(sFileSourceLog, "initWithAsset: no video track found in asset");
    }

    return self;
}

- (void)dealloc {
    [self invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Identity
// ─────────────────────────────────────────────────────────────────────────────

- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGExportFileSourceNode"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSource; }

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Port declaration
// ─────────────────────────────────────────────────────────────────────────────

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo],
    ];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Format negotiation
// ─────────────────────────────────────────────────────────────────────────────

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    if ([portId isEqualToString:@"video_out"] && _renderSize.width > 0) {
        return [VGMediaFormat videoFormatWithPixelFormat:kCVPixelFormatType_32BGRA
                                                  width:(uint32_t)_renderSize.width
                                                 height:(uint32_t)_renderSize.height];
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGNode — Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    // Capture generation from context (may be 0 for export graphs).
    _generation = context.generation;

    NSError *readerError = nil;
    if (![self _buildReaderFromTime:kCMTimeZero error:&readerError]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            if (completion) completion(readerError);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (completion) completion(nil);
    });
}

- (void)invalidate {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&_invalidated, &expected, 1)) {
        return;  // Already invalidated — idempotent.
    }

    // Cancel reader.
    if (_reader) {
        [_reader cancelReading];
        _reader      = nil;
        _trackOutput = nil;
    }

    // Release last delivered buffer.
    if (_lastDeliveredBuffer) {
        CVPixelBufferRelease(_lastDeliveredBuffer);
        _lastDeliveredBuffer = NULL;
    }

    os_log(sFileSourceLog, "invalidated");
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Push-mode (no-ops for pull-only source)
// ─────────────────────────────────────────────────────────────────────────────

- (void)startProducing {
    // No-op. VGExportFileSourceNode is pull-only (VGClockPolicyPull).
    // VGExportScheduler drives production via pullFrame:, not push callbacks.
}

- (void)stopProducing {
    // No-op. Pull-only source; no push callback to cancel.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Pull-mode
// ─────────────────────────────────────────────────────────────────────────────

- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    // ── Guard 1: invalidated ──────────────────────────────────────────────────
    if (atomic_load(&_invalidated)) {
        NSError *err = [NSError errorWithDomain:@"VGExportFileSourceNode"
                                           code:1
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"pullFrame: called after invalidate."
        }];
        return [VGFrameResult errorResult:err generation:request.generation];
    }

    // ── Guard 2: cancelled request ────────────────────────────────────────────
    if (request.isCancelled) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── Guard 3: generation mismatch ──────────────────────────────────────────
    if (request.generation != _generation) {
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── Guard 4: reader not ready ─────────────────────────────────────────────
    if (!_reader || !_trackOutput) {
        NSError *err = [NSError errorWithDomain:@"VGExportFileSourceNode"
                                           code:2
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"pullFrame: called before prepareWithContext:."
        }];
        return [VGFrameResult errorResult:err generation:request.generation];
    }

    // ── Release previous buffer (RR-36) ──────────────────────────────────────
    // Source owns _lastDeliveredBuffer (+1). Release before acquiring next frame.
    if (_lastDeliveredBuffer) {
        CVPixelBufferRelease(_lastDeliveredBuffer);
        _lastDeliveredBuffer = NULL;
    }

    // ── Pull next sample from AVAssetReaderTrackOutput ────────────────────────
    // copyNextSampleBuffer returns +1 CMSampleBufferRef.
    // Returns NULL when exhausted (status → Completed) or on error (status → Failed).
    CMSampleBufferRef sample = [_trackOutput copyNextSampleBuffer];

    if (!sample) {
        // Reader exhausted or failed. Map status to VGFrameResult.
        AVAssetReaderStatus status = _reader.status;
        if (status == AVAssetReaderStatusCompleted) {
            return [VGFrameResult endOfStreamWithGeneration:request.generation];
        } else if (status == AVAssetReaderStatusFailed) {
            NSError *err = _reader.error ?: [NSError errorWithDomain:@"VGExportFileSourceNode"
                                                                code:3
                                                            userInfo:@{
                NSLocalizedDescriptionKey: @"AVAssetReader failed with unknown error."
            }];
            return [VGFrameResult errorResult:err generation:request.generation];
        }
        // Defensive: unknown status — treat as EOS.
        return [VGFrameResult endOfStreamWithGeneration:request.generation];
    }

    // ── Extract pixel buffer ──────────────────────────────────────────────────
    // CMSampleBufferGetImageBuffer returns +0 CVPixelBufferRef.
    // Must retain before releasing sample.
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    if (!pb) {
        CFRelease(sample);
        // Sample exists but has no image buffer (e.g. timing-only sample). Skip.
        return [VGFrameResult skippedWithGeneration:request.generation];
    }

    // ── Retain pixel buffer before releasing sample (Apple Framework Check) ───
    // After CFRelease(sample), the CVPixelBuffer may be freed if not retained.
    CVPixelBufferRetain(pb);

    // ── Extract timing ────────────────────────────────────────────────────────
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    CMTime sampleDuration = CMSampleBufferGetDuration(sample);
    CMTime duration = CMTIME_IS_VALID(sampleDuration) && !CMTIME_IS_INDEFINITE(sampleDuration)
        ? sampleDuration
        : CMTimeMake(1, (int32_t)_sourceFPS);

    // ── Release sample (pixel buffer now independently retained) ─────────────
    CFRelease(sample);

    // ── Store retained buffer (source owns +1) ────────────────────────────────
    _lastDeliveredBuffer = pb;

    // ── Build VGFrameEnvelope ─────────────────────────────────────────────────
    // payload.videoBuffer is +0 per VGFrameEnvelope.h contract.
    // The pointer is valid until the next pullFrame: or invalidate.
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.mediaType          = VGMediaTypeVideo;
    env.payload.videoBuffer = (void *)pb;  // +0 in envelope; source holds +1
    env.pts                = pts;
    env.dts                = kCMTimeInvalid;
    env.duration           = duration;
    env.generation         = request.generation;
    env.metadata           = NULL;

    return [VGFrameResult deliveredWithEnvelope:env generation:request.generation];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSourceNode — Seek
// ─────────────────────────────────────────────────────────────────────────────

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // Update generation so in-flight pullFrame: calls with the old generation
    // return .skipped.
    _generation = generation;

    // Release held buffer before rebuilding reader.
    if (_lastDeliveredBuffer) {
        CVPixelBufferRelease(_lastDeliveredBuffer);
        _lastDeliveredBuffer = NULL;
    }

    // AVAssetReader is forward-only. Cancel current reader and recreate with
    // a timeRange starting at the seek position.
    if (_reader) {
        [_reader cancelReading];
        _reader      = nil;
        _trackOutput = nil;
    }

    NSError *error = nil;
    if (![self _buildReaderFromTime:time error:&error]) {
        os_log_error(sFileSourceLog, "seekTo: failed to rebuild reader: %{public}@",
                     error.localizedDescription);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Build (or rebuild) the AVAssetReader and AVAssetReaderTrackOutput starting
/// at `startTime`. For kCMTimeZero, no timeRange is set (reads full asset).
///
/// Output settings match the playback path (VanguardFileMediaSource._setupAssetReader):
///   kCVPixelFormatType_32BGRA + MetalCompatibility + IOSurface backing.
///
/// alwaysCopiesSampleData = NO: vends original decoded buffers (read-only).
/// This avoids an extra copy on every frame and matches the playback path.
///
/// Returns YES on success; NO with error on failure.
- (BOOL)_buildReaderFromTime:(CMTime)startTime error:(NSError **)outError {
    if (!_videoTrack) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGExportFileSourceNode"
                                            code:4
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"No video track found in asset."
            }];
        }
        return NO;
    }

    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:_asset error:&error];
    if (!reader || error) {
        if (outError) *outError = error;
        return NO;
    }

    // For seek positions > 0, set timeRange so the reader starts near the
    // target. Same pattern as VanguardFileMediaSource._rebuildVideoReaderForSecs:.
    if (CMTIME_IS_VALID(startTime) && CMTimeGetSeconds(startTime) > 0) {
        CMTime assetDuration = _asset.duration;
        if (CMTIME_IS_VALID(assetDuration) &&
            CMTimeCompare(startTime, assetDuration) < 0) {
            CMTime remaining = CMTimeSubtract(assetDuration, startTime);
            reader.timeRange = CMTimeRangeMake(startTime, remaining);
        }
    }

    // Output settings: 32BGRA + Metal-compatible + IOSurface-backed.
    // Same settings as VanguardFileMediaSource (playback path) for consistency.
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey:  @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:_videoTrack
                                         outputSettings:outputSettings];
    // alwaysCopiesSampleData = NO: use original decoded buffer (read-only).
    // Avoids per-frame copy. Matches playback path (VanguardFileMediaSource.m:1965).
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGExportFileSourceNode"
                                            code:5
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Cannot add AVAssetReaderTrackOutput to reader."
            }];
        }
        return NO;
    }

    [reader addOutput:output];

    if (![reader startReading]) {
        if (outError) *outError = reader.error;
        return NO;
    }

    _reader      = reader;
    _trackOutput = output;

    os_log(sFileSourceLog, "reader built from %.3fs — status=%ld",
           CMTimeGetSeconds(startTime), (long)reader.status);
    return YES;
}

@end
