import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models.dart';

RumContext readFlutterEnvironment() {
  final WidgetsBinding binding = WidgetsBinding.instance;
  final Iterable<FlutterView> views = binding.platformDispatcher.views;
  final FlutterView? view = views.isEmpty ? null : views.first;
  final double? logicalWidth = view == null
      ? null
      : view.physicalSize.width / view.devicePixelRatio;
  final double? logicalHeight = view == null
      ? null
      : view.physicalSize.height / view.devicePixelRatio;
  final double? shortestSide = logicalWidth == null || logicalHeight == null
      ? null
      : logicalWidth < logicalHeight
      ? logicalWidth
      : logicalHeight;

  return <String, Object?>{
    'browser': 'Flutter',
    'os': _platformName(defaultTargetPlatform),
    'device': shortestSide == null
        ? 'mobile'
        : shortestSide >= 600
        ? 'tablet'
        : 'mobile',
    'language': binding.platformDispatcher.locale.toLanguageTag(),
    'timezone': DateTime.now().timeZoneName,
    if (logicalWidth != null && logicalHeight != null)
      'viewport': '${logicalWidth.round()}x${logicalHeight.round()}',
  };
}

String _platformName(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'Android',
  TargetPlatform.iOS => 'iOS',
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.windows => 'Windows',
  TargetPlatform.linux => 'Linux',
  TargetPlatform.fuchsia => 'Fuchsia',
};
