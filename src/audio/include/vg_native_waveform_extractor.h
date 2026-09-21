#pragma once

#include <vector>
#include <string>
#include <cstdint>

namespace vanguard {

struct VgNativeWaveformResult {
    bool success = false;
    std::vector<float> samples;
    double durationSeconds = 0.0;
    int32_t samplesPerSecond = 0;
    int32_t pointCount = 0;
    std::string errorMessage;
};

class VgNativeWaveformExtractor {
public:
    static VgNativeWaveformResult extract(
        const std::string& path,
        int32_t samplesPerSecond,
        double maxDurationSeconds
    );
};

} // namespace vanguard
