// VanguardGraphScheduler.m
// vanguard_media_engine — Phase 4, P4-2 / P4-5 / P4-9
//
// P4-2: Scheduler skeleton — lifecycle (start/pause/resume/seekTo/
//       setFilterChain/invalidate). applyThermalState: dormant stub.
// P4-5: Frame delegate — receives raw frames, executes filter chain,
//       delivers processed envelope to sink.
// P4-9: Cost-budget thermal policy — applyThermalState: activated.
//       Replaces binary isExpensive runtime policy with scalar
//       estimatedGPUCostMs greedy-disable algorithm. Closes RR-33.

#import "VanguardGraphScheduler.h"
#import "VanguardMetalRenderer.h" // P4-5: sink type for presentEnvelope:
#include <float.h>                // P4-9: FLT_MAX for Nominal/Fair tier budget
#import <os/lock.h>
#import <os/log.h>
#include <stdatomic.h>

static os_log_t sSchedulerLog;

@implementation VanguardGraphScheduler {
  dispatch_queue_t _schedulerQueue; // serial; reserved for P4-5 activation
  os_unfair_lock _chainLock;        // guards _filterChain swap
  NSArray<id<VGMetalFilterNode>> *_filterChain;
  _Atomic(BOOL) _invalidated;
  BOOL _isRunning;
  // P4-5: Metal device stored at startWithClock:device: for use in
  // didReceiveRawFrame: filter loop.
  id<MTLDevice> _device;
}

+ (void)initialize {
  if (self == [VanguardGraphScheduler class]) {
    sSchedulerLog = os_log_create("com.vanguard.engine", "scheduler");
  }
}

- (instancetype)init {
  self = [super init];
  if (!self)
    return nil;
  _schedulerQueue = dispatch_queue_create("com.vanguard.scheduler.serial",
                                          DISPATCH_QUEUE_SERIAL);
  _chainLock = OS_UNFAIR_LOCK_INIT;
  _filterChain = nil;
  atomic_store(&_invalidated, NO);
  _isRunning = NO;
  os_log_debug(sSchedulerLog, "[VGScheduler] init");
  return self;
}

// ─── VGGraphScheduler ────────────────────────────────────────────────────────

- (void)startWithClock:(id<VGMasterClock>)clock device:(id<MTLDevice>)device {
  if (atomic_load(&_invalidated))
    return;
  _device = device; // P4-5: retain device for filter execution
  _isRunning = YES;
  os_log_debug(sSchedulerLog, "[VGScheduler] startWithClock: (P4-5)");
}

- (void)pause {
  if (atomic_load(&_invalidated))
    return;
  _isRunning = NO;
  os_log_debug(sSchedulerLog, "[VGScheduler] pause (dormant P4-2)");
}

- (void)resume {
  if (atomic_load(&_invalidated))
    return;
  _isRunning = YES;
  os_log_debug(sSchedulerLog, "[VGScheduler] resume (dormant P4-2)");
}

- (void)seekTo:(double)seconds generation:(uint64_t)generation {
  if (atomic_load(&_invalidated))
    return;
  os_log_debug(sSchedulerLog,
               "[VGScheduler] seekTo:%.3f generation:%llu (dormant P4-2)",
               seconds, (unsigned long long)generation);
}

- (void)setFilterChain:(nullable NSArray<id<VGMetalFilterNode>> *)chain {
  if (atomic_load(&_invalidated))
    return;

  // Snapshot old chain before the lock-protected swap.
  NSArray<id<VGMetalFilterNode>> *oldChain = nil;

  os_unfair_lock_lock(&_chainLock);
  oldChain = [_filterChain copy];
  _filterChain = chain ? [chain copy] : nil;
  os_unfair_lock_unlock(&_chainLock);

  // Invalidate removed nodes OUTSIDE the lock (must not hold lock during ObjC).
  if (oldChain) {
    NSSet *newSet = chain ? [NSSet setWithArray:chain] : [NSSet set];
    for (id<VGMetalFilterNode> node in oldChain) {
      if (![newSet containsObject:node]) {
        [node invalidate];
      }
    }
  }

  os_log_debug(sSchedulerLog,
               "[VGScheduler] setFilterChain: count=%lu (dormant P4-2)",
               (unsigned long)chain.count);
}

