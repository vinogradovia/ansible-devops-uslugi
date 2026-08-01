# ADR-0008: Роль `infra_panel` (дашборд-стартовая страница платформы, homer)

- **Статус:** Принято (docker-путь реализован; k3s-путь роли — открытый вопрос, см. ниже)
- **Дата:** 2026-08-01
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения и реализации)

## Контекст

Коллекция `devops.uslugi` — универсальная IT-платформа из нескольких независимых компонентов
(мониторинг, DNS, reverse-proxy, БД HA и т.д.), каждый из которых после установки живёт на своём
домене/порту. У оператора нет единой точки входа со ссылками на всё, что реально развёрнуто на
конкретном инстансе платформы — только знание конкретных доменов из инвентаря.

Решено добавить дашборд-стартовую страницу со ссылками на установленные компоненты — за основу
взят [homer](https://github.com/bastienwirtz/homer) (легковесный статический дашборд, YAML-конфиг,
без бэкенда/БД). Разворачивается на сервере мониторинга — том же хосте, где `monitoring_server`, —
как "ядро проекта" (формулировка из исходного запроса), а не на каждом хосте платформы.

Ключевые развилки были закрыты в ходе обсуждения (`AskUserQuestion`) и последующей реализации, а не
все — заранее одним решением; часть технических деталей (§5, §6) обнаружена эмпирически в процессе
реализации и задокументирована здесь постфактум, по аналогии с тем, как ADR-0007 фиксирует находки
из практики.

## Решения

### 1. Место среди существующих ролей — новая самостоятельная роль `infra_panel`

**Решение:** отдельная роль `roles/infra_panel/`, а не часть `monitoring_server`. Не является
заменой/альтернативой ни одной существующей роли и не взаимоисключающая ни с чем (в отличие от
`nginx_multidomain`/`reverse_proxy_traefik`/`reverse_proxy_npm`) — это дополнительное веб-приложение
позади уже существующего reverse-proxy, а не сам reverse-proxy.

**Обоснование:** `monitoring_server` уже сочетает два оркестратор-бэкенда, Grafana-дашборды,
алертинг — добавление туда ещё одного веб-приложения увеличило бы и без того широкую
ответственность роли. Отдельная роль тестируется независимо (свой molecule-сценарий в будущем, см.
§8) и может быть не подключена вовсе, если панель не нужна.

### 2. Оркестраторы — docker реализован, k3s пока не (роль)

**Решение:** переменная-конвенция `infra_panel_orchestrator: docker|k3s`, как в
`monitoring_server`/`monitoring_agent`. На момент принятия ADR **реализован только docker-путь**
(`roles/infra_panel/tasks/infra-panel.docker.yml`, `meta/main.yml` тянет роль `docker` условно,
`when: infra_panel_orchestrator == 'docker'` — по образцу `monitoring_agent`, а не безусловно, как
`reverse_proxy_traefik`, чтобы не требовать переделок при добавлении k3s-ветки).

Для k3s есть рабочий, но **не интегрированный с ролью** пример: релиз `homer` в
`helm/envs/k3s-monitoring.yaml`, разворачиваемый той же командой `Helmwave up`, что и весь
остальной k3s-стек `monitoring_server` (ADR-0007 §6) — то есть на кластере с k3s-путём
`monitoring_server` homer уже физически разворачивается уже сейчас, но со статичным примером
конфига, не читающим `infra_panel_*`-переменные. Довести это до полноценного k3s-пути роли
(шаблонизация `config.yml`/basic-auth из тех же переменных, что и в docker-пути) — открытый вопрос,
см. §9.

### 3. Источник ссылок дашборда — авто (из `monitoring_server`) + ручные extra

**Решение:** `services:` итогового `config.yml` собирается из двух источников:

1. **Авто** — если в том же play применена роль `monitoring_server` с
   `monitoring_server_grafana_enabled: true`, ссылка на Grafana добавляется автоматически
   (`monitoring_server_grafana_server_domain`). Переменные читаются как обычные vars той же
   области видимости плейбука (role defaults одной роли видны другим ролям того же play в
   Ansible) — без `hostvars`, без ошибки, если `monitoring_server` не применялась
   (`default(false)`/`is defined`).
2. **Ручное** — `infra_panel_extra_services`, список групп/пунктов в родном формате homer.

**Отклонённая альтернатива:** кросс-ролевой автодискавери по всей платформе (сбор ссылок с
`reverse_proxy_traefik`/`reverse_proxy_npm`/`nginx_multidomain`/`infra_dns` через `hostvars` по
всему inventory) — мощнее, но требует новой архитектурной связности между независимыми ролями,
которых сейчас в коллекции сознательно нет ни у одной пары ролей. Отложено; §1 явно фиксирует
`infra_panel` как не более чем "приложение позади reverse-proxy", а не оркестратор знаний о всей
платформе.

**Технический долг:** сейчас в авто-блок заведена только Grafana — VictoriaMetrics/другие
компоненты `monitoring_server` не имеют собственного публичного домена в docker-пути (не
проксируются через Traefik в `compose-monitoring-server.yml.j2`), поэтому добавить их в авто-список
пока не из чего.

