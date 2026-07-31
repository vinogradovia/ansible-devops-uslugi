# Архитектура роли `nginx_multidomain`

> Статус документа: описывает **фактическую реализацию** роли на текущий момент, а не
> первоначальный замысел. Обновлено по итогам ревью кода (см. `ROADMAP.md`, пункт P5-32) —
> предыдущая версия документа описывала более широкую задуманную архитектуру
> (`snippets/*.j2`, `_default_locations`, `logrotate.yml` и т.д.), часть которой при реализации
> была либо упрощена, либо не реализована вовсе. Актуальный список пробелов — в разделе 8.
>
> Роль по-прежнему **реализована частично** и не готова для production без учёта раздела 9
> (известные баги/риски).

Ansible-роль для управления Nginx на серверах shared hosting с поддержкой множества доменов,
разных типов сайтов (`static`, `proxy`), TLS (готовые сертификаты; Let's Encrypt — не
реализован), rate limiting и proxy cache зон.

---

## 1. Фактическая структура роли

```
nginx_multidomain/
├── defaults/
│   └── main.yml                      # единственный defaults-файл; vars/Debian.yml,
│                                      # vars/Ubuntu.yml не созданы — install_repo.yml
│                                      # строит имя дистрибутива инлайн через ansible_distribution
├── tasks/
│   ├── main.yml                      # оркестрация, порядок — см. раздел 3
│   ├── install_package.yml           # nginx_install_method: package
│   ├── install_repo.yml              # nginx_install_method: repo (nginx.org)
│   ├── rate_limit_zones.yml
│   ├── proxy_cache_zones.yml
│   ├── conf_d_files.yml
│   ├── certificates_custom.yml       # только ssl.mode: custom
│   ├── stub_status.yml
│   └── vhosts.yml                    # цикл по nginx_domains (type: static|proxy)
├── templates/
│   ├── rate-limit-zones.conf.j2
│   ├── proxy-cache-zones.conf.j2
│   ├── stub_status.conf.j2
│   └── vhost/
│       ├── static.conf.j2
│       └── proxy.conf.j2
└── handlers/
    └── main.yml                      # fail-fast: nginx -t → reload
```

Этот документ — `docs/adr/0003-ginx-multidomain-role.md` в корне коллекции, а не внутри роли;
каталог `roles/nginx_multidomain/docs/` пуст (см. ROADMAP.md, пункт P3-25 — раньше там лежали
нерабочие черновики-артефакты первой скелетной генерации роли, удалены).

Отсутствует по сравнению с первоначальным замыслом (и не появилось взамен): `vars/Debian.yml`/
`vars/Ubuntu.yml`, `templates/nginx.conf.j2`, `templates/snippets/*.j2`, `templates/logrotate.j2`,
`templates/vhost/php-fpm.conf.j2`. `meta/main.yml` и `extensions/molecule/nginx_multidomain/`
с тех пор появились (ROADMAP.md, таблица P4). Подробности — раздел 8.

Layout конфигов — классический Debian-стиль: `sites-available/<domain>.conf` → symlink в
`sites-enabled/`. Роль **не подключает** `sites-enabled/*` в главном `nginx.conf` — это должно
уже быть в стоковом конфиге пакета nginx (роль не проверяет и не гарантирует это; подробнее —
раздел 9.4).

---

## 2. Схема переменных

### 2.1. Установка Nginx

```yaml
nginx_install_method: "package"       # package | repo
nginx_repo_release_channel: "stable"  # stable | mainline (для install_method: repo)
nginx_service_name: "nginx"
nginx_user: "www-data"
nginx_group: "www-data"
```

### 2.2. Пути

```yaml
nginx_conf_dir: "/etc/nginx"
nginx_sites_available_dir: "{{ nginx_conf_dir }}/sites-available"
nginx_sites_enabled_dir: "{{ nginx_conf_dir }}/sites-enabled"
nginx_confd_dir: "{{ nginx_conf_dir }}/conf.d"
nginx_htpasswd_dir: "{{ nginx_confd_dir }}/htpasswd"   # каталог используется в шаблоне, но
                                                        # ничего в него не пишет (см. 8.3)
nginx_log_dir: "/var/log/nginx"
```

