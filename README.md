# vanguard_media_engine

Vanguard is a high-performance native media engine plugin for Flutter, providing timeline editing, camera capture and filters, hardware-accelerated playback, and streaming media cache capabilities.

All public APIs are exported from `package:vanguard_media_engine/vanguard_media_engine.dart`.

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

// 5. Query playback diagnostics and status
session = await client.getStatus(session);
print('State: ${session.state}, Position: ${session.positionMs}ms / ${session.durationMs}ms');

// 6. Stop and release native resources
session = await client.stop(session);
await client.dispose(session);
```

### Supported Formats

- **Android**: Full native Media3 adaptive streaming backend supporting HLS, Apple LL-HLS via `VGStreamingFormatHint.hls`, and DASH (`VGStreamingFormatHint.dash`).
- **iOS**: The public Dart API is safe to import on iOS, but native streaming playback backend is not yet implemented (returns typed unsupported session objects). Future AVPlayer HLS/LL-HLS parity is planned; iOS DASH remains deferred.

### Boundaries & Guidelines

- **No Direct Channel Access**: Do not call raw `MethodChannel` from ConnectsApp; always use `VGStreamingPlaybackClient`.
- **Decoupled Cache Policy**: Direct playback should not be blocked by cache/prewarm policy or storage guards.
- **Scope Exclusion**: WebRTC and LiveKit interactive rooms and room audio are outside this HTTP playback API.
- **Physical Proof Status**: The current public physical smoke target exists, but physical proof is pending device visibility.

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

## Package Architecture

- `lib/`: Dart public API definitions and platform bridge clients.
- `src/`: Native C++ engine implementation for timeline and composition.
- `android/`: Android platform implementation including Media3 streaming cache coordinator and FFI glue.
- `ios/`: iOS platform implementation (Metal rendering, AVFoundation integration).
