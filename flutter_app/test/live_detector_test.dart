import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:basketball_highlights/data/live_detector.dart';
import 'package:basketball_highlights/domain/letterbox.dart';
import 'package:basketball_highlights/domain/shot_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The worker isolate end to end: bytes in one side, boxes out the other.
///
/// `live_reference_test.dart` proves the same numbers on the host with the calls inlined; this
/// proves the channel, the busy/drop rule and the tensor round trip that only exist in
/// [LiveDetector]. It needs the same host runtime as that test, so it skips without it:
///   cp .venv/lib/python3.*/site-packages/onnxruntime/capi/libonnxruntime.*.dylib \
///      flutter_app/libonnxruntime.1.15.1.dylib
void main() {
  // Without the widget binding `rootBundle` has no asset store to read from, and a missing
  // asset is indistinguishable from a missing model.
  TestWidgetsFlutterBinding.ensureInitialized();

  final referenceFile = File('../fixtures/live_reference.json');
  final runnable =
      File('libonnxruntime.1.15.1.dylib').existsSync() &&
      File('assets/model/best.onnx').existsSync();
  final reference =
      jsonDecode(referenceFile.readAsStringSync()) as Map<String, dynamic>;
  final frameW = reference['width'] as int, frameH = reference['height'] as int;

  LiveDetector? detector;
  StreamQueue<LiveFrame>? results;

  group('live detector isolate', () {
    setUp(() async {
      detector = await LiveDetector.load();
      results = StreamQueue(detector!.frames);
    });
    tearDown(() async {
      await results?.cancel(immediate: true);
      await detector?.dispose();
    });

    Nv21Frame frameOf(String path) => Nv21Frame(
      bytes: _gunzip(File('../fixtures/$path').readAsBytesSync()),
      width: frameW,
      height: frameH,
      rotation: 0,
    );

    test('a busy worker drops instead of queueing', () async {
      final frame = frameOf(
        ((reference['frames'] as List).first as Map<String, dynamic>)['nv21']
            as String,
      );
      expect(detector!.feed(frame), isTrue);
      expect(detector!.feed(frame), isFalse);
      expect(detector!.feed(frame), isFalse);
      expect(detector!.dropped, 2);
      await _next(results!);
      expect(detector!.feed(frame), isTrue, reason: 'the worker is free again');
      await _next(results!);
    });

    for (final entry
        in (reference['frames'] as List).cast<Map<String, dynamic>>()) {
      test('frame ${entry['index']} matches the Python boxes', () async {
        detector!.feed(frameOf(entry['nv21'] as String));
        final got = await _next(results!);
        expect([got.frameW, got.frameH], [frameW, frameH]);
        expect(
          got.totalUs,
          greaterThan(0),
          reason: 'the stages have to be timed',
        );
        _match(
          got.detections,
          (entry['detections'] as List).cast<List<dynamic>>(),
        );
      });
    }
  }, skip: !runnable);
}

Future<LiveFrame> _next(StreamQueue<LiveFrame> results) => results.next.timeout(
  const Duration(seconds: 30),
  onTimeout: () => throw StateError('the worker isolate never answered'),
);

/// Same tolerances as the host test: re-encoding through 4:2:0 is lossy and the drift only
/// shows on weak boxes (strong ones agree to 1px / 0.01).
void _match(List<Detection> got, List<List<dynamic>> want) {
  String describe(List<Detection> rows) => [
    for (final d in rows)
      '[${d.cls}, ${d.cx.round()}, ${d.cy.round()}, ${d.w.round()}, ${d.h.round()}, '
          '${d.conf.toStringAsFixed(4)}]',
  ].join('\n  ');
  expect(
    got.length,
    want.length,
    reason:
        'box count differs.\n got:\n  ${describe(got)}\n want:\n  '
        '${describe(want.map(Detection.fromList).toList())}',
  );
  for (var i = 0; i < want.length; i++) {
    final w = want[i], g = got[i];
    expect(g.cls, w[0], reason: 'box #$i class');
    expect(g.cx, closeTo(w[1], 5.0), reason: 'box #$i cx');
    expect(g.cy, closeTo(w[2], 5.0), reason: 'box #$i cy');
    expect(g.w, closeTo(w[3], 5.0), reason: 'box #$i w');
    expect(g.h, closeTo(w[4], 5.0), reason: 'box #$i h');
    expect(g.conf, closeTo(w[5], 0.10), reason: 'box #$i conf');
  }
}

Uint8List _gunzip(Uint8List gzipped) =>
    Uint8List.fromList(gzip.decode(gzipped));
