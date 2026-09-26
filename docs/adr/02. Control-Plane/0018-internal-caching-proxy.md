# ADR-0018: кеширующий прокси (Nexus Repository OSS) внутри платформы

- **Статус:** Принято
- **Дата:** 2026-08-28
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

За время работы над ADR-0015 (агентная платформа, GPU-нода `llm1`) и ADR-0017 (мониторинг)
несколько раз находилась одна и та же категория проблемы: конкретный внешний CDN/asset-хост
недоступен из сети платформенных окружений, хотя основной домен резолвится нормально:

- `vagrantcloud.com`/HashiCorp archivist — 404 на скачивание vagrant box.
- `nvcr.io` (NVIDIA container registry) — 403 Forbidden на любом пути.
- `release-assets.githubusercontent.com` — TCP-коннект зависает намертво (не 403/404, а полный
  блэкхол). Этот случай особенно болезненный: `xanmanning.k3s` (роль-зависимость, устанавливающая
  k3s) безусловно перепроверяет checksum k3s-бинаря с GitHub Releases на **каждом** прогоне
  `ansible-playbook site.yml`, даже когда k3s уже установлен и работает — блокирует весь прогон
  на `platform/aicd`, а не только новые задачи.

Запрошена отдельная ADR с целью минимизировать зависимость платформенных окружений от внешней
сети — кеширующий прокси внутри каждого платформенного кластера.

## Решения

### 1. Кеш не чинит уже заблокированные хосты — это не его задача

`nvcr.io`/`release-assets.githubusercontent.com` блокируются на уровне сети/CDN, а не количеством
запросов — кеширующий прокси, встав между платформой и этими хостами, столкнётся с той же
блокировкой при первой попытке заполнить кеш. Для уже заблокированных хостов остаётся отдельный,
уже устоявшийся приём — зеркалирование конкретного нужного артефакта в собственный Gitea
OCI-реестр (ADR-0015 §10, `gitea.<домен>/nvcr.io/...`).

Кеш решает другую, соседнюю задачу: (а) снижает частоту обращений наружу для ресурсов, которые
СЕЙЧАС доступны, но перезапрашиваются на каждом прогоне (Docker/OCI-образы, k3s-бинарь у
`xanmanning.k3s`), и (б) снимает риск транзиентной деградации/будущей блокировки именно этих
ресурсов.

### 2. Целевые кеши под протокол, не общий forward-прокси с SSL-bump

Рассматривался общий прозрачный forward-прокси (Squid + SSL-bump на весь исходящий HTTPS-трафик)
— отклонён: не чинит уже заблокированные хосты (см. §1) точно так же, как и целевой кеш, но
требует раздать собственный CA на каждый клиент платформы — инвазивнее без выигрыша.

### 3. Один сервис — Nexus Repository OSS, не набор из отдельных инструментов

Рассматривался вариант из трёх целевых лёгких сервисов (`registry:2` для Docker/OCI,
`apt-cacher-ng` для apt, nginx `proxy_cache` для GitHub Releases k3s-бинаря) — суммарно ~300-500MB
RAM. Выбран однако **Nexus Repository OSS** — поддерживает proxy-репозитории всех нужных форматов
(`docker`, `apt`, `raw`/generic — для GitHub Releases, плюс `helm` — закрывает будущее расширение
бесплатно) одним общим сервисом/UI/API/хранилищем, вместо трёх независимых конфигураций.

**Компромисс, принятый осознанно:** Nexus OSS официально требует 4GB RAM/2 CPU минимум (JVM;
community-отчёты — от 2GB при экономии) — заметно больше суммы трёх целевых лёгких сервисов. Оба
окружения сейчас на 6144/8192 MiB total, уже поделённых между Gitea/Semaphore/OpenBao/Authelia/
Radar/infra-panel/мониторингом (RAM недавно поднимали именно из-за нехватки места, ADR-0017 §4).
RAM обеих VM поднимается ещё раз, второй раунд (см. §7) — единый сервис на все форматы важнее
экономии RAM.