- (void)applyThermalState:(NSProcessInfoThermalState)state {
  // P4-9: Cost-budget thermal policy (RR-33 closure).
  // Replaces binary isExpensive runtime iteration with scalar
  // estimatedGPUCostMs greedy-disable.  Lock is held ONLY for the chain pointer
  // snapshot, released before any node.enabled write or sort operation
  // (DEC-54).

  if (atomic_load(&_invalidated))
    return;

  // ── 1. Snapshot chain under lock ──────────────────────────────────────────
  NSArray<id<VGMetalFilterNode>> *chain = nil;
  os_unfair_lock_lock(&_chainLock);
  chain = _filterChain; // ARC-retained snapshot; lock released immediately
  os_unfair_lock_unlock(&_chainLock);

  if (!chain.count) {
    os_log_debug(sSchedulerLog,
                 "[VGScheduler] applyThermalState:%ld — empty chain, nothing "
                 "to throttle",
                 (long)state);
    return;
  }

  // ── 2. Select tier budget (ms) ────────────────────────────────────────────
  // Calibrated for Phase 3 behavioral equivalence with the current 3-node set
  // (LUT=2ms, Beauty=3ms, Segmentation=5ms):
  //   Nominal/Fair  → FLT_MAX — all nodes always on
  //   Serious       → 5.0 ms  — allows LUT(2)+Beauty(3)=5ms, disables Seg(5ms)
  //   Critical      → 0.0 ms  — all nodes off
  // N-node scaling is correct: greedy-disable from most expensive until
  // totalCost ≤ budget, regardless of node count.
  float budgetMs;
  switch (state) {
  case NSProcessInfoThermalStateNominal:
  case NSProcessInfoThermalStateFair:
    budgetMs = FLT_MAX;
    break;
  case NSProcessInfoThermalStateSerious:
    budgetMs = 5.0f;
    break;
  case NSProcessInfoThermalStateCritical:
    budgetMs = 0.0f;
    break;
  default:
    os_log_debug(sSchedulerLog,
                 "[VGScheduler] applyThermalState: unknown state %ld — no-op",
                 (long)state);
    return;
  }

  // ── 3. Enable all nodes (lock NOT held — node.enabled write) ─────────────
  for (id<VGMetalFilterNode> node in chain) {
    node.enabled = YES;
  }

  // ── 4. Compute total estimated GPU cost ───────────────────────────────────
  float totalCostMs = 0.0f;
  for (id<VGMetalFilterNode> node in chain) {
    totalCostMs += node.estimatedGPUCostMs;
  }

  // ── 5. Greedy disable: most expensive first until totalCost ≤ budget ──────
  if (totalCostMs > budgetMs) {
    // Sort descending by estimatedGPUCostMs (most expensive first).
    // Lock NOT held during sort or node.enabled writes.
    NSArray<id<VGMetalFilterNode>> *sorted =
        [chain sortedArrayUsingComparator:^NSComparisonResult(
                   id<VGMetalFilterNode> a, id<VGMetalFilterNode> b) {
          float costA = a.estimatedGPUCostMs;
          float costB = b.estimatedGPUCostMs;
          if (costA > costB)
            return NSOrderedAscending; // a before b = most expensive first
          if (costA < costB)
            return NSOrderedDescending;
          return NSOrderedSame;
        }];

    for (id<VGMetalFilterNode> node in sorted) {
      if (totalCostMs <= budgetMs)
        break;
      node.enabled = NO;
      totalCostMs -= node.estimatedGPUCostMs;
    }
  }

  os_log_debug(
      sSchedulerLog,
      "[VGScheduler] applyThermalState:%ld budget=%.1fms remaining=%.1fms "
      "nodes=%lu",
      (long)state, budgetMs, totalCostMs, (unsigned long)chain.count);
}

- (void)invalidate {
  // Idempotent: only the first call executes teardown.
  BOOL expected = NO;
  if (!atomic_compare_exchange_strong(&_invalidated, &expected, YES))
    return;

  os_unfair_lock_lock(&_chainLock);
  NSArray<id<VGMetalFilterNode>> *chain = _filterChain;
  _filterChain = nil;
  os_unfair_lock_unlock(&_chainLock);

  // Invalidate remaining nodes outside the lock.
  for (id<VGMetalFilterNode> node in chain) {
    [node invalidate];
  }

  _isRunning = NO;
  os_log_debug(sSchedulerLog, "[VGScheduler] invalidate");
}

// ─── VGFrameDelegate ─────────────────────────────────────────────────────────

