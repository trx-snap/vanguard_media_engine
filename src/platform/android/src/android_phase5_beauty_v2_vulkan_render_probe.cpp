// android_phase5_beauty_v2_vulkan_render_probe.cpp
// P5-BEAUTY-V2-VULKAN-RENDER: implementation of the pure CPU reference math
// and synthetic probe-image generators declared in
// android_phase5_beauty_v2_vulkan_render_probe.h. See that header for the
// modularity rationale and the quantization contract.

#include "android_phase5_beauty_v2_vulkan_render_probe.h"

#include <algorithm>
#include <cmath>

namespace vanguard_probe_beauty_v2_vulkan {

namespace {

// Must equal the `kMaxLoopRadius` constant baked into beauty_v2_blur.frag
// (shaders/glsl/beauty_v2_blur.frag), mandatorily mirrored here so no proof
// lane can diverge from the GPU path for a reason unrelated to shader
// correctness. Every preset radius this diagnostic exercises (1, 7, 9, 12)
// is well under this cap.
constexpr int kMaxLoopRadius = 16;

float ToUnit(uint8_t v) { return static_cast<float>(v) / 255.0f; }

uint8_t QuantizeUnit(float v) {
    v = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    return static_cast<uint8_t>(std::floor(v * 255.0f + 0.5f));
}

struct Float3 {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
};

Float3 operator+(Float3 a, Float3 b) { return {a.r + b.r, a.g + b.g, a.b + b.b}; }
Float3 operator-(Float3 a, Float3 b) { return {a.r - b.r, a.g - b.g, a.b - b.b}; }
Float3 operator*(Float3 a, float s) { return {a.r * s, a.g * s, a.b * s}; }
float Dot(Float3 a, Float3 b) { return a.r * b.r + a.g * b.g + a.b * b.b; }
Float3 Clamp01(Float3 a) {
    auto c = [](float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); };
    return {c(a.r), c(a.g), c(a.b)};
}

Float3 PixelRgbF(const ProbeImage& img, int x, int y) {
    const Rgba8& p = img[static_cast<size_t>(y) * kProbeWidth + x];
    return {ToUnit(p.r), ToUnit(p.g), ToUnit(p.b)};
}

// Shared horizontal (axis=0) / vertical (axis=1) bilateral blur pass,
// matching beauty_v2_blur.frag exactly, including the same clamped
// texel-fetch boundary handling and the mandatory 8-bit UNORM
// round-to-nearest quantization of the output before the next pass reads it.
ProbeImage CpuBilateralBlurPass(const ProbeImage& input, int axis, int radius,
                                float sigma, float rangeSigma) {
    ProbeImage output(static_cast<size_t>(kProbePixelCount));
    const float twoSig2 = 2.0f * sigma * sigma;
    const float twoRangeSig2 = 2.0f * rangeSigma * rangeSigma;

    for (int y = 0; y < kProbeHeight; ++y) {
        for (int x = 0; x < kProbeWidth; ++x) {
            const Rgba8& centreTexel = input[static_cast<size_t>(y) * kProbeWidth + x];
            const Float3 centre = {ToUnit(centreTexel.r), ToUnit(centreTexel.g), ToUnit(centreTexel.b)};

            Float3 acc{0.0f, 0.0f, 0.0f};
            float wSum = 0.0f;
            for (int i = -kMaxLoopRadius; i <= kMaxLoopRadius; ++i) {
                if (i < -radius || i > radius) continue;
                int sx = x;
                int sy = y;
                if (axis == 0) {
                    sx = std::min(std::max(x + i, 0), kProbeWidth - 1);
                } else {
                    sy = std::min(std::max(y + i, 0), kProbeHeight - 1);
                }
                const Float3 tap = PixelRgbF(input, sx, sy);
                const float spatial = std::exp(-static_cast<float>(i * i) / twoSig2);
                const Float3 delta = tap - centre;
                const float range = std::exp(-Dot(delta, delta) / twoRangeSig2);
                const float w = spatial * range;
                acc = acc + tap * w;
                wSum += w;
            }

            const Float3 result = (wSum > 1e-6f) ? (acc * (1.0f / wSum)) : centre;
            output[static_cast<size_t>(y) * kProbeWidth + x] = {
                QuantizeUnit(result.r), QuantizeUnit(result.g), QuantizeUnit(result.b), centreTexel.a};
        }
    }
    return output;
}

// Matches beauty_v2_composite.frag exactly: fused highpass, variance proxy,
// adaptive smoothing gate, detail damping, tone compression, midtone lift,
// detail add-back, alpha preservation from the original.
ProbeImage CpuComposite(const ProbeImage& orig, const ProbeImage& mean,
                        const vanguard::render::VulkanBeautyV2Parameters& params) {
    ProbeImage output(static_cast<size_t>(kProbePixelCount));

    for (int y = 0; y < kProbeHeight; ++y) {
        for (int x = 0; x < kProbeWidth; ++x) {
            const size_t idx = static_cast<size_t>(y) * kProbeWidth + x;
            const Rgba8& origTexel = orig[idx];
            const Float3 origF = {ToUnit(origTexel.r), ToUnit(origTexel.g), ToUnit(origTexel.b)};
            const Float3 meanF = PixelRgbF(mean, x, y);

            const Float3 highPass = Clamp01(origF - meanF + Float3{0.5f, 0.5f, 0.5f}) - Float3{0.5f, 0.5f, 0.5f};
            const float varLuma = (std::fabs(highPass.r) + std::fabs(highPass.g) + std::fabs(highPass.b)) / 3.0f;

            float k = (1.0f - varLuma / (varLuma + params.theta)) * params.smoothStrength;
            k = std::min(std::max(k, 0.0f), 1.0f);

            const Float3 smoothed = origF + (meanF - origF) * k;
            const Float3 dampedDetail = highPass * params.detailDamping;

            const float luma = 0.299f * smoothed.r + 0.587f * smoothed.g + 0.114f * smoothed.b;
            const float compressed = luma - params.toneStrength * 0.08f * std::sin(luma * 3.14159265f);
            const float toneScale = (luma > 0.001f) ? (compressed / luma) : 1.0f;
            const Float3 toned = Clamp01(smoothed * toneScale);

            const float lift = params.midtoneLift * 4.0f * luma * (1.0f - luma);
            const Float3 lifted = Clamp01(toned + Float3{lift, lift, lift});

            const Float3 beauty = Clamp01(lifted + dampedDetail * (params.sharpenStrength * 2.0f));

            output[idx] = {QuantizeUnit(beauty.r), QuantizeUnit(beauty.g), QuantizeUnit(beauty.b), origTexel.a};
        }
    }
    return output;
}

uint32_t HashPixel(int x, int y, uint32_t salt) {
    uint32_t h = static_cast<uint32_t>(x) * 374761393u + static_cast<uint32_t>(y) * 668265263u +
                 salt * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= (h >> 16);
    return h;
}

} // namespace

