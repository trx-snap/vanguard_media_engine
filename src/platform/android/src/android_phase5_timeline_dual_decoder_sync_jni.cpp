// P5-COMPOSITOR-TRANS (sub-slice DUAL-DECODER-SYNC): dual MediaCodec
// synchronized ingest -> AHardwareBuffer -> Vulkan crossfade proof JNI bridge.
//
// Android-only translation unit added via the CMake target_sources block.
// Kotlin (AndroidTimelineDualDecoderSyncDriver) owns both MediaExtractor /
// MediaCodec / ImageReader.PRIVATE pipelines and the lockstep stepping loop;
// for every overlap frame it pairs one Image from each decoder on its owner
// thread and calls this route once with both HardwareBuffers. This
// translation unit is the composition root that owns:
//   1. JNI argument validation (handles, dimensions, frame indexes, finite
//      progress in [0,1]),
//   2. lane orchestration over the private support module
//      (android_phase5_timeline_dual_decoder_sync_vulkan_support.h): libandroid
//      lookup, temporary VkDevice with the AHardwareBuffer import extension +
//      samplerYcbcrConversion feature, import of both buffers through the
//      private VulkanHardwareBufferImage helper, YCbCr -> RGBA8 resolve with
//      the existing AOT passthrough SPIR-V, three offscreen renders through
//      VulkanTimelineTransitionCompositor (progress 0 -> from only, 1 -> to
//      only, requested progress -> constant-alpha blend) with host readback,
//   3. the crossfade gate: vanguard::compositors::ComputeTransitionGeometry(
//      kCrossfade, progress) supplies the blend weights and the blended
//      readback is checked pixel-for-pixel against the two solo readbacks,
//   4. JSON result shaping (status / markers / lane flags / telemetry),
//   5. teardown accounting: every import, intermediate, scratch object and
//      AHardwareBuffer reference is released and the device destroyed before
//      returning; the teardown is itself a gate.
//
// Runtime support: no Vulkan driver, no AHardwareBuffer-capable device, no
// samplerYcbcrConversion feature or a missing extension entry point reports
// status "UNSUPPORTED" with a fail-shaped payload (pass=false) instead of
// crashing. Import/render failures report "FAIL". Nothing here ever returns
// pass=true unless every lane gate passed.
//
// Non-claim: diagnostic only. No AndroidTimelineExportSession change, no
// production export route, no encoder/mux, no audio, no app/editor UI.
//
// JNI entry point (matching VanguardNativeBridge.kt declaration):
//   renderAndroidDagPhase5TimelineDualDecoderSyncCrossfade -> jstring (JSON)

#include <jni.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "android_phase5_timeline_dual_decoder_sync_vulkan_support.h"
#include "vanguard/compositors/vg_timeline_compositor_node.h"
#include "vulkan_timeline_transition_compositor.h"

