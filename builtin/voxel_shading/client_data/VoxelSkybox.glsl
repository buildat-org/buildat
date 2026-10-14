// The sky the voxel world stands under. Drawn on a skybox, so it has no depth
// presence at all: it is behind everything and never in the way of the ground.
//
// The gradient here is the one apps/sample_lighting_scene/make_client_data.py bakes
// into VoxelSky.xml, so what a glossy surface reflects agrees with what is
// overhead. The sun and the clouds are drawn only here: the reflection of the
// sky carries its own painted sun disc, and the clouds are not reflected at
// all, which is the one place the two skies knowingly disagree.
#include "Uniforms.glsl"
#include "Transform.glsl"
#include "Samplers.glsl"

varying vec3 vTexCoord;

uniform vec3 cSunDirection;

// The two ends of the gradient, and how much of the sky is cloud. They are
// parameters rather than constants because a game says what its own sky is
// -- Luanti's set_sky and set_clouds -- and create_skybox() sets them to the
// values below, which are what this sky was drawn as before any game asked.
// A material that sets none of them gets black, so nothing may leave them
// out.
uniform vec3 cSkyZenith;
uniform vec3 cSkyHorizon;
uniform float cCloudCover;
// How much light is on the clouds: one by day, and what a game's own night
// is at night. A cloud is white because the sun is on it, and a white cloud
// over a dark sky is the one thing that gives a night sky away.
uniform float cCloudLight;

// Kept equal to ZENITH, HORIZON and GROUND in make_client_data.py
const vec3 ZENITH = vec3(0.13, 0.24, 0.58);
const vec3 HORIZON = vec3(0.55, 0.66, 0.84);
// Below the horizon the drawn sky is haze rather than the cube map's GROUND:
// what is down there is the world, and the little of this that shows past its
// edge should sit behind distant terrain rather than under it
const vec3 HAZE = vec3(0.45, 0.49, 0.56);
const float HAZE_DEPTH = 0.25;

// A square rather than a disc, since everything else here is cubic. Half its
// width, on a plane one unit along the sun direction, so about 4 degrees.
// The size and the colour are parameters because a game says what is in its
// sky -- Luanti's set_sun and set_moon -- and a size of zero is no sun at
// all. create_skybox() sets them to what this sky was drawn as.
uniform float cSunHalf;
uniform vec3 cSunColor;
const float SUN_EDGE = 0.004;
// And whether what goes in that square is a game's own picture of a sun or a
// moon -- Luanti's set_sun{texture = ...} -- which is the diffuse texture
// when this is on. Zero is the painted square, which is what a material that
// says nothing gets.
uniform float cSunTextured;

// The stars, which are the other thing a game says its sky has. One to a
// cell of a grid laid over the sky, in the cells whose own hash falls under
// the density; a density of zero is a sky with none, which is what a game
// that says nothing gets. What decides when they are out is whoever sets
// the density -- here it is simply how many there are.
uniform float cStarDensity;
uniform vec3 cStarColor;
uniform float cStarSize;
const float STAR_GRID = 40.0;

// A flat layer of cloud, projected onto the sky by direction and snapped to a
// grid of its own, so that it is drawn in squares like everything else here.
// Coverage is how much of the layer is cloud at all; the two thresholds either
// side of it are where a cloud goes from its edge tone to its lit one.
const float CLOUD_SCALE = 6.0;
const float CLOUD_PIXELS = 11.0;   // Cloud grid squares per unit of the layer
const float CLOUD_COVERAGE = 0.34;
const float CLOUD_LIT_STEP = 0.07;
const vec3 CLOUD_LIT = vec3(1.05, 1.04, 1.02);
const vec3 CLOUD_SHADED = vec3(0.72, 0.76, 0.84);
const vec2 CLOUD_WIND = vec2(0.010, 0.004);
// Below CLOUD_HORIZON the projection is clamped, and holding it still is what
// would smear the layer down the sky in vertical streaks. The clouds are gone
// by then: they fade out between the two, so nothing of the clamped part is
// ever drawn. A flat layer thins into haze towards the horizon anyway.
const float CLOUD_HORIZON = 0.16;
const float CLOUD_FADE = 0.38;

