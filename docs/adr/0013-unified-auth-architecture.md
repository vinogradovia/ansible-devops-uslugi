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

### 9. Реальный клик-тест логина (не только проверка кнопки) выявил 5 багов OIDC (2026-08-26)

Прежняя «Проверено реальным прогоном» (§7/§8) подтверждала только *наличие* кнопки OIDC-входа
(`/api/auth/login` отдаёт список провайдеров, консент-экран открывается), но не полный цикл до
рабочей сессии в самом приложении. Пользователь запросил проверку через реальный клик в браузере
(Chrome DevTools MCP) — вскрылось 5 независимых багов, часть из них маскировала следующую (баг
исправлялся, логин продвигался на шаг дальше и упирался в следующий). Все присутствовали в обоих
окружениях с самого §7 — ADR был помечен «реализовано» преждевременно, до факта наличия
работающего логина.

1. **Неверный gomplate-datasource — оба потребителя отправляли строку `"<no value>"` вместо
   OAuth2 client secret.** `defineDatasource "vault"` в `gitea/values.yaml`/`semaphore/values.yaml`
   указывает на `secret/data/gitea`/`secret/data/semaphore` (для СВОИХ секретов — admin-пароль,
   cookie-ключи), но `gitea_client_secret`/`semaphore_client_secret` живут в `secret/authelia`
   (ADR §3). `(ds "vault").data.gitea_client_secret` резолвился в отсутствующее поле и Go-шаблоны
   молча подставляли литеральную строку `"<no value>"` (ровно 10 символов) — оба сервиса
   отправляли эту строку как client_secret, Authelia закономерно не находила соответствия.
   Найдено сравнением длины поля в живом поде (10 вместо ожидаемых 48) и прямым сравнением с
   реальным секретом из OpenBao. Исправлено вторым именованным датасорсом
   `defineDatasource "vault_authelia" "vault:///secret/data/authelia"` в обоих файлах —
   единственный способ прочитать поле из другого KV-пути в рамках одного gomplate-рендера.
2. **Semaphore: `invalid_client` при обмене authorization code на токен.** Authelia без явного
   `token_endpoint_auth_method` регистрирует OIDC-клиент с дефолтным `client_secret_basic`
   (HTTP Basic Auth), а Semaphore (v2.19.8) на этот эндпоинт отправляет credentials методом
   `client_secret_post` (в теле запроса) — Authelia отвечает `invalid_client`
   (`"token_endpoint_auth_method ... does not allow this method"`). Исправлено явным
   `token_endpoint_auth_method: 'client_secret_post'` на клиенте `semaphore`.
3. **`email`/`email_verified` по спецификации OIDC доступны только через `/userinfo`, не
   встраиваются в сам ID Token.** И Semaphore, и Gitea читают `email` именно из ID Token, не
   делают отдельный запрос к userinfo — падали с `"claim 'email' missing or has bad format"`,
   несмотря на то что LDAP-атрибут `mail` реально существует и виден bind-аккаунту svc-authelia
   (проверено `ldapsearch` под его же bind — anonymous bind атрибут не показывает вовсе, это
   отдельная защита FreeIPA, не связанная с багом). Исправлено `claims_policies` (официальный
   механизм Authelia) — принудительное копирование `email`/`email_verified` в ID Token.