namespace {

using vanguard::compositors::ComputeTransitionGeometry;
using vanguard::compositors::TimelineTransitionProgress;
using vanguard::compositors::TransitionType;
using vanguard::render::VulkanTimelineTransitionCompositor;

namespace support = vanguard::android_diag::dual_decoder_sync;
using support::AndroidBufferApi;
using support::ImportedFrame;
using support::RenderContext;
using support::ScratchBuffer;
using support::ScratchImage;
using support::VulkanScratch;

constexpr const char* kProofBoundary =
    "native_android_dual_mediacodec_imagereader_ahb_to_vulkan_transition_crossfade_diagnostic_only_no_export";
constexpr const char* kNativePassMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_NATIVE_CROSSFADE_PASS";
constexpr const char* kNativeFailMarker =
    "ANDROID_DAG_PHASE5_TIMELINE_DUAL_DECODER_SYNC_NATIVE_CROSSFADE_FAIL";

// ── JSON helpers ────────────────────────────────────────────────────────────

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

const char* BoolStr(bool v) { return v ? "true" : "false"; }

std::string DoubleStr(double v) {
    if (!std::isfinite(v)) return "null";
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9g", v);
    return buf;
}

class JsonObjectBuilder {
public:
    void Str(const std::string& key, const std::string& value) {
        Raw(key, "\"" + JsonEscape(value) + "\"");
    }
    void Bool(const std::string& key, bool value) { Raw(key, BoolStr(value)); }
    void U64(const std::string& key, uint64_t value) { Raw(key, std::to_string(value)); }
    void I64(const std::string& key, int64_t value) { Raw(key, std::to_string(value)); }
    void Dbl(const std::string& key, double value) { Raw(key, DoubleStr(value)); }
    void Raw(const std::string& key, const std::string& rawValue) {
        entries_.push_back("\"" + JsonEscape(key) + "\":" + rawValue);
    }
    std::string Json() const {
        std::string out = "{";
        for (size_t i = 0; i < entries_.size(); ++i) {
            if (i != 0) out += ",";
            out += entries_[i];
        }
        out += "}";
        return out;
    }

private:
    std::vector<std::string> entries_;
};

// ── Result shaping helpers ──────────────────────────────────────────────────

bool ValidDimension(jint v) {
    return v > 0 && static_cast<uint32_t>(v) <= support::kMaxFrameDimension;
}

// Records whatever the import lane learned about one buffer (description
// telemetry is emitted even when a later validation step failed).
void RecordImportedFrameDetails(JsonObjectBuilder& details,
                                const std::string& prefix,
                                const ImportedFrame& frame) {
    if (frame.described) {
        const AHardwareBuffer_Desc& d = frame.buffer.desc;
        details.U64(prefix + "BufferWidth", d.width);
        details.U64(prefix + "BufferHeight", d.height);
        details.U64(prefix + "BufferLayers", d.layers);
        details.U64(prefix + "BufferFormat", d.format);
        details.U64(prefix + "BufferUsage", d.usage);
        details.U64(prefix + "BufferStride", d.stride);
    }
    if (!frame.importResultName.empty()) {
        details.Str(prefix + "ImportResult", frame.importResultName);
    }
    if (frame.imported) {
        details.Bool(prefix + "ExternalFormat", frame.image.isExternalFormat());
        details.Bool(prefix + "YcbcrConversion", frame.image.hasYcbcrConversion());
        details.U64(prefix + "VkFormat", static_cast<uint64_t>(frame.image.cachedFormat));
        details.U64(prefix + "VkExternalFormat", frame.image.cachedExternalFormat);
    }
}

void RecordPixelTelemetry(JsonObjectBuilder& details,
                          const std::vector<uint8_t>& pxFrom,
                          const std::vector<uint8_t>& pxTo,
                          const std::vector<uint8_t>& pxMid) {
    const uint64_t frameDelta = support::SumAbsDiff(pxFrom, pxTo);
    const uint8_t* cFrom = support::PixelAt(pxFrom, support::kCanvasWidth / 2, support::kCanvasHeight / 2);
    const uint8_t* cTo   = support::PixelAt(pxTo, support::kCanvasWidth / 2, support::kCanvasHeight / 2);
    const uint8_t* cMid  = support::PixelAt(pxMid, support::kCanvasWidth / 2, support::kCanvasHeight / 2);
    details.U64("fromToAbsDiffSum", frameDelta);
    details.Bool("fromToFramesDiffer", frameDelta > 0);
    details.Str("fromCenterRgb", support::RgbString(cFrom));
    details.Str("toCenterRgb", support::RgbString(cTo));
    details.Str("crossfadeCenterRgb", support::RgbString(cMid));
    details.Dbl("fromMeanLuma", support::MeanLuma(pxFrom));
    details.Dbl("toMeanLuma", support::MeanLuma(pxTo));
    details.Dbl("crossfadeMeanLuma", support::MeanLuma(pxMid));
    details.Str("fromChecksum", std::to_string(support::Checksum(pxFrom)));
    details.Str("toChecksum", std::to_string(support::Checksum(pxTo)));
    details.Str("crossfadeChecksum", std::to_string(support::Checksum(pxMid)));
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_renderAndroidDagPhase5TimelineDualDecoderSyncCrossfade(
    JNIEnv* env,
    jobject /* this */,
    jobject fromHardwareBuffer,
    jint fromWidth,
    jint fromHeight,
    jint fromFrameIndex,
    jlong fromPtsUs,
    jobject toHardwareBuffer,
    jint toWidth,
    jint toHeight,
    jint toFrameIndex,
    jlong toPtsUs,
    jdouble progress) {

    std::string failureReason;
    auto fail = [&failureReason](const std::string& reason) {
        if (failureReason.empty()) {
            failureReason = reason;
        }
    };
    JsonObjectBuilder details;
    details.Str("proofBoundary", kProofBoundary);
    details.U64("canvasWidth", support::kCanvasWidth);
    details.U64("canvasHeight", support::kCanvasHeight);
    details.I64("colorTolerance", support::kColorTolerance);
    details.Dbl("maxMismatchFraction", support::kMaxMismatchFraction);
    details.Str("shaderSource", "aot_passthrough_vert_frag_spv_no_new_shaders");
    details.I64("fromFrameIndex", fromFrameIndex);
    details.I64("toFrameIndex", toFrameIndex);
    details.I64("fromPtsUs", fromPtsUs);
    details.I64("toPtsUs", toPtsUs);
    details.I64("fromWidth", fromWidth);
    details.I64("fromHeight", fromHeight);
    details.I64("toWidth", toWidth);
    details.I64("toHeight", toHeight);
    details.Dbl("progress", progress);

    // Gate flags (all default false; every lane must set its own true).
    bool argumentValidationOk    = false;
    bool vulkanSetupOk           = false;
    bool nativeImportOk          = false;
    bool nativeCrossfadeRenderOk = false;
    bool resourceReleaseOk       = false;
    bool unsupported             = false;

    // ── Lane 0: argument validation (no native work before this passes) ────
    {
        std::string argError;
        if (fromHardwareBuffer == nullptr || toHardwareBuffer == nullptr) {
            argError = "hardware_buffer_null";
        } else if (!ValidDimension(fromWidth) || !ValidDimension(fromHeight) ||
                   !ValidDimension(toWidth) || !ValidDimension(toHeight)) {
            argError = "frame_dimensions_invalid";
        } else if (fromFrameIndex < 0 || toFrameIndex < 0) {
            argError = "frame_index_negative";
        } else if (!std::isfinite(static_cast<double>(progress)) || progress < 0.0 || progress > 1.0) {
            argError = "progress_out_of_range";
        }
        argumentValidationOk = argError.empty();
        if (!argumentValidationOk) {
            fail("invalid_argument:" + argError);
            details.Str("argumentError", argError);
        }
    }

    AndroidBufferApi api;
    VulkanScratch vk;
    ImportedFrame fromFrame, toFrame;
    ScratchImage fromRgba, toRgba, colorTarget;
    ScratchBuffer readback;
    VulkanTimelineTransitionCompositor compositor;

    // ── Lane 1: libandroid + temporary Vulkan device with AHB import path ──
    if (argumentValidationOk) {
        std::string err;
        if (!api.Load(&err)) {
            unsupported = true;
            fail("ahardwarebuffer_api_unsupported:" + err);
            details.Str("androidApiError", err);
        } else {
            bool setupUnsupported = false;
            vulkanSetupOk = vk.Setup(&err, &setupUnsupported);
            details.Bool("vulkanDeviceInitOk", vulkanSetupOk);
            details.Bool("vulkanUnsupported", setupUnsupported);
            if (!vulkanSetupOk) {
                unsupported = setupUnsupported;
                fail((setupUnsupported ? "vulkan_unsupported:" : "vulkan_setup_failed:") + err);
                details.Str("vulkanSetupError", err);
            }
        }
    }

    if (vulkanSetupOk) {
        details.Str("deviceName", vk.deviceName);
        details.U64("deviceType", vk.deviceType);
        details.Str("apiVersion", support::VersionString(vk.apiVersion));
        details.U64("driverVersion", vk.driverVersion);
        details.U64("queueFamilyIndex", vk.queueFamily);
        details.Bool("foreignQueueFamilyExtensionEnabled", vk.foreignQueueExtEnabled);

        std::string err;
        bool ok = support::CreateDeviceImage(
                      vk, support::kCanvasWidth, support::kCanvasHeight,
                      VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                      /*withSampler=*/false, colorTarget, &err) &&
                  support::CreateHostBuffer(vk, support::kReadbackBytes,
                                            VK_BUFFER_USAGE_TRANSFER_DST_BIT, readback, &err);
        details.Bool("scratchResourcesOk", ok);
        details.Bool("readbackMemoryCoherent", readback.coherent);
        if (!ok) {
            vulkanSetupOk = false;
            fail("scratch_vulkan_resource_creation_failed:" + err);
            details.Str("scratchResourceError", err);
        }
    }

    // ── Lane 2: import both AHardwareBuffers + resolve to RGBA8 ────────────
    if (vulkanSetupOk) {
        std::string err;
        bool ok = support::ImportFrame(env, api, vk, fromHardwareBuffer,
                                       static_cast<uint32_t>(fromWidth), static_cast<uint32_t>(fromHeight),
                                       "from", fromFrame, &err);
        RecordImportedFrameDetails(details, "from", fromFrame);
        if (ok) {
            ok = support::ImportFrame(env, api, vk, toHardwareBuffer,
                                      static_cast<uint32_t>(toWidth), static_cast<uint32_t>(toHeight),
                                      "to", toFrame, &err);
            RecordImportedFrameDetails(details, "to", toFrame);
        }
        details.Bool("bothBuffersImported", ok);
        if (ok) {
            ok = support::ResolveImportedFrame(vk, fromFrame, fromRgba, &err);
            details.Bool("fromResolveOk", ok);
        }
        if (ok) {
            ok = support::ResolveImportedFrame(vk, toFrame, toRgba, &err);
            details.Bool("toResolveOk", ok);
        }
        nativeImportOk = ok;
        if (!ok) {
            fail("native_import_failed:" + err);
            details.Str("importError", err);
        }
    }

    // ── Lane 3: compositor-owned crossfade geometry + Vulkan render ─────────
    if (nativeImportOk) {
        RenderContext ctx;
        support::BindRenderTarget(ctx, vk, compositor, colorTarget, readback);

        // Runtime evaluation of the compositor-owned geometry (not constexpr).
        TimelineTransitionProgress geometry =
            ComputeTransitionGeometry(TransitionType::kCrossfade, static_cast<double>(progress));
        TimelineTransitionProgress fromOnly = ComputeTransitionGeometry(TransitionType::kCrossfade, 0.0);
        TimelineTransitionProgress toOnly   = ComputeTransitionGeometry(TransitionType::kCrossfade, 1.0);
        details.Dbl("geometryProgress", geometry.progress);
        details.Dbl("blendWeightFrom", geometry.blendWeightFrom);
        details.Dbl("blendWeightTo", geometry.blendWeightTo);
        details.Bool("geometryIsCrossfade", geometry.type == TransitionType::kCrossfade);

        std::vector<uint8_t> pxFrom, pxTo, pxMid;
        std::string err;
        bool ok = support::RenderAndRead(ctx, fromRgba, toRgba, support::ToVulkanGeometry(fromOnly),
                                         pxFrom, &err);
        details.Bool("fromOnlyRenderOk", ok);
        if (!ok) fail("from_only_render_failed:" + err);
        if (ok) {
            ok = support::RenderAndRead(ctx, fromRgba, toRgba, support::ToVulkanGeometry(toOnly),
                                        pxTo, &err);
            details.Bool("toOnlyRenderOk", ok);
            if (!ok) fail("to_only_render_failed:" + err);
        }
        if (ok) {
            ok = support::RenderAndRead(ctx, fromRgba, toRgba, support::ToVulkanGeometry(geometry),
                                        pxMid, &err);
            details.Bool("crossfadeRenderOk", ok);
            if (!ok) fail("crossfade_render_failed:" + err);
        }
        if (!ok) {
            details.Str("renderError", err);
        } else {
            const uint32_t totalPixels = support::kCanvasWidth * support::kCanvasHeight;
            const uint32_t mismatches =
                support::CountBlendMismatches(pxFrom, pxTo, pxMid, geometry.blendWeightTo);
            const double mismatchFraction = static_cast<double>(mismatches) / static_cast<double>(totalPixels);
            details.U64("blendMismatchPixels", mismatches);
            details.Dbl("blendMismatchFraction", mismatchFraction);
            RecordPixelTelemetry(details, pxFrom, pxTo, pxMid);

            const bool weightsConsistent =
                std::isfinite(geometry.blendWeightFrom) && std::isfinite(geometry.blendWeightTo) &&
                std::fabs((geometry.blendWeightFrom + geometry.blendWeightTo) - 1.0) <= 1e-9 &&
                std::fabs(geometry.blendWeightTo - static_cast<double>(progress)) <= 1e-9;
            details.Bool("blendWeightsConsistent", weightsConsistent);
            const uint64_t created  = compositor.temporaryObjectsCreated();
            const uint64_t released = compositor.temporaryObjectsReleased();
            const bool helperBalanced = created > 0 && created == released;
            details.U64("helperTemporaryObjectsCreated", created);
            details.U64("helperTemporaryObjectsReleased", released);

            nativeCrossfadeRenderOk = weightsConsistent && helperBalanced &&
                                      mismatchFraction <= support::kMaxMismatchFraction;
            if (!weightsConsistent) {
                fail("crossfade_blend_weights_inconsistent");
            } else if (!helperBalanced) {
                fail("helper_temporary_objects_not_released");
            } else if (!nativeCrossfadeRenderOk) {
                fail("crossfade_blend_pixel_mismatch");
            }
        }
    }

    // ── Teardown: every object this diagnostic created / acquired ──────────
    if (vk.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk.device);
    }
    readback.Destroy(vk.device);
    colorTarget.Destroy(vk.device);
    toRgba.Destroy(vk.device);
    fromRgba.Destroy(vk.device);
    toFrame.Destroy(vk, api);
    fromFrame.Destroy(vk, api);
    const bool hadDevice = vk.device != VK_NULL_HANDLE;
    vk.Teardown();
    api.Unload();

    const bool helperBalancedAtExit =
        compositor.temporaryObjectsCreated() == compositor.temporaryObjectsReleased();
    const bool handlesNull = vk.AllHandlesNull() && readback.IsNull() && colorTarget.IsNull() &&
                             fromRgba.IsNull() && toRgba.IsNull() &&
                             fromFrame.IsNull() && toFrame.IsNull() && api.lib == nullptr;
    resourceReleaseOk = hadDevice && vk.teardownWaitIdleOk && handlesNull && helperBalancedAtExit;
    details.Bool("teardownWaitIdleOk", vk.teardownWaitIdleOk);
    details.Bool("teardownHandlesNull", handlesNull);
    details.Bool("helperBalancedAtExit", helperBalancedAtExit);
    if (hadDevice && !resourceReleaseOk) fail("diagnostic_teardown_incomplete");

    const bool allNativeLanesPass =
        argumentValidationOk && vulkanSetupOk && nativeImportOk &&
        nativeCrossfadeRenderOk && resourceReleaseOk;
    const char* status = allNativeLanesPass ? "PASS" : (unsupported ? "UNSUPPORTED" : "FAIL");

    JsonObjectBuilder root;
    root.Bool("pass", allNativeLanesPass);
    root.Str("status", status);
    root.Str("nativeMarker", allNativeLanesPass ? kNativePassMarker : kNativeFailMarker);
    root.Str("proofBoundary", kProofBoundary);
    root.Str("failureReason", failureReason);
    root.Bool("argumentValidationOk", argumentValidationOk);
    root.Bool("vulkanSetupOk", vulkanSetupOk);
    root.Bool("nativeImportOk", nativeImportOk);
    root.Bool("nativeCrossfadeRenderOk", nativeCrossfadeRenderOk);
    root.Bool("resourceReleaseOk", resourceReleaseOk);
    root.Bool("unsupported", unsupported);
    root.Bool("allNativeLanesPass", allNativeLanesPass);
    root.Bool("nativeAllLanesPass", allNativeLanesPass);
    root.Raw("details", details.Json());

    const std::string resultStr = root.Json();
    return env->NewStringUTF(resultStr.c_str());
}
