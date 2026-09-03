# freeipa_directory

Заводит и обновляет данные каталога FreeIPA — группы и учётные записи людей — декларативно и
идемпотентно, поверх уже поднятого сервера (роль `freeipa` этой коллекции). Решения и их
обоснование — см. [`docs/adr/0019-platform-rbac-model.md`](../../docs/adr/0019-platform-rbac-model.md)
§3.

## Назначение и границы

Роль **не разворачивает сервер** — только управляет его содержимым: существование и атрибуты
групп/пользователей через JSON-RPC API (`community.general.ipa_group`/`ipa_user`), членство в
группах — сырым `ipa` CLI (см. «Механизм членства в группах» ниже, причина — баг модуля). Граница
с ролью `freeipa` (`docs/adr/0011-freeipa-role.md` §3, «роль = сервер, не данные каталога»)
сохраняется дословно: сервер поднимает `freeipa`, данные — эта роль.

Не покрывает:

- **Сервисные bind-аккаунты** (`svc-authelia`/`svc-nexus`/`svc-monitoring`) — заводятся отдельно,
  оркестрацией окружения (`site.yml`, сырыми `ipa` CLI-командами с `--password-expiration` далеко
  в будущем) — это осознанно другой класс объектов: не логинится интерактивно, не входит ни в
  какую платформенную группу. Не переносите их сюда без явного решения — префикс `svc-` зарезервирован
  под них отдельно (ADR-0019 §2).
- **Глобальный prune** («удалить всё, чего нет в списках `freeipa_directory_groups`/
  `freeipa_directory_users`») — не реализован. Каталог не только про платформу: там же живут
  `svc-*`-аккаунты и всё, что заведено вручную, — decl­аративный прогон, вычищающий незнакомое,
  снёс бы работающий доступ (тот же риск, что ADR-0019 §3 п.1 явно проговаривает). Удаление
  конкретного объекта — через его же элемент списка с `state: absent`. Единственный
  реализованный prune — `freeipa_directory_prune_group_members` (см. ниже), он безопасен, потому
  что действует только на членство **уже объявленных** групп, не на весь каталог.
- **Вложенные группы** (`proj-*` наследование от `platform-*`, ADR-0019 §2) — роль управляет
  только членством людей (`ipa group-add-member --users=...`), не вложенностью групп
  (`--groups=...`). `proj-*` сам по себе ADR-0019 §2 резервирует, но не заводит.
- **Маппинг групп в роли конкретных сервисов** (Grafana Admin/Editor/Viewer, Gitea admin/user,
  Nexus role-по-`id`, claim `groups` в ID Token Authelia) — ADR-0019 §4/§5/§6, отдельный слой
  поверх данных каталога, не эта роль.

## Куда играть роль

Играется **на самом freeipa-хосте** (`hosts: freeipa_servers`/эквивалент, тот же inventory-хост,
что роль `freeipa`), не `delegate_to: localhost` и не с отдельного control-хоста. Причина:
`freeipa_directory_ipa_validate_certs: true` по умолчанию рассчитывает на то, что системный trust
store уже доверяет самоподписанному CA сервера — `ipa-server-install` добавляет свой CA в
системный trust store того хоста, на котором он запущен, автоматически. С control-хоста этого
доверия нет, и потребовалось бы либо явно раздавать CA-сертификат FreeIPA (не тот же CA, что
`aicd-platform-ca.pem` — это отдельный, издаваемый Dogtag CA самого IPA), либо
`freeipa_directory_ipa_validate_certs: false`.

## Обязательные переменные

- `freeipa_directory_ipa_pass` — пароль admin-принципала каталога (тот же, что `freeipa_admin_password`
  роли `freeipa`), из ansible-vault. Без дефолта намеренно — роль падает на `tasks/validate.yml`,
  если не задан (тот же fail-fast паттерн, что `reverse_proxy_npm`/`reverse_proxy_traefik`/`freeipa`).

