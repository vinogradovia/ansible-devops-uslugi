# ADR-0016: OpenBao — секреты и внутренний PKI CA для platform/cicd

- **Статус:** Принято
- **Дата:** 2026-08-24
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

`platform/cicd` (ADR-0012, ADR-0014) сейчас хранит все секреты прямым текстом в
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
`platform/cicd`, и заодно — использовать ли его же как внутренний PKI CA вместо отдельного
`cert-manager`. `cicd.platform` живёт на приватной libvirt-сети без публичного DNS — Let's
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
используемый helmwave-темплейтер, `platform/cicd/ansible/site.yml`, `--templater gomplate`)
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
его, затем `platform/cicd/ansible/site.yml` инициализирует/распечатывает OpenBao и наполняет
секреты через ansible, и только затем второй, уже безусловный `helmwave up` (без `--tags`)
разворачивает Gitea/Semaphore/Flux, для которых `vault://` к этому моменту уже отвечает.

### 3. Init/unseal/bootstrap — идемпотентный ansible-блок в `site.yml`, не отдельный runbook

**Решение:** `platform/cicd/ansible/site.yml` при каждом прогоне (не только первом):
- проверяет существование K8s Secret `openbao-init` (namespace `platform`) — если нет,
  инициализирует OpenBao (`POST /v1/sys/init`, `secret_shares: 1`, `secret_threshold: 1`) и
  сохраняет `root_token`+unseal-ключ в этот Secret; если да — просто читает значения обратно
  (`kubernetes.core.k8s_info` + `b64decode`), НЕ реинициализирует;
- безусловно проверяет `seal-status` и распечатывает OpenBao, если он sealed (под мог
  перезапуститься между прогонами — raft-хранилище не авто-распечатывается);
- включает `secret/` (KV v2) и `pki/` (генерирует root CA для `cicd.platform`, `ttl: 87600h`,
  PKI-роль `cicd-platform` с `allowed_domains: cicd.platform`, `allow_subdomains: true`) — только
  если ещё не включены;
- генерирует admin-пароли Gitea/Semaphore и base64-ключи Semaphore **только если их ещё нет** в
  `secret/gitea`/`secret/semaphore` — критичная идемпотентность: пере-генерация при каждом
  прогоне сломала бы уже существующие сессии/данные (тот же принцип, что уже документирован для
  паролей других ролей, но здесь источник правды не git, а сам OpenBao);
- выпускает TLS-сертификаты (`POST /pki/issue/cicd-platform` для `gitea.cicd.platform` и
  `semaphore.cicd.platform`) и пишет их в K8s Secrets `type: kubernetes.io/tls`, тоже только если
  такого Secret ещё нет.

**Обоснование:** переиспользует уже существующий в коллекции паттерн check-Secret-then-act
(`roles/monitoring_server/tasks/monitoring-server.k3s.yml` — создание Grafana admin-секрета через
`kubernetes.core.k8s`), а не изобретает отдельный ручной runbook — весь жизненный цикл выражен в
том же `site.yml`, который уже отвечает за идемпотентный `ansible-playbook`-прогон всего стенда.

**Однодольный unseal-ключ (`secret_threshold: 1`)** — осознанное упрощение: полноценный
Shamir-кворум имеет смысл при нескольких операторах/HA-развёртывании, здесь единственная
K3s-нода и единственный оператор. Пересмотреть при росте платформы за пределы одного узла.

### 4. TLS через PKI secrets engine, без cert-manager

**Решение:** сертификаты для `gitea.cicd.platform`/`semaphore.cicd.platform` выпускаются
напрямую через `pki/issue/cicd-platform` (см. §3) и подключаются к уже существующим
`IngressRoute` через `tls.secretName` (шаблон `helm/localrepo/universal-chart/templates/
traefikingressroute.yml` уже поддерживает это поле — подтверждено чтением исходника, доработка
чарта не нужна).

**Обоснование:** единственный корневой CA для всех сервисов стенда вместо самоподписанного
сертификата Traefik по умолчанию на каждый хост — оператору достаточно один раз импортировать CA
`cicd.platform` в доверенное хранилище, а не подтверждать security exception для каждого
сервиса отдельно. `cert-manager` не используется — Let's Encrypt всё равно недоступен на
приватной сети без публичного DNS, а `vault`/`venafi`-issuer cert-manager поверх уже
поднятого OpenBao добавил бы ещё один компонент ради стенда, который и так полностью управляется
одним `ansible-playbook`-прогоном.

**Явно вне scope этого ADR:** автоматическая ротация/renewal сертификатов (TTL выставляется с
запасом, перевыпуск — ручной), интеграция с `reverse_proxy_traefik`/docker-based Traefik
инстансами пилотных Module (например, `infra-panel-target`, ADR-0014 Фаза 5) — это часть более
широкого расширения охвата контроллера (ADR-0014 Фаза 6 в широком смысле), отдельная задача.

## Не проработано (следующие шаги)

- `VAULT_TOKEN` для gomplate — root token OpenBao напрямую, не scoped read-only policy/token.
  Приемлемо для первой итерации персистентного, но ещё однопользовательского стенда; заменить на
  ограниченную политику — явный follow-up перед тем, как к стенду получит доступ кто-то ещё.
- Нет intermediate CA — root CA выпускает leaf-сертификаты напрямую. Приемлемо для
  единственной приватной non-HA платформы; пересмотреть при росте.
- Нет автоматической ротации/renewal TLS-сертификатов.
- CI-раннер (Gitea Actions, ADR-0012 §4) не читает секреты из OpenBao — эта интеграция покрывает
  только Helm-values Semaphore/Gitea через Semaphore/helmwave, не сам CI-контур.
- Интеграция OpenBao PKI с `reverse_proxy_traefik`/docker-Traefik пилотных Module — не сделана
  (ADR-0014 Фаза 6, отдельная задача).
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
