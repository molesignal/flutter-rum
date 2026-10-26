import 'dart:async';

import '../internal/identifiers.dart';
import '../internal/units.dart';
import '../models.dart';

/// A user action while it is still collecting what it caused.
///
/// An action stays open while requests it started are in flight and for a
/// short quiet period after the last thing it caused. Errors, crashes and
/// resources that happen in that time belong to the action; a tap that causes
/// an error is an `error_tap`.
final class ActionScope {
  ActionScope({
    required this.type,
    required this.name,
    this.nameSource,
    this.selector,
    this.position,
    this.targetWidth,
    this.targetHeight,
    List<String> frustrations = const <String>[],
    this.context = const <String, Object?>{},
    this.fixedLoadingNanoseconds,
  }) : id = generateUuid(),
       startedAtMillis = nowMillis(),
       frustrations = List<String>.of(frustrations);

  final String id;

  /// `tap`, `click`, `scroll`, `swipe`, `back`, `custom`, or
  /// `application_start`.
  final String type;
  final String name;

  /// `custom_attribute` for a name the developer chose, `mask_placeholder` for
  /// the generic name of an automatic tap.
  final String? nameSource;
  final String? selector;
  final ({int x, int y})? position;
  final int? targetWidth;
  final int? targetHeight;
  final RumContext context;
  final int startedAtMillis;
  final Stopwatch _clock = Stopwatch()..start();

  /// Frustrations known when the action started plus those added later.
  final List<String> frustrations;

  /// A duration measured elsewhere, such as the time to first display of
  /// `application_start`.
  final int? fixedLoadingNanoseconds;
  int errorCount = 0;
  int crashCount = 0;
  int resourceCount = 0;
  int pendingResources = 0;
  Timer? timer;
  int _lastActivityMicros = 0;

  bool get isTap => type == 'tap' || type == 'click';

  Duration get elapsed => _clock.elapsed;

  /// Time since the action last caused something.
  Duration get quietFor =>
      Duration(microseconds: _clock.elapsedMicroseconds - _lastActivityMicros);

  void touch() {
    _lastActivityMicros = _clock.elapsedMicroseconds;
  }

  /// Nanoseconds from the start of the action to the last thing it caused, or
  /// `null` when it caused nothing.
  int? get loadingNanoseconds =>
      fixedLoadingNanoseconds ??
      (_lastActivityMicros == 0
          ? null
          : nanosecondsOfMicroseconds(_lastActivityMicros));

  void addFrustration(String type) {
    if (!frustrations.contains(type)) frustrations.add(type);
  }
}
