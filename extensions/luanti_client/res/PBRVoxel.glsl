// A fork of builtin/voxel_shading's PBRVoxel.glsl, and no longer a copy of it.
//
// It started as one because a Luanti client cannot use the built-in shader:
// builtin/ is not on a client's resource path and there is no buildat server
// to deliver it. What keeps the two apart now is that a good deal of what is
// in here is an art style rather than a mechanism -- how far a spot turns, how
// narrowly a leaf passes light through itself -- and this client's worlds and
// apps/voxel_lighting's are not the same worlds. Tuning one of them through a
// shared file retunes the other, which is how voxel_lighting's rock quietly
// lost its speckle.
//
// So the two are not kept in step. A fix to the machinery is worth carrying
// across by hand; a number that decides how something looks is not. What
// differs today, and why:
//
//   cSkyLight, cSkyTint, cSkyTintAmount
//                       VOXELSKYTINT only, which is builtin/luanti's own
//                       client: the brightness of the sky's contribution and
//                       a hue to move the cube map towards, in place of
//                       cSkyColor. See the uniforms below for why they are
//                       two knobs rather than one.
//   cSkyColor           Only here. The colour the sky is at this moment, which
//                       the client pushes so that reflections follow the sky
//                       it paints without a cube map being rebaked.
//   SPOT_TILT           0.06 here, 0.45 there. A Luanti game's ground is
//                       plants the whole way across and every one of them can
//                       hold a spot, so the sparkle has to gather tightly
//                       around the light or it reads as glitter over a field.
//                       voxel_lighting's few surfaces are sparsely spotted and
//                       a wide turn is what makes them catch anything at all.
//   spotGloss           Ramped on sharply here, linear there. With plants this
//                       dense, the half open cells -- most of them at any
//                       moment -- are a sheen that follows the light.
//
// STATIC_SPOT_TILT is the same number in both and wants to stay that way: a
// facet is a chip of rock either way, and narrowing it does not gather the
// speckle anywhere, it only takes it off the sand.
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

