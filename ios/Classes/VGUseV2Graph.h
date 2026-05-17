// VGUseV2Graph.h
// Phase 4 Batch 3: V2 graph scheduler activation gate.
//
// Compile-time feature flag controlling V2 graph scheduler activation in
// VanguardGraphRuntime.
//
// Default: OFF (0). When OFF, all V2 code is eliminated by the preprocessor
// and the compiled binary is identical to pre-Batch-3 (zero behavioral change,
// zero runtime cost).
//
// When ON (1), VanguardGraphRuntime.m uses VGPlaybackGraphFactory +
// VGGraphSchedulerV2 instead of the V1 VanguardGraphScheduler for the
// prepareWithURL: wiring path. Falls back to V1 scheduler if V2 graph
// construction fails.
//
// Override without editing this file:
//   Set VG_USE_V2_GRAPH=1 in GCC_PREPROCESSOR_DEFINITIONS (Xcode build
//   settings or .xcconfig). The #ifndef guard ensures the file-level default
//   (0) is superseded by the build-system definition.
//
// Scope:
//   Affects only VanguardGraphRuntime.m.
//   Does NOT require recompilation of packages/UMF.
//   Does NOT require recompilation of Phase 3 adapter files.
//
// Phase 4 Batch 3. Remove this header and all #if VG_USE_V2_GRAPH guards
// in VanguardGraphRuntime.m once V2 is validated and V1 path is retired.

#pragma once

#ifndef VG_USE_V2_GRAPH
#define VG_USE_V2_GRAPH 0
#endif
