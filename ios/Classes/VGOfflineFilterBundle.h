// VGOfflineFilterBundle.h
// vanguard_media_engine — Photo-mode high-resolution Beauty fix
//
// VGOfflineFilterBundle is a simple ownership container that groups isolated
// offline filter nodes with the dimension-matched CVPixelBufferPool they borrow
// for output.
//
// Ownership contract:
//   The bundle ADOPTS a +1 CVPixelBufferPoolRef (passed via adoptedPool:).
//   It calls CVPixelBufferPoolRelease on that pool in dealloc.
//   BeautyV2FilterGroup borrows the pool (initWithPool:device:) and must never
//   outlive this bundle. Because VGImageExportSession invalidates filter nodes
//   at completion, and the bundle is released after session completion, the
//   ordering is always: session invalidates nodes → bundle released → pool released.
//
// Thread-safety: immutable after init. Read from any thread.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Ownership container for isolated offline filter nodes and their output pool.
@interface VGOfflineFilterBundle : NSObject

/// Ordered array of isolated id<VGMetalFilterNode> instances for VGImageExportSession.
@property (nonatomic, readonly) NSArray *nodes;

/// Designated initializer.
///
/// @param nodes       Ordered filter nodes (id<VGMetalFilterNode>). Copied.
/// @param adoptedPool The +1 CVPixelBufferPoolRef to adopt. The bundle calls
///                    CVPixelBufferPoolRelease in dealloc. Must not be NULL.
- (instancetype)initWithNodes:(NSArray *)nodes
                  adoptedPool:(CVPixelBufferPoolRef)adoptedPool NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithNodes:adoptedPool:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
