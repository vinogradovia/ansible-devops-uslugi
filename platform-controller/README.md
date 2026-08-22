# platform-controller — Module CRD + MVP-контроллер (Фазы 1 и 3 ADR-0014)

Архитектура и обоснование — `docs/adr/0014-platform-controller-architecture.md` §1/§2/§5,
план по фазам — `ROADMAP.md`, «Предлагаемая последовательность работ», пункт 7.

Свой `go.mod` (`github.com/vinogradovia/ansible-devops-uslugi/platform-controller`), независимый
от poetry/ansible-lint тулчейна остального репозитория, как и предполагалось в плане Фазы 3.
`main.go` + `internal/{controller,semaphore}/` — сам контроллер (Фаза 3). `config/crd/` +
`config/samples/` — схема `Module` CRD (Фаза 1), см. ниже.

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

## Контроллер MVP (Фаза 3)

`main.go` — `controller-runtime` manager без leader election (одноузловой пилот), без
metrics/health эндпоинтов (не нужны для локального прогона). Watch — по `*unstructured.Unstructured`
с `GroupVersionKind` `platform.devops.uslugi/v1alpha1, Kind=Module` (не типизированный клиент —
кодогенерации `deepcopy`/`client-gen` для этого MVP не делали, схема и так известна на этапе
Фазы 1, unstructured достаточно). `WithEventFilter(predicate.GenerationChangedPredicate{})` —
принципиально: `metadata.generation` не меняется при обновлении `status`, поэтому контроллер не
реагирует на свои же записи статуса (иначе — бесконечный цикл reconcile).

`internal/semaphore/client.go` — HTTP-клиент Semaphore API:

- Аутентификация — `Authorization: Bearer <token>` (персональный API-токен, не сессионная кука,
  не истекает при рестарте контроллера), `semaphoreui.com/docs/administration-guide/api/`.
- `StartTask(templateID, vars)` — `POST /api/project/{project_id}/tasks`, `vars` сериализуется в
  строковое поле `environment` тела запроса (переопределяет Environment, привязанный к Task
  Template) — так `spec.vars` модуля долетает до реального job'а.
- `Options.HostHeader`/`InsecureSkipTLSVerify` — пилотный стенд `platform/cicd` не имеет ни
  публичного DNS, ни валидного TLS: маршрутизация по `Host`-заголовку через встроенный k3s
  Traefik (тот же приём, что `curl -H "Host: ..."` в `platform/cicd/README.md`), сертификат
  самоподписанный. Оба — временное решение для одноузлового пилота.

`internal/controller/module_controller.go` — `Reconcile`: читает `spec.semaphoreTemplateID` и
`spec.vars`, вызывает `StartTask`, пишет `status.{conditions,lastAppliedRevision,lastSyncTime,
semaphoreJobID}` через `Status().Update`. `lastAppliedRevision` — `metadata.generation` в виде
строки (не git-revision, как задумано изначально в схеме, — контроллер не знает git-revision
inventory/vars напрямую, только Kubernetes-ресурс; сведение этих двух понятий — открытый вопрос,
см. ниже).

**Poll-loop до завершения job'а** (продолжение Фазы 3, до непрерывного drift-loop Фазы 4):
`StartTask` не дожидается результата — Semaphore выполняет job асинхронно. Вместо блокирующего
ожидания внутри одного вызова `Reconcile` использован стандартный для `controller-runtime`
приём — `ctrl.Result{RequeueAfter: pollInterval}` (5с): после старта job'а контроллер
возвращается, ставит `Ready=Unknown/SemaphoreTaskRunning`, и на следующий (перезапущенный по
таймеру) `Reconcile` для того же объекта — если `status.lastAppliedRevision` уже равен текущему
`metadata.generation` и `status.semaphoreJobID` уже проставлен — не стартует новый job, а
опрашивает существующий через `GetTask`, пока статус не станет терминальным
(`success`/`error`/`stopped`), и только тогда пишет финальный `Ready=True|False`. Сознательно
**без непрерывного drift-loop поверх уже завершённых job'ов** (Фаза 4) — после терминального
статуса `Reconcile` возвращает `ctrl.Result{}` без `RequeueAfter`, реагирует на новый
create/update spec только через `GenerationChangedPredicate`.

**Найденный и исправленный реальным прогоном баг: гонка кэша.** Изначально `Reconcile` читал
объект через обычный `r.Get()` (кэшированный клиент `controller-runtime`, из manager). На живом
стенде это привело к тому, что сразу за успешным стартом job'а иногда прилетал повторный
`Reconcile` (по таймеру `RequeueAfter`), который читал **устаревшую** версию объекта — кэш
(informer) ещё не успел увидеть только что записанный этим же контроллером `status`, поэтому
проверка «job для текущего generation уже запущен» ложно возвращала «нет» и стартовался **второй**
job для того же generation. Кэшированные чтения после собственной же записи `status` в одном и
том же reconcile-цикле — известная ловушка `controller-runtime`. Исправлено: `Reconcile` читает
объект через `mgr.GetAPIReader()` (`ModuleReconciler.APIReader`, отдельное поле, не встроенный
`client.Client`) — напрямую с API-сервера, минуя кэш. После исправления повторных job'ов на одном
generation при реальных прогонах больше не наблюдалось (см. ниже).

### Запуск (локально, не в кластере)

