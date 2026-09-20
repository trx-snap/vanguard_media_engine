// P5-ANDROID-DUET-GPU-TEXTURE-BRIDGE: native session backing
// AndroidDuetGpuTextureBridge.kt / VanguardNativeBridge.kt. Creates its own
// EGLDisplay/EGLContext/EGLSurface (1x1 pbuffer, ES3 with ES2 fallback),
// makes it current once at creation, and stores the caller's requested
// width/height as session metadata only.
//
// resolveAndroidDuetCameraHardwareBufferToRgbaTexture imports the caller's
// camera AHardwareBuffer transiently (EGLImage -> GL texture), draws it
// through a full-screen ES2 shader into a free slot of a small fixed pool of
// session-owned RGBA GL_TEXTURE_2D output textures (RGBA/RGBX buffers bind as
// GL_TEXTURE_2D; every other camera/private/YUV/implementation-defined format
// binds as GL_TEXTURE_EXTERNAL_OES), marks that slot in use, glFinish()es,
// and returns the slot's texture name.
// releaseAndroidDuetGpuTextureBridgeResolvedTexture returns a slot to the
// pool by texture name once its consumer (the MediaPipe
// TextureReleaseCallback) has finished reading it; unknown names / destroyed
// sessions are ignored.
// copyAndroidDuetTextureToHardwareBuffer imports a target RGBA/RGBX
// HardwareBuffer transiently as GL_TEXTURE_2D and draws a caller-supplied
// source texture into it. All fail closed (0/false) on any missing native
// symbol, unsupported format, or GL/EGL failure, matching
// AndroidDuetGpuTextureBridge.kt's fail-closed contract.
//
// Pool ownership rule (RND texture-slot pool): a slot that is in use is
// never redrawn. When every slot is in use, resolve fails closed with 0 so
// the caller can drop the camera frame instead of overwriting a texture that
// MediaPipe may still be sampling. The pool is sized to
// kResolvedOutputSlotCount; there is still no production frame loop wired to
// this bridge.

#include <jni.h>

#if defined(__ANDROID__)
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>

#include <array>
#include <atomic>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <unordered_map>

// Fallback in case the NDK headers in use predate this extension token.
// Value mirrors the Khronos-registered constant (also mirrored by
// gles_hardware_buffer_imports.cpp).
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif

#ifndef EGL_SYNC_NATIVE_FENCE_ANDROID
#define EGL_SYNC_NATIVE_FENCE_ANDROID 0x3144
#endif
#ifndef EGL_SYNC_NATIVE_FENCE_FD_ANDROID
#define EGL_SYNC_NATIVE_FENCE_FD_ANDROID 0x3145
#endif
#ifndef EGL_NO_NATIVE_FENCE_FD_ANDROID
#define EGL_NO_NATIVE_FENCE_FD_ANDROID -1
#endif

namespace {

constexpr int kMaxCopyTargetCacheSlots = 3;
// Number of resolved RGBA output textures that may be owned by the
// consumer (MediaPipe) at the same time. Matches the Kotlin pipeline's
// bounded in-flight accounting in AndroidDuetGpuGreenScreenPipeline.kt.
constexpr int kResolvedOutputSlotCount = 3;

// ---------------------------------------------------------------------------
// Native symbol resolution: AHardwareBuffer JNI/refcount/describe functions
// (dlsym from libandroid.so, no strong symbol references) and the EGL/GLES
// extension entry points needed to import an AHardwareBuffer as a GL texture
// (eglGetProcAddress, since these are extension entry points and not
// guaranteed to be strong-linked even though EGL/GLESv3 are linked). Resolved
// once for the process and cached; every resolve/copy call fails closed if
// any symbol is missing.
// ---------------------------------------------------------------------------

using FnAHardwareBuffer_fromHardwareBuffer = AHardwareBuffer* (*)(JNIEnv*, jobject);
using FnAHardwareBuffer_acquire = void (*)(AHardwareBuffer*);
using FnAHardwareBuffer_release = void (*)(AHardwareBuffer*);
using FnAHardwareBuffer_describe = void (*)(const AHardwareBuffer*, AHardwareBuffer_Desc*);

struct NativeGpuSymbols {
    FnAHardwareBuffer_fromHardwareBuffer fromHardwareBuffer = nullptr;
    FnAHardwareBuffer_acquire acquire = nullptr;
    FnAHardwareBuffer_release release = nullptr;
    FnAHardwareBuffer_describe describe = nullptr;

    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC getNativeClientBuffer = nullptr;
    PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture2D = nullptr;
    PFNEGLCREATESYNCKHRPROC createSync = nullptr;
    PFNEGLDESTROYSYNCKHRPROC destroySync = nullptr;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC dupNativeFenceFd = nullptr;

