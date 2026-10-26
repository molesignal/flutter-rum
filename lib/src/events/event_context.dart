import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../configuration.dart';
import '../environment/device_info.dart';
import '../internal/identifiers.dart';
import '../internal/runtime_info.dart';
import '../internal/sdk_info.dart';
import '../models.dart';
import '../session/session_manager.dart';
import 'view_scope.dart';

const Duration _deviceInfoRefreshInterval = Duration(minutes: 1);

/// The application, identity and device context every event carries, and the
/// envelope that wraps an event body with it.
final class EventContext {
  EventContext({
    required NormalizedRumConfiguration configuration,
    required RumDeviceInfoProvider deviceInfo,
    required String? anonymousUserId,
  }) : _configuration = configuration,
       _deviceInfo = deviceInfo,
       _anonymousUserId = anonymousUserId,
       user = configuration.user,
       globalContext = Map<String, Object?>.from(configuration.globalContext);

  final NormalizedRumConfiguration _configuration;
  final RumDeviceInfoProvider _deviceInfo;
  final String? _anonymousUserId;
  int _lastDeviceRefreshMicros = nowMicros();

  RumUser? user;
  RumAccount? account;
  RumContext globalContext;

  /// The latest value of every feature flag evaluated so far.
  final Map<String, Object?> featureFlags = <String, Object?>{};

  /// Whether the app is on screen; events say so in `view.in_foreground`.
  bool inForeground = true;

  String? get userId => user?.id ?? _anonymousUserId;

  /// Wraps an event [body] with the context every event carries. For a `view`
  /// event the body is the `view` object itself.
  RumContext wrap(
    RumEventKind kind, {
    required int date,
    required ViewScope view,
    required RumContext body,
    String? actionId,
    RumContext context = const <String, Object?>{},
  }) {
    _refreshDeviceInfoIfStale();
    final RumSession session = view.session;
    final bool isView = kind == RumEventKind.view;
    final RumDeviceInfo info = _deviceInfo.current;
    final RumContext eventContext = <String, Object?>{
      ...globalContext,
      ...context,
    };
    return <String, Object?>{
      'type': kind.wireName,
      'date': date,
      'source': 'flutter',
      'application': <String, Object?>{'id': _configuration.applicationId},
      'service': _configuration.service,
      'env': ?_configuration.env,
      'version': _configuration.version,
      'build_version': ?_configuration.buildVersion,
      'build_id': _configuration.debugId,
      'session': <String, Object?>{
        'id': session.id,
        'type': 'user',
        // Lets the receiver tell a session that just began from one it lost
        // track of.
        'start': session.startedAtMicros ~/ 1000,
        if (isView) 'has_replay': session.replayRecorded,
      },
      'view': isView
          ? body
          : <String, Object?>{
              'id': view.id,
              'url': view.url,
              'name': view.name,
              'in_foreground': inForeground,
            },
      if (actionId != null && kind != RumEventKind.action)
        'action': <String, Object?>{'id': actionId},
      if (!isView) kind.wireName: body,
      'usr': ?_userContext(),
      'account': ?account?.toJson(),
      'connectivity': ?_connectivityContext(info),
      'display': ?_displayContext(),
      'os': _osContext(info),
      'device': _deviceContext(info),
      'sdk': <String, Object?>{
        'name': sdkName,
        'version': sdkVersion,
        'session_sample_rate': _configuration.sessionSampleRate,
        'replay_sample_rate': _configuration.sessionReplaySampleRate,
      },
      if (eventContext.isNotEmpty) 'context': eventContext,
      if (featureFlags.isNotEmpty)
        'feature_flags': Map<String, Object?>.of(featureFlags),
    };
  }

  RumContext? _userContext() {
    final RumContext value = user?.toJson() ?? <String, Object?>{};
    final String? anonymousId = _anonymousUserId;
    if (anonymousId != null) value['anonymous_id'] = anonymousId;
    return value.isEmpty ? null : value;
  }

  RumContext? _connectivityContext(RumDeviceInfo info) {
    final String? status = info.connectivityStatus;
    if (status == null) return null;
    return <String, Object?>{
      'status': status,
      if (info.connectivityInterfaces.isNotEmpty)
        'interfaces': info.connectivityInterfaces,
    };
  }

  RumContext? _displayContext() {
    final ui.FlutterView? view = _firstView();
    if (view == null || view.devicePixelRatio <= 0) return null;
    return <String, Object?>{
      'viewport': <String, Object?>{
        'width': (view.physicalSize.width / view.devicePixelRatio).round(),
        'height': (view.physicalSize.height / view.devicePixelRatio).round(),
      },
    };
  }

  RumContext _osContext(RumDeviceInfo info) {
    final String? version = info.osVersion;
    return <String, Object?>{
      'name': info.osName ?? _osName(defaultTargetPlatform),
      'version': ?version,
      if (version != null) 'version_major': version.split('.').first,
      'build': ?info.osBuild,
    };
  }

  RumContext _deviceContext(RumDeviceInfo info) {
    final int? cpus = logicalProcessorCount();
    final String? locale = _dispatcher()?.locale.toLanguageTag();
    return <String, Object?>{
      'type': info.deviceType ?? _deviceType(),
      'brand': ?info.brand,
      'model': ?info.model,
      'architecture': _configuration.architecture,
      'locale': ?locale,
      'time_zone': _timeZone(DateTime.now().timeZoneOffset),
      'battery_level': ?info.batteryLevel,
      'power_saving_mode': ?info.powerSavingMode,
      'is_low_ram': ?info.isLowRam,
      'logical_cpu_count': ?cpus,
      'total_ram': ?info.totalRam,
    };
  }

  /// Phones and tablets share a platform, so a screen at least 600 logical
  /// pixels wide on its short side counts as a tablet.
  String _deviceType() {
    final bool handheld =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.fuchsia;
    if (!handheld) return 'desktop';
    final ui.FlutterView? view = _firstView();
    if (view == null || view.devicePixelRatio <= 0) return 'mobile';
    final ui.Size size = view.physicalSize / view.devicePixelRatio;
    return min(size.width, size.height) >= 600 ? 'tablet' : 'mobile';
  }

  void _refreshDeviceInfoIfStale() {
    final int now = nowMicros();
    if (now - _lastDeviceRefreshMicros <
        _deviceInfoRefreshInterval.inMicroseconds) {
      return;
    }
    _lastDeviceRefreshMicros = now;
    unawaited(_deviceInfo.refresh());
  }
}

ui.PlatformDispatcher? _dispatcher() {
  try {
    return WidgetsBinding.instance.platformDispatcher;
  } on Object {
    return null;
  }
}

ui.FlutterView? _firstView() {
  final Iterable<ui.FlutterView>? views = _dispatcher()?.views;
  return views == null || views.isEmpty ? null : views.first;
}

String _osName(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'Android',
  TargetPlatform.iOS => 'iOS',
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.windows => 'Windows',
  TargetPlatform.linux => 'Linux',
  TargetPlatform.fuchsia => 'Fuchsia',
};

/// `UTC+08:00`: Dart exposes the offset but not the IANA zone name.
String _timeZone(Duration offset) {
  final int minutes = offset.inMinutes.abs();
  final String sign = offset.isNegative ? '-' : '+';
  final String hours = (minutes ~/ 60).toString().padLeft(2, '0');
  final String rest = (minutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$rest';
}
