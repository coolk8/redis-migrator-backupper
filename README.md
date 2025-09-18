# Redis Migrator & Backupper

Скрипт и Docker-образ для переноса данных Redis из одной базы в другую с одновременным созданием резервной копии (snapshot RDB) источника, хранением и ротацией бэкапов.

Что делает:
- Делает RDB-снимок источника (SOURCE_REDIS_URL).
- Сохраняет копию снимка в каталог бэкапов (/backup) с именем вида: redis-backup_YYYYmmdd-HHMMSS.rdb.gz (UTC).
- Разворачивает этот снимок в целевую базу (TARGET_REDIS_URL), допускается перезапись при наличии OVERWRITE_DATABASE.
- Очищает временные файлы.
- Удаляет старые бэкапы по заданной политике (по дням и/или по количеству).

Важно: Скрипт запускается извне (например, cron). Внутреннего планировщика нет.

Содержимое репозитория:
- migrate.sh — основной скрипт миграции/бэкапа.
- Dockerfile — сборка образа (redis-cli, rdbtools и т.д.).


## Как это работает

1) Проверка переменных окружения: SOURCE_REDIS_URL, TARGET_REDIS_URL.  
2) Проверка целевой БД: если не пустая и не задан OVERWRITE_DATABASE — процесс останавливается.  
3) Создание RDB-дампа источника во временный файл /data/redis_dump.rdb.  
4) Копирование дампа в каталог бэкапов (/backup) с именованием по UTC-времени и с gzip-сжатием.  
5) Конвертация временного RDB в Redis protocol (через `rdb -c protocol`) и загрузка в целевую БД через `redis-cli --pipe`.  
6) Очистка временных файлов (`/data/redis_dump.rdb`, `/data/redis_dump.protocol`).  
7) Ротация бэкапов в /backup:
   - По дням: удаление файлов старше N дней.
   - По количеству: оставление только N последних файлов.
   - Если указаны оба — сначала удаление по дням, затем нормализация по количеству.


## Переменные окружения

Обязательные:
- SOURCE_REDIS_URL — строка подключения к исходной БД Redis.
- TARGET_REDIS_URL — строка подключения к целевой БД Redis.

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
- Имена бэкапов: `${BACKUP_PREFIX}_YYYYmmdd-HHMMSS.rdb[.gz]`
- Метка времени по умолчанию в UTC.


## Примеры запуска

Docker (Linux/macOS):
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

Docker (Windows PowerShell/CMD):
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