ProbeImage MakeFlatProbe(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return ProbeImage(static_cast<size_t>(kProbePixelCount), Rgba8{r, g, b, a});
}

ProbeImage MakeGradientProbe() {
    ProbeImage img(static_cast<size_t>(kProbePixelCount));
    for (int y = 0; y < kProbeHeight; ++y) {
        for (int x = 0; x < kProbeWidth; ++x) {
            const uint8_t v = static_cast<uint8_t>(
                std::lround(static_cast<float>(x) / static_cast<float>(kProbeWidth - 1) * 255.0f));
            img[static_cast<size_t>(y) * kProbeWidth + x] = {v, v, v, 255};
        }
    }
    return img;
}

ProbeImage MakeNoiseProbe() {
    ProbeImage img(static_cast<size_t>(kProbePixelCount));
    for (int y = 0; y < kProbeHeight; ++y) {
        for (int x = 0; x < kProbeWidth; ++x) {
            const uint8_t r = static_cast<uint8_t>(HashPixel(x, y, 1u) & 0xFFu);
            const uint8_t g = static_cast<uint8_t>(HashPixel(x, y, 2u) & 0xFFu);
            const uint8_t b = static_cast<uint8_t>(HashPixel(x, y, 3u) & 0xFFu);
            img[static_cast<size_t>(y) * kProbeWidth + x] = {r, g, b, 255};
        }
    }
    return img;
}

