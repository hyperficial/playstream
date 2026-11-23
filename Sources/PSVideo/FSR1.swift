// AMD FidelityFX Super Resolution 1.0 (EASU + RCAS), ported to Metal Shading Language from AMD's
// published source: GPUOpen-Effects/FidelityFX-FSR, ffx-fsr/ffx_fsr1.h (non-packed 32-bit paths
// FsrEasuF / FsrRcasF, constants from FsrEasuCon / FsrRcasCon) and the helper approximations from
// ffx_a.h (APrxLoRcpF1, APrxLoRsqF1, APrxMedRcpF1). Only the language was changed (HLSL/GLSL macros ->
// MSL); the arithmetic, constants and tap order follow the original.
//
// ---------------------------------------------------------------------------------------------------
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
// ---------------------------------------------------------------------------------------------------

import Foundation
import simd

enum FSR1 {
	/// EASU constants (FsrEasuCon), as floats: con0..con3.
	struct EasuConstants {
		var con0: SIMD4<Float>
		var con1: SIMD4<Float>
		var con2: SIMD4<Float>
		var con3: SIMD4<Float>
	}

	static func easuConstants(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> EasuConstants {
		let ivx = Float(inputWidth), ivy = Float(inputHeight) // viewport == resource size here
		let isx = Float(inputWidth), isy = Float(inputHeight)
		let osx = Float(outputWidth), osy = Float(outputHeight)
		return EasuConstants(
			con0: SIMD4(ivx / osx, ivy / osy, 0.5 * ivx / osx - 0.5, 0.5 * ivy / osy - 0.5),
			con1: SIMD4(1 / isx, 1 / isy, 1 / isx, -1 / isy),
			con2: SIMD4(-1 / isx, 2 / isy, 1 / isx, 2 / isy),
			con3: SIMD4(0 / isx, 4 / isy, 0, 0))
	}

	/// RCAS constant (FsrRcasCon): `stops` = 0 is maximum sharpness, each stop halves it.
	static func rcasSharpness(stops: Float) -> Float { exp2(-stops) }

	static let shaderSource = """
	// AMD FidelityFX Super Resolution 1.0 (EASU + RCAS), ported to MSL from ffx_fsr1.h / ffx_a.h.
	// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved. MIT License (see FSR1.swift).
	#include <metal_stdlib>
	using namespace metal;

	struct FsrOut { float4 position [[position]]; float2 uv; };
	vertex FsrOut fsr_vertex(uint vid [[vertex_id]]) {
		float2 q = float2((vid << 1) & 2, vid & 2);
		FsrOut o;
		o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(q.x, 1.0 - q.y);
		return o;
	}

	// ffx_a.h approximations.
	inline float APrxLoRcpF1(float a) { return as_type<float>(uint(0x7ef07ebb) - as_type<uint>(a)); }
	inline float APrxMedRcpF1(float a) { float b = as_type<float>(uint(0x7ef19fff) - as_type<uint>(a)); return b * (-b * a + 2.0); }
	inline float APrxLoRsqF1(float a) { return as_type<float>(uint(0x5f347d74) - (as_type<uint>(a) >> 1)); }
	inline float AMin3F1(float x, float y, float z) { return min(x, min(y, z)); }
	inline float AMax3F1(float x, float y, float z) { return max(x, max(y, z)); }
	inline float3 AMin3F3(float3 x, float3 y, float3 z) { return min(x, min(y, z)); }
	inline float3 AMax3F3(float3 x, float3 y, float3 z) { return max(x, max(y, z)); }

	struct EasuCon { float4 con0; float4 con1; float4 con2; float4 con3; };

	// FsrEasuTapF
	inline void FsrEasuTapF(thread float3 &aC, thread float &aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
		float2 v;
		v.x = (off.x * ( dir.x)) + (off.y * dir.y);
		v.y = (off.x * (-dir.y)) + (off.y * dir.x);
		v *= len;
		float d2 = v.x * v.x + v.y * v.y;
		d2 = min(d2, clp);
		float wB = (2.0 / 5.0) * d2 + (-1.0);
		float wA = lob * d2 + (-1.0);
		wB *= wB;
		wA *= wA;
		wB = (25.0 / 16.0) * wB + (-(25.0 / 16.0 - 1.0));
		float w = wB * wA;
		aC += c * w; aW += w;
	}

	// FsrEasuSetF
	inline void FsrEasuSetF(thread float2 &dir, thread float &len, float2 pp, bool biS, bool biT, bool biU, bool biV,
	                        float lA, float lB, float lC, float lD, float lE) {
		float w = 0.0;
		if (biS) w = (1.0 - pp.x) * (1.0 - pp.y);
		if (biT) w =        pp.x  * (1.0 - pp.y);
		if (biU) w = (1.0 - pp.x) *        pp.y ;
		if (biV) w =        pp.x  *        pp.y ;
		float dc = lD - lC;
		float cb = lC - lB;
		float lenX = max(abs(dc), abs(cb));
		lenX = APrxLoRcpF1(lenX);
		float dirX = lD - lB;
		dir.x += dirX * w;
		lenX = saturate(abs(dirX) * lenX);
		lenX *= lenX;
		len += lenX * w;
		float ec = lE - lC;
		float ca = lC - lA;
		float lenY = max(abs(ec), abs(ca));
		lenY = APrxLoRcpF1(lenY);
		float dirY = lE - lA;
		dir.y += dirY * w;
		lenY = saturate(abs(dirY) * lenY);
		lenY *= lenY;
		len += lenY * w;
	}

	// FsrEasuF, with the FsrEasuRF/GF/BF callbacks implemented as gather of the r, g, b components.
	fragment float4 fsr_easu(FsrOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant EasuCon &k [[buffer(0)]]) {
		constexpr sampler s(filter::nearest, address::clamp_to_edge);
		uint2 ip = uint2(in.position.xy);
		float2 pp = float2(ip) * k.con0.xy + k.con0.zw;
		float2 fp = floor(pp);
		pp -= fp;
		float2 p0 = fp * k.con1.xy + k.con1.zw;
		float2 p1 = p0 + k.con2.xy;
		float2 p2 = p0 + k.con2.zw;
		float2 p3 = p0 + k.con3.xy;
		float4 bczzR = src.gather(s, p0, int2(0), component::x);
		float4 bczzG = src.gather(s, p0, int2(0), component::y);
		float4 bczzB = src.gather(s, p0, int2(0), component::z);
		float4 ijfeR = src.gather(s, p1, int2(0), component::x);
		float4 ijfeG = src.gather(s, p1, int2(0), component::y);
		float4 ijfeB = src.gather(s, p1, int2(0), component::z);
		float4 klhgR = src.gather(s, p2, int2(0), component::x);
		float4 klhgG = src.gather(s, p2, int2(0), component::y);
		float4 klhgB = src.gather(s, p2, int2(0), component::z);
		float4 zzonR = src.gather(s, p3, int2(0), component::x);
		float4 zzonG = src.gather(s, p3, int2(0), component::y);
		float4 zzonB = src.gather(s, p3, int2(0), component::z);
		float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG);
		float4 ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
		float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG);
		float4 zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
		float bL = bczzL.x;
		float cL = bczzL.y;
		float iL = ijfeL.x;
		float jL = ijfeL.y;
		float fL = ijfeL.z;
		float eL = ijfeL.w;
		float kL = klhgL.x;
		float lL = klhgL.y;
		float hL = klhgL.z;
		float gL = klhgL.w;
		float oL = zzonL.z;
		float nL = zzonL.w;
		float2 dir = float2(0.0);
		float len = 0.0;
		FsrEasuSetF(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
		FsrEasuSetF(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
		FsrEasuSetF(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
		FsrEasuSetF(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);
		float2 dir2 = dir * dir;
		float dirR = dir2.x + dir2.y;
		bool zro = dirR < (1.0 / 32768.0);
		dirR = APrxLoRsqF1(dirR);
		dirR = zro ? 1.0 : dirR;
		dir.x = zro ? 1.0 : dir.x;
		dir *= float2(dirR);
		len = len * 0.5;
		len *= len;
		float stretch = (dir.x * dir.x + dir.y * dir.y) * APrxLoRcpF1(max(abs(dir.x), abs(dir.y)));
		float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 + (-0.5) * len);
		float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
		float clp = APrxLoRcpF1(lob);
		float3 min4 = min(AMin3F3(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w), float3(ijfeR.y, ijfeG.y, ijfeB.y)),
		                  float3(klhgR.x, klhgG.x, klhgB.x));
		float3 max4 = max(AMax3F3(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w), float3(ijfeR.y, ijfeG.y, ijfeB.y)),
		                  float3(klhgR.x, klhgG.x, klhgB.x));
		float3 aC = float3(0.0);
		float aW = 0.0;
		FsrEasuTapF(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x)); // b
		FsrEasuTapF(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y)); // c
		FsrEasuTapF(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
		FsrEasuTapF(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
		FsrEasuTapF(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
		FsrEasuTapF(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
		FsrEasuTapF(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.x, klhgG.x, klhgB.x)); // k
		FsrEasuTapF(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y)); // l
		FsrEasuTapF(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z)); // h
		FsrEasuTapF(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.w, klhgG.w, klhgB.w)); // g
		FsrEasuTapF(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z)); // o
		FsrEasuTapF(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w)); // n
		float3 pix = min(max4, max(min4, aC * float3(1.0 / aW)));
		return float4(pix, 1.0);
	}

	#define FSR_RCAS_LIMIT (0.25 - (1.0 / 16.0))

	// FsrRcasF (no FSR_RCAS_DENOISE, no alpha pass-through). con = linear sharpness (FsrRcasCon con[0]).
	fragment float4 fsr_rcas(FsrOut in [[stage_in]], texture2d<float, access::read> src [[texture(0)]], constant float &con [[buffer(0)]]) {
		int2 sp = int2(in.position.xy);
		int2 mx = int2(src.get_width() - 1, src.get_height() - 1);
		float3 b = src.read(uint2(clamp(sp + int2( 0, -1), int2(0), mx))).rgb;
		float3 d = src.read(uint2(clamp(sp + int2(-1,  0), int2(0), mx))).rgb;
		float3 e = src.read(uint2(sp)).rgb;
		float3 f = src.read(uint2(clamp(sp + int2( 1,  0), int2(0), mx))).rgb;
		float3 h = src.read(uint2(clamp(sp + int2( 0,  1), int2(0), mx))).rgb;
		float bR = b.r, bG = b.g, bB = b.b;
		float dR = d.r, dG = d.g, dB = d.b;
		float eR = e.r, eG = e.g, eB = e.b;
		float fR = f.r, fG = f.g, fB = f.b;
		float hR = h.r, hG = h.g, hB = h.b;
		float mn4R = min(AMin3F1(bR, dR, fR), hR);
		float mn4G = min(AMin3F1(bG, dG, fG), hG);
		float mn4B = min(AMin3F1(bB, dB, fB), hB);
		float mx4R = max(AMax3F1(bR, dR, fR), hR);
		float mx4G = max(AMax3F1(bG, dG, fG), hG);
		float mx4B = max(AMax3F1(bB, dB, fB), hB);
		float2 peakC = float2(1.0, -1.0 * 4.0);
		float hitMinR = min(mn4R, eR) * (1.0 / (4.0 * mx4R));
		float hitMinG = min(mn4G, eG) * (1.0 / (4.0 * mx4G));
		float hitMinB = min(mn4B, eB) * (1.0 / (4.0 * mx4B));
		float hitMaxR = (peakC.x - max(mx4R, eR)) * (1.0 / (4.0 * mn4R + peakC.y));
		float hitMaxG = (peakC.x - max(mx4G, eG)) * (1.0 / (4.0 * mn4G + peakC.y));
		float hitMaxB = (peakC.x - max(mx4B, eB)) * (1.0 / (4.0 * mn4B + peakC.y));
		float lobeR = max(-hitMinR, hitMaxR);
		float lobeG = max(-hitMinG, hitMaxG);
		float lobeB = max(-hitMinB, hitMaxB);
		float lobe = max(-FSR_RCAS_LIMIT, min(AMax3F1(lobeR, lobeG, lobeB), 0.0)) * con;
		float rcpL = APrxMedRcpF1(4.0 * lobe + 1.0);
		float pixR = (lobe * bR + lobe * dR + lobe * hR + lobe * fR + eR) * rcpL;
		float pixG = (lobe * bG + lobe * dG + lobe * hG + lobe * fG + eG) * rcpL;
		float pixB = (lobe * bB + lobe * dB + lobe * hB + lobe * fB + eB) * rcpL;
		return float4(saturate(float3(pixR, pixG, pixB)), 1.0);
	}
	"""
}
