# infra_panel

Дашборд-стартовая страница со ссылками на установленные компоненты платформы — обёртка над
[homer](https://github.com/bastienwirtz/homer). Разворачивается на сервере мониторинга (том же
хосте, что и `monitoring_server`), оркестратор выбирается той же переменной-конвенцией, что и в
`monitoring_server`/`monitoring_agent` (`infra_panel_orchestrator: docker|k3s`).

## Статус

- **docker** — реализовано.
- **k3s** — реализовано, но иначе устроено: роль **не** создаёт k8s-объекты и не устанавливает
  k3s/Helm — релиз `homer` уже часть общего Helmwave-стека (`helm/envs/k3s-monitoring.yaml`,
  тот же env-файл, что использует `monitoring_server_orchestrator: k3s`, см.
  `docs/adr/0007-monitoring-server-role.md` §6). `roles/infra_panel/tasks/infra-panel.k3s.yml`
  только рендерит values-файл этого релиза
  (`helm/values/k3s-monitoring/namespaces/monitoring/homer/values.yaml`) из тех же переменных,
  что docker-путь — `delegate_to: localhost`, т.к. Helmwave выполняется только с control-хоста.
  **Важно про порядок плеёв:** при `infra_panel_orchestrator: k3s` роль `infra_panel` должна
  идти в play **раньше** `monitoring_server` — иначе рендер значений появится на диске, но
  применится только следующим прогоном `Helmwave up` (для docker-пути порядок обратный: `infra_panel`
  читает уже готовые `monitoring_server_grafana_*`-переменные, порядок исполнения ролей там не
  важен, так как это просто group_vars, не результат работы роли).

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

Под k3s весь рендер (включая хэш) и так выполняется на контроллере (`delegate_to: localhost`),
поэтому `passlib` там нужен на control-хосте — poetry dev-зависимость коллекции (как `kubernetes`
для `monitoring_server_orchestrator: k3s`), устанавливается `poetry install`.

## k3s: переменные

- `infra_panel_helmwave_dir` (default: `{{ role_path | dirname | dirname }}/helm`) — где искать
  дерево `values/`, должно совпадать с тем, что использует `monitoring_server`
  (`monitoring_server_helmwave_dir`) для того же кластера.
- `infra_panel_helmwave_k8s_cluster` (default: `k3s-monitoring`) — имя env-файла
  (`helm/envs/<...>.yaml`), должно совпадать с `monitoring_server_helmwave_k8s_cluster`.
- `infra_panel_kubernetes_namespace` (default: `monitoring`) — где развёрнут релиз `homer`.
- `infra_panel_kubernetes_release_name` (default: `homer`) — буквальное имя релиза в
  `helm/helmwave.yml`; влияет на итоговые имена k8s-объектов (`helper.fullname` чарта), меняется
  только вместе с самим `helmwave.yml`, не независимо.
- `infra_panel_domain`/`infra_panel_users`/`infra_panel_extra_services`/`infra_panel_title` и
  т.д. — те же переменные, что и в docker-пути.
