# vanguard_media_engine

Vanguard is a high-performance native media engine plugin for Flutter, providing timeline editing, camera capture and filters, hardware-accelerated playback, and streaming media cache capabilities.

All public APIs are exported from `package:vanguard_media_engine/vanguard_media_engine.dart`.

## Public Streaming Compatibility Decision Client (Phase 4C5N / Phase 4C5O)

The package exposes `VGStreamingCompatibilityDecisionClient` as a typed public Dart client to evaluate compatibility decisions combining device video decoder capabilities (AVC/HEVC/AV1) with candidate streaming manifest ladders (HLS/DASH/LL-HLS) before playback without raw `MethodChannel` interaction.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> evaluateStreamCompatibility() async {
  // 1. Instantiate the streaming compatibility decision client
  final client = VGStreamingCompatibilityDecisionClient();

  // 2. Prepare candidate streaming manifest specifications
  final request = VGStreamingCompatibilityDecisionRequest(
    manifests: [
      VGStreamingManifestSpec(
        key: 'hls_stream',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
      ),
      VGStreamingManifestSpec(
        key: 'dash_stream',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
      ),
    ],
  );

  // 3. Evaluate compatibility decisions against real device codec capabilities
  final report = await client.evaluate(request);

  if (report.pass) {
    print('Compatibility decision passed (total reports: ${report.totalReports})');
    print('Codec probe pass: ${report.codecProbePass}, AVC supported: ${report.avcSupported}');
    print('Server ladder policy: ${report.serverLadderPolicy}');
    if (report.hasDeviceWarnings) {
      print('Device warnings: ${report.deviceWarnings}');
    }

    for (final entry in report.reports) {
      print('Stream [${entry.key}]: decision=${entry.decision}, preferred=${entry.preferredCodecFamily}, fallback=${entry.fallbackCodecFamily}');
      print('Safe codecs: ${entry.safeCodecFamilies}, renditions=${entry.renditionCount}, bitrate range=${entry.lowestBandwidth}..${entry.highestBandwidth} bps');
    }
  } else {
    print('Compatibility evaluation failed: ${report.raw}');
  }
}
```

### Guarantees, Invariants & Boundaries

- **Pure Diagnostic Compatibility Brain**: Combines device codec capability probing (`AdaptiveStreamingCodecCapabilityProbe`) with manifest ladder policy validation (`AdaptiveStreamingManifestPolicyValidator`) into safe, deterministic decisions (`prefer_av1_hardware`, `prefer_hevc_hardware`, `prefer_avc_fallback`, `blocked_*`). There is zero `ExoPlayer`/Media3 player allocation, zero `MediaCodec` decoding, zero `Surface`/`ImageReader`/`HardwareBuffer` allocation, and zero playback mutation.
- **Additive Server Ladder Policy (`add_hevc_av1_renditions_but_keep_avc_fallback`)**: Multi-codec streaming ladders must maintain an AVC/H.264 fallback rendition. While HEVC and AV1 renditions provide compression efficiency on supported devices, baseline AVC must remain present so older devices and iOS mirrors do not fail.
- **Advisory Only — Zero Track Selection / ABR Forcing**: The decisions produced by `VGStreamingCompatibilityDecisionClient` are diagnostic and advisory only. They do NOT force Media3 track selection, ABR rendition switching, playback caching, or product feed policies.
- **iOS Parity Expectation & DASH Decision Boundary**: The same public Dart contract (`VGStreamingCompatibilityDecisionClient`, `VGStreamingCompatibilityDecisionRequest`, `VGStreamingCompatibilityDecisionReport`, `VGStreamingCompatibilityDecisionEntry`) will be backed on iOS by AVFoundation/CoreMedia codec capabilities combined with HLS manifest ladders while preserving mandatory AVC fallback; DASH on iOS remains the already-deferred architecture/product decision. Non-Android platforms return typed unsupported reports (`phase: 'unsupported'`, `pass: false`) via `unsupported()` without crashing.

## Public Streaming Manifest Rendition Diagnostics Client (Phase 4C5L / Phase 4C5M)

The package exposes `VGStreamingManifestRenditionClient` as a typed public Dart client to inspect canonical HLS, DASH, and LL-HLS manifest rendition ladders and verify server ladder policies before playback without raw `MethodChannel` interaction.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> inspectCanonicalStreamRenditionLadders() async {
  // 1. Instantiate the streaming manifest rendition diagnostics client
  final client = VGStreamingManifestRenditionClient();

  // 2. Inspect canonical test streams across HLS, DASH, and LL-HLS
  final report = await client.inspectCanonicalStreams();

  if (report.pass) {
    print('Manifest rendition diagnostics passed (total variants: ${report.totalVariantsDiscovered})');
    print('HLS variants: ${report.hlsVariantCount}, DASH representations: ${report.dashRepresentationCount}, LL-HLS variants: ${report.llHlsVariantCount}');
    print('Server ladder policy satisfied: ${report.serverLadderPolicy}');
    print('Mandatory AVC fallback present: ${report.hasAvcFallback}');
    print('Advanced codecs discovered: ${report.hasAnyAdvancedCodecRendition}');
  } else {
    print('Manifest rendition inspection failed: ${report.raw}');
  }
}
```

### Guarantees, Invariants & Boundaries

- **Bounded Manifest-Only Diagnostics**: Inspection fetches remote HLS (`.m3u8`), LL-HLS, and MPEG-DASH (`.mpd`) multivariant manifests over bounded HTTP GETs without downloading media segments, allocating `ExoPlayer`/Media3 players, creating `MediaCodec` decoders, allocating GPU textures/surfaces, or mutating playback.
- **Additive Server Ladder Policy (`add_hevc_av1_renditions_but_keep_avc_fallback`)**: Multi-codec streaming ladders must maintain an AVC/H.264 fallback rendition. While HEVC and AV1 renditions provide compression efficiency on supported devices, baseline AVC must remain present so older devices and iOS mirrors do not fail.
- **Canonical Reference Smoke vs. Arbitrary Host Manifests**: `VGStreamingManifestRenditionClient` wraps the canonical platform smoke suite over built-in reference test streams. It does NOT validate arbitrary production server/CDN endpoints; for validating host-supplied or caller-configured manifest specifications, use `VGStreamingManifestPolicyClient`.
- **Pre-Fetch Segment Rejection**: Enforces pre-fetch security assertions to ensure media segment URLs (`.ts`, `.m4s`, `.mp4`, etc.) are rejected and never fetched during manifest inspection.
- **iOS Parity Expectation & DASH Decision Boundary**: The same public Dart contract (`VGStreamingManifestRenditionClient`, `VGStreamingManifestRenditionReport`, `VGStreamingManifestStreamDiagnostics`, `VGStreamingRenditionInfo`) will be backed on iOS by AVPlayer/HLS manifest inspection while preserving mandatory AVC fallback; DASH on iOS remains the already-deferred architecture/product decision. Non-Android platforms return typed unsupported reports (`phase: 'unsupported'`, `pass: false`) via `unsupported()` without crashing.

## Public Streaming Codec Capability Client (Phase 4C5J / Phase 4C5K)