**Охват v1**: Docker/OCI-образы (`docker` proxy repo → `registry-1.docker.io`), k3s-бинарь+checksum
с GitHub Releases (`raw` proxy repo), apt-пакеты `nvidia-container-toolkit`/gVisor (`apt` proxy
repo, единственные нестандартные apt-репозитории, которые реально ставит `roles/k3s_gpu_node`;
`download.docker.com` не нужен — роль `docker` этими двумя платформами не используется). Helm-репо
(`helm` proxy format — Nexus умеет, но сейчас victoriametrics/grafana/gitea-charts/
fluxcd-community/openbao/skyhook работают без проблем) — явно отложено на следующую итерацию.

### 4. Топология — Helm-релиз в существующем кластере, через Traefik Ingress

Каждое окружение (`platform/aicd`, `platform/aicd-devops-labs-ru`) изолировано в своей сети —
общий Nexus между ними невозможен и не нужен. Один Helm-релиз `nexus` в СУЩЕСТВУЮЩЕМ k3s-кластере
каждого окружения (тот же принцип, что все аддоны — не заводится отдельная VM). Namespace — новый
`cache`.

**Через Traefik Ingress, не NodePort.** `svclb-traefik` в k3s уже слушает хостовые порты 80/443
напрямую на control-plane ноде (тот же под виден и на `llm1`) — `llm1` до своего join в кластер
достаёт control-plane по обычному IP так же, как уже сейчас достаёт `gitea.aicd.devops-labs.ru`
для pull образов (`/etc/hosts`-запись на `llm1` перед `include_role: k3s_gpu_node`, ADR-0015) —
тот же приём, просто ещё одна `/etc/hosts`-строка для хостнейма(ов) Nexus. Отдельный NodePort не
нужен вовсе.

**Два разных хоста — человек vs машины:**
- **`nexus.<домен>`** — человеческий UI (порт Nexus 8081, тот же, что REST API).
- **`nexus-cache.<домен>`** — proxy-repo эндпоинты (`docker`/`apt`/`raw`, обычные анонимные pull
  без аутентификации — как у `registry:2`/`apt-cacher-ng`, иначе containerd/apt/`xanmanning.k3s`
  не заберут содержимое вообще). Docker-формат Nexus по документации требует отдельный
  HTTP-коннектор/порт под repo (не может отдавать Docker Registry V2 API с того же порта, что
  UI/остальные форматы) — точная схема (доп. Service/Ingress-путь под этот коннектор) уточняется
  на этапе реализации.

### 5. Аутентификация UI — LDAP-realm к persistent freeipa, не forwardAuth

Проверено (help.sonatype.com, community.sonatype.com): **Nexus Repository OSS не поддерживает
OIDC/SAML нативно** — это фича Nexus Pro (платной версии). LDAP-realm в OSS есть и полностью
рабочий.

Решение — Nexus напрямую по LDAP к тому же persistent `freeipa`, которым уже пользуется Authelia
(ADR-0013), вместо форвардинга через Authelia (`forwardAuth`-Middleware, применяемый у Radar/
infra-panel). Пользователи логинятся в Nexus своими обычными платформенными учётками, не отдельным
Nexus-local admin-паролем — тот же принцип "один каталог пользователей".

- Новый LDAP bind-аккаунт `svc-nexus` в `freeipa` — тот же приём и тот же play, что уже заводит
  `svc-authelia` (ADR-0013 §3: обычный непривилегированный IPA-пользователь,
  `--password-expiration` далеко в будущем).
- Nexus LDAP realm настраивается идемпотентно через REST API (`POST /service/rest/v1/security/ldap`
  с host/port/baseDn/bind-DN — те же значения, что уже прописаны в `authelia`-values для
  FreeIPA-пресета: `ldap://ipa.<домен>:389`, `base_dn: DC=...`, bind DN вида
  `UID=svc-nexus,CN=users,CN=accounts,DC=...`), затем `PUT /service/rest/v1/security/realms/active`
  — `LdapRealm` добавляется к списку активных realm'ов (не заменяет `Local Authenticating Realm` —
  admin-пользователь Nexus остаётся доступен как fallback).

