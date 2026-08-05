import 'package:flutter/widgets.dart';

import '../client.dart';

/// Resolves a Flutter route into the view name sent to MoleSignal.
typedef RumRouteNameResolver = String? Function(Route<dynamic> route);

String? defaultRumRouteNameResolver(Route<dynamic> route) {
  final String name = route.settings.name?.trim() ?? '';
  return name.isEmpty ? null : name;
}

/// Records visible named routes as RUM `view` actions.
final class RumNavigationObserver extends NavigatorObserver {
  RumNavigationObserver(
    this.client, {
    this.nameResolver = defaultRumRouteNameResolver,
  });

  final RumClient client;
  final RumRouteNameResolver nameResolver;

  Route<dynamic>? _currentRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _show(route, navigationType: 'push');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _currentRoute = previousRoute;
    if (previousRoute != null) _show(previousRoute, navigationType: 'pop');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _show(newRoute, navigationType: 'replace');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (identical(route, _currentRoute) && previousRoute != null) {
      _show(previousRoute, navigationType: 'remove');
    }
  }

  void _show(Route<dynamic> route, {required String navigationType}) {
    _currentRoute = route;
    final String? name = nameResolver(route);
    if (name == null || name.trim().isEmpty) return;
    client.startView(
      name,
      path: name,
      context: <String, Object?>{
        'navigation_type': navigationType,
        if (route.settings.arguments != null) 'has_route_arguments': true,
      },
    );
  }
}
