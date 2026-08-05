import '../configuration.dart';
import '../internal/diagnostics.dart';
import '../internal/identifiers.dart';
import '../models.dart';

Future<void> validateCredentialApplicationBinding(
  NormalizedRumConfiguration configuration,
  RumPersistence persistence,
) async {
  final String prefix = configuration.clientToken.split('_')[1];
  final String key = 'molesignal_rum_credential_binding_${fnv1a(prefix)}';
  try {
    final String? existing = await persistence.read(key);
    if (existing != null && existing != configuration.applicationId) {
      throw ArgumentError.value(
        configuration.applicationId,
        'applicationId',
        'the configured RUM credential was already bound to application $existing',
      );
    }
    if (existing == null) {
      await persistence.write(key, configuration.applicationId);
    }
  } on ArgumentError {
    rethrow;
  } on Object catch (error, stackTrace) {
    reportDiagnostic(
      configuration.onError,
      'RUM credential binding persistence failed',
      error,
      stackTrace,
    );
  }
}

Future<String?> getAnonymousUserId(
  NormalizedRumConfiguration configuration,
  RumPersistence persistence,
) async {
  if (!configuration.trackAnonymousUser) return null;
  final String key =
      'molesignal_rum_anonymous_${_storageKey(configuration.applicationId)}';
  try {
    final String? existing = await persistence.read(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final String created = generateId('anon');
    await persistence.write(key, created);
    return created;
  } on Object catch (error, stackTrace) {
    reportDiagnostic(
      configuration.onError,
      'RUM anonymous identity persistence failed',
      error,
      stackTrace,
    );
    return generateId('anon');
  }
}

String _storageKey(String value) {
  final String sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  final int end = sanitized.length > 80 ? 80 : sanitized.length;
  return sanitized.substring(0, end);
}
