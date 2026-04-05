Shader "Hidden/MetaballRayMarch"
{
    Properties
    {
        _BallColor          ("Ball Tint",           Color)          = (0.9, 0.6, 0.1, 1.0)
        _Smoothness         ("Smoothness",           Range(0,1))     = 0.95
        _RefractionStrength ("Refraction Strength",  Range(0, 0.15)) = 0.05
        _FresnelPower       ("Fresnel Power",        Range(1, 8))    = 4.0
        _Threshold          ("Metaball Threshold",   Range(0.1, 2))  = 1.0
        _MarchSteps         ("March Steps",          Int)            = 64
        _MarchDistance      ("Max March Distance",   Float)          = 20.0
        _RadiusScale        ("Radius Scale",         Float)          = 1.0
        _DebugMode          ("Debug Mode (0=off 1=ray dirs)", Float) = 0
    }

    HLSLINCLUDE

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

    // ---------------------------------------------------------------------------
    // Global shader variables — set via Shader.SetGlobal* each frame.
    // These must NOT be inside CBUFFER_START(UnityPerMaterial).
    // ---------------------------------------------------------------------------
    float4  _BallData[16];          // xyz = world position, w = radius
    int     _BallCount;
    // Use float4 to avoid GPU alignment issues with float3 globals
    float4  _MetaballLightDir;      // xyz = world-space direction toward light
    float4  _MetaballLightColor;    // xyz = rgb colour
    float4  _MetaballAmbient;       // xyz = rgb ambient

    // ---------------------------------------------------------------------------
    // Per-material properties — set via material.Set* or the Inspector.
    // Must be inside CBUFFER_START(UnityPerMaterial) for SRP to resolve them.
    // ---------------------------------------------------------------------------
    CBUFFER_START(UnityPerMaterial)
        float4  _BallColor;
        float   _Smoothness;
        float   _RefractionStrength;
        float   _FresnelPower;
        float   _Threshold;
        float   _MarchSteps;
        float   _MarchDistance;
        float   _RadiusScale;       // multiplier on top of lossyScale-derived radius
        float   _DebugMode;
    CBUFFER_END

    // _ColorPyramidTexture is already declared by HDRP's ShaderVariables.hlsl —
    // no need to redeclare it here. It holds scene color before transparents (refraction source).

    // ---------------------------------------------------------------------------
    // Metaball potential field  f(p) = sum( r² / |p - center|² )
    // Surface is where f(p) == _Threshold
    // ---------------------------------------------------------------------------
    float MetaballField(float3 pos)
    {
        float sum = 0.0;
        for (int i = 0; i < _BallCount; i++)
        {
            float3 delta = pos - _BallData[i].xyz;
            float  r     = _BallData[i].w * _RadiusScale;
            float  d2    = max(dot(delta, delta), 1e-5);
            sum += (r * r) / d2;
        }
        return sum;
    }

    // Central-difference normal — cheap, accurate enough for smooth blobs
    float3 MetaballNormal(float3 pos)
    {
        const float e = 0.015;
        float3 n;
        n.x = MetaballField(pos + float3(e, 0, 0)) - MetaballField(pos - float3(e, 0, 0));
        n.y = MetaballField(pos + float3(0, e, 0)) - MetaballField(pos - float3(0, e, 0));
        n.z = MetaballField(pos + float3(0, 0, e)) - MetaballField(pos - float3(0, 0, e));
        return normalize(-n); // negate: gradient points inward, we need outward normal
    }

    // ---------------------------------------------------------------------------
    // GGX specular
    // ---------------------------------------------------------------------------
    float GGXSpecular(float3 N, float3 H, float roughness)
    {
        float a  = roughness * roughness;
        float a2 = a * a;
        float NdotH  = saturate(dot(N, H));
        float NdotH2 = NdotH * NdotH;
        float denom  = (NdotH2 * (a2 - 1.0) + 1.0);
        return a2 / max(PI * denom * denom, 1e-5);
    }

    // ---------------------------------------------------------------------------
    // Vertex — standard fullscreen triangle (no VBO needed)
    // ---------------------------------------------------------------------------
    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        float2 uv         : TEXCOORD0;
    };

    Varyings Vert(uint vertexID : SV_VertexID)
    {
        Varyings o;
        o.positionCS = GetFullScreenTriangleVertexPosition(vertexID);
        o.uv         = GetFullScreenTriangleTexCoord(vertexID);
        return o;
    }

    // ---------------------------------------------------------------------------
    // Fragment
    // ---------------------------------------------------------------------------
    struct FragOutput
    {
        float4 color : SV_Target;
        float  depth : SV_Depth;
    };

    FragOutput Frag(Varyings i)
    {
        FragOutput o;

        // --- Reconstruct world-space ray ----------------------------------------
        // GetFullScreenTriangleTexCoord on DX gives V=0 at top (DX texture convention).
        // ComputeWorldSpacePosition expects V=0 at bottom (OpenGL/NDC convention).
        // Pre-flip Y so the two conventions match; without this the metaball appears
        // reflected vertically in the scene (objects below camera appear above horizon).
        float2 rayUV = float2(i.uv.x, 1.0 - i.uv.y);

        float3 rayOrigin = GetCurrentViewPosition();
        float3 posOnFar  = ComputeWorldSpacePosition(rayUV, UNITY_RAW_FAR_CLIP_VALUE, UNITY_MATRIX_I_VP);
        float3 rayDir    = normalize(posOnFar - rayOrigin);

        // --- Debug mode 1: show ray directions as RGB colours -------------------
        // Green should be bright at top of screen, dark at bottom (rays point up/down).
        // Red brighter on right, blue on both sides (Z forward).
        if (_DebugMode >= 0.5)
        {
            o.color = float4(rayDir * 0.5 + 0.5, 1.0);
            o.depth = UNITY_RAW_FAR_CLIP_VALUE;
            return o;
        }

        // --- Cap march at whatever opaque geometry is already in the depth buffer -
        float  sceneRawDepth = LoadCameraDepth(i.positionCS.xy);
        float3 scenePosWS    = ComputeWorldSpacePosition(rayUV, sceneRawDepth, UNITY_MATRIX_I_VP);
        float  maxDist       = min(_MarchDistance, length(scenePosWS - rayOrigin));

        // --- Ray march ----------------------------------------------------------
        int   marchSteps = max(1, (int)_MarchSteps);
        float stepSize   = maxDist / (float)marchSteps;
        float t          = 0.01; // start just past the camera near plane
        bool  hit        = false;
        float3 hitPos;

        UNITY_LOOP
        for (int s = 0; s < marchSteps; s++)
        {
            float3 pos   = rayOrigin + rayDir * t;
            float  field = MetaballField(pos);

            if (field >= _Threshold)
            {
                // Binary-search refinement for a crisper surface (2 extra steps)
                float tLo = t - stepSize, tHi = t;
                for (int r = 0; r < 4; r++)
                {
                    float tMid = (tLo + tHi) * 0.5;
                    if (MetaballField(rayOrigin + rayDir * tMid) >= _Threshold)
                        tHi = tMid;
                    else
                        tLo = tMid;
                }
                hitPos = rayOrigin + rayDir * tHi;
                hit    = true;
                break;
            }

            // Adaptive step — march faster when far from threshold
            float proximity = saturate(field / _Threshold);  // 0 = far, 1 = at surface
            t += stepSize * lerp(2.0, 0.5, proximity);
            if (t > maxDist) break;
        }

        if (!hit) discard;

        // --- Shading ------------------------------------------------------------
        float3 N    = MetaballNormal(hitPos);
        float3 V    = -rayDir;
        float  NdotV = saturate(dot(N, V));
        float  NdotL = saturate(dot(N, _MetaballLightDir.xyz));
        float3 H    = normalize(V + _MetaballLightDir.xyz);

        // Fresnel (Schlick)
        float fresnel = pow(1.0 - NdotV, _FresnelPower);

        // Refraction
        float2 refractUV  = i.uv + N.xy * _RefractionStrength * (1.0 - fresnel);
        refractUV         = clamp(refractUV, 0.001, 0.999);
        float3 pyramidCol = SAMPLE_TEXTURE2D_X_LOD(_ColorPyramidTexture,
                                s_linear_clamp_sampler,
                                refractUV * _RTHandleScale.xy, 0).rgb;
        float3 refractCol = lerp(_BallColor.rgb * 0.4, pyramidCol * _BallColor.rgb, 0.7);

        // Reflection via SH
        float3 irradiance = float3(
            dot(unity_SHAr, float4(N, 1)),
            dot(unity_SHAg, float4(N, 1)),
            dot(unity_SHAb, float4(N, 1)));
        irradiance = max(0, irradiance);

        // GGX specular
        float  roughness = 1.0 - _Smoothness;
        float  ggx       = GGXSpecular(N, H, max(roughness, 0.04));
        float  specScale = PI * roughness * roughness;
        float3 specular  = (_MetaballLightColor.xyz * NdotL) * ggx * specScale * _Smoothness;

        // Fresnel blend
        float3 baseColor = lerp(refractCol, irradiance * _BallColor.rgb * 0.5, fresnel * 0.6);
        float3 color     = baseColor + specular + _MetaballAmbient.xyz * _BallColor.rgb * 0.1;

        // Alpha
        float alpha = lerp(0.12, 0.88, fresnel) + saturate(ggx * specScale) * 0.4;
        alpha = saturate(alpha);

        // Premultiplied alpha (matches HDRP blend mode below)
        o.color = float4(color * alpha, alpha);

        // Write depth — this is what makes the metaball sit correctly in the
        // scene, receiving and casting depth-based effects (SSAO, SSR, etc.)
        float4 hitCS = mul(UNITY_MATRIX_VP, float4(hitPos, 1.0));
        o.depth = hitCS.z / hitCS.w;

        return o;
    }

    ENDHLSL

    SubShader
    {
        // No culling, no depth test (we write depth manually)
        Pass
        {
            Name "MetaballForward"
            ZWrite On
            ZTest Always
            Cull Off
            // Premultiplied alpha — plays nicely with HDR & tonemapping
            Blend One OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex   Vert
            #pragma fragment Frag
            #pragma target   4.5
            ENDHLSL
        }
    }
    Fallback Off
}
