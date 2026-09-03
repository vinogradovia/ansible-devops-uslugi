# Создание пользователя платформы (FreeIPA / Authelia)

Единая авторизация платформы (`docs/adr/0013-unified-auth-architecture.md`) построена так: один
каталог — persistent `freeipa` в каждом окружении, поверх него **Authelia** как OIDC-провайдер и
`forwardAuth`-шлюз. Аккаунт заводится **один раз в каталоге freeipa** — этого достаточно, чтобы
пользователь мог зайти во все подключённые сервисы:

- `infra-panel`, `radar` — через `forwardAuth` (форма логина Authelia, `one_factor`, логин+пароль
  из LDAP);
- `Semaphore`, `Gitea` — кнопкой «Sign in with Authelia» (нативный OIDC, автосоздание локального
  аккаунта сервиса при первом входе).

Каталог `freeipa` **пуст по умолчанию** (`roles/freeipa/README.md`, «Назначение и границы» — роль
только разворачивает сервер, не заводит пользователей) — эта процедура закрывает именно тот шаг,
который роль сознательно не делает.

**У каждого окружения — свой отдельный, не связанный с другим каталог.** Пользователя, заведённого
в `platform/aicd` (`ipa.aicd.platform`), в `platform/aicd-devops-labs-ru` (`ipa.aicd.devops-labs.ru`)
не существует — процедуру нужно повторить в каждом окружении, где нужен доступ этому человеку.

**Обновление (2026-09-04, ADR-0019):** для трёх платформенных персон (`platform-admins`/
`-engineers`/`-viewers`) заведение человека теперь декларативно — роль `freeipa_directory`,
подключённая в `site.yml` окружения (`platform/aicd` — уже так, `platform/aicd-devops-labs-ru` —
пока нет). Добавить нового человека в одну из этих групп — правка списка
`freeipa_directory_users` в `site.yml` и повторный прогон, без ручного `ipa user-add`/`kinit
admin` ниже. Эта ручная процедура остаётся актуальной для (а) `platform/aicd-devops-labs-ru` до
подключения роли и (б) любого пользователя вне трёх платформенных персон (break-glass,
одноразовые тестовые аккаунты и т.п.) — роль `freeipa_directory` не удаляет то, чего нет в её
списках (аддитивность, ADR-0019 §3 п.1), поэтому оба пути безопасно сосуществуют.

## 1. Подключиться к серверу freeipa нужного окружения

IP и имя хоста — из сгенерированного Terraform inventory (`platform/aicd/ansible/inventory.yml`
или `platform/aicd-devops-labs-ru/ansible/inventory.yml`, группа `freeipa_hosts`):

```bash
# platform/aicd
ssh -o StrictHostKeyChecking=no ansible@$(cd platform/aicd/terraform && tofu output -json | jq -r '.freeipa_ip.value')

# platform/aicd-devops-labs-ru
ssh -o StrictHostKeyChecking=no ansible@$(cd platform/aicd-devops-labs-ru/terraform && tofu output -json | jq -r '.freeipa_ip.value')
```

На сервере переключиться на root (`ipa`-команды ниже написаны без `sudo` для краткости):

```bash
sudo -i
```

## 2. Получить пароль `admin` и аутентифицироваться в Kerberos (`kinit`)

Пароль `admin` сгенерирован один раз при первом прогоне `site.yml` и хранится в OpenBao,
`secret/freeipa`, поле `admin_password` — тем же способом, что и остальные секреты платформы
(`docs/adr/0016-openbao-secrets-pki.md`). Если пароль уже известен (например, вы разворачивали
стенд сами и он остался в терминале/менеджере паролей) — просто используйте его и пропустите
получение через API ниже.

Если пароль нужно получить заново — с control-хоста, где лежит kubeconfig окружения
(`platform/aicd/ansible/.kube-tmp/.../k3s.yaml` или проще — прямо на самой k3s-ноде, где
`/etc/rancher/k3s/k3s.yaml` уже настроен по умолчанию для root):

```bash
# на k3s-ноде окружения (platform_hosts), под root
ROOT_TOKEN=$(kubectl -n platform get secret openbao-init -o jsonpath='{.data.root_token}' | base64 -d)
OPENBAO_ADDR="https://$(hostname -I | awk '{print $1}'):30820"

curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" \
  "${OPENBAO_ADDR}/v1/secret/data/freeipa" | jq -r '.data.data.admin_password'
```

Полученное значение не публикуйте в общих чатах/тикетах — это административный пароль всего
каталога. С сервера freeipa:

```bash
kinit admin
```

