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

/// Persists custom keys and subscription URLs in the OS secure store.
class CustomKeysRepository {
  CustomKeysRepository([FlutterSecureStorage? store])
      : _store = store ?? const FlutterSecureStorage();

  final FlutterSecureStorage _store;
  static const _kKeys = 'weronity.custom.keys.v1';
  static const _kSubs = 'weronity.custom.subs.v1';

  Future<List<CustomKey>> loadKeys() => _load(_kKeys, CustomKey.fromJson);
  Future<List<Subscription>> loadSubs() => _load(_kSubs, Subscription.fromJson);

  Future<void> saveKeys(List<CustomKey> keys) => _save(_kKeys, keys.map((e) => e.toJson()));
  Future<void> saveSubs(List<Subscription> subs) => _save(_kSubs, subs.map((e) => e.toJson()));

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
