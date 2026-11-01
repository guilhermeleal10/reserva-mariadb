#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Uso: $0 caminho/do/backup.sql" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "ATENCAO: a restauracao pode sobrescrever dados existentes."
read -r -p "Digite RESTAURAR para continuar: " CONFIRM
if [[ "$CONFIRM" != "RESTAURAR" ]]; then
  echo "Operacao cancelada."
  exit 1
fi

docker compose exec -T db sh -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' \
  < "$1"

echo "Restauracao concluida. Verifique os dados antes de voltar ao uso."
