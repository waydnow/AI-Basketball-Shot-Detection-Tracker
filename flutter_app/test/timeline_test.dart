import 'package:basketball_highlights/domain/models.dart';
import 'package:basketball_highlights/ui/timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Shot shot(int id, int tUs, {int beforeUs = 1000000, int afterUs = 1000000, bool? make}) => Shot(
      id: id,
      videoId: 'v',
      tUs: tUs,
      isMake: make ?? true,
      origin: ShotOrigin.auto,
      windowBeforeUs: beforeUs,
      windowAfterUs: afterUs,
    );

void main() {
  // 10s clip, viewing 2s..6s across 360px: 1s of video = 90px.
  final view =
      TimelineView(durationUs: 10000000, viewStartUs: 2000000, viewUs: 4000000, width: 360);

  group('time <-> pixel mapping', () {
    test('anchors the window edges at 0 and width', () {
      expect(view.xOfUs(2000000), 0);
      expect(view.xOfUs(6000000), 360);
      expect(view.usOfX(180), 4000000);
    });

    test('pixels beyond the clip read as its first and last instant', () {
      // A point left of the window is still a real instant of the clip; only values off the
      // end of the video clamp.
      expect(view.usOfX(-40), 1555556);
      expect(view.usOfX(-400), 0);
      expect(view.usOfX(1200), 10000000);
    });

    test('round trips inside the window', () {
      for (final us in [2000000, 3333333, 5999999]) {
        expect(view.usOfX(view.xOfUs(us)), us, reason: '$us us');
      }
    });
  });

  group('window arithmetic', () {
    test('zooming keeps the focused instant under the same pixel', () {
      final zoomed = view.zoom(0.5, 5000000);
      expect(zoomed.viewUs, 2000000);
      expect((zoomed.xOfUs(5000000) - view.xOfUs(5000000)).abs() < 1, isTrue);
    });

    test('zoom cannot go below one second or past the whole clip', () {
      expect(view.zoom(0.01, 5000000).viewUs, TimelineView.minViewUs);
      expect(view.zoom(100, 5000000).viewUs, 10000000);
    });

    test('panning stops at the clip edges', () {
      expect(view.panned(-1000000).viewStartUs, 0);
      expect(view.panned(9000000).viewStartUs, 6000000);
    });

    test('following the playhead only moves the window when it leaves the view', () {
      expect(view.following(3000000), same(view));
      // 9s centred would need a window running to 11s, so it stops at the end of the clip.
      expect(view.following(9000000).viewStartUs, 6000000);
    });
  });

  group('what a drag controls', () {
    final shots = [shot(1, 5000000), shot(2, 9000000)];

    test('empty strip pans', () {
      expect(dragActionAt(view: view, shots: shots, selectedId: null, x: view.xOfUs(3000000)),
          DragAction.pan);
    });

    test('a pin is grabbed within the hit radius and moves', () {
      final x = view.xOfUs(5000000);
      expect(
          dragActionAt(view: view, shots: shots, selectedId: null, x: x + 12), DragAction.movePin);
      expect(dragActionAt(view: view, shots: shots, selectedId: null, x: x + 40), DragAction.pan);
    });

    test('the selected pin exposes its window handles at the band edges', () {
      final before = view.xOfUs(5000000 - 1000000);
      final after = view.xOfUs(5000000 + 1000000);
      expect(dragActionAt(view: view, shots: shots, selectedId: 1, x: before),
          DragAction.windowBefore);
      expect(
          dragActionAt(view: view, shots: shots, selectedId: 1, x: after), DragAction.windowAfter);
      // Unselected, the same pixels belong to nobody's window.
      expect(dragActionAt(view: view, shots: shots, selectedId: null, x: before), DragAction.pan);
    });

    test('nearPin picks the closest of two overlapping pins', () {
      final crowded = [shot(1, 5000000), shot(2, 5100000)];
      expect(nearPin(crowded, view, 5070000)?.id, 2);
      expect(nearPin(crowded, view, 4990000)?.id, 1);
    });
  });

  group('cut plan', () {
    test('skips disabled pins and misses when asked, and clamps to the clip', () {
      final shots = [
        shot(1, 500000, beforeUs: 3000000, afterUs: 3000000),
        shot(2, 9900000, beforeUs: 3000000, afterUs: 3000000),
        shot(3, 5000000, make: false),
        shot(4, 7000000, make: false).copyWith(enabled: false),
      ];
      final all = planSegments(shots: shots, durationUs: 10000000, includeMisses: true);
      expect(all.map((s) => s.shot.id), [1, 3, 2]);
      expect(all.first.startUs, 0, reason: 'a pin 0.5s in cannot ask for 3s of lead-in');
      expect(all.last.endUs, 10000000);
      expect(planSegments(shots: shots, durationUs: 10000000, includeMisses: false).map((s) => s.shot.id),
          [1, 2]);
    });
  });

  test('formatUs reads as a timecode', () {
    expect(formatUs(0), '00:00.0');
    expect(formatUs(2302299), '00:02.3');
    expect(formatUs(75000000), '01:15.0');
  });

  testWidgets('the strip draws, and a long press on empty film reports that instant',
      (tester) async {
    int? added;
    await tester.binding.setSurfaceSize(const Size(360, 120));
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          child: TimelineStrip(
            view: const TimelineView(
                durationUs: 10000000, viewStartUs: 0, viewUs: 10000000, width: 360),
            shots: [shot(1, 5000000), shot(2, 9000000, make: false)],
            positionUs: 2500000,
            selectedId: 1,
            onSeek: (_) {},
            onPinLongPress: (us) => added = us,
          ),
        ),
      ),
    ));

    // The strip is top-left aligned in a 360x120 surface, so 180px is the half-time point.
    await tester.longPressAt(const Offset(180, 60));
    await tester.pump();
    expect(added, 5000000);

    await expectLater(
        find.byType(TimelineStrip), matchesGoldenFile('goldens/timeline_strip.png'));
  });
}