    bool valid = false;
    bool nativeFenceValid = false;
};

const NativeGpuSymbols& ResolveNativeGpuSymbols() {
    static const NativeGpuSymbols symbols = [] {
        NativeGpuSymbols s;
        // Intentionally never dlclose'd: libandroid.so is already resident
        // for the process lifetime, and these function pointers must stay
        // valid for every session this translation unit ever creates.
        void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
        if (lib) {
            s.fromHardwareBuffer = reinterpret_cast<FnAHardwareBuffer_fromHardwareBuffer>(
                dlsym(lib, "AHardwareBuffer_fromHardwareBuffer"));
            s.acquire = reinterpret_cast<FnAHardwareBuffer_acquire>(
                dlsym(lib, "AHardwareBuffer_acquire"));
            s.release = reinterpret_cast<FnAHardwareBuffer_release>(
                dlsym(lib, "AHardwareBuffer_release"));
            s.describe = reinterpret_cast<FnAHardwareBuffer_describe>(
                dlsym(lib, "AHardwareBuffer_describe"));
        }

        s.getNativeClientBuffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
            eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        s.createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
            eglGetProcAddress("eglCreateImageKHR"));
        s.destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
            eglGetProcAddress("eglDestroyImageKHR"));
        s.imageTargetTexture2D = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        s.createSync = reinterpret_cast<PFNEGLCREATESYNCKHRPROC>(
            eglGetProcAddress("eglCreateSyncKHR"));
        s.destroySync = reinterpret_cast<PFNEGLDESTROYSYNCKHRPROC>(
            eglGetProcAddress("eglDestroySyncKHR"));
        s.dupNativeFenceFd = reinterpret_cast<PFNEGLDUPNATIVEFENCEFDANDROIDPROC>(
            eglGetProcAddress("eglDupNativeFenceFDANDROID"));

        s.valid = s.fromHardwareBuffer && s.acquire && s.release && s.describe &&
                  s.getNativeClientBuffer && s.createImage && s.destroyImage &&
                  s.imageTargetTexture2D;
        s.nativeFenceValid = s.createSync && s.destroySync && s.dupNativeFenceFd;
        return s;
    }();
    return symbols;
}

// ---------------------------------------------------------------------------
// Full-screen quad shaders: one draw shape sampling a GL_TEXTURE_2D source,
// one sampling a GL_TEXTURE_EXTERNAL_OES source. Client-side vertex/UV
// arrays (no VBO) are sufficient for this single quad.
// ---------------------------------------------------------------------------

const char* kVertexShaderSrc =
    "attribute vec2 aPosition;\n"
    "attribute vec2 aTexCoord;\n"
    "varying vec2 vTexCoord;\n"
    "void main() {\n"
    "    vTexCoord = aTexCoord;\n"
    "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
    "}\n";

const char* kFragmentShaderSrc2D =
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform sampler2D uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

const char* kFragmentShaderSrcOes =
    "#extension GL_OES_EGL_image_external : require\n"
    "precision mediump float;\n"
    "varying vec2 vTexCoord;\n"
    "uniform samplerExternalOES uTexture;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(uTexture, vTexCoord);\n"
    "}\n";

const GLfloat kFullscreenQuadVertices[] = {
    // x,     y,     u,    v
    -1.0f, -1.0f, 0.0f, 0.0f,
     1.0f, -1.0f, 1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f, 1.0f,
     1.0f,  1.0f, 1.0f, 1.0f,
};

// Compiles a shader of the given type; returns 0 on failure (deleting the
// shader object before returning).
GLuint CompileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

// Links a vertex+fragment shader pair into a program; returns 0 on failure.
// Shader objects are always deleted before returning (a linked program keeps
// its own reference to attached shaders' compiled state).
GLuint LinkProgram(const char* vertexSrc, const char* fragmentSrc) {
    GLuint vertexShader = CompileShader(GL_VERTEX_SHADER, vertexSrc);
    if (vertexShader == 0) {
        return 0;
    }
    GLuint fragmentShader = CompileShader(GL_FRAGMENT_SHADER, fragmentSrc);
    if (fragmentShader == 0) {
        glDeleteShader(vertexShader);
        return 0;
    }

    GLuint program = glCreateProgram();
    if (program != 0) {
        glAttachShader(program, vertexShader);
        glAttachShader(program, fragmentShader);
        glLinkProgram(program);
        GLint linked = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (linked != GL_TRUE) {
            glDeleteProgram(program);
            program = 0;
        }
    }

    glDeleteShader(fragmentShader);
    glDeleteShader(vertexShader);
    return program;
}

