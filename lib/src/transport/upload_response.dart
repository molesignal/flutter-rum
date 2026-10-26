import 'dart:convert';

import '../models.dart';

const Duration maximumRetryAfter = Duration(hours: 1);

/// One event the receiver refused, by its position in the uploaded array.
final class RejectedEvent {
  const RejectedEvent(this.index, this.reason);

  final int index;
  final String reason;
}

/// What the receiver answered to an `events` upload:
/// `{"accepted": 2, "rejected": [{"index": 1, "reason": "..."}]}`.
final class UploadAnswer {
  const UploadAnswer({this.accepted, this.rejected = const <RejectedEvent>[]});

  /// `null` when the body did not say.
  final int? accepted;
  final List<RejectedEvent> rejected;
}

UploadAnswer parseUploadAnswer(String? body) {
  if (body == null || body.trim().isEmpty) return const UploadAnswer();
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const UploadAnswer();
    final Object? accepted = decoded['accepted'];
    final Object? rejected = decoded['rejected'];
    return UploadAnswer(
      accepted: accepted is num ? accepted.toInt() : null,
      rejected: rejected is List<dynamic>
          ? <RejectedEvent>[
              for (final Object? item in rejected)
                if (item is Map<String, dynamic> && item['index'] is num)
                  RejectedEvent(
                    (item['index']! as num).toInt(),
                    item['reason'] is String ? item['reason']! as String : '',
                  ),
            ]
          : const <RejectedEvent>[],
    );
  } on Object {
    return const UploadAnswer();
  }
}

/// The delay a `Retry-After` header asks for: delta-seconds or an HTTP date.
/// Returns `null` for a missing or malformed value.
Duration? parseRetryAfter(String? value, DateTime now) {
  final String text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final int? seconds = int.tryParse(text);
  if (seconds != null) {
    return seconds < 0 ? null : _capped(Duration(seconds: seconds));
  }
  final RegExpMatch? date = RegExp(
    r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(text);
  if (date == null) return null;
  const List<String> months = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final int month = months.indexOf(date.group(2)!.toLowerCase());
  if (month < 0) return null;
  final DateTime until = DateTime.utc(
    int.parse(date.group(3)!),
    month + 1,
    int.parse(date.group(1)!),
    int.parse(date.group(4)!),
    int.parse(date.group(5)!),
    int.parse(date.group(6)!),
  );
  final Duration wait = until.difference(now.toUtc());
  return wait.isNegative ? Duration.zero : _capped(wait);
}

Duration? retryAfterOf(RumTransportResponse response, DateTime now) {
  for (final MapEntry<String, String> header in response.headers.entries) {
    if (header.key.toLowerCase() == 'retry-after') {
      return parseRetryAfter(header.value, now);
    }
  }
  return null;
}

Duration _capped(Duration value) =>
    value > maximumRetryAfter ? maximumRetryAfter : value;
