# KUMA ClickHouse Backup Script (kuma_save_partition_v2)

## Описание
Скрипт автоматизирует процесс резервного копирования событий из **Хранилища KUMA**.
Позволяет выгружать данные:
- За один конкретный день
- За прошлый день
- За диапазон дат

Поддерживается автоматическая ротация логов работы скрипта, листинг списка тенантов (`-listtenants`) и очистка старых бэкапов с помощью аргумента `-keepdays`.

Скрипт основан на [инструкции KUMA Community](https://kb.kuma-community.ru/books/ustanovka-i-obnovlenie/page/arxivirovnie-i-vosstanovlenie-bd-cerez-clickhouse-backuprestore). 

> [!WARNING]
> Необходимо преднастроить хранилище по инструкции выше по главе **Настройка хранилища**.

---

## Требования
- Развернутый сервер хранилища **KUMA Storage**
- Преднастройте хранилище для создания бекапов (см. инструкцию выше)
- Доступ до KUMA Core порт: `7223/tcp` (API)
- Установленный пакет [`jq`](https://stedolan.github.io/jq/) на сервере хранилища
- Пользователь KUMA с ролью **"младший аналитик"** или выше, имеющий:
  - API токен
  - Права на чтение списка тенантов (`GET /tenants`)

> [!NOTE]
> Поддерживаются версии KUMA 3.х и 4.0. Протестировано на версиях KUMA 3.4 и 4.0

---

## 🚀 Установка
1. Скопируйте скрипт на сервер хранилища KUMA
2. Убедитесь, что все соответсвует требованиям выше
3. Отредактируйте конфигурационные переменные в скрипте:
   ```bash
   TOKEN_KUMA='ваш_API_токен'
   CORE_KUMA='адрес_core_kuma'
   ```
4. По необходимости отредактируйте (опционально) конфигурационные переменные в скрипте:
   ```bash
   threshold_free_disk=89
   keep_days=60
   LOG_DIR="/var/log"
   MAX_LOG_SIZE_MB=10  # Максимальный размер лог-файла в МБ
   ```
5. Дайте права на выполнение:
   ```bash
   chmod +x kuma_save_partition_v2.sh
   ```

---

## 🧩 Использование

### Запуск справки
```bash
./kuma_backup.sh -h
```

### Экспорт за один день
```bash
./kuma_backup.sh -exportday 20250825 -tenant "Test Tenant"
```

### Экспорт за вчера
```bash
./kuma_backup.sh -exportday yesterday -tenant "Test Tenant"
```

### Экспорт за диапазон дат
```bash
./kuma_backup.sh -exportrange 20250820 20250825 -tenant "Test Tenant"
```

### Получение списка доступных тенантов
```bash
./kuma_backup.sh -listtenants
```

### Настройка хранения бэкапов (например, 30 дней)
```bash
./kuma_backup.sh -exportday yesterday -tenant "Test Tenant" -keepdays 30
```

---

## 📂 Структура файлов
После выполнения бэкапа в каталоге `BACKUP_PATH` будут созданы:
- `backup_kuma_<host>_<tenant>_<partition>_<date>.zip` — архив с данными
- `backup_kuma_<host>_<tenant>_<partition>_<date>.desc` — метаданные (размер, MD5, tenant ID и пр.)

---

## 🙏 Благодарности
- Михаил З. — за основу скрипта  
- Ирина Лео — за функции логирования