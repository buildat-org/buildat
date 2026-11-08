// [KIT_VOXEL_FORMAT] Kit's voxels: Urho3D 1.7.1's LitSolid.glsl with two
// things the voxel mesher hands it, each a define of KitVoxel*.xml:
//
//   KITSKY   the World's sky light (kit.sky_light()): the mesher packs a
//       voxel's light into the vertex colour, rgb the light bounced off
//       nearby surfaces and a how much of the sky the surface sees (see
//       builtin/voxel_shading/client_data/PBRVoxel.glsl). The ambient a
//       face gets is cAmbientColor * a + rgb, and the sun reaches it by a
//       too: a room with no way to the sky is dark.
//   KITTINT  Kit's tint (0..15, an entry of a material's tint palette):
//       the colour the mesher wrote, packed 5-6-5, into the tangent's x. It
//       multiplies the albedo. 0 there (a mesh without the slot) is no tint.
//   KITTINTMASK  ([KIT_TINT_MASK]) a solid voxel's: the texture's alpha is
//       how much the tint applies (1 all, 0 none: a grass block's dirt, a
//       brick's mortar keep their colour); the face is opaque either way.
//   KITLOOKTINT  ([KIT_TINT_MASK]) an object's look wearing a voxel
//       material (module.lua's voxel_mesh): the tint is the material's
//       diffuse colour instead of a vertex's, masked as KITTINTMASK says.
//   KITLINEAR  ([KIT_LIGHTING]) physical lighting's: the frame is HDR,
//       lit in linear and encoded once at its end, so the albedo (tinted)
//       is decoded here, as luanti_client's PBRVoxel.glsl does, and with
//       KITSKY the light bounced (the mesher's display level) too.
//       simplified: 2.2, not the sRGB curve. A translucent face's alpha
//       is made linear's too ([KIT_PHYS_WATER_PINK]).
//   KITWATER  ([KIT_PHYS_WATER_LOOK]) a translucent face under KITLINEAR:
//       water's colour is mostly the sky it reflects, not a lit body, so
//       its diffuse is cut to a half and a Schlick Fresnel (F0 0.02)
//       reflection of the sky added (the fog's colour at the horizon, the
//       ambient's at the zenith), and a glint of the sun; the alpha grown
//       by the reflection, so a grazing look shows the bed less.
//       simplified: a flat surface, no waves, no cube map; glass (the same
//       technique) gets water's look. A per-face flag would part them.
//
// The vertex colour is light, not albedo, so it is not multiplied into the
// diffuse colour as LitSolid's VERTEXCOLOR does.
#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#include "Lighting.glsl"
#include "Fog.glsl"

#ifdef NORMALMAP
    varying vec4 vTexCoord;
    varying vec4 vTangent;
#else
    varying vec2 vTexCoord;
#endif
varying vec3 vNormal;
varying vec4 vWorldPos;
#ifdef KITSKY
    varying vec4 vColor;
#endif
#ifdef KITTINT
    varying float vTint;
#endif
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

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vNormal = GetWorldNormal(modelMatrix);
    vWorldPos = vec4(worldPos, GetDepth(gl_Position));

    #ifdef KITSKY
        vColor = iColor;
        #ifdef KITLINEAR
            vColor.rgb = pow(iColor.rgb, vec3(2.2));
        #endif
    #endif
    #ifdef KITTINT
        vTint = iTangent.x;
    #endif

    #ifdef NORMALMAP
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
            #ifdef KITSKY
                vVertexLight = vVertexLight * vColor.a + vColor.rgb;
            #endif
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

