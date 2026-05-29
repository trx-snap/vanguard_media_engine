// VGEditorGraphFactory.m
// Vanguard Media Engine — Phase 7 Stage 7.4
//
// Implementation of VGEditorGraphFactory.
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.4 — NON-EXECUTABLE DESCRIPTOR FACTORY
// ═══════════════════════════════════════════════════════════════════════════════
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.5 UPDATE — VALIDATOR ENABLED; PLANNER DEFERRED
// ═══════════════════════════════════════════════════════════════════════════════
//
// Stage 7.5 changes vs Stage 7.4:
//   • descriptorStage changed to "7.5_executable" (MOD-3, Opus Stage 7.5).
//     VGTimelineCompositorNode checks this key at init; Stage 7.4 descriptors
//     are rejected at runtime.
//   • VGGraphValidator is now called after building the descriptor (MOD-2, MOD-5).
//     VGGraphValidator.m's NoSource check has been patched to accept self-sourcing
//     compositor nodes (VGNodeRoleCompositor + zero incoming edges).
//   • VGGraphPlanner is NOT called (MOD-5, Opus required modification):
//     - The timeline topology is trivially [compositor → sink]; no BFS needed.
//     - Schedulers discover the self-sourcing compositor via the Phase 7 fallback
//       (MOD-1: VGGraphSchedulerV2.m + VGExportScheduler.m).
//     - VGGraphPlanner integration deferred to Stage 7.6+ (overlays, filters).
//
// This factory does NOT:
//   • Instantiate VGTimelineCompositorNode (the scheduler instantiates it).
//   • Call prepare/start/invalidate on any node.
//   • Invoke any runtime, scheduler, camera, export, or FFI code.
//   • Import AVFoundation, CoreMedia, Metal, UIKit, or Flutter.
//
// Clock policy: VGClockPolicyHybrid (MOD-2 of Stage 7.4 Opus validation).
//   Source-of-truth: VGClockPolicy.h ("Use for: file playback, timeline scrub")
//   and UMF_V2_01_Core_DAG_Architecture.md §6.5 (clockPolicy: hybrid).
//
// Validation (Stage 7.4 MOD-3/4/5): see +validateTimelineWithClips:transitions:error:.
//   MOD-3: transition.durationSeconds <= min(fromClip, toClip).timelineDuration
//   MOD-4: clips must be sorted by startTimeSeconds ascending; reject unsorted
//   MOD-5: Stage 7.4 accepts VGClipMediaKindVideo and VGClipMediaKindImage only
//
// Imports: Foundation + UMF descriptor/graph headers only.


#import "VGEditorGraphFactory.h"

// ─── Stage 7.1 descriptor models (UMF) ───────────────────────────────────────
#import "VGClipDescriptor.h"
#import "VGTransitionDescriptor.h"

// ─── UMF V2 graph descriptor types ───────────────────────────────────────────
#import "VGGraphDescriptor.h"
#import "VGGraphNodeDescriptor.h"
#import "VGGraphConnection.h"
#import "VGMediaPort.h"
#import "VGClockPolicy.h"
#import "VGSinkAdmissionPolicy.h"
#import "VGMediaNode.h"
#import "VGFrameEnvelope.h"

// ─── VGGraphValidator (Stage 7.5: enabled after MOD-2 NoSource patch) ─────────
// VGGraphPlanner is intentionally NOT imported. See MOD-5 / Opus Stage 7.5:
//   The timeline topology is trivial (compositor → sink); schedulers use the
//   Phase 7 self-sourcing-compositor fallback and do not require VGExecutionPlan.
#import "VGGraphValidator.h"
#import "VGValidationError.h"

// ─── Error domain ────────────────────────────────────────────────────────────

NSString * const VGEditorGraphFactoryErrorDomain = @"VGEditorGraphFactory";

// ─── Private helpers ──────────────────────────────────────────────────────────

