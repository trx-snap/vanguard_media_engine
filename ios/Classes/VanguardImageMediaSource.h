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

@end

NS_ASSUME_NONNULL_END
