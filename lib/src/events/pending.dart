import 'dart:ui' show Offset;

import '../internal/identifiers.dart';
import '../models.dart';
import 'action_scope.dart';

/// The error of a request that failed before a response arrived.
final class NetworkFailure implements Exception {
  const NetworkFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A request between `startResource` and its end.
final class PendingResource {
  PendingResource({
    required this.method,
    required this.url,
    required this.action,
    required this.context,
    int? startedAtMillis,
    this.duration,
    this.counted = true,
  }) : startedAtMillis = startedAtMillis ?? nowMillis();

  final String method;
  final Uri url;
  final ActionScope? action;
  final RumContext context;
  final int startedAtMillis;
  final Stopwatch _clock = Stopwatch()..start();

  /// Known when the request was measured elsewhere.
  final Duration? duration;

  /// The action was told this request is pending.
  final bool counted;

  Duration get elapsed => _clock.elapsed;
}

/// A duration vital between `startDurationVital` and `stopDurationVital`.
final class PendingVital {
  PendingVital({this.description, required this.context})
    : startedAtMillis = nowMillis();

  final String? description;
  final RumContext context;
  final int startedAtMillis;
  final Stopwatch _clock = Stopwatch()..start();

  Duration get elapsed => _clock.elapsed;
}

/// One tap, remembered to recognize rage taps and explicit-over-automatic
/// duplicates.
final class TapSample {
  const TapSample(this.millis, this.position);

  final int millis;
  final Offset position;
}
