// VGMetalLibraryResolver.h
// Phase 9B-5 — Metal shader packaging repair for static-linkage CocoaPods builds.
//
// Problem:
//   With `use_frameworks! :linkage => :static` (required for TensorFlowLiteC),
//   vanguard_media_engine compiles as a static archive. Xcode places the compiled
//   default.metallib inside an intermediate .framework product in DerivedData,
//   but that product is NOT embedded in Runner.app. All five Metal library load
//   sites (using `newDefaultLibraryWithBundle:[NSBundle bundleForClass:[self class]]`)
//   fail at runtime with MTLLibraryErrorDomain Code=6.
//
// Fix:
//   The two .metal shader files (VanguardEffects.metal, VanguardCompositor.metal)
//   are placed in the 'VanguardMetal' resource_bundles entry in the podspec.
//   Xcode compiles them into default.metallib inside VanguardMetal.bundle,
//   which CocoaPods copies into Runner.app. This resolver locates that bundle and
//   loads the library via newLibraryWithFile:error:.
//
// Usage:
//   id<MTLLibrary> lib = [VGMetalLibraryResolver libraryForDevice:device];
//   if (!lib) { /* handle failure */ }

#pragma once
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VGMetalLibraryResolver : NSObject

/// Returns a compiled MTLLibrary sourced from VanguardMetal.bundle.
///
/// Search order:
///   1. VanguardMetal.bundle inside the bundle that loaded VGMetalLibraryResolver
///      (framework path — use_frameworks! dynamic mode).
///   2. VanguardMetal.bundle inside the main app bundle
///      (static linkage / test host path).
///   3. default.metallib directly inside any candidate bundle's resourcePath
///      (fallback for non-standard layouts).
///
/// The result is loaded fresh each call (no cache) to allow device-specific
/// compilation. Callers should cache the returned library for the lifetime of
/// their GPU pipeline.
///
/// @param device  The MTLDevice to compile the library for.
/// @param caller  A short label used in log messages (e.g. @"BeautyV2").
/// @return        A compiled MTLLibrary, or nil on failure (error is logged).
+ (nullable id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device
                                     caller:(NSString *)caller;

@end

NS_ASSUME_NONNULL_END
