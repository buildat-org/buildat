// A field over the world's x and z that a game sets, 0 to 1, read at a
// pixel: builtin/voxel_shading's set_area_field() puts it on unit 6 of
// the scene and light passes, and cAreaField says where its grid lies --
// (x0, z0, 1 / width, 1 / depth) in nodes. Zero when no game set one
// (an unset parameter reads as zero), and then nothing is sampled.
//
// What the voxel shaders make of it is decay ([SKELENTI_DANGER_LOOK]): a
// place's danger in skelenti, the surface paling towards grey, darker,
// bones lying in dirt on the ground ([SKELENTI_BONES]). Included by PBRVoxel.glsl and VoxelUnlit.glsl
// inside their pixel shaders.

uniform vec4 cAreaField;
uniform sampler2D sAreaField6;

float GetAreaField(vec3 worldPos)
{
    if (cAreaField.z <= 0.0)
        return 0.0;
    vec2 uv = (worldPos.xz - cAreaField.xy) * cAreaField.zw;
    return texture2D(sAreaField6, clamp(uv, 0.0, 1.0)).r;
}

float AreaFieldHash(vec3 cell)
{
    vec3 p = fract(cell * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Far off a bone is under a pixel and would glitter, so from 15 to 40
// nodes away the bones fade into their average, spread evenly.
// simplified: by the distance, tuned at 800x500 and a 72 degree view; a
// screen several times larger glitters less and blurs sooner than it
// could. The upgrade is the bone's width on screen (fwidth), where the
// target has derivatives.
float AreaFieldFar(vec3 worldPos)
{
    return smoothstep(15.0, 40.0, distance(worldPos, cCameraPosPS));
}

// **Bones lying on the ground** ([SKELENTI_BONES]): seen from above, one
// in a cell of BONE_CELL nodes; layers of these grids, each its own
// scatter, more of them as the field rises -- BONE_PILE bones a cell at
// full, a ground all bones (user, 2026-10-15). A bone is a shaft with two
// knobs at each end, of its own length, thickness and turn, in a smudge
// of dirt. A side gets BONE_SIDE of a top's, on its own grids.
#ifndef BONE_CELL
#define BONE_CELL 0.8
#define BONE_PILE 8.0
#define BONE_DIRT 0.5
#define BONE_SIDE 0.3
#endif

// How many layers of bones at d, a fraction for the last one's share
float BoneLayers(float d)
{
    return BONE_PILE * d * d;
}

// One layer's bone at p: -> (how much is bone, how far along it from the
// middle 0..1, how much is dirt, the bone's own 0..1)
vec4 GetBoneIn(vec2 p, float layer, float share)
{
    p = p / BONE_CELL + vec2(0.37, 0.61) * layer;
    vec2 cell = floor(p);
    vec2 q = p - cell;
    vec3 k = vec3(cell, 0.0) + vec3(0.0, 0.0, layer * 31.0);
    if (AreaFieldHash(k + vec3(0.0, 0.0, 5.0)) >= share)
        return vec4(0.0);
    float own = AreaFieldHash(k + vec3(0.0, 0.0, 11.0));
    // Half its length and its radius, in the cell's units; kept inside
    // the cell, so no neighbour has to be looked at
    float len = mix(0.18, 0.34, AreaFieldHash(k + vec3(0.0, 0.0, 13.0)));
    float r = mix(0.045, 0.07, AreaFieldHash(k + vec3(0.0, 0.0, 19.0)));
    float a = AreaFieldHash(k + vec3(0.0, 0.0, 29.0)) * 6.2832;
    vec2 dir = vec2(cos(a), sin(a));
    vec2 room = vec2(max(0.0, 1.0 - 2.0 * (len + 2.0 * r)));
    vec2 c = vec2(0.5) + (vec2(AreaFieldHash(k + vec3(0.0, 0.0, 17.0)),
            AreaFieldHash(k + vec3(0.0, 0.0, 23.0))) - 0.5) * room;
    vec2 v = q - c;
    float t = dot(v, dir);
    float s = dot(v, vec2(-dir.y, dir.x));
    float shaft = length(vec2(t - clamp(t, -len, len), s)) - r;
    float knob = min(length(vec2(abs(t) - len, s - r * 0.8)),
            length(vec2(abs(t) - len, s + r * 0.8))) - r * 1.1;
    float edge = min(shaft, knob);
    return vec4(1.0 - smoothstep(-0.012, 0.012, edge),
            clamp(abs(t) / len, 0.0, 1.0),
            (1.0 - smoothstep(0.0, 0.15, edge)) * BONE_DIRT, own);
}

// The bones at p in n layers, the top layer's over those under it, the
// dirt of all; seed tells one set of grids from another
vec4 GetBone(vec2 p, float n, float seed)
{
    vec4 top = vec4(0.0);
    float dirt = 0.0;
    for (int i = 0; i < int(BONE_PILE + 0.999); i++) {
        if (float(i) >= n)
            break;
        vec4 b = GetBoneIn(p, float(i) + seed, min(1.0, n - float(i)));
        dirt = max(dirt, b.z);
        top.yw = mix(top.yw, b.yw, b.x);
        top.x = max(top.x, b.x);
    }
    top.z = dirt;
    return top;
}

// The albedo decayed by d: towards its own grey and darker, and bones in
// dirt -- on a face looking up (normal: the world's), fewer on a side. gamma: 2.2 for a caller
// in linear units (pbr), 1.0 in display units (unlit).
vec3 DecayAlbedo(vec3 albedo, vec3 worldPos, float d, vec3 normal,
        float gamma)
{
    float grey = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
    albedo = mix(albedo, vec3(grey), 0.6 * d) * (1.0 - 0.3 * d);
    if (normal.y < -0.5)
        return albedo;
    bool top = normal.y >= 0.5;
    // A side's plane: across it along x or z, and up
    vec2 p = top ? worldPos.xz : abs(normal.x) > abs(normal.z) ?
            worldPos.zy : worldPos.xy;
    float n = BoneLayers(d) * (top ? 1.0 : BONE_SIDE);
    vec3 g = vec3(gamma);
    vec3 dirt = pow(vec3(0.33, 0.27, 0.19), g);
    vec4 b = GetBone(p, n, top ? 0.0 : 40.0);
    // Off-white to yellowed brown, darker towards the ends
    vec3 bone = pow(mix(vec3(0.86, 0.81, 0.68), vec3(0.64, 0.52, 0.34), b.w) *
            (1.0 - 0.3 * b.y * b.y), g);
    vec3 near = mix(mix(albedo, dirt, b.z), bone, b.x);
    // Their average: a bone covers about a tenth of its cell, its dirt
    // half again
    vec3 far = mix(mix(albedo, dirt, min(1.0, n * 0.1) * BONE_DIRT),
            pow(vec3(0.75, 0.67, 0.51), g), 1.0 - pow(0.9, n));
    return mix(near, far, AreaFieldFar(worldPos));
}
