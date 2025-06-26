import 'package:flutter_earth_globe/globe_coordinates.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'point.dart';
import 'line_helper.dart';
import 'math_helper.dart';
import 'point_connection.dart';

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import 'misc.dart';
import 'trail.dart';

/// A custom painter that draws the foreground of the earth globe.
class ForegroundPainter extends CustomPainter {
  /// This painter is responsible for rendering the points, connections, and labels on the globe.
  /// It takes various parameters such as the list of connections, radius, rotation angles,
  /// zoom factor, points, hover point, click point, and callback functions for point interactions.
  ///
  /// The [hoverOverPoint] function is called when a point is being hovered over, providing the point ID,
  /// the 2D cartesian coordinates, and the hover state.
  ///
  /// The [onPointClicked] function is called when a point is clicked.
  ///
  /// The [connections] list contains the animated connections between points.
  ///
  /// The [hoverPoint] and [clickPoint] represent the current hover and click positions on the canvas.
  ///
  /// The [radius] determines the size of the globe.
  ///
  /// The [rotationZ], [rotationY], and [rotationX] angles control the rotation of the globe.
  ///
  /// The [zoomFactor] determines the zoom level of the globe.

  /// The [points] list contains the points to be rendered on the globe.
  ///
  /// Example usage:
  /// ```dart
  /// ForegroundPainter(
  ///  connections: connections,
  /// radius: 200,
  /// rotationZ: 0,
  /// rotationY: 0,
  /// rotationX: 0,
  /// zoomFactor: 1,
  /// points: points,
  /// hoverPoint: hoverPoint,
  /// clickPoint: clickPoint,
  /// onPointClicked: () {
  ///  print('Point clicked');
  /// },
  /// hoverOverPoint: (pointId, cartesian2D, isHovering, isVisible) {
  /// print('Hovering over point with ID: $pointId');
  /// },
  /// )
  /// ```
  ForegroundPainter({
    required this.connections,
    required this.radius,
    required this.rotationZ,
    required this.rotationY,
    required this.rotationX,
    required this.zoomFactor,
    required this.points,
    required this.trails,
    this.hoverPoint,
    this.clickPoint,
    this.onPointClicked,
    required this.hoverOverPoint,
    required this.hoverOverConnection,
  });

  Function(String pointId, Offset? hoverPoint, bool isHovering, bool isVisible)
      hoverOverPoint;
  Function(String connectionId, Offset? hoverPoint, bool isHovering,
      bool isVisible) hoverOverConnection;
  VoidCallback? onPointClicked;
  final List<AnimatedPointConnection> connections;
  final List<Trail> trails;
  final Offset? hoverPoint;
  final Offset? clickPoint;
  final double radius;
  final double rotationZ;
  final double rotationY;
  final double rotationX;
  final double zoomFactor;
  final List<Point> points;

