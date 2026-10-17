// extensions/physical_sky: the sky in HDR, at radiances the exposure
// meters ([LC_SKY_SHARED]): a gradient from the horizon to the zenith, the
// sun's disc and the moon, the stars at night, a flat layer of cloud lit by
// the sun and the sky, and floorplanner's treeline. Luanti's coloured sky,
// which the parity modes draw, is extensions/luanti_client/res/LuantiSky.glsl,
// the other half of what was one shader (SkyDome) with a switch.
//
// What time of day it is is not worked out here. The client hands in the
// radiances and the direction of the sun (init.lua beside this file works
// them out), so this file only draws what it is told.
//
// The cloud layer is the one from builtin/voxel_shading's VoxelSkybox, with
// the colour handed in rather than baked in: squares of two tones on a plane
// overhead, thinning into the sky towards the horizon.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
// SkyVis.glsl is not included any more: this shader dims by a scalar and has
// no use for a direction. See the note beside cSkyOutside below, and
// [CAVE_SKY]'s correction in doc/plan/rendering_plan.md.

varying vec3 vTexCoord;

uniform vec3 cSkyTop;
uniform vec3 cSkyHorizon;
uniform vec3 cSunDirection;
uniform vec3 cSunTint;
// [DAWN_LIGHT]: the sky's light before the sun, a radiance added on the band
// along the horizon in the sun's half -- so the glow lights the cube the
// reflections are drawn from, as the band does. Unset reads as zero.
uniform vec3 cDawnGlow;
// [DUSK_SKY]: the pbr band's level over the sky's own, the share of the
// glow the dome away from the sun gets, and the band's share of orange
uniform vec3 cDuskBand;
uniform float cStarFade;
// What the game says is up there: half the width of the sun's and the moon's
// squares, zero for one it has turned off; how many of the star grid's cells
// hold a star, and what colour; and how much of the sky the clouds cover.
uniform float cSunSize;
uniform float cSunOverexposure;
// The sun as a disc at its radiance, for the pbr path: E0 of the hour over
// the disc's solid angle, in the sun's colour for the elevation, which is
// what the path trace draws (Nishita's disc, clipped white at every hour)
// and what the sky cube then carries into the water. Zero (unset) keeps
// Luanti's square at texture brightness, which the parity modes want.
uniform vec3 cSunRadiance;
uniform float cMoonSize;
uniform float cStarDensity;
// [STARS_AXIS] The sky's turn, the axis the sun, the moon and the stars
// go round: the rows of its inverse (set_sky_turn), cSkyTurnOn 1 when a
// game gave one
uniform vec3 cSkyTurnX;
uniform vec3 cSkyTurnY;
uniform vec3 cSkyTurnZ;
uniform float cSkyTurnOn;
uniform vec3 cStarColor;
uniform float cCloudCoverage;
// How opaque the layer is, which is the alpha the game gave its cloud colour
uniform float cCloudAlpha;
// Whether the game gave the sun or the moon a texture of its own. When it
// did, sDiffMap holds the sun's and sNormalMap the moon's -- two units
// because a material has no third one this needs -- and the square is that
// texture instead of a flat colour.
uniform float cSunTextured;
uniform float cMoonTextured;
// How fast the cloud layer drifts, in this file's own units per second. The
// game says nodes a second and the client fudges it, because these clouds
// are not a layer at a height; see CLOUD_WIND below for what a node comes to.
uniform vec2 cCloudWind;

