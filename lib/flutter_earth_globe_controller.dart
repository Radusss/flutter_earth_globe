import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_earth_globe/misc.dart';
import 'package:flutter_earth_globe/rotating_globe.dart';
import 'package:flutter_earth_globe/satellite.dart';

import 'globe_coordinates.dart';
import 'point.dart';
import 'sphere_style.dart';

import 'point_connection.dart';

import 'point_connection_style.dart';

import 'trail.dart';
import 'trail_attachment.dart';

/// This class is the controller of the [RotatingGlobe] widget.
///
/// It is used to add/remove/update points and connections.
/// It is also used to control the rotation of the globe.
/// It is also used to load the surface and background images.
/// It is also used to set the style of the sphere.
/// It is also used to listen to the events of the globe.
class FlutterEarthGlobeController extends ChangeNotifier {
  bool _isRotating = false; // Whether the globe is rotating.
  bool _isReady = false; // Whether the globe is ready.
  List<Point> points = []; // The points on the globe.
  // Maps a point's id to its index inside `points` for O(1) lookups/updates.
  // Kept in sync by add/remove operations.
  final Map<String, int> idToIndex = <String, int>{};
  List<AnimatedPointConnection> connections =
      []; // The connections between points.
  List<Trail> trails = []; // The trails (poly-lines) on the globe.
  List<TrailAttachment> trailAttachments = []; // Trail attachments that follow points.
  // Shader trail attachments rendered via GPU (no vertex list allocation per-frame).
  List<ShaderTrailAttachment> shaderTrailAttachments = [];
  // Last-frame projected head 2D position per point for deriving render-direction.
  final Map<String, Offset> _lastShaderHead2D = <String, Offset>{};
  List<Satellite> satellites = []; // The satellites orbiting the globe.

  SphereStyle sphereStyle; // The style of the sphere.
  ui.Image? surface; // The surface image of the sphere.
  ui.Image? nightSurface; // The night surface image of the sphere.
  ui.Image? background; // The background image of the sphere.
  Uint32List? surfaceProcessed; // The processed surface image of the sphere.
  Uint32List?
      nightSurfaceProcessed; // The processed night surface image of the sphere.
  bool
      isBackgroundFollowingSphereRotation; // Whether the background follows the rotation of the sphere.
  ImageConfiguration
      surfaceConfiguration; // The configuration of the surface image.
  ImageConfiguration
      nightSurfaceConfiguration; // The configuration of the night surface image.
  ImageConfiguration
      backgroundConfiguration; // The configuration of the background image.

  AnimationController?
      rotationController; // The animation controller for sphere rotation.

  double rotationSpeed; // The speed of the rotation.

  double zoom; // The zoom level of the globe.
  double maxZoom; // The maximum zoom level of the globe.
  double minZoom; // The minimum zoom level of the globe.
  bool isZoomEnabled; // Whether the zoom is enabled.

  /// Feature flag to enable GPU-based trail rendering using a fragment shader.
  /// When disabled, the CPU path-based trail rendering is used.
  bool gpuTrailsEnabled = false;

  // Sensitivity properties
  double
      zoomSensitivity; // Sensitivity for scroll/pinch zoom (default 0.8, higher = faster zoom)
  double
      panSensitivity; // Sensitivity for panning/rotating the globe (default 1.0, higher = faster pan)

  // Atmospheric glow properties
  bool showAtmosphere; // Whether to show the atmospheric glow around the globe
  Color
      atmosphereColor; // Color of the atmospheric glow (default: Earth-like blue)
  double atmosphereBlur; // Blur radius for the atmospheric glow (default: 25)
  double
      atmosphereThickness; // Thickness of the atmosphere relative to globe radius (default: 0.15)
  double atmosphereOpacity; // Opacity of the atmospheric glow (default: 0.6)

  // Day/Night cycle properties
  bool isDayNightCycleEnabled; // Whether the day/night cycle is enabled.
  double
      sunLongitude; // The current longitude of the sun (in degrees, -180 to 180).
  double
      sunLatitude; // The current latitude of the sun (in degrees, -23.5 to 23.5 for realistic Earth tilt).
  double
      dayNightBlendFactor; // The sharpness of the day/night transition (0.0 = sharp, 1.0 = very smooth).
  bool
      useRealTimeSunPosition; // Whether to calculate sun position based on real time.
  DayNightCycleDirection
      dayNightCycleDirection; // The direction of the day/night cycle animation.

  bool
      zoomToMousePosition; // Whether zooming should zoom towards the mouse/pointer position.

  // Pan offset for zoom-to-cursor feature (in pixels)
  double panOffsetX; // Horizontal pan offset from center
  double panOffsetY; // Vertical pan offset from center

  GlobalKey<RotatingGlobeState> globeKey = GlobalKey();

