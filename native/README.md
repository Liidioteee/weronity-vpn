# native — нативное ядро (FFI)

Go (cgo). Обёртка над **sing-box** (основное ядро) и **Xray-core** (fallback для
legacy-конфигов), компилируемая в динамическую библиотеку и связываемая с Flutter
через `dart:ffi`.

Статус: **Фаза 3.0 + 3.1 сделаны** — c-shared конвейер проверен, движок = реальный
**sing-box v1.14.0**. Генератор конфига хардненный (см. ниже). Проверено на
Windows из листа «Проверка ядра sing-box» (Настройки → О приложении → Нативное
ядро). `ConnectionController` пока не переключён — это 3.2. Порядок работ —
`docs/roadmap.md` «Фаза 3».

## Структура

```
weronity_core/
  go.mod            module weronity/core (go 1.25.5, sing-box v1.14.0)
  config.go         ХАРДНЕНИНГ: sanitizeOutbound (allowlist) + buildSingBoxConfig
                    (loopback-only inbound, без control API) + assertConfigSafe
  config_test.go    тесты санитайзера (без cgo/sing-box)
  engine.go         реальный движок sing-box: box.New/Start/Close, логи, self-test
  engine_test.go    lifecycle с настоящим sing-box
  events.go         кольцевой буфер событий (Dart поллит wrnDrainEvents)
  bridge.go         //export C-шимы, import "C"
include/
  weronity_core.h   сгенерированный C-заголовок для справки
scripts/
  build-windows.sh  → native/build/windows/weronity_core.dll (~38 МБ) + копия рядом с exe
build/              git-ignored, артефакты сборки
```

Xray-fallback (`xray_core/`) и Android (`gomobile` → `libbox.aar`) добавляются
в 3.4–3.5.

## Экспортируемый C API

```c
char* wrnCoreVersion(void);                 // строку освобождать wrnFree
int   wrnPing(int x);                        // smoke: x -> x+1
void  wrnFree(char* p);
int   wrnStart(const char* config_json);     // {outbound, socks_port, self_test, log_level}; 0 = ok
int   wrnStop(void);
int   wrnIsRunning(void);
char* wrnStatsJSON(void);                    // {running, socks_port, uptime_ms, self_test{...}}; wrnFree
char* wrnDrainEvents(void);                  // JSON-массив [{kind:"log",level,tag,message}]; wrnFree
```

`wrnStart` принимает НЕ готовый конфиг sing-box, а `{"outbound": <объект ноды из
пула>, ...}`. `outbound` — недоверенный ввод; Go его санитизирует и оборачивает
в loopback-only конфиг. Никакого C-колбэка для логов (Go освобождает строку
сразу — было бы use-after-free); Dart поллит `wrnDrainEvents`.

Dart-сторона: `app/lib/core/native/native_core.dart` (`NativeCore.instance()`).
Если библиотеки нет — `NativeCoreState.unavailable`, приложение продолжает
работать на стаб-`ConnectionController`.

## Сборка

```bash
export PATH="/d/sdk/go/bin:$PATH"
bash native/scripts/build-windows.sh          # Windows x86_64 → .dll (~38 МБ)

# go vet / go test: нужен mingw gcc в PATH и те же теги, что при сборке
cd native/weronity_core
MINGW="$(ls -d /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs*/mingw64/bin)"
PATH="$MINGW:$PATH" CGO_ENABLED=1 go test -tags with_quic,with_utls,with_clash_api ./...
```

Теги сборки: **`with_quic,with_utls,with_clash_api`** (QUIC для hysteria2/tuic;
uTLS/REALITY; clash_api обязателен при `PlatformLogWriter`, но сокет не
открывает). CGO под Windows требует mingw-w64 gcc (winlibs UCRT, `winget install
BrechtSanders.WinLibs.POSIX.UCRT`) — не лежит в PATH, скрипт ищет его сам.
См. `docs/gotchas.md` #8–9.

| Платформа | Артефакт | Сборка |
|---|---|---|
| Windows | `weronity_core.dll` (x86_64) | mingw-w64 + `go build -buildmode=c-shared` |
| Linux | `libweronity_core.so` (x86_64, arm64) | gcc + cgo (в CI) |
| Android | `.so` (arm64-v8a, armeabi-v7a, x86_64) | NDK 27.3 + gomobile |
| iOS | `.xcframework` | отложено (нет macOS) |