### 2.3. Единый список доменов (`nginx_domains`)

Реализованы `type: static` и `type: proxy`. `type: php_fpm` в схеме упоминается как задуманное
значение, но **не поддержан циклом в `tasks/main.yml`** — домен с таким `type` будет молча
пропущен (условие `domain.type in ['static', 'proxy']`), без предупреждения.

```yaml
nginx_domains:
  - name: example.com
    aliases: [www.example.com]
    type: static                     # static | proxy  (php_fpm объявлен, но не обрабатывается)
    enabled: true                    # по умолчанию true, если не указано
    root: /var/www/example.com/public   # обязателен для static; для proxy — опционален
    index_files: ["index.html"]      # опционально, иначе nginx_default_index_files
    listen_address: ""               # опционально: слушать только на конкретном IP (только proxy.conf.j2)
    http2: false                     # опционально: "http2 on;" при ssl.enabled (только proxy.conf.j2)

    ssl:
      enabled: true
      mode: custom                   # letsencrypt | custom — letsencrypt НЕ выпускает сертификат
                                      # (см. 8.2), только формирует путь /etc/letsencrypt/live/<name>/...
      cert_file: ""                  # обязателен при mode: custom — путь НА ЦЕЛЕВОМ ХОСТЕ
      key_file: ""                   # обязателен при mode: custom — путь НА ЦЕЛЕВОМ ХОСТЕ
      cert_src: ""                   # опционально: файл НА КОНТРОЛЛЕРЕ, разворачивается в cert_file
      key_src: ""                    # (copy поддерживает прозрачную расшифровку ansible-vault)
      redirect_https: true
      hsts: true
      http_enabled: true             # опционально: false = не слушать 80 при redirect_https: false

    logs:
      format: [plain, json]          # json ССЫЛАЕТСЯ на log_format nginx_json, которого нигде
                                      # не существует — см. 8.4, это не "будущая фича", а сломанный
                                      # рендер прямо сейчас, если включить json
      access_log_path: ""
      error_log_path: ""
      extra_access_log:
        - path: /var/log/nginx/json-example.log
          format: json_analytics     # имя log_format, объявленного вне роли

    rate_limit:
      zone_name: "shared_web"        # общая зона на несколько доменов — дедуплицируется по имени
      rate: "10r/s"
      burst: 20
      nodelay: true

    basic_auth:
      enabled: true                  # ВНИМАНИЕ: шаблон рендерит auth_basic_user_file, но ни одна
      users: []                      # задача не генерирует сам htpasswd-файл — включение basic_auth
                                      # даёт валидный по синтаксису, но нерабочий (404/500 на auth)
                                      # vhost. См. 8.3.

    custom_locations:
      - path: /health
        override: true               # true — полностью заменяет дефолтный location с тем же path
        config: |
          access_log off;
          return 200 "ok";

    extra_server_directives: |       # произвольные строки на уровне server{}
      ignore_invalid_headers off;
      proxy_buffering off;

  # --- type: proxy — дополнительные поля ---
  - name: api.example.com
    type: proxy
    proxy_pass: "https://backend.internal"     # простой backend (взаимоисключающе с upstream)
    upstream:                                   # ИЛИ upstream-пул
      name: api_backend
      load_balancing: "ip_hash"
      keepalive: 32
      servers:
        - { address: "10.0.0.10:8080", weight: 5 }
        - { address: "10.0.0.11:8080", max_fails: 3, fail_timeout: "10s" }
        - { address: "10.0.0.12:8080", backup: true }
    extra_upstreams:                            # доп. upstream-блоки для custom_locations
      - name: back_php_srv
        keepalive: 40
        servers:
          - { address: "10.0.0.20:80" }
    proxy_redirect:
      from: "https://backend.internal/"
      to: "https://example.com/"
    proxy_cache: LBCACHE                        # имя зоны из nginx_proxy_cache_zones
    client_max_body_size: 128M
```

