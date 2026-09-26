# ADR-0017: Стандартный набор аддонов для k3s-стенда platform/aicd

- **Статус:** Принято
- **Дата:** 2026-08-25
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

K3s-нода `platform/aicd` (ADR-0012, ADR-0014, ADR-0016) до этого ADR разворачивала ровно четыре
Helm-релиза (`openbao`, `gitea`, `semaphore`, `flux2`, все — `helm/envs/platform.yaml`), и все они
обязательные: понятия "опциональный компонент" в `site.yml`/`envs/platform.yaml` не было —
второй вызов `helmwave up` ставил безусловно всё, что перечислено в файле окружения.

Требуется стандартный набор дополнительных инструментов, которые ставятся на стенд по умолчанию,
но которые можно переопределить (добавить сверх набора или исключить конкретный) без правки
`site.yml`/`envs/platform.yaml`. Первый кандидат в этот набор — [Radar](https://github.com/skyhook-io/radar),
open-source Kubernetes UI (топология, ресурсы, Helm/GitOps-диагностика, чарт `skyhook/radar`).

## Решения

### 1. Механизм "дефолт + оверрайд" — group_vars + helmwave `--tags`, без нового кода

**Решение:** новый файл `platform/aicd/ansible/group_vars/platform_hosts.yml` (директория была
зарезервирована под это с самого начала — комментарий в `inventory.yml`, «Переменные роли — в
`../ansible/group_vars/*.yml`»):

```yaml
platform_aicd_core_releases: [openbao, gitea, semaphore, flux2]
platform_aicd_default_addons: [radar]
platform_aicd_extra_addons: []
platform_aicd_disabled_addons: []
platform_aicd_enabled_addons: >-
  {{ (platform_aicd_default_addons + platform_aicd_extra_addons)
     | unique | difference(platform_aicd_disabled_addons) }}
```

Второй `helmwave up` в `site.yml` получил
`--tags "{{ (platform_aicd_core_releases + platform_aicd_enabled_addons) | join(',') }}"`.

**Обоснование:** helmwave уже автоматически тегирует каждый релиз его собственным именем
(`helm/helmwave.yml.tpl:76-78`), поэтому выборочная установка не требует ничего дописывать в
`envs/platform.yaml` — достаточно передать список нужных имён релизов через `--tags`. Это тот же
принцип, что уже применён в `roles/monitoring_server/defaults/main.yml`
(`monitoring_server_helmwave_tags`/`monitoring_server_helmwave_other_tags`,
`docs/adr/0007-monitoring-server-role.md` §6) — не изобретается параллельный механизм.

Переопределение — обычные ansible-переменные (`-e platform_aicd_disabled_addons=[radar]` или
правка `group_vars/platform_hosts.yml`), без необходимости трогать `helm/envs/platform.yaml`.

**Проверено реальным прогоном — важная асимметрия семантики `disabled_addons`.** `helmwave up
--tags` строит план ТОЛЬКО из релизов, прошедших фильтр по тегам — уже установленный, но
выпавший из фильтра релиз в план не попадает вообще, и helmwave его никак не трогает (не
обновляет, но и не удаляет). Реальный прогон с `-e platform_aicd_disabled_addons=[radar]` на уже
развёрнутом Radar подтвердил: `Releases Success 4 / 4` (без radar), под/Ingress/Secret Radar при
этом остались работать без изменений — helm-релиз просто перестал быть управляемым этим
прогоном. Значит `disabled_addons`/удаление из `default_addons`:
- **до** первой установки аддона — предотвращает его установку (работает как ожидается);
- **после** установки — не удаляет уже развёрнутый релиз, а лишь замораживает его (перестают
  применяться новые версии чарта/values). Для реального удаления нужен отдельный ручной шаг —
  `helmwave down --tags radar` или `helm uninstall radar -n platform` — это ansible-код
  сознательно не делает сам (удаление стороннего workload — не то же самое, что невключение
  нового, более рискованное действие для автоматизации без явного подтверждения оператора).

### 2. Radar — первый аддон, RBAC/auth-профиль

**Решение:** релиз `radar` (репозиторий `https://skyhook-io.github.io/helm-charts`, чарт
`skyhook/radar`, версия `1.11.0`) добавлен в `helm/envs/platform.yaml`. RBAC — дефолты чарта
(`rbac.secrets: false`, `rbac.helm: false`, `rbac.podExec: false`, `rbac.portForward: false`,
read-only `ClusterRole` на остальные ресурсы) оставлены как есть, без ослабления — Radar не
получает доступ к Kubernetes Secrets и не может изменять ресурсы через Helm, несмотря на то что
делит кластер с OpenBao, хранящим секреты всей платформы.

Аутентификация — `auth.mode: none` (дефолт чарта, встроенных `proxy`/`oidc` не используем), вход
защищён на уровне Traefik: `Middleware radar-basic-auth` (`traefik.io/v1alpha1`) + `Secret
radar-basic-auth` с htpasswd-содержимым, тот же приём, что уже применён для дашбордов
`infra_panel`/`reverse_proxy_traefik` (`community.general.htpasswd` на control-хосте). Пароль не
хардкод — читается/генерируется в уже поднятом OpenBao (`secret/radar`, тот же идемпотентный
check-404-then-generate шаблон, что `secret/gitea`/`secret/semaphore`, ADR-0016 §3). TLS —
`Secret radar-tls`, выпущен из того же внутреннего PKI CA, что `gitea-tls`/`semaphore-tls`
(переиспользован существующий цикл `tasks/issue-tls-cert.yml`, просто добавлен третий элемент
`loop`).

**Обоснование:** Radar размещается на кластере, критичном для платформы (там же OpenBao), поэтому
намеренно НЕ ослабляются дефолтные RBAC-ограничения чарта ради удобства (никакого
`rbac.secrets: true`/`rbac.helm: true`), и вход закрыт тем же способом, что уже проверен на других
внутренних дашбордах коллекции — не вводится новый паттерн авторизации специально под один сервис.

### 3. infra_panel — второй аддон, Ingress для OpenBao (2026-08-25)

**Решение:** релиз `infra-panel` (дефис — не `infra_panel`, как называется одноимённая роль/
ADR-0008: подчёркивание сломало бы RFC-1123-имена k8s-объектов, которые `universal-chart`
генерирует как `<release>-<key>`), тот же приём `localrepo/universal-chart`, что уже применён для
Semaphore — homer (`b4bz/homer:v26.4.2`) с дашбордом-ссылками на все веб-UI платформы (Gitea,
Semaphore, Radar, OpenBao). Basic-auth — тот же приём, что уже применён для Radar (`Middleware
infra-panel-basic-auth` + `Secret infra-panel-basic-auth`, пароль — idempotent-сгенерированный в
`secret/infra-panel`), а не хардкод в values, как в иллюстративном примере
`helm/values/k3s-monitoring/namespaces/monitoring/homer/values.yaml`. TLS — `Secret
infra-panel-tls`, тот же цикл `tasks/issue-tls-cert.yml`, что у остальных сервисов.

**Ingress для OpenBao** — до этого решения UI/API OpenBao был доступен только через `NodePort
:30820` (для control-хоста, не для конечного пользователя через домен). Чарт `openbao/openbao` не
отдаёт plain HTTP вообще (`global.tlsDisable: false`), backend слушает только TLS
самоподписанным bootstrap-сертификатом (`openbao-server-tls`) — Service автоматически проставляет
`appProtocol: HTTPS`, поэтому Traefik сам решает идти в backend по HTTPS, но не доверяет
самоподписанному сертификату без явного указания. Решение — `ServersTransport
openbao-insecure-backend` (`traefik.io/v1alpha1`, `insecureSkipVerify: true`), заводится
ansible'ом (тем же приёмом, что `Middleware radar-basic-auth`) и подключается **аннотацией на
Service** (`server.service.annotations`, не на Ingress — так документировано для
`service.serverstransport` в Traefik). Внешний TLS-сертификат Ingress'а — отдельный секрет
`openbao-ingress-tls` из того же внутреннего PKI CA, что у остальных сервисов (не тот же
самоподписанный `openbao-server-tls`, который остаётся исключительно внутренним bootstrap-
сертификатом самого listener'а).

Basic-auth перед OpenBao **не заводится** — OpenBao аутентифицирует сам себя (root token/policy),
тот же принцип, что уже применён к Gitea/Semaphore (задокументировано их же values-комментарием).

**Обоснование:** тот же принцип, что уже закреплён в §2 для Radar — не изобретается новый
паттерн авторизации/TLS специально под один сервис, переиспользуются уже проверенные примитивы
коллекции (Middleware+htpasswd, PKI CA, теперь ещё и `ServersTransport` — тот же CRD, что уже
поддержан `universal-chart` и упомянут в `helm/values/k3s-monitoring/.../vm/values.yaml` в другом
контексте).

**Проверено реальным прогоном** на обоих окружениях: под `infra-panel-infra-panel` `Running`,
`401` без basic-auth-credentials/`200` с ними, `/assets/config.yml` содержит все 4 ссылки;
`openbao.<domain>/ui/` — `200`, TLS issuer у обоих — внутренний CA (не самоподписанный
`openbao-server-tls`). Единственная реальная находка: `helm/helmwave.yml.tpl` требует базовый
`values/releases_common/<release>.yaml` для **каждого** релиза (`strict: true`, в отличие от
per-`K8S_CLUSTER`-оверрайда) — забытый файл для нового релиза уронил второй `helmwave up` с
`values file doesn't exist`; исправлено добавлением (пустого, `---`) `helm/values/releases_common/
infra-panel.yaml`, по образцу уже существующих `radar.yaml`/`semaphore.yaml`/`gitea.yaml`.

### 4. Мониторинг — третий аддон, урезанный k3s-путь, БЕЗ `roles/monitoring_server` (2026-08-28)

**Контекст:** оба окружения работали несколько недель без метрик/дашбордов собственного кластера.
Роль `roles/monitoring_server` уже поддерживает k3s-оркестратор (`docs/adr/0007-monitoring-server-role.md`
§6/§11, реально проверен molecule-прогоном), поэтому первым кандидатом было просто подключить её.

**Решение: НЕ подключать `roles/monitoring_server`.** Реверс-инжиниринг
`roles/monitoring_server/tasks/monitoring-server.k3s.yml` показал, что задача рендера
`k3s/local-path-provisioner.yml.j2` в `/var/lib/rancher/k3s/server/manifests/custom-local-storage.yaml`
выполняется **безусловно** (без `when`) — а это не отдельный StorageClass, а переопределение тем же
именем штатного `local-path` (Deployment/ConfigMap/StorageClass в `kube-system`, другая версия
образа провижининга). Оба `site.yml` уже содержат явное решение "штатный k3s local-path provisioner
НЕ переопределяется" (Gitea/OpenBao держат там PVC) — подключение роли молча откатило бы это
решение. Роль также поднимает свой отдельный `Helmwave up` (своя логика `--tags`), параллельный уже
существующему в `site.yml` двухфазному вызову.

Вместо роли — `vm` (`vm/victoria-metrics-k8s-stack`) и `grafana-operator`
(`oci://ghcr.io/grafana/helm-charts/grafana-operator`) заведены как ещё два обычных Helm-релиза в
том же `envs/platform.yaml`/`envs/platform-devops-labs-ru.yaml`, тегируются своим именем (как
`radar`/`infra-panel`) — используется штатный уже проверенный механизм §1, без второго
Helmwave-вызова и без риска для storage class.

**Урезанный состав (без Loki/`grafana-alloy`/VMAlert).** Единственная реально проверенная
k3s-конфигурация (`extensions/molecule/monitoring_server_k3s/`) требовала 6144Mi RAM/4vCPU для
полного стека — а реальный замер (2026-08-28, `metrics-server`) показал обе ноды платформы уже на
43% памяти БЕЗ единого мониторингового пода (`cicd` 3.9Gi allocatable, `aicd-labs` 5.8Gi). Полный
референсный стек рассчитан на приём метрик с **внешних** agent-хостов (`grafana-alloy`, файловый
`file_sd` VMAgent) — для самомониторинга платформенного кластера не нужен. V1: `vm`
(VictoriaMetrics Operator + `VMSingle`/`VMAgent`, только штатные in-cluster сорсы чарта —
kubelet/cAdvisor/kube-state-metrics/node-exporter) + `grafana-operator` (`Grafana`/`GrafanaFolder`
CR). Без VMAlert/Alertmanager — следующая итерация, после того как будет видно реальное потребление
урезанного стека. `vmsingle` storage — 5Gi (не референсные 20Gi, свободного диска мало),
`storageClassName` не указан — используется штатный `local-path`. RAM обеих VM поднята заранее
(`cicd` 4096→6144, `aicd-labs` 6000→8192 MiB) — живым `tofu apply` с graceful shutdown гостя,
подтверждено `free -h` после старта.

**Grafana — native OIDC через Authelia, не forwardAuth.** Тот же принцип, что уже выбран для
Gitea/Semaphore (§раздел ADR-0013): forwardAuth-Middleware (как у Radar/infra-panel) — только для
инструментов без собственной аутентификации. Grafana умеет OIDC сама (`auth.generic_oauth`) — новый
клиент `grafana` в Authelia (`consent_mode: pre-configured`, `1 year`, тот же принцип, что
Gitea/Semaphore), `client_secret` — новое поле `grafana_client_secret`(`_hash`) в уже существующем
`secret/authelia`. Поскольку оба `secret/authelia` уже давно забутстрапены (окружения работают не
первую неделю), добавление нового поля потребовало отдельного ретрофит-пути (проверка "поле
отсутствует", а не "весь secret отсутствует") — тот же приём, которым уже добавлялись хэши
`gitea_client_secret_hash`/`semaphore_client_secret_hash`, только теперь для одного дополнительного
поля на уже существующем секрете. `token_endpoint_auth_method: client_secret_basic`
(задокументированный дефолт Grafana) — по аналогии с уже найденным багом Semaphore
(`client_secret_post`, ADR-0013 §7) стоит перепроверить реальным логином.

**GPU-метрики llm1 (только `platform/aicd-devops-labs-ru`).** DCGM exporter — DaemonSet по образцу
`nvidia-device-plugin` (ADR-0015): `nodeSelector`/`toleration` на `llm1`, `runtimeClassName: nvidia`.
Сознательно **без** `resources.limits.nvidia.com/gpu` — llm1 отдаёт `Allocatable nvidia.com/gpu: 1`
(единственная карта), и запрос ресурса самим экспортёром мониторинга держал бы его недоступным для
любого реального AI/agent workload'а (ради которого GPU вообще заведён, ADR-0015). Вместо этого —
`NVIDIA_VISIBLE_DEVICES=all`/`NVIDIA_DRIVER_CAPABILITIES=all` в обход device-plugin allocation
(документированный NVIDIA-приём для мониторинга/сайдкаров). Образ — в отличие от
`k8s-device-plugin` (пришлось собирать из исходников, ADR-0015 §10), `nvidia/dcgm-exporter`
публикуется на Docker Hub напрямую и актуально — просто ретег/push в тот же Gitea-реестр
(`gitea.aicd.devops-labs.ru/nvcr.io/...`), без сборки. Метрики забираются `VMPodScrape`
(`helm/values/platform-devops-labs-ru/namespaces/monitoring/vm/extra-objects.yaml`) —
единственное расхождение values между окружениями.

**`platform/aicd-devops-labs-ru` — живьём развёрнуто и проверено** (2026-09-11, ROADMAP.md п.62):
`dcgm-exporter` DaemonSet `Running` на `llm1`, `VMPodScrape` — таргет `health: up` в vmagent,
реальные GPU-метрики (`DCGM_FI_DEV_GPU_UTIL` и др., с метками `modelName`/`UUID`) видны в
VictoriaMetrics. `platform/aicd` — статус без изменений: `ansible-playbook site.yml` там упирается
в блокировку `release-assets.githubusercontent.com` с этой конкретной сети (`xanmanning.k3s`
безусловно перепроверяет checksum k3s на каждом прогоне — тот же класс проблемы, что уже
документирован для vagrantcloud/hashicorp archivist/nvcr.io в истории этого репозитория); там GPU-
ноды и вовсе нет (только на `aicd-devops-labs-ru`, ADR-0015 §10), так что этот раздел там и не
применим. Код провалидирован `ansible-lint --profile production` + `--syntax-check`.

### 5. Дашборды экспортёров `monitoring_agent` — `GrafanaDashboard` из `ADDONS/` (2026-09-03)

**Контекст:** после установки `ipa_exporter` на хост `freeipa` (вне кластера) и его подключения
через `VMScrapeConfig`/`staticConfigs` метрики реально собирались (`ipa_up`/`ipa_users` видны в
VictoriaMetrics), но в Grafana дашборда FreeIPA не было — жалоба оператора. То есть скрейп и
визуализация разъехались: половина работы (сбор) была сделана, вторая (дашборд) — нет.

**Причина — в k3s-пути этого ADR не было вообще никакого механизма для сторонних дашбордов.**
Разбор показал две несвязанные половины, ни одна из которых не покрывает `ADDONS/`:

- `defaultDashboards.dashboards` чарта `vm` — закрытый список **его собственных** bundled-дашбордов
  (`victoriametrics-*`, `node-exporter-full`); добавить туда произвольный JSON нельзя, это не
  «список дашбордов для установки», а «какие из своих включить».
- Механизм роли `monitoring_server` (`monitoring_server_grafana_dashboards_group_install`,
  включая уже готовую группу `..._defaults_freeipa`) раскладывает `ADDONS/grafana_dashboards/*.json`
  через файловый provisioning Grafana (`grafana/provisioning/dashboards`) — но роль в платформенных
  окружениях сознательно не используется вовсе (§4), а её приём привязан к docker-пути с
  bind-mount'ом конфигов, к Grafana под управлением `grafana-operator` он неприменим.

**Решение: `GrafanaDashboard` CR (та же CRD, что уже использует чарт `vm`), создаваемый
ansible-задачей `site.yml` сразу после `Helmwave up`.** Модель дашборда читается
`lookup('file', ...)` прямо из `ADDONS/grafana_dashboards/` — единственного места в репозитории, где
эти JSON лежат; в `group_vars` попадает только имя файла
(`platform_*_grafana_addons_dashboards`), а не копия JSON. Почему не в helm-values `extraObjects`
релиза `grafana-operator`, где уже лежит `GrafanaFolder`: тот файл целиком — gomplate-шаблон, и
встраивание туда 48 KB чужого JSON — и дублирование источника, и лишний риск экранирования.
Почему после `Helmwave up`, а не раньше: и CRD `grafanadashboards.grafana.integreatly.org`, и
`GrafanaFolder` `addons`, на который ссылается `folderRef`, создаёт именно релиз `grafana-operator`.

Отдельная деталь — `spec.datasources`. Экспортированный из Grafana JSON ссылается на датасорс
плейсхолдером `${DS_VICTORIAMETRICS}` (блок `__inputs`), оператор подставляет вместо него значение
`datasourceName`. Имя `VictoriaMetrics` — то, что заводит чарт `vm`
(`defaultDatasources.victoriametrics`, `helm/values/*/namespaces/monitoring/vm/grafana.yaml`).

**Проверено живым прогоном (`platform/aicd-devops-labs-ru`, 2026-09-03):** CR применён
(`DashboardSynchronized: "Dashboard was successfully applied to 1 instances"`), в Grafana дашборд
лежит в папке `ADDONS`, плейсхолдеров `${DS_...}` в сохранённой модели не осталось, и в браузере
панели отдают реальные данные (`Status: UP`, `Active Users: 7`, `User Groups: 4`,
`Host Groups: 1`, `Scrape 238 ms` — сходится с `curl :9189/metrics` на самом хосте).
Два пустых блока — ожидаемое поведение, не дефект: `ipa_bind` (Anonymous bind) и
`ipa_replication_status` экспортёр сознательно не публикует, если bind-аккаунт не может читать
`cn=config` (обычный `svc-monitoring`, а не Directory Manager) и если реплик нет — см.
`ADDONS/exporters/freeipa_exporter/code/freeipaserver.py`, `_anon_bind`/`_replication_agreements`.

В `platform/aicd` заведён тот же механизм, но список дашбордов пуст: `ipa_exporter` там ещё не
включён (ВМ окружения выключены, живой прогон отложен) — дашборд показывал бы `No data`. Тот же
приём, что закомментированный таргет `:9189` в
`helm/values/platform/namespaces/monitoring/vm/extra-objects.yaml`: обе половины (сбор и
визуализация) включаются вместе, по факту живого прогона.

## Второе окружение (2026-08-25)

Механизм из §1 (и стандартный набор аддонов из §2/§3) переиспользован без изменений во втором,
независимом окружении платформы — `platform/aicd-devops-labs-ru` (Proxmox вместо libvirt, домен
`aicd.devops-labs.ru` вместо `aicd.platform`, свой var-префикс
`platform_aicd_devops_labs_ru_*`, свой `K8S_CLUSTER=platform-devops-labs-ru` у helmwave — см.
`platform/aicd-devops-labs-ru/README.md`). Radar и infra-panel включены в стандартный набор и там
же, без расхождений между стендами — решения этого ADR не привязаны к конкретному стенду. Раздел 4
(мониторинг) добавлен позже и тоже без расхождений, кроме GPU-метрик (только там, где есть GPU).

## Не проработано

- RBAC-профиль Radar не тюнится тоньше дефолтов чарта (например, `crdGroups` оставлены все
  включены по умолчанию — безвредно для CRD, которых нет в кластере, но не пересмотрено под
  конкретный состав `platform/aicd`).
- Нет отдельного ADR на каждый будущий аддон — при росте `platform_aicd_default_addons` за
  пределы одного-двух пунктов имеет смысл пересмотреть, стоит ли документировать каждый отдельно
  или продолжать расширять этот ADR.
- Basic-auth (общий пароль admin) — та же модель, что уже принята для
  `infra_panel`/`reverse_proxy_traefik`; per-user доступ (`auth.mode: oidc` чарта Radar, например
  поверх `freeipa`, ADR-0011) не рассматривался.

## Ссылки

- `docs/adr/0016-openbao-secrets-pki.md` — источник секрета (`secret/radar`) и PKI CA
  (`radar-tls`), которыми пользуется этот ADR.
- `docs/adr/0007-monitoring-server-role.md` §6 — прецедент `monitoring_server_helmwave_tags`,
  повторённый здесь как `platform_aicd_enabled_addons`.
- `docs/adr/0008-infra-panel-role.md` — прецедент basic-auth через Traefik Middleware +
  `community.general.htpasswd` для внутреннего дашборда.
- `docs/adr/0014-platform-controller-architecture.md` — платформенный контроллер, не затронут
  этим ADR (Radar — операторский инструмент, не Module).
