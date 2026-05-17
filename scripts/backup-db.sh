#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /opt/app/.env

: "${POSTGRES_DB:?need POSTGRES_DB}"
: "${POSTGRES_USER:?need POSTGRES_USER}"

BACKUP_DIR=/var/backups/app
KEEP_DAYS=7
DATE=$(date +%Y%m%d-%H%M%S)
FILE="$BACKUP_DIR/db-$DATE.sql.gz"

mkdir -p "$BACKUP_DIR"

docker exec app-postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$FILE"

if [ ! -s "$FILE" ]; then
  echo "backup empty, abort" >&2
  exit 1
fi

find "$BACKUP_DIR" -type f -name 'db-*.sql.gz' -mtime +"$KEEP_DAYS" -delete

echo "backup ok: $FILE"
