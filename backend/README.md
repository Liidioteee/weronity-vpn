# backend — краудсорсинговая телеметрия

Cloudflare Workers (TypeScript) + D1. Принимает анонимные HMAC-подписанные отчёты
о доступности нод и отдаёт агрегированную репутацию по ASN.

> Аккаунта Cloudflare пока нет. Разработка и тесты — локально
> (`wrangler dev` / miniflare + vitest). Деплой и создание ресурсов (D1, R2,
> Pages) — отдельным шагом позже.

## Эндпоинты

| Метод | Путь | Назначение |
|---|---|---|
| `POST` | `/report` | Приём отчёта `{asn, country, proto, node_fingerprint, ok, latency_ms, ts}`, заголовок `X-Sig`. |
| `GET` | `/reputation?asn=...` | Сводная репутация по ASN (успехи/фейлы, средняя задержка, last_seen). |
| `GET` | `/pool` | (опц.) прокси/зеркало `nodes_pool.json`. |

## Запуск (локально)

```bash
npm install
npm run dev        # wrangler dev, локальный D1
npm test           # vitest + miniflare
```

Zero-Log: не логируются IP, идентификаторы устройств, куки. В D1 — только агрегат
по `(asn, proto)`.