/// P4-5: Receives a raw decoded frame from VanguardMetalRenderer._onVideoFrame:
/// and drives the filter execution loop, then delivers to the renderer sink.
///
/// Execution model:
///   - Called on _videoDecodeQueue (same serial queue as Phase 3 execution).
///   - Queue identity preserved — no dispatch. G-02 A/V sync ordering holds.
///
/// Buffer ownership (RR-36):
///   - envelope.payload.videoBuffer is source-owned (+1 retained by source).
///   - We must NOT release it after presentEnvelope: returns.
///   - Filter-produced buffers are scheduler-owned (+1). We release our +1
///     after presentEnvelope: returns (renderer has taken its own +1).
///   - Intermediate buffers are released within this method before we exit.
///
/// Lock contract (DEC-54):
///   - _chainLock held ONLY for the pointer copy (nanoseconds).
///   - Released before any processEnvelope:device: call.
- (void)didReceiveRawFrame:(VGFrameEnvelope)envelope {
  if (atomic_load(&_invalidated))
    return;

  VanguardMetalRenderer *sink = self.sink;
  if (!sink)
    return; // no renderer wired yet — drop frame safely

  // ── 1. Snapshot filter chain under lock (DEC-54: nanoseconds only) ────────
  NSArray<id<VGMetalFilterNode>> *chain = nil;
  os_unfair_lock_lock(&_chainLock);
  chain = _filterChain; // ARC-retained snapshot; lock released immediately
  os_unfair_lock_unlock(&_chainLock);

  // ── 2. Execute filter loop ─────────────────────────────────────────────────
  // 'frame' tracks the current buffer through the chain.
  // 'deliveredBufferIsSchedulerOwned' tracks whether we own the final buffer.
  CVPixelBufferRef rawBuffer = envelope.payload.videoBuffer;
  CVPixelBufferRef frame = rawBuffer; // start: source-owned
  BOOL schedulerOwnedDelivered = NO;  // RR-36 ownership flag
  VGFrameEnvelope currentEnvelope = envelope;

  if (chain.count > 0) {
    for (id<VGMetalFilterNode> node in chain) {
      if (!node.enabled)
        continue; // DEC-55: pass disabled nodes through

      VGFrameEnvelope result = [node processEnvelope:currentEnvelope
                                              device:_device];

      if (!result.payload.videoBuffer) {
        // Filter failure: release any scheduler-owned intermediate and revert.
        if (schedulerOwnedDelivered) {
          CVPixelBufferRelease(frame);
          schedulerOwnedDelivered = NO;
        }
        frame = rawBuffer;          // revert to source-owned buffer
        currentEnvelope = envelope; // revert envelope
        break;                      // skip remaining nodes
      }

      // Release previous intermediate if we own it (not the original source
      // buf).
      if (schedulerOwnedDelivered) {
        CVPixelBufferRelease(frame);
      }
      frame = result.payload.videoBuffer;
      schedulerOwnedDelivered = YES; // filter output: scheduler owns +1
      currentEnvelope = result;
    }
  }

  // ── 3. Deliver to renderer sink (RR-36: synchronous, same call stack) ─────
  // Build the final envelope with the current buffer.
  VGFrameEnvelope deliveredEnvelope = currentEnvelope;
  deliveredEnvelope.payload.videoBuffer = frame;

  // presentEnvelope: will retain the buffer (+1) before storing.
  [sink presentEnvelope:deliveredEnvelope];

  // ── 4. Post-delivery cleanup (RR-36) ──────────────────────────────────────
  // If the delivered buffer was scheduler-owned (filter output), release our +1
  // now that the renderer has taken its own. Source-owned buffers must NOT be
  // released here — the source reclaims them on the next decode cycle.
  if (schedulerOwnedDelivered) {
    CVPixelBufferRelease(frame); // release scheduler's +1 on filter output
  }
  // Note: rawBuffer (source-owned) is NOT released here. VanguardMetalRenderer
  // released it when it called CVPixelBufferRelease(rawFrame) BEFORE forwarding
  // to this delegate. The source's own +1 is separate and persists until the
  // next copyNextSampleBuffer cycle. No double-release.

  os_log_debug(sSchedulerLog,
               "[VGScheduler] didReceiveRawFrame: chain=%lu schedulerOwned=%d",
               (unsigned long)chain.count, (int)schedulerOwnedDelivered);
}

- (BOOL)isRunning {
  return _isRunning;
}

@end
