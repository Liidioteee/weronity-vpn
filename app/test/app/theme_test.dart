import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/app/theme/app_theme.dart';
import 'package:weronity/app/theme/tokens.dart';

void main() {
  test('dark theme is Material 3, dark, violet-accented', () {
    final t = AppTheme.dark;
    expect(t.useMaterial3, isTrue);
    expect(t.brightness, Brightness.dark);
    expect(t.colorScheme.primary, WColors.violet);
    expect(t.scaffoldBackgroundColor, WColors.bgDark);
    expect(t.textTheme.bodyMedium?.fontFamily, 'Inter');
  });

  test('light theme mirrors the roles', () {
    final t = AppTheme.light;
    expect(t.brightness, Brightness.light);
    expect(t.colorScheme.primary, WColors.violet);
    expect(t.scaffoldBackgroundColor, WColors.bgLight);
  });

  test('status tokens are distinct', () {
    final colors = {
      WColors.protected,
      WColors.connecting,
      WColors.danger,
      WColors.info,
    };
    expect(colors, hasLength(4));
  });
}
