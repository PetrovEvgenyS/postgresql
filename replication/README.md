# PostgreSQL Репликация: Скрипты настройки Primary и Standby

## Описание

В репозитории три файла для автоматизации настройки **физической** репликации PostgreSQL:
- **setup_primary_postgres.sh** — настраивает первичный сервер (Primary): включает WAL, создаёт пользователя репликации, правит `postgresql.conf` и `pg_hba.conf`.
- **setup_standby_postgres.sh** — настраивает резервный сервер (Standby): останавливает сервис, делает `pg_basebackup` с Primary и включает потоковую репликацию.
- **README.md** — этот файл, с инструкциями, проверками и фейловером.

> Скрипты рассчитаны на Debian/Ubuntu-пакеты (`systemd`), с путями вида `/etc/postgresql/<версия>/main` и `/var/lib/postgresql/<версия>/main`. При необходимости поправьте переменные в начале скриптов.

## Требования

- PostgreSQL установлен на обоих серверах (Primary и Standby).
- Доступ суперпользователя PostgreSQL (`postgres`) на обоих серверах.
- Сетевое соединение между узлами (порт 5432 открыт).

## Порядок настройки

### 1) Настройка Primary

1. Отредактируйте переменные в `setup_primary_postgres.sh` (IP Standby, пароль/пользователь, версия PG).
2. Запустите скрипт на Primary:
   ```bash
   sudo ./setup_primary_postgres.sh
   ```
3. Убедитесь, что Primary слушает снаружи и параметры применены:
   ```bash
   sudo systemctl status postgresql
   ```
4. Создайте пользователя для репликации (если скрипт не сделал это сам):
   ```bash
   sudo -u postgres psql -c "CREATE ROLE replicator WITH LOGIN REPLICATION ENCRYPTED PASSWORD 'your_password';"
   ```

### 2) Настройка Standby

1. Отредактируйте переменные в `setup_standby_postgres.sh` (IP Primary, тот же пользователь/пароль, версия PG).
2. Запустите скрипт на Standby:
   ```bash
   sudo ./setup_standby_postgres.sh
   ```
3. Проверка статуса:
   - На Standby:
     ```sql
     SELECT pg_is_in_recovery();
     ```
     Должно быть `t` (true).
   - На Primary:
     ```sql
     SELECT client_addr, state, sync_state FROM pg_stat_replication;
     ```

## Проверка состояния репликации

- На Primary:
  ```sql
  SELECT pid, usename, client_addr, state, sync_state FROM pg_stat_replication;
  ```
- На Standby:
  ```sql
  SELECT pg_is_in_recovery(),
         pg_last_wal_receive_lsn(),
         pg_last_wal_replay_lsn(),
         now() - pg_last_xact_replay_timestamp() AS replay_delay;
  ```

## Как интерпретировать проверки (что считается «нормой»)

### На Primary (`pg_stat_replication`)
Запрос:
```sql
SELECT client_addr, state, sync_state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```
Что должно быть:
- **Строка(и) есть** — Standby(и) подключены.
- **state = 'streaming'** — идёт потоковая передача WAL.
- **sync_state = 'async'** (или `sync`/`potential` — смотря что настроено).
- **lag-колонки** (`write_lag/flush_lag/replay_lag`) — как можно ближе к `00:00:00`.
- **client_addr** — IP вашего Standby.

Если **нет строк** → Standby не подключён (см. сеть/пароль/`pg_hba.conf`/`listen_addresses`).

### На Standby
Запросы:
```sql
SELECT pg_is_in_recovery();                    -- должно быть t
SELECT pg_last_wal_receive_lsn();              -- последний полученный LSN
SELECT pg_last_wal_replay_lsn();               -- последний применённый LSN
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;  -- оценка лага по времени
```
Что должно быть:
- **pg_is_in_recovery = t** — узел в режиме реплики.
- **LSN-ы растут** со временем; `replay_lsn` догоняет `receive_lsn`.
- **replay_delay ≈ 0** (или несколько секунд при нагрузке). `NULL` бывает при отсутствии свежих транзакций.

### Короткий чеклист
- «**Репликация настроена**» — есть роль `REPLICATION`, `pg_hba.conf` содержит доступ для Standby, на Primary `wal_level=replica`, `max_wal_senders>0`, на Standby есть `standby.signal`/`primary_conninfo`.
- «**Репликация работает**» — на Primary видна строка в `pg_stat_replication` со **state='streaming'**, на Standby **`pg_is_in_recovery = t`**, LSN/время продвигаются.
- «**Есть отставание**» — большие значения `replay_lag/flush_lag/write_lag` на Primary или большой `replay_delay` на Standby; LSN почти не двигается.

### Частые проблемы и куда смотреть
- **FATAL: password authentication failed** — неверный пароль роли репликации или нет строки в `pg_hba.conf` (`host replication … md5`).  
- **no connection / нет строк в `pg_stat_replication`** — firewall/порт 5432, `listen_addresses`, `client_addr` не совпадает.  
- **`pg_is_in_recovery = f` на Standby** — реплика была промоутнута (или нет `standby.signal`).  
- **Лаг растёт** — высокая нагрузка/медленный диск на Standby; проверьте `replay_lag`/`replay_delay` и I/O.

## Переключение ролей (Failover)

### Повышение Standby до Primary
На **Standby**:
```bash
sudo -u postgres pg_ctl -D /var/lib/postgresql/<VERSION>/main promote
# либо (Ubuntu):
sudo -u postgres pg_ctlcluster <VERSION> main promote


export PG_CONF="/etc/postgresql/16/main/postgresql.conf"
sed -i "s/^#\?wal_level.*/wal_level = replica/" "$PG_CONF"
sed -i "s/^#\?max_wal_senders.*/max_wal_senders = 10/" "$PG_CONF"
sed -i "s/^#\?max_replication_slots.*/max_replication_slots = 10/" "$PG_CONF"

export PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
grep -qF "host    replication    replicator    10.10.10.2/24    md5" "$PG_HBA" \
  || sed -i '$a host    replication    replicator    10.10.10.2/24    md5' "$PG_HBA"

systemctl restart postgresql

su - postgres
createuser --replication -P repluser

```
Проверить:
```sql
SELECT pg_is_in_recovery();  -- должно быть f
SELECT client_addr, state FROM pg_stat_replication;
```

### Подключение старого Primary как Standby к новому Primary
На **старом Primary** (теперь будет Standby):
1. Остановить сервис и очистить каталог данных (внимание — удаляет локальные данные):
   ```bash
   systemctl stop postgresql
   rm -rf /var/lib/postgresql/16/main/*
   ```
2. Инициализация из нового Primary при помощи `pg_basebackup`:
   ```bash
   export PGPASSWORD='your_password'
   sudo -u postgres pg_basebackup -h <NEW_PRIMARY_IP> -U replicator -D /var/lib/postgresql/<VERSION>/main -X stream -R -P
   unset PGPASSWORD
   chown -R postgres:postgres /var/lib/postgresql/<VERSION>/main
   systemctl start postgresql
   ```
   Ключ `-R` создаст `standby.signal` и `primary_conninfo`.

## Примечания
- Обязательные параметры на Primary: `wal_level=replica`, `max_wal_senders>=5`, `listen_addresses='*'`.
- На Standby `pg_basebackup -R` сам создаёт `standby.signal` и `primary_conninfo` — вручную `recovery.conf` создавать не нужно (в PG ≥ 12).
- Аутентификация: в `pg_hba.conf` на Primary должна быть строка доступа типа `host replication <REPL_USER> <STANDBY_IP>/32 md5`.