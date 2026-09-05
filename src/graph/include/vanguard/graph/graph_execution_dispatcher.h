// P1-DAG-MULTINODE-EXECUTION-DISPATCHER: bounded platform-neutral graph-layer
// execution dispatcher foundation.
//
// This is the sole seam between a resolved GraphExecutionPlan and per-node
// execution. `vanguard::graph::Node` remains topology/timeline-only - this
// dispatcher never calls into Node itself; it only walks a
// GraphExecutionPlan's already-resolved node/binding data, resolves each
// node's GPU-bearing inputs against a GpuFrameTokenSession, and invokes a
// caller-supplied callback per node. Deliberately inert: no AHardwareBuffer*,
// no JNI/Android/Vulkan/EGL headers, no rendering, no GPU transport, no
// camera, no product/app/editor wiring.
#pragma once
#include "vanguard/core/status.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/gpu_frame_token.h"
#include <cstdint>
#include <functional>
#include <vector>

namespace vanguard {
namespace graph {

// One GPU-bearing input resolved for a node's callback invocation: the
// plan's declared binding plus the token published for it in the current
// GpuFrameTokenSession.
struct ResolvedGpuFrameInput {
    ExecutionInputBinding binding;
    GpuFrameToken          token;
};

// Per-node execution callback. Invoked at most once per plan node, in plan
// order, only after every one of that node's GPU-bearing
// (kVideoFrame/kTextureBuffer) input bindings has resolved. `resolvedInputs`
// omits non-GPU-bearing bindings (kAudioPacket, kMetadata) entirely.
// `outOutputs` starts empty; the callback appends zero or more produced
// tokens (a sink naturally appends none). A non-ok return stops the
// dispatch before any token in `outOutputs` is published.
using GraphExecutionNodeCallback = std::function<core::Status(
    const ExecutionPlanNode& node,
    const std::vector<ResolvedGpuFrameInput>& resolvedInputs,
    std::vector<GpuFrameToken>& outOutputs)>;

// Outcome of one successful GraphExecutionDispatcher::dispatch() call. Left
// default-constructed (all zero) whenever dispatch() returns a non-ok
// Status.
struct GraphExecutionDispatchResult {
    uint32_t nodesDispatched{0};
    uint32_t outputsPublished{0};
};

// Graph-layer dispatcher that walks a GraphExecutionPlan in dependency
// order, resolving each node's GPU-bearing input tokens from a
// GpuFrameTokenSession, invoking a callback per node, and publishing
// whatever GPU output tokens that callback returns.
class GraphExecutionDispatcher {
public:
    // Fails closed (leaves `outResult` default-constructed, returns a
    // non-ok Status, and invokes no callback) when:
    //   - `plan.nodes` is empty;
    //   - `callback` has no target (an empty std::function);
    //   - `session`'s evaluatedPtsUs/evaluatedGeneration does not match
    //     `plan`'s (stale session); or
    //   - any plan node's executionIndex does not equal its position in
    //     `plan.nodes` - checked over the whole plan before any callback
    //     runs.
    //
    // Otherwise, for every node in `plan.nodes`, in order:
    //   1. Resolves only that node's GPU-bearing (kVideoFrame/
    //      kTextureBuffer) input bindings against `session`, in binding
    //      order, into `resolvedInputs`; non-GPU-bearing bindings
    //      (kAudioPacket, kMetadata) are skipped without failure and never
    //      appear in `resolvedInputs`. If resolving a GPU-bearing binding
    //      fails (e.g. an unresolved consumer input), dispatch stops and
    //      returns that error; no callback is invoked for this node.
    //   2. Invokes `callback(node, resolvedInputs, outOutputs)`. If it
    //      returns a non-ok Status, dispatch stops before publishing any of
    //      `outOutputs` and returns that same Status.
    //   3. For each token in `outOutputs`, in order, validates before
    //      publishing: token.producingNodeId equals node.nodeId; token.
    //      outputPortId names exactly one declared port in node.
    //      outputPorts; that declared port's dataType is GPU-bearing.
    //      Then publishes the token via `session.publish()`, which itself
    //      fails closed on an invalid handle/descriptor, a stale pts/
    //      generation, or a duplicate publish. Any of these failures stops
    //      dispatch immediately and returns that error. A node may return a
    //      subset of its declared outputs, or none at all (sinks naturally
    //      return none); under-production is caught later by the consuming
    //      node's own unresolved-input failure, not here.
    //
    // On any failure, dispatch stops before invoking any downstream node's
    // callback and returns the first error. There is no rollback: tokens
    // already published to `session` by earlier nodes in this same call are
    // left in place; the caller must discard `session` on failure.
    // `outResult` is filled only when every node dispatches successfully.
    core::Status dispatch(const GraphExecutionPlan& plan,
                          GpuFrameTokenSession& session,
                          const GraphExecutionNodeCallback& callback,
                          GraphExecutionDispatchResult& outResult) const;
};

} // namespace graph
} // namespace vanguard
