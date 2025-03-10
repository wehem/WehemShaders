/*=============================================================================
    TFAA (2.0)
    Temporal Filter Anti-Aliasing Shader
    First published 2025 - Copyright, Jakob Wapenhensch
    License: CC BY-NC 4.0 (https://creativecommons.org/licenses/by-nc/4.0/)
    https://creativecommons.org/licenses/by-nc/4.0/legalcode
=============================================================================*/

#include "ReShadeUI.fxh"
#include "ReShade.fxh"

/*=============================================================================
    Preprocessor Settings
=============================================================================*/

// Uniform variable to access the frame time.
uniform float frametime < source = "frametime"; >;

// Constant for temporal weights adjustment based on a 48 FPS baseline.
static const float fpsConst = (1000.0 / 48.0);
// Precomputed Poisson Disk samples (32 samples in 2D)
static const float2 poissonSamples[32] = {
    float2(0.5000, 0.5000), float2(0.2500, 0.2500), float2(0.7500, 0.2500),
    float2(0.2500, 0.7500), float2(0.7500, 0.7500), float2(0.1250, 0.1250),
    float2(0.3750, 0.1250), float2(0.6250, 0.1250), float2(0.8750, 0.1250),
    float2(0.1250, 0.3750), float2(0.3750, 0.3750), float2(0.6250, 0.3750),
    float2(0.8750, 0.3750), float2(0.1250, 0.6250), float2(0.3750, 0.6250),
    float2(0.6250, 0.6250), float2(0.3750, 0.8750), float2(0.6250, 0.8750),
    float2(0.1250, 0.8750), float2(0.8750, 0.6250), float2(0.4375, 0.1875),
    float2(0.5625, 0.3125), float2(0.3125, 0.4375), float2(0.6875, 0.5625),
    float2(0.1875, 0.6875), float2(0.8125, 0.8125), float2(0.0625, 0.5625),
    float2(0.9375, 0.4375), float2(0.4375, 0.9375), float2(0.5625, 0.0625),
    float2(0.21875, 0.28125), float2(0.78125, 0.71875)
};


/*=============================================================================
    UI Uniforms
=============================================================================*/

/**
 * @brief Slider controlling the strength of the temporal filter.
 */
uniform float UI_TEMPORAL_FILTER_STRENGTH <
    ui_type    = "slider";
    ui_min     = 0.0; 
    ui_max     = 1.0; 
    ui_step    = 0.01;
    ui_label   = "Temporal Filter Strength";
    ui_category= "Temporal Filter";
    ui_tooltip = "";
> = 0.5;

/**
 * @brief Slider controlling the amount of adaptive sharpening.
 */
uniform float UI_POST_SHARPEN <
    ui_type    = "slider";
    ui_min     = 0.0; 
    ui_max     = 1.0; 
    ui_step    = 0.01;
    ui_label   = "Adaptive Sharpening";
    ui_category= "Temporal Filter";
    ui_tooltip = "";
> = 0.5;

uniform float UI_JITTER_STRENGTH  <
    ui_type    = "slider";
    ui_min     = 0.0; 
    ui_max     = 1.0; 
    ui_step    = 0.01;
    ui_label   = "Jitter Strength";
    ui_category= "Temporal Filter";
    ui_tooltip = "Controls the intensity of sub-pixel jittering (0.25 = original strength)";
> = 0.25;

uniform int UI_JITTER_PATTERN  <
    ui_type    = "combo";
    ui_items   = "Sobol Sequence\0Grid Aligned\0Random\0Halton Sequence\0Poisson Disk\0";
    ui_label   = "Jitter Pattern";
    ui_category= "Temporal Filter";
    ui_tooltip = "Selects jittering algorithm (Sobol/Halton/Poisson recommended)";
> = 0;

/*=============================================================================
    Textures & Samplers
=============================================================================*/

// Texture and sampler for depth input.
texture texDepthIn : DEPTH;
sampler smpDepthIn { 
    Texture = texDepthIn; 
};

// Texture and sampler for the current frame's color.
texture texInCur : COLOR;
sampler smpInCur { 
    Texture   = texInCur; 
    AddressU  = Clamp; 
    AddressV  = Clamp; 
    MipFilter = Linear; 
    MinFilter = Linear; 
    MagFilter = Linear; 
};

