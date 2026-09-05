import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../domain/country_names.dart';
import 'flag.dart';

/// The central connect/disconnect control.
///
/// * disconnected → violet outline ring
/// * connecting   → amber pulsing ring
/// * protected    → green glow; the ring is filled with the active country's
///   flag when known, otherwise a solid green disc
/// * switching    → a thin accent arc sweeps around the ring while the active
///   node is being hot-swapped
class PowerButton extends StatefulWidget {
  const PowerButton({
    required this.status,
    required this.onTap,
    this.flagCode,
    this.switching = false,
    this.size = 200,
    super.key,
  });

  final ConnectionStatus status;
  final VoidCallback onTap;
  final String? flagCode;
  final bool switching;
  final double size;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: WDur.pulse);

  bool get _wantsAnimation =>
      widget.status == ConnectionStatus.connecting ||
      widget.status == ConnectionStatus.protected ||
      widget.switching;

  @override
  void initState() {
    super.initState();
    if (_wantsAnimation) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant PowerButton old) {
    super.didUpdateWidget(old);
    if (_wantsAnimation && !_c.isAnimating) {
      _c.repeat();
    } else if (!_wantsAnimation && _c.isAnimating) {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _accent => switch (widget.status) {
        ConnectionStatus.protected => WColors.protected,
        ConnectionStatus.connecting => WColors.connecting,
        ConnectionStatus.error => WColors.danger,
        ConnectionStatus.disconnected => WColors.violet,
      };

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final protected = widget.status == ConnectionStatus.protected;
    final showFlag = protected && isKnownCountry(widget.flagCode);
    final ringR = size / 2 * 0.82;
    final flagD = (ringR - 4) * 2;

    return Semantics(
      button: true,
      label: widget.status.label,
      child: GestureDetector(
        key: const Key('powerButton'),
        onTap: widget.onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: _accent),
            duration: WDur.slow,
            curve: WCurves.enter,
            builder: (context, tweenedAccent, _) {
              final accent = tweenedAccent ?? _accent;
              return AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final t = _c.value;
                  final connecting =
                      widget.status == ConnectionStatus.connecting;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: Size.square(size),
                        painter: _PowerPainter(
                          accent: accent,
                          pulse: connecting ? t : 0,
                          glow: protected
                              ? (0.5 + 0.5 * math.sin(t * 2 * math.pi))
                              : 0,
                          sweep: widget.switching ? t : -1,
                          filled: protected && !showFlag,
                        ),
                      ),
                      if (showFlag)
                        SizedBox(
                          width: flagD,
                          height: flagD,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AnimatedSwitcher(
                                duration: WDur.slow,
                                switchInCurve: WCurves.enter,
                                transitionBuilder: (child, anim) =>
                                    FadeTransition(
                                  opacity: anim,
                                  child: ScaleTransition(
                                    scale: Tween<double>(begin: 0.85, end: 1)
                                        .animate(anim),
                                    child: child,
                                  ),
                                ),
                                child: FlagFill(
                                  widget.flagCode,
                                  diameter: flagD,
                                  key: ValueKey(widget.flagCode),
                                ),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      Colors.black.withValues(alpha: 0.05),
                                      Colors.black.withValues(alpha: 0.45),
                                    ],
                                    stops: const [0.55, 1],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      AnimatedSwitcher(
                        duration: WDur.normal,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.7, end: 1)
                                .animate(anim),
                            child: child,
                          ),
                        ),
                        child: Icon(
                          protected
                              ? Icons.shield_rounded
                              : Icons.power_settings_new_rounded,
                          key: ValueKey('$protected-$showFlag'),
                          size: size * 0.26,
                          color: showFlag
                              ? Colors.white
                              : (protected ? WColors.bgDark : accent),
                          shadows: showFlag
                              ? const [
                                  Shadow(blurRadius: 12, color: Colors.black87),
                                ]
                              : null,
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PowerPainter extends CustomPainter {
  _PowerPainter({
    required this.accent,
    required this.pulse,
    required this.glow,
    required this.sweep,
    required this.filled,
  });

  final Color accent;
  final double pulse;
  final double glow;

  /// `-1` when idle; otherwise `0..1` phase of the hot-swap sweep arc.
  final double sweep;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final ringR = r * 0.82;

    if (glow > 0 || filled) {
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..color = accent.withValues(alpha: 0.20 + 0.20 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 + 14 * glow),
      );
    }

    if (pulse > 0) {
      canvas.drawCircle(
        center,
        ringR + pulse * r * 0.18,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent.withValues(alpha: (1 - pulse) * 0.5),
      );
    }

    if (filled) {
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..style = PaintingStyle.fill
          ..shader = SweepGradient(
            colors: [accent, accent.withValues(alpha: 0.75), accent],
          ).createShader(Rect.fromCircle(center: center, radius: ringR)),
      );
    }

    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent,
    );

    if (sweep >= 0) {
      final start = sweep * 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringR),
        start,
        math.pi / 3,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.9),
      );
    }

    canvas.drawCircle(
      center,
      ringR - 10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: filled ? 0.0 : 0.25),
    );
  }

  @override
  bool shouldRepaint(covariant _PowerPainter old) =>
      old.pulse != pulse ||
      old.glow != glow ||
      old.sweep != sweep ||
      old.filled != filled ||
      old.accent != accent;
}
