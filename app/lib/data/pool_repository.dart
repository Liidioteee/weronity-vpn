import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import '../domain/node.dart';

/// Where the pool came from — surfaced in the UI so the user knows how fresh it is.
enum PoolOrigin { bundledAsset, cache, network }

class PoolSnapshot {
  const PoolSnapshot({
    required this.pool,
    required this.origin,
    required this.fetchedAt,
  });

  final NodePool pool;
  final PoolOrigin origin;
  final DateTime fetchedAt;

  static final empty = PoolSnapshot(
    pool: NodePool.empty,
    origin: PoolOrigin.bundledAsset,
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Loads `nodes_pool.json` from (in order of preference) the network, the local
/// Hive cache, or the bundled asset. Custom user keys are merged in by a higher
/// layer; this repository only owns the crowd-sourced pool.
class PoolRepository {
  PoolRepository({
    required Box<String> cacheBox,
    http.Client? client,
    this.poolUrl = _defaultPoolUrl,
    this.assetPath = 'assets/pool/nodes_pool.sample.json',
  })  : _cache = cacheBox,
        _client = client ?? http.Client();

  static const _defaultPoolUrl =
      'https://raw.githubusercontent.com/Liidioteee/weronity-vpn/pool-data/nodes_pool.json';
  static const _cacheKey = 'pool.json';
  static const _cacheAtKey = 'pool.fetchedAt';

  final Box<String> _cache;
  final http.Client _client;

  /// Overridable in Pro mode ("кастомный источник пула").
  String poolUrl;
  final String assetPath;

  /// Best-effort load without hitting the network: cache, else bundled asset.
  Future<PoolSnapshot> loadLocal() async {
    final cached = _cache.get(_cacheKey);
    if (cached != null) {
      try {
        return PoolSnapshot(
          pool: NodePool.decode(cached),
          origin: PoolOrigin.cache,
          fetchedAt: DateTime.tryParse(_cache.get(_cacheAtKey) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        );
      } catch (e) {
        debugPrint('PoolRepository: corrupt cache, falling back to asset: $e');
      }
    }
    final asset = await rootBundle.loadString(assetPath);
    return PoolSnapshot(
      pool: NodePool.decode(asset),
      origin: PoolOrigin.bundledAsset,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Fetch a fresh pool from [poolUrl]; on any failure returns [loadLocal].
  Future<PoolSnapshot> refresh() async {
    try {
      final res = await _client
          .get(Uri.parse(poolUrl))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw http.ClientException('HTTP ${res.statusCode}');
      }
      final body = utf8.decode(res.bodyBytes);
      final pool = NodePool.decode(body); // validates shape before caching
      final now = DateTime.now();
      await _cache.put(_cacheKey, body);
      await _cache.put(_cacheAtKey, now.toIso8601String());
      return PoolSnapshot(pool: pool, origin: PoolOrigin.network, fetchedAt: now);
    } catch (e) {
      debugPrint('PoolRepository.refresh failed ($poolUrl): $e');
      return loadLocal();
    }
  }

  void dispose() => _client.close();
}
