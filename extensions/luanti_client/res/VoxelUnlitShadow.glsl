// buildat: the darkening a shadow map casts over voxel geometry that is lit by
// what the mesher baked into its vertex colours.
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// **A shadow that multiplies, not a light that adds.** The unlit path draws
// Luanti's own baked light and has no diffuse term to add a directional light
// to -- put one through Urho3D's LitSolid over it and every face the sun
// reaches goes white. What official Luanti does with its dynamic shadows on
// is darken what the sun cannot see and leave the rest of the baked light
// alone, so that is what this pass does: it writes the shadow factor as a
// colour and the technique blends it with multiply.
//
// It runs as the technique's light pass, once per light in the scene. The
// Luanti launcher puts two there, the sun and the moon, and only one of them
// is ever enabled -- whichever is above the horizon -- so nothing is darkened
// twice.
//
// **And a point light adds** ([WIELD_LIGHT_LOOK]: a held torch). One pass
// has one blend, so it is premultiplied alpha, src + dst * (1 - src.a): the
// sun writes no colour and its darkening as the alpha, 1 - k, which leaves
// dst * k as the multiply did; a point light writes its light as the
// colour and 0 as the alpha, which adds it as LitSolid's pass would.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Fog.glsl"

varying vec4 vWorldPos;
varying vec3 vNormal;
// TRANSLUCENT ([PARITY_LEFTOVERS]): the same pass over a blended surface,
// water. The multiply lands on what is already composited -- the water
// and the bed seen through it, which has its own shadow pass -- so the
// darkening is weighted by the texel's alpha: the water's own share is
// shadowed, the bed's is left. simplified: the bed's share under a
// shadowed water is still darkened a little (1 - a of the way), which a
// second render target would avoid.
varying vec2 vTexCoord;
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
#endif

// How dark a shadowed surface is left is the light's shadowIntensity --
// Urho3D's GetShadow() returns cShadowIntensity.y (the light kept) in
// full shadow and 1 in the sun -- which the launcher sets from the game's
// set_lighting() and defaults to 0.67, Luanti's shadow_intensity 0.33 as
// VoxeLibre asks. It was a constant here as well once, and the two
// multiplied: a shadow at 0.89 that read like unlit ([PARITY_LEFTOVERS]).

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));
    vTexCoord = iTexCoord;
    #ifdef PERPIXEL
        #ifdef SHADOW
            vec4 projWorldPos = vec4(worldPos, 1.0);
            for (int i = 0; i < NUMCASCADES; i++)
                vShadowPos[i] = GetShadowPos(i, vNormal, projWorldPos);
        #endif
    #endif
}

void PS()
{
    #if defined(PERPIXEL) && !defined(DIRLIGHT)
        vec4 diffColor = cMatDiffColor * texture2D(sDiffMap, vTexCoord);
        vec3 lightDir;
        float diff = GetDiffuse(normalize(vNormal), vWorldPos.xyz, lightDir);
        vec3 lit = diffColor.rgb * cLightColor.rgb * diff *
                GetFogFactor(vWorldPos.w);
        #ifdef TRANSLUCENT
            lit *= diffColor.a;
        #endif
        gl_FragColor = vec4(lit, 0.0);
        return;
    #endif
    float k = 1.0;
    #if defined(PERPIXEL) && defined(SHADOW)
        k = GetShadow(vShadowPos, vWorldPos.w);
        // A face the light cannot see is in its own shadow whatever the map
        // says, and the map cannot say it: a wall facing away from the sun
        // is lit exactly as its neighbour facing into it. Luanti folds the
        // same term in beside its shadow map. The terminator is softened
        // over a fifth of a unit so that a curved surface -- a mob, a leaf
        // quad -- does not get a hard line across it.
        #ifdef DIRLIGHT
            k = min(k, mix(cShadowIntensity.y, 1.0,
                    smoothstep(0.0, 0.2, dot(normalize(vNormal), cLightDirPS))));
        #endif
    #endif
    #ifdef TRANSLUCENT
        k = mix(1.0, k, texture2D(sDiffMap, vTexCoord).a);
    #endif
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0 - k);
}
