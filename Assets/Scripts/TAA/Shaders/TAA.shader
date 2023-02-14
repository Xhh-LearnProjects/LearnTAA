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

    //-------------

    TEXTURE2D(_HistoryTexture);

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

    half4 GetSourceTexture(float2 uv)
    {
        return SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, uv, 0);
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

        // float3 history = GetFilteredHistory(prevUV);
        // history *= PerceptualWeight(history);

        float2 motionVector = 0;
        float3 history = 0;

        // --------------- Gather neigbourhood data ---------------
        float2 uv = input.uv.xy - _Jitter;
        // return half4(input.uv.zw, 0, 1);

        float3 color = GetSourceTexture(uv).rgb;

        NeighbourhoodSamples samples;
        GatherNeighbourhood(uv, color, samples);

        // --------------- Filter central sample ---------------
        float3 filteredColor = FilterCentralColor(samples);

        //TODO 处理屏幕边缘
        

        // --------------- Get neighbourhood information and clamp history ---------------
        float colorLuma = Luminance(filteredColor);
        float historyLuma = Luminance(history);

        float motionVectorLength = length(motionVector);
        GetNeighbourhoodCorners(samples, historyLuma, colorLuma, float2(_AntiFlickerIntensity, _ContrastForMaxAntiFlicker), motionVectorLength);
        history = GetClippedHistory(filteredColor, history, samples.minNeighbour, samples.maxNeighbour);

        #if SHARPEN_FILTER
        #endif

        return GetSourceTexture(uv);
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
