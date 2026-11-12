// 显式 GPU 蒙皮；手动 include，不生成静态/蒙皮变体。
// 调色板为模型局部空间的 inverse-bind × 当前关节变换（行向量）；旋转/平移骨骼。
#ifndef OLIB_SKINNING_HLSLI
#define OLIB_SKINNING_HLSLI
#include "model.hlsli"

//@region 顶点与调色板 ABI

// 每块 4096 字节；宿主每次绘制绑定全部 128 个关节，未使用项填写单位矩阵。
cbuffer OlibSkinning0 : register(b2, space1) {
	float4x4 OlibJoints0[64];
};
cbuffer OlibSkinning1 : register(b3, space1) {
	float4x4 OlibJoints1[64];
};

// location 与 TEXCOORD 同号；joints 为未归一化 UByte4，其余为 FloatN。
struct OlibSkinnedInput {
	[[vk::location(0)]] float3 position : TEXCOORD0;
	[[vk::location(1)]] float3 normal : TEXCOORD1;
	[[vk::location(2)]] float2 uv : TEXCOORD2;
	[[vk::location(3)]] float4 tangent : TEXCOORD3;
	[[vk::location(4)]] uint4 joints : TEXCOORD4;
	[[vk::location(5)]] float4 weights : TEXCOORD5;
};
//@endregion

//@region 行向量蒙皮

float4x4 olib_skin_joint(uint index) {
	// 先检查范围，禁止越界访问任何一块调色板。
	if (index >= 128) {
		return float4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
	}
	if (index < 64) {
		return OlibJoints0[index];
	}
	return OlibJoints1[index - 64];
}

float3 olib_skin_direction(float3 direction, float3 fallback) {
	float length_squared = dot(direction, direction);
	if (length_squared > 0) {
		return direction * rsqrt(length_squared);
	}
	return fallback;
}

// 返回模型局部空间顶点；接着由作者应用 World / Wvp。uv、joints、weights 不变。
OlibSkinnedInput olib_skin_vertex(OlibSkinnedInput v) {
	float4 weights = max(v.weights, 0.0);
	float total = dot(weights, float4(1, 1, 1, 1));
	if (total <= 0) {
		return v;
	}
	weights /= total;
	float4x4 skin = olib_skin_joint(v.joints.x) * weights.x
		+ olib_skin_joint(v.joints.y) * weights.y
		+ olib_skin_joint(v.joints.z) * weights.z
		+ olib_skin_joint(v.joints.w) * weights.w;
	v.position = mul(float4(v.position, 1), skin).xyz;
	// w=0 的方向不受平移影响；归一化避免线性混合缩短方向，零向量安全回退。
	v.normal = olib_skin_direction(mul(v.normal, (float3x3)skin), v.normal);
	v.tangent.xyz = olib_skin_direction(mul(v.tangent.xyz, (float3x3)skin), v.tangent.xyz);
	// tangent.w 为副切线手性，原样保留。
	return v;
}
//@endregion

#endif
