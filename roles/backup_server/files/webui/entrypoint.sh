#!/bin/sh
# bareos-webui-proxy (WebSocket/API прокси к Director, порт 9104) + apache2 (статика Vue + проксирует
# /bareos-webui-new/{ws,api} на localhost:9104) — оба процесса в одном контейнере, см.
# docs/adr/0009-backup-server-role.md §8.
set -e

# --config, не -c (реальный CLI: "bareos-webui-proxy --help" -> "--config TEXT:FILE=/etc/
# bareos-webui-proxy/bareos-webui-proxy.ini" — -c просто не распознаётся, "The following
# arguments were not expected", процесс падал сразу же и не запускался вообще, найдено реальным
# прогоном demo/backup, docs/adr/0009-backup-server-role.md §9).
bareos-webui-proxy --config /etc/bareos-webui-proxy/bareos-webui-proxy.ini &

exec apache2ctl -D FOREGROUND
