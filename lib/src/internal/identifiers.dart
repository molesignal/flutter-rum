import 'dart:math';

int nowMicros() => DateTime.now().microsecondsSinceEpoch;

String generateId(String prefix) {
  Random random;
  try {
    random = Random.secure();
  } on Object {
    random = Random();
  }
  final StringBuffer value = StringBuffer(prefix)..write('_');
  for (int index = 0; index < 16; index += 1) {
    value.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return value.toString();
}

bool sample(double rate) {
  if (rate <= 0) return false;
  if (rate >= 100) return true;
  return Random().nextDouble() * 100 < rate;
}

String fnv1a(String value) {
  int hash = 0x811c9dc5;
  for (final int codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