// **What a player who cannot see the sky is under.** Luanti's `indoors`
// colour, already multiplied by how light it is, and whether the game let
// this happen at all -- its `auto_dim_skybox`, 1 for yes and 0 for no.
//
// The value it is mixed by is the sky visibility cube the client already
// keeps, per direction: a seam is a place where the rasteriser shows sky
// where the voxel data says rock, so the cube is near zero there **by
// construction** and the hole goes dark without anything having to detect
// it. At a tunnel mouth the mouth stays bright and the rock beside it does
// not. See [CAVE_SKY] in doc/plan/rendering_plan.md.
//
// Both read as zero for a material that sets neither, which is a sky that
// is never dimmed -- the right answer for a client that knows nothing about
// this.
uniform vec3 cSkyIndoors;
uniform float cSkyAutoDim;
// The gradient's shape: the path trace's at 13:00, the horizon's band kept
// to the lowest part of the dome and the top colour holding above it
// (render over the sea, elevation 17 to 2 degrees: the top's share 0.90,
// 0.71, 0.36, 0.09, 0.01 -- a smoothstep of sin elevation over 0 to 0.38);
// the sky is the lighting's number ([PBR_FIT] term 1). 1 here is an
// overcast dome instead (floorplanner's [FP_OVERCAST]): the horizon colour
// spread up by the square root, nearer the CIE dome's than the clear sky's.
uniform float cSkyOvercast;
// The cloud colour is a reflectance and these are what lights it
// ([CLOUD_LIGHT]): the sun's share, albedo * E_sun * k_sun * facing / pi,
// and the sky's, albedo * sky_mean / pi, both in the sky's radiance units.
// The thin edge of a cloud lets the sun through and the thick middle does
// not, so the sun's share thins with the density.
uniform vec3 cCloudSun;
uniform vec3 cCloudSky;
// How much sky the camera can see, as one number: 0 in a cave, 1 anywhere
// that is not one. See [CAVE_SKY]'s correction in doc/plan/rendering_plan.md.
uniform float cSkyOutside;
// **A treeline along the horizon** (apps/floorplanner's plan setting;
// unset, 0, it is not drawn): a tree's height over its distance, and the
// ground's height in the world, which its foot stands on where the ground
// ends (TREE_DISTANCE away).
uniform float cTreeline;
uniform float cTreeGround;

// How far below the horizon the sky darkens into the ground haze
const float HAZE_DEPTH = 0.25;

// How soft the edge of the sun's or the moon's square is. How wide they are
// is cSunSize and cMoonSize, which the game decides.
const float BODY_EDGE = 0.004;
const vec3 MOON_COLOR = vec3(0.86, 0.88, 0.94);
// The sun's own colour, which it wears until it is low enough to take the
// tint the horizon is painted with: a sun the colour of dawn at midday is
// what the tint alone gives
const vec3 SUN_COLOR = vec3(1.0, 0.97, 0.86);
// How far past white the sun's disc is drawn. The sun is brighter than
// anything else in the frame by orders of magnitude and it has to be said
// somehow: on the vanilla path the frame clips at one, so the disc is pushed
// a little past it and its core comes out white with the texture's own colour
// left at the edges; on the PBR path the frame is tone mapped and this is a
// real multiplier, which is also what makes the bloom around it. Set from
// world.lua. Scaled back to nothing as the sun comes down to the horizon,
// because a low sun is a dim one and its colour is the point of it.

const float CLOUD_SCALE = 6.0;
const float CLOUD_PIXELS = 11.0;
// How wide the thin edge of a cloud is, in the noise's own units: the cells
// that used to be drawn a darker grey are these, and they are drawn thin
// instead. It starts at the threshold rather than straddling it, so that the
// sky the clouds cover is still the sky the threshold says they cover.
const float CLOUD_EDGE = 0.07;
const float CLOUD_HORIZON = 0.16;
const float CLOUD_FADE = 0.38;

// The stars: one per cell of a grid laid over the sky, only some cells holding
// one at all -- how many is cStarDensity, out of how many stars the game asked
// for. Few enough to read as stars: at any greater density the night sky is
// white noise.
//
// The grid is on the faces of a cube around the viewer rather than on a plane
// overhead, which keeps a cell about the same size wherever it is; a plane
// crowds them at the horizon and thins them at the zenith. Six faces of
// 2 x STAR_GRID cells is about 250 thousand of them, so the density a game of
// a thousand stars comes to puts a thousand in the sky.
const float STAR_GRID = 102.0;
// How bright a star is drawn, against the colour the game gave them. Less than
// the colour says, because the moon is the bright thing in a night sky and a
// star drawn at its own colour comes out brighter than the moon does.
// A tenth of what it was ([STARS], user 2026-09-22: half the size and a
// tenth as bright).
const float STAR_BRIGHTNESS = 0.065;
// How much of its cell a star fills, about the cell's centre: half its
// width, so a quarter of the cell's area
const float STAR_SIZE = 0.5;