// Light bounced off the surroundings, in the same units as the zone's
// ambient, reaching a surface in proportion to how much sky it does not
// see: the second term of the ambient ([PBR_FIT] term 2), so that a cave
// is lit by the day outside it rather than black, and by nothing at
// night. The client sets it with the hour; unset it reads as zero and the
// shader is what it was. The mesher's own bounce (0.055, the lamps' unit)
// stays in the vertex colour beside it and is small in these units.
// simplified: no hemisphere weighting -- a vertical face in the open gets
// no ground bounce, since its sky visibility is one. The upgrade is a
// ground radiance times (1 - n.y) / 2 on top, once the render says how much.
uniform vec3 cBounceLight;
// What a lamp at full is on the packed path, in the ambient's units: the
// mesher's lamp nibble is display white at full (LAMP_COLOR), which is no
// radiance. Set by voxel_shading.set_lamp_light(); the plain path's vertex
// rgb is already the light and does not read this.
uniform vec3 cLampLight;
// [CAVE_AO]: a light of the place itself, not of the sky -- a constant a
// cave is never darker than, so the corner table and the hemisphere rays
// have something to shape where both nibbles are nought and the picture
// would otherwise be one flat black. It takes the local shade like every
// other ambient term, which is the whole point of it.
//
// **Constant on purpose, and not scaled by cBounceLight**: the bounce
// follows the hour, and a floor that follows the hour is exactly what
// [DARK_INVARIANT] forbids in a place no ray reaches. This one is the
// same at noon and at midnight, so it gives a sealed cave its edges back
// without giving it the sun. Nought unless a client sets it
// (voxel_shading.set_cave_ambient), so no game's look moves by default.
uniform vec3 cCaveAmbient;
// [UNDERGROUND_LIGHT]: how lit the chamber the camera is in is, 0 where
// nothing daylit is in sight of it and 1 in a cave whose far end is in the
// open. The bounce term's own floor -- the light a face gets where the
// flood's nibble says nothing reaches it -- is scaled by this, so a sealed
// place stops following the hour while a cave lit round a corner keeps its
// light. It is per frame and not per face on purpose: bounce light in a
// chamber is one quantity, no face can work out what arrives round a corner,
// and a per-face answer costs a remesh an experiment. The client measures it
// with the same rays it already marches for the reflections
// (voxel_shading.chamber_light()). **1.0 unless a client sets it**, which is
// what the term was before this existed, so no game's look moves.
uniform float cChamberLight;
// [NIGHT_GRAY]'s third ladder: the gray keyed on **the light a face gets**
// rather than on the radiance it gives out. The pass over the frame reads
// light times albedo, so it cannot hold the rule across materials -- snow at
// the cave floor gives out more than stone lit at three times it -- and the
// rule the user stated is about the light: a face lit at the floor is gray
// whatever its albedo, one lit above it is coloured. Full gray at
// cCaveAmbient's own level and colour whole a quarter above it. 0 leaves this
// out and the frame pass does the work instead. The value is the ramp's top
// as a multiple of the floor -- 1.25 is the picked width, and widening it is
// [NIGHT_GRAY]'s fourth ladder, since at 1.25 the transition reads as a band
// in some frames (user, 2026-09-25).
uniform float cGrayByLight;
// The transmitted light's level ([PBR_FIT] 3b); 1.0 is Lambert through
// the leaf's colour squared
uniform float cTranslucencyGain;
// And the ground: what the lower hemisphere of a face outdoors sees, the
// radiance of sunlit and sky-lit ground, which a vertical face gets half
// of and a ceiling all of. In the ambient's units, set by the client from
// the sun and the sky of the hour times the ground's albedo; the warm
// bounce that the path trace's second bounce puts on a terrace's side.
// Scaled by the shaped skylight so a cave's ceiling does not see a sunlit
// field through the rock.
uniform vec3 cGroundLight;
// Whether the vertex alpha is packed: the skylight nibble in its high four
// bits, the shade (occlusion, rays, terrain, face) in its low four -- what
// the mesher writes for a client that hands it a horizon map. Then the sun's
// gate reads the nibble alone and the sky's share the product, and a lit
// wall in a trench keeps its sun. Unset (0), the alpha is nibble times shade
// as it always was. Set per material by voxel_shading.set_packed_sky() --
// a render path parameter did not reach this vertex stage. See [PBR_FIT] 2c.
uniform float cPackedSky;
// The shadow-kind diagnostic: the vertex colour drawn as it is, no albedo,
// no ambient -- the mesher has put one occlusion term in each channel
// (BUILDAT_VOXEL_SHADOW_KINDS). Set per material by
// voxel_shading.set_shadow_kinds(). Unset reads as 0.
uniform float cShadowKinds;

// The mesher's shade -- corners, rays, face -- in the low nibble of this
// client's alpha, in 0...1 as the packed layout's b: what the cave floor
// takes, since where no sky reaches the sky times the shade is nought
// ([CAVE_EXPOSURE_FLOOR])
float ShadeOfAlpha(float a)
{
    float bits = floor(a * 255.0 + 0.5);
    return (bits - floor(bits / 16.0) * 16.0) / 15.0;
}

// (gate, share): the nibble the sun is gated by and the sky share the
// ambient is scaled by, out of the vertex alpha in either layout
vec2 SkyOfAlpha(float a)
{
    if (cPackedSky > 0.5)
    {
        // "packed" is a reserved word in GLSL, hence the name
        float bits = floor(a * 255.0 + 0.5);
        float hi = floor(bits / 16.0);
        float lo = bits - hi * 16.0;
        // The low nibble is a product -- corner table, hemisphere rays,
        // terrain cap, face shade, in sixteen levels -- and nothing shapes
        // it here: a power on it deepened all four at once, the deep ones
        // most, and banded the dark end ([SHADE_NIBBLE]). Occlusion is
        // fitted per factor in the mesher, on the pbr path.
        // The share: the geometric terms (the low nibble -- corners,
        // rays, cap) times the flood's nibble squared. The nibble is the
        // one term that carries depth into a cave or a bore -- a level a
        // node from the opening -- and the geometric terms do not: with
        // the nibble out, a bore's walls read one level the whole way
        // down where the render ramps them 13-18 times to the back
        // ([INTERIOR_FALLOFF]'s six crops, 2026-09-20: cave_falloff
        // render 0.056 against 0.85, bore_falloff 0.075 against 1.25).
        // Cubed, fitted to the ramps: linear read the back of the bore
        // at 62 times the render, squared at 10, the cubed one is the
        // reading in the plan; at the surface the nibble is 15 and the
        // geometric terms stand alone, which is the underground rule
        // without a test for the surface.
        float sky = hi / 15.0;
        return vec2(sky, lo / 15.0 * sky * sky * sky);
    }
    // This client's mesh: the same two nibbles (world.lua
    // set_mesh_alpha_nibbles), read back as the sky times the shade it
    // was before them; the shade over FACE_SHADE's top of 1.15
    float sky = floor(floor(a * 255.0 + 0.5) / 16.0) / 15.0;
    float s = min(sky * ShadeOfAlpha(a) * 1.15, 1.0);
    return vec2(s, s);
}

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
    // The sky's part of the ambient, kept apart from the rest so the pixel
    // shader can scale it by the sky-visibility cube over the normal's
    // hemisphere -- the terrain's own occlusion, which the skylight nibble
    // (column light) does not carry. See [PBR_FIT] 2c, the terrain scale.
    varying vec3 vSkyAmbient;
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

