Shader "Hidden/PostProcessing/TAA"
{

    HLSLINCLUDE

    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/Shaders/PostProcessing/Common.hlsl"

    //-------------

    //-------------
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

    struct NeighbourhoodSamples
    {
        half3 neighbours[4];

        half3 central;
        half3 minNeighbour;
        half3 maxNeighbour;
        half3 avgNeighbour;
    };

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

        // Plus shape 上下左右 bc mr tc ml
        samples.neighbours[0] = GetSourceTexture(uv + float2(0, 1) * k);
        samples.neighbours[1] = GetSourceTexture(uv + float2(1, 0) * k);
        samples.neighbours[2] = GetSourceTexture(uv + float2(0, -1) * k);
        samples.neighbours[3] = GetSourceTexture(uv + float2(-1, 0) * k);
    }

    half3 FilterCentralColor(NeighbourhoodSamples samples)
    {
        // blackman harris filter 省掉
        return samples.central;
    }

    void GetNeighbourhoodCorners(inout NeighbourhoodSamples samples, half historyLuma, half colorLuma, float2 antiFlickerParams, float motionVectorLength)
    {

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
        half3 history = 0;

        // --------------- Gather neigbourhood data ---------------
        float2 uv = input.uv.xy - _Jitter;
        // return half4(input.uv.zw, 0, 1);

        half3 color = GetSourceTexture(uv).rgb;

        NeighbourhoodSamples samples;
        GatherNeighbourhood(uv, color, samples);

        // --------------- Filter central sample ---------------
        half3 filteredColor = FilterCentralColor(samples);

        //TODO 处理屏幕边缘
        

        // --------------- Get neighbourhood information and clamp history ---------------
        half colorLuma = Luminance(filteredColor);
        half historyLuma = Luminance(history);

        float motionVectorLength = length(motionVector);


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
