import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/data/custom_keys_repository.dart';
import 'package:weronity/state/custom_keys.dart';

/// In-memory repo so the notifier can run without the OS secure store.
class _FakeRepo implements CustomKeysRepository {
  List<CustomKey> keys = [];
  List<Subscription> subs = [];

  @override
  Future<List<CustomKey>> loadKeys() async => keys;
  @override
  Future<List<Subscription>> loadSubs() async => subs;
  @override
  Future<void> saveKeys(List<CustomKey> k) async => keys = k;
  @override
  Future<void> saveSubs(List<Subscription> s) async => subs = s;
}

const _key1 =
    'vless://11111111-2222-3333-4444-555555555555@de.example.net:443?type=tcp&security=reality'
    '&pbk=TESTKEY123&sid=abcd&fp=chrome&sni=www.microsoft.com&flow=xtls-rprx-vision#Мой ключ DE';
const _key2 = 'trojan://pw@nl.example.net:443?type=ws&security=tls&sni=nl.example.net&path=%2Ft#NL';

ProviderContainer _container(_FakeRepo repo) => ProviderContainer(
      overrides: [customKeysRepositoryProvider.overrideWithValue(repo)],
    );

void main() {
  test('addFromText adds a pasted vless key with a cyrillic label', () async {
    final repo = _FakeRepo();
    final c = _container(repo);
    addTearDown(c.dispose);

    await c.read(customKeysProvider.future);
    final r = await c.read(customKeysProvider.notifier).addFromText(_key1);

    expect(r.added, 1);
    expect(r.failed, 0);
    final data = c.read(customKeysProvider).requireValue;
    expect(data.keys, hasLength(1));
    expect(data.nodes, hasLength(1));
    expect(data.nodes.single.isCustom, isTrue);
    expect(data.nodes.single.tag, 'Мой ключ DE');
    expect(repo.keys, hasLength(1)); // persisted
  });

  test('adds multiple, skips duplicates on a second paste', () async {
    final repo = _FakeRepo();
    final c = _container(repo);
    addTearDown(c.dispose);
    await c.read(customKeysProvider.future);
    final n = c.read(customKeysProvider.notifier);

    final r1 = await n.addFromText('$_key1\n$_key2');
    expect(r1.added, 2);
    final r2 = await n.addFromText(_key1);
    expect(r2.added, 0);
    expect(r2.duplicates, 1);
    expect(c.read(customKeysProvider).requireValue.keys, hasLength(2));
  });

  test('addFromText decodes a base64 blob', () async {
    final repo = _FakeRepo();
    final c = _container(repo);
    addTearDown(c.dispose);
    await c.read(customKeysProvider.future);

    final blob = base64.encode(utf8.encode('$_key1\n$_key2'));
    final r = await c.read(customKeysProvider.notifier).addFromText(blob);
    expect(r.added, 2);
  });

  test('addFromText on junk reports nothing added', () async {
    final repo = _FakeRepo();
    final c = _container(repo);
    addTearDown(c.dispose);
    await c.read(customKeysProvider.future);

    final r = await c.read(customKeysProvider.notifier).addFromText('hello world');
    expect(r.added, 0);
    expect(r.isNothing, isTrue);
  });

  test('removeKey drops it and re-persists', () async {
    final repo = _FakeRepo();
    final c = _container(repo);
    addTearDown(c.dispose);
    await c.read(customKeysProvider.future);
    final n = c.read(customKeysProvider.notifier);

    await n.addFromText(_key1);
    await n.removeKey(_key1);
    expect(c.read(customKeysProvider).requireValue.keys, isEmpty);
    expect(repo.keys, isEmpty);
  });
}
