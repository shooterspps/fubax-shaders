/** Tilt-Shift PS, version 2.0.1

This code © 2022 Jakub Maksymilian Fober

This work is licensed under the Creative Commons
Attribution-NonCommercial-NoDerivs 3.0 Unported License.
To view a copy of this license, visit
http://creativecommons.org/licenses/by-nc-nd/3.0/.

Copyright owner further grants permission for commercial reuse of
image recordings derived from the Work (e.g. let's play video,
gameplay stream with ReShade filters, screenshots with ReShade
filters) provided that any use is accompanied by the name of the
shader used and a link to ReShade website https://reshade.me.

If you need additional licensing for your commercial product, contact
me at jakub.m.fober@protonmail.com.
*/

	/* MACROS */

// Maximum number of samples for chromatic aberration
#define TILT_SHIFT_MAX_SAMPLES 128u
#define ITU_REC 601

	/* COMMONS */

#include "ReShade.fxh"
#include "ReShadeUI.fxh"
#include "ColorAndDither.fxh"

	/* MENU */

// Blur amount

uniform float4 K < __UNIFORM_DRAG_FLOAT4
	ui_min = -0.2; ui_max = 0.2;
	ui_label = "畸变曲线 'k'";
	ui_tooltip = "畸变系数 K1, K2, K3, K4";
	ui_category = "移轴摄影模糊";
> = float4(0.025, 0f, 0f, 0f);

uniform int BlurAngle < __UNIFORM_SLIDER_INT1
	ui_min = -90; ui_max = 90;
	ui_label = "倾斜角度";
	ui_tooltip = "倾斜模糊线.";
	ui_category = "移轴摄影模糊";
> = 0;

uniform float BlurOffset < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1f; ui_max = 1f; ui_step = 0.01;
	ui_label = "线条偏移";
	ui_tooltip = "偏移模糊中心线.";
	ui_category = "移轴摄影模糊";
> = 0f;

// Blur line

uniform bool VisibleLine < __UNIFORM_INPUT_BOOL1
	ui_label = "可视化中心线";
	ui_tooltip = "可视化模糊中心线.";
	ui_category = "模糊线";
	ui_category_closed = true;
> = false;

uniform uint BlurLineWidth < __UNIFORM_SLIDER_INT1
	ui_min = 2u; ui_max = 64u;
	ui_label = "可视化线宽";
	ui_tooltip = "倾斜位移线厚度像素单位.";
	ui_category = "模糊线";
> = 32u;

	/* TEXTURES */

// Define screen texture with mirror tiles
sampler BackBuffer
{
	Texture = ReShade::BackBufferTex;
#if BUFFER_COLOR_SPACE <= 2 && BUFFER_COLOR_BIT_DEPTH != 10 // linear workflow
	SRGBTexture = true;
#endif
	// Border style
	AddressU = MIRROR;
	AddressV = MIRROR;
};

	/* FUNCTIONS */

/* S curve by JMF
   Generates smooth bell falloff for blur.
   Preserves brightness.
   Input is in [0, 1] range. */
float bell_curve(float gradient)
{
	gradient = 1f-abs(gradient*2f-1f);
	float top = max(gradient, 0.5);
	float bottom = min(gradient, 0.5);
	return 4f*((bottom*bottom+top)-(top*top-top))-3f;
}
// Get coordinates rotation matrix
float2x2 get2dRotationMatrix(int angle)
{
	// Convert angle to radians
	float angleRad = radians(angle);
	// Get rotation components
	float rotSin = sin(angleRad), rotCos = cos(angleRad);
	// Generate rotated 2D axis as a 2x2 matrix
	return float2x2(
		 rotCos, rotSin, // Rotated space X axis
		-rotSin, rotCos  // Rotated space Y axis
	);
}
// Get blur radius
float getBlurRadius(float2 viewCoord)
{
	// Get rotation axis matrix
	const float2x2 rotationMtx = get2dRotationMatrix(BlurAngle);
	// Get offset vector
	float2 offsetDir = mul(rotationMtx, float2(0f, BlurOffset)); // Get rotated offset
	offsetDir.x *= -BUFFER_ASPECT_RATIO; // Scale offset to horizontal bounds
	// Offset and rotate coordinates
	viewCoord = mul(rotationMtx, viewCoord+offsetDir);
	// Get anisotropic radius
	float4 radius;
	radius[0] = viewCoord.y*viewCoord.y; // r²
	radius[1] = radius[0]*radius[0]; // r⁴
	radius[2] = radius[1]*radius[0]; // r⁶
	radius[3] = radius[2]*radius[0]; // r⁸
	// Get blur strength in Brown-Conrady lens distortion division model
	return abs(1f-rcp(dot(radius, K)+1f));
}

	/* SHADERS */