The package exposes `VGStreamingCodecCapabilityClient` as a typed public Dart client to inspect device streaming decoder capabilities across AVC/H.264, HEVC/H.265, and AV1 before playback without raw `MethodChannel` interaction.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> inspectDeviceCodecCapabilities() async {
  // 1. Instantiate the streaming codec capability client
  final client = VGStreamingCodecCapabilityClient();

  // 2. Probe device video decoders
  final report = await client.probe();

  if (report.pass) {
    print('Codec capability probe passed (SDK ${report.androidSdk})');
    print('AVC supported: ${report.avcSupported}');
    print('HEVC supported: ${report.hevcSupported} (Hardware: ${report.hasHardwareHevc})');
    print('AV1 supported: ${report.av1Supported} (Hardware: ${report.hasHardwareAv1})');
    print('Server ladder policy: ${report.serverLadderPolicy}');
  } else {
    print('Codec capability probe failed: ${report.raw}');
  }
}
```

### Guarantees, Invariants & Boundaries

- **Metadata-Only Codec Inspection**: Probing queries platform decoder metadata via Android `MediaCodecList(MediaCodecList.REGULAR_CODECS)` and `MediaCodecInfo`. There is zero `MediaCodec` allocation, zero video decoding execution, zero ExoPlayer/Media3 player creation, zero network I/O, zero `Surface`/`Image`/`HardwareBuffer` allocation, and zero playback mutation.
- **Additive Server Ladder Policy (`add_hevc_av1_renditions_but_keep_avc_fallback`)**: Server streaming ladders must remain additive: AVC/H.264 fallback is mandatory across all streams. Advanced codecs (HEVC and AV1) provide compression efficiency where supported, but baseline AVC must remain available for compatibility.
- **Advisory / Telemetry Status for HEVC & AV1**: HEVC and AV1 capabilities are reported as advisory telemetry. Absence of HEVC/AV1 or presence of software-only decoders (e.g. `c2.android.av1-dav1d.decoder` without hardware acceleration) does NOT cause probe failure as long as baseline AVC decoder support is confirmed.
- **iOS Parity Expectation**: The same public Dart contract (`VGStreamingCodecCapabilityClient`, `VGStreamingCodecCapabilityReport`, `VGStreamingCodecInfo`) will be backed on iOS by `AVFoundation` / `CoreMedia` / `VideoToolbox` capability queries while preserving baseline H.264 fallback. Non-Android platforms return typed unsupported reports (`phase: 'unsupported'`, `pass: false`) via `unsupported()` without crashing.

## Public Streaming Manifest Policy Validation Client (Phase 4C5H / Phase 4C5I)

The package exposes `VGStreamingManifestPolicyClient` as a typed public Dart client to validate candidate HLS, DASH, and LL-HLS multivariant manifest ladders against server ladder policies before playback without raw `MethodChannel` interaction.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> validateCandidateManifests() async {
  // 1. Instantiate the streaming manifest policy client
  final client = VGStreamingManifestPolicyClient();

  // 2. Prepare candidate manifest specifications
  final request = VGStreamingManifestPolicyValidationRequest(
    manifests: [
      VGStreamingManifestSpec(
        key: 'hls_stream',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
      ),
      VGStreamingManifestSpec(
        key: 'dash_stream',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
      ),
    ],
  );

  // 3. Validate candidate manifests against server ladder policy
  final report = await client.validate(request);

  if (report.pass) {
    print('Manifest policy validation passed: ${report.serverLadderPolicy}');
    print('Total validated: ${report.totalManifestsValidated}');
  } else {
    print('Manifest policy validation failed: ${report.raw}');
  }
}
```

### Guarantees, Invariants & Boundaries

- **Manifest-Only Validation**: Validation inspects only multivariant playlist tags and DASH MPD representation structures. There is zero playback session allocation, zero ExoPlayer/Media3 player creation, zero MediaCodec decoding, zero surface allocation, zero segment fetching beyond bounded manifest inspection, and no ABR forcing.
- **Server Ladder Policy Enforcement**: Enforces the additive server ladder policy: `add_hevc_av1_renditions_but_keep_avc_fallback`. If HEVC or AV1 renditions are present, an AVC/H.264 fallback rendition remains mandatory.
- **Pre-Fetch Segment Rejection**: Enforces pre-fetch security assertions to ensure media segment URLs are rejected and never fetched during manifest inspection.
- **iOS Parity Expectation**: The same public Dart contract (`VGStreamingManifestPolicyClient`, `VGStreamingManifestPolicyValidationRequest`, `VGStreamingManifestPolicyValidationReport`) will be backed on iOS by AVFoundation/HLS manifest validation preserving AVC fallback; DASH on iOS remains the already-deferred architecture/product decision. Non-Android platforms return typed unsupported reports (`phase: 'unsupported'`, `pass: false`) via `fromMap`/`unsupported()` without crashing.

## Public Streaming Playback Status Poller (Phase 4C7AC / Phase 4C7AD / Phase 4C7AE / Phase 4C7AG / Phase 4C7AH)

The package exposes `VGStreamingPlaybackStatusPoller` as a pure Dart periodic polling helper over `VGStreamingPlaybackController`. It periodically refreshes controller telemetry, converts snapshots into immutable `VGStreamingPlaybackStatusSummary` objects, and emits them over a broadcast stream without busy-polling collisions.

### Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class StreamingPlayerWidget extends StatefulWidget {
  final VGStreamingPlaybackController controller;
  const StreamingPlayerWidget({super.key, required this.controller});

  @override
  State<StreamingPlayerWidget> createState() => _StreamingPlayerWidgetState();
}

class _StreamingPlayerWidgetState extends State<StreamingPlayerWidget> {
  late final VGStreamingPlaybackStatusPoller _poller;
  StreamSubscription<VGStreamingPlaybackStatusSummary>? _sub;
  VGStreamingPlaybackStatusSummary _summary =
      const VGStreamingPlaybackStatusSummary.empty();

  @override
  void initState() {
    super.initState();
    // 1. Create poller with optional configuration
    _poller = VGStreamingPlaybackStatusPoller(
      controller: widget.controller,
      config: VGStreamingPlaybackStatusPollerConfig(
        interval: const Duration(milliseconds: 500),
        emitInitialSummary: true,
      ),
    );

    // 2. Listen to broadcast stream
    _sub = _poller.summaries.listen((summary) {
      setState(() {
        _summary = summary;
      });
    });

    // 3. Start periodic polling
    _poller.start();
  }

  @override
  void dispose() {
    // 4. Stop and dispose poller with UI lifecycle (does NOT dispose controller)
    _sub?.cancel();
    _poller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LinearProgressIndicator(value: _summary.progressFraction),
        Text('Position: ${_summary.positionMs}ms / ${_summary.durationMs}ms'),
      ],
    );
  }
}
```

### Invariants & Non-Claims

- **Protocol Neutrality Across HLS, DASH, and LL-HLS**: The exact same `VGStreamingPlaybackStatusPoller` API operates identically across HLS, DASH, and LL-HLS streams on Android. Physical verification proves polling, summary derivation, and real playback progress / render evidence (`renderedFrames > 0`, `isPlaying == true`, `positionMs > 0`, or `bufferedPositionMs > 0`) are protocol-agnostic rather than relying solely on initial buffering metadata.
- **Media3 Adaptive Engine Ownership**: AndroidX Media3 retains full ownership of underlying manifest parsing, adaptive bitrate (ABR) switching, buffering policies, network connection management, and segment loading.
- **Controller Ownership**: `VGStreamingPlaybackStatusPoller` does NOT own or dispose the underlying `VGStreamingPlaybackController`. The poller should be stopped and disposed by the host UI widget lifecycle.
- **Convenience Only**: The poller makes no product feed decisions, no retry policy, no ABR decisions, no caching policy, and makes no native lifecycle decisions.
- **Cache-Read Observability**: When playback cache is enabled on the active source descriptor, status poller summaries (`VGStreamingPlaybackStatusSummary`) seamlessly convey cache-read telemetry (`playbackCacheBytesRead`, `playbackCacheSizeBytes`, `playbackCacheIgnoredCount`, `playbackCacheReadObserved`, `playbackCacheTelemetryAttached`). This provides UI/diagnostics observation only: it does not make ABR or cache policy decisions, does not perform feed prediction or prefetching algorithms, and does not apply to WebRTC/LiveKit caching.
- **Concurrency Guard**: If a refresh tick is in flight, overlapping periodic ticks are skipped to prevent concurrent native channel calls.
- **iOS Parity & DASH Decision Boundary**: Because `VGStreamingPlaybackStatusPoller` is written entirely in pure Dart and operates on public controller and summary interfaces, it works automatically on iOS as soon as the iOS backend populates the matching session fields. DASH on iOS remains the already-deferred product/architecture decision; the Dart poller remains reusable once iOS fills session fields.

## Public Streaming Playback Status Summary Helper (Phase 4C7AA / Phase 4C7AB)

The package exposes `VGStreamingPlaybackStatusSummary` as a pure Dart immutable summary object providing safe, UI-friendly telemetry for progress bars, buffer indicators, live vs. VOD distinction, display dimensions, and cache-read observability.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// Derive from controller snapshot:
final summary = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(controller.snapshot);

// Or derive directly from a session:
// final summary = VGStreamingPlaybackStatusSummary.fromSession(session);

// Safe UI consumption:
final double progress = summary.progressFraction;   // Clamped 0.0..1.0 (0.0 for live / non-positive duration)
final double buffered = summary.bufferedFraction;   // Clamped 0.0..1.0
final bool isLive = summary.isLive;                 // true if liveOffsetMs != null or durationMs < 0
final bool isSeekable = summary.isSeekable;         // true only for positive VOD duration
final bool isPlaying = summary.isPlaying;
final bool isBuffering = summary.isBufferingOrOpening;
final bool isTerminal = summary.isTerminal;

// Telemetry & cache observability:
if (summary.playbackCacheReadObserved) {
  print('Cache bytes read: ${summary.playbackCacheBytesRead} / ${summary.playbackCacheSizeBytes}');
}
```

