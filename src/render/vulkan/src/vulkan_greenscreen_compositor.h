// vulkan_greenscreen_compositor.h
// DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: Private helper -
// VulkanGreenScreenCompositor.
//
// Blends a caller-owned foreground RGBA8 image over a caller-owned
// background RGBA8 image using a caller-owned single-channel R8 mask image
// (the Duet green-screen / segmentation matte) into a caller-owned offscreen
// RGBA8_UNORM color attachment, then copies the attachment into a
// caller-owned host-visible readback buffer. The mask may have any
// resolution: all three textures are sampled with the same normalized
// framebuffer coordinate, so a lower-resolution mask is scaled by its sampler
// (the diagnostic composition root proves a 17x19 mask over a 64x48 output).
//
// This helper is diagnostic-only in this slice. It is NOT a graph node, owns
// no Duet / camera / segmentation / export state, and does not touch
// production VulkanBackend / VulkanDescriptorResources /
// VulkanGraphicsCommandRecorder state or the production Duet preview/export
// route (AndroidDuetPreviewCompositor / AndroidDuetExportSession are never
// referenced). vanguard_render_vulkan keeps its dependency direction: this
// header never includes a compositors, graph, or Dart-facing header, exactly
// like VulkanOverlayCompositor and VulkanBeautyV2Compositor.
//
// Pinned color / alpha contract (mirrored by greenscreen_blend.frag, by the
// pure CPU reference below, and by the diagnostic JSON `colorContract` /
// `blendFormula` fields):
//   * background / foreground images: VK_FORMAT_R8G8B8A8_UNORM, straight
//     (non-premultiplied) color; sampled as normalized [0,1] floats.
//   * mask image: VK_FORMAT_R8_UNORM; the .r channel is sampled as the
//     normalized maskAlpha in [0,1] (0 -> background, 1 -> foreground).
//   * No sRGB <-> linear conversion anywhere: the target attachment is
//     RGBA8_UNORM (never an *_SRGB format), every operand is a UNORM sample,
//     and the arithmetic runs in normalized UNORM sample space.
//   * Formula (per fragment, in the fragment shader):
//       out.rgb = mix(background.rgb, foreground.rgb, maskAlpha)
//       out.a   = mix(background.a,   foreground.a,   maskAlpha)
//   * The fixed-function blend stage is DISABLED; the shader output is the
//     final attachment value (hardware round-to-nearest UNORM conversion).
//   * CPU reference (ComputeVulkanGreenScreenReferencePixel): the same
//     formula evaluated in double precision on the 8-bit inputs, i.e.
//       ref_c = round((bg_c * (255 - m) + fg_c * m) / 255)
//     with round-half-away-from-zero; the GPU's float32 evaluation plus
//     UNORM conversion (tie direction implementation-defined) can differ
//     from that by at most one code, so the readback comparison tolerance is
//     kVulkanGreenScreenReferenceColorTolerance (= 1) per channel.
//
// Shader strategy: the existing AOT passthrough fullscreen-triangle vertex
// module (shaders/passthrough_vert_spv.h) is reused unmodified with an
// identity UV transform, so the fragment varying is the normalized
// framebuffer coordinate ((x + 0.5) / W, (y + 0.5) / H), top-left origin,
// Y down. The new fragment module shaders/greenscreen_blend_frag_spv.h
// (source: shaders/glsl/greenscreen_blend.frag) samples background
// (binding 0), foreground (binding 1) and mask (binding 2) at that one
// coordinate and writes the mix. The vertex stage's declared 112-byte
// VideoTransformFullPushConstants block must be covered by the pipeline
// layout's vertex push-constant range even though only bytes [0,32) are
// meaningful; the fragment stage reads no push constants.
//
// Sampler contract (caller-owned, not validated): the diagnostic uses
// NEAREST + CLAMP_TO_EDGE for all three images so mask texel selection is
// floor(uv * maskSize), exactly what MapVulkanGreenScreenMaskTexel mirrors.
// A production caller may use LINEAR for the mask; the CPU reference here
// only models NEAREST.
//
// Ownership / lifecycle: owns only the temporary Vulkan objects it creates
// per blendGreenScreen() call (two shader modules, descriptor set layout, one
// descriptor pool holding one set, pipeline layout, render pass,
// framebuffer, one pipeline, one command buffer from the caller's pool, one
// fence) and destroys / frees all of them on every success and failure path
// before returning; temporaryObjectsCreated() == temporaryObjectsReleased()
// whenever no call is in progress. It never creates or destroys the device,
// queue, command pool, the three sampled images / views / samplers, the
// color attachment image / view, or the readback buffer / memory. The call
// is synchronous: it submits once and waits on its own fence, so on return
// the readback buffer holds the rendered RGBA8 pixels (tightly packed, row
// pitch = extentWidth * 4). The caller maps / invalidates the readback memory
// itself. Sampled images must already be in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; the attachment is left in
// VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL.
//
// Private source: this header is confined to the private Vulkan render
// backend implementation. On Android it includes <vulkan/vulkan.h>; on
// non-Android host builds the Vulkan handle fields become void*/uint32_t
// mirrors and blendGreenScreen() compiles to a safe unavailable stub,
// matching the other private Vulkan helpers. The pure validation / mask
// mapping / CPU reference math compiles on every platform.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#if defined(__ANDROID__)
#ifndef VK_USE_PLATFORM_ANDROID_KHR
#define VK_USE_PLATFORM_ANDROID_KHR
#endif
#include <vulkan/vulkan.h>
#endif

