# platform/aicd — Фаза 0 ADR-0014 (K3s + Gitea + Semaphore UI)

**Переименовано из `platform/cicd` (2026-08-25).** Директория, префикс ansible-переменных
(`platform_aicd_*`) и прикладной домен (`cicd.platform` → `aicd.platform`, Ingress-хосты, PKI CN)
переименованы; внутренние terraform-идентификаторы живой VM (`local.vms.cicd`, storage pool/сеть
`platform-cicd`) сознательно оставлены как есть — см. заметку в `terraform/versions.tf`
(переименование форсирует пересоздание pool/сети/диска/домена VM целиком, проверено эмпирически).
Операторам: локальные `/etc/hosts`-записи/закладки на `gitea.cicd.platform`/
`semaphore.cicd.platform`/`radar.cicd.platform` нужно вручную поправить на `*.aicd.platform`.

Персистентная платформенная инфраструктура (`docs/adr/0012-cicd-platform-architecture.md` §6),
не демо-стенд — в отличие от `demo/*` (ADR-0006, эфемерные одноразовые VM, демонстрирующие роли
коллекции клиентам), этот стенд обслуживает саму разработку коллекции (CI/CD) и не пересоздаётся
регулярно. Поэтому не переиспользует `demo/stand.sh` (жёстко резолвит `demo/$case/...`) — запуск
вручную, теми же двумя командами, что использует сам `stand.sh` внутри.

Архитектура и обоснование решений — `docs/adr/0014-platform-controller-architecture.md`,
`docs/adr/0012-cicd-platform-architecture.md` §4/§5, план по фазам — `ROADMAP.md`,
«Предлагаемая последовательность работ», пункт 7, Фаза 0.

Одна K3s-нода (`xanmanning.k3s`, тот же пин версии, что `roles/monitoring_server/meta/main.yml`)
хостит Gitea (источник Module-манифестов/inventory) и Semaphore UI (исполнитель Task Template)
как Helm-релизы через Helmwave (`helm/envs/platform.yaml`) — тем же способом, каким
`monitoring_server` уже разворачивает VictoriaMetrics/Grafana/Loki
(`docs/adr/0007-monitoring-server-role.md` §6).

## Запуск

```bash
cd terraform
tofu init -input=false
tofu apply -input=false -auto-approve

# Дождаться SSH (single VM — обычно секунды после apply)
ssh -o StrictHostKeyChecking=no ansible@$(tofu output -json | jq -r '.vm_ips.value.cicd') true

cd ../ansible
poetry run ansible-playbook -i inventory.yml site.yml
```

Требует на control-хосте (не на самой VM): `helm`, `helmwave`, python-пакет `kubernetes`
(dev-зависимость `pyproject.toml`) — те же требования, что `extensions/molecule/monitoring_server_k3s/`.

## Ручные шаги после первого запуска

Выполнены вживую (через REST API Gitea/Semaphore, `curl` с control-хоста через `ssh` на VM —
прямой сетевой доступ с control-хоста в сеть стенда недоступен):

1. **Gitea** — организация `platform`, приватный репозиторий `platform/gitops` (Module-манифесты
   + Ansible-inventory, `auto_init`, ветка `main`). Учётные данные администратора —
   `helm/values/platform/namespaces/platform/gitea/values.yaml` (`gitea.admin`) — **плейсхолдер,
   сменить перед реальным использованием**.
