// Voxel geometry lit by what the mesher baked into its vertex colors, and
// nothing else. Urho3D's CoreData/Shaders/GLSL/Unlit.glsl with the vertex
// color read the way interface/mesh.h says to read it:
//
//   ambient = cAmbientColor.rgb * vColor.a + vColor.rgb
//
// The alpha is how much of the sky the surface sees and the rgb is the light
// that reaches it regardless of the sky. cAmbientColor is the zone's ambient
// color, so a world moves the sun by setting that one color and no geometry
// is built again.
//
// Unlit because that is the whole point: the light is in the vertex colors,
// where ambient occlusion and a per-face brightness are already folded in.
// A dynamic light in the scene reaches this geometry through the additive
// light pass the technique beside this file adds, which is Urho3D's own
// LitSolid rather than anything here. The fancier alternative is
// builtin/voxel_shading's PBRVoxel,
// which reads the same vertex colors and adds normal maps, reflections and
// direct light on top of them.
//
// A texel below half alpha is discarded rather than blended, which is what
// makes a texture with holes in it -- leaves, a plant, a pane of glass --
// read as holes while staying in the opaque pass.

#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Fog.glsl"

varying vec2 vTexCoord;
varying vec4 vWorldPos;
varying vec4 vColor;

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetTexCoord(iTexCoord);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));
    vColor = iColor;
}

#ifdef COMPILEPS
#include "AreaField.glsl"
#endif

void PS()
{
    vec4 diffColor = cMatDiffColor * texture2D(sDiffMap, vTexCoord);
    #ifndef TRANSLUCENT
        if (diffColor.a < 0.5)
            discard;
    #endif
    // A game's field of decay where this is (AreaField.glsl)
    float decay = GetAreaField(vWorldPos.xyz);
    if (decay > 0.0)
        diffColor.rgb = DecayAlbedo(diffColor.rgb, vWorldPos.xyz, decay,
                vec3(0.85, 0.82, 0.70));

    vec3 ambient = cAmbientColor.rgb * vColor.a + vColor.rgb;
    float fogFactor = GetFogFactor(vWorldPos.w);
    #ifdef TRANSLUCENT
        // The alpha is kept and blended instead of being a cutoff, and the
        // fog is applied to the color the same way. The blend is against
        // whatever is already in the buffer, so the pass writes no depth and
        // Urho3D sorts the drawables back to front for it.
        gl_FragColor = vec4(GetFog(diffColor.rgb * ambient, fogFactor),
                diffColor.a);
    #else
        gl_FragColor = vec4(GetFog(diffColor.rgb * ambient, fogFactor), 1.0);
    #endif
}
