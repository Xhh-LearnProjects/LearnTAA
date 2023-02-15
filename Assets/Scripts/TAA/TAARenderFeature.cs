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
        [Tooltip("使用MotionVector (SceneView没有)")]
        public bool UseMotionVector;
        [Tooltip("ToneMapping减少闪烁,但是会降低一些高亮的溢出")]
        public bool UseToneMapping = false;


        [Tooltip("历史帧中静止像素混合比例")]
        [Range(0, 0.99f)]
        public float StationaryBlending = 0.95f;


        [Tooltip("历史帧中明显运动帧混合比例")]
        [Range(0, 0.99f)]
        public float MotionBlending = 0.7f;

        [Tooltip("降低闪烁")]
        [Range(0f, 1f)]
        // [HideInInspector]
        public float AntiFlicker = 0.5f;

        [Space(6)]
        [Header("High Quality")]
        [Tooltip("锐化做的比较轻微且只在HighQuality生效")]
        [Range(0f, 0.5f)]
        public float SharpenStrength = 0.15f;

        [Range(0f, 1f)]
        [HideInInspector]
        public float sharpenHistoryStrength = 0.35f;

        [Tooltip("锐化混合只在HighQuality生效")]
        [Range(0f, 1f)]
        [HideInInspector]
        public float SharpenBlend = 0.2f;

        [Tooltip("对历史帧做锐化只在HighQuality生效")]
        [HideInInspector]
        public bool UseBicubic = false;
    }

    public Settings settings;

    private TAAPass m_TAAPass;
    private TemporalAntialiasingCamera m_TAACameraPass;

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

        m_TAAPass.Setup(settings, m_MultiCameraInfo, m_Jitter, m_PreviousViewProjectionMatrix);
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


