#!/bin/bash
# ver. 0.2 (05.12.2024)

#скрипт запускается на серверах хранилища, где есть CH
#скрипт позволяет сделать резервную копию событий kuma за прошедший день, или период
# выгрузку можно делать только для отдельного тенанта
# скрипт сделан на основании инструкции https://kb.kuma-community.ru/books/ustanovka-i-obnovlenie/page/arxivirovnie-i-vosstanovlenie-bd-cerez-clickhouse-backuprestore

# для работы скрипта требуется
# 1. установка утилиты jq
# 2. созданная уз KUMA с ролью "младший аналитик" или выше, с токеном доступа и правами API на чтение списка тенантов (GET /tenants)
# Токен указывается в переменной TOKEN_KUMA
# 3. Открытый порт 7223/tcp со стороны узлов хранилища в сторону core
# для начала работы требуется заполнить две переменных - TOKEN_KUMA и CORE_KUMA
#  Спасибо Михаилу З. за этот скрипт
#  Спасибо Ирине Лео за функции логирования

#set -x

# ===== Конфигурационные переменные =====
TOKEN_KUMA='825f0162626fcdedc38641324f2f2b5c'
CORE_KUMA='kuma-aio.sales.lab'
threshold_free_disk=89   # указываем порог зянятого места на диске с бекапами в процентах
keep_days=60   # по умолчанию храним бэкапы 60 дней (можно задать аргументом -keepdays)

# ===== Параметры в зависмимости от версии KUMA =====
KUMA_VER=$(/opt/kaspersky/kuma/kuma version | cut -d "." -f1-2)
if [[ $(bc <<< "$KUMA_VER < 4.0") -eq 1 ]]; then
    clientCH=/opt/kaspersky/kuma/clickhouse/bin/client.sh
    api_ver=v1
