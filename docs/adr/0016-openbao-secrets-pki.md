# ADR-0016: OpenBao — секреты и внутренний PKI CA для platform/aicd

- **Статус:** Принято
- **Дата:** 2026-08-24
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

**Примечание (2026-08-25):** директория и прикладной домен переименованы `platform/cicd`/
`cicd.platform` → `platform/aicd`/`aicd.platform` уже после принятия этого ADR — текст ниже
приведён к актуальному имени; внутренние terraform-идентификаторы живой VM (`local.vms.cicd`,
`platform-cicd`) сознательно оставлены как есть, см. `platform/aicd/terraform/versions.tf`.

## Контекст

`platform/aicd` (ADR-0012, ADR-0014) сейчас хранит все секреты прямым текстом в
git-закоммиченных `helm/values/platform/namespaces/platform/{gitea,semaphore}/values.yaml` —
admin-пароли Gitea/Semaphore и base64-ключи `SEMAPHORE_COOKIE_HASH`/`SEMAPHORE_COOKIE_ENCRYPTION`/
`SEMAPHORE_ACCESS_KEY_ENCRYPTION` заведены как плейсхолдеры прямо в файлах с явной пометкой
«сменить перед реальным использованием» (см. комментарии в обоих `values.yaml`). TLS — дефолтный
самоподписанный сертификат встроенного в k3s Traefik (`CN=TRAEFIK DEFAULT CERT`).

ADR-0012 §3 уже решил эту развилку архитектурно: секреты — во внешнем **OpenBao**, не в
оригинальном HashiCorp Vault (геоблок `apt.releases.hashicorp.com`/`releases.hashicorp.com`,
эмпирически подтверждён 5+ независимыми проверками в сессии над `roles/freeipa`, см.
`extensions/molecule/freeipa/molecule.yml`). Но сама инфраструктура OpenBao ни разу не
поднималась — ADR-0012 фиксировал только выбор инструмента, не реализацию.

Этот ADR закрывает два смежных открытых вопроса одним решением: как реализовать OpenBao для
`platform/aicd`, и заодно — использовать ли его же как внутренний PKI CA вместо отдельного
`cert-manager`. `aicd.platform` живёт на приватной libvirt-сети без публичного DNS — Let's
Encrypt в любом случае недоступен, а заводить cert-manager с self-signed issuer ради одного
приватного стенда — лишний компонент инфраструктуры без выигрыша перед прямым использованием
PKI secrets engine уже поднятого OpenBao.

## Решения

### 1. Helm-релиз: официальный чарт `openbao/openbao`, integrated storage (raft), не dev-режим

**Решение:** новый релиз `openbao` в `helm/envs/platform.yaml` (репозиторий
`https://openbao.github.io/openbao-helm`, чарт `openbao/openbao`, версия `0.29.2` — актуальная
стабильная на момент написания). Хранилище — **integrated storage (raft)**, `server.ha.enabled:
false` (single-node, тот же масштаб, что и весь стенд — одна K3s-нода).

**Обоснование:** dev-режим (`server.dev.enabled: true`) держит все данные в памяти — под
перезапустится, и вместе с ним исчезнут все секреты и корневой CA, что для персистентной
платформенной инфраструктуры (в отличие от `demo/*`, ADR-0006 §9) неприемлемо. Полноценный
Vault/OpenBao кластер (HA, несколько реплик) избыточен для одной K3s-ноды — та же логика, что уже
применена к `monitoring_server_orchestrator`/Semaphore (`server.ha.enabled: false`, один под,
персистентный volume через штатный `local-path`).

### 2. Гомплейт `vault://` datasource вместо ansible-обвязки для чтения секретов в values

**Решение:** секреты читаются в Helm values напрямую через встроенный в **gomplate** (уже
используемый helmwave-темплейтер, `platform/aicd/ansible/site.yml`, `--templater gomplate`)
datasource `vault://` — API-совместимый с любым Vault-подобным сервером, включая OpenBao без
доработок: `{{ (datasource "vault" "secret/gitea").data.admin_password }}` прямо в
`values.yaml`. Аутентификация — `$VAULT_ADDR`/`$VAULT_TOKEN`, передаются в `environment:` вызова
`helmwave up` тем же способом, что уже передаются `KUBECONFIG`/`NO_PROXY`.

**Обоснование:** устраняет необходимость городить отдельный ansible-слой, читающий секреты из
OpenBao и подставляющий их в values файлы перед рендером — значение читается непосредственно в
момент рендера тем инструментом, который и так уже шаблонизирует values.

**Курица и яйцо:** OpenBao должен быть поднят/распечатан/наполнен секретами ДО того, как gomplate
рендерит values для Gitea/Semaphore (иначе `vault://` datasource упадёт — сервер недоступен).
Решение — двухфазный `helmwave up`, используя уже применяемый в коллекции механизм тегов релизов
(`docs/adr/0007-monitoring-server-role.md`, `monitoring_server_helmwave_tags`/`--tags`): релиз
`openbao` помечен `tags: [openbao]`, первый вызов `helmwave up --tags openbao` поднимает только
его, затем `platform/aicd/ansible/site.yml` инициализирует/распечатывает OpenBao и наполняет
секреты через ansible, и только затем второй, уже безусловный `helmwave up` (без `--tags`)
разворачивает Gitea/Semaphore/Flux, для которых `vault://` к этому моменту уже отвечает.

