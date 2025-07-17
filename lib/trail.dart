import 'package:flutter/material.dart';
import 'globe_coordinates.dart';

/// Visual style applied to a [Trail] poly-line.
class TrailStyle {
  /// Colour of the stroke.
  final Color color;

  /// Stroke width in logical pixels.
  final double width;

  /// Optional dash pattern (like canvas.drawDashed).
  /// Specify an even length list of on/off lengths in logical pixels.
  /// If `null` the trail is rendered as a solid line.
  final List<double>? dashArray;

  /// Optional glow/halo color around the trail. When null no halo is rendered.
  /// Typical usage: a semi-transparent version of [color] (e.g. color.withOpacity(0.2)).
  final Color? glowColor;

  /// Stroke width of the glow in logical pixels. Ignored when [glowColor] is null.
  /// If set to 0 no glow will be rendered even when [glowColor] is provided.
  final double glowWidth;

  /// Enable magical trail effect with gradient colors and multiple layers.
  /// When true, creates a sophisticated trail with color transitions and glow layers.
  final bool useMagicalEffect;

  /// Number of glow layers to render when using magical effect.
  /// More layers create a smoother, more ethereal glow but require more rendering.
  final int magicalLayers;

  /// Color progression for the magical trail effect.
  /// Should be a list of colors from tail to head (e.g., [transparent, blue, cyan, white]).
  /// If null, uses a default blue-to-white progression.
  final List<Color>? magicalColors;

  /// Width multiplier for the trail head when using magical effect.
  /// The trail width will vary from normal width at tail to (width * headWidthMultiplier) at head.
  final double headWidthMultiplier;

  /// Opacity multiplier for the magical effect.
  /// Controls the overall intensity of the magical trail effect.
  final double magicalOpacity;

  const TrailStyle({
    this.color = Colors.red,
    this.width = 2.0,
    this.dashArray,
    this.glowColor,
    this.glowWidth = 0,
    this.useMagicalEffect = false,
    this.magicalLayers = 5,
    this.magicalColors,
    this.headWidthMultiplier = 2.0,
    this.magicalOpacity = 1.0,
  });

  TrailStyle copyWith({
    Color? color,
    double? width,
    List<double>? dashArray,
    Color? glowColor,
    double? glowWidth,
    bool? useMagicalEffect,
    int? magicalLayers,
    List<Color>? magicalColors,
    double? headWidthMultiplier,
    double? magicalOpacity,
  }) {
    return TrailStyle(
      color: color ?? this.color,
      width: width ?? this.width,
      dashArray: dashArray ?? this.dashArray,
      glowColor: glowColor ?? this.glowColor,
      glowWidth: glowWidth ?? this.glowWidth,
      useMagicalEffect: useMagicalEffect ?? this.useMagicalEffect,
      magicalLayers: magicalLayers ?? this.magicalLayers,
      magicalColors: magicalColors ?? this.magicalColors,
      headWidthMultiplier: headWidthMultiplier ?? this.headWidthMultiplier,
      magicalOpacity: magicalOpacity ?? this.magicalOpacity,
    );
  }

  /// Get the default magical color progression if none specified.
  List<Color> get defaultMagicalColors => [
    Colors.transparent,
    Colors.blue.withOpacity(0.3),
    Colors.cyan.withOpacity(0.7),
    Colors.white.withOpacity(0.9),
  ];

  /// Get the color for a specific position along the trail (0.0 = tail, 1.0 = head).
  Color getColorForProgress(double progress) {
    final colors = magicalColors ?? defaultMagicalColors;
    if (colors.isEmpty) return color;
    if (colors.length == 1) return colors.first;
    
    progress = progress.clamp(0.0, 1.0);
    
    // Find the two colors to interpolate between
    final scaledProgress = progress * (colors.length - 1);
    final index = scaledProgress.floor();
    final localProgress = scaledProgress - index;
    
    if (index >= colors.length - 1) return colors.last;
    
    return Color.lerp(colors[index], colors[index + 1], localProgress) ?? colors.last;
  }
}

/// A light-weight object representing a breadcrumb trail on the globe.
/// A trail is drawn as a poly-line that connects each vertex in [vertices]
/// in the given order.
class Trail {
  final String id;
  final List<GlobeCoordinates> vertices;
  final TrailStyle style;

  /// Maximum number of vertices to keep in [vertices] before dropping the
  /// oldest ones. When `null` the trail can grow indefinitely.
  final int? maxLength;

  /// Altitude at which the trail floats above the globe surface.
  final double altitude;

  const Trail({
    required this.id,
    required this.vertices,
    this.style = const TrailStyle(),
    this.altitude = 0,
    this.maxLength,
  });

  Trail copyWith({
    List<GlobeCoordinates>? vertices,
    TrailStyle? style,
    double? altitude,
    int? maxLength,
  }) {
    return Trail(
      id: id,
      vertices: vertices ?? this.vertices,
      style: style ?? this.style,
      altitude: altitude ?? this.altitude,
      maxLength: maxLength ?? this.maxLength,
    );
  }
} 