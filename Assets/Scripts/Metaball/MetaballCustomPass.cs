using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.HighDefinition;

/// <summary>
/// HDRP Custom Pass that ray-marches the metaball SDF and composites the result
/// into the scene color + depth buffers before transparent objects are rendered.
///
/// Add a CustomPassVolume to any GameObject in the scene, set its mode to Global,
/// and add this pass to it. Then assign the metaball material in MetaballManager.
/// </summary>
public class MetaballCustomPass : CustomPass
{
    // Set by MetaballManager each frame before Execute() is called
    public Material MetaballMaterial;

    protected override void Setup(ScriptableRenderContext ctx, CommandBuffer cmd)
    {
        // Nothing to allocate — we reuse HDRP's color pyramid and depth buffers
    }

    protected override void Execute(CustomPassContext ctx)
    {
        if (MetaballMaterial == null) return;

        // Draw a fullscreen triangle using the ray march shader.
        // We write to BOTH the color AND depth buffer so the metaballs:
        //   - Are occluded by opaque objects in front of them
        //   - Occlude opaque objects behind them
        //   - Feed correct depth into SSAO, SSR, contact shadows, etc.
        HDUtils.DrawFullScreen(
            ctx.cmd,
            MetaballMaterial,
            ctx.cameraColorBuffer,
            ctx.cameraDepthBuffer,
            shaderPassId: 0);
    }

    protected override void Cleanup()
    {
        // No allocations to release
    }
}
