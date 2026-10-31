// Buildat: builtin/kit/client_data/KitEffects.glsl
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 4h: the play view's effects (kit_effects.xml, controls.lua):
// a blur, a glitch (bands shifted and the colours split, moving), a tint
// over it and a vignette. cKitTint: the tint's colour, its amount in a;
// cKitFx: vignette, blur, glitch (0...1), the time in seconds.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vScreenPos;

#ifdef COMPILEPS
uniform vec4 cKitTint;
uniform vec4 cKitFx;
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
}

#ifdef COMPILEPS
float hash(float n)
{
    return fract(sin(n) * 43758.5453);
}
#endif

void PS()
{
    vec2 uv = vScreenPos;
    float t = cKitFx.w;
    // The glitch: a band of rows shifted sideways, now and then
    float g = cKitFx.z;
    float band = floor(uv.y * 24.0 + floor(t * 12.0) * 7.0);
    float shift = (hash(band) - 0.5) * 0.08 * g * step(1.0 - g * 0.6, hash(band + 3.1));
    uv.x += shift;
    vec2 split = vec2(0.006 * g, 0.0);
    // The blur: a 3x3 box, wider as it grows
    vec2 px = cGBufferInvSize * (1.0 + cKitFx.y * 6.0);
    vec3 c = vec3(0.0);
    if (cKitFx.y > 0.001) {
        for (int i = -1; i <= 1; i++)
            for (int j = -1; j <= 1; j++)
                c += texture2D(sDiffMap, uv + vec2(float(i), float(j)) * px).rgb;
        c /= 9.0;
    } else {
        c = texture2D(sDiffMap, uv).rgb;
    }
    if (g > 0.001) {
        c.r = texture2D(sDiffMap, uv + split).r;
        c.b = texture2D(sDiffMap, uv - split).b;
    }
    c = mix(c, cKitTint.rgb, cKitTint.a);
    // The vignette: darker toward the corners
    vec2 d = vScreenPos - 0.5;
    c *= 1.0 - cKitFx.x * smoothstep(0.2, 0.75, length(d));
    gl_FragColor = vec4(c, 1.0);
}
