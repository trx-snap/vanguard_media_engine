#include "vanguard/graph/graph_execution_dispatcher.h"

#include <cstddef>
#include <string>

namespace vanguard {
namespace graph {

namespace {

bool IsGpuBearingDataType(PortDataType type) {
    return type == PortDataType::kVideoFrame || type == PortDataType::kTextureBuffer;
}

} // namespace

core::Status GraphExecutionDispatcher::dispatch(const GraphExecutionPlan& plan,
                                                GpuFrameTokenSession& session,
                                                const GraphExecutionNodeCallback& callback,
                                                GraphExecutionDispatchResult& outResult) const {
    outResult = GraphExecutionDispatchResult{};

    if (plan.nodes.empty()) {
        return core::Status(core::StatusCode::kError,
                            "GraphExecutionDispatcher::dispatch: plan has no nodes");
    }
    if (!callback) {
        return core::Status(core::StatusCode::kError,
                            "GraphExecutionDispatcher::dispatch: callback is empty");
    }
    if (session.evaluatedPtsUs() != plan.evaluatedPtsUs ||
        session.evaluatedGeneration() != plan.evaluatedGeneration) {
        return core::Status(
            core::StatusCode::kError,
            "GraphExecutionDispatcher::dispatch: session evaluatedPtsUs/evaluatedGeneration "
            "does not match plan (stale session)");
    }
    for (size_t i = 0; i < plan.nodes.size(); ++i) {
        if (plan.nodes[i].executionIndex != static_cast<uint32_t>(i)) {
            return core::Status(
                core::StatusCode::kError,
                "GraphExecutionDispatcher::dispatch: node '" + plan.nodes[i].nodeId +
                    "' executionIndex does not match its position in the plan");
        }
    }

    uint32_t nodesDispatched = 0;
    uint32_t outputsPublished = 0;

    for (const auto& node : plan.nodes) {
        std::vector<ResolvedGpuFrameInput> resolvedInputs;
        resolvedInputs.reserve(node.inputs.size());
        for (const auto& binding : node.inputs) {
            if (!IsGpuBearingDataType(binding.dataType)) {
                continue;
            }
            GpuFrameToken token;
            core::Status resolveStatus = session.resolve(binding, token);
            if (!resolveStatus.ok()) {
                return core::Status(core::StatusCode::kError,
                                    "GraphExecutionDispatcher::dispatch: " + resolveStatus.message());
            }
            resolvedInputs.push_back(ResolvedGpuFrameInput{binding, token});
        }

        std::vector<GpuFrameToken> outputs;
        core::Status callbackStatus = callback(node, resolvedInputs, outputs);
        if (!callbackStatus.ok()) {
            return callbackStatus;
        }

        for (const auto& token : outputs) {
            if (token.producingNodeId != node.nodeId) {
                return core::Status(
                    core::StatusCode::kError,
                    "GraphExecutionDispatcher::dispatch: output token producingNodeId '" +
                        token.producingNodeId + "' does not match dispatching node '" +
                        node.nodeId + "'");
            }

            const PortDescriptor* declaredPort = nullptr;
            int matchCount = 0;
            for (const auto& port : node.outputPorts) {
                if (port.id == token.outputPortId) {
                    declaredPort = &port;
                    ++matchCount;
                }
            }
            if (matchCount != 1) {
                return core::Status(
                    core::StatusCode::kError,
                    "GraphExecutionDispatcher::dispatch: output port '" + token.outputPortId +
                        "' is not a unique declared output port on node '" + node.nodeId + "'");
            }
            if (!IsGpuBearingDataType(declaredPort->dataType)) {
                return core::Status(
                    core::StatusCode::kError,
                    "GraphExecutionDispatcher::dispatch: declared output port '" +
                        token.outputPortId + "' on node '" + node.nodeId +
                        "' is not GPU-bearing");
            }

            core::Status publishStatus = session.publish(token);
            if (!publishStatus.ok()) {
                return publishStatus;
            }
            ++outputsPublished;
        }

        ++nodesDispatched;
    }

    outResult.nodesDispatched = nodesDispatched;
    outResult.outputsPublished = outputsPublished;
    return core::Status::OK();
}

} // namespace graph
} // namespace vanguard
