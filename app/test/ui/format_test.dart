import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/ui/common/format.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });

  test('formatSpeed converts bytes/s to bits/s with unit', () {
    expect(formatSpeed(0), '0 bps');
    expect(formatSpeed(120), '960 bps');
    expect(formatSpeed(125), '1.0 Kbps');
    expect(formatSpeed(125000), '1.0 Mbps');
  });

  test('formatPing', () {
    expect(formatPing(null), '—');
    expect(formatPing(87), '87 мс');
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 5)), '00:05');
    expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '03:07');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });

  test('formatAge', () {
    expect(formatAge(0), '< 1 ч');
    expect(formatAge(5), '5 ч');
    expect(formatAge(50), '2 дн');
  });
}
