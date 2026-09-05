import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import 'app/app.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter('weronity');

  final poolBox = await Hive.openBox<String>('pool_cache');
  final settingsBox = await Hive.openBox<dynamic>('settings');

  runApp(
    ProviderScope(
      overrides: [
        poolCacheBoxProvider.overrideWithValue(poolBox),
        settingsBoxProvider.overrideWithValue(settingsBox),
      ],
      child: const WeronityApp(),
    ),
  );
}
