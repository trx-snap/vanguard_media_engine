// gles_green_screen_gpu_resident_renderer.h
// ANDROID-GREENSCREEN-GPU-RESIDENT: private helper - GlesGreenScreenGpuResidentRenderer.
//
// Native half of the Android live GreenScreen GPU-resident preview backend
// (AndroidGreenScreenGpuResidentPreviewBackend.kt). Adapted from the RND
// gpuzero `gl_renderer.cpp` GPU-resident loop with every camera-owner concern
// removed: no AHardwareBuffer / EGLImage import, no CameraStreamReader,
// no AImage. The renderer samples an already-latched GL_TEXTURE_EXTERNAL_OES
// texture that Kotlin drives through a SurfaceTexture (updateTexImage on the
// render thread), and every camera sample in every pass goes through the
// SurfaceTexture transform matrix supplied via SetCameraTransform.
//
// Owns:
//   - its own EGLDisplay / ES 3.1 EGLContext / 1x1 pbuffer (context stays
//     current on the render thread while no output is attached),
//   - an optional EGL window surface over a borrowed ANativeWindow (attached /
//     detached independently of the camera input, which survives output loss),
//   - an optional second EGL window surface over a live recording's encoder
//     ANativeWindow (AttachRecorderWindow; same display/config/context, so the
//     presented composite is re-drawn into it with zero copies),
//   - the camera OES texture name (created here, handed to Kotlin for
//     SurfaceTexture construction),
//   - model-input RGBA8 texture + FBO, coarse R8 mask texture, R32F alpha
//     ping/pong/history textures, optional background image texture, the
//     compute / composite programs and the full-screen quad.
//
// Does NOT own: the TFLite interpreter (Kotlin), the SurfaceTexture / camera
// Surface (Kotlin), the output Surface (Flutter SurfaceProducer; only the EGL
// window surface wrapping it is created/destroyed here).
//
// One frame transaction (all on the render thread, context current):
//   DownscaleCameraToModelInput -> [Kotlin: Interpreter.run] ->
//   UploadCoarseMask -> RenderFrame (guided filter -> optional temporal ->
//   composite -> eglSwapBuffers) -> [while recording: RenderRecorderFrame
//   (composite only, same textures and effective mode ->
//   eglPresentationTimeANDROID -> eglSwapBuffers on the encoder surface)].
// A still photo (VG-LIVE-GREENSCREEN-PHOTO) is RenderFrameCapturing: the
// same transaction with one glReadPixels of the composite inserted between
// the composite pass and the preview eglSwapBuffers, so the CPU copy is
// exactly the frame that is presented (and that a recorder pass re-draws).
//
// Threading: single render thread only. No internal locking.
//
// Private header: EGL/GLES/Android headers never appear here; the .cpp
// confines them behind #if defined(__ANDROID__) and compiles to a failing
// stub elsewhere.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace render {

/** Canvas-pixel rect, top-left origin (mirrors AndroidGreenScreenPixelRect). */
struct GlesGreenScreenGpuResidentRect {
    float left = 0.0f;
    float top = 0.0f;
    float width = 0.0f;
    float height = 0.0f;
};

/** Cumulative per-session counters for the release-time summary log. */
struct GlesGreenScreenGpuResidentStats {
    uint64_t framesRendered = 0;
    uint64_t framesSwapped = 0;
    uint64_t downscales = 0;
    uint64_t maskUploads = 0;
    uint64_t refinePasses = 0;
    double totalDownscaleMs = 0.0;
    double totalRefineMs = 0.0;
    double totalCompositeMs = 0.0;
    float lastDownscaleMs = 0.0f;
    float lastRefineMs = 0.0f;
    float lastCompositeMs = 0.0f;
    // Live recording (RenderRecorderFrame), cumulative across takes.
    uint64_t recorderFramesSubmitted = 0;
    uint64_t recorderFramesSkipped = 0;
    uint64_t recorderFailures = 0;
    double totalRecorderCompositeMs = 0.0;
    float lastRecorderSwapMs = 0.0f;
    float maxRecorderSwapMs = 0.0f;
    // Still photo read-backs (RenderFrameCapturing), cumulative.
    uint64_t compositeCaptures = 0;
    uint64_t compositeCaptureFailures = 0;
    float lastCaptureReadMs = 0.0f;
};

