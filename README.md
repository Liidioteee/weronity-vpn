<div align="center">

# Weronity

**Кроссплатформенный свободный VPN-клиент с гибридной архитектурой ядер,
автоматическим сбором, валидацией и горячим автопереключением публичных прокси-нод.**

100% Free & Open Source · Zero-Log · GPLv3

</div>

---

## Что это

Weronity — VPN-клиент для Linux, Android и Windows (iOS — на уровне архитектуры,
сборка отложена), который:

- **Zero-Config** — подключение в 1 клик без ручного ввода ключей;
- **Pro-режим** — метрики, ручное управление конфигами, DNS, маршрутизацией,
  кастомные тестовые эндпоинты, Live Logs, инспектор нод;
- сам **собирает, валидирует и классифицирует** публичные ноды через контур на
  GitHub Actions и раздаёт их как `nodes_pool.json`;
- запускает **pre-flight проверку** нод на устройстве перед подключением;
- **горячо переключается** на живой узел без разрыва TUN-интерфейса;
- отдаёт **анонимную краудсорсинговую телеметрию** (HMAC) о репутации нод по ASN.

## Архитектура

```
GitHub Actions (cron 20m) ─ скрейпинг → санитизация → GeoIP → пинг → nodes_pool.json
        │ upload
Cloudflare Pages/R2  ─ раздача nodes_pool.json (zero cost)
        │ polling
Flutter GUI ──(Dart FFI)──> sing-box core  (fallback: Xray-core)
        │                        │
   Pro / Simple UI        TUN / Wintun / VpnService
        │
   Pre-flight Test Engine ─ локальный тест заблокированных сервисов
        │ анонимный отчёт (HMAC)
Cloudflare Workers API + D1 ─ репутация нод по ASN
```

Подробно: [`docs/architecture.md`](docs/architecture.md).

## Структура репозитория

| Каталог | Содержимое | Стек |
|---|---|---|
| [`collector/`](collector/) | Контур сбора: скрейперы, парсеры URI-схем, дедуп, GeoIP, пинг, классификация | Python 3.13 |
| [`backend/`](backend/) | Edge API телеметрии, хранилище репутации по ASN | Cloudflare Workers (TS) + D1 |
| [`app/`](app/) | Клиентское приложение, Simple/Pro UI | Flutter / Dart |
| [`native/`](native/) | FFI-обёртка над sing-box и Xray-core | Go (cgo) |
| [`.github/workflows/`](.github/workflows/) | CI: пайплайн сбора (cron 20m), тесты, сборки | GitHub Actions |
| [`docs/`](docs/) | Архитектура, схема пула, дорожная карта | — |

## Протоколы

VLESS (Reality/XTLS, WS, gRPC, HTTPUpgrade, TCP) · Hysteria 2 (obfs/Salamander) ·
Trojan (TLS, gRPC, WS) · ShadowTLS v2/v3 · VMess (WS, TCP, mKCP, gRPC) ·
Shadowsocks (AEAD, 2022-blake3) · TUIC v5.

## Статус

Ранняя разработка. Дорожная карта и текущая фаза — [`docs/roadmap.md`](docs/roadmap.md).

## Лицензия

[GNU GPL v3.0](LICENSE). На время разработки единственный источник ключей —
[`igareck/vpn-configs-for-russia`](https://github.com/igareck/vpn-configs-for-russia).

## Приватность

Zero-Log Policy: приложение не собирает персональные данные. Телеметрия —
только анонимные HMAC-подписанные метрики доступности нод по ASN, без привязки
к пользователю. См. [`docs/architecture.md`](docs/architecture.md#телеметрия).
