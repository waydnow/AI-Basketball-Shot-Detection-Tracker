/// The post-processing half of the detector, mirroring ultralytics'
/// `non_max_suppression(..., conf=0.05, iou=0.7)` + `scale_boxes` + `clip_boxes` on the
/// raw `output0` tensor.
///
/// `test/live_reference_test.dart` feeds tensors and blobs dumped by
/// `tools/dump_live_reference.py` through this and compares against the boxes Python's own
/// pipeline produced, so a "tidy up" here that changes which boxes survive is caught.
library;

import 'dart:math' as math;

import 'letterbox.dart';
import 'shot_logic.dart';

/// Deliberately low: the shot logic needs weak near-hoop ball detections, and gates them
/// itself against `ball_conf_near_hoop`.
const double confFloor = 0.05;
const double nmsIou = 0.7;
const int maxDet = 300;
const int classCount = 2; // config.yaml: 0 = Basketball, 1 = Basketball Hoop

class _Candidate {
  _Candidate(this.cls, this.conf, this.x1, this.y1, this.x2, this.y2);

  final int cls;
  final double conf;
  double x1, y1, x2, y2;

  double get area => math.max(0, x2 - x1) * math.max(0, y2 - y1);
}

/// Decodes `output0` and returns detections in upright-frame pixels, in the same
/// `[cls, cx, cy, w, h, conf]` shape the Python fixtures store.
///
/// [rows] is the tensor's `4+nc` rows for batch 1 - ONNX Runtime's `OrtValue.value` already
/// hands the output over in that shape, so getting here costs no copying.
List<Detection> yoloDetections({
  required List<List<double>> rows,
  required Letterbox box,
  double conf = confFloor,
  double iou = nmsIou,
}) {
  final anchors = rows[0].length;
  final candidates = <_Candidate>[];

  for (var a = 0; a < anchors; a++) {
    var best = rows[4][a];
    var bestCls = 0;
    for (var c = 1; c < classCount; c++) {
      final s = rows[4 + c][a];
      if (s > best) {
        best = s;
        bestCls = c;
      }
    }
    // ultralytics keeps a box on `score > conf`, not `>=`.
    if (best <= conf) continue;

    // The graph emits cx, cy, w, h; NMS works in xyxy.
    final cx = rows[0][a], cy = rows[1][a];
    final w = rows[2][a], h = rows[3][a];
    candidates.add(
      _Candidate(bestCls, best, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2),
    );
  }

  final kept = <_Candidate>[];
  for (var c = 0; c < classCount; c++) {
    final sameClass = candidates.where((x) => x.cls == c).toList()
      ..sort((a, b) => b.conf.compareTo(a.conf));
    for (final cand in sameClass) {
      if (kept.any((k) => k.cls == c && _iou(k, cand) > iou)) continue;
      kept.add(cand);
    }
  }
  // NMS returns detections in score order; ultralytics then takes the first max_det.
  kept.sort((a, b) => b.conf.compareTo(a.conf));

  final inverse = box.inversePad();
  return [
    // scale_boxes subtracts the letterbox pad and divides by the gain, clip_boxes clamps to
    // the frame, then everything truncates to whole pixels the way tools/dump_reference.py
    // did - the state machine's geometry is built on integer boxes, and taking the centre of
    // a scaled box before truncating moves it by a pixel on odd widths.
    for (final cand in kept.take(maxDet))
      _toFrameDetection(cand, box, inverse.gain, inverse.padX, inverse.padY),
  ];
}

Detection _toFrameDetection(
  _Candidate cand,
  Letterbox box,
  double gain,
  double padX,
  double padY,
) {
  double x(double blob) => ((blob - padX) / gain)
      .clamp(0.0, box.frameW.toDouble())
      .truncateToDouble();
  double y(double blob) => ((blob - padY) / gain)
      .clamp(0.0, box.frameH.toDouble())
      .truncateToDouble();
  final x1 = x(cand.x1), y1 = y(cand.y1), x2 = x(cand.x2), y2 = y(cand.y2);
  final w = x2 - x1, h = y2 - y1;
  // The confidence is quantised to 4 decimals before the state machine ceils it to 2,
  // exactly as tools/dump_reference.py does. Without the first step, float noise such as
  // 0.30000000000000004 pushes the ceil a whole percent higher and flips a gate.
  final conf = pyRound(cand.conf * 1e4) / 1e4;
  return Detection(
    cand.cls,
    x1 + (w / 2).floorToDouble(),
    y1 + (h / 2).floorToDouble(),
    w,
    h,
    conf,
  );
}

double _iou(_Candidate a, _Candidate b) {
  final inter =
      math.max(0.0, math.min(a.x2, b.x2) - math.max(a.x1, b.x1)) *
      math.max(0.0, math.min(a.y2, b.y2) - math.max(a.y1, b.y1));
  final union = a.area + b.area - inter;
  return union <= 0 ? 0.0 : inter / union;
}
