import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persistent storage backed by the platform's shared-preferences service.
final class SharedPreferencesRumPersistence implements RumPersistence {
  SharedPreferencesRumPersistence({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> remove(String key) => _preferences.remove(key);

  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);
}
