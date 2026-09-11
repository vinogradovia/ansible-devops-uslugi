# Flux — GitOps-синхронизация (Фаза 2 ADR-0014)

Тот же дизайн, что `platform/aicd/flux/README.md` (первый стенд) — здесь описаны только различия
и статус конкретно этого окружения.

Flux (source-controller + kustomize-controller, остальные контроллеры чарта отключены, см.
`helm/values/platform-devops-labs-ru/namespaces/flux-system/flux2/values.yaml`) ставится Helm-
релизом через Helmwave (`helm/envs/platform-devops-labs-ru.yaml`) — как и на первом стенде, это
уже было сделано механическим переносом `site.yml`/`helm/envs/*` до того, как этот каталог
(конфигурация самого Flux) появился. Secret `gitops-git-auth` (flux-system) тоже уже
синхронизируется безусловно на каждом прогоне `platform/aicd-devops-labs-ru/ansible/site.yml`
(задачи «Flux: прочитать текущий admin_password secret/gitea»/«Flux: синхронизировать
gitops-git-auth», актуальный admin_password из `secret/gitea` OpenBao этого окружения) — в
отличие от первого стенда, здесь этот Secret никогда не заводился отдельным файлом с
плейсхолдером, синк был частью site.yml с самого начала.

## Ресурсы

- `gitrepository.yaml` — `GitRepository` `flux-system/gitops`, ветка `main`, интервал 1m. Тот же
  `url` (`http://gitea-http.platform.svc.cluster.local:3000/platform/gitops.git`), что первый
  стенд — namespace/имя Service Gitea не меняются между окружениями (оба через тот же
  `gitea-charts/gitea`, namespace `platform`).
- `kustomization.yaml` — Flux `Kustomization` `flux-system/platform-modules`: путь
  `./clusters/platform` в этом `GitRepository`, `prune: true`, `targetNamespace: platform`.

Применены вручную (`kubectl apply -f`, тот же приём, что первый стенд — конфигурация самого Flux,
курица/яйцо) на живой кластер `aicd-devops-labs-ru`. Автоматизация через `site.yml` — тот же
открытый пункт, что на первом стенде.

## Проверено реальным прогоном

`GitRepository`/`Kustomization` — оба `READY: True` в течение первого интервала (~1 мин), сразу
после того, как в `platform/gitops` (Gitea этого стенда) появился реальный `clusters/platform/`.

**Фаза 2 закрыта** для этого окружения.

## Не проработано (следующие шаги)

Тот же список, что первый стенд (`platform/aicd/flux/README.md`, «Не проработано») —
`gitrepository.yaml`/`kustomization.yaml` не под автоматизацией `site.yml`, `gitea_admin`
(полноправный admin) как креды `GitRepository` — временное решение, CRD `modules.platform.devops.uslugi`
применяется отдельно от Flux (`kubectl apply`, не под GitOps).
