# freeipa

Разворачивает один standalone-сервер [FreeIPA](https://www.freeipa.org/) — центральный каталог
пользователей и групп (LDAP + Kerberos KDC + собственный CA) для всей платформы. Остальные модули
(и отдельная роль Keycloak, ещё не реализована) используют этот каталог напрямую по LDAP/Kerberos
или транзитом через Keycloak как identity provider.

## Назначение и границы

Роль только **разворачивает сервер** (`ipa-server-install`) — она не заводит пользователей/группы
в каталоге. Управление данными каталога (пользователи, группы, sudo-правила, HBAC) делайте
отдельно через `ipa` CLI/API или отдельную роль — совмещать провижининг сервера с управлением его
данными в одной роли не стоит: разная частота изменений, разная модель идемпотентности.

Не покрывает:

- **Репликацию** между несколькими IPA-серверами (`ipa-replica-install`) — только один сервер.
- **Встроенный DNS** FreeIPA (`--setup-dns`) — сознательно не используется, см. ниже.
- Заведение пользователей/групп/политик в каталоге.
- Интеграцию клиентов (`ipa-client-install`) — это задача роли/плейбука клиентской стороны.

## Целевая ОС

**Rocky Linux 9 / AlmaLinux 9 (`dnf`)** — единственная в этой коллекции роль на RHEL-семействе,
остальные роли — Debian/Ubuntu (`apt`). Не совпадение и не выбор по умолчанию: пакета
`freeipa-server` для Ubuntu/Debian **не существует** — Ubuntu (`noble`/24.04) и Debian
(`bookworm`) публикуют в своих репозиториях только клиентскую часть (`freeipa-client`,
`freeipa-common`), без самого сервера. Это выяснилось эмпирически при первом прогоне
molecule-сценария (`apt install freeipa-server` падал с «No package matching 'freeipa-server' is
available») — до этого роль была написана под Ubuntu 24.04/apt по умолчанию для консистентности с
остальной коллекцией, но реального пути развернуть сервер на этой ОС нет. На Rocky/Alma 9
`freeipa-server` ставится из коробки через `dnf`/AppStream, без сторонних репозиториев.

## Без встроенного DNS

`ipa-server-install` запускается без `--setup-dns` — отдельный DNS-сервер ради одной роли платформы
не поднимается. Вместо этого резолвинг `freeipa_hostname` обеспечивается одним из двух способов:

- **`freeipa_manage_hosts_entry: true` (по умолчанию)** — роль сама добавляет self-entry в
  `/etc/hosts` сервера (`<IP> <FQDN> <short-hostname>`). Достаточно для одиночного сервера,
  которому не нужно, чтобы *другие* хосты резолвили его по имени через DNS.
- **Внешний DNS** (например, роль `infra_dns` этой коллекции) — если клиентам FreeIPA (будущим
  `ipa-client-install`) нужно резолвить сервер по имени, заведите A/PTR-записи там и выключите
  `freeipa_manage_hosts_entry`, чтобы не держать два источника истины.

Install использует `--no-host-dns`, чтобы не требовать от инсталлятора прямой/обратной DNS-проверки
хоста — актуально в средах без реального DNS (molecule, ранняя стадия разворачивания).

## Обязательные переменные

Без дефолтов намеренно (тот же fail-fast паттерн, что `reverse_proxy_npm`/`reverse_proxy_traefik`)
— роль падает на этапе `Validate`, если не заданы:

- `freeipa_domain` — например `example.com`.
- `freeipa_realm` — Kerberos realm, обычно домен в верхнем регистре: `EXAMPLE.COM`.
- `freeipa_dm_password` — пароль Directory Manager (LDAP), из ansible-vault.
- `freeipa_admin_password` — пароль Kerberos-принципала `admin`, из ansible-vault.

`freeipa_hostname` (по умолчанию `ansible_fqdn`) обязан быть в форме `host.{{ freeipa_domain }}` —
роль проверяет это отдельным `assert` перед установкой (частая причина падения
`ipa-server-install` в реальной эксплуатации — hostname не резолвится в свой домен).

**Пароли неизбежно передаются `ipa-server-install` через аргументы командной строки** (у него нет
поддержки stdin/файла для `--ds-password`/`--admin-password`, в отличие от `smbpasswd` в роли
`samba_server`) — задача обёрнута в `no_log: true`, но кратковременно они видны в `ps` на самом
хосте на время установки.

## Пример

```yaml
- hosts: freeipa_servers
  roles:
    - role: devops.uslugi.freeipa
      freeipa_domain: example.com
      freeipa_realm: EXAMPLE.COM
      freeipa_hostname: ipa-01.example.com
      freeipa_dm_password: "{{ vault_freeipa_dm_password }}"
      freeipa_admin_password: "{{ vault_freeipa_admin_password }}"
```

## Что дальше (не входит в эту роль)

- Заведение пользователей/групп — `ipa user-add`/`ipa group-add` (CLI/API) или отдельная роль
  поверх этой.
- Подключение клиентов — `ipa-client-install` на потребляющих хостах.
- Keycloak как federation-слой поверх этого каталога (LDAP/Kerberos) — отдельная роль, ещё не
  реализована.