### 3. Init/unseal/bootstrap — идемпотентный ansible-блок в `site.yml`, не отдельный runbook

**Решение:** `platform/aicd/ansible/site.yml` при каждом прогоне (не только первом):
- проверяет существование K8s Secret `openbao-init` (namespace `platform`) — если нет,
  инициализирует OpenBao (`POST /v1/sys/init`, `secret_shares: 1`, `secret_threshold: 1`) и
  сохраняет `root_token`+unseal-ключ в этот Secret; если да — просто читает значения обратно
  (`kubernetes.core.k8s_info` + `b64decode`), НЕ реинициализирует;
- безусловно проверяет `seal-status` и распечатывает OpenBao, если он sealed (под мог
  перезапуститься между прогонами — raft-хранилище не авто-распечатывается);
- включает `secret/` (KV v2) и `pki/` (генерирует root CA для `aicd.platform`, `ttl: 87600h`,
  PKI-роль `aicd-platform` с `allowed_domains: aicd.platform`, `allow_subdomains: true`) — только
  если ещё не включены;
- генерирует admin-пароли Gitea/Semaphore и base64-ключи Semaphore **только если их ещё нет** в
  `secret/gitea`/`secret/semaphore` — критичная идемпотентность: пере-генерация при каждом
  прогоне сломала бы уже существующие сессии/данные (тот же принцип, что уже документирован для
  паролей других ролей, но здесь источник правды не git, а сам OpenBao);
- выпускает TLS-сертификаты (`POST /pki/issue/aicd-platform` для `gitea.aicd.platform` и
  `semaphore.aicd.platform`) и пишет их в K8s Secrets `type: kubernetes.io/tls`, тоже только если
  такого Secret ещё нет.

**Обоснование:** переиспользует уже существующий в коллекции паттерн check-Secret-then-act
(`roles/monitoring_server/tasks/monitoring-server.k3s.yml` — создание Grafana admin-секрета через
`kubernetes.core.k8s`), а не изобретает отдельный ручной runbook — весь жизненный цикл выражен в
том же `site.yml`, который уже отвечает за идемпотентный `ansible-playbook`-прогон всего стенда.

**Однодольный unseal-ключ (`secret_threshold: 1`)** — осознанное упрощение: полноценный
Shamir-кворум имеет смысл при нескольких операторах/HA-развёртывании, здесь единственная
K3s-нода и единственный оператор. Пересмотреть при росте платформы за пределы одного узла.

### 4. TLS через PKI secrets engine, без cert-manager

**Решение:** сертификаты для `gitea.aicd.platform`/`semaphore.aicd.platform` выпускаются
напрямую через `pki/issue/aicd-platform` (см. §3) и подключаются к уже существующим
`IngressRoute` через `tls.secretName` (шаблон `helm/localrepo/universal-chart/templates/
traefikingressroute.yml` уже поддерживает это поле — подтверждено чтением исходника, доработка
чарта не нужна).

**Обоснование:** единственный корневой CA для всех сервисов стенда вместо самоподписанного
сертификата Traefik по умолчанию на каждый хост — оператору достаточно один раз импортировать CA
`aicd.platform` в доверенное хранилище, а не подтверждать security exception для каждого
сервиса отдельно. `cert-manager` не используется — Let's Encrypt всё равно недоступен на
приватной сети без публичного DNS, а `vault`/`venafi`-issuer cert-manager поверх уже
поднятого OpenBao добавил бы ещё один компонент ради стенда, который и так полностью управляется
одним `ansible-playbook`-прогоном.

**Явно вне scope этого ADR:** интеграция с `reverse_proxy_traefik`/docker-based Traefik
инстансами пилотных Module (например, `infra-panel-target`, ADR-0014 Фаза 5) — это часть более
широкого расширения охвата контроллера (ADR-0014 Фаза 6 в широком смысле), отдельная задача.

### 5. Хвосты первой итерации: scoped render-token, авто-ренью TLS, TLS для API самого OpenBao

Три пункта из «Не проработано» первой редакции этого ADR, закрытые вторым заходом:

**Scoped `VAULT_TOKEN`.** Policy `aicd-platform-render` (`sys/policies/acl/aicd-platform-render`,
`platform/aicd/ansible/site.yml`) даёт только `read` на `secret/data/gitea` и
`secret/data/semaphore` — ничего из `sys/*`/`pki/*`/write. Токен по этой policy (`ttl: 87600h`,
`auth/token/create`) выпускается один раз, сохраняется в K8s Secret `openbao-render-token` (тот
же идемпотентный паттерн, что `openbao-init`) и используется как `VAULT_TOKEN` для второго
`helmwave up` вместо root token. Root token остаётся только внутри самого ansible-блока
init/unseal/engines/PKI — наружу, во внешний процесс (`helmwave`), больше не передаётся.

