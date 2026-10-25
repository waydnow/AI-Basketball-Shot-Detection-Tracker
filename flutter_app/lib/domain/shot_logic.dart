/// Port of `utils.py` + `shot_logic.py`. Every threshold and rounding rule is mirrored
/// deliberately: `test/parity_test.dart` asserts this file reproduces the Python goldens
/// byte-for-byte, so a "cleanup" here that changes any verdict is a real regression.
library;

import 'dart:math' as math;

const int ballClass = 0;
const int hoopClass = 1;

/// The hoop box spans rim + net, with the rim at its top edge. Multiples of the box, so
/// they survive a change of camera distance or resolution.
const double rimHalfW = 0.5;
const double netDepth = 1.0;
const double xTolerance = 0.1;

/// A detection that has survived gating: ((x, y), frame, w, h, conf) in the Python original.
class Tracked {
  const Tracked(this.x, this.y, this.frame, this.w, this.h, this.conf);

  final int x;
  final int y;
  final int frame;
  final int w;
  final int h;
  final double conf;
}

class Detection {
  const Detection(this.cls, this.cx, this.cy, this.w, this.h, this.conf);

  /// Raw `[class_id, center_x, center_y, w, h, conf]` rows, as stored in the fixtures.
  factory Detection.fromList(List<dynamic> row) =>
      Detection(row[0] as int, (row[1] as num).toDouble(), (row[2] as num).toDouble(),
          (row[3] as num).toDouble(), (row[4] as num).toDouble(), (row[5] as num).toDouble());

  final int cls;
  final double cx;
  final double cy;
  final double w;
  final double h;
  final double conf;

  Tracked at(int frameIndex) =>
      Tracked(cx.toInt(), cy.toInt(), frameIndex, w.toInt(), h.toInt(), conf);
}

class ShotEvent {
  const ShotEvent({
    required this.frame,
    required this.microseconds,
    required this.isMake,
    required this.upFrame,
    required this.hoop,
  });

  final int frame;
  final int microseconds;
  final bool isMake;
  final int upFrame;

  /// (cx, cy, w, h) of the hoop the verdict was made against.
  final List<int> hoop;

  String get type => isMake ? 'make' : 'miss';
}

/// Rim plane y and opening x-range.
({double rimY, double x1, double x2}) rimGeometry(Tracked hoop) {
  final rimY = hoop.y - 0.5 * hoop.h;
  return (rimY: rimY, x1: hoop.x - rimHalfW * hoop.w, x2: hoop.x + rimHalfW * hoop.w);
}

/// A make is the ball centre passing down *through the cylinder* dropped from the rim
/// opening: it must cross the rim plane inside the opening and stay inside it all the way
/// to the bottom of the net. Returns the verdict plus a reason, so a wrong call can be
/// traced to a bad box rather than argued about from video stills.
(bool, String) score(List<Tracked> ballPos, List<Tracked> hoopPos) {
  final hoop = hoopPos.last;
  final (:rimY, :x1, :x2) = rimGeometry(hoop);
  final netY = rimY + netDepth * hoop.h;
  final tolerance = xTolerance * hoop.w;
  final lo = x1 - tolerance;
  final hi = x2 + tolerance;

  for (var i = ballPos.length - 2; i >= 0; i--) {
    final y1 = ballPos[i].y, y2 = ballPos[i + 1].y;
    if (y1 < rimY && rimY <= y2) {
      // downward crossing of the rim plane
      final t = (rimY - y1) / (y2 - y1);
      final crossX = ballPos[i].x + (ballPos[i + 1].x - ballPos[i].x) * t;
      if (!(x1 < crossX && crossX < x2)) {
        return (false, 'crossed rim y=${rimY.round()} at x=${crossX.round()}, '
            'outside opening [${x1.round()},${x2.round()}]');
      }
      for (var j = i + 1; j < ballPos.length; j++) {
        if (!(lo < ballPos[j].x && ballPos[j].x < hi)) {
          return (false, 'drifted to x=${ballPos[j].x} at y=${ballPos[j].y}, '
              'outside cylinder [${lo.round()},${hi.round()}]');
        }
        if (ballPos[j].y >= netY) break;
      }
      return (true, 'stayed in the cylinder from rim y=${rimY.round()} '
          'to net bottom y=${netY.round()}');
    }
  }
  return (false, 'no downward crossing of rim y=${rimY.round()}');
}

/// Ball below the net - the shot attempt is over.
bool detectDown(List<Tracked> ballPos, List<Tracked> hoopPos) {
  final hoop = hoopPos.last;
  return ballPos.last.y > hoop.y + 0.5 * hoop.h;
}

/// Ball above the rim, near this basket - start of a shot attempt.
bool detectUp(List<Tracked> ballPos, List<Tracked> hoopPos) {
  final hoop = hoopPos.last;
  final ball = ballPos.last;
  final x1 = hoop.x - 1.5 * hoop.w;
  final x2 = hoop.x + 1.5 * hoop.w;
  final y1 = hoop.y - 2 * hoop.h;
  final y2 = hoop.y - 0.5 * hoop.h;
  return x1 < ball.x && ball.x < x2 && y1 < ball.y && ball.y < y2;
}

bool inHoopRegion(int x, int y, List<Tracked> hoopPos) {
  if (hoopPos.isEmpty) return false;
  final hoop = hoopPos.last;
  final x1 = hoop.x - hoop.w;
  final x2 = hoop.x + hoop.w;
  final y1 = hoop.y - hoop.h;
  final y2 = hoop.y + 0.5 * hoop.h;
  return x1 < x && x < x2 && y1 < y && y < y2;
}

