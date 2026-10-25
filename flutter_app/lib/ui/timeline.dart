import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';

/// The visible slice of the time axis. The strip is never wider than the screen, so zooming
/// moves a window instead of laying out a 3000px widget, and a horizontal drag has exactly
/// one meaning at any moment - pan the window, or move the pin it started on.
class TimelineView {
  const TimelineView({
    required this.durationUs,
    required this.viewStartUs,
    required this.viewUs,
    required this.width,
  });

  final int durationUs;
  final int viewStartUs;

  /// Span of the window in microseconds; `viewUs >= 1 second` always.
  final int viewUs;
  final double width;

  static const minViewUs = 1000000;
  static const pinHitPx = 16;
  static const handleHitPx = 14;

  double xOfUs(int us) => (us - viewStartUs) / viewUs * width;

  int usOfX(double x) => (viewStartUs + (x / width) * viewUs).round().clamp(0, durationUs);

  TimelineView zoom(double factor, int focusUs) {
    final span = math.max(viewUs, minViewUs);
    final next = math.min(
        math.max((span * factor).round(), minViewUs), math.max(minViewUs, durationUs));
    final anchor = (focusUs - viewStartUs) / span; // keep the focus point under the finger
    return _shifted(next, focusUs - (anchor * next).round());
  }

  /// Centres the window on `us` and clamps so the ruler never scrolls past the clip.
  TimelineView focused(int us, {double fraction = 0.5}) =>
      _shifted(viewUs, us - (viewUs * fraction).round());

  /// Panning: the same span, starting at `newStartUs`, clamped to the clip.
  TimelineView panned(int newStartUs) => _shifted(viewUs, newStartUs);

  /// Show the whole clip, however long it is.
  TimelineView fitted() => _shifted(math.max(minViewUs, durationUs), 0);

  /// Follows playback, but only when the playhead has actually left the window - a timeline
  /// that recentres on every frame makes the pins jitter under the finger.
  TimelineView following(int us) =>
      (us >= viewStartUs && us <= viewStartUs + viewUs) ? this : focused(us);

  TimelineView _shifted(int nextViewUs, int nextStart) {
    final maxStart = math.max(0, durationUs - nextViewUs);
    return TimelineView(
      durationUs: durationUs,
      viewStartUs: nextStart.clamp(0, maxStart),
      viewUs: nextViewUs,
      width: width,
    );
  }
}

/// What a drag that started at `x` is allowed to change.
enum DragAction { none, pan, movePin, windowBefore, windowAfter }

/// What a pin drag means. The first movement past the dead zone decides it, once and for
/// the whole gesture: mostly vertical is "pull the pin out of the film to delete it", mostly
/// horizontal is "change its time". Latching is what lets the second one move the pin while
/// the first one leaves it exactly where it was.
enum PinDrag { undecided, move, delete }

PinDrag pinDragMode(Offset moved) {
  if (moved.distance < 8) return PinDrag.undecided;
  return moved.dy.abs() > moved.dx.abs() ? PinDrag.delete : PinDrag.move;
}

/// Where the finger is, as reported during a drag. The strip owns the pixels, so it decides
/// whether the finger has left the film; the parent only accumulates `delta` to feed
/// [pinDragMode] and to translate `us` into an edit.
class DragUpdate {
  const DragUpdate({required this.us, required this.delta, required this.offStrip});

  final int us;

  /// This event's movement, in pixels and on both axes.
  final Offset delta;

  /// The finger is outside the strip: a delete drag is armed.
  final bool offStrip;
}

/// Resolution order is the one the user sees: the selected pin's window handles win first -
/// they are only drawn when it is selected and sit a whole window away from its head, so
/// they cannot be found by the pin test below. Then a pin wins over the strip, and only an
/// empty stretch pans.
DragAction dragActionAt({
  required TimelineView view,
  required List<Shot> shots,
  required int? selectedId,
  required double x,
}) {
  Shot? selected;
  if (selectedId != null) {
    for (final s in shots) {
      if (s.id == selectedId) selected = s;
    }
  }
  if (selected != null) {
    if ((view.xOfUs(selected.tUs - selected.windowBeforeUs) - x).abs() <=
        TimelineView.handleHitPx) {
      return DragAction.windowBefore;
    }
    if ((view.xOfUs(selected.tUs + selected.windowAfterUs) - x).abs() <=
        TimelineView.handleHitPx) {
      return DragAction.windowAfter;
    }
  }
  return nearPin(shots, view, view.usOfX(x)) != null ? DragAction.movePin : DragAction.pan;
}

Shot? nearPin(List<Shot> shots, TimelineView view, int us) {
  Shot? best;
  var bestPx = double.infinity;
  for (final s in shots) {
    final px = (view.xOfUs(s.tUs) - view.xOfUs(us)).abs();
    if (px <= TimelineView.pinHitPx && px < bestPx) {
      best = s;
      bestPx = px;
    }
  }
  return best;
}