#ifdef KITWATER
// What a water face draws, blended by its alpha: lit (its body's light),
// a (its opacity), plus what it reflects (spec: the sun's glint; the sky
// with the ambient). Out: over the bed, F * reflected + (1 - F) * the body
// over (1 - F) * the bed, as the blend's (colour, alpha).
vec4 KitWater(vec3 lit, float a, vec3 normal, vec3 spec)
{
    vec3 toEye = normalize(cCameraPosPS - vWorldPos.xyz);
    float ndv = clamp(abs(dot(normal, toEye)), 0.0, 1.0);
    float f = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
    vec3 refl = spec;
    #ifdef AMBIENT
        vec3 r = reflect(-toEye, normal);
        vec3 sky = mix(cFogColor, cAmbientColor.rgb, clamp(r.y, 0.0, 1.0));
        #ifdef KITSKY
            sky *= vColor.a;
        #endif
        refl += f * sky;
    #endif
    float a2 = a + f * (1.0 - a);
    return vec4((refl + (1.0 - f) * a * lit) / max(a2, 0.001), a2);
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

    #ifdef KITTINT
        float tintPacked = floor(vTint + 0.5);
        if(tintPacked > 0.5){
            float tintR = floor(tintPacked / 2048.0);
            float tintG = floor((tintPacked - tintR * 2048.0) / 32.0);
            float tintB = tintPacked - tintR * 2048.0 - tintG * 32.0;
            vec3 tintColor = vec3(tintR / 31.0, tintG / 63.0, tintB / 31.0);
            #ifdef KITTINTMASK
                diffColor.rgb *= mix(vec3(1.0), tintColor, diffInput.a);
            #else
                diffColor.rgb *= tintColor;
            #endif
        }
        #ifdef KITTINTMASK
            diffColor.a = cMatDiffColor.a;
        #endif
    #endif
    
    #if defined(KITLOOKTINT) && defined(KITTINTMASK)
        diffColor = vec4(diffInput.rgb * mix(vec3(1.0), cMatDiffColor.rgb,
                diffInput.a), cMatDiffColor.a);
    #endif

    #ifdef KITLINEAR
        diffColor.rgb = pow(diffColor.rgb, vec3(2.2));
        // [KIT_PHYS_WATER_PINK] A translucent face (water, glass) lets
        // through what sRGB blending let through: (1 - a) there was a share
        // of the encoded value, (1 - a)^2.2 of the linear one. With a's own
        // share the bright bed under water (sand: ~0.6 linear against
        // water's ~0.05) outshone the water and read pink.
        // simplified: a's curve alone; no absorption by depth
        diffColor.a = 1.0 - pow(1.0 - diffColor.a, 2.2);
    #endif
    #ifdef KITWATER
        diffColor.rgb *= 0.5;
    #endif

    // Get material specular albedo
    #ifdef SPECMAP
        vec3 specColor = cMatSpecColor.rgb * texture2D(sSpecMap, vTexCoord.xy).rgb;
    #else
        vec3 specColor = cMatSpecColor.rgb;
    #endif

    // Get normal
    #ifdef NORMALMAP
        mat3 tbn = mat3(vTangent.xyz, vec3(vTexCoord.zw, vTangent.w), vNormal);
        vec3 normal = normalize(tbn * DecodeNormal(texture2D(sNormalMap, vTexCoord.xy)));
    #else
        vec3 normal = normalize(vNormal);
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

        float diff = GetDiffuse(normal, vWorldPos.xyz, lightDir);
        // The sky gates the sun and the moon; under KITLINEAR a lamp (a
        // point light, environment.lua's) lights a cave too
        #if defined(KITSKY) && (!defined(KITLINEAR) || defined(DIRLIGHT))
            diff *= vColor.a;
        #endif

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

        #ifdef KITWATER
            // The sun's glint: Blinn-Phong of a calm surface, normalized,
            // by the Fresnel at the half vector
            vec3 toEyeW = normalize(cCameraPosPS - vWorldPos.xyz);
            vec3 hw = normalize(lightDir + toEyeW);
            float fh = 0.02 + 0.98 * pow(1.0 - clamp(dot(hw, toEyeW), 0.0, 1.0), 5.0);
            vec3 glint = diff * lightColor * fh * 40.0 *
                    pow(clamp(dot(normal, hw), 0.0, 1.0), 400.0);
        #endif
        #ifdef AMBIENT
            #ifdef KITSKY
                finalColor += (cAmbientColor.rgb * vColor.a + vColor.rgb) *
                    diffColor.rgb;
            #else
                finalColor += cAmbientColor.rgb * diffColor.rgb;
            #endif
            finalColor += cMatEmissiveColor;
            #ifdef KITWATER
                vec4 w = KitWater(finalColor, diffColor.a, normal, glint);
                gl_FragColor = vec4(GetFog(w.rgb, fogFactor), w.a);
            #else
                gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
            #endif
        #else
            #ifdef KITWATER
                vec4 w = KitWater(finalColor, diffColor.a, normal, glint);
                gl_FragColor = vec4(GetLitFog(w.rgb, fogFactor), w.a);
            #else
                gl_FragColor = vec4(GetLitFog(finalColor, fogFactor), diffColor.a);
            #endif
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

        vec3 finalColor = vVertexLight * diffColor.rgb;
        #ifdef AO
            // If using AO, the vertex light ambient is black, calculate occluded ambient here
            finalColor += texture2D(sEmissiveMap, vTexCoord2).rgb * cAmbientColor.rgb * diffColor.rgb;
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

        gl_FragData[0] = vec4(GetFog(finalColor, fogFactor), 1.0);
        gl_FragData[1] = fogFactor * vec4(diffColor.rgb, specIntensity);
        gl_FragData[2] = vec4(normal * 0.5 + 0.5, specPower);
        #ifndef HWDEPTH
            gl_FragData[3] = vec4(EncodeDepth(vWorldPos.w), 0.0);
        #endif
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

        #ifdef KITWATER
            vec4 w = KitWater(finalColor, diffColor.a, normal, vec3(0.0));
            gl_FragColor = vec4(GetFog(w.rgb, fogFactor), w.a);
        #else
            gl_FragColor = vec4(GetFog(finalColor, fogFactor), diffColor.a);
        #endif
    #endif
}
