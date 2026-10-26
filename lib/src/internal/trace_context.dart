import '../models.dart';

final RegExp _traceparent = RegExp(
  r'^[\da-f]{2}-([\da-f]{32})-([\da-f]{16})-[\da-f]{2}(?:-|$)',
  caseSensitive: false,
);

RumTraceContext? parseTraceparent(String? value) {
  if (value == null) return null;
  final RegExpMatch? match = _traceparent.firstMatch(value.trim());
  final String? traceId = match?.group(1)?.toLowerCase();
  final String? spanId = match?.group(2)?.toLowerCase();
  if (traceId == null || spanId == null) return null;
  if (RegExp(r'^0+$').hasMatch(traceId) || RegExp(r'^0+$').hasMatch(spanId)) {
    return null;
  }
  return RumTraceContext(traceId: traceId, spanId: spanId);
}

String? traceparentFromServerTiming(String? value) {
  if (value == null) return null;
  for (final String metric in value.split(',')) {
    final String name = metric.split(';').first.trim().toLowerCase();
    if (name != 'traceparent') continue;
    final RegExpMatch? description = RegExp(
      r';\s*desc=(?:"([^"]+)"|([^;,\s]+))',
      caseSensitive: false,
    ).firstMatch(metric);
    return description?.group(1) ?? description?.group(2);
  }
  return null;
}
