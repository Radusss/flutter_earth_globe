import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_earth_globe/shader_trail_renderer.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'globe_coordinates.dart';
import 'line_helper.dart';
import 'math_helper.dart';
import 'point.dart';
import 'point_connection.dart';
import 'point_connection_style.dart';
import 'satellite.dart';
import 'trail.dart';
import 'trail_attachment.dart';

/// Calculated position data for a point on the globe
class PointRenderData {
  final String id;
  final Offset position2D;
  final double depth; // 0-1, higher = closer to camera
  final bool isVisible;
  final Point point;
  final double transitionProgress; // 0-1 for fade in animation

  // 3D surface normal for tilt effect (Globe.GL style)
  final double normalX; // Surface normal x component (towards camera)
  final double normalY; // Surface normal y component (horizontal)
  final double normalZ; // Surface normal z component (vertical)
  final double
      tiltAngle; // Angle from camera view (0 = facing camera, pi/2 = edge)

  PointRenderData({
    required this.id,
    required this.position2D,
    required this.depth,
    required this.isVisible,
    required this.point,
    this.transitionProgress = 1.0,
    this.normalX = 1.0,
    this.normalY = 0.0,
    this.normalZ = 0.0,
    this.tiltAngle = 0.0,
  });
}

/// Calculated position data for an arc/connection on the globe
class ArcRenderData {
  final String id;
  final Offset start2D;
  final Offset end2D;
  final Offset
      control2D; // Bezier control point (legacy, kept for compatibility)
  final Offset midPoint2D;
  final List<Offset> arcPoints2D; // Points along the great circle arc
  final List<bool> arcPointsVisible; // Visibility of each arc point
  final bool isStartVisible;
  final bool isEndVisible;
  final bool isMidVisible;
  final AnimatedPointConnection connection;
  final double transitionProgress; // 0-1 for fade in animation
  final double growthProgress; // 0-1 for arc growth animation
  final double dashOffset; // Current dash animation offset

  ArcRenderData({
    required this.id,
    required this.start2D,
    required this.end2D,
    required this.control2D,
    required this.midPoint2D,
    required this.arcPoints2D,
    required this.arcPointsVisible,
    required this.isStartVisible,
    required this.isEndVisible,
    required this.isMidVisible,
    required this.connection,
    this.transitionProgress = 1.0,
    this.growthProgress = 1.0,
    this.dashOffset = 0.0,
  });
}

/// Calculated position data for a satellite on the globe
class SatelliteRenderData {
  final String id;
  final Offset position2D;
  final double depth; // 0-1, higher = closer to camera
  final bool isVisible;
  final Satellite satellite;
  final double transitionProgress; // 0-1 for fade in animation
  final GlobeCoordinates
      currentPosition; // Current position (for orbiting satellites)

  // 3D surface normal for tilt effect
  final double normalX;
  final double normalY;
  final double normalZ;
  final double tiltAngle;

  // Orbit path points (if showOrbitPath is enabled)
  final List<Offset>? orbitPath2D;
  final List<bool>? orbitPathVisible;

  SatelliteRenderData({
    required this.id,
    required this.position2D,
    required this.depth,
    required this.isVisible,
    required this.satellite,
    required this.currentPosition,
    this.transitionProgress = 1.0,
    this.normalX = 1.0,
    this.normalY = 0.0,
    this.normalZ = 0.0,
    this.tiltAngle = 0.0,
    this.orbitPath2D,
    this.orbitPathVisible,
  });
}

/// Calculated position data for a trail on the globe
class TrailRenderData {
  final String id;
  final Trail trail;
  final List<Offset> points2D;
  final List<bool> pointsVisible;
  final double transitionProgress; // 0-1 for fade in animation

  TrailRenderData({
    required this.id,
    required this.trail,
    required this.points2D,
    required this.pointsVisible,
    this.transitionProgress = 1.0,
  });
}

/// Manages transition animations for points and connections
class TransitionState {
  final DateTime addedAt;
  double transitionProgress;
  double growthProgress;

  TransitionState({
    required this.addedAt,
    this.transitionProgress = 0.0,
    this.growthProgress = 0.0,
  });
}

/// Globe.GL-style foreground renderer for points and connections.
///
/// This class calculates positions for all elements and renders them
/// with proper animations, transitions, and GPU acceleration where possible.
class GlobeForegroundRenderer {
  // Transition states for animations
  final Map<String, TransitionState> _pointTransitions = {};
  final Map<String, TransitionState> _connectionTransitions = {};
  final Map<String, TransitionState> _satelliteTransitions = {};
  final Map<String, TransitionState> _trailTransitions = {};

  // Time tracking for dash animations
  DateTime? _lastFrameTime;

  // Accumulated dash offsets per connection (for continuous animation)
  final Map<String, double> _dashOffsets = {};

  /// Calculate render data for all points
  List<PointRenderData> calculatePointPositions({
    required List<Point> points,
    required double radius,
    required double rotationY,
    required double rotationZ,
    required Size canvasSize,
    required DateTime now,
  }) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final List<PointRenderData> result = [];

    for (final point in points) {
      // Initialize transition if new point
      if (!_pointTransitions.containsKey(point.id)) {
        _pointTransitions[point.id] = TransitionState(addedAt: now);
      }

      // Update transition progress
      final transition = _pointTransitions[point.id]!;
      final elapsed = now.difference(transition.addedAt).inMilliseconds;
      final duration = point.style.transitionDuration;
      transition.transitionProgress =
          duration > 0 ? (elapsed / duration).clamp(0.0, 1.0) : 1.0;

      // Calculate 3D position
      // Apply altitude to the point position
      final pointRadius = radius + point.altitude;
      final cartesian3D = getSpherePosition3D(
        point.coordinates,
        pointRadius,
        rotationY,
        rotationZ,
      );

      // Project to 2D
      final position2D = Offset(
        center.dx + cartesian3D.y,
        center.dy - cartesian3D.z,
      );

      // Visibility check (front-facing)
      final isVisible = cartesian3D.x > 0;

      // Depth calculation for scaling (normalized 0-1)
      final depth = isVisible ? (cartesian3D.x / pointRadius).clamp(0.0, 1.0) : 0.0;

      // Calculate surface normal (normalized cartesian3D is the surface normal)
      // This gives us the direction the surface is facing
      final normalX = cartesian3D.x / pointRadius; // Towards camera
      final normalY = cartesian3D.y / pointRadius; // Horizontal
      final normalZ = cartesian3D.z / pointRadius; // Vertical

      // Tilt angle: angle between surface normal and camera direction (1,0,0)
      // cos(angle) = dot(normal, cameraDir) = normalX
      final tiltAngle = math.acos(normalX.clamp(-1.0, 1.0));

      result.add(PointRenderData(
        id: point.id,
        position2D: position2D,
        depth: depth,
        isVisible: isVisible,
        point: point,
        transitionProgress: transition.transitionProgress,
        normalX: normalX,
        normalY: normalY,
        normalZ: normalZ,
        tiltAngle: tiltAngle,
      ));
    }

