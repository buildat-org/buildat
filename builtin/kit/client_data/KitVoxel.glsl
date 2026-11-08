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
//   KITWATER  ([KIT_PHYS_WATER_LOOK]) a translucent face under KITLINEAR,
//       lit as luanti_client's PBRVoxel.glsl lights skeldat's water
//       (surface.lua's: roughness 0.35, spec_strength 0.9, so F0 0.072):
//       the sun's GGX lobe (times pi: the light is given over pi,
//       environment.lua's KIT_PHYS_SUN_PI), the sky's light (the
//       ambient) by EnvBRDFApprox and the specular emphasis of 0.7; the
//       alpha grown by the reflection, so a grazing look shows the bed
//       less. simplified: a flat surface, no spots, no cube map; glass
//       (the same technique) gets water's look. A per-face flag would
//       part them.
//   KITNORMALS  ([KIT_NORMALS]) physical lighting's relief: the atlas's
//       normal map (a material's bumpiness of its texture's brightness as
//       height), in a frame from the screen-space derivatives of the world
//       position and the texture coordinate, as PBRVoxel.glsl's
//       VOXELNORMALMAP: a voxel face is flat, so it is exact and costs no
//       vertex attribute (Kit's tangent carries the tint).
//   KITSPOTS  ([KIT_SPOTS]) physical lighting's glints, PBRVoxel.glsl's
//       VOXELSPOTS: the atlas's surface maps carry a material's share of
//       moving spots (the spec map's alpha: water, leaves) and still ones
//       (the normal map's alpha: sand's stones, ore); a spot's normal
//       turned across the face and made glossy (GGX at 0.10, F0 0.08), so
//       it catches the sun. simplified: the spots' gloss alone -- the rest
//       of a face has no specular (water's KITWATER lobe aside); the leaves'
//       light through a spot (translucency) left out.
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

#if defined(KITWATER) || defined(KITSPOTS)
// PBRVoxel's sun lobe: GGX, Schlick on the half vector, Smith's
// height-correlated visibility; rough is perceptual (squared here). Times
// pi: the light is given over pi (environment.lua's KIT_PHYS_SUN_PI), as
// Urho's diffuse has no 1/pi. Multiplied by n.l (Urho's diff) after.
float KitGGX(vec3 normal, vec3 lightDir, float rough, float f0)
{
    vec3 toEye = normalize(cCameraPosPS - vWorldPos.xyz);
    vec3 h = normalize(lightDir + toEye);
    float ndl = clamp(dot(normal, lightDir), 0.0, 1.0);
    float ndh = clamp(dot(normal, h), 0.0001, 1.0);
    float vdh = clamp(dot(toEye, h), 0.0001, 1.0);
    float ndv = abs(dot(normal, toEye)) + 1e-5;
    float a = rough * rough;
    float a2 = a * a;
    float dd = ndh * ndh * (a2 - 1.0) + 1.0;
    float d = a2 / (3.14159 * dd * dd);
    float f = f0 + (1.0 - f0) * pow(1.0 - vdh, 5.0);
    float gv = ndl * sqrt(ndv * ndv * (1.0 - a2) + a2);
    float gl = ndv * sqrt(ndl * ndl * (1.0 - a2) + a2);
    return 3.14159 * d * f * 0.5 / max(gv + gl, 1e-5);
}
#endif

