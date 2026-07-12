// VGTimelineStateSnapshot.h
// Vanguard Media Engine — Phase 10-C Slice C
//
// Package-internal timeline-state snapshot for cross-thread consumers.
// Consumed by the Slice D audio scheduling queue.
//
// VISIBILITY: Package-internal only. Do NOT add to public_header_files.
// Do NOT import from VanguardGraphRuntime.h.

#pragma once

#import "VanguardGraphRuntime.h"
#import <Foundation/Foundation.h>
#import <stdint.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGTimelineStateSnapshot ─────────────────────────────────────────────────
//
// A coherent, atomic snapshot of the timeline playback clock state.
//
// Contract:
//   - All six fields form one logical tuple. They are always written together
//     under os_unfair_lock and are never observed in a torn state by readers.
//   - Times are in seconds.
//   - playStartHostTime is the CACurrentMediaTime() value captured at the last
//     play() or seek-while-playing() transition.
//   - playStartPTS is the timelineCurrentPTS value paired with that host time.
//     Together they allow a reader to estimate the current PTS without holding
//     the lock: estimatedPTS = playStartPTS + (CACurrentMediaTime() - playStartHostTime).
//   - generation is a monotonically increasing discontinuity counter.
//     It is incremented exactly once per seekTimelineTo: call. Readers must
//     stop and reschedule audio when generation changes.
//   - isPlaying reflects whether the timeline clock is actively advancing.
//     When NO, timelinePTS is the frozen paused/stopped position.
//   - isValid is NO before successful preparation and permanently NO after
//     invalidation. Readers must check isValid before acting on any field.
//
// Thread-safety:
//   readTimelineStateSnapshot may be called from any non-hard-real-time queue.
//   It MUST NOT be called from a hard real-time audio render callback (IOProc /
//   AURenderCallback), as os_unfair_lock is not safe in that context.
//   It MUST NOT be called after the VanguardGraphRuntime object has deallocated.

typedef struct {
    /// Current timeline playback position in seconds (media time).
    /// Frozen on pause; advances each display-link tick while playing.
    double timelinePTS;

    /// CACurrentMediaTime() at the last play or seek-while-playing transition.
    double playStartHostTime;

    /// timelinePTS value at the moment playStartHostTime was captured.
    double playStartPTS;

    /// Seek discontinuity counter. Incremented exactly once per seek.
    uint64_t generation;

    /// YES while the timeline clock is actively advancing.
    BOOL isPlaying;

    /// YES after successful preparation and before invalidation; NO otherwise.
    /// Permanently NO after invalidation — never restored.
    BOOL isValid;
} VGTimelineStateSnapshot;


// ─── VanguardGraphRuntime (TimelineStateSnapshot) ─────────────────────────────
//
// Package-internal category. Not part of the public VGGraphRuntime protocol.
// Implemented in VanguardGraphRuntime.m alongside the rest of the timeline code.

@interface VanguardGraphRuntime (TimelineStateSnapshot)

/// Returns a by-value coherent copy of the current timeline state snapshot.
///
/// Acquires _timelineSnapshotLock, copies the struct, releases the lock,
/// and returns the copy. No allocation. No Objective-C messaging on the
/// hot path. Lock hold time is bounded to the cost of copying ~48 bytes.
///
/// May be called from any non-hard-real-time queue including serial scheduling
/// queues. MUST NOT be called from a hard real-time audio render callback.
/// MUST NOT be called after this VanguardGraphRuntime has been deallocated.
///
/// After invalidation the returned snapshot has isValid == NO.
- (VGTimelineStateSnapshot)readTimelineStateSnapshot;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
