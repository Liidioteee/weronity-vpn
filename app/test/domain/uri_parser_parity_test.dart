import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/domain/uri_parser.dart';

/// The Dart parser is a hand-maintained port of `collector/parsers/*.py`. Both
/// suites assert the same fixture (generated from the Python side by
/// `collector/tests/gen_parity.py`), so a key the user pastes gets the same id
/// — and the same accept/reject verdict — as the same node in the pool.
void main() {
  final fixture = File('../collector/tests/fixtures/parity_expected.json');

  test('the parity fixture is present', () {
    expect(fixture.existsSync(), isTrue,
        reason: 'run `python tests/gen_parity.py` in collector/');
  });

  final entries = fixture.existsSync()
      ? (jsonDecode(fixture.readAsStringSync()) as List<dynamic>)
          .cast<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];

  for (final e in entries) {
    final uri = e['uri'] as String;
    final want = e['node'] as Map<String, dynamic>?;
    final label = uri.contains('#') ? uri.split('#').last : uri.substring(0, 24);

    test('parity: $label', () {
      final node = parseProxyUri(uri);
      if (want == null) {
        expect(node, isNull, reason: 'the collector rejects this URI');
        return;
      }
      expect(node, isNotNull, reason: 'the collector accepts this URI');
      expect(node!.id, want['id']);
      expect(node.protocol, want['protocol']);
      expect(node.transport, want['transport']);
      expect(node.endpoint.host, want['host']);
      expect(node.endpoint.port, want['port']);
      expect(node.classification.sni, want['sni']);
      expect(node.classification.security.name, want['security']);
      expect(node.outbound['type'], want['outbound_type']);
    });
  }
}
