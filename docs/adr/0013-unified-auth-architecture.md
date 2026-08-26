# ADR-0013: Единая авторизация — Authelia поверх `freeipa`, `*_auth_method` для потребителей

- **Статус:** Принято; реализовано на `platform/aicd` и `platform/aicd-devops-labs-ru`
  (2026-08-26) — persistent `freeipa`, Authelia (OIDC + `forwardAuth`), `forwardAuth` перед
  `infra-panel`/`radar`, нативный OIDC у Semaphore/Gitea. Оба окружения проверены живым прогоном
  (см. §7 и §8).
- **Дата:** 2026-08-21
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

Авторизация в разных ролях коллекции реализована независимо и минимально: basic-auth с
htpasswd-хэшем, генерируемым/инлайнящимся отдельно в каждой роли
(`reverse_proxy_traefik_dashboard_users`, `infra_panel` basic-auth перед homer,
`reverse_proxy_npm` admin UI). Ни единого набора пользователей/групп, ни SSO между сервисами
(Grafana, Bareos webui, infra-panel, NPM admin, Traefik dashboard) нет.

Роль `freeipa` (ADR-0011) уже реализована — standalone LDAP/Kerberos-каталог,
`ipa-server-install`, без репликации и без управления данными каталога. ROADMAP Backlog №49
изначально фиксировал приоритет: OAuth2/OIDC — основной протокол, LDAP (через `freeipa`) —
fallback для сервисов, которые OIDC не умеют. Этот ADR закрывает архитектурные развилки,
не позволявшие приступить к реализации.

## Решения

### 1. Каталог пользователей — один, `freeipa`; OIDC ставится поверх, не рядом

**Решение:** `freeipa` остаётся единственным источником правды о пользователях/группах.
OIDC-провайдер (§2) федерируется с ним через LDAP-бэкенд, а не заводит собственную независимую
базу пользователей.

**Обоснование:** два независимых каталога пользователей (LDAP в `freeipa` + отдельная БД
OIDC-провайдера) означают рассинхронизацию учёток и двойное администрирование — прямо
противоречит цели единой авторизации. LDAP и OIDC в этой архитектуре — два протокола поверх
одного каталога, а не два независимых механизма: `freeipa` обслуживает admin-панели, которые
умеют только basic-auth-через-LDAP (bind напрямую), OIDC-провайдер обслуживает всех, кто умеет
современный протокол.

### 2. OIDC-провайдер — Authelia, не Keycloak

**Решение:** self-hosted OIDC-провайдер — **Authelia**.

**Обоснование:** Authelia — лёгкий Go-бинарник, спроектирован именно под `forwardAuth`-паттерн
перед reverse-proxy (нативно поддерживает Traefik `forwardAuth` middleware), умеет LDAP-бэкенд
из коробки (федерация с `freeipa`, §1). Keycloak (JVM + своя Postgres-БД, полноценный
admin UI/self-service) тяжелее и функционально избыточен для сценария "authentication gateway
перед существующими admin-панелями коллекции" — тут не нужен богатый self-service/multi-realm
функционал Keycloak, а вес и эксплуатационная сложность (JVM-тюнинг, отдельная БД) не оправданы.

### 3. Роль — отдельная (`oauth_provider`/`sso`, имя не выбрано), на платформенной инфраструктуре ADR-0012

**Решение:** Authelia — отдельная роль по паттерну `_server` (аналогично `monitoring_server`,
`backup_server`), не интеграционный слой, размазанный по ролям-потребителям. Живёт на той же
новой персистентной платформенной инфраструктуре, что Harbor/Gitea/OpenBao/Semaphore
(`docs/adr/0012-cicd-platform-architecture.md` §6) — не в `demo/full-platform`, не совмещена
с самим `freeipa`.

