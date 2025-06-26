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

  const TrailStyle({
    this.color = Colors.red,
    this.width = 2.0,
    this.dashArray,
  });

  TrailStyle copyWith({Color? color, double? width, List<double>? dashArray}) {
    return TrailStyle(
      color: color ?? this.color,
      width: width ?? this.width,
      dashArray: dashArray ?? this.dashArray,
    );
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