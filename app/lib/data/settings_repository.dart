import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

enum RoutingMode {
  smart,
  global,
  splitTunnel;

  String get label => switch (this) {
        RoutingMode.smart => 'Умный',
        RoutingMode.global => 'Глобальный',
        RoutingMode.splitTunnel => 'По приложениям',
      };
}

/// How the tunnel is exposed to the OS.
enum ConnectionMode {
  /// A local SOCKS/HTTP proxy on `127.0.0.1:<proxyPort>`. Point apps at it.
  proxy,

  /// System-wide capture via a TUN device. Needs admin rights (Phase 3.3).
  vpn;

  String get label => switch (this) {
        ConnectionMode.proxy => 'Прокси',
        ConnectionMode.vpn => 'VPN (TUN)',
      };

  String get wire => name;

  static ConnectionMode parse(Object? v) =>
      v == 'vpn' || v == 1 ? ConnectionMode.vpn : ConnectionMode.proxy;
}

/// What the window's close button does on desktop.
enum WindowCloseAction {
  ask,
  tray,
  quit;

  String get label => switch (this) {
        WindowCloseAction.ask => 'Спрашивать',
        WindowCloseAction.tray => 'В трей',
        WindowCloseAction.quit => 'Выходить',
      };

  static WindowCloseAction parse(Object? v) => switch ('$v') {
        'tray' || '1' => WindowCloseAction.tray,
        'quit' || '2' => WindowCloseAction.quit,
        _ => WindowCloseAction.ask,
      };
}

/// Custom routing buckets edited in Pro mode; fed to the sing-box route config
/// in Phase 4.
enum RuleBucket {
  direct,
  proxy,
  block;

  String get label => switch (this) {
        RuleBucket.direct => 'Напрямую',
        RuleBucket.proxy => 'Через VPN',
        RuleBucket.block => 'Блокировать',
      };

  String get hint => switch (this) {
        RuleBucket.direct => 'Домены в обход туннеля',
        RuleBucket.proxy => 'Домены всегда через туннель',
        RuleBucket.block => 'Домены, которым отвечаем отказом',
      };
}

/// Plain settings snapshot. Persisted key-by-key in a Hive box.
@immutable
class Settings {
  const Settings({
    this.proMode = false,
    this.themeMode = ThemeMode.dark,
    this.routingMode = RoutingMode.smart,
    this.adBlock = false,
    this.autoConnectLastNode = true,
    this.poolUrlOverride,
    this.preflightEndpoints = defaultPreflightEndpoints,
    this.lastGoodNodeId,
    this.directRules = const [],
    this.proxyRules = const [],
    this.blockRules = const [],
    this.connectionMode = ConnectionMode.proxy,
    this.proxyPort = 55555,
    this.strictRoute = false,
    this.closeAction = WindowCloseAction.ask,
    this.checkConcurrency = 8,
    this.checkTimeoutMs = 4000,
    this.autoCheck = true,
    this.autoSwitch = true,
  });

  final bool proMode;
  final ThemeMode themeMode;
  final RoutingMode routingMode;
  final bool adBlock;
  final bool autoConnectLastNode;
  final String? poolUrlOverride;
  final List<String> preflightEndpoints;
  final String? lastGoodNodeId;
  final List<String> directRules;
  final List<String> proxyRules;
  final List<String> blockRules;
  final ConnectionMode connectionMode;
  final int proxyPort;

  /// VPN mode only: sing-box `strict_route` on the tun inbound. Closes the leak
  /// paths `auto_route` leaves open, at the cost of being the setting most
  /// likely to strand a machine whose routing is already owned by something
  /// else — so it is off by default and the UI warns about it.
  final bool strictRoute;

  final WindowCloseAction closeAction;

  /// Node-check tuning. `checkConcurrency` — how many nodes are probed at once
  /// during a manual "Проверить видимые" sweep (1–20). `checkTimeoutMs` — a
  /// probe that gets no answer within this is called dead.
  final int checkConcurrency;
  final int checkTimeoutMs;

  /// Keep checking nodes (and the live connection) in the background, gently.
  final bool autoCheck;

  /// When connected and the active node stops responding, switch to the best
  /// live alternative (same country first) automatically.
  final bool autoSwitch;

  List<String> rules(RuleBucket bucket) => switch (bucket) {
        RuleBucket.direct => directRules,
        RuleBucket.proxy => proxyRules,
        RuleBucket.block => blockRules,
      };

  /// Keep the service URLs here in sync with `state/bundles.dart`
  /// `kBlockedServices` — preflight collects a per-URL result and the
  /// auto-bundles ("Лучшие для YouTube" …) match on it.
  static const defaultPreflightEndpoints = <String>[
    'https://www.google.com/generate_204', // generic connectivity
    'https://www.youtube.com/favicon.ico',
    'https://www.instagram.com/favicon.ico',
    'https://x.com/favicon.ico',
    'https://www.facebook.com/favicon.ico',
    'https://discord.com/assets/favicon.ico',
    'https://signal.org/favicon.ico',
  ];

