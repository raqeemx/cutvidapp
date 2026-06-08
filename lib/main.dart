import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'services/clip_repository.dart';
import 'services/export_queue_service.dart';
import 'services/incoming_media.dart';
import 'services/playback_store.dart';
import 'screens/home_screen.dart';
import 'screens/media_resolver_screen.dart';
import 'utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  final repo = ClipRepository();
  await repo.init();

  await PlaybackStore.init();

  // A video may have launched the app from outside ("Open with").
  final initialUri = await IncomingMedia.getInitialMedia();

  runApp(ClipMasterApp(repository: repo, initialUri: initialUri));
}

class ClipMasterApp extends StatefulWidget {
  final ClipRepository repository;

  /// URI of a video that launched the app from outside, if any (cold start).
  final String? initialUri;

  const ClipMasterApp({
    super.key,
    required this.repository,
    this.initialUri,
  });

  @override
  State<ClipMasterApp> createState() => _ClipMasterAppState();
}

class _ClipMasterAppState extends State<ClipMasterApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    // Warm start: videos opened while the app is already running.
    _sub = IncomingMedia.stream.listen(_handleIncoming);

    // Cold start: route after the first frame so the navigator exists.
    final initial = widget.initialUri;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleIncoming(initial);
      });
    }
  }

  void _handleIncoming(String uri) {
    _navKey.currentState?.push(
      MaterialPageRoute(builder: (_) => MediaResolverScreen(uri: uri)),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ClipRepository>.value(value: widget.repository),
        ChangeNotifierProvider<ExportQueueService>(
          create: (_) => ExportQueueService(widget.repository),
        ),
      ],
      child: MaterialApp(
        navigatorKey: _navKey,
        title: 'TrimXClip',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const HomeScreen(),
      ),
    );
  }
}
