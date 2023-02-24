using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering;
using UnityEngine.Experimental.Rendering;

public class TAAPass : ScriptableRenderPass
{
    ProfilingSampler m_ProfilingSampler;
    private Material m_Material;
    private TAARenderFeature.Settings m_Settings;

    Dictionary<int, MultiCameraInfo> m_MultiCameraInfo;// = new Dictionary<int, MultiCameraInfo>();
    string[] m_ShaderKeywords = new string[5];
    Matrix4x4 m_PreviousViewProjectionMatrix;
    Vector2 m_Jitter;
    bool useAlpha = false;

    public TAAPass()
    {
        m_ProfilingSampler = new ProfilingSampler("TemporalAntialiasing");

        if (m_Material == null)
        {
            m_Material = CoreUtils.CreateEngineMaterial(Shader.Find("Hidden/PostProcessing/TAA"));
        }
    }

    static class ShaderConstants
    {
        internal static readonly int PrevViewProjectionMatrix = Shader.PropertyToID("_PrevViewProjectionMatrix");
        internal static readonly int Jitter = Shader.PropertyToID("_Jitter");
        internal static readonly int Params1 = Shader.PropertyToID("_Params1");
        internal static readonly int Params2 = Shader.PropertyToID("_Params2");

        public static string GetQualityKeyword(TAARenderFeature.Settings.TAAQuality quality)
        {
            switch (quality)
            {
                case TAARenderFeature.Settings.TAAQuality.Low:
                    return "LOW_QUALITY";
                case TAARenderFeature.Settings.TAAQuality.High:
                    return "HIGH_QUALITY";
                case TAARenderFeature.Settings.TAAQuality.Medium:
                default:
                    return "MEDIUM_QUALITY";
            }
        }
    }

    void SetupMaterials(ref RenderingData renderingData)
    {
        if (m_Material == null)
            return;

        var cameraData = renderingData.cameraData;

        var width = cameraData.cameraTargetDescriptor.width;
        var height = cameraData.cameraTargetDescriptor.height;

        m_Material.SetMatrix(ShaderConstants.PrevViewProjectionMatrix, m_PreviousViewProjectionMatrix);
        m_Material.SetVector(ShaderConstants.Jitter, m_Jitter);

        float antiFlickerIntensity = Mathf.Lerp(0.0f, 3.5f, m_Settings.AntiFlicker);
        float contrastForMaxAntiFlicker = 0.7f - Mathf.Lerp(0.0f, 0.3f, Mathf.SmoothStep(0.5f, 1.0f, m_Settings.AntiFlicker));
        m_Material.SetVector(ShaderConstants.Params1, new Vector4(m_Settings.SharpenStrength, antiFlickerIntensity, contrastForMaxAntiFlicker, m_Settings.sharpenHistoryStrength));
        m_Material.SetVector(ShaderConstants.Params2, new Vector4(m_Settings.SharpenBlend, m_Settings.StationaryBlending, m_Settings.MotionBlending, 0));

        // -------------------------------------------------------------------------------------------------
        // local shader keywords
        m_ShaderKeywords[0] = ShaderConstants.GetQualityKeyword(m_Settings.Quality);
        m_ShaderKeywords[1] = (!cameraData.isSceneViewCamera && m_Settings.UseMotionVector) ? "_USEMOTIONVECTOR" : "_";
        m_ShaderKeywords[2] = m_Settings.UseToneMapping ? "_USETONEMAPPING" : "_";
        m_ShaderKeywords[3] = m_Settings.UseBicubic ? "_USEBICUBIC5TAP" : "_";
        m_ShaderKeywords[4] = useAlpha ? "ENABLE_ALPHA" : "_";
        m_Material.shaderKeywords = m_ShaderKeywords;
    }



    void CheckHistoryRT(int id, int hash, CommandBuffer cmd, RTHandle source, RenderTextureDescriptor desc, bool isSceneView)
    {
        if (!m_MultiCameraInfo.ContainsKey(hash))
        {
            m_MultiCameraInfo[hash] = new MultiCameraInfo();
        }

        // 为了记录A通道 需要修改格式  移动平台未知
        if (!isSceneView && SystemInfo.IsFormatSupported(GraphicsFormat.R16G16B16A16_SFloat, FormatUsage.Sample))
        {
            useAlpha = true;
            desc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;
        }
        else
        {
            useAlpha = false;
        }

        var rtHandle = m_MultiCameraInfo[hash].GetHistoryRTHandle(id);

        if (RenderingUtils.ReAllocateIfNeeded(ref rtHandle, desc, name: "_TemporalHistoryRT_" + id))
        {
            cmd.Blit(source, rtHandle);
            // 分辨率改变时还是从上一个历史RT拷贝
            m_MultiCameraInfo[hash].SetHistoryRTHandle(id, rtHandle);
        }
    }


    public void Setup(TAARenderFeature.Settings settings, Dictionary<int, MultiCameraInfo> multiCameraInfoMap, Vector2 jitter, Matrix4x4 previousViewProjectionMatrix)
    {
        m_Settings = settings;
        m_MultiCameraInfo = multiCameraInfoMap;
        m_Jitter = jitter;
        m_PreviousViewProjectionMatrix = previousViewProjectionMatrix;
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        if (m_Material == null)
            return;

        var cmd = CommandBufferPool.Get();

        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            SetupMaterials(ref renderingData);

            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.msaaSamples = 1;
            desc.depthBufferBits = 0;
            Camera camera = renderingData.cameraData.camera;

            //准备历史RT
            int hash = camera.GetHashCode();
            var source = renderingData.cameraData.renderer.cameraColorTargetHandle;
            CheckHistoryRT(0, hash, cmd, source, desc, renderingData.cameraData.isSceneViewCamera);
            CheckHistoryRT(1, hash, cmd, source, desc, renderingData.cameraData.isSceneViewCamera);

            RTHandle rt1 = null, rt2 = null;
            m_MultiCameraInfo[hash].GetHistoryPingPongRT(ref rt1, ref rt2);

            m_Material.SetTexture("_HistoryTexture", rt1);
            Blit(cmd, source, rt2, m_Material);
            Blit(cmd, rt2, source);

            // Blit(cmd, ref renderingData, m_Material);
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        base.OnCameraCleanup(cmd);
    }
}
