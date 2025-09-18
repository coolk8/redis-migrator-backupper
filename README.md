# Redis Migrator & Backupper

Скрипт и Docker-образ для переноса данных Redis из одной базы в другую с одновременным созданием резервной копии (snapshot RDB) источника, хранением и ротацией бэкапов.

Что делает:
- Делает RDB-снимок источника (SOURCE_REDIS_URL) и при включённых бэкапах сохраняет его в каталог бэкапов.
- Альтернативно умеет восстанавливать из заранее подготовленного RDB-файла (RESTORE_RDB_PATH), минуя дамп из источника.
- Разворачивает выбранный снимок в целевую базу (TARGET_REDIS_URL), допускается перезапись при наличии OVERWRITE_DATABASE.
- Очищает временные файлы.
- Удаляет старые бэкапы по заданной политике (по дням и/или по количеству).
- В самом конце выводит список доступных бэкапов из каталога BACKUP_DIR (включая только что созданный снимок, если он был создан в этом запуске).

Важно: Скрипт запускается извне (например, cron). Внутреннего планировщика нет.

Содержимое репозитория:
- migrate.sh — основной скрипт миграции/бэкапа.
- Dockerfile — сборка образа (redis-cli, rdbtools и т.д.).


## Как это работает

1) Проверка переменных окружения:
   - TARGET_REDIS_URL — обязателен всегда.
   - SOURCE_REDIS_URL — обязателен, если НЕ задан RESTORE_RDB_PATH.
   - RESTORE_RDB_PATH — необязателен; если задан, дамп из источника не делается.

2) Проверка целевой БД: если не пустая и не задан OVERWRITE_DATABASE — процесс останавливается.

3) Определение источника данных:
   - Если задан RESTORE_RDB_PATH — используем указанный файл:
     - Поддерживаются `.rdb` и `.rdb.gz`.
     - Можно указать абсолютный путь внутри контейнера, либо basename файла из каталога BACKUP_DIR (например: `redis-backup_20250918-120000.rdb.gz`).
     - Файл `.gz` распаковывается потоком во временный файл `/data/redis_dump.rdb`.
   - Иначе выполняется `redis-cli --rdb` по адресу SOURCE_REDIS_URL, результат сохраняется во временный файл `/data/redis_dump.rdb`.

4) Сохранение бэкапа и ротация:
   - Бэкап сохраняется в BACKUP_DIR только если мы делали дамп из SOURCE_REDIS_URL в этом запуске (во избежание дубликатов при восстановлении из файла).
   - Имена бэкапов: `${BACKUP_PREFIX}_YYYYmmdd-HHMMSS.rdb[.gz]` (метка времени по умолчанию UTC).
   - Ротация:
     - По дням: удаление файлов старше BACKUP_RETENTION_DAYS.
     - По количеству: хранение только BACKUP_RETENTION_COUNT последних файлов.

5) Конвертация временного RDB в Redis protocol (через `rdb -c protocol`) и загрузка в целевую БД через `redis-cli --pipe`.

6) Очистка временных файлов (`/data/redis_dump.rdb`, `/data/redis_dump.protocol`).

7) Вывод списка доступных бэкапов:
   - В самом конце скрипт выводит содержимое BACKUP_DIR, отсортированное по времени (последние — первыми).
   - Отображаются файлы по шаблону `${BACKUP_PREFIX}_*.rdb*`.


## Переменные окружения

Обязательные:
- TARGET_REDIS_URL — строка подключения к целевой БД Redis.

Условно обязательные:
- SOURCE_REDIS_URL — требуется, если НЕ задан RESTORE_RDB_PATH.

Переменные восстановления из файла:
- RESTORE_RDB_PATH — путь к RDB для восстановления вместо актуального дампа источника.
  - Поддерживаемые варианты:
    - Абсолютный путь внутри контейнера: `/backup/my-dump.rdb` или `/backup/my-dump.rdb.gz`
    - Имя файла (basename) из каталога BACKUP_DIR: `redis-backup_20250918-120000.rdb.gz`
  - Поддерживаемые расширения: `.rdb`, `.rdb.gz`
  - При указании RESTORE_RDB_PATH переменная SOURCE_REDIS_URL не требуется.

Управление перезаписью целевой БД:
- OVERWRITE_DATABASE — если установлена любая непустая строка, разрешает перезапись непустой целевой БД.

