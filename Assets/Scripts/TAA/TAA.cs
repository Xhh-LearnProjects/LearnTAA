using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering;

public class TAAPass : ScriptableRenderPass
{
    ProfilingSampler m_ProfilingSampler;
    private Material m_Material;

    Dictionary<int, MultiCameraInfo> m_MultiCameraInfo;// = new Dictionary<int, MultiCameraInfo>();

    public TAAPass()
    {
        m_ProfilingSampler = new ProfilingSampler("TemporalAntialiasing");

    }

    void CheckHistoryRT(int id, int hash, CommandBuffer cmd, RTHandle source, RenderTextureDescriptor desc)
    {
        if (!m_MultiCameraInfo.ContainsKey(hash))
        {
            m_MultiCameraInfo[hash] = new MultiCameraInfo();
        }

        var rt = m_MultiCameraInfo[hash].GetHistoryRT(id);

        if (rt == null || rt.width != desc.width || rt.height != desc.height)
        {
            var newRT = RenderTexture.GetTemporary(desc);
            newRT.name = "_TemporalHistoryRT_" + id;

            // 分辨率改变时还是从上一个历史RT拷贝
            cmd.Blit(rt == null ? source : rt, newRT);

            if (rt != null)
                RenderTexture.ReleaseTemporary(rt);

            m_MultiCameraInfo[hash].SetHistoryRT(id, newRT);
        }
    }


    public void Setup(TAARenderFeature.Settings settings, Material material, Dictionary<int, MultiCameraInfo> multiCameraInfoMap)
    {
        m_Material = material;
        m_MultiCameraInfo = multiCameraInfoMap;
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        if (m_Material == null)
            return;

        var cmd = CommandBufferPool.Get();

        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;

            // RenderingUtils.ReAllocateIfNeeded(ref m_Target, renderingData.cameraData.cameraTargetDescriptor, FilterMode.Point, wrapMode: TextureWrapMode.Clamp, name: "_TAATexture");

            Camera camera = renderingData.cameraData.camera;

            //准备历史RT
            int hash = camera.GetHashCode();
            var source = renderingData.cameraData.renderer.cameraColorTargetHandle;
            CheckHistoryRT(0, hash, cmd, source, desc);
            CheckHistoryRT(1, hash, cmd, source, desc);

            RenderTexture rt1 = null, rt2 = null;
            m_MultiCameraInfo[hash].GetHistoryPingPongRT(ref rt1, ref rt2);
            cmd.SetGlobalTexture("_HistoryTexture", rt1);

            // Blit(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_Target, m_Material);
            Blit(cmd, ref renderingData, m_Material);
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }
}