/// Produce a VGEditorGraphFactoryErrorDomain NSError with the given code and message.
static NSError *_VGEditorError(VGEditorGraphFactoryErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VGEditorGraphFactoryErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// ─── Implementation ───────────────────────────────────────────────────────────

@implementation VGEditorGraphFactory

// ─── Public: validation ───────────────────────────────────────────────────────

/// Validate clips + transitions against Stage 7.4 timeline rules.
///
/// Implements all 10 rules described in the header (MOD-3/4/5 inclusive).
/// Returns YES on full pass; NO with outError populated on first failure.
+ (BOOL)validateTimelineWithClips:(NSArray<VGClipDescriptor *> *)clips
                      transitions:(nullable NSArray<VGTransitionDescriptor *> *)transitions
                            error:(NSError * _Nullable * _Nullable)outError
{
    NSArray<VGTransitionDescriptor *> *safeTransitions = transitions ?: @[];

    // ── Rule 1: at least one clip ─────────────────────────────────────────────
    if (clips.count == 0) {
        if (outError) {
            *outError = _VGEditorError(VGEditorGraphFactoryErrorEmptyClips,
                @"VGEditorGraphFactory: clips array must not be empty.");
        }
        return NO;
    }

    // ── Rule 2: no nil element in clips ──────────────────────────────────────
    for (NSUInteger i = 0; i < clips.count; i++) {
        if ((id)clips[i] == [NSNull null] || clips[i] == nil) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorNilElement,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: clips[%lu] is nil.", (unsigned long)i]));
            }
            return NO;
        }
    }

    // ── Rule 3: every clip passes -isValid ────────────────────────────────────
    for (NSUInteger i = 0; i < clips.count; i++) {
        VGClipDescriptor *clip = clips[i];
        if (![clip isValid]) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorInvalidClip,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: clips[%lu] (id=%@) fails -isValid.",
                        (unsigned long)i, clip.clipId]));
            }
            return NO;
        }
    }

    // ── Rule 4: clip IDs are non-empty and Rule 5: clip IDs are unique ────────
    //
    // -isValid already asserts clipId.length > 0, but we double-check here so
    // uniqueness errors carry a clear diagnostic.
    NSMutableSet<NSString *> *seenClipIds =
        [NSMutableSet setWithCapacity:clips.count];

    for (NSUInteger i = 0; i < clips.count; i++) {
        VGClipDescriptor *clip = clips[i];
        if (clip.clipId.length == 0) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorInvalidClip,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: clips[%lu] has an empty clipId.",
                        (unsigned long)i]));
            }
            return NO;
        }
        if ([seenClipIds containsObject:clip.clipId]) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorDuplicateClipId,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: duplicate clipId \"%@\" at clips[%lu].",
                        clip.clipId, (unsigned long)i]));
            }
            return NO;
        }
        [seenClipIds addObject:clip.clipId];
    }

    // ── Rule 6 (MOD-4): clips sorted by startTimeSeconds ascending ────────────
    //
    // Equal start times are rejected as ambiguous ordering.
    for (NSUInteger i = 1; i < clips.count; i++) {
        double prevStart = clips[i - 1].startTimeSeconds;
        double currStart = clips[i].startTimeSeconds;
        if (currStart <= prevStart) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorUnsortedClips,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: clips are not sorted by startTimeSeconds "
                         "ascending. clips[%lu].startTimeSeconds (%.4f) is not greater "
                         "than clips[%lu].startTimeSeconds (%.4f). "
                         "Provide clips pre-sorted in timeline order.",
                        (unsigned long)i, currStart,
                        (unsigned long)(i - 1), prevStart]));
            }
            return NO;
        }
    }

    // ── Rule 7 (MOD-5): media kind must be video or image ────────────────────
    //
    // Stage 7.4 first slice: audio-only timelines are Phase 8 scope
    // (VGAudioOnlyTimelineDescriptor).  Unknown kind is always rejected.
    for (NSUInteger i = 0; i < clips.count; i++) {
        VGClipDescriptor *clip = clips[i];
        VGClipMediaKind kind = clip.mediaKind;
        if (kind != VGClipMediaKindVideo && kind != VGClipMediaKindImage) {
            NSString *kindDesc;
            switch (kind) {
                case VGClipMediaKindAudio:   kindDesc = @"audio";   break;
                case VGClipMediaKindUnknown: kindDesc = @"unknown"; break;
                default:                     kindDesc = @"unsupported"; break;
            }
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorUnsupportedMediaKind,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: clips[%lu] (id=%@) has unsupported "
                         "mediaKind \"%@\". Stage 7.4 accepts video and image only. "
                         "Audio-only timelines are Phase 8 scope.",
                        (unsigned long)i, clip.clipId, kindDesc]));
            }
            return NO;
        }
    }

    // ── Rule 2b: no nil element in transitions ────────────────────────────────
    for (NSUInteger i = 0; i < safeTransitions.count; i++) {
        if ((id)safeTransitions[i] == [NSNull null] || safeTransitions[i] == nil) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorNilElement,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] is nil.",
                        (unsigned long)i]));
            }
            return NO;
        }
    }

    // ── Rule 8: every transition passes -isValid ──────────────────────────────
    for (NSUInteger i = 0; i < safeTransitions.count; i++) {
        VGTransitionDescriptor *t = safeTransitions[i];
        if (![t isValid]) {
            if (outError) {
                *outError = _VGEditorError(VGEditorGraphFactoryErrorInvalidTransition,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@) fails -isValid.",
                        (unsigned long)i, t.transitionId]));
            }
            return NO;
        }
    }

    // ── Rules 9a/9b/9c (MOD-3) and Rule 10: linked transition checks ─────────
    //
    // Hard-cut transitions (type == none OR durationSeconds == 0) are exempt
    // from clip-linkage requirements.  All non-hard-cut transitions must:
    //   9a. Have non-nil, non-empty fromClipId and toClipId.
    //   9b. Both IDs must reference a clip in the clips array.
    //   9c (MOD-3). durationSeconds <= min(fromClip.timelineDuration,
    //                                       toClip.timelineDuration).
    //  10. No two non-hard-cut transitions share the same fromClipId+toClipId.
    //
    // Build a clipId → VGClipDescriptor lookup map for O(1) access.
    NSMutableDictionary<NSString *, VGClipDescriptor *> *clipById =
        [NSMutableDictionary dictionaryWithCapacity:clips.count];
    for (VGClipDescriptor *clip in clips) {
        clipById[clip.clipId] = clip;
    }

    // Track seen (fromClipId, toClipId) pairs for conflict detection (Rule 10).
    // Key format: "<fromClipId>|<toClipId>"
    NSMutableSet<NSString *> *seenTransitionPairs = [NSMutableSet set];

    for (NSUInteger i = 0; i < safeTransitions.count; i++) {
        VGTransitionDescriptor *t = safeTransitions[i];

        // Hard cuts require no further checking.
        if (t.isHardCut) {
            continue;
        }

        // ── Rule 9a: fromClipId and toClipId must be non-nil and non-empty ───
        if (t.fromClipId.length == 0 || t.toClipId.length == 0) {
            if (outError) {
                *outError = _VGEditorError(
                    VGEditorGraphFactoryErrorTransitionUnknownClip,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@, type=%ld) "
                         "is a non-hard-cut transition but has a nil or empty "
                         "fromClipId (\"%@\") or toClipId (\"%@\"). "
                         "Both IDs are required for linked transitions.",
                        (unsigned long)i, t.transitionId, (long)t.type,
                        t.fromClipId ?: @"<nil>",
                        t.toClipId   ?: @"<nil>"]));
            }
            return NO;
        }

        // ── Rule 9b: both IDs must reference a clip ───────────────────────────
        VGClipDescriptor *fromClip = clipById[t.fromClipId];
        VGClipDescriptor *toClip   = clipById[t.toClipId];

        if (!fromClip) {
            if (outError) {
                *outError = _VGEditorError(
                    VGEditorGraphFactoryErrorTransitionUnknownClip,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@) references "
                         "fromClipId \"%@\" which does not exist in the clips array.",
                        (unsigned long)i, t.transitionId, t.fromClipId]));
            }
            return NO;
        }
        if (!toClip) {
            if (outError) {
                *outError = _VGEditorError(
                    VGEditorGraphFactoryErrorTransitionUnknownClip,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@) references "
                         "toClipId \"%@\" which does not exist in the clips array.",
                        (unsigned long)i, t.transitionId, t.toClipId]));
            }
            return NO;
        }

        // ── Rule 9c (MOD-3): duration <= min clip timelineDuration ────────────
        //
        // timelineDuration = trimDuration / speed (computed by VGClipDescriptor).
        // A transition cannot be longer than either of the clips it links.
        double fromDuration = fromClip.timelineDuration;
        double toDuration   = toClip.timelineDuration;
        double minDuration  = MIN(fromDuration, toDuration);

        if (t.durationSeconds > minDuration) {
            if (outError) {
                *outError = _VGEditorError(
                    VGEditorGraphFactoryErrorTransitionTooLong,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@) has "
                         "durationSeconds (%.4f s) that exceeds the shorter of the "
                         "two linked clips' timelineDuration "
                         "(from clip \"%@\" = %.4f s, to clip \"%@\" = %.4f s, "
                         "min = %.4f s). "
                         "Shorten the transition or lengthen the adjacent clips.",
                        (unsigned long)i, t.transitionId, t.durationSeconds,
                        t.fromClipId, fromDuration,
                        t.toClipId,   toDuration,
                        minDuration]));
            }
            return NO;
        }

        // ── Rule 10: detect conflicting transitions for the same pair ─────────
        NSString *pairKey = [NSString stringWithFormat:@"%@|%@",
                             t.fromClipId, t.toClipId];
        if ([seenTransitionPairs containsObject:pairKey]) {
            if (outError) {
                *outError = _VGEditorError(
                    VGEditorGraphFactoryErrorConflictingTransition,
                    ([NSString stringWithFormat:
                        @"VGEditorGraphFactory: transitions[%lu] (id=%@) conflicts "
                         "with an earlier non-hard-cut transition for the same "
                         "fromClipId \"%@\" / toClipId \"%@\" pair. "
                         "Only one non-hard-cut transition per clip boundary is allowed.",
                        (unsigned long)i, t.transitionId,
                        t.fromClipId, t.toClipId]));
            }
            return NO;
        }
        [seenTransitionPairs addObject:pairKey];
    }

    // All rules passed.
    return YES;
}

