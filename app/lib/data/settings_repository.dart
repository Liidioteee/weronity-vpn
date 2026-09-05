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

  List<String> rules(RuleBucket bucket) => switch (bucket) {
        RuleBucket.direct => directRules,
        RuleBucket.proxy => proxyRules,
        RuleBucket.block => blockRules,
      };

  static const defaultPreflightEndpoints = <String>[
    'https://www.google.com/generate_204',
    'https://www.youtube.com/favicon.ico',
    'https://www.instagram.com/favicon.ico',
    'https://x.com/favicon.ico',
    'https://www.bbc.com/favicon.ico',
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

  List<String> _list(String key) =>
      (_box.get(key) as List?)?.cast<String>() ?? const [];

  Settings load() => Settings(
        proMode: _box.get('proMode', defaultValue: false) as bool,
        themeMode: ThemeMode
            .values[_box.get('themeMode', defaultValue: ThemeMode.dark.index) as int],
        routingMode: RoutingMode.values[
            _box.get('routingMode', defaultValue: RoutingMode.smart.index) as int],
        adBlock: _box.get('adBlock', defaultValue: false) as bool,
        autoConnectLastNode:
            _box.get('autoConnectLastNode', defaultValue: true) as bool,
        poolUrlOverride: _box.get('poolUrlOverride') as String?,
        preflightEndpoints:
            (_box.get('preflightEndpoints') as List?)?.cast<String>() ??
                Settings.defaultPreflightEndpoints,
        lastGoodNodeId: _box.get('lastGoodNodeId') as String?,
        directRules: _list('directRules'),
        proxyRules: _list('proxyRules'),
        blockRules: _list('blockRules'),
        connectionMode:
            ConnectionMode.parse(_box.get('connectionMode', defaultValue: 0)),
        proxyPort: (_box.get('proxyPort', defaultValue: 55555) as num).toInt(),
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
    });
  }
}