class TimelinePainter extends CustomPainter {
  TimelinePainter({
    required this.view,
    required this.shots,
    required this.positionUs,
    this.selectedId,
    this.deleteArmedId,
  });

  final TimelineView view;
  final List<Shot> shots;
  final int positionUs;
  final int? selectedId;

  /// A pin being dragged out of the film: drawn in delete red, and nothing else changes.
  final int? deleteArmedId;

  static const _ruler = 18.0;
  static const _stripTop = 30.0;
  static const _stripBottom = 92.0;
  static const _headY = 44.0;
  static const _stemBottom = _stripBottom - 6;
  static const _handleY = (_stripTop + _stripBottom) / 2 - 12;

  @override
  void paint(Canvas canvas, Size size) {
    _paintFilmStrip(canvas, size);
    _paintRuler(canvas, size);
    for (final shot in shots) {
      _paintShot(canvas, shot);
    }
    _paintPlayhead(canvas, size);
  }

  void _paintFilmStrip(Canvas canvas, Size size) {
    final body = Rect.fromLTRB(0, _stripTop, size.width, _stripBottom);
    canvas.drawRect(body, Paint()..color = const Color(0xFF1C1F24));
    // Sprocket holes: the film idiom, and a cheap scale reference for how much of the
    // clip the window covers.
    final hole = Paint()..color = const Color(0xFF0F1114);
    const pitch = 16.0;
    for (var x = 4.0; x < size.width - pitch; x += pitch) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, _stripTop + 3, pitch - 9, 6), const Radius.circular(2)),
          hole);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, _stripBottom - 9, pitch - 9, 6), const Radius.circular(2)),
          hole);
    }
  }

  void _paintRuler(Canvas canvas, Size size) {
    final stepUs = _tickStepUs(view, size.width);
    final first = (view.viewStartUs / stepUs).ceil() * stepUs;
    final text = TextPainter(textDirection: TextDirection.ltr);
    final line = Paint()
      ..color = const Color(0xFF6B7280)
      ..strokeWidth = 1;
    for (var us = first; us <= view.viewStartUs + view.viewUs; us += stepUs) {
      final x = view.xOfUs(us).toDouble();
      canvas.drawLine(Offset(x, _ruler + 6), Offset(x, _stripTop), line);
      text.text = TextSpan(
          text: formatUs(us),
          style: const TextStyle(color: Color(0xFF9AA3AF), fontSize: 9));
      text.layout();
      text.paint(canvas, Offset(x + 2, 2));
    }
  }

  /// Ticks stay at least 64px apart, so zooming out never produces a grey smear of text.
  static int _tickStepUs(TimelineView view, double width) {
    const candidates = [
      500000, 1000000, 2000000, 5000000, 10000000, 15000000, 30000000, 60000000
    ];
    final perPx = view.viewUs / math.max(width, 1);
    for (final c in candidates) {
      if (c / perPx >= 64) return c;
    }
    return candidates.last;
  }

  void _paintShot(Canvas canvas, Shot shot) {
    final x = view.xOfUs(shot.tUs);
    final before = view.xOfUs(shot.tUs - shot.windowBeforeUs);
    final after = view.xOfUs(shot.tUs + shot.windowAfterUs);
    final selected = shot.id != null && shot.id == selectedId;
    final armed = shot.id != null && shot.id == deleteArmedId;
    final base = armed
        ? const Color(0xFFE53935)
        : shot.manual
            ? const Color(0xFFFFB300)
            : const Color(0xFF43A047);
    final color = armed || shot.enabled ? base : base.withValues(alpha: 0.35);

    if (shot.enabled || armed) {
      canvas.drawRect(
        Rect.fromLTRB(before, _stripTop + 12, after, _stripBottom - 12),
        Paint()..color = color.withValues(alpha: selected ? 0.30 : 0.16),
      );
    }

    canvas.drawLine(Offset(x, _headY), Offset(x, _stemBottom),
        Paint()
          ..color = color
          ..strokeWidth = selected ? 2.5 : 1.5);

    final head = Rect.fromCircle(center: Offset(x, _headY), radius: selected ? 9 : 7);
    if (shot.isMake) {
      canvas.drawCircle(head.center, head.width / 2, Paint()..color = color);
    } else {
      // A miss is the same pin with an empty head, so the two colours keep meaning
      // "auto vs edited" rather than competing to say "in vs out".
      canvas.drawCircle(head.center, head.width / 2 - 1.5,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    if (selected) {
      canvas.drawCircle(head.center, head.width / 2 + 3,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      _paintHandle(canvas, before, color);
      _paintHandle(canvas, after, color);
    }
  }

  void _paintHandle(Canvas canvas, double x, Color color) {
    final rect = Rect.fromLTWH(x - 3, _handleY, 6, 26);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = color);
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = view.xOfUs(positionUs);
    if (x < 0 || x > size.width) return;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x, 0), Offset(x, _stripBottom + 4), paint);
    canvas.drawPath(
        Path()
          ..moveTo(x - 5, 0)
          ..lineTo(x + 5, 0)
          ..lineTo(x, 8)
          ..close(),
        paint);
  }

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.view.viewStartUs != view.viewStartUs ||
      old.view.viewUs != view.viewUs ||
      old.view.width != view.width ||
      old.positionUs != positionUs ||
      old.selectedId != selectedId ||
      old.deleteArmedId != deleteArmedId ||
      old.shots != shots;
}

