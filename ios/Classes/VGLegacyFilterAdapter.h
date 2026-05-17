// VGLegacyFilterAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps any id<VGMetalFilterNode> (Phase 1/legacy GPU filter) into the V2
// VGTransformNode protocol so it can be inserted into a VGGraphDescriptor-
// driven DAG without modifying the wrapped class.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF) because UMF has
// no dependency on vanguard_media_engine. The dependency flows one-way:
//   vanguard_media_engine → UMF
//
// Pixel parity verification deferred to Phase 4 gate (RR-V2-003).
//
// Phase 3 stubs:
//   - negotiateFormatForPort:inputFormats: → returns nil
//   - All delegation is 1:1 to the wrapped VGMetalFilterNode.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VGMetalFilterNode.h (UMF),
// imported in the .m file only.
@protocol VGMetalFilterNode;

/// Thin V2 adapter wrapping any id<VGMetalFilterNode> as a VGTransformNode.
///
/// All protocol requirements delegate directly to the wrapped filter.
/// processEnvelope:device: has an identical signature on VGMetalFilterNode and
/// VGTransformNode — the call is a direct forward with no transformation.
///
/// Thread-safety: Inherits the thread-safety of the wrapped filter.
/// The wrapped filter is responsible for its own internal serialisation.
@interface VGLegacyFilterAdapter : NSObject <VGTransformNode>

/// The wrapped legacy GPU filter node. Retained by this adapter.
@property (nonatomic, strong, readonly) id<VGMetalFilterNode> filter;

/// Designated initialiser.
/// @param filter  The VGMetalFilterNode instance to wrap. Must not be nil.
- (instancetype)initWithFilter:(id<VGMetalFilterNode>)filter NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