**Оговорка, которую стоит зафиксировать, а не считать полным SSO:** LDAP-realm даёт "один и тот же
пароль", но не "одну сессию браузера" — в отличие от Gitea/Semaphore/Grafana (нативный OIDC через
Authelia, реальный shared-session SSO), у Nexus остаётся СВОЯ форма логина (просто теперь
принимает платформенные LDAP-креды вместо Nexus-local). Полноценный SSO с общей сессией для Nexus
в OSS-редакции не реализуем без Pro.

### 6. Bootstrap Nexus и клиентская сторона

Bootstrap (idempotent, тот же приём, что OpenBao/Gitea в этом репозитории):

1. Helm-релиз `nexus` (`localrepo/universal-chart` — официального чарта Sonatype не поддерживает,
   тот же приём, что semaphore/homer/authelia): Deployment + PVC (без persistence Nexus теряет все
   proxy-repo настройки при рестарте пода) + Service + Ingress.
2. Первый старт Nexus генерирует случайный admin-пароль в `/nexus-data/admin.password` внутри
   контейнера — читается через `kubectl exec`, сохраняется как реальный пароль в `secret/nexus` в
   OpenBao (идемпотентный GET→404→POST, как `secret/radar`/`secret/grafana`), затем меняется на
   сгенерированный через `POST /service/rest/v1/security/users/admin/change-password`.
3. Идемпотентное создание трёх proxy-repo через REST API (`GET /service/rest/v1/repositories` →
   если нужного имени нет → `POST /service/rest/v1/repositories/<format>/proxy`): `docker-hub-proxy`
   (`remoteUrl: https://registry-1.docker.io`), `k3s-releases-proxy` (формат `raw`, `remoteUrl:
   https://github.com/`), `nvidia-toolkit-apt-proxy`/`gvisor-apt-proxy` (формат `apt`, реальные
   репозитории `roles/k3s_gpu_node`).
4. LDAP-realm — см. §5.

**Обновление по итогам живого прогона `platform/aicd-devops-labs-ru` (2026-08-28), реальные
находки (не гипотетические):** REST-схема Nexus 3.95.3 отличается от community-рекомендаций,
на которые изначально опирался этот раздел — `POST .../repositories/docker/proxy` требует
дополнительный обязательный блок `dockerProxy.indexType` (иначе 400), `PUT
.../security/realms/active` не принимает `NexusAuthorizingRealm` (такого realm в этой версии не
существует — актуальный список только `NexusAuthenticatingRealm`/`LdapRealm`/токен-реалмы форматов,
проверено через `GET /service/rest/v1/security/realms/available`), а без `force_basic_auth: true`
у `ansible.builtin.uri` POST/PUT-запросы с телом падали 401 (GET-проверки "проходили" 200 случайно,
за счёт анонимного чтения `/repositories`, а не за счёт реальной проверки пароля). Все три
исправлены в коде. Отдельно подтверждено эмпирически: анонимный доступ к `apt`-proxy репозиториям
(`nvidia-toolkit-apt-proxy`/`gvisor-apt-proxy`) действительно не работает (401 Unauthorized) — в
отличие от `docker`/`raw`-форматов, которые анонимный pull проксируют корректно. Откат на прямой
источник для этих двух репозиториев (заранее заложенный этим пунктом) реализован через
`block`/`rescue` в `roles/k3s_gpu_node/tasks/{nvidia,gvisor}.yml` и подтверждён живым прогоном —
GPU-нода `llm1` собирается полностью, просто без выгоды от кеша для этих двух apt-репозиториев.
Причина 401 именно для `apt`-формата (в отличие от `docker`/`raw`) не расследовалась дальше —
не блокирует остальное, как и предполагалось изначально.

Клиентская сторона:

- **Docker/OCI** — `/etc/rancher/k3s/registries.yaml` на каждом k3s-узле (control-plane + `llm1`):
  `mirrors."docker.io".endpoint` на docker-коннектор `nexus-cache.<домен>` (нативный механизм
  containerd/k3s, ничего нового не изобретается) — `template` + `systemctl restart k3s`/
  `k3s-agent` handler (тот же приём, что уже использован для перезапуска после смены CA, ADR-0015).
