// Compiled at runtime (SwiftPM's command-line build does not compile .metal files).
//
// One full-screen triangle per eye. For every headset pixel the fragment shader:
//   1. applies the PSVR lens pre-distortion (panotools model, values from Monado)
//      separately for R, G and B to cancel chromatic aberration,
//   2. turns the undistorted position into a view ray, rotates it by head orientation,
//   3. maps the ray onto the video (equirect 360 / 180, a flat virtual screen, or a mesh lookup table).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct EyeUniforms {
    float4 rot0, rot1, rot2;   // world-from-head rotation columns
    float4 videoRect;          // this eye's sub-rect of the video texture (x, y, w, h)
    float4 fov;                // tan(half fov x), tan(half fov y), viewport w px, viewport h px
    float4 k;                  // distortion k0..k3
    float4 params;             // k4, distortion scale px, flat half width, flat half height
    float4 aberration;         // r, g, b scale, distortion enabled
    float4 mode;               // projection (0 = 360, 1 = 180, 2 = flat), content (0 = test grid, 1 = video, 2 = loading)
    float4 color0, color1, color2;  // YCbCr -> RGB matrix columns
    float4 colorOffset;             // subtracted from (Y, Cb, Cr) first
    float4 meshInfo;                // first lookup-table slice for this eye
};

// Mesh projections (YouTube VR180) are pre-rendered into a direction -> texture-coordinate lookup
// table: six cube faces, each a 90-degree view. The same face table is used to build and to read it.
constant float3 kFaceForward[6] = { float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0),
                                    float3(0, -1, 0), float3(0, 0, 1), float3(0, 0, -1) };
constant float3 kFaceUp[6] = { float3(0, 1, 0), float3(0, 1, 0), float3(0, 0, 1),
                               float3(0, 0, -1), float3(0, 1, 0), float3(0, 1, 0) };

struct LutUniforms {
    uint face;
};

struct LutOut {
    float4 position [[position]];
    float2 uv;
};

vertex LutOut lut_vertex(uint vid [[vertex_id]],
                         const device float3* positions [[buffer(0)]],
                         const device float2* uvs [[buffer(1)]],
                         constant LutUniforms& lu [[buffer(2)]]) {
    float3 f = kFaceForward[lu.face], up = kFaceUp[lu.face], right = cross(f, up);
    float3 p = positions[vid];
    float z = dot(p, f);
    const float n = 0.001, far = 10.0;
    LutOut o;
    o.position = float4(dot(p, right), dot(p, up), z * far / (far - n) - far * n / (far - n), z);
    o.uv = uvs[vid];
    return o;
}

fragment float4 lut_fragment(LutOut in [[stage_in]]) {
    return float4(in.uv, 1.0, 1.0);   // b = covered by the mesh
}

// Texture coordinate (xy) and coverage (z) for a world direction.
static float3 mesh_lookup(float3 d, constant EyeUniforms& u, texture2d_array<float> lut, sampler s) {
    float3 a = abs(d);
    uint face;
    if (a.x >= a.y && a.x >= a.z) face = d.x > 0 ? 0 : 1;
    else if (a.y >= a.z) face = d.y > 0 ? 2 : 3;
    else face = d.z > 0 ? 4 : 5;
    float3 f = kFaceForward[face], up = kFaceUp[face], right = cross(f, up);
    float z = dot(d, f);
    float2 st = float2(0.5 + 0.5 * dot(d, right) / z, 0.5 - 0.5 * dot(d, up) / z);
    return lut.sample(s, st, uint(u.meshInfo.x) + face).xyz;
}

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float3 view_ray(float2 uv, constant EyeUniforms& u) {
    float2 t = float2((uv.x - 0.5) * 2.0 * u.fov.x, (0.5 - uv.y) * 2.0 * u.fov.y);
    float3x3 r = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    return r * normalize(float3(t, -1.0));
}