**Обоснование:** тот же принцип, что уже применён к `backup_agent`/`docker` — авторизация
достаточно самостоятельный, переиспользуемый инфраструктурный примитив, чтобы не размазывать его
логику по каждой роли-потребителю (обратное решение потребовало бы, чтобы каждая роль сама умела
разворачивать/настраивать Authelia — явное дублирование). Размещение на платформенной
инфраструктуре ADR-0012 обосновано и практически: Semaphore (тот же ADR, §5) уже зафиксирован как
будущий потребитель SSO (follow-up) — Authelia и её первый реальный потребитель логично живут
рядом.

**Не проработано:** финальное имя роли (`oauth_provider` слишком общее — не привязано к
конкретному продукту, если когда-то Authelia будет заменена; `authelia` — конкретное, но
нетипично для остальных ролей коллекции, которые именуются по функции, а не по продукту, ср.
`backup_server`/`backup_agent`, а не `bareos_server`). Решить перед реализацией.

### 4. Интеграция потребителей — нативный OIDC, где есть; `forwardAuth`, где нет; общая `*_auth_method`

**Решение:** каждая роль-потребитель сама учится валидировать/настраивать OIDC, если сам сервис
это умеет нативно (пример — Grafana, `generic_oauth` в `grafana.ini`, `monitoring_server`).
Если сервис не умеет OIDC вообще (сейчас это все admin-панели коллекции с голым basic-auth —
`reverse_proxy_traefik` dashboard, `infra_panel`, `reverse_proxy_npm` admin UI), перед ним
ставится Traefik `forwardAuth` middleware, делегирующий проверку сессии в Authelia — сама роль
не учится ничему новому, меняется только конфигурация Traefik-labels на контейнере.

Единая переменная `*_auth_method: basic | ldap | oauth` в каждой роли-потребителе — по прямому
образцу уже принятого паттерна `*_backup_tool` (`docs/adr/0010-backup-agent-role.md`):
взаимоисключающий выбор, дефолт — `basic` (обратная совместимость, ничего не ломается для
существующих инсталляций), `ldap`/`oauth` подключают Authelia-интеграцию соответствующим для
роли способом (нативная конфигурация сервиса или `forwardAuth`-labels).

**Обоснование:** та же логика, что уже закреплена в `docs/adr/0004-mysql-ha-replication-role.md`
§11 (условная `meta`-зависимость для обязательного примитива, композиция — для независимо
включаемого аспекта) — здесь ближе ко второму: авторизация — не обязательный примитив, без
которого роль не работает вовсе (в отличие от `docker` для `orchestrator: docker`), а
опциональный режим, который оператор осознанно включает per-host/per-service. Значит,
`*_auth_method`, а не безусловная `meta`-зависимость на Authelia.

### 5. Повторная проверка: Authelia остаётся, не Keycloak (2026-08-26)

**Контекст повторной проверки:** после появления ROADMAP №55 (единая авторизация для
kube-apiserver, кандидат — Dex или аналог) встал вопрос — не проще ли закрыть обе задачи (SSO
приложений §2/§4 и OIDC для kube-apiserver) одним более функциональным провайдером (Keycloak)
вместо двух разных компонентов (Authelia + Dex/аналог), федерированных в один и тот же `freeipa`.

**Решение:** выбор Authelia (§2) подтверждён без изменений. Задача №55 по-прежнему решается
отдельным компонентом (Dex или аналог), а не заменой Authelia на Keycloak.

**Обоснование:**
- Для сценария §4 (`forwardAuth` перед admin-панелями без OIDC) у Keycloak нет нативного аналога
  `forwardAuth` — пришлось бы ставить `oauth2-proxy` перед Keycloak для тех же панелей (Traefik
  dashboard, `infra_panel`, `reverse_proxy_npm` admin UI). Замена не убирает компонент, а
  добавляет третий поверх уже более тяжёлого Keycloak.
- Цель "единой авторизации" обеспечивается §1 — единым каталогом `freeipa`, а не единым
  OIDC-провайдером. Authelia и Dex, федерированные в один и тот же LDAP, не создают
  рассинхронизации учёток — два протокольных адаптера поверх одного каталога полностью
  укладываются в принцип §1. Реального выигрыша от единого issuer'а для kube-apiserver и для
  приложений за reverse-proxy нет: `kubectl` OIDC-логин — отдельный from-browser/device-flow, не
  разделяет cookie-сессию портала Authelia.