// **What the skylight nibble is allowed to say**, for the client that turns
// this on. On the PBR path the sun is a real light with a shadow map, and
// the shadow map is what darkens what is under a tree -- so node lighting is
// left to answer the one question a shadow map cannot, "am I underground",
// and nothing else. The curve holds at full until the light has fallen far
// enough that it can only be rock overhead, and then drops away: a canopy
// reads 11..14 of 15 and stays fully lit, a cave reads 0..2 and goes dark,
// and a doorway is the band between.
//
// extensions/luanti_client shapes the same nibble in its own block copy,
// with the same knee -- see PBR_LIGHT_MAP in its world.lua, whose comment
// says what the knee is for: *raise it and overhangs start being darkened
// twice, once here and once by the shadow map.* That double is exactly what
// this is here to stop; see [AMBIENT_LEVEL] in doc/plan/rendering_plan.md.
//
// Behind VOXELSKYCURVE because the extension has already applied it before
// the mesher sees the value and must not apply it again.
#ifdef VOXELSKYCURVE
    // The knee sits low now: the mesher folds the face's hemisphere
    // visibility into the alpha beside the nibble ([PBR_FIT] 2c), so a lit
    // wall in a trench reads a third and must keep its sun; rock still
    // reads nothing and a cave wall under a nibble of two reads under a
    // tenth. What is lost is the dapple under a canopy, whose floor now
    // reads under the knee and is dark twice, once here and once by the
    // shadow map, which was shadowing it anyway.
    // Back at the nibble's own knee: with the alpha packed the gate reads
    // the nibble alone, and the shade cannot pull a lit wall under it.
    const float SKY_KNEE_LOW = 2.0 / 15.0;
    const float SKY_KNEE_HIGH = 11.0 / 15.0;

    float ShapeSkylight(float sky)
    {
        float t = clamp((sky - SKY_KNEE_LOW) /
            (SKY_KNEE_HIGH - SKY_KNEE_LOW), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
#else
    float ShapeSkylight(float sky)
    {
        return sky;
    }
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
            vSkyVisibility = ShapeSkylight(SkyOfAlpha(iColor.a).x);
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
            vSkyAmbient = vec3(0.0, 0.0, 0.0);
            vTexCoord2 = iTexCoord1;
        #else
            // The sky's share is the nibble as it is, not the shaped one:
            // the knee is for the sun, whose shadow map already darkens a
            // canopy's floor; the sky is not in the shadow map, and a face
            // under leaves does see less of it -- 11..14 of 15 is what
            // Luanti says it sees. The render's canopy-shaded snow reads
            // 0.6 of open shade ([PBR_FIT] term 2). The bounce keeps the
            // shaped value: a canopy is not a cave.
            // The sky's share by how much of the hemisphere is sky: all
            // of it for a floor, half for a wall, none for a ceiling --
            // the other half is the ground's, below. The nibble alone gave
            // a wall the whole dome, and a dirt side in a block's shadow
            // read 2.7 times the render's ([PBR_FIT], contrast_dirt).
            // 0.8 for a wall, over the hemisphere's half: the 0.35 that
            // stood here was fitted to the pit beside vp1's stone block, a
            // shadow hemmed in on three sides, and left every open shadow
            // 2.3 times too dark (contrast_dirt on the cliff top: render
            // 2.76, pbr 6.26). The open shadow is the ambient's target and
            // the pit is occlusion's ([PBR_FIT], user 2026-09-18).
            vec2 sky = SkyOfAlpha(iColor.a);
            vSkyAmbient = GetAmbient(GetZonePos(worldPos)) * sky.y *
                    (1.0 - 0.15 * max(vNormal.y, 0.0));
            // The bounce falls off into a cave with the daylight Luanti
            // propagates, a level a node from the mouth, over a floor of
            // half: the render's cave is lit near the mouth and dark deep
            // in, and (1 - shaped) alone lit the whole interior one
            // uniform grey ([PBR_FIT], contrast_cave). The floor is what
            // the daylight cannot carry -- fifteen nodes and it is gone,
            // the render's second bounce is not -- and is [PBRI]'s to
            // replace. Zero in the open, where the ground term is the
            // bounce.
            // The mesher's shade -- corner table, hemisphere rays, terrain
            // -- on the bounce and the ground as well as on the sky: with
            // it on the ambient alone, the pit beside vp1's stone block
            // read 2.2 times the render's off the ground term, and the
            // shadow-kind run showed the corners computed and lost here
            // ([PBR_FIT] 2c). With the alpha packed the shade is the low
            // nibble, which is sky.y over sky.x; unpacked the two are one.
            // Packed, the rgb is the lamp in r, the terrain cap in g and
            // the local shade in b (the mesher's face_vertex_colors()):
            // the bounce and the ground take the local shade alone, since
            // the mountain behind the ridge does not block the lit ground
            // in front of a face, and a cave wall under a terrain cap of
            // zero still bounces. Unpacked the rgb is the light itself and
            // the shade is one.
            bool isPacked = cPackedSky > 0.5;
            // The lamp's falloff computed from the nibble, not stepped
            // with it: Luanti's lamp light drops one level a node, and
            // fourteen levels at full lit vp7's deep wall ten times the
            // render's from a glowstone five nodes off ([LAMP_REF]). The
            // vertex r is the level alone, smoothed over the corner's open
            // voxels, with no shade on it: the mesher's rays put out a
            // torch in any room narrower than their reach and lit only
            // the spots that saw out ([TORCH_LIGHT], user 2026-10-11). The
            // distance is counted from a torch's level, not from fifteen:
            // a torch's own faces (11) full, nothing at a level of nought.
            // One over the distance less its value at twelve, not the
            // inverse square: the nibble is the flood's path, which goes
            // round what a ray would not, and the square left a torch dark
            // at half its reach; less the tail, as a step at nought left a
            // lamp's floor on every face in the world (the 02:00 snow
            // field lit like an afternoon, [PBR_FIT] 2026-09-20).
            // simplified: the nibble does not say the source's level, so
            // a glowstone (14) reads full for three nodes; a source's level
            // in the vertex is the upgrade.
            float lampLevel = isPacked ? 15.0 * iColor.r : 0.0;
            float lampDist = clamp(12.0 - lampLevel, 1.0, 12.0);
            vec3 baked = isPacked ?
                cLampLight * max(1.0 / lampDist - 1.0 / 12.0, 0.0) *
                    (12.0 / 11.0) : iColor.rgb;
            float shade = isPacked ? iColor.b : 1.0;
            // The ground a wall faces is lit or it is not, and the base
            // pass has no shadow map to say which; what it has is how
            // enclosed the place is -- the local shade and the terrain cap
            // -- and an enclosed place's ground is in the same shadow. So
            // the ground term takes their product squared: vp1's pit face
            // (0.55 local, 0.63 terrain) keeps 0.12 of it and the open
            // shaded wall on the cliff top (0.65, 0.90) 0.34, which is the
            // render's 0.27 between them ([PBR_FIT], contrast_dirt_pit).
            // The mesher's underground rule rides in g: nought under the
            // column's own surface, the terrain cap above it
            float under_g = isPacked ? iColor.g : 1.0;
            float groundSeen = isPacked ? shade * iColor.g : 1.0;
            // Cubed, with the ground's albedo doubled beside it ([PBR_FIT]
            // 3.3, 2026-09-19): the open shaded wall wanted more of the
            // lit ground and the pit less, and the enclosure's power is
            // what tells them apart (contrast_dirt 5.0 to 4.1 of the
            // render's 2.8, contrast_dirt_pit 6.4 to 6.7 of 12)
            groundSeen *= groundSeen * groundSeen;
            // And the interior's share of the lit ground: a wall just
            // inside a mouth is warm in the render (cave_lit_wall
            // 0.160/0.091/0.065, the sunlit floor's bounce through the
            // opening) where the sky share alone is grey-blue at a fifth
            // of it ([INTERIOR_FALLOFF], 2026-09-20). What says "inside,
            // near the mouth" is the mesher's underground rule (g = 0
            // under the column's own surface) and the flood's nibble
            // still high: the nibble to the sixth (cubed, the cave's
            // back wall and corner read twice the render and its ramp
            // flatter than without the term; to the sixth the back is
            // the render's and the lit wall keeps most of its warmth).
            // Nought in the open, where the cap is g and groundSeen is
            // the term, and nought at a nibble of 15 either: the
            // mesher's rule takes a pit's floor row for underground (the
            // map's 3x3 erosion), and a face the sky reaches whole is
            // the open's.
            float n3 = sky.x * sky.x * sky.x;
            float interior = isPacked ?
                shade * (1.0 - iColor.g) * n3 * n3 * (1.0 - step(0.97, sky.x)) : 0.0;
            // The diagnostics ride on this varying rather than one of
            // their own: 1 is the mesher's terms, 3 is what the nibbles
            // say (the flood's share, the sky share it becomes, the
            // shade), and 2 wants the light itself, which is the sum
            // below ([UNDERGROUND_LIGHT]).
            // **5 and 6 are that sum's two halves** ([SKY_COLUMN_CAVE],
            // 2026-09-28): 2 draws `vVertexLight + vSkyAmbient * skyVis`
            // and a night frame that stays lit with every uniform
            // ablated cannot be read through it -- which half carries
            // the light is the whole question. 5 is the sky ambient on
            // its own, 6 is `baked` on its own.
            vVertexLight = cShadowKinds > 5.5 ? baked :
                cShadowKinds > 4.5 ? vec3(0.0) :
                cShadowKinds > 3.5 ?
                    vec3(under_g, groundSeen, interior) :
                cShadowKinds > 2.5 ? vec3(sky.x, sky.y, shade) :
                cShadowKinds > 0.5 && cShadowKinds < 1.5 ? iColor.rgb : baked +
                cBounceLight * (0.15 * cChamberLight + 1.0 * sky.x) *
                    (1.0 - ShapeSkylight(sky.x)) * shade +
                cGroundLight * (0.5 - 0.5 * vNormal.y) *
                    (ShapeSkylight(sky.x) * groundSeen + interior) +
                cCaveAmbient * (isPacked ? shade : ShadeOfAlpha(iColor.a));
        #endif
        vSkyVisibility = ShapeSkylight(SkyOfAlpha(iColor.a).x);

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

    // The sky visibility cube and its lookup, beside this file. At column
    // zero because Urho3D's Shader::ProcessSource() only consumes an
    // #include that starts its line; indented, it reaches the GLSL
    // compiler as "include not found".
#include "SkyVis.glsl"

    // Multiplies the reflected sky, for looking at the reflections rather
    // than at the scene. 1 is what a game renders; the benchmarks turn it up
    // so that changes to the sky visibility sampling are visible at all --
    // most of a cave is rock reflecting almost nothing, and a change worth
    // arguing about moves a wall by a fraction of a value out of 255. Zero
    // when nothing sets it, so voxel_shading pushes it every frame.
    uniform float cSpecEmphasis;

    // What the sky is worth now, as a colour: the cube map beside this file is
    // one static noon gradient, and this is what makes it a sunset, a
    // thunderstorm or the green of being under water. The client sets it from
    // the same colours it paints the sky with, so the reflections follow the
    // sky without a cube map being rebaked. Zero when nothing sets it, which
    // is why the client pushes it with the sky.
    uniform vec3 cSkyColor;

    #ifdef VOXELSKYTINT
        // What builtin/luanti's own client drives instead of cSkyColor: the
        // brightness of the sky's contribution, and a hue to move the cube
        // map towards without changing how bright it answers. Behind a
        // define because **a shader parameter a material never sets reads as
        // zero**: the techniques in this directory that do not declare it
        // never see these, so their materials never have to set them.
        //
        // The two are not the same knob. cSkyColor multiplies, so a dim sky
        // dims the reflection and a coloured one colours it together;
        // cSkyTint keeps the luminance the cube gives and moves only the
        // hue, with cSkyLight scaling separately. A client that wants a
        // night that is dark and blue rather than dark and grey wants the
        // second.
        uniform float cSkyLight;
        uniform vec3 cSkyTint;
        uniform float cSkyTintAmount;
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
    //
    // It is also what decides how far from the light the sparkle reaches. A
    // spot turned this far catches the sun from anywhere within that angle of
    // the mirror direction, so a large one puts glints over a whole field
    // rather than in the band where the light is actually being reflected.
    const float SPOT_TILT = 0.06;
    // Bigger than the moving ones: a facet is a chip of rock, not a leaf.
    // Taken from the world position for the same reason as those, that a map
    // lives in one voxel face and would repeat every voxel.
    const float STATIC_SPOT_CELLS = 6.0;     // Cells per voxel, per axis
    // Left where it was when the moving kind was narrowed: a facet is a chip
    // of rock that is flat and stays turned, not a leaf that has caught the
    // light for a moment, and narrowing it takes the speckle off sand and
    // gravel rather than gathering it anywhere.
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
        // The atlas is a game's textures as they come, display-encoded, and
        // this path lights in linear and encodes once at the end: read as
        // linear, an sRGB texel is an albedo a third too bright and half
        // as saturated -- grass read max/min 1.7 against the render's 3.9
        // off the same PNG, which Cycles decodes ([PBR_FIT]). Decoded here.
        // simplified: 2.2, not the sRGB curve; the difference is under the
        // texel's own quantisation.
        diffInput.rgb = pow(diffInput.rgb, vec3(2.2));
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
            // A spot is glossy because it is a leaf or a facet that has
            // turned, and one that has half turned is a smaller turn rather
            // than a wider, duller highlight: the fade belongs in the tilt,
            // which carries it below. Ramping the gloss on sharply instead is
            // what keeps the half open cells -- which at any moment are most
            // of them -- from being a broad sheen that follows the light
            // across a whole field.
            float spotMask = max(surfaceSpots, staticSpots);
            float spotGloss = spotMask * spotMask * spotMask;
            roughness = mix(roughness, SPOT_ROUGHNESS, spotGloss);
            // Full strength however matte the rest is, so that rock can be
            // dull everywhere except at its facets
            specStrength = mix(specStrength, 1.0, spotGloss);
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

    // The spec map's strength alone, 0.08 at full as Principled's specular
    // level has it: not times cMatSpecColor, which no voxel material sets
    // and which Urho3D defaults to black -- so every dielectric had a
    // Fresnel of zero and the sun no highlight at all ([PBR_FIT],
    // sun_glint_grass read a tenth of the render's, and bluish: what was
    // left was the sky through EnvBRDFApprox's grazing term).
    vec3 specColor = mix(vec3(0.08 * specStrength), diffColor.rgb, metalness);
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
            // The light's ramp texture, not GetAttenPoint's fixed curve
            // (a quarter at the middle, gone well before the range): the
            // held and placed lights' ramp is the baked lamp term's own
            // falloff ([WIELD_LIGHT_LOOK], res/light_ramp.png)
            atten = GetDiffuse(normal, vWorldPos.xyz, lightDir);
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
            // ... where the shadow map does not reach. Within its range
            // the map knows what the flood's nibble cannot: the sun
            // through a cave's sideways mouth lights the floor at the
            // player's feet where the nibble has decayed to nothing (vp7's
            // sun_step, 0.93 in the render against 0 here, [PBR_FIT]
            // 2026-09-20). Urho's own fade says how far past the range a
            // fragment is; the gate takes over exactly there.
            #ifdef SHADOW
                float beyond = clamp((vWorldPos.w - cShadowDepthFade.z) *
                        cShadowDepthFade.w, 0.0, 1.0);
                lightColor *= mix(1.0, vSkyVisibility, beyond);
            #else
                lightColor *= vSkyVisibility;
            #endif
        #endif

        vec3 toCamera = normalize(cCameraPosPS - vWorldPos.xyz);
        vec3 lightVec = normalize(lightDir);
        float ndl = clamp((dot(normal, lightVec)), M_EPSILON, 1.0);

        // The BRDF, written out rather than Urho3D's GetBRDF(): a face lit
        // by an irradiance E reflects albedo * E * n.l / pi and, on top,
        // the Cook-Torrance lobe D * F * V * E * n.l -- GGX with its pi,
        // Schlick's Fresnel on the half vector, Smith's height-correlated
        // visibility, which carries the 1 / (4 n.l n.v). Urho3D's chain
        // had a diffuse that fell with the view angle and a second pi over
        // everything, a Fresnel scaled by an IOR of its own and a
        // visibility without the 1 / (4 n.l n.v), and it was never compiled
        // for these materials anyway (SPECULAR needs MatSpecColor set).
        // What is here is Principled's lobe, which the reference is lit
        // with ([PBR_FIT], sun_glint_grass). `roughness` is already alpha
        // (r squared, above).
        vec3 halfVec = normalize(toCamera + lightVec);
        float ndh = clamp(dot(normal, halfVec), M_EPSILON, 1.0);
        float vdh = clamp(dot(toCamera, halfVec), M_EPSILON, 1.0);
        float ndv = abs(dot(normal, toCamera)) + 1e-5;
        float alpha = max(roughness, 0.02);
        float a2 = alpha * alpha;
        float dd = ndh * ndh * (a2 - 1.0) + 1.0;
        float D = a2 / (M_PI * dd * dd);
        vec3 F = specColor + (vec3(1.0) - specColor) * pow(1.0 - vdh, 5.0);
        float gv = ndl * sqrt(ndv * ndv * (1.0 - a2) + a2);
        float gl = ndv * sqrt(ndl * ndl * (1.0 - a2) + a2);
        float V = 0.5 / max(gv + gl, 1e-5);
        vec3 BRDF = diffColor.rgb * (1.0 / M_PI) + D * F * V;
        finalColor.rgb = BRDF * lightColor * (atten * shadow);

        #if defined(VOXELTRANSLUCENCY) && defined(METALLIC)
            // Light through the surface from the far side, as a mix that
            // takes from the reflected light what it passes: a surface of
            // translucency t reflects (1 - t) of its diffuse and passes t of
            // the light on its back, Lambert from that side, tinted by the
            // leaf's colour. Refitted ([PBR_FIT], translucency_canopy;
            // [NO_SPOTS_REF]) from a term that was added on top of the
            // lighting, conserved nothing, carried a forward-scatter power
            // and, for a surface with no spots, passed the light all over
            // at full strength -- which is what a reference run's NO_SPOTS
            // switch made of every canopy, so the moon lit the trees at
            // 02:00 a few hundred times over. The focus is gone: a canopy
            // seen against the sun is brighter than seen with it by the
            // back Lambert alone, which is what the render's pair reads.
            //
            // simplified: not multiplied by shadow -- a surface lit from
            // behind is its own shadow caster, so the shadow map would say
            // it is shadowed and the term never appear; a leaf in another's
            // shadow glows. Sampling the map along the transmission
            // direction would be the fix.
            // Tinted by the albedo in full, as the reference's Translucent
            // BSDF is; mixed toward white the back-lit face read six times
            // the render's over the front-lit one, since the leaf's green is
            // a twentieth and white is not.
            // Tinted by the albedo once, as the render's Translucent BSDF
            // is: its back-lit canopy's g/r of 3 is the leaf's own, which a
            // squared tint would make 9 ([PBR_FIT] 3b, 2026-09-19).
            // cTranslucencyGain is what the fit sets the level with.
            float backNdl = max(0.0, -dot(normal, lightVec));
            float t = surfaceSrc.b;
            finalColor.rgb = finalColor.rgb * (1.0 - t) +
                t * cTranslucencyGain * diffColor.rgb * lightColor * backNdl / M_PI;
        #endif

        #ifdef AMBIENT
            finalColor += cAmbientColor.rgb * diffColor.rgb;
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
        // The sky's ambient by how much sky there is over this surface's
        // hemisphere, out of the camera's visibility cube: the normal and
        // four directions leaning off it. Tried as [PBR_FIT] 2c's step 1
        // and left behind a define no technique sets: the cube is the
        // camera's, and a snow field's shadow beside the tree the camera
        // stood under went three times too dark while the terrace under
        // the mountain, far off, did not move. Step 2 is a horizon map.
        #if defined(VOXELIBL) && defined(VOXELSKYCUBEAMBIENT)
            vec3 skyN = normalize(normal);
            vec3 skyT = abs(skyN.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
            vec3 skyU = normalize(cross(skyN, skyT));
            vec3 skyV = cross(skyN, skyU);
            float skyVis = (GetSkyVisibility(skyN) * 2.0 +
                GetSkyVisibility(normalize(skyN + skyU)) +
                GetSkyVisibility(normalize(skyN - skyU)) +
                GetSkyVisibility(normalize(skyN + skyV)) +
                GetSkyVisibility(normalize(skyN - skyV))) / 6.0;
        #else
            float skyVis = 1.0;
        #endif
        if(cShadowKinds > 0.5){
            // 2: the whole light a face gets, the sky share included --
            // the same sum the line below draws with, without the albedo
            gl_FragColor = vec4(
                cShadowKinds > 4.5 && cShadowKinds < 5.5 ?
                    vSkyAmbient * skyVis :
                cShadowKinds > 1.5 && cShadowKinds < 2.5 ?
                    vVertexLight + vSkyAmbient * skyVis : vVertexLight, 1.0);
            return;
        }
        vec3 finalColor = (vVertexLight + vSkyAmbient * skyVis) * diffColor.rgb;
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
            vec3 lookup = FixCubeLookup(reflectDir);
            // simplified: a direction the camera cannot see the sky along
            // reflects nothing rather than the dark rock that is actually
            // there. Bounced light is in the vertex color if a floor for it is
            // ever wanted.
            #ifdef VOXELSKYTINT
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb *
                    GetSkyVisibility(reflectDir);
                if(cSkyTintAmount > 0.0){
                    float sky_luma = dot(cube, vec3(0.299, 0.587, 0.114));
                    cube = mix(cube, cSkyTint * sky_luma, cSkyTintAmount);
                }
            #else
                vec3 cube = textureLod(sZoneCubeMap, lookup, mip).rgb *
                    GetSkyVisibility(reflectDir) * cSkyColor;
            #endif
            // Scaled by how much sky the surface itself sees as well as by
            // how much is visible along the reflection: the cube map answers
            // for the direction, the vertex color for the place. That is
            // the smooth end. A rough lobe integrates the hemisphere, and
            // what the hemisphere's sky comes to at this place is what the
            // diffuse ambient already carries -- the drawn sky's hue at the
            // hour's level, times the sky share and the normal's slice of
            // the dome -- so the rough end reflects that. The cube's lowest
            // mip is not it: it is the drawn sky at full, which at dawn is
            // forty times the ambient, and it gated nothing by place -- the
            // visibility cube is the camera's. It put a blue sheen on a
            // grass top under a mountain five times the render's and was
            // four fifths of that top's light ([PBR_FIT], terrain_occlusion
            // by ablation with the key pinned).
            // Over by 0.35 (a perceptual 0.6): the atlas makes a bright
            // texel of grass smoother than its node by up to 0.8, so a
            // matte node has texels at 0.45 here, and a quarter of the
            // drawn sky's horizon band at dawn is still more than the
            // ambient. Water at 0.12 and the metals keep the cube.
            vec3 env = mix(cube * vSkyVisibility, vSkyAmbient,
                smoothstep(0.05, 0.35, roughness));
            finalColor.rgb += env * EnvBRDFApprox(specColor, roughness, ndv) *
                cSpecEmphasis
            #ifdef VOXELSKYTINT
                * cSkyLight
            #endif
                ;
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

        // [NIGHT_GRAY] by the light rather than the radiance, when asked
        if(cGrayByLight > 0.0)
        {
            const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
            // **The whole light, the sky's share included.** vVertexLight
            // is only part of it -- the lamp, the bounce, the ground and
            // the cave floor -- and the sky is the term that lights an
            // open shadow, so keying on vVertexLight alone drew every
            // daylight shadow and every cave mouth gray whatever the sky
            // was giving it ([UNDERGROUND_LIGHT], the playtest fault).
            // The same sum the colour below is drawn with. A sealed place
            // has no sky share, so nothing there moves.
            float lightL = dot(vVertexLight + vSkyAmbient * skyVis, LUMA);
            float floorL = max(dot(cCaveAmbient, LUMA), 1e-6);
            float keep = smoothstep(floorL, cGrayByLight * floorL, lightL);
            finalColor = mix(vec3(dot(finalColor, LUMA)), finalColor, keep);
        }
        gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
    #endif
}
