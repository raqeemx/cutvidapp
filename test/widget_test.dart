import 'package:flutter_test/flutter_test.dart';

import 'package:clip_master/utils/time_format.dart';

void main() {
  test('formatDuration formats minutes and seconds', () {
    expect(formatMs(75000), '01:15');
    expect(formatMs(150000), '02:30');
    expect(formatMs(0), '00:00');
  });

  test('formatDuration handles hours', () {
    expect(formatMs(3661000), '01:01:01');
  });
}
