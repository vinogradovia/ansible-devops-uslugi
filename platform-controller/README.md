# platform-controller — Module CRD (Фаза 1 ADR-0014)

Архитектура и обоснование — `docs/adr/0014-platform-controller-architecture.md` §1/§2/§5,
план по фазам — `ROADMAP.md`, «Предлагаемая последовательность работ», пункт 7.

Это каталог будущего Go-контроллера (Фаза 3 — свой `go.mod`, `cmd/`, `internal/controller/`,
независимый от poetry/ansible-lint тулчейна остального репозитория). На Фазе 1 в нём — только
схема `Module` CRD и один пример CR, без единой строчки кода контроллера — цель Фазы 1 в том,
чтобы доказать, что схема достаточна, прежде чем писать reconcile-логику.

## Схема

`config/crd/module-crd.yaml` — `CustomResourceDefinition` `modules.platform.devops.uslugi/v1alpha1`:

- `spec.role` — имя Ansible-роли коллекции `devops.uslugi` (ADR §1).
- `spec.vars` — произвольная структура (`x-kubernetes-preserve-unknown-fields`), эквивалент
  Ansible `group_vars` для роли.
- `spec.inventoryRef.{repository,revision,path}` — ссылка на существующий inventory-файл в git,
  не отдельный CRD хостов (ADR §5).
- `spec.semaphoreTemplateID` — ID Task Template в Semaphore, который контроллер вызывает при
  reconcile (ADR §2). Соответствие role → ID пока задаётся вручную здесь — автоматический lookup
  не спроектирован (ADR-0014, «Не проработано»).
- `status.conditions` — стандартный K8s conditions-паттерн (аналог Crossplane Managed Resources).
- `status.{lastAppliedRevision,lastSyncTime,semaphoreJobID}` — остальной статус reconcile.

## Проверено реальным прогоном

На живом стенде `platform/cicd` (см. его README) — вживую, не только `kubectl apply --dry-run`:

```bash
kubectl apply -f config/crd/module-crd.yaml
kubectl apply -f config/samples/module-infra-panel.yaml
```

`config/samples/module-infra-panel.yaml` ссылается на реально существующие на стенде объекты —
репозиторий `platform/gitops` в Gitea и Task Template id=1 (`infra_panel (pilot, ADR-0014 Фаза 0)`)
в Semaphore-проекте `platform` (id=1), созданные вручную через REST API этих сервисов
(`platform/cicd/README.md`, «Ручные шаги»).

Результат: CR создаётся и проходит валидацию OpenAPI-схемой (вложенные `vars`/`inventoryRef` —
без ошибок), short name `mod` резолвится, additional printer columns (`Role`/`Ready`/`LastSync`)
отображаются. `status`-subresource отдельно протестирован через
`kubectl patch --subresource=status` (имитация будущей записи контроллера) — `conditions`,
`lastAppliedRevision`, `lastSyncTime`, `semaphoreJobID` принимаются и корректно читаются обратно
(`kubectl get module` показывает `READY: True`, `LASTSYNC` — записанное значение).

**Фаза 1 закрыта**: схема достаточна для перехода к Фазе 2 (GitOps-синхронизация Flux) и Фазе 3
(код контроллера) без известных пробелов в структуре `spec`/`status`.

## Не проработано (переносится из ADR-0014, актуально и для этой схемы)

- Соответствие `role → semaphoreTemplateID` задаётся вручную в каждом CR — автоматический lookup
  (например, по конвенции именования Task Template) не спроектирован.
- Формат `status.conditions` не финализирован строгим набором `type` (`Ready`/`Progressing`/...) —
  сейчас это просто открытый список, контроллер (Фаза 3) должен будет договориться о конкретных
  значениях.
- Соответствие «модуль ↔ роль» 1:1 или объединение нескольких ролей одним модулем — не решено
  (ADR-0014, «Не проработано» — не переоткрывается здесь).
