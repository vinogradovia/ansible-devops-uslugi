# Архитектура роли `monitoring_server`

> Статус документа: описывает **фактическую реализацию** роли на текущий момент (реверс-инжиниринг
> по коду), а не задуманную архитектуру. Формат — по аналогии с
> `docs/adr/0003-ginx-multidomain-role.md`. Большинство P0-находок предыдущего код-ревью
> (`ROADMAP.md`, раздел P0 «monitoring_server», пункты 1–5) на момент написания этого документа уже
> **исправлены в коде** — ниже описано их текущее (исправленное) состояние, а не исходные баги. Этот
> документ добавляет к ROADMAP.md находки, которых там ещё нет — в первую очередь раздел 6
> (k3s-путь) и раздел 10.
>
> **Обновление 1:** после первой версии документа в `helm/` добавлен реальный пример
> `helmwave`-конфигурации (`helmwave.yml`/`helmwave.yml.tpl`, `envs/`, `values/`) — раздел 6
> переписан: находка «в `helm/` пусто, ставить нечего» больше не актуальна дословно, но
> актуальна суть — задача `Helmwave up` в самой роли по-прежнему закомментирована (роль не
> запускает этот пример автоматически).
>
> **Обновление 2:** `Helmwave up` больше не закомментирован — раскомментирован, исправлен
> (KUBECONFIG/NO_PROXY, корректный `argv`) и **проверен реальным molecule-прогоном**
> (`extensions/molecule/monitoring_server_k3s/`, раздел 11): k3s-путь теперь реально
> разворачивает VictoriaMetrics Operator + grafana-operator через `helm/`, а не только описывает
> их примером. Раздел 6 переписан заново под эту реальность; главная находка документа теперь —
> не «стек не разворачивается», а более мелкие нестыковки примера `helm/` с дефолтами роли
> (см. раздел 6/9).

Роль разворачивает observability-стек (метрики через VictoriaMetrics, логи через Grafana Loki,
визуализация через Grafana, алертинг через VMAlert/VMRule) на два взаимоисключающих
оркестратор-бэкенда: `docker` (дефолт) и `k3s`.

---

## 1. Фактическая структура роли

```
monitoring_server/
├── defaults/main.yml            # 229 строк — единственный defaults-файл
├── vars/main.yml                # реестр экспортёров monitoring_server_victoria_metrics_exporters
├── meta/main.yml                 # role: docker (when orchestrator docker),
│                                 # xanmanning.k3s (when orchestrator k3s, теги init/never)
├── handlers/main.yml             # 3 handler'а — см. раздел 5
├── tasks/
│   ├── main.yml                              # оркестрация верхнего уровня, см. раздел 4
│   ├── check-and-install-requirements.yml    # общий для обоих оркестраторов
│   ├── check-and-install-requirements.docker.yml
│   ├── check-and-install-requirements.k3s.yml
│   ├── monitoring-server.docker.yml          # см. раздел 5
│   ├── monitoring-server.k3s.yml             # см. раздел 6 — главная находка документа
│   ├── victoria-metrics-provisioning-exporter-targets.yaml
│   ├── victoria-metrics-provisioning-alerts.yaml
│   ├── grafana-provisioning-dashboards_group.yaml
│   └── grafana-provisioning-dashboard.yaml
├── templates/
│   ├── compose-monitoring-server.yml.j2      # docker: victoria-metrics/grafana/loki*/s3
│   ├── loki-config.yaml.j2
│   ├── grafana-dashboard-provider.yaml.j2    # docker: провайдер файловых дашбордов
│   ├── oneitemtemplate_nice_yaml.j2          # generic YAML-рендер одного элемента (datasources)
│   ├── victoria-metrics-scrape-config.yaml.j2
│   ├── victoria-metrics-scrape-<exporter>-targets.json.j2   # 11 файлов, по одному на экспортёр
│   ├── k3s/local-path-provisioner.yml.j2
│   ├── kubernetes/configmap.vm-filesd.j2     # k3s: ConfigMap с file_sd targets
│   ├── kubernetes/vmrules-vm-exporters.j2    # k3s: CRD VMRule (delimiters [[ ]], см. раздел 7)
│   └── alert-rules/**                        # PromQL-правила, инклюдятся в vmrules-vm-exporters.j2
├── tests/
│   ├── inventory
│   └── test.yml                              # голый include_role на localhost, все флаги off —
│                                              # не ловит ни одну находку (см. раздел 11)
└── README.md                                  # неотредактированная заготовка ansible-galaxy init
```

`helm/` (используется как `monitoring_server_helmwave_dir`, вычисляется как
`{{ role_path | dirname | dirname }}/helm`, т.е. корень коллекции) на момент первой версии этого
документа был пуст; после обновления содержит реальный пример `helmwave`-проекта:

```
helm/
├── helmwave.yml          # статический, отрендеренный под один конкретный кластер
├── helmwave.yml.tpl      # шаблонизированная версия (gomplate-синтаксис), читает envs/<K8S_CLUSTER>.yaml
├── envs/
│   ├── _helm-repos.yaml          # общие Helm-репозитории/registries для всех кластеров
│   └── k3s-monitoring.yaml       # список releases для конкретного окружения "k3s-monitoring"
├── values/
│   ├── releases_common/<release>.yaml               # общие values на релиз, для всех кластеров
│   └── k3s-monitoring/namespaces/monitoring/<release>/*.yaml   # per-кластер оверрайды
├── localrepo/             # локальный Helm-репозиторий (index.yaml + nxs-universal-chart .tgz),
│                           # используется только закомментированным в envs/*.yaml релизом
│                           # storage-classes — сейчас не подключён (см. раздел 6)
└── tmp/                    # смешанное содержимое: (а) helmwave build/vendor-кэш чартов
                             # (helm/tmp/victoria-metrics-k8s-stack/, helm/tmp/nxs-universal-chart/
                             # с собственным .git/), (б) забытые fetch-копии kubeconfig с прошлых
                             # прогонов роли (test-host/, local_test/, k3s-monitoring.in.example.com/),
                             # (в) россыпь *_targets.json — см. раздел 10.4
```

Раздел 6 разбирает, что именно этот пример деплоит и почему сама роль его по-прежнему не
запускает автоматически.

---

