# PostgreSQL Репликация: Скрипты настройки Primary и Standby

## Описание

В репозитории три файла для автоматизации настройки **физической** репликации PostgreSQL:
- **setup_primary_postgres_clean.sh** — настраивает первичный сервер (Primary): включает WAL, создаёт пользователя репликации, правит `postgresql.conf` и `pg_hba.conf`.
- **setup_standby_postgres_clean.sh** — настраивает резервный сервер (Standby): останавливает сервис, делает `pg_basebackup` с Primary и включает потоковую репликацию.
- **README_postgres_clean.md** — этот файл, с инструкциями, проверками и фейловером.

> Скрипты рассчитаны на Debian/Ubuntu-пакеты (`systemd`), с путями вида `/etc/postgresql/<версия>/main` и `/var/lib/postgresql/<версия>/main`. При необходимости поправьте переменные в начале скриптов.

## Требования

- PostgreSQL установлен на обоих серверах (Primary и Standby).
- Доступ суперпользователя PostgreSQL (`postgres`) на обоих серверах.
- Сетевое соединение между узлами (порт 5432 открыт).
- На Standby установлен клиент `pg_basebackup` (обычно в пакете `postgresql-client` или `postgresql-<версия>`).

## Порядок настройки

### 1) Настройка Primary

1. Отредактируйте переменные в `setup_primary_postgres_clean.sh` (IP Standby, пароль/пользователь, версия PG).
2. Запустите скрипт на Primary:
   ```bash
   sudo ./setup_primary_postgres_clean.sh
   ```
3. Убедитесь, что Primary слушает снаружи и параметры применены:
   ```bash
   sudo systemctl status postgresql
   ```
4. Создайте пользователя для репликации (если скрипт не сделал это сам):
   ```bash
   sudo -u postgres psql -c "CREATE ROLE replicator WITH LOGIN REPLICATION ENCRYPTED PASSWORD 'Ee123456';"
   ```

### 2) Настройка Standby

1. Отредактируйте переменные в `setup_standby_postgres_clean.sh` (IP Primary, тот же пользователь/пароль, версия PG).
2. Запустите скрипт на Standby:
   ```bash
   sudo ./setup_standby_postgres_clean.sh
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

## Переключение ролей (Failover)

### Повышение Standby до Primary
На **Standby**:
```bash
sudo -u postgres pg_ctl -D /var/lib/postgresql/<VERSION>/main promote
# либо (Ubuntu):
sudo -u postgres pg_ctlcluster <VERSION> main promote
```
Проверить:
```sql
SELECT pg_is_in_recovery();  -- должно быть f
```

### Подключение старого Primary как Standby к новому Primary
На **старом Primary** (теперь будет Standby):
1. Остановить сервис и очистить каталог данных (внимание — удаляет локальные данные):
   ```bash
   sudo systemctl stop postgresql
   sudo rm -rf /var/lib/postgresql/<VERSION>/main/*
   ```
2. Инициализация из нового Primary при помощи `pg_basebackup`:
   ```bash
   export PGPASSWORD='Ee123456'
   sudo -u postgres pg_basebackup -h <NEW_PRIMARY_IP> -U replicator -D /var/lib/postgresql/<VERSION>/main -X stream -R -P
   unset PGPASSWORD
   sudo chown -R postgres:postgres /var/lib/postgresql/<VERSION>/main
   sudo systemctl start postgresql
   ```
   Ключ `-R` создаст `standby.signal` и `primary_conninfo`.

## Примечания
- Обязательные параметры на Primary: `wal_level=replica`, `max_wal_senders>=5`, `listen_addresses='*'`.
- На Standby `pg_basebackup -R` сам создаёт `standby.signal` и `primary_conninfo` — вручную `recovery.conf` создавать не нужно (в PG ≥ 12).
- Аутентификация: в `pg_hba.conf` на Primary должна быть строка доступа типа `host replication <REPL_USER> <STANDBY_IP>/32 md5`.