/// The strip itself; all state changes are reported as callbacks so the widget is pure and
/// golden-testable without a video decoder.
class TimelineStrip extends StatelessWidget {
  const TimelineStrip({
    super.key,
    required this.view,
    required this.shots,
    required this.positionUs,
    this.selectedId,
    this.deleteArmedId,
    this.height = 100,
    this.onSeek,
    this.onPinTap,
    this.onPinLongPress,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final TimelineView view;
  final List<Shot> shots;
  final int positionUs;
  final int? selectedId;

  /// Painted in delete red while the drag that will remove it is in flight.
  final int? deleteArmedId;
  final double height;

  /// Called with the time under the finger.
  final ValueChanged<int>? onSeek;
  final ValueChanged<Shot>? onPinTap;
  final ValueChanged<int>? onPinLongPress;

  /// The drag that started on the strip. [DragAction] and the pin it resolved to are decided
  /// here, where the pixel width is known, and reported to the parent - the strip stays
  /// stateless and the parent never has to hit-test in pixels.
  final void Function(DragAction action, Shot? pin, int us)? onDragStart;
  final ValueChanged<DragUpdate>? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sized = TimelineView(
            durationUs: view.durationUs,
            viewStartUs: view.viewStartUs,
            viewUs: view.viewUs,
            width: constraints.maxWidth);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onSeek == null
              ? null
              : (d) {
                  final tapped = nearPin(shots, sized, sized.usOfX(d.localPosition.dx));
                  if (tapped != null) {
                    onPinTap?.call(tapped);
                  } else {
                    onSeek?.call(sized.usOfX(d.localPosition.dx));
                  }
                },
          onLongPressStart: onPinLongPress == null
              ? null
              : (d) => onPinLongPress!.call(sized.usOfX(d.localPosition.dx)),
          // A pan, not a horizontal drag: pulling a pin out of the film is the one gesture
          // that needs the vertical axis, and an axis the strip never reports cannot be
          // tested by anything.
          onPanStart: onDragStart == null
              ? null
              : (d) {
                  final us = sized.usOfX(d.localPosition.dx);
                  onDragStart!(
                      dragActionAt(
                          view: sized,
                          shots: shots,
                          selectedId: selectedId,
                          x: d.localPosition.dx),
                      nearPin(shots, sized, us),
                      us);
                },
          onPanUpdate: onDragUpdate == null
              ? null
              : (d) => onDragUpdate!(DragUpdate(
                  us: sized.usOfX(d.localPosition.dx),
                  delta: d.delta,
                  offStrip: d.localPosition.dy < 0 || d.localPosition.dy > height,
                )),
          onPanEnd: onDragEnd == null ? null : (d) => onDragEnd!(),
          child: CustomPaint(
            size: Size(constraints.maxWidth, height),
            painter: TimelinePainter(
                view: sized,
                shots: shots,
                positionUs: positionUs,
                selectedId: selectedId,
                deleteArmedId: deleteArmedId),
          ),
        );
      },
    );
  }
}

/// Zoom controls next to the strip.
class TimelineControls extends StatelessWidget {
  const TimelineControls({super.key, required this.view, required this.onZoom, required this.onFit});

  final TimelineView view;
  final ValueChanged<double> onZoom;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final canZoomIn = view.viewUs > TimelineView.minViewUs;
    final canZoomOut = view.viewUs < view.durationUs;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.zoom_out),
          onPressed: canZoomOut ? () => onZoom(2) : null,
          tooltip: '显示整段',
        ),
        IconButton(
          icon: const Icon(Icons.zoom_in),
          onPressed: canZoomIn ? () => onZoom(0.5) : null,
          tooltip: '放大',
        ),
        IconButton(icon: const Icon(Icons.fit_screen), onPressed: onFit, tooltip: '适配全片'),
        const Spacer(),
        Text('${(view.viewUs / 1000000).toStringAsFixed(1)}s 窗口',
            style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
