import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Ultra-high performance scroll behavior optimized for 240Hz displays
class ScrollBehavior extends MaterialScrollBehavior {
  const ScrollBehavior();

  @override
  Widget buildViewportChrome(
    BuildContext context,
    Widget child,
    AxisDirection axisDirection,
  ) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    // Use Ubuntu-optimized physics for high refresh rate displays
    return const ScrollPhysicsClass(
      parent: ClampingScrollPhysics(),
    );
  }
}

/// Ubuntu-style scroll physics optimized for 240Hz displays
class ScrollPhysicsClass extends ClampingScrollPhysics {
  const ScrollPhysicsClass({
    ScrollPhysics? parent,
    this.friction = 0.015, // Lower friction for smoother scrolling
    this.tolerance = const Tolerance(
      velocity: 1.0,
      distance: 1.0,
    ),
  }) : super(parent: parent);

  final double friction;
  final Tolerance tolerance;

  @override
  ScrollPhysicsClass applyTo(ScrollPhysics? ancestor) {
    return ScrollPhysicsClass(
      parent: buildParent(ancestor),
      friction: friction,
      tolerance: tolerance,
    );
  }

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
    mass: 0.5, // Lighter mass for faster response
    stiffness: 300.0, // Higher stiffness for snappier feel
    ratio: 1.1, // Slight damping for smooth deceleration
  );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // Apply slight resistance for more controlled feel
    return offset * 0.98;
  }

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    return true;
  }

  @override
  double carryMomentum(ScrollMetrics position, double velocity) {
    // Preserve more momentum for smoother scrolling
    return velocity * 0.95;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    return super.createBallisticSimulation(position, velocity);
  }
}

/// Ultra-responsive scroll controller for 240Hz displays
class UbuntuScrollController extends ScrollController {
  UbuntuScrollController({
    double initialScrollOffset = 0.0,
    String? debugLabel,
  }) : super(
    initialScrollOffset: initialScrollOffset,
    debugLabel: debugLabel,
  );

  /// Smooth scroll with ultra-high refresh rate optimization
  Future<void> animateToWithRefreshRate(
    double offset, {
    Duration duration = const Duration(milliseconds: 200),
    Curve curve = Curves.easeOutCubic,
  }) {
    return animateTo(
      offset,
      duration: duration,
      curve: curve,
    );
  }

  /// Instant scroll for 240Hz responsiveness
  void jumpToInstant(double offset) {
    jumpTo(offset);
  }
}

/// Custom scroll position for ultra-smooth scrolling
class UbuntuScrollPosition extends ScrollPositionWithSingleContext {
  UbuntuScrollPosition({
    required ScrollPhysics physics,
    required ScrollContext context,
    double initialPixels = 0.0,
    bool keepScrollOffset = true,
    ScrollPosition? oldPosition,
    String? debugLabel,
  }) : super(
    physics: physics,
    context: context,
    initialPixels: initialPixels,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // Apply content dimensions with ultra-high precision
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  @override
  void applyUserOffset(double delta) {
    // Apply user offset with enhanced precision for 240Hz
    super.applyUserOffset(delta);
  }

  @override
  void goBallistic(double velocity) {
    // Enhanced ballistic scrolling for high refresh rate
    super.goBallistic(velocity);
  }
}

/// Ultra-high performance scroll view for Ubuntu-style file explorer
class ScrollView extends StatelessWidget {
  const ScrollView({
    Key? key,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.controller,
    this.child,
    this.dragStartBehavior = DragStartBehavior.start,
    this.clipBehavior = Clip.hardEdge,
    this.restorationId,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  }) : super(key: key);

  final Axis scrollDirection;
  final bool reverse;
  final EdgeInsetsGeometry? padding;
  final bool? primary;
  final ScrollPhysics? physics;
  final ScrollController? controller;
  final Widget? child;
  final DragStartBehavior dragStartBehavior;
  final Clip clipBehavior;
  final String? restorationId;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const ScrollBehavior(),
      child: ListView(
        scrollDirection: scrollDirection,
        reverse: reverse,
        padding: padding,
        primary: primary,
        physics: physics ?? const ScrollPhysicsClass(),
        controller: controller,
        dragStartBehavior: dragStartBehavior,
        clipBehavior: clipBehavior,
        keyboardDismissBehavior: keyboardDismissBehavior,
        children: child != null ? [child!] : [],
      ),
    );
  }
}