2. **Semaphore** — проект `platform` (id=1), Git-интеграция на `platform/gitops` (repository id=1,
   ssh-key типа `login_password` — репозиторий приватный, ключ типа `none` не давал креденшлов
   для клонирования, см. `platform-controller/README.md`, «Фаза 4»/«Фаза 5»), inventory
   `infra_panel` (id=1, тип `file`, указывает на `inventory/infra_panel.ini` с реальным целевым
   хостом — `platform/aicd/terraform/infra-panel-target.tf`, отдельная VM, см. ниже),
   environment `default` (id=1), Task Template `infra_panel (pilot, ADR-0014 Фаза 0)` (id=1,
   playbook `playbooks/infra_panel.yml`). Учётные данные администратора —
   `helm/values/platform/namespaces/platform/semaphore/values.yaml`
   (`SEMAPHORE_ADMIN`/`SEMAPHORE_ADMIN_PASSWORD`) — тоже плейсхолдер.

   В `platform/gitops` дополнительно закоммичены `playbooks/infra_panel.yml` (тонкая обёртка —
   `hosts: infra_panel`, `become: true`, `roles: [devops.uslugi.infra_panel]`) и
   `requirements.yml`, указывающий на реальный источник коллекции `devops.uslugi` — приватное
   зеркало `platform/devops-uslugi` в этом же Gitea (запушено пользователем вручную из корня
   коллекции — агенту это действие недоступно, инструментарий безопасности расценивает
   `git push` всего репозитория/точечное копирование через API как передачу содержимого
   доверенного репозитория и блокирует это независимо от согласия пользователя). Креды для
   клонирования зеркала — не в git (коммитить пароль в `requirements.yml` тоже заблокировано), а
   в Semaphore Environment (`env`, не `json`):
   `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0=http.extraHeader`/`GIT_CONFIG_VALUE_0=Authorization: Basic
   ...` — секрет живёт только в БД Semaphore.

   **Task Template реально выполняется полностью успешно** (`status: success`) — Docker Engine
   реально устанавливается на целевой VM, контейнер `infra-panel` (homer) реально поднимается и
   `healthy`. Подробности сквозного прогона (git → Flux → Module → контроллер → Semaphore →
   реальная инфраструктура) — `platform-controller/README.md`, «Фаза 5».

3. **Реальный целевой хост** (`platform/aicd/terraform/infra-panel-target.tf`) — отдельная VM
   (1 vCPU/1GB/15GB, Debian 12), сознательно НЕ добавлена в общий `local.vms` (`vms.tf`) —
   реальным `tofu plan` обнаружено, что любое изменение в shared-ресурсах (сеть, cloudinit-
   шаблон) заставляет Terraform пересоздать их для уже работающей `cicd` — риск для живого
   Gitea/Semaphore/Flux. Полностью отдельные ресурсы в `infra-panel-target.tf`. IP — обычный
   DHCP (статический IP через cloud-init `network_config` не заработал — сеть гостя не
   поднялась вообще, недиагностируемо без консоли гостя в этом окружении). Выделенный SSH-ключ
   (`tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target.pub`, приватная часть —
   Semaphore Key, не в git).

## Проверено реальным прогоном

Полный цикл (`tofu apply` → `ansible-playbook site.yml`) выполнен и проверен целиком: оба пода
(`gitea`, `semaphore-semaphore`) `Running`, 0 рестартов, оба PVC `Bound`, оба сервиса отвечают
`200 OK` по HTTP(S) через встроенный в k3s Traefik (`curl -H "Host: gitea.aicd.platform" ...`,
`curl -H "Host: semaphore.aicd.platform" ...`). `ansible-playbook` идемпотентен на повторном
прогоне (второй запуск — `changed=2`, без ошибок).

Две реальные находки первого прогона, обе исправлены в `site.yml`/`.gitignore`:

1. **Race condition: Traefik CRD ещё не зарегистрирован в момент первого `helmwave up`.** k3s
   разворачивает встроенный Traefik (и его CRD `ingressroutes.traefik.io`) асинхронно через
   собственный HelmChart-контроллер — сразу после того, как `xanmanning.k3s` отчитывается об
   успехе, CRD может ещё не существовать. Chart Semaphore (`nxs-universal-chart`) рендерит
   `IngressRoute` только если `$.Capabilities.APIVersions.Has "traefik.io/v1alpha1"` — без
   ожидания релиз применяется молча БЕЗ `IngressRoute` (Helm просто пропускает шаблон, без
   ошибки) — обнаруживается не сразу, а когда сервис оказывается недоступен снаружи. Исправлено:
   `site.yml` ждёт регистрации CRD (`kubernetes.core.k8s_info` + `until`/`retries`) перед
   `helmwave up`.
2. **`helm/helmwave.yml` — общий файл, коллизия между кластерами.** Он же используется как
   закоммиченный референсный рендер для `K8S_CLUSTER=k3s-monitoring`
   (`roles/monitoring_server`) — `helmwave up --yml` безусловно перезаписывает этот файл под
   ТЕКУЩИЙ `K8S_CLUSTER`. Ручной запуск с `K8S_CLUSTER=platform` во время отладки находки №1
   перезаписал чужой референс, пришлось откатывать через `git checkout`. Исправлено: `site.yml`
   рендерит в `--file helmwave.platform.yml` (гитигнорится) вместо дефолтного имени.