4. **Gitea дополнительно требует claim `nickname`, которого Authelia не производит вовсе.**
   `"Auto Registration ... returned missing fields: email,nickname"`. `nickname` не входит в
   стандартный набор claim'ов Authelia — заведён через `custom_claims` как алиас на атрибут
   `username` (НЕ `preferred_username` — это имя claim'а, а не атрибута; Authelia явно
   валидирует и отказывается стартовать с `"claim ... has an attribute name ... which is not a
   known attribute"` при попытке использовать имя claim'а вместо имени атрибута).
5. **Gitea по умолчанию запрашивает у Authelia только scope `openid`**, не `profile`/`email`
   (подтверждено экраном согласия — одна строка вместо трёх/четырёх, как у Semaphore) — Authelia
   не выдаёт claim'ы, на которые у клиента нет РАЗРЕШЁННОГО и ЗАПРОШЕННОГО scope, независимо от
   `claims_policies` (claims_policies лишь решает, КУДА положить УЖЕ разрешённый claim, а не
   выдаёт на него право). Значение чарта Gitea `oauth[].scopes` — universal generic passthrough
   (`gitea.oauth_settings` в `_helpers.tpl` чарта: каждый ключ мапы становится `--<kebab-case>
   <value>` флагом CLI `gitea admin auth add-oauth`/`update-oauth`, задокументированный
   `--scopes "Additional scopes to request"`) — установлено `scopes: "profile email nickname"`.
   `nickname` — custom scope Authelia, тоже должен быть явно объявлен и разрешён клиенту.

**Сквозная методологическая находка:** ConfigMap-based конфиги (`config.yml` homer/`infra-panel`,
`configuration.yml` Authelia) монтируются в под с `subPath` — Kubernetes принципиально не
обновляет `subPath`-смонтированные файлы при изменении ConfigMap, **и это не чинится
автоматическими рестартами контейнера** (например, в `CrashLoopBackOff`) — под должен быть
именно **пересоздан** (`kubectl rollout restart` создаёт новый Pod, не просто новый контейнер в
старом). Несколько раз за эту сессию правка казалась "не подействовавшей" именно по этой причине
(живой под продолжал работать на конфиге из момента своего СОЗДАНИЯ, а не последнего изменения
ConfigMap) — при любой будущей правке `configMaps`-секций `authelia`/`infra-panel` values.yaml
это нужно держать в голове по умолчанию, не как редкое исключение.

**Проверено реальным клик-тестом до конца (Chrome DevTools MCP, оба окружения):** тестовый
пользователь каталога (`ipa user-add`, `admin` не годится — учётке спецаккаунта FreeIPA
запрещён атрибут `mail`, `"attribute 'mail' not allowed"`) успешно проходит полный цикл
Authelia → consent → возврат в приложение → рабочая сессия — и для Semaphore (`New Project`
после логина), и для Gitea (аккаунт auto-registered, `nickname` = LDAP username, попадает на
`Панель управления`).

### 10. UX-доработка входа: прямые OIDC-ссылки в infra-panel + `consent_mode: pre-configured` (2026-08-27)

После §9 логин технически работал целиком, но с двумя лишними шагами на каждый визит:

1. **Ссылки Gitea/Semaphore в `infra-panel` вели на обычную страницу логина сервиса**, где
   пользователю нужно было ещё найти и нажать кнопку «Sign in with Authelia» — истоники подтверждены
   чтением исходников (`gitea` — `routers/web/web.go`, `m.Group("/oauth2", ...).Get("/{provider}",
   auth.SignInOAuth)`, где `{provider}` — имя auth source, то же `authelia`, что уже используется в
   `redirect_uris`; `semaphore` — `api/router.go`,
   `publicAPIRouter.HandleFunc("/auth/oidc/{provider}/login", oidcLogin)`, где `{provider}` — id
   клиента). Ссылки в `infra-panel/values.yaml` (оба окружения) заменены на
   `https://gitea.<domain>/user/oauth2/authelia` и
   `https://semaphore.<domain>/api/auth/oidc/authelia/login` — клик сразу либо логинит (если сессия
   Authelia жива), либо показывает форму логина/consent, без промежуточной страницы сервиса.
   `radar`/`infra-panel` сами этого не требовали — `forwardAuth` и так перехватывает запрос до
   рендера страницы.
2. **Authelia по умолчанию (`consent_mode: 'explicit'`) переспрашивает согласие на каждый вход** —
   consent-решение не переживает даже собственную сессию входа, не говоря уже про новую. Добавлено
   `consent_mode: 'pre-configured'` + `pre_configured_consent_duration: '1 year'` (значение
   зафиксировано как дефолт для всех новых OIDC-клиентов платформы, не разовая настройка) обоим
   клиентам (`gitea`, `semaphore`) на обоих окружениях. Пользователю показывается дополнительный
   чекбокс «Запомнить разрешения» на экране consent — если отметить его при согласии, повторные
   входы (в пределах `pre_configured_consent_duration`, привязано к
   subject+client_id+scopes+audience) полностью пропускают экран consent.

**Проверено реальным клик-тестом** (`platform/aicd-devops-labs-ru`): после первого входа с отмеченным
«Запомнить разрешения» повторный цикл logout(Semaphore)/`/api/auth/oidc/authelia/login` привёл
прямо в приложение без единого промежуточного экрана.

### 11. Найден и разобран баг: разные пользователи SSO "схлопывались" в один аккаунт Gitea (2026-08-27)

Пользователь заметил: после входа в Gitea интерфейс показывал `testuser`, хотя на самой Authelia
активная сессия была под другим аккаунтом. Полное расследование заняло несколько раундов
диагностики (см. ниже) и завершилось однозначным, воспроизводимым выводом.

**Что НЕ было причиной** (проверено и исключено экспериментально):
- Authelia выдаёт полностью корректные, уникальные claim'ы на каждого пользователя — проверено
  дважды прямым HTTP-обменом authorization code → id_token/`/api/oidc/userinfo` в обход браузера
  и Gitea (`sub`/`email`/`nickname` были верны и различались между пользователями).
- Кэш "прямого callback" (`goth`/Gitea пытается переиспользовать access_token без повторного
  похода к провайдеру) — не подтвердился: server-side логи Gitea показали полный цикл
  `307 → authorize → /callback?code=...` при КАЖДОЙ попытке, не "короткий" путь.

**Настоящая причина — простая, но некритично задокументированная особенность Gitea**:
`GET /user/logout` в Gitea 1.23.4 возвращает **404** (в этой версии logout — CSRF-защищённый
`POST` через форму в UI, а не GET-ссылка) — то есть любая попытка "разлогиниться" переходом по
URL молча ничего не делает, активная сессия Gitea остаётся прежней. Из-за этого при первой же
попытке войти под ДРУГИМ пользователем Authelia (пока сессия Gitea была ещё жива под старым
пользователем) сработала штатная логика Gitea: `routers/web/auth/oauth.go`,
`SignInOAuthCallback` — если после OIDC-обмена локальный аккаунт для нового external ID ещё не
существует (`u == nil`) **и при этом `ctx.Doer != nil`** (уже есть активная сессия), Gitea не
создаёт нового пользователя, а **привязывает новую внешность к УЖЕ ЗАЛОГИНЕННОМУ аккаунту**
(`externalaccount.LinkAccountToUser`) и редиректит на `/user/settings/security`. Эта привязка
навсегда сохраняется в таблице `external_login_user` (по `external_id` = OIDC `sub`) — поэтому
даже полностью "чистые" повторные попытки (свежие cookies, честный `curl`-round-trip без единого
браузерного артефакта) продолжали резолвиться в тот же неверный локальный аккаунт: Gitea просто
находил уже существующую (ошибочную) привязку и не пытался создать новую.

Диагностика подтверждена прямым чтением SQLite базы Gitea
(`kubectl cp .../gitea.db`, `sqlite3` на k3s-ноде — в самом контейнере `sqlite3`/`apk` недоступны
из-за непривилегированного пользователя образа): строка `external_login_user` для второго
тестового пользователя содержала абсолютно верные `email`/`name`/`nick_name`, но `user_id`
указывал на ПЕРВОГО пользователя.

**Исправление — не код, а процедура**: разлогиниваться из Gitea нужно через реальную кнопку
«Выход» в UI (или `POST /user/logout` с CSRF-токеном), а не переходом на `GET /user/logout`.
Проверено полным циклом на живом стенде: после честного logout через UI и переключения сессии
Authelia на другого пользователя (`testuser2`, специально заведённый в freeipa для этого теста)
Gitea корректно (а) создала для него отдельный, новый локальный аккаунт при первом входе, и (б)
при обратном переключении на первого пользователя (снова честный logout + новый логин) вернула
именно его собственный, не перепутанный аккаунт.

**Восстановление уже испорченного состояния**: если привязка уже "приклеилась" не к тому
аккаунту (как в этом инциденте), достаточно зайти под ПОСТРАДАВШИМ (реальным) пользователем в
`/user/settings/security` → «Управление привязанными аккаунтами» → «Удалить» у записи `authelia`
— это стирает ВСЕ external-login-записи этого пользователя для источника (можно удалить лишнюю,
привязка самого пользователя восстановится автоматически при следующем корректном входе).

**Не является багом ansible/Authelia/архитектуры этой платформы** — чисто особенность (можно
сказать, дефект UX) самой Gitea 1.23.4: `GET /user/logout` тихо не работает, и это в сочетании со
штатной (документированной) политикой "auto-link при уже открытой сессии" даёт неожиданный,
трудный для диагностики результат. Стоит завести отдельную заметку/предупреждение в README о том,
что программные интеграции (скрипты, автоматизация), которые логинятся под разными
пользователями Gitea в одной cookie-сессии, обязаны использовать настоящий `POST`-logout, а не
`GET /user/logout`.

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