    // Sort by depth (back to front) for proper overlapping
    result.sort((a, b) => a.depth.compareTo(b.depth));

    return result;
  }

  /// Calculate render data for all connections (Globe.GL style)
  List<ArcRenderData> calculateConnectionPositions({
    required List<AnimatedPointConnection> connections,
    required double radius,
    required double rotationY,
    required double rotationZ,
    required Size canvasSize,
    required DateTime now,
  }) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final List<ArcRenderData> result = [];

    // Calculate delta time for dash animation
    final deltaMs = _lastFrameTime != null
        ? now.difference(_lastFrameTime!).inMilliseconds.toDouble()
        : 16.0;
    _lastFrameTime = now;

    for (final connection in connections) {
      // Initialize transition if new connection
      if (!_connectionTransitions.containsKey(connection.id)) {
        _connectionTransitions[connection.id] = TransitionState(addedAt: now);
        _dashOffsets[connection.id] = 0.0;
      }

      final transition = _connectionTransitions[connection.id]!;
      final elapsed = now.difference(transition.addedAt).inMilliseconds;

      // Update transition (fade in) progress
      final transitionDuration = connection.style.transitionDuration;
      transition.transitionProgress = transitionDuration > 0
          ? (elapsed / transitionDuration).clamp(0.0, 1.0)
          : 1.0;

      // Update growth animation progress
      final growthDuration = connection.style.growthAnimationDuration;
      if (connection.style.animateOnAdd) {
        transition.growthProgress = growthDuration > 0
            ? (elapsed / growthDuration).clamp(0.0, 1.0)
            : 1.0;
      } else {
        transition.growthProgress = 1.0;
      }

      // Update dash animation offset
      // Animate if dashAnimateTime is set (like Globe.GL's dashAnimateTime prop)
      // OR if isMoving is true (legacy behavior)
      if (connection.style.dashAnimateTime > 0 || connection.isMoving) {
        final animateTime = connection.style.dashAnimateTime > 0
            ? connection.style.dashAnimateTime
            : 1000.0; // Default 1 second if just isMoving
        final dashSpeed = 1.0 / animateTime;
        final dashIncrement = deltaMs * dashSpeed;
        _dashOffsets[connection.id] =
            ((_dashOffsets[connection.id] ?? 0.0) + dashIncrement) % 1.0;
      }

      // === Globe.GL Style Arc Calculation ===
      // Get 3D positions
      final startVec =
          getSpherePosition3D(connection.start, radius, rotationY, rotationZ);
      final endVec =
          getSpherePosition3D(connection.end, radius, rotationY, rotationZ);

      // Project to 2D
      final start2D = Offset(center.dx + startVec.y, center.dy - startVec.z);
      final end2D = Offset(center.dx + endVec.y, center.dy - endVec.z);

      // Calculate arc using Globe.GL's method:
      // altitude = geoDistance / 2 * altAutoScale (default 0.5)
      final centralAngle =
          calculateCentralAngle(connection.start, connection.end);
      final geoDistance = centralAngle; // In degreesToRadians, proportional to distance

      // Globe.GL default: altitude = distance/2 * 0.5 = distance/4
      // Scaled by curveScale for user control
      final altitude = (geoDistance / 2) * 0.5 * connection.curveScale;
      final arcAltitude = radius * altitude;

      // Generate arc points - use more segments for smoother edge transitions
      // Higher resolution prevents visible "stepping" when arc disappears at sphere edge
      const numSegments =
          1000; // Higher than Globe.GL default for smoother clipping
      final List<Offset> arcPoints2D = [];
      final List<bool> arcPointsVisible = [];

      // Normalized start/end vectors
      final startNorm = startVec.normalized();
      final endNorm = endVec.normalized();

      for (int i = 0; i <= numSegments; i++) {
        final t = i / numSegments;

        // Spherical interpolation for the base point on the sphere
        final sinAngle = math.sin(centralAngle);
        double baseX, baseY, baseZ;

        if (sinAngle > 0.0001) {
          final a = math.sin((1 - t) * centralAngle) / sinAngle;
          final b = math.sin(t * centralAngle) / sinAngle;
          baseX = a * startNorm.x + b * endNorm.x;
          baseY = a * startNorm.y + b * endNorm.y;
          baseZ = a * startNorm.z + b * endNorm.z;
        } else {
          baseX = startNorm.x * (1 - t) + endNorm.x * t;
          baseY = startNorm.y * (1 - t) + endNorm.y * t;
          baseZ = startNorm.z * (1 - t) + endNorm.z * t;
        }

        // Normalize base point
        final baseLen =
            math.sqrt(baseX * baseX + baseY * baseY + baseZ * baseZ);
        if (baseLen > 0) {
          baseX /= baseLen;
          baseY /= baseLen;
          baseZ /= baseLen;
        }

        // Globe.GL altitude profile: smooth curve peaking at middle
        // Using sine profile for smoother arc (similar to Globe.GL's bezier)
        final altFactor = math.sin(t * math.pi);
        final currentAltitude = arcAltitude * altFactor;
        final currentRadius = radius + currentAltitude;

        // Final 3D position
        final arcX = baseX * currentRadius;
        final arcY = baseY * currentRadius;
        final arcZ = baseZ * currentRadius;

        // Project to 2D
        final point2D = Offset(center.dx + arcY, center.dy - arcZ);
        arcPoints2D.add(point2D);

        // Visibility check: for elevated arcs, we need to check if the point
        // would be occluded by the sphere.
        // In 2D projection, the sphere appears as a circle of radius `radius`.
        // An arc point at (arcX, arcY, arcZ) is visible if:
        // 1. It's in front of the sphere (arcX > 0), OR
        // 2. It's elevated above the sphere's visible edge
        //
        // For smooth edge transitions, we use the actual 3D geometry:
        // The visible horizon of the sphere is at x=0 (camera at infinity on +X).
        // For an elevated point at radius R+altitude, it becomes hidden when
        // arcX becomes negative enough that the sphere surface blocks it.

        final projectedDistFromCenter = math.sqrt(arcY * arcY + arcZ * arcZ);

        // For elevated arcs: calculate if the point is above the sphere's silhouette
        // The sphere silhouette is a circle of radius `radius` in the YZ plane
        // An elevated point appears "above" the silhouette if its 2D projection
        // is outside this circle
        final isAboveSilhouette =
            projectedDistFromCenter > radius && currentAltitude > 0;

        // For the front/back check, use a slightly lenient threshold
        // This prevents harsh cutting exactly at x=0
        // Points just behind the center plane but elevated should still show
        final horizonThreshold = -currentAltitude * 0.3;
        final isInFrontEnough = arcX > horizonThreshold;

        arcPointsVisible.add(isInFrontEnough || isAboveSilhouette);
      }

      // Calculate midpoint for label
      const midIdx = numSegments ~/ 2;
      final midPoint2D = arcPoints2D[midIdx];

      // Legacy control point
      var midPoint3D = (startVec + endVec) / 2;
      midPoint3D.normalize();
      midPoint3D.scale(radius + arcAltitude);
      final control2D =
          Offset(center.dx + midPoint3D.y, center.dy - midPoint3D.z);

      result.add(ArcRenderData(
        id: connection.id,
        start2D: start2D,
        end2D: end2D,
        control2D: control2D,
        midPoint2D: midPoint2D,
        arcPoints2D: arcPoints2D,
        arcPointsVisible: arcPointsVisible,
        isStartVisible: startVec.x > 0,
        isEndVisible: endVec.x > 0,
        isMidVisible: midPoint3D.x > 0,
        connection: connection,
        transitionProgress: transition.transitionProgress,
        growthProgress: transition.growthProgress,
        dashOffset: _dashOffsets[connection.id] ?? 0.0,
      ));
    }

    return result;
  }

  /// Calculate render data for all satellites
  List<SatelliteRenderData> calculateSatellitePositions({
    required List<Satellite> satellites,
    required double radius,
    required double rotationY,
    required double rotationZ,
    required Size canvasSize,
    required DateTime now,
  }) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final List<SatelliteRenderData> result = [];

    for (final satellite in satellites) {
      // Initialize transition if new satellite
      if (!_satelliteTransitions.containsKey(satellite.id)) {
        _satelliteTransitions[satellite.id] = TransitionState(addedAt: now);
      }

      // Update transition progress
      final transition = _satelliteTransitions[satellite.id]!;
      final elapsed = now.difference(transition.addedAt).inMilliseconds;
      final duration = satellite.style.transitionDuration;
      transition.transitionProgress =
          duration > 0 ? (elapsed / duration).clamp(0.0, 1.0) : 1.0;

      // Get current position (handles orbiting satellites)
      final currentPosition = satellite.getPositionAtTime(now);

      // Calculate satellite radius (globe radius + altitude)
      final satelliteRadius = radius * (1.0 + satellite.altitude);

      // Calculate 3D position at the satellite's altitude
      final cartesian3D = getSpherePosition3D(
        currentPosition,
        satelliteRadius,
        rotationY,
        rotationZ,
      );

      // Project to 2D
      final position2D = Offset(
        center.dx + cartesian3D.y,
        center.dy - cartesian3D.z,
      );

      // Visibility check - satellites above the globe can be visible even when
      // coordinates are "behind" the globe
      // Use the same logic as arc points for elevated objects
      final projectedDistFromCenter = math
          .sqrt(cartesian3D.y * cartesian3D.y + cartesian3D.z * cartesian3D.z);
      final isAboveSilhouette =
          projectedDistFromCenter > radius && satellite.altitude > 0;
      final horizonThreshold = -satellite.altitude * radius * 0.3;
      final isVisible = cartesian3D.x > horizonThreshold || isAboveSilhouette;

      // Depth calculation for scaling (normalized 0-1)
      final depth =
          isVisible ? (cartesian3D.x / satelliteRadius).clamp(0.0, 1.0) : 0.0;

      // Calculate surface normal
      final normalX = cartesian3D.x / satelliteRadius;
      final normalY = cartesian3D.y / satelliteRadius;
      final normalZ = cartesian3D.z / satelliteRadius;
      final tiltAngle = math.acos(normalX.clamp(-1.0, 1.0));

      // Calculate orbit path if enabled
      List<Offset>? orbitPath2D;
      List<bool>? orbitPathVisible;

      if (satellite.style.showOrbitPath && satellite.orbit != null) {
        orbitPath2D = [];
        orbitPathVisible = [];

        // Generate orbit path points
        const numOrbitPoints = 360;
        final orbitPeriod = satellite.orbit!.period;

        for (int i = 0; i <= numOrbitPoints; i++) {
          final t = i / numOrbitPoints;
          final orbitTime = satellite.referenceTime.add(
            Duration(milliseconds: (orbitPeriod.inMilliseconds * t).round()),
          );

          final orbitPos = satellite.orbit!
              .getPositionAtTime(orbitTime, satellite.referenceTime);
          final orbitCartesian = getSpherePosition3D(
            orbitPos,
            satelliteRadius,
            rotationY,
            rotationZ,
          );

          final orbitPoint2D = Offset(
            center.dx + orbitCartesian.y,
            center.dy - orbitCartesian.z,
          );
          orbitPath2D.add(orbitPoint2D);

          // Visibility check for orbit path
          final orbitProjDist = math.sqrt(orbitCartesian.y * orbitCartesian.y +
              orbitCartesian.z * orbitCartesian.z);
          final orbitAboveSilhouette =
              orbitProjDist > radius && satellite.altitude > 0;
          final orbitHorizonThreshold = -satellite.altitude * radius * 0.3;
          orbitPathVisible.add(
              orbitCartesian.x > orbitHorizonThreshold || orbitAboveSilhouette);
        }
      }

      result.add(SatelliteRenderData(
        id: satellite.id,
        position2D: position2D,
        depth: depth,
        isVisible: isVisible,
        satellite: satellite,
        currentPosition: currentPosition,
        transitionProgress: transition.transitionProgress,
        normalX: normalX,
        normalY: normalY,
        normalZ: normalZ,
        tiltAngle: tiltAngle,
        orbitPath2D: orbitPath2D,
        orbitPathVisible: orbitPathVisible,
      ));
    }

    // Sort by depth (back to front) for proper overlapping
    result.sort((a, b) => a.depth.compareTo(b.depth));

    return result;
  }

  /// Calculate render data for all trails
  List<TrailRenderData> calculateTrailPositions({
    required List<Trail> trails,
    required double radius,
    required double rotationY,
    required double rotationZ,
    required Size canvasSize,
    required DateTime now,
  }) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final List<TrailRenderData> result = [];

    for (final trail in trails) {
      // Initialize transition if new trail
      if (!_trailTransitions.containsKey(trail.id)) {
        _trailTransitions[trail.id] = TransitionState(addedAt: now);
      }
      final transition = _trailTransitions[trail.id]!;
      // Simple fade in
      transition.transitionProgress = 1.0; 

      final points2D = <Offset>[];
      final pointsVisible = <bool>[];
      
      final trailAltitude = radius * trail.altitude;
      final trailRadius = radius + trailAltitude;

      for (final vertex in trail.vertices) {
        final vec = getSpherePosition3D(vertex, trailRadius, rotationY, rotationZ);
        final pos2D = Offset(center.dx + vec.y, center.dy - vec.z);
        points2D.add(pos2D);

        // Visibility check
        final projectedDist = math.sqrt(vec.y * vec.y + vec.z * vec.z);
        final isAboveSilhouette = projectedDist > radius && trail.altitude > 0;
        final horizonThreshold = -trail.altitude * radius * 0.3;
        final isVisible = vec.x > horizonThreshold || isAboveSilhouette;
        pointsVisible.add(isVisible);
      }

      result.add(TrailRenderData(
        id: trail.id,
        trail: trail,
        points2D: points2D,
        pointsVisible: pointsVisible,
        transitionProgress: transition.transitionProgress,
      ));
    }

    return result;
  }

  /// Clean up transitions for removed elements
  void cleanupRemovedElements(
      List<Point> points, List<AnimatedPointConnection> connections,
      [List<Satellite>? satellites, List<Trail>? trails]) {
    final pointIds = points.map((p) => p.id).toSet();
    final connectionIds = connections.map((c) => c.id).toSet();

    _pointTransitions.removeWhere((key, _) => !pointIds.contains(key));
    _connectionTransitions
        .removeWhere((key, _) => !connectionIds.contains(key));
    _dashOffsets.removeWhere((key, _) => !connectionIds.contains(key));

    if (satellites != null) {
      final satelliteIds = satellites.map((s) => s.id).toSet();
      _satelliteTransitions
          .removeWhere((key, _) => !satelliteIds.contains(key));
    }
    
    if (trails != null) {
      final trailIds = trails.map((t) => t.id).toSet();
      _trailTransitions.removeWhere((key, _) => !trailIds.contains(key));
    }
  }
}

