#include <metal_stdlib>
using namespace metal;

struct HaloUniforms { float2 size; float2 origin; float time; float opacity; float animated; float padding; };
struct HaloVertex { float4 position [[position]]; float2 uv; };
vertex HaloVertex haloVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y) };
}
static half3 lightPalette(float phase) {
    const half3 colors[8] = {
        half3(0.05h, 0.78h, 1.0h), half3(0.14h, 0.32h, 1.0h),
        half3(0.49h, 0.13h, 1.0h), half3(1.0h, 0.12h, 0.64h),
        half3(1.0h, 0.28h, 0.12h), half3(1.0h, 0.72h, 0.25h),
        half3(1.0h, 0.17h, 0.65h), half3(0.18h, 0.38h, 1.0h)
    };
    float p = fract(phase) * 8.0;
    int i = int(p);
    return mix(colors[i], colors[(i + 1) % 8], half(smoothstep(0.0, 1.0, fract(p))));
}
static float roundedDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - (halfSize - radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}
/// One premultiplied GPU pass, including activation front and the settled rim.
fragment half4 haloFragment(HaloVertex in [[stage_in]], constant HaloUniforms &u [[buffer(0)]]) {
    float2 center = u.size * 0.5;
    float2 p = in.uv * u.size - center;
    float radius = min(54.0, u.size.x * 0.13);
    float sd = roundedDistance(p, center - 1.5, radius);
    if (sd > 0.0) return half4(0);
    float edge = -sd;
    if ((u.time >= 1.05 || u.animated < 0.5) && edge > 185.0) return half4(0);
    float angle = atan2(p.y / max(center.y, 1.0), p.x / max(center.x, 1.0));
    float t = u.time * u.animated;
    float flow = -angle / (2.0 * M_PI_F) + 0.34 + t * 0.055;
    flow += 0.055 * sin(angle * 3.0 - t * 0.85) + 0.025 * sin(angle * 5.0 + t * 0.65);
    half3 hue = lightPalette(flow);
    float flash = u.animated * pow(sin(M_PI_F * clamp(u.time / 1.05, 0.0, 1.0)), 2.0);
    float traveling = pow(max(0.0, cos(angle * 2.0 - t * 1.6)), 12.0);
    float fine = exp(-edge / 2.2);
    float soft = exp(-edge / (10.0 + traveling * 7.0 + flash * 22.0));
    float bloom = exp(-edge / (30.0 + flash * 65.0)) * (1.0 - smoothstep(100.0, 185.0, edge));
    // Isotropic light starts at the contact point, never at a rectangular outline.
    float2 source = clamp(u.origin, float2(0), float2(1)) * u.size;
    float2 fromSource = in.uv * u.size - source;
    float distance = length(fromSource);
    float reach = length(max(source, u.size - source));
    float progress = 1.0 - pow(1.0 - clamp(u.time / 0.72, 0.0, 1.0), 2.0);
    float waveRadius = reach * progress;
    float width = 24.0 + progress * 42.0;
    float frontDistance = distance - waveRadius;
    float envelope = u.animated * (1.0 - smoothstep(0.50, 0.90, u.time));
    float front = exp(-pow(frontDistance / width, 2.0)) * envelope;
    // A filled luminous tail and short soft source flash avoid an empty expanding outline.
    float wash = exp(-distance / max(24.0, waveRadius * 0.65)) * envelope;
    float sourceFlash = exp(-pow(distance / (44.0 + progress * 24.0), 2.0)) * exp(-u.time * 8.0) * envelope;
    float rimArrival = u.animated > 0.5 ? mix(0.18, 1.0, smoothstep(-width, width, -frontDistance)) : 1.0;
    float shimmer = 0.86 + 0.14 * sin(angle * 4.0 - t * 1.1);
    float brightness = (fine * (0.86 + traveling * 0.12) + soft * 0.42 + bloom * (0.08 + flash * 0.26)) * rimArrival;
    brightness = clamp(brightness * shimmer + front * 0.32 + wash * 0.085 + sourceFlash, 0.0, 1.0);
    hue = mix(hue, half3(1.0h, 0.93h, 0.98h), half(clamp(fine * (traveling * 0.32 + flash * 0.26) + front * 0.35 + sourceFlash * 0.8, 0.0, 1.0)));
    half alpha = half(brightness * u.opacity);
    return half4(hue * alpha, alpha);
}
