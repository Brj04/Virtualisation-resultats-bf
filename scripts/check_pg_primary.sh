#!/usr/bin/env bash
set -u

IP="${HAPROXY_SERVER_ADDR:-}"
PORT="${HAPROXY_SERVER_PORT:-5432}"

[ -n "$IP" ] || exit 1

RESULTAT=$(
    PGPASSFILE=/var/lib/haproxy/.pgpass \
    PGCONNECT_TIMEOUT=2 \
    psql -X -w -qAt \
        -h "$IP" \
        -p "$PORT" \
        -U resultats_app \
        -d resultats \
        -c "SELECT NOT pg_is_in_recovery();" \
        2>/dev/null
) || exit 1

[ "$RESULTAT" = "t" ]