# reverse_proxy_npm

Разворачивает [Nginx Proxy Manager](https://nginxproxymanager.com/) (NPM) в docker и управляет его
proxy-хостами декларативно через REST API. Проектное решение и обоснование — см.
[`docs/adr/0001-reverse-proxy-npm-role.md`](../../docs/adr/0001-reverse-proxy-npm-role.md).

## Назначение

Узкоспециализированная альтернатива для операторов/клиентов, которым нужен GUI для управления
proxy-хостами, а не IaC через YAML. **Взаимоисключающая** с `nginx_multidomain` и
`reverse_proxy_traefik` на одном хосте — все три роли занимают порты 80/443.

## Обязательные переменные

Роль падает на этапе `check-and-install-requirements.yml`, если не заданы (без дефолтов
намеренно — см. ADR §5):

- `reverse_proxy_npm_admin_email` — email администратора NPM (не должен совпадать с дефолтным
  `admin@example.com`).
- `reverse_proxy_npm_admin_password` — пароль администратора (не должен совпадать с дефолтным
  `changeme`).

При `reverse_proxy_npm_db_driver: mysql` дополнительно обязательны
`reverse_proxy_npm_mysql_host` и `reverse_proxy_npm_mysql_password`.

## Admin UI (порт 81)

По умолчанию порт 81 биндится только на `127.0.0.1` — `reverse_proxy_npm_admin_ui_bind_address`.
Для внешнего доступа **не** меняйте этот адрес — включите
`reverse_proxy_npm_admin_ui_expose_host: true` и задайте `reverse_proxy_npm_admin_ui_domain`: роль
сама создаст в NPM proxy-host на себя (`127.0.0.1:81`) с доменом
`npm-ui-<host-label>.<reverse_proxy_npm_admin_ui_domain>` и Let's Encrypt, вместо прямого
проброса порта 81 наружу. `<host-label>` — `ansible_host` (если не задан — `inventory_hostname`),
но только первая метка до точки: если это уже FQDN (`web1.internal.example.com`), берётся только
`web1` — иначе домен получился бы вида `npm-ui-web1.internal.example.com.<домен>`. Исключение —
IPv4-адрес (`ansible_host: 192.168.1.5`): он подставляется целиком, т.к. усечение до первого
октета сделало бы метку неуникальной.

## Custom/self-signed сертификат

По умолчанию `ssl_forced: true` запрашивает сертификат у Let's Encrypt (`certificate_id: "new"`,
требует реальный публичный DNS + доступ по HTTP-01). Как альтернатива — загрузка уже готового
(в т.ч. самоподписанного) сертификата в NPM: задайте на элементе `reverse_proxy_npm_proxy_hosts`
(или на `reverse_proxy_npm_admin_ui_ssl_provider` для self-managed admin UI, см. выше)
`ssl_provider: custom` и укажите `ssl_certificate_path`/`ssl_certificate_key_path` — пути к
PEM-файлам **на управляемом хосте**, не на контроллере (роль читает их там же, где выполняет все
остальные вызовы NPM API — на самом хосте, см. `reverse_proxy_npm_api_url`). Роль сама создаёт
сертификат в NPM (`POST /nginx/certificates`, `provider: other`) и загружает файлы
(`.../upload`), идемпотентно — по существующему `nice_name`/`domain_names`.

```yaml
reverse_proxy_npm_proxy_hosts:
  - domain_name: "internal.example.com"
    host: "10.0.0.7"
    host_port: 8080
    ssl_forced: true
    ssl_provider: custom
    ssl_certificate_path: /etc/ssl/internal.example.com/fullchain.pem
    ssl_certificate_key_path: /etc/ssl/internal.example.com/privkey.pem
```

Основной сценарий использования — внутренние домены без публичного DNS (или тестовые
окружения), где выпуск Let's Encrypt заведомо невозможен.

## Проксирование на другие контейнеры на этом же хосте