  // Layered repaint notifiers to avoid rebuilding the entire widget tree
  // for foreground-only changes (points/trails). The foreground painter can
  // listen to this to repaint without triggering a full setState in the
  // RotatingGlobe widget.
  final ChangeNotifier foregroundNotifier = ChangeNotifier();

  FlutterEarthGlobeController({
    ImageProvider? surface,
    ImageProvider? nightSurface,
    ImageProvider? background,
    this.rotationSpeed = 0.2,
    this.isZoomEnabled = false,
    this.zoom = 1,
    this.maxZoom = 2.5,
    this.minZoom = -1.0, // Allow zooming out further (negative = smaller globe)
    bool isRotating = false,
    this.isBackgroundFollowingSphereRotation = false,
    this.surfaceConfiguration = const ImageConfiguration(),
    this.nightSurfaceConfiguration = const ImageConfiguration(),
    this.backgroundConfiguration = const ImageConfiguration(),
    this.sphereStyle = const SphereStyle(),
    bool gpuTrailsEnabled = false,
    this.isDayNightCycleEnabled = false,
    this.sunLongitude = 0.0,
    this.sunLatitude = 0.0,
    this.dayNightBlendFactor = 0.15,
    this.useRealTimeSunPosition = false,
    this.dayNightCycleDirection = DayNightCycleDirection.leftToRight,
    this.zoomSensitivity = 0.8,
    this.panSensitivity = 1.0,
    this.zoomToMousePosition = false,
    this.panOffsetX = 0.0,
    this.panOffsetY = 0.0,
    this.showAtmosphere = true,
    this.atmosphereColor = const ui.Color.fromARGB(255, 57, 123, 185),
    this.atmosphereBlur = 30.0,
    this.atmosphereThickness = 0.03,
    this.atmosphereOpacity = 0.2,
  }) {
    assert(minZoom < maxZoom);
    assert(zoom >= minZoom && zoom <= maxZoom);
    _isRotating = isRotating;
    this.gpuTrailsEnabled = gpuTrailsEnabled;
    if (surface != null) {
      loadSurface(surface);
    }

    if (nightSurface != null) {
      loadNightSurface(nightSurface);
    }

    if (background != null) {
      loadBackground(background);
    }
  }

  /// Enables or disables GPU-based trail rendering and notifies listeners.
  void setGpuTrailsEnabled(bool enabled) {
    if (gpuTrailsEnabled == enabled) return;
    gpuTrailsEnabled = enabled;
    // Foreground rendering path may change; trigger repaint/rebuild.
    notifyListeners();
    foregroundNotifier.notifyListeners();
  }

  // internal calls
  Function(AnimatedPointConnection connection,
      {required bool animateDraw,
      required Duration animateDrawDuration})? onPointConnectionAdded;

  Function()? onResetGlobeRotation;

  Function({Duration cycleDuration, DayNightCycleDirection direction})?
      onStartDayNightCycleAnimation;
  Function()? onStopDayNightCycleAnimation;

  void load() {
    _isReady = true;
    onLoaded?.call();
    if (_isRotating) {
      startRotation();
    }
  }

  // external calls

  /// Returns true if the globe is rotating
  bool get isRotating => _isRotating;

  /// Sets the rotation of the globe
  set isRotating(bool value) => _isRotating;

  /// Returns true if the globe is ready
  bool get isReady => _isReady;

  /// Resets the pan offset to center the globe in the view.
  /// This is useful after using zoom-to-cursor to return to the default centered position.
  ///
  /// Example usage:
  /// ```dart
  /// controller.resetPanOffset();
  /// ```
  void resetPanOffset() {
    panOffsetX = 0.0;
    panOffsetY = 0.0;
    notifyListeners();
  }

  /// Starts the day/night cycle animation.
  ///
  /// The [cycleDuration] parameter specifies how long one complete day/night cycle takes.
  /// Default is 1 minute for a full 24-hour simulation.
  ///
  /// The [direction] parameter specifies whether the sun moves left-to-right or right-to-left.
  /// Default is [DayNightCycleDirection.leftToRight].
  ///
  /// Example usage:
  /// ```dart
  /// controller.startDayNightCycle(
  ///   cycleDuration: Duration(seconds: 30),
  ///   direction: DayNightCycleDirection.rightToLeft,
  /// );
  /// ```
  void startDayNightCycle({
    Duration cycleDuration = const Duration(minutes: 1),
    DayNightCycleDirection? direction,
  }) {
    isDayNightCycleEnabled = true;
    if (direction != null) {
      dayNightCycleDirection = direction;
    }
    onStartDayNightCycleAnimation?.call(
      cycleDuration: cycleDuration,
      direction: dayNightCycleDirection,
    );
    notifyListeners();
  }

  /// Stops the day/night cycle animation.
  ///
  /// Example usage:
  /// ```dart
  /// controller.stopDayNightCycle();
  /// ```
  void stopDayNightCycle() {
    onStopDayNightCycleAnimation?.call();
    notifyListeners();
  }