### 2.4. Глобальные зоны и прочее

```yaml
nginx_proxy_cache_zones: []
# - name: micro
#   path: /var/cache/nginx/micro
#   levels: "1:2"          # опционально, по умолчанию "1:2"
#   keys_zone_size: 50m    # опционально, по умолчанию 10m
#   max_size: 2g           # опционально, по умолчанию 1g
#   inactive: 30m          # опционально, по умолчанию 10m
#   use_temp_path: "off"   # опционально, по умолчанию off

nginx_rate_limit_zone_size: "10m"

nginx_certbot_webroot_path: "/var/www/_letsencrypt"   # используется только в шаблонах vhost'ов
nginx_certbot_email: ""                                # (location /.well-known/acme-challenge/);
                                                        # сам certbot роль нигде не вызывает

nginx_stub_status:
  enabled: false
  listen: "127.0.0.1:8090"
  location: "/nginx_status"

nginx_conf_d_files: []                 # произвольные http{}-уровневые сниппеты (map{}/geo{} и т.п.)
# - name: api-maps.conf
#   content: "{{ lookup('file', 'api-maps.conf') }}"
```

---

## 3. Порядок задач (`tasks/main.yml`, по факту)

```
1. assert: nginx_domains is sequence

2. install_package.yml (nginx_install_method == "package")
   ИЛИ install_repo.yml (nginx_install_method == "repo", репозиторий nginx.org,
   apt_key — устаревший модуль, задокументирован как временное решение в самом файле)

3. Создать sites-available/, sites-enabled/, conf.d/, log_dir (всегда, безусловно)

4. rate_limit_zones.yml   — рендерит conf.d/rate-limit-zones.conf, если есть хоть одна зона
5. proxy_cache_zones.yml  — рендерит conf.d/proxy-cache-zones.conf, если nginx_proxy_cache_zones не пуст
6. conf_d_files.yml       — раскладывает nginx_conf_d_files (когда список не пуст)
7. certificates_custom.yml — разворачивает cert_src/key_src для ssl.mode == 'custom'
                              (выполняется всегда; внутри — no-op, если подходящих доменов нет)
8. stub_status.yml        — рендерит conf.d/stub_status.conf, если nginx_stub_status.enabled

9. vhosts.yml в цикле по nginx_domains, только для
   domain.enabled | default(true) и domain.type in ['static', 'proxy']:
   a. assert: для type: proxy — proxy_pass ИЛИ upstream.servers обязательны
      (для type: static аналогичного assert на domain.root — НЕТ, см. 9.2)
   b. создать domain.root (если задан)
   c. set_fact _domain_ssl_cert/_domain_ssl_key (если ssl.enabled) — см. 9.1 про утечку между
      итерациями цикла
   d. рендер sites-available/<name>.conf из templates/vhost/<type>.conf.j2
   e. symlink в sites-enabled/ (force: true)

10. meta: flush_handlers — гарантирует, что nginx -t/reload отработают до конца плея,
    а не по умолчанию в конце всего playbook run
```

Ни одна задача не проверяет дубли `server_name` между доменами/хостами группы инвентаря —
`validate_domains.yml` из первоначального замысла не реализован (раздел 8.1).

---

## 4. Handlers (fail-fast)

```yaml
# handlers/main.yml — оба handler'а на listen: "reload nginx", порядок выполнения —
# по порядку объявления в файле (validate раньше reload), а не по порядку notify
- name: validate nginx configuration
  ansible.builtin.command: nginx -t
  changed_when: false
  listen: reload nginx

- name: reload nginx
  ansible.builtin.systemd:
    name: "{{ nginx_service_name }}"
    state: reloaded
  listen: reload nginx
```

