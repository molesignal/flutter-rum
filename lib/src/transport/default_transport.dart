import 'dart:convert';

import 'package:http/http.dart' as http;

import '../internal/runtime_info.dart';
import '../models.dart';

/// Bodies shorter than this are sent uncompressed.
const int _minimumCompressedBytes = 1024;

/// Responses are read for the receiver's answer, not for large payloads.
const int _maximumResponseCharacters = 64 * 1024;

final class DefaultRumTransport extends RumTransport {
  DefaultRumTransport({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    final List<int> raw = utf8.encode(request.body);
    final List<int>? compressed =
        request.compress && raw.length >= _minimumCompressedBytes
        ? gzipBytes(raw)
        : null;
    final http.Response response = await _client.post(
      request.url,
      headers: <String, String>{
        ...request.headers,
        if (compressed != null) 'content-encoding': 'gzip',
      },
      body: compressed ?? raw,
    );
    final String body = response.body;
    return RumTransportResponse(
      ok: response.statusCode >= 200 && response.statusCode < 300,
      status: response.statusCode,
      statusText: response.reasonPhrase,
      body: body.length > _maximumResponseCharacters
          ? body.substring(0, _maximumResponseCharacters)
          : body,
      headers: <String, String>{
        for (final MapEntry<String, String> header in response.headers.entries)
          header.key.toLowerCase(): header.value,
      },
    );
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}