  /// Adds a [connection] between two [points] to the globe.
  ///
  /// The [connection] parameter represents the connection to be added to the globe.
  /// The [animateDraw] parameter represents whether the connection should be animated when drawn.
  /// The [animateDrawDuration] parameter represents the duration of the animation when drawing the connection.
  ///
  /// Example usage:
  /// ```dart
  /// controller.addPointConnection(PointConnection(
  ///   start: GlobeCoordinates(0, 0),
  ///   end: GlobeCoordinates(0, 0),
  ///   id: 'id',
  ///   title: 'title',
  ///   isTitleVisible: true,
  ///   showTitleOnHover: true,
  ///   isMoving: true),
  ///   animateDraw: true,
  ///  );
  /// ```
  void addPointConnection(PointConnection connection,
      {bool animateDraw = false,
      Duration animateDrawDuration = const Duration(seconds: 2)}) {
    final animatedConnection = AnimatedPointConnection.fromPointConnection(
        pointConnection: connection);
    connections.add(animatedConnection);
    notifyListeners();
    onPointConnectionAdded?.call(animatedConnection,
        animateDraw: animateDraw, animateDrawDuration: animateDrawDuration);
  }

  /// Focuses on the [coordinates] on the globe.
  ///
  /// The [coordinates] parameter represents the coordinates to focus on.
  /// The [animate] parameter represents whether the focus should be animated.
  /// The [duration] parameter represents the duration of the animation.
  ///
  /// Example usage:
  /// ```dart
  /// controller.focusOnCoordinates(GlobeCoordinates(0, 0), animate: true);
  /// ```
  void focusOnCoordinates(GlobeCoordinates coordinates,
      {bool animate = false,
      Duration? duration = const Duration(milliseconds: 500)}) {
    globeKey.currentState
        ?.focusOnCoordinates(coordinates, animate: animate, duration: duration);
  }

  /// Updates the [connection] between two [points] on the globe.
  ///
  /// The [id] parameter represents the id of the connection to be updated.
  /// The [label] parameter represents the label of the connection.
  /// The [labelBuilder] parameter represents the builder of the label of the connection.
  /// The [isLabelVisible] parameter represents the visibility of the label of the connection.
  /// The [labelOffset] parameter represents the offset of the label from the connection line.
  /// The [isMoving] parameter represents whether the connection is currently moving.
  /// The [style] parameter represents the style of the connection line.
  /// The [labelTextStyle] parameter represents the text style of the label.
  /// The [onTap] parameter is a callback function that is called when the connection is tapped.
  /// The [onHover] parameter is a callback function that is called when the connection is hovered over.
  ///
  /// Example usage:
  /// ```dart
  /// controller.updatePointConnection('id',
  ///   title: 'title',
  ///   textStyle: TextStyle(color: Colors.red),
  ///   isTitleVisible: true,
  ///   isMoving: true,
  ///   style: PointConnectionStyle(color: Colors.red),
  ///  );
  /// ```
  void updatePointConnection(
    String id, {
    String? label,
    Widget? Function(BuildContext context, PointConnection pointConnection,
            bool isHovering, bool isVisible)?
        labelBuilder,
    bool? isLabelVisible,
    Offset? labelOffset,
    bool? isMoving,
    PointConnectionStyle? style,
    TextStyle? labelTextStyle,
    VoidCallback? onTap,
    VoidCallback? onHover,
  }) {
    final index = connections.indexWhere((element) => element.id == id);
    if (index == -1) return;
    connections[index] = connections[index].copyWith(
        label: label,
        isMoving: isMoving,
        labelBuilder: labelBuilder,
        isLabelVisible: isLabelVisible,
        labelOffset: labelOffset,
        style: style,
        labelTextStyle: labelTextStyle,
        onTap: onTap,
        onHover: onHover) as AnimatedPointConnection;
    notifyListeners();
  }

  /// Removes the [connection] between two [points] from the globe.
  ///
  /// The [id] parameter represents the id of the connection to be removed.
  ///
  /// Example usage:
  /// ```dart
  ///  controller.removePointConnection('id');
  /// ```
  void removePointConnection(String id) {
    connections.removeWhere((element) => element.id == id);
    notifyListeners();
  }

  /// Adds a [point] to the globe.
  ///
  /// The [point] parameter represents the point to be added to the globe.
  ///
  /// Example usage:
  /// ```dart
  /// controller.addPoint(Point(
  ///  coordinates: GlobeCoordinates(0, 0),
  /// id: 'id',
  /// title: 'title',
  /// isTitleVisible: true,
  /// showTitleOnHover: true,
  /// style: PointStyle(color: Colors.red),
  /// textStyle: TextStyle(color: Colors.red),
  /// onTap: () {},
  /// onHover: () {},
  /// ));
  /// ```
  void addPoint(Point point) {
    points.add(point);
    // Update O(1) index map
    idToIndex[point.id] = points.length - 1;
    // Foreground-only change: repaint without rebuilding the whole tree
    foregroundNotifier.notifyListeners();
  }

