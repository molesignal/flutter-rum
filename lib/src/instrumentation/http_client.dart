import 'dart:async';

import 'package:http/http.dart' as http;

import '../client.dart';
import '../internal/trace_context.dart';
import '../models.dart';

/// A composable `package:http` client that records outgoing resources.
final class MoleSignalHttpClient extends http.BaseClient {
  MoleSignalHttpClient(this.rum, {http.Client? inner, this.closeInner = true})
    : _inner = inner ?? http.Client();

  final MoleSignalRumClient rum;
  final http.Client _inner;
  final bool closeInner;
  int _requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!rum.resourceTrackingEnabled ||
        rum.isSdkUrl(request.url) ||
        !rum.shouldTrackUrl(request.url)) {
      return _inner.send(request);
    }

    final String key = 'http_${identityHashCode(this)}_${_requests++}';
    final String? requestTraceparent = _header(request.headers, 'traceparent');
    rum.startResource(key, request.method, request.url);
    try {
      final http.StreamedResponse response = await _inner.send(request);
      final RumTraceContext? traceContext = rum.shouldReadTrace(request.url)
          ? parseTraceparent(_header(response.headers, 'traceparent')) ??
                parseTraceparent(
                  traceparentFromServerTiming(
                    _header(response.headers, 'server-timing'),
                  ),
                ) ??
                parseTraceparent(requestTraceparent)
          : null;
      int responseBytes = 0;
      bool finished = false;

      void finish({Object? error}) {
        if (finished) return;
        finished = true;
        if (error == null) {
          rum.stopResource(
            key,
            statusCode: response.statusCode,
            size: responseBytes,
            traceContext: traceContext,
          );
        } else {
          rum.stopResourceWithError(
            key,
            error,
            statusCode: response.statusCode,
            traceContext: traceContext,
          );
        }
      }

      late final StreamController<List<int>> controller;
      StreamSubscription<List<int>>? subscription;
      controller = StreamController<List<int>>(
        sync: true,
        onListen: () {
          subscription = response.stream.listen(
            (List<int> chunk) {
              responseBytes += chunk.length;
              controller.add(chunk);
            },
            onError: (Object error, StackTrace stackTrace) {
              finish(error: error);
              controller.addError(error, stackTrace);
            },
            onDone: () {
              finish();
              unawaited(controller.close());
            },
            cancelOnError: false,
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () async {
          await subscription?.cancel();
          finish(error: const _ResponseCancelled());
        },
      );

      return http.StreamedResponse(
        controller.stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } on Object catch (error, stackTrace) {
      rum.stopResourceWithError(
        key,
        error,
        traceContext: rum.shouldReadTrace(request.url)
            ? parseTraceparent(requestTraceparent)
            : null,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  void close() {
    if (closeInner) _inner.close();
  }
}

/// The caller stopped reading the response body; not a failure of the request.
final class _ResponseCancelled implements Exception {
  const _ResponseCancelled();

  @override
  String toString() => 'response body consumption cancelled';
}

String? _header(Map<String, String> headers, String name) {
  final String lowerName = name.toLowerCase();
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == lowerName) return entry.value;
  }
  return null;
}