// Backup texture for the current frame's color.
texture texInCurBackup < pooled = true; > { 
    Width   = BUFFER_WIDTH; 
    Height  = BUFFER_HEIGHT; 
    Format  = RGBA8; 
};

sampler smpInCurBackup { 
    Texture   = texInCurBackup; 
    AddressU  = Clamp; 
    AddressV  = Clamp; 
    MipFilter = Linear; 
    MinFilter = Linear; 
    MagFilter = Linear; 
};

// Texture for storing the exponential frame buffer.
texture texExpColor < pooled = true; > { 
    Width   = BUFFER_WIDTH; 
    Height  = BUFFER_HEIGHT; 
    Format  = RGBA16F; 
};

sampler smpExpColor { 
    Texture   = texExpColor; 
    AddressU  = Clamp; 
    AddressV  = Clamp; 
    MipFilter = Linear; 
    MinFilter = Linear; 
    MagFilter = Linear; 
};

// Backup texture for the exponential frame buffer.
texture texExpColorBackup < pooled = true; > { 
    Width   = BUFFER_WIDTH; 
    Height  = BUFFER_HEIGHT; 
    Format  = RGBA16F; 
};

sampler smpExpColorBackup { 
    Texture   = texExpColorBackup; 
    AddressU  = Clamp; 
    AddressV  = Clamp; 
    MipFilter = Linear; 
    MinFilter = Linear; 
    MagFilter = Linear; 
};

// Backup texture for the last frame's depth.
texture texDepthBackup < pooled = true; > { 
    Width   = BUFFER_WIDTH; 
    Height  = BUFFER_HEIGHT; 
    Format  = R16f; 
};

sampler smpDepthBackup { 
    Texture   = texDepthBackup; 
    AddressU  = Clamp; 
    AddressV  = Clamp; 
    MipFilter = Point; 
    MinFilter = Point; 
    MagFilter = Point; 
};

/*=============================================================================
    Functions
=============================================================================*/

/**
 * @brief Samples a texture at a specified UV coordinate and mip level.
 *
 * @param s     Sampler reference of the texture.
 * @param uv    UV coordinate in texture space.
 * @param mip   Mip level to sample.
 * @return      The texture sample as a float4.
 */
float4 tex2Dlod(sampler s, float2 uv, float mip)
{
    return tex2Dlod(s, float4(uv, 0, mip));
}

/**
 * @brief Converts an RGB color to the YCbCr color space.
 *
 * @param rgb   Input RGB color.
 * @return      Corresponding color in YCbCr space (float3).
 */
float3 cvtRgb2YCbCr(float3 rgb)
{
    float y  = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
    float cb = (rgb.b - y) * 0.565;
    float cr = (rgb.r - y) * 0.713;

    return float3(y, cb, cr);
}

/**
 * @brief Converts a YCbCr color to RGB color space.
 *
 * @param YCbCr Input color in YCbCr format.
 * @return      Converted RGB color (float3).
 */
float3 cvtYCbCr2Rgb(float3 YCbCr)
{
    return float3(
        YCbCr.x + 1.403 * YCbCr.z,
        YCbCr.x - 0.344 * YCbCr.y - 0.714 * YCbCr.z,
        YCbCr.x + 1.770 * YCbCr.y
    );
}

/**
 * @brief Wrapper function converting RGB to an intermediate color space.
 *
 * Acts as a pass-through to cvtRgb2YCbCr.
 *
 * @param rgb   Input RGB color.
 * @return      Converted color in the intermediate space ("whatever" space).
 */
float3 cvtRgb2whatever(float3 rgb)
{
    return cvtRgb2YCbCr(rgb);
}

/**
 * @brief Wrapper function converting the intermediate color space to RGB.
 *
 * Acts as a pass-through to cvtYCbCr2Rgb.
 *
 * @param whatever Input color in the intermediate ("whatever") space.
 * @return         Converted RGB color.
 */
float3 cvtWhatever2Rgb(float3 whatever)
{
    return cvtYCbCr2Rgb(whatever);
}

