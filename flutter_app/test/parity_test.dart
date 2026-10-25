import 'dart:convert';
import 'dart:io';

import 'package:basketball_highlights/domain/shot_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// Asserts the Dart port produces exactly the events Python produced from the same raw
/// detections. The goldens come from `python tools/dump_reference.py replay`, so this is the
/// guard against the two implementations drifting apart during the port.
void main() {
  const stem = 'video_test_5';
  final detectionsFile = File('../fixtures/${stem}_detections.json');
  final eventsFile = File('../fixtures/${stem}_events.json');

  test('fixtures are present (run tools/dump_reference.py first)', () {
    expect(detectionsFile.existsSync(), isTrue, reason: '${detectionsFile.path} missing');
    expect(eventsFile.existsSync(), isTrue, reason: '${eventsFile.path} missing');
  });

  final detections = jsonDecode(detectionsFile.readAsStringSync()) as Map<String, dynamic>;
  final expected = jsonDecode(eventsFile.readAsStringSync()) as Map<String, dynamic>;

  test('replays every frame and matches the Python event list', () {
    final params = expected['tracker_params'] as Map<String, dynamic>;
    final tracker = ShotTracker(
      fps: (detections['fps'] as num).toDouble(),
      ballConf: (params['ball_conf'] as num).toDouble(),
      ballConfNearHoop: (params['ball_conf_near_hoop'] as num).toDouble(),
      hoopConf: (params['hoop_conf'] as num).toDouble(),
      attemptCooldownS: (params['attempt_cooldown_s'] as num).toDouble(),
      explain: true,
    );

    for (final frame in detections['frames'] as List<dynamic>) {
      final rows = frame['d'] as List<dynamic>;
      tracker.addFrame(frame['i'] as int, rows.map((r) => Detection.fromList(r as List<dynamic>)));
    }

    expect(tracker.makes, expected['makes'], reason: 'make count');
    expect(tracker.attempts, expected['attempts'], reason: 'attempt count');

    final want = expected['events'] as List<dynamic>;
    expect(tracker.events.length, want.length, reason: 'event count');

    for (var i = 0; i < want.length; i++) {
      final e = want[i] as Map<String, dynamic>;
      final g = tracker.events[i];
      expect([g.frame, g.microseconds, g.type, g.upFrame, g.hoop],
          [e['frame'], e['t_us'], e['type'], e['up_frame'], (e['hoop'] as List).cast<int>()],
          reason: 'event #$i (${tracker.reasons[i]})');
    }
  });
}
