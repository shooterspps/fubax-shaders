/*
Filmic Anamorph Sharpen PS v1.4.7 (c) 2018 Jakub Maximilian Fober
Some changes by ccritchfield https://github.com/ccritchfield

This work is licensed under the Creative Commons
Attribution-ShareAlike 4.0 International License.
To view a copy of this license, visit
http://creativecommons.org/licenses/by-sa/4.0/.
*/


  ////////////
 /// MENU ///
////////////

#include "ReShadeUI.fxh"

uniform float Strength < __UNIFORM_SLIDER_FLOAT1
	ui_label = "强度";
	ui_min = 0.0; ui_max = 100.0; ui_step = 0.01;
> = 60.0;

uniform float Offset < __UNIFORM_SLIDER_FLOAT1
	ui_label = "半径";
	ui_tooltip = "高通交叉偏移像素";
	ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.1;

uniform float Clamp < __UNIFORM_SLIDER_FLOAT1
	ui_label = "钳位";
	ui_min = 0.5; ui_max = 1.0; ui_step = 0.001;
> = 0.65;

uniform bool UseMask < __UNIFORM_INPUT_BOOL1
	ui_label = "只锐化中心";
	ui_tooltip = "只锐化图像的中心";
> = false;

uniform bool DepthMask < __UNIFORM_INPUT_BOOL1
	ui_label = "启用深度边缘屏蔽";
	ui_tooltip = "深度高通掩模开关";
	ui_category = "深度遮罩";
	ui_category_closed = true;
> = false;

uniform int DepthMaskContrast < __UNIFORM_DRAG_INT1
	ui_label = "掩模边缘强度";
	ui_tooltip = "深度高通掩模量";
	ui_category = "深度遮罩";
	ui_min = 0; ui_max = 2000; ui_step = 1;
> = 128;

uniform int Coefficient < __UNIFORM_RADIO_INT1
	ui_tooltip = "用于数字视频信号使用BT.709, 对于模拟信号(如VGA)使用BT.601";
	ui_label = "YUV 系数";
	ui_items = "BT.709 - 数字视频信号\0BT.601 - 模拟信号\0";
	ui_category = "附加设置";
	ui_category_closed = true;
> = 0;

uniform bool Preview < __UNIFORM_INPUT_BOOL1
	ui_label = "预览锐化层";
	ui_tooltip = "预览锐化层和蒙版进行调整.\n"
		"你看不见红色的笔画,\n"
		"尝试在设置选项卡中更改预处理器定义.";
	ui_category = "调试视图";
	ui_category_closed = true;
> = false;

  ////////////////
 /// TEXTURES ///
////////////////

#include "ReShade.fxh"

// Define screen texture with mirror tiles
sampler BackBuffer
{
	Texture = ReShade::BackBufferTex;
	AddressU = MIRROR;
	AddressV = MIRROR;
	#if BUFFER_COLOR_BIT_DEPTH != 10
		SRGBTexture = true;
	#endif
};

  /////////////////
 /// FUNCTIONS ///
/////////////////

// RGB to YUV709 Luma
static const float3 Luma709 = float3(0.2126, 0.7152, 0.0722);
// RGB to YUV601 Luma
static const float3 Luma601 = float3(0.299, 0.587, 0.114);

// Overlay blending mode
float Overlay(float LayerA, float LayerB)
{
	float MinA = min(LayerA, 0.5);
	float MinB = min(LayerB, 0.5);
	float MaxA = max(LayerA, 0.5);
	float MaxB = max(LayerB, 0.5);
	return 2.0 * (MinA * MinB + MaxA + MaxB - MaxA * MaxB) - 1.5;
}

// Overlay blending mode for one input
float Overlay(float LayerAB)
{
	float MinAB = min(LayerAB, 0.5);
	float MaxAB = max(LayerAB, 0.5);
	return 2.0 * (MinAB * MinAB + MaxAB + MaxAB - MaxAB * MaxAB) - 1.5;
}

// Convert to linear gamma
float gamma(float grad) { return pow(abs(grad), 2.2); }
float3 gamma(float3 grad) { return pow(abs(grad), 2.2); }

  //////////////
 /// SHADER ///
//////////////

