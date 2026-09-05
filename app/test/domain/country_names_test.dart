import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/domain/country_names.dart';

void main() {
  test('resolves common codes to Russian names', () {
    expect(countryNameRu('DE'), 'Германия');
    expect(countryNameRu('de'), 'Германия');
    expect(countryNameRu('US'), 'США');
    expect(countryNameRu('GB'), 'Великобритания');
    expect(countryNameRu('RU'), 'Россия');
  });

  test('falls back for unknown / missing codes', () {
    expect(countryNameRu(null), 'Неизвестно');
    expect(countryNameRu('??'), 'Неизвестно');
    expect(countryNameRu(''), 'Неизвестно');
    expect(countryNameRu('ZZ'), 'ZZ');
  });

  test('isKnownCountry', () {
    expect(isKnownCountry('NL'), isTrue);
    expect(isKnownCountry('nl'), isTrue);
    expect(isKnownCountry('??'), isFalse);
    expect(isKnownCountry(null), isFalse);
  });

  test('covers every country seen in the bundled sample pool', () {
    const seen = [
      'DE', 'US', 'SG', 'JP', 'CA', 'AL', 'IE', 'IT', 'LT', 'TH', 'GB', 'CN',
      'FI', 'SE', 'NL', 'AE', 'RU', 'HK', 'AU', 'BG', 'NO', 'PL', 'RO', 'ID',
      'AT', 'CY',
    ];
    for (final c in seen) {
      expect(isKnownCountry(c), isTrue, reason: c);
    }
  });
}
