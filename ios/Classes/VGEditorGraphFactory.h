// VGEditorGraphFactory.h
// Vanguard Media Engine — Phase 7 Stage 7.4
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.4 — NON-EXECUTABLE DESCRIPTOR FACTORY
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGEditorGraphFactory is a pure graph-construction utility.  It:
//   - Consumes committed Stage 7.1 descriptor models (VGClipDescriptor,
//     VGTransitionDescriptor)
//   - Validates timeline-specific descriptor integrity
//   - Builds a VGGraphDescriptor encoding the planned editor topology
//   - Returns the descriptor WITHOUT executing frames or wiring runtime nodes
//
// ── IMPORTANT — NON-EXECUTABLE DESCRIPTOR ──────────────────────────────────
//
//   The VGGraphDescriptor returned by +buildTimelineGraphWithClips:transitions:error:
//   is a TOPOLOGY PLANNING DESCRIPTOR.  It is NOT an executable graph.
//
//   Specifically:
//     • VGTimelineCompositorNode is referenced only as a nodeClass string.
//       Its Objective-C implementation is deferred to Stage 7.5.
//       NSClassFromString(@"VGTimelineCompositorNode") returns nil at this stage.
//     • The descriptor has NOT been validated by VGGraphValidator.
//       The timeline compositor is a self-sourcing node (no external input ports)
//       and would fail VGGraphValidator's NoSource check if submitted directly.
//       Full VGGraphValidator integration is Stage 7.5 scope.
//     • The descriptor has NOT been planned by VGGraphPlanner.
//       No VGExecutionPlan is produced here.
//     • No rendering, frame delivery, or runtime execution occurs in this factory.
//     • No prepareWithCompletion:, startProducing, or invalidate calls are made.
//
//   This descriptor is suitable for:
//     - Topology inspection and logging
//     - Unit tests that verify descriptor shape
//     - The Stage 7.3 playground's descriptor display
//     - Feeding into Stage 7.5 once VGTimelineCompositorNode is implemented
//
// ── GRAPH TOPOLOGY (clockPolicy = VGClockPolicyHybrid) ──────────────────────
//
//   ┌──────────────────────────────────────────┐
//   │  timeline (VGTimelineCompositorNode)      │  role: compositor
//   │  parameters: clips[], transitions[]       │  port: video_out
//   └────────────────┬─────────────────────────┘
//                    │  synchronous, dropLatest
//   ┌────────────────▼─────────────────────────┐
//   │  preview (VGRendererSinkAdapter)          │  role: sink
//   │  port: video_in (required)                │
//   └──────────────────────────────────────────┘
//
// ── STAGE BOUNDARIES ────────────────────────────────────────────────────────
//
//   Stage 7.1 — Descriptor models (DONE): VGClipDescriptor, VGTransitionDescriptor
//   Stage 7.3 — Descriptor playground (DONE): example app display/validation
//   Stage 7.4 — This file: factory builds non-executable planning descriptor
//   Stage 7.5 — NEXT: VGTimelineCompositorNode.h/.m + live graph integration
//   Stage 7.6 — ConnectsApp editor integration (deferred)
//
// ── DO NOT IMPLEMENT ────────────────────────────────────────────────────────
//
//   This file must not be modified to call VGGraphValidator, VGGraphPlanner,
//   or any runtime/scheduler/camera/export/FFI code.  Those belong in Stage 7.5+.
//
// ── FILES NOT TOUCHED ───────────────────────────────────────────────────────
//
//   connectsapp_app/**               VGUseV2Graph.h
//   vanguard_media_engine/lib/**     VanguardGraphRuntime.m
//   vanguard_media_engine/example/** VanguardGraphScheduler.m
//   packages/UMF/ios/Classes/**      VGTimelineCompositorNode.h/.m
//   packages/UMF/Docs/**             VanguardCameraMediaSource.m
//   packages/UMF/implementation/**   VanguardExportSession.swift
//
// Foundation + UMF headers only.  No AVFoundation, CoreMedia, Metal, UIKit, Flutter.
//
// Phase 7 Stage 7.4. All methods are class methods. Do not instantiate.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations — full types imported in .m only to keep this header lean.
@class VGClipDescriptor;
@class VGTransitionDescriptor;
@class VGGraphDescriptor;

// ─── VGEditorGraphFactoryErrorCode ───────────────────────────────────────────
/// Stable error codes for VGEditorGraphFactory validation failures.
///
/// Use these codes to distinguish failure reasons programmatically.
/// All errors use the domain `VGEditorGraphFactoryErrorDomain`.
typedef NS_ENUM(NSInteger, VGEditorGraphFactoryErrorCode) {

    /// The clips array is empty.  At least one clip is required.
    VGEditorGraphFactoryErrorEmptyClips            = 1000,

    /// A nil element was found inside the clips or transitions array.
    VGEditorGraphFactoryErrorNilElement            = 1001,

    /// A clip does not satisfy its own -isValid constraint.
    VGEditorGraphFactoryErrorInvalidClip           = 1002,

    /// Two or more clips share the same clipId.
    VGEditorGraphFactoryErrorDuplicateClipId       = 1003,

    /// Clips are not ordered by startTimeSeconds ascending.
    VGEditorGraphFactoryErrorUnsortedClips         = 1004,

    /// A clip has a mediaKind that is not supported by Stage 7.4.
    /// Stage 7.4 accepts video and image.  Audio-only clips are rejected.
    VGEditorGraphFactoryErrorUnsupportedMediaKind  = 1005,

    /// A transition does not satisfy its own -isValid constraint.
    VGEditorGraphFactoryErrorInvalidTransition     = 1006,

    /// A transition references a fromClipId or toClipId that is not in the
    /// clips array.
    VGEditorGraphFactoryErrorTransitionUnknownClip = 1007,

    /// A transition's durationSeconds exceeds the timelineDuration of the
    /// shorter of the two linked clips.
    VGEditorGraphFactoryErrorTransitionTooLong     = 1008,

    /// Two or more non-hard-cut transitions share the same fromClipId/toClipId pair.
    VGEditorGraphFactoryErrorConflictingTransition = 1009,
};

