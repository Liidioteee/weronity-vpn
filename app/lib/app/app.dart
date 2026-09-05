import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class WeronityApp extends ConsumerWidget {
  const WeronityApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    ref.watch(poolPollingProvider); // background pool refresh
    ref.watch(nativeCoreProvider); // probe the FFI core, log the outcome
    return MaterialApp.router(
      title: 'Weronity',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