Бэкапы:
- BACKUP_ENABLED (по умолчанию: true) — включение/выключение бэкапов.
- BACKUP_DIR (по умолчанию: /backup) — каталог хранения бэкапов (смонтируйте volume).
- BACKUP_PREFIX (по умолчанию: redis-backup) — префикс имени файла.
- BACKUP_COMPRESS (по умолчанию: gzip) — gzip или none.
- BACKUP_RETENTION_COUNT (по умолчанию: 7) — хранить N последних файлов (оставьте пустым, чтобы выключить).
- BACKUP_RETENTION_DAYS (по умолчанию: пусто) — удалять файлы старше D дней (оставьте пустым, чтобы выключить).
- BACKUP_TIMESTAMP_TZ (по умолчанию: UTC) — UTC или local (для меток времени в именах файлов).

Примечания:
- При восстановлении из файла (RESTORE_RDB_PATH) новый бэкап не создаётся, чтобы не плодить дубликаты.
- В конце работы всегда выводится список доступных бэкапов из BACKUP_DIR.


## Примеры запуска

Типичная миграция (дамп из источника + запись бэкапа + восстановление в целевую):
```bash
docker run --rm \
  -e SOURCE_REDIS_URL=redis://:pass@src.example.com:6379/0 \
  -e TARGET_REDIS_URL=redis://:pass@dst.example.com:6379/0 \
  -e OVERWRITE_DATABASE=1 \
  -e BACKUP_RETENTION_COUNT=7 \
  -e BACKUP_RETENTION_DAYS=14 \
  -v /var/backups/redis:/backup \
  your-image:tag
```

Восстановление из конкретного файла в BACKUP_DIR (basename):
```bash
docker run --rm \
  -e RESTORE_RDB_PATH=redis-backup_20250918-120000.rdb.gz \
  -e TARGET_REDIS_URL=redis://:pass@dst.example.com:6379/0 \
  -e OVERWRITE_DATABASE=1 \
  -v /var/backups/redis:/backup \
  your-image:tag
# SOURCE_REDIS_URL не требуется
```

Восстановление из произвольного абсолютного пути:
```bash
docker run --rm \
  -e RESTORE_RDB_PATH=/backup/my-prod.rdb \
  -e TARGET_REDIS_URL=redis://:pass@dst.example.com:6379/0 \
  -e OVERWRITE_DATABASE=1 \
  -v /var/backups/redis:/backup \
  your-image:tag
```

Docker (Windows PowerShell/CMD) — пример миграции:
```powershell
docker run --rm ^
  -e SOURCE_REDIS_URL=redis://:pass@src.example.com:6379/0 ^
  -e TARGET_REDIS_URL=redis://:pass@dst.example.com:6379/0 ^
  -e OVERWRITE_DATABASE=1 ^
  -e BACKUP_RETENTION_COUNT=7 ^
  -e BACKUP_RETENTION_DAYS=14 ^
  -v C:\host\backup:/backup ^
  your-image:tag
```

Docker (Windows) — восстановление из файла:
```powershell
docker run --rm ^
  -e RESTORE_RDB_PATH=redis-backup_20250918-120000.rdb.gz ^
  -e TARGET_REDIS_URL=redis://:pass@dst.example.com:6379/0 ^
  -e OVERWRITE_DATABASE=1 ^
  -v C:\host\backup:/backup ^
  your-image:tag
```

Cron (пример для Linux; запускает ежедневно в 03:00, лог пишет в файл):
```cron
0 3 * * * docker run --rm \
  -e SOURCE_REDIS_URL=redis://... \
  -e TARGET_REDIS_URL=redis://... \
  -e OVERWRITE_DATABASE=1 \
  -e BACKUP_RETENTION_COUNT=7 \
  -e BACKUP_RETENTION_DAYS=14 \
  -v /var/backups/redis:/backup \
  your-image:tag >> /var/log/redis-migrator.log 2>&1
```

Сборка образа:
```bash
docker build -t your-image:tag .
```

Рекомендации:
- Всегда монтируйте host-директорию в `/backup`, чтобы бэкапы сохранялись вне контейнера.
- Проверьте права на запись у каталога `/backup`.


## Поведение при ошибках

Скрипт пишет подробные логи. По историческим причинам завершение при ошибках возвращает код `0` (для совместимости с внешним кроном/CI). По логам можно понять, что произошло (строки с [ERROR]). Если требуется другой код возврата — измените `error_exit`/trap-логику в `migrate.sh`.


## Внутренние файлы

Во время работы используются временные файлы:
- `/data/redis_dump.rdb`
- `/data/redis_dump.protocol`

Они автоматически удаляются по завершении.


## Лицензия

MIT (или укажите свою).
