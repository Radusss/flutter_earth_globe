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
  List<GlobeCoordinates> generateAbsoluteVertices(GlobeCoordinates pointPosition) {
    return relativeVertices.map((relative) {
      double newLat = pointPosition.latitude + relative.latitude;
      double newLon = pointPosition.longitude + relative.longitude;
      
      // Handle longitude wrapping
      if (newLon >= 360) newLon -= 360;
      if (newLon < 0) newLon += 360;
      
      // Clamp latitude to valid range
      newLat = newLat.clamp(-90.0, 90.0);
      
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