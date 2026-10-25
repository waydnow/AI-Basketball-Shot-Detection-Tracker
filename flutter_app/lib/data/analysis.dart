import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../domain/models.dart';
import 'settings.dart';

/// Where a clip's markers come from. Phase 4 adds an on-device ONNX implementation; the UI
/// only talks to this, so nothing has to change when the real detector arrives.
abstract class AnalysisBackend {
  Future<List<Shot>> analyze(String videoId, AppSettings settings);

  /// Shown under the timeline so a demo marker is never mistaken for a real detection.
  String get label;
}

/// The Python reference run on `video_test_5.mp4`, replayed into the UI.
class FixtureAnalysis implements AnalysisBackend {
  const FixtureAnalysis();

  static const asset = 'assets/fixtures/video_test_5_events.json';

  @override
  String get label => '示例识别结果（Python 黄金文件）· 阶段 4 换成端侧推理';

  @override
  Future<List<Shot>> analyze(String videoId, AppSettings settings) async {
    final data = jsonDecode(await rootBundle.loadString(asset)) as Map<String, dynamic>;
    return [
      for (final e in (data['events'] as List).cast<Map<String, dynamic>>())
        Shot(
          videoId: videoId,
          tUs: e['t_us'] as int,
          isMake: e['type'] == 'make',
          origin: ShotOrigin.auto,
          windowBeforeUs: settings.windowBeforeUs,
          windowAfterUs: settings.windowAfterUs,
        ),
    ];
  }
}
