#!/usr/bin/env bash
set -euo pipefail
docker compose up -d
echo "Odoo is starting... open: http://127.0.0.1:8069"
echo "Postgres: localhost:5433 user=odoo pass=odoo"
