@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/native/native_core.dart';

void main() {
  final core = NativeCore.instance();
  final loaded = core.state == NativeCoreState.ok;

  test('NativeCore.instance() never throws and returns a resolved state', () {
    expect(core.state, isA<NativeCoreState>());
    expect(identical(NativeCore.instance(), core), isTrue);
  });

  test('when the library is absent it degrades, it does not crash', () {
    if (loaded) return;
    expect(core.isAvailable, isFalse);
    expect(core.version(), isNull);
    expect(core.ping(1), isNull);
    expect(core.stats(), isNull);
    expect(core.drainEvents(), isEmpty);
    expect(core.startNode(const {'type': 'trojan'}), lessThan(0));
    expect(core.stop(), lessThan(0));
    expect(core.isRunning(), isFalse);
  });

  test(
    'if the library IS loaded, smoke calls marshal correctly',
    () {
      expect(core.ping(41), 42);
      expect(core.version(), contains('weronity-core'));
      expect(core.isRunning(), isFalse);
      // a hostile outbound type is rejected before the engine starts
      expect(core.startNode(const {'type': 'direct', 'server': 'x', 'server_port': 1}),
          isNot(0));
      expect(core.isRunning(), isFalse);
    },
    skip: loaded ? false : 'weronity_core not loadable in this test run',
  );
}
