/*
Chromakey PS v1.5.2a (c) 2018 Jacob Maximilian Fober

This work is licensed under the Creative Commons
Attribution-ShareAlike 4.0 International License.
To view a copy of this license, visit
http://creativecommons.org/licenses/by-sa/4.0/.
*/

#include "ReShade.fxh"
#include "ReShadeUI.fxh"


	  ////////////
	 /// MENU ///
	////////////

uniform float Threshold < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 0.999; ui_step = 0.001;
	ui_category = "距离调整";
> = 0.5;

uniform bool RadialX <
	ui_label = "水平径向深度";
	ui_category = "径向距离";
	ui_category_closed = true;
> = false;
uniform bool RadialY <
	ui_label = "垂直径向深度";
	ui_category = "径向距离";
> = false;

uniform int FOV < __UNIFORM_SLIDER_INT1
	ui_label = "视场(水平)";
	ui_tooltip = "视野的角度";
	#if __RESHADE__ < 40000
		ui_step = 1;
	#endif
	ui_min = 0; ui_max = 170;
	ui_category = "径向距离";
> = 90;

uniform int Pass < __UNIFORM_RADIO_INT1
	ui_label = "键类型";
	ui_items = "背景键\0前景键\0";
	ui_category = "方向调整";
> = 0;

uniform bool Floor <
	ui_label = "覆盖地板";
	ui_category = "地板遮挡 (实验性)";
	ui_category_closed = true;
> = false;

uniform float FloorAngle < __UNIFORM_SLIDER_FLOAT1
	ui_label = "地板角度";
	ui_category = "地板遮盖 (实验性)";
	ui_min = 0.0; ui_max = 1.0;
> = 1.0;

uniform int Precision < __UNIFORM_SLIDER_INT1
	ui_label = "地板精度";
	ui_category = "地板遮盖 (实验性)";
	ui_min = 2; ui_max = 64;
> = 4;

uniform int Color < __UNIFORM_RADIO_INT1
	ui_label = "键颜色";
	ui_tooltip = "超级蓝色和绿色是色度键的工业标准颜色";
	ui_items = "超级蓝抠像(tm)\0绿色抠像(tm)\0自定义\0";
	ui_category = "颜色设置";
	ui_category_closed = true;
> = 1;

uniform float3 CustomColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "自定义颜色";
	ui_category = "颜色设置";
> = float3(1.0, 0.0, 0.0);

uniform bool AntiAliased <
	ui_label = "抗锯齿覆盖";
	ui_tooltip = "禁用该选项将减少遮蔽间隙";
	ui_category = "额外设置";
	ui_category_closed = true;
> = false;


	  /////////////////
	 /// FUNCTIONS ///
	/////////////////

float MaskAA(float2 texcoord)
{
	// Sample depth image
	float Depth = ReShade::GetLinearizedDepth(texcoord);

	// Convert to radial depth
	float2 Size;
	Size.x = tan(radians(FOV*0.5));
	Size.y = Size.x / ReShade::AspectRatio;
	if(RadialX) Depth *= length(float2((texcoord.x-0.5)*Size.x, 1.0));
	if(RadialY) Depth *= length(float2((texcoord.y-0.5)*Size.y, 1.0));

	// Return jagged mask
	if(!AntiAliased) return step(Threshold, Depth);

	// Get half-pixel size in depth value
	float hPixel = fwidth(Depth)*0.5;

	return smoothstep(Threshold-hPixel, Threshold+hPixel, Depth);
}

float3 GetPosition(float2 texcoord)
{
	// Get view angle for trigonometric functions
	const float theta = radians(FOV*0.5);

	float3 position = float3( texcoord*2.0-1.0, ReShade::GetLinearizedDepth(texcoord) );
	// Reverse perspective
	position.xy *= position.z;

	return position;
}

// Normal map (OpenGL oriented) generator from DisplayDepth.fx
float3 GetNormal(float2 texcoord)
{
	float3 offset = float3(BUFFER_PIXEL_SIZE.xy, 0.0);
	float2 posCenter = texcoord.xy;
	float2 posNorth  = posCenter - offset.zy;
	float2 posEast   = posCenter + offset.xz;

	float3 vertCenter = float3(posCenter - 0.5, 1.0) * ReShade::GetLinearizedDepth(posCenter);
	float3 vertNorth  = float3(posNorth - 0.5,  1.0) * ReShade::GetLinearizedDepth(posNorth);
	float3 vertEast   = float3(posEast - 0.5,   1.0) * ReShade::GetLinearizedDepth(posEast);

	return normalize(cross(vertCenter - vertNorth, vertCenter - vertEast)) * 0.5 + 0.5;
}

	  //////////////
	 /// SHADER ///
	//////////////

float3 ChromakeyPS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	// Define chromakey color, Ultimatte(tm) Super Blue, Ultimatte(tm) Green, or user color
	float3 Screen;
	switch(Color)
	{
		case 0:{ Screen = float3(0.07, 0.18, 0.72); break; } // Ultimatte(tm) Super Blue
		case 1:{ Screen = float3(0.29, 0.84, 0.36); break; } // Ultimatte(tm) Green
		case 2:{ Screen = CustomColor;              break; } // User defined color
	}

	// Generate depth mask
	float DepthMask = MaskAA(texcoord);

	if (Floor)
	{
		float AngleScreen =  (float)round( GetNormal(texcoord).y*Precision )/Precision;
		float AngleFloor = (float)round( FloorAngle*Precision )/Precision;

		bool FloorMask = AngleScreen==AngleFloor;

		DepthMask = FloorMask ? 1.0 : DepthMask;
	}

	if(bool(Pass)) DepthMask = 1.0-DepthMask;

	return lerp(tex2D(ReShade::BackBuffer, texcoord).rgb, Screen, DepthMask);
}


	  //////////////
	 /// OUTPUT ///
	//////////////

technique Chromakey < ui_tooltip = "根据深度生成绿屏墙"; >
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = ChromakeyPS;
	}
}
