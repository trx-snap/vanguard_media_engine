// VGAudioPreviewProductionCollaborators.h
// Vanguard Media Engine — Audio Slice N
//
// Production AVFoundation adapters extracted from VanguardAudioPreviewRuntime.m.
// Includes: clock, boundary timer, file provider, engine adapter (+ isRunning),
// and player adapter.
//
// VISIBILITY: private_header_files — package-internal only.
// Tests inject mock collaborators via VGAPrTestCollaborators.h.
// Do NOT import from VanguardGraphRuntime.h or public headers.

#pragma once

#import "VanguardAudioPreviewRuntime.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGProductionAudioPreviewClock ───────────────────────────────────────────

@interface VGProductionAudioPreviewClock : NSObject <VGAudioPreviewClock>
@end

// ─── VGProductionAudioPreviewTimer ───────────────────────────────────────────

@interface VGProductionAudioPreviewTimer : NSObject <VGAudioPreviewTimer>
- (instancetype)initWithQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// ─── VGProductionAudioPreviewFileProvider ────────────────────────────────────

@interface VGProductionAudioPreviewFileProvider : NSObject <VGAudioPreviewFileProvider>
@end

// ─── VGProductionAudioPreviewEngine ──────────────────────────────────────────

/// Wraps AVAudioEngine. Implements VGAudioPreviewEngine including isRunning.
@interface VGProductionAudioPreviewEngine : NSObject <VGAudioPreviewEngine>
- (instancetype)initWithEngine:(AVAudioEngine *)engine NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// ─── VGProductionAudioPreviewPlayer ──────────────────────────────────────────

/// Wraps AVAudioPlayerNode.
@interface VGProductionAudioPreviewPlayer : NSObject <VGAudioPreviewPlayer>
- (instancetype)initWithNode:(AVAudioPlayerNode *)node NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
