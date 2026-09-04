// P3-MULTICAM-NODE: MultiCamCompositorNode native/layout-math foundation
// validation diagnostic. Pure in-memory C++ math only: no threads, no
// Camera2, no GLES/Vulkan, no file IO. This diagnostic constructs
// vanguard::compositors::MultiCamCompositorNode instances and calls the
// free ComputeMultiCamLayout() function with synthetic inputs, checking
// node topology plus PiP/split geometry invariants and fail-safe clamping.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry points (matching VanguardNativeBridge.kt P3-MULTICAM-NODE
// declarations):
//   runAndroidDagPhase3MultiCamCompositorSmoke -> jstring
//   runAndroidDagPhase3MultiCamDescriptorBridgeSmoke -> jstring
//
// The second entry point is the P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-
// BRIDGE diagnostic: it consumes the primitive fields already parsed out of a
// Dart VGLivePreviewConfig/VGDualCameraDescriptor layout map by the Kotlin
// coordinator and converts them into a native MultiCamLayout, proving Dart
// layout-map consumption only. No camera open, no concurrent capture, no
// render, no OES, no recording/export, no product/editor UI, no iOS.

#include <jni.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <string>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vanguard/graph/node.h"

namespace {

using vanguard::compositors::MultiCamCompositorNode;
using vanguard::compositors::MultiCamLayout;
using vanguard::compositors::MultiCamLayoutMode;
using vanguard::compositors::MultiCamLayoutResult;
using vanguard::compositors::MultiCamPiPAnchor;
using vanguard::compositors::MultiCamPiPGeometry;
using vanguard::compositors::MultiCamSplitDirection;
using vanguard::compositors::MultiCamSplitGeometry;
using vanguard::compositors::NormalizedRect;

constexpr double kEpsilon = 1e-9;

bool NearlyEqual(double a, double b, double epsilon = kEpsilon) {
    return std::isfinite(a) && std::isfinite(b) && std::fabs(a - b) <= epsilon;
}

bool IsFiniteInUnit(double v) {
    return std::isfinite(v) && v >= 0.0 && v <= 1.0;
}

bool RectIsFiniteInUnit(const NormalizedRect& r) {
    return IsFiniteInUnit(r.x) && IsFiniteInUnit(r.y) &&
           IsFiniteInUnit(r.width) && IsFiniteInUnit(r.height);
}

bool RectNearlyEquals(const NormalizedRect& r, double x, double y, double w, double h) {
    return NearlyEqual(r.x, x) && NearlyEqual(r.y, y) &&
           NearlyEqual(r.width, w) && NearlyEqual(r.height, h);
}

MultiCamPiPGeometry MakePiP(MultiCamPiPAnchor anchor,
                             double centerX,
                             double centerY,
                             double normalizedWidth,
                             double aspectRatio,
                             double marginFraction,
                             double cornerRadiusFractionOfCanvasWidth,
                             double opacity) {
    MultiCamPiPGeometry pip{};
    pip.anchor = anchor;
    pip.centerX = centerX;
    pip.centerY = centerY;
    pip.normalizedWidth = normalizedWidth;
    pip.aspectRatio = aspectRatio;
    pip.marginFraction = marginFraction;
    pip.cornerRadiusFractionOfCanvasWidth = cornerRadiusFractionOfCanvasWidth;
    pip.opacity = opacity;
    return pip;
}

MultiCamSplitGeometry MakeSplit(MultiCamSplitDirection direction, double splitRatio) {
    MultiCamSplitGeometry split{};
    split.direction = direction;
    split.splitRatio = splitRatio;
    return split;
}

MultiCamLayout MakePiPLayout(double canvasWidth, double canvasHeight, MultiCamPiPGeometry pip) {
    MultiCamLayout layout{};
    layout.mode = MultiCamLayoutMode::kPictureInPicture;
    layout.canvasWidth = canvasWidth;
    layout.canvasHeight = canvasHeight;
    layout.pip = pip;
    layout.split = MakeSplit(MultiCamSplitDirection::kTopBottom, 0.5);
    return layout;
}

MultiCamLayout MakeSplitLayout(double canvasWidth, double canvasHeight, MultiCamSplitGeometry split) {
    MultiCamLayout layout{};
    layout.mode = MultiCamLayoutMode::kSplitScreen;
    layout.canvasWidth = canvasWidth;
    layout.canvasHeight = canvasHeight;
    layout.pip = MakePiP(MultiCamPiPAnchor::kFreeFloating, 0.5, 0.5, 0.35, 9.0 / 16.0, 0.05, 0.0, 1.0);
    layout.split = split;
    return layout;
}

// --- Dart layout-map -> native enum bridge helpers --------------------------

std::string JStringToStdString(JNIEnv* env, jstring value) {
    if (!value) return std::string();
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return std::string();
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// Mirrors VGDualCameraLayoutModeExtension.fromValue: unknown/missing -> pip.
MultiCamLayoutMode ResolveLayoutMode(const std::string& raw) {
    if (raw == "splitScreen") return MultiCamLayoutMode::kSplitScreen;
    return MultiCamLayoutMode::kPictureInPicture;
}

const char* LayoutModeName(MultiCamLayoutMode mode) {
    return mode == MultiCamLayoutMode::kSplitScreen ? "splitScreen" : "pip";
}

// Mirrors VGPiPAnchorExtension.fromValue: unknown/missing -> bottomRight.
MultiCamPiPAnchor ResolveAnchor(const std::string& raw) {
    if (raw == "topLeft") return MultiCamPiPAnchor::kTopLeft;
    if (raw == "topRight") return MultiCamPiPAnchor::kTopRight;
    if (raw == "bottomLeft") return MultiCamPiPAnchor::kBottomLeft;
    if (raw == "freeFloating") return MultiCamPiPAnchor::kFreeFloating;
    return MultiCamPiPAnchor::kBottomRight;
}

const char* AnchorName(MultiCamPiPAnchor anchor) {
    switch (anchor) {
        case MultiCamPiPAnchor::kTopLeft: return "topLeft";
        case MultiCamPiPAnchor::kTopRight: return "topRight";
        case MultiCamPiPAnchor::kBottomLeft: return "bottomLeft";
        case MultiCamPiPAnchor::kBottomRight: return "bottomRight";
        case MultiCamPiPAnchor::kFreeFloating: return "freeFloating";
    }
    return "bottomRight";
}

// Mirrors VGSplitScreenDirectionExtension.fromValue: unknown/missing -> topBottom.
MultiCamSplitDirection ResolveSplitDirection(const std::string& raw) {
    if (raw == "leftRight") return MultiCamSplitDirection::kLeftRight;
    return MultiCamSplitDirection::kTopBottom;
}

const char* SplitDirectionName(MultiCamSplitDirection direction) {
    return direction == MultiCamSplitDirection::kLeftRight ? "leftRight" : "topBottom";
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamCompositorSmoke(
    JNIEnv* env,
    jobject /* this */) {

    bool allPass = true;
    std::ostringstream detail;

    // 1. Node kind/type/ports.
    MultiCamCompositorNode node("multicam_node_smoke");
    const bool nodeKindOk = node.kind() == vanguard::graph::NodeKind::kProcessing;
    const bool nodeTypeOk = node.type() == vanguard::graph::NodeType::kMultiCamCompositor;
    const auto& inputs = node.inputPorts();
    const auto& outputs = node.outputPorts();
    const bool portsOk =
        inputs.size() == 2 &&
        inputs[0].id == "primary_video_in" &&
        inputs[0].dataType == vanguard::graph::PortDataType::kVideoFrame &&
        inputs[1].id == "secondary_video_in" &&
        inputs[1].dataType == vanguard::graph::PortDataType::kVideoFrame &&
        outputs.size() == 1 &&
        outputs[0].id == "composited_video_out" &&
        outputs[0].dataType == vanguard::graph::PortDataType::kVideoFrame;
    const bool nodeOk = nodeKindOk && nodeTypeOk && portsOk;
    allPass = allPass && nodeOk;
    detail << "nodeOk=" << (nodeOk ? "true" : "false") << ";";

    // 2. PiP free-floating with non-square (16:9) canvas.
    {
        const double canvasWidth = 1920.0;
        const double canvasHeight = 1080.0;
        const double canvasAspect = canvasWidth / canvasHeight;
        const double normalizedWidth = 0.3;
        const double aspectRatio = 9.0 / 16.0;
        const auto layout = MakePiPLayout(
            canvasWidth, canvasHeight,
            MakePiP(MultiCamPiPAnchor::kFreeFloating, 0.5, 0.5, normalizedWidth, aspectRatio, 0.05, 0.0, 1.0));
        const MultiCamLayoutResult result = MultiCamCompositorNode::computeLayout(layout);

        const bool primaryOk = RectNearlyEquals(result.primaryViewport, 0.0, 0.0, 1.0, 1.0);
        const double expectedHeight = normalizedWidth * canvasAspect / aspectRatio;
        const double expectedX = 0.5 - normalizedWidth / 2.0;
        const double expectedY = 0.5 - expectedHeight / 2.0;
        const bool freeFloatOk =
            RectNearlyEquals(result.secondaryViewport, expectedX, expectedY, normalizedWidth, expectedHeight) &&
            RectIsFiniteInUnit(result.secondaryViewport);
        const bool cropOk =
            RectNearlyEquals(result.primaryCrop, 0.0, 0.0, 1.0, 1.0) &&
            RectNearlyEquals(result.secondaryCrop, 0.0, 0.0, 1.0, 1.0);
        const bool pipFreeFloatOk = primaryOk && freeFloatOk && cropOk;
        allPass = allPass && pipFreeFloatOk;
        detail << "pipFreeFloatOk=" << (pipFreeFloatOk ? "true" : "false") << ";";
    }

    // 3. All four corner anchors, asymmetric top-left/Y-down checks on a
    //    non-square (landscape) canvas so horizontal and vertical margins
    //    differ, proving the canvasAspect margin conversion is applied.
    {
        const double canvasWidth = 1600.0;
        const double canvasHeight = 900.0;
        const double canvasAspect = canvasWidth / canvasHeight; // > 1: vertical margin > horizontal
        const double normalizedWidth = 0.2;
        const double aspectRatio = 1.0;
        const double marginFraction = 0.1;
        const double expectedHeight = normalizedWidth * canvasAspect / aspectRatio;
        const double horizontalMargin = marginFraction;
        const double verticalMargin = marginFraction * canvasAspect;

        auto layoutFor = [&](MultiCamPiPAnchor anchor) {
            return MakePiPLayout(
                canvasWidth, canvasHeight,
                MakePiP(anchor, 0.5, 0.5, normalizedWidth, aspectRatio, marginFraction, 0.0, 1.0));
        };

        const auto topLeft = MultiCamCompositorNode::computeLayout(layoutFor(MultiCamPiPAnchor::kTopLeft));
        const auto topRight = MultiCamCompositorNode::computeLayout(layoutFor(MultiCamPiPAnchor::kTopRight));
        const auto bottomLeft = MultiCamCompositorNode::computeLayout(layoutFor(MultiCamPiPAnchor::kBottomLeft));
        const auto bottomRight = MultiCamCompositorNode::computeLayout(layoutFor(MultiCamPiPAnchor::kBottomRight));

        const bool topLeftOk = RectNearlyEquals(
            topLeft.secondaryViewport, horizontalMargin, verticalMargin, normalizedWidth, expectedHeight);
        const bool topRightOk = RectNearlyEquals(
            topRight.secondaryViewport,
            1.0 - horizontalMargin - normalizedWidth, verticalMargin, normalizedWidth, expectedHeight);
        const bool bottomLeftOk = RectNearlyEquals(
            bottomLeft.secondaryViewport,
            horizontalMargin, 1.0 - verticalMargin - expectedHeight, normalizedWidth, expectedHeight);
        const bool bottomRightOk = RectNearlyEquals(
            bottomRight.secondaryViewport,
            1.0 - horizontalMargin - normalizedWidth,
            1.0 - verticalMargin - expectedHeight, normalizedWidth, expectedHeight);

        // Asymmetric Y-down sanity: top anchors have a strictly smaller y than
        // bottom anchors (top-left origin, Y increases downward), and the
        // vertical margin (derived via canvasAspect) differs from the
        // horizontal one since canvasAspect != 1.
        const bool yDownOk = topLeft.secondaryViewport.y < bottomLeft.secondaryViewport.y &&
                             topRight.secondaryViewport.y < bottomRight.secondaryViewport.y &&
                             !NearlyEqual(horizontalMargin, verticalMargin);

        const bool anchorsOk = topLeftOk && topRightOk && bottomLeftOk && bottomRightOk && yDownOk;
        allPass = allPass && anchorsOk;
        detail << "anchorsOk=" << (anchorsOk ? "true" : "false") << ";";
    }

    // 4. Split-screen top/bottom and left/right tiling: no gaps, no overlap.
    {
        const double splitRatio = 0.6;
        const auto topBottom = MultiCamCompositorNode::computeLayout(
            MakeSplitLayout(1280.0, 720.0, MakeSplit(MultiCamSplitDirection::kTopBottom, splitRatio)));
        const bool topBottomOk =
            RectNearlyEquals(topBottom.primaryViewport, 0.0, 0.0, 1.0, splitRatio) &&
            RectNearlyEquals(topBottom.secondaryViewport, 0.0, splitRatio, 1.0, 1.0 - splitRatio) &&
            NearlyEqual(topBottom.primaryViewport.y + topBottom.primaryViewport.height,
                        topBottom.secondaryViewport.y) &&
            NearlyEqual(topBottom.primaryViewport.height + topBottom.secondaryViewport.height, 1.0);

        const auto leftRight = MultiCamCompositorNode::computeLayout(
            MakeSplitLayout(1280.0, 720.0, MakeSplit(MultiCamSplitDirection::kLeftRight, splitRatio)));
        const bool leftRightOk =
            RectNearlyEquals(leftRight.primaryViewport, 0.0, 0.0, splitRatio, 1.0) &&
            RectNearlyEquals(leftRight.secondaryViewport, splitRatio, 0.0, 1.0 - splitRatio, 1.0) &&
            NearlyEqual(leftRight.primaryViewport.x + leftRight.primaryViewport.width,
                        leftRight.secondaryViewport.x) &&
            NearlyEqual(leftRight.primaryViewport.width + leftRight.secondaryViewport.width, 1.0);

        const bool splitOk = topBottomOk && leftRightOk;
        allPass = allPass && splitOk;
        detail << "splitOk=" << (splitOk ? "true" : "false") << ";";
    }

    // 5. Clamps for bad/nonfinite inputs.
    {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        const double inf = std::numeric_limits<double>::infinity();

        // PiP width clamp: absurdly large width clamps to 0.95; negative
        // width clamps to 0.05; NaN aspect ratio falls back to 9/16 (finite
        // positive) rather than propagating NaN.
        const auto oversizedPip = MultiCamCompositorNode::computeLayout(
            MakePiPLayout(1000.0, 1000.0,
                MakePiP(MultiCamPiPAnchor::kFreeFloating, nan, nan, 5.0, nan, inf, nan, inf)));
        const bool oversizedOk =
            NearlyEqual(oversizedPip.secondaryViewport.width, 0.95) &&
            RectIsFiniteInUnit(oversizedPip.secondaryViewport) &&
            IsFiniteInUnit(oversizedPip.secondaryOpacity) &&
            IsFiniteInUnit(oversizedPip.secondaryCornerRadiusFractionOfCanvasWidth);

        const auto undersizedPip = MultiCamCompositorNode::computeLayout(
            MakePiPLayout(1000.0, 1000.0,
                MakePiP(MultiCamPiPAnchor::kTopLeft, 0.5, 0.5, -1.0, -1.0, -1.0, -1.0, -1.0)));
        const bool undersizedOk =
            NearlyEqual(undersizedPip.secondaryViewport.width, 0.05) &&
            RectIsFiniteInUnit(undersizedPip.secondaryViewport) &&
            NearlyEqual(undersizedPip.secondaryOpacity, 0.0) &&
            NearlyEqual(undersizedPip.secondaryCornerRadiusFractionOfCanvasWidth, 0.0);

        // Invalid canvas dimensions fall back to a square canvas aspect
        // rather than propagating a division artifact.
        const auto invalidCanvas = MultiCamCompositorNode::computeLayout(
            MakePiPLayout(nan, -5.0,
                MakePiP(MultiCamPiPAnchor::kFreeFloating, 0.5, 0.5, 0.3, 1.0, 0.05, 0.0, 1.0)));
        const bool invalidCanvasOk =
            RectIsFiniteInUnit(invalidCanvas.secondaryViewport) &&
            NearlyEqual(invalidCanvas.secondaryViewport.height, 0.3);

        // Split ratio clamp: extreme and NaN inputs clamp into [0.2, 0.8].
        const auto splitTooHigh = MultiCamCompositorNode::computeLayout(
            MakeSplitLayout(1280.0, 720.0, MakeSplit(MultiCamSplitDirection::kTopBottom, 5.0)));
        const auto splitTooLow = MultiCamCompositorNode::computeLayout(
            MakeSplitLayout(1280.0, 720.0, MakeSplit(MultiCamSplitDirection::kLeftRight, -5.0)));
        const auto splitNan = MultiCamCompositorNode::computeLayout(
            MakeSplitLayout(1280.0, 720.0, MakeSplit(MultiCamSplitDirection::kTopBottom, nan)));
        const bool splitClampOk =
            NearlyEqual(splitTooHigh.primaryViewport.height, 0.8) &&
            NearlyEqual(splitTooLow.primaryViewport.width, 0.2) &&
            NearlyEqual(splitNan.primaryViewport.height, 0.5) &&
            RectIsFiniteInUnit(splitTooHigh.secondaryViewport) &&
            RectIsFiniteInUnit(splitTooLow.secondaryViewport) &&
            RectIsFiniteInUnit(splitNan.secondaryViewport);

        const bool clampOk = oversizedOk && undersizedOk && invalidCanvasOk && splitClampOk;
        allPass = allPass && clampOk;
        detail << "clampOk=" << (clampOk ? "true" : "false") << ";";
    }

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << detail.str()
        << "proofBoundary=native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}

// P3-MULTICAM-NODE-DART-TO-NATIVE-LAYOUT-MAP-BRIDGE: consumes the primitive
// fields the Kotlin coordinator already parsed out of a Dart layout map
// (VGLivePreviewConfig / VGDualCameraDescriptor layout subset: layoutMode,
// pipLayout.{anchor,centerX,centerY,widthFraction,aspectRatio,
// marginFraction,cornerRadius,opacity}, splitLayout.{direction,splitRatio}),
// maps each string field to the matching native MultiCam* enum with the same
// unknown-value fallbacks as the Dart *Extension.fromValue helpers, builds a
// MultiCamLayout on a fixed diagnostic canvas, and calls the already-verified
// MultiCamCompositorNode::computeLayout(). Proves freeFloating PiP center
// geometry consumption (secondary viewport center reproduces the input
// centerX/centerY) and leftRight split consumption (primary/secondary
// viewport widths reproduce splitRatio with no gap/overlap) when the caller's
// mode/anchor/direction select those lanes. Diagnostic only: no camera open,
// no concurrent capture, no render, no OES, no recording/export, no
// product/editor UI, no iOS.
extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase3MultiCamDescriptorBridgeSmoke(
    JNIEnv* env,
    jobject /* this */,
    jstring layoutModeJ,
    jstring pipAnchorJ,
    jdouble pipCenterX,
    jdouble pipCenterY,
    jdouble pipWidthFraction,
    jdouble pipAspectRatio,
    jdouble pipMarginFraction,
    jdouble pipCornerRadius,
    jdouble pipOpacity,
    jstring splitDirectionJ,
    jdouble splitRatio) {

    const MultiCamLayoutMode layoutMode = ResolveLayoutMode(JStringToStdString(env, layoutModeJ));
    const MultiCamPiPAnchor anchor = ResolveAnchor(JStringToStdString(env, pipAnchorJ));
    const MultiCamSplitDirection direction = ResolveSplitDirection(JStringToStdString(env, splitDirectionJ));

    constexpr double kBridgeCanvasWidth = 1920.0;
    constexpr double kBridgeCanvasHeight = 1080.0;

    MultiCamLayout layout{};
    layout.mode = layoutMode;
    layout.canvasWidth = kBridgeCanvasWidth;
    layout.canvasHeight = kBridgeCanvasHeight;
    layout.pip = MakePiP(anchor, pipCenterX, pipCenterY, pipWidthFraction, pipAspectRatio,
                          pipMarginFraction, pipCornerRadius, pipOpacity);
    layout.split = MakeSplit(direction, splitRatio);

    const MultiCamLayoutResult result = MultiCamCompositorNode::computeLayout(layout);

    const bool rectsFiniteInUnitOk =
        RectIsFiniteInUnit(result.primaryViewport) &&
        RectIsFiniteInUnit(result.secondaryViewport) &&
        IsFiniteInUnit(result.secondaryOpacity) &&
        IsFiniteInUnit(result.secondaryCornerRadiusFractionOfCanvasWidth);

    const bool pipCenterApplicable =
        layoutMode == MultiCamLayoutMode::kPictureInPicture &&
        anchor == MultiCamPiPAnchor::kFreeFloating;
    double secondaryCenterX = 0.0;
    double secondaryCenterY = 0.0;
    bool pipCenterOk = true;
    if (pipCenterApplicable) {
        secondaryCenterX = result.secondaryViewport.x + result.secondaryViewport.width / 2.0;
        secondaryCenterY = result.secondaryViewport.y + result.secondaryViewport.height / 2.0;
        pipCenterOk = NearlyEqual(secondaryCenterX, pipCenterX) && NearlyEqual(secondaryCenterY, pipCenterY);
    }

    const bool splitConsumptionApplicable =
        layoutMode == MultiCamLayoutMode::kSplitScreen &&
        direction == MultiCamSplitDirection::kLeftRight;
    bool splitConsumptionOk = true;
    if (splitConsumptionApplicable) {
        splitConsumptionOk =
            RectNearlyEquals(result.primaryViewport, 0.0, 0.0, splitRatio, 1.0) &&
            RectNearlyEquals(result.secondaryViewport, splitRatio, 0.0, 1.0 - splitRatio, 1.0) &&
            NearlyEqual(result.primaryViewport.x + result.primaryViewport.width, result.secondaryViewport.x) &&
            NearlyEqual(result.primaryViewport.width + result.secondaryViewport.width, 1.0);
    }

    const bool allPass = rectsFiniteInUnitOk && pipCenterOk && splitConsumptionOk;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "layoutModeResolved=" << LayoutModeName(layoutMode) << ";"
        << "anchorResolved=" << AnchorName(anchor) << ";"
        << "directionResolved=" << SplitDirectionName(direction) << ";"
        << "rectsFiniteInUnitOk=" << (rectsFiniteInUnitOk ? "true" : "false") << ";"
        << "pipCenterApplicable=" << (pipCenterApplicable ? "true" : "false") << ";"
        << "pipCenterOk=" << (pipCenterOk ? "true" : "false") << ";"
        << "pipSecondaryCenterX=" << secondaryCenterX << ";"
        << "pipSecondaryCenterY=" << secondaryCenterY << ";"
        << "splitConsumptionApplicable=" << (splitConsumptionApplicable ? "true" : "false") << ";"
        << "splitConsumptionOk=" << (splitConsumptionOk ? "true" : "false") << ";"
        << "splitPrimaryWidth=" << result.primaryViewport.width << ";"
        << "splitSecondaryWidth=" << result.secondaryViewport.width << ";"
        << "proofBoundary=dart_layout_map_to_native_multicam_layout_diagnostic_only_no_camera_no_render_no_recording_no_product";

    const std::string resultStr = oss.str();
    return env->NewStringUTF(resultStr.c_str());
}
