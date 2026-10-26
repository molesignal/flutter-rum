import 'dart:math';

int nowMicros() => DateTime.now().microsecondsSinceEpoch;

int nowMillis() => DateTime.now().millisecondsSinceEpoch;

final Random _random = _createRandom();

Random _createRandom() {
  try {
    return Random.secure();
  } on Object {
    return Random();
  }
}

/// A random RFC 4122 version 4 UUID, accepted by the contract's `identifier`.
String generateUuid() {
  final List<int> bytes = List<int>.generate(
    16,
    (int _) => _random.nextInt(256),
    growable: false,
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

bool sample(double rate) {
  if (rate <= 0) return false;
  if (rate >= 100) return true;
  return _random.nextDouble() * 100 < rate;
}

String fnv1a(String value) {
  int hash = 0x811c9dc5;
  for (final int codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