class GlesGreenScreenGpuResidentRenderer {
public:
    enum class BackgroundMode : int32_t {
        kBlack = 0,
        kSolidColor = 1,
        kImage = 2,
        kVideo = 3,
    };

    enum class CameraMode : int32_t {
        kNone = 0,         // camera layer not drawn (background stays visible)
        kPlaceholder = 1,  // fixed placeholder fill of the camera rect
        kPassthrough = 2,  // latched camera frame, unmasked
        kMasked = 3,       // latched camera frame keyed by the refined alpha
    };

    /** Outcome of one RenderRecorderFrame call. */
    enum class RecorderFrameStatus : int32_t {
        kSubmitted = 0,  // composite swapped into the encoder surface with its PTS
        kSkipped = 1,    // nothing to record (no recorder / no fresh composite / no output); not an error
        kFailed = 2,     // EGL/GL failure on the encoder surface; the owner must detach it
    };

    GlesGreenScreenGpuResidentRenderer();
    ~GlesGreenScreenGpuResidentRenderer();

    GlesGreenScreenGpuResidentRenderer(const GlesGreenScreenGpuResidentRenderer&) = delete;
    GlesGreenScreenGpuResidentRenderer& operator=(const GlesGreenScreenGpuResidentRenderer&) = delete;

    // -- Lifecycle ----------------------------------------------------------

    /**
     * Creates the EGL display / ES 3.1 context / pbuffer, compiles every
     * program and allocates the static GL objects (camera OES texture, quad).
     * Leaves the context current on the calling thread. On failure every
     * partial resource is destroyed and *error describes the first failure.
     */
    bool Initialize(std::string* error);

    /** Terminal teardown (idempotent, never throws). Destroys the recorder
     *  surface, the window surface, every GL object, the pbuffer, the
     *  context and the display. */
    void Destroy();

    bool IsInitialized() const { return initialized_; }

    /** Makes the context current on the calling thread (window surface if
     *  attached, else the pbuffer). */
    bool MakeCurrent();

    /** GL_TEXTURE_EXTERNAL_OES texture name for the Kotlin SurfaceTexture. */
    uint32_t CameraTextureId() const { return cameraTexture_; }

    /** Allocates the model-input RGBA8 texture + FBO for the interpreter's
     *  input tensor size. Requires a current context. */
    bool ConfigureModelInput(int width, int height, std::string* error);

    // -- Output window -------------------------------------------------------

    /**
     * Wraps a borrowed ANativeWindow* (acquired here; released on detach) in
     * an EGL window surface and makes it current. Re-attaching destroys the
     * previous window surface first. Never releases the Android Surface.
     */
    bool AttachOutputWindow(void* nativeWindow, int widthPx, int heightPx, std::string* error);

    /** Destroys ONLY the EGL window surface (and drops the window ref); the
     *  context, camera texture and every other GL object survive. */
    void DetachOutputWindow();

    bool HasOutputWindow() const { return eglWindowSurface_ != nullptr; }

    // -- Recorder window (VG-LIVE-GREENSCREEN-RECORDING) ----------------------

    /**
     * Wraps a live recording's encoder ANativeWindow (acquired here; released
     * on detach/destroy) in a second EGL window surface on this renderer's
     * own display/config/context, probes that it can be made current, then
     * hands the preview window back. Requires an attached output window of
     * exactly widthPx x heightPx (the composite geometry is derived from the
     * output size) and eglPresentationTimeANDROID (resolved once through
     * eglGetProcAddress); fails closed otherwise. Re-attaching destroys the
     * previous recorder surface first. Never releases the Android Surface.
     */
    bool AttachRecorderWindow(void* nativeWindow, int widthPx, int heightPx, std::string* error);

    /** Destroys ONLY the recorder EGL window surface (and drops its window
     *  ref); the preview window, the context and every GL object survive. */
    void DetachRecorderWindow();

    bool HasRecorderWindow() const { return eglRecorderSurface_ != nullptr; }

