// VGStillImageFilterFactory.h
// vanguard_media_engine — Photo-mode high-resolution Beauty fix
//
// VGStillImageFilterFactory builds isolated offline filter nodes for
// single-shot high-resolution still-image export. It is deliberately separate
// from VGCameraGraphFactory (push-mode live camera) to avoid mixing lifecycles.
//
// Scope: ConnectsApp global Beauty only.
//   - type == "beauty", beautyVersion == 2 → BeautyV2FilterGroup (primary).
//   - type == "beauty", beautyVersion != 2  → VanguardBeautyFilterNode (V1 fallback).
//   - Any other type, or faceAwareEnabled == true → visible NSError (NOT silently skipped).
//
// The factory creates a dimension-matched IOSurface-backed BGRA Metal-compatible
// CVPixelBufferPool, initializes BeautyV2FilterGroup (or V1) borrowing it, and
// returns a VGOfflineFilterBundle that ADOPTS the pool (+1 ownership transfer).
//
// All methods are class methods. This class must not be instantiated.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@class VGOfflineFilterBundle;

/// Factory for isolated offline still-image filter nodes.
@interface VGStillImageFilterFactory : NSObject

/// Create isolated offline filter nodes from live-graph spec dictionaries,
/// sized for the decoded still-image dimensions.
///
/// @param specs    Active filter spec dictionaries from graphSession.activeFilterSpecs.
///                 Each must contain "type" (NSString) and optional "parameters" (NSDictionary).
///                 Only "beauty" type is supported; any other type returns nil + error.
///                 faceAwareEnabled == true inside parameters returns nil + error.
/// @param width    Display-corrected pixel width (from UIImage.size, already EXIF-adjusted).
/// @param height   Display-corrected pixel height (from UIImage.size, already EXIF-adjusted).
/// @param device   MTLDevice. Must not be nil.
/// @param outError Populated on any failure (unsupported type, pool allocation failure, etc.)
/// @return VGOfflineFilterBundle owning the isolated nodes and the adopted pool, or nil on failure.
+ (nullable VGOfflineFilterBundle *)createOfflineFilterBundleFromSpecs:(NSArray<NSDictionary *> *)specs
                                                                 width:(size_t)width
                                                                height:(size_t)height
                                                                device:(id<MTLDevice>)device
                                                                 error:(NSError * _Nullable * _Nullable)outError;

/// init is unavailable.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
