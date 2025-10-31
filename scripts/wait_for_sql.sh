#!/usr/bin/env bash
set -euo pipefail

SERVER="${1:-localhost,1433}"
USER="${2:-SA}"
PASSWORD="${3:-Your_password123}"
TIMEOUT_SECONDS="${4:-120}"

SQLCMD_BIN="${SQLCMD_BIN:-}"
if [[ -z "$SQLCMD_BIN" ]]; then
  if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
    SQLCMD_BIN=/opt/mssql-tools18/bin/sqlcmd
  elif [[ -x /opt/mssql-tools/bin/sqlcmd ]]; then
    SQLCMD_BIN=/opt/mssql-tools/bin/sqlcmd
  else
    echo "Unable to locate sqlcmd binary." >&2
    exit 1
  fi
fi

DEADLINE=$((SECONDS + TIMEOUT_SECONDS))

until "$SQLCMD_BIN" -C -S "$SERVER" -U "$USER" -P "$PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; do
  if (( SECONDS >= DEADLINE )); then
    echo "Timed out waiting for SQL Server on $SERVER" >&2
    exit 1
  fi
  sleep 3
done

echo "SQL Server is ready on $SERVER"