```bash
export KUBECONFIG=/путь/к/kubeconfig-стенда
export SEMAPHORE_URL=https://<ip-стенда>
export SEMAPHORE_HOST_HEADER=semaphore.cicd.platform
export SEMAPHORE_INSECURE_TLS=true
export SEMAPHORE_PROJECT_ID=1
export SEMAPHORE_TOKEN=<личный API-токен, создан вручную через POST /api/user/tokens>
go run .
```

Токен для пилота положен в K8s `Secret` `platform/semaphore-api-token` (создан вручную через
Semaphore API, не хранится в git) — на реальном запуске контроллер сейчас читает его из
переменной окружения, а не из Secret напрямую (чтение секретов кластера самим контроллером —
открытый вопрос, см. ниже).

### Проверено реальным прогоном

Собран через `golang:1.23` (Docker-контейнер — Go на control-хосте не установлен, а трогать
хостовую систему ради тулчейна одного пилотного компонента не требовалось): `go build`/`go vet`
чисто. Запущен локально (тем же `docker run --network host`, чтобы обойти системный HTTP-прокси
control-хоста для приватного IP стенда — `NO_PROXY` его не покрывает) против живого стенда
`platform/cicd` с реальным API-токеном Semaphore.

Полный цикл подтверждён несколькими прогонами (каждый раз — новый `generation` через
`kubectl patch spec.vars`, чтобы имитировать create/update): контроллер стартовал, вызывал ровно
один `POST /api/project/1/tasks`, писал `Ready=Unknown/SemaphoreTaskRunning`, через `pollInterval`
опрашивал тот же job (`GET /api/project/1/tasks/{id}`, статус `waiting` → `error`), и по
достижении терминального статуса писал финальный `Ready=False/SemaphoreTaskFailed` — **без
единого повторного/дублирующего job'а** на один и тот же generation, после исправления гонки
кэша выше. Проверено через `kubectl get module infra-panel-pilot -o jsonpath='{.status}'` на
каждом шаге; `semaphoreJobID` каждый раз совпадал с реальным ID задачи, независимо подтверждённым
`GET /api/project/1/tasks` (тот же `template_id`, тот же `environment` с переданными vars). Сама
задача в Semaphore каждый раз закономерно завершалась `status: "error"` — collection
`devops.uslugi` не установлена раннером (тот же открытый вопрос, что и в
`platform/cicd/README.md`, «Ручные шаги»: `requirements.yml` ссылается на несуществующий пока
`platform/devops-uslugi`) — это ожидаемо и не относится к зоне ответственности контроллера
(«вызвать Semaphore API, дождаться результата и записать статус», не «убедиться, что сам job
внутри Semaphore успешен» — то, что реально произошло в Semaphore, каждый раз корректно долетало
в `status.conditions` Module, что и требовалось доказать на этой фазе).

Побочно обнаружено (не баг, а ожидаемое поведение Фазы 2): ручной `kubectl patch spec.vars`
для тестирования — это дрейф от Git, и уже работающий с Фазы 2 `Kustomization`
`platform-modules` в течение своего reconcile-интервала (1 мин) откатывает такой ручной патч
обратно к версии из `platform/gitops` — что само по себе тоже генерирует новый `generation` и
успешно проходит тот же самый путь `Reconcile` без дублирования job'ов. Наглядная демонстрация
того, что Фазы 2 и 3 корректно сочетаются друг с другом.

**Фаза 3 закрыта**: контроллер вне кластера реально управляет Module-объектами в кластере через
Semaphore API.

## Не проработано (следующие шаги)

- Соответствие `role → semaphoreTemplateID` задаётся вручную в каждом CR — автоматический lookup
  (например, по конвенции именования Task Template) не спроектирован.
- Формат `status.conditions` использует только `type: Ready` (`True`/`False`/`Unknown` в
  зависимости от фазы job'а) — отдельный `type: Progressing` не заведён; при желании различать
  «ещё не решено» от «решено и работает» на уровне conditions потребуется отдельный тип.
- `lastAppliedRevision` — `metadata.generation` ресурса, не git-revision inventory/vars, как
  предполагала схема Фазы 1 (git-revision конкретного коммита `platform/gitops`, из которого Flux
  синхронизировал Module, контроллеру сейчас не виден — не передаётся Flux дальше в сам объект).
- Контроллер получает Semaphore-токен из переменной окружения процесса, не читает его из
  K8s `Secret` сам во время выполнения — при развёртывании самого контроллера в кластер (сейчас
  запускается только локально) это придётся исправить.
- Соответствие «модуль ↔ роль» 1:1 или объединение нескольких ролей одним модулем — не решено
  (ADR-0014, «Не проработано» — не переоткрывается здесь).
- Развёртывание самого контроллера в кластер (Deployment, RBAC на `modules.platform.devops.uslugi`
  и их `status` subresource) — не сделано, контроллер запускается только локально с внешним
  `KUBECONFIG`. Непрерывный drift-loop (Фаза 4) без этого не имеет смысла разворачивать в проде.
- `pollInterval` (5с) — захардкожен константой, не вынесен в конфигурацию. Тот же нерешённый
  вопрос «период requeue-цикла», что и ADR-0014, «Не проработано» (компромисс между быстрым
  обнаружением завершения job'а и нагрузкой на Semaphore API при множестве модулей одновременно),
  актуальный уже здесь, ещё до самого drift-loop Фазы 4.
