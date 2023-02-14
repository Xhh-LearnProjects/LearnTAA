Shader "Hidden/PostProcessing/TAA"
{

    HLSLINCLUDE

    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/Shaders/PostProcessing/Common.hlsl"

    //-------------
    #if HIGH_QUALITY
        #define YCOCG                   1
        #define NEIGHBOUROOD_VARIANCE   1
        #define HISTORY_CLIP_AABB       1
        #define WIDE_NEIGHBOURHOOD      1
        #define SHARPEN_FILTER          1
    #elif MEDIUM_QUALITY
        #define YCOCG                   1
        #define NEIGHBOUROOD_VARIANCE   1
        #define HISTORY_CLIP_AABB       1
        #define WIDE_NEIGHBOURHOOD      0
        #define SHARPEN_FILTER          0
    #else
        #define YCOCG                   0
        #define NEIGHBOUROOD_VARIANCE   0
        #define HISTORY_CLIP_AABB       0
        #define WIDE_NEIGHBOURHOOD      0
        #define SHARPEN_FILTER          0
    #endif

    // ------------------------------------------------------------------------------------
    #define CLAMP_MAX       65472.0 // HALF_MAX minus one (2 - 2^-9) * 2^15

    TEXTURE2D(_HistoryTexture); float4 _HistoryTexture_TexelSize;

    float4x4 _PrevViewProjectionMatrix;
    float2 _Jitter;
    float4 _Params1;
    float4 _Params2;
    #define _SharpenStrength                _Params1.x
    #define _AntiFlickerIntensity           _Params1.y
    #define _ContrastForMaxAntiFlicker      _Params1.z
    #define _SharpenHistoryStrength         _Params1.w
    #define _SharpenBlend                   _Params2.x
    #define _StationaryBlend                _Params2.y
    #define _MotionBlend                    _Params2.z



    #define SMALL_NEIGHBOURHOOD_SIZE 4
    #define WIDTH_NEIGHBOURHOOD_SIZE 8
    #define NEIGHBOUR_COUNT ((WIDE_NEIGHBOURHOOD == 0) ? SMALL_NEIGHBOURHOOD_SIZE : WIDTH_NEIGHBOURHOOD_SIZE)

    struct NeighbourhoodSamples
    {
        #if WIDE_NEIGHBOURHOOD
            float3 neighbours[8];
        #else
            float3 neighbours[4];
        #endif

        float3 central;
        float3 minNeighbour;
        float3 maxNeighbour;
        float3 avgNeighbour;
    };

    //三分量各取最小值
    float3 Min3Float3(float3 a, float3 b, float3 c)
    {
        return float3(Min3(a.x, b.x, c.x),
        Min3(a.y, b.y, c.y),
        Min3(a.z, b.z, c.z));
    }

    float3 Max3Float3(float3 a, float3 b, float3 c)
    {
        return float3(Max3(a.x, b.x, c.x),
        Max3(a.y, b.y, c.y),
        Max3(a.z, b.z, c.z));
    }

    float3 ConvertToWorkingSpace(float3 color)
    {
        #if YCOCG
            return RGBToYCoCg(color);
        #else
            return color;
        #endif
    }

    float3 ConvertToOutputSpace(float3 color)
    {
        #if YCOCG
            return YCoCgToRGB(color);
        #else
            return color;
        #endif
    }

    float GetLuma(float3 color)
    {
        #if YCOCG
            // We work in YCoCg hence the luminance is in the first channel.
            return color.x;
        #else
            return Luminance(color);
        #endif
    }

    float PerceptualWeight(float3 c)
    {
        #if _USETONEMAPPING
            return rcp(GetLuma(c) + 1.0);
        #else
            return 1;
        #endif
    }

    float PerceptualInvWeight(float3 c)
    {
        #if _USETONEMAPPING
            return rcp(1.0 - GetLuma(c));
        #else
            return 1;
        #endif
    }

    half4 GetSourceTexture(float2 uv)
    {
        return SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, uv, 0);
    }

    // 没有MotionVector 只处理摄像机运动的偏移
    // 得到当前片元在上一帧画面中的位置
    float2 GetReprojection(float depth, float2 uv)
    {
        //https://zhuanlan.zhihu.com/p/138866533
        #if UNITY_REVERSED_Z
            depth = 1.0 - depth;
        #endif

        depth = 2.0 * depth - 1.0;
        // 深度还原世界坐标 TODO 这里unity_CameraInvProjection需要传递
        float3 viewPos = ComputeViewSpacePosition(uv, depth, unity_CameraInvProjection);
        float4 worldPos = float4(mul(unity_CameraToWorld, float4(viewPos, 1.0)).xyz, 1.0);

        // 利用上一帧VP矩阵 找到当前坐标在上一帧的uv
        float4 prevClipPos = mul(_PrevViewProjectionMatrix, worldPos);
        float2 prevPosCS = prevClipPos.xy / prevClipPos.w;
        return prevPosCS * 0.5 + 0.5;
    }

    // From Filmic SMAA presentation[Jimenez 2016]
    // A bit more verbose that it needs to be, but makes it a bit better at latency hiding
    float3 HistoryBicubic5Tap(float2 UV, float sharpening)
    {
        float2 samplePos = UV * _HistoryTexture_TexelSize.zw;
        float2 tc1 = floor(samplePos - 0.5) + 0.5;
        float2 f = samplePos - tc1;
        float2 f2 = f * f;
        float2 f3 = f * f2;

        const float c = sharpening;

        float2 w0 = -c * f3 + 2.0 * c * f2 - c * f;
        float2 w1 = (2.0 - c) * f3 - (3.0 - c) * f2 + 1.0;
        float2 w2 = - (2.0 - c) * f3 + (3.0 - 2.0 * c) * f2 + c * f;
        float2 w3 = c * f3 - c * f2;

        float2 w12 = w1 + w2;
        float2 tc0 = _HistoryTexture_TexelSize.xy * (tc1 - 1.0);
        float2 tc3 = _HistoryTexture_TexelSize.xy * (tc1 + 2.0);
        float2 tc12 = _HistoryTexture_TexelSize.xy * (tc1 + w2 / w12);

        float3 s0 = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, float2(tc12.x, tc0.y)).rgb;
        float3 s1 = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, float2(tc0.x, tc12.y)).rgb;
        float3 s2 = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, float2(tc12.x, tc12.y)).rgb;
        float3 s3 = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, float2(tc3.x, tc0.y)).rgb;
        float3 s4 = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, float2(tc12.x, tc3.y)).rgb;

        float cw0 = (w12.x * w0.y);
        float cw1 = (w0.x * w12.y);
        float cw2 = (w12.x * w12.y);
        float cw3 = (w3.x * w12.y);
        float cw4 = (w12.x * w3.y);

        // ANTI_RINGING
        float3 min = Min3Float3(s0, s1, s2);
        min = Min3Float3(min, s3, s4);

        float3 max = Max3Float3(s0, s1, s2);
        max = Max3Float3(max, s3, s4);

        //
        s0 *= cw0;
        s1 *= cw1;
        s2 *= cw2;
        s3 *= cw3;
        s4 *= cw4;

        float3 historyFiltered = s0 + s1 + s2 + s3 + s4;
        float weightSum = cw0 + cw1 + cw2 + cw3 + cw4;

        float3 filteredVal = historyFiltered * rcp(weightSum);

        // ANTI_RINGING
        // This sortof neighbourhood clamping seems to work to avoid the appearance of overly dark outlines in case
        // sharpening of history is too strong.
        return clamp(filteredVal, min, max);
    }

    float3 GetFilteredHistory(float2 uv)
    {
        #if _USEBICUBIC5TAP
            float3 history = HistoryBicubic5Tap(uv, _SharpenHistoryStrength);
        #else
            // Bilinear凑活下 没必要Bicubic
            float3 history = SAMPLE_TEXTURE2D(_HistoryTexture, sampler_LinearClamp, uv).rgb;
        #endif

        history = clamp(history, 0, CLAMP_MAX);
        return ConvertToWorkingSpace(history);
    }


    //收集周边信息
    void GatherNeighbourhood(float2 uv, half3 centralColor, out NeighbourhoodSamples samples)
    {
        float2 k = _BlitTextureSize.xy;
        samples = (NeighbourhoodSamples)0;
        samples.central = centralColor;

        #if WIDE_NEIGHBOURHOOD
            // Plus shape 上下左右 bc mr tc ml
            samples.neighbours[0] = GetSourceTexture(uv + float2(0, 1) * k);
            samples.neighbours[1] = GetSourceTexture(uv + float2(1, 0) * k);
            samples.neighbours[2] = GetSourceTexture(uv + float2(0, -1) * k);
            samples.neighbours[3] = GetSourceTexture(uv + float2(-1, 0) * k);

            // Cross shape 斜角 bl tr br tl
            samples.neighbours[4] = GetSourceTexture(uv + float2(-1, 1) * k);
            samples.neighbours[5] = GetSourceTexture(uv + float2(1, -1) * k);
            samples.neighbours[6] = GetSourceTexture(uv + float2(1, 1) * k);
            samples.neighbours[7] = GetSourceTexture(uv + float2(-1, -1) * k);

        #else // SMALL_NEIGHBOURHOOD_SHAPE == 4
            // Plus shape 上下左右 bc mr tc ml
            samples.neighbours[0] = GetSourceTexture(uv + float2(0, 1) * k);
            samples.neighbours[1] = GetSourceTexture(uv + float2(1, 0) * k);
            samples.neighbours[2] = GetSourceTexture(uv + float2(0, -1) * k);
            samples.neighbours[3] = GetSourceTexture(uv + float2(-1, 0) * k);
        #endif
    }

    float3 FilterCentralColor(NeighbourhoodSamples samples)
    {
        // blackman harris filter 省掉
        return samples.central;
    }

    // msalvi_temporal_supersampling 2016
    void VarianceNeighbourhood(inout NeighbourhoodSamples samples, float historyLuma, float colorLuma, float2 antiFlickerParams, float motionVectorLength)
    {
        float3 moment1 = 0;
        float3 moment2 = 0;

        UNITY_UNROLL
        for (int i = 0; i < NEIGHBOUR_COUNT; ++i)
        {
            moment1 += samples.neighbours[i];
            moment2 += samples.neighbours[i] * samples.neighbours[i];
        }
        samples.avgNeighbour = moment1 * rcp(NEIGHBOUR_COUNT);

        moment1 += samples.central;
        moment2 += samples.central * samples.central;

        const int sampleCount = NEIGHBOUR_COUNT + 1;
        moment1 *= rcp(sampleCount);
        moment2 *= rcp(sampleCount);

        float3 stdDev = sqrt(abs(moment2 - moment1 * moment1));

        float stDevMultiplier = 1.5;
        // The reasoning behind the anti flicker is that if we have high spatial contrast (high standard deviation)
        // and high temporal contrast, we let the history to be closer to be unclipped. To achieve, the min/max bounds
        // are extended artificially more.
        // float temporalContrast = saturate(abs(colorLuma - historyLuma) / Max3(0.2, colorLuma, historyLuma));

        // const float screenDiag = length(_SourceTex_TexelSize.zw);
        // const float maxFactorScale = 2.25f; // when stationary
        // const float minFactorScale = 0.8f; // when moving more than slightly
        // float localizedAntiFlicker = lerp(antiFlickerParams.x * minFactorScale, antiFlickerParams.x * maxFactorScale, saturate(1.0f - 2.0f * (motionVectorLen * screenDiag)));
        
        // stDevMultiplier += lerp(0.0, localizedAntiFlicker, smoothstep(0.05, antiFlickerParams.y, temporalContrast));
        // TODO 抗闪烁会导致半透物体问题
        samples.minNeighbour = moment1 - stdDev * stDevMultiplier;
        samples.maxNeighbour = moment1 + stdDev * stDevMultiplier;
    }

    void MinMaxNeighbourhood(inout NeighbourhoodSamples samples)
    {
        // We always have at least the first 4 neighbours.
        samples.minNeighbour = Min3Float3(samples.neighbours[0], samples.neighbours[1], samples.neighbours[2]);
        samples.minNeighbour = Min3Float3(samples.minNeighbour, samples.central, samples.neighbours[3]);

        samples.maxNeighbour = Max3Float3(samples.neighbours[0], samples.neighbours[1], samples.neighbours[2]);
        samples.maxNeighbour = Max3Float3(samples.maxNeighbour, samples.central, samples.neighbours[3]);
        
        samples.avgNeighbour = 0;
        //计算平均值
        UNITY_UNROLL
        for (int i = 0; i < NEIGHBOUR_COUNT; ++i)
        {
            samples.avgNeighbour += samples.neighbours[i];
        }
        samples.avgNeighbour *= rcp(NEIGHBOUR_COUNT);
    }

    void GetNeighbourhoodCorners(inout NeighbourhoodSamples samples, half historyLuma, half colorLuma, float2 antiFlickerParams, float motionVectorLength)
    {
        #if NEIGHBOUROOD_VARIANCE //方差
            VarianceNeighbourhood(samples, historyLuma, colorLuma, antiFlickerParams, motionVectorLength);
        #else
            MinMaxNeighbourhood(samples);
        #endif
    }

    float3 DirectClipToAABB(float3 history, float3 minimum, float3 maximum)
    {
        // note: only clips towards aabb center (but fast!)
        float3 center = 0.5 * (maximum + minimum);
        float3 extents = 0.5 * (maximum - minimum);

        // This is actually `distance`, however the keyword is reserved
        float3 offset = history - center;
        float3 v_unit = offset.xyz / extents.xyz;
        float3 absUnit = abs(v_unit);
        float maxUnit = Max3(absUnit.x, absUnit.y, absUnit.z);

        if (maxUnit > 1.0)
            return center + (offset / maxUnit);
        else
            return history;
    }

    float3 GetClippedHistory(float3 filteredColor, float3 history, float3 minimum, float3 maximum)
    {
        #if HISTORY_CLIP_AABB
            return DirectClipToAABB(history, minimum, maximum);
            // #elif HISTORY_CLIP_BLEDN
            //     float historyBlend = DistToAABB(filteredColor, history, minimum, maximum);
            //     return lerp(history, filteredColor, historyBlend);
        #else
            return clamp(history, minimum, maximum);
        #endif
    }


    struct VaryingsTAA
    {
        float4 positionCS : SV_POSITION;
        float4 uv : TEXCOORD0;
    };

    VaryingsTAA VertTAA(Attributes input)
    {
        VaryingsTAA output;
        UNITY_SETUP_INSTANCE_ID(input);
        
        #if SHADER_API_GLES
            float4 pos = input.positionOS;
            float2 uv = input.uv;
        #else
            float4 pos = GetFullScreenTriangleVertexPosition(input.vertexID);
            float2 uv = GetFullScreenTriangleTexCoord(input.vertexID);
        #endif

        output.positionCS = pos;
        output.uv.xy = uv;

        float4 ndc = output.positionCS * 0.5f;
        // 注意这里不要管_ProjectionParams.x
        output.uv.zw = ndc.xy + ndc.w;

        return output;
    }


    half4 FragTAA(VaryingsTAA input) : SV_Target
    {
        // --------------- Get resampled history ---------------
        float depth = SampleSceneDepth(input.uv.xy);

        float2 prevUV = GetReprojection(depth, input.uv.zw);
        float2 motionVector = input.uv.xy - prevUV;

        float3 history = GetFilteredHistory(prevUV);
        history *= PerceptualWeight(history);
        // return float4(history, 1);

        // --------------- Gather neigbourhood data ---------------
        float2 uv = input.uv.xy - _Jitter;

        float3 color = GetSourceTexture(uv).rgb;

        NeighbourhoodSamples samples;
        GatherNeighbourhood(uv, color, samples);

        // --------------- Filter central sample ---------------
        float3 filteredColor = FilterCentralColor(samples);

        //TODO 处理屏幕边缘
        bool offScreen = any(abs(prevUV * 2 - 1) >= 1.0f);
        if (offScreen)
            history = filteredColor;

        // --------------- Get neighbourhood information and clamp history ---------------
        float colorLuma = GetLuma(filteredColor);
        float historyLuma = GetLuma(history);

        float motionVectorLength = length(motionVector);
        GetNeighbourhoodCorners(samples, historyLuma, colorLuma, float2(_AntiFlickerIntensity, _ContrastForMaxAntiFlicker), motionVectorLength);
        history = GetClippedHistory(filteredColor, history, samples.minNeighbour, samples.maxNeighbour);

        #if SHARPEN_FILTER
        #endif

        // --------------- Compute blend factor for history ---------------
        // TODO
        // float blendFactor = GetBlendFactor(motionVectorLength, colorLuma, historyLuma, GetLuma(samples.minNeighbour), GetLuma(samples.maxNeighbour));
        // blendFactor = max(blendFactor, 0.03);
        // 还是先用老版本混合系数
        float blendFactor = 1 - clamp(lerp(_StationaryBlend, _MotionBlend, motionVectorLength * 6000), _MotionBlend, _StationaryBlend);

        // --------------- Blend to final value and output ---------------
        float3 finalColor = lerp(history, filteredColor, blendFactor);

        finalColor *= PerceptualInvWeight(finalColor);
        finalColor = ConvertToOutputSpace(finalColor);
        finalColor = clamp(finalColor, 0, CLAMP_MAX);

        return float4(finalColor, blendFactor);
    }
    

    ENDHLSL

    //-----------------------------------------------------
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" "RenderType" = "Opaque" }

        Pass
        {
            Name "TemporalAntialiasing"
            Cull Back

            HLSLPROGRAM
            #pragma vertex VertTAA
            #pragma fragment FragTAA
            
            ENDHLSL
        }
    }
}
