// extensions/luanti_client/res/PBRVoxel.glsl is a fork of this file, with an
// art style of its own: its spot and transmission constants are tuned for a
// world made of Luanti's plants and are deliberately not these. Carry a fix to
// the machinery across by hand; leave the numbers that decide how something
// looks alone, in both directions.
//
// Copied from CoreData/Shaders/GLSL/PBRLitSolid.glsl (Urho3D 1.7.1). Two
// changes, both about how voxel skylight reaches the ambient term:
//
//   VS  vVertexLight mixes the zone ambient with the vertex color instead of
//       being the zone ambient alone
//   PS  the vertex color is not multiplied into diffColor
//
// The mesher packs a voxel's lighting into the vertex color as
//   rgb = light bounced off nearby surfaces, already attenuated
//   a   = how much of the sky the surface sees
// so the ambient a surface receives is
//   cAmbientColor.rgb * color.a + color.rgb
// which is a real mix of two colors: sky blue where the sky is visible, and
// the neutral grey of bounced light where it is not. Ambient occlusion and a
// per-face brightness are already folded into both terms by the mesher.
//
// Direct light is deliberately left alone, unless VOXELSUNGATE is defined:
// with it, the directional light is multiplied by the vertex color's alpha, so
// that a world whose light value says "underground" gets no sun. That is for a
// world whose light curve is built for it -- see PBR_LIGHT_MAP in the Luanti
// client's world.lua; without such a curve it would darken shadowed faces
// twice, which is why it is off by default.
//
// On top of that, two things the stock PBR shaders do differently:
//
//   VOXELNORMALMAP  the tangent frame is built from the derivatives of the
//       world position and the texture coordinate rather than from a vertex
//       attribute, because the voxel mesher writes no tangent -- the vertex's
//       tangent slot carries the surface modifiers instead, when there are any
//   VOXELIBL  reflections of the zone cube map, specular only. The diffuse
//       half of image based lighting is left out: the skylight in the vertex
//       color is already the scene's ambient diffuse, and adding an
//       unoccluded sky on top of it would light the inside of a cave. The
//       specular term is scaled by the same skylight for the same reason.
//       cSkyVis dims the cube map by direction: it is how much of the sky the
//       camera can see each way, as 6x6 values per cube face, which the client
//       fills by marching the voxel data. So a tunnel's walls stop reflecting
//       sky while the sky out of its mouth still reflects, and a cave seen
//       from outside reflects no horizon band it cannot see. There is no
//       separate indoor cube map: the same sky, dimmed where it is not
//       visible, is what a surface indoors reflects.
//   VOXELSPOTS  which parts of a surface are turned to catch the light at this
//       moment. Worked out per pixel from world position and time rather than
//       stored, so the specks come and go the way leaves in wind do, and a
//       surface with no animated normal map can still sparkle.
//   VOXELMODIFIERS  the voxel format's surface modifiers, which the mesher
//       wrote into the vertex tangent: an albedo tint, and wetness, grain and
//       gloss changing the albedo, the roughness and how much of the texture's
//       relief is kept. Off by default, because a world that binds no modifier
//       has nothing in the tangent; see PBRVoxelModifiers.xml.
//   VOXELTRANSLUCENCY  light reaching a surface from behind and coming through
//       it at those spots, tinted by the surface's own color. This is why a
//       leaf against the sun reads yellow-green and not as the blue of the sky
//       lighting its front.
//
// sSpecMap carries roughness in r, where Urho's own PBR shaders read it, and
// spec_strength, translucency and the spot fraction in gba. Metalness is not
// per texel here; nothing has been metal yet, so it stays cMetallic.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Constants.glsl"
#include "Fog.glsl"
#include "PBR.glsl"
#include "IBL.glsl"
#line 30010

#if defined(NORMALMAP)
    varying vec4 vTexCoord;
    varying vec4 vTangent;
#else
    varying vec2 vTexCoord;
#endif
varying vec3 vNormal;
varying vec4 vWorldPos;
#ifdef VOXELMODIFIERS
    varying vec4 vSurface;
#endif
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
    #ifdef VOXELSUNGATE
        // How much of the sky this vertex sees, which on the light pass is
        // what says whether the sun can reach it at all; see below
        varying float vSkyVisibility;
    #endif
    #ifdef SPOTLIGHT
        varying vec4 vSpotPos;
    #endif
    #ifdef POINTLIGHT
        varying vec3 vCubeMaskVec;
    #endif
