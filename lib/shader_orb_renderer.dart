import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Simple GPU orb renderer using fragment shader `shaders/orb.frag`.
///
/// Draws a glowing particle ring that looks like a fiery orb, centered in a
/// small rectangle around a given on-screen position.
class ShaderOrbRenderer {
  ShaderOrbRenderer._();

  static final ShaderOrbRenderer instance = ShaderOrbRenderer._();

  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  Future<void>? _initFuture;
  bool _failed = false;
  final Paint _paint = Paint();

  // [uSize.x, uSize.y, uOrigin.x, uOrigin.y, iTime]
  final Float32List _uniforms = Float32List(5);

  void warmUp() {
    _initFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      const String pkgKey = 'packages/flutter_earth_globe/shaders/orb.frag';
      const String localKey = 'shaders/orb.frag';
      try {
        _program ??= await ui.FragmentProgram.fromAsset(pkgKey);
        // ignore: avoid_print
        print('[ShaderOrbRenderer] Loaded shader: $pkgKey');
      } catch (e) {
        // ignore: avoid_print
        print('[ShaderOrbRenderer] Failed to load $pkgKey, retrying $localKey ($e)');
        _program ??= await ui.FragmentProgram.fromAsset(localKey);
        // ignore: avoid_print
        print('[ShaderOrbRenderer] Loaded shader: $localKey');
      }
      _shader ??= _program!.fragmentShader();
      _failed = false;
    } catch (_) {
      _failed = true;
      // ignore: avoid_print
      print('[ShaderOrbRenderer] Failed to load shader program shaders/orb.frag');
    }
  }

  bool get isReady => _shader != null;
  bool get isFailed => _failed;

  /// Draw the orb centered at [center] using a square [sizePx] extent.
  /// Provide a monotonically increasing [timeSeconds] for animation.
  void drawOrb({
    required Canvas canvas,
    required Offset center,
    required double sizePx,
    required double timeSeconds,
  }) {
    if (_shader == null) {
      warmUp();
      // ignore: avoid_print
      print('[ShaderOrbRenderer] draw skipped: shader not ready');
      return;
    }

    final double half = sizePx * 0.5;
    final Rect rect = Rect.fromLTWH(center.dx - half, center.dy - half, sizePx, sizePx);

    int i = 0;
    _uniforms[i++] = sizePx;
    _uniforms[i++] = sizePx;
    _uniforms[i++] = rect.left;
    _uniforms[i++] = rect.top;
    _uniforms[i++] = timeSeconds.toDouble();

    final ui.FragmentShader shader = _shader!;
    for (int j = 0; j < _uniforms.length; j++) {
      shader.setFloat(j, _uniforms[j]);
    }

    _paint
      ..blendMode = BlendMode.plus
      ..isAntiAlias = true
      ..shader = shader;

    try {
      canvas.drawRect(rect, _paint);
    } catch (e) {
      // ignore: avoid_print
      print('[ShaderOrbRenderer] drawRect failed: $e');
    }
  }
}