/// GPU-accelerated foreground painter using Fragment Shaders
class GpuForegroundPainter extends CustomPainter {
  final List<PointRenderData> points;
  final List<ArcRenderData> arcs;
  final List<SatelliteRenderData> satellites;
  final List<TrailRenderData> trails;
  final List<ShaderTrailAttachment> shaderTrails;
  final double radius;
  final Offset center;
  final Offset? hoverPoint;
  final Offset? clickPoint;
  final double rotationY;
  final double rotationZ;

  // Whether to skip satellite shape drawing (when using GPU shader for satellites)
  // Orbit paths and labels will still be drawn via Canvas
  final bool skipSatelliteShapes;

  // Callbacks
  final void Function(
          String pointId, Offset? position, bool isHovering, bool isVisible)?
      onPointHover;
  final void Function(String connectionId, Offset? position, bool isHovering,
      bool isVisible)? onConnectionHover;
  final void Function(String satelliteId, Offset? position, bool isHovering,
      bool isVisible)? onSatelliteHover;
  final VoidCallback? onPointClicked;

  // Previous state for change detection
  final String? previousHoveredPointId;
  final String? previousHoveredConnectionId;
  final String? previousHoveredSatelliteId;

  // Helper to get the last head position for shader trails
  final Offset? Function(String pointId)? getLastHead2D;
  final void Function(String pointId, Offset position)? setLastHead2D;

