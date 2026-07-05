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
`npm-ui-<ansible_host>.<reverse_proxy_npm_admin_ui_domain>` и Let's Encrypt, вместо прямого
проброса порта 81 наружу.

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

## Вне скоупа

- Интеграция с бэкапами `reverse_proxy_npm_config_dir` — отдельная задача (ADR, «Открытые
  вопросы»).
- DNS-01 через `infra_dns` — сознательно не реализовано (ADR §9), ACME полностью внутри NPM.
