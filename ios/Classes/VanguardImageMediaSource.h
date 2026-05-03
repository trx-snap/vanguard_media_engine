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

/// @param imageURL  Local file URL for a JPEG/PNG/HEIC/WebP image
/// @param processor Shared VanguardImageProcessor — no new pool allocation
- (instancetype)initWithURL:(NSURL *)imageURL
                  processor:(VanguardImageProcessor *)processor NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

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
