#!/bin/bash

set -e

echo "Create pghoard directories..."
mkdir -p /home/postgres/restore
chmod 700 /home/postgres/restore
chown -R postgres /home/postgres

echo "Create pghoard configuration with confd ..."
if getent hosts rancher-metadata; then
  confd -onetime -backend rancher -prefix /2015-12-19
else
  confd -onetime -backend env
fi

echo "Dump configuration..."
cat /home/postgres/pghoard_restore.json

echo "Set pghoard to maintenance mode"
touch /tmp/pghoard_maintenance_mode_file

echo "Get the latest available basebackup ..."
gosu postgres pghoard_restore get-basebackup --config pghoard_restore.json --site $PGHOARD_RESTORE_SITE --target-dir restore --restore-to-master --recovery-target-action promote --recovery-end-command "pkill pghoard" --overwrite $*

# Set minimal configuration
gosu postgres echo "
listen_addresses = '*'
max_connections = 1000
" > restore/postgresql.conf

gosu postgres echo "
local all all trust
host  all all 127.0.0.1/32 trust
host  all all localhost    md5
" > restore/pg_hba.conf

touch /home/postgres/restore/recovery.signal

echo "Starting the pghoard daemon ..."
gosu postgres pghoard --short-log --config /home/postgres/pghoard_restore.json &

if [ -z "$RESTORE_CHECK_COMMAND" ]; then
  # Manual mode
  # Just start PostgreSQL
  echo "Starting PostgresSQL ..."
  exec gosu postgres postgres -D restore
else
  # Automatic test mode

  # Send data to the real postgresql so that it will be checked during the next backup check
  # 1. Send data to real postgres
  # 2. Backup is done, with those new data
  # 3. Next restore tests that this new data is present in backup
  PGPASSWORD=$RESTORE_TEST_PASSWORD psql --host $PG_HOST --port $PG_PORT --dbname $RESTORE_TEST_DATABASE -U $RESTORE_TEST_USER \
    -c 'CREATE TABLE IF NOT EXISTS pghoard_restore_test_date (
              id         SERIAL PRIMARY KEY,
              created_at TIMESTAMPTZ DEFAULT Now()
        );
        INSERT INTO pghoard_restore_test_date DEFAULT VALUES;
    '

  # Run test commands against PostgreSQL server and exit
  echo "Starting PostgresSQL ..."
  gosu postgres pg_ctl -D restore start

  # Give postgres some time before starting the harassment
  sleep 20

  until gosu postgres psql -At -c "SELECT * FROM pg_is_in_recovery()" | grep -q f
  do
    sleep 5
    echo "AutoCheck: waiting for restoration to finish..."
  done

  echo "AutoCheck: Checking that yesterday's insertion is in today's backup..."
  SQL="SELECT created_at FROM pghoard_restore_test_date WHERE created_at > NOW() - INTERVAL '2 day';"
  OUT=$(gosu postgres psql --dbname $RESTORE_TEST_DATABASE -c "$SQL")
  echo $OUT
  OUT_LINES=$( echo $OUT | wc -l)
  echo "AutoCheck: $OUT_LINES lines returned"

  if [ $OUT_LINES -gt 0 ]; then
    echo "AutoCheck: SUCCESS"
    BUILTIN_RES=1
  else
    echo "AutoCheck: FAILURE"
    BUILTIN_RES=0
  fi


  echo "AutoCheck: running command on db..."
  OUT=$(gosu postgres psql --dbname $RESTORE_TEST_DATABASE -c "$RESTORE_CHECK_COMMAND")
  echo $OUT
  OUT_LINES=$(echo $OUT | wc -l)
  echo "AutoCheck: $OUT_LINES lines returned"

  if [ $OUT_LINES -gt 0 ]; then
    echo "AutoCheck: SUCCESS"
    RES=1
  else
    echo "AutoCheck: FAILURE"
    RES=0
  fi

  if [[ $BUILTIN_RES && $RES ]]; then
    echo "Daily PostgreSQL backup test succeeded"
    exit 0
  else
    echo "Daily PostgreSQL backup test failed"
    echo "Please see logs for more informations"
    exit 1
  fi
fi
