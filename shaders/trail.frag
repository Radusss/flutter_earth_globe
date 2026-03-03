#include <flutter/runtime_effect.glsl>

precision mediump float;

// Output color for Flutter runtime effect
out vec4 fragColor;

// Uniforms
uniform vec2 uHead;        // head position in pixels
uniform vec2 uDir;         // normalized direction vector (pixels)
uniform float uLength;     // trail length in pixels (positive)
uniform float uWidth;      // base width in pixels at tail
uniform float uHeadMul;    // head width multiplier (CPU parity)

uniform vec4 uGlowColor;   // RGBA
uniform float uGlow;       // glow thickness multiplier
// Up to 4 gradient stops tail->head for CPU parity; if uStopCount<4, repeats end
uniform vec4 uStop0;
uniform vec4 uStop1;
uniform vec4 uStop2;
uniform vec4 uStop3;
uniform float uStopCount;  // 2..4 typically
// Global progress range [uT0, uT1] covered by this drawn ribbon segment
uniform float uT0;         // 0 at overall tail
uniform float uT1;         // 1 at overall head
uniform float uMaskOutside; // 1: only show outside globe disc when behind horizon
uniform float uShimmer;     // shimmer intensity multiplier

uniform float uTime;       // seconds for subtle shimmer if desired

uniform vec2 uCenter;      // globe center in pixels
uniform float uRadius;     // globe radius in pixels
// Signed distance to a constant-width capsule with rounded caps for this segment.
// Returns: (distToEdge, t01Local) where t01Local is 0 at tail and 1 at head of this segment.
vec2 ribbonDistance(vec2 p, vec2 head, vec2 dir, float ribbonLength, float baseWidth) {
  vec2 nDir = normalize(dir);
  vec2 nPerp = vec2(-nDir.y, nDir.x);

  // Local coordinates where x is along -dir (tail -> head), y is perpendicular
  vec2 d = p - head;
  float x = dot(d, -nDir);       // 0 at head, +length at tail
  float y = dot(d, nPerp);

  float t = clamp(1.0 - x / max(ribbonLength, 0.0001), 0.0, 1.0); // 0 at tail, 1 at head

  // Match CPU trail: constant width per segment, already baked via uHeadMul
  float halfWidth = 0.5 * (baseWidth * uHeadMul);

  // Distance to tapered rectangle body in [0,length]
  float distCore = abs(y) - halfWidth;
  float outsideX = max(-x, x - ribbonLength); // positive when outside [0, length]
  float rectDist = max(distCore, outsideX);

  // Rounded caps: distance to head/tail circles
  vec2 tailPos = head - nDir * ribbonLength;
  float distHeadCap = length(p - head) - halfWidth;
  float distTailCap = length(p - tailPos) - halfWidth;

  float distToEdge = min(rectDist, min(distHeadCap, distTailCap));

  return vec2(distToEdge, t);
}

// Smooth alpha from signed distance using hardware derivatives for screen-space AA
float coverage(float signedDist) {
  // Edge width proportional to pixel footprint
  float w = fwidth(signedDist);
  // Returns 1 inside (negative dist), 0 outside with smooth edge
  return smoothstep(0.0, w, -signedDist);
}

void main() {
  vec2 frag = FlutterFragCoord();

  // Distance field for the ribbon
  vec2 distAndT = ribbonDistance(frag, uHead, uDir, max(uLength, 0.0), max(uWidth, 0.001));
  float distToEdge = distAndT.x;
  float t01Local = distAndT.y; // 0 tail → 1 head (within this segment)
  // Convert to global trail progress using [uT0,uT1] provided by host
  float t01 = mix(uT0, uT1, t01Local);

  // Core ribbon color via multi-stop gradient tail->head
  vec4 c0 = uStop0;
  vec4 c1 = uStop1;
  vec4 c2 = uStop2;
  vec4 c3 = uStop3;
  float sc = clamp(uStopCount, 2.0, 4.0);
  vec4 baseColor;
  if (sc <= 2.0) {
    baseColor = mix(c0, c3, t01);
  } else if (sc <= 3.0) {
    float seg = t01 * 2.0;
    baseColor = mix(seg < 1.0 ? c0 : c2, seg < 1.0 ? c1 : c3, fract(seg));
  } else {
    float seg = t01 * 3.0;
    if (seg < 1.0) baseColor = mix(c0, c1, seg);
    else if (seg < 2.0) baseColor = mix(c1, c2, seg - 1.0);
    else baseColor = mix(c2, c3, seg - 2.0);
  }

  // Core body coverage with derivative-based smoothing
  float bodyAlpha = coverage(distToEdge);
  // Stronger longitudinal fade to accentuate head vs tail
  bodyAlpha *= clamp(pow(t01, 2.6), 0.0, 1.0);

  // Outer glow using expanded distance and smooth falloff
  float glowWidthPx = max(uWidth * max(uGlow, 0.0), 0.0);
  float glowEdge = fwidth(distToEdge) * 2.0; // slightly softer than body
  // Transition window centered at -glowWidthPx (outside body)
  float glowBand = smoothstep(-(glowWidthPx + glowEdge), -(glowWidthPx - glowEdge), -distToEdge);
  // Remove overlap with core body to avoid halo overdraw
  float glowAlpha = max(glowBand - bodyAlpha, 0.0);
  // Slightly intensify glow near the head to mimic a bright tip, and fade at tail
  glowAlpha *= (0.6 + 0.4 * t01) * pow(max(t01, 0.0), 1.3);

  vec4 glow = uGlowColor * glowAlpha;
  vec4 body = baseColor * bodyAlpha;

  // Optional shimmer near head (low intensity for parity)
  float shimmerTerm = uShimmer * 0.05 * sin(18.0 * t01 + 2.5 * uTime);
  body.rgb += shimmerTerm * body.a;

  // Horizon fade: 0 inside disc, 1 outside, with derivative-based smoothing
  float distToCenter = length(frag - uCenter);
  float hw = fwidth(distToCenter) * 2.0;
  float outside = smoothstep(uRadius - hw, uRadius + hw, distToCenter);
  // Match CPU: if head is behind (host computes), only show outside globe disc
  float vis = mix(1.0, outside, uMaskOutside);
  vec4 color = (body + glow) * vis;
  // Clamp and enforce premultiplied alpha safety
  color = clamp(color, 0.0, 1.0);
  fragColor = color;
}
