# ADR-0001: Роль `reverse_proxy_npm` (Nginx Proxy Manager)

- **Статус:** Принято
- **Дата:** 2026-07-05
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

В коллекции уже есть два reverse-proxy пути:

- `nginx_multidomain` — нативный nginx, per-domain vhost'ы (`static`/`proxy`), конфигурация как код
  через Ansible-переменные (`nginx_domains`).
- `reverse_proxy_traefik` — Traefik в docker, конфигурация через labels/dynamic-конфиг, dashboard
  с basic-auth пользователями.

Обе роли рассчитаны на технических операторов, работающих через инвентарь/переменные. Возникла
потребность в решении для менее технических операторов/клиентов, которым нужен GUI для управления
proxy-хостами без правки YAML — отсюда Nginx Proxy Manager (NPM, `jc21/nginx-proxy-manager`).

За основу взят публичный пример роли
[`DenAV/nginx-proxy-manager-ansible`](https://github.com/DenAV/nginx-proxy-manager-ansible) (MIT).
Референс реализует **только** management-часть: кастомный модуль `library/npm_proxy.py` вызывает
REST API NPM (`POST /api/tokens` → bearer-токен, затем create/delete proxy host) и не разворачивает
сам контейнер (это отдельный `docker/docker-compose_npm.yml`, поднимаемый вручную). Наша роль должна
закрыть оба куска: и деплой контейнера, и декларативное управление proxy-хостами — под одной ролью
и в соответствии с конвенциями коллекции.

## Решения

### 1. Назначение и место среди существующих ролей

**Решение:** `reverse_proxy_npm` — самостоятельная альтернатива, не замена `nginx_multidomain`/
`reverse_proxy_traefik`. Целевой сценарий — узкоспециализированный: клиенты/операторы, которым нужен
GUI, а не IaC через YAML.

**Последствия:** роль не наследует и не переиспользует шаблоны `nginx_multidomain`
(разная модель конфигурации — см. §2), это полностью независимая роль.

### 2. Конфликт с существующими nginx/traefik-ролями

**Решение:** `reverse_proxy_npm` **взаимоисключающая** с `nginx_multidomain` и
`reverse_proxy_traefik` на одном хосте (конфликт портов 80/443 — NPM сам является nginx-процессом
внутри контейнера и слушает эти порты). Конфликт должен быть явно задокументирован (README роли +
`assert`/предупреждение в самой роли, по аналогии с тем, как P5-31 в ROADMAP закрыл конфликт
`nginx`/`nginx_multidomain`), а не оставлен как подразумеваемое знание.

**Действие при реализации:** добавить в `tasks/main.yml` роли явную проверку/предупреждение, если на
хосте одновременно присутствуют факты/переменные, указывающие на активные
`nginx_multidomain_enabled`/`reverse_proxy_traefik_enabled` (там, где это технически проверяемо), и
зафиксировать конфликт в README роли.

### 3. Модель управления конфигурацией — гибрид

**Решение:** вариант (c) — гибрид из двух слоёв в одной роли:

1. **Deploy-слой** — Ansible разворачивает NPM как docker-контейнер (аналог
   `docker/docker-compose_npm.yml` референса, адаптированный под конвенции коллекции: путь конфигурации
   через `reverse_proxy_npm_config_dir`, управление через `community.docker.docker_compose_v2`, как в
   `reverse_proxy_traefik`).
2. **Management-слой** — отдельные задачи синхронизируют proxy-хосты из репозитория (список в
   `defaults`/`vars` роли) через REST API NPM, по образцу референса: `POST /api/tokens` для
   bearer-токена, затем create/delete через кастомный модуль.

**Действие при реализации:** порт кастомного модуля `npm_proxy.py` в
`plugins/modules/npm_proxy.py` коллекции (FQCN `devops.uslugi.npm_proxy`) — не в `roles/*/library/`,
т.к. это модуль уровня коллекции, а не одной роли (см. уже существующую заготовку
`plugins/README.md`). При портировании сохранить атрибуцию MIT-лицензии оригинала (`DenAV`) в
заголовке файла/README.

### 4. Оркестратор

**Решение:** только `orchestrator: docker`, без выбора docker/k3s (в отличие от
`monitoring_server`). Официальный образ NPM не предполагает systemd/bare-metal установку.

### 5. Секреты и дефолтный admin-доступ

**Решение:** fail-fast без скрытых дефолтов:

- Переменная с паролем администратора (`reverse_proxy_npm_admin_password`) — **обязательная**, без
  значения по умолчанию в `defaults/main.yml`. Роль падает через `assert`, если переменная не задана
  оператором в inventory/group_vars.
- На первом converge (когда NPM ещё имеет дефолтного пользователя `admin@example.com`/`changeme`)
  роль вызывает API `POST /api/tokens` с дефолтными credentials; если это удаётся — выполняет смену
  email/пароля на значения из переменных роли через `PUT /api/users/{id}`. При последующих прогонах
  дефолтный логин не проходит (401) — тогда роль просто аутентифицируется уже новыми credentials
  (идемпотентность через `failed_when`/`when` по коду ответа, аналогично паттерну health-check в
  референсе).

**Отличие от паттерна `monitoring_server`:** там достаточно `assert`, сравнивающего переменную с
известным дефолтом (см. `check-and-install-requirements.docker.yml`), т.к. пароль передаётся через
env при первом старте контейнера. Для NPM смена пароля — это API-вызов, а не переменная окружения,
поэтому нужна task-логика, а не только `assert`.

### 6. Backend БД

**Решение:** по умолчанию — встроенный SQLite (меньше зависимостей, соответствует минимализму
остальных ролей). Внешний MySQL/MariaDB — опциональный тумблер
(`reverse_proxy_npm_db_driver: sqlite|mysql`), аналогично переключателям экспортеров в
`monitoring_agent` (`_enabled`-флаг + отдельный набор `_mysql_*` переменных, подключаемых только при
`db_driver == 'mysql'`).

### 7. Персистентность и бэкапы

**Решение:** bind mount по конвенции коллекции — `reverse_proxy_npm_config_dir` (аналог
`reverse_proxy_traefik_config_dir`), с поддиректориями под `/data` и `/etc/letsencrypt` контейнера.
Интеграция с бэкапами — **вне скоупа ADR**, отдельная задача (роль только гарантирует
предсказуемый путь на хосте, который можно бэкапить внешними средствами).

### 8. Сеть и безопасность admin-панели

**Решение:**

- Порт **81** (admin UI) по умолчанию публикуется только на `127.0.0.1` (bind на loopback), внешний
  доступ — через явный флаг (`reverse_proxy_npm_admin_ui_expose_host: false` по умолчанию).
- Для внешнего доступа к UI роль дополнительно создаёт **внутри самого NPM** (через management-слой,
  §3) proxy-host на собственный порт 81 с доменом вида `npm-ui-{{ ansible_host }}.{{ domain }}`,
  т.е. admin-панель публикуется через сам NPM (с его же Let's Encrypt), а не через сырой проброс
  порта 81 наружу.

### 9. Интеграция с DNS/ACME

**Решение:** интеграция с `infra_dns` (bind9, DNS-01) — **не требуется**. ACME полностью остаётся
внутренней логикой NPM (HTTP-01 через встроенный acme.sh), без завязки на другие роли коллекции.

### 10. Наименование роли

**Решение:** `reverse_proxy_npm` — по аналогии с `reverse_proxy_traefik` (единообразие префикса
`reverse_proxy_*` для всех "готовых прокси-приложений", в отличие от `nginx_multidomain`, которая
рендерит нативный конфиг).

### 11. Тестовое покрытие

**Решение (исходное, см. ревизию 2026-07-26 ниже):** molecule-сценарий закладывается сразу при
реализации роли, а не откладывается (в отличие от исторического долга `reverse_proxy_traefik`,
см. ROADMAP P4/№27). Сценарий — `extensions/molecule/reverse_proxy_npm/`, `driver: docker`
(одноразовый контейнер), по образцу `nginx_multidomain`: converge поднимает NPM + прогоняет
management-слой на тестовый proxy-host, verify проверяет: контейнер запущен, admin-пароль сменён
(API логин дефолтными credentials возвращает 401), тестовый proxy-host создан и отвечает, admin
UI недоступен на внешнем интерфейсе по умолчанию.

**Актуальное решение:** driver сменён на `vagrant`/`libvirt`, добавлена проверка
`admin_ui_expose_host: true` через custom/self-signed сертификат — см. «Ревизия 2026-07-26» ниже.

## Ревизия 2026-07-26: custom-сертификат как фича + переход molecule-теста на libvirt

**Контекст:** §11 закладывал `driver: docker` для molecule-сценария и явно исключал из проверки
`reverse_proxy_npm_admin_ui_expose_host: true` — этот путь дёргает настоящий Let's Encrypt
HTTP-01, а у одноразового тестового контейнера нет ни публичной сети, ни DNS. Владелец роли
попросил пересмотреть тестовое покрытие и получить полноценный тест на libvirt.

**Решение 1 — custom-сертификат как полноценная фича роли, не заглушка для теста.**
`plugins/modules/npm_proxy.py` при `ssl_forced: true` до этой ревизии всегда запрашивал
сертификат у Let's Encrypt (`certificate_id: "new"`). Добавлена альтернатива: оператор может
указать `ssl_provider: custom` (на элементе `reverse_proxy_npm_proxy_hosts` или на
`reverse_proxy_npm_admin_ui_ssl_provider` для self-managed admin UI, см. §8) и пути к готовому
PEM-сертификату/ключу на управляемом хосте (`ssl_certificate_path`/`ssl_certificate_key_path`) —
роль сама создаёт сертификат в NPM (`POST /nginx/certificates`, `provider: other`) и загружает
файлы, передавая полученный `certificate_id` в модуль вместо `"new"`. Основной практический
случай — внутренние домены без публичного DNS (в т.ч. самоподписанные сертификаты), где выпуск
Let's Encrypt заведомо недостижим — то же ограничение, что мешало протестировать
`admin_ui_expose_host` в §11.

**Решение 2 — molecule-сценарий: `driver: docker` → `driver: vagrant`/`libvirt`.**
Смена драйвера сама по себе НЕ решает проблему §11 — libvirt-ВМ по умолчанию тоже в приватной
NAT-сети без публичного DNS, реальный ACME HTTP-01 недостижим и там. Реальное решение — тестировать
SSL/admin-UI-путь через custom/self-signed сертификат (Решение 1), а не через настоящий ACME.
Заодно переход на полноценную ВМ (аналогично `monitoring_server`, `docs/adr/0007`, §11) убирает
docker-in-docker и связанный с ним workaround `storage-driver: vfs` — роль сама Docker не ставит
(`meta/main.yml: dependencies: []`), поэтому `prepare.yml` сценария по-прежнему устанавливает
Docker Engine, но уже как внешний провижининг настоящей ВМ, а не внутри тестового контейнера.
Новый сценарий (`box: cloud-image/ubuntu-24.04`) **заменяет** прежний docker-driver сценарий
целиком, а не сосуществует с ним. `prepare.yml` генерирует самоподписанный сертификат/ключ
(`openssl req -x509`, CLI-утилита — без новой galaxy-зависимости `community.crypto`, это чисто
тестовый инструмент сценария, не часть роли) для домена self-managed admin UI; `verify.yml`
проверяет, что этот proxy-host создан с непустым `certificate_id` и что HTTPS через NPM реально
обслуживается этим сертификатом. Настоящий Let's Encrypt HTTP-01 по-прежнему не тестируется ни
одним driver'ом коллекции — для этого нужен реальный публичный DNS, вне скоупа molecule-тестов.

**Подтверждено полным прогоном `molecule test -s reverse_proxy_npm`
(create → prepare → converge → idempotence → verify → destroy, все шаги зелёные).** По ходу
реализации вскрылись три нюанса NPM API/Ansible, не очевидные из документации заранее:

1. `ansible.builtin.uri` с `body_format: form-multipart` читает `files[].filename` **с
   контроллера**, а не с управляемого хоста, — для сертификата, лежащего на самой ВМ, нужен
   `ansible.builtin.slurp` + передача байтов через `content` (см.
   `manage-custom-certificates-item.yml`).
2. При этом `filename` всё равно нужно указать **рядом** с `content` (произвольное имя, не
   обязано существовать на контроллере — читается с диска только когда `content` не задан) — без
   него NPM (multer на бэкенде) не распознаёт часть как файл и отвечает 400 "Certificate file was
   not provided".
3. `verify.yml` не может проверить HTTPS через `https://127.0.0.1/` с заголовком `Host:` —
   NPM/nginx маршрутизирует TLS по SNI на этапе handshake, до чтения `Host`; понадобилась запись в
   `/etc/hosts` ВМ (`prepare.yml`) и запрос по настоящему доменному имени.

Отдельно (не связано с NPM, но было первым найденным багом): исходный `prepare.yml` унаследовал
`https://download.docker.com/linux/debian` из прежнего docker-сценария (образ на Debian) — с
box'ом Ubuntu 24.04 репозиторий Debian не публикует suite `noble`. Исправлено на
`{{ ansible_distribution | lower }}`, как в `roles/docker/tasks/install-repo.yml`.

## Открытые вопросы / вне скоупа

- Интеграция с бэкапами (§7) — отдельная задача.
- Явный host-level конфликт-чек с `nginx_multidomain`/`reverse_proxy_traefik` (§2) — на этапе
  реализации нужно решить, проверяется ли это автоматически (по занятым портам/фактам) или только
  документируется.
- Версия образа `jc21/nginx-proxy-manager` для пиннинга и политика её обновления — не обсуждалась,
  зафиксировать при реализации `defaults/main.yml` (по аналогии с `reverse_proxy_traefik_image_version`).

## Ссылки

- Референс для management-слоя: https://github.com/DenAV/nginx-proxy-manager-ansible
- `ROADMAP.md` §P5 — прецедент архитектурной развилки `nginx` vs `nginx_multidomain` (тот же класс
  решения: две конкурирующие роли для одной задачи).
- `roles/reverse_proxy_traefik/` — конвенции именования переменных (`*_config_dir`,
  `*_default_password`) и структуры docker-based роли.