/**
 * @brief Performs bicubic interpolation using 5 sample points.
 *
 * Inspired by techniques from Marty, this function computes the filtered
 * value by calculating sample weights and positions.
 *
 * @param source    Sampler reference of the texture.
 * @param texcoord  Texture coordinate to be sampled.
 * @return          Interpolated color as float4.
 */
float4 bicubic_5(sampler source, float2 texcoord)
{
    // Compute the texture size.
    float2 texsize = tex2Dsize(source);

    // Convert texture coordinate to texel space.
    float2 UV = texcoord * texsize;

    // Determine the center of the texel grid.
    float2 tc = floor(UV - 0.5) + 0.5;

    // Compute the fractional part for weighting.
    float2 f = UV - tc;

    // Calculate powers of f needed for weight computation.
    float2 f2 = f * f;
    float2 f3 = f2 * f;

    // Compute weights for the neighboring texels.
    float2 w0 = f2 - 0.5 * (f3 + f);
    float2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    float2 w3 = 0.5 * (f3 - f2);
    float2 w12 = 1.0 - w0 - w3;

    // Store sample weights and corresponding sample position offsets.
    float4 ws[3];
    ws[0].xy = w0;
    ws[1].xy = w12;
    ws[2].xy = w3;

    // Calculate sample positions in texel space.
    ws[0].zw = tc - 1.0;
    ws[1].zw = tc + 1.0 - w1 / w12;
    ws[2].zw = tc + 2.0;

    // Normalize the sample offsets to texture coordinate space.
    ws[0].zw /= texsize;
    ws[1].zw /= texsize;
    ws[2].zw /= texsize;

    // Combine neighboring samples weighted by the computed factors.
    float4 ret;
    ret  = tex2Dlod(source, float2(ws[1].z, ws[0].w), 0) * ws[1].x * ws[0].y;
    ret += tex2Dlod(source, float2(ws[0].z, ws[1].w), 0) * ws[0].x * ws[1].y;
    ret += tex2Dlod(source, float2(ws[1].z, ws[1].w), 0) * ws[1].x * ws[1].y;
    ret += tex2Dlod(source, float2(ws[2].z, ws[1].w), 0) * ws[2].x * ws[1].y;
    ret += tex2Dlod(source, float2(ws[1].z, ws[2].w), 0) * ws[1].x * ws[2].y;
    
    // Normalize the result.
    float normfact = 1.0 / (1.0 - (f.x - f2.x) * (f.y - f2.y) * 0.25);
    return max(0, ret * normfact);
}

/**
 * @brief Samples historical frame data using bicubic interpolation.
 *
 * Wraps the bicubic interpolation method to retrieve a filtered history value.
 *
 * @param historySampler Sampler for the history texture.
 * @param texcoord       Texture coordinate.
 * @return               Filtered historical sample as a float4.
 */
float4 sampleHistory(sampler2D historySampler, float2 texcoord)
{
    return bicubic_5(historySampler, texcoord);
}

/**
 * @brief Retrieves and linearizes the depth value from the depth texture.
 *
 * Converts the non-linear depth sample into a linear depth value and handles
 * reversed depth input when enabled.
 *
 * @param texcoord Texture coordinate.
 * @return         Linearized depth value.
 */
float getDepth(float2 texcoord)
{
    // Sample raw depth.
    float depth = tex2Dlod(smpDepthIn, texcoord, 0).x;

    #if RESHADE_DEPTH_INPUT_IS_REVERSED
        // Adjust for reversed depth if required.
        depth = 1.0 - depth;
    #endif

    // Define a near plane constant.
    const float N = 1.0;

    // Linearize depth based on the far plane parameter.
    depth /= RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - depth * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - N);

    return depth;
}

uniform uint frameCount < source = "framecount"; >;

float Halton(uint index, uint base) {
    float result = 0.0;
    float f = 1.0 / base;
    for (uint i = 0; i < 8; i++) {
        if (index == 0) break;
        result += f * (index % base);
        index /= base;
        f /= base;
    }
    return result;
}

