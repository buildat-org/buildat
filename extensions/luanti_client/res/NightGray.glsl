// buildat: light below an absolute level shown in grayscale, with a smooth
// threshold -- the eye's rods see no colour, and a moonlit field is gray
// ([NIGHT_GRAY]). One quad pass over the pbr path's HDR viewport, before
// the auto-exposure, so its input is the scene's radiance in the
// reference's units (a dark cave at noon would go gray as the meter
// opened otherwise). cNightGray is (L0, L1): full gray at L0 and below,
// the colour whole at L1 and above, a smoothstep between.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vScreenPos;

#ifdef COMPILEPS
uniform vec2 cNightGray;
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
    vec4 c = texture2D(sDiffMap, vScreenPos);
    float L = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
    float keep = smoothstep(cNightGray.x, cNightGray.y, L);
    gl_FragColor = vec4(mix(vec3(L), c.rgb, keep), c.a);
}