### Invariants & Non-Claims

- **Convenience / Read Model Only**: `VGStreamingPlaybackStatusSummary` is purely a derived presentation and status helper. It makes no product feed decisions, no ABR rendition selections, no retry policy, no caching policy, and triggers no platform channel mutations.
- **Defensive Telemetry Clamping**: Out-of-bounds metrics (negative positions, overflow percentages, negative cache byte counters) are defensively sanitized and clamped to their valid ranges.
- **iOS Parity Expectation**: Because `VGStreamingPlaybackStatusSummary` is written entirely in pure Dart and operates on `VGStreamingPlaybackSession` / `VGStreamingPlaybackControllerSnapshot`, the exact same summary helper works automatically on iOS as soon as the iOS backend populates the matching session fields.

## Public Streaming Playback Health Advisor (Phase 4C7AI / Phase 4C7AJ)

The package exposes `VGStreamingPlaybackHealthAdvisor` as a pure Dart advisory helper that combines `VGStreamingPlaybackStatusSummary` streams, historical buffer samples, and optional `VGStreamingPreflightReport` preflight results to provide actionable, typed health guidance (`VGStreamingPlaybackHealthAdvice`) for mobile applications operating over poor, choppy, or degraded networks.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void checkPlaybackHealth({
  required VGStreamingPlaybackStatusSummary currentSummary,
  required List<VGStreamingPlaybackStatusSummary> recentSummaries,
  VGStreamingPreflightReport? preflightReport,
}) {
  // 1. Construct immutable health advisor request
  final request = VGStreamingPlaybackHealthAdvisorRequest(
    current: currentSummary,
    recent: recentSummaries,
    preflightReport: preflightReport,
    currentNetworkProfile: VGStreamingNetworkProfile.auto,
    lowBufferPercentThreshold: 15,
    lowBufferMsThreshold: 2000,
    repeatedBufferingCountThreshold: 2,
    stalledPositionCountThreshold: 3,
  );

  // 2. Evaluate health advisory
  final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

  // 3. Act on typed guidance in UI or product policy
  print('Severity: ${advice.severity}');                 // healthy, watch, degraded, stalled, terminal
  print('Recommended Action: ${advice.recommendedAction}'); // keepCurrentProfile, preferConstrainedProfile, leaveLowLatency, waitForBuffer, retryPlayback, doNotRetryTerminal
  print('Recommended Profile: ${advice.recommendedNetworkProfile}'); // auto, stable, constrained, lowLatency
  print('Should Leave Low Latency: ${advice.shouldLeaveLowLatency}');
  print('Should Retry: ${advice.shouldRetry}');
  print('Reasons: ${advice.reasons}');
}
```

### Invariants, Scope & Network Policy Guidance

- **UI & Product Policy Only**: `VGStreamingPlaybackHealthAdvisor` is strictly a pure Dart diagnostic and decision helper. It does not own the player, mutate playback, reopen streams, touch the cache substrate, force rendition tracks, or control product feed ranking.
- **Media3 Owns ABR**: AndroidX Media3 / ExoPlayer remains the authoritative ABR and playback engine. The advisor provides high-level network profile hints (`VGStreamingNetworkProfile`) and UI recommendations rather than manipulating individual segment requests.
- **Poor-Network Strategy**: On rough, high-jitter, or bandwidth-constrained mobile networks, applications should favor standard HLS/DASH streams with `VGStreamingNetworkProfile.constrained` over Apple LL-HLS (`lowLatency`), which operates with shallow buffer depths and higher rebuffering risk, unless explicit low-latency live interaction is strictly required by the product.
- **iOS Parity Expectation**: Because `VGStreamingPlaybackHealthAdvisor` is written in pure Dart and operates on public summary and preflight data structures, it behaves identically across platforms without native code dependencies.

## Public Streaming Playback Recovery Planner (Phase 4C7AK / Phase 4C7AL)

The package exposes `VGStreamingPlaybackRecoveryPlanner` as a pure Dart helper that transforms health advice (`VGStreamingPlaybackHealthAdvice`), playback status (`VGStreamingPlaybackStatusSummary`), and active session options (`VGStreamingPlaybackOptions`) into a typed, immutable host recovery plan (`VGStreamingPlaybackRecoveryPlan`) without mutating playback or calling platform channels.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void planPlaybackRecovery({
  required VGStreamingPlaybackHealthAdvice advice,
  VGStreamingPlaybackStatusSummary? currentStatus,
  VGStreamingPlaybackOptions? currentOptions,
}) {
  // 1. Construct immutable recovery plan request
  final request = VGStreamingPlaybackRecoveryPlanRequest(
    advice: advice,
    currentStatus: currentStatus,
    currentOptions: currentOptions,
    allowAutomaticRetry: false,
    retryDelayMs: 750,
    preserveCacheOptions: true,
  );

  // 2. Synthesize typed recovery plan
  final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

  // 3. Inspect typed recovery instructions
  print('Intent: ${plan.intent}');                   // none, waitForBuffer, retryCurrentProfile, retryConstrainedProfile, reopenStandardLatency, stopTerminal
  print('Urgency: ${plan.urgency}');                 // none, passive, active, immediate
  print('Should Reopen: ${plan.shouldReopenPlayback}');
  print('Requires Host Action: ${plan.requiresHostAction}');
  print('Can Build Options: ${plan.canBuildPlaybackOptions}');
  print('Resume Position: ${plan.resumePositionMs}ms');
  print('Retry Delay: ${plan.retryDelayMs}ms');

  // 4. If host chooses to act, use cloned and adjusted playback options
  if (plan.shouldReopenPlayback && plan.playbackOptions != null) {
    // e.g. controller.open(plan.playbackOptions!) or playbackClient.open(plan.playbackOptions!)
  }
}
```

### Invariants & Architectural Boundaries

- **Pure Advisory Helper**: `plan.advisoryOnly == true` and `plan.playbackMutation == false`. The recovery planner never calls `VGStreamingPlaybackClient.open`, `play`, `pause`, `stop`, `dispose`, or cache APIs.
- **Product Ownership**: The host application retains full ownership over when, whether, and how to execute playback retries, stream switches, and user-facing recovery indicators.
- **Option Cloning & Cache Preservation**: When options are provided, the planner safely clones options with adjusted network profiles (`constrained`, `stable`) while preserving format hints, headers, geometry, and cache options when requested.
- **Live vs. VOD Resume Logic**: For VOD streams (`isLive == false`), the planner preserves current playhead position as the resume point. For live streams, resume position remains `null` to automatically track the live edge unless an explicit override is provided.
- **iOS Parity**: Pure Dart implementation over public models runs identically on iOS without platform code dependencies.

## Public Streaming Playback Resilience Monitor (Phase 4C7AM / Phase 4C7AN / Phase 4C7AO / Phase 4C7AP)

The package exposes `VGStreamingPlaybackResilienceMonitor` as a pure Dart resilience stream monitor. It consumes a `Stream<VGStreamingPlaybackStatusSummary>` (such as from `VGStreamingPlaybackStatusPoller.summaries`), maintains a bounded chronological history, evaluates real-time health advice via `VGStreamingPlaybackHealthAdvisor`, and synthesizes host recovery plans via `VGStreamingPlaybackRecoveryPlanner` into composite resilience snapshots (`VGStreamingPlaybackResilienceSnapshot`).

### Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void monitorPlaybackResilience({
  required Stream<VGStreamingPlaybackStatusSummary> summaryStream,
  VGStreamingPlaybackOptions? currentOptions,
}) {
  // 1. Instantiate the resilience monitor with optional config
  final monitor = VGStreamingPlaybackResilienceMonitor(
    summaries: summaryStream,
    config: VGStreamingPlaybackResilienceMonitorConfig(
      maxHistoryLength: 8,
      currentNetworkProfile: VGStreamingNetworkProfile.auto,
      currentOptions: currentOptions,
      allowAutomaticRetry: false,
      retryDelayMs: 750,
      preserveCacheOptions: true,
    ),
  );

  // 2. Listen to broadcast stream of composite resilience snapshots
  final subscription = monitor.snapshots.listen((snapshot) {
    print('Severity: ${snapshot.healthAdvice.severity}');
    print('Recommended Action: ${snapshot.healthAdvice.recommendedAction}');
    print('Recovery Intent: ${snapshot.recoveryPlan.intent}');
    print('Urgency: ${snapshot.recoveryPlan.urgency}');
    print('History Depth: ${snapshot.historyLength}');
    print('Reasons: ${snapshot.reasons}');

    if (snapshot.recoveryPlan.shouldReopenPlayback &&
        snapshot.recoveryPlan.playbackOptions != null) {
      // Host application can safely act on the adjusted options
    }
  });

  // 3. Start monitoring
  monitor.start();

  // 4. Teardown with widget / controller lifecycle
  // subscription.cancel();
  // monitor.dispose();
}
```

### Physical Verification & Lifecycle Boundaries (Phase 4C7AO / Phase 4C7AP)

The resilience monitor is physically verified on real Android hardware (`SM-A566B` / `RRGL207K8GB` on Android 16 API 36) via `example/lib/android_streaming_resilience_monitor_public_api_physical_smoke.dart`, exercising the full composition chain:
`VGStreamingSourceSet` -> `VGStreamingPreflightClient` -> `VGStreamingPlaybackDecisionPlanner` -> `VGStreamingPlaybackController` -> `VGStreamingPlaybackTextureView` -> `VGStreamingPlaybackStatusPoller` -> `VGStreamingPlaybackResilienceMonitor` -> `VGStreamingPlaybackHealthAdvice` + `VGStreamingPlaybackRecoveryPlan`.

- **Lifecycle Decoupling & Independent Teardown**: Monitor disposal closes its output stream and cancels its input subscription without disposing or altering the underlying `VGStreamingPlaybackStatusPoller` or `VGStreamingPlaybackController`. Similarly, poller disposal does not dispose the underlying controller.
- **Pure Advisory Invariants**: All evaluated snapshots strictly guarantee `snapshot.advisoryOnly == true`, `snapshot.playbackMutation == false`, `healthAdvice.advisoryOnly == true`, `healthAdvice.playbackMutation == false`, `recoveryPlan.advisoryOnly == true`, and `recoveryPlan.playbackMutation == false`.

### Invariants & Non-Claims

- **Pure Dart Stream Monitor**: `snapshot.advisoryOnly == true` and `snapshot.playbackMutation == false`. The resilience monitor does not own or dispose the player, does not own `VGStreamingPlaybackController` or `VGStreamingPlaybackStatusPoller`, does not call `MethodChannel` or native code, and does not automatically retry or reopen playback.
- **Media3 ABR Engine Ownership**: AndroidX Media3 retains sole ownership over underlying segment fetching and adaptive bitrate track switching. The monitor evaluates telemetry trends and suggests macro network profile adjustments.
- **Product Recovery Control**: The host application retains complete authority over executing recovery actions and presenting user-facing recovery indicators.
- **Error Resilience & Safe Disposal**: Input stream errors are recorded in snapshot diagnostics without throwing or terminating the monitor. Disposed monitors safely ignore further emissions and can be disposed idempotently.
- **iOS Parity**: Pure Dart implementation over public streaming models runs identically on iOS without native code dependencies.

## Public Streaming Playback Retry Budget Planner (Phase 4C7AQ / Phase 4C7AR)

The package exposes `VGStreamingPlaybackRetryBudgetPlanner` as a pure Dart advisory helper that bounds playback retries over a rolling time window with minimum cooldown delays to prevent infinite retry loops and runaway network usage on mobile devices over poor or degraded networks.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void checkRetryBudget({
  required VGStreamingPlaybackRecoveryPlan recoveryPlan,
  required List<VGStreamingPlaybackRetryAttempt> recentAttempts,
  String? streamKey,
}) {
  // 1. Construct immutable retry budget request with deterministic timestamp
  final request = VGStreamingPlaybackRetryBudgetRequest(
    recoveryPlan: recoveryPlan,
    recentAttempts: recentAttempts,
    config: const VGStreamingPlaybackRetryBudgetConfig(
      maxAttempts: 3,
      windowMs: 120000, // 2-minute rolling window
      minimumDelayMs: 750, // 750 ms minimum cooldown
      blockTerminalStop: true,
      requirePlaybackOptionsForReopen: true,
      requireHostActionRespect: true, // Default: blocks automatic retry when host action is required
    ),
    nowMs: DateTime.now().millisecondsSinceEpoch,
    streamKey: streamKey,
  );

  // 2. Evaluate retry budget decision
  final result = VGStreamingPlaybackRetryBudgetPlanner.evaluate(request);

  // 3. Inspect typed decision and telemetry
  print('Decision: ${result.decision}'); // allow, delay, block, notRetryable
  print('Can Retry: ${result.canRetry}'); // true only if allow
  print('Attempts in Window: ${result.attemptsInWindow}');
  print('Remaining Attempts: ${result.remainingAttempts}');
  print('Retry After: ${result.retryAfterMs}ms');
  print('Reasons: ${result.reasons}');

  // 4. Act according to host application policy
  switch (result.decision) {
    case VGStreamingPlaybackRetryBudgetDecision.allow:
      // Record attempt and execute recovery plan reopening
      break;
    case VGStreamingPlaybackRetryBudgetDecision.delay:
      // Schedule cooldown timer before retrying (wait result.retryAfterMs)
      break;
    case VGStreamingPlaybackRetryBudgetDecision.block:
      // Budget exhausted, blocked, or host action required; show user fallback UI
      break;
    case VGStreamingPlaybackRetryBudgetDecision.notRetryable:
      // Plan does not support retry (terminal stop, passive wait, healthy)
      break;
  }
}
```

### Invariants, Scope & Non-Claims

- **Pure Advisory Helper**: `result.advisoryOnly == true` and `result.playbackMutation == false`. `VGStreamingPlaybackRetryBudgetPlanner` never executes retries, never opens/stops sessions, never creates timers/clocks, never mutates `recentAttempts`, and calls zero native platform channels.
- **Host Action Respect Guard**: By default (`requireHostActionRespect == true`), the retry budget will not authorize automatic retry (`decision == block`, `canRetry == false`, reason `hostActionRequired` / code `host_action_required`) when the upstream recovery plan requires host action (`recoveryPlan.requiresHostAction == true`). Product code must opt out of this guard (`requireHostActionRespect: false`) only when it is deliberately executing the host-approved action.
- **Product Ownership**: The host application owns recording `VGStreamingPlaybackRetryAttempt` instances, scheduling retry timers, and determining user recovery presentation.
- **Deterministic & Pure**: All evaluations are synchronous functions of `nowMs`, `recentAttempts`, `config`, and `recoveryPlan`.
- **Stream Key Isolation**: Optional `streamKey` scoping enables per-stream budget tracking across multi-stream feeds.
- **iOS Parity**: Pure Dart implementation over public streaming models runs identically on iOS without native platform code dependencies.

## Public Streaming Playback Retry Attempt Journal (Phase 4C7AS / Phase 4C7AT)

