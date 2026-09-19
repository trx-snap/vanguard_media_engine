// Copyright 2026, Connects. All rights reserved.
// ios_live_green_screen_public_api_physical_smoke.dart
//
// Dedicated iOS physical smoke harness proving the generic (caller-agnostic)
// live green-screen public Dart API can route a full session lifecycle
// through the platform interface on iOS: start with the product default
// full-frame identity foreground (no explicit foregroundTransform is passed;
// VGLiveGreenScreenConfig always serializes its identity default) over a solid
// background (proving full-frame natural camera / background replacement as
// the product default for live camera, meeting, calling, and going-live),
// wait (bounded) for the native segmenter to publish its first matte, update
// to a static image file background while that default full-frame identity
// foreground remains active (proving generic static image background
// support), read the native diagnostics and ASSERT that real keying happened
// (see "Keying proof gates" below), and stop — all while a bounded live
// preview texture is visible for manual observation.
//
// The default run stays in the full-frame identity foreground for its whole
// life so a visual reviewer only ever sees the product green-screen output.
// The explicit overlay-style transform phase (scale 0.45 picture-in-picture
// over a green background) is OPT-IN via
//     --dart-define=LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true
// and, when included, proves route acceptance of an explicit transform only;
// it is never green-screen quality proof (a downscaled camera over green is
// not what keyed output looks like).
//
// This harness exercises the public contracts in `vg_live_green_screen.dart`
// only (via `MethodChannelVGLiveGreenScreenPlatform`); it is not scoped to
// any caller such as Duet, live meeting/calling, or the Universal Editor.
// It mirrors `android_live_green_screen_public_api_physical_smoke.dart` with
// `IOS_` markers and an iOS proof boundary.
//
// Proof boundary:
//   - Device requirement: iOS physical device with camera permission already
//     granted to the example Runner (this harness does not request
//     permissions itself; the native camera source prompts on first use if
//     the status is not yet determined).
//   - Harness command:
//       cd packages/vanguard_media_engine/example &&
//       flutter run -d <iosDeviceId> \
//         -t lib/ios_live_green_screen_public_api_physical_smoke.dart \
//         --dart-define=LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS=8
//     Fast-Metal A/B (RND): add
//         --dart-define=LIVE_GREENSCREEN_IOS_FAST_METAL=true
//     Before START the harness sends that bool to the diagnostic-only native
//     route `setLiveGreenScreenDiagnosticsOptions` ({iosFastMetalPrecision})
//     on the shared MethodChannel (SET_DIAGNOSTICS_OPTIONS step). The route
//     is NOT public Dart API: it is rejected with live_busy while a session
//     is active and applies to the next start only, which is why it precedes
//     START. The request is recorded in the JSON as
//     `requestedFastMetalPrecision` (plus the route's echoed
//     `diagnosticsOptions`), and the native `fastMetalPrecision` /
//     `metalAllowPrecisionLoss` values returned by the diagnostics route are
//     reported next to it as `nativeFastMetalPrecision` / `fastMetalApplied`;
//     a mismatch is logged as IOS_LIVE_GREENSCREEN_PUBLIC_API_FAST_METAL_NOT_APPLIED
//     (a note, never a failure).
//     Segmentation backend: the default run proves the native production
//     default without forcing an override: when
//     `LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND` is absent or empty, no
//     `iosSegmentationBackend` key is passed in `setLiveGreenScreenDiagnosticsOptions`,
//     letting the unconfigured native default ("auto") run and be proven. On
//     iOS "auto" resolves to the ARKit ARMatteGenerator engine when the device
//     supports front-camera face tracking with person segmentation (native
//     diagnostics: segmentationEngine "arkit", providerKind "arkit",
//     providerMode "arkit_face_matte_full", timingSemantics
//     "arkit_matte_generator_spans", segmentationBackend "arkit",
//     requestedSegmentationBackend "auto", segmentationBackendSelection
//     "arkit_default") and to Vision Fast otherwise (providerMode vision_fast,
//     segmentationBackendSelection vision_default_arkit_unsupported(...)).
//     To run an explicit A/B override, pass:
//         --dart-define=LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND=<auto|arkit|litert|visionFast|visionBalanced|visionAccurate|litertSelfie>
//     (arkit = explicit ARKit engine with no Vision fallback — an unsupported
//     device takes the degraded-unkeyed path with the exact reason;
//     litert = alternate LiteRT/Metal path; litertSelfie = the
//     same LiteRT/Metal runtime on the small Android-production selfie model
//     selfie_segmentation_landscape.tflite with aspect-fit input and a direct
//     single-channel person matte, no fallback). When non-empty, the value is sent
//     alongside the fast-Metal bool as `iosSegmentationBackend` in the same
//     SET_DIAGNOSTICS_OPTIONS call (an unknown value is rejected natively with
//     INVALID_ARG, which fails that step). The request is recorded as
//     `requestedSegmentationBackend` ('nativeDefault' when no override is
//     requested); the native echo `segmentationBackend`
//     plus `providerKind`, `providerMode`, and `timingSemantics` from the
//     diagnostics route are reported next to it as
//     `nativeSegmentationBackend` / `providerKind` / `providerMode` /
//     `timingSemantics` (plus the native `requestedSegmentationBackend`,
//     `segmentationBackendSelection`, `segmentationEngine`, and the ARKit
//     engine spans `avgMatteGenerationMs` / `avgCompositeMs` / `effectiveFps`
//     when present), with `segmentationBackendApplied` true when the
//     running provider matches the request (an explicit "auto" request is
//     applied when the native side resolved it to the ARKit engine or to
//     Vision Fast; null when no override was requested).
//     A mismatch is logged as
//     IOS_LIVE_GREENSCREEN_PUBLIC_API_SEGMENTATION_BACKEND_NOT_APPLIED (a
//     note, never a failure). For a Vision backend the split spans mean:
//     invoke = Vision request perform, inputCopy = 0, outputAccess =
//     observation lookup, policy = mask copy (see `timingSemantics`).
//     Live matte refinement (RND): the default run leaves the live matte
//     refinement at its native production default (`s1`, the unchanged live
//     pipeline): when `LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT` is absent or
//     empty, no `iosLiveMatteRefinement` key is passed in
//     `setLiveGreenScreenDiagnosticsOptions`. To opt into the "A tight alpha"
//     offline A/B candidate, pass:
//         --dart-define=LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT=tightAlphaR1
//     (an unknown value is rejected natively with INVALID_ARG, which fails that
//     step). The request is recorded as `requestedLiveMatteRefinement` ('s1'
//     when no override is requested); the native echo `liveMatteRefinement`
//     from the diagnostics route is reported next to it as
//     `nativeLiveMatteRefinement`. This option never changes the overlay/PIP
//     phase, which stays independently opt-in and defaults to false.
//   - Keying readiness (WAIT_KEYING_READY step): right after START, before
//     the first observation window, the harness polls the diagnostic-only
//     native route `getLiveGreenScreenDiagnostics` every
//     LIVE_GREENSCREEN_KEYING_READY_POLL_MS (default 250) until
//     `maskPublishCount > 0` (the compositor consumed a real matte), or until
//     the native side reports the terminal failure path (`isKeyed` false /
//     providerKind unavailable|released), or until
//     LIVE_GREENSCREEN_KEYING_READY_TIMEOUT_MS (default 10000) elapses. It
//     prints IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_READY:{…} or
//     IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_NOT_READY:{…}. The step itself
//     never fails on timeout/degraded (the observation windows still run so
//     the reviewer sees what the device shows); the outcome is asserted by
//     ASSERT_KEYING_PROOF after GET_DIAGNOSTICS, so a session that never keyed
//     fails at diagnostics instead of passing silently.
//   - Keying proof gates (ASSERT_KEYING_PROOF step, after GET_DIAGNOSTICS):
//     the top-level fields isKeyed, providerKind, providerMode,
//     segmentationBackend, failureReason, terminalReason, sampleCount,
//     maskPublishCount, lastMaskCoveragePercent, degradedEventCount are
//     printed as IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_PROOF:{…} and the
//     smoke FAILS (pass=false, IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_PROOF_FAIL,
//     step FAIL, PHYSICAL_FAIL) when ANY of these holds:
//       * isKeyed != true
//       * degradedEventCount > 0 (any degraded / fallback event was received)
//       * providerKind is "released" or "unavailable"
//       * sampleCount <= 0 (no provider inference sample; also true for the
//         heuristic face-region fallback, which is not a person matte)
//       * maskPublishCount <= 0 (no matte ever reached the compositor)
//       * keying readiness was not reached before the first observation window
//     No latency threshold is asserted: timing values are reported only.
//   - Native log markers expected in the device log (not asserted here):
//       IOS_LIVE_GREENSCREEN_SESSION_STARTED, IOS_LIVE_GREENSCREEN_CAMERA_STARTED,
//       IOS_LIVE_GREENSCREEN_BACKGROUND_UPDATED, IOS_LIVE_GREENSCREEN_TRANSFORM_UPDATED,
//       IOS_LIVE_GREENSCREEN_SESSION_RELEASED, plus exactly one of
//       IOS_LIVE_GREENSCREEN_MASK_PROVIDER_VISION_READY (expected on device
//       for the production Vision Fast default, or visionBalanced / visionAccurate),
//       IOS_LIVE_GREENSCREEN_MASK_PROVIDER_LITERT_READY (expected on device
//       when overridden to litert backend, and — with
//       model=selfie_segmentation_landscape mattePath=person_confidence_direct —
//       for a litertSelfie request),
//       IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK (heuristic face-region
//       matte; NOT a LiteRT quality run; litert backend only), or
//       IOS_LIVE_GREENSCREEN_MASK_PROVIDER_UNAVAILABLE (degraded, unkeyed);
//       and IOS_LIVE_GREENSCREEN_MASK_FIRST_PUBLISHED once the first matte lands,
//       and IOS_LIVE_GREENSCREEN_DIAGNOSTICS when the diagnostics route replies.
//   - LiteRT matte latency telemetry (GET_DIAGNOSTICS step): after the final
//     observation window and before STOP, the harness calls the diagnostic-only
//     native route `getLiveGreenScreenDiagnostics` directly on the shared
//     MethodChannel (it is NOT part of the public Dart interface) and embeds
//     the returned map verbatim as `diagnostics` in the JSON payload
//     (sampleCount, avgTotalMs, maxTotalMs, avgInferenceMs, maxInferenceMs,
//     avgPreMs, avgPostMs, avgCadenceMs, firstTotalMs, lastTotalMs,
//     firstMaskLatencyMs, maskPublishCount, lastMaskCoveragePercent,
//     providerKind, failureReason, terminalReason, terminalState, …). The
//     GET_DIAGNOSTICS step fails only if the route itself fails; the timing
//     numbers are reported, not asserted against thresholds. The keying
//     presence gates listed above are asserted by the separate
//     ASSERT_KEYING_PROOF step.
//     Latency split (RND): when the native build reports the split inference
//     spans (avgInputCopyMs / avgInvokeMs / avgOutputAccessMs and their
//     max/min/last variants, avgPolicyMs) they are additionally surfaced as
//     the `latencySplit` map plus `providerMode` and `fastMetalApplied`.
//     Older native builds without those keys yield `latencySplit: null`
//     and `latencySplitFieldsPresent: false`; the step still passes.
//   - Claims allowed:
//       * public Dart API route via VGLiveGreenScreenPlatformInterface
//         (MethodChannelVGLiveGreenScreenPlatform) on iOS
//       * default generic live green-screen start: startLiveGreenScreenSession
//         accepted with default full-frame identity foreground (no explicit
//         foregroundTransform passed; the config's identity default is
//         serialized; 720x1280 canvas, solid teal background) proving
//         full-frame natural camera / background replacement as the product
//         default
//       * static image background proof: updateLiveGreenScreenBackground
//         accepted for a VGGreenScreenImageFileBackground (still_C.png staged
//         from rootBundle into a temp file, aspectFill) while the default
//         full-frame identity foreground is still active — no transform
//         update precedes this step — proving generic static image
//         background support for live camera/meeting/calling/going-live
//       * keying proof (default run): the native diagnostics reported a live
//         keyed session (isKeyed true, providerKind neither released nor
//         unavailable, no degraded/fallback event, sampleCount > 0,
//         maskPublishCount > 0, readiness reached before the first
//         observation window) — asserted, not merely reported
//       * ONLY with LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true: explicit
//         optional transform route proof — updateLiveGreenScreenTransform
//         accepted for an overlay-style placement (scale 0.45, bottom-left
//         offset) and updateLiveGreenScreenBackground accepted for a second
//         solid background color (solid green). Route acceptance only; the
//         resulting picture-in-picture frame is NOT green-screen output.
//       * stopLiveGreenScreenSession accepted
//       * bounded live preview texture present for manual observation across
//         the default full-frame identity phase and the static image
//         background phase (still full-frame identity foreground); plus the
//         opt-in overlay transform phase when it is included
//       * staged image fixture temp file/directory guaranteed cleanup
//       * LiteRT matte latency/cadence telemetry captured on device through
//         the diagnostic-only getLiveGreenScreenDiagnostics route and
//         reported verbatim in the JSON `diagnostics` map
//       * fast-Metal request (dart-define) delivered through the diagnostic-
//         only setLiveGreenScreenDiagnosticsOptions route before START, and
//         the native requested/applied precision, provider mode, and split
//         inference spans (input copy / invoke / output access) reported
//         side by side
//       * segmentation backend native default proof (when no override is
//         passed) proving the unconfigured native default selects Vision
//         Fast; or explicit backend request (dart-define: litert | visionFast |
//         visionBalanced | visionAccurate | litertSelfie) delivered through
//         the same route before START, and
//         the native echoed backend / providerKind / providerMode /
//         timingSemantics reported side by side for a LiteRT vs Apple Vision
//         A/B on the same harness
//       * live matte refinement native default proof (when no override is
//         passed) proving the unconfigured native default stays "s1"; or
//         explicit opt-in request (dart-define: tightAlphaR1) delivered
//         through the same setLiveGreenScreenDiagnosticsOptions route before
//         START, with the native echoed `liveMatteRefinement` reported side
//         by side with the request
//   - Non-claims:
//       * no automated pixel or matte quality proof; the image background
//         step is proved by accepted route/lifecycle/acceptance plus a
//         bounded observation window, not by manual or automated visual
//         classification. The keying proof gates prove that a real person
//         matte was produced and consumed, not that it was accurate.
//       * the opt-in overlay/PIP phase is never green-screen quality proof:
//         a scale-0.45 camera over a green background must not be read as
//         keyed output; by default that phase does not run at all
//       * no latency threshold assertion: timing values (avg/max/min spans,
//         cadence, first-mask latency) are reported, never used to fail the
//         smoke; only the presence gates above (sampleCount > 0,
//         maskPublishCount > 0) are asserted
//       * no fast-Metal assertion: a requested-but-not-applied precision
//         option or missing split fields are reported, never used to fail
//       * no segmentation backend assertion: a requested-but-not-applied
//         backend or native default mismatch is reported
//         (segmentationBackendApplied), never used to fail; Vision split
//         spans are request/observation/copy spans, not TFLite tensor spans
//         (see timingSemantics)
//       * no live matte refinement assertion or quality claim: the requested
//         vs native `liveMatteRefinement` value is reported only, never used
//         to fail the smoke; this option carries no visual quality proof for
//         "tightAlphaR1" beyond route acceptance
//       * no video background proof (solid/image background only; video
//         backgrounds remain explicitly not proved/deferred)
//       * no export proof
//       * no recording proof
//       * no audio proof
//       * no Android proof
//       * no all-device or low-end device performance proof

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vg_green_screen.dart';
import 'package:vanguard_media_engine/vg_live_green_screen.dart';

