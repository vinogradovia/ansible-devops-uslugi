# infra_panel

Дашборд-стартовая страница со ссылками на установленные компоненты платформы — обёртка над
[homer](https://github.com/bastienwirtz/homer). Разворачивается на сервере мониторинга (том же
хосте, что и `monitoring_server`), оркестратор выбирается той же переменной-конвенцией, что и в
`monitoring_server`/`monitoring_agent` (`infra_panel_orchestrator: docker|k3s`).

## Статус

- **docker** — реализовано (эта роль).
- **k3s** — пока не реализовано на уровне роли. Рабочий пример деплоя через
  `nxs-universal-chart` есть в `helm/` (релиз `homer` в `helm/envs/k3s-monitoring.yaml`,
  разворачивается той же командой `Helmwave up`, что и остальной k3s-стек
  `monitoring_server` — см. `docs/adr/0007-monitoring-server-role.md`), но конфигурация ссылок
  там статична (не читает `infra_panel_*`-переменные) — интеграция с этой ролью впереди.

## Зависит от

Роли `docker` (`meta/main.yml`, `when: infra_panel_orchestrator == 'docker'`) — сама Docker Engine
не устанавливает.

Публикация наружу — через `reverse_proxy_traefik` (Docker-провайдер по shared-сети `proxy`,
`traefik.*`-labels на контейнере homer, как у `grafana` в `monitoring_server`). Роль не
устанавливает Traefik сама и не создаёт сеть `proxy` по умолчанию
(`infra_panel_docker_proxy_network_external: true`) — она должна быть создана заранее (обычно
роль `reverse_proxy_traefik`), либо переключите
`infra_panel_docker_proxy_network_external: false`.

## Обязательные шаги перед использованием

- `infra_panel_users` — список пользователей basic-auth (`{name, password, state}`, `state` по
  умолчанию `present`). Роль падает на этапе `check-and-install-requirements.docker.yml`, если
  пароль хотя бы одного пользователя с `state: present` совпадает с дефолтным
  `infra_panel_default_password` (`"PleAse_Change_ME!"`) — панель агрегирует ссылки на весь
  внутренний инструментарий платформы, анонимный/дефолтный доступ недопустим.
- `infra_panel_domain` — домен, на котором публикуется панель (`Host()`-правило Traefik).

## Ссылки на дашборде

`services:` в итоговом `config.yml` homer собирается из двух источников (мёржатся):

1. **Авто** — если в этом же play применена роль `monitoring_server` с
   `monitoring_server_grafana_enabled: true`, в группу `infra_panel_auto_monitoring_group_name`
   (по умолчанию "Monitoring") автоматически добавляется ссылка на Grafana
   (`monitoring_server_grafana_server_domain`). Переменные `monitoring_server_*` читаются как
   обычные vars той же плейбук-области видимости — если роль `monitoring_server` не применялась,
   просто ничего не добавляется, без ошибки.
2. **Ручное** — `infra_panel_extra_services`, список групп/пунктов в родном формате homer
   (см. [конфигурацию homer](https://github.com/bastienwirtz/homer#configuration)).

## basic-auth: как это устроено под capot

Traefik (роль `reverse_proxy_traefik`) не монтирует файлы `infra_panel_config_dir` внутрь своего
контейнера — это отдельный docker-compose проект. Поэтому пароли не идут через
`usersFile`, а инлайнятся прямо в label контейнера homer
(`traefik.http.middlewares.infra-panel-auth.basicauth.users=...`): apr1-хэш считает
`community.general.htpasswd` на управляемом хосте (пишет
`{{ infra_panel_config_dir }}/users/infra-panel-auth`), а не Jinja-фильтр `password_hash` — тот
исполняется на контроллере, где `passlib` не установлен (в отличие от управляемого хоста, куда
его ставит `check-and-install-requirements.docker.yml`).