// Vertex shader generating a triangle covering the entire screen
void TiltShiftVS(
	in  uint   vertexId  : SV_VertexID,
	out float4 vertexPos : SV_Position,
	out float2 texCoord  : TEXCOORD0,
	out float2 viewCoord : TEXCOORD1)
{
	// Define vertex position
	const float2 vertexPosList[3] =
	{
		float2(-1f, 1f), // Top left
		float2(-1f,-3f), // Bottom left
		float2( 3f, 1f)  // Top right
	};
	// Export screen centered texture coordinates and vertex position,
	// correct aspect ratio of texture coordinates, normalize vertically
	viewCoord.x = (texCoord.x =   vertexPos.x = vertexPosList[vertexId].x)*BUFFER_ASPECT_RATIO;
	viewCoord.y =  texCoord.y = -(vertexPos.y = vertexPosList[vertexId].y);
	vertexPos.zw = float2(0f, 1f); // Export vertex position
	texCoord = texCoord*0.5+0.5; // Map to corner
}

// Horizontal dynamic blur pass
void TiltShiftPassHorizontalPS(
	in  float4 pixCoord  : SV_Position,
	in  float2 texCoord  : TEXCOORD0,
	in  float2 viewCoord : TEXCOORD1,
	out float3 color     : SV_Target)
{
	// Get blur radius
	float blurRadius = getBlurRadius(viewCoord);
	// Get blur pixel scale
	uint blurPixelCount = uint(ceil(blurRadius*BUFFER_HEIGHT));
	// Blur the background image
	if (blurPixelCount!=0u && any(K!=0f))
	{
		// Convert to even number and clamp to maximum sample count
		blurPixelCount = min(
			blurPixelCount+blurPixelCount%2u, // Convert to even
			TILT_SHIFT_MAX_SAMPLES-TILT_SHIFT_MAX_SAMPLES%2u // Convert to even
		);
		// Map blur horizontal radius to texture coordinates
		blurRadius *= BUFFER_HEIGHT*BUFFER_RCP_WIDTH; // Divide by aspect ratio
		float rcpWeightStep = rcp(blurPixelCount*2u);
		float rcpOffsetStep = rcp(blurPixelCount*2u-1u);
		color = 0f; // Initialize
		for (uint i=1u; i<blurPixelCount*2u; i+=2u)
		{
			// Get step weight
			float weight = bell_curve(i*rcpWeightStep);
			// Get step offset
			float offset = (i-1u)*rcpOffsetStep-0.5;
			color += tex2Dlod(
				BackBuffer,
				float4(blurRadius*offset+texCoord.x, texCoord.y, 0f, 0f) // Offset coordinates
			).rgb*weight;
		}
		// Restore brightness
		color /= blurPixelCount;
	}
	// Bypass blur
	else color = tex2Dfetch(BackBuffer, uint2(pixCoord.xy)).rgb;
	color = saturate(color); // Clamp values

#if BUFFER_COLOR_SPACE <= 2 && BUFFER_COLOR_BIT_DEPTH != 10 // Manual gamma
	color = to_display_gamma_hq(color);
#endif
	// Dither output to increase perceivable picture bit-depth
	color = BlueNoise::dither(uint2(pixCoord.xy), color);
}