    /**
     * Re-composites the frame the last RenderFrame presented (same latched
     * camera frame, refined alpha, background, layout and effective camera
     * mode) into the recorder surface, stamps presentationTimeNs and swaps.
     * Runs the composite pass only: no segmentation, no refinement, no alpha
     * reallocation and no preview frame counters. Consumes the composite
     * (at most one recorder frame per RenderFrame) and leaves the preview
     * window (or the pbuffer) current again on every path.
     */
    RecorderFrameStatus RenderRecorderFrame(int64_t presentationTimeNs, std::string* error);

    // -- State ---------------------------------------------------------------

    void SetLayout(const GlesGreenScreenGpuResidentRect& sourceRect,
                   const GlesGreenScreenGpuResidentRect& cameraRect);

    /**
     * Latches the SurfaceTexture transform matrix (column-major 4x4, as
     * returned by getTransformMatrix) plus the upright camera aspect
     * (width / height after that transform) used for the aspect-fill
     * viewport and the alpha resolution.
     */
    void SetCameraTransform(const float stMatrixColumnMajor[16], float cameraUprightAspect);

    void SetBackgroundBlack();
    void SetBackgroundSolidColor(uint32_t argb);
    /** Uploads tightly packed RGBA8 pixels (row 0 = top). Requires a current context. */
    bool SetBackgroundImage(const uint8_t* rgba, int width, int height, bool aspectFill, std::string* error);
    void SetBackgroundImageScaleMode(bool aspectFill);
    void ClearBackgroundImage();

    /**
     * Allocates (if not already) the GL_TEXTURE_EXTERNAL_OES texture a Kotlin
     * SurfaceTexture is constructed around for MediaCodec background-video
     * output, mirroring CameraTextureId()/cameraTexture_'s ownership split:
     * native creates and owns the GL texture name, Kotlin owns the
     * SurfaceTexture/Surface/decoder wrapping it. Idempotent while a texture
     * is already allocated (call ClearBackgroundVideo first to force a fresh
     * one for a new video source). Requires a current context. 0 on failure.
     */
    uint32_t EnsureBackgroundVideoTexture(std::string* error);

    /**
     * Latches the background video's SurfaceTexture transform matrix (as
     * returned by getTransformMatrix), its decoded dimensions, its
     * 0/90/180/270 source rotation and its scale mode, and switches the
     * background to video. Call once per decoded frame (after
     * EnsureBackgroundVideoTexture), mirroring SetCameraTransform's per-frame
     * latch for the camera layer.
     */
    void SetBackgroundVideoFrame(const float stMatrixColumnMajor[16], int videoWidth, int videoHeight,
                                  int rotationDegrees, bool aspectFill);

    /**
     * Releases the background-video OES texture (if any) and reverts the
     * background to black if it was showing video. Idempotent, never throws.
     * Mirrors ClearBackgroundImage.
     */
    void ClearBackgroundVideo();

    void SetFilterToggles(bool guidedFilter, bool temporalStabilizer, bool despill);

    // -- Frame transaction ---------------------------------------------------

    /**
     * GPU-downscales the latched camera frame into the model input texture,
     * reads it back and packs it as normalized float RGB (NHWC, row 0 = top)
     * into outRgbFloats (must hold width*height*3 floats). Requires a
     * current context and ConfigureModelInput.
     */
    bool DownscaleCameraToModelInput(float* outRgbFloats, size_t outFloatCount, std::string* error);

    /**
     * Converts a float32 single-channel mask (row 0 = top, width*height
     * floats, values clamped to [0,1]) to R8 and uploads it as the coarse
     * alpha texture. Requires a current context.
     */
    bool UploadCoarseMask(const float* mask, size_t floatCount, int width, int height, std::string* error);

    /**
     * Guided filter (+ optional temporal) over the coarse mask when
     * refineMask is set (or when no refined alpha exists yet), then the
     * composite into the window surface and eglSwapBuffers. Returns the swap
     * result; false without an attached window. Remembers the effective
     * camera mode it actually composited (kMasked degrades to kNone before
     * the first coarse mask) so RenderRecorderFrame records exactly what was
     * presented.
     */
    bool RenderFrame(CameraMode cameraMode, bool refineMask, std::string* error);

