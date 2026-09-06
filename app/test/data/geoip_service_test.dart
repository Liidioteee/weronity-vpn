import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/data/geoip_service.dart';

/// Build a minimal WGI2 asset: codes ["", "US", "DE"], records
///   0.0.0.0    -> unknown
///   1.0.0.0    -> US
///   2.0.0.0    -> DE
///   3.0.0.0    -> unknown
Uint8List _asset() {
  final b = BytesBuilder();
  b.add('WGI2'.codeUnits);
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  u16(3); // n_cc
  b.add([0, 0]); // index 0 = ""
  b.add('US'.codeUnits);
  b.add('DE'.codeUnits);

  u32(4); // count
  u32(0x00000000);
  u16(0);
  u32(0x01000000);
  u16(1); // 1.0.0.0
  u32(0x02000000);
  u16(2); // 2.0.0.0
  u32(0x03000000);
  u16(0); // 3.0.0.0
  return b.toBytes();
}

void main() {
  final geo = GeoIpService.parseBytes(_asset());

  test('parseV4', () {
    expect(GeoIpService.parseV4('1.2.3.4'), 0x01020304);
    expect(GeoIpService.parseV4('255.255.255.255'), 0xFFFFFFFF);
    expect(GeoIpService.parseV4('1.2.3'), isNull);
    expect(GeoIpService.parseV4('1.2.3.256'), isNull);
    expect(GeoIpService.parseV4('example.com'), isNull);
  });

  test('lookupIp resolves the range a value falls in', () {
    expect(geo.lookupIp(GeoIpService.parseV4('1.0.0.0')!), 'US');
    expect(geo.lookupIp(GeoIpService.parseV4('1.255.255.255')!), 'US');
    expect(geo.lookupIp(GeoIpService.parseV4('2.0.0.1')!), 'DE');
    expect(geo.lookupIp(GeoIpService.parseV4('3.0.0.0')!), isNull); // unknown
    expect(geo.lookupIp(0), isNull); // before first non-zero range
  });

  test(
    'lookupHost handles an IPv4 literal without touching the network',
    () async {
      expect(await geo.lookupHost('2.2.2.2'), 'DE');
      expect(await geo.lookupHost('1.1.1.1'), 'US');
      expect(await geo.lookupHost(''), isNull);
    },
  );

  test('cachedCountry is sync for literals', () {
    expect(geo.cachedCountry('1.0.0.5'), 'US');
    expect(geo.cachedCountry('unresolved.example'), isNull);
  });

  test('bad magic is rejected', () {
    expect(
      () => GeoIpService.parseBytes(Uint8List.fromList('NOPE....'.codeUnits)),
      throwsFormatException,
    );
  });
}
