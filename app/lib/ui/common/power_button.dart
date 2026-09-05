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
class PowerButton extends StatefulWidget {
  const PowerButton({
    required this.status,
    required this.onTap,
    this.flagCode,
    this.size = 200,
    super.key,
  });

  final ConnectionStatus status;
  final VoidCallback onTap;
  final String? flagCode;
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
      widget.status == ConnectionStatus.protected;

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
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              final connecting = widget.status == ConnectionStatus.connecting;
              return Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: Size.square(size),
                    painter: _PowerPainter(
                      accent: _accent,
                      pulse: connecting ? t : 0,
                      glow: protected
                          ? (0.5 + 0.5 * math.sin(t * 2 * math.pi))
                          : 0,
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
                            duration: WDur.normal,
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
                    child: Icon(
                      protected
                          ? Icons.shield_rounded
                          : Icons.power_settings_new_rounded,
                      key: ValueKey('$protected-$showFlag'),
                      size: size * 0.26,
                      color: showFlag
                          ? Colors.white
                          : (protected ? WColors.bgDark : _accent),
                      shadows: showFlag
                          ? const [Shadow(blurRadius: 12, color: Colors.black87)]
                          : null,
                    ),
                  ),
                ],
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
    required this.filled,
  });

  final Color accent;
  final double pulse;
  final double glow;
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
      old.filled != filled ||
      old.accent != accent;
}