// Vertical dynamic blur pass
void TiltShiftPassVerticalPS(
	in  float4 pixCoord  : SV_Position,
	in  float2 texCoord  : TEXCOORD0,
	in  float2 viewCoord : TEXCOORD1,
	out float3 color     : SV_Target)
{
	// Get blur radius
	float blurRadius = getBlurRadius(viewCoord);
	// Get blur pixel scale
	uint blurPixelCount = uint(ceil(blurRadius*BUFFER_HEIGHT));
	// Blur the background image
	if (blurPixelCount!=0u && any(K!=0f))
	{
		// Convert to even number and clamp to maximum sample count
		blurPixelCount = min(
			blurPixelCount+blurPixelCount%2u, // Convert to even
			TILT_SHIFT_MAX_SAMPLES-TILT_SHIFT_MAX_SAMPLES%2u // Convert to even
		);
		float rcpWeightStep = rcp(blurPixelCount*2u);
		float rcpOffsetStep = rcp(blurPixelCount*2u-1u);
		color = 0f; // Initialize
		for (uint i=1u; i<blurPixelCount*2u; i+=2u)
		{
			// Get step weight
			float weight = bell_curve(i*rcpWeightStep);
			// Get step offset
			float offset = (i-1u)*rcpOffsetStep-0.5;
			color += tex2Dlod(
				BackBuffer,
				float4(texCoord.x, blurRadius*offset+texCoord.y, 0f, 0f) // Offset coordinates
			).rgb*weight;
		}
		// Restore brightness
		color /= blurPixelCount;
	}
	// Bypass blur
	else color = tex2Dfetch(BackBuffer, uint2(pixCoord.xy)).rgb;
	color = saturate(color); // Clamp values

	// Draw tilt-shift line
	if (VisibleLine)
	{
		const float2x2 rotationMtx = get2dRotationMatrix(BlurAngle);
		// Get offset vector
		const float2 offsetDir = mul(
			float2x2(-rotationMtx[0]*BUFFER_ASPECT_RATIO, rotationMtx[1]), // Scale offset to horizontal bounds
			float2(0f, BlurOffset) // Blur offset as vertical vector
		);
		// Scale rotation matrix to pixel size
		const float2x2 pixelRoationMtx = rotationMtx*BUFFER_HEIGHT*0.5; // Since coordinates are normalized vertically

		// Offset and rotate coordinates
		viewCoord = mul(pixelRoationMtx, viewCoord+offsetDir);
		// Generate line mask
		float lineHorizontal = saturate(
			 BlurLineWidth*0.5 // Line thickness from center
			-abs(viewCoord.y)  // Horizontal line
		);

		// Add center line to the image with offset color by 180°
		float lineColor = abs(dot(LumaMtx, color)*2f-1f);
		color = lerp(
			color,
#if BUFFER_COLOR_SPACE <= 2 && BUFFER_COLOR_BIT_DEPTH != 10 // manual gamma
			to_linear_gamma_hq(lineColor),
#else
			lineColor,
#endif
			lineHorizontal
		);
	}

#if BUFFER_COLOR_SPACE <= 2 && BUFFER_COLOR_BIT_DEPTH != 10 // Manual gamma
	color = to_display_gamma_hq(color);
#endif
	// Dither output to increase perceivable picture bit-depth
	color = BlueNoise::dither(uint2(pixCoord.xy), color);
}

	/* OUTPUT */

technique TiltShift
<
	ui_label = "移轴摄影";
	ui_tooltip =
		"移轴摄影模糊特效.\n"
		"\n"
		"	· 每像素动态采样.\n"
		"	· 最小样本数.\n"
		"\n"
		"This effect © 2018-2022 Jakub Maksymilian Fober\n"
		"Licensed under CC BY-NC-ND 3.0 + additional permissions (see source).";
>
{
	pass GaussianBlurHorizontal
	{
		VertexShader = TiltShiftVS;
		PixelShader  = TiltShiftPassHorizontalPS;
	}
	pass GaussianBlurVerticalWithLine
	{
		VertexShader = TiltShiftVS;
		PixelShader  = TiltShiftPassVerticalPS;
	}
}
