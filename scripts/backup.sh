#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$BACKUP_DIR/reservas_$STAMP.sql"

cd "$ROOT_DIR"
docker compose exec -T db sh -c \
  'mariadb-dump --single-transaction --routines --triggers -uroot -p"$MARIADB_ROOT_PASSWORD" --databases reservas' \
  > "$OUT"

echo "Backup criado em: $OUT"
