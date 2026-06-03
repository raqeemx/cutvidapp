import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'services/clip_repository.dart';
import 'screens/home_screen.dart';
import 'utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  final repo = ClipRepository();
  await repo.init();

  runApp(ClipMasterApp(repository: repo));
}

class ClipMasterApp extends StatelessWidget {
  final ClipRepository repository;
  const ClipMasterApp({super.key, required this.repository});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ClipRepository>.value(
      value: repository,
      child: MaterialApp(
        title: 'Clip Master',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