#else
    varying vec3 vVertexLight;
    // How much of the sky this vertex sees, ambient occlusion included; the
    // alpha the mesher packed into the vertex color
    varying float vSkyVisibility;
    varying vec4 vScreenPos;
    #ifdef ENVCUBEMAP
        varying vec3 vReflectionVec;
    #endif
    #if defined(LIGHTMAP) || defined(AO)
        varying vec2 vTexCoord2;
    #endif
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));

    #ifdef VOXELMODIFIERS
        // The voxel format's surface modifiers, which the mesher wrote into
        // the tangent. Not transformed: they are numbers, not a direction.
        vSurface = iTangent;
    #endif


    #if defined(NORMALMAP) || defined(DIRBILLBOARD)
        vec4 tangent = GetWorldTangent(modelMatrix);
        vec3 bitangent = cross(tangent.xyz, vNormal) * tangent.w;
        vTexCoord = vec4(GetTexCoord(iTexCoord), bitangent.xy);
        vTangent = vec4(tangent.xyz, bitangent.z);
    #else
        vTexCoord = GetTexCoord(iTexCoord);
    #endif

    #ifdef PERPIXEL
        // Per-pixel forward lighting
        vec4 projWorldPos = vec4(worldPos, 1.0);

        #ifdef VOXELSUNGATE
            vSkyVisibility = iColor.a;
        #endif

        #ifdef SHADOW
            // Shadow projection: transform from world space to shadow space
            for (int i = 0; i < NUMCASCADES; i++)
                vShadowPos[i] = GetShadowPos(i, vNormal, projWorldPos);
        #endif

        #ifdef SPOTLIGHT
            // Spotlight projection: transform from world space to projector texture coordinates
            vSpotPos = projWorldPos * cLightMatrices[0];
        #endif

        #ifdef POINTLIGHT
            vCubeMaskVec = (worldPos - cLightPos.xyz) * mat3(cLightMatrices[0][0].xyz, cLightMatrices[0][1].xyz, cLightMatrices[0][2].xyz);
        #endif
    #else
        // Ambient & per-vertex lighting
        #if defined(LIGHTMAP) || defined(AO)
            // If using lightmap, disregard zone ambient light
            // If using AO, calculate ambient in the PS
            vVertexLight = vec3(0.0, 0.0, 0.0);
            vTexCoord2 = iTexCoord1;
        #else
            vVertexLight = GetAmbient(GetZonePos(worldPos)) * iColor.a +
                iColor.rgb;
        #endif
        vSkyVisibility = iColor.a;

        #ifdef NUMVERTEXLIGHTS
            for (int i = 0; i < NUMVERTEXLIGHTS; ++i)
                vVertexLight += GetVertexLight(i, worldPos, vNormal) * cVertexLights[i * 3].rgb;
        #endif

        vScreenPos = GetScreenPos(gl_Position);

        #ifdef ENVCUBEMAP
            vReflectionVec = worldPos - cCameraPos;
        #endif
    #endif
}

