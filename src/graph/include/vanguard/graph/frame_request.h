#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace vanguard {
namespace graph {

enum class EvaluationStatusCode {
    kSuccess = 0,
    kInvalidGraph,
    kStaleGeneration,
    kOutOfTimelineBounds,
    kNoActiveNodes,
    kEvaluationError
};

struct FrameRequest {
    uint64_t timelinePtsUs{0};
    uint64_t generationId{0};
    uint32_t canvasWidth{1080};
    uint32_t canvasHeight{1920};
    bool     isSeek{false};
    bool     isPreroll{false};
};

struct ActiveNodeInfo {
    std::string nodeId;
    NodeType    nodeType;
    NodeKind    nodeKind;
    uint64_t    localPtsUs{0};
    float       weight{1.0f};
    uint32_t    layerIndex{0};
};

struct FrameEvaluationResult {
    EvaluationStatusCode               statusCode{EvaluationStatusCode::kSuccess};
    std::string                        errorMessage;
    uint64_t                           evaluatedPtsUs{0};
    uint64_t                           evaluatedGeneration{0};
    std::vector<std::shared_ptr<Node>> activeNodes;
    std::vector<ActiveNodeInfo>        activeNodeDetails;
    bool                               hasVideo{false};
    bool                               hasAudio{false};

    bool ok() const { return statusCode == EvaluationStatusCode::kSuccess; }
};

} // namespace graph
} // namespace vanguard
