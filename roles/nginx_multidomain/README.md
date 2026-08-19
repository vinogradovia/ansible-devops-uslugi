# nginx_multidomain

Ansible-роль для управления nginx на серверах shared hosting с поддержкой множества доменов,
разных типов сайтов (`type: static`, `type: proxy`), TLS (готовые сертификаты; Let's Encrypt —
не реализован), rate limiting и proxy-cache зон. Единственная nginx-роль в коллекции (роль
`nginx` была экспериментом и удалена — ROADMAP.md, P5-32).

Не разворачивает docker, зависимостей от других ролей коллекции нет (`meta/main.yml`:
`dependencies: []`).

## Статус: реализована частично

Это не production-ready роль без учёта известных ограничений ниже. Полная картина —
[`docs/adr/0003-ginx-multidomain-role.md`](../../docs/adr/0003-ginx-multidomain-role.md)
(схема переменных, порядок задач, разделы 8 и 9 — что реализовано/не реализовано и известные
баги). Этот README — краткая выжимка, за деталями и обоснованием решений — в ADR.

**Реализовано и рабочее**: установка nginx (`package`/`repo`), vhost'ы `static`/`proxy`
(включая upstream-пулы, `extra_upstreams`, `proxy_redirect`, custom locations с override
только для `/`), агрегация rate-limit и proxy-cache зон, `stub_status`, custom-сертификаты
(`ssl.mode: custom`, включая vault-зашифрованные `cert_src`/`key_src`), fail-fast `nginx -t` →
`reload`.

**Не реализовано**: `type: php_fpm` (объявлен в схеме, но падает явным `assert`, а не молча
игнорируется), выпуск сертификатов Let's Encrypt (`ssl.mode: letsencrypt` подставляет пути к
сертификатам в шаблоны, но ничего их не выпускает — без внешнего certbot это гарантированный
`nginx -t` fail), генерация htpasswd для `basic_auth` (шаблон уже безусловно ссылается на файл,
которого никто не создаёт — **ломает `nginx -t`, а не просто не работает**), `log_format
nginx_json` (роль не управляет главным `nginx.conf`, поэтому `logs.format: [json]` ссылается на
необъявленный `log_format` — тоже гарантированный fail), logrotate.

## Обязательные условия

- Главный `/etc/nginx/nginx.conf` должен уже содержать `include sites-enabled/*;` (роль его не
  рендерит и полагается на стоковый файл пакета) — на этапе установки роль явно проверяет это
  `assert`'ом и падает понятной ошибкой, если директивы нет (актуально, например, при
  `nginx_install_method: repo` — пакет `nginx.org` не подключает `sites-enabled` вовсе, только
  `conf.d`). Стоковый `sites-enabled/default` роль не убирает — это остаётся ручным шагом.
- Не включайте `basic_auth.enabled: true` или `logs.format: [json]` до починки соответствующих
  пробелов (см. выше) — оба варианта детерминированно ломают `nginx -t`.

## Пример конфигурации

```yaml
nginx_domains:
  - name: example.com
    type: static
    root: /var/www/example.com/public
    ssl:
      enabled: true
      mode: custom
      cert_file: /etc/nginx/ssl/example.com/fullchain.pem
      key_file: /etc/nginx/ssl/example.com/privkey.pem

  - name: api.example.com
    type: proxy
    proxy_pass: "https://backend.internal"
    rate_limit:
      zone_name: shared_api
      rate: "10r/s"
      burst: 20
```

Полная схема переменных (все опциональные поля) — см. комментарии в `defaults/main.yml` или
раздел 2 ADR.

## Molecule

`extensions/molecule/nginx_multidomain/` — одноразовая ВМ (`driver: vagrant`/`libvirt`,
`cloud-image/ubuntu-24.04`). Converge покрывает `type: static` и `type: proxy`, verify гоняет
реальный `nginx -t` + ansible-based проверки. Сознательно **не** покрывает
`letsencrypt`/`basic_auth`/`json`-логи — эти пути заведомо ломают `nginx -t` (см. выше).