#ifdef COMPILEPS
    // How much of the surface is letting light through at this point, right
    // now. A leaf lets light past when it happens to have a gap behind it, and
    // in any wind that is a different leaf a moment later, so this is a
    // function of where and when rather than a map: nothing about it is stored
    // per texel.
    //
    // The world is diced into cells a fraction of a voxel across. Each cell
    // gets its own phase and its own rate from a hash of its position, and
    // opens and closes on a sine of those; the threshold decides how much of
    // that cycle counts as open, and so what fraction of cells are open at
    // once. A slow term along the wind direction is added to the phase, which
    // turns what would be an even twinkle into gusts crossing the surface.

    // How much of the sky the camera can see, per direction: a cube of
    // SKYVIS_CELLS squared values per face, 1 for full sky and 0 for none,
    // packed four to a vec4 in face, row, column order. The client writes them as one
    // buffer parameter, which Urho hands to a float array uniform; a cube map
    // texture would have to be built and uploaded per update instead.
    //
    // vec4 rather than a float array so the packing is the same whether or not
    // the driver lays uniforms out as std140, where an array of float or vec3
    // pads every element out to four.
    // Cells per cube face, per axis. Six faces of SKYVIS_CELLS squared values,
    // packed four to a vec4, so the array is 6*C*C/4 long -- keep the two in
    // step, and in step with CELLS in the client's module.lua, which fills
    // them.
    const int SKYVIS_CELLS = 6;
    uniform vec4 cSkyVis[54];

    // Multiplies the reflected sky, for looking at the reflections rather
    // than at the scene. 1 is what a game renders; the benchmarks turn it up
    // so that changes to the sky visibility sampling are visible at all --
    // most of a cave is rock reflecting almost nothing, and a change worth
    // arguing about moves a wall by a fraction of a value out of 255. Zero
    // when nothing sets it, so voxel_shading pushes it every frame.
    uniform float cSpecEmphasis;

    // How much light is on the sky the cube map holds. The cube map is baked
    // at noon, so a reflection at night is a reflection of the day's sky;
    // dimming it is most of the way to the right thing, and a second cube
    // map or one rendered as the day goes is the rest. One is the daylight
    // it was baked in, and voxel_shading pushes it beside the emphasis.
    uniform float cSkyLight;

    // And what colour that sky is now. The cube map holds the noon sky, so
    // a reflection at night is the day's blue however far it is dimmed; this
    // moves the sample towards the colour the game says its sky is at this
    // hour, keeping the brightness the cube gives it so that the shape of
    // the reflection survives. The amount is zero for a material that says
    // nothing, which is the cube map as it was baked.
    uniform vec3 cSkyTint;
    uniform float cSkyTintAmount;

    // **Where the cube map was rendered from, and the box it holds**
    // ([LAUNCH_WORLD], 2026-09-24: "the reflection might have the wrong
    // FOV"). A cube map is a picture of the world from one point, and a
    // surface reflects along a direction -- so every surface that is not
    // *at* that point reflects the room as seen from somewhere else, and
    // a wide flat floor shows it at the wrong size and in the wrong
    // place. That reads exactly like a wrong field of view.
    //
    // The correction is the standard one for a room-shaped space: follow
    // the reflected ray to where it leaves the box the cube map holds,
    // and look up *that* point relative to the probe. A sky needs none of
    // this -- it is at infinity -- so the box is zero unless something
    // sets it, and zero means the lookup is the raw direction, which is
    // what every world that has a sky in its cube map wants.
#ifdef VOXELROOMPROBE
    // **Asked for explicitly, not inferred from the box.** A shader
    // parameter a material never sets does not reliably read as zero --
    // Urho3D writes the ones a material has and leaves the rest as the
    // last draw left them -- so a correction switched on by "the box is
    // not degenerate" turned itself on in games that had never heard of
    // it, and sample_lighting_scene's pond moved by seven times its own noise
    // floor ([LOOK_CHECK], 2026-09-24). One flag, set beside the box.
    uniform float cProbeBox;
    // [LAUNCH_WORLD] stage 3: a floor of light for a sealed room, the
    // luanti_client fork's cCaveAmbient carried across -- the room's
    // vertex colours are nought (no skylight, no flood), so neither the
    // zone's ambient nor the bounce in them reaches a voxel there. Added
    // in the ambient pass times the albedo. Nought unless the room sets
    // it, so its look does not move by default.
    uniform vec3 cCaveAmbient;
    uniform vec3 cProbePos;
    uniform vec3 cProbeBoxMin;
    uniform vec3 cProbeBoxMax;