  GpuForegroundPainter({
    required this.points,
    required this.arcs,
    required this.satellites,
    this.trails = const [],
    this.shaderTrails = const [],
    required this.radius,
    required this.center,
    this.hoverPoint,
    this.clickPoint,
    this.rotationY = 0.0,
    this.rotationZ = 0.0,
    this.skipSatelliteShapes = false,
    this.onPointHover,
    this.onConnectionHover,
    this.onSatelliteHover,
    this.onPointClicked,
    this.previousHoveredPointId,
    this.previousHoveredConnectionId,
    this.previousHoveredSatelliteId,
    this.getLastHead2D,
    this.setLastHead2D,
  });

  @override
  void paint(Canvas canvas, Size size) {
    String? currentHoveredPointId;
    String? currentHoveredConnectionId;
    bool clickHandled = false;

    // Draw shader trails (GPU accelerated)
    if (shaderTrails.isNotEmpty) {
      for (final attachment in shaderTrails) {
        _drawShaderTrail(canvas, attachment, size);
      }
    }

    // Draw trails first (lowest layer)
    for (final trail in trails) {
      _drawTrail(canvas, trail, size);
    }

    // Draw points first (behind arcs)
    for (final point in points) {
      if (!point.isVisible) {
        onPointHover?.call(point.id, point.position2D, false, false);
        continue;
      }

      _drawPoint(canvas, point);

      // Draw label (non-builder labels)
      if (point.point.isLabelVisible &&
          point.point.label != null &&
          point.point.label!.isNotEmpty &&
          point.point.labelBuilder == null) {
        _drawLabel(canvas, point.point.label!, point.point.labelTextStyle,
            point.position2D, size);
      }
    }

    // Draw arcs (on top of points)
    for (final arc in arcs) {
      // Check if any portion of the arc is visible (elevated arcs can peek over horizon)
      final hasVisiblePortion = arc.arcPointsVisible.any((v) => v);
      if (!hasVisiblePortion) {
        onConnectionHover?.call(arc.id, arc.midPoint2D, false, false);
        continue;
      }

      final path = _drawArc(canvas, arc, size);

      if (path != null) {
        // Check hover on arc (arcs have priority over points since they're on top)
        final isHovering = currentHoveredConnectionId == null &&
            hoverPoint != null &&
            _isPointOnPath(hoverPoint!, path, arc.connection.strokeWidth + 4);

        if (isHovering) {
          currentHoveredConnectionId = arc.id;
          if (arc.id != previousHoveredConnectionId) {
            arc.connection.onHover?.call();
          }
        }

        onConnectionHover?.call(arc.id, arc.midPoint2D, isHovering, true);

        // Handle click on arc first (since arcs are on top)
        if (!clickHandled &&
            clickPoint != null &&
            _isPointOnPath(clickPoint!, path, arc.connection.strokeWidth + 4)) {
          // Defer callback to after paint to avoid triggering widget builds during paint
          final callback = arc.connection.onTap;
          if (callback != null) {
            SchedulerBinding.instance.addPostFrameCallback((_) => callback());
          }
          onPointClicked?.call();
          clickHandled = true;
        }
      } else {
        onConnectionHover?.call(arc.id, arc.midPoint2D, false, false);
      }
    }

    // Handle point hover/click after drawing (points are behind arcs but still interactive)
    for (final point in points) {
      if (!point.isVisible) continue;

      // Calculate hit rect for hover/click
      final scaledSize = point.point.style.size * (0.7 + 0.6 * point.depth);
      final hitRect = Rect.fromCenter(
        center: point.position2D,
        width: scaledSize * 2 + 8, // Add padding for easier clicking
        height: scaledSize * 2 + 8,
      );

      final isHovering = currentHoveredPointId == null &&
          currentHoveredConnectionId == null && // Arc hover takes priority
          hoverPoint != null &&
          hitRect.contains(hoverPoint!);

      if (isHovering) {
        currentHoveredPointId = point.id;
        if (point.id != previousHoveredPointId) {
          point.point.onHover?.call();
        }
      }

      onPointHover?.call(
          point.id, point.position2D, isHovering, point.isVisible);

      // Handle click (arcs already handled, so only if not already clicked)
      if (!clickHandled &&
          clickPoint != null &&
          hitRect.contains(clickPoint!)) {
        // Defer callback to after paint to avoid triggering widget builds during paint
        final callback = point.point.onTap;
        if (callback != null) {
          SchedulerBinding.instance.addPostFrameCallback((_) => callback());
        }
        onPointClicked?.call();
        clickHandled = true;
      }
    }

    // Draw satellites (on top of arcs, as they are elevated objects)
    String? currentHoveredSatelliteId;
    for (final satellite in satellites) {
      if (!satellite.isVisible) {
        onSatelliteHover?.call(
            satellite.id, satellite.position2D, false, false);
        continue;
      }

      // Draw orbit path first (behind the satellite) - always use Canvas for paths
      if (satellite.orbitPath2D != null && satellite.orbitPathVisible != null) {
        _drawOrbitPath(canvas, satellite);
      }

      // Draw the satellite shape (skip if using GPU shader for satellite shapes)
      if (!skipSatelliteShapes) {
        _drawSatellite(canvas, satellite);
      }

      // Draw label (non-builder labels) - always use Canvas for labels
      if (satellite.satellite.isLabelVisible &&
          satellite.satellite.label != null &&
          satellite.satellite.label!.isNotEmpty &&
          satellite.satellite.labelBuilder == null) {
        _drawLabel(
            canvas,
            satellite.satellite.label!,
            satellite.satellite.labelTextStyle,
            satellite.position2D + satellite.satellite.labelOffset,
            size);
      }

      // Calculate hit rect for hover/click
      final scaledSize =
          satellite.satellite.style.size * (0.7 + 0.6 * satellite.depth);
      final hitRect = Rect.fromCenter(
        center: satellite.position2D,
        width: scaledSize * 2 + 8,
        height: scaledSize * 2 + 8,
      );

      final isHovering = currentHoveredSatelliteId == null &&
          currentHoveredConnectionId == null &&
          currentHoveredPointId == null &&
          hoverPoint != null &&
          hitRect.contains(hoverPoint!);

      if (isHovering) {
        currentHoveredSatelliteId = satellite.id;
        if (satellite.id != previousHoveredSatelliteId) {
          satellite.satellite.onHover?.call();
        }
      }

      onSatelliteHover?.call(
          satellite.id, satellite.position2D, isHovering, true);

      // Handle click
      if (!clickHandled &&
          clickPoint != null &&
          hitRect.contains(clickPoint!)) {
        // Defer callback to after paint to avoid triggering widget builds during paint
        final callback = satellite.satellite.onTap;
        if (callback != null) {
          SchedulerBinding.instance.addPostFrameCallback((_) => callback());
        }
        onPointClicked?.call();
        clickHandled = true;
      }
    }
  }

