// android_phase5_beauty_v2_gles_render_probe.h
// P5-BEAUTY-V2-GLES-RENDER: pure (no GL/EGL) CPU reference math and
// synthetic probe-image generators for the GlesBeautyV2Compositor
// shader/raster + CPU-parity diagnostic proof.
//
// Split out of android_phase5_beauty_v2_gles_render_jni.cpp per the
// Constitution modularity pre-authorization recorded in the readiness
// packet (section 4/11): incorporating the CPU reference math and 7 proof
// lanes in one translation unit risked crossing the 800-line mandatory
// review trigger. This header/'.cpp' pair owns only pure, platform-neutral
// reference math and fixture generation; the JNI translation unit keeps
// EGL/GL ownership, lane orchestration, and JSON serialization.
//
// The CPU reference mirrors the GLES shaders in gles_beauty_v2_compositor.cpp
// line-for-line (identical bilateral weighting, fused highpass, adaptive
// smoothing gate, tone compression, midtone lift, detail add-back) and
// quantizes Pass 1 and Pass 2 intermediate outputs to 8-bit UNORM via
// round-to-nearest (floor(clamp(v,0,1)*255+0.5)) before the next pass reads
// them, mirroring the GL_RGBA8 intermediate FBOs (readiness packet section 9,
// P1-12). A float-throughout CPU reference is forbidden because it can
// diverge from the GLES path for reasons unrelated to shader correctness;
// this implementation never does that.

#pragma once

#include <cstdint>
#include <vector>

#include "gles_beauty_v2_compositor.h"

namespace vanguard_probe_beauty_v2 {

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
// elements. No visual top/bottom orientation claim is made or needed: the
// same indexing convention is used for probe generation, glTexImage2D
// upload, glReadPixels comparison, and the CPU reference, so GPU and CPU
// results are directly index-comparable regardless of GL's bottom-row-first
// readback convention.
using ProbeImage = std::vector<Rgba8>;

ProbeImage MakeFlatProbe(uint8_t r, uint8_t g, uint8_t b, uint8_t a);
ProbeImage MakeGradientProbe();
ProbeImage MakeNoiseProbe();
ProbeImage MakeStepEdgeProbe();
ProbeImage MakeMidtoneProbe();

// Runs the exact CPU reference 3-pass pipeline (blur_h -> blur_v ->
// composite) over `input` with `params`, matching the GLES shaders exactly.
ProbeImage ComputeCpuReference(const ProbeImage& input,
                               const vanguard::render::GlesBeautyV2Parameters& params);

struct ParityResult {
    int maxDeltaR = 0;
    int maxDeltaG = 0;
    int maxDeltaB = 0;
    int maxDeltaA = 0;
    double meanAbsoluteError = 0.0;
    bool withinTolerance = false;
};

// Compares `gpu` (glReadPixels output) against `cpu` (ComputeCpuReference
// output) across every pixel/channel. Passes when max |delta| <= 2 LSB per
// channel and mean absolute error < 1.0 LSB (readiness packet section 9,
// P0-2 tolerance) -- the sole primary pass/fail gate; percent-reduction
// thresholds are never used.
ParityResult CompareImages(const ProbeImage& gpu, const ProbeImage& cpu);

// Population mean / variance of luma (0..255 scale) across the image;
// non-gating telemetry only (soft-preset smoothing-observed, max-preset
// midtone-lift comparison base).
double ComputeMeanLuma(const ProbeImage& image);
double ComputeLumaVariance(const ProbeImage& image);

// abs(luma(xRight,y) - luma(xLeft,y)); non-gating telemetry only
// (strong-preset edge-preservation).
int LumaStepDelta(const ProbeImage& image, int xLeft, int xRight, int y);

} // namespace vanguard_probe_beauty_v2
