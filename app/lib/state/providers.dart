import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../core/connection_controller.dart';
import '../data/node_filter.dart';
import '../data/pool_repository.dart';
import '../data/settings_repository.dart';
import '../domain/node.dart';
import 'custom_keys.dart';

/// Hive boxes — opened in `main()` and injected via [ProviderScope.overrides].
final poolCacheBoxProvider = Provider<Box<String>>(
  (ref) => throw UnimplementedError('override poolCacheBoxProvider in main()'),
);
final settingsBoxProvider = Provider<Box<dynamic>>(
  (ref) => throw UnimplementedError('override settingsBoxProvider in main()'),
);

final poolRepositoryProvider = Provider<PoolRepository>((ref) {
  final repo = PoolRepository(cacheBox: ref.watch(poolCacheBoxProvider));
  final override = ref.watch(settingsProvider).poolUrlOverride;
  if (override != null && override.trim().isNotEmpty) {
    repo.poolUrl = override.trim();
  }
  ref.onDispose(repo.dispose);
  return repo;
});

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(settingsBoxProvider)),
);

// --- settings ---------------------------------------------------------------

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() => ref.read(settingsRepositoryProvider).load();

  Future<void> _mutate(Settings next) async {
    state = next;
    await ref.read(settingsRepositoryProvider).save(next);
  }

  Future<void> setProMode(bool v) => _mutate(state.copyWith(proMode: v));
  Future<void> setThemeMode(ThemeMode v) => _mutate(state.copyWith(themeMode: v));
  Future<void> setRoutingMode(RoutingMode v) =>
      _mutate(state.copyWith(routingMode: v));
  Future<void> setAdBlock(bool v) => _mutate(state.copyWith(adBlock: v));
  Future<void> setAutoConnectLastNode(bool v) =>
      _mutate(state.copyWith(autoConnectLastNode: v));
  Future<void> setPoolUrlOverride(String? v) =>
      _mutate(state.copyWith(poolUrlOverride: () => v));
  Future<void> setPreflightEndpoints(List<String> v) =>
      _mutate(state.copyWith(preflightEndpoints: v));
  Future<void> rememberLastGoodNode(String? id) =>
      _mutate(state.copyWith(lastGoodNodeId: () => id));
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

// --- pool ------------------------------------------------------------------

class PoolNotifier extends AsyncNotifier<PoolSnapshot> {
  @override
  Future<PoolSnapshot> build() => ref.watch(poolRepositoryProvider).loadLocal();

  Future<void> refresh() async {
    state = const AsyncLoading<PoolSnapshot>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(poolRepositoryProvider).refresh(),
    );
  }
}

final poolProvider =
    AsyncNotifierProvider<PoolNotifier, PoolSnapshot>(PoolNotifier.new);

/// All selectable nodes: crowd-sourced pool + user's custom keys / subscriptions.
final nodesProvider = Provider<List<Node>>((ref) {
  final pool = ref.watch(poolProvider).valueOrNull?.pool.nodes ?? const <Node>[];
  final custom = ref.watch(customNodesProvider);
  if (custom.isEmpty) return pool;
  final byId = {for (final n in pool) n.id: n};
  for (final n in custom) {
    byId.putIfAbsent(n.id, () => n);
  }
  return byId.values.toList();
});

// --- filtering -----------------------------------------------------------

class FilterNotifier extends Notifier<NodeFilter> {
  @override
  NodeFilter build() => const NodeFilter();

  void set(NodeFilter f) => state = f;
  void reset() => state = const NodeFilter();
  void update(NodeFilter Function(NodeFilter) f) => state = f(state);
}

final filterProvider =
    NotifierProvider<FilterNotifier, NodeFilter>(FilterNotifier.new);

final filteredNodesProvider = Provider<List<Node>>((ref) {
  final filter = ref.watch(filterProvider);
  return filter.apply(ref.watch(nodesProvider));
});

final countryOptionsProvider = Provider<List<CountryOption>>(
  (ref) => CountryOption.from(ref.watch(nodesProvider)),
);

// --- connection --------------------------------------------------------

// ChangeNotifierProvider disposes the notifier itself — no manual ref.onDispose.
final connectionControllerProvider =
    ChangeNotifierProvider<ConnectionController>((ref) => ConnectionController());

/// Resolves a [Selection] to a concrete node against the current pool:
/// an explicit node as-is; otherwise the lowest-ping recommended node in the
/// chosen country (or globally for "⚡ Авто"). Session-priority for a previously
/// used node is Phase 4.
final resolveSelectionProvider = Provider<Node? Function(Selection)>((ref) {
  final nodes = ref.watch(nodesProvider);
  return (sel) {
    if (sel.node != null) return sel.node;

    Iterable<Node> pool = nodes.where((n) => n.health.alive);
    if (sel.countryCode != null) {
      pool = pool.where((n) => n.countryCode == sel.countryCode);
    }
    final recommended = pool.where((n) => n.recommended);
    return pickLowestPing(recommended.isNotEmpty ? recommended : pool);
  };
});
