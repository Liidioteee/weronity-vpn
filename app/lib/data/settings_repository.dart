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
    });
  }
}
