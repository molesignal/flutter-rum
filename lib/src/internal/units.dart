/// The largest integer every runtime represents exactly (JavaScript numbers
/// are doubles), so a duration the contract carries as integer nanoseconds is
/// never rounded or wrapped around on any platform. About 104 days.
const int maximumNanoseconds = 9007199254740991;

/// [microseconds] as the contract's integer nanoseconds, between `0` and
/// [maximumNanoseconds]. A negative span (a clock that went backwards) is `0`.
int nanosecondsOfMicroseconds(int microseconds) {
  if (microseconds <= 0) return 0;
  if (microseconds > maximumNanoseconds ~/ 1000) return maximumNanoseconds;
  return microseconds * 1000;
}

int nanosecondsOf(Duration duration) =>
    nanosecondsOfMicroseconds(duration.inMicroseconds);
