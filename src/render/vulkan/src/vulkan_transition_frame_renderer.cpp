// vulkan_transition_frame_renderer.cpp
// P5-COMPOSITOR-TRANS: transition-only helpers for VulkanFrameRenderer's
// two-source clip overlap transition frame. See the header for ownership.
//
// Placement / draw-mode helpers compile on every platform (pure math);
// draw-list construction and the blend pipeline are Android-only.

#include "vulkan_transition_frame_renderer.h"

#include <algorithm>
#include <cmath>

#if defined(__ANDROID__)
#include <android/log.h>
#define VGLOG_VTFR(...) __android_log_print(ANDROID_LOG_DEBUG, "VanguardVkTransitionFrame", __VA_ARGS__)
#endif

namespace vanguard {
namespace render {

// ---------------------------------------------------------------------------
// Draw model
// ---------------------------------------------------------------------------

bool ResolveVulkanTransitionDrawMode(const VideoTransitionFrameTransform& transition,
                                     VulkanTransitionDrawMode* outMode) {
    if (outMode == nullptr) return false;
    const double wFrom = transition.blendWeightFrom;
    const double wTo = transition.blendWeightTo;
    if (!std::isfinite(wFrom) || !std::isfinite(wTo) || !std::isfinite(transition.progress)) {
        return false;
    }
    VulkanTransitionDrawMode mode;
    if (wTo <= 0.0) {
        mode = VulkanTransitionDrawMode::kFromOnly;
    } else if (wFrom <= 0.0) {
        mode = VulkanTransitionDrawMode::kToOnly;
    } else if (wFrom >= 1.0 && wTo >= 1.0) {
        mode = VulkanTransitionDrawMode::kPaintOver;
    } else {
        mode = VulkanTransitionDrawMode::kCrossfade;
        if (!transition.fromViewport.isIdentity() || !transition.toViewport.isIdentity() ||
            !transition.fromCrop.isIdentity() || !transition.toCrop.isIdentity()) {
            return false;
        }
    }
    *outMode = mode;
    return true;
}

// ---------------------------------------------------------------------------
// Placement math
// ---------------------------------------------------------------------------

namespace {

VulkanTransitionPixelRect intersectRects(const VulkanTransitionPixelRect& a,
                                         const VulkanTransitionPixelRect& b) {
    VulkanTransitionPixelRect r;
    r.x = std::max(a.x, b.x);
    r.y = std::max(a.y, b.y);
    r.right = std::min(a.right, b.right);
    r.bottom = std::min(a.bottom, b.bottom);
    return r;
}

bool isFiniteNormalizedRect(const RenderNormalizedRect& r) {
    return std::isfinite(r.x) && std::isfinite(r.y) &&
           std::isfinite(r.width) && std::isfinite(r.height) &&
           r.width >= 0.0 && r.height >= 0.0;
}

// Viewports may lie outside [0,1]; crops must stay inside [0,1].
bool isCropInsideUnit(const RenderNormalizedRect& c) {
    const double eps = 1e-9;
    return c.x >= -eps && c.y >= -eps &&
           c.x + c.width <= 1.0 + eps && c.y + c.height <= 1.0 + eps;
}

int32_t roundToPixel(double v) {
    // Viewports are bounded to a few canvas widths by the placement math;
    // clamp defensively so a pathological value can never overflow int32.
    const double clamped = std::max(-65536.0, std::min(65536.0, v));
    return static_cast<int32_t>(std::lround(clamped));
}

} // anonymous namespace

bool ResolveVulkanTransitionLayerPlacement(const VideoFrameTransform& layer,
                                           const RenderNormalizedRect& viewport,
                                           const RenderNormalizedRect& crop,
                                           uint32_t extentWidth,
                                           uint32_t extentHeight,
                                           VulkanTransitionLayerPlacement* out) {
    if (out == nullptr || extentWidth == 0 || extentHeight == 0) return false;
    *out = VulkanTransitionLayerPlacement{};
    if (!isFiniteNormalizedRect(viewport) || !isFiniteNormalizedRect(crop) ||
        !isCropInsideUnit(crop)) {
        return false;
    }
    const double W = static_cast<double>(extentWidth);
    const double H = static_cast<double>(extentHeight);

    // Layer canvas destination rect (aspect fit), full extent when default.
    double dx = 0.0, dy = 0.0, dw = W, dh = H;
    if (!layer.destinationRect.isDefault()) {
        if (layer.destinationRect.width <= 0 || layer.destinationRect.height <= 0 ||
            layer.destinationRect.x < 0 || layer.destinationRect.y < 0 ||
            static_cast<int64_t>(layer.destinationRect.x) + layer.destinationRect.width >
                static_cast<int64_t>(extentWidth) ||
            static_cast<int64_t>(layer.destinationRect.y) + layer.destinationRect.height >
                static_cast<int64_t>(extentHeight)) {
            return false;
        }
        dx = static_cast<double>(layer.destinationRect.x);
        dy = static_cast<double>(layer.destinationRect.y);
        dw = static_cast<double>(layer.destinationRect.width);
        dh = static_cast<double>(layer.destinationRect.height);
    }

    // The whole layer canvas is placed at the transition viewport, so the
    // destination rect scales about the canvas origin and translates with it.
    const double vx0 = viewport.x * W + dx * viewport.width;
    const double vy0 = viewport.y * H + dy * viewport.height;
    const double vx1 = vx0 + dw * viewport.width;
    const double vy1 = vy0 + dh * viewport.height;
    out->viewport.x = roundToPixel(vx0);
    out->viewport.y = roundToPixel(vy0);
    out->viewport.right = roundToPixel(vx1);
    out->viewport.bottom = roundToPixel(vy1);

    // Visible canvas region = crop mapped through the viewport, clipped.
    const double rx0 = (viewport.x + crop.x * viewport.width) * W;
    const double ry0 = (viewport.y + crop.y * viewport.height) * H;
    const double rx1 = (viewport.x + (crop.x + crop.width) * viewport.width) * W;
    const double ry1 = (viewport.y + (crop.y + crop.height) * viewport.height) * H;
    VulkanTransitionPixelRect canvas;
    canvas.x = 0;
    canvas.y = 0;
    canvas.right = static_cast<int32_t>(extentWidth);
    canvas.bottom = static_cast<int32_t>(extentHeight);
    VulkanTransitionPixelRect region;
    region.x = roundToPixel(rx0);
    region.y = roundToPixel(ry0);
    region.right = roundToPixel(rx1);
    region.bottom = roundToPixel(ry1);
    out->region = intersectRects(region, canvas);
    if (out->region.empty()) {
        out->visible = false;
        return true;
    }
    out->content = intersectRects(out->viewport, out->region);
    out->visible = true;
    return true;
}

#if defined(__ANDROID__)

// ---------------------------------------------------------------------------
// Draw-list construction
// ---------------------------------------------------------------------------

namespace {

// Black fill push constants: zero color matrix rows, opaque alpha offset.
VideoTransformFullPushConstants makeBlackPushConstants() {
    VideoTransformFullPushConstants pc{};
    pc.uv.uvTransform0[0] = 1.0f;
    pc.uv.uvTransform1[1] = 1.0f;
    pc.color.offset[3] = 1.0f;
    return pc;
}

bool appendTransitionDraw(VulkanTransitionPassParams* params,
                          const VulkanTransitionLayerResources& res,
                          const VulkanTransitionPixelRect& viewport,
                          const VulkanTransitionPixelRect& scissor,
                          const VideoTransformFullPushConstants& pc) {
    if (params->drawCount >= kVulkanTransitionMaxLayerDraws) return false;
    if (viewport.empty() || scissor.empty()) return true; // nothing to draw
    VulkanTransitionLayerDraw& d = params->draws[params->drawCount++];
    d.pipeline = res.pipeline;
    d.pipelineLayout = res.pipelineLayout;
    d.descriptorSet = res.descriptorSet;
    d.pushConstants = pc;
    d.viewportX = viewport.x;
    d.viewportY = viewport.y;
    d.viewportWidth = viewport.width();
    d.viewportHeight = viewport.height();
    d.scissorX = scissor.x;
    d.scissorY = scissor.y;
    d.scissorWidth = scissor.width();
    d.scissorHeight = scissor.height();
    d.useBlendConstants = res.useBlendConstants;
    d.blendConstant = res.blendConstant;
    return true;
}

} // anonymous namespace

bool AppendVulkanTransitionLayer(VulkanTransitionPassParams* params,
                                 const VulkanTransitionLayerResources& res,
                                 const VulkanTransitionLayerPlacement& placement,
                                 bool includeBands) {
    if (params == nullptr) return false;
    if (!placement.visible) return true;
    const VulkanTransitionPixelRect& R = placement.region;
    const VulkanTransitionPixelRect& C = placement.content;
    if (includeBands) {
        const VideoTransformFullPushConstants black = makeBlackPushConstants();
        if (C.empty()) {
            if (!appendTransitionDraw(params, res, R, R, black)) return false;
        } else {
            VulkanTransitionPixelRect band;
            // top
            band.x = R.x; band.y = R.y; band.right = R.right; band.bottom = C.y;
            if (!appendTransitionDraw(params, res, band, band, black)) return false;
            // bottom
            band.x = R.x; band.y = C.bottom; band.right = R.right; band.bottom = R.bottom;
            if (!appendTransitionDraw(params, res, band, band, black)) return false;
            // left
            band.x = R.x; band.y = C.y; band.right = C.x; band.bottom = C.bottom;
            if (!appendTransitionDraw(params, res, band, band, black)) return false;
            // right
            band.x = C.right; band.y = C.y; band.right = R.right; band.bottom = C.bottom;
            if (!appendTransitionDraw(params, res, band, band, black)) return false;
        }
    }
    return appendTransitionDraw(params, res, placement.viewport, C, res.pushConstants);
}

// ---------------------------------------------------------------------------
// Constant-alpha blend pipeline
// ---------------------------------------------------------------------------

bool CreateVulkanTransitionBlendPipeline(VkDevice device,
                                         VkPipelineLayout pipelineLayout,
                                         VkRenderPass renderPass,
                                         VkShaderModule vertShader,
                                         VkShaderModule fragShader,
                                         VkPipeline* outPipeline) {
    if (outPipeline == nullptr) return false;
    *outPipeline = VK_NULL_HANDLE;
    if (device == VK_NULL_HANDLE || pipelineLayout == VK_NULL_HANDLE ||
        renderPass == VK_NULL_HANDLE || vertShader == VK_NULL_HANDLE ||
        fragShader == VK_NULL_HANDLE) {
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage  = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertShader;
    stages[0].pName  = "main";
    stages[1].sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage  = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragShader;
    stages[1].pName  = "main";

    VkPipelineVertexInputStateCreateInfo vertexInput{};
    vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    VkPipelineInputAssemblyStateCreateInfo inputAssembly{};
    inputAssembly.sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssembly.primitiveRestartEnable = VK_FALSE;

    const VkDynamicState dynamicStates[] = {
        VK_DYNAMIC_STATE_VIEWPORT,
        VK_DYNAMIC_STATE_SCISSOR,
        VK_DYNAMIC_STATE_BLEND_CONSTANTS,
    };
    VkPipelineDynamicStateCreateInfo dynamicState{};
    dynamicState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 3;
    dynamicState.pDynamicStates    = dynamicStates;

    VkPipelineViewportStateCreateInfo viewportState{};
    viewportState.sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.scissorCount  = 1;

    VkPipelineRasterizationStateCreateInfo rasterizer{};
    rasterizer.sType       = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizer.cullMode    = VK_CULL_MODE_NONE;
    rasterizer.frontFace   = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterizer.lineWidth   = 1.0f;

    VkPipelineMultisampleStateCreateInfo multisampling{};
    multisampling.sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    multisampling.minSampleShading     = 1.0f;

    VkPipelineColorBlendAttachmentState attachment{};
    attachment.blendEnable         = VK_TRUE;
    attachment.srcColorBlendFactor = VK_BLEND_FACTOR_CONSTANT_ALPHA;
    attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA;
    attachment.colorBlendOp        = VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    attachment.alphaBlendOp        = VK_BLEND_OP_ADD;
    attachment.colorWriteMask      = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                     VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo colorBlend{};
    colorBlend.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlend.logicOpEnable   = VK_FALSE;
    colorBlend.logicOp         = VK_LOGIC_OP_COPY;
    colorBlend.attachmentCount = 1;
    colorBlend.pAttachments    = &attachment;

    VkGraphicsPipelineCreateInfo pipelineCI{};
    pipelineCI.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineCI.stageCount          = 2;
    pipelineCI.pStages             = stages;
    pipelineCI.pVertexInputState   = &vertexInput;
    pipelineCI.pInputAssemblyState = &inputAssembly;
    pipelineCI.pViewportState      = &viewportState;
    pipelineCI.pRasterizationState = &rasterizer;
    pipelineCI.pMultisampleState   = &multisampling;
    pipelineCI.pColorBlendState    = &colorBlend;
    pipelineCI.pDynamicState       = &dynamicState;
    pipelineCI.layout              = pipelineLayout;
    pipelineCI.renderPass          = renderPass;
    pipelineCI.subpass             = 0;
    pipelineCI.basePipelineHandle  = VK_NULL_HANDLE;
    pipelineCI.basePipelineIndex   = -1;

    VkPipeline pipeline = VK_NULL_HANDLE;
    const VkResult result = vkCreateGraphicsPipelines(
        device, VK_NULL_HANDLE, 1, &pipelineCI, nullptr, &pipeline);
    if (result != VK_SUCCESS) {
        VGLOG_VTFR("transition blend vkCreateGraphicsPipelines failed: %d",
                   static_cast<int>(result));
        return false;
    }
    *outPipeline = pipeline;
    return true;
}

#endif // __ANDROID__

} // namespace render
} // namespace vanguard
