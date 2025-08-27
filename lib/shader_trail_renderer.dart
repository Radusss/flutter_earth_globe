import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

/// Lightweight GPU trail renderer that draws a tapered ribbon using a fragment shader.
///
/// This class lazily loads the `shaders/trail.frag` program, maintains a reusable
/// [Paint] and a small uniform buffer, and provides a single [drawRibbon] entry point.
class ShaderTrailRenderer {
  ShaderTrailRenderer._();

  static final ShaderTrailRenderer instance = ShaderTrailRenderer._();

  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  Future<void>? _initFuture;
  bool _failed = false;
  final Paint _paint = Paint();
  // Uniform layout must match the order in shaders/trail.frag
  // [uHead.x, uHead.y, uDir.x, uDir.y, uLength, uWidth, uHeadMul,
  //  uHeadColor.r,g,b,a, uTailColor.r,g,b,a, uGlowColor.r,g,b,a, uGlow,
  //  uStop0.r,g,b,a, uStop1.r,g,b,a, uStop2.r,g,b,a, uStop3.r,g,b,a,
  //  uStopCount, uT0, uT1, uMaskOutside, uShimmer, uTime, uCenter.x, uCenter.y,
  //  uRadius, uZoom, uRotationY, uRotationZ]
  final Float32List _uniforms = Float32List(48);

