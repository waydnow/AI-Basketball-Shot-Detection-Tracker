import 'package:shared_preferences/shared_preferences.dart';

/// The three confidence gates have to move together - raising only the hoop one keeps the
/// phantom balls, raising only the ball one loses the shot at the rim - so the UI offers one
/// dial and this names the triples behind it. `standard` is what the Python reference and the
/// golden fixtures were produced with.
enum DetectionSensitivity {
  loose(0.15, 0.10, 0.35, '宽松'),
  standard(0.30, 0.15, 0.50, '标准'),
  strict(0.45, 0.25, 0.60, '严格');

  const DetectionSensitivity(this.ballConf, this.ballConfNearHoop, this.hoopConf, this.label);

  /// Higher means fewer boxes survive, i.e. fewer markers and more misses.
  final double ballConf;
  final double ballConfNearHoop;
  final double hoopConf;
  final String label;
}

/// App-wide defaults. Per-marker windows live in the `shots` table; these are only the
/// values a newly added or newly detected marker starts with.
class AppSettings {
  AppSettings({
    this.windowBeforeS = 3.0,
    this.windowAfterS = 3.0,
    this.sensitivity = DetectionSensitivity.standard,
    this.includeMisses = true,
    this.outputHeight = 0,
    this.outputFps = 0,
  });

  double windowBeforeS;
  double windowAfterS;
  DetectionSensitivity sensitivity;
  bool includeMisses;

  /// 0 means "keep the source", which is what the ffmpeg step passes straight through.
  int outputHeight;
  double outputFps;

  int get windowBeforeUs => (windowBeforeS * 1000000).round();
  int get windowAfterUs => (windowAfterS * 1000000).round();

  double get ballConf => sensitivity.ballConf;
  double get ballConfNearHoop => sensitivity.ballConfNearHoop;
  double get hoopConf => sensitivity.hoopConf;

  static Future<AppSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final stored = sp.getString('sensitivity');
    return AppSettings(
      windowBeforeS: sp.getDouble('window_before_s') ?? 3.0,
      windowAfterS: sp.getDouble('window_after_s') ?? 3.0,
      sensitivity: DetectionSensitivity.values
          .firstWhere((e) => e.name == stored, orElse: () => DetectionSensitivity.standard),
      includeMisses: sp.getBool('include_misses') ?? true,
      outputHeight: sp.getInt('output_height') ?? 0,
      outputFps: sp.getDouble('output_fps') ?? 0,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('window_before_s', windowBeforeS);
    await sp.setDouble('window_after_s', windowAfterS);
    await sp.setString('sensitivity', sensitivity.name);
    await sp.setBool('include_misses', includeMisses);
    await sp.setInt('output_height', outputHeight);
    await sp.setDouble('output_fps', outputFps);
  }
}