// Sharpen pass
float3 FilmicAnamorphSharpenPS(float4 pos : SV_Position, float2 UvCoord : TEXCOORD) : SV_Target
{
	// Sample display image
	float3 Source = tex2D(BackBuffer, UvCoord).rgb;

	// Generate radial mask
	float Mask;
	if (UseMask)
	{
		// Generate radial mask
		Mask = 1.0-length(UvCoord*2.0-1.0);
		Mask = Overlay(Mask) * Strength;
		// Bypass
		if (Mask <= 0) return Source;
	}
	else Mask = Strength;

	// Get pixel size
	float2 Pixel = BUFFER_PIXEL_SIZE;
	// Choose luma coefficient, if False BT.709 luma, else BT.601 luma
	const float3 LumaCoefficient = bool(Coefficient) ? Luma601 : Luma709;

	if (DepthMask)
	{
		/*
		// original
		float2 DepthPixel = Pixel*Offset + Pixel;
		Pixel *= Offset;
		*/

		// !!! calc pixel*offset once, use twice
		float2 PixelOffset = Pixel * Offset;
		float2 DepthPixel = PixelOffset + Pixel;
		Pixel = PixelOffset;

		// Sample display depth image
		float SourceDepth = ReShade::GetLinearizedDepth(UvCoord);

		float2 NorSouWesEst[4] = {
			float2(UvCoord.x, UvCoord.y + Pixel.y),
			float2(UvCoord.x, UvCoord.y - Pixel.y),
			float2(UvCoord.x + Pixel.x, UvCoord.y),
			float2(UvCoord.x - Pixel.x, UvCoord.y)
		};

		float2 DepthNorSouWesEst[4] = {
			float2(UvCoord.x, UvCoord.y + DepthPixel.y),
			float2(UvCoord.x, UvCoord.y - DepthPixel.y),
			float2(UvCoord.x + DepthPixel.x, UvCoord.y),
			float2(UvCoord.x - DepthPixel.x, UvCoord.y)
		};

		// Luma high-pass color
		// Luma high-pass depth
		float HighPassColor = 0.0, DepthMask = 0.0;

		[unroll]for(int s = 0; s < 4; s++)
		{
			HighPassColor += dot(tex2D(BackBuffer, NorSouWesEst[s]).rgb, LumaCoefficient);
			DepthMask += ReShade::GetLinearizedDepth(NorSouWesEst[s])
			+ ReShade::GetLinearizedDepth(DepthNorSouWesEst[s]);
		}

		HighPassColor = 0.5 - 0.5 * (HighPassColor * 0.25 - dot(Source, LumaCoefficient));

		DepthMask = 1.0 - DepthMask * 0.125 + SourceDepth;
		DepthMask = min(1.0, DepthMask) + 1.0 - max(1.0, DepthMask);
		DepthMask = saturate(DepthMaskContrast * DepthMask + 1.0 - DepthMaskContrast);

		// Sharpen strength
		HighPassColor = lerp(0.5, HighPassColor, Mask * DepthMask);

		// Clamping sharpen
		/*
		// original
		HighPassColor = (Clamp != 1.0) ? max(min(HighPassColor, Clamp), 1.0 - Clamp) : HighPassColor;
		*/

		// !!! Clamp in settings above is restricted to 0.5 to 1.0
		// !!! 1.0 - Clamp is the low value, while Clamp is the high value
		// !!! so we can literally just use the clamp() func instead of min/max.
		// !!! not sure if author was trying to take advantage of some kind of
		// !!! compiler "cheat" using min/max instead of clamp to improve
		// !!! performance. doesn't make sense to min/max otherwise.
		HighPassColor = (Clamp != 1.0) ? clamp( HighPassColor, 1.0 - Clamp, Clamp ) : HighPassColor;

		float3 Sharpen = float3(
			Overlay(Source.r, HighPassColor),
			Overlay(Source.g, HighPassColor),
			Overlay(Source.b, HighPassColor)
		);

		if(Preview) // Preview mode ON
		{
			float PreviewChannel = lerp(HighPassColor, HighPassColor * DepthMask, 0.5);
			return gamma(float3(
				1.0 - DepthMask * (1.0 - HighPassColor),
				PreviewChannel,
				PreviewChannel
			));
		}

		return Sharpen;
	}
	else
	{
		Pixel *= Offset;

		float2 NorSouWesEst[4] = {
			float2(UvCoord.x, UvCoord.y + Pixel.y),
			float2(UvCoord.x, UvCoord.y - Pixel.y),
			float2(UvCoord.x + Pixel.x, UvCoord.y),
			float2(UvCoord.x - Pixel.x, UvCoord.y)
		};

		// Luma high-pass color
		float HighPassColor = 0.0;
		[unroll]
		for(int s = 0; s < 4; s++)
			HighPassColor += dot(tex2D(BackBuffer, NorSouWesEst[s]).rgb, LumaCoefficient);

		// !!! added space above to make it more obvious
		// !!! that loop is now a one-liner in this else branch
		// !!! where-as loop in branch above was multi-part
		HighPassColor = 0.5 - 0.5 * (HighPassColor * 0.25 - dot(Source, LumaCoefficient));

		// Sharpen strength
		HighPassColor = lerp(0.5, HighPassColor, Mask);

		// Clamping sharpen
		/*
		// original
		HighPassColor = (Clamp != 1.0) ? max(min(HighPassColor, Clamp), 1.0 - Clamp) : HighPassColor;
		*/

		// !!! Clamp in settings above is restricted to 0.5 to 1.0
		// !!! 1.0 - Clamp is the low value, while Clamp is the high value
		// !!! so we can literally just use the clamp() func instead of min/max.
		// !!! not sure if author was trying to take advantage of some kind of
		// !!! compiler "cheat" using min/max instead of clamp to improve
		// !!! performance. doesn't make sense to min/max otherwise.
		HighPassColor = (Clamp != 1.0) ? clamp( HighPassColor, 1.0 - Clamp, Clamp ) : HighPassColor;

		float3 Sharpen = float3(
			Overlay(Source.r, HighPassColor),
			Overlay(Source.g, HighPassColor),
			Overlay(Source.b, HighPassColor)
		);

		// Preview mode ON
		return Preview? gamma(HighPassColor) : Sharpen;
	}
}


	  //////////////
	 /// OUTPUT ///
	//////////////

technique FilmicAnamorphSharpen < ui_label = "影视畸变锐化"; >
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = FilmicAnamorphSharpenPS;
		SRGBWriteEnable = true;
	}
}