- Keycloak (JVM + отдельная Postgres-БД, ~1 ГБ RAM базово) противоречит уже устоявшемуся в
  коллекции принципу предпочитать лёгкие однобинарные инструменты — тот же критерий, что уже
  применялся к выбору `freeipa` вместо полноценного IAM-стека и изначально к выбору Authelia
  вместо Keycloak (§2).
- OIDC-провайдер Authelia — [OpenID Certified](https://www.authelia.com/overview/authorization/openid-connect-1.0/),
  на 2026-08-26 находится на стадии beta 7 из 8 ([roadmap апстрима](https://www.authelia.com/roadmap/active/openid-connect-1.0-provider/),
  v4.39), формально ещё не объявлен GA, но поддерживает `groups`-claim и custom scopes/claims —
  достаточно для кандидата §4 (Grafana `generic_oauth`). Риск, не блокер: апстрим прямо не
  позиционирует эту реализацию как issuer для сервисов, которым нужны кастомные claims под
  RBAC, — именно такой сценарий у kube-apiserver, что независимо от веса Keycloak тоже говорит
  не в пользу Authelia для №55.
- Для №55 отраслевой консенсус — Keycloak либо Dex, но не Authelia (её OIDC — bolt-on поверх
  forwardAuth-ядра). Выбор между Keycloak и Dex конкретно для №55 не сделан этим пересмотром —
  требует отдельного ADR (см. ROADMAP №55). Здесь закрыт только вопрос "менять ли Authelia на
  Keycloak ради №2/№4", а не выбор провайдера для №55.

### 6. Ревизия §3: Helm-релиз вместо отдельной роли (2026-08-26)

**Решение:** Authelia реализована НЕ отдельной ansible-ролью коллекции (как предполагал §3), а
Helm-релизом (`localrepo/universal-chart`) с оркестрацией секретов/TLS/forwardAuth в
`platform/aicd/ansible/site.yml` — тем же приёмом, что уже применён для OpenBao/Gitea/Semaphore/
Radar/infra-panel на этой же инфраструктуре.

**Обоснование:** с момента написания §3 фактическая практика `platform/aicd*` (ADR-0012 §6 сам
оставлял вопрос "роль или нет" открытым) устоялась в пользу "нет" для всей платформенной
инфраструктуры — ни один из перечисленных в ADR-0012 компонентов (кроме Harbor, не
реализован) в итоге не стал ролью коллекции. Authelia технически — точно такой же кейс (один
контейнер, конфиг-файл, секреты, TLS, Ingress), заводить под неё новую роль с molecule-сценарием
означало бы единственное на всю платформенную инфраструктуру исключение без практической пользы.
Имя роли (§3, «не проработано») снимается этим же решением — вопрос больше не актуален.

### 7. Реализация на `platform/aicd` (2026-08-26) — freeipa persistent, Authelia, forwardAuth, OIDC

**freeipa** — новая persistent VM (`platform/aicd/terraform/freeipa-target.tf`, тот же
Packer-образ Rocky 9, что `demo/full-platform`), роль `freeipa` применяется отдельным play
(`platform/aicd/ansible/site.yml`) на хосте `ipa.aicd.platform`. Bind-аккаунт `svc-authelia`
(обычный непривилегированный IPA-пользователь, `--password-expiration` далеко в будущем — иначе
FreeIPA требует смены пароля при первом использовании, а сервисный аккаунт никогда не логинится
интерактивно) заводится оркестрацией `site.yml` (не самой ролью, ADR-0011 §3).

**Authelia** — `configuration.yml` через ConfigMap, `authentication_backend.ldap.implementation:
'freeipa'` (готовый пресет Authelia под FreeIPA), OIDC-клиенты для Semaphore/Gitea
(`client_secret` — pbkdf2-sha512-хэш, посчитан `authelia crypto hash generate` через Docker на
control-хосте), хранилище — SQLite на PVC, TLS — из внутреннего PKI CA OpenBao.

**Найденные реальным прогоном проблемы (по хронологии, все исправлены):**

1. **CoreDNS: два `hosts`-плагина в одном Server Block роняют CoreDNS в CrashLoopBackOff.**
   Дефолтный k3s Corefile уже содержит `hosts /etc/coredns/NodeHosts` — второй `hosts {}` через
   `coredns-custom` (нужен был, чтобы резолвить `*.aicd.platform` изнутри кластера — эти хосты
   существуют только во внешнем `/etc/hosts` операторов) конфликтует. Исправлено плагином
   `template` (нет такого ограничения) с `answer` на ClusterIP встроенного Traefik.
2. **CoreDNS: `template IN A` без соответствующего `IN AAAA` — авторитетный NXDOMAIN ломает
   строгие резолверы.** AAAA-запрос для тех же имён проваливался через `fallthrough` в upstream
   (не знающий про `aicd.platform` вообще) и получал NXDOMAIN — семантически неверно (должно быть
   NODATA: имя существует, просто нет AAAA-записи). Резолвер Go (Traefik) и musl libc (`curl`)
   трактуют такой NXDOMAIN как "имени не существует вообще" и отбрасывают уже полученный
   успешный A-ответ. Исправлено вторым `template IN AAAA ... { rcode NOERROR }` для тех же имён.
3. **`freeipa`: релиз `authelia` отсутствовал в `platform_aicd_core_releases`.** Добавлен в
   `envs/platform.yaml`, но не в список для `--tags` второго `helmwave up` — релиз никогда не
   применялся, хотя ошибок никто не видел (просто не устанавливался).
   `depends_on: [{name: authelia}]` добавлен для `gitea`/`semaphore` — оба делают HTTPS-вызов к
   Authelia в момент своего старта, `helmwave` гарантирует `wait: true` на зависимости раньше них.
4. **gomplate `strings.Indent` непредсказуемо индентирует первую строку многострочного PEM иначе,
   чем остальные** — первая строка RSA-ключа получала на 18 пробелов больше, ломая YAML внутри
   вложенного `key: |`. Исправлено конвертацией в one-line double-quoted строку
   (`strings.ReplaceAll` реальных переносов строк на литеральные `\n`, YAML разворачивает их
   обратно при парсинге) — без риска рассинхронизации отступов.
5. **Authelia: `session.cookies[].default_redirection_url` не может совпадать с `authelia_url`** —
   иначе пользователя после логина редиректило бы обратно на сам портал. Указано на `infra-panel`
   как логичную стартовую страницу платформы.
6. **firewalld на образе Rocky 9 не запущен и не enabled по умолчанию** —
   `ansible.posix.firewalld` с `immediate: true` требует реально работающий демон. Добавлен явный
   `systemd: name=firewalld state=started enabled=true` перед открытием LDAP-портов.
7. **Gitea/Semaphore не доверяют внутреннему PKI CA OpenBao** (`x509: certificate signed by
   unknown authority`) при HTTPS-вызове к Authelia — Go-клиент внутри образов не знает о
   самодельном CA. Секрет `aicd-platform-ca` (CA-сертификат, публичный, не секрет по сути — взят
   из `pki/ca/pem`) монтируется в оба сервиса, `SSL_CERT_FILE` указывает на него.
8. **Критическая находка — `forwardAuth` c легаси-эндпоинтом `/api/verify` полностью не
   проверял авторизацию.** Middleware был настроен по устаревшему паттерну
   (`address: https://sso.aicd.platform/api/verify?rd=...`) — запрос реально доходил до Authelia
   (подтверждено TLS-сертификатом и логами), но Authelia у `/api/verify` авторизовывала запрос по
   ДОМЕНУ САМОГО ВЫЗОВА (`sso.aicd.platform`, `policy: bypass`), полностью игнорируя
   `X-Forwarded-Host` защищаемого ресурса — debug-лог Authelia прямым текстом показал `object
   https://sso.aicd.platform/api/verify...` вместо реального `infra-panel.aicd.platform`. На
   практике это означало: `forwardAuth` пропускал АБСОЛЮТНО ЛЮБОЙ запрос без проверки —
   эксплуатируемая дыра в защите, не косметический баг. Официальный текущий паттерн для Traefik
   (`authelia.com/integration/proxies/traefik/`) — другой эндпоинт, `/api/authz/forward-auth`,
   и адрес — **внутренний ClusterIP-сервис напрямую**
   (`http://authelia-authelia.platform.svc.cluster.local:9091/...`), не внешний домен через
   Traefik. Заодно устранило нужду в `tls.insecureSkipVerify` (был нужен только из-за HTTPS до
   внешнего домена) и саму возможность конфликта "домен вызова vs домен защищаемого ресурса".
   Найдено и исправлено ДО передачи стенда в реальную эксплуатацию — живых пользователей за это
   время не было.
9. **Побочный инцидент: приватный RSA-ключ подписи OIDC засветился в открытом виде в терминальном
   выводе** при ручной отладке рендеринга gomplate (`helmwave build` без `no_log`, в отличие от
   ansible-задачи). Ключ ни разу не использовался (Authelia ни разу не стартовала успешно с
   момента его генерации) — риск низкий, но `secret/authelia` целиком удалён и пересоздан заново
   идемпотентным механизмом сразу после обнаружения.

**Проверено реальным прогоном:** `Releases Success 7/7`, `forwardAuth` корректно возвращает `302`
на портал логина для `infra-panel`/`radar` без сессии (было — 200 с реальным контентом, до находки
№8), TLS-issuer у `sso.aicd.platform` — внутренний CA, Gitea (`/user/login`) и Semaphore
(`/api/auth/login` → `"oidc_providers":[{"id":"authelia",...}]`) показывают кнопку входа через
Authelia, повторный прогон полностью идемпотентен (`changed=3`, только always-changed задачи).

### 8. Реализация на `platform/aicd-devops-labs-ru` (2026-08-26) — Фаза F, механический перенос

После подготовки пользователем Rocky 9 cloud-init шаблона на Proxmox (VMID 9001, внешний
пререквизит из §7 «Не проработано») код §7 перенесён вторым окружением тем же приёмом, что уже
использовался для предыдущих релизов этой платформы (`sed`-замена префиксов/домена + unified
diff + `patch`, см. `demo/full-platform`/`platform/aicd` историю): `freeipa-target.tf`
(`proxmox_virtual_environment_vm`, статический IP вместо DHCP-резервации libvirt), `site.yml`
(3 play в том же порядке), `group_vars/freeipa_hosts.yml`, Helm values Authelia/CA-траста
Gitea/Semaphore, `authelia` в `platform_aicd_devops_labs_ru_core_releases`.

**Найденные реальным прогоном проблемы этой фазы (сверх уже известных из §7, все исправлены):**

1. **CPU-модель Proxmox по умолчанию (`qemu64`) не поддерживает x86-64-v2 (SSE4.2 и др.),
   обязательные для ядра Rocky Linux 9.** VM зависала на пустой serial-консоли без единой строки
   вывода (ядро падает до инициализации консоли) — не диагностируется штатными средствами (`qm
   config` показывал корректный `serial0: socket`). Исправлено `cpu.type = "x86-64-v2-AES"` в
   `freeipa-target.tf` (только для `freeipa`, `aicd_labs`/Ubuntu не затронута — та же
   дефолтная `qemu64` для Ubuntu-ядра проблемой не является).
2. **Механическая sed-замена случайно переименовала литеральный идентификатор, который должен
   был остаться одинаковым в обоих окружениях.** `Secret aicd-platform-ca` (сознательно с
   одинаковым именем на `platform/aicd` и здесь, §7 находка №7) при переносе получил имя
   `aicd-devops-labs-ru-ca` — правило "aicd-platform → aicd-devops-labs-ru" не различает
   "заменить домен" и "не трогать этот один литерал". Из-за рассинхронизации имени Secret'а с тем,
   что ждут `values.yaml` Gitea/Semaphore (`originalName: aicd-platform-ca`), оба пода зависали
   на несуществующем volume (`Init:0/3`/`ContainerCreating`) — `helmwave up` с `wait: true` ждал
   Ready **более 4 часов** прежде чем сдаться по таймауту. Исправлено возвратом буквального имени
   `aicd-platform-ca`; урок — при мех. переносе явно перепроверять все "намеренно одинаковые"
   идентификаторы, а не полагаться на список sed-правил целиком.
3. **`ipa-server-install` прерван обрывом SSH-сессии (сетевая флакость физической LAN этого
   стенда, см. ниже) ровно в тот момент, когда файл `/etc/ipa/default.conf` уже существовал, но
   реальная настройка LDAP/KDC/CA ещё не завершилась.** Идемпотентность роли `freeipa`
   (`creates: /etc/ipa/default.conf`) в норме верно пропускает повторную установку — но здесь она
   молча пропускала переустановку УЖЕ СЛОМАННОГО состояния (`ipactl`: `"IPA is not configured"`,
   `systemctl start ipa` падал: `"control process exited with error code"`). Диагностировано
   прямым SSH + `journalctl -u ipa.service`. Восстановлено вручную (`ipa-server-install
   --uninstall --unattended` на самой VM — однократное ручное вмешательство, не входит в
   автоматический контур playbook), после чего следующий прогон поставил FreeIPA с нуля успешно.
   Общий урок для этого паттерна идемпотентности: `creates:` защищает от повторного запуска
   долгой команды, но не отличает "успешно завершилась" от "прервана на полпути" — риск,
   специфичный для одношаговых (`--unattended`) инсталляторов без собственного transactional
   отката.
4. **Rocky 9 шаблон Proxmox (VMID 9001) не содержит пакет `firewalld` вовсе** (в отличие от
   Packer-образа `platform/aicd` из §7 находки №6, где пакет уже стоит, просто не запущен) —
   `ansible.builtin.systemd` падал `"Could not find the requested service firewalld: host"`.
   Исправлено явной `ansible.builtin.dnf: name=firewalld state=present` перед
   запуском/включением сервиса — разница между Packer-образом и шаблоном, подготовленным вручную
   пользователем через веб-интерфейс/CLI Proxmox.
5. **Сильная периодическая обрывность SSH/HTTPS до физической LAN этого Proxmox-стенда** (уже
   документированная в `ansible.cfg` находка, но в моменте реализации проявилась значительно
   острее обычного — короткие ad hoc SSH-подключения рвались чаще, чем проходили, ~40% успеха)
   потребовала для живого прогона отдельного bash-цикла с автоматическим повтором
   `ansible-playbook` (до 20 попыток, очистка `~/.ssh` control-socket между попытками — обнаружен
   и отдельный побочный баг: осиротевший control-socket от прежде прерванного прогона на диске
   `~/.ansible/cp/` вызывал зависание НОВЫХ соединений, пытавшихся его переиспользовать через
   идентичный `ControlPath`) — идемпотентность каждой из уже описанных выше задач (freeipa,
   bind-аккаунт, секреты OpenBao) подтверждена тем, что финальный успешный прогон случился только
   на очередной попытке после уже нескольких частично успешных, без дублей/конфликтов состояния.

**Проверено реальным прогоном:** `Releases Success 7/7`, `forwardAuth` — `302` на портал логина
для `infra-panel.aicd.devops-labs.ru`/`radar.aicd.devops-labs.ru` без сессии, TLS-issuer у
`sso.aicd.devops-labs.ru` — внутренний CA этого окружения, Gitea (`gitea admin auth list` →
источник `authelia`, `OAuth2`, `enabled=true`) и Semaphore (`SEMAPHORE_OIDC_PROVIDERS` в
переменных окружения пода) настроены, `freeipa` (`systemctl is-active ipa` → `active`, все
сервисы IPA стартовали), повторный прогон полностью идемпотентен (`freeipa: changed=0`,
`aicd-labs: changed=3`, все три — заведомо always-changed задачи: подстановка IP в kubeconfig и
два `Helmwave up`).

## Не проработано (следующие шаги)

- `monitoring_server`/Grafana (нативный OIDC, §4, первый исторически предполагавшийся кандидат) и
  клиентские `reverse_proxy_traefik`/`reverse_proxy_npm`-стенды — вне охвата реализации §7:
  Grafana живёт в другой, не связанной сети; клиентские стенды — на произвольных сетях заказчиков
  без маршрута к платформенной Authelia. Требует отдельной архитектурной проработки (VPN/сетевой
  мост или отдельный per-заказчик экземпляр Authelia), не просто "ещё один потребитель".
- LDAP — обычный `ldap://` (не `ldaps://`/StartTLS) между Authelia и `freeipa` — Authelia логирует
  предупреждение при каждом старте. Сознательное упрощение для внутренней L2-сети одного
  libvirt-хоста, не пересмотрено.
- `access_control` — `one_factor` для `infra-panel`/`radar`, `authorization_policy: one_factor`
  для OIDC-клиентов Semaphore/Gitea (не `two_factor`): TOTP/WebAuthn enrollment потребовал бы
  интерактивной само-регистрации пользователя, не автоматизированной этим контуром.
- Доступ к самому kube-apiserver (`kubectl`) этим ADR не покрыт — область действия ограничена
  приложениями за reverse-proxy (§4). Отдельная идея (Dex или аналог как OIDC-issuer перед
  kube-apiserver) зафиксирована в `ROADMAP.md` №55.
- Статус OIDC-провайдера Authelia (beta 7/8 на 2026-08-26, §5) — проверить перед следующими
  потребителями, не стал ли он GA и не появились ли анонсированные апстримом
  breaking-изменения в consent-policy.
- Каталог `freeipa` пуст (роль сознательно не заводит пользователей/группы, ADR-0011) — реальные
  учётные записи для входа через Authelia нужно заводить вручную (`ipa user-add`) отдельно от
  этой реализации.

## Ссылки

- `ROADMAP.md` №49 — единая авторизация, закрыт этим ADR архитектурно.
- `ROADMAP.md` №55 — единая авторизация для доступа к Kubernetes (kube-apiserver OIDC, Dex или
  аналог) — смежная, но не покрытая этим ADR область (см. «Не проработано» выше).
- `docs/adr/0011-freeipa-role.md` — `freeipa`, каталог пользователей (§1).
- `docs/adr/0012-cicd-platform-architecture.md` §6 — платформенная инфраструктура, куда
  размещается Authelia (§3); §5 — Semaphore как будущий потребитель SSO.
- `docs/adr/0010-backup-agent-role.md` — прецедент `*_backup_tool` (образец для `*_auth_method`,
  §4) и разбора meta-зависимость vs композиция.
- `docs/adr/0004-mysql-ha-replication-role.md` §11 — критерий meta-зависимость vs композиция,
  применённый в §4.
- [Authelia + Traefik ForwardAuth — официальный паттерн](https://www.authelia.com/integration/proxies/traefik/) —
  `/api/authz/forward-auth`, внутренний адрес сервиса, а не `/api/verify` через внешний домен
  (§7, находка №8).
- [Authelia LDAP — FreeIPA](https://www.authelia.com/integration/ldap/freeipa/) —
  `authentication_backend.ldap.implementation: 'freeipa'` (§7).
- `docs/adr/0017-platform-cicd-default-addons.md` — прецедент Helm-релиза вместо роли для
  платформенной инфраструктуры (§6), тот же принцип для Radar/infra-panel.
- [Authelia OpenID Connect 1.0 Provider — roadmap/статус беты](https://www.authelia.com/roadmap/active/openid-connect-1.0-provider/),
  [overview/OpenID Certified](https://www.authelia.com/overview/authorization/openid-connect-1.0/) —
  источники для повторной проверки §5.
