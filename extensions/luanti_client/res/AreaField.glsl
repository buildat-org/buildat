// A field over the world's x and z that a game sets, 0 to 1, read at a
// pixel: builtin/voxel_shading's set_area_field() puts it on unit 6 of
// the scene and light passes, and cAreaField says where its grid lies --
// (x0, z0, 1 / width, 1 / depth) in nodes. Zero when no game set one
// (an unset parameter reads as zero), and then nothing is sampled.
//
// What the voxel shaders make of it is decay ([SKELENTI_DANGER_LOOK]): a
// place's danger in skelenti, the surface paling towards grey, darker,
// chipped with bone. Included by PBRVoxel.glsl and VoxelUnlit.glsl
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

// Eight chips a voxel across, the grid offset by a fraction so that no
// face lies on a cell boundary (see GetSpotPos() in PBRVoxel.glsl for why
// that matters). How many are bone grows with the field. Farther than a
// chip is a pixel wide they would glitter, so from 15 to 40 nodes away
// they fade into their share of bone, spread evenly.
// simplified: by the distance, tuned at 800x500 and a 72 degree view; a
// screen several times larger glitters less and blurs sooner than it
// could. The upgrade is the chip's width on screen (fwidth), where the
// target has derivatives.
float AreaFieldFar(vec3 worldPos)
{
    return smoothstep(15.0, 40.0, distance(worldPos, cCameraPosPS));
}

float GetBoneChip(vec3 worldPos, float d)
{
    vec3 cell = floor(worldPos * 8.0 + 0.37);
    float share = 0.4 * d * d;
    float chip = AreaFieldHash(cell + 131.0) < share ? 1.0 : 0.0;
    return mix(chip, share, AreaFieldFar(worldPos));
}

// The albedo decayed by d: towards its own grey, darker, and bone where a
// chip is. bone is the bone's colour in the caller's units (linear in the
// pbr shader, display in the unlit one).
vec3 DecayAlbedo(vec3 albedo, vec3 worldPos, float d, vec3 bone)
{
    float grey = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
    albedo = mix(albedo, vec3(grey), 0.85 * d) * (1.0 - 0.3 * d);
    return mix(albedo, bone, GetBoneChip(worldPos, d) * 0.9);
}