  void _drawShaderTrail(
      Canvas canvas, ShaderTrailAttachment attachment, Size size) {
    // Find the point this trail is attached to
    final pointData = points
        .where((p) => p.id == attachment.pointId)
        .firstOrNull; // O(N) lookup per trail, acceptable for small counts

    if (pointData == null) return;

    // Check if we have relative vertices to define the trail shape (curved trail)
    if (attachment.relativeVertices.isNotEmpty) {
      _drawCurvedShaderTrail(canvas, attachment, pointData, size);
      return;
    }

    // Calculate head position
    // For shader trails, we want the 2D position on screen
    final head = pointData.position2D;

    // Calculate direction for trail
    // If we have a previous position, use that to determine direction
    Offset direction = const Offset(0, 1); // Default down
    final lastHead = getLastHead2D?.call(attachment.pointId);

    if (lastHead != null) {
      final diff = lastHead - head;
      if (diff.distance > 0.1) {
        direction = diff;
      }
    }

    // Update last head position for next frame
    // We do this during paint which is suboptimal but convenient
    // Better to do in the calculation phase
    setLastHead2D?.call(attachment.pointId, head);

    // Calculate trail properties
    // Use proper spherical scaling
    // width in pixels = radius * width_in_radians
    // Ensure minimum width for visibility
    final widthPx = math.max(
      radius * degreesToRadians(attachment.widthDegrees),
      1.5,
    );
    final lengthPx = radius * degreesToRadians(attachment.lengthDegrees);

    // Draw using the shader renderer
    // Calculate a bounding box for the trail (rough estimate)
    final bounds = Rect.fromCenter(
      center: head + direction * 0.5, // Offset slightly
      width: math.max(lengthPx, widthPx) * 4,
      height: math.max(lengthPx, widthPx) * 4,
    );

    // Calculate visibility for masking
    // A trail attached to a point behind the globe should be masked if it's not "high" enough
    // to peek over the horizon.
    // However, the shader handles the actual masking logic based on the maskOutsideOnly flag.
    // If maskOutsideOnly is true, the shader only draws parts of the trail that are OUTSIDE the globe circle.
    // This is useful for trails coming from behind the globe - we want to see the part sticking out,
    // but not the part that should be occluded by the sphere.
    
    // Check if the attachment point is on the front hemisphere
    final isFront = pointData.isVisible; // isVisible is true if x > 0 (front hemisphere)
    
    // Check if the point is "above horizon" (radially outside the globe disk)
    final distFromCenter = (head - center).distance;
    final isAboveHorizon = distFromCenter > radius;
    
    // We should mask if the point is BEHIND the globe (not front).
    // If it's behind, we set maskOutsideOnly = true, which means "only draw the part outside the globe circle".
    // This correctly handles:
    // 1. Behind and inside (hidden) -> Masked out completely (since it's inside)
    // 2. Behind and sticking out (altitude) -> Masked inside, drawn outside (visible)
    final maskOutsideOnly = !isFront;

    ShaderTrailRenderer.instance.drawRibbon(
      canvas: canvas,
      bounds: bounds,
      head: head,
      direction: direction,
      lengthPx: lengthPx,
      widthPx: widthPx,
      headWidthMultiplier: attachment.headWidthMultiplier,
      headColor: attachment.headColor,
      tailColor: attachment.tailColor,
      colorStops: attachment.gradientStops ?? [],
      segmentT0: 1.0, // Head (T=1)
      segmentT1: 0.0, // Tail (T=0) - Reversed from legacy to match color order
      maskOutsideOnly: maskOutsideOnly,
      glowColor: attachment.glowColor,
      glowStrength: attachment.glowStrength,
      shimmer: attachment.shimmer,
      timeSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
      globeCenter: center,
      globeRadius: radius,
      zoom: 1.0, // Zoom already baked into radius/coordinates
      rotationY: rotationY,
      rotationZ: rotationZ,
    );
  }