    /**
     * RenderFrame plus a one-shot CPU read-back of the composite it presents
     * (VG-LIVE-GREENSCREEN-PHOTO). After the composite pass and BEFORE
     * eglSwapBuffers, the full output (outputWidth x outputHeight, tightly
     * packed RGBA8, GL bottom-left row order) is glReadPixels'd into outRgba,
     * whose capacity must be >= outputWidth * outputHeight * 4 bytes.
     * *outCaptured reports the read-back; the return value is the swap
     * result exactly as RenderFrame, and the frame is presented whether or
     * not the read-back succeeded (a failed read-back only sets *error).
     * Same thread / context rules as RenderFrame.
     */
    bool RenderFrameCapturing(CameraMode cameraMode, bool refineMask, uint8_t* outRgba,
                              size_t outRgbaCapacityBytes, bool* outCaptured, std::string* error);

    const GlesGreenScreenGpuResidentStats& stats() const { return stats_; }
    std::string StatsSummary() const;

private:
    struct GlRect {
        float x = 0.0f;
        float y = 0.0f;
        float w = 0.0f;
        float h = 0.0f;
    };

    bool CreateEglCore(std::string* error);
    bool CreatePrograms(std::string* error);
    bool CreateStaticObjects(std::string* error);
    bool EnsureAlphaTextures(int width, int height, std::string* error);
    bool EnsureCoarseAlphaTexture(int width, int height, std::string* error);
    void DestroyGlObjects();
    void DestroyWindowSurfaceQuietly();
    void DestroyRecorderSurfaceQuietly();
    void MakePbufferCurrentQuietly();

    GlRect ToGl(const GlesGreenScreenGpuResidentRect& rect) const;
    GlRect CameraAspectFillViewport(const GlesGreenScreenGpuResidentRect& rect) const;
    GlRect BackgroundImageRect(const GlesGreenScreenGpuResidentRect& rect) const;
    GlRect BackgroundVideoRect(const GlesGreenScreenGpuResidentRect& rect) const;
    void DeriveAlphaResolution(int* width, int* height) const;

    bool RunGuidedFilter(std::string* error);
    bool RunTemporalStabilizer(std::string* error);
    bool RunComposite(CameraMode cameraMode, std::string* error);

    // Shared body of RenderFrame / RenderFrameCapturing: captureRgba == nullptr
    // means no read-back; otherwise the composite is read into it before the
    // swap and *outCaptured (may be nullptr) reports the read-back.
    bool RenderFrameInternal(CameraMode cameraMode, bool refineMask, uint8_t* captureRgba,
                             size_t captureCapacityBytes, bool* outCaptured, std::string* error);
    // glReadPixels of the current default-framebuffer composite into outRgba
    // (RGBA8, bottom-left origin). Requires the preview window current and a
    // just-completed composite pass.
    bool ReadCompositeToCpu(uint8_t* outRgba, size_t outRgbaCapacityBytes, std::string* error);

    // EGL (void* aliases of EGLDisplay / EGLConfig / EGLContext / EGLSurface).
    void* eglDisplay_ = nullptr;
    void* eglConfig_ = nullptr;
    void* eglContext_ = nullptr;
    void* eglPbufferSurface_ = nullptr;
    void* eglWindowSurface_ = nullptr;
    void* nativeWindow_ = nullptr;  // ANativeWindow*, acquired on attach
    bool initialized_ = false;

    // Recorder (encoder) window surface; same config/context as the preview.
    void* eglRecorderSurface_ = nullptr;
    void* recorderNativeWindow_ = nullptr;  // ANativeWindow*, acquired on attach
    int recorderWidth_ = 0;
    int recorderHeight_ = 0;
    void (*presentationTimeProc_)() = nullptr;  // eglPresentationTimeANDROID, resolved on first attach
    CameraMode lastCompositedMode_ = CameraMode::kNone;
    bool hasRecordableComposite_ = false;
    bool recorderSizeMismatchLogged_ = false;
    // Per-take counters (reset on attach) for the detach summary log.
    uint64_t recorderTakeSubmitted_ = 0;
    uint64_t recorderTakeSkipped_ = 0;
    uint64_t recorderTakeFailed_ = 0;
    double recorderTakeCompositeMs_ = 0.0;
    float recorderTakeMaxSwapMs_ = 0.0f;

