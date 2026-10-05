import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/custom_keys_repository.dart';
import '../data/geoip_service.dart';
import '../domain/country_names.dart';
import '../domain/node.dart';
import '../domain/uri_parser.dart';

final customKeysRepositoryProvider =
    Provider<CustomKeysRepository>((ref) => CustomKeysRepository());

/// Offline IPv4 -> country database, loaded once from a bundled asset.
final geoIpServiceProvider =
    FutureProvider<GeoIpService>((ref) => GeoIpService.instance());

@immutable
class CustomKeysData {
  const CustomKeysData({
    this.keys = const [],
    this.subs = const [],
    this.nodes = const [],
    this.bundles = const [],
    this.storageError,
  });

  /// Individually added keys (paste / QR).
  final List<CustomKey> keys;

  /// Subscription URLs.
  final List<Subscription> subs;

  /// Parsed nodes from both sources, tagged `imported`.
  final List<Node> nodes;

  /// User-made node collections (ТЗ: «свои подборки»).
  final List<KeyBundle> bundles;

  /// Set when the last write to the OS secure store failed: what is on screen
  /// will not survive a restart, and the user has to know.
  final String? storageError;

  bool get isEmpty => keys.isEmpty && subs.isEmpty;

  CustomKeysData copyWith({
    List<CustomKey>? keys,
    List<Subscription>? subs,
    List<Node>? nodes,
    List<KeyBundle>? bundles,
  }) =>
      CustomKeysData(
        keys: keys ?? this.keys,
        subs: subs ?? this.subs,
        nodes: nodes ?? this.nodes,
        bundles: bundles ?? this.bundles,
        storageError: storageError,
      );
}

/// Result of trying to add pasted/scanned text.
class AddResult {
  const AddResult(this.added, this.duplicates, this.failed,
      {this.addedNodeIds = const []});
  final int added;
  final int duplicates;
  final int failed;

  /// Node ids for the keys that were actually added — used to offer "combine
  /// into a bundle" right after a multi-key paste.
  final List<String> addedNodeIds;

  bool get isNothing => added == 0 && duplicates == 0;
}

class CustomKeysNotifier extends AsyncNotifier<CustomKeysData> {
  late CustomKeysRepository _repo;
  final _client = http.Client();

  // Session cache of subscription-derived nodes, keyed by URL.
  final Map<String, List<Node>> _subNodes = {};

  // host -> ISO country code ('' = resolved, no country). Filled in the
  // background so imported keys get a flag.
  final Map<String, String> _ccByHost = {};
  GeoIpService? _geo;
  bool _disposed = false;
  bool _geoRunning = false;
  CustomKeysData? _geoPending;

  // User bundles — kept as a field so _assemble() (called from several places)
  // doesn't need a wider signature.
  List<KeyBundle> _bundles = const [];

  String? _storageError;

  /// Every mutation is read-state → await → write-state. Run them one at a
  /// time, or two that overlap (a paste while a subscription is downloading)
  /// write back a stale copy and silently undo each other.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Runs a write to the secure store and remembers whether it worked.
  Future<void> _store(Future<void> Function() write) async {
    try {
      await write();
      _storageError = null;
    } on Object catch (e) {
      debugPrint('custom keys: storage write failed (${e.runtimeType})');
      _storageError = 'Системное хранилище недоступно — ключи и подписки '
          'не сохранятся после перезапуска приложения.';
    }
  }

  @override
  Future<CustomKeysData> build() async {
    _repo = ref.watch(customKeysRepositoryProvider);
    ref.onDispose(() {
      _disposed = true;
      _client.close();
    });
    try {
      _geo = await ref.read(geoIpServiceProvider.future);
    } on Object catch (e) {
      debugPrint('GeoIpService unavailable: ${e.runtimeType}');
      _geo = null;
    }
    final keys = await _repo.loadKeys();
    final subs = await _repo.loadSubs();
    _bundles = await _repo.loadBundles();
    final data = _assemble(keys, subs);
    unawaited(_resolveGeo(data));
    return data;
  }

