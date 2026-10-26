import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basketball_highlights/domain/letterbox.dart';
import 'package:basketball_highlights/domain/shot_logic.dart';
import 'package:basketball_highlights/domain/yolo_post.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// Everything the live camera path has to get right about a frame, checked against numbers
/// Python produced for the same pixels (`python tools/dump_live_reference.py --frames 6`).
///
/// The first two groups run anywhere. The third needs ONNX Runtime on the host:
///   cp .venv/lib/python3.*/site-packages/onnxruntime/capi/libonnxruntime.*.dylib \
///      flutter_app/libonnxruntime.1.15.1.dylib
void main() {
  final referenceFile = File('../fixtures/live_reference.json');
  final dylib = File('libonnxruntime.1.15.1.dylib');
  final model = File('assets/model/best.onnx');
  setUpAll(() {
    expect(
      referenceFile.existsSync(),
      isTrue,
      reason: 'run python tools/dump_live_reference.py first',
    );
  });
  final reference =
      jsonDecode(referenceFile.readAsStringSync()) as Map<String, dynamic>;

  group('letterbox geometry', () {
    for (final row
        in (reference['geometry'] as List).cast<Map<String, dynamic>>()) {
      final frameW = row['frame_w'] as int, frameH = row['frame_h'] as int;
      test('${frameW}x$frameH', () {
        final box = Letterbox.forFrame(frameW, frameH);
        expect(
          [box.blobW, box.blobH],
          [row['blob_w'], row['blob_h']],
          reason: 'blob size',
        );
        expect(
          [box.unpadW, box.unpadH],
          [row['unpad_w'], row['unpad_h']],
          reason: 'resized size',
        );
        expect(
          [box.padLeft, box.padTop],
          [row['left'], row['top']],
          reason: 'pad offsets',
        );
        expect(box.scale, closeTo(row['ratio'] as double, 1e-12));
      });
    }
  });

  group('decode + NMS against ultralytics', () {
    for (final entry
        in (reference['frames'] as List).cast<Map<String, dynamic>>()) {
      test(
        'frame ${entry['index']} (${(entry['detections'] as List).length} boxes)',
        () {
          final box = Letterbox.forFrame(
            reference['width'] as int,
            reference['height'] as int,
          );
          final got = yoloDetections(
            rows: _rowsFromFile(
              File('../fixtures/${entry['tensor']}'),
              (4 + classCount) * box.anchorsOf(),
            ),
            box: box,
            conf: (reference['conf_floor'] as num).toDouble(),
            iou: (reference['iou'] as num).toDouble(),
          );
          _expectRows(got, (entry['detections'] as List).cast<List<dynamic>>());
        },
      );
    }
  });

  group('camera frame to detection, through the real model', () {
    // The plugin loads `libonnxruntime.1.15.1.dylib` by name on macOS; without it the host
    // cannot run the graph at all, so these cases report as skipped rather than failed.
    final runnable = dylib.existsSync() && model.existsSync();
    final entries = (reference['frames'] as List).cast<Map<String, dynamic>>();

    test(
      'the host runtime and the model are both present',
      () {},
      skip: !runnable,
    );

    for (final entry in entries) {
      test('frame ${entry['index']}', () {
        final nv21 = _gunzip(
          File('../fixtures/${entry['nv21']}').readAsBytesSync(),
        );
        final frame = Nv21Frame(
          bytes: nv21,
          width: reference['width'] as int,
          height: reference['height'] as int,
          rotation: 0,
        );
        _expectRows(
          _host?.run(frame) ??
              (_host = _Host(model.readAsBytesSync())).run(frame),
          (entry['detections'] as List).cast<List<dynamic>>(),
          // Re-encoding 720p through 4:2:0 chroma is lossy, and the worst drift that costs
          // is on the weak boxes: measured across these frames, a strong detection agrees
          // to 1px / 0.01 confidence and the loosest one (a 0.31 ball box overlapping the
          // hoop) moves 5px / 0.09. The decode itself is exact - the group above proves it
          // to 1px / 0.001 on the same tensors.
          positionTolerance: 5.0,
          confTolerance: 0.10,
        );
      }, skip: !runnable);
    }
  });
}

_Host? _host;

extension on Letterbox {
  /// 80x48 + 40x24 + 20x12 for a 640x384 blob.
  int anchorsOf() =>
      (blobW / 8).floor() * (blobH / 8).floor() +
      (blobW / 16).floor() * (blobH / 16).floor() +
      (blobW / 32).floor() * (blobH / 32).floor();
}

/// Rows in the same `[cls, cx, cy, w, h, conf]` shape the fixture stores, ordered by score.
void _expectRows(
  List<Detection> got,
  List<List<dynamic>> want, {
  double positionTolerance = 1.0,
  double confTolerance = 0.001,
}) {
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
    final w = want[i];
    final g = got[i];
    expect(g.cls, w[0], reason: 'box #$i class');
    expect(g.cx, closeTo(w[1], positionTolerance), reason: 'box #$i cx');
    expect(g.cy, closeTo(w[2], positionTolerance), reason: 'box #$i cy');
    expect(g.w, closeTo(w[3], positionTolerance), reason: 'box #$i w');
    expect(g.h, closeTo(w[4], positionTolerance), reason: 'box #$i h');
    expect(g.conf, closeTo(w[5], confTolerance), reason: 'box #$i conf');
  }
}

List<List<double>> _rowsFromFile(File file, int floats) {
  final bytes = file.readAsBytesSync();
  expect(
    bytes.length,
    floats * 4,
    reason: '${file.path} is not the tensor this blob expects',
  );
  final data = Float32List.view(bytes.buffer, bytes.offsetInBytes, floats);
  final anchors = floats ~/ (4 + classCount);
  return [
    for (var c = 0; c < 4 + classCount; c++)
      data.sublist(c * anchors, (c + 1) * anchors),
  ];
}

Uint8List _gunzip(Uint8List gzipped) =>
    Uint8List.fromList(gzip.decode(gzipped));

/// The host-side stand-in for the worker isolate: preprocess, graph, decode - the same calls
/// `lib/data/live_detector.dart` makes, so this test exercises the real API surface.
class _Host {
  _Host(Uint8List modelBytes) {
    OrtEnv.instance.init();
    _options = OrtSessionOptions()..setIntraOpNumThreads(4);
    _session = OrtSession.fromBuffer(modelBytes, _options);
    _runOptions = OrtRunOptions();
  }

  late final OrtSessionOptions _options;
  late final OrtSession _session;
  late final OrtRunOptions _runOptions;

  List<Detection> run(Nv21Frame frame) {
    final box = frame.letterbox;
    final blob = frame.toBlob();
    final tensor = OrtValueTensor.createTensorWithDataList(blob, [
      1,
      3,
      box.blobH,
      box.blobW,
    ]);
    final outputs = _session.run(_runOptions, {
      _session.inputNames.first: tensor,
    });
    final rows = [
      for (final row in ((outputs[0]!.value as List)[0] as List))
        Float64List((row as List).length)
          ..setAll(0, row.map((v) => (v as num).toDouble())),
    ];
    final detections = yoloDetections(rows: rows, box: box);
    for (final value in outputs) {
      value?.release();
    }
    tensor.release();
    return detections;
  }
}
