import '../models.dart';
import 'sanitization.dart';

void reportDiagnostic(
  RumDiagnosticHandler? handler,
  String message, [
  Object? cause,
  StackTrace? stackTrace,
]) {
  if (handler == null) return;
  try {
    handler(
      RumDiagnostic(
        sanitizeText(message),
        cause: cause == null ? null : sanitizeText(cause.toString()),
        stackTrace: stackTrace == null
            ? null
            : StackTrace.fromString(sanitizeStackText(stackTrace.toString())),
      ),
    );
  } on Object {
    // Diagnostics must never affect the monitored application.
  }
}
