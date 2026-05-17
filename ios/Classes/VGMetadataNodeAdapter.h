// VGMetadataNodeAdapter.h
// Phase 3: Adapter only. No runtime wiring.
//
// Wraps VGSegmentationNode (a VGMetalFilterNode conformer in vanguard_media_engine)
// into the V2 VGMetadataNode protocol. This exposes the segmentation node as a
// first-class metadata-producing DAG node without modifying VGSegmentationNode.
//
// Dependency note: Lives in vanguard_media_engine (NOT UMF).
//   vanguard_media_engine → UMF (one-way dependency, no circular risk).
//
// Pixel parity verification deferred to Phase 4 gate (RR-V2-003).
//
// Phase 3 stubs:
//   - negotiateFormatForPort:inputFormats: → returns nil
//   - enrichEnvelope:device: delegates to VGSegmentationNode.processEnvelope:device:
//     which already attaches metadata to the envelope.
//
// nodeRole: VGNodeRoleMetadata (= 4), declared as static const NSInteger in
// VGGraphNodeDescriptor.h. Cast to VGNodeRole at call site.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGMetadataNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration — full definition in VGSegmentationNode.h,
// imported in the .m file only.
@class VGSegmentationNode;

/// Thin V2 adapter wrapping VGSegmentationNode as a VGMetadataNode.
///
/// enrichEnvelope:device: delegates directly to
/// VGSegmentationNode.processEnvelope:device:, which reads the video payload,
/// runs face detection and mask generation, and attaches the result to
/// envelope.metadata under the @"com.vanguard.mask.skin" key.
///
/// The adapter exposes a metadata_out port keyed to @"com.vanguard.mask.skin"
/// so the V2 graph validator can verify the downstream consumer declares a
/// matching metadata_in port.
@interface VGMetadataNodeAdapter : NSObject <VGMetadataNode>

/// The wrapped segmentation node. Retained by this adapter.
@property (nonatomic, strong, readonly) VGSegmentationNode *node;

/// Designated initialiser.
/// @param node  The VGSegmentationNode instance to wrap. Must not be nil.
- (instancetype)initWithSegmentationNode:(VGSegmentationNode *)node NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