#endif

    const float TRANSMISSION_CELLS = 16.0;   // Cells per voxel, per axis
    // A material whose own roughness is already below this cannot glint, so
    // water is given a duller base than a still pond would have
    const float SPOT_ROUGHNESS = 0.10;
    // How far a spot turns away from the surface it is on. This is what makes
    // a spot catch the sun: glossiness on its own only shows where the thing
    // being reflected has some contrast to it, and the sky in the cube map is
    // a smooth gradient with no sun drawn in it, so a sharper reflection of it
    // looks no different from a blurred one. A turned normal moves the direct
    // sunlight's own highlight instead, which is the bright thing in the scene.
    const float SPOT_TILT = 0.45;
    // Bigger than the moving ones: a facet is a chip of rock, not a leaf.
    // Taken from the world position for the same reason as those, that a map
    // lives in one voxel face and would repeat every voxel.
    const float STATIC_SPOT_CELLS = 6.0;     // Cells per voxel, per axis
    const float STATIC_SPOT_TILT = 0.35;
    const float TRANSMISSION_RATE = 0.03;    // Cycles per second, mean
    const vec3 TRANSMISSION_WIND = vec3(0.35, 0.0, -0.2);

    // fract(sin(dot(...))) loses its uniformity once the coordinates get
    // large, and a cell index here is the world position times sixteen, so
    // this hashes by mixing fractional parts instead and stays even across the
    // whole volume.
    float TransmissionHash(vec3 cell)
    {
        vec3 p = fract(cell * 0.1031);
        p += dot(p, p.yzx + 33.33);
        return fract((p.x + p.y) * p.z);
    }

    // How much of a spot this point is, right now. Each cell runs its own
    // cycle, at its own rate and from its own starting point, and is a spot for
    // openFraction of it. Working in the cycle's own
    // 0..1 position rather than in the height of a wave keeps that fraction
    // exact: near the top of a sine the wave is almost flat, so a threshold
    // that lets 4 per cent of cells fully open leaves another 10 per cent
    // hovering just under it, and the surface hazes over instead of speckling.
    // Which way a spot has turned, before it is flattened onto the surface.
    // Constant per cell, so a spot holds still while it is open rather than
    // shimmering within itself.
    vec3 GetSpotTilt(vec3 worldPos, float cells)
    {
        vec3 cell = floor(worldPos * cells);
        return vec3(TransmissionHash(cell + 41.0),
            TransmissionHash(cell + 67.0),
            TransmissionHash(cell + 89.0)) * 2.0 - 1.0;
    }

    // A still spot is on or off with no fade: a facet has an edge, and its
    // tilt is constant across the cell, so it reads as one flat surface.
    float GetStaticSpots(vec3 worldPos, float fraction)
    {
        if (fraction <= 0.0)
            return 0.0;
        vec3 cell = floor(worldPos * STATIC_SPOT_CELLS);
        return TransmissionHash(cell + 7.0) < fraction ? 1.0 : 0.0;
    }

    float SkyVisCell(int face, int row, int col)
    {
        // "flat" is a reserved word in GLSL, hence the name
        int cell = (face * SKYVIS_CELLS + row) * SKYVIS_CELLS + col;
        return cSkyVis[cell / 4][cell - (cell / 4) * 4];
    }

    // How much sky is visible along dir. The largest component of the
    // direction picks the cube face and the other two, divided by it, are the
    // position on that face in -1..1; the client builds a cell's direction the
    // same way round, so the two agree without either of them following a cube
    // map face convention. Bilinear between cell centers, clamped at the face
    // edges the way a cube map with clamped wrapping would be: neighbouring
    // faces' edge cells look nearly the same way, so the seam does not show.
    float GetSkyVisibility(vec3 dir)
    {
        vec3 a = abs(dir);
        float m, u, v;
        int face;
        if (a.x >= a.y && a.x >= a.z)
        {
            m = a.x;
            face = dir.x >= 0.0 ? 0 : 1;
            u = dir.y;
            v = dir.z;
        }
        else if (a.y >= a.z)
        {
            m = a.y;
            face = dir.y >= 0.0 ? 2 : 3;
            u = dir.x;
            v = dir.z;
        }
        else
        {
            m = a.z;
            face = dir.z >= 0.0 ? 4 : 5;
            u = dir.x;
            v = dir.y;
        }
        m = max(m, M_EPSILON);
        // Cell centers sit half a cell in from each edge, so the position in
        // cells is the position across the face times the cell count, less a
        // half
        float half_cells = float(SKYVIS_CELLS) * 0.5;
        float last = float(SKYVIS_CELLS - 1);
        float fu = clamp((u / m + 1.0) * half_cells - 0.5, 0.0, last);
        float fv = clamp((v / m + 1.0) * half_cells - 0.5, 0.0, last);
        int c0 = int(fu);
        int c1 = min(c0 + 1, SKYVIS_CELLS - 1);
        int r0 = int(fv);
        int r1 = min(r0 + 1, SKYVIS_CELLS - 1);
        float tu = fu - float(c0);
        return mix(
            mix(SkyVisCell(face, r0, c0), SkyVisCell(face, r0, c1), tu),
            mix(SkyVisCell(face, r1, c0), SkyVisCell(face, r1, c1), tu),
            fv - float(r0));
    }

    float GetSurfaceSpots(vec3 worldPos, float openFraction)
    {
        // No spots at all: none of the surface is one. The translucency term
        // wants the opposite of this -- a material with no spots lets light
        // through all over rather than nowhere -- and says so where it uses
        // it, rather than here, where the value is also the mask that glosses
        // the surface and turns its normal. Returning 1.0 here made every
        // material that named no spots fully spotted: its whole surface took
        // the spot roughness and a per cell random tilt, which is the speckle
        // that showed on plain rock and grass.
        if (openFraction <= 0.0)
            return 0.0;
        vec3 cell = floor(worldPos * TRANSMISSION_CELLS);
        float rate = TRANSMISSION_RATE * (0.6 + TransmissionHash(cell + 19.0));
        // A slow ramp along the wind direction, which turns what would be an
        // even twinkle into gusts crossing the surface
        float gust = dot(worldPos, TRANSMISSION_WIND);
        float u = fract(TransmissionHash(cell) + cElapsedTimePS * rate + gust);
        // Fade in and out rather than blink, using a quarter of the window at
        // each end so that a gap is still fully open in the middle of it
        float edge = openFraction * 0.25;
        return smoothstep(0.0, edge, u) *
            (1.0 - smoothstep(openFraction - edge, openFraction, u));
    }
