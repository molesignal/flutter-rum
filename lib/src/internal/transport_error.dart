import 'dart:async';

import 'sanitization.dart';

final class NormalizedTransportError {
  const NormalizedTransportError(this.type, this.code, this.message);

  final String type;
  final String code;
  final String message;
}

NormalizedTransportError normalizeTransportError(Object error) {
  final String runtime = error.runtimeType.toString().toLowerCase();
  final String message = sanitizeText(error.toString(), limit: 1024);
  final String lower = '$runtime $message'.toLowerCase();
  if (error is TimeoutException || lower.contains('timeout')) {
    return NormalizedTransportError('timeout', 'timeout', message);
  }
  if (lower.contains('handshake') ||
      lower.contains('certificate') ||
      lower.contains('tls') ||
      lower.contains('ssl')) {
    return NormalizedTransportError('tls', 'tls_handshake', message);
  }
  if (lower.contains('failed host lookup') ||
      lower.contains('name or service not known') ||
      lower.contains('nodename nor servname')) {
    return NormalizedTransportError('dns', 'dns_lookup', message);
  }
  if (lower.contains('cancel')) {
    return NormalizedTransportError('cancel', 'cancelled', message);
  }
  if (lower.contains('connection refused')) {
    return NormalizedTransportError(
      'connection',
      'connection_refused',
      message,
    );
  }
  if (lower.contains('connection reset') || lower.contains('broken pipe')) {
    return NormalizedTransportError('connection', 'connection_reset', message);
  }
  return NormalizedTransportError('connection', 'connection_failed', message);
}
