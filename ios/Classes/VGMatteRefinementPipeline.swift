// VGMatteRefinementPipeline.swift
// Caller-agnostic green-screen matte refinement pipeline.
//
// Owns only mask refinement policy and CoreImage filter graph construction:
// the S1 stage order, the S4/S5 candidates (S5 lab-only; the S4 soft-alpha R2
// variant is the production live default and S4 R1 an opt-in live RND mode),
// and the opt-in live "tightAlphaR1" post-pass.
// It does NOT own a CIContext,
// pixel buffer pools, camera, ARKit, Vision, render loops, sessions,
// publishing, or background compositing — every caller (the Duet compositor's
// composite(), the ARKit ARMatteGenerator live engine, and the offline replay
// / matte-stage diagnostics lab) renders the CIImage recipes this pipeline
// returns through its own CIContext.
//
// S1 base mask refinement pipeline (the explicit `s1` live fallback; also the first four
// stages of every other live mode, including the production default Soft R2):
// The aspect-filled L8 mask is refined at output (canvas) scale before a caller's own
// CIBlendWithMask:
//   morphology close -> feather -> trimap -> guided edge preserve
//
// Refinement stages:
//   1. applyGreenScreenMorphologyClose — morphological close (CIMorphologyMaximum dilate,
//      then CIMorphologyMinimum erode, radius 1.0; r1b). Clamped to extent before dilate,
//      cropped to a finite radius-padded rect before erode to ensure bounded input and
//      prevent EXC_BAD_ACCESS, filling pinholes and stair-step bites before blur.
//   2. featherGreenScreenMask — CIGaussianBlur at feather radius 4.0 px softens the mask.
//   3. applyGreenScreenTrimap — remaps blurred mask luminance via smoothstep(0.10, 0.90, m)
//      to establish definite foreground/background regions with a widened transition band.
//   4. applyGreenScreenGuidedEdgePreserve — restores the pre-trimap feathered mask wherever
//      the camera frame has strong edges (CIEdges intensity 2.0, blur 1.5, smoothstep
//      0.08/0.34), preserving fine detail (hair, fingers) while keeping flat regions clean.
//
// Diagnostic stage tap: greenScreenMatteStages(aspectFilledMask:in:guidedBy:) is the single
// implementation of the stage order above and returns every intermediate CIImage plus
// per-stage applied flags (GreenScreenMatteStages). refineLiveGreenScreenMask (the live path
// every caller uses) is a thin view over it, so production and diagnostics share one filter
// pipeline and cannot drift.
//
// S4 camera-guided alpha (lab; the soft R2 variant is the production live default and
// R1 an opt-in live RND mode):
// greenScreenMatteStages(..., refinementMode: .s4GuidedAlphaR1) additionally runs
// applyGreenScreenS4GuidedAlpha (with the R1 parameter set) on the S1 final mask. It builds a narrow unknown band
// from the S1 matte (morphological gradient dilate − erode, softened, smoothstepped), a
// camera luminance edge-confidence map (CIColorMatrix luma → CIEdges → blur → smoothstep),
// and two in-band alpha candidates (an edge-aligned steepened S1 alpha and a locally
// softened S1 alpha). Inside the band the candidate alpha is selected by edge confidence;
// outside the band the S1 mask is returned untouched. Every step is a bounded stock
// CoreImage filter (no CPU pixel loops, no global blur of the output, no S1 constant
// changes) and any unavailable/degenerate step fails open to the S1 final mask. The live
// path requests S4 in the default LiveMatteRefinementMode.s4SoftAlphaR2 (soft R2 set)
// and in the opt-in .s4GuidedAlphaR1 (R1 set); the explicit .s1 fallback never requests it.
//
// S4-family R2 variants: .s4SoftAlphaR2 and .s4TightAlphaR2 run the exact same
// applyGreenScreenS4GuidedAlpha recipe as .s4GuidedAlphaR1, each with its own
// GreenScreenS4Parameters set (a wider/softer band and softer in-band alpha, or a
// narrower band and steeper in-band alpha, respectively). They populate the same S4 result
// fields and finalMask and fail open to the S1 final mask identically. Both are reachable
// through the offline matte-lab GreenScreenRefinementMode; additionally, .s4SoftAlphaR2 is
// the production live default (LiveMatteRefinementMode.s4SoftAlphaR2 =
// defaultLiveMatteRefinementMode, see below; promoted after physical A/B proof against
// S1), while .s4TightAlphaR2 stays lab-only with no
// LiveMatteRefinementMode counterpart, so the live path never requests it. The R1 parameter
// values are the unchanged greenScreenS4* constants, so .s4GuidedAlphaR1 output is
// byte-for-byte as before.
//
// S5 "guided filter R1" RND candidate (diagnostic only, NOT live):
// greenScreenMatteStages(..., refinementMode: .s5GuidedFilterR1) additionally runs
// applyGreenScreenS5GuidedFilterR1 on the S1 final mask. It approximates a true
// local-linear guided filter (He et al.) using only stock CoreImage GPU filters — box-blur
// means of the camera luminance guide I and the S1 mask p, their correlations and
// variance/covariance, the closed-form linear coefficients a = cov/(var+eps) and
// b = meanP − a·meanI, a second box blur of those coefficients, and q = meanA·I + meanB —
// then clamps q to [0, 1] and applies it only inside a narrow matte-edge band (same
// morphological-gradient band construction family as S4, S5-scoped constants); outside the
// band the S1 mask is returned untouched. Every step is a bounded stock CoreImage filter
// (no CPU pixel loops, no custom kernel needed) and any unavailable/degenerate step fails
// open to the S1 final mask. The live path never requests S5 in any live mode.
//
// Live matte refinement modes (LiveMatteRefinementMode; live-selectable):
// Distinct from the GreenScreenRefinementMode above (which gates the offline matte-lab /
// replay diagnostics), LiveMatteRefinementMode gates a second, independent knob a caller's
// live path may select (only through a diagnostic-only route before session start).
// The production live default is defaultLiveMatteRefinementMode (.s4SoftAlphaR2, see
// below): sending no option yields Soft R2. Explicit "s1" is the retained fallback and
// routes to exactly the previous S1-only production path, byte-for-byte unchanged.
//
// "s4GuidedAlphaR1" live matte refinement (opt-in RND live mode; NOT the production
// default): promotes the S4 candidate above from lab-only to an opt-in live mode so it can
// be compared physically against S1 on device. When a pipeline instance opts into
// .s4GuidedAlphaR1, refineLiveGreenScreenMask requests greenScreenMatteStages with
// GreenScreenRefinementMode.s4GuidedAlphaR1 and returns stages.finalMask
// (postS4GuidedAlpha); on S4 fail-open that is exactly the S1 final mask, unchanged, with
// s4GuidedAlphaR1Applied == false. The tightAlphaR1 post-pass never runs in this mode. No
// S1 constant or stage body changes.
//
// "s4SoftAlphaR2" live matte refinement (the production live default,
// defaultLiveMatteRefinementMode): the S4-family "soft alpha R2" variant (the lab-winning
// candidate in same-frame ARKit replay boundary-step metrics, then physically A/B proven
// against S1 on device at equal effective fps with no degraded events). When a pipeline
// instance runs .s4SoftAlphaR2 (the default with no init argument, or explicitly
// requested), refineLiveGreenScreenMask requests greenScreenMatteStages with
// GreenScreenRefinementMode.s4SoftAlphaR2 and returns stages.finalMask
// (postS4GuidedAlpha); on S4 fail-open that is exactly the S1 final mask, unchanged, with
// s4GuidedAlphaApplied == false. s4GuidedAlphaR1Applied is never true in this mode (it is
// R1-only, kept for backwards compatibility); the general s4GuidedAlphaApplied flag is
// true for any live S4-family mode whose S4 stage applied. The tightAlphaR1 post-pass
// never runs in this mode. No S1 constant, S4 R1 constant, or stage body changes; the
// Objective-C initializer uses this same default.
//
// "tightAlphaR1" live matte refinement (opt-in; live-selectable, NOT lab-only):
// When a pipeline instance opts into
// .tightAlphaR1, refineLiveGreenScreenMask runs applyLiveTightAlphaR1 on the S1 final mask
// (postGuidedEdge) only — never on the raw segmentation mask: a smoothstep remap
// (approximately 0.28/0.90) tightens the alpha transition, then a small final
// CIGaussianBlur (~0.35 px) re-softens the now-steeper edge. Every step is a bounded stock
// CoreImage filter (no CPU pixel loops, no custom Metal/kernel) and any unavailable/
// degenerate step fails open to the S1 mask unchanged.
//
// Offline lab parity for tightAlphaR1 (diagnostic only; never selects the live mode):
// GreenScreenRefinementMode.tightAlphaR1 lets the offline matte-stage lab run the very
// same applyLiveTightAlphaR1 post-pass on the S1 final mask (postGuidedEdge) so the lab
// can emit objective mask-edge metrics for it next to S1/S4/S5. It reuses the live
// implementation and constants verbatim, so lab evidence describes exactly what the live
// opt-in would render; it does not change LiveMatteRefinementMode, its default, or any
// live caller. The live path never requests it.
//
// Fail-open behavior:
// Each refinement stage is fail-open to its input: if a required CoreImage filter is
// unavailable or inputs are degenerate, the stage is skipped and the previous stage's
// output is used unchanged, so the worst case is the raw unmodified mask.
//
// Source compatibility: VGDuetPreviewCompositor defines typealiases (GreenScreenRefinementMode,
// LiveMatteRefinementMode, GreenScreenMatteStages, LiveGreenScreenMaskRefinement) to this
// pipeline's nested types, and delegates its greenScreenMatteStages(...) and
// refineLiveGreenScreenMaskForExternalEngine(...) methods to a VGMatteRefinementPipeline
// instance it owns, so existing diagnostics call sites compile unchanged. The compositor
// is generic (shared by Duet and green screen), so its own `init` default is the neutral
// .s1 path and does NOT track defaultLiveMatteRefinementMode; green-screen callers pass
// that constant explicitly when they want Soft R2.
//
// Objective-C bridge (VGGreenScreenFilterNode.m, the UMF camera graph green screen node):
// The class is an NSObject subclass exported through the generated
// vanguard_media_engine-Swift.h header. Objective-C callers instantiate it with plain
// `init` (always the production default live mode, defaultLiveMatteRefinementMode =
// .s4SoftAlphaR2; no other live mode is selectable from
// Objective-C) and call `refineLiveGreenScreenMaskWithAspectFilledMask:inRect:guidedBy:`,
// which runs the exact `refineLiveGreenScreenMask(aspectFilledMask:in:guidedBy:)` live path
// and wraps its result in VGMatteRefinementLiveResult (mask, the four S1 applied flags, the
// live mode raw value, and the S4-family/tightAlphaR1 applied flags), so an Objective-C
// caller's telemetry reports the actual live mode/proof (production default S4 soft-alpha
// R2, built on the S1 base stages) instead of a stale S1-only assumption.
// The S1 production constants are also exported (read-only class properties) so an
// Objective-C caller's logs print the pipeline's own values and cannot drift from them.
// Nothing else — the diagnostic stage tap, S4/S5, and every nested Swift type not on
// LiveGreenScreenMaskRefinement — is visible to Objective-C.

