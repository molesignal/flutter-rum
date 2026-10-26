import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../internal/runtime_info.dart';
import 'device_info.dart';

const Duration _pluginTimeout = Duration(seconds: 2);

/// The provider used when `RumConfiguration.trackDeviceInfo` is on.
RumDeviceInfoProvider createDefaultDeviceInfoProvider({
  required bool usePlugins,
}) => usePlugins ? PluginDeviceInfoProvider() : DartDeviceInfoProvider();

/// Reads only what Dart itself exposes: the OS version text and nothing that
/// needs a platform plugin.
final class DartDeviceInfoProvider implements RumDeviceInfoProvider {
  DartDeviceInfoProvider() : current = dartDeviceInfo();

  @override
  final RumDeviceInfo current;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> close() async {}
}

/// Adds brand, model, memory, battery and connectivity through
/// `device_info_plus`, `battery_plus` and `connectivity_plus`.
///
/// Every platform call is bounded and failure-tolerant: a missing plugin
/// implementation (unit tests, unsupported platforms) leaves the field unset.
final class PluginDeviceInfoProvider implements RumDeviceInfoProvider {
  PluginDeviceInfoProvider() : _basic = dartDeviceInfo() {
    _current = _basic;
  }

  final RumDeviceInfo _basic;
  late RumDeviceInfo _current;
  RumDeviceInfo? _static;
  RumDeviceInfo? _battery;
  RumDeviceInfo? _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _connectivityChanges;
  bool _closed = false;

  @override
  RumDeviceInfo get current => _current;

  @override
  Future<void> refresh() async {
    if (_closed) return;
    final bool readStatic = _static == null;
    final List<RumDeviceInfo?> results = await Future.wait(
      <Future<RumDeviceInfo?>>[
        if (readStatic) _guard(_readStatic) else Future<RumDeviceInfo?>.value(),
        _guard(_readBattery),
        _guard(_readConnectivity),
      ],
    );
    if (_closed) return;
    _static = results[0] ?? _static;
    _battery = results[1] ?? _battery;
    _connectivity = results[2] ?? _connectivity;
    _compose();
    await _listenForConnectivityChanges();
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _connectivityChanges?.cancel();
    _connectivityChanges = null;
  }

  void _compose() {
    _current = <RumDeviceInfo?>[_static, _battery, _connectivity].fold(
      _basic,
      (RumDeviceInfo value, RumDeviceInfo? part) =>
          part == null ? value : value.merge(part),
    );
  }

