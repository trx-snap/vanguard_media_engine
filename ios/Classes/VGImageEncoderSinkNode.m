// VGImageEncoderSinkNode.m
// vanguard_media_engine — Phase 5D-2
//
// Concrete VGFrameSink: CGImageDestination-based still-image encoder.
//
// Pull-mode only. No AVAssetWriter. No VanguardVideoToolboxEncoder.
// No VGGraphSchedulerV2. No push callbacks. No camera path.
//
// Key architectural invariants:
//   - presentEnvelope: is synchronous — writes the image file before returning.
//   - CVPixelBuffer → CGImage via VTCreateCGImageFromCVPixelBuffer (Apple recommended).
//   - CGImageDestination created per-encode in presentEnvelope: (single image).
//   - No semaphore needed — all operations are synchronous.
//   - Output format resolved during prepareWithContext: via resolvedFormatForPlatform.
//
// NOT imported:
//   AVAssetWriter, VanguardVideoToolboxEncoder, VGGraphSchedulerV2,
//   VanguardFileMediaSource, VanguardGraphRuntime, VanguardMetalRenderer,
//   VGFrameDelegate, VGExportScheduler.

#import "VGImageEncoderSinkNode.h"

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGImageEncodeFormat.h>
#import <UMF/VGImageColorProfilePolicy.h>

#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VTUtilities.h>
#import <MobileCoreServices/MobileCoreServices.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Error domain ─────────────────────────────────────────────────────────────
static NSString *const kVGImageEncoderSinkNodeErrorDomain = @"VGImageEncoderSinkNode";

// ─── Error codes ──────────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger, VGImageEncoderSinkNodeError) {
    VGImageEncoderSinkNodeErrorInvalidated                = 10,
    VGImageEncoderSinkNodeErrorDeleteExistingFile          = 11,
    VGImageEncoderSinkNodeErrorUnsupportedFormat           = 12,
    VGImageEncoderSinkNodeErrorUnsupportedColorPolicy      = 13,
    VGImageEncoderSinkNodeErrorUnsupportedOrientationPolicy = 14,
    VGImageEncoderSinkNodeErrorNotPrepared                 = 20,
    VGImageEncoderSinkNodeErrorNoFrameSubmitted             = 21,
    VGImageEncoderSinkNodeErrorOutputFileMissing            = 22,
    VGImageEncoderSinkNodeErrorOutputFileEmpty              = 23,
    VGImageEncoderSinkNodeErrorCGImageCreationFailed        = 30,
    VGImageEncoderSinkNodeErrorDestinationCreationFailed    = 31,
    VGImageEncoderSinkNodeErrorFinalizeFailed               = 32,
    VGImageEncoderSinkNodeErrorUnsupportedPixelFormat       = 33,
    VGImageEncoderSinkNodeErrorNullBuffer                   = 34,
};

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - UTI mapping
// ─────────────────────────────────────────────────────────────────────────────

/// Map VGImageEncodeFormat to a CFString UTI for CGImageDestination.
/// Returns NULL for unsupported formats on iOS (WebP).
static CFStringRef _Nullable _UTIForFormat(VGImageEncodeFormat format) {
    switch (format) {
        case VGImageEncodeFormatJPEG:
            return kUTTypeJPEG;
        case VGImageEncodeFormatHEIC:
            // "public.heic" — available on iOS 11+ with HEVC hardware
            return CFSTR("public.heic");
        case VGImageEncodeFormatPNG:
            return kUTTypePNG;
        case VGImageEncodeFormatWebP:
            // P0-FU-025: WebP encoding NOT supported on iOS via ImageIO.
            // Caller must use resolvedFormatForPlatform before reaching here.
            return NULL;
        default:
            return NULL;
    }
}

/// Returns a human-readable name for the color space used in the manifest.
static NSString *_ColorSpaceNameFromCGColorSpace(CGColorSpaceRef _Nullable cs) {
    if (!cs) return @"";
    CFStringRef name = CGColorSpaceGetName(cs);
    if (name) {
        return (__bridge NSString *)name;
    }
    return @"";
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - @implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGImageEncoderSinkNode {
    // Identity
    NSString                *_nodeId;

    // Init-time config
    NSURL                   *_outputURL;
    VGImageExportProfile    *_profile;

    // State
    BOOL                     _ready;
    BOOL                     _invalidated;
    NSInteger                _framesSubmitted;

    // Resolved at prepare time
    VGImageEncodeFormat      _resolvedFormat;
    CFStringRef              _resolvedUTI;

    // Output tracking for manifest
    int32_t                  _outputWidth;
    int32_t                  _outputHeight;
    NSString                *_outputColorSpace;
    BOOL                     _orientationApplied;
}

@synthesize ready = _ready;
@synthesize framesSubmitted = _framesSubmitted;

// ─── VGNode identity ──────────────────────────────────────────────────────────

- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGImageEncoderSinkNode"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSink; }

- (NSArray<VGMediaPort *> *)declaredPorts {
    // Sink: one required video_in port. No output ports.
    return @[ [VGMediaPort inputPort:@"video_in"
                           mediaType:VGMediaTypeVideo
                            required:YES] ];
}

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    // Sink nodes do not produce output — no format negotiation needed.
    return nil;
}