Не проверено на этом прогоне (не входило в scope Фазы 0, следующие шаги):

- ~~Секреты (admin-пароли Gitea/Semaphore, cookie/access-key Semaphore) — плейсхолдеры прямо в
  values-файлах~~ — **сделано**, см. «OpenBao — секреты и внутренний PKI CA» ниже.
- ~~TLS — самоподписанный (дефолтный сертификат встроенного Traefik)~~ — **сделано** (внутренний
  PKI CA), см. ниже.
- Официального Helm-чарта Semaphore UI не найдено — развёрнут как голый
  Deployment/PVC/Service/IngressRoute через `nxs-universal-chart` (тот же приём, что уже
  применён для `homer`, `helm/envs/k3s-monitoring.yaml`) — работает, но не «из коробки»
  сопровождается апстримом Semaphore.

## OpenBao — секреты и внутренний PKI CA (docs/adr/0016-openbao-secrets-pki.md)

Реализовано и проверено реальным прогоном на живом стенде: секреты Gitea/Semaphore (admin-пароли,
cookie/access-key Semaphore) читаются gomplate-датасорсом `vault://` из OpenBao вместо плейнтекста
в git, TLS-сертификаты `gitea.aicd.platform`/`semaphore.aicd.platform` выпускаются внутренним PKI
CA OpenBao (`CN=aicd.platform`) вместо дефолтного `TRAEFIK DEFAULT CERT`. Реальная проверка:
`openssl s_client` показывает `issuer=CN=aicd.platform`, логин в Gitea/Semaphore реальным
сгенерированным паролем (прочитанным из OpenBao) — `200`/`204`. Повторный прогон
`ansible-playbook` полностью идемпотентен — все init/unseal/secrets/PKI/TLS-задачи `skipping`,
`changed=3` (только always-changed `lineinfile`/`helmwave up`, без пере-генерации секретов).

Семь реальных находок, все исправлены в `site.yml`/`tasks/issue-tls-cert.yml`/values:

1. **Control-хост не имеет маршрута к ClusterIP k3s-сервисов.** Тот же found, что уже
   зафиксирован для kube-apiserver (подмена `127.0.0.1` на реальный IP) — OpenBao опубликован
   через `NodePort` (`server.service.nodePort: 30820`), весь HTTP API адресуется через
   `<реальный IP ноды>:30820`.
2. **`.json.keys[0]` коллизирует с Python `dict.keys()`.** Jinja резолвит `.keys` как атрибут
   (builtin-метод) раньше, чем как JSON-ключ `"keys"` — `sys/init` ответ Vault/OpenBao содержит
   поле именно с таким именем, отсюда `"builtin_function_or_method object has no element 0"`.
   Итог первого прогона — **OpenBao успешно инициализировался, но root_token/unseal-ключ не
   сохранились никуда** (задача упала до записи Secret) — постоянно запечатанный инстанс без
   восстановимых ключей, пришлось руками удалить pod+PVC `openbao-0` и переинициализировать с
   нуля (никаких реальных секретов внутри ещё не было — цена такой находки нулевая). Исправлено
   явной bracket-нотацией `.json['keys'][0]`.
3. **`register` на то же имя переменной внутри пропущенного `when`-блока затирает валидное
   значение.** Задача «Перечитать Secret» внутри `when`-block (выполняется только при первой
   инициализации) регистрировала результат в ТУ ЖЕ переменную, что и предшествующая проверка
   существования Secret — при пропуске блока (Secret уже есть) Ansible всё равно пишет в
   `register` skip-результат (`{"skipped": true}`, без `.resources`), затирая валидный результат
   более ранней проверки. Отсюда `"object of type 'dict' has no attribute 'resources'"` на
   следующей задаче. Исправлено: отдельное имя переменной + промежуточный `set_fact` с условием
   `... is defined and ....resources is defined`.
