# collector — контур сбора нод

Python 3.13. Скрейпит источники, декодирует URI-схемы, чистит, дедуплицирует,
разрешает GeoIP/ASN, пингует, классифицирует и собирает `nodes_pool.json`.

На время разработки единственный источник —
[`igareck/vpn-configs-for-russia`](https://github.com/igareck/vpn-configs-for-russia)
(все файлы).

## Запуск (локально)

```bash
py -3.13 -m venv .venv
.venv/Scripts/activate      # PowerShell: .venv\Scripts\Activate.ps1
pip install -e ".[dev]"
python -m weronity_collector run --out out/nodes_pool.json
pytest
```

## Структура

```
src/weronity_collector/
  schema.py      — модель Node, JSON-схема пула, валидация
  sources/       — Source-абстракция + github-источник
  parsers/       — vless, hysteria2, trojan, vmess, shadowsocks, tuic, shadowtls,
                   clash (YAML), subscription (base64)
  pipeline/      — decode, sanitize, dedup, geoip, ping, classify, serialize
  __main__.py    — CLI (run, validate, stats)
tests/           — pytest, фикстуры реальных URI в tests/fixtures/
```

Подробнее о полях пула и классификации — [`../docs/pool-schema.md`](../docs/pool-schema.md).