import CoreGraphics
import CoreImage
import Foundation

/// Objective-C view of `VGMatteRefinementPipeline.LiveGreenScreenMaskRefinement`:
/// the refined live mask, the four S1 per-stage applied flags, and the live refinement
/// mode/S4-family metadata. Immutable; built only
/// by `VGMatteRefinementPipeline.refineLiveGreenScreenMaskBridged(aspectFilledMask:in:guidedBy:)`
/// (the Objective-C bridge method, selector
/// `refineLiveGreenScreenMaskWithAspectFilledMask:inRect:guidedBy:`). Swift callers keep using the struct directly.
@objc(VGMatteRefinementLiveResult)
public final class VGMatteRefinementLiveResult: NSObject {
    /// Refined mask (the instance-mode final mask: Soft R2 by default, which fails open to
    /// the S1 final mask), a lazy CoreImage recipe cropped to the rect it was refined in;
    /// fails open stage by stage to the raw input, never nil.
    @objc public let mask: CIImage
    @objc public let morphologyCloseApplied: Bool
    @objc public let featherApplied: Bool
    @objc public let trimapApplied: Bool
    @objc public let guidedEdgeApplied: Bool
    /// Raw value of the instance's `LiveMatteRefinementMode` (e.g. `"s4SoftAlphaR2"`, the
    /// production default via Objective-C `init`, or `"s1"`). Exposes the mode this specific
    /// refinement ran under so an Objective-C caller's diagnostics track the pipeline's own
    /// live mode instead of a stale assumption.
    @objc public let liveMatteRefinementMode: String
    /// True only when this refinement ran `.tightAlphaR1` and the post-pass fully applied.
    @objc public let tightAlphaR1Applied: Bool
    /// True only when this refinement ran `.s4GuidedAlphaR1` (R1-only) and every S4 step
    /// applied; false on S4 fail-open and in every other mode, including `.s4SoftAlphaR2`.
    @objc public let s4GuidedAlphaR1Applied: Bool
    /// True in any live S4-family mode (`.s4GuidedAlphaR1`, `.s4SoftAlphaR2`) when every S4
    /// step applied; false on S4 fail-open to S1 and in every non-S4 mode.
    @objc public let s4GuidedAlphaApplied: Bool

    init(_ refinement: VGMatteRefinementPipeline.LiveGreenScreenMaskRefinement) {
        self.mask                   = refinement.mask
        self.morphologyCloseApplied = refinement.morphologyCloseApplied
        self.featherApplied         = refinement.featherApplied
        self.trimapApplied          = refinement.trimapApplied
        self.guidedEdgeApplied      = refinement.guidedEdgeApplied
        self.liveMatteRefinementMode = refinement.liveMatteRefinementMode.rawValue
        self.tightAlphaR1Applied     = refinement.tightAlphaR1Applied
        self.s4GuidedAlphaR1Applied  = refinement.s4GuidedAlphaR1Applied
        self.s4GuidedAlphaApplied    = refinement.s4GuidedAlphaApplied
        super.init()
    }
}

@objc(VGMatteRefinementPipeline)
public final class VGMatteRefinementPipeline: NSObject {

    /// Production default live matte refinement mode: the single source of truth for
    /// every green-screen-owned entry point that does not receive an explicit mode (this
    /// class's `init` default, the Objective-C `init()` used by the independent
    /// green-screen filter node, `VGARKitLiveGreenScreenPreviewCoordinator.StartRequest.init`,
    /// the method channel's missing-option default, and the replay diagnostics, which
    /// pass it explicitly). The generic `VGDuetPreviewCompositor.init` deliberately does
    /// NOT default to this constant: its default is the neutral `.s1`, so Duet never
    /// inherits green-screen tuning; the live green-screen session coordinator forwards
    /// the session mode explicitly. `.s4SoftAlphaR2` was promoted from the
    /// diagnostic-only opt-in after the offline lab tournament (best boundary-step
    /// metric) and a physical same-harness A/B against S1 on device (equal effective fps,
    /// no degraded events). `.s1` stays available as the explicit fallback and still
    /// routes to the exact previous S1-only path; `.s4TightAlphaR2` has no live
    /// counterpart and is never selectable here.
    static let defaultLiveMatteRefinementMode: LiveMatteRefinementMode = .s4SoftAlphaR2

    /// Live-selectable matte refinement mode for this pipeline instance (see
    /// `LiveMatteRefinementMode`). Defaults to `defaultLiveMatteRefinementMode`
    /// (`.s4SoftAlphaR2`) when no argument is passed to `init`; never mutated for the
    /// lifetime of the instance.
    let liveMatteRefinementMode: LiveMatteRefinementMode

    init(liveMatteRefinementMode: LiveMatteRefinementMode
             = VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) {
        self.liveMatteRefinementMode = liveMatteRefinementMode
        super.init()
    }

    /// Objective-C entry point (`[[VGMatteRefinementPipeline alloc] init]`): always the
    /// production default live mode (`defaultLiveMatteRefinementMode`, `.s4SoftAlphaR2`),
    /// so Objective-C callers track the promoted default rather than a stale mode. Swift
    /// callers that want a different live mode use `init(liveMatteRefinementMode:)`; mode
    /// selection is deliberately not reachable from Objective-C.
    @objc public override convenience init() {
        self.init(liveMatteRefinementMode: VGMatteRefinementPipeline.defaultLiveMatteRefinementMode)
    }

    // MARK: - Matte refinement stage tap

    /// Matte refinement modes selectable through
    /// `greenScreenMatteStages(aspectFilledMask:in:guidedBy:refinementMode:)` (the offline
    /// matte-lab / replay diagnostics tap). A caller's live composite path requests
    /// `.s4SoftAlphaR2` by default (`defaultLiveMatteRefinementMode`), `.s1` in the
    /// explicit s1 fallback, or `.s4GuidedAlphaR1` when the pipeline instance opted into
    /// `LiveMatteRefinementMode.s4GuidedAlphaR1` (see
    /// `refineLiveGreenScreenMask`). `.s4TightAlphaR2`, `.s5GuidedFilterR1`, and
    /// `.tightAlphaR1` here are never requested live. Raw values are the exact strings
    /// accepted at the method channel.
    enum GreenScreenRefinementMode: String, CaseIterable {
        /// S1 base stages: morphology close → feather → trimap → guided edge (the explicit
        /// live `s1` fallback; every other mode runs these first).
        case s1 = "s1"
        /// RND candidate: S1 final mask plus band-limited camera-guided alpha refinement
        /// (lab, and the opt-in live `LiveMatteRefinementMode.s4GuidedAlphaR1` mode).
        case s4GuidedAlphaR1 = "s4GuidedAlphaR1"
        /// S4-family variant (lab, and the production live default
        /// `LiveMatteRefinementMode.s4SoftAlphaR2`): the same S4 guided-alpha recipe
        /// with the "soft alpha R2" parameter set (wider, softer band; softer in-band
        /// alpha). See `greenScreenS4SoftAlphaR2Parameters`.
        case s4SoftAlphaR2 = "s4SoftAlphaR2"
        /// Lab-only S4-family variant (NOT live; no `LiveMatteRefinementMode` counterpart):
        /// the same S4 guided-alpha recipe with the "tight alpha R2" parameter set
        /// (narrower band; steeper in-band alpha). See `greenScreenS4TightAlphaR2Parameters`.
        case s4TightAlphaR2 = "s4TightAlphaR2"
        /// RND candidate: S1 final mask plus band-limited local-linear guided-filter
        /// refinement (approximate He et al. guided filter) using the camera frame as guide.
        case s5GuidedFilterR1 = "s5GuidedFilterR1"
        /// Offline lab evaluation of the live opt-in "tight alpha R1" post-pass: S1 final
        /// mask plus the exact `applyLiveTightAlphaR1` recipe (smoothstep remap + small
        /// final blur). Diagnostic only here; selecting it never changes
        /// `LiveMatteRefinementMode` or any live default.
        case tightAlphaR1 = "tightAlphaR1"
    }

    /// Live-selectable matte refinement mode, selected only through a diagnostic-only route
    /// before session start; never part of the public Dart API. Distinct from
    /// `GreenScreenRefinementMode`, which gates the offline matte-lab / replay diagnostics —
    /// the two enums stay independent: only `.s4GuidedAlphaR1` and `.s4SoftAlphaR2` map
    /// onto their lab counterparts (the S5 lab candidate and the lab-only
    /// `.s4TightAlphaR2` can never be reached live), and `.tightAlphaR1` reaches the
    /// lab only through its explicit `GreenScreenRefinementMode.tightAlphaR1` parity case.
    /// `defaultLiveMatteRefinementMode` (`.s4SoftAlphaR2`) runs whenever no option is
    /// sent; `.s1` is the explicit fallback. Raw values are the exact strings
    /// accepted at the method channel (`allCases` is the parser's source of truth).
    enum LiveMatteRefinementMode: String, CaseIterable {
        /// Explicit fallback (the previous production default): the unchanged S1 final
        /// mask, byte-for-byte the S1-only path.
        case s1 = "s1"
        /// Opt-in RND candidate ("A tight alpha" offline A/B): bounded CoreImage
        /// post-pass over the S1 final mask (smoothstep remap + small final blur). See
        /// `applyLiveTightAlphaR1`.
        case tightAlphaR1 = "tightAlphaR1"
        /// Opt-in RND live mode (physical S1 vs S4 comparison; NOT the production
        /// default): the S4 camera-guided alpha candidate run live on top of the unchanged
        /// S1 stages, i.e. `greenScreenMatteStages(..., refinementMode: .s4GuidedAlphaR1)`
        /// `finalMask`. Fails open to the S1 final mask; never runs tightAlphaR1. See
        /// `applyGreenScreenS4GuidedAlpha` (R1 parameter set).
        case s4GuidedAlphaR1 = "s4GuidedAlphaR1"
        /// Production live default (`defaultLiveMatteRefinementMode`; the lab-winning S4
        /// "soft alpha R2" variant, physically A/B proven against S1): the S4 camera-guided
        /// alpha refinement with the R2 soft parameter set run live on top of the unchanged
        /// S1 stages, i.e. `greenScreenMatteStages(..., refinementMode: .s4SoftAlphaR2)`
        /// `finalMask`. Fails open to the S1 final mask; never runs tightAlphaR1. See
        /// `applyGreenScreenS4GuidedAlpha` (`greenScreenS4SoftAlphaR2Parameters`).
        case s4SoftAlphaR2 = "s4SoftAlphaR2"
    }

