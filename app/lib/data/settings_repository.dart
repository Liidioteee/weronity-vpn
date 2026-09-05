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
  });

  final bool proMode;
  final ThemeMode themeMode;
  final RoutingMode routingMode;
  final bool adBlock;
  final bool autoConnectLastNode;
  final String? poolUrlOverride;
  final List<String> preflightEndpoints;
  final String? lastGoodNodeId;

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
      );
}

class SettingsRepository {
  SettingsRepository(this._box);

  final Box<dynamic> _box;

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
    });
  }
}
