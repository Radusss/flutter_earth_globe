import 'package:flutter_earth_globe/globe_coordinates.dart';
import 'package:flutter_earth_globe/trail_attachment.dart';
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
import 'shader_trail_renderer.dart';
import 'shader_orb_renderer.dart';

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
    required this.shaderTrailAttachments,
    required this.gpuTrailsEnabled,
    required this.getLastHead2D,
    required this.setLastHead2D,
    this.hoverPoint,
    this.clickPoint,
    this.onPointClicked,
    required this.hoverOverPoint,
    required this.hoverOverConnection,
    Listenable? repaint,
  }) : super(repaint: repaint);

  Function(String pointId, Offset? hoverPoint, bool isHovering, bool isVisible)
      hoverOverPoint;
  Function(String connectionId, Offset? hoverPoint, bool isHovering,
      bool isVisible) hoverOverConnection;
  VoidCallback? onPointClicked;
  final List<AnimatedPointConnection> connections;
  final List<Trail> trails;
  final List<ShaderTrailAttachment> shaderTrailAttachments;
  final Offset? hoverPoint;
  final Offset? clickPoint;
  final double radius;
  final double rotationZ;
  final double rotationY;
  final double rotationX;
  final double zoomFactor;
  final List<Point> points;
  final bool gpuTrailsEnabled;
  final Offset? Function(String pointId) getLastHead2D;
  final void Function(String pointId, Offset position) setLastHead2D;

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
        // If this is our special GPU orb, draw the shader effect instead of a flat oval
        if (point.id == 'red_orb') {
          final ShaderOrbRenderer orb = ShaderOrbRenderer.instance;
          orb.warmUp();
          // Size the orb relative to point size and zoom (tweakable)
          final double orbSize = point.style.size * 18.0 * (1.0 + 0.2 * zoomFactor);
          // Use an approximate time based on system clock; the effect is continuous
          final double t = DateTime.now().millisecondsSinceEpoch / 1000.0;
          orb.drawOrb(
            canvas: canvas,
            center: cartesian2D,
            sizePx: orbSize,
            timeSeconds: t,
          );
        } else {
          canvas.drawOval(rect, pointPaint);
        }
        if (point.id == 'red_orb') {
          // Debug: rendering info for orb
          // ignore: avoid_print
          print('[ORB] render visible at 2D=' + cartesian2D.toString() +
              ' front=' + isFrontHemisphere.toString() +
              ' aboveHorizon=' + isAboveHorizon.toString());
        }
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
        if (point.id == 'red_orb') {
          // Debug: not visible this frame
          // ignore: avoid_print
          print('[ORB] render hidden (behind globe) at 2D=' + cartesian2D.toString());
        }
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
    if (!gpuTrailsEnabled && trails.isNotEmpty) {
      for (final trail in trails) {
        if (trail.vertices.length < 2) continue; // need at least 2 points

        // Convert vertices to 2D points, filtering out non-visible ones.
        // Keep track of the original index so we can preserve head→tail
        // styling even when the head becomes invisible beyond the horizon.
        final List<Offset> visiblePoints = <Offset>[];
        final List<int> visibleIndices = <int>[];

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
          visiblePoints.add(cart2D);
          visibleIndices.add(i);
        }

        if (visiblePoints.length < 2) continue;

        if (trail.style.useMagicalEffect) {
          _drawMagicalTrail(
            canvas,
            visiblePoints,
            trail.style,
            originalIndices: visibleIndices,
            totalCount: trail.vertices.length,
          );
        } else {
          _drawSimpleTrail(canvas, visiblePoints, trail.style);
        }
      }
    }

    // --- Draw Shader Trails ------------------------------------------------
    if (gpuTrailsEnabled && shaderTrailAttachments.isNotEmpty) {
      final ShaderTrailRenderer renderer = ShaderTrailRenderer.instance;
      renderer.warmUp();
      // If shader init previously failed, skip GPU path entirely to avoid stalls
      if (renderer.isFailed) {
        // ignore: avoid_print
        print('[ForegroundPainter] Shader init failed, skipping GPU trails');
        // Fallback: render nothing here; CPU trails remain available behind flag
        return;
      }
      for (final attachment in shaderTrailAttachments) {
        // Locate the head point
        final point = points.firstWhere(
          (p) => p.id == attachment.pointId,
          orElse: () => Point(
            id: '__missing__',
            coordinates: const GlobeCoordinates(0, 0),
          ),
        );
        if (point.id == '__missing__') continue;

        final double pointRadius = radius + point.altitude + attachment.altitudeOffset;
        final vector.Vector3 cart3D = getSpherePosition3D(
          point.coordinates,
          pointRadius,
          rotationY,
          rotationZ,
        );

        final center = Offset(size.width / 2, size.height / 2);
        final Offset head2D = Offset(center.dx + cart3D.y, center.dy - cart3D.z);

        // Head visibility (used for fallback straight ribbon); do not early-out,
        // since curved GPU trails can still be partially visible when head is hidden.
        bool isFront = cart3D.x > 0;
        bool isAboveHorizon = false;
        if (!isFront) {
          final dx = head2D.dx - center.dx;
          final dy = head2D.dy - center.dy;
          final dist = math.sqrt(dx * dx + dy * dy);
          isAboveHorizon = dist >= radius;
        }

        // Convert degrees to pixels using radius & zoom factor.
        // Approx: 1 degree arc length ~ pi*R/180 in pixels.
        final double pixelsPerDegree = math.pi * pointRadius / 180.0;
        final double widthPx = attachment.widthDegrees * pixelsPerDegree;

        // Choose colors and multi-stop gradient to mirror CPU magical trail
        final Color headColor = attachment.headColor;
        final Color tailColor = (attachment.gradientStops != null && attachment.gradientStops!.isNotEmpty)
            ? attachment.gradientStops!.first
            : attachment.tailColor;
        final List<Color> stops = attachment.gradientStops ?? <Color>[tailColor, headColor];

        // If we have relative vertices, project them and draw a chain of ribbons along the curve.
        if (attachment.relativeVertices.isNotEmpty) {
          final List<Offset> projected = <Offset>[];
          final List<bool> headVisible = <bool>[]; // per-vertex visibility
          final List<bool> maskOutsideOnlyForVertex = <bool>[]; // per-vertex outside-only mask
          for (final rel in attachment.relativeVertices) {
            double newLat = point.coordinates.latitude + rel.latitude;
            double newLon = point.coordinates.longitude + rel.longitude;
            // Pole-crossing normalization (parity with CPU TrailAttachment)
            while (newLat > 90) {
              newLat = 180 - newLat;
              newLon += 180;
            }
            while (newLat < -90) {
              newLat = -180 - newLat;
              newLon += 180;
            }
            while (newLon >= 360) newLon -= 360;
            while (newLon < 0) newLon += 360;

            final vector.Vector3 v3 = getSpherePosition3D(
              GlobeCoordinates(newLat, newLon),
              pointRadius,
              rotationY,
              rotationZ,
            );
            final Offset p2d = Offset(center.dx + v3.y, center.dy - v3.z);
            projected.add(p2d);
            bool vFront = v3.x > 0;
            bool vAbove = false;
            if (!vFront) {
              final double ddx = p2d.dx - center.dx;
              final double ddy = p2d.dy - center.dy;
              final double dd = math.sqrt(ddx * ddx + ddy * ddy);
              vAbove = dd >= radius;
            }
            headVisible.add(vFront || vAbove);
            maskOutsideOnlyForVertex.add(!vFront && vAbove);
          }
          if (projected.isNotEmpty) {
            projected[0] = head2D;
            // Replace visibility for head (index 0) with computed from current head
            headVisible[0] = (isFront || isAboveHorizon);
            maskOutsideOnlyForVertex[0] = (!isFront && isAboveHorizon);
          }

          final double glowPad = widthPx * math.max(attachment.glowStrength, 0.0);
          final double halfW = widthPx + glowPad;

          for (int i = 1; i < projected.length; i++) {
            final Offset p0 = projected[i - 1];
            final Offset p1 = projected[i];
            // Cull segment if its head endpoint (closer to the actual head, i-1)
            // is not visible (behind and not above horizon). This removes
            // segments nearest to the head first.
            final int headIdx = i - 1;
            if (headIdx < headVisible.length && headVisible[headIdx] == false) {
              continue;
            }
            final Offset seg = p1 - p0;
            final double segLen = seg.distance;
            if (segLen <= 0.5) continue;

            final Offset dir2D = seg / segLen;

            final double minX = math.min(p0.dx, p1.dx) - halfW;
            final double maxX = math.max(p0.dx, p1.dx) + halfW;
            final double minY = math.min(p0.dy, p1.dy) - halfW;
            final double maxY = math.max(p0.dy, p1.dy) + halfW;
            final Rect bounds = Rect.fromLTRB(minX, minY, maxX, maxY);

            final double t = (i - 1) / (projected.length - 1);
            final double headMul = 1.0 + (attachment.headWidthMultiplier - 1.0) * t;

            renderer.drawRibbon(
              canvas: canvas,
              bounds: bounds,
              head: p1,
              direction: dir2D,
              lengthPx: segLen,
              widthPx: widthPx,
              headWidthMultiplier: headMul,
              headColor: headColor,
              tailColor: tailColor,
              colorStops: stops,
              maskOutsideOnly: (headIdx < maskOutsideOnlyForVertex.length)
                  ? maskOutsideOnlyForVertex[headIdx]
                  : (!isFront && isAboveHorizon),
              glowColor: attachment.glowColor,
              glowStrength: attachment.glowStrength,
              shimmer: attachment.shimmer,
              timeSeconds: 0.0,
              globeCenter: center,
              globeRadius: radius,
              zoom: zoomFactor,
              rotationY: rotationY,
              rotationZ: rotationZ,
            );
          }
        } else {
          // Legacy straight ribbon using last-frame screen-space motion.
          final Offset? last = getLastHead2D(point.id);
          Offset dir2D = const Offset(0, -1);
          if (last != null) {
            final dx = head2D.dx - last.dx;
            final dy = head2D.dy - last.dy;
            final double len = math.sqrt(dx * dx + dy * dy);
            if (len > 1e-3) {
              dir2D = Offset(dx / len, dy / len);
            }
          }
          setLastHead2D(point.id, head2D);

          final double lengthPx = attachment.lengthDegrees * pixelsPerDegree;
          final double glowPad = widthPx * math.max(attachment.glowStrength, 0.0);
          final double halfW = widthPx + glowPad;
          final Offset tail = head2D - dir2D * lengthPx;
          final double minX = math.min(head2D.dx, tail.dx) - halfW;
          final double maxX = math.max(head2D.dx, tail.dx) + halfW;
          final double minY = math.min(head2D.dy, tail.dy) - halfW;
          final double maxY = math.max(head2D.dy, tail.dy) + halfW;
          final Rect bounds = Rect.fromLTRB(minX, minY, maxX, maxY);

          renderer.drawRibbon(
            canvas: canvas,
            bounds: bounds,
            head: head2D,
            direction: dir2D,
            lengthPx: lengthPx,
            widthPx: widthPx,
            headWidthMultiplier: attachment.headWidthMultiplier,
            headColor: headColor,
            tailColor: tailColor,
            colorStops: stops,
            maskOutsideOnly: !isFront && isAboveHorizon,
            glowColor: attachment.glowColor,
            glowStrength: attachment.glowStrength,
            shimmer: attachment.shimmer,
            timeSeconds: 0.0,
            globeCenter: center,
            globeRadius: radius,
            zoom: zoomFactor,
            rotationY: rotationY,
            rotationZ: rotationZ,
          );
        }
        // debug log removed for parity and perf
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

  // Helper to draw a simple trail (original behavior)
  void _drawSimpleTrail(Canvas canvas, List<Offset> points, TrailStyle style) {
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }

    // Optional glow/halo
    if (style.glowColor != null && style.glowWidth > 0) {
      final glowPaint = Paint()
        ..color = style.glowColor!
        ..strokeWidth = style.glowWidth
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, style.glowWidth * 0.35);

      if (style.dashArray != null && style.dashArray!.length >= 2) {
        _drawDashedPath(canvas, path, glowPaint, style.dashArray!);
      } else {
        canvas.drawPath(path, glowPaint);
      }
    }

    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.width
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    if (style.dashArray != null && style.dashArray!.length >= 2) {
      _drawDashedPath(canvas, path, paint, style.dashArray!);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  // Helper to draw a magical trail with gradient colors and multiple layers
  void _drawMagicalTrail(
    Canvas canvas,
    List<Offset> points,
    TrailStyle style, {
    required List<int> originalIndices,
    required int totalCount,
  }) {
    if (points.length < 2) return;

    // Draw multiple trail layers for glow effect
    for (int layer = 0; layer < style.magicalLayers; layer++) {
      final layerWidth = style.width * (style.magicalLayers - layer) / style.magicalLayers * 2.0;
      final layerOpacity = (layer + 1) / style.magicalLayers * style.magicalOpacity;

      // Draw segments between consecutive points
      for (int i = 1; i < points.length; i++) {
        // Compute progress using the original index along the trail, so that
        // when the head goes behind the globe it does not stay white at the edge.
        final int headToTailIndex = originalIndices[i];
        final double progress = 1.0 - (headToTailIndex / (totalCount - 1));
        
        // Get color for this position
        final segmentColor = style.getColorForProgress(progress);
        
        // Calculate width variation (tail to head)
        final segmentWidth = style.width + (progress * (style.width * (style.headWidthMultiplier - 1.0)));
        final finalWidth = segmentWidth * layerWidth / style.width;
        
        // Calculate final opacity
        final finalOpacity = segmentColor.opacity * progress * layerOpacity;
        
        final paint = Paint()
          ..color = segmentColor.withOpacity(finalOpacity)
          ..strokeWidth = finalWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;

        // Add subtle blur for outer layers
        if (layer > 0) {
          paint.maskFilter = ui.MaskFilter.blur(
            ui.BlurStyle.normal,
            layerWidth * 0.15,
          );
        }

        canvas.drawLine(points[i - 1], points[i], paint);
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    // Repaints driven by the provided Listenable via super(repaint: ...).
    // Returning false avoids extra invalidations when the painter instance is
    // unchanged.
    return false;
  }
}
