import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/app/hints.dart';

void main() {
  test('every hint has a title and a substantive body', () {
    expect(kHints, isNotEmpty);
    for (final e in kHints.entries) {
      expect(e.value.title, isNotEmpty, reason: e.key);
      expect(
        e.value.body.length,
        greaterThan(30),
        reason: '${e.key} body too short',
      );
    }
  });

  test('the parameters that must carry ℹ️ per the spec are all covered', () {
    const required = {
      'pro_mode',
      'routing_mode',
      'adblock',
      'auto_last_node',
      'auto_fastest',
      'lifetime_class',
      'stability',
      'ping',
      'security_reality',
      'sni',
      'protocol',
      'pool_source',
      'preflight_endpoints',
      'custom_keys',
      'zero_log',
    };
    expect(kHints.keys.toSet().containsAll(required), isTrue);
  });

  test('hintRecord falls back to empty for an unknown key', () {
    expect(hintRecord('does_not_exist'), (title: '', body: ''));
    final r = hintRecord('pro_mode');
    expect(r.title, 'Pro-режим');
  });
}