// Draws the full-screen quad sampling `sourceTexture` (bound to
// `sourceTarget`) through `program` into whatever framebuffer/viewport the
// caller has already bound. Restores texture/program/array-attrib bindings
// before returning on every path.
bool DrawFullscreenQuad(GLuint program, GLenum sourceTarget, GLuint sourceTexture) {
    const GLint positionLoc = glGetAttribLocation(program, "aPosition");
    const GLint texCoordLoc = glGetAttribLocation(program, "aTexCoord");
    const GLint textureLoc = glGetUniformLocation(program, "uTexture");
    if (positionLoc < 0 || texCoordLoc < 0 || textureLoc < 0) {
        return false;
    }

    glUseProgram(program);

    glEnableVertexAttribArray(static_cast<GLuint>(positionLoc));
    glVertexAttribPointer(static_cast<GLuint>(positionLoc), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(GLfloat), kFullscreenQuadVertices);
    glEnableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
    glVertexAttribPointer(static_cast<GLuint>(texCoordLoc), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(GLfloat), kFullscreenQuadVertices + 2);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(sourceTarget, sourceTexture);
    glUniform1i(textureLoc, 0);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    const bool ok = (glGetError() == GL_NO_ERROR);

    glBindTexture(sourceTarget, 0);
    glDisableVertexAttribArray(static_cast<GLuint>(texCoordLoc));
    glDisableVertexAttribArray(static_cast<GLuint>(positionLoc));
    glUseProgram(0);

    return ok;
}

struct DuetGpuTextureBridgeSession {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    int width = 0;
    int height = 0;

    // Fixed pool of RGBA output textures owned by this session. A slot is
    // marked inUse from the moment resolve returns its texture name until
    // ReleaseResolvedTexture() is called with that name; an inUse slot is
    // never selected for a new resolve.
    struct ResolvedOutputSlot {
        GLuint texture = 0;
        GLuint fbo = 0;
        int width = 0;
        int height = 0;
        bool inUse = false;
    };

    std::array<ResolvedOutputSlot, kResolvedOutputSlotCount> outputSlots{};
    // Guards outputSlots' inUse flags between the resolve thread and the
    // consumer's release callback thread.
    std::mutex outputSlotMutex;

    struct CopyTargetSlot {
        AHardwareBuffer* buffer = nullptr;
        EGLImageKHR image = EGL_NO_IMAGE_KHR;
        GLuint texture = 0;
        GLuint fbo = 0;
        uint32_t width = 0;
        uint32_t height = 0;
    };

    std::array<CopyTargetSlot, kMaxCopyTargetCacheSlots> copyTargetSlots{};
    int nextCopyTargetEvictIndex = 0;

    // Persistent shader programs, built lazily on first use and reused for
    // every subsequent resolve/copy call on this session.
    GLuint program2D = 0;
    GLuint programOes = 0;

    // Picks a free (not inUse) pool slot, ensures its texture/FBO exist and
    // the texture is sized width x height, with this session's context
    // already current. Returns nullptr when every slot is in use or on any
    // GL failure (leaving the slot's prior state intact). Does not mark the
    // slot inUse; the caller does that only after a successful draw.
    ResolvedOutputSlot* AcquireFreeOutputSlot(int requestedWidth, int requestedHeight) {
        ResolvedOutputSlot* slot = nullptr;
        for (ResolvedOutputSlot& candidate : outputSlots) {
            if (!candidate.inUse) {
                slot = &candidate;
                break;
            }
        }
        if (slot == nullptr) {
            return nullptr;
        }

        if (slot->texture == 0) {
            glGenTextures(1, &slot->texture);
            if (slot->texture == 0) {
                return nullptr;
            }
        }

        if (slot->width != requestedWidth || slot->height != requestedHeight) {
            glBindTexture(GL_TEXTURE_2D, slot->texture);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, requestedWidth, requestedHeight, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
            const bool allocOk = (glGetError() == GL_NO_ERROR);
            glBindTexture(GL_TEXTURE_2D, 0);
            if (!allocOk) {
                return nullptr;
            }
            slot->width = requestedWidth;
            slot->height = requestedHeight;
        }

        if (slot->fbo == 0) {
            glGenFramebuffers(1, &slot->fbo);
            if (slot->fbo == 0) {
                return nullptr;
            }
            glBindFramebuffer(GL_FRAMEBUFFER, slot->fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                   slot->texture, 0);
            const bool complete =
                glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            if (!complete) {
                glDeleteFramebuffers(1, &slot->fbo);
                slot->fbo = 0;
                return nullptr;
            }
        }
        return slot;
    }