  Geo _geoFor(String cc) => Geo(country: cc, countryName: countryNameRu(cc));

  CustomKeysData _assemble(List<CustomKey> keys, List<Subscription> subs) {
    final nodes = <String, Node>{};
    void add(Node n) {
      final cc = _ccByHost[n.endpoint.host];
      nodes.putIfAbsent(
        n.id,
        () => (cc != null && cc.isNotEmpty) ? n.copyWith(geo: _geoFor(cc)) : n,
      );
    }

    for (final k in keys) {
      final n = parseProxyUri(k.rawUri);
      if (n != null) add(n);
    }
    for (final s in subs) {
      for (final n in _subNodes[s.url] ?? const <Node>[]) {
        add(n);
      }
    }
    return CustomKeysData(
      keys: keys,
      subs: subs,
      nodes: nodes.values.toList(),
      bundles: _bundles,
      storageError: _storageError,
    );
  }

  // ---- bundles --------------------------------------------------------

  Future<void> _persistBundles() async {
    await _store(() => _repo.saveBundles(_bundles));
    final cur = state.valueOrNull;
    if (cur != null) state = AsyncData(_assemble(cur.keys, cur.subs));
  }

  static String _bundleId() =>
      'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// Create a bundle from [nodeIds]; returns its id (empty if nothing to add).
  Future<String> createBundle(String name, Iterable<String> nodeIds) {
    final ids = nodeIds.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return Future<String>.value('');
    return _serial(() async {
      final b = KeyBundle(
        id: _bundleId(),
        name: name.trim().isEmpty ? 'Подборка' : name.trim(),
        nodeIds: ids,
        createdAt: DateTime.now(),
      );
      _bundles = [..._bundles, b];
      await _persistBundles();
      return b.id;
    });
  }

  Future<void> renameBundle(String id, String name) => _serial(() async {
        _bundles = [
          for (final b in _bundles)
            if (b.id == id) b.copyWith(name: name.trim()) else b,
        ];
        await _persistBundles();
      });

  Future<void> addToBundle(String id, Iterable<String> nodeIds) =>
      _serial(() async {
        _bundles = [
          for (final b in _bundles)
            if (b.id == id)
              b.copyWith(nodeIds: {...b.nodeIds, ...nodeIds}.toList())
            else
              b,
        ];
        await _persistBundles();
      });

  Future<void> removeBundle(String id) => _serial(() async {
        _bundles = _bundles.where((b) => b.id != id).toList();
        await _persistBundles();
      });

  /// Resolve a country for every not-yet-known host in [data], then re-emit
  /// state so the flags appear. Coalesces overlapping calls (newest [data]
  /// wins). Takes [data] explicitly because the first call fires before
  /// `build()` returns, i.e. before `state` is `AsyncData`.
  Future<void> _resolveGeo(CustomKeysData data) async {
    if (_geo == null || _disposed) return;
    _geoPending = data;
    if (_geoRunning) return;
    _geoRunning = true;
    try {
      while (_geoPending != null && !_disposed) {
        final next = _geoPending!;
        _geoPending = null;
        await _resolveGeoOnce(next);
      }
    } finally {
      _geoRunning = false;
    }
  }

  Future<void> _resolveGeoOnce(CustomKeysData data) async {
    final geo = _geo;
    if (geo == null) return;

    final hosts = <String>{for (final n in data.nodes) n.endpoint.host}
      ..removeWhere((h) => h.isEmpty || _ccByHost.containsKey(h));
    if (hosts.isEmpty) return;

    var changed = false;
    for (final h in hosts) {
      if (_disposed) return;
      final cc = await geo.lookupHost(h);
      _ccByHost[h] = cc ?? '';
      if (cc != null && cc.isNotEmpty) changed = true;
    }
    if (changed && !_disposed) {
      final now = state.valueOrNull ?? data;
      state = AsyncData(_assemble(now.keys, now.subs));
    }
  }

  Future<void> _persistAndRefresh(List<CustomKey> keys, List<Subscription> subs) async {
    await _store(() async {
      await _repo.saveKeys(keys);
      await _repo.saveSubs(subs);
    });
    final data = _assemble(keys, subs);
    state = AsyncData(data);
    unawaited(_resolveGeo(data));
  }

