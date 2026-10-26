/// What the platform reports about the device the application runs on.
///
/// Every field is optional; the SDK sends only what is known. Values the SDK
/// can read from Flutter itself (locale, time zone, viewport, architecture)
/// are not part of this snapshot.
final class RumDeviceInfo {
  const RumDeviceInfo({
    this.osName,
    this.osVersion,
    this.osBuild,
    this.deviceType,
    this.brand,
    this.model,
    this.batteryLevel,
    this.powerSavingMode,
    this.isLowRam,
    this.totalRam,
    this.connectivityStatus,
    this.connectivityInterfaces = const <String>[],
  });

  /// `Android`, `iOS`, `macOS`, ... Defaults to the Flutter target platform.
  final String? osName;
  final String? osVersion;
  final String? osBuild;

  /// `mobile`, `tablet`, `desktop`, ... Defaults to a screen-size heuristic.
  final String? deviceType;
  final String? brand;

  /// The model identifier, for example `Pixel 8` or `iPhone15,2`.
  final String? model;

  /// Battery charge between `0` and `1`.
  final double? batteryLevel;
  final bool? powerSavingMode;
  final bool? isLowRam;

  /// Physical memory in bytes.
  final int? totalRam;

  /// `connected`, `not_connected`, or `maybe`.
  final String? connectivityStatus;

  /// Contract `connectivity.interfaces` values such as `wifi` and `cellular`.
  final List<String> connectivityInterfaces;

  /// This snapshot with every field [other] knows taking precedence.
  RumDeviceInfo merge(RumDeviceInfo other) => RumDeviceInfo(
    osName: other.osName ?? osName,
    osVersion: other.osVersion ?? osVersion,
    osBuild: other.osBuild ?? osBuild,
    deviceType: other.deviceType ?? deviceType,
    brand: other.brand ?? brand,
    model: other.model ?? model,
    batteryLevel: other.batteryLevel ?? batteryLevel,
    powerSavingMode: other.powerSavingMode ?? powerSavingMode,
    isLowRam: other.isLowRam ?? isLowRam,
    totalRam: other.totalRam ?? totalRam,
    connectivityStatus: other.connectivityStatus ?? connectivityStatus,
    connectivityInterfaces: other.connectivityStatus == null
        ? connectivityInterfaces
        : other.connectivityInterfaces,
  );
}

/// Supplies the device, OS, battery and connectivity context of events.
///
/// The SDK reads [current] whenever it builds an event, so it must return
/// without waiting; [refresh] is where slow platform queries belong.
abstract interface class RumDeviceInfoProvider {
  RumDeviceInfo get current;

  /// Re-reads values that change over time (battery, connectivity). It must
  /// not throw.
  Future<void> refresh();

  Future<void> close();
}