**Авто-ренью TLS-сертификатов.** `tasks/issue-tls-cert.yml` пишет аннотацию
`aicd.platform/renew-after-epoch` на Secret (`gitea-tls`/`semaphore-tls`) в момент выпуска
(`issued_at + 60d`, TTL сертификата — 90д, т.е. 30-дневный запас), и на каждом прогоне
`site.yml` перевыпускает сертификат не только при отсутствии Secret, но и когда этот порог
пройден. Разбор PEM (`notAfter`) не потребовался — Secret и так уже читается для
existence-проверки, epoch-аннотация дешевле отдельного парсинга сертификата на control-хосте.

**TLS для API самого OpenBao.** Bootstrap self-signed сертификат (`community.crypto.
openssl_privatekey`/`openssl_csr`/`x509_certificate`, SAN — cluster-DNS имя и реальный IP ноды),
сгенерированный на control-хосте и смонтированный в под через Secret `openbao-server-tls` +
`server.extraVolumes` чарта (`/openbao/userconfig/openbao-server-tls/{tls.crt,tls.key}`) —
**независимо** от PKI engine самого OpenBao, чтобы избежать курицы-и-яйца (для выпуска
сертификата из `pki/issue` нужен уже распечатанный OpenBao с включённым PKI, а слушать TLS он
обязан с первого старта). `global.tlsDisable: false` переключает listener,
readiness/liveness-пробы (`openbao.scheme` helper чарта) и `BAO_ADDR`/`BAO_API_ADDR` внутри пода
на https без доработки runtime-кода; `server.configAnnotation: true` заставляет под
перезапуститься при смене конфига (по умолчанию чарт этого не делает — ConfigMap меняется, но
процесс перечитывает конфиг только при старте). Все `ansible.builtin.uri`-вызовы к OpenBao
переключены на `https://` с `ca_path`, указывающим на тот же self-signed файл (используется как
собственный доверенный якорь — `basicConstraints CA:true` для этого не требуется, он проверяется
TLS-стеком только для промежуточных звеньев цепочки, не для самого якоря доверия). Отдельно —
gomplate-датасорс `vault://` внутри `helmwave` использует СВОЙ HTTP-клиент
(`hashicorp/vault/api`), не `ansible.builtin.uri` — `ca_path` на него не действует; такой же
доверенный файл передаётся вторым вызовом `helmwave up` через стандартный для Vault/OpenBao CLI
env var `VAULT_CACERT`.

**Проверено `helm template` перед живым прогоном** (namespace/имена совпадают с реальным
релизом): корректная https-схема в `BAO_ADDR`/`BAO_API_ADDR`, корректный `volumeMount` для
`userconfig-openbao-server-tls`, `tls_cert_file`/`tls_key_file` в отрендеренном ConfigMap,
readinessProbe — `exec: bao status -tls-skip-verify` (не зависит от доверия к сертификату).

**Осознанно не сделано и здесь:** сертификат для самого API OpenBao не переиздаётся из
собственного PKI engine после его инициализации (был бы более «единый» источник доверия, но
требует двухфазного переключения листенера и не даёт ощутимой пользы для internal-only API) —
возможный будущий рефайнмент, не текущая задача.

## Не проработано (следующие шаги)

- Нет intermediate CA — root CA выпускает leaf-сертификаты напрямую. Приемлемо для
  единственной приватной non-HA платформы; пересмотреть при росте.
- CI-раннер (Gitea Actions, ADR-0012 §4) не читает секреты из OpenBao — эта интеграция покрывает
  только Helm-values Semaphore/Gitea через Semaphore/helmwave, не сам CI-контур.
- Интеграция OpenBao PKI с `reverse_proxy_traefik`/docker-Traefik пилотных Module — не сделана
  (ADR-0014 Фаза 6, отдельная задача).
- `Module.spec.vars` пилотных Module (например, `infra-panel-pilot`) по-прежнему плейнтекст в
  `platform/gitops` — перенос в OpenBao не сделан (затрагивает platform-controller, отдельная
  задача).
- Официальные значения по умолчанию чарта `openbao/openbao` (ресурсы, readinessProbe, размер
  PVC) взяты как есть без тонкой настройки под нагрузку одной K3s-ноды — пересмотреть при первом
  реальном использовании под нагрузкой.

## Ссылки

- `docs/adr/0012-cicd-platform-architecture.md` §3 — исходное решение в пользу OpenBao
  (геоблок HashiCorp), закрывается этим ADR.
- `docs/adr/0014-platform-controller-architecture.md` — платформенный контроллер, чьи
  Module (`infra-panel-pilot` и др.) в будущем смогут читать секреты из этого же OpenBao.
- `docs/adr/0007-monitoring-server-role.md` §6, `monitoring_server_helmwave_tags` — прецедент
  использования тегов helmwave-релизов для выборочного `up`.
- `roles/monitoring_server/tasks/monitoring-server.k3s.yml` — прецедент паттерна
  create-Secret-если-отсутствует через `kubernetes.core.k8s`.
- `ROADMAP.md`, «Предлагаемая последовательность работ», пункт 7 — контекст фаз ADR-0014, на
  фоне которых выполнена эта работа.