The package exposes `VGStreamingPlaybackRetryJournal` as a pure Dart in-memory journal helper for recording, pruning, snapshotting, and evaluating streaming playback retry attempts (`VGStreamingPlaybackRetryAttempt`) with `VGStreamingPlaybackRetryBudgetPlanner` without manual bookkeeping or custom list pruning logic.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void manageRetryJournal({
  required VGStreamingPlaybackRecoveryPlan recoveryPlan,
}) {
  // 1. Instantiate in-memory journal with optional config
  final journal = VGStreamingPlaybackRetryJournal(
    config: const VGStreamingPlaybackRetryJournalConfig(
      maxStoredAttempts: 32,
      defaultWindowMs: 120000, // 2-minute default pruning window
    ),
  );

  final nowMs = DateTime.now().millisecondsSinceEpoch;

  // 2. Evaluate retry budget directly via journal
  final budgetResult = journal.evaluateBudget(
    recoveryPlan: recoveryPlan,
    nowMs: nowMs,
    streamKey: 'stream_primary',
  );

  if (budgetResult.canRetry) {
    // 3. Record attempt into journal when executing retry
    journal.recordNow(
      nowMs: nowMs,
      intent: recoveryPlan.intent,
      streamKey: 'stream_primary',
      reason: 'rebuffer_timeout',
    );
  }

  // 4. Prune expired attempts older than rolling window
  journal.prune(nowMs: nowMs);

  // 5. Inspect immutable journal snapshot
  final snapshot = journal.snapshot(streamKey: 'stream_primary');
  print('Attempts for stream: ${snapshot.count}');
}
```

### Invariants & Boundaries

- **Pure In-Memory Helper**: `snapshot.advisoryOnly == true` and `snapshot.playbackMutation == false`. `VGStreamingPlaybackRetryJournal` owns only an in-memory `List<VGStreamingPlaybackRetryAttempt>`, never writes to disk, never runs background timers, never mutates playback, and calls zero native platform channels.
- **Deterministic Time**: Clocks are caller-provided (`nowMs`); the journal never reads system clocks internally.
- **Defensive JSON Import**: `VGStreamingPlaybackRetryJournal.fromJson` defensively parses valid attempt maps and silently skips malformed items without throwing exceptions.
- **iOS Parity**: Pure Dart implementation over public streaming models runs identically on iOS without native platform code dependencies.

## Cached Streaming Playback All-Up Integration Recipe

The package provides end-to-end composition across bounded cache prewarming, manifest preflight capability evaluation, startup decision planning, session-safe controller management, presentation via `VGStreamingPlaybackTextureView`, and snapshot-level playback timing and buffer telemetry.

### Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> prewarmAndPlayCachedStream() async {
  // 1. Define candidate stream sources with cache options
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
      ),
      VGStreamingSourceDescriptor(
        key: 'dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
      ),
    ],
  );

  // 2. Synthesize and dispatch bounded cache prewarm request
  final cacheClient = VGStreamingCacheClient();
  final prewarmPlan = VGStreamingCachePrewarmPlanner.planForSourceSet(
    sourceSet: sourceSet,
    requestIdPrefix: 'feed_prewarm',
    sourceKeys: const ['hls'],
    maxBytes: 2 * 1024 * 1024,
    lowLatencyPolicy: VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
  );

  if (prewarmPlan.requests.isNotEmpty) {
    await cacheClient.prewarmRequest(prewarmPlan.requests.first);
  }

  // 3. Evaluate preflight capabilities under network constraints
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    sourceSet.toPreflightRequest(
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 4. Plan playback decision using pure-Dart planner
  final decision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: preflightReport,
      preference: VGStreamingSourceSelectionPreference.preserveOrder,
      preferredKeys: const ['hls'],
    ),
  );

  // 5. Open session via playback controller
  final controller = VGStreamingPlaybackController();
  final snapshot = await controller.open(decision, startPlayback: true);

  if (!snapshot.pass || snapshot.textureId == null) {
    print('Playback failed to open: ${snapshot.reason}');
    return;
  }

  // 6. Presentation via VGStreamingPlaybackTextureView
  // (e.g. VGStreamingPlaybackTextureView(snapshot: snapshot))

  // 7. Poll and read snapshot-level timing, buffer, and cache event telemetry
  final refreshed = await controller.refresh();
  if (refreshed.hasPlaybackTelemetry) {
    print(
      'Cached playback telemetry: duration=${refreshed.durationMs}ms, '
      'position=${refreshed.positionMs}ms, '
      'buffered=${refreshed.bufferedPercent}% (${refreshed.bufferedPositionMs}ms ahead), '
      'liveOffset=${refreshed.liveOffsetMs}, '
      'cacheEnabled=${refreshed.playbackCacheEnabled}, '
      'cacheBytesRead=${refreshed.playbackCacheBytesRead}B, '
      'cacheSizeBytes=${refreshed.playbackCacheSizeBytes}B, '
      'cacheIgnoredCount=${refreshed.playbackCacheIgnoredCount}',
    );
  }

  // 8. Control media lifecycle
  await controller.pause();
  await controller.play();
  await controller.stop();
  await controller.dispose();
}
```

### Verification & Invariants

- **Composition & Telemetry Proof**: Proves end-to-end composition across cache prewarm (`VGStreamingCacheClient`), preflight capability evaluation (`VGStreamingPreflightClient`), decision planning (`VGStreamingPlaybackDecisionPlanner`), controller facade (`VGStreamingPlaybackController`), presentation (`VGStreamingPlaybackTextureView`), snapshot timing/buffer telemetry, and native Media3 `CacheDataSource.EventListener` cache event telemetry.
- **Cache Hit Scope**: Proves public API composition, prewarm completion, and actual cache-read byte reporting via Media3 `CacheDataSource.EventListener`. Does not guarantee every subsequent ABR rendition or segment is cached (Media3 owns ABR / segment loading).
- **ABR Ownership**: Media3 runtime still owns ABR rendition selection.
- **ConnectsApp & Platform Boundaries**: Zero ConnectsApp feed prediction wiring; iOS cache backend remains planned and frozen in UMF architecture documents.

## Streaming Playback Texture View Widget Recipe

The package exposes `VGStreamingPlaybackTextureView` as a presentation-only Flutter widget that renders the active session texture from a `VGStreamingPlaybackControllerSnapshot`. It automatically manages aspect ratio preservation via `FittedBox`, letterboxing/pillarboxing background color, placeholder builder, and error builder callbacks.

### Quick Start

```dart
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Widget buildStreamingView(VGStreamingPlaybackControllerSnapshot snapshot) {
  return VGStreamingPlaybackTextureView(
    snapshot: snapshot,
    fit: BoxFit.contain,
    alignment: Alignment.center,
    backgroundColor: Colors.black,
    placeholderBuilder: (context, snap) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Text('Loading stream (${snap.reason})...'),
      );
    },
    errorBuilder: (context, snap) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Text('Stream failed: ${snap.lastError ?? snap.reason}'),
      );
    },
  );
}
```

### Orientation & Display Dimension Handling (Phases 4C7S, 4C7T, 4C7U, 4C7V)

`VGStreamingPlaybackTextureView` consumes `session.effectiveDisplayWidth` and `session.effectiveDisplayHeight` rather than raw encoded video dimensions. This automatically preserves display aspect ratio when explicit display dimensions (`displayWidth`, `displayHeight`) or cardinal rotation angles (`rotationDegrees` of 90° or 270°) are reported by the session.

- **Display-Canvas Convention & Native Metadata Propagation (Phase 4C7U)**: Android streaming playback aligns with local playback's proven display-canvas convention:
  - Encoded dimensions (`videoWidth`, `videoHeight`) remain video stream metadata and size the decoder output bridge (`HttpAdaptiveImageReaderBridge`).
  - Display dimensions (`displayWidth`, `displayHeight` / `effectiveDisplayWidth`, `effectiveDisplayHeight`) configure the Flutter `SurfaceProducer.setSize` texture buffer and drive the native True-DAG render canvas (`renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration` width/height and Vulkan vertex shader push constants).
  - Media3 track format reads `player.videoFormat?.rotationDegrees`, normalizes cardinal values (0°, 90°, 180°, 270°), computes display dimensions, forwards them to the listener, and renders each frame with the native rotation transform.
- **Official Platform Baseline**:
  - Android `MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION` retrieves video rotation angle in degrees (values: 0, 90, 180, 270).
  - Android `MediaFormat.KEY_ROTATION` describes clockwise rotation on an output surface for surface-configured codecs (supported values: 0, 90, 180, 270; default: 0).
  - Media3 `Format.rotationDegrees` specifies clockwise rotation to apply for correct orientation (values: 0, 90, 180, 270).
  - Media3 `VideoSize.unappliedRotationDegrees` is deprecated (handled internally by player, returning 0).
- **Metadata vs. Visual Proof Boundary**: Phase 4C7U/4C7V closes orientation and display metadata propagation and diagnostic reporting across all streaming formats. Current physical streams are 0-degree, so arbitrary rotated stream visual proof still needs a rotated streaming fixture.
- **iOS Parity**: The iOS implementer will mirror these public fields (`rotationDegrees`, `displayWidth`, `displayHeight`) using AVFoundation track and video output metadata (`AVAssetTrack.preferredTransform`, display dimensions).

## Streaming Playback Controller Facade Recipe

