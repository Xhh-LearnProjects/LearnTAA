using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

//作为单一的临时工程 暂时使用RendererFeature来实现 正式工程应该集成到后处理中去
//TemporalAntialiasing
public class TAARenderFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public enum TAAQuality
        {
            Low,
            Medium,
            High
        }

        public TAAQuality Quality;
        public bool PreviewInSceneView;
        public bool UseMotionVector;


        [Tooltip("历史帧中静止像素混合比例")]
        [Range(0, 0.99f)]
        public float StationaryBlending = 0.95f;


        [Tooltip("历史帧中明显运动帧混合比例")]
        [Range(0, 0.99f)]
        public float MotionBlending = 0.7f;

        [Tooltip("降低闪烁")]
        [Range(0f, 1f)]
        public float AntiFlicker = 0.5f;

        [Space(6)]
        [Header("High Quality")]
        [Tooltip("锐化做的比较轻微且只在HighQuality生效")]
        [Range(0f, 0.5f)]
        public float SharpenStrength = 0.15f;

        [Range(0f, 1f)]
        public float sharpenHistoryStrength = 0.35f;

        [Tooltip("锐化混合只在HighQuality生效")]
        [Range(0f, 1f)]
        public float SharpenBlend = 0.2f;
    }

    public Settings settings;

    private TAAPass m_TAAPass;
    private TemporalAntialiasingCamera m_TAACameraPass;

    Material m_Material;
    Matrix4x4 m_PreviousViewProjectionMatrix;
    Vector2 m_Jitter;


    //为了能在sceneview也能生效 使用多个MultiCameraInfo
    Dictionary<int, MultiCameraInfo> m_MultiCameraInfo = new Dictionary<int, MultiCameraInfo>();

    public override void Create()
    {
        m_TAAPass = new TAAPass();
        m_TAAPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;

        m_TAACameraPass = new TemporalAntialiasingCamera();
        //根据渲染路径决定顺序
        // m_TAACameraPass.renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;//Forward
        m_TAACameraPass.renderPassEvent = RenderPassEvent.BeforeRenderingGbuffer;//Deferred

        if (m_Material == null)
        {
            m_Material = CoreUtils.CreateEngineMaterial(Shader.Find("Hidden/PostProcessing/TAA"));
        }
    }

    public int sampleIndex { get; private set; }
    const int k_SampleCount = 8;

    Vector2 GenerateRandomOffset()
    {
        //使用低差序列来生成随机数
        // The variance between 0 and the actual halton sequence values reveals noticeable instability
        // in Unity's shadow maps, so we avoid index 0.
        var offset = new Vector2(
                HaltonSequence.Get((sampleIndex & 1023) + 1, 2) - 0.5f,
                HaltonSequence.Get((sampleIndex & 1023) + 1, 3) - 0.5f
            );

        if (++sampleIndex >= k_SampleCount)
            sampleIndex = 0;

        return offset;
    }

    Matrix4x4 GetJitteredProjectionMatrix(CameraData cameraData, ref Vector2 jitter)
    {
        var projMatrix = cameraData.camera.projectionMatrix;
        var desc = cameraData.cameraTargetDescriptor;

        jitter = new Vector2(jitter.x / desc.width, jitter.y / desc.height);

        if (cameraData.camera.orthographic)
        {
            projMatrix[0, 3] -= jitter.x * 2;
            projMatrix[1, 3] -= jitter.y * 2;
        }
        else
        {
            projMatrix[0, 2] += jitter.x * 2;
            projMatrix[1, 2] += jitter.y * 2;
        }

        return projMatrix;
    }

    static class ShaderConstants
    {
        internal static readonly int PrevViewProjectionMatrix = Shader.PropertyToID("_PrevViewProjectionMatrix");
        internal static readonly int Jitter = Shader.PropertyToID("_Jitter");
        internal static readonly int Params1 = Shader.PropertyToID("_Params1");
        internal static readonly int Params2 = Shader.PropertyToID("_Params2");

        public static string GetQualityKeyword(Settings.TAAQuality quality)
        {
            switch (quality)
            {
                case Settings.TAAQuality.Low:
                    return "LOW_QUALITY";
                case Settings.TAAQuality.High:
                    return "HIGH_QUALITY";
                case Settings.TAAQuality.Medium:
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

        float antiFlicker = 0;
        float antiFlickerIntensity = Mathf.Lerp(0.0f, 3.5f, antiFlicker);
        float contrastForMaxAntiFlicker = 0.7f - Mathf.Lerp(0.0f, 0.3f, Mathf.SmoothStep(0.5f, 1.0f, antiFlicker));
        m_Material.SetVector(ShaderConstants.Params1, new Vector4(settings.SharpenStrength, antiFlickerIntensity, contrastForMaxAntiFlicker, settings.sharpenHistoryStrength));
        m_Material.SetVector(ShaderConstants.Params2, new Vector4(settings.SharpenBlend, settings.StationaryBlending, settings.MotionBlending, 0));
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        CameraData cameraData = renderingData.cameraData;
        Camera camera = cameraData.camera;
        int hash = camera.GetHashCode();

        if (!m_MultiCameraInfo.ContainsKey(hash))
        {
            m_MultiCameraInfo[hash] = new MultiCameraInfo();
        }

        Matrix4x4 curVPMatrix = camera.projectionMatrix * camera.worldToCameraMatrix;
        m_PreviousViewProjectionMatrix = m_MultiCameraInfo[hash].SetPreviousVPMatrix(curVPMatrix);
        //-----------
        // TODO jitterSpread
        int taaFrameIndex = sampleIndex;
        Vector2 jitter = GenerateRandomOffset();//获得镜头抖动
        Matrix4x4 jitterredProjectMatrix = GetJitteredProjectionMatrix(cameraData, ref jitter);//获取抖动后的P矩阵
        m_Jitter = jitter;
        m_TAACameraPass.Setup(jitterredProjectMatrix, taaFrameIndex);
        renderer.EnqueuePass(m_TAACameraPass);

        SetupMaterials(ref renderingData);

        //移动到PASS下
        // RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
        // desc.msaaSamples = 1;
        // desc.depthBufferBits = 0;
        // var source = renderingData.cameraData.renderer.cameraColorTargetHandle;
        // CheckHistoryRT(0, hash, cmd, source, desc);


        m_TAAPass.Setup(settings, m_Material, m_MultiCameraInfo);
        renderer.EnqueuePass(m_TAAPass);
    }


}

public class MultiCameraInfo
{
    const int k_NumHistoryTextures = 2;
    RTHandle[] m_HistoryPingPongRTHandle;
    public Matrix4x4 m_PreviousViewProjectionMatrix = Matrix4x4.zero;
    int m_PingPong = 0;

    public MultiCameraInfo()
    {
        m_HistoryPingPongRTHandle = new RTHandle[k_NumHistoryTextures];
    }

    public Matrix4x4 SetPreviousVPMatrix(Matrix4x4 curVPMatrix)
    {
        Matrix4x4 preVPMatrix = m_PreviousViewProjectionMatrix == Matrix4x4.zero ? curVPMatrix : m_PreviousViewProjectionMatrix;
        m_PreviousViewProjectionMatrix = curVPMatrix;
        return preVPMatrix;
    }

    public RTHandle GetHistoryRTHandle(int id)
    {
        return m_HistoryPingPongRTHandle[id];
    }

    public void SetHistoryRTHandle(int id, RTHandle rt)
    {
        m_HistoryPingPongRTHandle[id] = rt;
    }

    public void GetHistoryPingPongRT(ref RTHandle rt1, ref RTHandle rt2)
    {
        int index = m_PingPong;
        m_PingPong = ++m_PingPong % 2;

        rt1 = GetHistoryRTHandle(index);
        rt2 = GetHistoryRTHandle(m_PingPong);
    }

    public void Clear()
    {
        for (int i = 0; i < m_HistoryPingPongRTHandle.Length; i++)
        {
            if (m_HistoryPingPongRTHandle[i] != null)
                m_HistoryPingPongRTHandle[i].Release();
            m_HistoryPingPongRTHandle[i] = null;
        }
    }
}


