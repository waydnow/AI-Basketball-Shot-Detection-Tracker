import 'package:shared_preferences/shared_preferences.dart';

/// App-wide defaults. Per-marker windows live in the `shots` table; these are only the
/// values a newly added or newly detected marker starts with.
class AppSettings {
  AppSettings({
    this.windowBeforeS = 3.0,
    this.windowAfterS = 3.0,
    this.ballConf = 0.3,
    this.ballConfNearHoop = 0.15,
    this.hoopConf = 0.5,
    this.includeMisses = true,
    this.outputHeight = 0,
    this.outputFps = 0,
  });

  double windowBeforeS;
  double windowAfterS;
  double ballConf;
  double ballConfNearHoop;
  double hoopConf;
  bool includeMisses;

  /// 0 means "keep the source", which is what the ffmpeg step passes straight through.
  int outputHeight;
  double outputFps;

  int get windowBeforeUs => (windowBeforeS * 1000000).round();
  int get windowAfterUs => (windowAfterS * 1000000).round();

  static Future<AppSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    return AppSettings(
      windowBeforeS: sp.getDouble('window_before_s') ?? 3.0,
      windowAfterS: sp.getDouble('window_after_s') ?? 3.0,
      ballConf: sp.getDouble('ball_conf') ?? 0.3,
      ballConfNearHoop: sp.getDouble('ball_conf_near_hoop') ?? 0.15,
      hoopConf: sp.getDouble('hoop_conf') ?? 0.5,
      includeMisses: sp.getBool('include_misses') ?? true,
      outputHeight: sp.getInt('output_height') ?? 0,
      outputFps: sp.getDouble('output_fps') ?? 0,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('window_before_s', windowBeforeS);
    await sp.setDouble('window_after_s', windowAfterS);
    await sp.setDouble('ball_conf', ballConf);
    await sp.setDouble('ball_conf_near_hoop', ballConfNearHoop);
    await sp.setDouble('hoop_conf', hoopConf);
    await sp.setBool('include_misses', includeMisses);
    await sp.setInt('output_height', outputHeight);
    await sp.setDouble('output_fps', outputFps);
  }
}