const String kSmokeStartMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_SMOKE_START';
const String kSolidObserveBeginMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_SOLID_BEGIN';
const String kSolidObserveEndMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_SOLID_END';
const String kImageObserveBeginMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_IMAGE_BEGIN';
const String kImageObserveEndMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_IMAGE_END';
const String kUpdatedObserveBeginMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_UPDATED_BEGIN';
const String kUpdatedObserveEndMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OBSERVE_UPDATED_END';
const String kDiagnosticsMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_DIAGNOSTICS:';
const String kDiagnosticsOptionsMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_DIAGNOSTICS_OPTIONS:';
const String kLatencySplitMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_LATENCY_SPLIT:';
const String kCameraPresetMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_CAMERA_PRESET:';
const String kAvgTotalMsMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_AVG_TOTAL_MS:';
const String kFastMetalRequestedMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_FAST_METAL_REQUESTED=';
const String kFastMetalNotAppliedMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_FAST_METAL_NOT_APPLIED';
const String kSegmentationBackendRequestedMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_SEGMENTATION_BACKEND_REQUESTED=';
const String kSegmentationBackendNotAppliedMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_SEGMENTATION_BACKEND_NOT_APPLIED';
const String kLiveMatteRefinementRequestedMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_LIVE_MATTE_REFINEMENT_REQUESTED=';
const String kOverlayPhaseMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_OVERLAY_PHASE_INCLUDED=';
const String kKeyingReadyMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_READY:';
const String kKeyingNotReadyMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_NOT_READY:';
const String kKeyingProofMarkerPrefix =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_PROOF:';
const String kKeyingProofFailMarker =
    'IOS_LIVE_GREENSCREEN_PUBLIC_API_KEYING_PROOF_FAIL';
