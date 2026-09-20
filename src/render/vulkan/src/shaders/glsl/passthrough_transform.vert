// passthrough_transform.vert
// Vanguard Android True-DAG Phase 4B2C: fullscreen triangle vertex shader
// with push-constant UV rotation transform.
// Phase 10: push constant block extended with a color-matrix half (read only
// by passthrough_transform.frag) so both stages share one identical 7-vec4
// push-constant block layout/offsets.
//
// Draws a single fullscreen triangle using gl_VertexIndex 0/1/2.
// UV coordinates are transformed via push constants before passing to fragment shader.
//
// Push constants (VideoTransformFullPushConstants, 112 bytes, offset 0):
//   layout(push_constant) uniform Transform {
//     vec4 uvTransform0;      // offset  0: row0 coefficients [cx, cy, 0, bias] for u
//     vec4 uvTransform1;      // offset 16: row1 coefficients [cx, cy, 0, bias] for v
//     vec4 colorMatrixRow0;   // offset 32: fragment-only
//     vec4 colorMatrixRow1;   // offset 48: fragment-only
//     vec4 colorMatrixRow2;   // offset 64: fragment-only
//     vec4 colorMatrixRow3;   // offset 80: fragment-only
//     vec4 colorMatrixOffset; // offset 96: fragment-only
//   } xf;
//
// Fragment UV: uv = vec2(dot(xf.uvTransform0, vec4(x,y,0,1)),
//                        dot(xf.uvTransform1, vec4(x,y,0,1)))
// This vertex shader reads only uvTransform0/uvTransform1.

#version 450

layout(push_constant) uniform Transform {
    vec4 uvTransform0;
    vec4 uvTransform1;
    vec4 colorMatrixRow0;
    vec4 colorMatrixRow1;
    vec4 colorMatrixRow2;
    vec4 colorMatrixRow3;
    vec4 colorMatrixOffset;
} xf;

layout(location = 0) out vec2 outUv;
layout(location = 1) out vec2 outViewportNdc;

// Fullscreen triangle positions in clip space (NDC).
// gl_VertexIndex: 0=(-1,-1), 1=(3,-1), 2=(-1,3)
const vec2 kPositions[3] = vec2[](
    vec2(-1.0, -1.0),
    vec2( 3.0, -1.0),
    vec2(-1.0,  3.0)
);

// Identity UV coordinates for each vertex (in [0,1] space):
// 0=(0,0), 1=(2,0), 2=(0,2)
const vec2 kUvBase[3] = vec2[](
    vec2(0.0, 0.0),
    vec2(2.0, 0.0),
    vec2(0.0, 2.0)
);

void main() {
    vec2 pos = kPositions[gl_VertexIndex];
    vec2 uv  = kUvBase[gl_VertexIndex];

    // Apply UV rotation transform via push constants.
    // uv.x = dot(uvTransform0, vec4(uv.x, uv.y, 0, 1))
    // uv.y = dot(uvTransform1, vec4(uv.x, uv.y, 0, 1))
    vec4 uvExt = vec4(uv.x, uv.y, 0.0, 1.0);
    outUv = vec2(dot(xf.uvTransform0, uvExt),
                 dot(xf.uvTransform1, uvExt));
    outViewportNdc = pos;

    gl_Position = vec4(pos, 0.0, 1.0);
}
