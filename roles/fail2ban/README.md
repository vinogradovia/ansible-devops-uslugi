# fail2ban

Устанавливает и настраивает [Fail2Ban](https://github.com/fail2ban/fail2ban) — управляет
`jail.local` (декларативный список `fail2ban_jails`), ставит bundled-фильтры под известные
интеграции коллекции (см. ниже) и, при необходимости, кастомные `filter.d`-конфиги
(`fail2ban_custom_filters`) для любых других нестандартных форматов логов, под которые нет ни
стокового фильтра в пакете `fail2ban`, ни bundled-фильтра этой роли.

Роль не знает про `roles/fail2ban_ui` (веб-панель для Fail2Ban) — они полностью независимы,
может использоваться любая по отдельности. `fail2ban_ui` продолжает считать сам Fail2Ban
внешним пререквизитом (см. `roles/fail2ban_ui/README.md`) — эта роль его закрывает, если
раньше он ставился ad hoc.

## Переменные

- `fail2ban_bantime`/`fail2ban_findtime`/`fail2ban_maxretry`/`fail2ban_ignoreip`/
  `fail2ban_backend` — глобальная секция `[DEFAULT]` в `jail.local`. Каждый jail в
  `fail2ban_jails` может переопределить `maxretry`/`findtime`/`bantime`/`backend` для себя.
- `fail2ban_jails` — список jail'ов, **полностью декларативный**: `jail.local` перерендеривается
  целиком на каждом прогоне, выключить/удалить jail — значит убрать его из списка (или
  `enabled: false`), отдельного `state: absent` не нужно (в отличие от incremental-задач вроде
  `community.general.htpasswd` в других ролях коллекции). Схема элемента — см. комментарий в
  `defaults/main.yml`. `filter`, если не задан, по умолчанию равен имени jail'а — штатное
  поведение самого `jail.conf` апстрима, не переопределяется этой ролью.
- `fail2ban_custom_filters` — список `{name, content}`, рендерится как есть в
  `/etc/fail2ban/filter.d/<name>.conf` под ключ `[Definition]`. Нужен только для логов
  нестандартного формата — большинство стоковых сервисов (nginx с дефолтным `combined`
  форматом, sshd) уже покрыты фильтрами из самого пакета `fail2ban`
  (`/etc/fail2ban/filter.d/*.conf`), кастомный фильтр писать не нужно.

## Известные интеграции (ADR/ROADMAP Backlog №47)

- **`nginx_multidomain`** — использует стоковый nginx-формат логов (`nginx_default_log_formats:
  [plain]`, роль не переопределяет `log_format`), поэтому кастомный фильтр не нужен вовсе:
  jail с `filter: nginx-limit-req` (фильтр из пакета `fail2ban`) и `logpath` на error-логи
  доменов (`{{ nginx_log_dir }}/error_*.log`) банит по превышению `limit_req`-зоны — та же
  функциональность, что `nginx_multidomain` уже реализует (`domain.rate_limit`), просто
  добавляет реальный бан поверх штатного HTTP 503. См. `demo/nginx-multidomain/`.
- **`reverse_proxy_npm`** (Nginx Proxy Manager) — свой, нестандартный `log_format` (см.
  апстримный `docker/rootfs/etc/nginx/conf.d/include/log-proxy.conf`), не совпадает со
  стоковыми nginx-фильтрами fail2ban. Ловит повторные 401/403/404 от одного IP по полю
  `[Client ...]` NPM-формата — bundled-фильтр `npm-proxy` (`templates/filter.d/npm-proxy.conf.j2`,
  устанавливается ролью безусловно, инертен без jail'а), `logpath` — на
  `{{ reverse_proxy_npm_config_dir }}/data/logs/proxy-host-*_access.log` (bind-mount контейнера
  на хост, `roles/reverse_proxy_npm/templates/compose-reverse-proxy-npm.yml.j2`). См. `demo/npm/`.

## Пример

```yaml
fail2ban_jails:
  - name: sshd
    filter: sshd
    backend: systemd
    port: ssh
    maxretry: 5
  - name: nginx-limit-req
    filter: nginx-limit-req
    logpath: /var/log/nginx/error_*.log
  - name: npm-proxy
    filter: npm-proxy
    logpath: /opt/reverse-proxy-npm/data/logs/proxy-host-*_access.log
```