const String kSmokeJsonPrefix = 'IOS_LIVE_GREENSCREEN_PUBLIC_API_JSON:';
const String kSmokePassMarker = 'IOS_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_PASS';
const String kSmokeFailMarker = 'IOS_LIVE_GREENSCREEN_PUBLIC_API_PHYSICAL_FAIL';

/// Asset path of the still-image fixture staged into a temp file and used as
/// the static image background for [VGGreenScreenImageFileBackground].
const String kImageBackgroundAssetPath = 'assets/manual_test_clips/still_C.png';

/// Diagnostic-only native route (not part of the public Dart interface).
/// Invoked directly on the shared plugin channel so the physical smoke can
/// report real LiteRT matte latency/cadence numbers from the active session.
const String kDiagnosticsMethod = 'getLiveGreenScreenDiagnostics';

/// Diagnostic-only native route (not part of the public Dart interface) that
/// stores `{iosFastMetalPrecision: bool, iosSegmentationBackend?: string}` for
/// the NEXT session start. When `iosSegmentationBackend` is omitted, the
/// native production default (Vision Fast) is selected. The
/// native side rejects it with `live_busy` while a session is active, so the
/// harness always sends it before START. The reply echoes the stored options.
const String kDiagnosticsOptionsMethod = 'setLiveGreenScreenDiagnosticsOptions';
const MethodChannel kDiagnosticsChannel = MethodChannel('vanguard_media_engine');

/// Length of each observation phase (initial and updated), in seconds.
/// Override with `--dart-define=LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS=<n>`.
/// Clamped to a minimum of 2 seconds.
const int _rawHoldSeconds = int.fromEnvironment(
  'LIVE_GREENSCREEN_PUBLIC_API_HOLD_SECONDS',
  defaultValue: 8,
);
const int kHoldSeconds = _rawHoldSeconds < 2 ? 2 : _rawHoldSeconds;

/// Fast-Metal switch: request the LiteRT Metal delegate's fast precision mode
/// (allow_precision_loss = true, float16 permitted). Default false keeps the
/// production full-float32 path. Override with
/// `--dart-define=LIVE_GREENSCREEN_IOS_FAST_METAL=true`.
const bool kFastMetalRequested = bool.fromEnvironment(
  'LIVE_GREENSCREEN_IOS_FAST_METAL',
  defaultValue: false,
);

/// Which native segmentation backend the next start should use.
/// When absent or empty (the default), no `iosSegmentationBackend` option is
/// sent, allowing the native production default ("auto": the ARKit
/// ARMatteGenerator engine when supported, else Vision Fast) to run and be
/// proven. Override with
/// `--dart-define=LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND=<backend>`
/// (`auto` the same resolution as the default; `arkit` explicit ARKit engine
/// with no Vision fallback; `litert` selectable alternate LiteRT/Metal path;
/// `visionFast` / `visionBalanced` / `visionAccurate` select the Apple Vision
/// person-segmentation provider; `litertSelfie` runs the small Android selfie
/// model on LiteRT/Metal). The native route rejects any other value with
/// INVALID_ARG.
const String kSegmentationBackendRequested = String.fromEnvironment(
  'LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND',
  defaultValue: '',
);

/// Whether an explicit segmentation backend override was requested via
/// `LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND`. When false, the harness proves
/// the unconfigured native production default ("auto": ARKit when supported,
/// else Vision Fast).
const bool kSegmentationBackendOverrideRequested =
    kSegmentationBackendRequested != '';

/// Backend name formatted for display, markers, and payload: 'nativeDefault'
/// when [kSegmentationBackendRequested] is empty, or the explicit backend string.
const String kSegmentationBackendReported =
    kSegmentationBackendOverrideRequested
        ? kSegmentationBackendRequested
        : 'nativeDefault';

/// Which opt-in live matte refinement RND candidate the next start should use
/// (see VGDuetPreviewCompositor.LiveMatteRefinementMode). When absent or empty
/// (the default), no `iosLiveMatteRefinement` option is sent, letting the
/// native production default ("s1", the unchanged live pipeline) run and be
/// proven. Override with
/// `--dart-define=LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT=tightAlphaR1`
/// to opt into the "A tight alpha" offline A/B candidate. The native route
/// rejects any other value with INVALID_ARG.
const String kLiveMatteRefinementRequested = String.fromEnvironment(
  'LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT',
  defaultValue: '',
);

/// Whether an explicit live matte refinement override was requested via
/// `LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT`. When false, the harness
/// proves the unconfigured native production default ("s1").
const bool kLiveMatteRefinementOverrideRequested =
    kLiveMatteRefinementRequested != '';

/// Live matte refinement name formatted for display, markers, and payload:
/// 's1' when [kLiveMatteRefinementRequested] is empty, or the explicit
/// requested value.
const String kLiveMatteRefinementReported =
    kLiveMatteRefinementOverrideRequested
        ? kLiveMatteRefinementRequested
        : 's1';

/// Opt-in: run the explicit overlay-style transform phase (scale 0.45
/// picture-in-picture over a green background) after the image background
/// phase. Default false so the default visual proof stays full-frame
/// identity from START to STOP and a reviewer can never mistake the PIP
/// frame for green-screen output. Override with
/// `--dart-define=LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true`.
const bool kIncludeOverlayPhase = bool.fromEnvironment(
  'LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE',
  defaultValue: false,
);

/// Upper bound on the keying readiness poll (START → first consumed matte),
/// in milliseconds. Override with
/// `--dart-define=LIVE_GREENSCREEN_KEYING_READY_TIMEOUT_MS=<n>`. Clamped to a
/// minimum of 1000. This bounds only how long the harness WAITS before the
/// first observation window; it is not a latency threshold on inference.
const int _rawKeyingReadyTimeoutMs = int.fromEnvironment(
  'LIVE_GREENSCREEN_KEYING_READY_TIMEOUT_MS',
  defaultValue: 10000,
);
const int kKeyingReadyTimeoutMs =
    _rawKeyingReadyTimeoutMs < 1000 ? 1000 : _rawKeyingReadyTimeoutMs;

/// Interval between readiness diagnostics polls, in milliseconds. Override
/// with `--dart-define=LIVE_GREENSCREEN_KEYING_READY_POLL_MS=<n>`. Clamped to
/// a minimum of 50.
const int _rawKeyingReadyPollMs = int.fromEnvironment(
  'LIVE_GREENSCREEN_KEYING_READY_POLL_MS',
  defaultValue: 250,
);
const int kKeyingReadyPollMs =
    _rawKeyingReadyPollMs < 50 ? 50 : _rawKeyingReadyPollMs;

/// `providerKind` values that mean the session has no live segmentation
/// provider: "released" (adapter dropped after the terminal failure path) and
/// "unavailable" (no provider could be created).
const Set<String> kNoProviderKinds = <String>{'released', 'unavailable'};

/// Event types that mean keying was reduced or switched off.
const Set<String> kDegradedEventTypes = <String>{'degraded', 'fallback'};

