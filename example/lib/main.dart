import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molesignal_flutter/molesignal_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final MoleSignalRumClient rum = await initRum(
    const RumConfiguration(
      applicationId: 'example-mobile',
      clientToken: String.fromEnvironment('MOLESIGNAL_RUM_TOKEN'),
      site: 'https://molesignal.example.com',
      service: 'example-app',
      env: 'development',
      version: String.fromEnvironment(
        'MOLESIGNAL_VERSION',
        defaultValue: '0.3.0',
      ),
      buildVersion: String.fromEnvironment('MOLESIGNAL_BUILD_VERSION'),
      architecture: String.fromEnvironment('MOLESIGNAL_ARCHITECTURE'),
      debugId: String.fromEnvironment('MOLESIGNAL_DEBUG_ID'),
      sessionReplaySampleRate: 100,
      trackUserInteractions: true,
    ),
  );
  rum.setUser(const RumUser(id: 'example-user', name: 'Example User'));
  rum.addFeatureFlagEvaluation('new_home', true);
  runApp(
    RumApp(
      client: rum,
      child: ExampleApp(rum: rum),
    ),
  );
}

final class ExampleApp extends StatelessWidget {
  const ExampleApp({required this.rum, super.key});

  final MoleSignalRumClient rum;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MoleSignal Flutter RUM',
    navigatorObservers: <NavigatorObserver>[RumNavigationObserver(rum)],
    routes: <String, WidgetBuilder>{
      '/': (_) => HomePage(rum: rum),
      '/details': (_) => const DetailsPage(),
    },
  );
}

final class HomePage extends StatefulWidget {
  const HomePage({required this.rum, super.key});

  final MoleSignalRumClient rum;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  late final http.Client _httpClient = MoleSignalHttpClient(widget.rum);

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    try {
      await _httpClient.get(Uri.parse('https://example.com/health'));
    } catch (error, stackTrace) {
      widget.rum.addError(error, stackTrace: stackTrace);
    }
  }

  Future<void> _measureLoad() async {
    widget.rum.startDurationVital('example_load');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    widget.rum.stopDurationVital('example_load');
    widget.rum.addTiming('example_loaded');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MoleSignal RUM example')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RumUserAction(
            client: widget.rum,
            name: 'Open details',
            child: ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/details'),
              child: const Text('Open details'),
            ),
          ),
          TextButton(
            onPressed: _sendRequest,
            child: const Text('Send an instrumented request'),
          ),
          TextButton(
            onPressed: _measureLoad,
            child: const Text('Measure a duration'),
          ),
          TextButton(
            onPressed: () => widget.rum.addAction(
              'Checkout submitted',
              context: const <String, Object?>{'cart_size': 3},
            ),
            child: const Text('Record a custom action'),
          ),
        ],
      ),
    ),
  );
}

final class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: RumReplayBlock(child: Text('Sensitive account details')),
    ),
  );
}
