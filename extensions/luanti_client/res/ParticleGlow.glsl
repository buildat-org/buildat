// buildat: a particle at full glow ([VANILLA_WEATHER]: the lightning) --
// Urho3D's UnlitParticle without the fog, its texture times its colour.
// Luanti draws a particle at LIGHT_MAX glow as a light, and fog at the
// strike's distance in a storm's short fog made the bolt grey. The colour
// is the emitter's, a radiance on the pbr path and so past one there.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"

varying vec2 vTexCoord;
varying vec4 vColor;

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetTexCoord(iTexCoord);
    vColor = iColor;
}

void PS()
{
    gl_FragColor = cMatDiffColor * texture2D(sDiffMap, vTexCoord) * vColor;
}
