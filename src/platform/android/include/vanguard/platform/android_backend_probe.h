#pragma once
#include "vanguard/render/backend_capability.h"
#include <jni.h>

#include <cstddef>
#include <cstdint>
#include <string>

namespace vanguard {
namespace platform {

// ---------------------------------------------------------------------------
// P1-GPU-BLACKLIST-NATIVE-RULE-PROOF: reusable native GPU driver blacklist
// rule evaluator. Mirrors the Dart VGGpuDriverBlacklistEvaluator semantics
// exactly:
//   - Ordered first match: rules are evaluated in array order and the first
//     matching rule wins.
//   - vendorId must match exactly.
//   - deviceId == 0 in a rule is a wildcard (matches any device for that
//     vendor).
//   - driverVersion must be >= driverVersionMin (inclusive).
//   - driverVersionMax == 0 means unbounded; otherwise driverVersion must be
//     <= driverVersionMax (inclusive).
// This is diagnostic/reusable plumbing only; it does not own or hold any
// rule table itself.
// ---------------------------------------------------------------------------
struct GpuDriverBlacklistRule {
    uint32_t    vendorId;
    uint32_t    deviceId;         // 0 = wildcard
    uint32_t    driverVersionMin; // inclusive
    uint32_t    driverVersionMax; // inclusive; 0 = unbounded
    const char* label;
};

struct GpuDriverBlacklistMatch {
    bool        matched          = false;
    int         matchedRuleIndex = -1; // -1 = clean / no match
    int         evaluationCount  = 0;  // rules inspected before stopping
    const char* label            = "not_blacklisted";
    const char* result           = "not_blacklisted"; // "blacklisted_match" | "not_blacklisted"
};

GpuDriverBlacklistMatch EvaluateGpuDriverBlacklist(
    const GpuDriverBlacklistRule* rules,
    std::size_t                   ruleCount,
    uint32_t                      vendorId,
    uint32_t                      deviceId,
    uint32_t                      driverVersion);

// Returns the size of the production (compiled-in) driver blacklist rule
// table used by AndroidProbeBackendCapability(). Zero until fleet profiling
// data is available. Diagnostic-only accessor; does not expose entries.
std::size_t ProductionGpuDriverBlacklistRuleCount();

// Diagnostic-only: runs a fixed set of synthetic native rule-evaluator lanes
// against locally constructed rule tables. Does NOT read or mutate the
// production rule table beyond confirming its size stays zero.
struct GpuDriverBlacklistNativeSmokeResult {
    bool        pass        = false;
    int         totalLanes  = 0;
    int         passedLanes = 0;
    // "laneName=true|laneName=false|..." in lane execution order.
    std::string laneSummary;
};

GpuDriverBlacklistNativeSmokeResult RunGpuDriverBlacklistNativeRuleSmoke();

render::BackendCapability AndroidProbeBackendCapability();

} // namespace platform
} // namespace vanguard