The package exposes `VGStreamingPlaybackController` as a bounded, session-safe Dart facade over `VGStreamingPlaybackClient` and `VGStreamingPlaybackDecision`. It serializes operations with a private busy guard, owns exactly one active playback session at a time, and provides high-level control (`open`, `play`, `pause`, `seek`, `refresh`, `stop`, `dispose`).

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> controlStreamingPlayback() async {
  // 1. Define candidate stream sources in a source set
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'primary_hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
      VGStreamingSourceDescriptor(
        key: 'backup_dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
    ],
  );

  // 2. Synthesize preflight request from source set and evaluate
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    sourceSet.toPreflightRequest(
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 3. Plan playback decision using pure-Dart planner
  final decision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: preflightReport,
      preference: VGStreamingSourceSelectionPreference.preserveOrder,
      preferredKeys: const ['primary_hls'],
    ),
  );

  // 4. Create controller and open session
  final controller = VGStreamingPlaybackController();
  final snapshot = await controller.open(decision, startPlayback: true);

  if (!snapshot.pass || snapshot.textureId == null) {
    print('Playback failed to open: ${snapshot.reason}');
    return;
  }

  // Render Texture(textureId: snapshot.textureId!) in Flutter widget tree

  // 5. Control playback and read controller snapshot telemetry
  await controller.pause();
  await controller.seek(5000);
  await controller.play();

  final refreshed = await controller.refresh();
  print(
    'Playback status: duration=${refreshed.durationMs}ms, '
    'position=${refreshed.positionMs}ms, '
    'buffered=${refreshed.bufferedPercent}% (${refreshed.bufferedPositionMs}ms ahead), '
    'liveOffset=${refreshed.liveOffsetMs}',
  );

  await controller.stop();

  // 6. Release resources
  await controller.dispose();
}
```

### Controller Playback Timing & Buffer Telemetry (Phases 4C7Y, 4C7Z, 4C6P)

`VGStreamingPlaybackControllerSnapshot` exposes read-only convenience getters for stream timing, buffer, and cache event telemetry delegating directly to the underlying session:
- `durationMs`: Total media duration in milliseconds (`-1` for live/unbounded streams or when idle/unsupported).
- `positionMs`: Current playhead position in milliseconds (`0` when idle/unsupported).
- `bufferedPositionMs`: Look-ahead buffered duration in milliseconds ahead of current playhead (`0` when idle/unsupported).
- `bufferedPercent`: 0–100 percentage of the look-ahead buffer filled (`0` when idle/unsupported).
- `liveOffsetMs`: Current distance from live edge in milliseconds (`null` for VOD or when idle/unsupported).
- `playbackCacheEnabled`: Whether the active session was opened with playback cache enabled (`false` when no session).
- `playbackCacheTelemetryAttached`: Whether the Media3 `CacheDataSource` event telemetry listener is attached (`false` when no session).
- `playbackCacheBytesRead`: Cumulative bytes read from cache during playback (`0` when no session).
- `playbackCacheSizeBytes`: Latest reported total cache size in bytes (`0` when no session).
- `playbackCacheIgnoredCount`: Cumulative count of ignored cache read events (`0` when no session).
- `playbackCacheLastIgnoredReason`: Reason string for the last ignored cache event, or `null` if none occurred.
- `hasPlaybackTelemetry`: Whether an active playback session is present.

These accessors allow app integrators and UI layers to consume playback and cache event metrics directly from the controller snapshot without repeatedly drilling into `snapshot.session`.

## Streaming Playback Decision Planner Recipe

The package exposes `VGStreamingPlaybackDecisionPlanner` to combine preflight advisories (`VGStreamingPreflightReport`), startup plans (`VGStreamingStartupPlan`), and source selection (`VGStreamingSourceSelector`) into a single immutable app-facing decision object (`VGStreamingPlaybackDecision`).

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> planAndPlayStream() async {
  // 1. Define candidate stream sources in a source set
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'primary_hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
      VGStreamingSourceDescriptor(
        key: 'backup_dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
    ],
  );

  // 2. Synthesize preflight request from source set and evaluate
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    sourceSet.toPreflightRequest(
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 3. Plan playback decision using pure-Dart planner
  final decision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: preflightReport,
      preference: VGStreamingSourceSelectionPreference.preserveOrder,
      preferredKeys: const ['primary_hls'],
    ),
  );

  if (!decision.canOpenPlayback || decision.playbackOptions == null) {
    print('Playback blocked: ${decision.decision}, warnings: ${decision.warnings}');
    return;
  }

  // 4. Open playback session using planned options and control media
  final playbackClient = VGStreamingPlaybackClient();
  var session = await playbackClient.open(decision.playbackOptions!);
  session = await playbackClient.play(session);

  // 5. Stop and release
  session = await playbackClient.stop(session);
  await playbackClient.dispose(session);
}
```

## Streaming Source Selector Recipe

The package exposes `VGStreamingSourceSelector` to evaluate candidate streaming source descriptors against a validated `VGStreamingStartupPlan` and caller selection preferences (e.g. `preserveOrder`, `preferHls`, `preferDash`, `preferLowLatency`, `preferConstrainedReliability`, or specific `preferredKeys`).

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> selectAndPlayStream() async {
  // 1. Define candidate stream sources in a source set
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'primary_hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
      VGStreamingSourceDescriptor(
        key: 'backup_dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
    ],
  );

  // 2. Synthesize preflight request from source set and evaluate
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    sourceSet.toPreflightRequest(
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 3. Synthesize startup plan from preflight report
  final plan = VGStreamingStartupPlanner.fromPreflight(preflightReport);

  // 4. Select candidate source using pure-Dart selector
  final selection = VGStreamingSourceSelector.select(
    VGStreamingSourceSelectionRequest(
      sourceSet: sourceSet,
      startupPlan: plan,
      preference: VGStreamingSourceSelectionPreference.preserveOrder,
      preferredKeys: const ['primary_hls'],
    ),
  );

  if (!selection.selected || selection.playbackOptions == null) {
    print('Selection failed: ${selection.decision}, warnings: ${selection.warnings}');
    return;
  }

  // 5. Open playback session and control media
  final playbackClient = VGStreamingPlaybackClient();
  var session = await playbackClient.open(selection.playbackOptions!);
  session = await playbackClient.play(session);

  // 6. Stop and release
  session = await playbackClient.stop(session);
  await playbackClient.dispose(session);
}
```

## Streaming Source Descriptor Recipe

The package exposes `VGStreamingSourceDescriptor` and `VGStreamingSourceSet` to define stream metadata, preflight validation requirements, presentation dimensions, and cache options in a unified pure-Dart model. Candidate sources seamlessly generate preflight requests and derive validated `VGStreamingPlaybackOptions` via startup plans.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> playDescriptorDrivenStream() async {
  // 1. Define candidate stream sources in a source set
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'primary_hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
      VGStreamingSourceDescriptor(
        key: 'backup_dash',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
    ],
  );

  // 2. Synthesize preflight request from source set and evaluate
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    sourceSet.toPreflightRequest(
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 3. Synthesize startup plan from preflight report
  final plan = VGStreamingStartupPlanner.fromPreflight(preflightReport);
  if (!plan.shouldProceed) {
    print('Startup aborted: ${plan.reason}');
    return;
  }

  // 4. Derive validated playback options directly from candidate descriptor using plan
  final primarySource = sourceSet.sourceForKey('primary_hls');
  final playbackOptions = primarySource.toPlaybackOptions(plan);

  // 5. Open playback session and control media
  final playbackClient = VGStreamingPlaybackClient();
  var session = await playbackClient.open(playbackOptions);
  session = await playbackClient.play(session);

  // 6. Stop and release
  session = await playbackClient.stop(session);
  await playbackClient.dispose(session);
}
```

## Streaming All-Up Integration Recipe

The package provides an end-to-end adaptive streaming pipeline: evaluate candidate manifests with `VGStreamingPreflightClient`, generate an immutable startup plan with `VGStreamingStartupPlanner`, build validated options guided by preflight network policies, and execute playback with `VGStreamingPlaybackClient`.

### Quick Start

```dart
import 'package:flutter/widgets.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> playAdaptiveStream() async {
  // 1. Evaluate candidate manifests via preflight client
  final preflightClient = VGStreamingPreflightClient();
  final preflightReport = await preflightClient.evaluate(
    VGStreamingPreflightRequest(
      manifests: [
        VGStreamingManifestSpec(
          key: 'mux_hls',
          uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
          formatHint: VGStreamingFormatHint.hls,
        ),
      ],
      requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    ),
  );

  // 2. Synthesize startup plan from preflight advisory report
  final plan = VGStreamingStartupPlanner.fromPreflight(preflightReport);
  if (!plan.shouldProceed) {
    print('Playback aborted by startup plan: ${plan.reason}');
    return;
  }

  // 3. Build validated playback options guided by preflight-recommended profile
  final options = plan.buildPlaybackOptions(
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    initialWidth: 1080,
    initialHeight: 1920,
    formatHint: VGStreamingFormatHint.hls,
    autoPlay: true,
  );

  // 4. Open playback session and render to Texture widget
  final playbackClient = VGStreamingPlaybackClient();
  var session = await playbackClient.open(options);
  session = await playbackClient.play(session);

  // 5. Query status and lifecycle controls
  session = await playbackClient.getStatus(session);
  session = await playbackClient.pause(session);
  if (session.durationMs > 0) {
    session = await playbackClient.seek(session, 5000);
  }

  // 6. Stop and release native resources
  session = await playbackClient.stop(session);
  await playbackClient.dispose(session);
}
```

## Streaming Playback API

The package exposes `VGStreamingPlaybackClient` to manage adaptive streaming media playback (HLS / DASH) rendered into Flutter `Texture` widgets. All public APIs are exported from `package:vanguard_media_engine/vanguard_media_engine.dart`.