## 3. Завести пользователя

```bash
ipa user-add <uid> \
  --first=<Имя> \
  --last=<Фамилия> \
  --email=<uid>@<домен окружения>
```

где `<домен окружения>` — `aicd.platform` или `aicd.devops-labs.ru`. Пример:

```bash
ipa user-add ivanov \
  --first=Ivan \
  --last=Ivanov \
  --email=ivanov@aicd.platform
```

`--email` **обязателен**, а не опция для красоты: Authelia передаёт claim `email` в ID Token
(`identity_providers.oidc.claims_policies` в `authelia/values.yaml`), и без него автосоздание
аккаунта при первом OIDC-входе в Semaphore/Gitea падает с ошибкой вида `returned missing fields:
email` (см. `docs/adr/0013-unified-auth-architecture.md` §9 — ровно этот баг там разобран подробно
на этапе отладки самой платформы).

`ipa user-add` сама печатает одноразовый случайный пароль пользователя (или используйте
`--password` и введите свой интерактивно) — по умолчанию FreeIPA требует сменить его при первом
входе.

**Важное ограничение схемы**: то же самое (`ipa user-mod ... --email=...`) не сработает для
встроенной учётной записи `admin` — её objectClass не допускает атрибут `mail`. Ограничение
касается только специальной записи `admin`, обычных пользователей оно не затрагивает.

## 4. Первый вход и смена пароля

По умолчанию у нового пользователя выставлен флаг «сменить пароль при первом входе» — LDAP-bind
с временным паролем от имени этого пользователя завершится ошибкой `invalid credentials` с
одновременным требованием сменить пароль, которое умеет обработать `ldappasswd`/`kinit`, но не
форма логина Authelia. Есть два варианта:

**А. Сменить пароль на сервере сразу после создания** (проще, рекомендуется для сервисных/тестовых
аккаунтов):

```bash
kpasswd <uid>
```

(введите временный пароль, затем новый постоянный — после этого пользователь может логиниться
через форму Authelia без дополнительных действий).

**Б. Дать пользователю самому сменить пароль** через `ipa passwd <uid>` или штатный self-service
UI FreeIPA (`https://ipa.<домен>/ipa/ui/`, если он поднят) — не обязательно, если вариант А уже
закрыл вопрос.

Если нужно вообще отключить принудительную смену при первом входе (например, для сервисного
аккаунта, который никогда не логинится интерактивно — по этому же принципу в самой платформе
заведены `svc-authelia` и тестовые учётки для проверки OIDC-логина):

```bash
ipa user-mod <uid> --password-expiration=20351231235959Z
```

## 5. Проверить

```bash
ipa user-show <uid>
```

Ожидается непустой `Email address`, `Password: True`. Дополнительно можно проверить bind под
самим пользователем (после смены пароля из шага 4):

```bash
ldapsearch -x -H ldap://ipa.<домен>:389 \
  -D "uid=<uid>,cn=users,cn=accounts,dc=<domain-component>,dc=..." \
  -w '<новый пароль>' -b "dc=<domain-component>,dc=..." "uid=<uid>"
```

## 6. Что пользователь получает сразу после этого

- `https://infra-panel.<домен>/`, `https://radar.<домен>/` — открыть URL, Authelia покажет форму
  логина, ввести `<uid>`/пароль. Доступ — `one_factor` (без TOTP/WebAuthn, см.
  `docs/adr/0013-unified-auth-architecture.md`, «Не проработано» — второй фактор осознанно не
  включён в MVP-охват).
- `https://semaphore.<домен>/`, `https://gitea.<домен>/` — на странице логина кнопка «Sign in with
  Authelia» → тот же логин/пароль → экран согласия (consent) Authelia → локальный аккаунт сервиса
  создаётся автоматически при первом входе (`ENABLE_AUTO_REGISTRATION` у Gitea,
  auto-registration у Semaphore — ничего дополнительно настраивать не нужно).

Группы/роли/HBAC-политики каталога сейчас никак не используются потребителями (ни `forwardAuth`,
ни OIDC-клиенты не проверяют членство в группах) — `ipa group-add`/`ipa group-add-member` можно
использовать для организации каталога, но на доступ к сервисам это пока не влияет.

## 7. Деактивация/удаление

```bash
ipa user-disable <uid>   # временно — сессии Authelia у пользователя после этого не создаются заново
ipa user-del <uid>       # безвозвратно
```

`ipa user-disable` не завершает уже существующую активную сессию Authelia немедленно — это
блокирует только новые LDAP bind-попытки (следующий логин или продление истёкшей сессии).
