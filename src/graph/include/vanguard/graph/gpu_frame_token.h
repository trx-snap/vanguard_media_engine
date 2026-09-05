// P1-DAG-MULTINODE-GPU-FRAME-TOKEN-CONTRACT: platform-neutral, non-owning
// GPU frame token identity/binding contract.
//
// This header defines the data-plane identity and consumer-binding shape for
// a GPU-backed frame produced during one GraphExecutionPlan evaluation. It is
// deliberately inert: no AHardwareBuffer*, no JNI/Android/Vulkan/EGL headers,
// no file descriptors, no dup/close/acquire/release, no allocation/import/
// render. `handle` is a backend-owned opaque vanguard::render::
// HardwareBufferHandle value; token identity always derives from that value,
// never from any platform buffer pointer. Fence presence is recorded as
// plain booleans, not as file descriptors - actual fence transport remains
// entirely the platform backend's responsibility.
//
// GpuFrameTokenSession is a non-owning publish/resolve ledger scoped to the
// lifetime of a single GraphExecutionPlan evaluation (identified by that
// plan's evaluatedPtsUs/evaluatedGeneration). It never reads vanguard::graph
// ::Graph directly - it only accepts vanguard::graph::ExecutionInputBinding
// values already resolved by BuildGraphExecutionPlan, plus caller-supplied
// GpuFrameToken values. It fails closed (returns a non-ok core::Status and
// leaves its published-token state unchanged) on: duplicate publish for the
// same producing node/output-port key, an unresolved consumer input (no
// token published for the binding's from-node/from-port key), a stale
// evaluatedPtsUs/evaluatedGeneration mismatch between a token and this
// session, an invalid (kInvalidHardwareBufferHandle) handle, an empty
// producing-node/output-port/consumer-binding id, or an invalid descriptor.
#pragma once
#include "vanguard/core/status.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/render/hardware_buffer_import.h"
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>

namespace vanguard {
namespace graph {

// Mirrors vanguard::render::HardwareBufferDescriptor's fields exactly, by
// value. Kept as a distinct type so this header never needs to include any
// backend-owning render translation unit.
struct GpuFrameDescriptor {
    uint32_t width{0};
    uint32_t height{0};
    uint32_t layers{0};
    uint32_t format{0};
    uint32_t stride{0};
    uint64_t usage{0};
};

// Non-owning identity/binding token for one produced GPU frame. Copyable by
// value; holds no OS/GPU resource and requires no explicit release.
struct GpuFrameToken {
    vanguard::render::HardwareBufferHandle handle{vanguard::render::kInvalidHardwareBufferHandle};
    GpuFrameDescriptor                     descriptor{};
    std::string                            producingNodeId;
    std::string                            outputPortId;
    uint64_t                               evaluatedPtsUs{0};
    uint64_t                               evaluatedGeneration{0};
    bool                                   hasAcquireFence{false};
    bool                                   hasReleaseFence{false};
};

// Returns true iff `descriptor` describes a plausible GPU frame: non-zero
// width, height, and layers. Stride/format/usage are backend-defined and are
// not range-checked here (a stride of 0 is a legitimate "not applicable"
// value per vanguard::render::HardwareBufferDescriptor).
bool IsValidGpuFrameDescriptor(const GpuFrameDescriptor& descriptor);

// Returns true iff `token` is structurally valid: a non-invalid handle,
// non-empty producingNodeId/outputPortId, and a valid descriptor. Does not
// check evaluatedPtsUs/evaluatedGeneration against any session - that check
// is session-scoped (see GpuFrameTokenSession::publish).
bool IsValidGpuFrameToken(const GpuFrameToken& token);

// Non-owning publish/resolve ledger for the GPU frame tokens produced and
// consumed within one GraphExecutionPlan evaluation.
class GpuFrameTokenSession {
public:
    GpuFrameTokenSession(uint64_t evaluatedPtsUs, uint64_t evaluatedGeneration);

    uint64_t evaluatedPtsUs() const;
    uint64_t evaluatedGeneration() const;

    // Publishes `token` under its own (producingNodeId, outputPortId) key.
    // Fails closed (returns a non-ok Status; no state is mutated) when:
    //   - token.producingNodeId or token.outputPortId is empty;
    //   - token.handle == vanguard::render::kInvalidHardwareBufferHandle;
    //   - !IsValidGpuFrameDescriptor(token.descriptor);
    //   - token.evaluatedPtsUs/evaluatedGeneration does not match this
    //     session's evaluatedPtsUs/evaluatedGeneration (stale token); or
    //   - a token was already published for the same
    //     (producingNodeId, outputPortId) key (duplicate publish).
    core::Status publish(const GpuFrameToken& token);

    // Resolves `binding` (as produced by BuildGraphExecutionPlan) to the
    // token previously published for the (binding.fromNodeId,
    // binding.fromPortId) key. Fails closed (returns a non-ok Status;
    // `outToken` is left unchanged) when binding.inputPortId,
    // binding.fromNodeId, or binding.fromPortId is empty, or when no token
    // was published for that key (unresolved consumer input).
    core::Status resolve(const ExecutionInputBinding& binding, GpuFrameToken& outToken) const;

    // Deterministic count of tokens currently published in this session.
    size_t publishedCount() const;

private:
    struct Key {
        std::string nodeId;
        std::string portId;
        bool operator==(const Key& other) const {
            return nodeId == other.nodeId && portId == other.portId;
        }
    };
    struct KeyHash {
        size_t operator()(const Key& key) const {
            return std::hash<std::string>()(key.nodeId) ^
                   (std::hash<std::string>()(key.portId) << 1);
        }
    };

    uint64_t evaluatedPtsUs_;
    uint64_t evaluatedGeneration_;
    std::unordered_map<Key, GpuFrameToken, KeyHash> published_;
};

} // namespace graph
} // namespace vanguard
