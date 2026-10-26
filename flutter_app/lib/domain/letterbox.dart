/// The preprocessing the Python side does with `LetterBox(new_shape=(640, 640), auto=True,
/// stride=32)` plus `[..., ::-1].transpose(2, 0, 1) / 255`, rebuilt for the NV21 buffer the
/// Android camera hands us.
///
/// `test/live_preprocess_test.dart` compares every geometry number below against a table
/// dumped from ultralytics itself (`tools/dump_live_reference.py`), because feeding the graph
/// a differently shaped blob moves detections by far more than any numeric error - the exact
/// failure mode documented in tools/export_onnx.py.
library;

import 'dart:typed_data';
import 'dart:math' as math;

const int modelImgsz = 640;
const int modelStride = 32;

/// ultralytics rounds with Python's banker's rounding; Dart rounds half away from zero. The
/// two disagree exactly on the .5 that splits the letterbox padding, so mirror Python.
int pyRound(double v) {
  final below = v.floor();
  final above = v.ceil();
  final down = v - below;
  final up = above - v;
  if (down > up) return above;
  if (down < up) return below;
  return below.isEven ? below : above;
}

/// A resized/padded model input and the mapping back to the upright camera frame.
class Letterbox {
  const Letterbox({
    required this.frameW,
    required this.frameH,
    required this.blobW,
    required this.blobH,
    required this.scale,
    required this.unpadW,
    required this.unpadH,
    required this.padLeft,
    required this.padTop,
  });

  /// Upright frame size (after [Nv21Frame.rotation] has been applied).
  final int frameW;
  final int frameH;
  final int blobW;
  final int blobH;

  /// Pixels-per-frame-pixel, i.e. ultralytics' `r`.
  final double scale;

  /// The un-letterboxed size, before the stride rounding pads it out to [blobW] x [blobH].
  final int unpadW;
  final int unpadH;
  final int padLeft;
  final int padTop;

  factory Letterbox.forFrame(
    int frameW,
    int frameH, {
    int imgsz = modelImgsz,
    int stride = modelStride,
  }) {
    // Every step below is a line-for-line copy of ultralytics' LetterBox.__call__.
    final scale = math.min(imgsz / frameH, imgsz / frameW);
    final unpadW = pyRound(frameW * scale);
    final unpadH = pyRound(frameH * scale);
    // center=True splits the leftover stride padding in two, and Python's `/` keeps it a
    // float, so the halves below are rounded from a .5 rather than truncated.
    final dw = ((imgsz - unpadW) % stride) / 2.0;
    final dh = ((imgsz - unpadH) % stride) / 2.0;
    final left = pyRound(dw - 0.1);
    final top = pyRound(dh - 0.1);
    final right = pyRound(dw + 0.1);
    final bottom = pyRound(dh + 0.1);
    return Letterbox(
      frameW: frameW,
      frameH: frameH,
      blobW: unpadW + left + right,
      blobH: unpadH + top + bottom,
      scale: scale,
      unpadW: unpadW,
      unpadH: unpadH,
      padLeft: left,
      padTop: top,
    );
  }

  /// `scale_boxes` derives its own gain/pad from the two shapes instead of trusting the
  /// letterbox, so reproduce that too rather than reusing [scale].
  ({double gain, double padX, double padY}) inversePad() {
    final gain = math.min(blobH / frameH, blobW / frameW);
    return (
      gain: gain,
      padX: pyRound((blobW - frameW * gain) / 2 - 0.1).toDouble(),
      padY: pyRound((blobH - frameH * gain) / 2 - 0.1).toDouble(),
    );
  }
}