    /// Every intermediate image of the production matte refinement pipeline plus the
    /// per-stage applied flags, as produced by
    /// `greenScreenMatteStages(aspectFilledMask:in:guidedBy:refinementMode:)`.
    /// Images are lazy CoreImage recipes cropped to the camera rect; the caller renders
    /// them through its own CIContext. `postGuidedEdge` is exactly the mask a caller's live
    /// composite path feeds to CIBlendWithMask in the explicit `.s1` live fallback (the
    /// default `.s4SoftAlphaR2` and opt-in `.s4GuidedAlphaR1` live modes feed `finalMask`). The S4 fields
    /// are populated only when an S4-family mode (`.s4GuidedAlphaR1`, `.s4SoftAlphaR2`, or
    /// the lab-only `.s4TightAlphaR2`) was requested; otherwise they alias `postGuidedEdge`.
    struct GreenScreenMatteStages {
        /// The aspect-filled mask exactly as passed in (input to stage 1).
        let aspectFilledInput: CIImage
        /// Stage 1 output (morphology close), or `aspectFilledInput` when not applied.
        let postMorphologyClose: CIImage
        /// Stage 2 output (feather), or `postMorphologyClose` when not applied.
        let postFeather: CIImage
        /// Stage 3 output (trimap), or `postFeather` when not applied.
        let postTrimap: CIImage
        /// Stage 4 output (guided edge preserve), or `postTrimap` when not applied.
        /// This is the final refined mask used by a caller's live composite path.
        let postGuidedEdge: CIImage
        let morphologyCloseApplied: Bool
        let featherApplied: Bool
        let trimapApplied: Bool
        let guidedEdgeApplied: Bool

        /// Mode these stages were requested with. The live path requests `.s4SoftAlphaR2`
        /// (default), `.s1` (explicit fallback), or `.s4GuidedAlphaR1` (opt-in live RND
        /// mode), never `.s4TightAlphaR2` / `.s5GuidedFilterR1` / `.tightAlphaR1`.
        let refinementMode: GreenScreenRefinementMode
        /// S4-family output: the band-limited camera-guided refinement of `postGuidedEdge`
        /// when `refinementMode` is an S4-family mode (`.s4GuidedAlphaR1`, `.s4SoftAlphaR2`,
        /// `.s4TightAlphaR2`; each with its own parameter set) and every S4 filter step
        /// succeeded; otherwise exactly `postGuidedEdge` (fail-open to S1).
        let postS4GuidedAlpha: CIImage
        /// S4 refinement band weight (0 = S1 kept, 1 = fully S4-refined), only when S4 was
        /// applied; nil otherwise. Diagnostic tap so the lab can show where S4 acted.
        let s4RefinementBand: CIImage?
        /// True only when an S4-family mode was requested and fully applied.
        let s4GuidedAlphaApplied: Bool
        /// Non-nil only when an S4-family mode was requested but failed open to S1;
        /// names the first unavailable/degenerate step.
        let s4GuidedAlphaFailOpenReason: String?

        /// S5 RND candidate output: the band-limited local-linear guided-filter refinement
        /// of `postGuidedEdge` when `refinementMode == .s5GuidedFilterR1` and every S5
        /// filter step succeeded; otherwise exactly `postGuidedEdge` (fail-open to S1).
        let postS5GuidedFilter: CIImage
        /// S5 refinement band weight (0 = S1 kept, 1 = fully S5-refined), only when S5 was
        /// applied; nil otherwise. Diagnostic tap so the lab can show where S5 acted.
        let s5RefinementBand: CIImage?
        /// True only when `.s5GuidedFilterR1` was requested and fully applied.
        let s5GuidedFilterApplied: Bool
        /// Non-nil only when `.s5GuidedFilterR1` was requested but failed open to S1;
        /// names the first unavailable/degenerate step.
        let s5GuidedFilterFailOpenReason: String?

        /// Offline tight-alpha R1 output: `applyLiveTightAlphaR1` (the exact live opt-in
        /// post-pass) run on `postGuidedEdge` when `refinementMode == .tightAlphaR1` and
        /// every step succeeded; otherwise exactly `postGuidedEdge` (not requested, or
        /// fail-open to S1).
        let postTightAlphaR1: CIImage
        /// True only when `.tightAlphaR1` was requested and fully applied.
        let tightAlphaR1Applied: Bool
        /// Non-nil only when `.tightAlphaR1` was requested but failed open to S1; names
        /// the first unavailable/degenerate step.
        let tightAlphaR1FailOpenReason: String?

        /// The final mask selected by `refinementMode`: `postGuidedEdge` for `.s1`,
        /// `postS4GuidedAlpha` for every S4-family mode (`.s4GuidedAlphaR1`,
        /// `.s4SoftAlphaR2`, `.s4TightAlphaR2`), `postS5GuidedFilter` for
        /// `.s5GuidedFilterR1`, `postTightAlphaR1` for `.tightAlphaR1` (each identical to
        /// `postGuidedEdge` on fail-open). A caller's live composite path reads
        /// `postGuidedEdge` directly in the `.s1` fallback and `finalMask` in the
        /// `.s4SoftAlphaR2` (default) / `.s4GuidedAlphaR1` live modes.
        var finalMask: CIImage {
            switch refinementMode {
            case .s1:               return postGuidedEdge
            case .s4GuidedAlphaR1,
                 .s4SoftAlphaR2,
                 .s4TightAlphaR2:   return postS4GuidedAlpha
            case .s5GuidedFilterR1: return postS5GuidedFilter
            case .tightAlphaR1:     return postTightAlphaR1
            }
        }
    }

    /// Result of the live mask refinement (see
    /// `refineLiveGreenScreenMask(aspectFilledMask:in:guidedBy:)`).
    /// `mask` is a lazy CoreImage recipe cropped to the rect it was refined in; the caller
    /// blends and renders it through its own CIContext. The applied flags are the exact
    /// per-stage flags the live composite path logs for its own first blend.
    struct LiveGreenScreenMaskRefinement {
        /// Refined mask (S1 final mask; plus tight-alpha R1, or an S4-family guided-alpha
        /// candidate, when opted in); fails open stage by stage to the raw input, never nil.
        let mask: CIImage
        /// Mode this pipeline instance runs live (`.s4SoftAlphaR2` default, `.s1`
        /// fallback, `.tightAlphaR1`, or `.s4GuidedAlphaR1`).
        let liveMatteRefinementMode: LiveMatteRefinementMode
        let morphologyCloseApplied: Bool
        let featherApplied: Bool
        let trimapApplied: Bool
        let guidedEdgeApplied: Bool
        /// True only in `.tightAlphaR1` mode when the post-pass fully applied.
        let tightAlphaR1Applied: Bool
        /// True only in `.s4GuidedAlphaR1` mode when every S4 step applied; false on S4
        /// fail-open to S1 and in every other mode (including `.s4SoftAlphaR2`). Kept for
        /// backwards compatibility of existing logs/summaries; logged as
        /// liveS4GuidedAlphaR1Applied by live callers.
        let s4GuidedAlphaR1Applied: Bool
        /// True in any live S4-family mode (`.s4GuidedAlphaR1`, `.s4SoftAlphaR2`) when
        /// every S4 step applied (mirrors `GreenScreenMatteStages.s4GuidedAlphaApplied`);
        /// false on S4 fail-open to S1 and in every non-S4 mode. Logged as
        /// liveS4GuidedAlphaApplied by live callers.
        let s4GuidedAlphaApplied: Bool
    }

    // MARK: - S1 production constants
    //
    // Exported to Objective-C as read-only class properties (`@objc public static let`)
    // so VGGreenScreenFilterNode.m logs the pipeline's own S1 values instead of a
    // duplicated copy; values and Swift call sites are unchanged.

    /// Production mask refinement: morphological close (CIMorphologyMaximum dilate then
    /// CIMorphologyMinimum erode, radius 1.0; r1b) applied before feathering to fill tiny
    /// stair-step bites and pinholes in the raw matte.
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints
    /// maskMorphologyCloseEnabled / maskMorphologyCloseApplied /
    /// maskMorphologyCloseRadius.
    @objc public static let greenScreenMaskMorphologyCloseEnabled: Bool = true
    @objc public static let greenScreenMaskMorphologyCloseRadius: CGFloat = 1.0

    /// Production mask refinement: feather radius, in canvas pixels, applied as a
    /// CIGaussianBlur `inputRadius` to soften the closed mask at output scale before
    /// CIBlendWithMask (production constant: 4.0 px, S1; promoted from 3.0 px after the
    /// on-device matte-stage edge-metrics lab measured lower average / p95 / max boundary
    /// steps on the same captured frame, together with the 0.10 / 0.90 trimap band below).
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints this value as
    /// maskFeatherRadius.
    @objc public static let greenScreenMaskFeatherRadius: CGFloat = 4.0

    /// Production mask refinement: trimap / alpha-curve pass remapping mask luminance m
    /// through smoothstep(greenScreenTrimapLow, greenScreenTrimapHigh, m) to produce
    /// solid foreground/background bands with a widened soft edge (production constants:
    /// 0.10 / 0.90, S1; promoted from 0.14 / 0.86 together with the 4.0 px feather above).
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints
    /// maskTrimapEnabled / maskTrimapApplied / maskTrimapLow / maskTrimapHigh.
    @objc public static let greenScreenTrimapEnabled: Bool = true
    @objc public static let greenScreenTrimapLow:  CGFloat = 0.10
    @objc public static let greenScreenTrimapHigh: CGFloat = 0.90