4. **YAML folded block scalar (`>-`) схлопывает перенос строки между Jinja-подстановками в
   пробел.** `stringData.tls.crt`, собранный из `{{ certificate }}` и `{{ ca_chain }}` на двух
   строках `>-`-блока, давал `"-----END CERTIFICATE----- -----BEGIN CERTIFICATE-----"` на одной
   строке — Traefik: `"unable to generate TLS certificate: tls: failed to find any PEM data"`.
   Исправлено explicit `"...\n..."` в двухкавычечной строке (YAML разворачивает escape в реальный
   перенос строки на этапе парсинга, до Jinja-рендера).
5. **Gitea `strategy: RollingUpdate` + локальный leveldb (`queue.TYPE: level`) на общем PVC —
   гарантированный deadlock при любом будущем `helm upgrade`.** Новый под стартует ДО остановки
   старого (дефолт чарта, `maxUnavailable: 0`), оба делят один `PersistentVolumeClaim` и один
   on-disk leveldb-файл очереди — новый под падает в `CrashLoopBackOff`
   (`"unable to lock level db ...: resource temporarily unavailable"`), а старый не завершается,
   пока новый не станет `Ready` — тупик. Исправлено `strategy.type: Recreate` в
   `helm/values/.../gitea/values.yaml`. Уже застрявший rollout (с прошлого, ещё не
   Recreate-прогона) пришлось разруливать вручную: временный debug-под с той же PVC для удаления
   зависшего (stale) `LOCK`-файла leveldb.
6. **Semaphore не синхронизирует пароль администратора для уже существующего пользователя.** В
   отличие от Gitea (`"Running update to sync password!"` на каждом старте), bootstrap-скрипт
   образа `semaphoreui/semaphore` при старте видит существующего пользователя и просто отвечает
   `"Welcome back, Administrator!"`, НЕ применяя новое значение `SEMAPHORE_ADMIN_PASSWORD` — смена
   пароля в values не даёт эффекта, пока БД не пересоздана с нуля. Разрешено — PVC `semaphore-data`
   пересоздан (`kubectl delete pvc` + повторный `helmwave up`), тестовые Project/Task стенда
   потеряны (тот же принцип, что уже был принят при миграции bolt→sqlite, см. выше) — приемлемо
   для пилотного стенда, следующий раз пароль будет реально «прижившимся» через `vault://` без
   дополнительных действий, если он не меняется.
7. **Секрет `gitops-git-auth` (flux-system) не был синхронизирован с новым admin_password и
   молча сломал GitOps на часы.** `platform/aicd/flux/git-credentials-secret.yaml` был заведён
   вручную ДО OpenBao с плейсхолдером `"PleAse_Change_ME!"` (`kubectl apply -f`, см.
   `platform/aicd/flux/README.md`) — при переезде `gitea.admin.password` на OpenBao (находка №5
   выше) этот отдельный Secret никто не тронул. `GitRepository gitops` ушёл в `READY: False
   (authentication required)` и оставался в этом состоянии часами незамеченным — verify-шаги этой
   фазы проверяли логин в Gitea/Semaphore напрямую, но не статус `GitRepository`. Исправлено:
   файл `git-credentials-secret.yaml` удалён, `site.yml` теперь безусловно синхронизирует Secret
   `gitops-git-auth` с текущим `admin_password` из `secret/gitea` на каждом прогоне (задачи «Flux:
   прочитать текущий admin_password secret/gitea»/«Flux: синхронизировать gitops-git-auth», после
   второго `helmwave up`, когда namespace `flux-system` уже существует). **Урок на будущее**: при
   миграции секрета, расшаренного на несколько Secret-объектов/потребителей, проверять статус
   ВСЕХ потребителей (в т.ч. `kubectl get gitrepository`), а не только тех, что были целью самой
   миграции.

### Хвосты ADR-0016: scoped render-token, авто-ренью TLS, TLS для API самого OpenBao

Второй заход по «Не проработано» первой редакции — все три пункта закрыты и проверены живым
прогоном: `VAULT_TOKEN` для gomplate теперь scoped-токен (policy `aicd-platform-render`, только
read `secret/gitea`|`secret/semaphore`), `gitea-tls`/`semaphore-tls` перевыпускаются
автоматически по epoch-аннотации `renew-after-epoch` (60 из 90 дней TTL), API самого OpenBao
теперь слушает `https://` (bootstrap self-signed сертификат, не из своего PKI engine — см.
`docs/adr/0016-openbao-secrets-pki.md` §5).