float SkyHash(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float SkyNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(SkyHash(i), SkyHash(i + vec2(1.0, 0.0)), f.x),
               mix(SkyHash(i + vec2(0.0, 1.0)), SkyHash(i + vec2(1.0, 1.0)), f.x),
               f.y);
}

// Two octaves rather than three: a third one is finer than the grid the
// clouds are snapped to and only breaks them up into loose squares
float CloudDensity(vec2 p)
{
    float v = SkyNoise(p) * 0.65;
    v += SkyNoise(p * 2.03) * 0.35;
    return v;
}

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    gl_Position.z = gl_Position.w;
    vTexCoord = iPos.xyz;
}

void PS()
{
    vec3 d = normalize(vTexCoord);
    vec3 sun = normalize(cSunDirection);

    vec3 color = d.y < 0.0 ?
            mix(cSkyHorizon, HAZE, min(1.0, -d.y / HAZE_DEPTH)) :
            mix(cSkyHorizon, cSkyZenith, sqrt(d.y));

    // Clouds, on a plane overhead: dividing by d.y is what makes them lie flat
    // and crowd together towards the horizon instead of wrapping the dome
    if(d.y > 0.0){
        vec2 p = d.xz / max(d.y, CLOUD_HORIZON) * CLOUD_SCALE +
                cElapsedTimePS * CLOUD_WIND;
        // One value per square, so the edges land on the grid rather than
        // wherever the noise happened to cross the threshold
        float density = CloudDensity(floor(p * CLOUD_PIXELS) / CLOUD_PIXELS);
        float threshold = 1.0 - cCloudCover;
        // Two tones: the thicker middle of a cloud and the squares around it
        vec3 cloud = (density > threshold + CLOUD_LIT_STEP ?
                CLOUD_LIT : CLOUD_SHADED) * cCloudLight;
        float cover = step(threshold, density) *
                smoothstep(CLOUD_HORIZON, CLOUD_FADE, d.y);
        color = mix(color, cloud, cover);
    }

    // The sun, over the clouds: it is the one thing up there that is not
    // behind them
    float towards = dot(d, sun);
    if(towards > 0.0 && cSunHalf > 0.0){
        vec3 su = normalize(cross(sun, vec3(0.0, 1.0, 0.0)));
        vec3 sv = cross(su, sun);
        vec3 onPlane = d / towards;
        vec2 at = vec2(dot(onPlane, su), dot(onPlane, sv));
        vec2 uv = abs(at);
        if(cSunTextured > 0.5){
            // The game's own picture over the same square, by its alpha:
            // the sky is behind it where it is clear
            vec2 t = at / cSunHalf * 0.5 + 0.5;
            if(t.x >= 0.0 && t.x <= 1.0 && t.y >= 0.0 && t.y <= 1.0){
                vec4 picture = texture2D(sDiffMap, t);
                color = mix(color, picture.rgb * cSunColor, picture.a);
            }
        } else {
            float square = 1.0 - smoothstep(cSunHalf - SUN_EDGE,
                    cSunHalf + SUN_EDGE, max(uv.x, uv.y));
            color = mix(color, cSunColor, square);
        }
    }

    // The stars, under the sun and over everything else: one to a cell, at
    // the place inside it its own hash puts it
    if(cStarDensity > 0.0 && d.y > 0.0){
        vec3 sp = d * STAR_GRID;
        vec3 cell = floor(sp);
        float h = SkyHash(cell.xy + cell.z * 37.0);
        if(h < cStarDensity){
            vec3 at = cell + vec3(fract(h * 13.7), fract(h * 31.3),
                    fract(h * 71.1));
            float star = 1.0 - smoothstep(0.0, cStarSize, length(sp - at));
            color = mix(color, cStarColor, star);
        }
    }

    gl_FragColor = vec4(color, 1.0);
}
