// android_phase5_beauty_v2_vulkan_render_probe.h
// P5-BEAUTY-V2-VULKAN-RENDER: pure (no Vulkan calls) CPU reference math and
// synthetic probe-image generators for the VulkanBeautyV2Compositor
// shader/raster + CPU-parity diagnostic proof.
//
// Split out of android_phase5_beauty_v2_vulkan_render_jni.cpp mirroring the
// modularity precedent already recorded for the verified GLES twin
// (android_phase5_beauty_v2_gles_render_probe.h/.cpp): incorporating the CPU
// reference math and every proof lane in one translation unit risks crossing
// the mandatory review file-size trigger. This header/.cpp pair owns only
// pure, platform-neutral reference math and fixture generation; the JNI
// translation unit keeps Vulkan device/image ownership, lane orchestration,
// and JSON serialization.
//
// The CPU reference mirrors the beauty_v2_blur.frag / beauty_v2_composite.frag
// Vulkan shaders line-for-line (identical bilateral weighting, fused
// highpass, adaptive smoothing gate, tone compression, midtone lift, detail
// add-back), which are themselves an exact Vulkan port of the verified GLES
// shaders in gles_beauty_v2_compositor.cpp. It quantizes Pass 1 and Pass 2
// intermediate outputs to 8-bit UNORM via round-to-nearest
// (floor(clamp(v,0,1)*255+0.5)) before the next pass reads them, mirroring
// the VK_FORMAT_R8G8B8A8_UNORM intermediate images this helper renders into
// (frozen contract). A float-throughout CPU reference is forbidden because
// it can diverge from the GPU path for reasons unrelated to shader
// correctness; this implementation never does that.
//
// This header intentionally does not include gles_beauty_v2_compositor.h:
// vanguard_render_vulkan and its diagnostics must not depend on GLES. It
// operates purely on vanguard::render::VulkanBeautyV2Parameters (defined in
// vulkan_beauty_v2_compositor.h, itself GLES-independent).

#pragma once

#include <cstdint>
#include <vector>

#include "vulkan_beauty_v2_compositor.h"

namespace vanguard_probe_beauty_v2_vulkan {

constexpr int kProbeWidth = 64;
constexpr int kProbeHeight = 64;
constexpr int kProbePixelCount = kProbeWidth * kProbeHeight;

struct Rgba8 {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
    uint8_t a = 0;
};

// Row-major, index = y * kProbeWidth + x; always exactly kProbePixelCount
// elements. Matches the row convention used for probe generation, the
// staging-buffer upload into the source sampled image, the readback-buffer
// comparison, and the CPU reference, so GPU and CPU results are directly
// index-comparable.
using ProbeImage = std::vector<Rgba8>;

ProbeImage MakeFlatProbe(uint8_t r, uint8_t g, uint8_t b, uint8_t a);
ProbeImage MakeGradientProbe();
ProbeImage MakeNoiseProbe();
ProbeImage MakeStepEdgeProbe();
ProbeImage MakeMidtoneProbe();

// Runs the exact CPU reference 3-pass pipeline (blur_h -> blur_v ->
// composite) over `input` with `params`, matching the Vulkan fragment
// shaders exactly.
ProbeImage ComputeCpuReference(const ProbeImage& input,
                               const vanguard::render::VulkanBeautyV2Parameters& params);

struct ParityResult {
    int maxDeltaR = 0;
    int maxDeltaG = 0;
    int maxDeltaB = 0;
    int maxDeltaA = 0;
    double meanAbsoluteError = 0.0;
    bool withinTolerance = false;
};

// Compares `gpu` (readback-buffer output) against `cpu` (ComputeCpuReference
// output) across every pixel/channel. Passes when max |delta| <= 2 LSB per
// channel and mean absolute error < 1.0 LSB -- the sole primary pass/fail
// gate; percent-reduction thresholds are never used.
ParityResult CompareImages(const ProbeImage& gpu, const ProbeImage& cpu);

// Population mean / variance of luma (0..255 scale) across the image;
// non-gating telemetry only (soft-preset smoothing-observed, max-preset
// midtone-lift comparison base).
double ComputeMeanLuma(const ProbeImage& image);
double ComputeLumaVariance(const ProbeImage& image);

// abs(luma(xRight,y) - luma(xLeft,y)); non-gating telemetry only
// (strong-preset edge-preservation).
int LumaStepDelta(const ProbeImage& image, int xLeft, int xRight, int y);

} // namespace vanguard_probe_beauty_v2_vulkan
