import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../domain/country_names.dart';

/// A country flag with a graceful fallback for unknown / missing codes.
class FlagView extends StatelessWidget {
  const FlagView(this.code, {this.size = 28, this.circle = true, super.key});

  final String? code;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    if (!isKnownCountry(code)) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(WRadius.sm),
        ),
        child: Icon(
          Icons.public_rounded,
          size: size * 0.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return CountryFlag.fromCountryCode(
      code!,
      width: size,
      height: size,
      shape: circle ? const Circle() : const RoundedRectangle(WRadius.sm),
    );
  }
}

/// Flag rendered to fill a circle — used as the power-button background while
/// connected. Falls back to a flat accent circle for unknown codes.
class FlagFill extends StatelessWidget {
  const FlagFill(this.code, {required this.diameter, super.key});

  final String? code;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    if (!isKnownCountry(code)) {
      return SizedBox(width: diameter, height: diameter);
    }
    return ClipOval(
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: FittedBox(
          fit: BoxFit.cover,
          child: CountryFlag.fromCountryCode(
            code!,
            width: diameter,
            height: diameter * 0.75, // flags are 4:3; cover crops to the circle
          ),
        ),
      ),
    );
  }
}

/// `🇩🇪 Германия` style pairing, flag first then the Russian name.
class CountryLabel extends StatelessWidget {
  const CountryLabel(
    this.code, {
    this.flagSize = 22,
    this.style,
    this.showCode = false,
    super.key,
  });

  final String? code;
  final double flagSize;
  final TextStyle? style;
  final bool showCode;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FlagView(code, size: flagSize),
        const SizedBox(width: WSpace.sm),
        Flexible(
          child: Text(
            countryNameRu(code),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style ?? Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (showCode && isKnownCountry(code)) ...[
          const SizedBox(width: WSpace.sm),
          Text(
            code!.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
