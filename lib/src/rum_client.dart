import 'models.dart';

/// Public operations supported by a MoleSignal RUM client.
abstract interface class RumClient {
  void setUser(RumUser user);
  void clearUser();
  RumUser? getUser();

  void setAccount(RumAccount account);
  void clearAccount();
  RumAccount? getAccount();

  void setGlobalContext(RumContext context);
  void setGlobalContextProperty(String key, Object? value);
  void removeGlobalContextProperty(String key);
  void clearGlobalContext();
  RumContext getGlobalContext();

  /// Records the value a feature flag evaluated to; later events carry it in
  /// `feature_flags`.
  void addFeatureFlagEvaluation(String name, Object? value);

  /// Starts a view. [key] is the route path or URL (`view.url`); [name]
  /// defaults to it. Starting a view ends the previous one.
  void startView(
    String key, {
    String? name,
    RumContext context = const <String, Object?>{},
  });

  /// Ends the current view when it was started with [key].
  void stopView(String key);

  /// Marks a moment in the current view, as time since the view started
  /// (`view.custom_timings`).
  void addTiming(String name);

  void addAction(
    String name, {
    RumActionType type = RumActionType.custom,
    RumContext context = const <String, Object?>{},
  });

  void addError(
    Object error, {
    StackTrace? stackTrace,
    RumErrorSource source = RumErrorSource.custom,
    String? type,
    String? fingerprint,
    List<RumStackFrame> frames = const <RumStackFrame>[],
    RumContext context = const <String, Object?>{},
  });

  /// Reports a request that has already finished.
  void addResource(RumResource resource);

  /// Starts timing a request; finish it with [stopResource] or
  /// [stopResourceWithError]. [key] identifies the request.
  void startResource(
    String key,
    String method,
    Uri url, {
    RumContext context = const <String, Object?>{},
  });

  void stopResource(
    String key, {
    int? statusCode,
    int? size,
    RumTraceContext? traceContext,
    RumContext context = const <String, Object?>{},
  });

  /// Finishes a request that failed before a response arrived.
  void stopResourceWithError(
    String key,
    Object error, {
    int? statusCode,
    RumTraceContext? traceContext,
    RumContext context = const <String, Object?>{},
  });

  void startDurationVital(
    String name, {
    String? description,
    RumContext context = const <String, Object?>{},
  });

  void stopDurationVital(
    String name, {
    String? description,
    RumContext context = const <String, Object?>{},
  });

  /// Reports a duration measured elsewhere.
  void addDurationVital(
    String name,
    Duration duration, {
    String? description,
    RumContext context = const <String, Object?>{},
  });

  void startSessionReplayRecording();
  void stopSessionReplayRecording();

  RumInternalContext getInternalContext();
  Future<RumFlushResult> flush();
  Future<RumFlushResult> stop();
}
