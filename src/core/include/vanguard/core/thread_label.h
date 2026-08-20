#pragma once

namespace vanguard {
namespace core {

enum class ThreadLabel {
    kUnknown = 0,
    kDartIsolate,
    kNativeRender,
    kNativeCommand,
    kCodecWorker
};

} // namespace core
} // namespace vanguard