### Quick Start

```dart
import 'package:flutter/widgets.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// 1. Instantiate the streaming playback client
final client = VGStreamingPlaybackClient();

// 2. Open an adaptive stream session
var session = await client.open(
  VGStreamingPlaybackOptions(
    uri: Uri.parse('https://cdn.example.com/live/master.m3u8'),
    initialWidth: 1080,
    initialHeight: 1920,
    formatHint: VGStreamingFormatHint.hls,
    networkProfile: VGStreamingNetworkProfile.auto,
    autoPlay: true,
    cacheOptions: const VGPlaybackCacheOptions(
      cacheEnabled: true,
      cacheMaxBytes: 512 * 1024 * 1024,
    ),
  ),
);

// 3. Render video frames onto a Flutter texture
Widget buildVideoWidget(VGStreamingPlaybackSession session) {
  return Texture(textureId: session.textureId);
}

// 4. Playback controls
session = await client.pause(session);
session = await client.play(session);
session = await client.seek(session, 15000); // Seek to 15s

// 5. Query playback diagnostics, timing, and buffer status
session = await client.getStatus(session);
print('State: ${session.state}, Position: ${session.positionMs}ms / ${session.durationMs}ms, '
      'Buffered: ${session.bufferedPositionMs}ms (${session.bufferedPercent}%), LiveOffset: ${session.liveOffsetMs}ms');

// 6. Stop and release native resources
session = await client.stop(session);
await client.dispose(session);
```

### Playback Timing & Buffer Telemetry (Phases 4C7W, 4C7X)

App integrators can read typed stream timing and buffer metrics directly from `VGStreamingPlaybackSession`:
- `durationMs`: Total stream duration in milliseconds (`-1` for live/unbounded streams; normalized from Media3 `C.TIME_UNSET`).
- `positionMs`: Current playhead position in milliseconds.
- `bufferedPositionMs`: Look-ahead buffered duration in milliseconds ahead of the playhead.
- `bufferedPercent`: 0–100 percentage of the look-ahead buffer filled.
- `liveOffsetMs`: Distance from live edge in milliseconds (`null` for VOD).

These fields are populated defensively via `client.getStatus(session)` and state transition responses (`open`, `play`, `pause`, `seek`, `stop`) without requiring raw `MethodChannel` access.

### Playback Cache Event Telemetry (Phases 4C6P, 4C6Q)

When streaming playback is opened with cache enabled (`VGPlaybackCacheOptions(cacheEnabled: true)`), the Android Media3 engine attaches a `CacheDataSource.EventListener` to report honest cache-read diagnostics:
- `playbackCacheEnabled`: Whether the session requested read-through playback cache.
- `playbackCacheTelemetryAttached`: Whether the Media3 `CacheDataSource` event telemetry listener was attached to the active session.
- `playbackCacheBytesRead`: Cumulative bytes read from cache during playback.
- `playbackCacheSizeBytes`: Latest reported total cache size in bytes.
- `playbackCacheIgnoredCount`: Cumulative count of ignored cache read events (e.g. on cache I/O errors or unset length).
- `playbackCacheLastIgnoredReason`: Reason string for the last ignored cache event (`"error"`, `"unset_length"`, or `null`).

**Non-Claims & Invariants**:
- Telemetry reports actual Media3 `CacheDataSource` events observed during active playback;
- It does **not** prove every adaptive segment was served from cache (ExoPlayer Media3 runtime retains full ownership over ABR adaptation and segment-graph loading);
- Physical proof verified on hardware (`RRGL207K8GB`) via `android_streaming_cached_playback_all_up_public_api_physical_smoke.dart`.

### Supported Formats

- **Android**: Full native Media3 adaptive streaming backend supporting HLS, Apple LL-HLS via `VGStreamingFormatHint.hls`, and DASH (`VGStreamingFormatHint.dash`).
- **iOS**: The public Dart API is safe to import on iOS, but native streaming playback backend is not yet implemented (returns typed unsupported session objects). Future AVPlayer HLS/LL-HLS parity is planned; iOS DASH remains deferred.

### Boundaries & Guidelines

- **No Direct Channel Access**: Do not call raw `MethodChannel` from ConnectsApp; always use `VGStreamingPlaybackClient`.
- **Decoupled Cache Policy**: Direct playback should not be blocked by cache/prewarm policy or storage guards.
- **Scope Exclusion**: WebRTC and LiveKit interactive rooms and room audio are outside this HTTP playback API.
- **Physical Proof Status**: Verified on physical hardware via `android_streaming_playback_public_api_physical_smoke.dart`.

## Streaming Preflight Advisory API

The package exposes `VGStreamingPreflightClient` to evaluate candidate streaming manifest specifications against device codec capabilities and network policies before initiating playback.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// 1. Instantiate the streaming preflight client
final client = VGStreamingPreflightClient();

// 2. Prepare candidate manifest specifications
final manifests = [
  VGStreamingManifestSpec(
    key: 'mux_hls',
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
    requireAdaptiveLadder: true,
    requireAvcFallback: true,
  ),
  VGStreamingManifestSpec(
    key: 'shaka_dash',
    uri: Uri.parse(
      'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
    ),
    formatHint: VGStreamingFormatHint.dash,
  ),
];

// 3. Evaluate preflight request
final report = await client.evaluate(
  VGStreamingPreflightRequest(
    manifests: manifests,
    requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
    preferLowLatency: false,
  ),
);

// 4. Inspect advisory decisions and network policies
if (report.pass) {
  print('Preflight passed: recommended profile = ${report.recommendedNetworkProfile}');
  print('Policy config: ${report.recommendedNetworkPolicy}');
} else {
  print('Preflight warnings: ${report.warnings}');
}
```

### Advisory Guarantees & Boundaries

- **Advisory-Only**: `report.advisoryOnly == true` and `report.playbackMutation == false`. Preflight evaluation performs static codec and manifest capability checks without allocating players, decoders, textures, or rendering pipelines.
- **No Direct Channel Access**: Do not invoke `evaluateStreamingPreflightAdvisory` directly; always use `VGStreamingPreflightClient`.
- **Platform Support**:
  - Android: Backed by native codec capability inspection and adaptive network policy engine.
  - iOS: Public Dart API is safe to import on iOS and returns typed unsupported report objects (`phase: 'unsupported'`, `pass: false`) until native AVPlayer preflight is implemented.

## Streaming Cache Prewarm Planner Recipe

The package exposes `VGStreamingCachePrewarmPlanner` to bridge candidate stream descriptors (`VGStreamingSourceDescriptor` / `VGStreamingSourceSet`) into deterministic, bounded cache prewarm requests (`VGPlaybackPrewarmRequest` / `VGStreamingCachePrewarmPlan`) without platform coupling or side effects. Requests can be dispatched directly via the `VGStreamingCacheClient.prewarmRequest` extension.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> planAndPrewarmStreams() async {
  // 1. Define candidate stream sources in a source set
  final sourceSet = VGStreamingSourceSet(
    sources: [
      VGStreamingSourceDescriptor(
        key: 'primary_hls',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
      ),
      VGStreamingSourceDescriptor(
        key: 'll_live',
        uri: Uri.parse(
          'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
        ),
        formatHint: VGStreamingFormatHint.hls,
        initialWidth: 1080,
        initialHeight: 1920,
        requireLlHlsTags: true,
      ),
    ],
  );

  // 2. Synthesize prewarm plan with low-latency constraints
  final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
    sourceSet: sourceSet,
    requestIdPrefix: 'feed_prewarm',
    sourceKeys: const ['primary_hls', 'll_live'],
    maxBytes: 2 * 1024 * 1024,
    lowLatencyPolicy: VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
  );

  // 3. Dispatch planned prewarm requests to cache client
  final client = VGStreamingCacheClient();
  for (final request in plan.requests) {
    final startResult = await client.prewarmRequest(request);
    print('Started prewarm for ${request.requestId}: ${startResult.state}');
  }
}
```

## Streaming Cache API

The package exposes `VGStreamingCacheClient` to manage media prewarming and caching for streaming video/audio playback.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

// 1. Instantiate the streaming cache client
final client = VGStreamingCacheClient();

// 2. Query cache status
final status = await client.getStatus(
  options: const VGPlaybackCacheOptions(
    cacheEnabled: true,
    cacheMaxBytes: 512 * 1024 * 1024,
    cacheDirectoryName: 'vanguard_playback_cache',
  ),
);
print('Cache available: ${status.cacheAvailable}, used bytes: ${status.cacheSpaceBytes}');

