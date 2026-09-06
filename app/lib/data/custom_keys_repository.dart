import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One user-supplied key (pasted or scanned). The raw URI is the source of
/// truth; it is re-parsed on load so an app update can improve parsing.
@immutable
class CustomKey {
  const CustomKey({required this.rawUri, required this.addedAt, this.label});

  final String rawUri;
  final DateTime addedAt;
  final String? label;

  Map<String, dynamic> toJson() => {
        'raw': rawUri,
        'added': addedAt.toIso8601String(),
        if (label != null) 'label': label,
      };

  factory CustomKey.fromJson(Map<String, dynamic> j) => CustomKey(
        rawUri: j['raw'] as String,
        addedAt: DateTime.tryParse(j['added']?.toString() ?? '') ?? DateTime.now(),
        label: j['label'] as String?,
      );
}

/// A subscription URL. Its nodes are refetched on demand.
@immutable
class Subscription {
  const Subscription({
    required this.url,
    required this.addedAt,
    this.lastFetched,
    this.nodeCount = 0,
    this.error,
  });

  final String url;
  final DateTime addedAt;
  final DateTime? lastFetched;
  final int nodeCount;
  final String? error;

  Subscription copyWith({DateTime? lastFetched, int? nodeCount, String? error}) =>
      Subscription(
        url: url,
        addedAt: addedAt,
        lastFetched: lastFetched ?? this.lastFetched,
        nodeCount: nodeCount ?? this.nodeCount,
        error: error,
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'added': addedAt.toIso8601String(),
        if (lastFetched != null) 'fetched': lastFetched!.toIso8601String(),
        'count': nodeCount,
        if (error != null) 'error': error,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        url: j['url'] as String,
        addedAt: DateTime.tryParse(j['added']?.toString() ?? '') ?? DateTime.now(),
        lastFetched: DateTime.tryParse(j['fetched']?.toString() ?? ''),
        nodeCount: (j['count'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
      );
}

/// A user-made collection of nodes (ТЗ: «свои подборки»). Stores node ids;
/// resolved against the live pool when selected. Auto-generated collections
/// (`id` starts with `auto:`) are computed at runtime and never persisted.
@immutable
class KeyBundle {
  const KeyBundle({
    required this.id,
    required this.name,
    required this.nodeIds,
    this.createdAt,
  });

  final String id;
  final String name;
  final List<String> nodeIds;
  final DateTime? createdAt;

  bool get isAuto => id.startsWith('auto:');

  KeyBundle copyWith({String? name, List<String>? nodeIds}) => KeyBundle(
        id: id,
        name: name ?? this.name,
        nodeIds: nodeIds ?? this.nodeIds,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'nodes': nodeIds,
        if (createdAt != null) 'created': createdAt!.toIso8601String(),
      };

  factory KeyBundle.fromJson(Map<String, dynamic> j) => KeyBundle(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? 'Подборка').toString(),
        nodeIds: [
          for (final n in (j['nodes'] as List<dynamic>? ?? const []))
            n.toString(),
        ],
        createdAt: DateTime.tryParse(j['created']?.toString() ?? ''),
      );
}

/// Persists custom keys and subscription URLs in the OS secure store.
class CustomKeysRepository {
  CustomKeysRepository([FlutterSecureStorage? store])
      : _store = store ?? const FlutterSecureStorage();

  final FlutterSecureStorage _store;
  static const _kKeys = 'weronity.custom.keys.v1';
  static const _kSubs = 'weronity.custom.subs.v1';
  static const _kBundles = 'weronity.custom.bundles.v1';

  Future<List<CustomKey>> loadKeys() => _load(_kKeys, CustomKey.fromJson);
  Future<List<Subscription>> loadSubs() => _load(_kSubs, Subscription.fromJson);
  Future<List<KeyBundle>> loadBundles() => _load(_kBundles, KeyBundle.fromJson);

  Future<void> saveKeys(List<CustomKey> keys) => _save(_kKeys, keys.map((e) => e.toJson()));
  Future<void> saveSubs(List<Subscription> subs) => _save(_kSubs, subs.map((e) => e.toJson()));
  Future<void> saveBundles(List<KeyBundle> b) =>
      _save(_kBundles, b.map((e) => e.toJson()));

  Future<List<T>> _load<T>(String key, T Function(Map<String, dynamic>) from) async {
    final raw = await _readSafe(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map<String, dynamic>) from(e),
      ];
    } catch (e) {
      debugPrint('CustomKeysRepository: corrupt "$key" ($e)');
      return [];
    }
  }

  Future<void> _save(String key, Iterable<Map<String, dynamic>> data) async {
    try {
      await _store.write(key: key, value: jsonEncode(data.toList()));
    } catch (e) {
      debugPrint('CustomKeysRepository: write "$key" failed ($e)');
    }
  }

  Future<String?> _readSafe(String key) async {
    try {
      return await _store.read(key: key);
    } catch (e) {
      debugPrint('CustomKeysRepository: read "$key" failed ($e)');
      return null;
    }
  }
}
