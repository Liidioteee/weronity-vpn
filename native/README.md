# native — нативное ядро (FFI)

Go (cgo). Обёртка над **sing-box** (основное ядро) и **Xray-core** (fallback для
legacy-конфигов), компилируемая в динамическую библиотеку и связываемая с Flutter
через Dart FFI.

Наполняется в Фазе 3. Таргеты сборки:

| Платформа | Артефакт | Сборка |
|---|---|---|
| Android | `.so` (arm64-v8a, armeabi-v7a, x86_64) | NDK + `go build -buildmode=c-shared` |
| Windows | `.dll` (x86_64) | MSVC/MinGW + cgo |
| Linux | `.so` (x86_64, arm64) | gcc + cgo (в CI) |
| iOS | `.xcframework` | отложено |

## Планируемая структура

```
singbox-ffi/
  bridge.go       — экспортируемые C-функции (start, stop, stats, on_event)
  config.go       — генерация конфига sing-box из модели Node
  go.mod
xray-ffi/         — аналогично для Xray-core
scripts/          — build-android.sh, build-windows.ps1, build-linux.sh
include/           — сгенерированные C-заголовки для FFI
```

## API (черновик)

```
int  wrn_start(const char* config_json);
int  wrn_stop(void);
char* wrn_stats_json(void);          // upload/download, текущий outbound, пинг
void wrn_set_event_callback(void (*cb)(const char* json));   // logs, switch, error
```