ProbeImage MakeStepEdgeProbe() {
    ProbeImage img(static_cast<size_t>(kProbePixelCount));
    for (int y = 0; y < kProbeHeight; ++y) {
        for (int x = 0; x < kProbeWidth; ++x) {
            const uint8_t v = (x < kProbeWidth / 2) ? 0 : 255;
            img[static_cast<size_t>(y) * kProbeWidth + x] = {v, v, v, 255};
        }
    }
    return img;
}

ProbeImage MakeMidtoneProbe() { return MakeFlatProbe(128, 128, 128, 255); }

ProbeImage ComputeCpuReference(const ProbeImage& input,
                               const vanguard::render::VulkanBeautyV2Parameters& params) {
    const ProbeImage passA = CpuBilateralBlurPass(input, 0, params.radius, params.sigma, params.rangeSigma);
    const ProbeImage passB = CpuBilateralBlurPass(passA, 1, params.radius, params.sigma, params.rangeSigma);
    return CpuComposite(input, passB, params);
}

ParityResult CompareImages(const ProbeImage& gpu, const ProbeImage& cpu) {
    ParityResult result;
    double sumAbsError = 0.0;
    size_t sampleCount = 0;
    const size_t n = std::min(gpu.size(), cpu.size());
    for (size_t i = 0; i < n; ++i) {
        const int dr = std::abs(static_cast<int>(gpu[i].r) - static_cast<int>(cpu[i].r));
        const int dg = std::abs(static_cast<int>(gpu[i].g) - static_cast<int>(cpu[i].g));
        const int db = std::abs(static_cast<int>(gpu[i].b) - static_cast<int>(cpu[i].b));
        const int da = std::abs(static_cast<int>(gpu[i].a) - static_cast<int>(cpu[i].a));
        result.maxDeltaR = std::max(result.maxDeltaR, dr);
        result.maxDeltaG = std::max(result.maxDeltaG, dg);
        result.maxDeltaB = std::max(result.maxDeltaB, db);
        result.maxDeltaA = std::max(result.maxDeltaA, da);
        sumAbsError += dr + dg + db + da;
        sampleCount += 4;
    }
    result.meanAbsoluteError = sampleCount > 0 ? sumAbsError / static_cast<double>(sampleCount) : 0.0;
    result.withinTolerance = result.maxDeltaR <= 2 && result.maxDeltaG <= 2 && result.maxDeltaB <= 2 &&
                             result.maxDeltaA <= 2 && result.meanAbsoluteError < 1.0;
    return result;
}

double ComputeMeanLuma(const ProbeImage& image) {
    if (image.empty()) return 0.0;
    double sum = 0.0;
    for (const Rgba8& p : image) {
        sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
    return sum / static_cast<double>(image.size());
}

double ComputeLumaVariance(const ProbeImage& image) {
    if (image.empty()) return 0.0;
    const double mean = ComputeMeanLuma(image);
    double sumSq = 0.0;
    for (const Rgba8& p : image) {
        const double luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        const double d = luma - mean;
        sumSq += d * d;
    }
    return sumSq / static_cast<double>(image.size());
}

int LumaStepDelta(const ProbeImage& image, int xLeft, int xRight, int y) {
    auto lumaAt = [&](int x) {
        const Rgba8& p = image[static_cast<size_t>(y) * kProbeWidth + x];
        return static_cast<int>(std::lround(0.299 * p.r + 0.587 * p.g + 0.114 * p.b));
    };
    return std::abs(lumaAt(xRight) - lumaAt(xLeft));
}

} // namespace vanguard_probe_beauty_v2_vulkan