    // Marks the slot whose texture name matches `textureName` as free.
    // Returns false (no-op) when no in-use slot carries that name. Requires
    // no GL context: this only flips the ownership flag.
    bool ReleaseResolvedTexture(GLuint textureName) {
        if (textureName == 0) {
            return false;
        }
        for (ResolvedOutputSlot& slot : outputSlots) {
            if (slot.texture == textureName) {
                const bool wasInUse = slot.inUse;
                slot.inUse = false;
                return wasInUse;
            }
        }
        return false;
    }

    int InUseOutputSlotCount() const {
        int count = 0;
        for (const ResolvedOutputSlot& slot : outputSlots) {
            if (slot.inUse) {
                ++count;
            }
        }
        return count;
    }

    GLuint EnsureProgram2D() {
        if (program2D == 0) {
            program2D = LinkProgram(kVertexShaderSrc, kFragmentShaderSrc2D);
        }
        return program2D;
    }

    GLuint EnsureProgramOes() {
        if (programOes == 0) {
            programOes = LinkProgram(kVertexShaderSrc, kFragmentShaderSrcOes);
        }
        return programOes;
    }

    void DestroyCopyTargetSlot(CopyTargetSlot& slot, const NativeGpuSymbols& symbols) {
        if (slot.fbo != 0) {
            glDeleteFramebuffers(1, &slot.fbo);
            slot.fbo = 0;
        }
        if (slot.texture != 0) {
            glDeleteTextures(1, &slot.texture);
            slot.texture = 0;
        }
        if (slot.image != EGL_NO_IMAGE_KHR && symbols.destroyImage) {
            symbols.destroyImage(display, slot.image);
            slot.image = EGL_NO_IMAGE_KHR;
        }
        if (slot.buffer != nullptr && symbols.release) {
            symbols.release(slot.buffer);
            slot.buffer = nullptr;
        }
        slot.width = 0;
        slot.height = 0;
    }