// Returns texture uv for a world ray; z = 1 when the ray hits the video.
static float3 video_uv(float3 d, constant EyeUniforms& u, texture2d_array<float> lut, sampler s) {
    int projection = int(u.mode.x);
    float2 local;
    bool hit;
    if (projection == 3) {
        float3 m = mesh_lookup(d, u, lut, s);
        local = m.xy;
        hit = m.z > 0.99;
    } else if (projection == 2) {
        if (d.z > -1e-3) return float3(0.0);
        float2 p = d.xy / -d.z;
        local = float2(0.5 + 0.5 * p.x / u.params.z, 0.5 - 0.5 * p.y / u.params.w);
        hit = all(local >= 0.0) && all(local <= 1.0);
    } else {
        float lon = atan2(d.x, -d.z);
        float lat = asin(clamp(d.y, -1.0, 1.0));
        float span = projection == 1 ? M_PI_F : 2.0 * M_PI_F;
        local = float2(0.5 + lon / span, 0.5 - lat / M_PI_F);
        hit = projection == 0 || (local.x >= 0.0 && local.x <= 1.0);
        if (projection == 0) local.x = fract(local.x);
    }
    return float3(u.videoRect.xy + local * u.videoRect.zw, hit ? 1.0 : 0.0);
}

// Lat/long grid shown with --test (no video): checks tracking and lens settings.
static float3 test_pattern(float3 d) {
    float lon = atan2(d.x, -d.z) * 180.0 / M_PI_F;
    float lat = asin(clamp(d.y, -1.0, 1.0)) * 180.0 / M_PI_F;
    float2 g = abs(fract(float2(lon, lat) / 15.0 + 0.5) - 0.5) * 15.0;
    float line = 1.0 - smoothstep(0.0, 0.35, min(g.x, g.y));
    float3 base = lat > 0.0 ? float3(0.10, 0.16, 0.30) : float3(0.18, 0.13, 0.08);
    float3 lineColor = abs(lon) < 0.6 ? float3(1.0, 0.3, 0.3) : (abs(lat) < 0.6 ? float3(0.3, 1.0, 0.4) : float3(0.85));
    return mix(base, lineColor, line);
}

static float3 shade(float3 d, constant EyeUniforms& u, texture2d<float> luma, texture2d<float> chroma,
                    texture2d_array<float> lut, sampler s) {
    if (u.mode.y < 0.5) return test_pattern(d);
    if (u.mode.y > 1.5) return float3(0.0);
    float3 t = video_uv(d, u, lut, s);
    if (t.z < 0.5) return int(u.mode.x) == 2 ? float3(0.02) : float3(0.0);
    float3 ycc = float3(luma.sample(s, t.xy).r, chroma.sample(s, t.xy).rg) - u.colorOffset.xyz;
    return saturate(float3x3(u.color0.xyz, u.color1.xyz, u.color2.xyz) * ycc);
}

fragment float4 eye_fragment(VOut in [[stage_in]],
                             constant EyeUniforms& u [[buffer(0)]],
                             texture2d<float> luma [[texture(0)]],
                             texture2d<float> chroma [[texture(1)]],
                             texture2d_array<float> lut [[texture(2)]],
                             sampler s [[sampler(0)]]) {
    if (u.aberration.w < 0.5) {
        return float4(shade(view_ray(in.uv, u), u, luma, chroma, lut, s), 1.0);
    }
    float2 px = u.fov.zw;
    float2 p = (in.uv - 0.5) * px / u.params.y;
    float r = length(p);
    float f = u.k.x + r * (u.k.y + r * (u.k.z + r * (u.k.w + r * u.params.x)));
    float2 pd = p * f * u.params.y / px;
    float red = shade(view_ray(0.5 + pd * u.aberration.x, u), u, luma, chroma, lut, s).r;
    float green = shade(view_ray(0.5 + pd * u.aberration.y, u), u, luma, chroma, lut, s).g;
    float blue = shade(view_ray(0.5 + pd * u.aberration.z, u), u, luma, chroma, lut, s).b;
    return float4(red, green, blue, 1.0);
}
"""