  void _drawCurvedShaderTrail(
    Canvas canvas,
    ShaderTrailAttachment attachment,
    PointRenderData pointData,
    Size size,
  ) {
    // 1. Generate absolute coordinates for the trail
    // Use the logic from TrailAttachment to handle pole crossing
    final headCoord = pointData.point.coordinates;
    final vertices = _generateAbsoluteVertices(headCoord, attachment.relativeVertices);
    
    // Prepend the head coordinate so the trail starts exactly at the point
    vertices.insert(0, headCoord);

    if (vertices.length < 2) return;

    // 2. Calculate visibility and projection for all vertices
    final points3D = <Vector3>[];
    final points2D = <Offset>[];
    final isVisible = <bool>[];

    // The trail altitude is additive to the point altitude
    // point.altitude is absolute units (e.g. 10.0)
    // attachment.altitudeOffset is usually relative to radius? Or normalized?
    // Based on previous code radius * (1.0 + offset) implies offset is normalized.
    final trailRadius = radius + pointData.point.altitude + (radius * attachment.altitudeOffset);

    for (final vertex in vertices) {
      final vec = getSpherePosition3D(vertex, trailRadius, rotationY, rotationZ);
      points3D.add(vec);
      points2D.add(Offset(center.dx + vec.y, center.dy - vec.z));
      
      // Visibility check (same as standard trails)
      final projectedDist = math.sqrt(vec.y * vec.y + vec.z * vec.z);
      final isAboveSilhouette = projectedDist > radius && attachment.altitudeOffset > 0;
      final horizonThreshold = -attachment.altitudeOffset * radius * 0.3;
      isVisible.add(vec.x > horizonThreshold || isAboveSilhouette);
    }

    // 3. Draw segments
    final segmentCount = vertices.length - 1;
    // Width scales with zoom (radius is zoomed), but ensure minimum visibility
    final widthPx = math.max(
      radius * degreesToRadians(attachment.widthDegrees),
      1.5,
    );
    
    // Total length for T calculation? 
    // We approximate T based on segment index for uniform distribution
    // Or we could use actual distance, but index based is smoother for animations usually.

    for (int i = 0; i < segmentCount; i++) {
      // Skip if both ends are hidden (and not above horizon/edge case)
      // For robustness, we draw if ANY part is potentially visible or sticking out
      // The shader handles masking for "behind" parts
      final p1 = points2D[i];
      final p2 = points2D[i + 1];
      final v1 = points3D[i];
      // final v2 = points3D[i + 1];
      
      final seg = p1 - p2;
      final segLen = seg.distance;
      
      // When the motion is almost purely toward or away from the camera,
      // the projected 2D length can approach zero. Instead of skipping,
      // render a minimal capsule (dot-like) so the whisper remains visible.
      final double minLenPx = math.max(1.0, widthPx);
      final double ribbonLen = segLen < minLenPx ? minLenPx : segLen;
      final Offset dir2D = segLen > 1e-3 ? (seg / segLen) : const Offset(0, -1);

      final direction = dir2D * ribbonLen;
      final length = ribbonLen;

      // T goes from 1.0 (Head) to 0.0 (Tail)
      // i=0 is Head (T=1). i=segmentCount is Tail (T=0).
      // Segment i goes from T_start to T_end
      final tStart = 1.0 - (i / segmentCount);
      final tEnd = 1.0 - ((i + 1) / segmentCount);

      // Match CPU: width increases from tail to head
      // Increase size difference: stronger ease-in to grow more near the head
      final double eased = tStart * tStart * tStart; // cubic
      final double headMul = 1.0 + (attachment.headWidthMultiplier - 1.0) * eased;

      // Determine masking
      // If the segment start is front-facing, we don't mask.
      // If it's back-facing, we mask (draw only outside).
      final isFront = v1.x > 0;
      final maskOutsideOnly = !isFront;

      final bounds = Rect.fromCenter(
        center: p1 + direction * 0.5,
        width: math.max(length, widthPx) * 4,
        height: math.max(length, widthPx) * 4,
      );

      ShaderTrailRenderer.instance.drawRibbon(
        canvas: canvas,
        bounds: bounds,
        head: p1,
        direction: direction,
        lengthPx: length, // Segment length
        widthPx: widthPx,
        headWidthMultiplier: headMul,
        // Ideally headWidthMultiplier applies to the WHOLE trail. 
        // But here we draw segments. The shader applies taper based on T?
        // If the shader uses T for width, then headWidthMultiplier is fine.
        // If shader uses length for taper, we have a problem.
        // Looking at shader inputs: uWidth, uHeadMul.
        // If shader logic is: width = uWidth * mix(1.0, uHeadMul, t);
        // Then passing global params + local T is correct.
        headColor: attachment.headColor,
        tailColor: attachment.tailColor,
        colorStops: attachment.gradientStops ?? [],
        segmentT0: tStart,
        segmentT1: tEnd,
        maskOutsideOnly: maskOutsideOnly,
        glowColor: attachment.glowColor,
        glowStrength: attachment.glowStrength,
        shimmer: attachment.shimmer,
        timeSeconds: DateTime.now().millisecondsSinceEpoch / 1000.0,
        globeCenter: center,
        globeRadius: radius,
        zoom: 1.0,
        rotationY: rotationY,
        rotationZ: rotationZ,
      );
    }
  }