    CopyTargetSlot* EnsureCopyTargetSlot(
        JNIEnv* env,
        jobject targetHardwareBuffer,
        jint requestedWidth,
        jint requestedHeight,
        const NativeGpuSymbols& symbols) {
        AHardwareBuffer* ahb = symbols.fromHardwareBuffer(env, targetHardwareBuffer);
        if (!ahb) {
            return nullptr;
        }

        AHardwareBuffer_Desc desc{};
        symbols.describe(ahb, &desc);
        const bool isRgbaCompatible =
            desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM ||
            desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
        if (desc.width == 0 || desc.height == 0 || desc.layers == 0 || !isRgbaCompatible ||
            desc.width != static_cast<uint32_t>(requestedWidth) ||
            desc.height != static_cast<uint32_t>(requestedHeight)) {
            return nullptr;
        }

        for (CopyTargetSlot& slot : copyTargetSlots) {
            if (slot.buffer == ahb && slot.texture != 0 && slot.fbo != 0 &&
                slot.width == desc.width && slot.height == desc.height) {
                return &slot;
            }
        }

        CopyTargetSlot* slotToUse = nullptr;
        for (CopyTargetSlot& slot : copyTargetSlots) {
            if (slot.buffer == nullptr) {
                slotToUse = &slot;
                break;
            }
        }
        if (slotToUse == nullptr) {
            slotToUse = &copyTargetSlots[static_cast<size_t>(nextCopyTargetEvictIndex)];
            nextCopyTargetEvictIndex = (nextCopyTargetEvictIndex + 1) % kMaxCopyTargetCacheSlots;
            DestroyCopyTargetSlot(*slotToUse, symbols);
        }

        symbols.acquire(ahb);

        EGLClientBuffer clientBuffer = symbols.getNativeClientBuffer(ahb);
        if (!clientBuffer) {
            symbols.release(ahb);
            return nullptr;
        }

        const EGLint imageAttribs[] = {EGL_NONE};
        EGLImageKHR image = symbols.createImage(
            display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, clientBuffer, imageAttribs);
        if (image == EGL_NO_IMAGE_KHR) {
            symbols.release(ahb);
            return nullptr;
        }

        GLuint texture = 0;
        glGenTextures(1, &texture);
        bool ok = texture != 0;
        if (ok) {
            glBindTexture(GL_TEXTURE_2D, texture);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            symbols.imageTargetTexture2D(GL_TEXTURE_2D, static_cast<GLeglImageOES>(image));
            ok = (glGetError() == GL_NO_ERROR);
            glBindTexture(GL_TEXTURE_2D, 0);
        }
        if (!ok) {
            if (texture != 0) glDeleteTextures(1, &texture);
            symbols.destroyImage(display, image);
            symbols.release(ahb);
            return nullptr;
        }

        GLuint fbo = 0;
        glGenFramebuffers(1, &fbo);
        if (fbo == 0) {
            glDeleteTextures(1, &texture);
            symbols.destroyImage(display, image);
            symbols.release(ahb);
            return nullptr;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        if (!complete) {
            glDeleteFramebuffers(1, &fbo);
            glDeleteTextures(1, &texture);
            symbols.destroyImage(display, image);
            symbols.release(ahb);
            return nullptr;
        }

        slotToUse->buffer = ahb;
        slotToUse->image = image;
        slotToUse->texture = texture;
        slotToUse->fbo = fbo;
        slotToUse->width = desc.width;
        slotToUse->height = desc.height;
        return slotToUse;
    }

    ~DuetGpuTextureBridgeSession() {
        if (display == EGL_NO_DISPLAY) {
            return;
        }
        // GL resources must be deleted with this session's own context
        // current, before the context/surface/display themselves go away.
        eglMakeCurrent(display, surface, surface, context);
        const NativeGpuSymbols& symbols = ResolveNativeGpuSymbols();
        if (symbols.valid) {
            for (CopyTargetSlot& slot : copyTargetSlots) {
                DestroyCopyTargetSlot(slot, symbols);
            }
        }
        for (ResolvedOutputSlot& slot : outputSlots) {
            if (slot.fbo != 0) {
                glDeleteFramebuffers(1, &slot.fbo);
                slot.fbo = 0;
            }
            if (slot.texture != 0) {
                glDeleteTextures(1, &slot.texture);
                slot.texture = 0;
            }
            slot.width = 0;
            slot.height = 0;
            slot.inUse = false;
        }
        if (program2D != 0) {
            glDeleteProgram(program2D);
            program2D = 0;
        }
        if (programOes != 0) {
            glDeleteProgram(programOes);
            programOes = 0;
        }
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface != EGL_NO_SURFACE) {
            eglDestroySurface(display, surface);
        }
        if (context != EGL_NO_CONTEXT) {
            eglDestroyContext(display, context);
        }
        eglTerminate(display);
    }
};

struct ScopedSessionCurrent {
    explicit ScopedSessionCurrent(DuetGpuTextureBridgeSession* session)
        : session(session),
          current(session != nullptr &&
                  eglMakeCurrent(session->display, session->surface, session->surface, session->context) == EGL_TRUE) {}

    ~ScopedSessionCurrent() {
        if (current && session != nullptr) {
            eglMakeCurrent(session->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
    }

    bool ok() const { return current; }

    DuetGpuTextureBridgeSession* session = nullptr;
    bool current = false;
};

std::atomic<jlong> gNextHandle{1};
std::mutex gSessionMutex;
std::unordered_map<jlong, std::shared_ptr<DuetGpuTextureBridgeSession>> gSessions;

std::shared_ptr<DuetGpuTextureBridgeSession> GetSession(jlong handle) {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    auto it = gSessions.find(handle);
    if (it != gSessions.end()) {
        return it->second;
    }
    return nullptr;
}

jlong CreateImpl(jint width, jint height) {
    if (width <= 0 || height <= 0) {
        return 0;
    }

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        return 0;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
        return 0;
    }

    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        eglTerminate(display);
        return 0;
    }

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE || numConfigs < 1) {
        eglTerminate(display);
        return 0;
    }

    const EGLint contextAttribsEs3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribsEs3);
    if (context == EGL_NO_CONTEXT) {
        const EGLint contextAttribsEs2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribsEs2);
    }
    if (context == EGL_NO_CONTEXT) {
        eglTerminate(display);
        return 0;
    }

    const EGLint pbufferAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, pbufferAttribs);
    if (surface == EGL_NO_SURFACE) {
        eglDestroyContext(display, context);
        eglTerminate(display);
        return 0;
    }

    if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        eglDestroySurface(display, surface);
        eglDestroyContext(display, context);
        eglTerminate(display);
        return 0;
    }

    auto session = std::make_shared<DuetGpuTextureBridgeSession>();
    session->display = display;
    session->context = context;
    session->surface = surface;
    session->width = static_cast<int>(width);
    session->height = static_cast<int>(height);

    // Do not leave this EGLContext current on the creator thread. MediaPipe
    // invokes mask callbacks on its own GL thread, and EGL forbids binding one
    // context on two threads at the same time.
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    const jlong handle = gNextHandle.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(gSessionMutex);
        gSessions.emplace(handle, std::move(session));
    }
    return handle;
}