#ifdef KITSPOTS
// PBRVoxel.glsl's spots, its constants
const float KS_CELLS = 16.0;
const float KS_TILT = 0.06;
const float KS_STATIC_CELLS = 6.0;
const float KS_STATIC_TILT = 0.35;
const float KS_RATE = 0.03;
const vec3 KS_WIND = vec3(0.35, 0.0, -0.2);
const float KS_ROUGH = 0.10;
float KsHash(vec3 cell)
{
    vec3 p = fract(cell * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
vec3 KsTilt(vec3 pos, float cells)
{
    vec3 cell = floor(pos * cells);
    return vec3(KsHash(cell + 41.0), KsHash(cell + 67.0),
        KsHash(cell + 89.0)) * 2.0 - 1.0;
}
float KsStill(vec3 pos, float fraction)
{
    if (fraction <= 0.0)
        return 0.0;
    return KsHash(floor(pos * KS_STATIC_CELLS) + 7.0) < fraction ? 1.0 : 0.0;
}
float KsMoving(vec3 pos, float fraction)
{
    if (fraction <= 0.0)
        return 0.0;
    vec3 cell = floor(pos * KS_CELLS);
    float rate = KS_RATE * (0.6 + KsHash(cell + 19.0));
    float u = fract(KsHash(cell) + cElapsedTimePS * rate + dot(pos, KS_WIND));
    float edge = fraction * 0.25;
    return smoothstep(0.0, edge, u) *
        (1.0 - smoothstep(fraction - edge, fraction, u));
}
#endif

#ifdef KITWATER
const float KITWATER_ROUGH = 0.35;
const float KITWATER_F0 = 0.072;
// What a water face draws, blended by its alpha: lit (its body's light),
// a (its opacity), plus what it reflects (spec: the sun's; the sky with
// the ambient). Out: over the bed, the reflected plus (1 - F) of the body
// over (1 - F) of the bed, as the blend's (colour, alpha).
vec4 KitWater(vec3 lit, float a, vec3 normal, vec3 spec)
{
    vec3 toEye = normalize(cCameraPosPS - vWorldPos.xyz);
    float ndv = clamp(abs(dot(normal, toEye)), 0.0, 1.0);
    // Urho's IBL.glsl EnvBRDFApprox (Karis), F0 a scalar
    vec4 r = KITWATER_ROUGH * vec4(-1.0, -0.0275, -0.572, 0.022) +
            vec4(1.0, 0.0425, 1.0, -0.04);
    float a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    float f = clamp(KITWATER_F0 * ab.x + ab.y, 0.0, 1.0);
    vec3 refl = spec;
    #ifdef AMBIENT
        vec3 sky = cAmbientColor.rgb;
        #ifdef KITSKY
            sky *= vColor.a;
        #endif
        refl += 0.7 * f * sky;
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
        // KITWATER keeps the plain alpha, as skeldat's PBRVoxel does: the
        // lit bed through it is most of water's look there
        #ifndef KITWATER
            diffColor.a = 1.0 - pow(1.0 - diffColor.a, 2.2);
        #endif
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
    #elif defined(KITNORMALS)
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
        vec3 normal = normalize(mat3(tangentU * invMax, tangentV * invMax,
            geomNormal) * nn);
    #else
        vec3 normal = normalize(vNormal);
    #endif

    #ifdef KITSPOTS
        // A spot is a piece of the face turned: across it, never past
        // its horizon; glossy by the cube of how far it is in
        vec3 spotPos = vWorldPos.xyz - normalize(vNormal) * 0.01;
        float moving = KsMoving(spotPos, texture2D(sSpecMap, vTexCoord.xy).a);
        float still = KsStill(spotPos, texture2D(sNormalMap, vTexCoord.xy).a);
        float spotMask = max(moving, still);
        float spotGloss = spotMask * spotMask * spotMask;
        vec3 spotTilt = KsTilt(spotPos, KS_CELLS) * (KS_TILT * moving) +
            KsTilt(spotPos, KS_STATIC_CELLS) * (KS_STATIC_TILT * still);
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

        vec3 glint = vec3(0.0);
        #ifdef KITWATER
            // The sun's lobe; a spot's rougher no more ([KIT_SPOTS])
            float wRough = KITWATER_ROUGH;
            #ifdef KITSPOTS
                wRough = mix(wRough, KS_ROUGH, spotGloss);
            #endif
            // diff is n.l times the shadow and the sky's gate
            glint = diff * lightColor * KitGGX(normal, lightDir, wRough,
                KITWATER_F0);
        #elif defined(KITSPOTS)
            // A spot's glint, at full strength however matte the rest
            if (spotGloss > 0.0)
                finalColor += diff * lightColor * spotGloss *
                    KitGGX(normal, lightDir, KS_ROUGH, 0.08);
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