#endif

void PS()
{
    // Get material diffuse albedo
    #ifdef DIFFMAP
        vec4 diffInput = texture2D(sDiffMap, vTexCoord.xy);
        #ifdef ALPHAMASK
            if (diffInput.a < 0.5)
                discard;
        #endif
        vec4 diffColor = cMatDiffColor * diffInput;
    #else
        vec4 diffColor = cMatDiffColor;
    #endif


    #ifdef VOXELMODIFIERS
        // simplified: the four slots are read as tint, wetness, grain and
        // gloss, which is the first four of the engine's surface roles in
        // its own order. A world that binds exactly those gets this; one
        // that binds a different set -- speckle, emission, or only two of
        // these -- gets the slots shifted and has to write its own shader,
        // which is what a game does anyway once it knows what it wants its
        // materials to look like. The upgrade path is a uniform naming the
        // role in each slot, at the cost of a branch per slot.
        float mTint = vSurface.x;
        float mWetness = vSurface.y;
        float mGrain = vSurface.z;
        float mGloss = vSurface.w;

        // The tint is a colour rather than a scalar, packed 5-6-5; see
        // VoxelFormat::tint in interface/voxel.h. It multiplies the albedo,
        // which is the whole reason it travels here instead of in the vertex
        // colour: the vertex colour is light.
        float tintPacked = floor(mTint + 0.5);
        float tintR = floor(tintPacked / 2048.0);
        float tintG = floor((tintPacked - tintR * 2048.0) / 32.0);
        float tintB = tintPacked - tintR * 2048.0 - tintG * 32.0;
        diffColor.rgb *= vec3(tintR / 31.0, tintG / 63.0, tintB / 31.0);

        // Wet darkens and sharpens: water fills the pores of a surface, so
        // less light scatters back out of it and more reflects off the film
        // on top. Both are what a wet pavement does.
        diffColor.rgb *= 1.0 - 0.45 * mWetness;
    #endif

    // How much of a spot this pixel is. Used twice: to gloss the surface here,
    // and to let light through it in the lighting below.
    float surfaceSpots = 0.0;
    float staticSpots = 0.0;

    #ifdef METALLIC
        vec4 surfaceSrc = texture2D(sSpecMap, vTexCoord.xy);

        float roughness = surfaceSrc.r + cRoughness;
        float metalness = cMetallic;
        float specStrength = surfaceSrc.g;
        #ifdef VOXELSPOTS
            surfaceSpots = GetSurfaceSpots(vWorldPos.xyz, surfaceSrc.a);
            staticSpots = GetStaticSpots(vWorldPos.xyz,
                texture2D(sNormalMap, vTexCoord.xy).a);
            float spotMask = max(surfaceSpots, staticSpots);
            roughness = mix(roughness, SPOT_ROUGHNESS, spotMask);
            // Full strength however matte the rest is, so that rock can be
            // dull everywhere except at its facets
            specStrength = mix(specStrength, 1.0, spotMask);
        #endif
    #else
        float roughness = cRoughness;
        float metalness = cMetallic;
        float specStrength = 1.0;
    #endif

    #ifdef VOXELMODIFIERS
        // Wetness and the binder both smooth a surface; the binder also
        // gives it something to shine with, where a wet surface shines with
        // the water on it
        roughness *= 1.0 - 0.55 * mWetness - 0.45 * mGloss;
        specStrength = mix(specStrength, 1.0,
            max(0.7 * mWetness, 0.8 * mGloss));
    #endif

    roughness *= roughness;

    roughness = clamp(roughness, ROUGHNESS_FLOOR, 1.0);
    metalness = clamp(metalness, METALNESS_FLOOR, 1.0);

    vec3 specColor = mix(0.08 * specStrength * cMatSpecColor.rgb,
        diffColor.rgb, metalness);
    diffColor.rgb = diffColor.rgb - diffColor.rgb * metalness;

    // Get normal
    #if defined(NORMALMAP) || defined(DIRBILLBOARD)
        vec3 tangent = vTangent.xyz;
        vec3 bitangent = vec3(vTexCoord.zw, vTangent.w);
        mat3 tbn = mat3(tangent, bitangent, vNormal);
    #endif

    #ifdef NORMALMAP
        vec3 nn = DecodeNormal(texture2D(sNormalMap, vTexCoord.xy));
        //nn.rg *= 2.0;
        vec3 normal = normalize(tbn * nn);
    #elif defined(VOXELNORMALMAP)
        // Cotangent frame: the tangent is the direction in world space that
        // the texture's u axis runs, recovered from the screen space
        // derivatives. Voxel faces are flat and axis aligned, so this is exact
        // for them and costs no vertex attribute.
        vec3 geomNormal = normalize(vNormal);
        vec3 dpdx = dFdx(vWorldPos.xyz);
        vec3 dpdy = dFdy(vWorldPos.xyz);
        vec2 dtdx = dFdx(vTexCoord.xy);
        vec2 dtdy = dFdy(vTexCoord.xy);
        vec3 dpdyPerp = cross(dpdy, geomNormal);
        vec3 dpdxPerp = cross(geomNormal, dpdx);
        vec3 tangentU = dpdyPerp * dtdx.x + dpdxPerp * dtdy.x;
        vec3 tangentV = dpdyPerp * dtdx.y + dpdxPerp * dtdy.y;
        float invMax = inversesqrt(max(dot(tangentU, tangentU),
            dot(tangentV, tangentV)));
        vec3 nn = DecodeNormal(texture2D(sNormalMap, vTexCoord.xy));
        #ifdef VOXELMODIFIERS
            // Grain is how fine the material is. A coarse surface keeps the
            // relief its texture's normal map has; a fine one -- sand, flour
            // -- has relief far below a texel and reads as flat, so the
            // normal is pulled towards the face's own.
            //
            // Not renormalized: the frame below is not orthonormal, so
            // normalizing here changes the shading of every surface and not
            // only of a grainy one -- which showed up as glints on a world
            // that had bound no grain at all.
            nn.xy *= 1.0 - 0.8 * mGrain;
        #endif
        vec3 normal = normalize(mat3(tangentU * invMax, tangentV * invMax,
            geomNormal) * nn);
    #else
        vec3 normal = normalize(vNormal);
    #endif

    #ifdef VOXELSPOTS
        // A spot is a piece of the surface that has turned: a leaf facing a
        // different way, or a ripple. Same mask as the gloss and the
        // transmission, so all three are the same event.
        //
        // The turn is taken across the surface rather than in any direction.
        // A free direction tips some normals past the horizon, and those
        // reflect the ground half of the cube map: brown specks on water.
        vec3 spotTilt =
            GetSpotTilt(vWorldPos.xyz, TRANSMISSION_CELLS) *
                (SPOT_TILT * surfaceSpots) +
            GetSpotTilt(vWorldPos.xyz, STATIC_SPOT_CELLS) *
                (STATIC_SPOT_TILT * staticSpots);
        spotTilt -= normal * dot(spotTilt, normal);
        normal = normalize(normal + spotTilt);
    #endif

    // Get fog factor
    #ifdef HEIGHTFOG
        float fogFactor = GetHeightFogFactor(vWorldPos.w, vWorldPos.y);
    #else
        float fogFactor = GetFogFactor(vWorldPos.w);
    #endif

    #if defined(PERPIXEL)
        // Per-pixel forward lighting
        vec3 lightColor;
        vec3 lightDir;
        vec3 finalColor;

        float atten = 1.0;

        #if defined(DIRLIGHT)
            atten = GetAtten(normal, vWorldPos.xyz, lightDir);
        #elif defined(SPOTLIGHT)
            atten = GetAttenSpot(normal, vWorldPos.xyz, lightDir);
        #else
            atten = GetAttenPoint(normal, vWorldPos.xyz, lightDir);
        #endif

        float shadow = 1.0;
        #ifdef SHADOW
            shadow = GetShadow(vShadowPos, vWorldPos.w);
        #endif

        #if defined(SPOTLIGHT)
            lightColor = vSpotPos.w > 0.0 ? texture2DProj(sLightSpotMap, vSpotPos).rgb * cLightColor.rgb : vec3(0.0, 0.0, 0.0);
        #elif defined(CUBEMASK)
            lightColor = textureCube(sLightCubeMap, vCubeMaskVec).rgb * cLightColor.rgb;
        #else
            lightColor = cLightColor.rgb;
        #endif

        #if defined(DIRLIGHT) && defined(VOXELSUNGATE)
            // The sun does not reach underground, and nothing else in the
            // scene knows that: a shadow map cannot tell a cave from a leaf
            // canopy, because in both cases the sky is blocked by geometry
            // that is being drawn. So the world's own light value is the
            // gate, and it is built for exactly this -- see PBR_LIGHT_MAP in
            // world.lua, which holds at full through a canopy and falls to
            // nothing in rock. Under a tree the sun is at full here and the
            // shadow map does the darkening; in a cave there is no sun to
            // shadow.
            lightColor *= vSkyVisibility;
        #endif

        vec3 toCamera = normalize(cCameraPosPS - vWorldPos.xyz);
        vec3 lightVec = normalize(lightDir);
        float ndl = clamp((dot(normal, lightVec)), M_EPSILON, 1.0);

        vec3 BRDF = GetBRDF(vWorldPos.xyz, lightDir, lightVec, toCamera, normal, roughness, diffColor.rgb, specColor);

        finalColor.rgb = BRDF * lightColor * (atten * shadow) / M_PI;

        #if defined(VOXELTRANSLUCENCY) && defined(METALLIC)
            // Light through the surface from the far side. It needs the light
            // on the back (atten is zero there, which is why this cannot ride
            // on it) and the camera roughly opposite the light, which is the
            // one geometry where a thin surface glows.
            //
            // simplified: not multiplied by shadow. A surface lit from behind
            // is its own shadow caster, so the shadow map says it is shadowed
            // and the term would never appear. That also means a leaf in
            // somebody else's shadow glows; with voxel geometry, where only
            // the outside of a canopy is meshed at all, that is rare enough to
            // leave. Sampling the shadow map along the transmission direction
            // would be the fix.
            //
            // The light keeps only part of the surface's color on the way
            // through. A spot where light comes through a canopy is partly a
            // gap, which passes the sun unchanged, and partly thin leaf, which
            // tints it; what a surface transmits is not what it reflects. Using
            // the albedo raw applies the leaf's green a second time and the
            // spots come out as saturated as the texture.
            const float TRANSMISSION_TINT = 0.55;
            vec3 transmitted = mix(vec3(1.0), diffColor.rgb,
                TRANSMISSION_TINT);
            float backNdl = max(0.0, -dot(normal, lightVec));
            float forward = pow(max(0.0, dot(-lightVec, toCamera)), 6.0);
            // A material with no spots at all is translucent all over
            #ifdef VOXELSPOTS
                float through = surfaceSrc.a > 0.0 ? surfaceSpots : 1.0;
            #else
                float through = 1.0;
            #endif
            finalColor.rgb += surfaceSrc.b * through * transmitted *
                lightColor * (backNdl * forward) / M_PI;
        #endif

        #ifdef AMBIENT
            finalColor += cAmbientColor.rgb * diffColor.rgb;
            #ifdef VOXELROOMPROBE
                finalColor += cCaveAmbient * diffColor.rgb;
            #endif
            finalColor += cMatEmissiveColor;
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
        #else
            gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), diffColor.a);
        #endif
    #elif defined(DEFERRED)
        // Fill deferred G-buffer
        const vec3 spareData = vec3(0,0,0); // Can be used to pass more data to deferred renderer
        gl_FragData[0] = vec4(specColor, spareData.r);
        gl_FragData[1] = vec4(diffColor.rgb, spareData.g);
        gl_FragData[2] = vec4(normal * roughness, spareData.b);
        gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #else
        // Ambient & per-vertex lighting
        vec3 finalColor = vVertexLight * diffColor.rgb;
        #ifdef AO
            // If using AO, the vertex light ambient is black, calculate occluded ambient here
            finalColor += texture2D(sEmissiveMap, vTexCoord2).rgb * cAmbientColor.rgb * diffColor.rgb;
        #endif

        #ifdef MATERIAL
            // Add light pre-pass accumulation result
            // Lights are accumulated at half intensity. Bring back to full intensity now
            vec4 lightInput = 2.0 * texture2DProj(sLightBuffer, vScreenPos);
            vec3 lightSpecColor = lightInput.a * lightInput.rgb / max(GetIntensity(lightInput.rgb), 0.001);

            finalColor += lightInput.rgb * diffColor.rgb + lightSpecColor * specColor;
        #endif

        vec3 toCamera = normalize(vWorldPos.xyz - cCameraPosPS);
        vec3 reflection = normalize(reflect(toCamera, normal));

        #ifdef VOXELIBL
            // Specular half of image based lighting only; see the note at the
            // top of this file. Rougher surfaces read a blurrier mip, which is
            // what makes water a mirror and rock not.
            vec3 reflectDir = GetSpecularDominantDir(normal, reflection,
                roughness);
            float ndv = clamp(dot(-toCamera, normal), 0.0, 1.0);
            float mip = GetMipFromRoughness(roughness);
            // Parallax correction, where the cube map holds a room
            // rather than a sky: the ray from this surface along the
            // reflection, out to the box, and the lookup is that hit
            // point seen from the probe. A degenerate box (nothing set
            // it) leaves the direction alone.
            vec3 probeDir = reflectDir;
            #ifdef VOXELROOMPROBE
            if(cProbeBox > 0.5 && cProbeBoxMax.x > cProbeBoxMin.x){
                vec3 invR = 1.0 / probeDir;
                vec3 tMax = (cProbeBoxMax - vWorldPos.xyz) * invR;
                vec3 tMin = (cProbeBoxMin - vWorldPos.xyz) * invR;
                vec3 tFar = max(tMax, tMin);
                float t = min(min(tFar.x, tFar.y), tFar.z);
                // Behind the surface or outside the box: keep the plain
                // direction rather than aiming at nothing
                if(t > 0.0){
                    probeDir = normalize(vWorldPos.xyz + probeDir * t -
                        cProbePos);
                }
            }
            #endif
            vec3 lookup = FixCubeLookup(probeDir);
            // simplified: a direction the camera cannot see the sky along
            // reflects nothing rather than the dark rock that is actually
            // there. Bounced light is in the vertex color if a floor for it is
            // ever wanted.
            // **Is this cube map the sky, or this room?** One answer
            // drives both halves ([LAUNCH_WORLD], 2026-09-24): a sky is
            // at infinity, so it wants no parallax and it *does* want
            // gating -- a tunnel's walls stop reflecting sky while the
            // sky out of its mouth still reflects. A cube map that
            // holds the room around it wants the opposite: the
            // parallax above, and no gating at all, because a room is
            // visible from inside it by definition. So the flag that
            // says "a room-shaped box" turns the sky visibility off as
            // well as the correction on.
            #ifdef VOXELROOMPROBE
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb;
                if(cProbeBox <= 0.5){
                    cube *= GetSkyVisibility(reflectDir);
                }
            #else
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb *
                    GetSkyVisibility(reflectDir);
            #endif
            // **A reflection is a colour, never a NaN** ([PBR_HDR]). A
            // float16 zone cube can hand back a value that is not a
            // number, and this term is *added* to the frame: one NaN
            // here makes the pixel NaN, every additive light pass after
            // it adds to NaN, and the surface goes black -- which is
            // what "a float probe unlights the room" was. Comparisons
            // against NaN are false, so this is written as a test that
            // only a real number passes.
            if(!(cube.r >= 0.0 && cube.r < 1.0e6 &&
                    cube.g >= 0.0 && cube.g < 1.0e6 &&
                    cube.b >= 0.0 && cube.b < 1.0e6)){
                cube = vec3(0.0);
            }
            if(cSkyTintAmount > 0.0){
                float sky_luma = dot(cube, vec3(0.299, 0.587, 0.114));
                cube = mix(cube, cSkyTint * sky_luma, cSkyTintAmount);
            }
            // Scaled by how much sky the surface itself sees as well as by
            // how much is visible along the reflection: the cube map answers
            // for the direction, the vertex color for the place.
            // The same answer again: a surface in a sealed room sees all
            // of that room's cube map whatever its own skylight says,
            // and this room's is nought everywhere -- there is no sky in
            // it to be visible.
            #ifdef VOXELROOMPROBE
                float skyGate = cProbeBox > 0.5 ? 1.0 : vSkyVisibility;
            #else
                float skyGate = vSkyVisibility;
            #endif
            finalColor.rgb += cube * EnvBRDFApprox(specColor, roughness, ndv) *
                skyGate * cSpecEmphasis * cSkyLight;
        #endif

        #ifdef ENVCUBEMAP
            finalColor += cMatEnvMapColor * textureCube(sEnvCubeMap, reflect(vReflectionVec, normal)).rgb;
        #endif
        #ifdef LIGHTMAP
            finalColor += texture2D(sEmissiveMap, vTexCoord2).rgb * diffColor.rgb;
        #endif
        #ifdef EMISSIVEMAP
            finalColor += cMatEmissiveColor * texture2D(sEmissiveMap, vTexCoord.xy).rgb;
        #else
            finalColor += cMatEmissiveColor;
        #endif

        gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
    #endif
}
