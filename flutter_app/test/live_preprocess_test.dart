import 'dart:typed_data';

import 'package:basketball_highlights/domain/letterbox.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of the camera->blob step that a fixture cannot cover: which way the frame is
/// pointing, and that the padding is the grey the graph was trained on.
void main() {
  group('pythonRound', () {
    test('matches banker\'s rounding on the half', () {
      // Dart's .round() would give 1 and 3 here, and the difference lands on the padding split.
      expect(pyRound(0.5), 0);
      expect(pyRound(1.5), 2);
      expect(pyRound(2.5), 2);
      expect(pyRound(3.5), 4);
      expect(pyRound(-0.5), 0);
      expect(pyRound(11.9), 12);
      expect(pyRound(3.4), 3);
    });
  });

  group('nv21 rotation', () {
    // The raw buffer always has its bright half at raw x < width/2, so the side it lands on in
    // the blob says which way the clockwise-to-upright mapping went.
    for (final scenario in const [
      (0, 'left'),
      (90, 'top'),
      (180, 'right'),
      (270, 'bottom'),
    ]) {
      final rotation = scenario.$1;
      test(
        'a frame rotated $rotation puts the bright half on the ${scenario.$2} side',
        () {
          final frame = _splitFrame(64, 64, rotation);
          final blob = frame.toBlob();
          expect(_brightSide(blob, 640, 640), scenario.$2);
        },
      );
    }

    test('a quarter turn swaps the upright dimensions', () {
      final bytes = Uint8List(96 * 64 * 3 ~/ 2);
      for (final turn in const [
        (0, 96, 64),
        (90, 64, 96),
        (180, 96, 64),
        (270, 64, 96),
      ]) {
        final frame = Nv21Frame(
          bytes: bytes,
          width: 96,
          height: 64,
          rotation: turn.$1,
        );
        expect(
          [frame.uprightW, frame.uprightH],
          [turn.$2, turn.$3],
          reason: 'rotation ${turn.$1}',
        );
      }
    });
  });

  group('letterbox padding', () {
    test('the pad rows and columns are exactly 114/255', () {
      // 1280x720 -> 640x384 with 12px of pad above and below, the shape video_test_5 uses.
      final frame = _splitFrame(1280, 720, 0);
      final box = frame.letterbox;
      expect([box.blobW, box.blobH, box.padTop], [640, 384, 12]);
      final blob = frame.toBlob();
      final plane = box.blobW * box.blobH;
      // The blob is float32, so compare against what the graph actually sees, not the double.
      final pad = (Float32List(1)..[0] = 114 / 255)[0];
      double at(int c, int y, int x) => blob[c * plane + y * box.blobW + x];
      expect(at(0, 0, 0), pad); // top pad, red
      expect(at(1, 5, 300), pad); // top pad, green
      expect(at(2, 383, 639), pad); // bottom pad, blue
      // Inside the picture the halves are the bright/dark test pattern, not grey.
      expect(at(0, 192, 10), greaterThan(0.9));
      expect(at(0, 192, 630), lessThan(0.2));
    });

    test('a uniform grey frame stays uniform through the resize', () {
      final bytes = Uint8List(16 * 16 * 3 ~/ 2)..fillRange(0, 16 * 16, 114);
      // Neutral chroma, otherwise the tiny buffer's zeroed V/U planes turn the grey pink.
      bytes.fillRange(16 * 16, bytes.length, 128);
      final frame = Nv21Frame(bytes: bytes, width: 16, height: 16, rotation: 0);
      final blob = frame.toBlob();
      final distinct = blob.toSet();
      expect(
        distinct.length,
        1,
        reason: 'Y=114, U=V=128 is neutral grey, and 114 is also the pad',
      );
      expect(distinct.first, closeTo(114 / 255, 1e-6));
    });
  });
}

/// NV21 with `width` x `height` in the *raw* buffer orientation: the bright band is at raw
/// x < width/2, chroma neutral. Rotation is applied when reading, so the side the bright band
/// lands on is what the upright mapping has to get right.
Nv21Frame _splitFrame(int width, int height, int rotation) {
  final bytes = Uint8List(width * height * 3 ~/ 2);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      bytes[y * width + x] = x < width / 2 ? 255 : 16;
    }
  }
  final chroma = width * height;
  for (var i = chroma; i < bytes.length; i++) {
    bytes[i] = 128;
  }
  return Nv21Frame(
    bytes: bytes,
    width: width,
    height: height,
    rotation: rotation,
  );
}

/// Which side of a uniform-scale blob the bright half landed on.
String _brightSide(Float32List blob, int w, int h) {
  double mean(int x0, int x1, int y0, int y1) {
    var sum = 0.0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        sum += blob[y * w + x];
      }
    }
    return sum / ((x1 - x0) * (y1 - y0));
  }

  final sides = {
    'left': mean(0, w ~/ 4, h ~/ 4, h * 3 ~/ 4),
    'right': mean(w * 3 ~/ 4, w, h ~/ 4, h * 3 ~/ 4),
    'top': mean(w ~/ 4, w * 3 ~/ 4, 0, h ~/ 4),
    'bottom': mean(w ~/ 4, w * 3 ~/ 4, h * 3 ~/ 4, h),
  };
  return sides.entries.reduce((a, b) => a.value > b.value ? a : b).key;
}
