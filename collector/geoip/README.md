# geoip/

MaxMind-format `.mmdb` databases used by `pipeline/geoip.py` for country + ASN
resolution. **Not committed** (see `.gitignore`).

Populate from [sapics/ip-location-db](https://github.com/sapics/ip-location-db)
via the jsDelivr CDN (no API token; country data is CC0/PDDL, ASN data derives
from RouteViews/whois):

```bash
python scripts/fetch_geoip.py            # writes dbip-country-lite.mmdb + dbip-asn-lite.mmdb here
```

The reader accepts both record layouts — flat `{"country_code": "US"}`
(ip-location-db) and nested `{"country": {"iso_code": "US"}}` (MaxMind GeoLite2),
so a `GeoLite2-Country.mmdb` / `GeoLite2-ASN.mmdb` pair works too.

Recognised filenames (first match wins):

| purpose | filenames |
|---|---|
| country | `dbip-country-lite.mmdb`, `GeoLite2-Country.mmdb`, `dbip-city-lite.mmdb` |
| ASN | `dbip-asn-lite.mmdb`, `GeoLite2-ASN.mmdb` |

If absent, the pipeline still runs and leaves `geo.*` fields `null` (with a
warning) — used for offline development and tests.