// ─── Public: graph construction ───────────────────────────────────────────────

/// Build a non-executable editor timeline topology descriptor.
///
/// Steps:
///   (a) Validate via +validateTimelineWithClips:transitions:error:.
///   (b) Serialize clips and transitions into parameter dictionaries.
///   (c) Build the timeline compositor VGGraphNodeDescriptor.
///   (d) Build the preview sink VGGraphNodeDescriptor.
///   (e) Build a synchronous, dropLatest VGGraphConnection between them.
///   (f) Build and return VGGraphDescriptor with VGClockPolicyHybrid.
///
///   NOTE: VGGraphValidator and VGGraphPlanner are intentionally NOT called.
///   See the file-level comment and Opus MOD-1.
+ (nullable VGGraphDescriptor *)buildTimelineGraphWithClips:(NSArray<VGClipDescriptor *> *)clips
                                                transitions:(nullable NSArray<VGTransitionDescriptor *> *)transitions
                                                      error:(NSError * _Nullable * _Nullable)outError
{
    NSArray<VGTransitionDescriptor *> *safeTransitions = transitions ?: @[];

    // ── (a) Validate ──────────────────────────────────────────────────────────
    NSError *validationError = nil;
    BOOL valid = [self validateTimelineWithClips:clips
                                    transitions:safeTransitions
                                          error:&validationError];
    if (!valid) {
        if (outError) {
            *outError = validationError;
        }
        return nil;
    }

    // ── (b) Serialize descriptor arrays into parameter dictionaries ───────────
    //
    // VGClipDescriptor and VGTransitionDescriptor both provide -toDictionary,
    // producing property-list-compatible NSDictionary values.  These are
    // embedded in the timeline node's parameters map so the topology is
    // self-describing for logging, inspection, and future Stage 7.5 consumption.
    NSMutableArray<NSDictionary<NSString *, id> *> *clipDicts =
        [NSMutableArray arrayWithCapacity:clips.count];
    for (VGClipDescriptor *clip in clips) {
        [clipDicts addObject:[clip toDictionary]];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *transitionDicts =
        [NSMutableArray arrayWithCapacity:safeTransitions.count];
    for (VGTransitionDescriptor *t in safeTransitions) {
        [transitionDicts addObject:[t toDictionary]];
    }

    // ── (c) Build the timeline compositor node ────────────────────────────────
    //
    // nodeClass: "VGTimelineCompositorNode"
    //   Stored as a pure string per Phase 2 VGGraphNodeDescriptor design.
    //   NSClassFromString returns nil at Stage 7.4.  This is expected and safe.
    //   The concrete class is implemented in Stage 7.5.
    //
    // nodeRole: VGNodeRoleCompositor
    //   Matches the §6.5 architecture doc: "role: compositor".
    //   NOTE: VGGraphValidator CHECK 1 (NoSource) would fail if called because
    //   the compositor has no external input ports.  This is why VGGraphValidator
    //   is intentionally NOT called in Stage 7.4 (Opus MOD-1).
    //
    // ports: one output port "video_out"
    //   The compositor is self-sourcing: it manages its own AVAssetReaders
    //   internally.  In Stage 7.4, a single output port is declared.  The
    //   full multi-input compositor port declaration is Stage 7.5 scope.
    //
    // parameters:
    //   - "clips"         : serialized clip descriptor array
    //   - "transitions"   : serialized transition descriptor array
    //   - "descriptorStage": "7.5_executable" (MOD-3, Opus Stage 7.5)
    //     VGTimelineCompositorNode.initWithNodeId:parameters:ports:error:
    //     checks this key and rejects the Stage 7.4 non-executable marker.
    VGMediaPort *timelineOutputPort =
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo];

    NSDictionary<NSString *, id> *timelineParameters = @{
        @"clips"          : [clipDicts copy],
        @"transitions"    : [transitionDicts copy],
        @"descriptorStage": @"7.5_executable",
    };

    VGGraphNodeDescriptor *timelineNode =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:@"timeline"
                                            nodeClass:@"VGTimelineCompositorNode"
                                             nodeRole:VGNodeRoleCompositor
                                           parameters:timelineParameters
                                                ports:@[timelineOutputPort]];

    // ── (d) Build the preview sink node ──────────────────────────────────────
    //
    // nodeClass: "VGRendererSinkAdapter"
    //   An existing Phase 3 adapter class.  Referenced here as a string
    //   consistent with the §6.5 canonical topology.  The preview sink is
    //   included so the descriptor encodes the complete planned topology.
    //
    // nodeRole: VGNodeRoleSink
    //
    // ports: one required input port "video_in"
    VGMediaPort *previewInputPort =
        [VGMediaPort inputPort:@"video_in" mediaType:VGMediaTypeVideo required:YES];

    VGGraphNodeDescriptor *previewNode =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:@"preview"
                                            nodeClass:@"VGRendererSinkAdapter"
                                             nodeRole:VGNodeRoleSink
                                           parameters:@{}
                                                ports:@[previewInputPort]];

    // ── (e) Build the timeline → preview connection ───────────────────────────
    //
    // Per §6.5 canonical topology and VGSinkAdmissionPolicy.h:
    //   "Timeline scrub: dropLatest + generation check"
    //
    // Synchronous edge with dropLatest admission policy is the correct
    // configuration for a preview renderer in a hybrid-clock graph.
    VGGraphConnection *connection =
        [VGGraphConnection synchronousEdgeFrom:@"timeline"
                                          port:@"video_out"
                                            to:@"preview"
                                          port:@"video_in"
                               admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];

    // ── (f) Build VGGraphDescriptor ───────────────────────────────────────────
    //
    // graphId: "editorTimelineGraph_7_5" — updated to Stage 7.5.
    //
    // clockPolicy: VGClockPolicyHybrid (MOD-2 of Stage 7.4 Opus validation)
    //   Source-of-truth: VGClockPolicy.h ("Use for: file playback, timeline scrub
    //   (hybrid clock-at-scrub-PTS)") and §6.5 (clockPolicy: hybrid).
    //
    // audioSidecar: nil — audio sidecar is Phase 8 scope.
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"editorTimelineGraph_7_5"
                                             nodes:@[timelineNode, previewNode]
                                       connections:@[connection]
                                       clockPolicy:VGClockPolicyHybrid
                                      audioSidecar:nil];

    // ── (g) Validate via VGGraphValidator (Stage 7.5: enabled) ───────────────
    //
    // VGGraphValidator.m CHECK 1 (NoSource) has been patched (MOD-2) to accept
    // self-sourcing compositor nodes (VGNodeRoleCompositor + zero incoming edges).
    // The timeline compositor qualifies: it has one output port (video_out) and
    // no incoming connections, satisfying the self-sourcing compositor check.
    //
    // VGGraphPlanner is NOT called (MOD-5, Opus Stage 7.5 required modification):
    //   - The timeline topology is trivially [compositor → sink].
    //   - Schedulers use the Phase 7 self-sourcing-compositor fallback (MOD-1)
    //     to discover the compositor as the pull source without VGExecutionPlan.
    //   - VGGraphPlanner integration is deferred to Stage 7.6+ when overlays
    //     and filter chain nodes are added to the timeline graph.
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL descriptorValid = [VGGraphValidator validateDescriptor:descriptor
                                                         errors:&validationErrors];
    if (!descriptorValid) {
        if (outError) {
            NSString *errorDesc = [NSString stringWithFormat:
                @"VGEditorGraphFactory: VGGraphValidator rejected the timeline "
                 "descriptor. Errors: %@", validationErrors];
            *outError = [NSError errorWithDomain:VGEditorGraphFactoryErrorDomain
                                            code:VGEditorGraphFactoryErrorInvalidClip
                                        userInfo:@{NSLocalizedDescriptionKey: errorDesc}];
        }
        return nil;
    }

    return descriptor;
}

@end
