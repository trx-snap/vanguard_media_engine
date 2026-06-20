// VanguardImageMediaSource.h
// Phase 2 — P2-T5: Static image timeline node
//
// Conforms to VanguardMediaSource. Decodes an image URL to a CVPixelBuffer
// and holds it indefinitely (duration = kCMTimeIndefinite).
// Seek is a no-op; the same frame is always displayed.
// Used for photos in the story timeline.

#import "VanguardMediaSource.h"
#import "VanguardImageProcessor.h"
#import <UMF/VGMediaNode.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VanguardImageMediaSource : NSObject <VanguardMediaSource, VGMediaNode>

/// Designated initialiser.
/// @param imageURL               Local file URL for a JPEG/PNG/HEIC/WebP image
/// @param processor              Shared VanguardImageProcessor — no new pool allocation
/// @param releaseBuffersOnInvalidate  When YES, CVPixelBufferRelease is called for
///   _buffer and _rawBuffer inside invalidate(). Safe ONLY for one-shot serial
///   export sessions (VGImageExportSession). Must remain NO (default) for any
///   live-preview or concurrent rendering path to prevent IOSurface fence deadlocks.
- (instancetype)initWithURL:(NSURL *)imageURL
                  processor:(VanguardImageProcessor *)processor
   releaseBuffersOnInvalidate:(BOOL)releaseBuffersOnInvalidate NS_DESIGNATED_INITIALIZER;

/// Convenience initialiser — releaseBuffersOnInvalidate defaults to NO.
/// All live-preview and rendering paths use this initialiser.
- (instancetype)initWithURL:(NSURL *)imageURL
                  processor:(VanguardImageProcessor *)processor;

- (instancetype)init NS_UNAVAILABLE;

/// When YES, invalidate() will call CVPixelBufferRelease on _buffer and _rawBuffer.
/// Default: NO (historical intentional-leak policy for live/preview paths).
/// Set to YES only for one-shot serial export sessions (VGImageExportSession).
@property (nonatomic, readonly) BOOL releaseBuffersOnInvalidate;

/// Display-correct pixel dimensions of the decoded image.
/// Set during prepareWithCompletion: from UIImage.size, which already applies EXIF
/// orientation. Zero until prepareWithCompletion: succeeds.
/// Read by VanguardGraphRuntime to size the session pixel buffer pool at the correct
/// aspect ratio (avoiding the 1080×1920 fallback for non-9:16 photos).
@property (nonatomic, readonly) CGSize renderSize;

/// Returns a +1 retained copy of the original unfiltered image buffer.
/// Returns NULL if the buffer has not yet been decoded (start not called) or
/// if the source has been invalidated.
/// Caller MUST CVPixelBufferRelease the returned buffer.
- (nullable CVPixelBufferRef)copyRawBuffer;

@end

NS_ASSUME_NONNULL_END
