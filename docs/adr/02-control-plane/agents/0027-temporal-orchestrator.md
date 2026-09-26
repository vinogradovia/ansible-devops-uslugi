# ADR-0027: Temporal — оркестратор durable execution для AI-агентов

- **Статус:** Предложено
- **Дата:** 2026-09-26
- **Авторы:** Ivan Vinogradov (на основе §12 ADR-0015)

## Контекст

ADR-0015 (§«Схема размещения агентного стека», §6–§9, §12) определяет архитектуру AI-agent
платформы, в которой Temporal — единственный узел, создающий `agent-job` и оркестрирующий
их жизненный цикл. ADR-0015 §11 выбирает OpenAI Agents SDK для реализации цикла «рассуждение →
tool-call → наблюдение» внутри `agent-job` и фиксирует, что официальный интеграционный путь
этого SDK с Temporal GA с марта 2026 (turn агента исполняется как Temporal Activity).

Кодовая реализация Temporal отсутствует: ни в `roles/`, ни в `helm/`, ни в `platform/*/site.yml`
нет ни одной задачи или манифеста, связанного с Temporal. Развёрнутые компоненты — только
`llm1`-нода (Фаза 1, ADR-0015 §10), инференс (llama-server/TEI) и LiteLLM-гейтвей
(`docs/platform/agent-platform.md`).

ADR-0015 §12 описывает Temporal подробно, но как вложенный параграф общей архитектуры — не
самостоятельный документ решения. Выделение в отдельный ADR необходимо для:

- развязки ответственности: ADR-0015 остаётся обобщённой архитектурой (агенты, изоляция,
  namespace'ы, bootstrap), а ADR-0027 — специализированным решением по одному компоненту;
- возможности ссылаться на ADR-0027 из других документов (ROADMAP, планы реализации,
  `platform/*/site.yml`) без перехода к §12 внутри ADR-0015;
- фиксации решений, которые зависят от ограничений самого Temporal Server (хранилище,
  версионирование, Helm-чарт), а не от общей агентной архитектуры.

## Решения

### 1. Temporal — оркестратор durable execution, не просто планировщик

**Решение:** Temporal используется как движок durable execution (workflow описывается обычным
кодом, не YAML/DSL), а не как cron-планировщик или простая обёртка над `kubectl create job`.
Каждый шаг агента — отдельная Activity в workflow, с ретраями по retry-policy и таймерами.
`Signal`/`Query` — отдельные примитивы Temporal (внешнее событие и чтение состояния
выполняющегося workflow), не разновидность таймера.

**Обоснование:** прогон агента — цепочка из нескольких вызовов модели и инструментов,
растянутая на минуты. Одноразовый Job без durable-слоя при любом транзиентном сбое
(вытеснение пода, перезапуск ноды, OOM, сетевой обрыв к LiteLLM) теряет весь прогресс целиком.
Temporal восстанавливает workflow с последнего завершённого шага, а не с начала, и ретраит
только упавшую Activity.

**Связь с ADR-0015 §12:** полное сохранение оригинального обоснования, см.
`docs/adr/0015-ai-agent-platform-architecture.md`, §12.

### 2. Размещение: `ns: platform`, runtimeClass `runc`

**Решение:** Temporal Server живёт в namespace `platform` под дефолтным `runc`-рантаймом.
Сам Temporal не исполняет код агента — только оркестрирует создание/повтор/расписание Job'ов.
Отдельный namespace для Worker'ов не требуется, если Worker остаётся постоянным процессом в
`ns: platform` (Паттерн A «Job-per-turn» или Паттерн C «Worker-in-platform, Job-wait» — см.
Открытый вопрос №1). Если вместо этого Worker переносится в `ns: agents` (Паттерн B
«Worker-in-agents»), потребуется отдельная схема NetworkPolicy — выбор паттерна не входит в этот
ADR (Открытый вопрос №1).

**Обоснование:** Temporal — инфраструктурный компонент платформы, а не агентный workload.
Размещение в `ns: platform` рядом с другими платформенными сервисами (Semaphore, Gitea,
Authelia) упрощает сеть и доступ к БД. `runc` достаточен — Temporal Server не требует GPU
или песочницы.

**Связь с ADR-0015 §6, §9:** Temporal явно отложен до последнего шага bootstrap
(«первый агент — вручную, одним `kubectl create job`, и только потом Temporal и расписания»).

### 3. Хранилище — `postgresql-infra-1` (standalone PostgreSQL, ADR-0023)

**Решение:** Temporal Server использует отдельную базу данных PostgreSQL на VM
`postgresql-infra-1` (ADR-0023) — тот же standalone PostgreSQL, что обслуживает саму платформу
(LiteLLM, `postgres_exporter`). Не использует встроенное SQLite (только для локальной
разработки), не разворачивает CloudNativePG в кластере. БД заводится отдельной схемой и
пользователем на существующем инстансе, не отдельным кластером.

**Обоснование:**

1. **Единый источник истины для инфраструктурных БД.** Платформа уже использует
   `postgresql-infra-1` для LiteLLM и exporter'ов (ADR-0023) — добавление ещё одной БД/схемы
   на тот же инстанс упрощает эксплуатацию (один бэкап, один мониторинг, одно TLS-сертифицирование),
   в отличие от раздувания кластера дополнительными PostgreSQL-инстансами (CloudNativePG в `ns: data`
   для Temporal + CloudNativePG для retriever'а = два независимых стега в одном namespace).

2. **Совместимость.** Начиная с Temporal Server v1.20 — требуется только SQL-совместимая БД
   (PostgreSQL/MySQL), Elasticsearch для advanced visibility больше не обязателен.
   `postgresql-infra-1` предоставляет PostgreSQL 15+ — полностью совместимо. LiteLLM уже
   обращается к `postgresql-infra-1` по TCP 5432 — прецедент, что маршрут с платформенных нод до
   этой VM в принципе рабочий, но LiteLLM живёт в `ns: gateway`, не в `ns: platform`, а
   `egress-proxy` (ADR-0015 §7) — это путь `ns: gateway` во внешний интернет, к внутренней
   `postgresql-infra-1` отношения не имеет и в кластере пока не реализован ни для одного
   namespace (NetworkPolicy для `ns: platform` не заведены). Для Temporal правило egress к
   `postgresql-infra-1:5432` предстоит завести отдельно — см. чек-лист ADR-0022 №10 ниже.

3. **Изоляция отказов на уровне схемы.** Хотя БД общая с LiteLLM, schema/temporal отделена
   на уровне PostgreSQL (отдельный пользователь, отдельная schema). Падение БД LiteLLM не
   должно влиять на durable execution — и наоборот, потеря event History Temporal'а означает
   потерю всех не завершённых агентов, но это тот же инстанс, что обслуживает LiteLLM.

**Отличие от ADR-0015 §12:** в ADR-0015 этот вопрос оставлен открытым
(«переиспользует ли Temporal тот же кластер отдельной базой/схемой, или получает собственный
инстанс CloudNativePG»). Здесь принято решение в пользу отдельной схемы на существующем
`postgresql-infra-1` (ADR-0023).

**Локальная разработка не мигрирует в кластер.** Embedded SQLite Temporal Server остаётся
инструментом локальной разработки/тестирования вне этого кластера — миграция истории workflow
между SQLite и PostgreSQL здесь не требуется, соответствующей истории Event History попросту не
существует до первого прогона на `postgresql-infra-1`.

### 4. Helm-чарт — с отключением встроенных зависимостей

**Решение:** Temporal разворачивается Helm-чартом `temporalio/temporal` (официальный от
Temporal Technologies). Из чарта сознательно отключаются встроенные Cassandra, Elasticsearch
и Prometheus — иначе чарт поднимет вторую половину кластера, что на пилоте (один узел)
неприемлемо по ресурсам.

**Обоснование:** ADR-0015 §07 (`agent-stack-k3s.md`, §04, таблица `platform`) прямо указывает:
«Отключите в values встроенные Cassandra, Elasticsearch и Prometheus — иначе чарт поднимет
вторую половину кластера». На пилоте один узел k3s и ограниченный RAM — каждая лишняя сервисная
нагрузка критична, независимо от того, что БД самого Temporal (§3) — внешний
`postgresql-infra-1`, а не встроенная в чарт зависимость. Prometheus для мониторинга Temporal
будет подниматься отдельно через `kube-prometheus-stack` (namespace `obs`), а не встроенным в
чарт.

**Отличие от ADR-0015 §12:** ADR-0015 не описывает механизм установки чарта — здесь фиксируется
конкретный Helm-чарт и осознанные отключения.

### 5. Порядок развёртывания — последний шаг bootstrap

**Решение:** Temporal развёртывается последним из всего агентного стека, после: (1) GPU-ноды
и bootstrap кластера, (2) каркаса namespace'ов и NetworkPolicy, (3) первого ручного прогона
агента через `kubectl create job`, (4) базовых данных (CloudNativePG + MinIO).

**Обоснование:** ADR-0015 §9 п.9: «первый агент — вручную, одним `kubectl create job`, и только
потом Temporal и расписания» — тот же принцип «фундамент → следующий слой», что уже применён
для freeipa → Authelia в ADR-0013: сначала подтверждается, что изолированный прогон агента
корректен сам по себе, и только потом поверх него добавляется слой оркестрации/повторов.

**Связь с ADR-0015 §10 (Фаза 1):** Фаза 1 (нода-фундамент) сознательно исключает Temporal
из периметра — проверяется только GPU/изоляция/RuntimeClass. Temporal попадает в следующую
фазу, после подтверждения корректности ручного прогона.

## Открытые вопросы / вне скоупа

### 1. Где исполняется код агента: Worker или изолированный Job?

Диаграмма ADR-0015 (`TEMPORAL → создаёт Job → JOB`) описывает паттерн «Temporal лишь порождает
k8s Job, вся работа агента — внутри изолированного пода `runsc`». Но официальная интеграция
OpenAI Agents SDK + Temporal (ADR-0015 §11) построена на другом паттерне: каждый ход (turn)
агента исполняется как Temporal Activity **внутри самого Worker-процесса**, без создания
отдельного k8s Job на каждый шаг.

Эти два паттерна не эквивалентны по границе изоляции:

- **Паттерн A (Job-per-turn):** Temporal в `ns: platform` создаёт Job'ы в `ns: agents`. Worker
  — постоянный процесс в `ns: platform`. Каждый turn агента — это `kubectl create job` + ожидание
  завершения. Безопасно по изоляции, но добавляет latency и нагрузку на kube-api.
- **Паттерн B (Worker-in-agents):** Worker живёт в `ns: agents` под `runsc`. Activity внутри
  workflow — прямой ход агента (LLM call, tool call). Максимальная изоляция, но Worker —
  постоянный процесс с доступом к GPU-ноде и внешним API.
- **Паттерн C (Worker-in-platform, Job-wait):** Worker остаётся в `ns: platform`, Activity внутри
  workflow — вызов «дождаться завершения k8s Job» (через kube-api), а не сам ход агента.

**Вне скоупа этого ADR:** выбор между паттернами. Это потребует отдельного ADR, так как влияет
на все следующие компоненты: NetworkPolicy (вход из `ns: platform` в `agents` для
Worker-in-platform или наоборот), доступ Worker'а к kube-api, GPU-ноде, внешним API,
ServiceAccount'ы.

### 2. Human-in-the-loop и Signal

Примитив Temporal `Signal` технически подходит для паузы workflow на подтверждение человеком
(ADR-0015 §12). Но последовательность шагов, кто именно подтверждает и через какой UI, этим
ADR не определены. В OpenAI Agents SDK human-in-the-loop собирается вручную через
`guardrails`/проверки на стороне вызывающего кода — не через Signal.

### 3. Наблюдаемость за Temporal

Не определено:

- UI Temporal (по умолчанию порт 8088) — публиковать ли через Traefik IngressRoute или
  оставить внутренним?
- Метрики Temporal (Prometheus `/metrics`) — подключать ли к `kube-prometheus-stack` в
  `ns: obs` или к VictoriaMetrics в `monitoring_server`?
- Логи — собирать ли в Loki?

**Вне скоупа:** детали наблюдаемости за Temporal. Решения будут приниматься при реализации,
когда станет известен SLA компонента и потребность в его UI/метриках для операторов.

### 4. Версионирование и совместимость

ADR-0015 §11 выбирает OpenAI Agents SDK с официальной интеграцией Temporal GA с марта 2026.
Не определено: какая конкретная версия Temporal Server будет использоваться (v1.25+, v1.28+,
или какая-то другая). Это влияет на:

- Поддерживаемые SQL-базы (PostgreSQL 15+ для v1.20+)
- Совместимость с Temporal CLI (если будет использоваться для локальной разработки)
- Поддержку новых примитивов (Child Workflow, Cron Schedule)

## Не проработано

- **Автоскейлинг Worker'ов.** Не определено, как Worker'ы масштабируются: отдельный Deployment
  с HPA на основе очереди задач, или один постоянный инстанс на пилоте.
- **Multi-tenant namespace'ы в Temporal.** Если каждая клиентская `Project` (ADR-0015 §2)
  будет иметь отдельный Temporal namespace для изоляции данных/workflow — это отдельный
  вопрос, не связанный с базовым развёртыванием.
- **Бэкап event history.** Не определён RPO/RTO для event history Temporal'а. Если используется
  `postgresql-infra-1` (ADR-0023) — бэкап через Bareos должен быть включён в рамках
  требования №11 ADR-0022 (`backup_server_clients`), аналогично тому, как `postgresql-infra-1`
  бэкапится для LiteLLM. Если CloudNativePG — отдельный backup schedule, PITR point.

## Соответствие ADR-0022 (чек-лист онбординга)

| Требование | Применимо | Статус | Комментарий |
|---|---|---|---|
| 1. Внутренний репозиторий (Helm через Nexus) | Да | Предположено | Helm-чарт `temporalio/temporal` будет тянуться через `nexus-cache` helm proxy-repo (требование №1 ADR-0022: Nexus получает `helm` proxy-repo, существующие Helm-репозитории платформы переключаются на него). До этого — пока чарт тянется напрямую из публичного интернета, компонент нарушает требование №1. |
| 2. RBAC через групповую модель ADR-0019/0020 | Да (UI) | Вне скоупа | Temporal UI (порт 8088) — read-only dashboard операторов, не web-приложение с нативным OIDC. Решение по авторизации: `forwardAuth` на Authelia (как `radar`/`infra-panel`, переходный паттерн ADR-0022 §2) или без авторизации (если UI не публикуется наружу). Группа `platform-admins` — кандидат для доступа. |
| 3. Ссылка в `infra-panel` | Да | Предположено | Если Temporal UI будет опубликован, ссылка в `infra_panel_extra_services` ведёт на SSO-авторизованный эндпоинт (прямой redirect URL для инициации OIDC-флоу через Authelia, требование №3 ADR-0022). |
| 4. Метрики — экспортёр, scrape, дашборд, все три сразу | Да | Предположено | Temporal Server отдаёт метрики нативно через Prometheus `/metrics` (требование №4 ADR-0022). Подключение к VictoriaMetrics через `VMServiceScrape` (как LiteLLM, ADR-0015 §6). Дашборд — из `ADDONS/grafana_dashboards/` или официальный от Temporal. Все три части сдаются вместе. |
| 5. TLS из внутреннего PKI CA | Да (если HTTP UI) | Предположено | Если Temporal UI публикуется наружу — TLS из OpenBao PKI через `tasks/issue-tls-cert.yml` (требование №5 ADR-0022, ADR-0016 §3). Если UI не публикуется — не применимо. |
| 6. DNS — запись в двух местах | Да | Предположено | Если Temporal UI получает домен — запись в `coredns-custom` ConfigMap кластера + README окружения, раздел "/etc/hosts операторов" (требование №6 ADR-0022). |
| 7. Секреты из OpenBao | Да | Предположено | Любые секреты (токены, пароли bind-учётки для БД) — генерируются/читаются идемпотентным GET→404→POST-циклом в OpenBao, подставляются через `gomplate vault://` (требование №7 ADR-0022). Bind-учётка для `postgresql-infra-1` — отдельный `secret/temporal` OpenBao. |
| 8. Стаб `helm/values/releases_common/<name>.yaml` | Да | Обязательно | Файл `helm/values/releases_common/temporal.yaml` заводится до первого `helmwave up` (требование №8 ADR-0022). |
| 9. Явные `resources.requests`/`limits` | Да | Обязательно | Deployment StatefulSet Temporal Server декларирует explicit `resources.requests`/`limits` (требование №9 ADR-0022). На единственной ноде pилота необъявленный лимит — риск OOM. |
| 10. NetworkPolicy | Да | Решение: default-deny не нужен | `ns: platform` сегодня не имеет `default-deny` (требование №10 ADR-0022). Решение для Temporal: без `default-deny`, но с явным правилом egress к `postgresql-infra-1:5432` и к kube-dns. Полный анализ NetworkPolicy для `ns: platform` — отдельная задача (ROADMAP). |
| 11. Резервное копирование | Да | Решение: бэкап через Bareos на `postgresql-infra-1` | Event History Temporal'а — состояние, потеря которого болезненна. Бэкап — через Bareos на `postgresql-infra-1` (требование №11 ADR-0022, ADR-0009/0010). БД заводится в `backup_server_clients` вместе с другими БД на том же инстансе. Сам Helm-релиз Temporal (stateless) — бэкап не требуется, состояние воспроизводимо из declarations. |
| 12. MCP — регистрируется сразу | Нет | Неприменимо | У Temporal нет MCP-сервера. |
| 13. Документация `docs/platform/<name>.md` | Да | Предположено | Файл `docs/platform/temporal.md` заводится вместе с компонентом (требование №13 ADR-0022). HLD/LLD/DD по уже устоявшемуся шаблону. |
| 14. Инфраструктурные тесты | Да | Предположено | Персистентный pytest-based тест (testinfra) проверяющий реальное развёрнутое состояние (требование №14 ADR-0022): под/сервис запущен, порт слушает, метрики доступны, `VMServiceScrape` health: up, `pg_up` для БД на `postgresql-infra-1`. |
| 15. Развёртывание через Operator | Нет | Обоснованно: Deployment | Готового Kubernetes Operator для Temporal Server не существует (требование №15 ADR-0022, поиск через OperatorHub.io + организация `temporalio`). Развёртывание через Helm-чарт (`temporalio/temporal`) — прямой Deployment/StatefulSet. Запись в ROADMAP: «Operator для Temporal — не найден, реализация самостоятельно не планируется (нет официального Operator от вендора, зрелых community-проектов нет)». |

## Ссылки

- `docs/adr/0015-ai-agent-platform-architecture.md` — §12 (исходное описание), §6–§9 (bootstrap,
  namespace'ы, runtime), §11 (выбор OpenAI Agents SDK)
- `docs/adr/0015.1-infra-agent.md` — контур активации агентных workflow
- `docs/adr/0016-openbao-secrets-pki.md` — секреты и TLS/PKI (чек-лист ADR-0022 №5/№7)
- `docs/adr/0019-platform-rbac-model.md`, `docs/adr/0020-kube-apiserver-oidc.md` — модель допуска
  (чек-лист ADR-0022 №2)
- `docs/adr/0022-new-component-requirements.md` — чек-лист онбординга, применённый целиком в
  разделе «Соответствие ADR-0022»
- `docs/adr/0023-postgresql-standalone-role.md` — `postgresql-infra-1`, решение §3
- `docs/adr/0009-backup-server-role.md`, `docs/adr/0010-backup-agent-role.md` — Bareos-бэкап
  (чек-лист ADR-0022 №11)
- `docs/Requirements Specification/agent-stack-k3s.md` — §04 (таблица `platform`, Helm-чарт),
  §07 (bootstrap)
- `docs/platform/agent-platform.md` — HLD/LLD, текущий статус реализации
- [Temporal — How it Works](https://temporal.io/how-it-works)
- [Temporal Architecture — Temporal Documentation](https://docs.temporal.io/encyclopedia/architecture/temporal-architecture)
- [Announcing OpenAI Agents SDK + Temporal Integration](https://temporal.io/blog/announcing-openai-agents-sdk-integration)
