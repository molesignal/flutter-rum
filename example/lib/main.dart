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
      architecture: String.fromEnvironment('MOLESIGNAL_ARCHITECTURE'),
      debugId: String.fromEnvironment('MOLESIGNAL_DEBUG_ID'),
      sessionReplaySampleRate: 100,
      trackUserInteractions: true,
    ),
  );
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
            onPressed: () async {
              try {
                await _httpClient.get(Uri.parse('https://example.com/health'));
              } catch (error, stackTrace) {
                widget.rum.addError(error, stackTrace: stackTrace);
              }
            },
            child: const Text('Send an instrumented request'),
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