## 2. Схема переменных (по факту `defaults/main.yml`)

### 2.1. Оркестратор и общие пути

```yaml
monitoring_server_orchestrator: docker         # docker | k3s
monitoring_server_config_dir: /opt/monitoring-server
monitoring_server_storage_dir: /opt/monitoring_storage
monitoring_server_helmwave_dir: "{{ role_path | dirname | dirname }}/helm"
monitoring_server_helmwave_tmp: "{{ monitoring_server_helmwave_dir }}/tmp"
monitoring_server_kubernetes_namespace: monitoring
```

### 2.2. Docker-специфика

```yaml
monitoring_server_docker_proxy_network_external: true   # ожидает уже существующую внешнюю сеть
monitoring_server_docker_proxy_network_name: proxy      # "proxy" — конвенция с reverse_proxy_traefik
monitoring_server_docker_logging_defaults: {...}        # json-file, max-size 50m, max-file 5
```

Grafana в docker-compose безусловно подключена к сети `proxy` с Traefik-лейблами
(`traefik.http.routers.grafana...`) — роль **не разворачивает** сам Traefik и полагается на то, что
сеть `proxy` уже создана (внешним `reverse_proxy_traefik` либо вручную). Это неявный композиционный
контракт, нигде не проверяемый `assert`'ом (раздел 10.3).

### 2.3. Per-экспортёр флаги (11 экспортёров + blackbox/nodejs)

Единый паттерн на каждый экспортёр:

```yaml
monitoring_server_victoria_metrics_scrape_<exporter>: true|false
monitoring_server_victoria_metrics_scrape_<exporter>_port_default: <port>
monitoring_server_victoria_metrics_alerts_rules_<exporter>_default: >-
  {{ monitoring_server_victoria_metrics_scrape_<exporter> and monitoring_server_orchestrator == 'k3s' }}
```

Дополнительный `and monitoring_server_orchestrator == 'k3s'` в каждом `_alerts_rules_..._default` —
результат решения P5-33 (`ROADMAP.md`): без этого гейта алерты были бы включены по умолчанию и под
`docker`, где `vmalert` не существует вовсе. `blackbox`/`nodejs_exporter` не имеют собственного
`_port_default` — они не рендерят scrape-target через этот механизм (см. раздел 3).

### 2.4. Grafana

```yaml
monitoring_server_grafana_enabled: false
monitoring_server_default_password: "PleAse_Change_ME!"
monitoring_server_grafana_security_admin_password: "{{ monitoring_server_default_password }}"
monitoring_server_grafana_server_root_url: "https://grafana.docker.localhost"
monitoring_server_grafana_dashboard_provisioning: >-
  {{ true if monitoring_server_orchestrator == 'k3s' else monitoring_server_grafana_enabled }}
```

Fail-fast на дефолтный пароль — в `check-and-install-requirements.yml` (общий файл, не
`*.docker.yml`, см. раздел 4 почему).

**Дашборды** — группами, через два независимых набора переменных, объединяемых в рантайме:

```yaml
monitoring_server_grafana_dashboards_group_defaults_<name>:
  <name>:
    enable: false
    folder: <опционально>          # используется только k3s-путём, см. раздел 8
    dashboards:
      - name: <human name>
        uid: <grafana uid>
        src: "../../ADDONS/grafana_dashboards/<file>.json"
```

Восемь готовых групп в `defaults/main.yml` (mysql, pve1, nginx, blackbox, php_fpm, prom_client,
freeipa, redis), все `enable: false` по умолчанию. Пользователь коллекции переопределяет/добавляет
через `monitoring_server_grafana_dashboards_group_install_<name>` (тот же формат) — оба набора
переменных, `..._group_default*`/`..._group_install*`, собираются через
`lookup('community.general.merge_variables', <префикс>, pattern_type='prefix')` (`tasks/main.yml`)
и объединяются `combine(recursive=true)`. Префиксный матчинг здесь неочевиден, но работает
корректно: искомый префикс `monitoring_server_grafana_dashboards_group_default` — строковый префикс
имени `monitoring_server_grafana_dashboards_group_defaults_mysql` (лишняя `s` идёт сразу после
конца префикса), совпадение засчитывается.

### 2.5. Локальный S3 (MinIO) и Grafana Loki

```yaml
monitoring_server_local_storage_s3_enabled: false
monitoring_server_local_storage_s3:
  access_key: local_storage_s3
  secret_key: supersecret_local_storage_s3
monitoring_server_local_storage_s3_volume_device: false   # путь на хосте для bind-mount (опционально)

monitoring_server_grafana_loki_enabled: false
monitoring_server_grafana_loki_common_storage_s3:
  endpoint: s3:9000
  bucketnames: loki-data
  access_key_id: "{{ monitoring_server_local_storage_s3.access_key }}"
  ...
```

`loki-config.yaml.j2` хардкодит `object_store: s3` — локальной файловой альтернативы нет. Поэтому
`monitoring_server_grafana_loki_enabled: true` **обязательно** требует
`monitoring_server_local_storage_s3_enabled: true` — проверяется явным `fail` в
`check-and-install-requirements.docker.yml` (не через `depends_on`/скрытый workaround). Оба флага по
умолчанию `false` — дефолтная конфигурация не затрагивается.

---

## 3. Реестр экспортёров (`vars/main.yml`)

Единый список `monitoring_server_victoria_metrics_exporters` управляет и провижинингом
scrape-таргетов, и алертами. Ключи одного элемента:

| ключ | назначение |
|---|---|
| `name` | идентификатор (используется в именах ресурсов k3s, job_name docker) |
| `src`/`dest` | шаблон scrape-target JSON и путь назначения (**docker-путь**) |
| `state` | булев флаг включения — обычно ссылается на `..._scrape_<exporter>` |
| `alert_rules_default_enabled` | ссылается на `..._alerts_rules_<exporter>_default` (§2.3) |
| `alert_rules_src` | список путей к YAML с PromQL-правилами (инклюдятся в VMRule, k3s-only) |

**Не все 13 элементов одинаковы по факту:**

- `node-exporter`, `docker-exporter`, `cadvisor`, `ipa-exporter`, `redis-exporter`,
  `nginx-exporter`, `mysqld-exporter`, `pve-exporter` — есть и `src`/`dest` (работают под docker),
  и `alert_rules_src` (работают под k3s).
