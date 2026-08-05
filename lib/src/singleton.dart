import 'client.dart';
import 'configuration.dart';

MoleSignalRumClient? _activeClient;

/// Initializes and installs the process-wide MoleSignal RUM client.
///
/// A previous client is stopped before it is replaced.
Future<MoleSignalRumClient> initRum(RumConfiguration configuration) async {
  final MoleSignalRumClient? previous = _activeClient;
  if (previous != null) await previous.stop();
  final MoleSignalRumClient client = await MoleSignalRumClient.create(
    configuration,
  );
  _activeClient = client;
  return client;
}

/// Returns the active process-wide client, if initialized.
MoleSignalRumClient? getRum() => _activeClient;
