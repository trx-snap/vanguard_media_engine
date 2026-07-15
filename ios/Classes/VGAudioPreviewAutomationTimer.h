// VGAudioPreviewAutomationTimer.h
// Vanguard Media Engine — Audio Slice J
//
// Protocol and production implementation for the repeating automation timer.
// The timer invokes a supplied block at a fixed interval on the owning
// scheduler queue.
//
// CRITICAL SOURCE-GENERATION GUARD:
// The production implementation maintains a monotonically increasing internal
// generation counter.  On every startWithInterval:block: or cancel call the
// generation is incremented.  The dispatch source event handler captures the
// generation at creation time.  Before invoking the user block the handler
// promotes its weak timer reference, compares the captured generation against
// the current generation, and only calls the user block on a match.
// This guarantees that an already-enqueued handler from a cancelled or replaced
// source cannot reach the user block — even before the runtime's token and
// serial guards run.
//
// Package-internal only.  Do NOT add to public_header_files.

#pragma once

#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGAudioPreviewAutomationTimer protocol ───────────────────────────────────

@protocol VGAudioPreviewAutomationTimer <NSObject>

/// Starts the repeating timer with the given interval.
/// Cancels any existing source before starting a new one.
/// The block is invoked on the queue supplied at initialisation.
- (void)startWithInterval:(NSTimeInterval)interval block:(dispatch_block_t)block;

/// Cancels the timer. Idempotent.
- (void)cancel;

@end

// ─── VGProductionAudioPreviewAutomationTimer ──────────────────────────────────
//
// Package-internal class.  Tests may instantiate this directly to validate the
// production timer behaviour (TP1–TP6).

@interface VGProductionAudioPreviewAutomationTimer
    : NSObject <VGAudioPreviewAutomationTimer>

/// Initialises the timer targeting the given queue.
- (instancetype)initWithQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