- `php-fpm-exporter`, `nginxlog-exporter`, `prom-client` — есть `src`/`dest` (docker-scrape
  работает), но `alert_rules_src` **закомментирован** (`# alert_rules_src:` / `# - "alert-rules/"`)
  — файла правил ещё не существует, `alert_rules_default_enabled` формально `false` для docker
  автоматически (гейт `orchestrator == 'k3s'`, §2.3), но даже под k3s включение ничего не даст —
  список правил пуст.
- `blackbox`, `nodejs-exporter` — **нет** `src`/`dest` вовсе (закомментированы) — их
  scrape-конфигурация не реализована через `file_sd` вообще, это VMScrape/k3s-only экспортёры.
  Включение под docker (`monitoring_server_victoria_metrics_scrape_blackbox: true`) даёт понятный
  `fail` (см. раздел 4), а не крах на undefined-переменной.

---

## 4. Порядок задач (`tasks/main.yml`, факт)

```
1. check-and-install-requirements.yml           — общий: fail на дефолтный пароль Grafana
   (вынесен из docker.yml намеренно: monitoring-server.k3s.yml создаёт Secret
   grafana-credentials БЕЗ when: monitoring_server_grafana_enabled — проверка нужна обоим
   оркестраторам, см. ROADMAP.md P2-16)

2. check-and-install-requirements.<orchestrator>.yml   — специфичные fail-fast'ы (раздел 2.5,
   раздел 7)

3. monitoring-server.<orchestrator>.yml                — основной провижининг (разделы 5/6)

4. Provisioning victoria-metrics exporters scrape_config/targets
   — include victoria-metrics-provisioning-exporter-targets.yaml в цикле по
   monitoring_server_victoria_metrics_exporters (для ОБОИХ оркестраторов, ветвление внутри файла)

5. Provisioning victoria-metrics alerts
   — include victoria-metrics-provisioning-alerts.yaml дважды: state=present, затем state=absent
   (для добавления новых и снятия отключённых правил разом; внутри файла — no-op для docker,
   раздел 7)

6. GrafanaDashboards (when: monitoring_server_grafana_dashboard_provisioning)
   — merge group_default*/group_install*, цикл по группам → grafana-provisioning-dashboards_group →
   grafana-provisioning-dashboard (раздел 8)

7. Remove fetched k3s kubeconfig от control-хоста
   (when: orchestrator == k3s and context.dest определён — очистка после того, как kubeconfig
   больше не нужен ни одной из задач выше)
```

---

## 5. Docker-оркестратор — фактическая реализация

`monitoring-server.docker.yml` рендерит `compose.yml` (валидируется
`docker compose -f %s config` прямо в самой задаче — fail-fast до применения) и поднимает через
`community.docker.docker_compose_v2`. Сервисы (`compose-monitoring-server.yml.j2`, все — по
условным блокам на соответствующий `_enabled`-флаг):

- **`victoria-metrics`** (`victoriametrics/victoria-metrics:latest` — тег не закреплён явной
  версией, в отличие от остальных образов роли, см. раздел 10.2) — порт `8428`, скрейп-конфиг из
  volume `.../scrape_config`, ретеншн 30d.
- **`grafana`** (`grafana/grafana:latest`, тоже не закреплена версия) — сеть `proxy` + Traefik-лейблы
  (§2.2).
- **`loki_read`/`loki_write`/`loki_backend`/`loki_gateway`** (только при
  `monitoring_server_grafana_loki_enabled`) — микросервисная топология Loki с `memberlist`
  (gossip-кластер из 3 нод), `loki_gateway` — самописный nginx-конфиг, сгенерированный inline через
  `entrypoint: sh -euc "cat <<EOF > /etc/nginx/nginx.conf ..."` (не через volume/template Ansible —
  вся маршрутизация `/loki/api/*`/`/api/prom/*` между `loki_read`/`loki_write` зашита прямо в
  compose-шаблон). `loki_read`/`loki_write` объявляют `depends_on: [s3]` (без
  `condition: service_healthy` — только порядок старта контейнера, не готовность MinIO);
  `loki_backend` **не** объявляет `depends_on` на `s3` вовсе, хотя тоже пишет в S3-хранилище через
  `common.storage.s3` (раздел 10.1).
- **`s3`** (MinIO, только при `monitoring_server_local_storage_s3_enabled`) — entrypoint сам создаёт
  `loki-data`/`loki-ruler` как каталоги на диске (для MinIO с файловым бэкендом каталог верхнего
  уровня — и есть bucket, `mkdir -p` без отдельного `mc mb` работает корректно, это не баг).

**Grafana dashboard provisioning (docker)** — фикс P0-3 из ROADMAP: провайдер
(`grafana-dashboard-provider.yaml.j2`) рендерится один раз в `tasks/main.yml` (не на каждый
dashboard), `notify: Restart grafana` (провайдер читается только при старте контейнера, hot-reload
не поддерживается). Сам провайдер — **единственная плоская директория**
(`path: /etc/grafana/provisioning/dashboards`, `folder: ""`), без под-папок — см. раздел 8 про
следствие для поля `folder:` в схеме дашбордов.

**Handlers** (`handlers/main.yml`): `Reload victoria-metrics by api` (`wget .../-/reload` внутри
контейнера через `docker_compose_v2_exec`) и `Restart grafana` (полный рестарт сервиса). Оба
notify'ятся точечно из задач рендеринга конфигов, а не безусловно.

---

## 6. k3s-оркестратор — фактическая реализация (обновлено: `Helmwave up` больше не закомментирован)

`monitoring-server.k3s.yml` по факту выполняет:

1. `Fetch k3s context` — скачивает `/etc/rancher/k3s/k3s.yaml` на control-хост (`become: true`,
   фикс P2-15).
2. Патчит `server: https://127.0.0.1:6443` на реальный IP хоста в скачанном kubeconfig.
3. Рендерит `k3s/local-path-provisioner.yml.j2` как манифест `/var/lib/rancher/k3s/server/manifests/
   custom-local-storage.yaml` (k3s подхватывает файлы в этой директории автоматически при старте) —
   StorageClass `local-path`, путь на хосте — `monitoring_server_storage_dir`.