  /// Starts loading the shader program if not already started.
  void warmUp() {
    _initFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      // Try package-qualified asset key first (required when used from an app)
      const String pkgKey = 'packages/flutter_earth_globe/shaders/trail.frag';
      const String localKey = 'shaders/trail.frag';
      try {
        _program ??= await ui.FragmentProgram.fromAsset(pkgKey);
        // ignore: avoid_print
        print('[ShaderTrailRenderer] Loaded shader: $pkgKey');
      } catch (e) {
        // ignore: avoid_print
        print('[ShaderTrailRenderer] Failed to load $pkgKey, retrying $localKey ($e)');
        _program ??= await ui.FragmentProgram.fromAsset(localKey);
        // ignore: avoid_print
        print('[ShaderTrailRenderer] Loaded shader: $localKey');
      }
      _shader ??= _program!.fragmentShader();
      _failed = false;
    } catch (_) {
      _failed = true;
      // Debug print for diagnostics in profile/release
      // ignore: avoid_print
      print('[ShaderTrailRenderer] Failed to load shader program shaders/trail.frag');
    }
  }

  bool get isReady => _shader != null;
  bool get isFailed => _failed;

  /// Disposes the underlying shader instance so it can be re-created lazily.
  void dispose() {
    // Currently FragmentShader does not expose a dispose; just drop references.
    _shader = null;
    _program = null;
  }

  /// Draw a single ribbon behind [head] along [direction] with pixel-space dimensions.
  ///
  /// The caller should provide a tight [bounds] rectangle that encloses the ribbon
  /// for optimal raster performance. Colors should be premultiplied compatible.
  void drawRibbon({
    required Canvas canvas,
    required Rect bounds,
    required Offset head,
    required Offset direction,
    required double lengthPx,
    required double widthPx,
    required double headWidthMultiplier,
    required Color headColor,
    required Color tailColor,
    required List<Color> colorStops,
    required double segmentT0,
    required double segmentT1,
    required bool maskOutsideOnly,
    required Color glowColor,
    required double glowStrength,
    required double shimmer,
    required double timeSeconds,
    required Offset globeCenter,
    required double globeRadius,
    required double zoom,
    required double rotationY,
    required double rotationZ,
  }) {
    if (_shader == null) {
      // Kick off load if needed; skip drawing this frame
      warmUp();
      // ignore: avoid_print
      print('[ShaderTrailRenderer] draw skipped: shader not ready');
      return;
    }

    // Normalize direction; avoid NaNs
    final double dirLen = direction.distance;
    double dirX = dirLen > 1e-6 ? direction.dx / dirLen : 0.0;
    double dirY = dirLen > 1e-6 ? direction.dy / dirLen : -1.0;

    // Platform parity fix: on iOS the vertical drag/sign for GPU ribbons
    // renders inverted compared to CPU paths/sphere rotation. Flip Y only
    // for iOS to match Android and CPU rendering.
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        dirY = -dirY;
      }
    } catch (_) {
      // defaultTargetPlatform may not be available in some contexts; ignore
    }

    // Pack uniforms in declared order
    int i = 0;
    _uniforms[i++] = head.dx;
    _uniforms[i++] = head.dy;
    _uniforms[i++] = dirX;
    _uniforms[i++] = dirY;
    _uniforms[i++] = lengthPx;
    _uniforms[i++] = widthPx;
    _uniforms[i++] = headWidthMultiplier;

    _uniforms[i++] = headColor.red / 255.0;
    _uniforms[i++] = headColor.green / 255.0;
    _uniforms[i++] = headColor.blue / 255.0;
    _uniforms[i++] = headColor.opacity;

    _uniforms[i++] = tailColor.red / 255.0;
    _uniforms[i++] = tailColor.green / 255.0;
    _uniforms[i++] = tailColor.blue / 255.0;
    _uniforms[i++] = tailColor.opacity;

    _uniforms[i++] = glowColor.red / 255.0;
    _uniforms[i++] = glowColor.green / 255.0;
    _uniforms[i++] = glowColor.blue / 255.0;
    _uniforms[i++] = glowColor.opacity;

    _uniforms[i++] = glowStrength;

    // Pack up to 4 color stops from tail->head. If fewer provided, repeat ends.
    final int stopCount = colorStops.isEmpty ? 2 : colorStops.length.clamp(2, 4);
    Color stop0 = stopCount >= 1 ? colorStops[0] : tailColor;
    Color stop1 = stopCount >= 2 ? colorStops[1] : headColor;
    Color stop2 = stopCount >= 3 ? colorStops[2] : headColor;
    Color stop3 = stopCount >= 4 ? colorStops[3] : headColor;

    // Tail/head fallback if no stops passed
    if (colorStops.isEmpty) {
      stop0 = tailColor;
      stop1 = headColor;
      stop2 = headColor;
      stop3 = headColor;
    }

    // uStop0
    _uniforms[i++] = stop0.red / 255.0;
    _uniforms[i++] = stop0.green / 255.0;
    _uniforms[i++] = stop0.blue / 255.0;
    _uniforms[i++] = stop0.opacity;
    // uStop1
    _uniforms[i++] = stop1.red / 255.0;
    _uniforms[i++] = stop1.green / 255.0;
    _uniforms[i++] = stop1.blue / 255.0;
    _uniforms[i++] = stop1.opacity;
    // uStop2
    _uniforms[i++] = stop2.red / 255.0;
    _uniforms[i++] = stop2.green / 255.0;
    _uniforms[i++] = stop2.blue / 255.0;
    _uniforms[i++] = stop2.opacity;
    // uStop3
    _uniforms[i++] = stop3.red / 255.0;
    _uniforms[i++] = stop3.green / 255.0;
    _uniforms[i++] = stop3.blue / 255.0;
    _uniforms[i++] = stop3.opacity;

    _uniforms[i++] = stopCount.toDouble(); // uStopCount
    _uniforms[i++] = segmentT0; // uT0
    _uniforms[i++] = segmentT1; // uT1
    _uniforms[i++] = maskOutsideOnly ? 1.0 : 0.0; // uMaskOutside
    _uniforms[i++] = shimmer; // uShimmer

    _uniforms[i++] = timeSeconds;
    _uniforms[i++] = globeCenter.dx;
    _uniforms[i++] = globeCenter.dy;
    _uniforms[i++] = globeRadius;
    _uniforms[i++] = zoom;
    _uniforms[i++] = rotationY;
    _uniforms[i++] = rotationZ;

    // Older Flutter stable exposes setFloat on FragmentShader
    final ui.FragmentShader shader = _shader!;
    for (int j = 0; j < _uniforms.length; j++) {
      shader.setFloat(j, _uniforms[j]);
    }

    // Reuse paint and shader; ensure blend mode supports premultiplied alpha
    _paint
      ..blendMode = BlendMode.srcOver
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.low
      ..shader = shader;
    try {
      canvas.drawRect(bounds, _paint);
    } catch (e) {
      // ignore: avoid_print
      print('[ShaderTrailRenderer] drawRect failed: $e');
    }
  }
}