// ─── Init ─────────────────────────────────────────────────────────────────────

- (instancetype)initWithOutputURL:(NSURL *)outputURL
                          profile:(VGImageExportProfile *)profile {
    NSParameterAssert(outputURL != nil);
    NSParameterAssert(profile != nil);

    self = [super init];
    if (!self) return nil;

    _nodeId          = [[NSUUID UUID] UUIDString];
    _outputURL       = outputURL;
    _profile         = profile;

    _ready           = NO;
    _invalidated     = NO;
    _framesSubmitted = 0;

    _resolvedFormat  = VGImageEncodeFormatJPEG;
    _resolvedUTI     = NULL;

    _outputWidth     = 0;
    _outputHeight    = 0;
    _outputColorSpace = @"";
    _orientationApplied = NO;

    return self;
}

// ─── VGNode lifecycle ──────────────────────────────────────────────────────────

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError *_Nullable))completion {
    NSAssert(completion != nil, @"VGImageEncoderSinkNode: completion must not be nil");

    if (_invalidated) {
        completion([NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                       code:VGImageEncoderSinkNodeErrorInvalidated
                                   userInfo:@{
            NSLocalizedDescriptionKey: @"Node is invalidated"
        }]);
        return;
    }

    // ── 1. Validate color profile policy ──────────────────────────────────────
    //
    // Phase 5D-2: Only Preserve is fully supported.
    // Other policies require CGColorSpace conversion which is deferred.
    VGImageColorProfilePolicyType colorPolicy = _profile.colorProfilePolicy;
    if (colorPolicy != VGImageColorProfilePolicyPreserve) {
        completion([NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                       code:VGImageEncoderSinkNodeErrorUnsupportedColorPolicy
                                   userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"Color profile policy '%@' is not yet supported in Phase 5D-2. "
                    @"Only VGImageColorProfilePolicyPreserve is supported. "
                    @"Color conversion deferred to Phase 12+.",
                    VGImageColorProfilePolicyName(colorPolicy)]
        }]);
        return;
    }

    // ── 2. Validate orientation policy ────────────────────────────────────────
    //
    // Phase 5D-2: Only Preserve is fully supported.
    // ApplyAndRotate requires pixel rotation for 8 EXIF cases — deferred.
    VGImageOrientationPolicyType orientPolicy = _profile.orientationPolicy;
    if (orientPolicy != VGImageOrientationPolicyPreserve) {
        completion([NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                       code:VGImageEncoderSinkNodeErrorUnsupportedOrientationPolicy
                                   userInfo:@{
            NSLocalizedDescriptionKey:
                @"Orientation policy 'ApplyAndRotate' is not yet supported in Phase 5D-2. "
                @"Only VGImageOrientationPolicyPreserve is supported. "
                @"Pixel rotation deferred to Phase 12+."
        }]);
        return;
    }

    // ── 3. Resolve format via platform capability probe ───────────────────────
    _resolvedFormat = [_profile resolvedFormatForPlatform];
    _resolvedUTI = _UTIForFormat(_resolvedFormat);

    if (!_resolvedUTI) {
        completion([NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                       code:VGImageEncoderSinkNodeErrorUnsupportedFormat
                                   userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"Resolved format %ld is not supported for encoding on this platform",
                    (long)_resolvedFormat]
        }]);
        return;
    }

    // ── 4. Delete existing output file ────────────────────────────────────────
    //
    // CGImageDestinationCreateWithURL can overwrite per Apple docs, but we
    // delete proactively for consistency with VGVideoEncoderSinkNode pattern.
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_outputURL.path]) {
        NSError *deleteErr = nil;
        [fm removeItemAtURL:_outputURL error:&deleteErr];
        if (deleteErr) {
            completion([NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                           code:VGImageEncoderSinkNodeErrorDeleteExistingFile
                                       userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"Failed to delete existing file at %@: %@",
                        _outputURL.path, deleteErr.localizedDescription],
                NSUnderlyingErrorKey: deleteErr
            }]);
            return;
        }
    }

    _ready = YES;
    completion(nil);
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    _ready = NO;
}

