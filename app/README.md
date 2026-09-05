# app — клиентское приложение

Flutter. Таргеты на время разработки: **Android, Windows, Linux** (Linux — в CI).
iOS — только абстракции платформенного слоя, без сборки.

Проект Flutter будет инициализирован в Фазе 2 (`flutter create` прямо в этот
каталог). До этого здесь только данный файл.

## Планируемая структура

```
lib/
  main.dart
  app/            — тема (тёмная, фиолетовый акцент), роутинг, DI
  ui/simple/      — главный экран: питание, селектор локаций, счётчик
  ui/pro/         — Node Inspector, Live Logs, графики, редактор правил
  ui/common/      — виджет подсказки ℹ️, переиспользуемые компоненты
  domain/         — модели (Node, Pool, Session), use-cases
  data/           — репозитории: пул, свои ключи, телеметрия; Isar/Hive
  core/           — FFI-мост к sing-box/xray, генерация конфигов, контроллер
  platform/       — TUN, autostart, permissions (android/windows/linux/ios-stub)
test/
```

## Запуск (после Фазы 2)

```bash
flutter pub get
flutter run -d windows
flutter test
```
