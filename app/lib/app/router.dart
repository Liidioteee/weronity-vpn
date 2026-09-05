import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/keys/keys_screen.dart';
import '../ui/pro/pro_screen.dart';
import '../ui/settings/settings_screen.dart';
import '../ui/shell/home_shell.dart';
import '../ui/simple/home_screen.dart';
import '../ui/simple/locations_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => HomeShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const HomeScreen(),
              routes: [
                GoRoute(
                  path: 'locations',
                  builder: (context, state) => const LocationsScreen(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/keys',
              builder: (context, state) => const KeysScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/pro',
              builder: (context, state) => const ProScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Tabs shown in the bottom navigation bar. [pro] is only surfaced when the
/// Pro-mode toggle is on (see `HomeShell`).
enum AppTab {
  home(Icons.shield_outlined, Icons.shield_rounded, 'Главная', '/'),
  keys(Icons.vpn_key_outlined, Icons.vpn_key_rounded, 'Ключи', '/keys'),
  settings(Icons.tune_outlined, Icons.tune_rounded, 'Настройки', '/settings'),
  pro(Icons.auto_awesome_outlined, Icons.auto_awesome_rounded, 'Pro', '/pro');

  const AppTab(this.icon, this.activeIcon, this.label, this.location);

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String location;
}