### 4. Публикация и доступ — за `reverse_proxy_traefik`, basic-auth обязателен

**Решение:** homer подключается к shared docker-сети `proxy` и объявляет себя через
`traefik.*`-labels (Docker-провайдер) — тем же способом, каким `grafana` подключена в
`compose-monitoring-server.yml.j2`. Целевая reverse-proxy роль — конкретно
`reverse_proxy_traefik`, а не абстрактная "любая" (`nginx_multidomain`/`reverse_proxy_npm`
рассматривались, но `reverse_proxy_traefik` — единственная, где podключение декларативно через
labels без необходимости писать конфиг в чужую роль/директорию, и она уже используется
`monitoring_server` тем же способом).

Basic-auth **обязателен без опции отключения** — панель агрегирует ссылки на весь внутренний
инструментарий платформы, анонимный доступ недопустим. Дефолтный пароль (`"PleAse_Change_ME!"`)
фейлит установку (`check-and-install-requirements.docker.yml`), паттерн 1-в-1 из ADR-0001 §5 /
`reverse_proxy_traefik`.

**Следствие (см. §6):** `reverse_proxy_traefik` — отдельный docker-compose проект и не примонтирует
файлы `infra_panel_config_dir` в свой контейнер, поэтому обычный для роли `reverse_proxy_traefik`
механизм `usersFile` (файл на диске, путь внутри контейнера Traefik) для `infra_panel` не подходит.

### 5. k3s-чарт — локальный `nxs-universal-chart`, не официальный чарт homer и не голые манифесты

**Решение:** в качестве примера k3s-деплоя (см. §2) использован уже вендоренный в
`helm/localrepo/` generic-чарт `nxs-universal-chart` (deployments/services/configMaps/secrets +
нативные Traefik CRD), а не:

- **официальный Helm-чарт homer** — не существует (только community-варианты, проверено по
  апстрим-документации homer);
- **голые k8s-манифесты через `ansible.builtin.k8s`** — паттерн, которым `monitoring_server`
  применяет VMScrapeConfig/VMRule напрямую (ADR-0007 §6), но для полноценного
  Deployment+Service+ConfigMap+Secret+IngressRoute+Middleware означал бы писать и поддерживать
  шесть Jinja-шаблонов манифестов с нуля, дублируя то, что уже есть в `nxs-universal-chart`.

**Технические находки в процессе (эмпирически проверено, `helm 3.21.3`):**

- `helm/localrepo/` изначально содержал `index.yaml` + `universal-chart-2.8.1.tgz`, подразумевая
  использование как Helm-репозитория — не заработало бы: Helm 3 не поддерживает схему `file://`
  для `helm repo add` (`Error: could not find protocol handler for: file`).
- Ссылка на чарт напрямую как на `.tgz`-путь (`chart.name: localrepo/universal-chart-2.8.1.tgz`,
  без repositories вообще) резолвится helmwave как локальный чарт, но падает на
  `helm dependency update` — Helm отказывается обновлять зависимости у **запакованных** чартов
  (`only unpacked charts can be updated`), даже если у чарта нет ни одной зависимости.
- Решение: чарт распакован в `helm/localrepo/universal-chart/` (директория, не архив) — на такой
  путь helmwave ссылается напрямую (`chart: localrepo/universal-chart`) без записи в
  `repositories:` вообще; итоговые манифесты проверены `helm template` и `helmwave build`.

### 6. basic-auth в docker-пути — hash инлайном в label, не `usersFile`

**Решение:** apr1-хэш пароля считает `community.general.htpasswd` **на управляемом хосте**
(`infra_panel_config_dir/users/infra-panel-auth`), результат читается обратно `ansible.builtin.slurp`
и подставляется прямо в docker-label контейнера homer
(`traefik.http.middlewares.infra-panel-auth.basicauth.users=user:$$apr1$$...`, `$` экранирован
как `$$` для docker-compose).

**Отклонённая альтернатива:** Jinja-фильтр `password_hash('apr_md5_crypt')` (считался бы на
контроллере, без лишней ansible-задачи) — не работает в этом окружении: `passlib` установлен
`check-and-install-requirements.docker.yml` только на управляемый хост (как и в
`reverse_proxy_traefik`), на контроллере (poetry venv коллекции) его нет и добавлять как
Python-зависимость коллекции ради одного фильтра избыточно. Проверено эмпирически
(`ansible ... -a "msg={{ '...' | password_hash(...) }}"` падает с `passlib must be installed`).

**Отклонённая альтернатива №2:** `usersFile` (как у собственного дашборда `reverse_proxy_traefik`)
— потребовала бы монтировать директорию `infra_panel` в контейнер Traefik, которым владеет другая
роль (кросс-ролевая связность по путям на диске) — не совместимо с §1 (роли независимы).

### 7. Версия образа — закреплена явно

**Решение:** `infra_panel_image_version: v26.4.2` (последний релиз homer на момент написания), а не
`latest` — согласуется с общим принципом коллекции пиннить версии образов явно (ADR-0007 §10.2,
пример `monitoring_server_victoria_metrics_image_version`).