float2 GenerateJitter(uint x, uint y, uint frame) {
    if (UI_JITTER_PATTERN == 1) { // Grid Aligned
        return float2(0.0, 0.0);
    }
    if (UI_JITTER_PATTERN == 2) { // Random
        uint seed = x ^ y + frame;
        float jitter = frac(sin(seed) * 43758.5453);
        return float2(jitter, 1.0 - jitter) * UI_JITTER_STRENGTH * ReShade::PixelSize;
    }
    if (UI_JITTER_PATTERN == 3) { // Halton
        uint pixelIndex = x ^ y;
        float x_jitter = Halton(pixelIndex + frame, 2);
        float y_jitter = Halton(pixelIndex + frame, 3);
        return float2(x_jitter, y_jitter) * UI_JITTER_STRENGTH * ReShade::PixelSize;
    }
    if (UI_JITTER_PATTERN == 4) { // Poisson Disk
        uint seed = x * 16807 + y * 331u + frame * 1122334455u;
        uint sampleIndex = (seed % 32); // 32 samples
        
        // Adaptive rotation based on pixel hash
        float hash = frac(sin(seed) * 43758.5453);
        float angle = 6.2831853 * hash; // Full 0-2π rotation
        
        float s = sin(angle), c = cos(angle);
        float2 rotated = float2(
            poissonSamples[sampleIndex].x * c - poissonSamples[sampleIndex].y * s,
            poissonSamples[sampleIndex].x * s + poissonSamples[sampleIndex].y * c
        );
        
        return rotated * UI_JITTER_STRENGTH * ReShade::PixelSize;
    }
    
    // Default Sobol sequence
    uint seed = x ^ y;
    frame = frame % 1024;
    uint bits = frame * (seed | 1);
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    float jitter = float(bits) / 4294967295.0;
    return float2(jitter, 1.0 - jitter) * UI_JITTER_STRENGTH * ReShade::PixelSize;
}


/*=============================================================================
    Motion Vector Imports
=============================================================================*/

namespace Deferred 
{
    // Texture storing motion vectors (RGBA16F).
    // XY: Delta UV; Z: Confidence; W: Depth.
    texture MotionVectorsTex { 
        Width  = BUFFER_WIDTH; 
        Height = BUFFER_HEIGHT; 
        Format = RG16F;
    };
    sampler sMotionVectorsTex { 
        Texture = MotionVectorsTex; 
    };

    /**
     * @brief Retrieves the motion vector at a given texture coordinate.
     *
     * @param uv Texture coordinate.
     * @return   Motion vector as a float2.
     */
    float2 get_motion(float2 uv)
    {
        return tex2Dlod(sMotionVectorsTex, uv, 0).xy;
    }
}


/*=============================================================================
    Shader Pass Functions
=============================================================================*/

/**
 * @brief Saves the current frame's color and depth into a backup texture.
 *
 * Samples the scene's color and computes the linearized depth for use in
 * later temporal filtering passes.
 *
 * @param position Unused screen-space position.
 * @param texcoord Texture coordinate.
 * @return         Color from the current frame with depth stored in the alpha channel.
 */
