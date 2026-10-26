import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/environment/default_device_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device_info_plus data', () {
    test('Android: maker, model, release, build and memory', () {
      final RumDeviceInfo info = androidDeviceInfo(<String, dynamic>{
        'manufacturer': 'samsung',
        'brand': 'samsung',
        'model': 'SM-S928B',
        'version': <String, dynamic>{
          'release': '15',
          'incremental': 'S928BXXU1AXA1',
          'sdkInt': 35,
        },
        'isLowRamDevice': false,
        'physicalRamSize': 11713,
      });
      expect(info.brand, 'Samsung');
      expect(info.model, 'SM-S928B');
      expect(info.osVersion, '15');
      expect(info.osBuild, 'S928BXXU1AXA1');
      expect(info.isLowRam, isFalse);
      expect(info.totalRam, 11713 * 1024 * 1024);
    });

    test('Android: a maker that already capitalizes is left alone', () {
      expect(
        androidDeviceInfo(<String, dynamic>{'manufacturer': 'OnePlus'}).brand,
        'OnePlus',
      );
      expect(
        androidDeviceInfo(<String, dynamic>{'brand': 'google'}).brand,
        'Google',
      );
    });

    test('Android: missing or malformed data stays unset', () {
      final RumDeviceInfo info = androidDeviceInfo(<String, dynamic>{
        'manufacturer': '  ',
        'version': 'not a map',
        'physicalRamSize': -1,
        'isLowRamDevice': 'yes',
      });
      expect(info.brand, isNull);
      expect(info.osVersion, isNull);
      expect(info.totalRam, isNull);
      expect(info.isLowRam, isNull);
    });

    test('iOS: the hardware identifier is the model, Apple the brand', () {
      final RumDeviceInfo phone = iosDeviceInfo(<String, dynamic>{
        'systemVersion': '17.5.1',
        'model': 'iPhone',
        'utsname': <String, dynamic>{'machine': 'iPhone15,2'},
        'physicalRamSize': 6144,
      });
      expect(phone.brand, 'Apple');
      expect(phone.model, 'iPhone15,2');
      expect(phone.osVersion, '17.5.1');
      expect(phone.deviceType, isNull);
      expect(phone.totalRam, 6144 * 1024 * 1024);

      expect(
        iosDeviceInfo(<String, dynamic>{
          'utsname': <String, dynamic>{'machine': 'iPad14,3'},
        }).deviceType,
        'tablet',
      );
    });

    test(
      'iOS: a simulator reports its architecture, so the generic model is used',
      () {
        final RumDeviceInfo info = iosDeviceInfo(<String, dynamic>{
          'model': 'iPhone',
          'utsname': <String, dynamic>{'machine': 'arm64'},
        });
        expect(info.model, 'iPhone');
      },
    );

    test('macOS: version and memory', () {
      final RumDeviceInfo info = macosDeviceInfo(<String, dynamic>{
        'majorVersion': 14,
        'minorVersion': 5,
        'patchVersion': 1,
        'model': 'Mac14,2',
        'memorySize': 17179869184,
      });
      expect(info.osVersion, '14.5.1');
      expect(info.model, 'Mac14,2');
      expect(info.deviceType, 'desktop');
      expect(info.totalRam, 17179869184);
    });
  });

  group('connectivity_plus results', () {
    test('map to contract interfaces', () {
      final RumDeviceInfo info = connectivityInfo(<ConnectivityResult>[
        ConnectivityResult.wifi,
        ConnectivityResult.mobile,
        ConnectivityResult.ethernet,
        ConnectivityResult.bluetooth,
        ConnectivityResult.vpn,
        ConnectivityResult.other,
        ConnectivityResult.wifi,
      ]);
      expect(info.connectivityStatus, 'connected');
      expect(info.connectivityInterfaces, <String>[
        'wifi',
        'cellular',
        'ethernet',
        'bluetooth',
        'other',
      ]);
    });

    test('none is not connected', () {
      final RumDeviceInfo info = connectivityInfo(<ConnectivityResult>[
        ConnectivityResult.none,
      ]);
      expect(info.connectivityStatus, 'not_connected');
      expect(info.connectivityInterfaces, <String>['none']);
    });

    test('nothing reported is unknown', () {
      final RumDeviceInfo info = connectivityInfo(const <ConnectivityResult>[]);
      expect(info.connectivityStatus, isNull);
    });
  });

  group('providers', () {
    test('a snapshot is merged with what a newer one knows', () {
      const RumDeviceInfo base = RumDeviceInfo(
        brand: 'Google',
        batteryLevel: 0.9,
        connectivityStatus: 'connected',
        connectivityInterfaces: <String>['wifi'],
      );
      final RumDeviceInfo merged = base.merge(
        const RumDeviceInfo(
          model: 'Pixel 8',
          batteryLevel: 0.5,
          connectivityStatus: 'not_connected',
          connectivityInterfaces: <String>['none'],
        ),
      );
      expect(merged.brand, 'Google');
      expect(merged.model, 'Pixel 8');
      expect(merged.batteryLevel, 0.5);
      expect(merged.connectivityStatus, 'not_connected');
      expect(merged.connectivityInterfaces, <String>['none']);

      final RumDeviceInfo kept = base.merge(const RumDeviceInfo(model: 'x'));
      expect(kept.connectivityInterfaces, <String>['wifi']);
    });

    test('the Dart-only provider needs no platform plugin', () async {
      final DartDeviceInfoProvider provider = DartDeviceInfoProvider();
      await provider.refresh();
      expect(provider.current.brand, isNull);
      expect(provider.current.batteryLevel, isNull);
      await provider.close();
    });

    test(
      'the plugin provider survives platforms without the plugins',
      () async {
        final PluginDeviceInfoProvider provider = PluginDeviceInfoProvider();
        await provider.refresh().timeout(const Duration(seconds: 10));
        await provider.refresh().timeout(const Duration(seconds: 10));
        // In unit tests no platform implementation answers, so nothing is known
        // beyond what Dart provides; the point is that nothing throws or hangs.
        expect(provider.current.brand, isNull);
        expect(provider.current.batteryLevel, isNull);
        await provider.close();
        await provider.refresh();
      },
    );

    test('the client uses plugins unless told not to', () {
      expect(
        createDefaultDeviceInfoProvider(usePlugins: true),
        isA<PluginDeviceInfoProvider>(),
      );
      expect(
        createDefaultDeviceInfoProvider(usePlugins: false),
        isA<DartDeviceInfoProvider>(),
      );
    });
  });
}