  /// Add every proxy URI found in [text] (a single URI, a list, or base64).
  Future<AddResult> addFromText(String text) => _serial(() => _addFromText(text));

  Future<AddResult> _addFromText(String text) async {
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

    var dupes = 0, failed = 0;
    final addedIds = <String>[];
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
      addedIds.add(node.id);
    }
    if (addedIds.isNotEmpty) await _persistAndRefresh(keys, current.subs);
    return AddResult(addedIds.length, dupes, failed, addedNodeIds: addedIds);
  }

  Future<void> removeKey(String rawUri) => _serial(() async {
        final current = state.valueOrNull ?? const CustomKeysData();
        final keys = current.keys.where((k) => k.rawUri != rawUri).toList();
        await _persistAndRefresh(keys, current.subs);
      });

  /// Remove several keys in one persist (bulk delete from the manager).
  Future<void> removeKeys(Set<String> rawUris) async {
    if (rawUris.isEmpty) return;
    await _serial(() async {
      final current = state.valueOrNull ?? const CustomKeysData();
      final keys =
          current.keys.where((k) => !rawUris.contains(k.rawUri)).toList();
      if (keys.length == current.keys.length) return;
      await _persistAndRefresh(keys, current.subs);
    });
  }

  /// Add a subscription URL and fetch it once.
  Future<String?> addSubscription(String url) async {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return 'Ссылка должна начинаться с http:// или https://';
    }
    final error = await _serial<String?>(() async {
      final current = state.valueOrNull ?? const CustomKeysData();
      if (current.subs.any((s) => s.url == u)) {
        return 'Такая подписка уже добавлена';
      }
      final sub = Subscription(url: u, addedAt: DateTime.now());
      await _persistAndRefresh(current.keys, [...current.subs, sub]);
      return null;
    });
    if (error != null) return error;
    await refreshSubscription(u);
    return null;
  }

  Future<void> removeSubscription(String url) => _serial(() async {
        final current = state.valueOrNull ?? const CustomKeysData();
        _subNodes.remove(url);
        final subs = current.subs.where((s) => s.url != url).toList();
        await _persistAndRefresh(current.keys, subs);
      });

  Future<void> refreshAllSubscriptions() async {
    final subs = state.valueOrNull?.subs ?? const <Subscription>[];
    for (final s in subs) {
      await refreshSubscription(s.url);
    }
  }

  /// A subscription body larger than this is not a subscription.
  static const _maxSubscriptionBytes = 8 * 1024 * 1024;

  Future<void> refreshSubscription(String url) async {
    // The download (up to 20 s) happens outside the mutation queue; only
    // applying its result is serialised.
    List<Node>? nodes;
    try {
      final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
      if (res.bodyBytes.length > _maxSubscriptionBytes) {
        throw const FormatException('subscription body too large');
      }
      nodes = parseSubscription(
        utf8.decode(res.bodyBytes),
        source: 'subscription:$url',
      );
    } catch (e) {
      // No URL in the message — subscription links usually carry a token.
      debugPrint('subscription refresh failed: ${e.runtimeType}');
    }
    if (_disposed) return;

    await _serial(() async {
      // Re-read the state: keys and subscriptions may have changed while the
      // download was in flight (and this one may have been removed).
      final current = state.valueOrNull ?? const CustomKeysData();
      if (!current.subs.any((s) => s.url == url)) return;
      final fetched = nodes;
      if (fetched != null) _subNodes[url] = fetched;
      final subs = [
        for (final s in current.subs)
          if (s.url != url)
            s
          else if (fetched != null)
            s.copyWith(lastFetched: DateTime.now(), nodeCount: fetched.length)
          else
            s.copyWith(error: 'Не удалось загрузить'),
      ];
      await _store(() => _repo.saveSubs(subs));
      final data = _assemble(current.keys, subs);
      state = AsyncData(data);
      unawaited(_resolveGeo(data));
    });
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