jlong GetParentGlContextImpl(jlong handle) {
    auto session = GetSession(handle);
    if (!session) {
        return 0;
    }
    return reinterpret_cast<jlong>(session->context);
}

// Imports cameraHardwareBuffer transiently (EGLImage -> GL texture; 2D for
// RGBA/RGBX, external OES for every other camera/private/YUV/
// implementation-defined format), draws it through a full-screen shader into
// a free pool slot's RGBA output texture sized width x height, glFinish()es,
// marks that slot in use, and returns its texture name (0 on any failure,
// including "every slot is still owned by the consumer"). The transient
// imported texture/EGLImage/AHardwareBuffer ref are always released before
// returning, so the caller may recycle the camera buffer immediately; only
// the returned output texture stays owned until ReleaseResolvedTextureImpl.
jint ResolveCameraHardwareBufferImpl(JNIEnv* env, jlong handle, jobject cameraHardwareBuffer, jint width, jint height) {
    if (!env || !cameraHardwareBuffer || width <= 0 || height <= 0) {
        return 0;
    }
    auto session = GetSession(handle);
    if (!session) {
        return 0;
    }

    const NativeGpuSymbols& symbols = ResolveNativeGpuSymbols();
    if (!symbols.valid) {
        return 0;
    }

    ScopedSessionCurrent current(session.get());
    if (!current.ok()) {
        return 0;
    }

    AHardwareBuffer* ahb = symbols.fromHardwareBuffer(env, cameraHardwareBuffer);
    if (!ahb) {
        return 0;
    }
    symbols.acquire(ahb);

    AHardwareBuffer_Desc desc{};
    symbols.describe(ahb, &desc);
    if (desc.width == 0 || desc.height == 0 || desc.layers == 0) {
        symbols.release(ahb);
        return 0;
    }

    const bool isTexture2DFormat =
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM ||
        desc.format == AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
    const GLenum sourceTarget = isTexture2DFormat ? GL_TEXTURE_2D : GL_TEXTURE_EXTERNAL_OES;

    EGLClientBuffer clientBuffer = symbols.getNativeClientBuffer(ahb);
    if (!clientBuffer) {
        symbols.release(ahb);
        return 0;
    }

    const EGLint imageAttribs[] = {EGL_NONE};
    EGLImageKHR image = symbols.createImage(
        session->display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, clientBuffer, imageAttribs);
    if (image == EGL_NO_IMAGE_KHR) {
        symbols.release(ahb);
        return 0;
    }

    GLuint sourceTexture = 0;
    glGenTextures(1, &sourceTexture);
    bool attachOk = sourceTexture != 0;
    if (attachOk) {
        glBindTexture(sourceTarget, sourceTexture);
        glTexParameteri(sourceTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(sourceTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(sourceTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(sourceTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        symbols.imageTargetTexture2D(sourceTarget, static_cast<GLeglImageOES>(image));
        attachOk = (glGetError() == GL_NO_ERROR);
        glBindTexture(sourceTarget, 0);
    }

    jint resultTexture = 0;
    if (attachOk) {
        // Slot selection and the inUse flip share outputSlotMutex with
        // ReleaseResolvedTextureImpl, which MediaPipe may call from its own
        // GL thread while this resolve runs on the pipeline GL worker. The
        // draw itself only touches this session's context (already current
        // on this thread), so holding the mutex across it is safe and keeps
        // "select free slot" and "mark it owned" atomic with respect to
        // concurrent releases.
        std::lock_guard<std::mutex> lock(session->outputSlotMutex);
        DuetGpuTextureBridgeSession::ResolvedOutputSlot* slot =
            session->AcquireFreeOutputSlot(width, height);
        if (slot != nullptr) {
            const GLuint program = isTexture2DFormat ? session->EnsureProgram2D() : session->EnsureProgramOes();
            if (program != 0) {
                glBindFramebuffer(GL_FRAMEBUFFER, slot->fbo);
                glViewport(0, 0, width, height);
                const bool drawOk = DrawFullscreenQuad(program, sourceTarget, sourceTexture);
                glFinish();
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                if (drawOk) {
                    slot->inUse = true;
                    resultTexture = static_cast<jint>(slot->texture);
                }
            }
        }
    }

    if (sourceTexture != 0) {
        glDeleteTextures(1, &sourceTexture);
    }
    symbols.destroyImage(session->display, image);
    symbols.release(ahb);

    return resultTexture;
}

// Returns the pool slot whose texture name is `textureName` to the free
// state. Safe on any thread and needs no GL context (ownership flag only):
// the slot's texture is never deleted or redrawn here, so a stale MediaPipe
// read that raced this release still sees a valid texture. Unknown texture
// names and destroyed sessions are ignored (returns false).
jboolean ReleaseResolvedTextureImpl(jlong handle, jint textureName) {
    if (textureName <= 0) {
        return JNI_FALSE;
    }
    auto session = GetSession(handle);
    if (!session) {
        return JNI_FALSE;
    }
    std::lock_guard<std::mutex> lock(session->outputSlotMutex);
    return session->ReleaseResolvedTexture(static_cast<GLuint>(textureName)) ? JNI_TRUE : JNI_FALSE;
}

// Imports targetHardwareBuffer transiently as GL_TEXTURE_2D (fail closed if
// its format is not RGBA/RGBX), draws textureName into it through a
// full-screen sampler2D shader, and returns whether the draw succeeded. The
// transient imported texture/EGLImage/AHardwareBuffer ref are always
// released before returning.
constexpr jint kCopyFailedFenceFd = -2;

jint CopyTextureToHardwareBufferFenceFdImpl(
    JNIEnv* env,
    jlong handle,
    jint textureName,
    jint width,
    jint height,
    jobject targetHardwareBuffer,
    bool preferAcquireFence) {
    if (!env || !targetHardwareBuffer || textureName <= 0 || width <= 0 || height <= 0) {
        return kCopyFailedFenceFd;
    }
    auto session = GetSession(handle);
    if (!session) {
        return kCopyFailedFenceFd;
    }

    const NativeGpuSymbols& symbols = ResolveNativeGpuSymbols();
    if (!symbols.valid) {
        return kCopyFailedFenceFd;
    }

    ScopedSessionCurrent current(session.get());
    if (!current.ok()) {
        return kCopyFailedFenceFd;
    }

    auto* target = session->EnsureCopyTargetSlot(env, targetHardwareBuffer, width, height, symbols);
    if (!target) {
        return kCopyFailedFenceFd;
    }

    bool copyOk = false;
    glBindFramebuffer(GL_FRAMEBUFFER, target->fbo);
    const GLuint program = session->EnsureProgram2D();
    if (program != 0) {
        glViewport(0, 0, width, height);
        copyOk = DrawFullscreenQuad(program, GL_TEXTURE_2D, static_cast<GLuint>(textureName));
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!copyOk) {
        return kCopyFailedFenceFd;
    }

    if (preferAcquireFence && symbols.nativeFenceValid) {
        const EGLint syncAttribs[] = {
            EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID,
            EGL_NONE
        };
        EGLSyncKHR sync = symbols.createSync(
            session->display, EGL_SYNC_NATIVE_FENCE_ANDROID, syncAttribs);
        if (sync != EGL_NO_SYNC_KHR) {
            glFlush();
            const int fd = symbols.dupNativeFenceFd(session->display, sync);
            symbols.destroySync(session->display, sync);
            if (fd >= 0) {
                return static_cast<jint>(fd);
            }
        }
    }

    glFinish();
    return -1;
}

jboolean CopyTextureToHardwareBufferImpl(JNIEnv* env, jlong handle, jint textureName, jint width, jint height, jobject targetHardwareBuffer) {
    return CopyTextureToHardwareBufferFenceFdImpl(
        env, handle, textureName, width, height, targetHardwareBuffer,
        /*preferAcquireFence=*/false) != kCopyFailedFenceFd ? JNI_TRUE : JNI_FALSE;
}

void DestroyImpl(jlong handle) {
    std::lock_guard<std::mutex> lock(gSessionMutex);
    gSessions.erase(handle);
}

} // namespace

// ---------------------------------------------------------------------------
// Companion object JNI bindings (default Kotlin companion method naming)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_createAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jobject /*companion*/, jint width, jint height) {
    return CreateImpl(width, height);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_getAndroidDuetGpuTextureBridgeParentGlContext(
    JNIEnv* /*env*/, jobject /*companion*/, jlong handle) {
    return GetParentGlContextImpl(handle);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_resolveAndroidDuetCameraHardwareBufferToRgbaTexture(
    JNIEnv* env, jobject /*companion*/, jlong handle, jobject cameraHardwareBuffer, jint width, jint height, jlong /*timestampUs*/) {
    return ResolveCameraHardwareBufferImpl(env, handle, cameraHardwareBuffer, width, height);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_copyAndroidDuetTextureToHardwareBuffer(
    JNIEnv* env, jobject /*companion*/, jlong handle, jint textureName, jint width, jint height, jobject targetHardwareBuffer) {
    return CopyTextureToHardwareBufferImpl(env, handle, textureName, width, height, targetHardwareBuffer);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_copyAndroidDuetTextureToHardwareBufferAcquireFenceFd(
    JNIEnv* env, jobject /*companion*/, jlong handle, jint textureName, jint width, jint height, jobject targetHardwareBuffer) {
    return CopyTextureToHardwareBufferFenceFdImpl(
        env, handle, textureName, width, height, targetHardwareBuffer,
        /*preferAcquireFence=*/true);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_releaseAndroidDuetGpuTextureBridgeResolvedTexture(
    JNIEnv* /*env*/, jobject /*companion*/, jlong handle, jint textureName) {
    return ReleaseResolvedTextureImpl(handle, textureName);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_00024Companion_destroyAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jobject /*companion*/, jlong handle) {
    DestroyImpl(handle);
}

// ---------------------------------------------------------------------------
// Class-level JNI bindings (for @JvmStatic or direct class resolution)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jclass /*clazz*/, jint width, jint height) {
    return CreateImpl(width, height);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_getAndroidDuetGpuTextureBridgeParentGlContext(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong handle) {
    return GetParentGlContextImpl(handle);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_resolveAndroidDuetCameraHardwareBufferToRgbaTexture(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jobject cameraHardwareBuffer, jint width, jint height, jlong /*timestampUs*/) {
    return ResolveCameraHardwareBufferImpl(env, handle, cameraHardwareBuffer, width, height);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_copyAndroidDuetTextureToHardwareBuffer(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jint textureName, jint width, jint height, jobject targetHardwareBuffer) {
    return CopyTextureToHardwareBufferImpl(env, handle, textureName, width, height, targetHardwareBuffer);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_copyAndroidDuetTextureToHardwareBufferAcquireFenceFd(
    JNIEnv* env, jclass /*clazz*/, jlong handle, jint textureName, jint width, jint height, jobject targetHardwareBuffer) {
    return CopyTextureToHardwareBufferFenceFdImpl(
        env, handle, textureName, width, height, targetHardwareBuffer,
        /*preferAcquireFence=*/true);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_releaseAndroidDuetGpuTextureBridgeResolvedTexture(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong handle, jint textureName) {
    return ReleaseResolvedTextureImpl(handle, textureName);
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong handle) {
    DestroyImpl(handle);
}

#else // !defined(__ANDROID__)

// Non-Android host builds never link this shared library's Android-only
// target_sources, but these stubs keep the translation unit self-contained
// and fail closed if ever compiled outside Android.
extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_createAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jclass /*clazz*/, jint /*width*/, jint /*height*/) {
    return 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_getAndroidDuetGpuTextureBridgeParentGlContext(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/) {
    return 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_resolveAndroidDuetCameraHardwareBufferToRgbaTexture(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/, jobject /*cameraHardwareBuffer*/, jint /*width*/, jint /*height*/, jlong /*timestampUs*/) {
    return 0;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_copyAndroidDuetTextureToHardwareBuffer(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/, jint /*textureName*/, jint /*width*/, jint /*height*/, jobject /*targetHardwareBuffer*/) {
    return JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_copyAndroidDuetTextureToHardwareBufferAcquireFenceFd(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/, jint /*textureName*/, jint /*width*/, jint /*height*/, jobject /*targetHardwareBuffer*/) {
    return -2;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_releaseAndroidDuetGpuTextureBridgeResolvedTexture(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/, jint /*textureName*/) {
    return JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_destroyAndroidDuetGpuTextureBridge(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong /*handle*/) {
}

#endif // defined(__ANDROID__)