  Settings copyWith({
    bool? proMode,
    ThemeMode? themeMode,
    RoutingMode? routingMode,
    bool? adBlock,
    bool? autoConnectLastNode,
    String? Function()? poolUrlOverride,
    List<String>? preflightEndpoints,
    String? Function()? lastGoodNodeId,
    List<String>? directRules,
    List<String>? proxyRules,
    List<String>? blockRules,
    ConnectionMode? connectionMode,
    int? proxyPort,
    bool? strictRoute,
    WindowCloseAction? closeAction,
    int? checkConcurrency,
    int? checkTimeoutMs,
    bool? autoCheck,
    bool? autoSwitch,
  }) =>
      Settings(
        proMode: proMode ?? this.proMode,
        themeMode: themeMode ?? this.themeMode,
        routingMode: routingMode ?? this.routingMode,
        adBlock: adBlock ?? this.adBlock,
        autoConnectLastNode: autoConnectLastNode ?? this.autoConnectLastNode,
        poolUrlOverride: poolUrlOverride != null
            ? poolUrlOverride()
            : this.poolUrlOverride,
        preflightEndpoints: preflightEndpoints ?? this.preflightEndpoints,
        lastGoodNodeId:
            lastGoodNodeId != null ? lastGoodNodeId() : this.lastGoodNodeId,
        directRules: directRules ?? this.directRules,
        proxyRules: proxyRules ?? this.proxyRules,
        blockRules: blockRules ?? this.blockRules,
        connectionMode: connectionMode ?? this.connectionMode,
        proxyPort: proxyPort ?? this.proxyPort,
        strictRoute: strictRoute ?? this.strictRoute,
        closeAction: closeAction ?? this.closeAction,
        checkConcurrency: checkConcurrency ?? this.checkConcurrency,
        checkTimeoutMs: checkTimeoutMs ?? this.checkTimeoutMs,
        autoCheck: autoCheck ?? this.autoCheck,
        autoSwitch: autoSwitch ?? this.autoSwitch,
      );

  Settings withRules(RuleBucket bucket, List<String> value) => switch (bucket) {
        RuleBucket.direct => copyWith(directRules: value),
        RuleBucket.proxy => copyWith(proxyRules: value),
        RuleBucket.block => copyWith(blockRules: value),
      };
}

class SettingsRepository {
  SettingsRepository(this._box);

  final Box<dynamic> _box;

  // Tolerant readers: a value of the wrong type (a damaged box, a newer build's
  // format) falls back to the default instead of throwing — settings are read
  // at startup, and a throw there means the app does not start at all.
  bool _bool(String key, bool fallback) {
    final v = _box.get(key);
    return v is bool ? v : fallback;
  }

  int _int(String key, int fallback) {
    final v = _box.get(key);
    return v is num ? v.toInt() : fallback;
  }

  String? _string(String key) {
    final v = _box.get(key);
    return v is String ? v : null;
  }

  E _enum<E>(List<E> values, String key, E fallback) {
    final v = _box.get(key);
    return v is int && v >= 0 && v < values.length ? values[v] : fallback;
  }

  List<String>? _listOrNull(String key) {
    final v = _box.get(key);
    return v is List ? [for (final e in v) if (e is String) e] : null;
  }

  List<String> _list(String key) => _listOrNull(key) ?? const [];

  Settings load() => Settings(
        proMode: _bool('proMode', false),
        themeMode: _enum(ThemeMode.values, 'themeMode', ThemeMode.dark),
        routingMode: _enum(RoutingMode.values, 'routingMode', RoutingMode.smart),
        adBlock: _bool('adBlock', false),
        autoConnectLastNode: _bool('autoConnectLastNode', true),
        poolUrlOverride: _string('poolUrlOverride'),
        preflightEndpoints: _listOrNull('preflightEndpoints') ??
            Settings.defaultPreflightEndpoints,
        lastGoodNodeId: _string('lastGoodNodeId'),
        directRules: _list('directRules'),
        proxyRules: _list('proxyRules'),
        blockRules: _list('blockRules'),
        connectionMode: ConnectionMode.parse(_box.get('connectionMode')),
        proxyPort: _int('proxyPort', 55555).clamp(1024, 65535),
        strictRoute: _bool('strictRoute', false),
        closeAction: WindowCloseAction.parse(_box.get('closeAction')),
        checkConcurrency: _int('checkConcurrency', 8).clamp(1, 20),
        checkTimeoutMs: _int('checkTimeoutMs', 4000).clamp(1000, 15000),
        autoCheck: _bool('autoCheck', true),
        autoSwitch: _bool('autoSwitch', true),
      );

  Future<void> save(Settings s) async {
    await _box.putAll({
      'proMode': s.proMode,
      'themeMode': s.themeMode.index,
      'routingMode': s.routingMode.index,
      'adBlock': s.adBlock,
      'autoConnectLastNode': s.autoConnectLastNode,
      'poolUrlOverride': s.poolUrlOverride,
      'preflightEndpoints': s.preflightEndpoints,
      'lastGoodNodeId': s.lastGoodNodeId,
      'directRules': s.directRules,
      'proxyRules': s.proxyRules,
      'blockRules': s.blockRules,
      'connectionMode': s.connectionMode.index,
      'proxyPort': s.proxyPort,
      'strictRoute': s.strictRoute,
      'closeAction': s.closeAction.name,
      'checkConcurrency': s.checkConcurrency,
      'checkTimeoutMs': s.checkTimeoutMs,
      'autoCheck': s.autoCheck,
      'autoSwitch': s.autoSwitch,
    });
  }
}
