#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$SCRIPT_DIR" in
  /opt/testradio|/opt/testradio/*) ;;
  *)
    echo "Refusing to start outside /opt/testradio: $SCRIPT_DIR" >&2
    exit 2
    ;;
esac

cd "$SCRIPT_DIR"
./prepare-upstream.sh
docker compose build
docker compose up -d
docker compose exec -T tx5dr node /opt/testradio-bootstrap/configure-dummy.mjs
docker compose ps
