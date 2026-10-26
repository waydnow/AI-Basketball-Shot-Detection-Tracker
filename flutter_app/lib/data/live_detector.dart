/// Runs the exported YOLO graph on camera frames, off the UI isolate.
///
/// ONNX Runtime's own `runAsync` only moves the graph off the calling isolate, and at
/// 640x384 the pixel work around it costs as much as the preview can spare, so the blob, the
/// graph and the decode all live in one worker isolate and the UI thread only ever receives
/// finished boxes.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../domain/letterbox.dart';
import '../domain/shot_logic.dart';
import '../domain/yolo_post.dart';

/// What one camera frame produced, split by stage so the screen can say whether overlaying
/// the trajectory is worth the latency.
class LiveFrame {
  const LiveFrame({
    required this.detections,
    required this.frameW,
    required this.frameH,
    required this.prepUs,
    required this.inferUs,
    required this.postUs,
  });

  /// Boxes in upright-frame pixels.
  final List<Detection> detections;
  final int frameW;
  final int frameH;

  /// NV21 -> blob, the graph, blob -> boxes.
  final int prepUs;
  final int inferUs;
  final int postUs;

  int get totalUs => prepUs + inferUs + postUs;

  List<Detection> get balls =>
      detections.where((d) => d.cls == ballClass).toList(growable: false);
  List<Detection> get hoops =>
      detections.where((d) => d.cls == hoopClass).toList(growable: false);
}

/// A live detector: [feed] frames, read [frames]. [feed] drops whatever it cannot start on -
/// a stale box is worse than a missing one.
class LiveDetector {
  static const modelAsset = 'assets/model/best.onnx';

  LiveDetector._(this._channel, this._toWorker, this._replyPort);

  final _Channel _channel;
  final SendPort _toWorker;
  final RawReceivePort _replyPort;

  Stream<LiveFrame> get frames => _channel.frames.stream;

  /// Frames discarded because the worker was still busy; read this before blaming the model.
  int get dropped => _channel.dropped;

  bool feed(Nv21Frame frame) {
    if (_channel.busy) {
      _channel.dropped++;
      return false;
    }
    _channel.busy = true;
    _toWorker.send({
      'kind': 'frame',
      'bytes': frame.bytes,
      'width': frame.width,
      'height': frame.height,
      'rotation': frame.rotation,
    });
    return true;
  }

  Future<void> dispose() async {
    _toWorker.send({'kind': 'exit'});
    await _channel.frames.close();
    _replyPort.close();
  }

  /// Loads the graph in a worker isolate. Throws when the asset or the runtime library is
  /// missing, which the live screen turns into a banner instead of a crash.
  static Future<LiveDetector> load({String asset = modelAsset}) async {
    final Uint8List model;
    try {
      model = (await rootBundle.load(asset)).buffer.asUint8List();
    } catch (e) {
      throw StateError(
        '$asset 未打包：先运行 tools/export_onnx.py 生成 best.onnx，'
        '再复制到 flutter_app/$asset（$e）',
      );
    }

    final channel = _Channel();
    final replyPort = RawReceivePort(channel.onMessage);
    await Isolate.spawn(_worker, {
      'reply': replyPort.sendPort,
      'model': model,
    }, debugName: 'yolo-inference');
    final toWorker = await channel.handshake.future;
    await channel.ready.future;
    return LiveDetector._(channel, toWorker, replyPort);
  }
}

/// Everything the reply port touches, kept separate so the port callback does not have to
/// reach into a detector that is still being constructed.
class _Channel {
  final frames = StreamController<LiveFrame>();
  final handshake = Completer<SendPort>();
  final ready = Completer<void>();

  bool busy = false;
  int dropped = 0;

