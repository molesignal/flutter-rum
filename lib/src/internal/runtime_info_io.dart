import 'dart:io';

String? operatingSystemVersion() {
  try {
    return Platform.operatingSystemVersion;
  } on Object {
    return null;
  }
}

int? processorCount() {
  try {
    return Platform.numberOfProcessors;
  } on Object {
    return null;
  }
}

int? currentMemoryBytes() {
  try {
    return ProcessInfo.currentRss;
  } on Object {
    return null;
  }
}

List<int>? gzipBytes(List<int> bytes) {
  try {
    return gzip.encode(bytes);
  } on Object {
    return null;
  }
}