/// Diagnostics keys that make up the split inference latency report. Present
/// only when the native build reports the split spans; absent keys are
/// tolerated (older native code) and reported as `latencySplit: null`.
const List<String> kLatencySplitKeys = <String>[
  'avgInputCopyMs',
  'maxInputCopyMs',
  'minInputCopyMs',
  'avgInvokeMs',
  'maxInvokeMs',
  'minInvokeMs',
  'avgOutputAccessMs',
  'maxOutputAccessMs',
  'minOutputAccessMs',
  'avgPolicyMs',
  'lastInputCopyMs',
  'lastInvokeMs',
  'lastOutputAccessMs',
];

/// Extracts the split inference spans from the diagnostics map. Returns null
/// when none of [kLatencySplitKeys] is present (native build predates the
/// split); otherwise a map holding every present key verbatim.
Map<String, Object?>? extractLatencySplit(Map<String, dynamic>? diagnostics) {
  if (diagnostics == null) return null;
  final split = <String, Object?>{};
  for (final key in kLatencySplitKeys) {
    if (diagnostics.containsKey(key)) {
      split[key] = diagnostics[key];
    }
  }
  return split.isEmpty ? null : split;
}

/// Native applied precision option (`metalAllowPrecisionLoss` from the
/// diagnostics route), or null when the native build does not report it.
bool? extractFastMetalApplied(Map<String, dynamic>? diagnostics) {
  final raw = diagnostics?['metalAllowPrecisionLoss'];
  return raw is bool ? raw : null;
}

/// Native `providerMode` expected for a requested backend, or null when any
/// mode is acceptable (litert: fp32 vs fp16 is governed by the fast-Metal
/// flag, so only `providerKind` is checked for it; litertSelfie is checked by
/// prefix, see [expectedProviderModePrefixForBackend]).
String? expectedProviderModeForBackend(String backend) {
  switch (backend) {
    case 'arkit':
      return 'arkit_face_matte_full';
    case 'visionFast':
      return 'vision_fast';
    case 'visionBalanced':
      return 'vision_balanced';
    case 'visionAccurate':
      return 'vision_accurate';
    default:
      return null;
  }
}

/// Native `providerMode` prefix expected for a requested backend whose exact
/// mode also depends on the fast-Metal flag (`litert_selfie_metal_fp32` /
/// `litert_selfie_metal_fp16` / `litert_selfie_cpu_simulator`), or null.
String? expectedProviderModePrefixForBackend(String backend) {
  switch (backend) {
    case 'litertSelfie':
      return 'litert_selfie';
    default:
      return null;
  }
}

/// Whether the native side ran the requested segmentation backend: the echoed
/// `segmentationBackend` must match the request and the running provider must
/// be the one that backend selects (`providerMode` arkit_face_matte_full for
/// an explicit arkit request; vision_fast / vision_balanced / vision_accurate
/// for a Vision request; `providerKind` litert for litert; `providerKind`
/// litert AND `providerMode` prefixed litert_selfie for litertSelfie — a plain
/// `litert_*` mode would mean the production model ran instead). An explicit
/// "auto" request is applied when the native side resolved it to the ARKit
/// engine (segmentationBackend arkit, providerKind arkit) or to Vision Fast
/// (segmentationBackend visionFast, providerMode vision_fast).
/// Null when the native build does not report `segmentationBackend`.
bool? extractSegmentationBackendApplied(
  Map<String, dynamic>? diagnostics,
  String requested,
) {
  final native = diagnostics?['segmentationBackend'];
  if (native is! String) return null;
  if (requested == 'auto') {
    if (native == 'arkit') return diagnostics?['providerKind'] == 'arkit';
    if (native == 'visionFast') {
      return diagnostics?['providerMode'] == 'vision_fast';
    }
    return false;
  }
  if (native != requested) return false;
  final expectedMode = expectedProviderModeForBackend(requested);
  if (expectedMode != null) {
    return diagnostics?['providerMode'] == expectedMode;
  }
  final expectedPrefix = expectedProviderModePrefixForBackend(requested);
  if (expectedPrefix != null) {
    final mode = diagnostics?['providerMode'];
    return diagnostics?['providerKind'] == 'litert' &&
        mode is String &&
        mode.startsWith(expectedPrefix);
  }
  return diagnostics?['providerKind'] == 'litert';
}

/// Integer view of a diagnostics number (`int` or `double` over the channel),
/// or null when absent / not numeric.
int? diagnosticsInt(Map<String, dynamic>? diagnostics, String key) {
  final raw = diagnostics?[key];
  return raw is num ? raw.toInt() : null;
}

/// Double view of a diagnostics number, or null when absent / not numeric.
double? diagnosticsDouble(Map<String, dynamic>? diagnostics, String key) {
  final raw = diagnostics?[key];
  return raw is num ? raw.toDouble() : null;
}

/// String view of a diagnostics value, or null when absent / not a string.
String? diagnosticsString(Map<String, dynamic>? diagnostics, String key) {
  final raw = diagnostics?[key];
  return raw is String ? raw : null;
}

/// Number of received events whose type is in [kDegradedEventTypes].
int countDegradedEvents(List<Map<String, dynamic>> events) {
  var count = 0;
  for (final event in events) {
    if (kDegradedEventTypes.contains(event['type'])) count++;
  }
  return count;
}

/// Top-level keying proof fields lifted out of the diagnostics map and the
/// received events. Every key is always present (null when the native build
/// did not report it) so the JSON shape is stable across builds.
Map<String, Object?> extractKeyingProof(
  Map<String, dynamic>? diagnostics,
  List<Map<String, dynamic>> events,
) {
  final failureReason = diagnosticsString(diagnostics, 'failureReason');
  final terminalReason = diagnosticsString(diagnostics, 'terminalReason');
  return <String, Object?>{
    'isKeyed': diagnostics?['isKeyed'] is bool
        ? diagnostics!['isKeyed'] as bool
        : null,
    'providerKind': diagnosticsString(diagnostics, 'providerKind'),
    'providerMode': diagnosticsString(diagnostics, 'providerMode'),
    'segmentationBackend':
        diagnosticsString(diagnostics, 'segmentationBackend'),
    'failureReason': failureReason,
    'terminalReason': terminalReason,
    'terminalState': diagnosticsString(diagnostics, 'terminalState'),
    'sampleCount': diagnosticsInt(diagnostics, 'sampleCount'),
    'maskPublishCount': diagnosticsInt(diagnostics, 'maskPublishCount'),
    'lastMaskCoveragePercent':
        diagnosticsDouble(diagnostics, 'lastMaskCoveragePercent'),
    'degradedEventCount': countDegradedEvents(events),
  };
}

/// The keying proof gates. Returns one human-readable line per violated
/// gate; empty means the session really keyed. [readinessReached] is the
/// WAIT_KEYING_READY outcome (false when the poll timed out or hit the
/// terminal failure path before the first observation window).
List<String> keyingProofViolations(
  Map<String, Object?> proof, {
  required bool readinessReached,
}) {
  final violations = <String>[];
  final isKeyed = proof['isKeyed'];
  if (isKeyed != true) {
    violations.add('isKeyed != true (native reported ${isKeyed ?? 'absent'})');
  }
  final degradedEventCount = proof['degradedEventCount'];
  if (degradedEventCount is int && degradedEventCount > 0) {
    violations.add('degradedEventCount > 0 ($degradedEventCount)');
  }
  final providerKind = proof['providerKind'];
  if (providerKind is! String) {
    violations.add('providerKind absent');
  } else if (kNoProviderKinds.contains(providerKind)) {
    violations.add('providerKind is $providerKind');
  }
  final sampleCount = proof['sampleCount'];
  if (sampleCount is! int || sampleCount <= 0) {
    violations.add('sampleCount <= 0 (${sampleCount ?? 'absent'})');
  }
  final maskPublishCount = proof['maskPublishCount'];
  if (maskPublishCount is! int || maskPublishCount <= 0) {
    violations.add(
      'maskPublishCount <= 0 (${maskPublishCount ?? 'absent'})',
    );
  }
  if (!readinessReached) {
    violations.add(
      'keying readiness not reached before the first observation window',
    );
  }
  return violations;
}

/// Initial solid background: a teal shade.
const int kInitialBackgroundArgb = 0xFF00695C;

/// Updated solid background: a green shade, chosen to be visibly distinct
/// from [kInitialBackgroundArgb] so the UPDATE_BACKGROUND_SOLID step is
/// observable on device.
const int kUpdatedBackgroundArgb = 0xFF2E7D32;

