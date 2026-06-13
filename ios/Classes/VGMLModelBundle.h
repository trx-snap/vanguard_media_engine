// VGMLModelBundle.h
// Phase 9B — Model resource resolver for VanguardMLModels.bundle.
//
// Locates the 'VanguardMLModels' resource bundle shipped inside the
// vanguard_media_engine CocoaPod and returns file URLs for named model assets.
//
// The bundle is nested inside the pod framework when use_frameworks! is on,
// so we walk the known bundle identifiers before falling back to the main bundle.
//
// Usage (caller does NOT own the returned NSURL — it is autoreleased):
//   NSURL *url = [VGMLModelBundle URLForModelNamed:@"selfie_multiclass_256x256"];
//   // url is nil if the asset is missing (treat as load failure).
//
// This file is the ONLY new Objective-C code added in Phase 9B-0.
// VGLiteRTMaskProvider is NOT implemented here — it is deferred to Phase 9B-1.
//
// Threading: stateless pure function — safe to call from any thread.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal static resolver for .tflite model assets in VanguardMLModels.bundle.
@interface VGMLModelBundle : NSObject

/// Returns a file URL for the named .tflite asset, or nil if not found.
///
/// @param modelName  Base name WITHOUT extension (e.g. @"selfie_multiclass_256x256").
+ (nullable NSURL *)URLForModelNamed:(NSString *)modelName;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
