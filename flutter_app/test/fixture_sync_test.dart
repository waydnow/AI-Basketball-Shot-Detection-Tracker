import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app bundles a copy of the Python golden so the timeline can be exercised before
/// on-device inference exists. This is what stops the two copies from drifting apart and
/// the demo from quietly disagreeing with `dump_reference.py`.
void main() {
  test('bundled events asset equals the Python golden', () {
    final golden = File('../fixtures/video_test_5_events.json');
    final asset = File('assets/fixtures/video_test_5_events.json');
    expect(golden.existsSync(), isTrue,
        reason: 'run tools/dump_reference.py first - the parity goldens are not optional');
    expect(asset.readAsStringSync(), golden.readAsStringSync());
  });
}
