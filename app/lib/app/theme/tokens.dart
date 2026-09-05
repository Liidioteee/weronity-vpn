import 'package:flutter/material.dart';

/// Design tokens for Weronity. Dark-first; the light palette mirrors the roles.
abstract final class WColors {
  // Brand — violet accent.
  static const violet = Color(0xFF8B7CFF);
  static const violetBright = Color(0xFFA79BFF);
  static const violetDeep = Color(0xFF6C4CE0);
  static const violetGlow = Color(0x558B7CFF);

  // Dark surfaces.
  static const bgDark = Color(0xFF0E0E14);
  static const surfaceDark = Color(0xFF16161F);
  static const surfaceHighDark = Color(0xFF1E1E2A);
  static const surfaceInkDark = Color(0xFF262635);
  static const outlineDark = Color(0xFF2E2E3E);

  // Light surfaces.
  static const bgLight = Color(0xFFF6F5FB);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceHighLight = Color(0xFFEDEBF6);
  static const surfaceInkLight = Color(0xFFE3E0F0);
  static const outlineLight = Color(0xFFD8D5E6);

  // Text.
  static const textDark = Color(0xFFEDEDF2);
  static const textMutedDark = Color(0xFF9A9AAE);
  static const textLight = Color(0xFF1A1A22);
  static const textMutedLight = Color(0xFF63637A);

  // Status.
  static const protected = Color(0xFF3DDC97);
  static const connecting = Color(0xFFF5B94D);
  static const danger = Color(0xFFFF6B8B);
  static const info = Color(0xFF5AC8FA);
}

abstract final class WSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

abstract final class WRadius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const pill = 999.0;

  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
}

abstract final class WDur {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 480);
  static const pulse = Duration(milliseconds: 1800);
}