else
    clientCH=/opt/kaspersky/kuma/storage/*/deps/clickhouse/bin/client.sh
    api_ver=v3
fi

# ===== Настройки логирования =====
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/kuma_backup.log"
MAX_LOG_SIZE_MB=10  # Максимальный размер лог-файла в МБ
previous_day=$(date -d "-1 days" +"%Y%m%d")
BACKUPHOST=$(hostname -f)

# ===== Инициализация логирования =====
# Создаем директорию для логов если не существует
[ ! -d "$LOG_DIR" ] && sudo mkdir -p "$LOG_DIR"
[ ! -f "$LOG_FILE" ] && sudo touch "$LOG_FILE" && sudo chmod 644 "$LOG_FILE"

# ===== Проверка установки jq =====
if ! command -v jq &> /dev/null; then
        echo -e "${RED}Отсутствует jq, пожалуйста установите необходимый пакет на ОС (пример): sudo apt-get install jq${NC}"
        exit 1
fi


# Проверка и ротация лога
current_log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
if [ $current_log_size -gt $((MAX_LOG_SIZE_MB * 1024 * 1024)) ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Лог превысил $MAX_LOG_SIZE_MB МБ, очищаем." > "$LOG_FILE"
fi

# Функция логирования
log() {
    local plain="[$(date '+%Y-%m-%d %H:%M:%S')] $(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')"
    local color="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$color"      # с цветом в консоль
    echo -e "$plain" >> "$LOG_FILE"  # без цвета в лог
}

# Начало работы скрипта
log "=== Запуск скрипта резервного копирования KUMA ==="

# ===== Цвета для вывода =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ===== Определение путей в конфигурации хранилища KUMA мест для резервного копирования=====
BACKUP_PATH=$(grep -Pzo "(?s)\<backups\>.+\<\/backups\>" /opt/kaspersky/kuma/clickhouse/cfg/config.d/override.xml | \
    grep -Pzo "(?s)\<allowed_path\>.+\<\/allowed_path\>" | \
    cut -d ">" -f 2 | cut -d "<" -f 1 | grep -Pzo "[\/\w\d]+")

# ===== Функции =====
function filesize {
       stat -c%s $BACKUP_FILE
}


#===== Функция проверки свободного места  =====
function check_disk_space {
    local path="$1"
    local threshold="$2"
    # Проверка существования каталога
    if [ ! -d "$path" ]; then
        log "${RED}ОШИБКА: Каталог $path не существует${NC}"
        return 1
    fi

    # Получение данных о месте с обработкой ошибок
    local disk_info
    if ! disk_info=$(df -h "$path" 2>/dev/null | awk 'NR==2'); then
        log "${RED}ОШИБКА: Не удалось проверить место в $path${NC}"
        return 1
    fi

    local used_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
    local free_space=$(echo "$disk_info" | awk '{print $4}')
    local total_space=$(echo "$disk_info" | awk '{print $2}')
    if [ -z "$used_percent" ]; then
        log "${RED}ОШИБКА: Не удалось определить занятое место в $path${NC}"
        return 1
    fi

    if [[ "$used_percent" -ge "$threshold" ]]; then
        log "${RED}КРИТИЧЕСКОЕ ЗНАЧЕНИЕ: В $path занято ${used_percent}% (порог: ${threshold}%)${NC}"
        log "${RED}Детали: Всего ${total_space}, свободно ${free_space}${NC}"
        return 1
    fi

    log "${GREEN}Места достаточно: $path (занято ${used_percent}%, свободно ${free_space} из ${total_space})${NC}"
    return 0
}


#===== Функция удаления старых бэкапов =====
#возможно не включать в некоторых сценариях, где очистка отдается на откуп внешней системе, которая будет забирать бекап и потом очищать его
function cleanup_old_backups {
    local cutoff_date=$(date -d "$keep_days days ago" +%Y%m%d)
    log "Очистка бэкапов старше $cutoff_date (храним $keep_days дней)"
    local no_old=1
    # Для .zip и .zip.old файлов
    for ext in zip zip.old; do
        find "$BACKUP_PATH" -name "backup_kuma_*.$ext" -type f | while read -r file; do
            file_date=$(echo "$file" | grep -oE '[0-9]{8}')
            if [[ "$file_date" && "$file_date" < "$cutoff_date" ]]; then
                log "Удаление: $file"
                rm -f "$file" || echo "Ошибка удаления $file" | tee -a "$LOGFILE"
                no_old=0
            else
                no_old=1
            fi
        done
    done

    if [[ $no_old ]]; then
        log "Нет старых бэкапов"
    fi
}


#Функции проверки корректности даты
function check_export_date {
        local check_date=$1
        if ! [[ $(date "+%Y%m%d" -d $check_date) ]]; then
                        log "${RED}Неверный формат даты резервного копирования: $check_date (ожидается YYYYMMDD)${NC}"
        fi
        if [[ $previous_day < $check_date ]]; then
                        log "${RED}Дата бекапа может быть не ранее $previous_day${NC}"
        fi
}


#функция бекапа
function backup_partition {

        BACKUP_DAY=$1

        #проверяем наличие свободного места на диске
        if ! check_disk_space "$BACKUP_PATH" "$threshold_free_disk" ; then
            exit 1
        fi

        # Получение информации о партициях
        get_part=$($clientCH -d kuma --multiline --query "
                   SELECT partition, name, partition_id
                   FROM system.parts
                   WHERE (substring(partition, 2, 8) = '$BACKUP_DAY') AND (table = 'events_local_v2')
                   AND NOT positionCaseInsensitive(partition,'audit')>0
                   Format JSONStrings
        ")

        #Результат get_partitionid содержит partition_id
        get_partitionid=$(echo $get_part | jq -r --arg jqbackup $BACKUPTENANTID '.data[] | select (.partition | contains ($jqbackup)) | .partition_id ' | uniq)

        if [[ -z "$get_partitionid" ]]; then
            log "${YELLOW}Партиции для даты $BACKUP_DAY не найдены${NC}"
            return 0
        fi

        log "Найдены Partition ID: $get_partitionid"

        for pid in $get_partitionid; do
            BACKUP_FILE="$BACKUP_PATH""backup_kuma_""$BACKUPHOST""_""$TENANTBACKUP""_""$pid""_""$BACKUP_DAY.zip"
            
            log "Создание бэкапа в файл: $BACKUP_FILE"
            #проверка на наличие файла бекапа меньше 1000 байт. файл может быть, но нулейвой длины
            if [ -f "$BACKUP_FILE" ]; then
                if [ "$(filesize "$BACKUP_FILE")" -lt 1000 ]; then
                    log "${YELLOW}Файл бэкапа меньше 1000 байт, переименовываем${NC}"
                    mv "$BACKUP_FILE" "${BACKUP_FILE}.old"
                else
                    log "${GREEN}Файл бэкапа уже существует и имеет нормальный размер${NC}"
                    return 1
                fi
            fi

            log "Создаём бэкап для Partition ID=$pid"
            backup_result=$($clientCH -d kuma --multiline --query "
                BACKUP TABLE kuma.events_local_v2
                PARTITION ID '$pid'
                TO File('$BACKUP_FILE')
                SETTINGS compression_method='zstd', compression_level=5
            ")

            result_code=$?
            if [ $result_code -eq 0 ]; then
                log "${GREEN}Бэкап Partition ID=$pid успешно создан${NC}"
            else
                log "${RED}ОШИБКА бэкапа Partition ID=$pid (код $result_code)${NC}"
                log "Детали ошибки: $backup_result"
                # exit 1
            fi

            BACKUP_FILE_DESC="$BACKUP_PATH""backup_kuma_""$BACKUPHOST""_""$TENANTBACKUP""_""$pid""_""$BACKUP_DAY.desc"
            {
                echo "Core Name: $CORE_KUMA"
                echo "Host Name: $BACKUPHOST"
                echo "Tenant Name: $TENANTBACKUP"
                echo "Tenant ID: $BACKUPTENANTID"
                echo "Backup Date: $BACKUP_DAY"
                echo "Partition ID: $get_partitionid"
                echo "Имя файла: $BACKUP_FILE"
                echo "Размер файла: $(du -h "$BACKUP_FILE" | cut -f1)"
                echo "MD5: $(md5sum $BACKUP_FILE | awk '{print $1}')"
            } > "$BACKUP_FILE_DESC"
        done
}

# ===== Обработка аргументов =====
usage="\n$(basename "$0") [-h] [-exportday] <YYYYMMDD> -exportrange <YYYYMMDD> <YYYYMMDD> [-tenant] <KUMA Tenant name> -- скрипт резервного копирования событий ClickHouse в KUMA \n
\n
где:\n
    ${YELLOW}-h${NC} -- данная справка\n
    ${YELLOW}-exportday <YYYYMMDD>${NC} -- экспорт KUMA партиций за дату <YYYYMMDD>\n
    ${YELLOW}-exportday yesterday${NC} -- экспорт KUMA партиций за предыдущий день\n
    ${YELLOW}-exportrange <YYYYMMDD> <YYYYMMDD>${NC} -- экспорт KUMA партиций за период с <YYYYMMDD> до <YYYYMMDD>\n
    ${YELLOW}-tenant <tenant name>${NC} -- имя тенанта в KUMA, если имя тенанта содержит пробел, то указываем в обрамлении двойных кавычек \"tenant name\" \n
    ${YELLOW}-listtenants${NC} -- получение списка партиций KUMA (Имя и ID)\n
    ${YELLOW}-keepdays <N>${NC} -- хранить бэкапы только N дней (по умолчанию 60)\n
\n
"

if [[ $# -eq 0 ]]; then
    log "${RED}ОШИБКА: Не указаны аргументы${NC}"
#   echo -e "${RED}Нет аргументов ${NC}"
    echo -e $usage
    exit 1
fi


#проверка параметров командной строки
while [ -n "$1" ]; do
    case "$1" in
        -exportday)
            export_date=$2
            if [ "$export_date" = "yesterday" ] ; then 
                export_date=$previous_day; 
                echo $export_date; 
            fi
            #Проверяем формат времени и что дата не из будущего
            check_export_date $export_date
            export_endday=$export_date
            shift
        ;;
        -exportrange)
            export_date="$2"
            export_endday="$3"
            #Проверяем формат времени и что дата не из будущего
            check_export_date $export_date
            check_export_date $export_endday
            if [[ $export_date > $export_endday ]]; then
                log "${RED}Дата начала $export_date периода бекапа не может быть позже даты $export_endday${NC}"
                exit 1;
            fi
            shift
            shift
        ;;        
        -tenant)
            export_tenant="$2"
            shift 
        ;;
        -listtenants)
            log "Список доступных тенантов:"
            tenants_json=$(curl -sk --header "Authorization: Bearer $TOKEN_KUMA" "https://$CORE_KUMA:7223/api/$api_ver/tenants") || {
                log "${RED}Ошибка: не удалось получить список тенантов${NC}"
                exit 1
            }
            echo "$tenants_json" | jq -r '.[] | "\(.name)\t\(.id)"' | column -t -s $'\t'
            exit 0
        ;;
        -keepdays)
            keep_days="$2"
            if ! [[ "$keep_days" =~ ^[0-9]+$ ]]; then
                log "Ошибка: параметр -keepdays должен быть числом"
                exit 1
            fi
            shift
        ;;
        -h) echo -e $usage
            exit 1
        ;;
        
        *)
            log "${RED}Неизвестный аргумент: $1${NC}"
            exit 1
        ;;
    esac
        shift
done

log "Параметры запуска: Дата=$export_date, Тенант=$export_tenant"
# echo "Дата бекапа:"$export_date "Имя тенаната KUMA:" $export_tenant | tee -a $LOGFILE

# ===== Основная логика =====
TENANTNAME=$export_tenant

if [ ! -d "$BACKUP_PATH" ]; then
    log "${RED}ОШИБКА: Каталог бекапа '$BACKUP_PATH' не существует. Проверьте соответствующую настройкуу на хранилище и обновите его конфигурацию.${NC}"
    exit 1
fi

#проверяем существование тенанта
log "Проверка тенанта $export_tenant..."

get_tenantname=$(curl -s -k --header "Authorization: Bearer $TOKEN_KUMA" "https://$CORE_KUMA:7223/api/$api_ver/tenants" | jq -r --arg jqtenant "${TENANTNAME}" '.[] | select (.name==$jqtenant) | .name')

if [[ -z "$get_tenantname" ]]; then
    log "${RED}ОШИБКА: Тенант $export_tenant не найден${NC}"
    exit 1
fi

TENANTBACKUP=$(echo $get_tenantname | tr -d ' ')
get_tenantid=$(curl -s -k --header "Authorization: Bearer $TOKEN_KUMA" "https://$CORE_KUMA:7223/api/$api_ver/tenants" | \
    jq -r --arg jqtenant "${TENANTNAME}" '.[] | select (.name==$jqtenant) | .id ')


BACKUPTENANTID=$get_tenantid
log "Найден тенант: $TENANTBACKUP (ID: $BACKUPTENANTID)"

# Выполнение бэкапа
log "===== Начало задачи резервного копирования ====="
log "Хост: $BACKUPHOST"
log "Путь для бэкапов: $BACKUP_PATH"


current_date="$export_date"

while [[ "$current_date" != $(date -d "$export_endday + 1 day" +%Y%m%d) ]]; do
    log "Обработка даты: $current_date"
    backup_partition $current_date
    current_date=$(date -d "$current_date + 1 day" +%Y%m%d)
done

cleanup_old_backups

# Завершение работы
log "===== Задача резервного копирования завершена ====="
log "Общее время работы: $SECONDS сек"
exit 0