/// The error domain used by VGEditorGraphFactory.
FOUNDATION_EXPORT NSString * const VGEditorGraphFactoryErrorDomain;

// ─── VGEditorGraphFactory ────────────────────────────────────────────────────
/// Pure graph-construction factory for the Phase 7 editor timeline topology.
///
/// Consumes Stage 7.1 descriptor models and builds a VGGraphDescriptor that
/// encodes the planned editor graph topology.  The descriptor is suitable for
/// inspection, logging, and unit tests, but is NOT yet executable because
/// VGTimelineCompositorNode is implemented in Stage 7.5.
///
/// See the file-level comment for the complete list of stage boundaries and
/// guarantees.  All methods are class methods.  Do not instantiate.
@interface VGEditorGraphFactory : NSObject

// ─── Graph construction ───────────────────────────────────────────────────────

/// Build a non-executable editor timeline topology descriptor.
///
/// The returned VGGraphDescriptor describes:
///   - A timeline compositor node (VGTimelineCompositorNode, Stage 7.5)
///     with the serialized clips and transitions as parameters.
///   - A preview renderer sink node (VGRendererSinkAdapter).
///   - A synchronous, dropLatest edge connecting timeline:video_out to
///     preview:video_in.
///   - Clock policy VGClockPolicyHybrid (correct for timeline scrub/playback).
///
/// IMPORTANT: The descriptor is NOT validated by VGGraphValidator and NOT
/// planned by VGGraphPlanner.  VGTimelineCompositorNode does not exist yet.
/// Do not attempt to execute or schedule this descriptor before Stage 7.5.
///
/// The method internally calls +validateTimelineWithClips:transitions:error:
/// before building the descriptor.  If validation fails, nil is returned and
/// outError is populated with a VGEditorGraphFactoryErrorDomain error.
///
/// @param clips        Non-empty, sorted (by startTimeSeconds ascending) array
///                     of VGClipDescriptor.  Each clip must pass -isValid.
///                     Stage 7.4 accepts VGClipMediaKindVideo and
///                     VGClipMediaKindImage.  VGClipMediaKindAudio and
///                     VGClipMediaKindUnknown are rejected.
/// @param transitions  Array of VGTransitionDescriptor.  May be empty (nil is
///                     treated as empty).  Each non-nil element must pass
///                     -isValid.  Linked transitions must reference clip IDs
///                     that exist in `clips`.
/// @param outError     On validation failure, set to a descriptive
///                     VGEditorGraphFactoryErrorDomain NSError.  On success,
///                     set to nil.  May be NULL.
/// @return A VGGraphDescriptor on success, or nil on validation failure.
+ (nullable VGGraphDescriptor *)buildTimelineGraphWithClips:(NSArray<VGClipDescriptor *> *)clips
                                                transitions:(nullable NSArray<VGTransitionDescriptor *> *)transitions
                                                      error:(NSError * _Nullable * _Nullable)outError;

// ─── Standalone validation ────────────────────────────────────────────────────

/// Validate a clips + transitions pair against Stage 7.4 timeline rules.
///
/// This method is called internally by +buildTimelineGraphWithClips:transitions:error:
/// and may also be called independently by tests or the example playground.
///
/// Validation rules enforced:
///   1.  clips is non-empty.
///   2.  No nil element in clips or transitions.
///   3.  Every clip passes [clip isValid].
///   4.  All clip IDs are non-empty strings.
///   5.  All clip IDs are unique within the array.
///   6.  Clips are sorted by startTimeSeconds ascending (strict: equal start
///       times are rejected as ambiguous ordering).
///   7.  Every clip's mediaKind is VGClipMediaKindVideo or VGClipMediaKindImage.
///       VGClipMediaKindAudio and VGClipMediaKindUnknown are rejected.
///   8.  Every transition passes [transition isValid].
///   9.  For transitions where type != VGTransitionTypeNone AND durationSeconds > 0:
///       a. fromClipId and toClipId must be non-nil and non-empty.
///       b. Both IDs must reference a clip in `clips`.
///       c. durationSeconds must be <= min(fromClip.timelineDuration,
///          toClip.timelineDuration).
///  10.  No two non-hard-cut transitions share the same fromClipId+toClipId pair.
///
/// @param clips        The clip descriptors to validate.
/// @param transitions  The transition descriptors to validate.  nil is treated
///                     as an empty array.
/// @param outError     On failure, set to a VGEditorGraphFactoryErrorDomain
///                     NSError describing the first validation failure found.
///                     On success, set to nil.  May be NULL.
/// @return YES if the timeline is valid; NO otherwise.
+ (BOOL)validateTimelineWithClips:(NSArray<VGClipDescriptor *> *)clips
                      transitions:(nullable NSArray<VGTransitionDescriptor *> *)transitions
                            error:(NSError * _Nullable * _Nullable)outError;

/// init is unavailable.  Use the class methods above.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