Реализовано в точности как в первоначальном замысле: если `nginx -t` падает, `reload` не
выполняется — плей завершится ошибкой на самом `command: nginx -t`, конфиг предыдущей версии
продолжает обслуживать трафик. Отдельного per-domain backup/restore нет — единственная страховка
именно эта проверка перед `reload`.

---

## 5. Rate limiting: агрегация зон

Реализовано в точности по первоначальному замыслу. `tasks/rate_limit_zones.yml` строит
`_nginx_rate_limit_zones` через `selectattr('rate_limit', 'defined') | map(attribute='rate_limit')
| unique(attribute='zone_name') | list`, `templates/rate-limit-zones.conf.j2` рендерит по одной
`limit_req_zone` на уникальный `zone_name`. Каждый vhost подключает лимит через
`limit_req zone=<zone_name> burst=<burst> [nodelay]` прямо внутри `location /` (см. раздел 7)
— отдельного `snippets/rate_limit_location.conf.j2` не создавалось, логика инлайн в
`vhost/*.conf.j2`.

## 6. Proxy cache: агрегация зон

Функциональность, которой не было в первоначальном замысле документа — появилась при реализации.
`tasks/proxy_cache_zones.yml` рендерит `conf.d/proxy-cache-zones.conf` из **глобального**
`nginx_proxy_cache_zones` (а не из `nginx_domains`, в отличие от rate-limit зон — здесь дедупликация
не нужна, так как список уже плоский и заполняется вручную). Домен подключает зону через
`domain.proxy_cache: <name>` — только `type: proxy`; для `type: static` поле не используется
шаблоном.

> Исправлено (найдено `extensions/molecule/nginx_multidomain` при первом прогоне): `nginx`
> не создаёт `zone.path` сам — `proxy_cache_path` не делает `mkdir -p`, и до этой правки
> "nginx -t" гарантированно падал на `mkdir() "<path>" failed (2: No such file or directory)`
> при **любом** использовании `nginx_proxy_cache_zones` ровно по документированной схеме
> переменных. `tasks/proxy_cache_zones.yml` теперь создаёт `zone.path` (owner/group:
> `nginx_user`/`nginx_group`) до рендера конфига.

---

## 7. Custom locations с override

Реализовано проще, чем в первоначальном замысле: вместо отдельного `_default_locations`,
управляемого переменными по типу сайта, каждый шаблон (`vhost/static.conf.j2`,
`vhost/proxy.conf.j2`) хардкодит свой единственный дефолтный `location /` инлайн и условно
пропускает его рендер, если путь `/` присутствует среди `override: true` в
`domain.custom_locations`:

```jinja
{% set override_paths = (domain.custom_locations | default([]))
     | selectattr('override', 'defined') | selectattr('override') | map(attribute='path') | list %}
...
{% if '/' not in override_paths %}
    location / { ... }
{% endif %}

{% for loc in (domain.custom_locations | default([])) %}
    location {{ loc.path }} {
{{ loc.config | indent(8, first=true) }}
    }
{% endfor %}
```

