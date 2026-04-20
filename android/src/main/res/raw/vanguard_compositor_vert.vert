// VanguardCompositor.vert
// Vanguard Media Engine — Phase 3 Android OpenGL ES 3 Vertex Shader
//
// Passes through a full-screen quad and UV coordinates to the fragment stage.

#version 300 es
precision mediump float;

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;

out vec2 vTexCoord;

void main() {
    // aPosition is in [0,1] UV space; convert to NDC [-1,1]
    gl_Position = vec4(aPosition.x * 2.0 - 1.0, -(aPosition.y * 2.0 - 1.0), 0.0, 1.0);
    vTexCoord   = aTexCoord;
}
