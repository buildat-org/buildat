// [HEIGHTMAP_REST] builtin/heightmap's ground: Urho3D 1.7.1's
// TerrainBlend.glsl with up to 16 materials instead of three -- up to four
// RGBA weight maps and the ground textures in one texture array. The
// lighting is TerrainBlend's, unchanged.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Fog.glsl"

varying vec2 vTexCoord;

#ifndef GL_ES
varying vec2 vDetailTexCoord;
#else
varying mediump vec2 vDetailTexCoord;
#endif

varying vec3 vNormal;
varying vec4 vWorldPos;
#ifdef PERPIXEL
    #ifdef SHADOW
        #ifndef GL_ES
            varying vec4 vShadowPos[NUMCASCADES];
        #else
            varying highp vec4 vShadowPos[NUMCASCADES];
        #endif
    #endif
    #ifdef SPOTLIGHT
        varying vec4 vSpotPos;
    #endif
    #ifdef POINTLIGHT
        varying vec3 vCubeMaskVec;
    #endif
#else
    varying vec3 vVertexLight;
    varying vec4 vScreenPos;
    #ifdef ENVCUBEMAP
        varying vec3 vReflectionVec;
    #endif
    #if defined(LIGHTMAP) || defined(AO)
        varying vec2 vTexCoord2;
    #endif
#endif

// Units 0-3: the weights of materials 0-3, 4-7, 8-11 and 12-15, RGBA; unit
// 4: the ground textures, a layer a material. A plane the map has not got is
// not read (cNumMaterials).
uniform sampler2D sWeightMap0;
uniform sampler2D sWeightMap1;
uniform sampler2D sWeightMap2;
uniform sampler2D sWeightMap3;
uniform mediump sampler2DArray sDetailArray4;
uniform float cNumMaterials;

#ifndef GL_ES
uniform vec2 cDetailTiling;
#else
uniform mediump vec2 cDetailTiling;
#endif

#ifdef COMPILEPS
// One layer by its weight; a layer of none is not sampled. Derivatives
// given, as a sample inside a branch that differs between pixels has none
// of its own.
void AddLayer(float w, float layer, vec2 dx, vec2 dy, inout vec4 sum,
        inout float total)
{
    if (w > 0.0)
    {
        sum += w * textureGrad(sDetailArray4, vec3(vDetailTexCoord, layer),
                dx, dy);
        total += w;
    }
}

void AddPlane(vec4 w, float first, vec2 dx, vec2 dy, inout vec4 sum,
        inout float total)
{
    AddLayer(w.r, first, dx, dy, sum, total);
    AddLayer(w.g, first + 1.0, dx, dy, sum, total);
    AddLayer(w.b, first + 2.0, dx, dy, sum, total);
    AddLayer(w.a, first + 3.0, dx, dy, sum, total);
}
#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));
    vTexCoord = GetTexCoord(iTexCoord);
    vDetailTexCoord = cDetailTiling * vTexCoord;

    #ifdef PERPIXEL
        // Per-pixel forward lighting
        vec4 projWorldPos = vec4(worldPos, 1.0);

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
            vVertexLight = GetAmbient(GetZonePos(worldPos));
        #endif
        
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

void PS()
{
    // Get material diffuse albedo
    // The materials' textures by their weights over the weights' sum; none
    // at all reads as the first
    vec2 dx = dFdx(vDetailTexCoord);
    vec2 dy = dFdy(vDetailTexCoord);
    vec4 sum = vec4(0.0);
    float total = 0.0;
    AddPlane(texture2D(sWeightMap0, vTexCoord), 0.0, dx, dy, sum, total);
    if (cNumMaterials > 4.0)
        AddPlane(texture2D(sWeightMap1, vTexCoord), 4.0, dx, dy, sum, total);
    if (cNumMaterials > 8.0)
        AddPlane(texture2D(sWeightMap2, vTexCoord), 8.0, dx, dy, sum, total);
    if (cNumMaterials > 12.0)
        AddPlane(texture2D(sWeightMap3, vTexCoord), 12.0, dx, dy, sum, total);
    vec4 diffColor = cMatDiffColor * (total > 0.0 ? sum / total :
            textureGrad(sDetailArray4, vec3(vDetailTexCoord, 0.0), dx, dy));

    // Get material specular albedo
    vec3 specColor = cMatSpecColor.rgb;

    // Get normal
    vec3 normal = normalize(vNormal);

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
        
        float diff = GetDiffuse(normal, vWorldPos.xyz, lightDir);

        #ifdef SHADOW
            diff *= GetShadow(vShadowPos, vWorldPos.w);
        #endif
    
        #if defined(SPOTLIGHT)
            lightColor = vSpotPos.w > 0.0 ? texture2DProj(sLightSpotMap, vSpotPos).rgb * cLightColor.rgb : vec3(0.0, 0.0, 0.0);
        #elif defined(CUBEMASK)
            lightColor = textureCube(sLightCubeMap, vCubeMaskVec).rgb * cLightColor.rgb;
        #else
            lightColor = cLightColor.rgb;
        #endif
    
        #ifdef SPECULAR
            float spec = GetSpecular(normal, cCameraPosPS - vWorldPos.xyz, lightDir, cMatSpecColor.a);
            finalColor = diff * lightColor * (diffColor.rgb + spec * specColor * cLightColor.a);
        #else
            finalColor = diff * lightColor * diffColor.rgb;
        #endif

        #ifdef AMBIENT
            finalColor += cAmbientColor.rgb * diffColor.rgb;
            finalColor += cMatEmissiveColor;
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
        #else
            gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), diffColor.a);
        #endif
    #elif defined(PREPASS)
        // Fill light pre-pass G-Buffer
        float specPower = cMatSpecColor.a / 255.0;

        gl_FragData[0] = vec4(normal * 0.5 + 0.5, specPower);
        gl_FragData[1] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #elif defined(DEFERRED)
        // Fill deferred G-buffer
        float specIntensity = specColor.g;
        float specPower = cMatSpecColor.a / 255.0;

        gl_FragData[0] = vec4(GetFog(vVertexLight * diffColor.rgb, fogFactor), 1.0);
        gl_FragData[1] = fogFactor * vec4(diffColor.rgb, specIntensity);
        gl_FragData[2] = vec4(normal * 0.5 + 0.5, specPower);
        gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
    #else
        // Ambient & per-vertex lighting
        vec3 finalColor = vVertexLight * diffColor.rgb;

        #ifdef MATERIAL
            // Add light pre-pass accumulation result
            // Lights are accumulated at half intensity. Bring back to full intensity now
            vec4 lightInput = 2.0 * texture2DProj(sLightBuffer, vScreenPos);
            vec3 lightSpecColor = lightInput.a * lightInput.rgb / max(GetIntensity(lightInput.rgb), 0.001);

            finalColor += lightInput.rgb * diffColor.rgb + lightSpecColor * specColor;
        #endif

        gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
    #endif
}