// ─── VGFrameSink — presentEnvelope: ──────────────────────────────────────────

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    // Guard: sink must be ready and not invalidated.
    if (!_ready || _invalidated) return;

    CVPixelBufferRef rawBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!rawBuffer) return;

    // ── 1. Validate pixel format ──────────────────────────────────────────────
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(rawBuffer);
    if (pixelFormat != kCVPixelFormatType_32BGRA &&
        pixelFormat != kCVPixelFormatType_32ARGB &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        NSLog(@"[VGImageEncoderSinkNode] presentEnvelope: unsupported pixel format 0x%08X — "
              @"expected 32BGRA, 32ARGB, or 420v/420f", (unsigned int)pixelFormat);
        return;
    }

    // ── 2. Create CGImage from CVPixelBuffer ──────────────────────────────────
    //
    // VTCreateCGImageFromCVPixelBuffer is the Apple-recommended way to convert
    // CVPixelBuffer → CGImage. It handles color space, pixel format mapping,
    // and byte order automatically. Available iOS 9+.
    CGImageRef cgImage = NULL;
    OSStatus vtStatus = VTCreateCGImageFromCVPixelBuffer(rawBuffer, NULL, &cgImage);
    if (vtStatus != noErr || !cgImage) {
        NSLog(@"[VGImageEncoderSinkNode] presentEnvelope: VTCreateCGImageFromCVPixelBuffer "
              @"failed with status %d", (int)vtStatus);
        if (cgImage) CGImageRelease(cgImage);
        return;
    }

    // ── 3. Record output dimensions and color space ───────────────────────────
    _outputWidth  = (int32_t)CGImageGetWidth(cgImage);
    _outputHeight = (int32_t)CGImageGetHeight(cgImage);

    CGColorSpaceRef cs = CGImageGetColorSpace(cgImage);
    _outputColorSpace = _ColorSpaceNameFromCGColorSpace(cs);

    // ── 4. Create CGImageDestination ──────────────────────────────────────────
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)_outputURL,
        _resolvedUTI,
        1,      // count: exactly 1 image
        NULL    // options: none
    );
    if (!dest) {
        NSLog(@"[VGImageEncoderSinkNode] presentEnvelope: "
              @"CGImageDestinationCreateWithURL failed for UTI %@",
              (__bridge NSString *)_resolvedUTI);
        CGImageRelease(cgImage);
        return;
    }

    // ── 5. Build per-image properties ─────────────────────────────────────────
    //
    // Quality: kCGImageDestinationLossyCompressionQuality (0.0–1.0).
    // PNG ignores this property (lossless).
    // Orientation: Preserve policy — no EXIF orientation tag manipulation.
    NSMutableDictionary *props = [NSMutableDictionary dictionaryWithCapacity:2];
    if (_resolvedFormat == VGImageEncodeFormatJPEG ||
        _resolvedFormat == VGImageEncodeFormatHEIC) {
        props[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] =
            @(_profile.quality);
    }
    // Preserve policy: no orientation property set — source orientation passes through.
    _orientationApplied = NO;

    // ── 6. Add image to destination ───────────────────────────────────────────
    CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);

    // ── 7. Finalize (synchronous write) ───────────────────────────────────────
    bool finalized = CGImageDestinationFinalize(dest);

    // ── 8. Release CF objects ─────────────────────────────────────────────────
    CFRelease(dest);
    CGImageRelease(cgImage);

    if (!finalized) {
        NSLog(@"[VGImageEncoderSinkNode] presentEnvelope: CGImageDestinationFinalize "
              @"returned false — image write failed");
        return;
    }

    _framesSubmitted++;
}

// ─── Export finalization ──────────────────────────────────────────────────────

- (nullable VGImageExportManifest *)finalizeExportWithError:(NSError *_Nullable *_Nullable)outError {
    if (!_ready && !_framesSubmitted) {
        if (outError) {
            *outError = [NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                            code:VGImageEncoderSinkNodeErrorNotPrepared
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Node was not prepared or no frames submitted"
            }];
        }
        return nil;
    }

    if (_framesSubmitted < 1) {
        if (outError) {
            *outError = [NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                            code:VGImageEncoderSinkNodeErrorNoFrameSubmitted
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"presentEnvelope: was never called successfully"
            }];
        }
        return nil;
    }

    // ── Verify output file exists ─────────────────────────────────────────────
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:_outputURL.path]) {
        if (outError) {
            *outError = [NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                            code:VGImageEncoderSinkNodeErrorOutputFileMissing
                                        userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Output file missing at %@", _outputURL.path]
            }];
        }
        return nil;
    }

    // ── Measure file size ─────────────────────────────────────────────────────
    NSError *attrErr = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:_outputURL.path error:&attrErr];
    int64_t fileSizeBytes = (int64_t)[attrs[NSFileSize] longLongValue];

    if (fileSizeBytes <= 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:kVGImageEncoderSinkNodeErrorDomain
                                            code:VGImageEncoderSinkNodeErrorOutputFileEmpty
                                        userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Output file is empty (0 bytes) at %@",
                        _outputURL.path]
            }];
        }
        return nil;
    }

    // ── Build VGImageExportManifest ───────────────────────────────────────────
    VGImageExportManifest *manifest = [[VGImageExportManifest alloc]
        initWithFormat:_resolvedFormat
                 width:_outputWidth
                height:_outputHeight
         fileSizeBytes:fileSizeBytes
            colorSpace:_outputColorSpace ?: @""
    orientationApplied:_orientationApplied
               quality:_profile.quality];

    _ready = NO;  // Finalized — no more frames accepted.
    return manifest;
}

// ─── dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    [self invalidate];
}

@end

NS_ASSUME_NONNULL_END
