using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering.HighDefinition;

/// <summary>
/// Manages a set of metaballs in the scene.
///
/// Setup:
///   1. Create a GameObject, attach this component.
///   2. Add a CustomPassVolume component to any scene object (mode = Global).
///      Add a MetaballCustomPass entry to it.
///   3. Assign the metaball material (using Hidden/MetaballRayMarch shader) here.
///   4. Add child GameObjects as ball transforms (or assign them manually).
///      Each ball's localScale.x is used as the radius.
///
/// The manager feeds ball world positions + radii to the shader and forwards
/// the main directional light data so the shader can shade correctly.
/// </summary>
[ExecuteAlways]
public class MetaballManager : MonoBehaviour
{
    [Header("Rendering")]
    [Tooltip("Material using the Hidden/MetaballRayMarch shader.")]
    public Material metaballMaterial;

    [Tooltip("The CustomPassVolume that holds the MetaballCustomPass.")]
    public CustomPassVolume customPassVolume;

    [Header("Balls  (Transform[] — position + scale.x = radius)")]
    public List<Transform> balls = new List<Transform>();

    [Header("Metaball Shape")]
    [Range(0.1f, 2f)]  public float threshold         = 1.0f;
    [Range(0f,   0.15f)] public float refractionStrength = 0.05f;
    [Range(1f,   8f)]  public float fresnelPower       = 4.0f;
    [Range(0f,   1f)]  public float smoothness         = 0.95f;
    public Color ballColor = new Color(0.9f, 0.6f, 0.1f, 1f);

    [Header("Ray March Quality")]
    [Range(16, 128)] public int  marchSteps    = 64;
    [Range(1f, 50f)] public float marchDistance = 20f;

    // Shader property IDs — cached for GC efficiency
    static readonly int ID_BallData            = Shader.PropertyToID("_BallData");
    static readonly int ID_BallCount           = Shader.PropertyToID("_BallCount");
    static readonly int ID_BallColor           = Shader.PropertyToID("_BallColor");
    static readonly int ID_Smoothness          = Shader.PropertyToID("_Smoothness");
    static readonly int ID_RefractionStrength  = Shader.PropertyToID("_RefractionStrength");
    static readonly int ID_FresnelPower        = Shader.PropertyToID("_FresnelPower");
    static readonly int ID_Threshold           = Shader.PropertyToID("_Threshold");
    static readonly int ID_MarchSteps          = Shader.PropertyToID("_MarchSteps");
    static readonly int ID_MarchDistance       = Shader.PropertyToID("_MarchDistance");
    static readonly int ID_LightDir            = Shader.PropertyToID("_MetaballLightDir");
    static readonly int ID_LightColor          = Shader.PropertyToID("_MetaballLightColor");
    static readonly int ID_Ambient             = Shader.PropertyToID("_MetaballAmbient");

    const int MAX_BALLS = 16;
    readonly Vector4[] _ballDataBuffer = new Vector4[MAX_BALLS];

    MetaballCustomPass _pass;

    void OnEnable()
    {
        FindOrCreateCustomPass();
    }

    void OnDisable()
    {
        if (_pass != null) _pass.enabled = false;
    }

    void Update()
    {
        if (metaballMaterial == null) return;

        // Wire material into the custom pass
        if (_pass != null)
            _pass.MetaballMaterial = metaballMaterial;

        UpdateBallData();
        UpdateLightData();
        UpdateMaterialKnobs();
    }

    // -------------------------------------------------------------------------

    void UpdateBallData()
    {
        int count = Mathf.Min(balls.Count, MAX_BALLS);
        for (int i = 0; i < count; i++)
        {
            if (balls[i] == null) continue;
            Vector3 pos = balls[i].position;
            float   rad = balls[i].lossyScale.x * 0.5f;
            _ballDataBuffer[i] = new Vector4(pos.x, pos.y, pos.z, rad);
        }
        // _BallData and _BallCount are global shader variables (not in UnityPerMaterial CBUFFER)
        // so they MUST be set via Shader.SetGlobal*, not material.Set*
        Shader.SetGlobalVectorArray(ID_BallData,  _ballDataBuffer);
        Shader.SetGlobalInt        (ID_BallCount, count);
    }

    void UpdateLightData()
    {
        Light sun = RenderSettings.sun;
        if (sun == null)
        {
            var lights = FindObjectsByType<Light>(FindObjectsSortMode.None);
            float bestIntensity = -1f;
            foreach (var l in lights)
            {
                if (l.type == LightType.Directional && l.intensity > bestIntensity)
                {
                    bestIntensity = l.intensity;
                    sun = l;
                }
            }
        }

        if (sun != null)
        {
            Vector3 dir   = -sun.transform.forward;
            Color   color = sun.color * sun.intensity;
            // Also global — same reason as ball data
            Shader.SetGlobalVector(ID_LightDir,   new Vector4(dir.x, dir.y, dir.z, 0));
            Shader.SetGlobalVector(ID_LightColor, new Vector4(color.r, color.g, color.b, 0));
        }

        Color amb = RenderSettings.ambientLight;
        Shader.SetGlobalVector(ID_Ambient, new Vector4(amb.r, amb.g, amb.b, 0));
    }

    void UpdateMaterialKnobs()
    {
        metaballMaterial.SetColor (ID_BallColor,           ballColor);
        metaballMaterial.SetFloat (ID_Smoothness,          smoothness);
        metaballMaterial.SetFloat (ID_RefractionStrength,  refractionStrength);
        metaballMaterial.SetFloat (ID_FresnelPower,        fresnelPower);
        metaballMaterial.SetFloat (ID_Threshold,           threshold);
        metaballMaterial.SetInt   (ID_MarchSteps,          marchSteps);
        metaballMaterial.SetFloat (ID_MarchDistance,       marchDistance);
    }

    void OnDrawGizmos()
    {
        // Shows exactly where the manager thinks each ball is + its radius.
        // Compare this with where the metaball appears on screen to diagnose offsets.
        Gizmos.color = new Color(1f, 0.5f, 0f, 0.4f);
        foreach (var t in balls)
        {
            if (t == null) continue;
            float radius = t.lossyScale.x * 0.5f;
            Gizmos.DrawWireSphere(t.position, radius);
        }
    }

    void FindOrCreateCustomPass()
    {
        if (customPassVolume == null)
        {
            // Try to find an existing volume in the scene
            customPassVolume = FindFirstObjectByType<CustomPassVolume>();
        }

        if (customPassVolume == null)
        {
            // Create one automatically
            var go = new GameObject("MetaballCustomPassVolume");
            customPassVolume = go.AddComponent<CustomPassVolume>();
            customPassVolume.isGlobal = true;
            Debug.Log("[MetaballManager] Created a new Global CustomPassVolume.");
        }

        // Find or add our pass
        _pass = null;
        foreach (var p in customPassVolume.customPasses)
        {
            if (p is MetaballCustomPass mp) { _pass = mp; break; }
        }

        // Injection point is a volume-level setting in HDRP
        customPassVolume.injectionPoint = CustomPassInjectionPoint.BeforeTransparent;

        if (_pass == null)
        {
            _pass = new MetaballCustomPass
            {
                name    = "Metaball Ray March",
                enabled = true
            };
            customPassVolume.customPasses.Add(_pass);
            Debug.Log("[MetaballManager] Added MetaballCustomPass to the volume.");
        }

        _pass.enabled = true;
    }
}