Три новых реальных находки этого захода:

8. **StatefulSet чарта `openbao/openbao` — `updateStrategy: OnDelete`.** Смена values
   (`global.tlsDisable`, `server.ha.raft.config`) обновляет ConfigMap и checksum-аннотацию в
   шаблоне STS, но НЕ перезапускает уже существующий под сам по себе — апстрим сознательно не
   делает автоматический rolling restart для raft-кластера. Под молча продолжал слушать
   старым (http) конфигом, а `ansible.builtin.uri` с новым `https://` адресом падал
   (`SSL: RECORD_LAYER_FAILURE` — TLS handshake против сервера, говорящего plain HTTP).
   Исправлено: новая задача в `site.yml` сравнивает `config-checksum` из шаблона STS и из живого
   пода и удаляет под при расхождении (StatefulSet сам пересоздаёт с PVC, данные raft не
   теряются) — на каждом прогоне, не только при первом переключении на TLS.
9. **K8s API требует строковые значения аннотаций, а ansible native-jinja отдаёт число.**
   `aicd.platform/renew-after-epoch: "{{ (epoch|int) + N }}"`, будучи ЦЕЛИКОМ одним числовым
   Jinja-выражением, рендерится в Python `int`, а не строку, ДАЖЕ будучи в двойных кавычках в
   YAML (кавычки — синтаксис YAML, Jinja их не видит) — `kubectl`/`kubernetes.core.k8s` затем
   пытается записать JSON `number`, API-сервер отвечает `"cannot unmarshal number into ...
   annotations of type string"`. Исправлено explicit `| string` в конце выражения.
10. **gomplate-датасорс `vault://` — отдельный HTTP-клиент, не `ansible.builtin.uri`.** После
    переключения OpenBao на TLS `ca_path`, добавленный во все ansible-задачи, никак не влияет на
    сам `helmwave`/gomplate — его `vault://` datasource использует свой Go-клиент
    (`hashicorp/vault/api`) и требует стандартный для Vault/OpenBao CLI env var `VAULT_CACERT`,
    иначе падает `"x509: certificate signed by unknown authority"`. Исправлено добавлением
    `VAULT_CACERT` в `environment:` второго `helmwave up` рядом с `VAULT_ADDR`/`VAULT_TOKEN`.

### Стандартный набор аддонов (docs/adr/0017-platform-cicd-default-addons.md)

Второй `helmwave up` теперь ограничен `--tags` — обязательные релизы
(`platform_aicd_core_releases`) плюс включённый набор аддонов
(`platform_aicd_default_addons`/`_extra_addons`/`_disabled_addons`,
`platform/aicd/ansible/group_vars/platform_hosts.yml`). Первый и пока единственный аддон —
[Radar](https://github.com/skyhook-io/radar) (open-source Kubernetes UI, чарт `skyhook/radar`):
RBAC-дефолты чарта оставлены как есть (без доступа к Secrets, без Helm-writes), вход — за
Traefik basic-auth (`Middleware radar-basic-auth`), пароль и TLS — из того же OpenBao/PKI, что
`gitea`/`semaphore` (ADR-0016). Чтобы отключить Radar на конкретном стенде (до первой установки):
`platform_aicd_disabled_addons: [radar]` в `group_vars/platform_hosts.yml` или `-e`. Найдено
реальным прогоном: на УЖЕ развёрнутом Radar тот же оверрайд релиз не удаляет (`helmwave up
--tags` просто исключает его из плана, не трогая существующий helm-релиз) — для реального
удаления нужен ручной `helmwave down --tags radar` (см. `docs/adr/0017-platform-cicd-default-addons.md`).

Не проработано (см. также `docs/adr/0016-openbao-secrets-pki.md`, «Не проработано»): нет
intermediate CA у PKI engine; CI-раннер (Gitea Actions) не читает секреты из OpenBao;
интеграция с `reverse_proxy_traefik`/docker-based Traefik пилотных Module (`infra-panel-target`)
— отдельная задача (Фаза 6 в широком смысле); `Module.spec.vars` пилотных Module по-прежнему
плейнтекст в `platform/gitops`; RBAC-профиль Radar не тюнится тоньше дефолтов чарта
(ADR-0017, «Не проработано»).
