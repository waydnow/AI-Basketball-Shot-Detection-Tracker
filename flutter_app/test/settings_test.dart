import 'package:basketball_highlights/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the three presets carry the triple the detector reads', () {
    final s = AppSettings()..applyPreset(DetectionSensitivity.strict);
    expect((s.ballConf, s.ballConfNearHoop, s.hoopConf), (0.45, 0.25, 0.60));
    expect(AppSettings().preset, DetectionSensitivity.standard);
    expect(DetectionSensitivity.standard.ballConf, 0.30,
        reason: 'the Python reference and the golden fixtures were cut at 0.30');
  });

  test('the name is read back off the numbers, so a slider cannot lie about it', () {
    final s = AppSettings()..hoopConf = 0.55;
    expect(s.preset, isNull, reason: 'one value off any triple is 自定义');
    s.hoopConf = 0.35;
    expect(s.preset, isNull);
    s.ballConf = 0.15;
    s.ballConfNearHoop = 0.10;
    expect(s.preset, DetectionSensitivity.loose, reason: 'back on a triple, back on the name');
  });

  test('a slider step lands exactly on the triple it came from', () {
    // Slider computes its own values, so 6/18 of 0.9 is not 0.3; the page quantises before
    // storing, and that is what keeps a preset labelled as one.
    final stepped = (0.9 * 6 / 18 * 100).round() / 100;
    expect(stepped == 0.9 * 6 / 18, isFalse);
    expect(AppSettings(ballConf: stepped).preset, isNotNull);
  });
}