NPM — сам контейнер: `127.0.0.1` в `reverse_proxy_npm_proxy_hosts[].host` — это loopback самого
NPM, а не хоста, и `host.docker.internal` **не подходит** — nginx внутри NPM резолвит
`forward_host` динамически через Docker embedded DNS (127.0.0.11), которое не видит статические
записи `/etc/hosts` (это резолвер уровня nginx, а не libc, поэтому `curl`/`getent` внутри
контейнера видят `host.docker.internal`, а сам проксирующий nginx — нет).

Роль создаёт docker-сеть с именем `reverse_proxy_npm_docker_network` (по умолчанию
`reverse-proxy-npm`). Чтобы проксировать на другой контейнер этого хоста, подключите его к этой
сети —

```bash
docker network connect reverse-proxy-npm <container_name>
```

— и укажите его container/hostname как `host` в `reverse_proxy_npm_proxy_hosts`. Для бэкендов вне
docker (LAN IP, другой хост) сеть не нужна — указывайте IP/резолвимое имя напрямую.

## Пример

```yaml
- hosts: npm_servers
  roles:
    - role: devops.uslugi.reverse_proxy_npm
      reverse_proxy_npm_admin_email: "admin@example.com.internal"
      reverse_proxy_npm_admin_password: "{{ vault_reverse_proxy_npm_admin_password }}"
      reverse_proxy_npm_admin_ui_expose_host: true
      reverse_proxy_npm_admin_ui_domain: "example.com"
      reverse_proxy_npm_proxy_hosts:
        - domain_name: "app.example.com"
          host: "10.0.0.5"
          host_port: 8080
          ssl_forced: true
          letsencrypt_email: "admin@example.com"
```

## Локальное тестирование (molecule, vagrant/libvirt)

`extensions/molecule/reverse_proxy_npm/` — `driver: vagrant`, провайдер `libvirt` (полноценная
ВМ, не `driver: docker`, см. ревизию ADR §11): роль сама не ставит Docker Engine
(`meta/main.yml: dependencies: []`), поэтому `prepare.yml` сценария ставит его как внешний
провижининг хоста, аналогично тому, как раньше это делалось внутри тестового контейнера — но без
docker-in-docker и связанного с ним workaround'а (`storage-driver: vfs`).

Настройка окружения — та же, что для `mysql_replication`/`monitoring_server`
(`docs/adr/0004-mysql-ha-replication-role.md`, раздел «Локальное тестирование»):

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system vagrant
vagrant plugin install vagrant-libvirt
poetry install

export ANSIBLE_LIBRARY="$(poetry run python -c 'import molecule_plugins.vagrant, os; print(os.path.join(os.path.dirname(molecule_plugins.vagrant.__file__), "modules"))')"
poetry run molecule test -s reverse_proxy_npm
```

Сценарий проверяет: контейнер NPM запущен, порт 81 только на loopback, права `compose.yml`,
дефолтный admin-пароль NPM отклонён (401), тестовый proxy-host (`traefik/whoami`) реально
проксирует HTTP, и — в отличие от прежнего docker-сценария — self-managed admin UI proxy-host
(`reverse_proxy_npm_admin_ui_expose_host: true`) с самоподписанным сертификатом
(`ssl_provider: custom`, см. выше): `prepare.yml` генерирует cert/key через `openssl req -x509`
на самой ВМ, `verify.yml` проверяет, что NPM реально обслуживает HTTPS этим сертификатом. Реальный
Let's Encrypt (HTTP-01) по-прежнему не тестируется — для этого нужен настоящий публичный DNS,
чего нет ни у одного из driver'ов molecule в этой коллекции.

## Вне скоупа

- Интеграция с бэкапами `reverse_proxy_npm_config_dir` — отдельная задача (ADR, «Открытые
  вопросы»).
- DNS-01 через `infra_dns` — сознательно не реализовано (ADR §9), ACME полностью внутри NPM.
