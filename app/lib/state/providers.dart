import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../core/connection_controller.dart';
import '../core/log_controller.dart';
import '../core/native/native_core.dart';
import '../core/singbox_bridge.dart';
import '../data/node_filter.dart';
import '../data/pool_repository.dart';
import '../data/settings_repository.dart';
import '../domain/node.dart';
import 'bundles.dart';
import 'candidates.dart';
import 'custom_keys.dart';
import 'exit_geo.dart';

/// Hive boxes — opened in `main()` and injected via [ProviderScope.overrides].
final poolCacheBoxProvider = Provider<Box<String>>(
  (ref) => throw UnimplementedError('override poolCacheBoxProvider in main()'),
);
final settingsBoxProvider = Provider<Box<dynamic>>(
  (ref) => throw UnimplementedError('override settingsBoxProvider in main()'),
);

/// Session state that must survive a restart: cached node-check results, the
/// last selected location/bundle.
final sessionBoxProvider = Provider<Box<dynamic>>(
  (ref) => throw UnimplementedError('override sessionBoxProvider in main()'),
);

final poolRepositoryProvider = Provider<PoolRepository>((ref) {
  final repo = PoolRepository(cacheBox: ref.watch(poolCacheBoxProvider));
  // select(): only the URL may rebuild the repository. Watching the whole
  // settings object re-parsed the pool on every unrelated toggle.
  final override =
      ref.watch(settingsProvider.select((s) => s.poolUrlOverride));
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
  Future<void> setRules(RuleBucket bucket, List<String> v) =>
      _mutate(state.withRules(bucket, v));
  Future<void> setConnectionMode(ConnectionMode v) =>
      _mutate(state.copyWith(connectionMode: v));
  Future<void> setProxyPort(int v) =>
      _mutate(state.copyWith(proxyPort: v.clamp(1024, 65535)));
  Future<void> setStrictRoute(bool v) =>
      _mutate(state.copyWith(strictRoute: v));
  Future<void> setCloseAction(WindowCloseAction v) =>
      _mutate(state.copyWith(closeAction: v));
  Future<void> setCheckConcurrency(int v) =>
      _mutate(state.copyWith(checkConcurrency: v.clamp(1, 20)));
  Future<void> setCheckTimeoutMs(int v) =>
      _mutate(state.copyWith(checkTimeoutMs: v.clamp(1000, 15000)));
  Future<void> setAutoCheck(bool v) => _mutate(state.copyWith(autoCheck: v));
  Future<void> setAutoSwitch(bool v) => _mutate(state.copyWith(autoSwitch: v));
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

/// Keeps the pool fresh in the background: one refresh shortly after start, then
/// every 30 minutes. Kept alive by a `ref.watch` at the app root.
final poolPollingProvider = Provider<void>((ref) {
  final kickoff = Timer(
    const Duration(seconds: 3),
    () => ref.read(poolProvider.notifier).refresh(),
  );
  final periodic = Timer.periodic(
    const Duration(minutes: 30),
    (_) => ref.read(poolProvider.notifier).refresh(),
  );
  ref.onDispose(() {
    kickoff.cancel();
    periodic.cancel();
  });
});

/// Crowd-sourced pool + user's custom keys / subscriptions, as listed — each
/// node still carries the country its source claimed.
final _listedNodesProvider = Provider<List<Node>>((ref) {
  final pool = ref.watch(poolProvider).valueOrNull?.pool.nodes ?? const <Node>[];
  final custom = ref.watch(customNodesProvider);
  if (custom.isEmpty) return pool;
  final byId = {for (final n in pool) n.id: n};
  for (final n in custom) {
    byId.putIfAbsent(n.id, () => n);
  }
  return byId.values.toList();
});

/// All selectable nodes. Where a check has seen which country a node really
/// exits in ([exitGeoProvider]), that replaces the listed country — so the
/// country picker, the filters, the selection and failover all work with where
/// the traffic actually comes out.
final nodesProvider = Provider<List<Node>>((ref) {
  final listed = ref.watch(_listedNodesProvider);
  final exits = ref.watch(exitGeoProvider);
  if (exits.isEmpty) return listed;
  return [for (final n in listed) withExitCountry(n, exits[n.id])];
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
final logControllerProvider =
    ChangeNotifierProvider<LogController>((ref) => LogController());

/// The active connection engine: the real sing-box bridge when the native core
/// loaded. Without it a release build gets [UnavailableEngine], which refuses to
/// connect; only a debug build falls back to the demo [ConnectionController]
/// (and the home screen says so).
final connectionControllerProvider = ChangeNotifierProvider<ConnectionEngine>(
  (ref) {
    void log(String level, String tag, String message) =>
        ref.read(logControllerProvider).add(level, tag, message);

    final core = ref.watch(nativeCoreProvider);
    if (core.isAvailable) {
      return SingBoxBridge(
        core: core,
        modeOf: () => ref.read(settingsProvider).connectionMode,
        portOf: () => ref.read(settingsProvider).proxyPort,
        strictRouteOf: () => ref.read(settingsProvider).strictRoute,
        // read (not watch): the pool refreshes every 30 min and must never
        // rebuild the engine — the backups are only needed at connect time.
        backupsFor: (primary) => ref.read(backupCandidatesProvider)(primary),
        onLog: log,
      );
    }
    if (kDebugMode) return ConnectionController(onLog: log);
    return UnavailableEngine(reason: core.loadError, onLog: log);
  },
);

/// Loads the Go/cgo FFI core once and reports the outcome into the log stream.
final nativeCoreProvider = Provider<NativeCore>((ref) {
  final core = NativeCore.instance();
  final log = ref.read(logControllerProvider);
  // Defer: a provider must not notify another provider during its own init.
  Future.microtask(() {
    switch (core.state) {
      case NativeCoreState.ok:
        log.add('info', 'ffi', 'нативное ядро загружено: ${core.version()}');
        log.add('debug', 'ffi', 'ffi smoke: ping(41) = ${core.ping(41)}');
      case NativeCoreState.unavailable:
        log.add('warn', 'ffi',
            'нативное ядро не загрузилось (${core.loadError ?? "?"})');
      case NativeCoreState.unsupported:
        log.add(
            'info', 'ffi', 'нативное ядро для этой платформы пока не собрано');
    }
  });
  return core;
});

// --- session persistence ---------------------------------------------

Map<String, dynamic> selectionToJson(Selection s) {
  if (s.isAuto) return const {'k': 'auto'};
  if (s.bundleId != null) return {'k': 'bundle', 'v': s.bundleId};
  if (s.countryCode != null) return {'k': 'country', 'v': s.countryCode};
  if (s.node != null) return {'k': 'node', 'v': s.node!.id};
  return const {'k': 'auto'};
}

Selection selectionFromJson(Object? raw, List<Node> nodes) {
  if (raw is! Map) return const Selection.auto();
  final v = '${raw['v'] ?? ''}';
  switch ('${raw['k']}') {
    case 'country':
      return v.isEmpty ? const Selection.auto() : Selection.country(v);
    case 'bundle':
      return v.isEmpty ? const Selection.auto() : Selection.bundle(v);
    case 'node':
      for (final n in nodes) {
        if (n.id == v) return Selection.node(n);
      }
      return const Selection.auto();
    default:
      return const Selection.auto();
  }
}

/// "Already restored" is a fact about *this run* of the app, so it lives in
/// memory. (It used to be written into the persistent session box, which made
/// the restore work exactly once per installation.)
class _RestoreOnce {
  bool done = false;
}

final _restoreOnceProvider = Provider<_RestoreOnce>((ref) => _RestoreOnce());

/// Re-applies the location/bundle the user had chosen last session, once the
/// pool is loaded. Watched once at the app root.
final sessionRestoreProvider = Provider<void>((ref) {
  final nodes = ref.watch(nodesProvider);
  if (nodes.isEmpty) return;
  final once = ref.read(_restoreOnceProvider);
  if (once.done) return;
  once.done = true;

  final box = ref.read(sessionBoxProvider);
  // Left behind by older builds; harmless, but no reason to keep it.
  if (box.get('selection.restored') != null) box.delete('selection.restored');
  final saved = selectionFromJson(box.get('selection'), nodes);
  if (saved.isAuto) return;

  Future.microtask(() {
    final controller = ref.read(connectionControllerProvider);
    if (controller.selection.isAuto && !controller.isActive) {
      controller.select(saved, ref.read(resolveSelectionProvider));
    }
  });
});

/// Backups preloaded into the selector group next to the chosen node, so a
/// later switch is a hot-swap rather than a reconnect. See `backupCandidates`.
final backupCandidatesProvider = Provider<List<Node> Function(Node)>((ref) {
  final nodes = ref.watch(nodesProvider);
  return (primary) => backupCandidates(
        primary,
        nodes,
        limit: SingBoxBridge.maxCandidates - 1,
      );
});

/// Resolves a [Selection] to a concrete node against the current pool:
/// an explicit node as-is; otherwise the lowest-ping recommended node in the
/// chosen country (or globally for "⚡ Авто"). The verified pick and the
/// "last good node" preference sit on top of this — see `connectPickProvider`.
final resolveSelectionProvider = Provider<Node? Function(Selection)>((ref) {
  final nodes = ref.watch(nodesProvider);
  final bundles = ref.watch(allBundlesProvider);
  return (sel) {
    if (sel.node != null) return sel.node;

    if (sel.bundleId != null) {
      for (final b in bundles) {
        if (b.id != sel.bundleId) continue;
        final live = bundleLiveNodes(b, nodes);
        return live.isEmpty ? null : live.first;
      }
      return null;
    }

    Iterable<Node> pool = nodes.where((n) => n.health.alive);
    if (sel.countryCode != null) {
      pool = pool.where((n) => n.countryCode == sel.countryCode);
    }
    // An automatic choice avoids nodes whose hop is not properly encrypted
    // unless nothing else is alive.
    pool = preferSecure(pool);
    final recommended = pool.where((n) => n.recommended);
    return pickLowestPing(recommended.isNotEmpty ? recommended : pool);
  };
});
