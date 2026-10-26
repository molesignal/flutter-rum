import 'runtime_info_stub.dart'
    if (dart.library.io) 'runtime_info_io.dart'
    as runtime;

/// `Platform.operatingSystemVersion`, or `null` where `dart:io` is unavailable.
String? operatingSystemVersionText() => runtime.operatingSystemVersion();

/// Logical processor count, or `null` where `dart:io` is unavailable.
int? logicalProcessorCount() => runtime.processorCount();

/// Resident set size of the process in bytes, or `null` when unknown.
int? currentMemoryBytes() => runtime.currentMemoryBytes();

/// Gzip-compressed [bytes], or `null` where compression is unavailable.
List<int>? gzipBytes(List<int> bytes) => runtime.gzipBytes(bytes);
