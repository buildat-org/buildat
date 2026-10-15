// Buildat: extensions/luanti_client/res/Saturation.glsl
// A game's set_lighting() saturation, Luanti's rule: the colour mixed with
// its luminance, 1 as is, 0 grey, below 0 the hues turned over (VoxeLibre's
// nausea is -1). Both Luanti clients, appended last (Saturation.xml).
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vScreenPos;

#ifdef COMPILEPS
uniform float cSaturation;
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
}

void PS()
{
    vec3 color = texture2D(sDiffMap, vScreenPos).rgb;
    float l = dot(color, vec3(0.2126, 0.7152, 0.0722));
    gl_FragColor = vec4(clamp(mix(vec3(l), color, cSaturation), 0.0, 1.0), 1.0);
}
