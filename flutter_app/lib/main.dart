import 'package:flutter/material.dart';

import 'data/analysis.dart';
import 'data/database.dart';
import 'data/settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  final settings = await AppSettings.load();
  runApp(BasketballHighlights(db: db, settings: settings, analysis: const FixtureAnalysis()));
}

class BasketballHighlights extends StatelessWidget {
  const BasketballHighlights({
    super.key,
    required this.db,
    required this.settings,
    required this.analysis,
  });

  final AppDatabase db;
  final AppSettings settings;
  final AnalysisBackend analysis;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '篮球高光',
      debugShowCheckedModeBanner: false,
      // The timeline is painted dark-on-dark deliberately: a film strip reads as a strip only
      // against a black background, and the editor screen is the app's main surface.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepOrange, brightness: Brightness.dark),
      ),
      home: HomePage(db: db, settings: settings, analysis: analysis),
    );
  }
}
