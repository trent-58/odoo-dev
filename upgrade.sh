#!/usr/bin/env bash
set -euo pipefail
DB="${1:-jasmin-database}"
docker exec -it $(docker compose ps -q odoo) bash -lc "odoo -c /etc/odoo/odoo.conf -d '$DB' -u customer_credit_control -u mini_sales_approval --stop-after-init"
docker compose restart odoo
echo "Upgraded modules in DB '$DB' and restarted Odoo."