- **apt** — source-list на `nvidia.github.io`/`storage.googleapis.com` в
  `roles/k3s_gpu_node/tasks/gvisor.yml`/`nvidia.yml` переписываются на `nexus-cache.<домен>` через
  новую опциональную переменную (дефолт пусто = текущее прямое поведение, чтобы роль оставалась
  рабочей вне этих двух платформ).
- **k3s-бинарь** — `xanmanning.k3s` уже имеет override-переменные `k3s_binary_url`/`k3s_hash_url`
  (`vars:` блок у `include_role: xanmanning.k3s` в `site.yml`) — переопределяются на
  `http://nexus-cache.<домен>/repository/k3s-releases-proxy/...`, без правок сторонней роли.

### 7. Bootstrap-порядок и второй раунд RAM

Nexus — Helm-релиз, требует уже работающего k3s. На абсолютно новом окружении первый прогон
`xanmanning.k3s`/apt на control-plane неизбежно идёт напрямую (курица-яйцо, Nexus ещё нет) — не
регрессия. Начиная со ВТОРОГО прогона (Nexus однажды успешно поднялся) — трафик идёт через него,
включая безусловную re-verification `xanmanning.k3s` при каждом следующем запуске (текущая боль,
которая чинится). Оба существующих окружения уже забутстрапены — эффект сразу с первого прогона
после внедрения.

RAM — второй раунд апгрейда (ADR-0017 §4 уже поднимал один раз под мониторинг):
`platform/aicd/terraform/vms.tf`: `cicd` 6144→10240 MiB (+4096 под Nexus);
`platform/aicd-devops-labs-ru/terraform/variables.tf`: `aicd-labs` 8192→12288 MiB (+4096). Тот же
живой процесс, что в прошлый раз — `tofu plan` → graceful shutdown гостя → `tofu apply` →
`free -h`/`kubectl get nodes`, по одной VM с подтверждением перед каждым apply.

### 8. Интеграция с infra-panel

Новая ручная ссылка на `https://nexus.<домен>` в `infra_panel_extra_services` (тот же механизм,
что уже используется для остальных ручных ссылок homer, ADR-0008).

### 9. Raw-hosted репозиторий `internal-releases` для собственных артефактов

Кроме proxy-репозиториев (§6, кешируют СТОРОННИЕ источники) у платформы появилась потребность
публиковать СВОИ артефакты — первый случай, roles/monitoring_agent/ipa_exporter: бинарь
`freeipa-exporter` из публичного GitHub-релиза v1.0.0 требовал GLIBC_2.35+, а Rocky 9 (единственная
ОС для freeipa, ADR-0011) даёт только glibc 2.34 — сервис уходил в бесконечный crash-loop
(ROADMAP.md P0-57). Пересобран под glibc 2.34 (сборочный стейдж `pyinstaller-artifact` в
`ADDONS/exporters/freeipa_exporter/Dockerfile`, база `python:3.12-slim-bullseye`, glibc 2.31 —
запас совместимости, а не подгонка ровно под 2.34) и опубликован не в новый публичный GitHub-релиз
(это отдельное решение — публикация публичного контента, не в скоупе этой задачи), а в собственный
raw-hosted репозиторий `internal-releases` того же Nexus, идемпотентно создаваемый REST-вызовом
(`POST /service/rest/v1/repositories/raw/hosted`, `writePolicy: ALLOW_ONCE` — путь неизменяем
после первой публикации, новая версия — новый путь/имя файла). Сама публикация артефакта — ручной
одноразовый шаг (`PUT /repository/internal-releases/<путь>`), тем же принципом, что сборка/push
`dcgm-exporter` в Gitea registry (ADR-0017): site.yml владеет только идемпотентным СУЩЕСТВОВАНИЕМ
репозитория, не его содержимым.