/// One streamed camera frame.
class Nv21Frame {
  const Nv21Frame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotation,
  });

  /// Y plane (width*height) then the V,U pairs interleaved (width*height/2), packed with no
  /// row stride - `camera_android_camerax` rebuilds this layout via androidx's
  /// `ImageProxyUtils.planesToNV21`, so strides are already gone.
  final Uint8List bytes;
  final int width;
  final int height;

  /// Degrees to rotate the buffer *clockwise* to get an upright image (0/90/180/270).
  final int rotation;

  bool get _swapped => rotation == 90 || rotation == 270;

  int get uprightW => _swapped ? height : width;
  int get uprightH => _swapped ? width : height;

  Letterbox get letterbox => Letterbox.forFrame(uprightW, uprightH);

  /// Model input: CHW float, 0..1, BT.601 full-range, 114 grey padding.
  Float32List toBlob() {
    final box = letterbox;
    final blob = Float32List(3 * box.blobW * box.blobH);
    final plane = box.blobW * box.blobH;
    const pad = 114.0 / 255.0;
    final chromaStart = width * height;
    final dxToSrc = _DstToSrc(box.unpadW, box.frameW);
    final dyToSrc = _DstToSrc(box.unpadH, box.frameH);

    for (var y = 0; y < box.blobH; y++) {
      final inRows = y >= box.padTop && y < box.padTop + box.unpadH;
      final uy = dyToSrc(y - box.padTop);
      for (var x = 0; x < box.blobW; x++) {
        final i = y * box.blobW + x;
        if (!inRows || !(x >= box.padLeft && x < box.padLeft + box.unpadW)) {
          blob[i] = pad;
          blob[i + plane] = pad;
          blob[i + 2 * plane] = pad;
          continue;
        }
        final rgb = _sampleRgb(dxToSrc(x - box.padLeft), uy, chromaStart);
        blob[i + 2 * plane] =
            rgb.$3 / 255.0; // CHW: R, G, B - Python flips BGR first
        blob[i + plane] = rgb.$2 / 255.0;
        blob[i] = rgb.$1 / 255.0;
      }
    }
    return blob;
  }

  (double, double, double) _sampleRgb(double ux, double uy, int chromaStart) {
    // Where the upright pixel came from in the raw buffer.
    double rx, ry;
    switch (rotation) {
      case 90:
        rx = uy;
        ry = height - 1 - ux;
      case 180:
        rx = width - 1 - ux;
        ry = height - 1 - uy;
      case 270:
        rx = width - 1 - uy;
        ry = ux;
      default:
        rx = ux;
        ry = uy;
    }

    // Luma: bilinear with edge clamping, like cv2's INTER_LINEAR.
    final x0 = rx.clamp(0.0, width - 1.0);
    final y0 = ry.clamp(0.0, height - 1.0);
    final ix = x0.floor(), iy = y0.floor();
    final ix1 = math.min(ix + 1, width - 1), iy1 = math.min(iy + 1, height - 1);
    final fx = x0 - ix, fy = y0 - iy;
    double luma(int px, int py) => bytes[py * width + px].toDouble();
    final yValue =
        (luma(ix, iy) * (1 - fx) + luma(ix1, iy) * fx) * (1 - fy) +
        (luma(ix, iy1) * (1 - fx) + luma(ix1, iy1) * fx) * fy;

    // Chroma: one pair per 2x2 block, nearest sample (what a 4:2:0 read can resolve anyway).
    final cx = (rx / 2).floor().clamp(0, width ~/ 2 - 1);
    final cy = (ry / 2).floor().clamp(0, height ~/ 2 - 1);
    final vu = chromaStart + cy * width + cx * 2;
    final v = bytes[vu] - 128;
    final u = bytes[vu + 1] - 128;

    // BT.601 full range, the convention Android camera buffers use.
    return (
      (yValue + 1.402 * v).clamp(0.0, 255.0),
      (yValue - 0.344136 * u - 0.714136 * v).clamp(0.0, 255.0),
      (yValue + 1.772 * u).clamp(0.0, 255.0),
    );
  }
}

/// cv2's INTER_LINEAR mapping, `(dst + 0.5) * src/dst - 0.5`, so a blob pixel reads the same
/// source position the Python reference's `cv2.resize` put it at.
class _DstToSrc {
  _DstToSrc(this.dstSize, this.srcSize);

  final int dstSize;
  final int srcSize;

  double call(int dst) =>
      ((dst + 0.5) * srcSize / dstSize - 0.5).clamp(0.0, srcSize - 1.0);
}