namespace vanguard {
namespace render {

// ── Pinned contract constants (all platforms) ───────────────────────────────

// Numeric VkFormat values of the pinned formats so host builds (no Vulkan
// headers) can still assert the contract. On Android the typed constants
// below are static_assert-ed against these.
constexpr uint32_t kVulkanGreenScreenColorFormatValue = 37u; // VK_FORMAT_R8G8B8A8_UNORM
constexpr uint32_t kVulkanGreenScreenMaskFormatValue  = 9u;  // VK_FORMAT_R8_UNORM

constexpr const char* kVulkanGreenScreenColorFormatName = "VK_FORMAT_R8G8B8A8_UNORM";
constexpr const char* kVulkanGreenScreenMaskFormatName  = "VK_FORMAT_R8_UNORM";

// Human/JSON-readable contract strings. The diagnostic pins these into its
// JSON payload and the Dart wrapper / physical smoke match them exactly.
constexpr const char* kVulkanGreenScreenColorContract =
    "rgba8_unorm_straight_alpha_fg_bg;r8_unorm_mask_as_normalized_maskAlpha;"
    "no_srgb_linear_conversion;unorm_sample_space_arithmetic;fixed_function_blend_disabled";
constexpr const char* kVulkanGreenScreenBlendFormula =
    "out.rgb=mix(background.rgb,foreground.rgb,maskAlpha);"
    "out.a=mix(background.a,foreground.a,maskAlpha)";
constexpr const char* kVulkanGreenScreenShaderSource =
    "aot_passthrough_vert_spv_reused_plus_new_greenscreen_blend_frag_spv";
constexpr const char* kVulkanGreenScreenReferenceRounding =
    "double_precision_round_half_away_from_zero_per_channel";

// Per-channel absolute tolerance when comparing GPU readback against
// ComputeVulkanGreenScreenReferencePixel (non-lossy RGBA8 readback).
constexpr int kVulkanGreenScreenReferenceColorTolerance = 1;

#if defined(__ANDROID__)
constexpr VkFormat kVulkanGreenScreenColorFormat = VK_FORMAT_R8G8B8A8_UNORM;
constexpr VkFormat kVulkanGreenScreenMaskFormat  = VK_FORMAT_R8_UNORM;
static_assert(static_cast<uint32_t>(kVulkanGreenScreenColorFormat) == kVulkanGreenScreenColorFormatValue,
              "pinned RGBA8_UNORM format value drifted");
static_assert(static_cast<uint32_t>(kVulkanGreenScreenMaskFormat) == kVulkanGreenScreenMaskFormatValue,
              "pinned R8_UNORM format value drifted");
#endif

// ── Caller-owned inputs / target ────────────────────────────────────────────

// One caller-owned combined image sampler pair. Not owned by the helper;
// both handles must be non-null and the image must already be in
// VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL.
struct VulkanGreenScreenSampledImage {
#if defined(__ANDROID__)
    VkImageView imageView = VK_NULL_HANDLE;
    VkSampler   sampler   = VK_NULL_HANDLE;
#else
    void* imageView = nullptr;
    void* sampler   = nullptr;
#endif
};

// The three sampled inputs of one blend. maskWidth / maskHeight are the
// mask image's texel dimensions (telemetry + validation: both must be > 0;
// the helper cannot query image extents from a view). They need not match
// the target extent.
struct VulkanGreenScreenInputs {
    VulkanGreenScreenSampledImage background; // RGBA8_UNORM, straight alpha
    VulkanGreenScreenSampledImage foreground; // RGBA8_UNORM, straight alpha
    VulkanGreenScreenSampledImage mask;       // R8_UNORM, .r == maskAlpha
    uint32_t maskWidth  = 0;
    uint32_t maskHeight = 0;
};

// Caller-owned device context plus offscreen render target and readback
// staging buffer. Nothing in this struct is created or destroyed by the
// helper.
struct VulkanGreenScreenRenderTarget {
#if defined(__ANDROID__)
    VkDevice      device      = VK_NULL_HANDLE;
    VkQueue       queue       = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    // Color attachment image: 2D, must be VK_FORMAT_R8G8B8A8_UNORM (the
    // pinned contract rejects any other format, including *_SRGB), single
    // mip / layer, usage must include COLOR_ATTACHMENT_BIT |
    // TRANSFER_SRC_BIT. Cleared to `clearColor` (every pixel is then
    // overwritten by the fullscreen draw) and left in
    // VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL after every successful render.
    VkImage       colorImage     = VK_NULL_HANDLE;
    VkImageView   colorImageView = VK_NULL_HANDLE;
    VkFormat      colorFormat    = VK_FORMAT_R8G8B8A8_UNORM;
    VkClearColorValue clearColor = {{0.0f, 0.0f, 0.0f, 1.0f}};
    // Host-visible readback buffer with usage TRANSFER_DST_BIT and size of at
    // least extentWidth * extentHeight * 4 bytes (declared by the caller in
    // readbackBufferSizeBytes; validated, not queried).
    VkBuffer      readbackBuffer          = VK_NULL_HANDLE;
    VkDeviceSize  readbackBufferSizeBytes = 0;
#else
    void*    device      = nullptr;
    void*    queue       = nullptr;
    void*    commandPool = nullptr;
    void*    colorImage     = nullptr;
    void*    colorImageView = nullptr;
    uint32_t colorFormat    = kVulkanGreenScreenColorFormatValue;
    float    clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    void*    readbackBuffer          = nullptr;
    uint64_t readbackBufferSizeBytes = 0;
#endif
    uint32_t extentWidth  = 0;
    uint32_t extentHeight = 0;
};

// ── Pure CPU reference (all platforms, no Vulkan calls) ─────────────────────

// Mask texel selected for output pixel (x, y) on an outputWidth x
// outputHeight target by a NEAREST / CLAMP_TO_EDGE sampler at the fragment
// centre: mx = floor((x + 0.5) * maskWidth / outputWidth) (same for y),
// evaluated exactly in integer arithmetic and clamped to the mask extent.
// Returns false (outputs untouched) when any dimension is 0 or (x, y) lies
// outside the output.
bool MapVulkanGreenScreenMaskTexel(uint32_t x,
                                   uint32_t y,
                                   uint32_t outputWidth,
                                   uint32_t outputHeight,
                                   uint32_t maskWidth,
                                   uint32_t maskHeight,
                                   uint32_t* outMaskX,
                                   uint32_t* outMaskY);

// Reference blend of one pixel per the pinned contract: for every channel
// c in {r, g, b, a}
//   out[c] = round((background[c] * (255 - maskValue) + foreground[c] * maskValue) / 255)
// (double precision, round-half-away-from-zero, clamped to [0, 255]), which
// is 255 * mix(bg/255, fg/255, maskValue/255) evaluated exactly. maskValue
// 0 reproduces `background` bit-exactly and 255 reproduces `foreground`.
void ComputeVulkanGreenScreenReferencePixel(const uint8_t background[4],
                                            const uint8_t foreground[4],
                                            uint8_t maskValue,
                                            uint8_t outPixel[4]);

// True when every channel of `actual` is within `tolerance` codes of
// `expected`. Returns the largest per-channel absolute delta through
// *outMaxDelta when non-null.
bool VulkanGreenScreenPixelWithinTolerance(const uint8_t actual[4],
                                           const uint8_t expected[4],
                                           int tolerance,
                                           int* outMaxDelta);

// Pure, platform-independent validation (no Vulkan calls) of target +
// inputs. Evaluates in exactly this order, returning false and setting
// *outError to the first failure:
//   "vulkan_greenscreen_compositor_invalid_argument"  - null device/queue/
//        commandPool/colorImage/colorImageView/readbackBuffer, zero extent,
//        or readbackBufferSizeBytes < extentWidth*extentHeight*4
//   "vulkan_greenscreen_compositor_invalid_format"    - colorFormat is not
//        VK_FORMAT_R8G8B8A8_UNORM (pinned contract; *_SRGB is rejected)
//   "vulkan_greenscreen_compositor_invalid_image"     - any of the three
//        imageView / sampler handles is null
//   "vulkan_greenscreen_compositor_invalid_mask_size" - maskWidth or
//        maskHeight == 0
// On success *outError is cleared and true is returned.
bool ValidateVulkanGreenScreenInputs(const VulkanGreenScreenRenderTarget& target,
                                     const VulkanGreenScreenInputs& inputs,
                                     std::string* outError);

class VulkanGreenScreenCompositor {
public:
    VulkanGreenScreenCompositor();
    ~VulkanGreenScreenCompositor();