/// Explicit optional foreground transform passed to
/// `updateLiveGreenScreenTransform`: an opt-in overlay-style shrink and
/// reposition (scale 0.45, bottom-left offset). Proves that the platform
/// interface accepts explicit transform updates, while keeping full-frame
/// identity as the product default for live camera/meeting/calling.
const VGLiveGreenScreenForegroundTransform
kExplicitOptionalForegroundTransform = VGLiveGreenScreenForegroundTransform(
  scale: 0.45,
  offsetX: -0.28,
  offsetY: 0.3,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IosLiveGreenScreenPublicApiPhysicalSmokeApp());
}

class IosLiveGreenScreenPublicApiPhysicalSmokeApp extends StatefulWidget {
  const IosLiveGreenScreenPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosLiveGreenScreenPublicApiPhysicalSmokeApp> createState() =>
      _IosLiveGreenScreenPublicApiPhysicalSmokeAppState();
}

class _IosLiveGreenScreenPublicApiPhysicalSmokeAppState
    extends State<IosLiveGreenScreenPublicApiPhysicalSmokeApp> {
  String _status =
      'Starting live green-screen public API harness (default full-frame foreground)...';
  String _currentStep = 'INIT';
  String _phaseLabel = 'INIT';
  VGLiveGreenScreenSession? _session;
  int _eventCount = 0;
  int _phaseElapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  void _updateStatus(String step, String status) {
    if (mounted) {
      setState(() {
        _currentStep = step;
        _status = status;
      });
    }
  }

  void _updateObserveProgress(
    String phaseLabel,
    int elapsedSeconds,
    int totalSeconds,
    int eventCount,
  ) {
    if (mounted) {
      setState(() {
        _phaseLabel = phaseLabel;
        _phaseElapsedSeconds = elapsedSeconds;
        _eventCount = eventCount;
        _status = 'Observing $phaseLabel ($elapsedSeconds/$totalSeconds s)';
      });
    }
  }

  Future<void> _runSmoke() async {
    print(kSmokeStartMarker);
    print('$kFastMetalRequestedMarkerPrefix$kFastMetalRequested');
    print('$kSegmentationBackendRequestedMarkerPrefix$kSegmentationBackendReported');
    print('$kLiveMatteRefinementRequestedMarkerPrefix$kLiveMatteRefinementReported');
    print('$kOverlayPhaseMarkerPrefix$kIncludeOverlayPhase');

    const platform = MethodChannelVGLiveGreenScreenPlatform();

    bool pass = false;
    String? sessionId;
    bool stopped = false;
    Directory? imageFixtureTempDir;
    bool isImageFixtureCleaned = false;
    Map<String, dynamic>? diagnostics;
    Map<String, dynamic>? diagnosticsOptions;
    // WAIT_KEYING_READY outcome: {outcome: ready|degraded|timeout, ...}.
    Map<String, Object?>? keyingReady;
    Map<String, Object?>? keyingProof;
    List<String> keyingProofViolationList = const <String>[];
    final events = <Map<String, dynamic>>[];
    StreamSubscription<VGLiveGreenScreenEvent>? eventsSub;

    final stepResults = <String, String>{};
    final failures = <String>[];

    Future<T> runStep<T>(
      String stepName,
      String description,
      Future<T> Function() action,
    ) async {
      _updateStatus(stepName, description);
      try {
        final result = await action();
        stepResults[stepName] = 'PASS';
        print('IOS_LIVE_GREENSCREEN_PUBLIC_API_STEP_${stepName}_PASS');
        return result;
      } catch (e, st) {
        stepResults[stepName] = 'FAIL';
        final failureMsg = '$stepName: $e';
        if (!failures.contains(failureMsg)) {
          failures.add(failureMsg);
        }
        print('IOS_LIVE_GREENSCREEN_PUBLIC_API_STEP_${stepName}_FAIL: $e\n$st');
        rethrow;
      }
    }

    void skipStep(String stepName, String why) {
      stepResults[stepName] = 'SKIPPED';
      print('IOS_LIVE_GREENSCREEN_PUBLIC_API_STEP_${stepName}_SKIPPED: $why');
    }

    Future<Map<String, dynamic>> readDiagnostics() async {
      final raw = await kDiagnosticsChannel.invokeMapMethod<String, dynamic>(
        kDiagnosticsMethod,
        <String, Object?>{'sessionId': sessionId},
      );
      if (raw == null) {
        throw StateError('$kDiagnosticsMethod returned null');
      }
      return raw;
    }

    Future<void> observePhase(
      String phaseLabel,
      String beginMarker,
      String endMarker,
    ) async {
      print(beginMarker);
      var elapsed = 0;
      while (elapsed < kHoldSeconds) {
        final remaining = kHoldSeconds - elapsed;
        final step = remaining < 1 ? remaining : 1;
        await Future<void>.delayed(Duration(seconds: step));
        elapsed += step;
        _updateObserveProgress(
          phaseLabel,
          elapsed,
          kHoldSeconds,
          events.length,
        );
      }
      print(endMarker);
    }

    try {
      // Subscribe before starting the session so no event is missed.
      eventsSub = VGLiveGreenScreenEvents.stream.listen((event) {
        events.add(<String, dynamic>{
          'type': event.type.name,
          'sessionId': event.sessionId,
          'previousBackend': event.previousBackend,
          'currentBackend': event.currentBackend,
          'reason': event.reason,
          'userMessage': event.userMessage,
        });
      });

      // Step 0: Push the diagnostic-only options for the upcoming start. The
      // native side stores {iosFastMetalPrecision, optional iosSegmentationBackend}
      // for the next start only and rejects the call with live_busy while a
      // session is active, which is why this runs before START. The
      // `iosSegmentationBackend` option is passed only when an explicit override
      // was requested; otherwise the unconfigured native default is left to run.
      // The reply echoes the stored options and is reported verbatim as
      // `diagnosticsOptions`. An unknown backend string is rejected with
      // INVALID_ARG and fails this step (loud, never a silent default).
      await runStep<void>(
        'SET_DIAGNOSTICS_OPTIONS',
        'Setting live green-screen diagnostics options (iosFastMetalPrecision=$kFastMetalRequested${kSegmentationBackendOverrideRequested ? ', iosSegmentationBackend=$kSegmentationBackendRequested' : ''}${kLiveMatteRefinementOverrideRequested ? ', iosLiveMatteRefinement=$kLiveMatteRefinementRequested' : ''})',
        () async {
          final options = <String, Object?>{
            'iosFastMetalPrecision': kFastMetalRequested,
          };
          if (kSegmentationBackendOverrideRequested) {
            options['iosSegmentationBackend'] = kSegmentationBackendRequested;
          }
          if (kLiveMatteRefinementOverrideRequested) {
            options['iosLiveMatteRefinement'] = kLiveMatteRefinementRequested;
          }
          final raw = await kDiagnosticsChannel.invokeMapMethod<String, dynamic>(
            kDiagnosticsOptionsMethod,
            options,
          );
          if (raw == null) {
            throw StateError('$kDiagnosticsOptionsMethod returned null');
          }
          diagnosticsOptions = raw;
          print('$kDiagnosticsOptionsMarkerPrefix${jsonEncode(raw)}');
        },
      );

      // Step 1: Start the session (720x1280 canvas, solid teal background).
      // No foregroundTransform is passed here, so the config uses (and still
      // serializes) VGLiveGreenScreenForegroundTransform.identity — the
      // product default for live camera, meeting, calling, and going-live —
      // proving full-frame natural camera / background replacement, not a
      // shrunk or repositioned overlay.
      final session = await runStep<VGLiveGreenScreenSession>(
        'START',
        'Starting live green-screen session (720x1280, teal, default full-frame identity foreground)',
        () {
          final config = VGLiveGreenScreenConfig(
            canvasSize: const VGGreenScreenSize(720, 1280),
            background: const VGGreenScreenSolidColorBackground(
              kInitialBackgroundArgb,
            ),
          );
          return platform.startLiveGreenScreenSession(config);
        },
      );
      sessionId = session.sessionId;
      if (mounted) {
        setState(() {
          _session = session;
          _phaseLabel = 'DEFAULT (teal, full-frame identity foreground)';
        });
      }

      // Step 1b: Bounded keying readiness poll. Wait for the compositor to
      // consume its first real matte (maskPublishCount > 0) before the first
      // observation window so the reviewer never grades a warm-up frame as
      // the product output. Exits early when the native side has already
      // taken the terminal failure path. The step itself only fails if the
      // diagnostics route fails; timeout/degraded are recorded here and
      // asserted by ASSERT_KEYING_PROOF.
      await runStep<void>(
        'WAIT_KEYING_READY',
        'Waiting for first consumed matte (maskPublishCount > 0, timeout ${kKeyingReadyTimeoutMs}ms)',
        () async {
          final stopwatch = Stopwatch()..start();
          var polls = 0;
          Map<String, dynamic> last = const <String, dynamic>{};
          String outcome = 'timeout';
          while (true) {
            last = await readDiagnostics();
            polls++;
            final maskPublishCount = diagnosticsInt(last, 'maskPublishCount') ?? 0;
            final providerKind = diagnosticsString(last, 'providerKind');
            final isKeyed = last['isKeyed'];
            final degradedEvents = countDegradedEvents(events);
            if (maskPublishCount > 0) {
              outcome = 'ready';
              break;
            }
            if (isKeyed == false ||
                degradedEvents > 0 ||
                (providerKind != null &&
                    kNoProviderKinds.contains(providerKind))) {
              outcome = 'degraded';
              break;
            }
            if (stopwatch.elapsedMilliseconds >= kKeyingReadyTimeoutMs) {
              outcome = 'timeout';
              break;
            }
            await Future<void>.delayed(
              const Duration(milliseconds: kKeyingReadyPollMs),
            );
          }
          stopwatch.stop();
          final result = <String, Object?>{
            'outcome': outcome,
            'reached': outcome == 'ready',
            'elapsedMs': stopwatch.elapsedMilliseconds,
            'polls': polls,
            'timeoutMs': kKeyingReadyTimeoutMs,
            'pollMs': kKeyingReadyPollMs,
            'isKeyed': last['isKeyed'],
            'providerKind': diagnosticsString(last, 'providerKind'),
            'providerMode': diagnosticsString(last, 'providerMode'),
            'segmentationBackend':
                diagnosticsString(last, 'segmentationBackend'),
            'failureReason': diagnosticsString(last, 'failureReason'),
            'terminalReason': diagnosticsString(last, 'terminalReason'),
            'sampleCount': diagnosticsInt(last, 'sampleCount'),
            'maskPublishCount': diagnosticsInt(last, 'maskPublishCount'),
            'firstMaskLatencyMs': diagnosticsDouble(last, 'firstMaskLatencyMs'),
            'degradedEventCount': countDegradedEvents(events),
          };
          keyingReady = result;
          print(
            '${outcome == 'ready' ? kKeyingReadyMarkerPrefix : kKeyingNotReadyMarkerPrefix}${jsonEncode(result)}',
          );
        },
      );

      // Step 2: Observe the default full-frame identity foreground over the
      // initial solid background.
      await runStep<void>(
        'OBSERVE_SOLID',
        'Observing default teal background and full-frame identity foreground (${kHoldSeconds}s)',
        () => observePhase(
          'DEFAULT (teal, full-frame identity foreground)',
          kSolidObserveBeginMarker,
          kSolidObserveEndMarker,
        ),
      );

      // Step 3: Stage the still_C.png fixture from rootBundle into a temp
      // file, ahead of the image background update.
      late final File stillFile;
      await runStep<void>(
        'STAGE_IMAGE_FIXTURE',
        'Staging still_C.png into temp directory',
        () async {
          imageFixtureTempDir = await Directory.systemTemp.createTemp(
            'live_greenscreen_public_api_smoke_',
          );
          stillFile = File('${imageFixtureTempDir!.path}/still_C.png');
          final stillData = await rootBundle.load(kImageBackgroundAssetPath);
          await stillFile.writeAsBytes(
            stillData.buffer.asUint8List(
              stillData.offsetInBytes,
              stillData.lengthInBytes,
            ),
            flush: true,
          );
          if (!await stillFile.exists() || await stillFile.length() == 0) {
            throw StateError('Staged still_C.png fixture missing or empty');
          }
        },
      );

      // Step 4: Update to a static image file background while the default
      // full-frame identity foreground (proven in steps 1-2) is still
      // active — no transform update precedes this step. Proves generic
      // static image background support for live camera/meeting/calling.
      await runStep<void>(
        'UPDATE_BACKGROUND_IMAGE',
        'Updating to static image background (still_C.png, aspectFill) — default full-frame identity foreground still active',
        () => platform.updateLiveGreenScreenBackground(
          sessionId!,
          VGGreenScreenImageFileBackground(
            stillFile.path,
            scaleMode: VGGreenScreenScaleMode.aspectFill,
          ),
        ),
      );
      if (mounted) {
        setState(() {
          _phaseLabel =
              'IMAGE BACKGROUND (still_C.png, full-frame identity foreground)';
        });
      }

      // Step 5: Observe the static image background over the still-active
      // default full-frame identity foreground.
      await runStep<void>(
        'OBSERVE_IMAGE',
        'Observing static image background and full-frame identity foreground (${kHoldSeconds}s)',
        () => observePhase(
          'IMAGE BACKGROUND (still_C.png, full-frame identity foreground)',
          kImageObserveBeginMarker,
          kImageObserveEndMarker,
        ),
      );

      // Steps 6-8 (OPT-IN, LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true only):
      // explicit overlay-style foreground transform (scale 0.45, bottom-left
      // reposition) + green solid background + observation window. This is a
      // route-acceptance proof of an explicit non-default mode and is NEVER
      // green-screen quality proof: a downscaled camera over green is not
      // keyed output. By default the phase is skipped so the whole visual
      // run stays in the full-frame identity foreground.
      if (kIncludeOverlayPhase) {
        // Step 6: Explicitly opt into a non-default overlay-style foreground
        // transform (shrink + bottom-left reposition). Applied after (not
        // before) the image background proof in steps 3-5.
        await runStep<void>(
          'UPDATE_TRANSFORM',
          'Updating to explicit optional overlay-style foreground transform (scale 0.45, bottom-left offset) — not the live default',
          () => platform.updateLiveGreenScreenTransform(
            sessionId!,
            kExplicitOptionalForegroundTransform,
          ),
        );

        // Step 7: Update the solid background to a different color.
        await runStep<void>(
          'UPDATE_BACKGROUND_SOLID',
          'Updating solid background to green',
          () => platform.updateLiveGreenScreenBackground(
            sessionId!,
            const VGGreenScreenSolidColorBackground(kUpdatedBackgroundArgb),
          ),
        );
        if (mounted) {
          setState(() {
            _phaseLabel =
                'EXPLICIT TRANSFORM (green, scale 0.45 overlay — NOT green-screen proof)';
          });
        }

        // Step 8: Observe the updated background + explicit overlay transform.
        await runStep<void>(
          'OBSERVE_UPDATED',
          'Observing updated green background and explicit overlay-style foreground transform (${kHoldSeconds}s) — route proof only',
          () => observePhase(
            'EXPLICIT TRANSFORM (green, scale 0.45 overlay — NOT green-screen proof)',
            kUpdatedObserveBeginMarker,
            kUpdatedObserveEndMarker,
          ),
        );
      } else {
        const why =
            'overlay/PIP phase is opt-in (LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true); default run stays full-frame identity';
        skipStep('UPDATE_TRANSFORM', why);
        skipStep('UPDATE_BACKGROUND_SOLID', why);
        skipStep('OBSERVE_UPDATED', why);
      }

      // Step 9: Read LiteRT matte latency / cadence telemetry for the still
      // active session through the diagnostic-only native route. The step
      // fails only if the route itself fails (missing reply, wrong id, or a
      // PlatformException); the returned timing numbers are reported
      // verbatim and never asserted against thresholds. The keying presence
      // gates are asserted by the next step.
      await runStep<void>(
        'GET_DIAGNOSTICS',
        'Reading live green-screen matte latency diagnostics',
        () async {
          final raw = await readDiagnostics();
          diagnostics = raw;
          print('$kDiagnosticsMarkerPrefix${jsonEncode(raw)}');
          print(
            '$kCameraPresetMarkerPrefix${diagnostics?['cameraSelectedSessionPreset'] ?? 'absent'}',
          );
          print(
            '$kAvgTotalMsMarkerPrefix${diagnostics?['avgTotalMs'] ?? 'absent'}',
          );

          // Split inference spans + precision mode + segmentation backend
          // (reported, never asserted).
          final split = extractLatencySplit(raw);
          final applied = extractFastMetalApplied(raw);
          final backendApplied = kSegmentationBackendOverrideRequested
              ? extractSegmentationBackendApplied(
                  raw,
                  kSegmentationBackendRequested,
                )
              : null;
          print(
            '$kLatencySplitMarkerPrefix${jsonEncode(<String, Object?>{
              'providerKind': raw['providerKind'],
              'providerMode': raw['providerMode'],
              'requestedSegmentationBackend': kSegmentationBackendReported,
              'segmentationBackendOverrideRequested':
                  kSegmentationBackendOverrideRequested,
              'nativeSegmentationBackend': raw['segmentationBackend'],
              'segmentationBackendApplied': backendApplied,
              // Native backend resolution identity (absent on older native
              // builds): which backend was requested natively ("auto" when
              // no override was sent), why the effective backend was chosen,
              // and which engine drives the session ("arkit" | "adapter").
              'nativeRequestedSegmentationBackend':
                  raw['requestedSegmentationBackend'],
              'segmentationBackendSelection':
                  raw['segmentationBackendSelection'],
              'segmentationEngine': raw['segmentationEngine'],
              'requestedLiveMatteRefinement': kLiveMatteRefinementReported,
              'nativeLiveMatteRefinement': raw['liveMatteRefinement'],
              'timingSemantics': raw['timingSemantics'],
              // ARKit engine spans (present only when segmentationEngine is
              // "arkit"; reported, never asserted).
              'avgMatteGenerationMs': raw['avgMatteGenerationMs'],
              'avgCompositeMs': raw['avgCompositeMs'],
              'effectiveFps': raw['effectiveFps'],
              // Model / matte-path echo (litert vs litertSelfie proof; absent
              // on older native builds).
              'modelName': raw['modelName'],
              'mattePath': raw['mattePath'],
              'inputGeometry': raw['inputGeometry'],
              'modelInputWidth': raw['modelInputWidth'],
              'modelInputHeight': raw['modelInputHeight'],
              'modelOutputWidth': raw['modelOutputWidth'],
              'modelOutputHeight': raw['modelOutputHeight'],
              'modelOutputChannels': raw['modelOutputChannels'],
              'requestedFastMetalPrecision': kFastMetalRequested,
              'nativeFastMetalPrecision': raw['fastMetalPrecision'],
              'fastMetalApplied': applied,
              'latencySplit': split,
            })}',
          );
          if (kFastMetalRequested && applied != true) {
            print(
              '$kFastMetalNotAppliedMarker requested=true applied=${applied ?? 'absent'} '
              'providerMode=${raw['providerMode'] ?? 'absent'}',
            );
          }
          if (kSegmentationBackendOverrideRequested && backendApplied != true) {
            print(
              '$kSegmentationBackendNotAppliedMarker requested=$kSegmentationBackendReported '
              'native=${raw['segmentationBackend'] ?? 'absent'} '
              'providerKind=${raw['providerKind'] ?? 'absent'} '
              'providerMode=${raw['providerMode'] ?? 'absent'}',
            );
          }

          // Top-level keying proof fields (asserted by the next step).
          final proof = extractKeyingProof(raw, events);
          keyingProof = proof;
          print('$kKeyingProofMarkerPrefix${jsonEncode(proof)}');
        },
      );

      // Step 9b: Assert the keying proof gates. This is what stops a session
      // that never keyed (terminal provider failure, heuristic-only fallback,
      // no matte consumed, degraded event, or readiness timeout) from being
      // reported as a PASS with a plausible-looking visual run.
      await runStep<void>(
        'ASSERT_KEYING_PROOF',
        'Asserting real keying (isKeyed, providerKind, sampleCount, maskPublishCount, no degraded events, readiness reached)',
        () async {
          final proof = keyingProof;
          if (proof == null) {
            throw StateError('keying proof unavailable (GET_DIAGNOSTICS did not run)');
          }
          final readinessReached = keyingReady?['reached'] == true;
          final violations = keyingProofViolations(
            proof,
            readinessReached: readinessReached,
          );
          keyingProofViolationList = violations;
          if (violations.isNotEmpty) {
            print(
              '$kKeyingProofFailMarker violations=${jsonEncode(violations)} '
              'failureReason=${proof['failureReason'] ?? 'absent'} '
              'terminalReason=${proof['terminalReason'] ?? 'absent'} '
              'providerKind=${proof['providerKind'] ?? 'absent'} '
              'providerMode=${proof['providerMode'] ?? 'absent'} '
              'segmentationBackend=${proof['segmentationBackend'] ?? 'absent'} '
              'readiness=${keyingReady?['outcome'] ?? 'absent'}',
            );
            throw StateError(
              'no real keying in the full-frame proof: ${violations.join('; ')}',
            );
          }
        },
      );

      // Step 10: Stop the session.
      await runStep<void>(
        'STOP',
        'Stopping live green-screen session',
        () async {
          await platform.stopLiveGreenScreenSession(sessionId!);
          stopped = true;
        },
      );

      pass = true;
    } catch (e) {
      pass = false;
    } finally {
      await eventsSub?.cancel();

      // Guaranteed cleanup fallback: stop the session exactly once if the
      // STOP step never ran or never completed.
      if (sessionId != null && !stopped) {
        try {
          await platform.stopLiveGreenScreenSession(sessionId);
          stopped = true;
        } catch (e) {
          print('IOS_LIVE_GREENSCREEN_PUBLIC_API: cleanup stop note: $e');
        }
      }

      // Guaranteed cleanup of the staged image fixture temp directory, even
      // if an earlier step failed before this point was reached.
      if (imageFixtureTempDir != null) {
        try {
          if (await imageFixtureTempDir!.exists()) {
            await imageFixtureTempDir!.delete(recursive: true);
          }
          isImageFixtureCleaned = true;
        } catch (e) {
          print(
            'IOS_LIVE_GREENSCREEN_PUBLIC_API: cleanup image fixture temp dir note: $e',
          );
        }
      } else {
        // No fixture was ever staged, so there is nothing to clean up.
        isImageFixtureCleaned = true;
      }

      final latencySplit = extractLatencySplit(diagnostics);
      final payload = <String, Object?>{
        'pass': pass,
        'proofBoundary': 'ios_live_green_screen_public_api_physical_smoke',
        'holdSeconds': kHoldSeconds,
        'sessionId': sessionId,
        'textureId': _session?.textureId,
        'defaultForegroundTransform': 'identity_full_frame',
        'imageBackgroundAssetPath': kImageBackgroundAssetPath,
        'imageBackgroundPhaseForegroundTransform': 'identity_full_frame',
        'imageFixtureCleaned': isImageFixtureCleaned,
        'overlayPhaseIncluded': kIncludeOverlayPhase,
        'explicitTransformPhase': kIncludeOverlayPhase,
        'overlayPhaseIsGreenScreenProof': false,
        // Keying proof (top level, stable shape; see extractKeyingProof).
        'isKeyed': keyingProof?['isKeyed'],
        'providerKind': keyingProof?['providerKind'],
        'providerMode': keyingProof?['providerMode'],
        'segmentationBackend': keyingProof?['segmentationBackend'],
        'failureReason': keyingProof?['failureReason'],
        'terminalReason': keyingProof?['terminalReason'],
        'terminalState': keyingProof?['terminalState'],
        'sampleCount': keyingProof?['sampleCount'],
        'maskPublishCount': keyingProof?['maskPublishCount'],
        'lastMaskCoveragePercent': keyingProof?['lastMaskCoveragePercent'],
        'degradedEventCount': countDegradedEvents(events),
        'keyingReady': keyingReady,
        'keyingReadyTimeoutMs': kKeyingReadyTimeoutMs,
        'keyingProof': keyingProof,
        'keyingProofViolations': keyingProofViolationList,
        'keyingProofPassed':
            keyingProof != null && keyingProofViolationList.isEmpty,
        'requestedFastMetalPrecision': kFastMetalRequested,
        'requestedSegmentationBackend': kSegmentationBackendReported,
        'segmentationBackendOverrideRequested':
            kSegmentationBackendOverrideRequested,
        'diagnosticsOptions': diagnosticsOptions,
        'nativeFastMetalPrecision': diagnostics?['fastMetalPrecision'],
        'fastMetalApplied': extractFastMetalApplied(diagnostics),
        'nativeSegmentationBackend': diagnostics?['segmentationBackend'],
        'segmentationBackendApplied': kSegmentationBackendOverrideRequested
            ? extractSegmentationBackendApplied(
                diagnostics,
                kSegmentationBackendRequested,
              )
            : null,
        // Native backend resolution identity (absent on older native builds).
        'nativeRequestedSegmentationBackend':
            diagnostics?['requestedSegmentationBackend'],
        'segmentationBackendSelection':
            diagnostics?['segmentationBackendSelection'],
        'segmentationEngine': diagnostics?['segmentationEngine'],
        'avgMatteGenerationMs': diagnostics?['avgMatteGenerationMs'],
        'avgCompositeMs': diagnostics?['avgCompositeMs'],
        'effectiveFps': diagnostics?['effectiveFps'],
        'requestedLiveMatteRefinement': kLiveMatteRefinementReported,
        'liveMatteRefinementOverrideRequested':
            kLiveMatteRefinementOverrideRequested,
        'nativeLiveMatteRefinement': diagnostics?['liveMatteRefinement'],
        'timingSemantics': diagnostics?['timingSemantics'],
        'modelName': diagnostics?['modelName'],
        'mattePath': diagnostics?['mattePath'],
        'inputGeometry': diagnostics?['inputGeometry'],
        'cameraSelectedSessionPreset':
            diagnostics?['cameraSelectedSessionPreset'],
        'avgTotalMs': diagnostics?['avgTotalMs'],
        'latencySplitFieldsPresent': latencySplit != null,
        'latencySplit': latencySplit,
        'diagnostics': diagnostics,
        'stepResults': stepResults,
        'failures': failures,
        'events': events,
        'claimsAllowed': <String>[
          'public Dart API route via VGLiveGreenScreenPlatformInterface (MethodChannelVGLiveGreenScreenPlatform) on iOS',
          'default generic live green-screen start: startLiveGreenScreenSession accepted with default full-frame identity foreground (no explicit foregroundTransform passed; the config identity default is serialized; 720x1280 canvas, solid teal background) proving full-frame natural camera / background replacement as the product default',
          'static image background proof: updateLiveGreenScreenBackground accepted for a VGGreenScreenImageFileBackground (still_C.png staged from rootBundle into a temp file, aspectFill) while the default full-frame identity foreground is still active, proving generic static image background support for live camera/meeting/calling/going-live',
          'keying proof asserted (not merely reported): native diagnostics reported isKeyed true, providerKind neither released nor unavailable, no degraded/fallback event received, sampleCount > 0, maskPublishCount > 0, and keying readiness (first consumed matte) reached before the first observation window',
          'bounded keying readiness poll (WAIT_KEYING_READY) executed before the first observation window with its outcome reported (keyingReady)',
          if (kIncludeOverlayPhase)
            'OPT-IN overlay route proof only (LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true): updateLiveGreenScreenTransform accepted for an overlay-style placement (scale 0.45, bottom-left offset) and updateLiveGreenScreenBackground accepted for a second solid background color (solid green), applied only after the image background proof; the resulting picture-in-picture frame is NOT green-screen output',
          'stopLiveGreenScreenSession accepted',
          if (kIncludeOverlayPhase)
            'bounded live preview texture present for manual observation across the default full-frame identity phase, the static image background phase (still full-frame identity foreground), and the opt-in overlay transform phase (route proof only)'
          else
            'bounded live preview texture present for manual observation across the default full-frame identity phase and the static image background phase (still full-frame identity foreground); no overlay/PIP phase ran',
          'staged image fixture temp file/directory guaranteed cleanup',
          'LiteRT matte latency/cadence telemetry captured on device through the diagnostic-only getLiveGreenScreenDiagnostics route and reported verbatim in the diagnostics map',
          'fast-Metal request (LIVE_GREENSCREEN_IOS_FAST_METAL dart-define) delivered through the diagnostic-only setLiveGreenScreenDiagnosticsOptions route before START, and the native requested/applied precision option, provider mode, and split inference spans (input copy / invoke / output access) reported side by side when present',
          'segmentation backend request (LIVE_GREENSCREEN_IOS_SEGMENTATION_BACKEND dart-define: auto | arkit | litert | visionFast | visionBalanced | visionAccurate | litertSelfie) delivered through the same diagnostic-only setLiveGreenScreenDiagnosticsOptions route before START, and the native echoed backend, requestedSegmentationBackend, segmentationBackendSelection, segmentationEngine, providerKind, providerMode, timingSemantics, modelName, mattePath, inputGeometry, split spans, and ARKit engine spans (avgMatteGenerationMs / avgCompositeMs / effectiveFps) reported side by side so the ARKit ARMatteGenerator engine (native default when supported), the LiteRT/Metal multiclass path, the small selfie model on the same runtime, and Apple Vision person segmentation can be A/B compared on the same harness',
          'live matte refinement native default proof (when no override is passed) proving the unconfigured native default stays "s1"; or explicit opt-in request (LIVE_GREENSCREEN_IOS_LIVE_MATTE_REFINEMENT dart-define: tightAlphaR1) delivered through the same diagnostic-only setLiveGreenScreenDiagnosticsOptions route before START, with the native echoed liveMatteRefinement reported side by side with the request',
        ],
        'nonClaims': <String>[
          'no automated pixel or matte quality proof; the image background step is proved by accepted route/lifecycle/acceptance plus a bounded observation window, not by visual classification; the keying proof gates prove a real person matte was produced and consumed, not that it was accurate',
          'the opt-in overlay/PIP phase (LIVE_GREENSCREEN_INCLUDE_OVERLAY_PHASE=true) is never green-screen quality proof: a scale-0.45 camera over a green background must not be read as keyed output; by default that phase does not run',
          'no latency threshold assertion: timing values (avg/max/min spans, cadence, first-mask latency) are reported, never used to fail the smoke; only the presence gates (sampleCount > 0, maskPublishCount > 0) and the bounded readiness wait are asserted',
          'no fast-Metal assertion: a requested-but-not-applied precision option or absent split fields are reported (fastMetalApplied / latencySplitFieldsPresent), never used to fail the smoke',
          'no segmentation backend assertion: a requested-but-not-applied backend is reported (segmentationBackendApplied false/null), never used to fail the smoke; Vision split spans are request/observation/copy spans, not TFLite tensor spans (see timingSemantics)',
          'no live matte refinement assertion or quality claim: the requested vs native liveMatteRefinement value is reported only, never used to fail the smoke; tightAlphaR1 carries no visual quality proof beyond route acceptance',
          'no video background proof (solid/image background only; video backgrounds remain explicitly not proved/deferred)',
          'no export proof',
          'no recording proof',
          'no audio proof',
          'no Android proof',
          'no all-device or low-end device performance proof',
        ],
      };

      print('$kSmokeJsonPrefix${jsonEncode(payload)}');
      print(pass ? kSmokePassMarker : kSmokeFailMarker);

      if (mounted) {
        setState(() {
          _status = pass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF041F1F),
        body: Stack(
          children: [
            if (session != null)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: session.canvasSize.width.toDouble(),
                    height: session.canvasSize.height.toDouble(),
                    child: Texture(textureId: session.textureId),
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.tealAccent),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.tealAccent, width: 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'iOS Live Green Screen Public API Physical Smoke',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Status: $_status',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      const Text(
                        'Backend: $kSegmentationBackendReported | FastMetal: $kFastMetalRequested | OverlayPhase: $kIncludeOverlayPhase',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      if (session != null)
                        Text(
                          'Session: ${session.sessionId} | Texture ID: ${session.textureId}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      Text(
                        'Phase: $_phaseLabel | Elapsed: ${_phaseElapsedSeconds}s / ${kHoldSeconds}s | Events: $_eventCount',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      if (_currentStep.isNotEmpty)
                        Text(
                          'Step: $_currentStep',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