/// Removes inaccurate data points. Windows are seconds converted with the video fps, so the
/// filters keep working when frames are skipped during analysis.
///
/// Drops at most one stale point per call, matching the Python `if` (not a `while`).
List<Tracked> cleanBallPos(List<Tracked> ballPos, int frameCount, double fps) {
  final jumpWindow = math.max(1, (0.17 * fps).round());
  final history = math.max(1, (1.0 * fps).round());

  if (ballPos.length > 1) {
    final prev = ballPos[ballPos.length - 2];
    final curr = ballPos[ballPos.length - 1];
    final fDif = curr.frame - prev.frame;
    final dist = math.sqrt(math.pow(curr.x - prev.x, 2) + math.pow(curr.y - prev.y, 2));
    final maxDist = 4 * math.sqrt(math.pow(prev.w, 2) + math.pow(prev.h, 2));

    if (dist > maxDist && fDif < jumpWindow) {
      ballPos.removeLast();
    } else if (curr.w * 1.4 < curr.h || curr.h * 1.4 < curr.w) {
      ballPos.removeLast();
    }
  }

  if (ballPos.isNotEmpty && frameCount - ballPos.first.frame > history) {
    ballPos.removeAt(0);
  }
  return ballPos;
}

List<Tracked> cleanHoopPos(List<Tracked> hoopPos, double fps) {
  final jumpWindow = math.max(1, (0.17 * fps).round());
  final history = math.max(1, (0.83 * fps).round());

  if (hoopPos.length > 1) {
    final prev = hoopPos[hoopPos.length - 2];
    final curr = hoopPos[hoopPos.length - 1];
    final fDif = curr.frame - prev.frame;
    final dist = math.sqrt(math.pow(curr.x - prev.x, 2) + math.pow(curr.y - prev.y, 2));
    final maxDist = 0.5 * math.sqrt(math.pow(prev.w, 2) + math.pow(prev.h, 2));

    if (dist > maxDist && fDif < jumpWindow) {
      hoopPos.removeLast();
    }
    if (curr.w * 1.3 < curr.h || curr.h * 1.3 < curr.w) {
      hoopPos.removeLast();
    }
  }

  while (hoopPos.length > history) {
    hoopPos.removeAt(0);
  }
  return hoopPos;
}

/// Feed one frame of detections at a time with [addFrame]; it returns shot events.
///
/// Hoop points are appended before ball points so that a frame's own hoop detection is
/// visible to the ball's near-hoop confidence test, making the result independent of the
/// order the detector happens to emit boxes in.
class ShotTracker {
  ShotTracker({
    required this.fps,
    this.ballConf = 0.3,
    this.ballConfNearHoop = 0.15,
    this.hoopConf = 0.5,
    this.attemptCooldownS = 1.5,
    this.explain = false,
  }) : cooldownFrames = math.max(1, (attemptCooldownS * fps).round());

  final double fps;
  final double ballConf;
  final double ballConfNearHoop;
  final double hoopConf;
  final double attemptCooldownS;
  final bool explain;
  final int cooldownFrames;

  final List<Tracked> ballPos = [];
  final List<Tracked> hoopPos = [];

  int makes = 0;
  int attempts = 0;
  final List<ShotEvent> events = [];
  final List<String> reasons = [];

  bool _up = false;
  bool _down = false;
  int _upFrame = 0;
  int _downFrame = 0;
  int? _lastAttemptFrame;

  List<ShotEvent> addFrame(int frameIndex, Iterable<Detection> detections) {
    final balls = <Tracked>[];
    final hoops = <Tracked>[];
    for (final d in detections) {
      // Python's math.ceil, not Dart's RoundingOptions: always round the confidence up.
      final conf = (d.conf * 100).ceil() / 100;
      final point = Tracked(d.cx.toInt(), d.cy.toInt(), frameIndex,
          d.w.toInt(), d.h.toInt(), conf);
      (d.cls == ballClass ? balls : hoops).add(point);
    }

    for (final hoop in hoops) {
      if (hoop.conf > hoopConf) hoopPos.add(hoop);
    }
    for (final ball in balls) {
      final nearHoop = inHoopRegion(ball.x, ball.y, hoopPos) && ball.conf > ballConfNearHoop;
      if (ball.conf > ballConf || nearHoop) ballPos.add(ball);
    }

    cleanBallPos(ballPos, frameIndex, fps);
    if (hoopPos.length > 1) cleanHoopPos(hoopPos, fps);

    return _detectShots(frameIndex);
  }

  List<ShotEvent> _detectShots(int frameIndex) {
    if (hoopPos.isEmpty || ballPos.isEmpty) return const [];

    if (!_up && _cooldownOver(frameIndex)) {
      _up = detectUp(ballPos, hoopPos);
      if (_up) _upFrame = ballPos.last.frame;
    }

    if (_up && !_down) {
      _down = detectDown(ballPos, hoopPos);
      if (_down) _downFrame = ballPos.last.frame;
    }

    if (_up && _down && _upFrame < _downFrame) {
      _up = false;
      _down = false;
      _lastAttemptFrame = frameIndex;
      attempts += 1;

      final (made, why) = score(ballPos, hoopPos);
      if (made) makes += 1;
      if (explain) reasons.add(why);
      final hoop = hoopPos.last;
      final event = ShotEvent(
        frame: _downFrame,
        microseconds: (_downFrame * 1000000 / fps).toInt(),
        isMake: made,
        upFrame: _upFrame,
        hoop: [hoop.x, hoop.y, hoop.w, hoop.h],
      );
      events.add(event);
      return [event];
    }

    return const [];
  }

  bool _cooldownOver(int frameIndex) =>
      _lastAttemptFrame == null || frameIndex - _lastAttemptFrame! >= cooldownFrames;
}
