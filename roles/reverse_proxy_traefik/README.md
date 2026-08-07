# reverse_proxy_traefik

Разворачивает [Traefik](https://traefik.io/) в docker как reverse proxy с автообнаружением
контейнеров через Docker-провайдер, HTTP→HTTPS редиректом и дашбордом за basic-auth.

## Назначение

Reverse proxy для docker-хостов, где сервисы объявляют свои роуты декларативно через
docker-labels (`traefik.enable=true`, `traefik.http.routers...`), а не через отдельный конфиг на
каждый домен — в этом отличие от `nginx_multidomain` (конфиг в YAML-инвентаре) и
`reverse_proxy_npm` (конфиг через GUI/REST API). **Взаимоисключающая** с этими двумя ролями на
одном хосте — все три занимают порты 80/443.

Зависит от роли `docker` (`meta/main.yml`, безусловно) — сама Docker Engine не устанавливает.

## Обязательные шаги перед использованием

- `reverse_proxy_traefik_dashboard_users` — список пользователей дашборда
  (`{name, password, state}`, `state` по умолчанию `present`). Роль падает на этапе
  `check-and-install-requirements.yml`, если пароль хотя бы одного пользователя с
  `state: present` совпадает с дефолтным `reverse_proxy_traefik_default_password`
  (`"PleAse_Change_ME!"`).

## Дашборд

Дашборд Traefik (`api@internal`) публикуется на
`https://traefik-dashboard.{{ reverse_proxy_traefik_internal_domain }}` за basic-auth
(`community.general.htpasswd`, файл `{{ reverse_proxy_traefik_config_dir }}/users/dashboard-auth`).
`reverse_proxy_traefik_internal_domain` по умолчанию — `docker.localhost` (нужен реальный резолвинг
DNS/hosts на этот домен, чтобы дашборд открылся).

Порт `8080` (небезопасный API/dashboard endpoint Traefik) также проброшен в compose — используется
только для отладки, в проде закрывайте его на файрволе.

## Пример fixture-приложения

Compose-файл включает тестовый контейнер `traefik/whoami`, доступный на
`https://whoami.{{ reverse_proxy_traefik_internal_domain }}` — удобен для проверки, что сам
Traefik и Docker-провайдер работают, прежде чем подключать реальные сервисы. Реальные сервисы
подключаются добавлением таких же `traefik.*` label'ов в их собственные compose-файлы/стеки в той
же docker-сети `proxy`.

## Dynamic-конфиги потребителей (`reverse_proxy_traefik_extra_dynamic_files`)

Список `{name, content}` — `content` рендерится как есть в
`{{ reverse_proxy_traefik_config_dir }}/dynamic/{{ name }}.yml` (file-провайдер Traefik,
перечитывается сам, без рестарта). Для того, что в принципе нельзя выразить через
docker-labels потребителя — например, `TLSOptions.alpnProtocols` (Traefik требует, чтобы
TLSOptions были определены не через docker-провайдер, только через file/CRD; понадобилось
роли `backup_server` — WebSocket-апгрейд к `bareos-webui-proxy` ломался при HTTP/2,
`docs/adr/0009-backup-server-role.md` §11). Ресурс, определённый так, роль-потребитель
подключает через `<имя-ресурса>@file` в своих собственных labels (тот же принцип, что
`dashboard-auth@file` для basicAuth-middleware самого дашборда, см. `templates/
traefik-dashboard.yml.j2`). Композиция на уровне плейбука-оператора — `reverse_proxy_traefik`
не тянет `backup_server`/другие потребители зависимостью и наоборот (см. `docs/adr/
0008-infra-panel-role.md` §3).

## Известные ограничения

- TLS-сертификаты не автоматизированы этой ролью (нет ACME-провайдера в `command:` Traefik) —
  сертификаты нужно класть в `{{ reverse_proxy_traefik_config_dir }}/certs` и подключать через
  `dynamic/`-конфиги отдельно.
- Роль полагается на то, что docker-compose v2 уже доступен на хосте — обеспечивается зависимостью
  от роли `docker`.