  List<GlobeCoordinates> _generateAbsoluteVertices(
      GlobeCoordinates start, List<GlobeCoordinates> relatives) {
    return relatives.map((relative) {
      double newLat = start.latitude + relative.latitude;
      double newLon = start.longitude + relative.longitude;

      // Normalize latitude with pole-crossing logic
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

  void _drawTrail(Canvas canvas, TrailRenderData trailData, Size size) {
    if (trailData.points2D.length < 2) return;
    
    final style = trailData.trail.style;
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    bool inPath = false;

    for (int i = 0; i < trailData.points2D.length; i++) {
      final isVisible = trailData.pointsVisible[i];
      final point = trailData.points2D[i];
      
      if (isVisible) {
        if (!inPath) {
          path.moveTo(point.dx, point.dy);
          inPath = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      } else {
        inPath = false;
      }
    }
    
    if (style.useMagicalEffect && style.magicalColors != null && style.magicalColors!.isNotEmpty) {
        // Draw with gradient if magical effect is enabled
        // This is a simplified CPU implementation of the magical effect
        // Real magical effect would require shader or complex gradient stroke
        // Here we just apply the color
        
        // TODO: Implement better gradient stroking if needed for CPU
        canvas.drawPath(path, paint);
    } else {
        canvas.drawPath(path, paint);
    }
  }

  Path? _drawArc(Canvas canvas, ArcRenderData arc, Size size) {
    final connection = arc.connection;

    // Scale relative to globe size
    const baseRadius = 150.0;
    final globeScale = radius / baseRadius;

    // Apply growth animation to animation progress
    final effectiveProgress = arc.growthProgress * connection.animationProgress;
    if (effectiveProgress <= 0) return null;

    // Check for invalid/NaN coordinates
    if (arc.start2D.dx.isNaN ||
        arc.start2D.dy.isNaN ||
        arc.end2D.dx.isNaN ||
        arc.end2D.dy.isNaN) {
      return null;
    }

    // Skip if start and end are the same
    if ((arc.start2D - arc.end2D).distance < 1) {
      return null;
    }

    final paint = Paint()
      ..color = connection.style.color.withAlpha(
          (connection.style.color.a * arc.transitionProgress * 255).round())
      ..strokeWidth = connection.style.lineWidth * globeScale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Build path from pre-calculated arc points (follows great circle on sphere)
    if (arc.arcPoints2D.length < 2) return null;

    // Apply growth animation - limit how far along the arc we draw
    final progressIdx =
        ((arc.arcPoints2D.length - 1) * effectiveProgress).round();
    if (progressIdx < 1) return null;

    // Globe.GL style: draw only the visible segments
    // Build path with gaps where segments are hidden behind the sphere
    final path = Path();
    bool inPath = false;
    int? lastVisibleIdx;

    for (int i = 0; i <= progressIdx; i++) {
      final isVisible = arc.arcPointsVisible[i];
      final point = arc.arcPoints2D[i];

      if (isVisible) {
        if (!inPath) {
          // Starting a new visible segment
          path.moveTo(point.dx, point.dy);
          inPath = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
        lastVisibleIdx = i;
      } else {
        // Hidden segment - end current path segment
        inPath = false;
      }
    }

    // If no visible segments, don't draw
    if (lastVisibleIdx == null) return null;

    // Calculate the visible path for hit detection and styling
    final pathMetricsList = path.computeMetrics().toList();

    if (pathMetricsList.isEmpty) return null;

    // Get total length across all path segments
    double totalLength = 0;
    for (final metric in pathMetricsList) {
      totalLength += metric.length;
    }

    if (totalLength < 1) return null;

    switch (connection.style.type) {
      case PointConnectionType.solid:
        canvas.drawPath(path, paint);
        break;

      case PointConnectionType.dashed:
        final dashLength = connection.style.dashSize * globeScale;
        final gapLength = connection.style.spacing * globeScale;
        final patternLength = dashLength + gapLength;

        // Calculate dash offset based on arc.dashOffset (0-1 normalized)
        final animatedOffset = arc.dashOffset * patternLength;

        // Draw dashes across all path segments
        for (final metric in pathMetricsList) {
          double distance = animatedOffset % patternLength;
          while (distance < metric.length) {
            final startDash = distance;
            final endDash = math.min(startDash + dashLength, metric.length);

            if (startDash < metric.length) {
              final startTangent = metric.getTangentForOffset(startDash);
              final endTangent = metric.getTangentForOffset(endDash);

              if (startTangent != null && endTangent != null) {
                canvas.drawLine(
                    startTangent.position, endTangent.position, paint);
              }
            }
            distance += patternLength;
          }
        }
        break;

      case PointConnectionType.dotted:
        final spacing = connection.style.spacing * globeScale;
        final animatedOffset = arc.dashOffset * spacing;
        final dotSize = connection.style.dotSize * globeScale;

        // Draw dots across all path segments
        for (final metric in pathMetricsList) {
          double distance = animatedOffset % spacing;
          while (distance < metric.length) {
            final tangent = metric.getTangentForOffset(distance);
            if (tangent != null) {
              canvas.drawCircle(tangent.position, dotSize, paint);
            }
            distance += spacing;
          }
        }
        break;
    }

    // Draw label
    if (connection.isLabelVisible &&
        connection.label != null &&
        connection.label!.isNotEmpty &&
        connection.labelBuilder == null) {
      _drawLabel(canvas, connection.label!, connection.labelTextStyle,
          arc.midPoint2D, size);
    }

    return path;
  }

  void _drawPoint(Canvas canvas, PointRenderData point) {
    final style = point.point.style;

    // Scale point relative to globe size
    // Use a base reference radius (150) so points scale with zoom
    const baseRadius = 150.0;
    final globeScale = radius / baseRadius;

    // Scale point based on depth (closer = larger)
    final depthScale = 0.7 + 0.6 * point.depth;
    final scaledSize = style.size * depthScale * globeScale;

    // Apply transition animation
    final alpha = style.color.a * point.transitionProgress;

    // Draw point with altitude effect
    final altitudeOffset = style.altitude * point.depth * 2.0 * globeScale;
    final drawPos =
        Offset(point.position2D.dx, point.position2D.dy - altitudeOffset);

    // === Globe.GL Style 3D Tilted Point ===
    // The point should appear as if it's a disc lying flat on the sphere surface
    // We're viewing the disc from an angle, so it appears as an ellipse

    // The foreshortening factor based on how tilted the surface is
    // normalX is how much the surface faces the camera (1 = facing, 0 = edge)
    final foreshortening = point.normalX.abs().clamp(0.1, 1.0);

    // Calculate the angle at which to orient the ellipse
    // The ellipse major axis should be PERPENDICULAR to the radial direction from center
    // normalY = horizontal position (but screen X increases right, so negate)
    // normalZ = vertical position on sphere
    // The foreshortening happens toward the center of the sphere
    final angleToCenter = math.atan2(point.normalZ, -point.normalY);

    // Full size for the major axis (tangent to sphere surface)
    final majorAxis = scaledSize * 2.0;
    // Compressed size for minor axis (radial direction, foreshortened)
    final minorAxis = scaledSize * 2.0 * foreshortening;

    canvas.save();
    canvas.translate(drawPos.dx, drawPos.dy);
    // Rotate so the minor axis points toward sphere center
    canvas.rotate(angleToCenter + math.pi / 2);

    // Draw the main colored disc
    final paint = Paint()
      ..color = style.color.withValues(alpha: alpha)
      ..style = PaintingStyle.fill;

    // Width = major axis (full), Height = minor axis (foreshortened)
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: majorAxis,
      height: minorAxis,
    );
    canvas.drawOval(rect, paint);

    canvas.restore();
  }

  void _drawSatellite(Canvas canvas, SatelliteRenderData satellite) {
    final style = satellite.satellite.style;

    // Scale satellite relative to globe size
    const baseRadius = 150.0;
    final globeScale = radius / baseRadius;

    // Scale based on depth and size attenuation
    final depthScale =
        style.sizeAttenuation ? (0.7 + 0.6 * satellite.depth) : 1.0;
    final scaledSize = style.size * depthScale * globeScale;

    // Apply transition animation
    final alpha = style.color.a * satellite.transitionProgress;

    // Draw glow effect first (behind the satellite)
    if (style.hasGlow) {
      final glowColor = style.glowColor ?? style.color;
      final glowPaint = Paint()
        ..color = glowColor
            .withAlpha((alpha * style.glowIntensity * 0.5 * 255).round())
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, scaledSize * 1.5);
      canvas.drawCircle(satellite.position2D, scaledSize * 1.5, glowPaint);
    }

    // Draw the satellite based on shape
    final paint = Paint()
      ..color = style.color.withAlpha((alpha * 255).round())
      ..style = PaintingStyle.fill;

    switch (style.shape) {
      case SatelliteShape.circle:
        canvas.drawCircle(satellite.position2D, scaledSize, paint);
        break;

      case SatelliteShape.square:
        final rect = Rect.fromCenter(
          center: satellite.position2D,
          width: scaledSize * 2,
          height: scaledSize * 2,
        );
        canvas.save();
        canvas.translate(satellite.position2D.dx, satellite.position2D.dy);
        canvas.rotate(math.pi / 4); // Rotate 45 degrees for diamond shape
        canvas.translate(-satellite.position2D.dx, -satellite.position2D.dy);
        canvas.drawRect(rect, paint);
        canvas.restore();
        break;

      case SatelliteShape.triangle:
        final path = Path();
        path.moveTo(
            satellite.position2D.dx, satellite.position2D.dy - scaledSize);
        path.lineTo(satellite.position2D.dx - scaledSize * 0.866,
            satellite.position2D.dy + scaledSize * 0.5);
        path.lineTo(satellite.position2D.dx + scaledSize * 0.866,
            satellite.position2D.dy + scaledSize * 0.5);
        path.close();
        canvas.drawPath(path, paint);
        break;

      case SatelliteShape.star:
        _drawStar(canvas, satellite.position2D, scaledSize, paint);
        break;

      case SatelliteShape.satelliteIcon:
        _drawSatelliteIcon(canvas, satellite.position2D, scaledSize, paint);
        break;
    }
  }

  void _drawStar(Canvas canvas, Offset center, double size, Paint paint) {
    final path = Path();
    const points = 5;
    const innerRadius = 0.4;

    for (int i = 0; i < points * 2; i++) {
      final angle = (i * math.pi / points) - math.pi / 2;
      final r = i.isEven ? size : size * innerRadius;
      final x = center.dx + r * math.cos(angle);
      final y = center.dy + r * math.sin(angle);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawSatelliteIcon(
      Canvas canvas, Offset center, double size, Paint paint) {
    // Draw a simple satellite shape: body with two solar panels
    final bodySize = size * 0.6;
    final panelWidth = size * 0.8;
    final panelHeight = size * 0.3;

    // Body (rectangle)
    final bodyRect = Rect.fromCenter(
      center: center,
      width: bodySize,
      height: bodySize,
    );
    canvas.drawRect(bodyRect, paint);

    // Left solar panel
    final leftPanel = Rect.fromCenter(
      center: Offset(center.dx - bodySize / 2 - panelWidth / 2, center.dy),
      width: panelWidth,
      height: panelHeight,
    );
    canvas.drawRect(leftPanel, paint);

    // Right solar panel
    final rightPanel = Rect.fromCenter(
      center: Offset(center.dx + bodySize / 2 + panelWidth / 2, center.dy),
      width: panelWidth,
      height: panelHeight,
    );
    canvas.drawRect(rightPanel, paint);
  }

  void _drawOrbitPath(Canvas canvas, SatelliteRenderData satellite) {
    if (satellite.orbitPath2D == null || satellite.orbitPathVisible == null) {
      return;
    }

    final style = satellite.satellite.style;
    final alpha = style.orbitPathColor.a * satellite.transitionProgress * 255;

    final paint = Paint()
      ..color = style.orbitPathColor.withAlpha(alpha.round())
      ..strokeWidth = style.orbitPathWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Build path with gaps where segments are hidden
    final path = Path();
    bool inPath = false;

    for (int i = 0; i < satellite.orbitPath2D!.length; i++) {
      final isVisible = satellite.orbitPathVisible![i];
      final point = satellite.orbitPath2D![i];

      if (isVisible) {
        if (!inPath) {
          path.moveTo(point.dx, point.dy);
          inPath = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      } else {
        inPath = false;
      }
    }

    if (style.orbitPathDashed) {
      // Draw dashed line
      final pathMetrics = path.computeMetrics();
      const dashLength = 5.0;
      const gapLength = 3.0;

      for (final metric in pathMetrics) {
        double distance = 0;
        while (distance < metric.length) {
          final startDash = distance;
          final endDash = math.min(startDash + dashLength, metric.length);

          if (startDash < metric.length) {
            final startTangent = metric.getTangentForOffset(startDash);
            final endTangent = metric.getTangentForOffset(endDash);

            if (startTangent != null && endTangent != null) {
              canvas.drawLine(
                  startTangent.position, endTangent.position, paint);
            }
          }
          distance += dashLength + gapLength;
        }
      }
    } else {
      canvas.drawPath(path, paint);
    }
  }

  void _drawLabel(Canvas canvas, String text, TextStyle? style, Offset position,
      Size size) {
    final textStyle =
        style ?? const TextStyle(color: Colors.white, fontSize: 12);
    final textSpan = TextSpan(text: text, style: textStyle);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final offset = Offset(
      position.dx - textPainter.width / 2,
      position.dy - textPainter.height - 8,
    );

    // Ensure label stays within bounds
    final clampedOffset = Offset(
      offset.dx.clamp(0, size.width - textPainter.width),
      offset.dy.clamp(0, size.height - textPainter.height),
    );

    textPainter.paint(canvas, clampedOffset);
  }

  bool _isPointOnPath(Offset point, Path path, double tolerance) {
    // Approximate by sampling path
    final metricsList = path.computeMetrics().toList();
    if (metricsList.isEmpty) return false;

    final metric = metricsList.first;
    const samples = 50;

    for (int i = 0; i <= samples; i++) {
      final t = metric.length * i / samples;
      final tangent = metric.getTangentForOffset(t);
      if (tangent != null) {
        if ((tangent.position - point).distance <= tolerance) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  bool shouldRepaint(covariant GpuForegroundPainter oldDelegate) {
    // Always repaint for smooth animations
    // The animation notifier will handle throttling
    return true;
  }
}