## Механизм членства в группах — сырой `ipa` CLI, не `community.general.ipa_group`

Существование/атрибуты групп и пользователей роль ведёт через `community.general.ipa_group`/
`ipa_user` (JSON-RPC, без `kinit`). Членство в группах — намеренно **другим** механизмом: сырой
`ipa group-add-member`/`ipa group-remove-member` с предварительным `kinit` (тот же приём, что
`site.yml` окружений уже использует для `svc-*`-bind-аккаунтов). Причина — подтверждённый живым
прогоном molecule баг апстрима: `community.general` 13.1.0,
[issue #1239](https://github.com/ansible-collections/community.general/issues/1239)/PR #11698 —
`IPAClient._post_json` трактует любой непустой ключ `failed` в ответе FreeIPA как ошибку, а ответ
FreeIPA на `group_add_member` **всегда** содержит `failed: {user: [], group: [], ...}`, даже когда
реально ничего не упало (пустые списки — но словарь с ключами truthy в Python независимо от
содержимого). Модуль падает на любом реальном (не no-op) добавлении участника в группу. Затронуты
только member-операции — `group_add`/`group_mod`/`user_add`/`user_mod` так не ломаются (их ответ
не содержит `failed`), поэтому объекты групп/пользователей остаются на модулях. Диф текущих
(`ipa group-show --all --raw`) и желаемых (`freeipa_directory_users[].groups`) участников считает
сама роль — подробности в `tasks/group-membership.yml`/`tasks/group-membership-apply.yml`.

## Аддитивность по умолчанию (ADR-0019 §3 п.1)

Роль создаёт и обновляет объекты из `freeipa_directory_groups`/`freeipa_directory_users`, но
никогда не удаляет то, чего нет в списках. Удалить конкретную группу/пользователя — добавить его
в список с `state: absent` (объект удаляется, остальные списки не сканируются). Членство в группах
по умолчанию тоже только добавляется, ручное или заведённое другим прогоном членство не снимается;
чтобы членство группы стало ровно тем, что указано в `freeipa_directory_users[].groups`, —
`freeipa_directory_prune_group_members: true`.

## Пароли людей (ADR-0019 §3 п.2)

`password` в `freeipa_directory_users[]` применяется **только при создании** учётной записи
(`update_password: on_create`) — повторные прогоны роли не перезаписывают пароль, который человек
мог уже сменить сам. Требование "сменить пароль при первом входе" — штатное поведение FreeIPA при
административной установке пароля, роль его не отключает (в отличие от `--password-expiration`
далеко в будущем у `svc-*`-аккаунтов, см. выше).

## Пример

```yaml
- hosts: freeipa_servers
  roles:
    - role: devops.uslugi.freeipa_directory
      freeipa_directory_ipa_pass: "{{ freeipa_admin_password }}"
      freeipa_directory_groups:
        - name: platform-admins
          description: "Полные права на все компоненты платформы"
        - name: platform-engineers
          description: "Обычный пользователь/деплой; без администрирования сервисов"
        - name: platform-viewers
          description: "Read-only доступ там, где он предусмотрен"
      freeipa_directory_users:
        - name: ivan
          first: Ivan
          last: Vinogradov
          email: ivan@example.com
          password: "{{ vault_freeipa_directory_password_ivan }}"
          groups: [platform-admins]
```

## Что дальше (не входит в эту роль)

- Перенос claim'а `groups` в ID Token Authelia и маппинг ролей внутри конкретных сервисов
  (ADR-0019 §4/§5/§6) — следующий шаг после того, как группы и хотя бы один реальный человек в
  `platform-admins` заведены (ADR-0019 §8, порядок внедрения).
- Проектные группы `proj-*` (ADR-0019 §2) — резервирование префикса есть, вложенные группы
  (`group:` в `ipa_group`) роль пока не прокидывает.
- Глобальный prune всего каталога — сознательно не реализован, см. «Назначение и границы» выше.
