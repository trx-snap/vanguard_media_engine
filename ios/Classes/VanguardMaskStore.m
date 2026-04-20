// VanguardMaskStore.m
// Phase 4

#import "VanguardMaskStore.h"
#include <os/lock.h>
#include <stdatomic.h>

@implementation VanguardMaskStore {
    os_unfair_lock            _lock;
    VanguardMaskSnapshot*     _snapshot;       // protected by _lock
    _Atomic(uint64_t)         _generation;     // monotonic, read without lock
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock       = OS_UNFAIR_LOCK_INIT;
    _snapshot   = nil;
    atomic_store(&_generation, 0);
    return self;
}

- (void)commitSnapshot:(VanguardMaskSnapshot *)snapshot {
    os_unfair_lock_lock(&_lock);
    _snapshot = snapshot;                      // ARC retains new, releases old
    os_unfair_lock_unlock(&_lock);
    atomic_fetch_add(&_generation, 1);         // outside lock — read-only races are fine
}

- (nullable VanguardMaskSnapshot *)latestSnapshot {
    os_unfair_lock_lock(&_lock);
    VanguardMaskSnapshot* snap = _snapshot;    // ARC: retain before unlock
    os_unfair_lock_unlock(&_lock);
    return snap;
}

- (uint64_t)generation {
    return atomic_load(&_generation);
}

@end
