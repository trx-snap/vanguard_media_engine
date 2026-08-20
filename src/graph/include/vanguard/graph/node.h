#pragma once
#include "vanguard/core/status.h"
#include <string>

namespace vanguard {
namespace graph {

class Node {
public:
    virtual ~Node() = default;
    virtual std::string id() const = 0;
};

} // namespace graph
} // namespace vanguard