    /// Production mask refinement: guided-edge-preservation pass restoring the
    /// pre-trimap feathered mask wherever the camera frame has strong edges
    /// (production constants: intensity 2.0, blur radius 1.5, smoothstep 0.08/0.34, S1),
    /// preserving thin detail (hair, fingers) while keeping flat regions cleanly keyed.
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints maskGuidedEdgeEnabled /
    /// maskGuidedEdgeApplied / maskGuidedEdgeIntensity / maskGuidedEdgeBlurRadius /
    /// maskGuidedEdgeLow / maskGuidedEdgeHigh.
    @objc public static let greenScreenGuidedEdgeEnabled: Bool = true
    @objc public static let greenScreenGuidedEdgeIntensity: CGFloat = 2.0
    @objc public static let greenScreenGuidedEdgeBlurRadius: CGFloat = 1.5
    @objc public static let greenScreenGuidedEdgeLow: CGFloat = 0.08
    @objc public static let greenScreenGuidedEdgeHigh: CGFloat = 0.34

    // MARK: - S4 guided-alpha constants (the R1 set: lab, and the opt-in live
    // `.s4GuidedAlphaR1` mode; never read in the `.s1` live fallback). The R2
    // parameter sets (Soft R2: lab and the production live default; Tight R2: lab only)
    // follow below and never touch these values.

