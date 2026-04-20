// VanguardCompositor.frag
// Vanguard Media Engine — Phase 3 Android OpenGL ES 3 Fragment Shader
//
// OES external textures (samplerExternalOES) are required for SurfaceTexture.
// Android's MediaCodec outputs to SurfaceTexture which wraps an OES texture.
// The GPU driver handles YUV → RGB conversion internally for external textures.

#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

in vec2 vTexCoord;
out vec4 fragColor;

// Background video frame from SurfaceTexture (OES)
uniform samplerExternalOES uBackground;

// Optional foreground layer (second video or bitmap overlay, sampler2D)
uniform sampler2D uForeground;
uniform float     uForegroundAlpha; // 0.0 = invisible, 1.0 = opaque
uniform bool      uHasForeground;

// Effect uniforms
uniform float uContrast;
uniform float uBrightness;
uniform float uSaturation;

vec3 applyEffects(vec3 color) {
    color += uBrightness;
    color = (color - 0.5) * uContrast + 0.5;
    float luminance = dot(color, vec3(0.299, 0.587, 0.114));
    color = mix(vec3(luminance), color, uSaturation);
    return clamp(color, 0.0, 1.0);
}

void main() {
    vec4 bg = texture(uBackground, vTexCoord);
    bg.rgb = applyEffects(bg.rgb);

    if (uHasForeground) {
        vec4 fg = texture(uForeground, vTexCoord);
        // Premultiplied alpha composite
        vec3 composited = bg.rgb * (1.0 - fg.a * uForegroundAlpha) + fg.rgb * uForegroundAlpha;
        fragColor = vec4(composited, 1.0);
    } else {
        fragColor = bg;
    }
}
