// VGLivestreamOverlayFilterNode.h
// vanguard_media_engine — Slice G1-C (iOS livestream text/sticker overlay)
//
// Camera-graph filter node that burns the static G1-A livestream overlay items
// (VGFilterSpecs.overlay: text and sticker) into the processed camera frame, so
// the Flutter preview, the processed-frame receiver (WebRTC/LiveKit egress),
// recording and photo sinks all receive the same overlaid pixels.
//
// Graph position: VGCameraGraphSession always appends this node LAST in the
// filter chain — after beauty and VGGreenScreenFilterNode, immediately before
// the VGFanOutSink — whatever position the "overlay" spec had in the stack.
//
// Wire schema (G1-A, validated by +parseItemsFromParameters:error:):
//   parameters.canvas   {width: 720, height: 1280} — exactly
//   parameters.items[]  at most 8, each:
//     id        non-empty string
//     kind      "text" | "sticker"
//     x, y      top-left, normalized to the canvas, in [0, 1]
//     w, h      size, normalized to the canvas, in (0, 1]
//     opacity   [0, 1] (absent or null → 1.0)
//     z         integer paint order, 0...1024 (absent or null → 0)
//     text      text kind only: non-empty, at most 120 UTF-16 units;
//               must be absent/null for a sticker
//     assetPath sticker kind only: absolute local path ("/…", no "://")
//               ending in .png/.jpg/.jpeg (case-insensitive);
//               must be absent/null for a text item
//   Unknown parameter or item keys are rejected. Items are returned sorted by
//   ascending z, stable in list order for equal z (the paint order).
//
// Orientation: iOS camera-graph frames are already upright portrait in viewer
// orientation — VanguardCameraMediaSource locks portrait and bakes front-camera
// mirroring into the pixels (AVCaptureConnection.videoMirrored), and neither the
// preview renderer nor VanguardRTCVideoCapturer (rotation 0) flips them again.
// The overlay is therefore drawn in the buffer's own top-left pixel space and is
// NEVER mirrored: text reads normally and stickers keep their authored
// orientation on both cameras. The 720x1280 canvas maps onto the centered 9:16
// window of the frame (the whole frame for the 720x1280 livestream capture).
//
// Resources: sticker files are decoded (ImageIO, EXIF-upright, bounded) once at
// init; the whole overlay layer (stickers + CoreText text over a translucent
// rounded box, per-item opacity baked in) is rasterized once per frame size into
// one IOSurface-backed premultiplied BGRA buffer. The per-frame path only
// composites that layer over the input (Core Image source-over, no colour
// management) into a buffer from the session pool — no per-frame buffer
// creation, decode or text layout.
//
// Fail-closed: an item whose sticker cannot be read/decoded is skipped
// (IOS_LIVESTREAM_OVERLAY_ITEM_SKIPPED); any node-level failure logs
// IOS_LIVESTREAM_OVERLAY_BYPASS and returns the input frame unchanged, so the
// camera, beauty, green screen and egress keep running without the overlay.

#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>

NS_ASSUME_NONNULL_BEGIN

/// NSError domain for a malformed "overlay" filter spec (the Flutter error code).
FOUNDATION_EXPORT NSString *const VGLivestreamOverlayInvalidSpecErrorDomain;

typedef NS_ENUM(NSInteger, VGLivestreamOverlayItemKind) {
    VGLivestreamOverlayItemKindText = 0,
    VGLivestreamOverlayItemKindSticker = 1,
};

/// One validated, immutable overlay item.
@interface VGLivestreamOverlayItemSpec : NSObject
@property (nonatomic, readonly, copy) NSString *itemId;
@property (nonatomic, readonly) VGLivestreamOverlayItemKind kind;
@property (nonatomic, readonly) double x;
@property (nonatomic, readonly) double y;
@property (nonatomic, readonly) double w;
@property (nonatomic, readonly) double h;
@property (nonatomic, readonly) double opacity;
@property (nonatomic, readonly) NSInteger z;
@property (nonatomic, readonly, copy, nullable) NSString *text;
@property (nonatomic, readonly, copy, nullable) NSString *assetPath;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface VGLivestreamOverlayFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

/// Validates `parameters` against the G1-A wire schema above. Pure: no I/O and
/// no file-existence check (an unreadable sticker is skipped at init instead).
/// Returns the items in paint order, or nil with *outError in
/// VGLivestreamOverlayInvalidSpecErrorDomain.
+ (nullable NSArray<VGLivestreamOverlayItemSpec *> *)parseItemsFromParameters:(nullable id)parameters
                                                                        error:(NSError * _Nullable * _Nullable)outError;

/// Decodes every sticker once (skipping unreadable ones with a log) and keeps
/// the items for the lazily built overlay layer. Never returns nil.
/// @param pool   Session-owned BGRA pool with the camera frame size; retained.
/// @param device Shared Metal device backing the Core Image context.
/// @param items  Output of +parseItemsFromParameters:error: (paint order).
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                       items:(NSArray<VGLivestreamOverlayItemSpec *> *)items NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── VGMediaNode / VGMetalFilterNode ─────────────────────────────────────────
@property (nonatomic, readonly, copy) NSString *nodeId;
@property (nonatomic, readonly, copy) NSString *nodeType;
@property (nonatomic, readonly, copy) NSString *filterName;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, readonly) BOOL isExpensive;
@property (nonatomic, readonly) float estimatedGPUCostMs;

/// Items requested by the spec, and items that survived sticker decoding.
@property (nonatomic, readonly) NSUInteger requestedItemCount;
@property (nonatomic, readonly) NSUInteger drawableItemCount;

/// Optional, log-only: describes the capture connection's mirroring for the
/// READY line. Never changes how the overlay is drawn.
@property (atomic, copy, nullable) NSString * (^mirrorDescriptionProvider)(void);

@end

NS_ASSUME_NONNULL_END
