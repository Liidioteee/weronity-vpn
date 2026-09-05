# native — нативное ядро (FFI)

Go (cgo). Обёртка над **sing-box** (основное ядро) и **Xray-core** (fallback для
legacy-конфигов), компилируемая в динамическую библиотеку и связываемая с Flutter
через `dart:ffi`.

Статус: **Фаза 3.0 сделана** — сквозной конвейер (сборка cgo → c-shared →
загрузка из Dart → маршалинг) проверен на Windows. Движок пока стаб; sing-box
подключается в 3.1. Подробности и порядок работ — `docs/roadmap.md` «Фаза 3».

## Структура

```
weronity_core/
  go.mod            module weronity/core
  engine.go         чистый Go: стаб-движок (start/stop/stats), эмиттер событий — unit-тесты
  engine_test.go    go test (без cgo)
  bridge.go         //export C-шимы, import "C"
weronity_core.h     ← генерируется рядом с DLL, копия в include/
include/
  weronity_core.h   сгенерированный C-заголовок для справки
scripts/
  build-windows.sh  → native/build/windows/weronity_core.dll (+ копия рядом с exe)
build/              git-ignored, артефакты сборки
```

Xray-fallback (`xray_core/`) и Android (`gomobile` → `libbox.aar`) добавляются
в 3.4–3.5.

## Экспортируемый C API

```c
char* wrnCoreVersion(void);                 // строку освобождать wrnFree
int   wrnPing(int x);                        // smoke: x -> x+1
void  wrnFree(char* p);
int   wrnStart(const char* config_json);     // 0 = ok, !=0 = ошибка
int   wrnStop(void);
int   wrnIsRunning(void);
char* wrnStatsJSON(void);                    // {running, uptime_ms, rx_bytes, tx_bytes}; освобождать wrnFree
void  wrnSetEventCallback(void (*cb)(const char* json));   // {kind:"log", level, tag, message}
```

Dart-сторона: `app/lib/core/native/native_core.dart` (`NativeCore.instance()`).
Если библиотеки нет — `NativeCoreState.unavailable`, приложение продолжает
работать на стаб-`ConnectionController`.

## Сборка

```bash
export PATH="/d/sdk/go/bin:$PATH"
bash native/scripts/build-windows.sh          # Windows x86_64 → .dll
cd native/weronity_core && go vet ./... && go test ./...
```

CGO под Windows требует mingw-w64 gcc (winlibs UCRT, `winget install
BrechtSanders.WinLibs.POSIX.UCRT`). Он не лежит в PATH — скрипт ищет его сам;
для ручного `go test` добавьте
`$(ls -d /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs*/mingw64/bin)`
в PATH. См. `docs/gotchas.md` #8.

| Платформа | Артефакт | Сборка |
|---|---|---|
| Windows | `weronity_core.dll` (x86_64) | mingw-w64 + `go build -buildmode=c-shared` |
| Linux | `libweronity_core.so` (x86_64, arm64) | gcc + cgo (в CI) |
| Android | `.so` (arm64-v8a, armeabi-v7a, x86_64) | NDK 27.3 + gomobile |
| iOS | `.xcframework` | отложено (нет macOS) |
