// VanguardMaskSnapshot.m

#import "VanguardMaskSnapshot.h"

@implementation VanguardMaskSnapshot

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          timestamp:(NSTimeInterval)timestamp
                         generation:(uint64_t)generation {
    self = [super init];
    if (!self) return nil;
    _pixelBuffer = pixelBuffer;
    if (_pixelBuffer) CVPixelBufferRetain(_pixelBuffer);
    _timestamp  = timestamp;
    _generation = generation;
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

@end