Отличие от первоначального замысла: `override` работает **только** для пути `/` (единственного
дефолтного location'а, который вообще есть в шаблонах) — механизм не масштабируется на другие
дефолтные location'ы, потому что их просто больше нет ни в одном шаблоне. Локации без
`override: true` не «дополняют» ничего специального — они просто рендерятся после `location /`
в порядке списка, как и было задумано.

---

## 8. Реализовано vs не реализовано

### Реализовано и рабочее
- Установка nginx (`package` и `repo`-каналы).
- Базовые директории, `conf.d`-сниппеты (`nginx_conf_d_files`).
- Агрегация rate-limit зон (раздел 5) и proxy-cache зон (раздел 6).
- `stub_status` (отдельный `server{}` без TLS, allow только localhost).
- vhost'ы `type: static` и `type: proxy`, включая upstream-пулы, `extra_upstreams`,
  `proxy_redirect`, `client_max_body_size`, кастомные `server`-директивы, custom locations
  с override только для `/`.
- Custom-сертификаты (`ssl.mode: custom`) с дедупликацией по `cert_file` и прозрачной
  расшифровкой ansible-vault через `copy: src=`.
- Fail-fast `nginx -t` → `reload` handler.

### 8.1. Не реализовано: `validate_domains.yml`
Нет pre-flight проверки дублей `server_name` (name + aliases) между доменами одного или разных
хостов инвентарной группы. Дубль `server_name` в реальности приведёт к тому, что nginx выберет
один из конфликтующих vhost'ов по правилам `server_name`/порядку файлов — без явной ошибки от
роли.

### 8.2. Не реализовано: `certificates_letsencrypt.yml`
`ssl.mode: letsencrypt` поддерживается только на уровне шаблонов — они подставляют путь
`/etc/letsencrypt/live/<domain.name>/{fullchain,privkey}.pem` и генерируют
`location /.well-known/acme-challenge/`, но **ничего в роли не выпускает сертификат** (нет задачи,
вызывающей `certbot`). Из-за этого `mode: letsencrypt` без внешнего механизма выпуска сертификатов
— это `nginx -t`, падающий на отсутствующих файлах сертификата.

### 8.3. Не реализовано: `basic_auth.yml` (генерация htpasswd)
Отличие от статуса "просто TODO": `vhost/*.conf.j2` **уже** безусловно рендерит
`auth_basic_user_file {{ nginx_htpasswd_dir }}/{{ domain.name }};`, как только
`domain.basic_auth.enabled: true` — то есть переменная из схемы уже "работает" на уровне
шаблона, создавая у пользователя ложное впечатление, что basic_auth реализован. По факту
директория `nginx_htpasswd_dir` создаётся (шаг 3 в разделе 3), но файл в неё никто не кладёт —
`nginx -t` в этом случае, скорее всего, тоже упадёт (ссылка на несуществующий файл).

### 8.4. Не реализовано: `nginx.conf.j2` / `log_format nginx_json`
Главный `/etc/nginx/nginx.conf` этой ролью не управляется вовсе (роль полагается на то, что он
уже существует — из пакета или из другой роли/источника). Как следствие,
`domain.logs.format: [json]` рендерит `access_log ... nginx_json;`, ссылаясь на `log_format`,
который нигде не объявлен — не «будущая фича», а гарантированный `nginx -t` fail при первом же
использовании json-логов.

### 8.5. Не реализовано: `logrotate.yml`, `vhost/php-fpm.conf.j2`, `vars/Debian.yml`/`vars/Ubuntu.yml`
- ~~`type: php_fpm` объявлен в схеме переменных, но цикл в `tasks/main.yml` фильтрует только
  `['static', 'proxy']` — домен с `type: php_fpm` молча игнорируется, без ошибки/предупреждения.~~
  — **исправлено** явным `assert` в начале `tasks/main.yml` (домен с `type`, отличным от
  `static`/`proxy`, теперь падает понятной ошибкой со ссылкой на этот раздел, а не молча
  пропускается). Сама функциональность `php_fpm` по-прежнему не реализована — это остаётся
  отдельной задачей, но теперь явный fail вместо тихой поломки.
- Логротация вообще не настраивается этой ролью.
- ~~`meta/main.yml` отсутствует~~ — **сделано**, добавлен (`dependencies: []` — роль не объявляет
  зависимость от `community.general`, хотя фактически её не использует напрямую, модули все из
  `ansible.builtin`).
- Дистрибутив-специфичные переменные (`vars/Debian.yml`/`Ubuntu.yml`) не понадобились — вся
  специфика свелась к одной строке в `install_repo.yml` (`ansible_distribution | lower`).

> Обновление: `extensions/molecule/nginx_multidomain/` теперь существует (docker-driver,
> одноразовый systemd-контейнер, converge покрывает `type: static` и `type: proxy`, verify
> гоняет реальный `nginx -t` + testinfra-эквивалентные ansible-проверки). См. `ROADMAP.md`,
> таблица P4. Он покрывает разделы 8.2–8.4 (letsencrypt/basic_auth/json-логи сознательно
> исключены из сценария как заведомо ломающие `nginx -t` — см. комментарий в
> `extensions/molecule/nginx_multidomain/group_vars/all.yml`) и регрессирует §9.1 (утечка
> `set_fact`). Первый же прогон сценария поймал не описанный в этом документе баг —
> см. раздел 6 (`proxy_cache_zones.yml` не создавал `zone.path`), уже исправлено.

---

## 9. Известные баги и риски реализации (не backlog — уже в коде)

### 9.1. Утечка `set_fact` между итерациями цикла доменов
`tasks/vhosts.yml`: `_domain_ssl_cert`/`_domain_ssl_key` устанавливаются через `set_fact`,
гейтованный `when: domain.ssl is defined and (domain.ssl.enabled | default(false))`. `set_fact`
переживает итерации `loop` — если домен N включает SSL, а домен N+1 (без `ssl:` вовсе) идёт
следом, `set_fact` для N+1 не выполнится, и в шаблон N+1 попадут дублирующиеся факты от домена N
через `vars: ssl_cert: "{{ _domain_ssl_cert | default('') }}"`. Сейчас безвредно только потому, что
оба шаблона перевычисляют `ssl_enabled` заново и не используют `ssl_cert`/`ssl_key`, если он
`false` — но это хрупкий инвариант, а не осознанная защита.

### 9.2. Асимметричная валидация обязательных полей
`tasks/vhosts.yml` содержит `assert` на `proxy_pass`/`upstream.servers` только для `type: proxy`.
Для `type: static` эквивалентного `assert` на `domain.root` нет — пропуск `root` не ловится
pre-flight-проверкой и всплывает уже как сырая Jinja-ошибка "no attribute 'root'" при рендере
шаблона.

### 9.3. `basic_auth`/`json`-логи выглядят реализованными, но ломают `nginx -t`
См. 8.3 и 8.4 — это не "не реализовано", а "реализовано наполовину так, что включение опции ломает
конфиг". Приоритетнее в починке, чем чисто отсутствующие фичи (letsencrypt, logrotate), потому что
пользователь схемы переменных не может по `defaults/main.yml` отличить их от рабочих опций.

### 9.4. Зависимость от нетронутого стокового `nginx.conf`
Роль не рендерит главный `/etc/nginx/nginx.conf` вовсе и полагается на то, что он уже содержит
`include sites-enabled/*` (это есть в пакете Debian/Ubuntu по умолчанию) — сама роль это не
проверяет и не гарантирует. Она также не убирает `sites-enabled/default`: стоковый
`default_server` vhost остаётся активным рядом с доменами `nginx_multidomain`, пока его не уберут
вручную или другим механизмом.
(Ранее эта роль конфликтовала с ныне удалённой legacy-ролью `nginx` — та управляла тем же
`nginx.conf` без `include sites-enabled/*` и перезаписывала его. Конфликт снят удалением роли
`nginx`, см. `ROADMAP.md`, пункт P5-31. Оставшийся риск — только внешняя предпосылка о
содержимом стокового конфига, описанная выше.)

---

## 10. Дальнейшие шаги

Приоритизация всех пунктов раздела 8–9 и их последовательность — см. `ROADMAP.md` (пункты P5-31 —
уже решён и выполнен, роль `nginx` удалена; P5-32, таблица P4). Из этого документа: чинить в
первую очередь стоит 9.1–9.3 (баги в уже существующем коде), затем закрыть внешнюю предпосылку
9.4 (явной проверкой/документированием требования к стоковому `nginx.conf`), и только потом
достраивать отсутствующие куски (8.1–8.5) — достраивать `letsencrypt`/`basic_auth`/`logrotate`
поверх кода с известными багами увеличивает объём того, что придётся переделывать.