4. Создаёт namespace `monitoring_server_kubernetes_namespace` (`kubernetes.core.k8s`).
5. Создаёт `Secret grafana-admin-credentials-custom` с админ-паролем Grafana — **безусловно**, без
   `when: monitoring_server_grafana_enabled` (см. раздел 4, почему проверка пароля общая).
6. **`Helmwave up`** — раскомментирован и исправлен (был синтаксически битый черновик: одна
   строка вместо `argv`-массива, без `KUBECONFIG`). Теперь:
   ```yaml
   environment:
     KUBECONFIG: "{{ monitoring_server_orchestrator_context.dest }}"
     K8S_CLUSTER: "{{ monitoring_server_helmwave_k8s_cluster }}"
     NO_PROXY / no_proxy: "127.0.0.1,localhost,{{ ansible_facts['default_ipv4']['address'] }}"
   ansible.builtin.command:
     chdir: "{{ monitoring_server_helmwave_dir }}"
     argv: [helmwave, up, --build, --yml, --templater, "{{ monitoring_server_helmwave_templater }}", ...]
   ```
   Новые переменные (`defaults/main.yml`): `monitoring_server_helmwave_k8s_cluster` (дефолт
   `k3s-monitoring` — имя единственного файла в `helm/envs/`, который сейчас есть в коллекции),
   `monitoring_server_helmwave_auto_yml` (дефолт `true` — включает `--yml --templater gomplate`,
   т.е. авто-рендер `helmwave.yml.tpl` → `helmwave.yml`; выключить, если у пользователя коллекции
   лежит только статический `helmwave.yml`), `monitoring_server_helmwave_templater` (дефолт
   `gomplate` — `helmwave.yml.tpl` использует `requiredEnv`/`readFile`/`fromYaml`, которых нет в
   дефолтном для helmwave шаблонизаторе `sprig`), `monitoring_server_helmwave_tags` (дефолт `[]` —
   ставить все releases из env-файла; можно ограничить списком тегов helmwave).

   **`NO_PROXY` — неочевидный, но обязательный нюанс.** `helm`/`helmwave` — Go-бинарники, уважающие
   `(NO_)PROXY` из окружения control-хоста. Если там настроен HTTP(S)-прокси для доступа в интернет
   (сам `helmwave` тянет чарты из публичных репозиториев/registries), запрос к kube-apiserver
   кластера (приватный адрес) уйдёт через прокси и не достучится — `Kubernetes cluster
   unreachable: ... context deadline exceeded`, а не ошибка роли. Обнаружено реальным прогоном
   molecule (раздел 11) — на машине, где запускался тест, был настроен `HTTPS_PROXY`.

**Проверено реальным прогоном (раздел 11) — стек РЕАЛЬНО разворачивается.** Пример
`helmwave`-конфигурации в `helm/` (envs/k3s-monitoring.yaml — все 5 releases, без ограничения по
тегам) ставит:

- релиз `vm` — chart `vm/victoria-metrics-k8s-stack` (0.69.0): VictoriaMetrics Operator + реальные
  `VMSingle`/`VMAgent`/`VMAlert`/`VMAlertmanager` (Telegram-нотификатор с плейсхолдер-токеном
  `CHANGEME_TELEGRAM_BOT_TOKEN`, не настоящий секрет) + `extraObjects` со StorageClass
  `local-monitoring-storage` (`provisioner: rancher.io/local-path`, зависит от того, что шаг 3 уже
  создал StorageClass `local-path` через тот же провижининг) + `VMScrapeConfig` на 9 экспортёров,
  монтирующих в `vmagent` те самые ConfigMap'ы `vm-filesd-<exporter>`, которые создаёт
  `victoria-metrics-provisioning-exporter-targets.yaml` (раздел 3) — согласовано по именам,
  подтверждено `kubectl` (`vmagent` реально видит и монтирует эти ConfigMap'ы).
- релиз `grafana-operator` — сам оператор + `Grafana` CR (`labels: {dashboards: grafana}`, берёт
  пароль из Secret `grafana-admin-credentials-custom`, шаг 5) + `GrafanaFolder` CR `addons`/`nginx` —
  оба реально существуют в кластере, `folder:` из `defaults/main.yml` (раздел 8) работает сквозно,
  не только гипотетически.
- релизы `grafana-alloy`/`grafana-alloy-blackbox`/`grafana-alloy-redis` — по-прежнему относятся к
  отдельной, ещё не подключённой в самой роли задаче (`ROADMAP.md`, Backlog фич, пункт 34). `vm` и
  `grafana-alloy-blackbox` разворачиваются и работают; **`grafana-alloy-redis` зависает в
  `Pending`** — его `values.yaml` ссылается на `Secret grafana-alloy-redis`, которого нет ни в
  одном файле `helm/values/` (не заведён вовсе). Это ожидаемый пробел именно backlog-фичи, не
  дефект `monitoring_server` — роль про этот Secret ничего не знает и не должна.

**Найденные при реальном прогоне нестыковки (не в самой роли, а в примере `helm/`, который теперь
реально исполняется):**

- `helm/values/.../vm/values.yaml` монтирует в `vmagent` ConfigMap `vm-filesd-prom-client`
  **безусловно**, наравне с остальными 10 экспортёрами — но
  `monitoring_server_victoria_metrics_scrape_prom_client` по умолчанию `false` (единственный из
  11 "обычных" экспортёров, выключенный по умолчанию, но не закомментированный в
  `extra-objects.yaml`, в отличие от `blackbox`/`nodejs-exporter`), и роль этот ConfigMap не
  создаёт. Результат — `vmagent` виснет в `Pending` (`FailedMount`) на дефолтной конфигурации
  роли, пока вызывающий явно не выставит `monitoring_server_victoria_metrics_scrape_prom_client:
  true`. Molecule-сценарий (раздел 11) делает это явно в своих `group_vars`.
- Порядок задач в `tasks/main.yml` (раздел 4: k3s-провижининг → exporter targets → alerts →
  dashboards) означает, что в момент, когда `Helmwave up` создаёт `vmagent`, ConfigMap'ы
  `vm-filesd-*` **ещё не существуют** (создаются следующим шагом) — на свежем кластере `vmagent`
  первые несколько минут проведёт в `Pending`/`FailedMount`, пока kubelet не подхватит появившиеся
  ConfigMap'ы (без перезапуска пода, автоматически). Не баг (одиночный прогон `tasks/main.yml`
  всё равно доводит до рабочего состояния), но стоит иметь в виду при первом `apply`.

