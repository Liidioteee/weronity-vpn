@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/native/native_core.dart';

void main() {
  test('NativeCore.instance() never throws and returns a resolved state', () {
    final core = NativeCore.instance();
    expect(core.state, isA<NativeCoreState>());
    // Same instance on repeat.
    expect(identical(NativeCore.instance(), core), isTrue);
  });

  test('when the library is not present it degrades, it does not crash', () {
    final core = NativeCore.instance();
    if (core.state != NativeCoreState.ok) {
      expect(core.isAvailable, isFalse);
      expect(core.version(), isNull);
      expect(core.ping(1), isNull);
      expect(core.statsJson(), isNull);
      expect(core.start('{}'), lessThan(0));
      expect(core.stop(), lessThan(0));
      expect(core.isRunning(), isFalse);
    }
  });

  test('if the library IS loaded, the smoke calls marshal correctly', () {
    final core = NativeCore.instance();
    if (core.state == NativeCoreState.ok) {
      expect(core.ping(41), 42);
      expect(core.version(), contains('weronity-core'));
      expect(core.isRunning(), isFalse);
      expect(core.start('not json'), isNot(0));
      expect(core.start('{"log":{}}'), 0);
      expect(core.isRunning(), isTrue);
      expect(core.statsJson(), contains('rx_bytes'));
      expect(core.stop(), 0);
      expect(core.isRunning(), isFalse);
    }
  }, skip: NativeCore.instance().state != NativeCoreState.ok
      ? 'weronity_core not loadable in this test run'
      : false);
}
