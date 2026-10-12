// Buildat: extensions/shaders/res/AutoExposureMean.glsl
// Urho3D's CoreData/Shaders/GLSL/AutoExposure.glsl (MIT) with one line
// changed: the key is the scene's geometric mean, not its fourth root.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "PostProcess.glsl"

varying vec2 vTexCoord;
varying vec2 vScreenPos;

#ifdef COMPILEPS
uniform float cAutoExposureAdaptRate;
uniform vec2 cAutoExposureLumRange;
uniform float cAutoExposureMiddleGrey;
uniform vec2 cHDR128InvSize;
uniform vec2 cLum64InvSize;
uniform vec2 cLum16InvSize;
uniform vec2 cLum4InvSize;

// The four corners, one each. Urho3D's copy takes (1, -1) twice and
// (-1, -1) never, and the skew compounds down the chain: at the last
// step the four taps of one texel weigh the frame's top-right quarter
// twice, its bottom-left not at all, and the key leans on the sky. At
// vp1 13:00 that keyed 3.7 where the frame's geometric mean is 2.4, and
// every lit crop read 0.6 of the render's while the radiances matched
// with the key pinned ([PBR_FIT], the level).
float GatherAvgLum(sampler2D texSampler, vec2 texCoord, vec2 texelSize)
{
    float lumAvg = 0.0;
    lumAvg += texture2D(texSampler, texCoord + vec2(-1.0, -1.0) * texelSize).r;
    lumAvg += texture2D(texSampler, texCoord + vec2(-1.0, 1.0) * texelSize).r;
    lumAvg += texture2D(texSampler, texCoord + vec2(1.0, 1.0) * texelSize).r;
    lumAvg += texture2D(texSampler, texCoord + vec2(1.0, -1.0) * texelSize).r;
    return lumAvg / 4.0;
}
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetQuadTexCoord(gl_Position);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
}

void PS()
{
    #ifdef LUMINANCE64
    float logLumSum = 0.0;
    logLumSum += log(dot(texture2D(sDiffMap, vTexCoord + vec2(-1.0, -1.0) * cHDR128InvSize).rgb, LumWeights) + 1e-5);
    logLumSum += log(dot(texture2D(sDiffMap, vTexCoord + vec2(-1.0, 1.0) * cHDR128InvSize).rgb, LumWeights) + 1e-5);
    logLumSum += log(dot(texture2D(sDiffMap, vTexCoord + vec2(1.0, 1.0) * cHDR128InvSize).rgb, LumWeights) + 1e-5);
    logLumSum += log(dot(texture2D(sDiffMap, vTexCoord + vec2(1.0, -1.0) * cHDR128InvSize).rgb, LumWeights) + 1e-5);
    gl_FragColor.r = logLumSum;
    #endif

    #ifdef LUMINANCE16
    gl_FragColor.r = GatherAvgLum(sDiffMap, vTexCoord, cLum64InvSize);
    #endif

    #ifdef LUMINANCE4
    gl_FragColor.r = GatherAvgLum(sDiffMap, vTexCoord, cLum16InvSize);
    #endif

    #ifdef LUMINANCE1
    // Urho3D's copy divides by 16 here, and what it keys on is the fourth
    // root of the scene's geometric mean: the 64x64 pass writes the SUM of
    // four logs, the two after it average, so a texel of lum4 is four
    // times the mean log. That key sits still while the scene scales by
    // ten, and a world drawn at the path-traced reference's radiances
    // ([PBR_FIT]) is white. Four is the number.
    gl_FragColor.r = exp(GatherAvgLum(sDiffMap, vTexCoord, cLum4InvSize) / 4.0);
    #endif

    #ifdef ADAPTLUMINANCE
    float adaptedLum = texture2D(sDiffMap, vTexCoord).r;
    float lum = texture2D(sNormalMap, vTexCoord).r;
    lum = lum == lum ? clamp(lum, cAutoExposureLumRange.x, cAutoExposureLumRange.y) :
            cAutoExposureLumRange.x;
    // **Adapted from the start, not from what the target held**: it is
    // made with each viewport and nothing writes it first, and what is in
    // it is anything -- a frame metered to black, the eye taking seconds
    // to come back from it (user, 2026-10-02: a random dark start). Once
    // running it never leaves the range, so out of it is that.
    if (!(adaptedLum >= cAutoExposureLumRange.x && adaptedLum <= cAutoExposureLumRange.y))
        adaptedLum = lum;
    // The exponent clamped: the minimap's clone adapts at a rate of a
    // million, and exp() of minus sixteen thousand is a driver's to get
    // right or not; exp(-30) is "at once" already. (Put in for
    // [BOX_MINIMAP_GREY] on a reading that turned out to compare two
    // worlds; kept as a guard.)
    gl_FragColor.r = adaptedLum + (lum - adaptedLum) *
            (1.0 - exp(-min(cDeltaTimePS * cAutoExposureAdaptRate, 30.0)));
    #endif

    #ifdef EXPOSE
    vec3 color = texture2D(sDiffMap, vScreenPos).rgb;
    float adaptedLum = texture2D(sNormalMap, vTexCoord).r;
    gl_FragColor = vec4(color * (cAutoExposureMiddleGrey / adaptedLum), 1.0);
    #endif
}
