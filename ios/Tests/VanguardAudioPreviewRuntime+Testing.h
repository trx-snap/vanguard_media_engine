// VanguardAudioPreviewRuntime+Testing.h
// Vanguard Media Engine — Audio Modularity M1
//
// Private test-only category declaration for the runtime scheduler-queue seam.
// Import this header in test translation units that call
// vg_performSynchronouslyOnSchedulerQueueForTesting:.
// Do not import from production or public headers.

#pragma once

#import "VanguardAudioPreviewRuntime.h"

#if VG_USE_V2_GRAPH

// Package-private testing seam declared in VanguardAudioPreviewRuntime.m.
@interface VanguardAudioPreviewRuntime (Testing)
- (void)vg_performSynchronouslyOnSchedulerQueueForTesting:
    (dispatch_block_t)block;
@end

#endif // VG_USE_V2_GRAPH