// 3. Prewarm streaming content (bounded background fetch)
final prewarmResult = await client.prewarm(
  requestId: 'feed_item_12345',
  uri: Uri.parse('https://cdn.example.com/video/stream.mp4'),
  maxBytes: 2 * 1024 * 1024, // 2 MiB budget
  options: const VGPlaybackCacheOptions(
    cacheEnabled: true,
    minimumFreeBytesAfterPrewarm: 64 * 1024 * 1024, // 64 MiB headroom guard
  ),
);

switch (prewarmResult.state) {
  case VGPlaybackPrewarmStartState.accepted:
    print('Prewarm queued: ${prewarmResult.requestId}');
    break;
  case VGPlaybackPrewarmStartState.blockedLowStorage:
    print('Prewarm blocked by storage guard (insufficient disk space)');
    break;
  case VGPlaybackPrewarmStartState.storageGuardError:
    print('Prewarm skipped: storage guard evaluation error');
    break;
  case VGPlaybackPrewarmStartState.duplicate:
  case VGPlaybackPrewarmStartState.invalid:
  case VGPlaybackPrewarmStartState.shutdown:
  case VGPlaybackPrewarmStartState.unsupported:
    print('Prewarm not started: ${prewarmResult.state}');
    break;
}

// 4. Poll job status
final jobStatus = await client.getPrewarmStatus('feed_item_12345');
print('Job state: ${jobStatus.state}, cached: ${jobStatus.bytesCached} bytes');

// 5. Cancel on scroll-away
await client.cancelPrewarm('feed_item_12345');

// 6. Clear cache on privacy/logout trigger
final clearResult = await client.clear(
  options: const VGPlaybackCacheOptions(cacheEnabled: true),
);
print('Cleared cache: pass=${clearResult.pass}, freed=${clearResult.beforeBytes - clearResult.afterBytes} bytes');
```

### Options and Error States

`VGPlaybackCacheOptions` parameters:
- `cacheEnabled`: Enables or disables the cache substrate (defaults to `true`).
- `cacheMaxBytes`: Total disk cache quota in bytes (default: 512 MiB).
- `cacheDirectoryName`: Subdirectory in the application cache directory (default: `'vanguard_playback_cache'`).
- `minimumFreeBytesAfterPrewarm`: Minimum required free disk space remaining after the prewarm write completes (default: 64 MiB).

Prewarm start states (`VGPlaybackPrewarmStartState`):
- `accepted`: Request accepted and queued for download.
- `blockedLowStorage`: Prewarm blocked because free storage is below `minimumFreeBytesAfterPrewarm`.
- `storageGuardError`: Prewarm skipped because storage headroom could not be evaluated.
- `duplicate`: A job with the specified `requestId` is already running or queued.
- `invalid`: Request parameters are invalid or cache is disabled.
- `shutdown`: Cache coordinator has been shut down.
- `unsupported`: Platform does not support native streaming cache.

### Ownership and Architectural Boundaries

- **Vanguard Package Ownership**: Owns the native cache substrate, disk management, bounded prewarm coordinator, and public Dart client APIs.
- **ConnectsApp Ownership**: Owns feed prefetch policy, viewport prediction, scroll-driven cancel triggers, and trigger timing.
- **Scope Exclusion**: WebRTC and LiveKit interactive room audio/video streams are not cached by this API.
- **Platform Support**:
  - Android: Fully backed by the native Media3 SimpleCache substrate and prewarm coordinator.
  - iOS: Native backend implementation is planned and frozen in UMF architecture documents, but not yet implemented. Calls on non-Android platforms safely catch `MissingPluginException` and return typed unsupported result objects (`phase: 'unsupported'`, `pass: false`).
- **Physical Proof Status**: Phase 4C6F3 physical proof is pending device visibility while mechanical and API unit/integration tests are in place.

## RTC Video Diagnostics API

The package exposes `VGRtcVideoDiagnosticsClient` to run health checks and diagnostics against Vanguard True-DAG RTC video transport contracts and adapter seams without raw `MethodChannel` calls.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> runRtcDiagnostics() async {
  // 1. Instantiate diagnostics client
  final client = VGRtcVideoDiagnosticsClient();

  // 2. Execute all 7 Android RTC video diagnostic routes
  final report = await client.runAll(
    request: const VGRtcVideoDiagnosticsRequest(
      width: 64,
      height: 64,
      frameCount: 3,
    ),
  );

  // 3. Inspect report and boundary invariants
  if (report.pass) {
    print('RTC Video Diagnostics passed across all 7 routes');
    print('Video-only boundary preserved: ${report.videoOnlyBoundaryPreserved}');
    print('Room/Audio boundary preserved: ${report.roomAudioBoundaryPreserved}');
    print('Transport-agnostic: ${report.transportAgnostic}');
  } else {
    print('RTC Diagnostics failed: ${report.raw}');
  }
}
```

### Invariants & Ownership Boundaries

- **Diagnostic-Only Wrapper**: This API is a diagnostic wrapper over existing Android RTC video seams (`RtcVideoFramePublisher`, `RtcVideoFrameSink`, `RealtimeVideoOutputAdapter`, `RealtimeVideoInputAdapter`, backpressure controller, frame validator, processed egress, and jitter buffer). It is not a LiveKit/WebRTC bridge implementation.
- **Product-Level Bridge**: Concrete WebRTC / LiveKit bridging remains strictly product-level (e.g. within ConnectsApp or an external bridge module) behind generic video seams per ADR-AND-09. Vanguard core has zero direct LiveKit or WebRTC SDK dependencies.
- **Video-Only (No Audio / Room Ownership)**: Vanguard operates strictly on video transport contracts. All room tokens, session state, participant management, and microphone/speaker audio are strictly owned by ConnectsApp / Room layer and must never enter Vanguard.
- **No WebRTC Caching**: Real-time WebRTC / LiveKit media streams are not cached by the Vanguard streaming playback cache.

## Adaptive Stream Timeline Diagnostics API

The package exposes `VGStreamingTimelineDiagnosticsClient` to run timeline monotonicity, duplicate dropping, out-of-order rejection, late dropping, future frame retryability, seek rebasing, rendition rebasing, and live-offset speed policy diagnostics against the native adaptive stream timeline controller without raw `MethodChannel` calls.

### Quick Start

```dart
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Future<void> runTimelineDiagnostics() async {
  // 1. Instantiate timeline diagnostics client
  final client = VGStreamingTimelineDiagnosticsClient();

  // 2. Execute adaptive stream timeline diagnostic smoke suite
  final report = await client.run(
    request: const VGStreamingTimelineDiagnosticsRequest(
      frameCount: 5,
    ),
  );

  // 3. Inspect report and timeline invariants
  if (report.pass) {
    print('Adaptive Stream Timeline Diagnostics passed across all 11 invariants');
    print('Sequential pass: ${report.sequentialPass}');
    print('Duplicate pass: ${report.duplicatePass}');
    print('Out-of-order pass: ${report.outOfOrderPass}');
    print('Late pass: ${report.latePass}');
    print('Future & retry pass: ${report.futurePass} / ${report.futureRetryPass}');
    print('Seek & rendition rebase pass: ${report.seekRebasePass} / ${report.renditionRebasePass}');
    print('Live offset policy pass: ${report.liveOffsetPolicyPass}');
    print('Negative input & reset pass: ${report.negativeInputPass} / ${report.resetPass}');
  } else {
    print('Timeline Diagnostics failed: ${report.raw}');
  }
}
```

### Invariants & Ownership Boundaries

- **Diagnostic-Only Wrapper**: This API is a diagnostic-only wrapper over the native `AdaptiveStreamTimelineController` and `AdaptiveStreamLiveOffsetPolicy` verification harness (`runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke`). It validates timestamp normalization, frame ordering, and rebasing math without controlling native playback ABR rendition switches or mutating product feed policies.
- **ABR & Player Boundary**: The native Media3 / ExoPlayer runtime continues to own ABR rendition selection and segment loading.
- **Product Boundary**: Zero ConnectsApp feed prediction or playback policy wiring in this API.
- **iOS Parity Expectation**: Safe to import on iOS (catches `MissingPluginException` and returns typed unsupported report). The iOS implementer will expose equivalent public diagnostics once the AVPlayer timeline backend lands.

## Package Architecture

- `lib/`: Dart public API definitions and platform bridge clients.
- `src/`: Native C++ engine implementation for timeline and composition.
- `android/`: Android platform implementation including Media3 streaming cache coordinator, RTC video coordinator, and FFI glue.
- `ios/`: iOS platform implementation (Metal rendering, AVFoundation integration).