// Which cell of that a direction falls in: the face it points at, and where on
// the face it lands; frac_out is where within the cell, 0..1 each way
vec3 StarCell(vec3 s, out vec2 frac_out)
{
    vec3 a = abs(s);
    vec2 uv;
    float face;
    if(a.x >= a.y && a.x >= a.z){
        uv = s.yz / a.x;
        face = s.x > 0.0 ? 0.0 : 1.0;
    } else if(a.y >= a.z){
        uv = s.xz / a.y;
        face = s.y > 0.0 ? 2.0 : 3.0;
    } else {
        uv = s.xy / a.z;
        face = s.z > 0.0 ? 4.0 : 5.0;
    }
    vec2 scaled = uv * STAR_GRID;
    frac_out = fract(scaled);
    return vec3(floor(scaled), face);
}

float SkyHash(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// The trees, in units of a tree's height: x along the horizon, y up from
// the ground. A row of trees in cells of `cell`, each a spruce (a cone in
// tiers) or a pine (a bare trunk under a rounded crown), of a height of
// lo..hi; seed tells rows apart. Returns how much of the point is a tree
// (the edge softened over `aa`), and in .y whether it is a pine's. `around`
// is the horizon's length in these units: the cells are fitted to it, so
// the row meets itself behind with no seam.
vec2 TreeRow(vec2 p, float cell0, float lo, float hi, float seed, float aa,
        float around, float pines)
{
    float n = max(1.0, floor(around / cell0));
    float cell = around / n;
    float c = floor(p.x / cell);
    vec2 best = vec2(0.0);
    for(int k = -2; k <= 2; k++){
        float ix = c + float(k);
        float id = mod(ix, n);
        float present = SkyHash(vec2(id, seed));
        if(present < 0.04)
            continue;
        float at = (ix + 0.2 + 0.6 * SkyHash(vec2(id, seed + 1.0))) * cell;
        float h = mix(lo, hi, SkyHash(vec2(id, seed + 2.0)));
        float pine = step(1.0 - pines, SkyHash(vec2(id, seed + 3.0)));
        float dx = abs(p.x - at);
        float y = p.y / h;
        float in_tree;
        if(pine < 0.5){
            // Spruce: as wide at the foot as ever, its side rising almost
            // upright and leaning in the more the higher it is, to a blunt
            // top (user: bulbous, not a triangle); each of five tiers
            // flaring out at its foot
            float tier = fract(y * 5.0 + SkyHash(vec2(id, seed + 4.0)));
            float hw = h * 0.21 * (1.0 - pow(clamp(y, 0.0, 1.0), 1.8)) *
                    (0.72 + 0.28 * tier);
            in_tree = (1.0 - smoothstep(hw - aa, hw + aa, dx)) *
                    (1.0 - smoothstep(1.0 - aa / h, 1.0, y));
        } else {
            // Pine: narrower and lower than a spruce, its crown at about
            // the backing's top so that it is part of the forest rather
            // than a ball over it (user); a trunk under a crown of a few
            // lumps, flat on top
            float hp = h * 0.85;
            float yp = p.y / hp;
            float trunk = 1.0 - smoothstep(hp * 0.012 - aa, hp * 0.012 + aa, dx);
            float crown = 0.0;
            for(int j = 0; j < 3; j++){
                float fj = float(j);
                vec2 lc = vec2((SkyHash(vec2(id, seed + 5.0 + fj)) - 0.5) *
                        0.18, 0.68 + 0.12 * SkyHash(vec2(id, seed + 8.0 + fj)));
                vec2 q = vec2((p.x - at) / hp - lc.x, yp - lc.y) /
                        vec2(0.11, 0.09);
                crown = max(crown, 1.0 - smoothstep(1.0 - aa / hp * 10.0, 1.0,
                        length(q)));
            }
            in_tree = max(trunk * step(yp, 0.7), crown);
        }
        in_tree *= step(0.0, y);
        if(in_tree > best.x)
            best = vec2(in_tree, pine);
    }
    return best;
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

float CloudDensity(vec2 p)
{
    float v = SkyNoise(p) * 0.65;
    v += SkyNoise(p * 2.03) * 0.35;
    return v;
}

// A square of the given half width around a direction, for the sun and the
// moon: how much of the pixel is inside it in x, and where inside it the
// pixel is in yz, as 0...1 across the square, for a body that wears a
// texture. 0 coverage outside it.
vec3 Body(vec3 d, vec3 towards_body, float half_width)
{
    float towards = dot(d, towards_body);
    if(towards <= 0.0)
        return vec3(0.0, 0.0, 0.0);
    vec3 su = normalize(cross(towards_body, vec3(0.0, 1.0, 0.0)));
    vec3 sv = cross(su, towards_body);
    vec3 onPlane = d / towards;
    vec2 at = vec2(dot(onPlane, su), dot(onPlane, sv));
    vec2 uv = abs(at);
    float cover = 1.0 - smoothstep(half_width - BODY_EDGE,
            half_width + BODY_EDGE, max(uv.x, uv.y));
    return vec3(cover, at / (half_width * 2.0) + 0.5);
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

    // The gradient. Luanti's sky is the horizon colour low down and the sky
    // colour overhead; the square root spends more of the dome on the
    // horizon band, which is where the two differ most.
    vec3 color = d.y < 0.0 ?
            mix(cSkyHorizon, cSkyHorizon * 0.55, min(1.0, -d.y / HAZE_DEPTH)) :
            mix(cSkyHorizon, cSkyTop, sqrt(d.y));
    if(cSkyOvercast < 0.5 && d.y >= 0.0){
        // Brightness and hue on their own curves: the render's horizon
        // band brightens over the lowest 20 degrees but stays blue until
        // the last few -- the top's share of the hue is 0.05 at the
        // horizon, 0.7 at 3 degrees, 0.9 at 9 (B/R 1.0, 1.2, 2.3 against
        // a top of 3.4); one weight for both went white too early.
        const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
        float lum_h = max(dot(cSkyHorizon, LUM), 1e-6);
        float lum_t = max(dot(cSkyTop, LUM), 1e-6);
        float lum = mix(lum_h, lum_t, smoothstep(0.0, 0.38, d.y));
        vec3 hue = mix(cSkyHorizon / lum_h, cSkyTop / lum_t,
                1.0 - exp(-d.y / 0.09));
        color = hue * lum;
    }

    // The band the sun paints around itself along the horizon, which is what
    // makes dawn and dusk read as dawn and dusk. Strongest when the sun is
    // itself near the horizon, and only in the half of the sky it is in.
    float low = clamp(1.0 - abs(sun.y) * 2.5, 0.0, 1.0);
    if(low > 0.0){
        vec2 flat_d = vec2(d.x, d.z);
        vec2 flat_sun = vec2(sun.x, sun.z);
        float len = length(flat_d) * length(flat_sun);
        float towards = len > 0.0001 ? dot(flat_d, flat_sun) / len : 0.0;
        float band = pow(max(towards, 0.0), 3.0) *
                pow(1.0 - min(abs(d.y), 1.0), 2.5) * low;
        // [DUSK_SKY], vanilla's (a sky that sets no DuskBand,
        // floorplanner's, keeps the old band): once the sun is down the
        // band is a radiance and not a colour. Mixed towards the sun's
        // tint at a fixed value it was a white patch on a black sky; an
        // orange at a few times the sky's own level dims as the sky
        // does. The share of orange is vanilla's (sky_dome.dusk_tint():
        // none at 18:40, all of it from 19:30), so with the sun high -- the
        // probed 05:45 among those hours -- it is the band it was.
        float dusk = cDuskBand.x > 0.0 ? cDuskBand.z : 0.0;
        const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
        vec3 orange = vec3(1.0, 0.55, 0.25) / 0.6246 *
                dot(color, LUM) * cDuskBand.x;
        color = mix(color, mix(cSunTint, orange, dusk), band * 0.8);
        // And the glow on the whole dome there, the most towards the sun
        // and a share of it opposite: the sky turns orange, not only the
        // patch the sun went down behind. cDawnGlow is zero with the sun up.
        float away = cDuskBand.x > 0.0 ? cDuskBand.y : 0.0;
        color += cDawnGlow * (away + (1.0 - away) *
                pow(max(towards, 0.0), 2.0)) *
                pow(1.0 - min(abs(d.y), 1.0), cDuskBand.x > 0.0 ? 2.0 : 4.0);
    }

    // The stars, behind everything else up there and only when the sky is
    // dark enough for them
    if(cStarFade > 0.0 && cStarDensity > 0.0 && d.y > -0.05){
        // Turned with the day, about the axis the sun goes round and by the
        // same angle: the game's turn ([STARS_AXIS]), else Luanti's untilted
        // one -- its star mesh turned by 2 pi (wicked time - 1/4) about Z,
        // the sun's own direction the cosine and sine of that, so it is the
        // rotation. Stars rise and set with it.
        vec3 turned = cSkyTurnOn > 0.5 ?
            vec3(dot(cSkyTurnX, d), dot(cSkyTurnY, d), dot(cSkyTurnZ, d)) :
            vec3(d.x * sun.x + d.y * sun.y, d.y * sun.x - d.x * sun.y, d.z);
        vec2 within;
        vec3 cell = StarCell(turned, within);
        vec2 key = cell.xy + cell.z * 71.0;
        float pick = SkyHash(key);
        // Only the middle of the cell is the star; the same count and
        // places at half the size
        vec2 off = abs(within - 0.5);
        if(pick < cStarDensity && max(off.x, off.y) < STAR_SIZE * 0.5){
            float twinkle = 0.55 + 0.45 * SkyHash(key + 7.0);
            color += cStarColor * twinkle * cStarFade * STAR_BRIGHTNESS *
                    smoothstep(-0.05, 0.15, d.y);
        }
    }

    // The clouds, on a plane overhead: dividing by d.y is what makes them lie
    // flat and crowd together towards the horizon instead of wrapping the dome
    if(d.y > 0.0 && cCloudCoverage > 0.0){
        vec2 p = d.xz / max(d.y, CLOUD_HORIZON) * CLOUD_SCALE +
                cElapsedTimePS * cCloudWind;
        float density = CloudDensity(floor(p * CLOUD_PIXELS) / CLOUD_PIXELS);
        float threshold = 1.0 - cCloudCoverage;
        // How much of a cloud this cell is: solid well past the threshold,
        // sky well short of it, and thinning across CLOUD_EDGE in between, so
        // that the edge of a cloud blends into the sky rather than being a
        // darker cloud. What the whole layer is worth on top of that is the
        // alpha the game gave its cloud colour, which is what Luanti draws
        // its own clouds with.
        float into = clamp((density - threshold) / CLOUD_EDGE, 0.0, 1.0);
        float cover = into * cCloudAlpha *
                smoothstep(CLOUD_HORIZON, CLOUD_FADE, d.y);
        vec3 cloud = cCloudSky + cCloudSun * (1.0 - 0.5 * into);
        color = mix(color, cloud, cover);
    }

    // The sun and the moon, over the clouds: they are the two things up there
    // that are not behind them. The sun goes the colour of the tint as it
    // comes down to the horizon, which is where that colour belongs; higher
    // up it is its own.
    //
    // Both are cut off at the horizon, as the ground covers them (user,
    // 2026-10-06): with no ground drawn there -- the world still loading,
    // a sky island -- the sun showed through at night. Their pictures'
    // glow goes with them.
    float above = clamp(d.y / max(fwidth(d.y), 1e-5) + 0.5, 0.0, 1.0);
    if(cSunSize > 0.0 && dot(cSunRadiance, vec3(1.0)) > 0.0){
        // A disc, not the square, at the radiance the client says
        vec3 body = Body(d, sun, cSunSize);
        vec2 at = (body.yz - 0.5) * cSunSize * 2.0;
        float cover = body.x * above * (1.0 - smoothstep(
                cSunSize - BODY_EDGE, cSunSize + BODY_EDGE, length(at)));
        color = mix(color, cSunRadiance, cover);
    } else if(cSunSize > 0.0){
        vec3 body = Body(d, sun, cSunSize);
        vec3 sun_color = mix(SUN_COLOR, cSunTint * 1.6, low);
        float cover = body.x * above;
        if(cSunTextured > 0.5){
            // The texture's own colours, and its alpha as the coverage: a
            // sun drawn as a disc in a square image is a disc here too
            vec4 tex = texture2D(sDiffMap, vec2(body.y, 1.0 - body.z));
            sun_color = tex.rgb;
            cover *= tex.a;
        }
        sun_color *= mix(cSunOverexposure, 1.0, low);
        color = mix(color, sun_color, cover);
    }
    if(cMoonSize > 0.0){
        vec3 body = Body(d, -sun, cMoonSize);
        vec3 moon_color = MOON_COLOR;
        float cover = body.x * above;
        if(cMoonTextured > 0.5){
            vec4 tex = texture2D(sNormalMap, vec2(body.y, 1.0 - body.z));
            moon_color = tex.rgb;
            cover *= tex.a;
        }
        // pbr adds it to the sky (user, 2026-10-06): the moon is lit, not
        // a hole, so its dark seas show the sky in front of it rather than
        // black, and it fades into a bright sky without a seam. A "brighter
        // than the sky" comparison switched colour abruptly where the two
        // crossed. The parity modes cover the sky with it, as Luanti does.
        color += moon_color * cover;
    }

    // **The treeline** (user, 2026-10-01): a forest TREE_DISTANCE away,
    // trees cTreeline of that tall; a row of full-sized spruces and pines
    // over a band of undergrowth, and a sparser row of smaller ones in
    // front of it, darker and less in the haze. Lit by the sun's
    // irradiance and the sky's dome, and dull and dark beside the lawn.
    if(cTreeline > 0.0){
        const float TREE_DISTANCE = 200.0;
        float horiz = max(length(d.xz), 1e-4);
        // In tree heights: along the horizon, and up from the ground where
        // it ends
        vec2 p = vec2((atan(d.z, d.x) + 3.14159265) / cTreeline,
                (d.y / horiz * TREE_DISTANCE + (cCameraPosPS.y - cTreeGround)) /
                (cTreeline * TREE_DISTANCE));
        float aa = max(length(fwidth(p)), 1e-4);
        if(p.y < 1.4 && p.y > -0.5){
            float around = 6.28319 / cTreeline;
            // Full, with hardly a gap (user): the forest's body, a strip
            // solid to a noisy top well up the trees, which spares most of
            // the single trees (user), and two rows of them over it
            vec2 back = TreeRow(p, 0.2, 0.75, 1.1, 3.0, aa, around, 0.15);
            vec2 mid = TreeRow(p, 0.32, 0.8, 1.2, 7.0, aa, around, 0.3);
            vec2 front = TreeRow(p, 0.45, 0.45, 0.7, 11.0, aa, around, 0.0);
            // Raised to where the crowns are, no sky seen through (user)
            float body_top = 0.72 + 0.15 * SkyNoise(vec2(p.x * 1.3, 1.0)) +
                    0.06 * SkyNoise(vec2(p.x * 7.0, 2.0));
            float body = (1.0 - smoothstep(body_top - aa, body_top + aa, p.y)) *
                    step(0.0, p.y);
            if(mid.x > back.x)
                back = mid;
            back.x = max(back.x, body);
            // Darker and duller than the summer lawn (0x55733a): 0x2d3a28,
            // and the pines a little browner
            vec3 SPRUCE = vec3(0.026, 0.042, 0.021);
            vec3 PINE = vec3(0.033, 0.041, 0.024);
            vec3 sun_e = cSunRadiance * 3.14159 * cSunSize * cSunSize;
            vec2 dh = d.xz / horiz;
            float sl = length(sun.xz);
            float facing = sl > 1e-4 ? -dot(dh, sun.xz / sl) : 0.0;
            vec3 light = sun_e / 3.14159 * max(sun.y, 0.0) *
                    (0.45 + 0.35 * facing) + cSkyTop * 1.2 * 0.6;
            vec3 back_c = mix(mix(SPRUCE, PINE, back.y) * light, cSkyHorizon,
                    0.22);
            vec3 front_c = mix(mix(SPRUCE, PINE, front.y) * 0.85 * light,
                    cSkyHorizon, 0.18);
            color = mix(color, back_c, back.x);
            color = mix(color, front_c, front.x);
        }
    }

    // And whether the camera can see the sky at all. **A scalar, not a
    // direction.** Mixing per direction -- which this did -- draws a halo
    // around every occluder: the visibility cube is camera-local and thirty
    // degrees to a cell while the sky is at infinity, so a cell whose ray
    // hits a tree darkens the real sky just past that tree's silhouette, in
    // a blob the size of a cell. The cube is right for reflections and for
    // the ambient a surface receives, which are properties of a point on a
    // surface; the sky is not a surface.
    //
    // cSkyOutside is one for anything less than fully enclosed, so the sky
    // is drawn as it is unless the camera is in a cave -- which is Luanti's
    // own shape, Sky::update() taking a scalar and a sunlight_seen bool.
    // Mixed once at the end rather than per layer: it takes the sun, the
    // moon and the stars with it, which is what stops a body blazing through
    // a seam in a cave roof.
    if(cSkyAutoDim > 0.0)
        color = mix(cSkyIndoors, color, cSkyOutside);

    gl_FragColor = vec4(color, 1.0);
}