    VulkanGreenScreenCompositor(const VulkanGreenScreenCompositor&) = delete;
    VulkanGreenScreenCompositor& operator=(const VulkanGreenScreenCompositor&) = delete;

    // Renders one full-target mask blend of inputs into target.colorImage,
    // copies it into target.readbackBuffer and waits for completion (see the
    // file header for the draw model and contract).
    //
    // outError - non-null; set to "" on success, to a validation reason from
    //            ValidateVulkanGreenScreenInputs, or to one of
    //            "vulkan_greenscreen_compositor_shader_module_failed"
    //            "vulkan_greenscreen_compositor_descriptor_failed"
    //            "vulkan_greenscreen_compositor_render_pass_failed"
    //            "vulkan_greenscreen_compositor_pipeline_failed"
    //            "vulkan_greenscreen_compositor_command_buffer_failed"
    //            "vulkan_greenscreen_compositor_submit_failed"
    //            "vulkan_greenscreen_compositor_wait_failed"
    //            for Vulkan-stage failures.
    //
    // Returns true only if every Vulkan object creation, the submit, and the
    // fence wait succeeded. Validation runs before any Vulkan call; on
    // validation failure zero Vulkan objects are created. Returns false with
    // outError="vulkan_greenscreen_compositor_unavailable_on_host" and no
    // Vulkan calls on non-Android builds.
    bool blendGreenScreen(const VulkanGreenScreenRenderTarget& target,
                          const VulkanGreenScreenInputs& inputs,
                          std::string* outError);

    // Lifecycle telemetry for diagnostics: cumulative count of temporary
    // Vulkan objects this instance created (successful vkCreate*/vkAllocate*)
    // and released (vkDestroy*/vkFree*). They are equal whenever no
    // blendGreenScreen() call is in progress; a difference indicates a leak.
    uint64_t temporaryObjectsCreated() const { return temporaryObjectsCreated_; }
    uint64_t temporaryObjectsReleased() const { return temporaryObjectsReleased_; }

private:
    uint64_t temporaryObjectsCreated_  = 0;
    uint64_t temporaryObjectsReleased_ = 0;
};

} // namespace render
} // namespace vanguard
