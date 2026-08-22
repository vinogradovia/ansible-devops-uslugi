# Flux — GitOps-синхронизация (Фаза 2 ADR-0014)

Архитектура и обоснование — `docs/adr/0014-platform-controller-architecture.md` §4, план по
фазам — `ROADMAP.md`, «Предлагаемая последовательность работ», пункт 7.

Flux (source-controller + kustomize-controller — только эти два, остальные контроллеры чарта
отключены, см. `helm/values/platform/namespaces/flux-system/flux2/values.yaml`) ставится Helm-
релизом через Helmwave (`helm/envs/platform.yaml`), тем же способом, что Gitea/Semaphore (Фаза 0).
Этот каталог — конфигурация самого Flux (откуда синхронизировать), а не то, что синхронизируется:
содержимое `clusters/platform/` в репозитории `platform/gitops` (Module-манифесты) — отдельно,
живёт в Gitea, не в этом репозитории.

## Ресурсы

- `git-credentials-secret.yaml` — basic-auth (admin-аккаунт Gitea, тот же плейсхолдер, что и
  везде на этом стенде, `platform/cicd/README.md`) для доступа к приватному `platform/gitops`.
- `gitrepository.yaml` — `GitRepository` `flux-system/gitops`, ветка `main`, интервал 1m.
- `kustomization.yaml` — Flux `Kustomization` `flux-system/platform-modules`: путь
  `./clusters/platform` в этом `GitRepository`, `prune: true`, `targetNamespace: platform`.

Применены вручную (`kubectl apply -f`, конфигурация самого Flux — не то, что предполагается
делать через сам Flux, курица/яйцо) на живой стенд `platform/cicd`. Автоматизация этого
применения через `site.yml` — не сделана, следующий шаг при возврате к этой фазе.

## Проверено реальным прогоном

`GitRepository`/`Kustomization` — оба `READY: True` в течение первого же interval (~20-30с).

Ключевая проверка (условие Фазы 2 — «коммит Module-манифеста в Gitea должен без ручных команд
отражаться в `kubectl get module`»): в `platform/gitops` закоммичено поле
`spec.vars.infra_panel_gitops_managed: true` в `clusters/platform/infra-panel-pilot.yaml` —
**только через Gitea API, ни разу не через `kubectl apply`**. После следующего reconcile-цикла
(≤1 минута) поле появилось в живом объекте `Module` в кластере
(`kubectl get module -n platform -o jsonpath='{.items[0].spec.vars}'`). Это отличает объект от
Module CR Фазы 1 (применённого вручную `kubectl apply`) — теперь тот же CR под управлением Flux,
Фаза 1 CR не удалялся, а естественно перешёл под GitOps-владение (одинаковые name/namespace).

**Фаза 2 закрыта.**

## Не проработано (следующие шаги)

- Применение самих `git-credentials-secret.yaml`/`gitrepository.yaml`/`kustomization.yaml` не
  автоматизировано через `site.yml` — сделано вручную один раз.
- `gitea_admin` (полноправный admin-аккаунт) как креды для `GitRepository` — временное решение,
  как и everywhere на этом стенде; отдельный read-only deploy-токен — задача для более поздней
  фазы (вместе с переездом секретов в OpenBao, `docs/adr/0012-cicd-platform-architecture.md` §3).
- CRD `modules.platform.devops.uslugi` (Фаза 1) сам не под управлением Flux — применён отдельно,
  напрямую `kubectl apply`. Решение, стоит ли заводить CRD туда же под GitOps — не принято.