### 8. `config.yml` не обновлялся в уже запущенном контейнере — найдено на живом demo-стенде

**Найдено** при смене `infra_panel_title` на реальном демо-стенде (`monitoring_servers`,
ADR-0006): повторный прогон роли рендерил новый `config.yml` (`ansible.builtin.template` репортил
`changed`), но `community.docker.docker_compose_v2` не видел изменений в самом `compose.yml` и не
пересоздавал/перезапускал контейнер — а `config.yml` смонтирован в контейнер отдельным bind-mount
файла (не частью compose-определения, см. §6 про причины). `ansible.builtin.template` переписывает
файл атомарно (temp + rename), поэтому уже запущенный контейнер продолжал держать старый inode —
через HTTP отдавался прежний контент, несмотря на изменившийся файл на диске.

**Исправлено:** `notify: Restart homer` на задаче рендера `config.yml`
(`tasks/infra-panel.docker.yml`) + handler `Restart homer`
(`community.docker.docker_compose_v2`, `state: restarted`, `handlers/main.yml`) — тот же паттерн,
что `roles/monitoring_server/handlers/main.yml` использует для
`grafana-dashboard-provider.yaml`/`Restart grafana` (та же причина: смонтированный файл вне
compose-определения).

**Технический долг:** molecule-сценарий (§Открытые вопросы, тестовое покрытие) не ловит такой
класс регрессий — `idempotence` перезапускает `converge` с теми же переменными, а не с
изменившимися, поэтому путь "конфиг изменился → handler сработал" им не покрыт.

## Открытые вопросы / вне скоупа

- **k3s-путь самой роли** (§2) — сейчас существует только статический пример в `helm/`, не
  подключённый к `infra_panel_*`-переменным и не запускаемый ролью `infra_panel` автоматически.
  Нужно решить: рендерить `config.yml`/basic-auth Secret из тех же переменных через
  `kubernetes.core.k8s` (по аналогии с CRD в `monitoring_server`), или встроить helmwave-релиз в
  саму роль.
- **Автогенерация basic-auth хэша в k3s-примере** — сейчас захардкожен плейсхолдер `admin/admin`
  (стандартный пример из документации Traefik) прямо в
  `helm/values/k3s-monitoring/namespaces/monitoring/homer/values.yaml`; при доведении k3s-пути
  роли до соответствия §6 нужно генерировать его тем же способом, что в docker-пути.
- **Кросс-ролевой автодискавери ссылок** (§3) — если в будущем понадобится собирать ссылки со всей
  платформы (не только с `monitoring_server` на одном хосте), потребует отдельного архитектурного
  решения о связности между независимыми ролями коллекции.
- ~~**Тестовое покрытие** — molecule-сценарий для `infra_panel` не создан~~ — **закрыто**:
  `extensions/molecule/infra_panel/` (см. CLAUDE.md, раздел «Molecule-тесты»), той же структуры,
  что `reverse_proxy_traefik`. Покрывает только docker-путь; k3s-сценарий появится вместе с
  реализацией k3s-пути роли (первый пункт этого раздела).
- **Иконки/логотипы для авто-сгенерированных пунктов** — сейчас хардкожены inline в шаблоне
  (`config.yml.j2`, `logo: https://grafana.com/...`) для Grafana; при добавлении новых
  авто-пунктов потребуется либо расширять шаблон, либо вынести маппинг компонент → иконка в
  отдельную переменную.
- **Molecule не покрывает регрессию "изменение конфига не подхватывается"** (§8) — идемпотентность
  проверяет отсутствие изменений при неизменных переменных, а не то, что handler `Restart homer`
  реально срабатывает и подхватывает новый `config.yml` при их изменении. Нужен отдельный шаг
  сценария (второй `converge` с другими `infra_panel_extra_services` + повторная HTTP-проверка
  контента), если такие регрессии станут повторяться.

## Ссылки

- `roles/infra_panel/` — реализация docker-пути (README.md роли — более подробное описание
  переменных и поведения).
- `extensions/molecule/infra_panel/` — molecule-сценарий docker-пути (см. открытые вопросы выше).
- `helm/envs/k3s-monitoring.yaml`, `helm/values/k3s-monitoring/namespaces/monitoring/homer/`,
  `helm/localrepo/universal-chart/` — пример k3s-деплоя (§2, §5).
- `docs/adr/0007-monitoring-server-role.md` §6 — механизм `Helmwave up`, переиспользованный для
  k3s-примера homer без изменений.
- `docs/adr/0001-reverse-proxy-npm-role.md` §5 — прецедент fail-fast на дефолтном
  admin-пароле, применённый к `infra_panel_default_password` (§4).
- `roles/reverse_proxy_traefik/` — паттерн basic-auth (`community.general.htpasswd`) и
  Docker-провайдер labels, частично переиспользованный, частично адаптированный (§4, §6).
- `roles/monitoring_server/templates/compose-monitoring-server.yml.j2` — образец подключения
  сервиса к сети `proxy` через labels (сервис `grafana`), по которому смоделирован
  `compose-infra-panel.yml.j2`.
