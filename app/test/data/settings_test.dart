import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:weronity/data/settings_repository.dart';

/// Minimal in-memory stand-in for the Hive settings box.
class _FakeBox implements Box<dynamic> {
  final Map<dynamic, dynamic> _m = {};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _m.containsKey(key) ? _m[key] : defaultValue;

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async =>
      _m.addAll(entries);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('Settings rules', () {
    test('rules() returns the matching bucket', () {
      const s = Settings(
        directRules: ['a.com'],
        proxyRules: ['b.com'],
        blockRules: ['c.com'],
      );
      expect(s.rules(RuleBucket.direct), ['a.com']);
      expect(s.rules(RuleBucket.proxy), ['b.com']);
      expect(s.rules(RuleBucket.block), ['c.com']);
    });

    test('withRules replaces only the targeted bucket', () {
      const s = Settings(directRules: ['keep.com']);
      final next = s.withRules(RuleBucket.block, ['x.com', 'y.com']);
      expect(next.directRules, ['keep.com']);
      expect(next.blockRules, ['x.com', 'y.com']);
      expect(next.proxyRules, isEmpty);
    });

    test('copyWith carries rule lists through untouched', () {
      const s = Settings(proxyRules: ['p.com']);
      final next = s.copyWith(proMode: true);
      expect(next.proxyRules, ['p.com']);
    });
  });

  group('SettingsRepository', () {
    test('defaults load when the box is empty', () {
      final repo = SettingsRepository(_FakeBox());
      final s = repo.load();
      expect(s.proMode, isFalse);
      expect(s.themeMode, ThemeMode.dark);
      expect(s.preflightEndpoints, Settings.defaultPreflightEndpoints);
      expect(s.directRules, isEmpty);
    });

    test('save then load round-trips rules and endpoints', () async {
      final repo = SettingsRepository(_FakeBox());
      const s = Settings(
        proMode: true,
        routingMode: RoutingMode.global,
        preflightEndpoints: ['https://example.com/generate_204'],
        directRules: ['gov.ru'],
        proxyRules: ['youtube.com', 'twitter.com'],
        blockRules: ['ads.example'],
      );
      await repo.save(s);

      final back = repo.load();
      expect(back.proMode, isTrue);
      expect(back.routingMode, RoutingMode.global);
      expect(back.preflightEndpoints, ['https://example.com/generate_204']);
      expect(back.directRules, ['gov.ru']);
      expect(back.proxyRules, ['youtube.com', 'twitter.com']);
      expect(back.blockRules, ['ads.example']);
    });
  });
}
