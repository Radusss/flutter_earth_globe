// shaders/orb.frag
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uSize;    // local canvas size (width, height)
uniform vec2 uOrigin;  // top-left of the local canvas in device pixels
uniform float iTime;   // seconds since start (set from Dart)

out vec4 fragColor;

const float PI = 3.14159265857;
const float speedfactor = 1.0;            // < 1.0 slower, > 1.0 faster
const float unit = PI / 280.0;            // particle spacing along the circle
const float particlenums = 40.0;          // particle count (tail made of ~40 particles)
const float intensityfactor = 1.0 / particlenums / 15000.0;

void main() {
  // Local fragment coord relative to the provided rect
  vec2 fragCoord = FlutterFragCoord().xy - uOrigin;

  // Normalized UV (0..1), then center and fix aspect so circle stays round
  vec2 uv = fragCoord / uSize;
  float aspect = uSize.x / uSize.y;
  uv = (uv - vec2(0.5)) * vec2(aspect, 1.0);

  vec3 color = vec3(0.0);

  // Blue particle ring (single orb) with size increasing along the ring to create a tail
  const vec3 blue = vec3(0.15, 0.45, 1.0);
  for (float i = 0.0; i < particlenums; i++) {
    float t = unit * i + iTime * speedfactor;
    vec2 orbit = vec2(sin(t), cos(t)) * 0.35;
    // Use -orbit so the tail aligns like the reference blue orb
    vec2 puv = 1.25 * uv - orbit;
    float invLen = 1.0 / max(length(puv), 1e-4);
    // Weight grows toward the head (higher i) to simulate trailing particles
    float w = pow(i, 2.0);
    color += blue * invLen * w;
  }
  // Radial mask so RGB is zero near the rect edges (prevents visible square)
  float r = length(uv);
  float mask = 1.0 - smoothstep(0.30, 0.50, r); // 1 at center, 0 at outer

  vec3 finalColor = color * intensityfactor * mask;
  fragColor = vec4(finalColor, 0.0); // alpha unused with additive blend
}