float4 SaveCur(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target0
{
    // Retrieve and linearize depth.
    float depthOnly = getDepth(texcoord);

    // Sample current frame color and pack depth into alpha channel.
    return float4(tex2Dlod(smpInCur, texcoord, 0).rgb, depthOnly);
}

/**
 * @brief Applies the temporal filter for anti-aliasing.
 *
 * Blends the current frame with historical data based on motion vectors,
 * local contrast, and depth continuity. This minimizes aliasing artifacts
 * while also applying adaptive sharpening.
 *
 * Steps:
 *   1. Sample the current frame's color and convert to an intermediate color space.
 *   2. Gather a 3x3 neighborhood (with defined offsets) to compute local contrast bounds.
 *   3. Retrieve the motion vector of the center pixel and compute the last sample position.
 *   4. Sample historical data (both color and depth) from previous frames.
 *   5. Calculate various factors: FPS correction, local contrast, motion speed, and disocclusion.
 *   6. Compute a blending weight using UI parameters and these factors.
 *   7. Clamp the historical sample within neighborhood bounds.
 *   8. Blend current and historical colors and apply an adaptive sharpening term.
 *
 * @param position Unused screen-space position.

 * @param texcoord Texture coordinate.
 * @return         Processed color after temporal filtering.
 */
float4 TemporalFilter(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target {
    uint2 pixelCoord = uint2(texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
    float2 sobolJitter = GenerateJitter(pixelCoord.x, pixelCoord.y, frameCount);
    float2 jitteredTexCoord = texcoord + sobolJitter;

    float4 sampleCur = tex2Dlod(smpInCurBackup, jitteredTexCoord, 0);
    float4 cvtColorCur = float4(cvtRgb2whatever(sampleCur.rgb), sampleCur.a);

    static const float2 nOffsets[9] = { 
        float2(-0.7,-0.7), float2(0, 1), float2(0.7, 0.7), 
        float2(-1, 0),     float2(0, 0), float2(1, 0), 
        float2(-0.7, 0.7), float2(0, -1), float2(0.7, 0.7) 
    };

    float4 neighborhood[9];
    int closestDepthIndex = 4;
    float4 minimumCvt = 2;
    float4 maximumCvt = -1;

    for (int i = 0; i < 9; i++) {
        neighborhood[i] = tex2Dlod(smpInCurBackup, jitteredTexCoord + (nOffsets[i] * ReShade::PixelSize), 0);
        float4 cvt = float4(cvtRgb2whatever(neighborhood[i].rgb), neighborhood[i].a);
        minimumCvt = min(minimumCvt, cvt);
        maximumCvt = max(maximumCvt, cvt);
    }

    float2 motion = Deferred::get_motion(jitteredTexCoord + (nOffsets[closestDepthIndex] * ReShade::PixelSize));
    float2 lastSamplePos = jitteredTexCoord + motion;

    float lastDepth = tex2Dlod(smpDepthBackup, lastSamplePos, 0).r;
    float4 sampleExp = saturate(sampleHistory(smpExpColorBackup, lastSamplePos));

    float fpsFix = frametime / fpsConst;
    float localContrast = saturate(pow(abs(maximumCvt.r - minimumCvt.r), 0.75));
    float speed = length(motion);
    float speedFactor = 1.0 - pow(saturate(speed * 20.0), 0.5);
    float depthDelta = max(0, saturate(minimumCvt.a - lastDepth)) / sampleCur.a;
    float depthMask = saturate(1.0 - pow(depthDelta * 4, 4));

    float weight = lerp(0.50, 0.99, UI_TEMPORAL_FILTER_STRENGTH);
    weight = lerp(weight, weight * (0.6 + localContrast * 2), 0.5);
    weight = clamp(weight * speedFactor * depthMask, 0.0, 0.95);

    float4 sampleExpClamped = float4(cvtWhatever2Rgb(clamp(cvtRgb2whatever(sampleExp.rgb), minimumCvt.rgb, maximumCvt.rgb)), sampleExp.a);
    const static float correctionFactor = 2;
    float3 blendedColor = saturate(pow(lerp(pow(sampleCur.rgb, correctionFactor), pow(sampleExpClamped.rgb, correctionFactor), weight), (1.0 / correctionFactor)));

    float sharp = (0.01 + localContrast) * (pow(speed, 0.3)) * 32;
    sharp = saturate(((sharp + sampleExpClamped.a) * 0.5) * depthMask * UI_POST_SHARPEN * UI_TEMPORAL_FILTER_STRENGTH);

    return float4(blendedColor, sharp);
}

/**
 * @brief Saves the post-processed exponential color and depth for history.
 *
 * This pass stores the final exponential color buffer and the corresponding
 * linearized depth value for usage in subsequent frames.
 *
 * @param position    Unused screen-space position.
 * @param texcoord    Texture coordinate.
 * @param lastExpOut  Output exponential color buffer.
 * @param depthOnly   Output linearized depth.
 */
void SavePost(float4 position : SV_Position, float2 texcoord : TEXCOORD, out float4 lastExpOut : SV_Target0, out float depthOnly : SV_Target1)
{
    // Store the current exponential color.
    lastExpOut = tex2Dlod(smpExpColor, texcoord, 0);

    // Store the corresponding linearized depth.
    depthOnly = getDepth(texcoord);
}

/**
 * @brief Final output pass that applies adaptive sharpening.
 *
 * Applies adaptive sharpening to the final image.
 *
 * @param position Unused screen-space position.
 * @param texcoord Texture coordinate.
 * @return         The final processed color with sharpening applied.
 */
float4 Out(float4 position : SV_Position, float2 texcoord : TEXCOORD ) : SV_Target
{
    // ---------- Sample Center and Neighboring Pixels ----------
    float4 center     = tex2Dlod(smpExpColor, texcoord, 0);
    float4 top        = tex2Dlod(smpExpColor, texcoord + (float2(0, -1) * ReShade::PixelSize), 0);
    float4 bottom     = tex2Dlod(smpExpColor, texcoord + (float2(0,  1) * ReShade::PixelSize), 0);
    float4 left       = tex2Dlod(smpExpColor, texcoord + (float2(-1, 0) * ReShade::PixelSize), 0);
    float4 right      = tex2Dlod(smpExpColor, texcoord + (float2(1,  0) * ReShade::PixelSize), 0);
    float4 topLeft    = tex2Dlod(smpExpColor, texcoord + (float2(-0.7, -0.7) * ReShade::PixelSize), 0);
    float4 topRight   = tex2Dlod(smpExpColor, texcoord + (float2(0.7,  -0.7) * ReShade::PixelSize), 0);
    float4 bottomLeft = tex2Dlod(smpExpColor, texcoord + (float2(-0.7,  0.7) * ReShade::PixelSize), 0);
    float4 bottomRight= tex2Dlod(smpExpColor, texcoord + (float2(0.7,   0.7) * ReShade::PixelSize), 0);

    // Find the maximum and minimum among the sampled neighbors.
    float4 maxBox = max(
                      max(top,    max(bottom, max(left, max(right, center)))),
                      max(topLeft, max(topRight, max(bottomLeft, bottomRight)))
                    );
    float4 minBox = min(
                      min(top,    min(bottom, min(left, min(right, center)))),
                      min(topLeft, min(topRight, min(bottomLeft, bottomRight)))
                    );

    // Fixed contrast value (tuned for high temporal blur scenarios).
    float contrast   = 0.9;
    float sharpAmount= saturate(maxBox.a);  // Sharpness factor based on alpha (as a proxy for weight).

    // Calculate cross weights similarly to AMD CAS.
    float4 crossWeight = -rcp(rsqrt(saturate(min(minBox, 1.0 - maxBox) * rcp(maxBox))) *
                              (-3.0 * contrast + 8.0));

    // Compute reciprocal weight factor based on the sum of the cross weights.
    float4 rcpWeight = rcp(4.0 * crossWeight + 1.0);
    
    // Sum the direct neighbors (top, bottom, left, right).
    float4 crossSumm = top + bottom + left + right;
    
    // Combine center pixel with weighted neighbors.
    return lerp(center, saturate((crossSumm * crossWeight + center) * rcpWeight), sharpAmount);

}


/*=============================================================================
    Shader Technique: TFAA
=============================================================================*/

/**
 * @brief Temporal Filter Anti-Aliasing Technique.
 *
 * The technique is composed of the following passes:
 *   - PassSavePre: Saves the current frame's color and depth.
 *   - PassTemporalFilter: Applies temporal filtering using history and motion vectors.
 *   - PassSavePost: Stores the exponential color buffer and depth for history.
 *   - PassShow: Outputs the final image with adaptive sharpening.
 */
technique TFAA
<
    ui_label = "TFAA";
    ui_tooltip = "- Temporal Filter Anti-Aliasing -\nTemporal component of TAA to be used with (after) spatial anti-aliasing techniques.\nRequires motion vectors to be available (LAUNCHPAD.fx).";
>
{
    pass PassSavePre
    {
        VertexShader   = PostProcessVS;
        PixelShader    = SaveCur;
        RenderTarget   = texInCurBackup;
    }

    pass PassTemporalFilter
    {
        VertexShader   = PostProcessVS;
        PixelShader    = TemporalFilter;
        RenderTarget   = texExpColor;
    }

    pass PassSavePost
    {
        VertexShader   = PostProcessVS;
        PixelShader    = SavePost;
        RenderTarget0  = texExpColorBackup;
        RenderTarget1  = texDepthBackup;
    }

    pass PassShow
    {
        VertexShader   = PostProcessVS;
        PixelShader    = Out;
    }
}
