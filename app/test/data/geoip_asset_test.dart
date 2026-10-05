@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/data/geoip_service.dart';

/// Sanity-check the *real* bundled asset (read straight off disk, not via
/// rootBundle) so a bad rebuild of `app/tool/build_geoip.py` is caught.
void main() {
  final file = File('assets/geoip/ipv4_country.v2.bin');

  test('bundled asset parses and resolves well-known IPs', () {
    expect(file.existsSync(), isTrue, reason: 'run app/tool/build_geoip.py');
    final geo = GeoIpService.parseBytes(file.readAsBytesSync());

    expect(geo.lookupIp(GeoIpService.parseV4('8.8.8.8')!), 'US'); // Google
    expect(geo.lookupIp(GeoIpService.parseV4('66.23.207.69')!), 'US');
    expect(geo.lookupIp(GeoIpService.parseV4('77.88.8.8')!), 'RU'); // Yandex
    expect(geo.lookupIp(GeoIpService.parseV4('1.1.1.1')!), isNotNull);
  });

  // The asset must say where an address *is*, not where its block was
  // registered: this FDCservers (a US company) range sits in Amsterdam, and a
  // registry-based table called it "US" — which the app then showed as the
  // node's country.
  test('a hosting range is located, not attributed to its registrant', () {
    final geo = GeoIpService.parseBytes(file.readAsBytesSync());
    expect(geo.lookupIp(GeoIpService.parseV4('50.7.120.162')!), 'NL');
  });
}