  /// Updates the [point] on the globe.
  ///
  /// The [id] parameter represents the id of the point to be updated.
  /// The [label] parameter represents the label of the point.
  /// The [labelBuilder] parameter represents the builder of the label of the point.
  /// The [isLabelVisible] parameter represents the visibility of the label of the point.
  /// The [labelOffset] parameter represents the offset of the label from the point.
  /// The [style] parameter represents the style of the point.
  /// The [labelTextStyle] parameter represents the text style of the label.
  /// The [onTap] parameter is a callback function that is called when the point is tapped.
  /// The [onHover] parameter is a callback function that is called when the point is hovered over.
  ///
  /// Example usage:
  /// ```dart
  ///  controller.updatePoint('id',
  ///  title: 'title',
  /// textStyle: TextStyle(color: Colors.red),
  /// isTitleVisible: true,
  /// showTitleOnHover: true,
  /// style: PointStyle(color: Colors.red),
  /// );
  /// ```
  void updatePoint(
    String id, {
    String? label,
    Widget? Function(
            BuildContext context, Point point, bool isHovering, bool isVisible)?
        labelBuilder,
    bool? isLabelVisible,
    Offset? labelOffset,
    PointStyle? style,
    TextStyle? labelTextStyle,
    VoidCallback? onTap,
    VoidCallback? onHover,
  }) {
    final int? index = idToIndex[id];
    if (index == null) return;

    points[index] = points[index].copyWith(
        label: label,
        labelBuilder: labelBuilder,
        isLabelVisible: isLabelVisible,
        labelOffset: labelOffset,
        style: style,
        labelTextStyle: labelTextStyle,
        onTap: onTap,
        onHover: onHover);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Removes the [point] from the globe.
  ///
  /// The [id] parameter represents the id of the point to be removed.
  ///
  /// Example usage:
  /// ```dart
  /// controller.removePoint('id');
  /// ```
  void removePoint(String id) {
    // Prefer O(1) map to locate and remove the point, then fix indices
    final int? removedIndex = idToIndex.remove(id);
    if (removedIndex != null) {
      points.removeAt(removedIndex);
      // Decrement indices for items that shifted left
      idToIndex.updateAll((key, value) => value > removedIndex ? value - 1 : value);
    } else {
      // Fallback for consistency if map wasn't populated
      final idx = points.indexWhere((p) => p.id == id);
      if (idx != -1) {
        points.removeAt(idx);
        // Rebuild the map to ensure consistency
        idToIndex
          ..clear()
          ..addEntries(points.asMap().entries.map(
            (e) => MapEntry(e.value.id, e.key),
          ));
      }
    }
    
    // Remove any trail attachments associated with this point
    final attachmentsToRemove = trailAttachments.where((a) => a.pointId == id).map((a) => a.id).toList();
    for (final attachmentId in attachmentsToRemove) {
      removeTrailAttachment(attachmentId);
    }
    
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Adds a [satellite] to the globe.
  ///
  /// The [satellite] parameter represents the satellite to be added to the globe.
  /// Satellites can be stationary (geostationary) or orbiting with defined orbital parameters.
  ///
  /// Example usage:
  /// ```dart
  /// // Add a geostationary satellite
  /// controller.addSatellite(Satellite(
  ///   id: 'geo-sat-1',
  ///   coordinates: GlobeCoordinates(0, -75.2),
  ///   altitude: 0.35,
  ///   label: 'GOES-16',
  ///   style: SatelliteStyle(size: 6, color: Colors.yellow),
  /// ));
  ///
  /// // Add an orbiting satellite (ISS-like)
  /// controller.addSatellite(Satellite(
  ///   id: 'iss',
  ///   coordinates: GlobeCoordinates(0, 0),
  ///   altitude: 0.06,
  ///   label: 'ISS',
  ///   orbit: SatelliteOrbit(
  ///     inclination: 51.6,
  ///     period: Duration(seconds: 30), // Faster for demo
  ///   ),
  ///   style: SatelliteStyle(
  ///     size: 8,
  ///     color: Colors.white,
  ///     showOrbitPath: true,
  ///   ),
  /// ));
  /// ```
  void addSatellite(Satellite satellite) {
    satellites.add(satellite);
    notifyListeners();
  }

  /// Updates an existing [satellite] on the globe.
  ///
  /// The [id] parameter represents the id of the satellite to be updated.
  ///
  /// Example usage:
  /// ```dart
  /// controller.updateSatellite('iss',
  ///   label: 'International Space Station',
  ///   style: SatelliteStyle(size: 10, color: Colors.blue),
  /// );
  /// ```
  void updateSatellite(
    String id, {
    GlobeCoordinates? coordinates,
    double? altitude,
    String? label,
    Widget? Function(BuildContext context, Satellite satellite, bool isHovering,
            bool isVisible)?
        labelBuilder,
    bool? isLabelVisible,
    Offset? labelOffset,
    SatelliteStyle? style,
    TextStyle? labelTextStyle,
    SatelliteOrbit? orbit,
    VoidCallback? onTap,
    VoidCallback? onHover,
  }) {
    final index = satellites.indexWhere((element) => element.id == id);
    if (index != -1) {
      satellites[index] = satellites[index].copyWith(
        coordinates: coordinates,
        altitude: altitude,
        label: label,
        labelBuilder: labelBuilder,
        isLabelVisible: isLabelVisible,
        labelOffset: labelOffset,
        style: style,
        labelTextStyle: labelTextStyle,
        orbit: orbit,
        onTap: onTap,
        onHover: onHover,
      );
      notifyListeners();
    }
  }

  /// Removes the [satellite] from the globe.
  ///
  /// The [id] parameter represents the id of the satellite to be removed.
  ///
  /// Example usage:
  /// ```dart
  /// controller.removeSatellite('iss');
  /// ```
  void removeSatellite(String id) {
    satellites.removeWhere((element) => element.id == id);
    notifyListeners();
  }

  /// Removes all satellites from the globe.
  ///
  /// Example usage:
  /// ```dart
  /// controller.clearSatellites();
  /// ```
  void clearSatellites() {
    satellites.clear();
    notifyListeners();
  }

  /// Gets a satellite by its [id].
  ///
  /// Returns null if no satellite with the given id is found.
  ///
  /// Example usage:
  /// ```dart
  /// final satellite = controller.getSatellite('iss');
  /// ```
  Satellite? getSatellite(String id) {
    try {
      return satellites.firstWhere((element) => element.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Loads the [image] as the surface of the globe.
  ///
  /// The [image] parameter represents the image to be loaded as the surface of the globe.
  /// The [configuration] parameter is optional and can be used to customize the image configuration.
  ///
  /// Example usage:
  /// ```dart
  /// controller.loadSurface(
  ///  AssetImage('assets/earth.jpg'),
  /// );
  /// ```
  void loadSurface(
    ImageProvider image, {
    ImageConfiguration configuration = const ImageConfiguration(),
  }) {
    image
        .resolve(configuration)
        .addListener(ImageStreamListener((info, _) async {
      surface = info.image;
      surfaceConfiguration = configuration;
      surfaceProcessed = await convertImageToUint32List(info.image);
      notifyListeners();
    }));
  }

  /// Loads the [image] as the night surface of the globe for day/night cycle effect.
  ///
  /// The [image] parameter represents the image to be loaded as the night surface of the globe.
  /// The [configuration] parameter is optional and can be used to customize the image configuration.
  ///
  /// Example usage:
  /// ```dart
  /// controller.loadNightSurface(
  ///  AssetImage('assets/earth_night.jpg'),
  /// );
  /// ```
  void loadNightSurface(
    ImageProvider image, {
    ImageConfiguration configuration = const ImageConfiguration(),
  }) {
    image
        .resolve(configuration)
        .addListener(ImageStreamListener((info, _) async {
      nightSurface = info.image;
      nightSurfaceConfiguration = configuration;
      nightSurfaceProcessed = await convertImageToUint32List(info.image);
      notifyListeners();
    }));
  }

  /// Loads the background image for the rotating globe.
  ///
  /// The [image] parameter specifies the image to be loaded as the background.
  /// The [configuration] parameter specifies the configuration for loading the image.
  /// The [isBackgroundFollowingSphereRotation] parameter specifies whether the background should follow the rotation of the sphere.
  ///
  /// Example usage:
  /// ```dart
  /// controller.loadBackground(
  /// AssetImage('assets/background.jpg'),
  /// );
  /// ```
  void loadBackground(
    ImageProvider image, {
    ImageConfiguration configuration = const ImageConfiguration(),
    bool isBackgroundFollowingSphereRotation = false,
  }) {
    image.resolve(configuration).addListener(ImageStreamListener((info, _) {
      background = info.image;
      backgroundConfiguration = configuration;
      // Update the controller field so the rendering layer can use it.
      this.isBackgroundFollowingSphereRotation = isBackgroundFollowingSphereRotation;
      notifyListeners();
    }));
  }

  /// Removes the background of the rotating globe.
  ///
  /// Example usage:
  /// ```dart
  /// controller.removeBackground();
  /// ```
  void removeBackground() {
    background = null;
    notifyListeners();
  }

  /// Sets the style of the rotating globe's sphere.
  ///
  /// The [style] parameter specifies the new style for the sphere.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.setSphereStyle(SphereStyle(color: Colors.blue, radius: 100));
  /// ```
  void setSphereStyle(SphereStyle style) {
    sphereStyle = style;
    notifyListeners();
  }

  /// Updates the aura (shadow) intensity of the globe.
  ///
  /// The [blurSigma] parameter controls the intensity of the aura effect.
  /// Higher values create a larger, more diffuse aura.
  /// 
  /// Example usage:
  /// ```dart
  /// controller.updateAuraIntensity(35.0); // Intensify aura
  /// controller.updateAuraIntensity(20.0); // Reset to default
  /// ```
  void updateAuraIntensity(double blurSigma) {
    sphereStyle = sphereStyle.copyWith(shadowBlurSigma: blurSigma);
    notifyListeners();
  }

  /// Updates the aura (shadow) color of the globe.
  ///
  /// The [color] parameter specifies the new aura color.
  /// 
  /// Example usage:
  /// ```dart
  /// controller.updateAuraColor(Colors.white.withOpacity(0.8));
  /// ```
  void updateAuraColor(Color color) {
    sphereStyle = sphereStyle.copyWith(shadowColor: color);
    notifyListeners();
  }

  /// Updates multiple aura properties at once for smooth animations.
  ///
  /// Example usage:
  /// ```dart
  /// controller.updateAura(
  ///   blurSigma: 35.0,
  ///   color: Colors.white.withOpacity(0.9),
  /// );
  /// ```
  void updateAura({double? blurSigma, Color? color}) {
    sphereStyle = sphereStyle.copyWith(
      shadowBlurSigma: blurSigma,
      shadowColor: color,
    );
    notifyListeners();
  }

  /// Starts the rotation of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.startRotation();
  /// ```
  void startRotation({double? rotationSpeed}) {
    _isRotating = true;
    this.rotationSpeed = rotationSpeed ?? this.rotationSpeed;
    rotationController?.forward();
    notifyListeners();
  }

  /// Stops the rotation of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.stopRotation();
  /// ```
  void stopRotation() {
    _isRotating = false;
    rotationController?.stop();
    notifyListeners();
  }

  /// Toggles the rotation of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.toggleRotation();
  /// ```
  void toggleRotation() {
    _isRotating = !_isRotating;
    if (_isRotating) {
      rotationController?.forward();
    } else {
      rotationController?.stop();
    }
    notifyListeners();
  }

  /// Resets the rotation of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.resetRotation();
  /// ```
  void resetRotation() {
    onResetGlobeRotation?.call();
  }

  /// Sets the rotation speed of the globe.
  ///
  /// The [rotationSpeed] parameter specifies the new rotation speed of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.setRotationSpeed(0.5);
  /// ```
  void setRotationSpeed(double rotationSpeed) {
    this.rotationSpeed = rotationSpeed;
    notifyListeners();
  }

  /// Sets the zoom level of the globe.
  ///
  /// The [zoom] parameter specifies the new zoom level of the globe.
  ///
  /// Example usage:
  /// ```dart
  /// FlutterEarthGlobeController controller = FlutterEarthGlobeController();
  /// controller.setZoom(2);
  /// ```
  void setZoom(double zoom) {
    // Prevent zoom changes if zooming is disabled
    if (!isZoomEnabled) return;
    assert(zoom >= minZoom && zoom <= maxZoom);
    if (zoom < minZoom) {
      zoom = minZoom;
    } else if (zoom > maxZoom) {
      zoom = maxZoom;
    } else {
      this.zoom = zoom;
    }
    // Zoom affects both sphere and foreground; rebuild + repaint
    notifyListeners();
    foregroundNotifier.notifyListeners();
  }

  /// Enables or disables the day/night cycle effect.
  ///
  /// When enabled, the globe will blend between the day surface and night surface
  /// based on the sun's position.
  ///
  /// Example usage:
  /// ```dart
  /// controller.setDayNightCycleEnabled(true);
  /// ```
  void setDayNightCycleEnabled(bool enabled) {
    isDayNightCycleEnabled = enabled;
    notifyListeners();
  }

  /// Sets the sun's position for the day/night cycle effect.
  ///
  /// The [longitude] parameter specifies the sun's longitude in degrees (-180 to 180).
  /// The [latitude] parameter specifies the sun's latitude in degrees (-23.5 to 23.5 for realistic Earth tilt).
  ///
  /// Example usage:
  /// ```dart
  /// controller.setSunPosition(longitude: 45.0, latitude: 10.0);
  /// ```
  void setSunPosition({double? longitude, double? latitude}) {
    if (longitude != null) {
      sunLongitude = longitude;
    }
    if (latitude != null) {
      sunLatitude = latitude;
    }
    notifyListeners();
  }

  /// Sets the blend factor for the day/night transition.
  ///
  /// A lower value creates a sharper transition, while a higher value creates a smoother gradient.
  /// Recommended values are between 0.1 and 0.3.
  ///
  /// Example usage:
  /// ```dart
  /// controller.setDayNightBlendFactor(0.2);
  /// ```
  void setDayNightBlendFactor(double factor) {
    dayNightBlendFactor = factor.clamp(0.01, 1.0);
    notifyListeners();
  }

  /// Calculates and sets the sun's position based on real-time.
  ///
  /// This uses astronomical calculations to determine where the sun is
  /// currently positioned over the Earth.
  ///
  /// Example usage:
  /// ```dart
  /// controller.updateSunPositionFromRealTime();
  /// ```
  void updateSunPositionFromRealTime() {
    final now = DateTime.now().toUtc();

    // Calculate the day of the year
    final startOfYear = DateTime.utc(now.year, 1, 1);
    final dayOfYear = now.difference(startOfYear).inDays + 1;

    // Calculate the sun's declination (latitude) based on the day of the year
    // This approximates the Earth's axial tilt effect
    final declination = -23.45 * math.cos(2 * math.pi * (dayOfYear + 10) / 365);

    // Calculate the sun's longitude based on the current time
    // The sun moves 15 degrees per hour (360 / 24)
    final hours = now.hour + now.minute / 60.0 + now.second / 3600.0;
    final longitude = 180 - (hours * 15); // Noon is at 0 degrees, moves west

    sunLatitude = declination;
    sunLongitude = longitude;
    notifyListeners();
  }

  /// Enables or disables real-time sun position tracking.
  ///
  /// When enabled, the sun's position will be calculated based on the current time.
  ///
  /// Example usage:
  /// ```dart
  /// controller.setUseRealTimeSunPosition(true);
  /// ```
  void setUseRealTimeSunPosition(bool enabled) {
    useRealTimeSunPosition = enabled;
    if (enabled) {
      updateSunPositionFromRealTime();
    }
    notifyListeners();
  }

  /// A callback function that is called when the globe is loaded.
  VoidCallback? onLoaded;

  /// Updates the coordinates of an existing [Point] identified by [id].
  ///
  /// This is a lightweight helper that keeps the same [Point] metadata
  /// (style, label, callbacks, etc.) and only changes its geographic
  /// position. Use it inside an animation loop instead of deleting and
  /// re-adding the point each frame.
  ///
  /// Example usage:
  /// ```dart
  /// controller.updatePointCoordinates(
  ///   'plane_42',
  ///   const GlobeCoordinates(48.8566, 2.3522), // Paris
  /// );
  /// ```
  void updatePointCoordinates(String id, GlobeCoordinates coordinates) {
    final int? index = idToIndex[id];
    if (index == null) return; // No point with that id.

    // Replace the Point instance with an updated copy.
    points[index] = points[index].copyWith(coordinates: coordinates);

    // Update any CPU trail attachments that follow this point when GPU trails are disabled.
    if (!gpuTrailsEnabled) {
      _updateAttachedTrails(id, coordinates);
    }
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Updates coordinates for multiple points at once and notifies listeners once.
  ///
  /// Any ids not found are skipped. Trails attached to affected points are
  /// also updated accordingly. This greatly reduces rebuild churn when moving
  /// many points per frame.
  void updatePointCoordinatesBulk(Map<String, GlobeCoordinates> updates) {
    if (updates.isEmpty) return;

    bool anyChanged = false;
    for (final entry in updates.entries) {
      final String id = entry.key;
      final GlobeCoordinates coordinates = entry.value;
      final int? index = idToIndex[id];
      if (index == null) continue;

      points[index] = points[index].copyWith(coordinates: coordinates);
      if (!gpuTrailsEnabled) {
        _updateAttachedTrails(id, coordinates);
      }
      anyChanged = true;
    }

    if (anyChanged) {
      // Foreground-only change
      foregroundNotifier.notifyListeners();
    }
  }

  /// Updates all trail attachments that follow the specified point.
  void _updateAttachedTrails(String pointId, GlobeCoordinates pointCoordinates) {
    for (final attachment in trailAttachments) {
      if (attachment.pointId == pointId) {
        // Generate new absolute vertices for the trail
        final newVertices = attachment.generateAbsoluteVertices(pointCoordinates);
        
        // Find the corresponding trail and update it
        final trailIndex = trails.indexWhere((t) => t.id == attachment.id);
        if (trailIndex != -1) {
          // Get the point's altitude for the trail
          final pointIndex = points.indexWhere((p) => p.id == pointId);
          final pointAltitude = pointIndex != -1 ? points[pointIndex].altitude : 0.0;
          
          trails[trailIndex] = trails[trailIndex].copyWith(
            vertices: newVertices,
            altitude: pointAltitude + attachment.altitudeOffset,
          );
        }
      }
    }
  }

  /// Adds a [trail] poly-line to the globe.
  void addTrail(Trail trail) {
    trails.add(trail);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Updates the properties of an existing trail.
  void updateTrail(
    String id, {
    List<GlobeCoordinates>? vertices,
    TrailStyle? style,
    double? altitude,
  }) {
    final index = trails.indexWhere((t) => t.id == id);
    if (index == -1) return;
    trails[index] = trails[index].copyWith(
      vertices: vertices,
      style: style,
      altitude: altitude,
    );
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Removes the trail with [id].
  void removeTrail(String id) {
    trails.removeWhere((t) => t.id == id);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Attaches a trail to a point. The trail will automatically follow the point's movement.
  /// 
  /// This is much more efficient than manually updating trail vertices each frame.
  /// The trail pattern is defined by relative coordinates that maintain their offset from the point.
  ///
  /// Example usage:
  /// ```dart
  /// controller.attachTrailToPoint(TrailAttachment(
  ///   id: 'whisper_1_trail',
  ///   pointId: 'whisper_1',
  ///   relativeVertices: TrailAttachment.createTrailingPattern(
  ///     segmentCount: 25,
  ///     segmentSpacing: 0.1,
  ///   ),
  ///   style: TrailStyle(useMagicalEffect: true),
  /// ));
  /// ```
  void attachTrailToPoint(TrailAttachment attachment) {
    // Remove any existing attachment with the same ID
    trailAttachments.removeWhere((a) => a.id == attachment.id);
    
    // Add the new attachment
    trailAttachments.add(attachment);
    
    // Find the point to get its current coordinates
    final pointIndex = idToIndex[attachment.pointId] ?? -1;
    if (pointIndex == -1) {
      // Point doesn't exist yet, trail will be created when point is moved
      return;
    }
    
    final point = points[pointIndex];
    final trailVertices = attachment.generateAbsoluteVertices(point.coordinates);
    
    // Create the actual trail
    final trail = Trail(
      id: attachment.id,
      vertices: trailVertices,
      style: attachment.style,
      altitude: point.altitude + attachment.altitudeOffset,
    );
    
    // Remove any existing trail with the same ID and add the new one
    trails.removeWhere((t) => t.id == attachment.id);
    trails.add(trail);
    
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Removes a trail attachment and its associated trail.
  void removeTrailAttachment(String attachmentId) {
    trailAttachments.removeWhere((a) => a.id == attachmentId);
    trails.removeWhere((t) => t.id == attachmentId);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Adds or replaces a GPU shader trail attachment.
  void attachShaderTrail(ShaderTrailAttachment attachment) {
    shaderTrailAttachments.removeWhere((a) => a.id == attachment.id);
    shaderTrailAttachments.add(attachment);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Removes a GPU shader trail attachment by id.
  void removeShaderTrail(String attachmentId) {
    shaderTrailAttachments.removeWhere((a) => a.id == attachmentId);
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Returns last known projected head 2D position for a point id.
  Offset? getLastShaderHead2D(String pointId) => _lastShaderHead2D[pointId];

  /// Updates last known projected head 2D position for a point id.
  void setLastShaderHead2D(String pointId, Offset position) {
    _lastShaderHead2D[pointId] = position;
  }

  /// Updates properties on an existing GPU shader trail attachment.
  void updateShaderTrail(
    String id, {
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
    final int idx = shaderTrailAttachments.indexWhere((a) => a.id == id);
    if (idx == -1) return;
    final ShaderTrailAttachment current = shaderTrailAttachments[idx];
    shaderTrailAttachments[idx] = current.copyWith(
      relativeVertices: relativeVertices,
      lengthDegrees: lengthDegrees,
      widthDegrees: widthDegrees,
      gradientStops: gradientStops,
      tailColor: tailColor,
      headColor: headColor,
      glowColor: glowColor,
      glowStrength: glowStrength,
      shimmer: shimmer,
      altitudeOffset: altitudeOffset,
      headWidthMultiplier: headWidthMultiplier,
    );
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Updates the properties of an existing trail attachment.
  void updateTrailAttachment(
    String id, {
    List<GlobeCoordinates>? relativeVertices,
    TrailStyle? style,
    double? altitudeOffset,
  }) {
    final index = trailAttachments.indexWhere((a) => a.id == id);
    if (index == -1) return;
    
    trailAttachments[index] = trailAttachments[index].copyWith(
      relativeVertices: relativeVertices,
      style: style,
      altitudeOffset: altitudeOffset,
    );
    
    // Update the corresponding trail if the point exists
    final attachment = trailAttachments[index];
    final pointIndex = points.indexWhere((p) => p.id == attachment.pointId);
    if (pointIndex != -1) {
      _updateAttachedTrails(attachment.pointId, points[pointIndex].coordinates);
    }
    
    // Foreground-only change
    foregroundNotifier.notifyListeners();
  }

  /// Gets all trail attachments for a specific point.
  List<TrailAttachment> getTrailAttachmentsForPoint(String pointId) {
    return trailAttachments.where((a) => a.pointId == pointId).toList();
  }

  /// Disposes the controller.
  @override
  void dispose() {
    onPointConnectionAdded = null;
    onResetGlobeRotation = null;
    onLoaded = null;
    rotationController?.dispose();
    foregroundNotifier.dispose();
    super.dispose();
  }
}
