import 'package:http/http.dart' as http;

import '../models.dart';

final class DefaultRumTransport extends RumTransport {
  DefaultRumTransport({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    final http.Response response = await _client.post(
      request.url,
      headers: request.headers,
      body: request.body,
    );
    return RumTransportResponse(
      ok: response.statusCode >= 200 && response.statusCode < 300,
      status: response.statusCode,
      statusText: response.reasonPhrase,
      body: response.statusCode >= 200 && response.statusCode < 300
          ? null
          : response.body,
    );
  }

  @override
  Future<void> close() async {
    if (_ownsClient) _client.close();
  }
}
