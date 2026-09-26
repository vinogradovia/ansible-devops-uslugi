# ADR-0026: Qdrant — векторное хранилище для RAG-контура платформенной базы знаний

- **Статус:** Предложено
- **Дата:** 2026-09-20
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

ROADMAP.md №66 описывает проблему: RAG в агентной платформе не имеет выделенного vector store —
Open WebUI хранит векторы во встроенном локально-персистентном Chroma на том же PVC, что
не позволяет изолировать `ns: agents` (ADR-0015 §7/§9) и не даёт переиспользуемой базы знаний
платформы за пределами одного чат-фронтенда.

Необходимо принять решения о выборе и развёртывании vector store **до** реализации — не
через ad hoc-манифесты в `helm/values/`, а как самостоятельный релиз с документированными
переменными, SecurityContext, backup-путём и scrape-конфигом для VictoriaMetrics.

ADR-0022 (§5) требует: Helm-развёртывание, namespace-границу, PVC для storage, авторизацию
не по умолчанию, метрики, S3-backup, и проверку совместимости с `liteLLM`/`open-webui`
через OpenAI-совместимый API (ADR-0022 §8).

## Решения

### 1. Qdrant как единственное векторное хранилище платформы

**Решение:** используется [Qdrant](https://qdrant.tech/) (Apache-2.0) — не Chroma, не
pgvector, не Weaviate/ Milvus.

**Обоснование:**

1. **OpenAI-совместимый REST API** — `open-webui` уже сконфигурирован на
   `RAG_EMBEDDING_ENGINE=openai` (§7 — текущий путь Chroma заменяется через
   `QDRANT_URL`/`QDRANT_API_KEY`, если open-webui поддерживает; для agent-джобов
   `retriever`-сервис вызывает Qdrant напрямую через его native REST/gRPC).
2. **Официальный Helm-чарт** — `qdrant/qdrant-helm` из `nexus-cache.<domain>`
    (`helm` proxy repo, ADR-0018 §3), не напрямую из
    `https://qdrant.github.io/qdrant-helm` — соответствует паттерну
    `helmwave` релизов коллекции (как `openbao`, `gitea`, `vm`).
3. **Snapshots на S3** — нативный механизм `POST /snapshots` +
   `PUT /snapshots/<name>` с `storage_location` на S3-совместимом эндпоинте — тот же
   `minio-infra-1`, что уже используется Loki (ROADMAP №68, ADR-0022 §5).
4. **Дense + sparse векторы + гибридный поиск** — `BM25`-индекс поверх payload'ов,
   не отдельная lexical-индексацая система — проще архитектуры, чем Chroma +
   отдельный BM25-сервис.
5. **Встроенные метрики на `/metrics`** (Prometheus) — без sidecar-экспортера,
   тот же принцип, что `vm`/`loki`/`grafana` в Victoria Metrics Stack.
6. **Не pgvector** — ADR-0015 §"Схема размещения" называет
   `postgres+pgvector (cnpg)` для `ns: data` — но это компонент другого назначения
   (бэкенд `retriever`-сервиса для агентов, та же схема). Qdrant как специализированный
   vector store для RAG — не дублирует pgvector, а дополняет его: pgvector для
   точечных поисков внутри БД приложения, Qdrant — для масштабного семантического
   поиска по платформенной KB.

### 2. Развёртывание — Helm-релиз в namespace `agents`, не standalone VM

**Решение:** Qdrant разворачивается как Helm-релиз через `helmwave` в namespace
`agents` (не `platform`, не `gateway`), тем же паттерном, что `litellm` в
`namespace: gateway` и `openwebui` в `namespace: platform`.

**Обоснование:**

1. **Сетевой периметр ADR-0015 §7** — `agents` namespace уже содержит `default-deny
   ingress/egress` с ровно четырьмя разрешёнными исходящими адресами; Qdrant
   должен быть *доступен из* `agents` (агент-джобы ищут векторы через `retriever`),
   но *не доступен снаружи*. Размещение в том же namespace упрощает `NetworkPolicy`
   (внутренний ClusterIP-only сервис без публичного IngressRoute — тот же принцип,
   что `local-embeddings`/TEI).
2. **`local-path` StorageClass** — пилот — один узел (ADR-0015 §10, №67 Longhorn
   отложен); PVC на `local-path` достаточен для начального объёма векторов.
3. **Масштабирование** — single-node по умолчанию; реплика включается через
   `qdrant_replication_factor` (если/когда появится multi-node кластер, №67).

### 3. Авторизация — API Key из OpenBao, не дефолтный `qdrant` пароль/ключ

**Решение:** `qdrant_service_api_key` — генерируется/читается идемпотентным
GET→404→POST-циклом в `secret/qdrant/api_key` OpenBao (тот же приём, что
`secret/nexus`/`secret/radar`/`secret/gitea`, ADR-0022 §7), хранится в
`k8s Secret` в namespace `agents`, монтируется как env `QDRANT_API_KEY`.
Qdrant запускается с `--api-key` (или `QDRANT_SERVICE_API_KEY`). Клиентские
сервисы (`open-webui`/`retriever`) читают ключ из собственного Secret,
передают в заголовке `api-key`.

**Обоснование:** Qdrant без API key принимает запросы от любого пода в namespace —
нарушение ADR-0022 §4 и ADR-0015 §7. Ни один пароль не появляется как
plaintext в git.

### 4. TLS — из внутреннего PKI CA OpenBao

**Решение:** `qdrant_tls_enabled: true` (default), сертификат через цикл
`tasks/issue-tls-cert.yml` (OpenBao PKI, ADR-0016) — `qdrant` добавляется
как ещё один элемент существующего `loop`, не отдельным механизмом.
Для кластера `agents` — один `qdrant-tls` Secret, монтируемый в контейнер
Qdrant. Клиенты подключаются по `https://qdrant-agent` с
`verify=/path/to/ca.pem` (тот же `aicd-platform-ca` Secret, что у
`openwebui`/`litellm`).

**Обоснование:** трафик внутри кластера не должен быть plain-text. ADR-0022 §5
требует TLS из внутреннего PKI CA — тот же цикл, что `gitea-tls`, `semaphore-tls`,
`radar-tls`, `infra-panel-tls`, `postgresql-tls`.

### 5. S3-снапшоты — на `minio-infra-1`, bucket `qdrant-snapshots`

**Решение:** `qdrant_s3_snapshot_bucket: "qdrant-snapshots"`, endpoint
`http://minio-infra-1:9000`, credentials из `minio-infra-1-credentials` Secret.
Снапшоты создаются по расписанию (cron) через отдельный Job, не встроенным в Qdrant.

**Обоснование:** ADR-0022 §5 требует backup-путь; `minio-infra-1` уже развёрнут
и предоставляет S3-совместимый API (§3). Bucket `qdrant-snapshots` создаётся
ansible-задачей (или `mc`-контейнером) до первого старта Qdrant. Расписание
снапшотов — `Kubernetes CronJob`, а не `cron` внутри контейнера (избегает
конкуренции при future horizontal pod autoscaler).

### 6. Prometheus metrics — `vmagent` scrape config, дашборд Grafana

**Решение:** Qdrant отдаёт `/metrics` на основном REST-порту `:6333` — отдельного
порта под метрики у него нет (в отличие от классических Prometheus-экспортеров).
`vmagent` из стека `vm` (Victoria Metrics Kubernetes Stack) скрейпит их через
`VMScrapeConfig` (k3s-путь, ADR-0007 §6/§10) с `namespace: agents`,
`service: qdrant`, `port: rest`. Теги: `[qdrant, agents]`.

Дашборд Grafana — `ADDONS/grafana_dashboards/qdrant.json` (создаётся при
онбординге, аналогично дашбордам для `vm`/`loki`/`minio`), с плейсхолдерами
`${DS_...}`, применяется как `GrafanaDashboard` CR в `ns: monitoring`.

**Обоснование:** ADR-0022 §4 требует три части сразу: экспортёр (или
встроенные `/metrics`), скрейп через `VMScrapeConfig` + подтверждение
видимости серии в VictoriaMetrics, дашборд в `ADDONS/grafana_dashboards/`.
`vm/victoria-metrics-k8s-stack` уже развёрнут в `ns: monitoring`, его
`VMScrapeConfig`-ресурс — стандартный механизм скрейпа для неконтролируемых
helmwave-релизов (тот же принцип, что для `litellm`/`openwebui`, если они
экспортируют метрики).

### 7. Потребители — Open WebUI и `retriever`-сервис агент-джобов

**Решение:** два потребителя на пилотном этапе:

- **Open WebUI** — `RAG_VECTOR_STORE=qdrant` (или эквивалентная переменная),
  `QDRANT_URL: https://qdrant-agent.agents.svc.cluster.local`,
  `QDRANT_API_KEY` из Secret. Коллекция: `openwebui-embeddings`.
- **`retriever`-сервис** (будущий, `ns: agents`) — прямой вызов Qdrant REST API
  через `requests`/`qdrant-client` Python-пакет, тот же `QDRANT_URL`/
  `QDRANT_API_KEY`, коллекция `platform-kb` (общая для всех агент-джобов).

**Обоснование:** ADR-0015 §7 определяет `retriever` как единственный путь агентов
к данным; Qdrant — его бэкенд. Open WebUI — первый потребитель, который сейчас
использует Chroma и должен быть мигрирован.

**Не проработано:** точные имена переменных open-webui для переключения с Chroma
на Qdrant (требуется проверка текущей версии open-webui docs). Если open-webui
не поддерживает Qdrant нативно — обёртка `chroma-to-qdrant-migration` или
собственная мини-сервис-прослойка.

### 8. Namespace — `agents`, не `platform` и не `gateway`

**Решение:** `qdrant-agent` релиз в `namespace: agents`, не в `platform` (где
`openwebui`) и не в `gateway` (где `litellm`).

**Обоснование:** Qdrant обслуживает `agents` (агент-джобы через `retriever`) в
первую очередь. Размещение в `agents` **не отменяет** необходимость явного
`NetworkPolicy`-правила — `default-deny` (§7 ADR-0015) блокирует и
внутринамespace-трафик, если для него нет отдельного allow; разница в том, что
такое правило проще: pod-selector внутри одного namespace, без меж-namespace
лейблов. `openwebui` (`ns: platform`) достучится до Qdrant через меж-namespace
Service (`qdrant-agent.agents.svc.cluster.local`), что требует отдельного
разрешающего правила `NetworkPolicy` — тот же класс решения, что
`litellm.gateway` доступ для `agents` (§7 ADR-0015).

**Риски:** если `retriever` ещё не развёрнут (ADR-0015 §7 "ns: data ещё не
развёрнут"), Qdrant будет пустой инфраструктурой до появления потребителя.
Это осознанно — ADR-0022 требует, чтобы инфраструктура была готова *до*
потребителя, а не наоборот.

### 9. Именование релиза — `qdrant-agent`

**Решение:** имя релиза `qdrant-agent`, не просто `qdrant`.

**Обоснование:** naming convention ADR-0023 §6 (`<component>-<purpose>-<n>`) —
`qdrant` (компонент), `agent` (purpose, обслуживает агентный контур), без `-1`
на пилоте (один инстанс). Если позже появится `qdrant-client-1` (для клиентских
проектов) — разделениеPurpose позволит избежать коллизий имён.

### 10. Ansible-роль — `roles/qdrant` для bootstrap хоста (если standalone), `site.yml` для k8s-релиза

**Решение:** на пилоте — **не отдельная Ansible-роль**, а задачи в
`platform/*/ansible/site.yml` (тот же паттерн, что `litellm`/`openwebui` —
ansible рендерит `k8s Secret` для API key, создаёт `VMScrapeConfig`, применяет
`helmwave up --tags qdrant-agent`).

Отдельная роль `roles/qdrant` потребуется только при переходе на standalone-развёртывание
(Qdrant как systemd-сервис на выделенной VM) — это отложенное решение, не пилот.

**Обоснование:** весь агентный стек развёртывается задачами `site.yml` поверх
k3s (RuntimeClass, device-plugin, namespace-каркас — ADR-0015 §10), и Qdrant
как Helm-релиз вписывается в ту же модель. `roles/qdrant` для k3s-пути —
избыточная абстракция: нет generic-чарта Qdrant под шаблон `universal-chart`,
поэтому ansible просто рендерит манифесты и вызывает `helmwave`.

## Явно вне периметра

- **Репликация Qdrant** — single-node на пилоте (ADR-0015 §10 — один узел),
  репликация включается при multi-node (№67 Longhorn).
- **Хардеринг RBAC внутри Qdrant** — Qdrant не поддерживает fine-grained RBAC
  (только API key per-collection или global), поэтому мультитенантность
  клиентов через отдельные коллекции, не роли.
- **Миграция данных из Chroma** — ad hoc-скрипт Python (`chromadb → qdrant-client`),
  не автоматизирован в ADR.
- **Перенос в Semaphore Module CRD** — Qdrant — stateful, автоматический
  drift-reconcile (ADR-0014 §3) не применим — управляется через ручные
  Semaphore Tasks, не Module CRD.

## Не проработано (следующие шаги)

- **Ссылка в `infra-panel`** — Qdrant имеет встроенный Dashboard UI (port 6333,
  `/dashboards`), нужна запись в `infra_panel_extra_services` (ADR-0022 §3).
- **Точные env-переменные open-webui для Qdrant** — требуется проверка версии
  open-webui (`v0.11.3` на момент этого ADR) и её RAG-конфига. Если нативная
  поддержка Qdrant отсутствует — нужна обёртка или миграция на версию с
  поддержкой.
- **Создание bucket `qdrant-snapshots`** — какая задача/плейбук отвечает за
  `mc mb` на `minio-infra-1` до старта Qdrant?
- **Резидентная память и CPU-требования** — сколько RAM нужно Qdrant для
  ожидаемого объёма коллекций? `local-path` PVC — 20Gi (§3 minio-infra-1),
  достаточно ли для начального RAG-корпуса?
- **Базовая коллекция при первом старте** — создавать ли `openwebui-embeddings`
  и `platform-kb` автоматически через initContainer/Job, или ad hoc?
- **Инфраструктурные тесты** — testinfra/pytest сценарий: под в Running, порт
  слушает, метрики доступны, API key работает, коллекции существуют.
- **DNS** — резолвинг `qdrant-agent` в `coredns-custom` ConfigMap (если нужен
  внешний доступ) и в README `/etc/hosts` операторов (ADR-0022 §6).
- **NetworkPolicy** — явная фиксация: `agents` namespace уже имеет `default-deny`
  (§7 ADR-0015) на весь трафик, включая внутринamespace — нужно явное
  pod-selector allow-правило `agent-job → qdrant-agent`, оно ещё не описано.
  Меж-namespace доступ из `ns: platform` (openwebui) — тот же класс решения, что
  `litellm.gateway` для `agents` (ADR-0015 §7), тоже не описан.
- **Резервное копирование** — S3-снапшоты на `minio-infra-1` заменяют Bareos-бэкап
  для Qdrant (архитектурно проще, нативный механизм Qdrant). В
  `backup_server_clients` не регистрируется.
- **Документация** — создание `docs/platform/qdrant.md` (HLD/LLD/DD) вместе с
  компонентом (ADR-0022 §13).

## Верификация

1. `helmwave up --tags qdrant-agent` — релиз `qdrant-agent` в `ns: agents`
   переходит в `Running`, под `qdrant` в `Running`, порт `:6333` (REST)
   и `:6334` (gRPC) слушаются.
2. `curl -s https://qdrant-agent.agents.svc:6333` (с `QDRANT_API_KEY` в заголовке)
   — `200 OK`, `/info` возвращает корректную версию.
3. `curl -s https://qdrant-agent.agents.svc:6333/metrics` — список метрик
   `qdrant_build_info`, `qdrant_collections_count` и т.п.
4. `VMScrapeConfig` для `qdrant` — `vmagent` скрейпит метрики,
   `get_metric_types qdrant_` в VictoriaMetrics возвращает записи.
5. S3-снапшот: `POST /snapshots` создаёт снапшот, `GET /snapshots`
   показывает его в `minio-infra-1:9001` bucket `qdrant-snapshots`.
6. Миграция open-webui: `RAG_VECTOR_STORE=qdrant` (или аналог), чат с
   файлом → вектор сохраняется в Qdrant коллекцию `openwebui-embeddings`.

## Реализация (если будет)

### Структура `helmwave` релиза

```yaml
# helm/envs/platform-devops-labs-ru.yaml
- name: qdrant-agent
  namespace: agents
  chart: qdrant/qdrant-helm
  tags: [qdrant-agent]
  version: <pin>
```

```yaml
# helm/helmwave.platform-devops-labs-ru.yml
- name: qdrant-agent
  namespace: agents
  chart:
    name: qdrant/qdrant-helm
    version: <pin>
  <<: *options
  values:
    - src: values/releases_common/qdrant.yaml
      strict: true
    - src: values/platform-devops-labs-ru/namespaces/agents/qdrant-agent/values.yaml
      strict: false
  tags:
    - qdrant-agent
    - agents/qdrant-agent
```

### Структура `values`

```yaml
# helm/values/platform-devops-labs-ru/namespaces/agents/qdrant-agent/values.yaml
# Qdrant Helm-чарт, минимальная конфигурация для single-node
# API key передаётся через gomplate vault://secret/qdrant/api_key,
# не через ansible.builtin.password в values.

cluster:
  replication_factor: 1
  number_of_replicas: 0

storage:
  storage_class: "local-path"
  size: 20Gi

service:
  type: ClusterIP
  ports:
    rest: 6333
    grpc: 6334
    # метрики — на этом же rest-порту (/metrics), отдельного порта Qdrant не отдаёт

security:
  api_key: "{{ vault.qdrant_api_key }}"
  tls_enabled: true

resources:
  requests:
    cpu: "250m"
    memory: "512Mi"
  limits:
    memory: "2Gi"
```

### Ansible-задачи в `site.yml` (после `helmwave up`)

1. `k8s Secret: qdrant-api-key` — хранит `QDRANT_API_KEY`, читается
   `openwebui` и `retriever` подами.
2. `VMScrapeConfig` — `agents-qdrant`, `namespace: agents`, `port: rest`
   (метрики на REST-порту, отдельного порта нет).
3. `Kubernetes Job: qdrant-init-collections` — создаёт коллекции
   `openwebui-embeddings` и `platform-kb` через REST API.
4. `Kubernetes CronJob: qdrant-snapshot` — `POST /snapshots` на расписании
   (например, ежедневно 03:00 UTC).

### Структура Ansible-роли `roles/qdrant` (для future standalone-пути)

```
roles/qdrant/
├── defaults/main.yml
├── tasks/
│   ├── main.yml
│   ├── install.yml
│   ├── configure.yml
│   └── snapshots.yml
├── templates/
│   ├── qdrant.service.j2
│   ├── qdrant.yaml.j2
│   └── qdrant-tls.conf.j2
├── handlers/main.yml
└── meta/main.yml
```

Стandalone-путь (Debian/Ubuntu, systemd) — отложен, не пилот.

## Ссылки

- `ROADMAP.md` №66 — постановка задачи: выделенный vector store для RAG.
- `ROADMAP.md` №68 — MinIO (`minio-infra-1`), S3-совместимое хранилище для
  снапшотов Qdrant (§5).
- `docs/adr/0015-ai-agent-platform-architecture.md` §7/§9 — namespace `agents`,
  default-deny, `retriever`-сервис, агентная сеть.
- `docs/adr/0022-new-component-requirements.md` — чек-лист нового компонента
  (§1–§12), по которому спроектирован этот ADR.
- `docs/adr/0023-postgresql-standalone-role.md` §6 — naming convention
  `<component>-<purpose>-<n>`.
- `helm/envs/platform-devops-labs-ru.yaml` — helmwave релизы платформы.
- `helm/values/platform-devops-labs-ru/namespaces/platform/minio-infra-1/values.yaml`
  — S3-эндпоинт для снапшотов Qdrant.
- `helm/values/platform-devops-labs-ru/namespaces/platform/openwebui/values.yaml`
  — текущая RAG-конфигурация Open WebUI (Chroma → Qdrant migration path).
- [Qdrant Helm chart](https://github.com/qdrant/qdrant-helm) — официальный
  Helm-чарт, источник для §2.
- [Qdrant Snapshots](https://qdrant.tech/documentation/concepts/snapshots/) —
  документация по S3-снапшотам (§5).
- [Qdrant Metrics](https://qdrant.tech/documentation/metrics/) — документация
  по Prometheus-метрикам (§6).
- [Qdrant REST API](https://qdrant.tech/documentation/rest-api/) — OpenAPI-
  спецификация для интеграции с `retriever` (§7).