  Future<void> _listenForConnectivityChanges() async {
    if (_connectivityChanges != null || _closed || _connectivity == null) {
      return;
    }
    try {
      _connectivityChanges = Connectivity().onConnectivityChanged.listen(
        (List<ConnectivityResult> results) {
          _connectivity = connectivityInfo(results);
          _compose();
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
    } on Object {
      // Connectivity changes are optional context.
    }
  }

  Future<RumDeviceInfo?> _readConnectivity() async => connectivityInfo(
    await Connectivity().checkConnectivity().timeout(_pluginTimeout),
  );

  Future<RumDeviceInfo?> _readBattery() async {
    final Battery battery = Battery();
    double? level;
    bool? powerSaving;
    try {
      final int percent = await battery.batteryLevel.timeout(_pluginTimeout);
      if (percent >= 0 && percent <= 100) level = percent / 100;
    } on Object {
      // Devices without a battery report no level.
    }
    try {
      powerSaving = await battery.isInBatterySaveMode.timeout(_pluginTimeout);
    } on Object {
      // Not every platform has a power-saving mode.
    }
    if (level == null && powerSaving == null) return null;
    return RumDeviceInfo(batteryLevel: level, powerSavingMode: powerSaving);
  }

  Future<RumDeviceInfo?> _readStatic() async {
    if (kIsWeb) return null;
    final BaseDeviceInfo info = await DeviceInfoPlugin().deviceInfo.timeout(
      _pluginTimeout,
    );
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => androidDeviceInfo(info.data),
      TargetPlatform.iOS => iosDeviceInfo(info.data),
      TargetPlatform.macOS => macosDeviceInfo(info.data),
      _ => null,
    };
  }

  Future<RumDeviceInfo?> _guard(Future<RumDeviceInfo?> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }
}

/// The OS facts Dart exposes without a plugin.
RumDeviceInfo dartDeviceInfo() {
  final String? text = operatingSystemVersionText();
  if (text == null) return const RumDeviceInfo();
  final RegExpMatch? match = RegExp(
    r'(?:Version\s+)?(\d+(?:\.\d+)*)\s*\(Build\s+([^)]+)\)',
  ).firstMatch(text);
  if (match == null) return const RumDeviceInfo();
  final bool reportsBuild =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
  if (!reportsBuild) return const RumDeviceInfo();
  return RumDeviceInfo(
    osVersion: match.group(1),
    osBuild: match.group(2)?.trim(),
  );
}

/// Maps `device_info_plus` Android data (`AndroidDeviceInfo.data`).
RumDeviceInfo androidDeviceInfo(Map<String, dynamic> data) {
  final Object? version = data['version'];
  final Map<dynamic, dynamic>? versionData = version is Map<dynamic, dynamic>
      ? version
      : null;
  return RumDeviceInfo(
    osVersion: _text(versionData?['release']),
    osBuild: _text(versionData?['incremental']),
    brand: _brand(_text(data['manufacturer']) ?? _text(data['brand'])),
    model: _text(data['model']),
    isLowRam: data['isLowRamDevice'] is bool
        ? data['isLowRamDevice']! as bool
        : null,
    totalRam: _megabytes(data['physicalRamSize']),
  );
}

/// Maps `device_info_plus` iOS data (`IosDeviceInfo.data`).
RumDeviceInfo iosDeviceInfo(Map<String, dynamic> data) {
  final Object? utsname = data['utsname'];
  final String? machine = utsname is Map<dynamic, dynamic>
      ? _text(utsname['machine'])
      : null;
  final bool identifier =
      machine != null &&
      (machine.startsWith('iPhone') ||
          machine.startsWith('iPad') ||
          machine.startsWith('iPod'));
  final String? model = identifier ? machine : _text(data['model']);
  return RumDeviceInfo(
    osVersion: _text(data['systemVersion']),
    brand: 'Apple',
    model: model,
    deviceType: model != null && model.startsWith('iPad') ? 'tablet' : null,
    totalRam: _megabytes(data['physicalRamSize']),
  );
}

/// Maps `device_info_plus` macOS data (`MacOsDeviceInfo.data`).
RumDeviceInfo macosDeviceInfo(Map<String, dynamic> data) {
  final Object? major = data['majorVersion'];
  final Object? minor = data['minorVersion'];
  final Object? patch = data['patchVersion'];
  return RumDeviceInfo(
    osVersion: major is int && minor is int && patch is int
        ? '$major.$minor.$patch'
        : null,
    brand: 'Apple',
    model: _text(data['model']),
    deviceType: 'desktop',
    totalRam: data['memorySize'] is int ? data['memorySize']! as int : null,
  );
}

/// Maps `connectivity_plus` results to the contract's `connectivity` fields.
RumDeviceInfo connectivityInfo(Iterable<ConnectivityResult> results) {
  final List<String> interfaces = <String>[];
  for (final ConnectivityResult result in results) {
    final String name = _interfaceName(result);
    if (!interfaces.contains(name)) interfaces.add(name);
  }
  if (interfaces.isEmpty) return const RumDeviceInfo();
  final bool offline = interfaces.length == 1 && interfaces.single == 'none';
  return RumDeviceInfo(
    connectivityStatus: offline ? 'not_connected' : 'connected',
    connectivityInterfaces: List<String>.unmodifiable(interfaces),
  );
}

String _interfaceName(ConnectivityResult result) {
  if (result == ConnectivityResult.wifi) return 'wifi';
  if (result == ConnectivityResult.mobile) return 'cellular';
  if (result == ConnectivityResult.ethernet) return 'ethernet';
  if (result == ConnectivityResult.bluetooth) return 'bluetooth';
  if (result == ConnectivityResult.none) return 'none';
  return 'other';
}

String? _text(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Android reports `samsung` as the brand; show it the way the maker spells it.
String? _brand(String? value) {
  if (value == null) return null;
  if (value != value.toLowerCase()) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

int? _megabytes(Object? value) =>
    value is int && value > 0 ? value * 1024 * 1024 : null;
