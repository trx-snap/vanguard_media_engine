#include "vanguard/graph/gpu_frame_token.h"

namespace vanguard {
namespace graph {

bool IsValidGpuFrameDescriptor(const GpuFrameDescriptor& descriptor) {
    return descriptor.width > 0 && descriptor.height > 0 && descriptor.layers > 0;
}

bool IsValidGpuFrameToken(const GpuFrameToken& token) {
    return token.handle != vanguard::render::kInvalidHardwareBufferHandle &&
           !token.producingNodeId.empty() &&
           !token.outputPortId.empty() &&
           IsValidGpuFrameDescriptor(token.descriptor);
}

GpuFrameTokenSession::GpuFrameTokenSession(uint64_t evaluatedPtsUs, uint64_t evaluatedGeneration)
    : evaluatedPtsUs_(evaluatedPtsUs), evaluatedGeneration_(evaluatedGeneration) {}

uint64_t GpuFrameTokenSession::evaluatedPtsUs() const { return evaluatedPtsUs_; }

uint64_t GpuFrameTokenSession::evaluatedGeneration() const { return evaluatedGeneration_; }

core::Status GpuFrameTokenSession::publish(const GpuFrameToken& token) {
    if (token.producingNodeId.empty()) {
        return core::Status(core::StatusCode::kError,
                            "GpuFrameTokenSession::publish: producingNodeId is empty");
    }
    if (token.outputPortId.empty()) {
        return core::Status(core::StatusCode::kError,
                            "GpuFrameTokenSession::publish: outputPortId is empty for node '" +
                                token.producingNodeId + "'");
    }
    if (token.handle == vanguard::render::kInvalidHardwareBufferHandle) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::publish: invalid handle for node '" +
                token.producingNodeId + "' port '" + token.outputPortId + "'");
    }
    if (!IsValidGpuFrameDescriptor(token.descriptor)) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::publish: invalid descriptor for node '" +
                token.producingNodeId + "' port '" + token.outputPortId + "'");
    }
    if (token.evaluatedPtsUs != evaluatedPtsUs_ ||
        token.evaluatedGeneration != evaluatedGeneration_) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::publish: stale evaluatedPtsUs/evaluatedGeneration for node '" +
                token.producingNodeId + "' port '" + token.outputPortId + "'");
    }

    const Key key{token.producingNodeId, token.outputPortId};
    if (published_.find(key) != published_.end()) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::publish: duplicate publish for node '" +
                token.producingNodeId + "' port '" + token.outputPortId + "'");
    }

    published_.emplace(key, token);
    return core::Status::OK();
}

core::Status GpuFrameTokenSession::resolve(const ExecutionInputBinding& binding,
                                           GpuFrameToken& outToken) const {
    if (binding.inputPortId.empty() || binding.fromNodeId.empty() || binding.fromPortId.empty()) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::resolve: binding has an empty inputPortId/fromNodeId/"
            "fromPortId");
    }

    const Key key{binding.fromNodeId, binding.fromPortId};
    const auto it = published_.find(key);
    if (it == published_.end()) {
        return core::Status(
            core::StatusCode::kError,
            "GpuFrameTokenSession::resolve: unresolved consumer input '" + binding.inputPortId +
                "'; no token published for node '" + binding.fromNodeId + "' port '" +
                binding.fromPortId + "'");
    }

    outToken = it->second;
    return core::Status::OK();
}

size_t GpuFrameTokenSession::publishedCount() const { return published_.size(); }

} // namespace graph
} // namespace vanguard