**Живым прогоном (2026-09-02) найдено: anonymous access у этого Nexus глобально выключен**
(`GET /service/rest/v1/security/anonymous` → `enabled: false`) — дефолт свежей Community Edition,
не осознанный выбор этого репозитория. Все три proxy-репозитория §6 УЖЕ работали не за счёт
"anonymous без всякой аутентификации", как предполагал текст §6/клиентской стороны выше, а
по какой-то иной причине (не расследовано отдельно — не блокирует их, apt-путь и так имеет
block/rescue fallback на прямой источник, docker/raw-путь ни разу не подтверждался при
реальном cache hit, только при успешном fallback). Для `internal-releases`, у которого fallback
на "прямой источник" не существует по определению (это не прокси, а единственный источник),
anonymous-401 обязателен к решению: заведён scoped read-only пользователь `svc-ipa-exporter-reader`
с ролью `internal-releases-reader` (только `nx-repository-view-raw-internal-releases-{read,browse}`,
privileges auto-создаются Nexus'ом вместе с самим репозиторием) — не общее включение anonymous на
весь Nexus, тот же принцип наименьших привилегий, что уже применён для scoped VAULT_TOKEN policy
gomplate/helmwave (см. ROADMAP/предыдущие ADR). Пароль — новое поле `internal_releases_reader_password`
в `secret/nexus` (тот же идемпотентный приём, что остальные поля секрета).

**Второй живой находка того же прогона: Nexus Community Edition требует явного принятия EULA
через REST (`POST /service/rest/v1/system/eula`, `{accepted: true, disclaimer: <точный текст из
GET>}`) прежде чем разрешит ЛЮБУЮ загрузку компонента** (`PUT`/upload — 403 "You must accept the
End User License Agreement... through the onboarding wizard or REST API" без этого; POST без
поля `disclaimer`, только `{accepted: true}` — 500 "Invalid EULA disclaimer", нужен точный текст).
Принято один раз вручную (администратором, не автоматизировано в site.yml — акт согласия с
условиями стороннего ПО не тот же класс действия, что REST-конфигурация; см. также диалог с
пользователем перед выполнением). Управление репозиториями (`GET`/`POST .../repositories`,
работавшее весь §6) EULA не требовало — только фактическая загрузка контента.

**Ipa_exporter-путь этой задачи столкнулся с ещё одним найденным вживую структурным ограничением:**
`svc-monitoring`/ipa_exporter настраивается в play `freeipa_hosts`, который по файлу идёт РАНЬШЕ
play "Platform CI/CD infra (продолжение)", где и происходит вся Nexus REST-конфигурация (сам
Nexus не готов к REST до того, как Authelia/freeipa существуют — тот же порядок, что §7). На
первом прогоне после включения фичи `svc-ipa-exporter-reader` ещё не существует — задача качает
бинарь падает 401. Без обработки такая ошибка не просто пропускает один экспортёр — она
ОСТАНАВЛИВАЕТ ВЕСЬ ОСТАЛЬНОЙ ПРОГОН ПЛЕЙБУКА (подтверждено эмпирически: ни одна последующая play
не выполняется вообще, включая ту, что и создала бы недостающего пользователя — вечный тупик).
Решение — `block`/`rescue` вокруг `include_role: monitoring_agent` в freeipa play (тот же
принцип бутстрап-толерантности, что §7 и apt block/rescue в `roles/k3s_gpu_node`): на первом
прогоне ipa_exporter не устанавливается (node_exporter — успевает, он раньше в роли), rescue
логирует ожидаемую причину и не блокирует остальной прогон; второй прогон (Nexus/пользователь уже
существуют от первого) проходит без rescue.

После починки glibc бинарь (v1.0.1) стартовал, но падал на первом же реальном LDAP-запросе к
FreeIPA — второй, независимый живой баг (ROADMAP.md P0-58), уже не инфраструктурный, а в коде
самого экспортёра (`ADDONS/exporters/freeipa_exporter/code/freeipaserver.py`): `_count_users`/
`_count_hostgroups` читали операционный атрибут `numSubordinates`, который FreeIPA отдаёт только
привилегированным bind'ам — обычный `svc-monitoring` получал запись вовсе без этого атрибута
(`KeyError`, не ошибку поиска). Исправлено переходом на прямое перечисление записей
(`SCOPE_ONELEVEL` + `len(results)`), тем же паттерном, что уже работал в `_count_groups`/
`_count_hosts` того же файла. Пересобран как v1.0.2, опубликован по новому пути в тот же
`internal-releases` (`writePolicy: ALLOW_ONCE` — путь v1.0.1 остаётся, просто больше не
используется). Итог подтверждён живым прогоном до конца: `ipa_exporter.service` — `active`
(не crash-loop), `curl :9189/metrics` отдаёт реальные `ipa_users`/`ipa_hosts`/`ipa_up 1`, таргет
`ipa_exporter`/`freeipa` в vmagent — `health: up` с ненулевыми `lastSamplesScraped`.

### 10. Живой прогон `platform/aicd` (2026-09-03) — первая верификация, три реальных находки

ВМ этого окружения были выключены с момента написания §7-9 выше — весь текст до этого момента
был провалидирован только `ansible-lint`/`--syntax-check`, README прямо фиксировал «не проверено
реальным прогоном». ВМ подняты обратно (`tofu apply`, `platform/aicd/terraform`, дрейф —
только `running: false → true` и отложенный апгрейд RAM `cicd` 6144→10240 MiB из §7, реальные
диски не пересоздавались), `site.yml` прогнан до полностью чистого состояния
(`failed=0`/`rescued=0` на обоих хостах). По пути найдены и исправлены три независимых бага —
ни один не специфичен для этого окружения по сути, все три — родовые баги, которые первый живой
прогон был первым шансом поймать:

1. **`kubernetes.core.k8s_exec` не уважал явный `NO_PROXY` — потому что его не было.** Единственная
   Nexus-bootstrap-задача, читающая `admin.password` из пода через `k8s_exec` (websocket, а не
   обычный REST), не имела своего блока `environment: {NO_PROXY, no_proxy}`, в отличие от всех
   соседних `uri`-задач и от `kubernetes.core.k8s_info`/`k8s` (Python kubernetes client для REST не
   ходит через системный прокси, `k8s_exec` — честно ходит, CONNECT-тоннель через локальный прокси
   `127.0.0.1:8118` этого control-хоста отвечал 503, `websocket-client` не восстанавливается).
   `platform/aicd-devops-labs-ru` историчeски не ловил эту ошибку не потому, что был написан
   правильно, а по совпадению — его сеть (`10.10.10.0/24`) уже входит в глобальный `NO_PROXY`
   control-хоста. Исправлено в обоих `site.yml` одинаково (явный `NO_PROXY` с адресом API-сервера).
2. **`internal-releases`-артефакт `freeipa-exporter` v1.0.2, пересобранный локально тем же
   `docker build --target pyinstaller-artifact` из §9, был упакован с бинарём в КОРНЕ архива** —
   `roles/monitoring_agent/tasks/systemd-ipa-exporter.yml` (`unarchive`, `include: "*/freeipa-exporter"`
   + `--strip-component=1`) ждёт бинарь ВНУТРИ поддиректории архива (типичный
   `goreleaser`-тарбол-конвенция — то, как был упакован уже верифицированный артефакт на
   `aicd-devops-labs-ru`, откуда и была скопирована сама задача `unarchive`, без переноса этого
   неявного требования в комментарии). Итог первого прогона —
   не crash-loop и не 401, а куда менее очевидный `"Not found in archive"`. Из-за
   `writePolicy: ALLOW_ONCE` сломанный компонент нельзя было просто перезаписать —
   потребовался явный `DELETE /service/rest/v1/components/{id}` (id — из
   `GET /service/rest/v1/search?repository=...&name=...`, при этом сам `name` в ответе Nexus
   содержит ведущий `/`: `/freeipa-exporter/freeipa-exporter-1.0.2.linux-amd64.tar.gz`) перед
   повторной заливкой. Исправлено переупаковкой (бинарь внутри `freeipa-exporter-1.0.2-linux-amd64/`)
   и обновлением `monitoring_agent_ipa_exporter_binary_checksum` в `site.yml` на checksum новой
   версии архива.
3. **Включение `ipa_exporter` в `site.yml` не сопровождалось вторым таргетом в
   `helm/values/platform/namespaces/monitoring/vm/extra-objects.yaml`** — файл ранее осознанно
   содержал только `node-exporter` (порт 9100), с комментарием «добавить обратно, когда бинарь
   будет пересобран», но сам факт включения фичи не добавил вторую запись `staticConfigs`
   автоматически (это два независимых файла в разных частях репозитория — `site.yml` описывает
   ЧТО ставится НА хост, `extra-objects.yaml` — ЧТО из этого хоста ходит СКРЕЙПИТЬ vmagent).
   Итог — `ipa_exporter.service active`, `curl :9189/metrics` с самого хоста отдаёт реальные
   метрики, но vmagent о таргете вообще не знал (не `down`, а полностью отсутствовал в
   `/api/v1/targets`). Исправлено добавлением второго `staticConfigs`-элемента (порт 9189,
   `job: ipa_exporter`), применено live через scoped `helmwave up --tags vm`.

Итог, подтверждённый после всех трёх фиксов: `vmagent` — оба таргета (`ipa_exporter`,
`node-exporter`) `health: up`; прямой `GET /api/v1/query?query=ipa_up` на VMSingle —
`{instance="freeipa", job="ipa_exporter"} 1`; `node_uname_info{job="node-exporter"}` содержит и
`cicd`, и `freeipa`/`ipa.aicd.platform` под одним job (тот же приём унификации, что уже применён
на `aicd-devops-labs-ru`, docs/adr/0017-platform-cicd-default-addons.md §5); `GrafanaDashboard`
`freeipa-exporter` — `DashboardSynchronized`, доступен через собственный REST API Grafana.

## Явно вне периметра (v1)

- Кеширование Helm-репозиториев — Nexus умеет (`helm` proxy format), но сейчас работает без
  проблем, следующая итерация.
- Общий Nexus между двумя окружениями — топологически невозможно (разные сети), не нужно.
- Полноценный SSO с общей сессией браузера для Nexus (см. §5) — недоступно в OSS-редакции.

## Верификация

1. `ansible-lint --profile production` + `--syntax-check` на обоих `site.yml` и на изменённой
   `roles/k3s_gpu_node`.
2. RAM: `tofu plan` перед apply (чистый дифф), подтверждение перед каждым apply, `free -h` после
   старта на обеих VM.
3. Живой прогон: релиз `nexus` `Running`/PVC `Bound`, оба Ingress-хоста отвечают, три proxy-repo
   реально созданы (`GET /service/rest/v1/repositories`), LDAP-realm активен, логин в UI
   платформенной учёткой работает.
4. `docker`: pull ранее не кешированного образа на control-plane после `registries.yaml` —
   `crictl images`/лог Nexus показывают реальный проксированный pull.
5. `apt`: `apt-get update`/`install` на `llm1` для nvidia-container-toolkit/gVisor — трафик реально
   идёт через Nexus, либо явный откат на прямой доступ, если apt-proxy-format не сработал с
   HTTPS-бэкендом (см. §6, п.3).
6. Повторный `ansible-playbook site.yml` — задача `xanmanning.k3s`/"Ensure the k3s hashsum is
   downloaded" резолвится через Nexus `raw`-proxy, не напрямую в GitHub (успешность самого шага на
   сети, где GitHub release-assets заблокирован, — уже достаточное доказательство).

## Ссылки

- `docs/adr/0015-ai-agent-platform-architecture.md` §10 — приём зеркалирования блокированных
  хостов (`nvcr.io`) в собственный Gitea OCI-реестр — для того, что кеш принципиально не решает.
- `docs/adr/0017-platform-cicd-default-addons.md` §4 — первый раунд апгрейда RAM, тот же живой
  процесс resize повторяется здесь вторым раундом.
- `docs/adr/0013-unified-auth-architecture.md` §3 — паттерн LDAP bind-аккаунта (`svc-authelia`),
  повторённый здесь для `svc-nexus`.
- `docs/adr/0008-infra-panel-role.md` — механизм ручных ссылок `infra_panel_extra_services`.
