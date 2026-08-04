# fail2ban_ui

Веб-панель управления [Fail2Ban](https://github.com/fail2ban/fail2ban) —
обёртка над [swissmakers/fail2ban-ui](https://github.com/swissmakers/fail2ban-ui)
(дашборд активных jail'ов, поиск/бан/анбан IP, редактирование jail/filter-конфигов,
приём callback от удалённых Fail2Ban-инстансов). Fail2Ban сам эта роль не устанавливает и не
настраивает — отдельной роли `fail2ban` в коллекции нет, ожидается, что Fail2Ban уже стоит на
хосте (обычным пакетом дистрибутива).

## Статус

- **systemd** — реализовано. Бинарник берётся не сборкой из исходников и не vendoring в git, а
  извлечением из уже собранного апстримом multi-arch docker-образа (см. "Как устроен
  systemd-путь" ниже) — апстрим не публикует готовых бинарников в GitHub Releases.
- **docker** — реализовано, `community.docker.docker_compose_v2` с `network_mode: host` (нужен
  для доступа к `/var/run/fail2ban/fail2ban.sock` и реальным client IP при управлении локальным
  Fail2Ban на том же хосте).
- **reverse-proxy: nginx** — реализовано (basic-auth, self-signed TLS по умолчанию).
- **reverse-proxy: traefik** — значение переменной заведено (`fail2ban_ui_reverse_proxy:
  false|nginx|traefik`), но НЕ реализовано: нет ни шаблона, ни задач. `docker`-путь роли к тому
  же использует `network_mode: host` (не общую сеть `proxy`, как `reverse_proxy_traefik`/
  `infra_panel`), поэтому подключение к Traefik потребовало бы отдельного решения по сети, не
  тривиального добавления labels.

## Как устроен systemd-путь

Апстрим публикует для fail2ban-ui только docker-образ (`docker.io/swissmakers/fail2ban-ui`) —
готовых бинарников в GitHub Releases нет. Вместо сборки из исходников (нужен Go-тулчейн на
каждом управляемом хосте) или vendoring бинарника прямо в git (раздувает репозиторий, не
масштабируется на новые версии/архитектуры) роль использует
[`crane`](https://github.com/google/go-containerregistry) — статический Go-бинарник (сам
устанавливается тем же паттерном download+checksum, что и экспортёры `monitoring_agent`), который
умеет вытащить файловую систему уже собранного апстримом образа БЕЗ Docker-демона:

```
crane export {{ fail2ban_ui_image }} - | tar -x -C {{ fail2ban_ui_config_dir }} --strip-components=1 app
```

В образах v1.5.x каталог `/app` содержит только сам бинарник — начиная с какой-то версии между
v1.4.4 (на которую изначально была рассчитана эта роль) и текущей v1.5.3 апстрим встроил
web-ассеты (templates/locales/static) в бинарник через `go:embed`, поэтому отдельно их тащить не
нужно (раньше здесь был `ansible.builtin.git checkout` всего репозитория — убран как избыточный).

Установка версии идемпотентна через файл-маркер `{{ fail2ban_ui_config_dir }}/.fail2ban_ui_version`
— повторное `crane export` (тянет образ из реестра) выполняется только если версия в маркере не
совпадает с `fail2ban_ui_version`.

## Обязательные шаги перед использованием

- `fail2ban_ui_reverse_proxy_users_auth` — список пользователей basic-auth (`{name, password,
  state}`), актуально только при `fail2ban_ui_reverse_proxy: nginx`. Роль падает на этапе
  `check-and-install-requirements.yml`, если пароль хотя бы одного пользователя с `state:
  present` совпадает с дефолтным `fail2ban_ui_reverse_proxy_default_password`
  (`"PleAse_Change_ME!"`) — панель управляет банами/jail'ами Fail2Ban, анонимный/дефолтный доступ
  недопустим.
- `fail2ban_ui_version` — версия образа/бинарника. `v1.4.4` (старый дефолт роли) больше не
  публикуется апстримом ни на Docker Hub, ни тегом в GitHub — используйте актуальную (`v1.5.x`),
  сверяйтесь с [releases апстрима](https://github.com/swissmakers/fail2ban-ui/releases).

## Зависит от

Роли `docker` (`meta/main.yml`, `when: fail2ban_ui_orchestrator == 'docker'`) — сама Docker Engine
не устанавливает. Для systemd-пути Docker не нужен вообще (см. "Как устроен systemd-путь" выше) —
`crane` работает без демона.

Коллекция `community.crypto` (`galaxy.yml`) — `openssl_privatekey`/`openssl_csr`/
`x509_certificate` для self-signed TLS-сертификата nginx, если `fail2ban_ui_reverse_proxy:
nginx` и сертификат ещё не существует на хосте.

## Локальный Fail2Ban: почему systemd-юнит и docker-контейнер запускаются от root

`User=root` в systemd-юните — осознанный выбор, не забытая настройка: приложению нужен доступ к
`/var/run/fail2ban/fail2ban.sock` (создаётся самим Fail2Ban как `root:root`), права на чтение/
запись `/etc/fail2ban/jail.d/*.conf`, чтение всего `/var/log` (проверка `logpath` перед
включением jail'а) и `systemctl restart fail2ban.service`. Тот же вывод и у самого апстрима —
`docker-compose.example.yml` явно комментирует `privileged: true` "needed if you want to use a
container-local fail2ban instance (because fail2ban.sock is owned by root)". Поскольку Fail2Ban
не разворачивается этой коллекцией (нет отдельной роли `fail2ban`), сузить права выделенным
пользователем без изменения конфигурации самого Fail2Ban (владелец сокета, группы) — вне
контроля этой роли.

## basic-auth (nginx): как это устроено под capot

Аналогично `reverse_proxy_traefik`/`infra_panel`: apr1-хэш считает `community.general.htpasswd`,
но **на control-хосте** (`delegate_to: localhost`), не на управляемом — итоговый файл сразу
копируется на целевой хост как обычный auth-файл nginx (`auth_basic_user_file`), в отличие от
Traefik-варианта, которому нужен инлайн в docker-label. Хэш считается в постоянный файл-кэш на
control-хосте (`fail2ban_ui_reverse_proxy_users_auth_cache_path`, по умолчанию
`~/.cache/ansible-fail2ban-ui/`), а не в одноразовый tempfile — `community.general.htpasswd`
идемпотентен только когда сверяет пароль с уже существующим хэшем (`passlib.verify`), а не
пересчитывает его каждый раз заново.

## API-эндпойнты callback без basic-auth

`/api/ban` и `/api/unban` в nginx-шаблоне намеренно не защищены basic-auth (`auth_basic off;`) —
это callback-эндпойнты, на которые стучатся УДАЛЁННЫЕ Fail2Ban-инстансы
(`fail2ban_ui_callback_url`/`fail2ban_ui_callback_secret`), у которых нет и не может быть
пароля человека-оператора. Авторизация для них — на уровне самого приложения
(`CALLBACK_SECRET`), не nginx.