  void onMessage(dynamic message) {
    if (message is! Map) return;
    switch (message['kind']) {
      case 'handshake':
        handshake.complete(message['port'] as SendPort);
      case 'ready':
        ready.complete();
      case 'error':
        busy = false;
        final error = StateError('端侧推理失败：${message['message']}');
        if (!handshake.isCompleted) handshake.completeError(error);
        if (!ready.isCompleted) ready.completeError(error);
        if (!frames.isClosed) frames.addError(error);
      case 'frame':
        busy = false;
        if (!frames.isClosed) frames.add(frameOf(message));
    }
  }
}

LiveFrame frameOf(Map message) => LiveFrame(
  detections: [
    for (final row in (message['boxes'] as List))
      Detection(
        (row[0] as num).toInt(),
        (row[1] as num).toDouble(),
        (row[2] as num).toDouble(),
        (row[3] as num).toDouble(),
        (row[4] as num).toDouble(),
        (row[5] as num).toDouble(),
      ),
  ],
  frameW: message['frameW'] as int,
  frameH: message['frameH'] as int,
  prepUs: message['prepUs'] as int,
  inferUs: message['inferUs'] as int,
  postUs: message['postUs'] as int,
);

Future<void> _worker(Map<String, Object> init) async {
  final reply = init['reply'] as SendPort;
  final receive = ReceivePort();
  reply.send({'kind': 'handshake', 'port': receive.sendPort});

  OrtSession? session;
  OrtSessionOptions? options;
  OrtRunOptions? runOptions;
  try {
    OrtEnv.instance.init();
    options = OrtSessionOptions()
      ..setIntraOpNumThreads(4)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    session = OrtSession.fromBuffer(init['model'] as Uint8List, options);
    runOptions = OrtRunOptions();
    final inputName = session.inputNames.first;
    reply.send({'kind': 'ready'});

    await for (final message in receive) {
      if (message is! Map) continue;
      if (message['kind'] == 'exit') break;
      try {
        reply.send(_process(session, runOptions, inputName, message));
      } catch (e) {
        reply.send({'kind': 'error', 'message': '$e'});
      }
    }
  } catch (e) {
    reply.send({'kind': 'error', 'message': '$e'});
  } finally {
    runOptions?.release();
    session?.release();
    options?.release();
    receive.close();
  }
}

Map<String, Object> _process(
  OrtSession session,
  OrtRunOptions runOptions,
  String inputName,
  Map message,
) {
  final frame = Nv21Frame(
    bytes: message['bytes'] as Uint8List,
    width: message['width'] as int,
    height: message['height'] as int,
    rotation: message['rotation'] as int,
  );
  final watch = Stopwatch()..start();
  final box = frame.letterbox;
  final blob = frame.toBlob();
  final prepUs = watch.elapsedMicroseconds;

  final tensor = OrtValueTensor.createTensorWithDataList(blob, [
    1,
    3,
    box.blobH,
    box.blobW,
  ]);
  final outputs = session.run(runOptions, {inputName: tensor});
  final inferUs = watch.elapsedMicroseconds - prepUs;

  final detections = yoloDetections(rows: _rowsOf(outputs[0]), box: box);
  for (final value in outputs) {
    value?.release();
  }
  tensor.release();

  return {
    'kind': 'frame',
    'frameW': box.frameW,
    'frameH': box.frameH,
    'prepUs': prepUs,
    'inferUs': inferUs,
    'postUs': watch.elapsedMicroseconds - inferUs - prepUs,
    'boxes': [
      for (final d in detections) [d.cls, d.cx, d.cy, d.w, d.h, d.conf],
    ],
  };
}

/// `output0` comes back as a nested `List` of `[1][4+nc][anchors]`; the row-major doubles
/// below are what [yoloDetections] indexes.
List<List<double>> _rowsOf(OrtValue? output) {
  final batch = (output!.value as List)[0] as List;
  return [
    // `cast` is load-bearing: the rows arrive as `List<dynamic>`, and a `map` over a dynamic
    // element type produces an `Iterable<dynamic>` that `setAll` refuses at runtime.
    for (final row in batch)
      Float64List((row as List).length)
        ..setAll(0, row.cast<num>().map((num v) => v.toDouble())),
  ];
}