  bool isSame(GlobeCoordinates c1, GlobeCoordinates c2) {
    return c1.latitude == c2.latitude && c1.longitude == c2.longitude;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final localHover = hoverPoint;
    final localClick = clickPoint;

    for (var point in points) {
      final pointPaint = Paint()..color = point.style.color;
      // Allow points to "float" above the globe surface by pushing them
      // further away from the centre by `point.altitude` logical units.
      final double pointRadius = radius + point.altitude;

      vector.Vector3 cartesian3D = getSpherePosition3D(
        point.coordinates,
        pointRadius,
        rotationY,
        rotationZ,
      );
      Offset cartesian2D =
          Offset(center.dx + cartesian3D.y, center.dy - cartesian3D.z);

      // final c2 = hoverOffsetToSphereCoordinates(
      //     cartesian2D, center, radius, rotationY, rotationZ);
      // if (c2 != null && cartesian3D.x > 0) {
      //   print('${isSame(point.coordinates, c2)}');
      // }

      // print(
      //     'new: $cartesian3D ---- converted: ${getVector3FromGlobeCoordinates(cartesian2D, center, radius, rotationZ)}');
      // print(
      //     'center: $center - point: ${point.coordinates} cartesian2D: $cartesian2D - cartesian3D: $cartesian3D');

      // A point is visible if either:
      //   • It is on the front hemisphere of the Earth (cartesian3D.x > 0) OR
      //   • It is on the rear hemisphere but protrudes outside the Earth
      //     disc in the 2-D projection (i.e. altitude makes it visible above
      //     the horizon).

      bool isFrontHemisphere = cartesian3D.x > 0;

      bool isAboveHorizon = false;
      if (!isFrontHemisphere) {
        // Distance of the 2-D projection from the centre of the Earth disc.
        final dx = cartesian2D.dx - center.dx;
        final dy = cartesian2D.dy - center.dy;
        final distFromCenter = math.sqrt(dx * dx + dy * dy);

        // If the projection lies outside the Earth radius the point is
        // geometrically visible (it sticks out from behind the planet).
        isAboveHorizon = distFromCenter >= radius;
      }

      if (isFrontHemisphere || isAboveHorizon) {
        final rect = getRectOnSphere(
          cartesian3D,
          cartesian2D,
          center,
          pointRadius,
          zoomFactor,
          point.style.size,
        );
        canvas.drawOval(rect, pointPaint);
        // if(rect.contains())
        if (localHover != null && rect.contains(localHover)) {
          Future.delayed(Duration.zero, () {
            point.onHover?.call();
            hoverOverPoint(point.id, cartesian2D, true, true);
          });
        } else {
          hoverOverPoint(point.id, cartesian2D, false, true);
        }

        if (localClick != null && rect.contains(localClick)) {
          Future.delayed(Duration.zero, () {
            point.onTap?.call();
            onPointClicked?.call();
          });
        }

        if ((point.isLabelVisible &&
                point.label != null &&
                point.label != '') &&
            point.labelBuilder == null) {
          paintText(point.label ?? '', point.labelTextStyle, cartesian2D, size,
              canvas);
        }
      } else {
        hoverOverPoint(point.id, cartesian2D, false, false);
      }
    }
    for (var connection in connections) {
      Map? info = drawAnimatedLine(canvas, connection, radius, rotationY,
          rotationZ, connection.animationProgress, size, hoverPoint);

      if (info?['path'] != null) {
        if (localHover != null &&
            isPointOnPath(localHover, info?['path'], connection.strokeWidth)) {
          Future.delayed(Duration.zero, () {
            connection.onHover?.call();
            hoverOverConnection(connection.id, info?['midPoint'], true, true);
          });
        } else {
          hoverOverConnection(connection.id, info?['midPoint'], false, true);
        }
        if (localClick != null &&
            isPointOnPath(localClick, info?['path'], connection.strokeWidth)) {
          Future.delayed(Duration.zero, () {
            connection.onTap?.call();
            onPointClicked?.call();
          });
        }
      } else {
        hoverOverConnection(connection.id, info?['midPoint'], false, false);
      }
    }

    // --- Draw Trails -------------------------------------------------------
    if (trails.isNotEmpty) {
      for (final trail in trails) {
        if (trail.vertices.length < 2) continue; // need at least 2 points

        final path = Path();

        Offset? firstPoint;

        for (int i = 0; i < trail.vertices.length; i++) {
          final coords = trail.vertices[i];
          // Apply altitude similar to points
          final vector.Vector3 cart3D = getSpherePosition3D(
            coords,
            radius + trail.altitude,
            rotationY,
            rotationZ,
          );
          // Skip vertices on back hemisphere that are not above horizon
          if (cart3D.x <= 0) {
            // Use same horizon visibility logic as for points
            final Offset cart2D = Offset(center.dx + cart3D.y, center.dy - cart3D.z);
            final dx = cart2D.dx - center.dx;
            final dy = cart2D.dy - center.dy;
            final dist = math.sqrt(dx * dx + dy * dy);
            if (dist < radius) {
              // invisible, skip
              continue;
            }
          }

          final Offset cart2D = Offset(center.dx + cart3D.y, center.dy - cart3D.z);

          if (firstPoint == null) {
            path.moveTo(cart2D.dx, cart2D.dy);
            firstPoint = cart2D;
          } else {
            path.lineTo(cart2D.dx, cart2D.dy);
          }
        }

        if (firstPoint != null) {
          final paint = Paint()
            ..color = trail.style.color
            ..strokeWidth = trail.style.width
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true;

          if (trail.style.dashArray != null && trail.style.dashArray!.length >= 2) {
            _drawDashedPath(canvas, path, paint, trail.style.dashArray!);
          } else {
            canvas.drawPath(path, paint);
          }
        }
      }
    }
  }

  // Helper to draw dashed paths since Canvas has no built-in API.
  void _drawDashedPath(Canvas canvas, Path origPath, Paint paint, List<double> dashArray) {
    final ui.PathMetrics metrics = origPath.computeMetrics();
    for (final ui.PathMetric metric in metrics) {
      double distance = 0.0;
      bool draw = true;
      int index = 0;
      while (distance < metric.length) {
        final length = dashArray[index % dashArray.length];
        if (draw) {
          final extracted = metric.extractPath(distance, distance + length);
          canvas.drawPath(extracted, paint);
        }
        distance += length;
        draw = !draw;
        index++;
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return true;
  }
}
