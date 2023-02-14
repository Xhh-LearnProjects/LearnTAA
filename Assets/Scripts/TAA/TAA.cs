using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering;

public class TAAPass : ScriptableRenderPass
{
    ProfilingSampler m_ProfilingSampler;
    private Material m_Material;

    public TAAPass()
    {
        m_ProfilingSampler = new ProfilingSampler("TemporalAntialiasing");

    }

    public void Setup(TAARenderFeature.Settings settings, Material material)
    {
        m_Material = material;
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        var cmd = CommandBufferPool.Get();

        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            Camera camera = renderingData.cameraData.camera;

            Blit(cmd, ref renderingData, m_Material);
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }
}