**Разница с прежней формулировкой находки:** до этого изменения раздел констатировал, что
`kubernetes.core.k8s` для VMRule/GrafanaDashboard/ConfigMap падает на `no matches for kind`, потому
что операторы никогда не ставились автоматически. Теперь — ставятся, и раздел 11 подтверждает это
реальным molecule-прогоном (VMRule/GrafanaDashboard/ConfigMap создаются успешно, `vmagent`
монтирует свои volume'ы). Остаётся не исправленным: сама роль/её `meta/main.yml` по-прежнему не
объявляют зависимость от `helmwave`/`helm` CLI или от python-пакета `kubernetes` на control-хосте —
`check-and-install-requirements.k3s.yml` фейлит явным сообщением, если `helmwave` не найден, но
только в момент запуска роли, а не как декларативная зависимость.

**Grafana Loki под k3s — реализовано 2026-07-14, без правок кода роли.** Новый Helm-релиз `loki`
(`grafana/loki` 6.54.0, `deploymentMode: SingleBinary`) в `helm/envs/k3s-monitoring.yaml`,
разворачивается тем же `Helmwave up` — роль не знает о его существовании, просто вызывает
helmwave. `monitoring_server_grafana_loki_enabled` (docker-only) сознательно **не** прокидывается
в `monitoring_server_helmwave_tags` для контроля этого релиза — причина и решение зафиксированы в
`ROADMAP.md`, П5 №35 (helmwave фильтрует только по inclusion-тегам, роль не должна знать
содержимое `envs/<cluster>.yaml` пользователя); вопрос остаётся открытым на будущее.

Фактическая реализация (`helm/values/k3s-monitoring/namespaces/monitoring/loki/values.yaml`):
- Storage — S3 через **бандлованный MinIO-сабчарт самого чарта grafana/loki**
  (`minio.enabled: true`), а не отдельный релиз/StatefulSet, как в docker-пути. Чарт **сам**
  подставляет `loki.storage.s3.endpoint/accessKeyId/secretAccessKey` из адреса сабчарта
  (`Service "<release>-minio"`) и `minio.rootUser`/`rootPassword` — любое ручное значение
  `loki.storage.s3.*` в values молча игнорируется (проверено `helm template`), поэтому в values
  эти ключи не указываются вовсе.
- `read`/`write`/`backend` (SimpleScalable-компоненты) явно обнулены (`replicas: 0`) — без этого
  чарт валидируется с ошибкой «more than zero replicas for both single binary and simple scalable
  targets», раз `deploymentMode: SingleBinary` не зануляет их сам.
- `resultsCache`/`chunksCache` (memcached) явно отключены (`enabled: false`) — дефолты чарта
  рассчитаны на продакшн-масштаб (`chunksCache.allocatedMemory: 8192` МБ ⇒ pod-запрос ~9.8Gi
  памяти) и не влезают в маленький single-node кластер; реальный прогон это поймал (`FailedScheduling:
  Insufficient memory`, ВМ с 6Gi RAM). Не нужны для «small Loki installations» (собственная
  формулировка чарта про SingleBinary).
- Внешний доступ (Promtail с `monitoring_agent`-хостов, обычно на других машинах) — через
  `gateway.ingress` чарта (nginx-гейтвей перед Loki, как и в docker-пути) на встроенный в k3s
  Traefik, хост `logs.in.example.com`.
- Datasource для Grafana — **не** заводится в самом релизе `loki` (в отличие от изначального плана
  через `extraObjects`): в `grafana-operator/values.yaml` уже были заранее заведены `GrafanaDatasource
  loki`/`loki-infra` (мультитенантность, `X-Scope-OrgID: tenant1`/`infra`) в ожидании этой задачи —
  url обеих переключен на внутренний cluster-DNS `http://loki-gateway.monitoring.svc.cluster.local`
  (Grafana и Loki в одном namespace одного кластера, внешний Ingress/DNS для этого server-side
  запроса не нужен; `logs.in.example.com` используется только внешним Promtail).

**Найденные и исправленные при реальном прогоне баги (не в роли — в `helm/`, схема helmwave):**
- **Гонка релизов на CRD.** `helmwave` по умолчанию деплоит releases параллельно. И `vm`
  (через встроенную grafana-интеграцию чарта), и `loki` (изначально, через собственный
  `extraObjects`) создают ресурсы `grafana.integreatly.org/*`, зависящие от CRD, которые ставит
  `grafana-operator` — без явного порядка это гонка («no matches for kind GrafanaDatasource»,
  поймано реальным прогоном для обоих). Схема `helmwave` поддерговала `depends_on` per-release
  (`{name: <release>}`), но **`helm/helmwave.yml.tpl` эту связь молча не пробрасывал** из
  `envs/<cluster>.yaml` в собранный `helmwave.yml` — исправлено (см. `.tpl`, блок `depends_on`).
  `vm` теперь явно зависит от `grafana-operator`.
- **Ownership-конфликт GrafanaDatasource "loki".** Первая версия `loki`-релиза сама создавала
  `GrafanaDatasource loki` через `extraObjects`, не заметив уже существующий одноимённый ресурс в
  `grafana-operator/values.yaml` — Helm отказался «импортировать» чужой ресурс
  (`invalid ownership metadata`). Урок: перед добавлением нового extraObjects-ресурса стоит
  проверить `grep -rn` по всему `helm/values/`, а не только по релизу, который редактируешь.

---

## 7. Alert-правила (VMAlert/VMRule) — архитектурное решение P5-33

**Docker:** `check-and-install-requirements.docker.yml` фейлит явным сообщением, если для любого
экспортёра `alert_rules_default_enabled: true` — со ссылкой на ROADMAP P0-1/P5-33 и подсказкой,
какую переменную выставить в `false`. `victoria-metrics-provisioning-alerts.yaml` для docker —
буквально закомментированный блок `# TODO`, задача-заглушка.

**k3s:** `victoria-metrics-provisioning-alerts.yaml` рендерит `vmrules-vm-exporters.j2` во
временный файл и применяет через `kubernetes.core.k8s` **дважды за прогон** — `state: present`
(добавить включённые) и `state: absent` (снять отключённые), с `run_once: true` (выполняется один
раз для группы, не на каждый хост). Шаблон использует **альтернативные Jinja-разделители**
`variable_start_string: "[["`/`variable_end_string: "]]"` — потому что `alert_rules_src`-файлы
(`templates/alert-rules/*.yml`) содержат Alertmanager/Go-template синтаксис
(`{{ $labels.instance }}` и т.п.) в полях `annotations.summary` — эти `{{ }}` должны остаться
литеральными в итоговом YAML, а не быть съедены Ansible-Jinja при рендере
`vmrules-vm-exporters.j2`. Обратная сторона решения (реальность §6) — примененные CRD ссылаются на
несуществующий (в этой роли) оператор.

---

## 8. Grafana dashboards — механизм и расхождение docker/k3s

Общий цикл (`tasks/main.yml` → `grafana-provisioning-dashboards_group.yaml` →
`grafana-provisioning-dashboard.yaml`) одинаков для обоих оркестраторов вплоть до конкретного шага
провижининга, где ветвление по `orchestrator`:

- **docker:** `ansible.builtin.copy` JSON-файла дашборда в единственную плоскую директорию
  (§5) — поле `folder:` группы (например, `folder: Nginx` у группы `nginx` в
  `defaults/main.yml`) **нигде не читается** этой веткой. По факту в docker-режиме все включённые
  дашборды оказываются в одной и той же (General/`""`) папке Grafana, независимо от того, что
  написано в схеме переменных — не баг в смысле «падает», а тихое расхождение между
  задокументированным полем схемы и его реальным эффектом.
- **k3s:** `folder:` используется как `folderRef` в CRD `GrafanaDashboard` — то есть здесь поле
  реально что-то делает, но только если оператор Grafana установлен и настроен с соответствующими
  папками (см. раздел 6 — сам оператор этой ролью не разворачивается).

---

## 9. Реализовано vs не реализовано

### Реализовано и рабочее (docker-путь, основной сценарий коллекции)
- VictoriaMetrics + scrape-конфиг с `file_sd` на 11 таргет-файлов, per-экспортёр вкл/выкл.
- Grafana с datasource VictoriaMetrics (авто) и Loki (авто при включении), файловый dashboard
  provisioning (плоская папка), Traefik-интеграция через внешнюю сеть `proxy`.
- Grafana Loki (микросервисный режим read/write/backend/gateway) + локальный MinIO как обязательный
  S3-бэкенд.
- Групповые Grafana-дашборды (8 готовых наборов в ADDONS) с механизмом override через
  `..._group_install_*`.
- Fail-fast на дефолтные пароли (Grafana, MinIO) и на несовместимые комбинации флагов
  (alert-правила под docker, Loki без S3).

### Реализовано и рабочее (k3s-путь, обновлено — было в «не реализовано» до этого изменения)
- **Реальный деплой стека под k3s** (VictoriaMetrics Operator + `VMSingle`/`VMAgent`/`VMAlert`/
  `VMAlertmanager`, grafana-operator + `Grafana`/`GrafanaFolder` CR, Grafana Loki `SingleBinary` +
  бандлованный MinIO) — `Helmwave up` больше не закомментирован (раздел 6), подтверждено реальным
  molecule-прогоном (раздел 11): `helmwave up --build --yml --templater gomplate` ставит все 6
  releases из `helm/envs/k3s-monitoring.yaml`, `vmagent` реально монтирует ConfigMap'ы
  `vm-filesd-*`, VMRule/GrafanaDashboard/GrafanaDatasource CR реально создаются через API кластера
  (не падают на `no matches for kind`), Loki реально принимает push и отдаёт запись обратно через
  `gateway`-Ingress.
- Требует на control-хосте (не на целевом хосте!): CLI `helm` + `helmwave` (fail-fast уже был,
  `check-and-install-requirements.k3s.yml`) и python-пакет `kubernetes` (добавлен в
  `pyproject.toml` dev-зависимостью, нужен `kubernetes.core.k8s`/`k8s_info`/`helm_info`).
  Активация зависимости `xanmanning.k3s` (`meta/main.yml`, `tags: [init, never]`) требует
  `--tags all,init` при запуске playbook/molecule — проверено эмпирически, см. раздел 11.

### Не реализовано / не работает по факту
- **VMAlert/Alertmanager под docker** — архитектурно исключено решением P5-33, не баг (раздел 7).
- **`grafana-alloy-redis`** (helmwave-релиз, k3s) зависает в `Pending` — его values ссылаются на
  Secret `grafana-alloy-redis`, которого нет ни в одном файле `helm/values/`. Относится к отдельной
  задаче ROADMAP backlog №34 (embedded-экспортёр grafana-alloy), не к `monitoring_server`.
- **`vm-filesd-prom-client`** (helmwave-релиз `vm`, k3s) — `helm/values/.../vm/values.yaml`
  монтирует этот ConfigMap в `vmagent` безусловно, но `monitoring_server_victoria_metrics_scrape_
  prom_client` по умолчанию `false` — на дефолтной конфигурации роли `vmagent` виснет в `Pending`,
  пока вызывающий явно не включит `prom_client` (раздел 6). Несогласованность примера `helm/` с
  дефолтами роли, а не баг самой роли.
- **`php-fpm-exporter`/`nginxlog-exporter`/`prom-client`** — alert-правила не написаны
  (`alert_rules_src` закомментирован в `vars/main.yml`), только scrape работает.
- **`folder:` в схеме Grafana-дашбордов под docker** — не используется (раздел 8).
- **README.md** — неотредактированная заготовка `ansible-galaxy init`, не описывает ни одну
  реальную переменную/сценарий использования роли.
- **`tests/test.yml`** — голый `include_role` на `localhost` без переменных, не проверяет ничего
  содержательного (компенсируется molecule-покрытием, раздел 11).

---

## 10. Известные баги и риски (новые находки, не описанные в `ROADMAP.md`)

### 10.1. `loki_backend` не объявляет `depends_on: [s3]`
В отличие от `loki_read`/`loki_write` (§5), сервис `loki_backend` в
`compose-monitoring-server.yml.j2` не имеет секции `depends_on` вовсе, хотя тоже обращается к
S3-хранилищу (`common.storage.s3`, используется компактором). При холодном старте всего стека
докер может поднять `loki_backend` до готовности `s3` — сейчас маскируется тем, что docker
compose обычно стартует контейнеры быстрее, чем Loki успевает начать реальную работу с
хранилищем, но это не гарантия.

**Обновление (закрыто отдельным фиксом, не связанным с этим пунктом):** реальный прогон
`extensions/molecule/monitoring_server/` (раздел 11) поймал СОСЕДНИЙ баг — ни у одного из
`loki_read`/`loki_write`/`loki_backend`/`loki_gateway`/`s3` не было `restart: unless-stopped`
(в отличие от `victoria-metrics`/`grafana`). Первый же прогон роли рендерит `/etc/docker/
daemon.json` (роль `docker`) и триггерит `Restart Docker daemon` — рестарт демона убивает все
контейнеры, и без restart-policy эти пять не поднимаются сами. Добавлен `restart: unless-stopped`
всем пяти сервисам в `compose-monitoring-server.yml.j2`. `depends_on: [s3]` у `loki_backend`
по-прежнему отсутствует — это отдельный, всё ещё не исправленный пункт.

### 10.2. Версии `victoria-metrics` и `grafana` не закреплены (`:latest`)
В отличие от всех остальных образов роли (`monitoring_server_grafana_loki_image_version: 3.6.4`,
`monitoring_server_local_storage_s3_image_version: RELEASE.2025-09-07T16-13-09Z` — оба закреплены
явной переменной), `compose-monitoring-server.yml.j2` хардкодит
`victoriametrics/victoria-metrics:latest` и `grafana/grafana:latest` прямо в шаблоне, без
собственной `_image_version`-переменной. Несогласованно с паттерном остальной роли и с тем, как
`docker`-путь `monitoring_agent` фиксирует версии экспортёров — при обновлении образов на сервере
поведение/API может неожиданно измениться между прогонами роли без явного контроля со стороны
оператора.

### 10.3. Отсутствие проверки внешней сети `proxy`
Grafana в docker-compose безусловно подключена к внешней сети `monitoring_server_docker_proxy_
network_name` (`external: true` по умолчанию, §2.2) — если эта сеть не создана заранее (например,
`reverse_proxy_traefik` ещё не применён к хосту), `docker compose -f %s config`-валидация в задаче
рендера **не поймает** эту проблему (валидация синтаксиса конфига, не наличия внешних ресурсов),
и упадёт уже `community.docker.docker_compose_v2` с менее очевидной ошибкой. Нет `assert`/явной
проверки существования сети перед стартом сервисов.

### 10.4. Забытые артефакты в `helm/tmp/` и `helm/.claude/`
Untracked-содержимое (см. `git status` коллекции), накопившееся в `helm/tmp/` минимум с трёх разных
прогонов: `helm/tmp/test-host/`, `helm/tmp/local_test/` и `helm/tmp/k3s-monitoring.in.example.com/` — под
каждым лежит `etc/rancher/k3s/k3s.yaml`, то есть fetch-копия kubeconfig, оставленная задачей `Fetch
k3s context` и не подчищенная финальной задачей очистки в `tasks/main.yml` (либо прогоны были
прерваны до неё, либо предшествовали её появлению в коде). Это не единичный случай, а системный:
каждый ручной/тестовый прогон роли против k3s оставляет такой файл, если не доходит до самого конца
`tasks/main.yml`. Отдельно там же — `helm/tmp/*_targets.json` (россыпь scrape-target файлов,
похоже, скопированных туда вручную при ручном тестировании ConfigMap'ов до появления
`victoria-metrics-provisioning-exporter-targets.yaml`) и `helm/tmp/nxs-universal-chart/` /
`helm/tmp/victoria-metrics-k8s-stack/` — это, по всей видимости, легитимный build/vendor-кэш самого
`helmwave` (векендорит чарты локально при `helmwave build`), а не мусор в том же смысле, что
kubeconfig-и, но тоже не предназначен для коммита в репозиторий. Отдельно — `helm/.claude/
settings.local.json`, локальный файл настроек Claude Code, тоже не относящийся к Ansible-контенту.
Рекомендация: добавить `helm/tmp/` (или как минимум `helm/tmp/*/etc/`, `helm/tmp/*_targets.json`)
и `helm/.claude/` в `.gitignore`, раз `helm/tmp/` используется и как рабочий каталог самой роли, и
как build-кэш helmwave.

---

## 11. Тестовое покрытие

Соответствует `ROADMAP.md`, таблица P4: `tests/test.yml` — `include_role` без единой переменной, с
дефолтными флагами (`monitoring_server_victoria_metrics_enabled: false`,
`monitoring_server_grafana_enabled: false` и т.д.) роль фактически ничего не разворачивает, тест
всегда зелёный независимо от реального состояния кода.

**Обновление:** появился `extensions/molecule/monitoring_server/` — покрывает
`monitoring_server_orchestrator: docker`. Отличия от остальных docker-сценариев коллекции
(`nginx_multidomain`, `reverse_proxy_npm`): `driver: vagrant`/`libvirt` (Ubuntu 24.04,
`cloud-image/ubuntu-24.04`), а не `driver: docker` — роль под `docker`-оркестратором сама
разворачивает многосервисный docker-compose стек (VictoriaMetrics, Grafana, 4 сервиса Loki, MinIO),
и гонять это внутри systemd-контейнера означало бы docker-in-docker с конфликтом overlay2 (см.
комментарии в `extensions/molecule/monitoring_server/molecule.yml`); полноценная ВМ снимает
ограничение целиком, ценой более тяжёлого/медленного прогона (vagrant-libvirt, а не docker driver).

Сценарий — одна ВМ, которая мониторит сама себя (`groups: [monitoring_servers,
monitoring_agents]`, тот же паттерн, что `tests/inventory.yml` в корне коллекции): поднимает
`monitoring_agent` (`node_exporter`, `network_mode: host`) и `monitoring_server` (VictoriaMetrics +
Grafana + Loki + MinIO, одна dashboard-группа `nginx`) на одном хосте. `verify.yml` проверяет не
только что контейнеры запущены, но и что VictoriaMetrics реально видит `node-exporter` таргет
`health: up` (настоящий scrape, не просто поднятый порт), что Grafana видит оба datasource
(VictoriaMetrics/Loki) и три дашборда группы `nginx`, что Loki gateway маршрутизирует на
read/write, и что MinIO отвечает на `/minio/health/live`.

**Обновление 2:** появился `extensions/molecule/monitoring_server_k3s/` — покрывает
`monitoring_server_orchestrator: k3s` **с реально включённым `Helmwave up`** (раздел 6), закрывая
находку «k3s-путь не имеет molecule-покрытия». Тот же `driver: vagrant`/`libvirt`
(`cloud-image/ubuntu-24.04`), но крупнее (`memory: 6144`, `cpus: 4` — k3s + VictoriaMetrics Operator
+ grafana-operator + 3x grafana-alloy заметно тяжелее docker-стека) и **без `idempotence`** в
`test_sequence` (как `extensions/molecule/proxysql`, но по другой причине: задача `Helmwave up` —
`ansible.builtin.command` без разбора stdout `helmwave` для `changed_when`, поэтому на уровне
ansible-задачи всегда `changed=true`; реальная идемпотентность видна на уровне самих Helm-релизов,
не через molecule idempotence).

Нетривиальные решения, найденные и проверенные только реальным прогоном (не выводятся из чтения
кода):
- Активация зависимости `xanmanning.k3s` (`meta/main.yml`, `tags: [init, never]`) — эмпирически
  проверено на минимальном примере (см. историю сессии), что `--tags init` активирует ТОЛЬКО эту
  зависимость и режет все нетегированные задачи самой роли (`--tags` — это whitelist), а
  `--tags all` не активирует `never` вовсе. Только `--tags all,init` включает и
  never-зависимость, и всё остальное как обычно — `provisioner.options.tags` в `molecule.yml`.
- `helm`/`helmwave`/`kubernetes.core.k8s_info`/`kubernetes.core.helm_info` на control-хосте уходят
  в прокси, если там настроен `HTTP(S)_PROXY` — приватный адрес кластера через прокси не
  достучаться (раздел 6). И роль (`Helmwave up`), и `verify.yml` сценария явно выставляют
  `NO_PROXY`/`no_proxy` на IP кластера.
- `verify.yml` не может переиспользовать kubeconfig, оставшийся от `converge` — роль сама удаляет
  свою fetch-копию в конце (`tasks/main.yml`, «Remove fetched k3s kubeconfig»). `verify.yml`
  получает свою собственную копию тем же способом (`Fetch` + патч server IP) и подчищает её за
  собой в конце — то есть решает ту же проблему накопления кубеконфигов, которую раздел 10.4
  фиксирует как риск ручных прогонов.
- Проверяет: 6 helm-релизов `deployed` (`kubernetes.core.helm_info`, включая `loki`), namespace/
  Secret, 14 контроллеров подов namespace `monitoring` явно проверены `Running` (11 из
  vm/grafana-operator/grafana-alloy + 3 из `loki`: singleBinary, `loki-minio`, `loki-gateway`;
  `grafana-alloy-redis` намеренно исключён из проверки, см. §9; `loki-canary`/`loki-results-cache`
  реально тоже `Running`, но отдельно не assert'ятся), `GrafanaFolder addons`/`nginx`, 3
  `GrafanaDashboard` группы `nginx`, ≥9 `VMRule` с префиксом `vm-exporters-`, `GrafanaDatasource
  loki` существует, и реальный push+query round-trip в Loki через `gateway`-Ingress (`Host:
  logs.in.example.com`, как в `nginx_multidomain`/`reverse_proxy_npm`) — записанная строка лога
  реально находится обратно через `/loki/api/v1/query_range`, а не просто «под поднялся».
- `monitoring_server_victoria_metrics_scrape_prom_client: true` в `group_vars` сценария — без этого
  `vmagent` виснет в `Pending` на дефолтах роли (см. §9/§6, находка про несогласованность
  `helm/values/.../vm/values.yaml`).
- Добавление Loki потребовало ещё двух фиксов в самой схеме `helmwave` (не в роли, раздел 6): (1)
  `helm/helmwave.yml.tpl` не пробрасывал `depends_on` из `envs/<cluster>.yaml` в собранный
  `helmwave.yml` — без явного порядка `vm`/`loki` (изначально) гоняли гонку на CRD
  `grafana.integreatly.org` против `grafana-operator`; (2) folded YAML-scalar (`>-`) в
  `ansible.builtin.uri`-задаче push/query round-trip схлопывал переносы строк в пробелы и портил
  query string (`&start=`/`&end=` с лишним пробелом перед ними) — исправлено явной конкатенацией
  через `~` внутри одного `{{ }}`-выражения вместо raw-текста с разрывами строк.

---

## Ссылки

- `ROADMAP.md`, раздел P0 «monitoring_server» (пункты 1–5) — история находок и фиксов, отражённых
  в разделах 2–8 этого документа как уже исправленное текущее состояние.
- `ROADMAP.md`, P5-33 — архитектурное решение «алертинг — k3s-only» (раздел 7).
- `ROADMAP.md`, P2-15/P2-16 — фикс очистки kubeconfig и переноса проверки пароля Grafana в общий
  файл (раздел 4).
- `ROADMAP.md`, таблица P4 — тестовое покрытие (раздел 11).
- `docs/adr/0003-ginx-multidomain-role.md` — формат документа-прецедента (реверс-инжиниринг вместо
  журнала решений).
- `docs/adr/0002-docker-role.md` — зависимость `monitoring_server` от роли `docker` при
  `orchestrator: docker` (`meta/main.yml`).
- `CLAUDE.md`, раздел «Добавление нового экспортера мониторинга» / `AGENTS.md` — 4-шаговый процесс
  подключения экспортёра, соответствует фактической структуре `vars/main.yml` (раздел 3).
- `helm/helmwave.yml`, `helm/helmwave.yml.tpl`, `helm/envs/`, `helm/values/` — пример
  `helmwave`-конфигурации, разбираемый в разделе 6; `helm/values/releases_common/storage-classes.yaml`
  пуст, соответствующий релиз `storage-classes` (chart `nixys/nxs-universal-chart` из
  `helm/localrepo/`) закомментирован в `envs/k3s-monitoring.yaml` — не подключён, в стороне от
  основной находки раздела 6.
