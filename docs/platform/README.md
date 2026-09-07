# Реестр компонентов платформы (`platform/aicd*`)

Персистентная k3s-инфраструктура двух окружений — `platform/aicd` (libvirt, домен
`aicd.platform`) и `platform/aicd-devops-labs-ru` (Proxmox, домен `aicd.devops-labs.ru`), —
которая обслуживает саму разработку и эксплуатацию коллекции (CI/CD, секреты, единая
авторизация, наблюдаемость), в отличие от `roles/*`, которые эта платформа применяет к
инфраструктуре клиентов. Архитектура и история решений — в `docs/adr/*`; этот раздел —
структурированное описание того, что из этого реально развёрнуто, тремя уровнями на каждый
компонент:

- **HLD** (High-Level Design) — место компонента в платформе: с кем связан, что даёт другим,
  от чего зависит сам.
- **LLD** (Low-Level Design) — внутреннее устройство: конфигурация, поток секретов, ключевые
  решения формата данных.
- **DD** (Diagram of Deployment) — что реально развёрнуто в кластере: namespace, объекты k8s,
  ресурсы, различия между двумя окружениями.

Общая картина (граф всех компонентов разом, физическая топология обоих окружений) —
[`overview.md`](overview.md). Реестр ролей коллекции (`roles/*`, отдельная документация,
README+ADR на роль) — [`../components.md`](../components.md), не дублируется здесь.

**Ведение обязательно, не факультативно.** Новый компонент получает свой файл сразу, в том же
PR/прогоне, а изменения в существующем компоненте обновляют соответствующий раздел тогда же, когда
меняется код/values — `docs/adr/0022-new-component-requirements.md` §13. Все 14 файлов ниже
заведены одним ретроактивным проходом 2026-09-07 — это разовое закрытие уже накопленного разрыва,
не образец процесса для будущих компонентов.

## Компоненты

| Компонент | Назначение | Документ | Статус |
|---|---|---|---|
| — | Платформа целиком: граф компонентов, физическая топология | [overview.md](overview.md) | — |
| FreeIPA (персистентный) | Единый каталог платформы — LDAP + Kerberos KDC + CA | [freeipa.md](freeipa.md) | реализовано, оба окружения |
| Authelia | OIDC-провайдер + forwardAuth, RBAC поверх групп `freeipa` | [authelia.md](authelia.md) | реализовано, оба окружения |
| OpenBao | Секреты (KV v2) + внутренний PKI CA | [openbao.md](openbao.md) | реализовано, оба окружения |
| Nexus | Кеширующий прокси (docker/apt/raw), внутренний registry | [nexus.md](nexus.md) | реализовано, оба окружения |
| Gitea | Self-hosted git — источник Module-манифестов/inventory | [gitea.md](gitea.md) | реализовано, оба окружения |
| gitea-actions-runner | CI-раннер Gitea Actions (host-режим, lint) | [gitea-actions-runner.md](gitea-actions-runner.md) | реализовано, оба окружения |
| Semaphore | Веб-панель запуска ansible/terraform | [semaphore.md](semaphore.md) | реализовано, оба окружения |
| Flux2 | GitOps-синхронизация Module-манифестов из Gitea | [flux.md](flux.md) | реализовано, оба окружения |
| platform-controller | Module CRD + reconcile-контроллер (Go, вне кластера) | [platform-controller.md](platform-controller.md) | пилот, только `platform/aicd` |
| Radar | Read-only Kubernetes UI | [radar.md](radar.md) | реализовано, оба окружения |
| infra-panel | Дашборд-стартовая страница (k3s-путь роли `infra_panel`) | [infra-panel.md](infra-panel.md) | реализовано, оба окружения |
| monitoring (VictoriaMetrics + Grafana) | Self-мониторинг самого k3s-кластера платформы | [monitoring.md](monitoring.md) | реализовано, оба окружения |
| agent-platform | Локальный LLM-инференс + гейтвей (ADR-0015/0021) | [agent-platform.md](agent-platform.md) | пилот (Фаза 1), только `platform/aicd-devops-labs-ru` |

## Сквозные схемы (не отдельные компоненты)

- **Единая авторизация** (кто и как входит) — `docs/adr/0013-unified-auth-architecture.md`,
  реализация — [authelia.md](authelia.md) + [freeipa.md](freeipa.md).
- **Ролевая модель / RBAC** (кому что доступно внутри сервисов) —
  `docs/adr/0019-platform-rbac-model.md`, матрица — [authelia.md](authelia.md#rbac-модель-adr-0019).
- **Доступ к `kube-apiserver` по OIDC** — `docs/adr/0020-kube-apiserver-oidc.md` (архитектурно
  решено, не реализовано) — [overview.md](overview.md#доступ-к-кластеру) и
  [freeipa.md](freeipa.md).
- **Платформенный контроллер как единица GitOps-исполнения** —
  `docs/adr/0014-platform-controller-architecture.md`, реализация —
  [platform-controller.md](platform-controller.md) + [flux.md](flux.md) + [semaphore.md](semaphore.md).

## Что не является отдельным компонентом этого реестра

- **k3s (control-plane)** — не описан отдельным файлом, это субстрат, на котором развёрнуты все
  компоненты выше; топология самого кластера (ноды, taint'ы, RuntimeClass) — часть
  [overview.md](overview.md) (DD) и, для GPU-ноды `llm1`, [agent-platform.md](agent-platform.md).
- **Официальный Harbor** (`docs/adr/0012-cicd-platform-architecture.md` §1) — архитектурно
  решён, ни строки кода не реализовано; роль его функции сейчас частично закрывает Nexus
  ([nexus.md](nexus.md)).
- **roles/\*** коллекции (`monitoring_server`, `mysql_replication` и т.д.) — отдельная
  документация, [`../components.md`](../components.md), не входят в этот реестр по определению
  (это исполняемые роли, применяемые ЧЕРЕЗ платформу, а не компоненты самой платформы)
