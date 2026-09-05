import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/custom_keys_repository.dart';
import '../domain/node.dart';
import '../domain/uri_parser.dart';

final customKeysRepositoryProvider =
    Provider<CustomKeysRepository>((ref) => CustomKeysRepository());

@immutable
class CustomKeysData {
  const CustomKeysData({
    this.keys = const [],
    this.subs = const [],
    this.nodes = const [],
  });

  /// Individually added keys (paste / QR).
  final List<CustomKey> keys;

  /// Subscription URLs.
  final List<Subscription> subs;

  /// Parsed nodes from both sources, tagged `imported`.
  final List<Node> nodes;

  bool get isEmpty => keys.isEmpty && subs.isEmpty;

  CustomKeysData copyWith({
    List<CustomKey>? keys,
    List<Subscription>? subs,
    List<Node>? nodes,
  }) =>
      CustomKeysData(
        keys: keys ?? this.keys,
        subs: subs ?? this.subs,
        nodes: nodes ?? this.nodes,
      );
}

/// Result of trying to add pasted/scanned text.
class AddResult {
  const AddResult(this.added, this.duplicates, this.failed);
  final int added;
  final int duplicates;
  final int failed;
  bool get isNothing => added == 0 && duplicates == 0;
}

class CustomKeysNotifier extends AsyncNotifier<CustomKeysData> {
  late CustomKeysRepository _repo;
  final _client = http.Client();

  // Session cache of subscription-derived nodes, keyed by URL.
  final Map<String, List<Node>> _subNodes = {};

  @override
  Future<CustomKeysData> build() async {
    _repo = ref.watch(customKeysRepositoryProvider);
    ref.onDispose(_client.close);
    final keys = await _repo.loadKeys();
    final subs = await _repo.loadSubs();
    return _assemble(keys, subs);
  }

  CustomKeysData _assemble(List<CustomKey> keys, List<Subscription> subs) {
    final nodes = <String, Node>{};
    for (final k in keys) {
      final n = parseProxyUri(k.rawUri);
      if (n != null) nodes[n.id] = n;
    }
    for (final s in subs) {
      for (final n in _subNodes[s.url] ?? const <Node>[]) {
        nodes.putIfAbsent(n.id, () => n);
      }
    }
    return CustomKeysData(keys: keys, subs: subs, nodes: nodes.values.toList());
  }

  Future<void> _persistAndRefresh(List<CustomKey> keys, List<Subscription> subs) async {
    await _repo.saveKeys(keys);
    await _repo.saveSubs(subs);
    state = AsyncData(_assemble(keys, subs));
  }

  /// Add every proxy URI found in [text] (a single URI, a list, or base64).
  Future<AddResult> addFromText(String text) async {
    final current = state.valueOrNull ?? const CustomKeysData();
    final existingRaw = current.keys.map((k) => k.rawUri.trim()).toSet();
    final existingIds = current.nodes.map((n) => n.id).toSet();

    final uris = extractProxyUris(text);
    if (uris.isEmpty) {
      final decoded = _maybeBase64(text);
      if (decoded != null) uris.addAll(extractProxyUris(decoded));
    }
    if (uris.isEmpty && text.trim().split('://').length == 2) {
      uris.add(text.trim()); // a bare single URI with an unusual scheme spelling
    }

    var added = 0, dupes = 0, failed = 0;
    final keys = [...current.keys];
    for (final uri in uris) {
      if (existingRaw.contains(uri.trim())) {
        dupes++;
        continue;
      }
      final node = parseProxyUri(uri);
      if (node == null) {
        failed++;
        continue;
      }
      if (existingIds.contains(node.id)) {
        dupes++;
        continue;
      }
      existingIds.add(node.id);
      keys.add(CustomKey(rawUri: uri.trim(), addedAt: DateTime.now()));
      added++;
    }
    if (added > 0) await _persistAndRefresh(keys, current.subs);
    return AddResult(added, dupes, failed);
  }

  Future<void> removeKey(String rawUri) async {
    final current = state.valueOrNull ?? const CustomKeysData();
    final keys = current.keys.where((k) => k.rawUri != rawUri).toList();
    await _persistAndRefresh(keys, current.subs);
  }

  /// Add a subscription URL and fetch it once.
  Future<String?> addSubscription(String url) async {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return 'Ссылка должна начинаться с http:// или https://';
    }
    final current = state.valueOrNull ?? const CustomKeysData();
    if (current.subs.any((s) => s.url == u)) return 'Такая подписка уже добавлена';

    final sub = Subscription(url: u, addedAt: DateTime.now());
    final subs = [...current.subs, sub];
    await _persistAndRefresh(current.keys, subs);
    await refreshSubscription(u);
    return null;
  }

  Future<void> removeSubscription(String url) async {
    final current = state.valueOrNull ?? const CustomKeysData();
    _subNodes.remove(url);
    final subs = current.subs.where((s) => s.url != url).toList();
    await _persistAndRefresh(current.keys, subs);
  }

  Future<void> refreshAllSubscriptions() async {
    final subs = state.valueOrNull?.subs ?? const <Subscription>[];
    for (final s in subs) {
      await refreshSubscription(s.url);
    }
  }

  Future<void> refreshSubscription(String url) async {
    final current = state.valueOrNull ?? const CustomKeysData();
    Subscription updated;
    try {
      final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
      final nodes = parseSubscription(
        utf8.decode(res.bodyBytes),
        source: 'subscription:$url',
      );
      _subNodes[url] = nodes;
      updated = (current.subs.firstWhere((s) => s.url == url,
              orElse: () => Subscription(url: url, addedAt: DateTime.now())))
          .copyWith(lastFetched: DateTime.now(), nodeCount: nodes.length);
    } catch (e) {
      debugPrint('subscription refresh failed ($url): $e');
      updated = (current.subs.firstWhere((s) => s.url == url,
              orElse: () => Subscription(url: url, addedAt: DateTime.now())))
          .copyWith(error: 'Не удалось загрузить');
    }
    final subs = [
      for (final s in current.subs) if (s.url == url) updated else s,
    ];
    state = AsyncData(_assemble(current.keys, subs));
    await _repo.saveSubs(subs);
  }

  String? _maybeBase64(String text) {
    try {
      var s = text.trim().replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      s += '=' * ((4 - s.length % 4) % 4);
      final decoded = utf8.decode(base64.decode(s));
      return decoded.contains('://') ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

final customKeysProvider =
    AsyncNotifierProvider<CustomKeysNotifier, CustomKeysData>(CustomKeysNotifier.new);

/// All custom-derived nodes (empty while loading).
final customNodesProvider = Provider<List<Node>>(
  (ref) => ref.watch(customKeysProvider).valueOrNull?.nodes ?? const [],
);