    /// S4 band extraction: morphological gradient radius (dilate − erode of the S1 mask),
    /// in canvas px. Defines how wide the refinable unknown band around the matte edge is.
    private static let greenScreenS4BandRadius: CGFloat = 2.0
    /// S4 band softening blur so the band boundary itself never introduces a seam.
    private static let greenScreenS4BandBlurRadius: CGFloat = 1.0
    /// S4 band weight smoothstep thresholds over the softened morphological gradient.
    private static let greenScreenS4BandLow: CGFloat = 0.10
    private static let greenScreenS4BandHigh: CGFloat = 0.50
    /// S4 camera luminance edge confidence: CIEdges intensity, blur radius, smoothstep.
    private static let greenScreenS4EdgeIntensity: CGFloat = 2.5
    private static let greenScreenS4EdgeBlurRadius: CGFloat = 1.0
    private static let greenScreenS4EdgeLow: CGFloat = 0.10
    private static let greenScreenS4EdgeHigh: CGFloat = 0.40
    /// S4 in-band candidates: soft-alpha blur radius used where the camera is flat, and the
    /// edge-aligned steepening smoothstep used where the camera has a strong edge.
    private static let greenScreenS4SoftAlphaRadius: CGFloat = 2.0
    private static let greenScreenS4SnapLow: CGFloat = 0.20
    private static let greenScreenS4SnapHigh: CGFloat = 0.80
    /// Rec.709 luma weights used to derive the S4 camera guide luminance (shared by every
    /// S4-family parameter set; not a tunable).
    private static let greenScreenS4LumaWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)

    /// One S4-family parameter set: every tunable `applyGreenScreenS4GuidedAlpha` reads.
    /// The R1 set is built from the `greenScreenS4*` constants above (values unchanged);
    /// the lab-only R2 variants carry their own literals.
    private struct GreenScreenS4Parameters {
        /// Band extraction: morphological gradient radius (dilate − erode), canvas px.
        let bandRadius: CGFloat
        /// Band softening blur radius, canvas px.
        let bandBlurRadius: CGFloat
        /// Band weight smoothstep thresholds over the softened morphological gradient.
        let bandLow: CGFloat
        let bandHigh: CGFloat
        /// Camera luminance edge confidence: CIEdges intensity, blur radius, smoothstep.
        let edgeIntensity: CGFloat
        let edgeBlurRadius: CGFloat
        let edgeLow: CGFloat
        let edgeHigh: CGFloat
        /// In-band candidates: soft-alpha blur radius (flat camera) and the edge-aligned
        /// steepening smoothstep (strong camera edge).
        let softAlphaRadius: CGFloat
        let snapLow: CGFloat
        let snapHigh: CGFloat
    }

    /// `.s4GuidedAlphaR1` parameter set: exactly the `greenScreenS4*` constants above, so
    /// the lab and opt-in live R1 mode are unchanged by the R2 variants.
    private static let greenScreenS4GuidedAlphaR1Parameters = GreenScreenS4Parameters(
        bandRadius:      VGMatteRefinementPipeline.greenScreenS4BandRadius,
        bandBlurRadius:  VGMatteRefinementPipeline.greenScreenS4BandBlurRadius,
        bandLow:         VGMatteRefinementPipeline.greenScreenS4BandLow,
        bandHigh:        VGMatteRefinementPipeline.greenScreenS4BandHigh,
        edgeIntensity:   VGMatteRefinementPipeline.greenScreenS4EdgeIntensity,
        edgeBlurRadius:  VGMatteRefinementPipeline.greenScreenS4EdgeBlurRadius,
        edgeLow:         VGMatteRefinementPipeline.greenScreenS4EdgeLow,
        edgeHigh:        VGMatteRefinementPipeline.greenScreenS4EdgeHigh,
        softAlphaRadius: VGMatteRefinementPipeline.greenScreenS4SoftAlphaRadius,
        snapLow:         VGMatteRefinementPipeline.greenScreenS4SnapLow,
        snapHigh:        VGMatteRefinementPipeline.greenScreenS4SnapHigh)
    /// `.s4SoftAlphaR2` (lab, and the production live default
    /// `LiveMatteRefinementMode.s4SoftAlphaR2`): wider, softer band and softer in-band
    /// alpha than R1.
    private static let greenScreenS4SoftAlphaR2Parameters = GreenScreenS4Parameters(
        bandRadius:      2.0,
        bandBlurRadius:  1.25,
        bandLow:         0.08,
        bandHigh:        0.55,
        edgeIntensity:   2.0,
        edgeBlurRadius:  1.25,
        edgeLow:         0.12,
        edgeHigh:        0.45,
        softAlphaRadius: 2.5,
        snapLow:         0.16,
        snapHigh:        0.84)
    /// `.s4TightAlphaR2` (lab only, never live): narrower band and steeper in-band alpha
    /// than R1.
    private static let greenScreenS4TightAlphaR2Parameters = GreenScreenS4Parameters(
        bandRadius:      1.5,
        bandBlurRadius:  0.75,
        bandLow:         0.12,
        bandHigh:        0.48,
        edgeIntensity:   2.8,
        edgeBlurRadius:  0.75,
        edgeLow:         0.10,
        edgeHigh:        0.36,
        softAlphaRadius: 1.5,
        snapLow:         0.24,
        snapHigh:        0.78)

    // MARK: - S5 guided-filter RND constants (diagnostic only; never read by the live path)

    /// S5 guided filter box-blur radius (canvas px): the local window used to estimate
    /// means, correlations, and the linear coefficients a/b of the guided filter.
    private static let greenScreenS5GuidedFilterRadius: CGFloat = 4.0
    /// S5 guided filter regularization epsilon: keeps a = cov/(var+eps) bounded where the
    /// camera guide is near-flat (var ≈ 0).
    private static let greenScreenS5Epsilon: CGFloat = 0.0001
    /// S5 band extraction: morphological gradient radius (dilate − erode of the S1 mask),
    /// in canvas px. Same construction family as the S4 band, but an independent constant
    /// so S4's band tuning is never touched.
    private static let greenScreenS5BandRadius: CGFloat = 2.0
    /// S5 band softening blur so the band boundary itself never introduces a seam.
    private static let greenScreenS5BandBlurRadius: CGFloat = 1.0
    /// S5 band weight smoothstep thresholds over the softened morphological gradient.
    private static let greenScreenS5BandLow: CGFloat = 0.10
    private static let greenScreenS5BandHigh: CGFloat = 0.50
    /// Rec.709 luma weights used to derive the S5 camera guide luminance (S5-scoped so S4's
    /// constant is never touched).
    private static let greenScreenS5LumaWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)

    // MARK: - Live "tight alpha R1" RND constants (opt-in; live-selectable, never read
    // unless liveMatteRefinementMode == .tightAlphaR1)

    /// Live tight-alpha smoothstep remap thresholds applied to the S1 final mask
    /// (offline A/B candidate "A tight alpha").
    private static let liveTightAlphaR1Low: CGFloat = 0.28
    private static let liveTightAlphaR1High: CGFloat = 0.90
    /// Live tight-alpha final softening blur radius, in canvas px, applied after the
    /// smoothstep remap to avoid reintroducing a hard edge.
    private static let liveTightAlphaR1BlurRadius: CGFloat = 0.35

    // MARK: - Public API

    /// Runs the four production refinement stages on an already aspect-filled mask and
    /// returns every intermediate image:
    ///   1. applyGreenScreenMorphologyClose — morphology close r1b fills pinholes / bites.
    ///   2. featherGreenScreenMask — gaussian blur softens edges.
    ///   3. applyGreenScreenTrimap — smoothstep curve separates foreground/background.
    ///   4. applyGreenScreenGuidedEdgePreserve — restores fine edges from camera guide.
    ///
    /// This is the single implementation of the stage order; `refineLiveGreenScreenMask`
    /// (the live path) is a thin view over it, so diagnostics and production cannot drift.
    /// Each stage fails open to its input if filter creation fails or inputs are degenerate.
    ///
    /// - Parameters:
    ///   - mask:  mask already aspect-filled into `rect`.
    ///   - rect:  CI-space camera rect.
    ///   - guide: camera frame already aspect-filled into `rect`; used as an edge guide
    ///            for stage 4 (and the S4 candidate) only, never composited into the
    ///            returned masks.
    ///   - refinementMode: `.s1` (default here; the four stages above, exactly what a
    ///            caller's live path runs in the explicit s1 fallback), `.s4GuidedAlphaR1`
    ///            (RND candidate run on top of the unchanged S1 stages; lab, and the opt-in
    ///            live `LiveMatteRefinementMode.s4GuidedAlphaR1` mode), `.s4SoftAlphaR2`
    ///            (the same recipe with the soft R2 parameter set; lab, and the production
    ///            live default `LiveMatteRefinementMode.s4SoftAlphaR2`),
    ///            `.s4TightAlphaR2` (lab-only S4-family variant; never live), or `.s5GuidedFilterR1`
    ///            (diagnostic-only RND candidate on top of the unchanged S1 stages;
    ///            see `applyGreenScreenS4GuidedAlpha` / `applyGreenScreenS5GuidedFilterR1`),
    ///            or `.tightAlphaR1` (offline lab evaluation of the live opt-in
    ///            `applyLiveTightAlphaR1` post-pass on the unchanged S1 final mask).
    func greenScreenMatteStages(aspectFilledMask mask: CIImage,
                                in rect: CGRect,
                                guidedBy guide: CIImage,
                                refinementMode: GreenScreenRefinementMode = .s1) -> GreenScreenMatteStages {
        let closed    = applyGreenScreenMorphologyClose(mask, in: rect)
        let feathered = featherGreenScreenMask(closed.mask, in: rect)
        let trimapped = applyGreenScreenTrimap(feathered.mask, in: rect)
        let guided    = applyGreenScreenGuidedEdgePreserve(trimapped: trimapped.mask,
                                                           feathered: feathered.mask,
                                                           guide: guide,
                                                           in: rect)
        let s4NotRequested = GreenScreenS4Result(mask: guided.mask, band: nil, applied: false, failOpenReason: nil)
        let s5NotRequested = GreenScreenS5Result(mask: guided.mask, band: nil, applied: false, failOpenReason: nil)
        let tightAlphaNotRequested = LiveTightAlphaR1Result(mask: guided.mask, applied: false, failOpenReason: nil)
        let s4: GreenScreenS4Result
        let s5: GreenScreenS5Result
        let tightAlpha: LiveTightAlphaR1Result
        switch refinementMode {
        case .s1:
            s4 = s4NotRequested
            s5 = s5NotRequested
            tightAlpha = tightAlphaNotRequested
        case .s4GuidedAlphaR1:
            // Lab, and the opt-in live RND mode: the R1 parameter set, values unchanged.
            s4 = applyGreenScreenS4GuidedAlpha(base: guided.mask, guide: guide, in: rect,
                                               parameters: VGMatteRefinementPipeline.greenScreenS4GuidedAlphaR1Parameters)
            s5 = s5NotRequested
            tightAlpha = tightAlphaNotRequested
        case .s4SoftAlphaR2:
            // Lab, and the diagnostic-only opt-in live mode: the same S4 recipe with the
            // "soft alpha R2" set.
            s4 = applyGreenScreenS4GuidedAlpha(base: guided.mask, guide: guide, in: rect,
                                               parameters: VGMatteRefinementPipeline.greenScreenS4SoftAlphaR2Parameters)
            s5 = s5NotRequested
            tightAlpha = tightAlphaNotRequested
        case .s4TightAlphaR2:
            // Lab only: the same S4 recipe with the "tight alpha R2" set. Never requested live.
            s4 = applyGreenScreenS4GuidedAlpha(base: guided.mask, guide: guide, in: rect,
                                               parameters: VGMatteRefinementPipeline.greenScreenS4TightAlphaR2Parameters)
            s5 = s5NotRequested
            tightAlpha = tightAlphaNotRequested
        case .s5GuidedFilterR1:
            s4 = s4NotRequested
            s5 = applyGreenScreenS5GuidedFilterR1(base: guided.mask, guide: guide, in: rect)
            tightAlpha = tightAlphaNotRequested
        case .tightAlphaR1:
            // Offline lab parity: the exact live opt-in post-pass over the S1 final mask,
            // never the raw segmentation mask. The live path never requests this mode.
            s4 = s4NotRequested
            s5 = s5NotRequested
            tightAlpha = applyLiveTightAlphaR1(guided.mask, in: rect)
        }
        return GreenScreenMatteStages(aspectFilledInput: mask,
                                      postMorphologyClose: closed.mask,
                                      postFeather: feathered.mask,
                                      postTrimap: trimapped.mask,
                                      postGuidedEdge: guided.mask,
                                      morphologyCloseApplied: closed.applied,
                                      featherApplied: feathered.applied,
                                      trimapApplied: trimapped.applied,
                                      guidedEdgeApplied: guided.applied,
                                      refinementMode: refinementMode,
                                      postS4GuidedAlpha: s4.mask,
                                      s4RefinementBand: s4.band,
                                      s4GuidedAlphaApplied: s4.applied,
                                      s4GuidedAlphaFailOpenReason: s4.failOpenReason,
                                      postS5GuidedFilter: s5.mask,
                                      s5RefinementBand: s5.band,
                                      s5GuidedFilterApplied: s5.applied,
                                      s5GuidedFilterFailOpenReason: s5.failOpenReason,
                                      postTightAlphaR1: tightAlpha.mask,
                                      tightAlphaR1Applied: tightAlpha.applied,
                                      tightAlphaR1FailOpenReason: tightAlpha.failOpenReason)
    }

    /// Live mask refinement: refines an already aspect-filled green-screen mask at output
    /// scale through `greenScreenMatteStages`, selected by this instance's
    /// `liveMatteRefinementMode`:
    ///   - `.s1` (explicit fallback; the previous default): S1 stages; returns
    ///     `postGuidedEdge` unchanged.
    ///   - `.tightAlphaR1`: S1 stages, then `applyLiveTightAlphaR1` on the S1 final mask
    ///     (`postGuidedEdge`).
    ///   - `.s4GuidedAlphaR1` (opt-in RND live mode): S1 stages plus the S4 guided-alpha
    ///     candidate (`refinementMode: .s4GuidedAlphaR1`); returns `stages.finalMask`
    ///     (`postS4GuidedAlpha`), which is exactly the S1 final mask when S4 fails open.
    ///     tightAlphaR1 never runs in this mode.
    ///   - `.s4SoftAlphaR2` (production live default, `defaultLiveMatteRefinementMode`):
    ///     S1 stages plus the S4
    ///     guided-alpha candidate with the soft R2 parameter set
    ///     (`refinementMode: .s4SoftAlphaR2`); returns `stages.finalMask`
    ///     (`postS4GuidedAlpha`) with the same fail-open semantics as R1. tightAlphaR1
    ///     never runs in this mode.
    /// S5 and the lab-only `.s4TightAlphaR2` are never requested live. Shared verbatim by every live caller (the Duet
    /// compositor's composite() and the ARKit engine), so there is exactly one
    /// implementation of the live refinement and callers cannot drift.
    ///
    /// - Parameters:
    ///   - mask:  single-channel matte already oriented and aspect-filled into `rect`
    ///            (mask ~= 1 → subject), the same geometry the caller blends with.
    ///   - rect:  CI-space (bottom-left origin) foreground rect the mask and guide were
    ///            filled into; every stage is evaluated only over this rect.
    ///   - guide: camera frame already oriented and aspect-filled into `rect`, used only
    ///            as the edge guide for the guided-edge-preserve stage.
    func refineLiveGreenScreenMask(aspectFilledMask mask: CIImage,
                                   in rect: CGRect,
                                   guidedBy guide: CIImage) -> LiveGreenScreenMaskRefinement {
        let stages: GreenScreenMatteStages
        let finalMask: CIImage
        var tightAlphaR1Applied = false
        var s4GuidedAlphaR1Applied = false
        var s4GuidedAlphaApplied = false
        switch liveMatteRefinementMode {
        case .s1:
            // Explicit s1 fallback (the previous production default): S1 final mask,
            // byte-for-byte as before.
            stages = greenScreenMatteStages(aspectFilledMask: mask, in: rect, guidedBy: guide)
            finalMask = stages.postGuidedEdge
        case .tightAlphaR1:
            // S1 final mask, then the opt-in tight-alpha post-pass (fails open to S1).
            stages = greenScreenMatteStages(aspectFilledMask: mask, in: rect, guidedBy: guide)
            let tightAlpha = applyLiveTightAlphaR1(stages.postGuidedEdge, in: rect)
            finalMask = tightAlpha.mask
            tightAlphaR1Applied = tightAlpha.applied
        case .s4GuidedAlphaR1:
            // Opt-in RND live mode: the S4 candidate on top of the unchanged S1 stages.
            // `finalMask` is `postS4GuidedAlpha`, which the stage tap already fails open to
            // `postGuidedEdge` (S1) when any S4 step is unavailable/degenerate. No tightAlpha.
            stages = greenScreenMatteStages(aspectFilledMask: mask, in: rect, guidedBy: guide,
                                            refinementMode: .s4GuidedAlphaR1)
            finalMask = stages.finalMask
            s4GuidedAlphaR1Applied = stages.s4GuidedAlphaApplied
            s4GuidedAlphaApplied = stages.s4GuidedAlphaApplied
        case .s4SoftAlphaR2:
            // Production live default: the S4 soft R2 refinement on top of the
            // unchanged S1 stages. Same fail-open as R1: `finalMask` is `postS4GuidedAlpha`,
            // which the stage tap already fails open to `postGuidedEdge` (S1) when any S4
            // step is unavailable/degenerate. No tightAlpha. The R1-only flag stays false.
            stages = greenScreenMatteStages(aspectFilledMask: mask, in: rect, guidedBy: guide,
                                            refinementMode: .s4SoftAlphaR2)
            finalMask = stages.finalMask
            s4GuidedAlphaApplied = stages.s4GuidedAlphaApplied
        }
        return LiveGreenScreenMaskRefinement(mask: finalMask,
                                             liveMatteRefinementMode: liveMatteRefinementMode,
                                             morphologyCloseApplied: stages.morphologyCloseApplied,
                                             featherApplied: stages.featherApplied,
                                             trimapApplied: stages.trimapApplied,
                                             guidedEdgeApplied: stages.guidedEdgeApplied,
                                             tightAlphaR1Applied: tightAlphaR1Applied,
                                             s4GuidedAlphaR1Applied: s4GuidedAlphaR1Applied,
                                             s4GuidedAlphaApplied: s4GuidedAlphaApplied)
    }

    /// Objective-C bridge over `refineLiveGreenScreenMask(aspectFilledMask:in:guidedBy:)`
    /// (selector `refineLiveGreenScreenMaskWithAspectFilledMask:inRect:guidedBy:`). Runs
    /// exactly that live path — the same instance mode, stages, constants, and per-stage
    /// fail-open — and returns its mask, the four S1 applied flags, the live mode raw
    /// value, and the S4-family/tightAlphaR1 applied flags as a
    /// `VGMatteRefinementLiveResult`. Never returns nil: every stage fails open to its
    /// input, so the worst case is the unmodified `mask`. An Objective-C instance always
    /// runs `defaultLiveMatteRefinementMode` (see `init()`, `.s4SoftAlphaR2`); the mode raw
    /// value and every applied flag on `LiveGreenScreenMaskRefinement` are exposed to
    /// Objective-C through `VGMatteRefinementLiveResult`.
    @objc(refineLiveGreenScreenMaskWithAspectFilledMask:inRect:guidedBy:)
    public func refineLiveGreenScreenMaskBridged(aspectFilledMask mask: CIImage,
                                                 in rect: CGRect,
                                                 guidedBy guide: CIImage) -> VGMatteRefinementLiveResult {
        return VGMatteRefinementLiveResult(refineLiveGreenScreenMask(aspectFilledMask: mask,
                                                                     in: rect,
                                                                     guidedBy: guide))
    }

    // MARK: - S1 stage implementations

    /// Morphological close: CIMorphologyMaximum (dilate) then CIMorphologyMinimum (erode),
    /// each with inputRadius = greenScreenMaskMorphologyCloseRadius (1.0 px; r1b).
    /// Clamped to extent before dilate, then cropped to a finite radius-padded rect before
    /// erode to ensure bounded input and prevent EXC_BAD_ACCESS, then cropped back to `rect`.
    /// Fails open to input mask if disabled, empty, or filters are unavailable.
    ///
    /// - Returns: the closed mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func applyGreenScreenMorphologyClose(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGMatteRefinementPipeline.greenScreenMaskMorphologyCloseEnabled else { return (mask, false) }
        let radius = VGMatteRefinementPipeline.greenScreenMaskMorphologyCloseRadius
        guard radius > 0, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }

        let clamped = mask.clampedToExtent()

        let maxParams: [String: Any] = [
            "inputImage":  clamped,
            "inputRadius": radius,
        ]
        guard let dilated = CIFilter(name: "CIMorphologyMaximum", parameters: maxParams)?.outputImage else {
            return (mask, false)
        }

        // r1b: `dilated` still carries the infinite extent inherited from
        // `clamped`. Feeding that straight into a second morphology filter
        // crashed with EXC_BAD_ACCESS on-device, so crop to a finite rect —
        // padded by the radius on each side so the erode below still has
        // valid samples out to its own reach — before the erode pass.
        // `boundedDilated` is used as-is (not re-clamped) since
        // clampedToExtent() would reintroduce an infinite-extent image and
        // recreate the exact crash condition this works around.
        let pad = max(radius * 2, 2)
        let workingRect = rect.insetBy(dx: -pad, dy: -pad)
        let boundedDilated = dilated.cropped(to: workingRect)

        let minParams: [String: Any] = [
            "inputImage":  boundedDilated,
            "inputRadius": radius,
        ]
        guard let eroded = CIFilter(name: "CIMorphologyMinimum", parameters: minParams)?.outputImage else {
            return (mask, false)
        }

        return (eroded.cropped(to: rect), true)
    }

    /// Softens the mask with CIGaussianBlur at greenScreenMaskFeatherRadius (4.0 px).
    /// Clamped to extent before blur and cropped back to `rect` to prevent edge darkening.
    /// Fails open to input mask if radius <= 0, empty, or blur filter is unavailable.
    ///
    /// - Returns: the feathered mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func featherGreenScreenMask(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        let radius = VGMatteRefinementPipeline.greenScreenMaskFeatherRadius
        guard radius > 0, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }
        let params: [String: Any] = [
            "inputImage":  mask.clampedToExtent(),
            "inputRadius": radius,
        ]
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: params)?.outputImage else {
            return (mask, false)
        }
        return (blurred.cropped(to: rect), true)
    }

    /// Remaps mask luminance m through smoothstep(low, high, m) with constants [0.10, 0.90].
    /// Values <= low become solid background, values >= high become solid foreground,
    /// and the narrow band in between stays soft.
    ///
    /// Implemented as a CoreImage GPU pipeline fusing CIColorMatrix, CIColorClamp,
    /// and CIColorPolynomial into a per-pixel program, cropped back to `rect`.
    /// Fails open to input mask if disabled, degenerate, empty, or filters are unavailable.
    ///
    /// - Returns: the remapped mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func applyGreenScreenTrimap(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGMatteRefinementPipeline.greenScreenTrimapEnabled else { return (mask, false) }
        let low  = VGMatteRefinementPipeline.greenScreenTrimapLow
        let high = VGMatteRefinementPipeline.greenScreenTrimapHigh
        guard high > low, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }

        // 1. Linear ramp: t = (m - low) / (high - low), applied to R, G, B; alpha untouched.
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      mask,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return (mask, false)
        }

        // 2. Clamp t to [0, 1] so the polynomial below only ever sees the smoothstep domain.
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return (mask, false)
        }

        // 3. Smoothstep curve: s = 0 + 0·t + 3·t² − 2·t³ (per R, G, B); alpha = identity.
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        guard let curved = CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage else {
            return (mask, false)
        }
        return (curved.cropped(to: rect), true)
    }

    /// Restores the pre-trimap `feathered` mask over the `trimapped` mask wherever
    /// the camera frame (`guide`) has a strong edge, preserving thin subject detail
    /// (hair, fingers) while flat regions keep the trimapped mask.
    ///
    /// Guided edge constants: intensity 2.0, blur radius 1.5, smoothstep [0.08, 0.34].
    /// Edge confidence is derived from `guide` alone via CIEdges -> CIGaussianBlur ->
    /// smoothstep normalized confidence mask -> CIBlendWithMask.
    /// Fails open to `trimapped` mask if disabled, degenerate, empty, or filters are unavailable.
    ///
    /// - Returns: the guided-edge-preserved mask and `applied == true`, or
    ///   `trimapped` unchanged and `applied == false`.
    private func applyGreenScreenGuidedEdgePreserve(trimapped: CIImage,
                                                      feathered: CIImage,
                                                      guide: CIImage,
                                                      in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGMatteRefinementPipeline.greenScreenGuidedEdgeEnabled else { return (trimapped, false) }
        let low  = VGMatteRefinementPipeline.greenScreenGuidedEdgeLow
        let high = VGMatteRefinementPipeline.greenScreenGuidedEdgeHigh
        guard high > low, !rect.isEmpty, !trimapped.extent.isEmpty,
              !feathered.extent.isEmpty, !guide.extent.isEmpty else {
            return (trimapped, false)
        }

        // 1. Crop the guide (camera frame) to the foreground rect.
        let croppedGuide = guide.cropped(to: rect)

        // 2. Edge detection on the camera frame itself.
        let edgesParams: [String: Any] = [
            "inputImage":     croppedGuide,
            "inputIntensity": VGMatteRefinementPipeline.greenScreenGuidedEdgeIntensity,
        ]
        guard let edges = CIFilter(name: "CIEdges", parameters: edgesParams)?.outputImage else {
            return (trimapped, false)
        }

        // 3. Small blur so isolated edge pixels become a soft confidence band
        //    instead of a 1-pixel-wide mask.
        let blurParams: [String: Any] = [
            "inputImage":  edges.clampedToExtent(),
            "inputRadius": VGMatteRefinementPipeline.greenScreenGuidedEdgeBlurRadius,
        ]
        guard let blurredEdges = CIFilter(name: "CIGaussianBlur", parameters: blurParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4a. Linear ramp: t = (m - low) / (high - low), applied to R, G, B; alpha untouched.
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      blurredEdges,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4b. Clamp t to [0, 1] so the polynomial below only ever sees the smoothstep domain.
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4c. Smoothstep curve: s = 0 + 0·t + 3·t² − 2·t³ (per R, G, B); alpha = identity.
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        guard let curved = CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage else {
            return (trimapped, false)
        }
        // 5. Crop back to `rect`.
        let edgeConfidence = curved.cropped(to: rect)

        // Composite: feathered where the camera has a strong edge, trimapped elsewhere.
        let blendParams: [String: Any] = [
            "inputImage":           feathered,
            "inputBackgroundImage": trimapped,
            "inputMaskImage":       edgeConfidence,
        ]
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: blendParams)?.outputImage else {
            return (trimapped, false)
        }
        return (blended.cropped(to: rect), true)
    }

    // MARK: - S4 guided-alpha (lab `.s4GuidedAlphaR1` / `.s4SoftAlphaR2` /
    // `.s4TightAlphaR2`; live `.s4SoftAlphaR2` (default) and opt-in `.s4GuidedAlphaR1` only)

    /// Result of the S4 candidate: `mask` is the refined mask (or `base` on fail-open),
    /// `band` the 0..1 refinement band weight when applied.
    struct GreenScreenS4Result {
        let mask: CIImage
        let band: CIImage?
        let applied: Bool
        let failOpenReason: String?
    }

    /// S4 "guided alpha": band-limited, camera-guided refinement of the S1 final mask,
    /// shared by every S4-family mode. `parameters` selects the variant:
    /// `greenScreenS4GuidedAlphaR1Parameters` (`.s4GuidedAlphaR1`; lab, and opt-in live),
    /// `greenScreenS4SoftAlphaR2Parameters` (`.s4SoftAlphaR2`; lab, and the production
    /// live default), or the lab-only `greenScreenS4TightAlphaR2Parameters`.
    /// The filter graph is identical for every set; only the numbers differ.
    ///
    /// Pipeline (all stock CoreImage filters, evaluated only over the camera `rect`; the
    /// values in parentheses are the R1 set):
    ///   1. Unknown band from the S1 matte: morphological gradient (CIMorphologyMaximum −
    ///      CIMorphologyMinimum via CIDifferenceBlendMode, `bandRadius` 2.0) →
    ///      CIGaussianBlur `bandBlurRadius` 1.0 → smoothstep(`bandLow` 0.10, `bandHigh`
    ///      0.50). ≈1 on the matte edge, 0 in solid regions.
    ///   2. Camera edge confidence from `guide` luminance (Rec.709 CIColorMatrix) → CIEdges
    ///      `edgeIntensity` 2.5 → CIGaussianBlur `edgeBlurRadius` 1.0 →
    ///      smoothstep(`edgeLow` 0.10, `edgeHigh` 0.40).
    ///   3. In-band candidates from the S1 mask: `snapped` = smoothstep(`snapLow` 0.20,
    ///      `snapHigh` 0.80, base) (edge-aligned, steeper transition) and `soft` =
    ///      CIGaussianBlur(base, `softAlphaRadius` 2.0).
    ///   4. `guidedInBand` = CIBlendWithMask(fg: snapped, bg: soft, mask: edgeConfidence):
    ///      steeper where the camera has a real edge, softer where it is flat.
    ///   5. `refined` = CIBlendWithMask(fg: guidedInBand, bg: base, mask: band): only band
    ///      pixels change; everything else is the S1 mask bit-for-bit.
    ///
    /// Fail-open: any nil filter, degenerate rect/extent, or inconsistent constant returns
    /// `base` unchanged with `applied == false` and a reason naming the step. Called by the
    /// live path in `LiveMatteRefinementMode.s4SoftAlphaR2` (soft R2 set; the production
    /// default) and when the pipeline instance opted into `.s4GuidedAlphaR1` (R1 set) —
    /// never in the explicit `.s1` fallback; S1 constants and stage bodies are untouched.
    private func applyGreenScreenS4GuidedAlpha(base: CIImage,
                                               guide: CIImage,
                                               in rect: CGRect,
                                               parameters: GreenScreenS4Parameters) -> GreenScreenS4Result {
        func failOpen(_ reason: String) -> GreenScreenS4Result {
            return GreenScreenS4Result(mask: base, band: nil, applied: false, failOpenReason: reason)
        }

        let bandRadius = parameters.bandRadius
        let bandBlur   = parameters.bandBlurRadius
        let bandLow    = parameters.bandLow
        let bandHigh   = parameters.bandHigh
        let edgeBlur   = parameters.edgeBlurRadius
        let edgeLow    = parameters.edgeLow
        let edgeHigh   = parameters.edgeHigh
        let softRadius = parameters.softAlphaRadius
        let snapLow    = parameters.snapLow
        let snapHigh   = parameters.snapHigh

        guard bandRadius > 0, bandBlur > 0, bandHigh > bandLow,
              edgeBlur > 0, edgeHigh > edgeLow,
              softRadius > 0, snapHigh > snapLow else {
            return failOpen("degenerate_constants")
        }
        guard !rect.isEmpty, !rect.isInfinite, rect.width >= 2, rect.height >= 2 else {
            return failOpen("degenerate_rect")
        }
        guard !base.extent.isEmpty, !base.extent.isInfinite,
              !guide.extent.isEmpty, !guide.extent.isInfinite else {
            return failOpen("empty_or_unbounded_input")
        }

        // 1. Unknown band: morphological gradient of the S1 mask, softened, smoothstepped.
        //    Every morphology input is a finite, edge-replicated crop (never an infinite
        //    extent chained into a second morphology filter; see r1b note in stage 1).
        let pad         = max(bandRadius * 2, 2)
        let workingRect = rect.insetBy(dx: -pad, dy: -pad)
        let morphInput  = base.clampedToExtent().cropped(to: workingRect.insetBy(dx: -bandRadius, dy: -bandRadius))
        guard let dilated = CIFilter(name: "CIMorphologyMaximum",
                                     parameters: ["inputImage": morphInput, "inputRadius": bandRadius])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_dilate_unavailable")
        }
        guard let eroded = CIFilter(name: "CIMorphologyMinimum",
                                    parameters: ["inputImage": morphInput, "inputRadius": bandRadius])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_erode_unavailable")
        }
        guard let gradient = CIFilter(name: "CIDifferenceBlendMode",
                                      parameters: ["inputImage": dilated, "inputBackgroundImage": eroded])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_gradient_unavailable")
        }
        guard let gradientSoft = CIFilter(name: "CIGaussianBlur",
                                          parameters: ["inputImage": gradient.clampedToExtent(), "inputRadius": bandBlur])?
                .outputImage?.cropped(to: rect) else {
            return failOpen("band_blur_unavailable")
        }
        guard let band = greenScreenS4Smoothstep(gradientSoft, low: bandLow, high: bandHigh)?.cropped(to: rect) else {
            return failOpen("band_smoothstep_unavailable")
        }

        // 2. Camera luminance edge confidence (guide is only ever read, never composited).
        let lumaWeights = VGMatteRefinementPipeline.greenScreenS4LumaWeights
        let lumaParams: [String: Any] = [
            "inputImage":      guide.cropped(to: rect),
            "inputRVector":    lumaWeights,
            "inputGVector":    lumaWeights,
            "inputBVector":    lumaWeights,
            "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
        guard let luma = CIFilter(name: "CIColorMatrix", parameters: lumaParams)?.outputImage else {
            return failOpen("edge_luma_unavailable")
        }
        let edgesParams: [String: Any] = [
            "inputImage":     luma,
            "inputIntensity": parameters.edgeIntensity,
        ]
        guard let edges = CIFilter(name: "CIEdges", parameters: edgesParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("edge_detect_unavailable")
        }
        guard let edgesSoft = CIFilter(name: "CIGaussianBlur",
                                       parameters: ["inputImage": edges.clampedToExtent(), "inputRadius": edgeBlur])?
                .outputImage?.cropped(to: rect) else {
            return failOpen("edge_blur_unavailable")
        }
        guard let edgeConfidence = greenScreenS4Smoothstep(edgesSoft, low: edgeLow, high: edgeHigh)?.cropped(to: rect) else {
            return failOpen("edge_smoothstep_unavailable")
        }

        // 3. In-band candidates derived from the S1 mask only.
        guard let softAlpha = CIFilter(name: "CIGaussianBlur",
                                       parameters: ["inputImage": base.clampedToExtent(), "inputRadius": softRadius])?
                .outputImage?.cropped(to: rect) else {
            return failOpen("soft_alpha_unavailable")
        }
        guard let snappedAlpha = greenScreenS4Smoothstep(base, low: snapLow, high: snapHigh)?.cropped(to: rect) else {
            return failOpen("snap_alpha_unavailable")
        }

        // 4. Guided selection inside the band: steeper at camera edges, softer where flat.
        let guidedParams: [String: Any] = [
            "inputImage":           snappedAlpha,
            "inputBackgroundImage": softAlpha,
            "inputMaskImage":       edgeConfidence,
        ]
        guard let guidedInBand = CIFilter(name: "CIBlendWithMask", parameters: guidedParams)?.outputImage else {
            return failOpen("guided_blend_unavailable")
        }

        // 5. Band-limited application: outside the band the S1 mask is returned untouched.
        let bandParams: [String: Any] = [
            "inputImage":           guidedInBand,
            "inputBackgroundImage": base,
            "inputMaskImage":       band,
        ]
        guard let refined = CIFilter(name: "CIBlendWithMask", parameters: bandParams)?.outputImage else {
            return failOpen("band_blend_unavailable")
        }
        return GreenScreenS4Result(mask: refined.cropped(to: rect), band: band, applied: true, failOpenReason: nil)
    }

    /// S4 helper: smoothstep(low, high, m) per R, G, B with alpha identity, as a fused
    /// CIColorMatrix → CIColorClamp → CIColorPolynomial recipe (same construction as the
    /// S1 trimap / guided-edge curves, kept separate so S1 stage bodies stay untouched).
    /// Returns nil when `high <= low` or a filter is unavailable.
    private func greenScreenS4Smoothstep(_ image: CIImage, low: CGFloat, high: CGFloat) -> CIImage? {
        guard high > low else { return nil }
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      image,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return nil
        }
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return nil
        }
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        return CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage
    }

    // MARK: - S5 guided-filter RND candidate (diagnostic only)

    /// Result of the S5 candidate: `mask` is the refined mask (or `base` on fail-open),
    /// `band` the 0..1 refinement band weight when applied.
    struct GreenScreenS5Result {
        let mask: CIImage
        let band: CIImage?
        let applied: Bool
        let failOpenReason: String?
    }

    /// S5 "guided filter R1": band-limited, camera-guided-filter refinement of the S1 final
    /// mask, approximating a true local-linear guided filter (He et al.) using only stock
    /// CoreImage GPU filters (no CPU pixel loops, no custom kernel needed).
    ///
    /// Let I = camera luminance guide, p = the S1 final mask (`base`). Over a box window of
    /// radius `greenScreenS5GuidedFilterRadius`:
    ///   meanI, meanP           = box-blur(I), box-blur(p)
    ///   corrI, corrIP          = box-blur(I·I), box-blur(I·p)
    ///   varI                   = corrI − meanI·meanI
    ///   covIP                  = corrIP − meanI·meanP
    ///   a                      = covIP / (varI + eps)   (eps floors the divisor so a
    ///                            reciprocal via CIGammaAdjust(power: -1) never sees <= 0)
    ///   b                      = meanP − a·meanI
    ///   meanA, meanB           = box-blur(a), box-blur(b)   (classic guided-filter step:
    ///                            the linear coefficients themselves are smoothed)
    ///   q                      = meanA·I + meanB, clamped to [0, 1]
    /// `q` is then applied only inside a narrow matte-edge band derived from `base`
    /// (morphological gradient dilate − erode, softened, smoothstepped — same construction
    /// family as the S4 band, S5-scoped constants); outside the band `base` is returned
    /// untouched.
    ///
    /// Fail-open: any nil filter, degenerate rect/extent, or inconsistent constant returns
    /// `base` unchanged with `applied == false` and a reason naming the step. Never called
    /// by the live path; S1 constants and stage bodies are untouched.
    private func applyGreenScreenS5GuidedFilterR1(base: CIImage,
                                                   guide: CIImage,
                                                   in rect: CGRect) -> GreenScreenS5Result {
        func failOpen(_ reason: String) -> GreenScreenS5Result {
            return GreenScreenS5Result(mask: base, band: nil, applied: false, failOpenReason: reason)
        }

        let filterRadius = VGMatteRefinementPipeline.greenScreenS5GuidedFilterRadius
        let epsilon      = VGMatteRefinementPipeline.greenScreenS5Epsilon
        let bandRadius   = VGMatteRefinementPipeline.greenScreenS5BandRadius
        let bandBlur     = VGMatteRefinementPipeline.greenScreenS5BandBlurRadius
        let bandLow      = VGMatteRefinementPipeline.greenScreenS5BandLow
        let bandHigh     = VGMatteRefinementPipeline.greenScreenS5BandHigh

        guard filterRadius > 0, epsilon > 0, bandRadius > 0, bandBlur > 0, bandHigh > bandLow else {
            return failOpen("degenerate_constants")
        }
        guard !rect.isEmpty, !rect.isInfinite, rect.width >= 2, rect.height >= 2 else {
            return failOpen("degenerate_rect")
        }
        guard !base.extent.isEmpty, !base.extent.isInfinite,
              !guide.extent.isEmpty, !guide.extent.isInfinite else {
            return failOpen("empty_or_unbounded_input")
        }

        // 1. Camera luminance guide I (Rec.709), cropped to rect.
        let lumaWeights = VGMatteRefinementPipeline.greenScreenS5LumaWeights
        let lumaParams: [String: Any] = [
            "inputImage":      guide.cropped(to: rect),
            "inputRVector":    lumaWeights,
            "inputGVector":    lumaWeights,
            "inputBVector":    lumaWeights,
            "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
        guard let lumaI = CIFilter(name: "CIColorMatrix", parameters: lumaParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("luma_unavailable")
        }

        // p is the S1 final mask, already 0..1 grayscale, cropped to rect.
        let p = base.cropped(to: rect)

        // 2. Box-filter means and elementwise products (all bounded stock GPU filters).
        func boxMean(_ image: CIImage) -> CIImage? {
            let params: [String: Any] = [
                "inputImage":  image.clampedToExtent(),
                "inputRadius": filterRadius,
            ]
            return CIFilter(name: "CIBoxBlur", parameters: params)?.outputImage?.cropped(to: rect)
        }
        func multiply(_ a: CIImage, _ b: CIImage) -> CIImage? {
            let params: [String: Any] = ["inputImage": a, "inputBackgroundImage": b]
            return CIFilter(name: "CIMultiplyBlendMode", parameters: params)?.outputImage?.cropped(to: rect)
        }
        func subtract(_ a: CIImage, _ b: CIImage) -> CIImage? {
            let params: [String: Any] = ["inputImage": a, "inputBackgroundImage": b]
            return CIFilter(name: "CISubtractBlendMode", parameters: params)?.outputImage?.cropped(to: rect)
        }

        guard let meanI = boxMean(lumaI) else { return failOpen("mean_i_unavailable") }
        guard let meanP = boxMean(p) else { return failOpen("mean_p_unavailable") }
        guard let iSquared = multiply(lumaI, lumaI) else { return failOpen("i_squared_unavailable") }
        guard let iTimesP = multiply(lumaI, p) else { return failOpen("i_times_p_unavailable") }
        guard let corrI = boxMean(iSquared) else { return failOpen("corr_i_unavailable") }
        guard let corrIP = boxMean(iTimesP) else { return failOpen("corr_ip_unavailable") }

        // 3. Variance / covariance over the box window.
        guard let meanISquared = multiply(meanI, meanI) else { return failOpen("mean_i_squared_unavailable") }
        guard let meanIMeanP   = multiply(meanI, meanP) else { return failOpen("mean_i_mean_p_unavailable") }
        guard let varI  = subtract(corrI, meanISquared) else { return failOpen("var_i_unavailable") }
        guard let covIP = subtract(corrIP, meanIMeanP) else { return failOpen("cov_ip_unavailable") }

        // 4. a = cov / (var + eps). (var + eps) is floored at eps so the reciprocal
        //    (CIGammaAdjust, power -1, i.e. pow(x, -1)) never sees a value <= 0.
        let epsBiasParams: [String: Any] = [
            "inputImage":      varI,
            "inputRVector":    CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector":    CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector":    CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: epsilon, y: epsilon, z: epsilon, w: 0),
        ]
        guard let varPlusEps = CIFilter(name: "CIColorMatrix", parameters: epsBiasParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("var_plus_eps_unavailable")
        }
        let floorParams: [String: Any] = [
            "inputImage":         varPlusEps,
            "inputMinComponents": CIVector(x: epsilon, y: epsilon, z: epsilon, w: 0),
            "inputMaxComponents": CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1),
        ]
        guard let varFloored = CIFilter(name: "CIColorClamp", parameters: floorParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("var_floor_unavailable")
        }
        let reciprocalParams: [String: Any] = [
            "inputImage": varFloored,
            "inputPower": -1.0,
        ]
        guard let reciprocalVar = CIFilter(name: "CIGammaAdjust", parameters: reciprocalParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("reciprocal_unavailable")
        }
        guard let a = multiply(covIP, reciprocalVar) else { return failOpen("coeff_a_unavailable") }

        // 5. b = meanP − a·meanI.
        guard let aTimesMeanI = multiply(a, meanI) else { return failOpen("a_times_mean_i_unavailable") }
        guard let b = subtract(meanP, aTimesMeanI) else { return failOpen("coeff_b_unavailable") }

        // 6. Box-filter the per-pixel linear coefficients themselves (classic guided-filter step).
        guard let meanA = boxMean(a) else { return failOpen("mean_a_unavailable") }
        guard let meanB = boxMean(b) else { return failOpen("mean_b_unavailable") }

        // 7. q = meanA·I + meanB, then clamp to [0, 1].
        guard let meanAI = multiply(meanA, lumaI) else { return failOpen("mean_a_times_i_unavailable") }
        let addParams: [String: Any] = ["inputImage": meanAI, "inputBackgroundImage": meanB]
        guard let qRaw = CIFilter(name: "CIAdditionCompositing", parameters: addParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("q_add_unavailable")
        }
        let qClampParams: [String: Any] = [
            "inputImage":         qRaw,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let q = CIFilter(name: "CIColorClamp", parameters: qClampParams)?.outputImage?.cropped(to: rect) else {
            return failOpen("q_clamp_unavailable")
        }

        // 8. Matte edge band from the S1 mask (same construction family as the S4 band, with
        //    S5-scoped constants): morphological gradient → soften → smoothstep. ~1 on the
        //    matte edge, 0 in solid regions, so q only replaces the S1 mask near the edge.
        let pad         = max(bandRadius * 2, 2)
        let workingRect = rect.insetBy(dx: -pad, dy: -pad)
        let morphInput  = p.clampedToExtent().cropped(to: workingRect.insetBy(dx: -bandRadius, dy: -bandRadius))
        guard let dilated = CIFilter(name: "CIMorphologyMaximum",
                                     parameters: ["inputImage": morphInput, "inputRadius": bandRadius])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_dilate_unavailable")
        }
        guard let eroded = CIFilter(name: "CIMorphologyMinimum",
                                    parameters: ["inputImage": morphInput, "inputRadius": bandRadius])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_erode_unavailable")
        }
        guard let gradient = CIFilter(name: "CIDifferenceBlendMode",
                                      parameters: ["inputImage": dilated, "inputBackgroundImage": eroded])?
                .outputImage?.cropped(to: workingRect) else {
            return failOpen("band_gradient_unavailable")
        }
        guard let gradientSoft = CIFilter(name: "CIGaussianBlur",
                                          parameters: ["inputImage": gradient.clampedToExtent(), "inputRadius": bandBlur])?
                .outputImage?.cropped(to: rect) else {
            return failOpen("band_blur_unavailable")
        }
        guard let band = greenScreenS5Smoothstep(gradientSoft, low: bandLow, high: bandHigh)?.cropped(to: rect) else {
            return failOpen("band_smoothstep_unavailable")
        }

        // 9. Band-limited application: outside the band the S1 mask is returned untouched.
        let bandParams: [String: Any] = [
            "inputImage":           q,
            "inputBackgroundImage": base,
            "inputMaskImage":       band,
        ]
        guard let refined = CIFilter(name: "CIBlendWithMask", parameters: bandParams)?.outputImage else {
            return failOpen("band_blend_unavailable")
        }
        return GreenScreenS5Result(mask: refined.cropped(to: rect), band: band, applied: true, failOpenReason: nil)
    }

    /// S5 helper: smoothstep(low, high, m) per R, G, B with alpha identity, as a fused
    /// CIColorMatrix → CIColorClamp → CIColorPolynomial recipe (same construction as
    /// `greenScreenS4Smoothstep`, kept separate so S4's helper stays untouched).
    /// Returns nil when `high <= low` or a filter is unavailable.
    private func greenScreenS5Smoothstep(_ image: CIImage, low: CGFloat, high: CGFloat) -> CIImage? {
        guard high > low else { return nil }
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      image,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return nil
        }
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return nil
        }
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        return CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage
    }

    // MARK: - Live "tight alpha R1" RND refinement (opt-in; live-selectable)

    /// Result of the live tight-alpha-R1 refinement: `mask` is the refined mask (or the
    /// S1 mask unchanged on fail-open), `applied` true only when it fully succeeded.
    struct LiveTightAlphaR1Result {
        let mask: CIImage
        let applied: Bool
        let failOpenReason: String?
    }

    /// Opt-in live matte refinement candidate ("A tight alpha" from the offline A/B lab).
    /// Runs live only when `liveMatteRefinementMode == .tightAlphaR1` (selected through a
    /// diagnostic-only route before session start); no other live mode (including the
    /// default `.s4SoftAlphaR2` and the `.s1` fallback) calls
    /// this function. The offline stage tap also calls it, unchanged, when
    /// `GreenScreenRefinementMode.tightAlphaR1` is requested so lab metrics describe the
    /// same recipe and constants the live opt-in renders.
    ///
    /// Pipeline (all stock CoreImage filters, evaluated only over `rect`):
    ///   1. Smoothstep remap of the S1 final mask `mask` (`postGuidedEdge`, never the raw
    ///      segmentation mask) through smoothstep(liveTightAlphaR1Low, liveTightAlphaR1High) —
    ///      the same fused CIColorMatrix -> CIColorClamp -> CIColorPolynomial recipe used
    ///      by the S1 trimap stage — tightening the alpha transition band.
    ///   2. A small final CIGaussianBlur (radius liveTightAlphaR1BlurRadius) re-softens
    ///      the now-steeper edge so it does not look aliased, then crops back to `rect`.
    ///
    /// Fail-open: any nil filter or degenerate rect/constants/input returns `mask`
    /// unchanged with `applied == false` and a reason naming the step. S1 constants and
    /// stage bodies are untouched; this never runs unless explicitly opted into.
    private func applyLiveTightAlphaR1(_ mask: CIImage, in rect: CGRect) -> LiveTightAlphaR1Result {
        func failOpen(_ reason: String) -> LiveTightAlphaR1Result {
            return LiveTightAlphaR1Result(mask: mask, applied: false, failOpenReason: reason)
        }

        let low        = VGMatteRefinementPipeline.liveTightAlphaR1Low
        let high       = VGMatteRefinementPipeline.liveTightAlphaR1High
        let blurRadius = VGMatteRefinementPipeline.liveTightAlphaR1BlurRadius
        guard high > low, blurRadius > 0 else {
            return failOpen("degenerate_constants")
        }
        guard !rect.isEmpty, !rect.isInfinite, rect.width >= 2, rect.height >= 2 else {
            return failOpen("degenerate_rect")
        }
        guard !mask.extent.isEmpty, !mask.extent.isInfinite else {
            return failOpen("empty_or_unbounded_input")
        }

        // 1. Smoothstep remap: t = (m - low) / (high - low), clamped to [0, 1], then
        //    s = 3t^2 - 2t^3 per R, G, B; alpha untouched.
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      mask,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return failOpen("remap_matrix_unavailable")
        }
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return failOpen("remap_clamp_unavailable")
        }
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        guard let curved = CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage else {
            return failOpen("remap_curve_unavailable")
        }
        let remapped = curved.cropped(to: rect)

        // 2. Small final Gaussian blur, clamped to extent before blur and cropped back to
        //    `rect` (same edge-darkening-avoidance pattern as featherGreenScreenMask).
        let blurParams: [String: Any] = [
            "inputImage":  remapped.clampedToExtent(),
            "inputRadius": blurRadius,
        ]
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: blurParams)?.outputImage else {
            return failOpen("final_blur_unavailable")
        }
        return LiveTightAlphaR1Result(mask: blurred.cropped(to: rect), applied: true, failOpenReason: nil)
    }
}