    int outputWidth_ = 0;
    int outputHeight_ = 0;

    int modelInputWidth_ = 0;
    int modelInputHeight_ = 0;

    // GL objects.
    uint32_t cameraTexture_ = 0;
    uint32_t modelInputTexture_ = 0;
    uint32_t modelInputFbo_ = 0;
    uint32_t coarseAlphaTexture_ = 0;
    uint32_t alphaPingTexture_ = 0;
    uint32_t alphaPongTexture_ = 0;
    uint32_t alphaHistoryTexture_ = 0;
    uint32_t backgroundImageTexture_ = 0;
    uint32_t backgroundVideoTexture_ = 0;
    uint32_t quadVao_ = 0;
    uint32_t quadVbo_ = 0;

    uint32_t downscaleProgram_ = 0;
    uint32_t guidedProgram_ = 0;
    uint32_t temporalProgram_ = 0;
    uint32_t compositeProgram_ = 0;

    // Uniform locations.
    int32_t downscaleModelSizeLoc_ = -1;
    int32_t downscaleStMatrixLoc_ = -1;
    int32_t guidedAlphaResolutionLoc_ = -1;
    int32_t guidedStMatrixLoc_ = -1;
    int32_t guidedFilterEnabledLoc_ = -1;
    int32_t temporalAlphaResolutionLoc_ = -1;
    int32_t compositeCameraTextureLoc_ = -1;
    int32_t compositeAlphaTextureLoc_ = -1;
    int32_t compositeBackgroundImageLoc_ = -1;
    int32_t compositeAlphaResolutionLoc_ = -1;
    int32_t compositeStMatrixLoc_ = -1;
    int32_t compositeSourceRectLoc_ = -1;
    int32_t compositeCameraScissorLoc_ = -1;
    int32_t compositeCameraViewportLoc_ = -1;
    int32_t compositeBackgroundImageRectLoc_ = -1;
    int32_t compositeBackgroundVideoTextureLoc_ = -1;
    int32_t compositeBackgroundVideoStMatrixLoc_ = -1;
    int32_t compositeBackgroundVideoRectLoc_ = -1;
    int32_t compositeBackgroundColorLoc_ = -1;
    int32_t compositePlaceholderColorLoc_ = -1;
    int32_t compositeBackgroundModeLoc_ = -1;
    int32_t compositeCameraModeLoc_ = -1;
    int32_t compositeDespillEnabledLoc_ = -1;

    int coarseAlphaWidth_ = 0;
    int coarseAlphaHeight_ = 0;
    int alphaWidth_ = 0;
    int alphaHeight_ = 0;
    uint32_t activeAlphaTexture_ = 0;
    bool hasCoarseMask_ = false;
    bool hasRefinedAlpha_ = false;

    GlesGreenScreenGpuResidentRect sourceRect_;
    GlesGreenScreenGpuResidentRect cameraRect_;
    bool hasLayout_ = false;

    float cameraStMatrix_[16];
    float cameraUprightAspect_ = 1080.0f / 1920.0f;

    BackgroundMode backgroundMode_ = BackgroundMode::kBlack;
    float backgroundColor_[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    int backgroundImageWidth_ = 0;
    int backgroundImageHeight_ = 0;
    bool backgroundImageAspectFill_ = true;

    float backgroundVideoStMatrix_[16];
    int backgroundVideoWidth_ = 0;
    int backgroundVideoHeight_ = 0;
    int backgroundVideoRotationDegrees_ = 0;
    bool backgroundVideoAspectFill_ = true;

    bool guidedFilterEnabled_ = true;
    bool temporalEnabled_ = false;
    bool despillEnabled_ = true;

    std::vector<uint8_t> modelInputRgba_;
    std::vector<uint8_t> coarseAlphaBytes_;

    GlesGreenScreenGpuResidentStats stats_;
};

}  // namespace render
}  // namespace vanguard
