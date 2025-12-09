import 'package:flutter/material.dart';
import 'globe_coordinates.dart';
import 'trail.dart';

/// A trail that automatically follows a point by maintaining relative offsets.
/// This provides much better performance than updating individual trail vertices.
class TrailAttachment {
  /// Unique identifier for this trail attachment.
  final String id;
  
  /// The ID of the point this trail should follow.
  final String pointId;
  
  /// List of relative coordinates that define the trail shape.
  /// These are offsets from the point's current position.
  /// The first element should be GlobeCoordinates(0, 0) for the point itself,
  /// followed by increasingly negative offsets to create the trail behind it.
  final List<GlobeCoordinates> relativeVertices;
  
  /// Visual style for the trail.
  final TrailStyle style;
  
  /// Altitude offset from the attached point.
  final double altitudeOffset;

  const TrailAttachment({
    required this.id,
    required this.pointId,
    required this.relativeVertices,
    this.style = const TrailStyle(),
    this.altitudeOffset = 0.0,
  });

  /// Creates a copy of this trail attachment with optional new values.
  TrailAttachment copyWith({
    String? id,
    String? pointId,
    List<GlobeCoordinates>? relativeVertices,
    TrailStyle? style,
    double? altitudeOffset,
  }) {
    return TrailAttachment(
      id: id ?? this.id,
      pointId: pointId ?? this.pointId,
      relativeVertices: relativeVertices ?? this.relativeVertices,
      style: style ?? this.style,
      altitudeOffset: altitudeOffset ?? this.altitudeOffset,
    );
  }

  /// Generates absolute trail vertices based on the point's current position.
  ///
  /// Uses pole-crossing normalization identical to the point update logic so
  /// trails remain continuous when crossing +/- 90° latitude. This avoids
  /// the visual reset where the head appears without a tail after crossing.
  List<GlobeCoordinates> generateAbsoluteVertices(GlobeCoordinates pointPosition) {
    return relativeVertices.map((relative) {
      double newLat = pointPosition.latitude + relative.latitude;
      double newLon = pointPosition.longitude + relative.longitude;

      // Normalize latitude with pole-crossing logic, adjusting longitude by 180°
      // each time we reflect over a pole.
      while (newLat > 90) {
        newLat = 180 - newLat;
        newLon += 180;
      }
      while (newLat < -90) {
        newLat = -180 - newLat;
        newLon += 180;
      }

      // Wrap longitude into [0, 360)
      while (newLon >= 360) newLon -= 360;
      while (newLon < 0) newLon += 360;

      return GlobeCoordinates(newLat, newLon);
    }).toList();
  }

  /// Creates a standard trailing pattern with the specified number of segments.
  /// The trail will extend behind the point in the direction of movement.
  static List<GlobeCoordinates> createTrailingPattern({
    required int segmentCount,
    required double segmentSpacing,
    double directionLat = -0.25, // Default backward direction
    double directionLon = 0.0,
  }) {
    final List<GlobeCoordinates> pattern = [];
    
    for (int i = 0; i < segmentCount; i++) {
      final double factor = i.toDouble();
      pattern.add(GlobeCoordinates(
        directionLat * factor * segmentSpacing,
        directionLon * factor * segmentSpacing,
      ));
    }
    
    return pattern;
  }

  /// Creates a curved trailing pattern that follows a specific direction.
  static List<GlobeCoordinates> createCurvedTrailingPattern({
    required int segmentCount,
    required double segmentSpacing,
    required double curvature,
    double directionLat = -0.25,
    double directionLon = 0.0,
  }) {
    final List<GlobeCoordinates> pattern = [];
    
    for (int i = 0; i < segmentCount; i++) {
      final double factor = i.toDouble();
      final double curve = curvature * factor * factor * 0.01;
      
      pattern.add(GlobeCoordinates(
        directionLat * factor * segmentSpacing,
        directionLon * factor * segmentSpacing + curve,
      ));
    }
    
    return pattern;
  }
} 

/// GPU shader-based trail attachment. Holds parameters needed by the fragment shader
/// to render a single tapered ribbon behind a moving point.
class ShaderTrailAttachment {
  /// Unique identifier for this trail attachment (also used as a draw key).
  final String id;

  /// The ID of the point this trail follows.
  final String pointId;

  /// Relative trail vertices in globe coordinates (tail→head offsets).
  ///
  /// When provided, the GPU renderer will project these vertices to screen
  /// space each frame and draw a chain of short ribbon segments along them.
  /// This mirrors the CPU trail curvature and ensures the trail remains fixed
  /// relative to the globe during rotation.
  ///
  /// If empty, the renderer falls back to a single straight ribbon based on the
  /// last-frame 2D motion direction (legacy behavior).
  final List<GlobeCoordinates> relativeVertices;

  /// Trail length in degrees (approx great-circle distance from head to tail).
  final double lengthDegrees;

  /// Trail width in degrees at the tail. Head width is controlled by the shader.
  final double widthDegrees;

  /// Gradient colors from tail to head. When null, uses [tailColor] → [headColor].
  final List<Color>? gradientStops;

  /// Tail color (used when [gradientStops] is null).
  final Color tailColor;

  /// Head color (used when [gradientStops] is null).
  final Color headColor;

  /// Glow color for the outer halo.
  final Color glowColor;

  /// Glow intensity multiplier (0 disables glow).
  final double glowStrength;

  /// Optional shimmer intensity (0 to disable; small values like 0.2 recommended).
  final double shimmer;

  /// Additional altitude offset relative to the point altitude.
  final double altitudeOffset;

  /// Multiplier for head width vs tail (matches CPU TrailStyle.headWidthMultiplier).
  final double headWidthMultiplier;

  const ShaderTrailAttachment({
    required this.id,
    required this.pointId,
    this.relativeVertices = const <GlobeCoordinates>[],
    this.lengthDegrees = 2.0,
    this.widthDegrees = 0.1,
    this.gradientStops,
    this.tailColor = const Color(0x3300BFFF),
    this.headColor = const Color(0xE6FFFFFF),
    this.glowColor = const Color(0x3300BFFF),
    this.glowStrength = 1.0,
    this.shimmer = 0.0,
    this.altitudeOffset = 0.0,
    this.headWidthMultiplier = 2.0,
  });

  ShaderTrailAttachment copyWith({
    String? id,
    String? pointId,
    List<GlobeCoordinates>? relativeVertices,
    double? lengthDegrees,
    double? widthDegrees,
    List<Color>? gradientStops,
    Color? tailColor,
    Color? headColor,
    Color? glowColor,
    double? glowStrength,
    double? shimmer,
    double? altitudeOffset,
    double? headWidthMultiplier,
  }) {
    return ShaderTrailAttachment(
      id: id ?? this.id,
      pointId: pointId ?? this.pointId,
      relativeVertices: relativeVertices ?? this.relativeVertices,
      lengthDegrees: lengthDegrees ?? this.lengthDegrees,
      widthDegrees: widthDegrees ?? this.widthDegrees,
      gradientStops: gradientStops ?? this.gradientStops,
      tailColor: tailColor ?? this.tailColor,
      headColor: headColor ?? this.headColor,
      glowColor: glowColor ?? this.glowColor,
      glowStrength: glowStrength ?? this.glowStrength,
      shimmer: shimmer ?? this.shimmer,
      altitudeOffset: altitudeOffset ?? this.altitudeOffset,
      headWidthMultiplier: headWidthMultiplier ?? this.headWidthMultiplier,
    );
  }
}