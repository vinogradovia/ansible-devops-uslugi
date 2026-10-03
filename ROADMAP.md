# ROADMAP — план улучшений коллекции `devops.uslugi`

Документ подготовлен по итогам код-ревью всех ролей коллекции (`monitoring_server`,
`monitoring_agent`, `infra_dns`, `nginx`, `nginx_multidomain`, `reverse_proxy_traefik`).
Каждый пункт содержит ссылку `файл:строка` и конкретный сценарий отказа — без общих
рекомендаций.

> **Обновление:** по решению P5-32 роль `nginx` удалена из коллекции целиком (была
> экспериментом; `nginx_multidomain` — её замена и единственный путь вперёд для nginx). Вместе
> с ролью удалены: `roles/nginx/` (включая устаревшую копию документации в `roles/nginx/docs/`),
> пустой сценарий `extensions/molecule/nginx/` и нерабочие scratch-плейбуки
> `tests/deploy_nginx_sites.yml`/`tests/deploy_nginx_sites_test.yml`, которые вызывали роль
> `nginx` или дублировали её логику. Пункты ниже, описывавшие баги конкретно в коде роли
> `nginx`, отмечены как закрытые удалением — исторически они остаются в документе, чтобы было
> видно, что находки не проигнорированы, а сняты вместе с самой ролью.

Ревью не включает `trial/swissmakers/fail2ban-ui` (сторонний вендоренный проект) и
`ADDONS/` (отдельно документированные экспортеры).

## Как читать приоритеты

- **P0** — ломает функциональность прямо сейчас на дефолтных/естественных настройках.
- **P1** — проблемы безопасности (секреты, дефолтные пароли, supply chain).
- **P2** — надёжность/идемпотентность (сработает не всегда, зависит от состояния хоста).
- **P3** — мёртвый код и репозиторный мусор, мешающий ориентироваться в коллекции.
- **P4** — отсутствующее тестовое покрытие.
- **P5** — архитектурные развилки, требующие решения, а не просто патча.

---

## P0 — Критические баги

### monitoring_server

1. ~~**Alert-правила вообще не применяются в docker-режиме** (дефолтный оркестратор).~~ —
   **закрыто по P5-34 решением «документировать как k3s-only»** (реализация `vmalert` в
   docker-compose осталась отдельной задачей архитектурного уровня, не патчем):
   - Все `monitoring_server_victoria_metrics_alerts_rules_*_default` в `defaults/main.yml` теперь
     дополнительно гейтятся на `monitoring_server_orchestrator == 'k3s'` (раньше просто наследовали
     `scrape_*`-флаг, который `true` по умолчанию почти для всех экспортеров — то есть алерты были
     бы «включены» по умолчанию и для docker, где `vmalert` не существует).
   - Добавлен fail-fast в `check-and-install-requirements.docker.yml`: если пользователь явно
     включает `alert_rules_default_enabled` для экспортера под `docker`, играется понятная ошибка
     со ссылкой на этот пункт и на P5-34, а не молчаливый no-op.
   - Проверено тремя сценариями: дефолтная docker-установка (список экспортеров с
     `alert_rules_default_enabled: true` — пустой, fail-fast не срабатывает); k3s (алерты
     по умолчанию включены для экспортеров со `scrape: true`, поведение не изменилось); explicit
     override под docker (`..._alerts_rules_node_exporter_default: true`) — понятный fail вместо
     молчаливого игнорирования.
2. ~~**mysqld-exporter и pve-exporter включены по умолчанию, но никогда не скрейпятся в
   docker-режиме.**~~ — **исправлено**: в `templates/victoria-metrics-scrape-config.yaml.j2`
   добавлены `job_name: mysqld-exporter`/`job_name: pve-exporter` с `file_sd_configs`, по тому же
   паттерну, что и у остальных экспортеров (target-файлы уже писались на диск через
   `vars/main.yml` — не хватало только job'ов в самом scrape-конфиге). Проверено рендером шаблона
   через Jinja2 напрямую — валидный YAML.
3. ~~**Grafana dashboard provisioning в docker сломан архитектурно.**~~ — **исправлено**: добавлен
   новый шаблон `templates/grafana-dashboard-provider.yaml.j2` (`apiVersion: 1 / providers: [...]`,
   `type: file`, `options.path: /etc/grafana/provisioning/dashboards`) и задача, рендерящая его
   один раз в `tasks/main.yml` (блок `GrafanaDashboards`, `when: orchestrator == 'docker'`, до
   цикла по группам дашбордов — не на каждый dashboard-item, файл общий для всех). Добавлен
   handler `Restart grafana` (провайдер читается Grafana только при старте, hot-reload не
   поддерживается) — рендер провайдера теперь `notify`'ит его. Проверено рендером шаблона напрямую
   через Jinja2 + `yaml.safe_load` — валидный YAML нужной структуры.
4. ~~**Включение `monitoring_server_victoria_metrics_scrape_blackbox` или `..._nodejs_exporter` в
   docker-режиме роняет плей.**~~ — **исправлено**: вместо падения на undefined-переменной
   (`item.src`/`item.dest` не существуют для VMScrape/k3s-only экспортеров), теперь явный
   `ansible.builtin.fail` с понятным сообщением (по аналогии с fail-fast pve-exporter'а из
   `monitoring_agent`, P0-10), плюс guard `'dest' in item` добавлен и в саму задачу рендеринга
   (была без него, в отличие от соседней задачи удаления). Проверено отдельным тестовым
   плейбуком: `blackbox: true` под docker — понятный fail вместо краша на undefined variable;
   `nodejs-exporter: false` — чисто пропускается без ошибок; `node-exporter` (с `dest`) — доходит
   до рендеринга как раньше.
5. ~~**`monitoring_server_grafana_loki_enabled: true` без `monitoring_server_local_storage_s3_enabled`
   рендерит невалидный compose.**~~ — **исправлено** явным `fail`, а не условным `depends_on`:
   `loki-config.yaml.j2` хардкодит `object_store: s3` (локальной файловой альтернативы не
   реализовано) — это не опциональная, а обязательная зависимость Loki от сервиса `s3` в этой
   коллекции, поэтому корректный фикс — не прятать `depends_on`, а явно требовать
   `monitoring_server_local_storage_s3_enabled: true` вместе с `..._grafana_loki_enabled: true`.
   Проверка добавлена в `check-and-install-requirements.docker.yml`. Оба флага по умолчанию
   `false` — дефолтная конфигурация не затронута.

### nginx / nginx_multidomain — закрыто удалением роли `nginx` (см. P5-32)

6. ~~**`roles/nginx/templates/nginx.conf.j2` не является валидным nginx-конфигом (3 независимых
   бага)**~~ — файл удалён вместе с ролью. Баги (отсутствующая `;` после `gzip_types`, неверный
   синтаксис директивы `user`, ссылка на необъявленный `log_format main`) в `nginx_multidomain`
   не воспроизводятся: эта роль не рендерит главный `nginx.conf` вовсе (полагается на стоковый —
   см. §9.4 архитектурного документа `nginx_multidomain`).
7. ~~**`roles/nginx/tasks/main.yml:33-38` — задача-«обработчик» на самом деле обычная task**~~ —
   файл удалён вместе с ролью. В `nginx_multidomain` reload реализован корректно как handler с
   fail-fast `nginx -t` (`roles/nginx_multidomain/handlers/main.yml`).
8. ~~**Конфликт ролей `nginx` и `nginx_multidomain` на одном хосте**~~ — снят удалением роли
   `nginx`: конфликтовать больше не с чем. Риск §9.4 архитектурного документа `nginx_multidomain`
   (роль полагается на нетронутый стоковый `nginx.conf` с `include sites-enabled/*` и раньше не
   проверяла/не гарантировала это) — **тоже исправлено**: явный `assert` в `tasks/main.yml`
   падает понятной ошибкой, если `nginx.conf` не подключает `sites-enabled` (было чисто внешней
   предпосылкой, не конфликтом ролей коллекции).

### monitoring_agent

9. ~~**Патч `/etc/docker/daemon.json` полностью не работает** — пропущены Jinja-скобки.~~ —
   **исправлено**: `roles/monitoring_agent/tasks/monitoring-agent.yml:97` теперь
   `path: "{{ monitoring_agent_docker_exporter_docker_daemon_json }}"`. Проверено `ansible-lint` и
   `--syntax-check` — регрессий нет.
10. ~~**`monitoring_agent_pve_exporter_enabled: true` не работает при дефолтном оркестраторе.**~~ —
    **исправлено** точечным `fail`, а не полной реализацией под docker: `tasks/exporters-pve-exporter.yml:4-9`
    теперь падает с явным сообщением, если `monitoring_agent_pve_exporter_enabled: true` и
    `monitoring_agent_orchestrator != 'systemd'` (конфиг для docker по-прежнему не поддержан —
    это осознанный fail-fast, а не молчаливый no-op, полная поддержка pve-exporter под docker
    остаётся отдельной задачей архитектурного уровня).
36. ~~**`pve_exporter`/`mysqld_exporter` под systemd крашатся сразу после старта —
    `PermissionError` при чтении собственного config-файла.**~~ — **найдено и исправлено** при
    сборке `extensions/molecule/monitoring_agent` (idempotence не проходил: systemd постоянно
    перезапускал упавший сервис). Оба файла (`pve.yml`, `.mysqld_exporter_my.cnf`) рендерились
    `root:root:0600`, а сами сервисы запускаются под выделенным непривилегированным
    `User=` (`pve_exporter`/`mysqld_exporter`, P1-11) — процесс не мог прочитать собственный
    config.file/`--config.my-cnf`. Исправлено переносом создания пользователя ДО рендера файла и
    рендером сразу с правильным владельцем (не последующим `chown`-патчем поверх — так было бы
    неидемпотентно: рендер каждый раз возвращал бы `root:root`, а патч — откатывал обратно):
    - `tasks/exporters-pve-exporter.yml` — `pve.yml` рендерится только когда
      `monitoring_agent_orchestrator == systemd` гарантирован предыдущим fail-fast'ом (№10), поэтому
      пользователь создаётся безусловно перед рендером, owner/group — сразу имя пользователя.
    - `tasks/monitoring-agent.yml` — `.mysqld_exporter_my.cnf` рендерится для ОБОИХ оркестраторов
      (под docker монтируется в контейнер, там `root:root` корректен), поэтому owner/group
      вычисляются условно (`... if monitoring_agent_orchestrator == 'systemd' else 'root'`), а
      пользователь создаётся заранее только для systemd-ветки.
    Проверено полным прогоном `molecule test -s monitoring_agent`: converge → idempotence (0
    изменений на обоих хостах) → verify (реальный `curl :9100/metrics`, `pve_exporter` слушает
    `:9221`, `.venv`/pip-путь). До этой находки роль ни разу не тестировалась с
    `monitoring_agent_pve_exporter_enabled: true` под systemd — баг существовал с момента
    появления pve-exporter в коллекции.
57. ~~**`monitoring_agent_ipa_exporter_binary_checksum` не совпадает с реальным артефактом.**~~ —
    **исправлено**: `roles/monitoring_agent/defaults/main.yml` — `get_url` падал `checksum mismatch`
    (заявлено `e2718c8c...`, реально `5b9264b0d9f72b849de7dce671d68a751710d90fc43d8da8d45bbcc0d23f6465`,
    подтверждено самим `get_url` на живом хосте). Найдено первым реальным включением
    `monitoring_agent_ipa_exporter_enabled: true` (platform/aicd-devops-labs-ru, разворачивание
    экспортёров на freeipa) — `extensions/molecule/monitoring_agent` этот путь не покрывает
    (`ipa_exporter` не включён ни в один group_vars сценария), поэтому баг с самого появления
    `ipa_exporter` в коллекции не мог быть пойман CI. Стоит рассмотреть добавление
    `monitoring_agent_ipa_exporter_enabled: true` в один из хостов сценария — не сделано в рамках
    этой находки (нужен доступный FreeIPA/LDAP-сервер для позитивной проверки, не просто systemd
    is-active, иначе тест не поймал бы даже эту находку — сам процесс поднимается независимо от
    того, отвечает ли реальный FreeIPA).
58. ~~**`ipa_exporter` не запускался на Rocky 9: GLIBC_2.35 (бинарь) + `KeyError:
    'numSubordinates'` (код).**~~ — **исправлено**, двумя независимыми находками одного и того же
    первого реального включения `monitoring_agent_ipa_exporter_enabled: true`
    (platform/aicd-devops-labs-ru, см. №57 выше):
    1. Бинарь `freeipa-exporter` (PyInstaller, GitHub-релиз v1.0.0) требовал GLIBC_2.35+, Rocky 9
       (ADR-0011) даёт только 2.34 — crash-loop сразу после старта
       (`Failed to load Python shared library ... GLIBC_2.35' not found`). Пересобран на
       `python:3.12-slim-bullseye` (glibc 2.31 — запас совместимости) через новый стейдж
       `pyinstaller-artifact` в `ADDONS/exporters/freeipa_exporter/Dockerfile` и опубликован в
       новый raw-hosted репозиторий `internal-releases` того же Nexus (не в публичный GitHub —
       ADR-0018 §9, отдельное решение остаётся вне скоупа).
    2. После починки glibc бинарь стартовал, но падал на первом же реальном LDAP-запросе:
       `_count_users`/`_count_hostgroups` (`ADDONS/exporters/freeipa_exporter/code/
       freeipaserver.py`) читали операционный атрибут `numSubordinates`, доступный только
       привилегированным bind'ам (Directory Manager) — обычный сервисный аккаунт
       (`svc-monitoring`) получал запись без этого атрибута вовсе (`KeyError`, не пустой
       результат поиска). Исправлено переходом на прямое перечисление записей (`SCOPE_ONELEVEL`
       + `len(results)`) — тот же рабочий паттерн, что уже использовали остальные `_count_*` в
       том же файле (`_count_groups`/`_count_hosts`).
    Оба бага не могли быть пойманы `extensions/molecule/monitoring_agent` (см. №57 — там
    `ipa_exporter` не включён вовсе) и специфичны для пути «обычный LDAP-пользователь + Rocky 9»,
    который до этого дня ни разу не проходил живую проверку с момента появления `ipa_exporter` в
    коллекции.

---

## P1 — Безопасность

11. ~~**Секреты пишутся в мирочитаемые файлы (`mode: '0644'`)**~~ — **исправлено**: везде, где
    рендерились файлы с секретами, проставлен `mode: '0600'` и добавлен `no_log: true` на саму
    задачу рендеринга:
    - `roles/monitoring_server/tasks/monitoring-server.docker.yml` — `compose.yml` с
      `GF_SECURITY_ADMIN_PASSWORD`.
    - `roles/monitoring_agent/tasks/monitoring-agent.yml` — `.mysqld_exporter_my.cnf` (пароль MySQL)
      и docker `compose.yml` (`REDIS_PASSWORD`/`FREEIPA_BIND_PW`).
    - `roles/monitoring_agent/tasks/exporters-pve-exporter.yml` — `pve.yml` (Proxmox API токен).
    - `roles/monitoring_agent/tasks/systemd-ipa-exporter.yml` и `systemd-redis-exporter.yml` —
      systemd unit-файлы с `FREEIPA_BIND_PW`/`REDIS_PASSWORD`.
12. ~~**Нет проверки, что дефолтные S3/MinIO credentials были заменены.**~~ — **исправлено**:
    `check-and-install-requirements.docker.yml` теперь падает явным `fail`, если
    `monitoring_server_local_storage_s3_enabled: true` и `access_key`/`secret_key` совпадают со
    значениями по умолчанию (`local_storage_s3`/`supersecret_local_storage_s3`) — по аналогии с уже
    существующей проверкой пароля Grafana.
13. ~~**Нет проверки контрольных сумм при загрузке бинарников экспортеров.**~~ — **исправлено**:
    все семь `roles/monitoring_agent/tasks/systemd-*-exporter.yml`, качающих бинарник через
    `get_url` (node, redis, nginx, nginxlog, php-fpm, ipa, mysqld — pve-exporter ставится через pip
    и `get_url` не использует), теперь передают `checksum: "{{ ..._binary_checksum }}"`. Значения
    `sha256:<hash>` в `roles/monitoring_agent/defaults/main.yml` получены с официальных
    checksums-файлов релизов (для `ipa-exporter`, у которого нет публикуемого checksums-файла в
    собственном релизе `vinogradovia/ansible-devops-uslugi` — посчитаны из скачанного по HTTPS
    релизного архива) и зафиксированы под уже закреплённые в defaults версии.
14. ~~**`xanmanning.k3s` — обязательная зависимость роли, но закомментирована в `galaxy.yml`.**~~ —
    **исправлено**: `galaxy.yml.dependencies` — поле для *коллекций* (`namespace.name`), а
    `xanmanning.k3s` — standalone-роль, а не коллекция, поэтому раскомментирование сломало бы
    `ansible-galaxy collection build/publish`. Вместо этого зависимость зафиксирована в новом
    `requirements.yml` в корне коллекции (`roles: [{name: xanmanning.k3s, version: v3.6.4}]` —
    для ролей, в отличие от коллекций, `requirements.yml` не поддерживает диапазоны версий,
    только точный тег), задокументирована в `README.md`/`CLAUDE.md`, комментарий в `galaxy.yml`
    объясняет, почему зависимость не может быть объявлена там.

---

## P2 — Надёжность / идемпотентность

15. ~~**Kubeconfig k3s выгружается на control-хост и никогда не удаляется, без явного
    `become: true` на самой задаче.**~~ — **исправлено**: `Fetch k3s context`
    (`monitoring-server.k3s.yml`) теперь явно `become: true` (не полагается на глобальный
    become плейбука). Kubeconfig используется вплоть до самого конца `tasks/main.yml`
    (`victoria-metrics-provisioning-exporter-targets.yaml`,
    `victoria-metrics-provisioning-alerts.yaml`, `grafana-provisioning-dashboard.yaml` — все берут
    `kubeconfig: "{{ monitoring_server_orchestrator_context.dest }}"` внутри своих
    `when: orchestrator == 'k3s'` блоков), поэтому удалить его раньше было нельзя — добавлена
    финальная задача в конце `tasks/main.yml` (`delegate_to: localhost`, после блока
    `GrafanaDashboards`), которая удаляет файл с control-хоста, когда он больше никому не нужен.
16. ~~**`check-and-install-requirements.docker.yml` выполняется безусловно**~~ — **исправлено**, но
    не простым добавлением `when: orchestrator == 'docker'`: проверка дефолтного пароля Grafana
    внутри этого файла на самом деле нужна **обоим** оркестраторам — `monitoring-server.k3s.yml`
    создаёт `Secret grafana-credentials` с этим паролем безусловно, без
    `when: monitoring_server_grafana_enabled`. Наивное добавление гейта `docker` сняло бы эту
    защиту для k3s. Вместо этого проверка Grafana вынесена в новый общий
    `check-and-install-requirements.yml` (выполняется для обоих оркестраторов), а в
    `check-and-install-requirements.docker.yml` остаётся только проверка дефолтных S3-credentials
    (действительно docker-specific — S3/MinIO есть только в docker-compose), и теперь этот файл
    корректно гейтится `when: monitoring_server_orchestrator == 'docker'` в `tasks/main.yml`,
    как и k3s-аналог.
17. ~~**`reverse_proxy_traefik`: `check-and-install-requirements.yml` не устанавливает Docker.**~~ —
    **исправлено** новой ролью `docker` (`docs/adr/0002-docker-role.md`): `reverse_proxy_traefik/
    meta/main.yml` теперь безусловно зависит от `docker`, которая ставит Docker Engine из
    официального репозитория перед запуском собственных задач роли. Та же роль подключена
    условно (`when: ..._orchestrator == 'docker'`) в `monitoring_server` и `monitoring_agent`.
18. ~~**nginx-exporter: версия docker-образа и systemd-бинарника расходятся.**~~ — **исправлено**:
    `monitoring_agent_nginx_exporter_image_version` в `defaults/main.yml` поднят с `1.4.1` до
    `1.5.0` — теперь совпадает с версией systemd-бинарника (`v1.5.0`), docker- и systemd-деплой
    запускают одну и ту же версию экспортера.
19. ~~**`roles/infra_dns/tasks/deploy_zone.yml` зависит от `ansible_date_time`, который не
    гарантирован**~~ — **исправлено**: заменено на Jinja-глобал `now(utc=true, fmt='%Y%m%d')`,
    который не требует `gather_facts` вообще (не читает факты хоста, вычисляется на
    control-ноде) — роль по-прежнему без `meta/main.yml`, но больше не зависит от того, собрал
    ли вызывающий плей facts.
20. ~~**Дефолтный `soa_contact` для reverse-зон некорректен.**~~ — **исправлено**: вместо попытки
    автоматически вывести валидный домен из PTR-зоны (`30.20.10.in-addr.arpa` не содержит
    информации, из которой можно построить существующий email-домен), `deploy_zone.yml` теперь
    явно падает `assert`'ом, если `zone.name` — reverse-зона (`*.in-addr.arpa`/`*.ip6.arpa`) и
    `zone.soa_contact` не задан. Требование задокументировано в `defaults/main.yml` вместе с
    примером reverse-зоны в комментарии.
21. ~~**`roles/nginx/tasks/deploy-site-templates.yml` и `tests/deploy_nginx_sites*.yml` гейтятся на
    `when: ansible_host is defined`**~~ — все три файла удалены вместе с ролью `nginx`
    (`roles/nginx/tasks/deploy-site-templates.yml`, `tests/deploy_nginx_sites.yml`,
    `tests/deploy_nginx_sites_test.yml`). `nginx_multidomain` деплоит vhost'ы без такого гейта.
37. ~~**`monitoring_server`: `loki_backend` не объявляет `depends_on: [s3]`**~~ (найдено при ревью
    `docs/adr/0007-monitoring-server-role.md` §10.1, не было в `ROADMAP.md`) — **исправлено**:
    в отличие от `loki_read`/`loki_write`, `loki_backend` в `compose-monitoring-server.yml.j2` не
    имел `depends_on`, хотя тоже обращается к S3 (компактор). Добавлен `depends_on: - s3`.
38. ~~**`monitoring_server`: версии `victoria-metrics`/`grafana` не закреплены (`:latest`)**~~
    (ADR-0007 §10.2) — **исправлено**: добавлены `monitoring_server_victoria_metrics_image_version`
    (`v1.148.0`) и `monitoring_server_grafana_image_version` (`13.1.1`, без `v` — тег образа
    отличается от схемы `victoria-metrics`/`loki`, обе версии проверены через Docker Hub API),
    тот же паттерн `_registry`/`_name`/`_version`/`_image`, что у `loki`/`s3`.
39. ~~**`monitoring_server`: нет проверки существования внешней docker-сети `proxy`**~~ (ADR-0007
    §10.3) — **исправлено**: `victoria-metrics`/`grafana` безусловно подключены к внешней сети
    `monitoring_server_docker_proxy_network_name` (`external: true` по умолчанию) — если её нет,
    `docker compose config`-валидация это не ловит (проверяет только синтаксис), и падает уже
    `community.docker.docker_compose_v2` с менее очевидной ошибкой. Новая проверка в
    `check-and-install-requirements.docker.yml` — `docker network inspect` через
    `ansible.builtin.command` (не `community.docker.docker_network_info` — тому нужен python-пакет
    `docker` на целевом хосте, которого роль `docker` не ставит), падает понятной ошибкой заранее.
46. ~~**`postgresql_replication`/`mysql_replication`: идемпотентная регистрация в `repmgr` не
    сверяет `node_id`.**~~ — **исправлено**: `tasks/replication-user.yml`/`configure-replica.yml` пропускают `repmgr
    primary register`/`standby register`, если `node check --role` уже успешен (узел уже
    зарегистрирован) — но не проверяют, что зарегистрированный в кластере `node_id`/`node_name`
    совпадает с текущим `postgresql_replication_node_id`/`repmgr.conf`. При этом `repmgr.conf`
    перетемплейтится безусловно на каждом прогоне (`template`-задача без гейта) — если
    `group_vars` хоста поменяли задним числом (например, поправили `node_id` уже после первичной
    регистрации), локальный конфиг молча разъезжается с тем, что реально числится в
    `repmgr.nodes`. Обнаруживается не сразу, а обычно в разгар аварии/failback, когда `repmgr node
    rejoin`/`standby register` падает с `ERROR: unable to retrieve node record for the local
    node` — воспроизведено на реальном инциденте (failback по
    `docs/runbooks/postgresql-failover.md`, раздел 3, шаг 3: у хоста в `repmgr.conf` был
    `node_id=1`, а в кластере он значился под `node_id=2`, ровно как и в `group_vars`, откуда
    `repmgr.conf` рендерится). Чинить: `assert`/явная проверка перед пропуском
    register-задачи — добавлена: `SELECT node_id FROM repmgr.nodes WHERE node_name = ...` (только
    когда `node check --role` уже нашёл рабочую регистрацию), `assert` fail-fast при расхождении с
    `postgresql_replication_node_id` — и на primary (`replication-user.yml`), и на репликах
    (`configure-replica.yml`). Проверено полным прогоном
    `extensions/molecule/postgresql_replication` (create → prepare → converge → idempotence →
    verify, три хоста, включая failback) — `idempotence` по-прежнему `changed=0`. Тезис про
    `mysql_replication` не подтвердился при проверке: там нет repmgr/node registry вообще
    (репликация — нативный MySQL GTID без понятия `node_id`), сверять нечего.

54. **`postgresql_replication`: `read_replica` не переподключается к новому primary после
    failback — `repmgr cluster show` показывает disconnected upstream.** Найдено при валидации
    Фазы 3 (bareos, №48, ниже) реальным прогоном `extensions/molecule/postgresql_replication` —
    первый раз verify дошёл настолько далеко в promote/failback-последовательности (раньше
    зависал на bareos-джобе, см. №48). После полного цикла stop-primary → promote dr_replica →
    rejoin старого primary как standby, задача «Repmgr cluster show после rejoin» падает:
    `postgresql-read-replica` (ID 2) — `not attached to its upstream node "postgresql-primary"`,
    `! postgresql-primary` в connection string. Топология статических IP (роль хоста меняется,
    адрес — нет, ADR §5): когда исходный primary остановлен, физическая streaming-связь
    `read_replica` с ним рвётся; ни `docs/runbooks/postgresql-failover.md`, ни verify.yml не
    содержат явного шага «переподключить/переклонировать read_replica к новому primary» — только
    rejoin для бывшего primary. **Корневая причина не подтверждена окончательно** (правдоподобно:
    отсутствующий шаг `repmgr standby follow`/reclone для read_replica; не исключена и таймингова
    гонка, не связанная с топологией) — это первый прогон, дошедший до этой точки, требует
    отдельного расследования прежде чем чинить.

---

## P3 — Мёртвый код и репозиторный мусор

23. ~~**`roles/monitoring_server/templates/__delete/`**~~ — **исправлено удалением**: каталог
    полностью не использовался ни одной задачей (подтверждено grep), `GrafanaDashboard.j2` внутри
    к тому же был синтаксически битый (два ключа `spec:`) — удалён целиком.
24. ~~**Файлы alert-правил с подчёркиванием в имени — повторяющийся паттерн черновиков, не
    единичный случай.**~~ — **исправлено**: все три файла
    (`templates/alert-rules/proxmox-ve/prometheus-pve-exporter_.yml`,
    `templates/alert-rules/redis/oliver006-redis-exporter_.yml`,
    `templates/alert-rules/blackbox/blackbox-exporter_.yml`) удалены — решение владельца
    коллекции: черновики, никогда не подключённые через `vars/main.yml`, не оформлять как
    альтернативу, а убрать как мусор.
25. ~~**`templates/alert-rules/grafana-alloy/embedded-exporter.yml` полностью не подключён**~~ —
    перенесено в «Backlog фич» ниже (не мёртвый код, а незавершённая функциональность — см. п. 35).
26. ~~**Дублированная документация `nginx_multidomain` в двух местах**~~ — `roles/nginx/docs/`
    удалён вместе с ролью `nginx`, дублирования больше нет. **Уборка `roles/nginx_multidomain/docs/`
    тоже сделана**: помимо упомянутых `files.zip`/`nginx_multidomain_role_skeleton.tar.gz`, в
    каталоге обнаружились их же распакованные копии (`main.yml`, `static.conf.j2`,
    `mnt/user-data/outputs/nginx_multidomain/tasks/main.yml` — артефакт неудачной распаковки
    архива в чужой вложенный путь) — черновик первой скелетной генерации роли, разошедшийся с
    актуальной реализацией. Все пять файлов удалены, каталог `docs/` теперь пуст. Заодно исправлена
    ставшая битой после переименования/переноса ссылка на архитектурный документ: он живёт в
    `docs/adr/0003-nginx-multidomain-role.md` в корне коллекции, а не в `roles/nginx_multidomain/docs/`
    (обновлены CLAUDE.md и собственное дерево каталогов внутри самого документа).
27. ~~**Два висячих (никогда не вызываемых) handler'а**~~ — **исправлено**: подтверждено `grep`
    по `notify:` во всех `tasks/systemd-*-exporter.yml`, что `State service node-exporter.socket`/
    `State service nginx-exporter.socket` нигде не notify'ятся (задачи в `systemd-node-exporter.yml`/
    `systemd-nginx-exporter.yml` дублируют их содержимое inline), оба handler'а удалены из
    `roles/monitoring_agent/handlers/main.yml`.
28. ~~**Молёкула-сценарий `reverse_proxy_traefik` фактически не рабочий, а не просто неполный**~~
    — **исправлено удалением**: `extensions/molecule/reverse_proxy_traefik/` был untracked-каркасом
    (`molecule.yml` нулевого размера — не распознаётся molecule как сценарий вообще,
    `converge.yml` не вызывал роль, `test_traefik.py` падал на `NameError` при сборе тестов, плюс
    копипаст-ассерт `"Welcome to nginx"` против приложения `traefik/whoami`). Удаление не убавляет
    покрытия — рабочего сценария и не было. Пересборка с нуля остаётся отдельной P4-задачей (см.
    таблицу P4 ниже).
29. ~~**`roles/nginx/README.md:42-49` отсылает к `extensions/molecule/nginx`, у которого нет
    `molecule.yml`**~~ — оба файла удалены вместе с ролью `nginx`.
30. ~~**`roles/reverse_proxy_traefik/README.md`** — неотредактированная заготовка
    `ansible-galaxy init`~~ — **исправлено**: написан реальный README (назначение роли,
    взаимоисключаемость с `nginx_multidomain`/`reverse_proxy_npm`, обязательная проверка пароля
    дашборда, устройство дашборда/fixture-приложения `whoami`, известные ограничения — TLS не
    автоматизирован).
31. ~~**Мелкие огрехи, не блокирующие, но стоящие отдельного PR:**~~ — **исправлено**:
    - `roles/reverse_proxy_traefik/tasks/check-and-install-requirements.yml` — опечатка в тексте
      ошибки («hange default_passwors» → «change reverse_proxy_traefik_default_password») и в
      имени задачи; проверка дефолтного пароля теперь пропускает пользователей с
      `item.state == 'absent'` (в дефолтах уже есть пример такого пользователя —
      `reverse_proxy_traefik_dashboard_users` содержит `olduser`/`state: absent`).
    - `roles/monitoring_agent/tasks/systemd-pve-exporter.yml` — удалена мёртвая
      check-mode-задача «Check if pve-exporter user exit», опиравшаяся на несуществующее поле
      `state` в возврате модуля `ansible.builtin.user` (подтверждено чтением `RETURN`-блока
      модуля — такого поля там нет, ветка была недостижима). `state:` в задаче «Add the user for
      pve-exporter» упрощён до `'present' if monitoring_agent_pve_exporter_enabled else 'absent'`
      — поведение не изменилось, недостижимая ветка просто убрана.
    - ~~`roles/nginx/tasks/main.yml:31` — Jinja-в-`when` антипаттерн~~ и
      ~~`tests/deploy_nginx_sites.yml`/`tests/deploy_nginx_sites_test.yml` — scratch-файлы,
      ссылка на несуществующую `ansible_env_vars`~~ — все три файла удалены вместе с ролью
      `nginx`.
40. ~~**Забытые артефакты `helm/tmp/`/`helm/.claude/` не в `.gitignore`**~~ (ADR-0007 §10.4, не
    было в `ROADMAP.md`) — при проверке оказалось уже **сделано**: обе директории (kubeconfig-и
    от `Fetch k3s context`, vendor-кэш `helmwave build`, локальные настройки Claude Code) уже
    в `.gitignore` корня коллекции. Сама находка была про риск случайного попадания в git — он
    снят; физически оставшиеся на диске артефакты прошлых прогонов — локальная уборка рабочей
    директории, не задача коллекции.
41. ~~**`nginx_multidomain`: assert на `domain.type` (fail-fast для `php_fpm`-заглушки, добавлен
    ранее в этой же сессии, см. таблицу P4 и `docs/adr/0003-nginx-multidomain-role.md` §8.5) не
    учитывал `domain.enabled: false`**~~ (найдено `/code-review` этой же сессии) —
    **исправлено**: добавлен `when: item.enabled | default(true)`, симметрично тому, как
    уже гейтятся циклы `vhosts.yml`/`vhost_absent.yml`. До фикса выключенный домен-заготовка
    (`enabled: false`, `type: php_fpm`) — раньше молча игнорировался обоими циклами — после
    добавления assert'а стал ронять весь play, хотя рендериться/убираться всё равно не должен был.
42. ~~**`nginx_multidomain`: проверка §9.4 (`sites-enabled` в `nginx.conf`) — наивный
    substring-поиск, проходит даже на закомментированном `include`**~~ (найдено `/code-review`) —
    **исправлено**: заменено на `is regex('^[^#\n]*sites-enabled', multiline=True)` — не совпадает,
    если "sites-enabled" встречается только в закомментированной строке. Заодно задокументировано в
    самом `fail_msg`: пакет `nginx.org` (`nginx_install_method: repo`) не подключает
    `sites-enabled` по умолчанию (только `conf.d`), в отличие от Debian/Ubuntu-пакета — проверено
    эмпирически, реальной установкой пакета в чистом Debian 12. Это не регрессия, а корректное
    срабатывание assert'а на не покрытый molecule-сценарием случай (`extensions/molecule/
    nginx_multidomain/` проверяет только `install_method: package`) — фикс тестового покрытия
    для `repo`-метода остаётся отдельной задачей.
43. ~~**`monitoring_server`: во всех 11 `victoria-metrics-scrape-*-targets.json.j2` персональный
    override порта агента (`monitoring_agent_*_port`) читается как голая переменная, а не
    `hostvars[host].get(...)`**~~ (найдено `/code-review` при проверке нового
    `victoria-metrics-scrape-grafana-alloy-targets.json.j2` — тот же паттерн скопирован из всех
    остальных шаблонов, воспроизводит существующий баг, а не создаёт новый) — **исправлено** во
    всех 10 затронутых шаблонах (`prom-client` не имеет per-host порта вообще). Раньше override
    порта для конкретного agent-хоста (host_vars, например при конфликте портов) молча
    игнорировался — использовался дефолтный порт для всех хостов сразу. Заодно нашёлся отдельный,
    не связанный с этой сессией баг того же ревью: `victoria-metrics-scrape-docker-exporter-
    targets.json.j2` использовал `monitoring_agent_node_exporter_port` (порт **другого**
    экспортёра, явная опечатка copy-paste) вместо `monitoring_agent_docker_exporter_port` —
    тоже исправлено.

44. ~~**Унифицировать driver всех molecule-сценариев на `vagrant`/`libvirt`**~~ (явное требование
    пользователя, 2026-07-31) — **сделано**: `nginx_multidomain`, `reverse_proxy_npm`,
    `reverse_proxy_traefik`, `infra_dns`, `monitoring_agent` мигрированы с `driver: docker`
    (одноразовый systemd-контейнер `geerlingguy/docker-debian12-ansible`) на `driver: vagrant` +
    `provider: libvirt` (box `cloud-image/ubuntu-24.04`), тот же паттерн, что уже использовали
    `mysql_replication`/`proxysql`/`monitoring_server`/`monitoring_server_k3s`. Полноценная ВМ
    убрала целый класс docker-in-docker обходов, которые раньше приходилось поддерживать вручную:
    `storage-driver: vfs` (`reverse_proxy_traefik/group_vars/all.yml`,
    `monitoring_agent/group_vars/monitoring_agent_docker.yml`), `mount --make-rshared /` для
    `rslave`-бинда `node_exporter` (`monitoring_agent/prepare.yml`), ожидание готовности systemd
    внутри контейнера (заменено на `cloud-init status --wait` во всех `prepare.yml`). Заодно нашёлся
    и исправлен баг, который раньше маскировался тем, что box был Debian: `reverse_proxy_npm/
    prepare.yml` подключал apt-репозиторий Docker по захардкоженному пути `linux/debian` — на новом
    box (Ubuntu) это ломало `apt update` ("does not have a Release file"); исправлено на
    `ansible_distribution | lower` (тот же приём, что `roles/docker/tasks/install-repo.yml`). Все
    пять сценариев перепрогнаны целиком (`create → prepare → converge → idempotence → verify →
    destroy`) на реальных libvirt ВМ — зелёные. `molecule-plugins[docker]` убран из dev-зависимостей
    `pyproject.toml` (`poetry lock`/`install` обновили `poetry.lock`) — ни один сценарий больше не
    использует `driver: docker`; единственное осознанное исключение —
    `extensions/molecule/docker/` (`driver: default`, только `syntax/create/destroy`, см. её
    комментарии и ADR-0002 §8). См. CLAUDE.md, «Molecule-тесты», для актуального описания.

45. ~~**Molecule-сценарии, которым нужен Docker на хосте, должны получать его через роль `docker`
    коллекции, а не ad-hoc apt-задачами**~~ (явное требование пользователя, 2026-07-31, цель —
    переиспользовать уже проверенную установку и унифицировать создаваемое Docker-окружение между
    сценариями) — **сделано**: единственным нарушением был `extensions/molecule/reverse_proxy_npm/
    prepare.yml` (сама роль `reverse_proxy_npm` Docker не ставит) — вручную повторял
    apt-репозиторий/GPG-ключ/пакеты (тот же код, что чинился в №44 под Ubuntu). Заменено на
    `ansible.builtin.include_role: name: docker` — теперь то же самое Docker-окружение (пиннинг
    версии, arch/distro-логика), что и в `reverse_proxy_traefik`/`monitoring_agent`/
    `monitoring_server`, где эту роль подключает зависимость самой роли через `meta/main.yml`.
    Остальные docker-сценарии уже не нарушали это правило — Docker в них ставится в рамках
    `converge` самой ролью-зависимостью. Сценарий перепрогнан целиком — зелёный.

---

## P4 — Тестовое покрытие

**Проверено 2026-07-31:** все сценарии из таблицы ниже, а также `extensions/molecule/
mysql_replication/` и `extensions/molecule/proxysql/` (не входят в эту таблицу, но тоже часть
покрытия P4), перепрогнаны целиком на реальных libvirt ВМ после миграции №44/№45 и подтверждены
зелёными: `monitoring_server` (docker-оркестратор — полный стек VictoriaMetrics/Grafana/Loki/MinIO,
реальный scrape node-exporter), `monitoring_server_k3s` (реальный `Helmwave up`, все 6 helm-релизов
`deployed`, поды готовы, VMRule/GrafanaDashboard/GrafanaDatasource на месте, тестовая запись реально
прошла через Loki), `monitoring_agent` (обе платформы, включая idempotence), `infra_dns`,
`nginx_multidomain`, `reverse_proxy_traefik`, `reverse_proxy_npm` (включая повторный прогон после
№45), `mysql_replication` (реальная GTID-репликация primary → read/DR-реплики) и `proxysql`
(реальная маршрутизация SELECT/INSERT через ProxySQL). Единственные failed-строки в логах —
штатные `FAILED - RETRYING` на `until`/retry-ожиданиях (scrape, готовность подов, API), не баги.

| Роль | Что есть сейчас | Чего не хватает |
|---|---|---|
| `monitoring_server` | ~~Нет molecule-сценария вообще~~ — **сделано**: два независимых сценария, `extensions/molecule/monitoring_server/` (`monitoring_server_orchestrator: docker`) и `extensions/molecule/monitoring_server_k3s/` (`monitoring_server_orchestrator: k3s`), оба `driver: vagrant`/`libvirt` (см. CLAUDE.md, раздел «Molecule-тесты»). docker-сценарий — full-стек (VM + Grafana + Loki + MinIO), verify проверяет реальный scrape node-exporter. k3s-сценарий крупнее (k3s + VictoriaMetrics Operator + grafana-operator + grafana-alloy через реальный `Helmwave up`) и без idempotence в `test_sequence` (`Helmwave up` — `ansible.builtin.command` без `changed_when`-анализа, всегда `changed=true`). | ~~`meta/main.yml` для роли по-прежнему отсутствует~~ — неверно, у роли уже есть `meta/main.yml` (`dependencies: docker`/`xanmanning.k3s`). Idempotence для k3s-сценария не достижима без переписывания задачи `Helmwave up` на `changed_when`-анализ stdout `helmwave` — отдельная задача. |
| `monitoring_agent` | ~~Нет molecule-сценария~~ — **сделано**: `extensions/molecule/monitoring_agent/` (`driver: vagrant`/`libvirt`, две платформы в одном сценарии — паттерн `mysql_replication`/`group_vars/<group>.yml`, а не два отдельных сценария; см. №44). `monitoring-agent-docker`: `node_exporter` + `docker_exporter` (проверка ключа `metrics-addr` в `/etc/docker/daemon.json`) + regression-проверка P0-10 (pve-exporter под docker падает fail-fast, а не молча игнорируется). `monitoring-agent-systemd`: `node_exporter` (socket activation) + `pve_exporter` (позитивный путь). Первый же прогон поймал реальный, ранее не описанный P0-баг (№36) — `pve_exporter`/`mysqld_exporter` крашились под systemd с `PermissionError`, читая собственный config-файл (`root:root:0600` против `User=<exporter>`), исправлено в том же PR. | ~~`meta/main.yml` для роли по-прежнему отсутствует~~ — неверно, у роли уже есть `meta/main.yml` (`dependencies: docker`). Остальные экспортеры (redis/nginx/nginxlog/php-fpm/ipa) в сценарий не включены — за пределами формулировки задачи («хотя бы по одному»). |
| `infra_dns` | ~~Только ручной `tests/deploy_infra_dns.yml`~~ — **сделано**: `extensions/molecule/infra_dns/` (`driver: vagrant`/`libvirt`, см. №44 — bind9 обычный systemd-сервис, без docker вообще). Converge покрывает forward-зону (дефолтный `soa_contact`, `include_hosts: true`) и reverse-зону (явный `soa_contact`, `include_hosts: false`). Verify гоняет реальный `named-checkconf` на полном `/etc/bind/named.conf` + `named-checkzone` на обоих зона-файлах (ловит P2-19/P2-20), права `bind:bind`/`0640`, наличие/отсутствие `$INCLUDE`-файла и функциональные `dig`-запросы (A, CNAME, `-x`/PTR) через реально поднятый `named`. Прогон зелёный, включая `idempotence` (0 изменений на повторном converge) — багов не найдено. | ~~`meta/main.yml` для роли по-прежнему отсутствует~~ — **сделано**, `roles/infra_dns/meta/main.yml` добавлен (`dependencies: []`). Негативный путь (reverse-зона без `soa_contact` → `assert`-fail, P2-20) сценарий не проверяет — только структурно валидные зоны. |
| `nginx_multidomain` | ~~Роль `nginx` удалена (п.31)~~ — **сделано**: `extensions/molecule/nginx_multidomain/` (`driver: vagrant`/`libvirt`, см. №44). Converge покрывает `type: static` и `type: proxy` (upstream-пул, `extra_upstreams`, custom-сертификаты, rate-limit/proxy-cache зоны, `conf_d_files`, `stub_status`, `enabled: false`). Verify гоняет реальный `nginx -t` + ansible-проверки (сервис running, symlink'и, дедуп зон, регрессия §9.1, функциональные `uri`-запросы на override-location и 502 от недоступного backend'а). `basic_auth`/`json`-логи (§8.3/8.4/9.3) намеренно не включены в сценарий — они по-прежнему ломают `nginx -t`, это осознанно задокументированный пробел, а не забытый. Первый же прогон сценария поймал реальный, ранее не описанный баг: `proxy_cache_zones.yml` не создавал `zone.path` (`nginx -t` падал на `mkdir()` для любого использования `nginx_proxy_cache_zones`) — исправлено в том же PR, см. архитектурный документ роли, раздел 6. | ~~`meta/main.yml` для роли по-прежнему отсутствует (см. §8.5 документа)~~ — **сделано**, `roles/nginx_multidomain/meta/main.yml` добавлен (`dependencies: []`). Когда баги §9.3 (basic_auth/json-логи) будут починены — добавить в сценарий домен, покрывающий оба случая, вместо текущего осознанного исключения. |
| `reverse_proxy_traefik` | ~~Нет molecule-сценария вообще~~ — **сделано**: `extensions/molecule/reverse_proxy_traefik/` (`driver: vagrant`/`libvirt`, та же структура, что `nginx_multidomain`/`reverse_proxy_npm`; см. №44). Converge реально вызывает роль (`import_role`); в отличие от удалённого нерабочего каркаса (см. P3 №27), fixture-приложение (`traefik/whoami`) не поднимается отдельно — оно уже часть compose-файла роли. Verify проверяет HTTP→HTTPS редирект, реальный ответ `whoami` через Traefik (вместо скопипащенного и никогда не совпадающего ассерта `"Welcome to nginx"` из старого каркаса) и basic-auth дашборда (401 без credentials, 200 с ними). | — |
| `mysql_replication` | `extensions/molecule/mysql_replication/` — converge+verify покрывают штатную репликацию (primary/read_replica/dr_replica), но **не** ручной promote (`tasks/promote.yml`, теги `mysql_replication_promote`+`never`, ADR-0004 §7) — молекула этот путь вообще не запускает. | Добавить в `verify.yml` последний шаг по образцу `extensions/molecule/postgresql_replication/verify.yml` (реализовано для ADR-0005): негативный тест (promote должен быть отклонён assert'ом на хосте, где `mysql_replication_role != 'dr_replica'`) + позитивный (реальный `RESET REPLICA ALL` на dr_replica через `include_role`/`tasks_from: promote`, проверка `read_only=OFF` и записи после promote). Не просто «для полноты» — именно эта работа для `postgresql_replication` вскрыла реальный баг (`include_tasks` + `tags`/`never` без `apply.tags` молча не выполнял promote при `--tags ..._promote --limit <host>`, задача-include матчилась, а вложенные задачи — нет), который идентично воспроизводится и в `mysql_replication/tasks/main.yml` (уже исправлено отдельным патчем — добавлен `apply.tags` — но регрессионного теста на этот конкретный баг пока нет, потому что нет молекулы для promote вообще). |

---

## P5 — Архитектурные развилки (требуют решения, не только патча)

32. ~~**Судьба роли `nginx` vs `nginx_multidomain`**~~ — **решено и выполнено**: роль `nginx`
    была экспериментом и удалена из коллекции полностью
    (`roles/nginx/`, `extensions/molecule/nginx/`, `tests/deploy_nginx_sites.yml`,
    `tests/deploy_nginx_sites_test.yml`). `nginx_multidomain` — единственная и окончательная
    nginx-роль коллекции; конфликт №8 и находки №6/№7/№21/№26/№28(nginx-часть)/№29/№31(nginx-часть)
    сняты вместе с удалением. CLAUDE.md обновлён, чтобы не упоминать `nginx` как отдельную роль.
    Риск §9.4 архитектурного документа `nginx_multidomain` (роль полагается на нетронутый
    стоковый `nginx.conf` с `include sites-enabled/*`) был внешней предпосылкой для деплоя, а не
    межролевым конфликтом — с тех пор тоже закрыт явным `assert`'ом (см. п. 8 выше).
33. ~~`nginx_multidomain` уже разошлась с собственным архитектурным документом~~ — **решено и
    выполнено**: документ (`roles/nginx_multidomain/docs/nginx_multidomain_role_architecture.md`)
    переписан под фактическую реализацию, а не наоборот. Новая версия документа фиксирует:
    - реальную структуру задач/шаблонов (`snippets/*.j2` и `_default_locations` заменены на
      инлайн-логику в `vhost/static.conf.j2`/`vhost/proxy.conf.j2`, override работает только для
      `location /`);
    - новую функциональность, которой не было в исходном замысле (`proxy_cache_zones.yml` +
      `nginx_proxy_cache_zones`, `conf_d_files.yml`);
    - честный статус отсутствующих кусков (§8: `validate_domains.yml`,
      `certificates_letsencrypt.yml`, `basic_auth.yml`, `logrotate.yml`, `vhost/php-fpm.conf.j2`,
      `meta/main.yml`, `vars/Debian.yml`/`Ubuntu.yml`, molecule);
    - важное уточнение, не замеченное в первом проходе ревью: `basic_auth.enabled: true` и
      `logs.format: [json]` **не «ещё не реализованы»**, а уже рендерятся шаблонами вхолостую —
      `auth_basic_user_file` и `log_format nginx_json` ссылаются на несуществующие
      файл/директиву, то есть включение этих опций прямо сейчас ломает `nginx -t` (см. §8.3, §8.4,
      §9.3 документа) — это ближе к P0, чем к обычному backlog-пункту, и должно чиниться раньше,
      чем достройка letsencrypt/logrotate;
    - утечку `set_fact` между итерациями цикла доменов (§9.1) и асимметричную `assert`-валидацию
      `root` для `type: static` (§9.2, соответствует пункту №6 выше) — на момент переписывания
      документа были задокументированы как известные риски; **с тех пор устранены в коде** (см.
      ниже).
    Раздел 10 документа фиксирует рекомендованный порядок: сначала §9.1–9.3 (баги в существующем
    коде), затем архитектурное решение по конфликту с `roles/nginx` (P5-32), и только потом —
    достройка отсутствующих кусков (§8).

    ~~Баги §9.1–9.3~~ — **исправлены** в `roles/nginx_multidomain/tasks/vhosts.yml`:
    - §9.1 (утечка `set_fact` между доменами) — `_domain_ssl_cert`/`_domain_ssl_key` теперь
      вычисляются безусловно (без `when` на всей задаче) и явно обнуляются в `''`, если
      `domain.ssl.enabled` не `true`, вместо того чтобы задача просто пропускалась и оставляла
      факты от предыдущей итерации цикла.
    - §9.2 (асимметричная валидация `root`) — добавлен `assert: domain.root is defined` под
      `when: domain.type == 'static'`, симметричный уже существовавшей проверке для `type: proxy`.
    - §9.3 (`basic_auth`/`json`-логи ломают `nginx -t`) — вместо реализации самих фич (это
      отдельная задача §8) добавлен явный `assert`, запрещающий `domain.basic_auth.enabled: true`
      и `domain.logs.format` со значением `json`, с сообщением, указывающим на архитектурный
      документ. Функциональность не реализована, но поломка `nginx -t` теперь превращается в
      понятную ошибку на этапе применения роли, а не в молчаливый сломанный конфиг.
    Регрессия §9.1 проверяется в `extensions/molecule/nginx_multidomain/` (verify:
    «static-plain не должен содержать ssl-директив (нет утечки `_domain_ssl_cert`/`_key`)») —
    прогон `molecule test -s nginx_multidomain` зелёный.
34. ~~**Механизм `alert_rules_src`/VMAlert для docker-оркестратора monitoring_server отсутствует
    как класс.**~~ — **решено**: выбран вариант «документировать как k3s-only» вместо реализации
    `vmalert` в docker-compose (это осталась отдельная задача архитектурного уровня, при желании
    заводится отдельным пунктом бэклога). Реализация решения — см. P0-1 выше: дефолты алертов
    гейтятся по оркестратору, добавлен fail-fast на явное включение под docker.
35. ~~**Нужен ли `monitoring_server_grafana_loki_enabled` для k3s-оркестратора — отложено.**~~ —
    **решено и реализовано**. Grafana Loki под `monitoring_server_orchestrator: k3s` реализован —
    Helm-релиз `loki` (`grafana/loki` 6.54.0, SingleBinary + бандлованный MinIO-сабчарт) в
    `helm/envs/k3s-monitoring.yaml`, ставится через уже существующий `Helmwave up`, без правок кода
    роли (см. `docs/adr/0007-monitoring-server-role.md` §6/§11 — там же два побочных фикса схемы
    helmwave, найденных при реализации: `depends_on` не пробрасывался из `.tpl`, и
    ownership-конфликт `GrafanaDatasource loki` с уже существующим ресурсом в
    `grafana-operator/values.yaml`).

    Сам вопрос из заголовка пункта — теперь тоже закрыт: добавлен **opt-in** механизм, а не прямой
    проброс `monitoring_server_grafana_loki_enabled` в `monitoring_server_helmwave_tags` (прямой
    проброс был бы некорректен — `helmwave` фильтрует релизы только по inclusion-тегам, нет
    "исключить один", поэтому без явного перечисления всех остальных релизов пользователя роль не
    может достоверно вывести, что ещё нужно оставить). Новая переменная
    `monitoring_server_helmwave_other_tags` (пусто по умолчанию) — теги всех релизов пользователя,
    кроме `loki`; `monitoring_server_helmwave_tags` теперь вычисляется как `other_tags +
    ([loki_tag] if grafana_loki_enabled else [])`, но только когда `other_tags` не пуст — иначе
    (дефолт) `monitoring_server_helmwave_tags` остаётся `[]`, `--tags` не передаётся вовсе,
    поведение полностью совпадает с тем, что было до этого пункта (архитектурная граница из ADR —
    роль не парсит и не предполагает содержимое `helm/` пользователя — соблюдена: список
    "остального" по-прежнему явно задаёт сам пользователь). Для комплектного
    `helm/envs/k3s-monitoring.yaml`: `monitoring_server_helmwave_other_tags: [vm, grafana-alloy,
    grafana-alloy-blackbox, grafana-alloy-redis, grafana-operator]`. Логика проверена прямым
    вычислением Jinja-выражения (`ansible-playbook` + `include_vars` + `debug`) для всех трёх
    веток (дефолт/exclude/include) — не отдельным k3s molecule-прогоном: он не задаёт `other_tags`,
    дефолт `[]` доказуемо не меняет его поведение, а гонять дорогой vagrant/libvirt-сценарий ради
    логики, не зависящей от реального кластера, избыточно.

---

## Backlog фич (незавершённая функциональность, не баги и не мусор)

Пункты этого раздела — не находки код-ревью, а самостоятельные задачи «добавить функциональность
по образцу уже существующей». Вынесены отдельно от P0-P5, чтобы не смешивать их с багами/мусором:
здесь нечего чинить, нужно реализовать с нуля по существующему шаблону.

34. ~~**Подключить экспортер `grafana-alloy` (embedded-exporter) в monitoring_server/monitoring_agent.**~~
    — **сделано**. Шаблон алертов уже был — `roles/monitoring_server/templates/alert-rules/grafana-alloy/embedded-exporter.yml`
    (перенесено из P3-24). Пройден стандартный 4-шаговый процесс:
    1. alert-правила — уже были.
    2. серверные переменные в `roles/monitoring_server/defaults/main.yml`:
       `monitoring_server_victoria_metrics_scrape_alloy` (default `true`),
       `..._scrape_alloy_port_default` (`12345`), `..._alerts_rules_alloy_default`.
    3. переменные агента в `roles/monitoring_agent/defaults/main.yml`:
       `monitoring_agent_alloy_enabled` (default `false`), `_image_registry`/`_repository`
       (`docker.io`/`grafana/alloy`), `_image_version` (`v1.18.0`), `_image`, `_port` (`12345`),
       `_systemd_name` (`alloy`), `_config_dir`, `_binary_download_url`
       (`grafana/alloy` releases, `alloy-linux-amd64.zip`), `_binary_install_path`,
       `_binary_checksum` (P1-13 паттерн). Поддержаны оба оркестратора — редкость среди
       экспортеров (`pve_exporter`, например, только `systemd`).
    4. регистрация в массиве `monitoring_server_victoria_metrics_exporters`
       (`roles/monitoring_server/vars/main.yml`): `name: alloy`.
    Config (`config.alloy`) — намеренно пустой (без компонентов): нужен только `alloy_build_info`
    для alert-правила `GrafanaAlloyServiceDown`, реальный сбор метрик/логов через grafana-alloy
    уже покрыт отдельно под k3s через Helm (`helm/values/releases_common/grafana-alloy*.yaml`,
    ADR-0007) — здесь только docker/systemd путь для оркестраторов `monitoring_agent`, где своего
    k3s нет. Архив `grafana/alloy` — `.zip`, а не `.tar.gz`, как у остальных экспортеров (плоский,
    без вложенной директории) — потребовал отдельного паттерна распаковки и установки пакета
    `unzip`.

    Первый же прогон `molecule test -s monitoring_agent` (расширен под `monitoring_agent_alloy_enabled: true`
    на обоих хостах) поймал реальный, ранее не описанный баг — **и не только у alloy**:
    config-файл `alloy` (как и `nginxlog-exporter`, тот же паттерн) рендерится в общей, не
    systemd-only части `tasks/monitoring-agent.yml` (нужен обоим оркестраторам), но его
    `notify: Restart service <X>` **безусловно** ведёт на handler с `ansible.builtin.systemd` —
    под docker-оркестратором такого юнита не существует вообще (там контейнер, не systemd-сервис),
    поэтому при любом изменении конфига падает `"Could not find the requested service"`.
    Исправлено добавлением `when: monitoring_agent_orchestrator == 'systemd'` на оба handler'а
    (`Restart service alloy`, `Restart service nginxlog-exporter`) — для docker-пути перезапуск не
    нужен, `docker_compose_v2` и так реконсилит контейнер на каждом `converge`. Баг у
    `nginxlog-exporter` был скрыт с момента появления экспортера — сработать он мог, только если
    одновременно включить `monitoring_agent_nginxlog_exporter_enabled: true` и
    `monitoring_agent_orchestrator: docker`, а таким сочетанием ни один существующий тест/сценарий
    не пользовался.

47. ~~**Новая роль `fail2ban` + реорганизация nginx/npm-демок вокруг неё.**~~ — **сделано**
    (2026-08-05). Все пять частей плана реализованы и проверены реальными прогонами:

    - **Роль `fail2ban`** (`roles/fail2ban/`) — устанавливает пакет, полностью декларативный
      `jail.local` из списка `fail2ban_jails`, опциональные custom `filter.d` (`fail2ban_custom_filters`)
      + bundled-фильтры под известные интеграции коллекции. `fail2ban-client -t` не умеет
      валидировать одиночный файл-кандидат (`-c` принимает только целый каталог конфигурации) —
      валидация постфактум отдельным command-таском, а не через `validate:` в `template`.
      Molecule-сценарий (`extensions/molecule/fail2ban/`) — не только валидность конфига, а
      реальный функциональный тест: дописывает строки в лог, дожидается настоящего бана IP.
    - **`nginx_multidomain` + `fail2ban`** — кастомный фильтр не понадобился: роль использует
      стоковый nginx-формат лога, штатный `filter: nginx-limit-req` из пакета `fail2ban` банит
      по превышению уже реализованной в роли rate-limit-зоны.
    - **`reverse_proxy_npm` + `fail2ban`** — bundled-фильтр `npm-proxy`
      (`roles/fail2ban/templates/filter.d/npm-proxy.conf.j2`). Два реальных расхождения с
      апстримным исходником NPM нашлись только живым прогоном на `demo/npm`, не при чтении кода:
      (а) NPM пишет ДВА разных формата лога — per-proxy-host access-лог и fallback-лог (запросы
      без совпавшего proxy-host, самый частый случай сканирования) — с разным числом полей перед
      `$status`, failregex сначала матчил только первый; (б) апстримный `log-proxy.conf` называет
      fallback-файл `fallback_http_access.log`, реальное имя в рантайме — `fallback_access.log`.
      Отдельно найдено и решено через `datepattern = {NONE}`: fail2ban сам пытается вычленить дату
      из строки ДО failregex, что ломало `^`-якорь обоих фильтров этого пункта плана — см.
      `roles/fail2ban/README.md`, "Известные интеграции".
    - **`demo/fail2ban-ui` → `demo/nginx-multidomain`** — переименован (тот же паттерн, что
      `mysql-ha-observability` → `mysql-ha-platform`), роли `nginx_multidomain`+`fail2ban`
      добавлены поверх уже существовавшего `fail2ban_ui`.
    - **Новый `demo/npm`** — `reverse_proxy_npm` + `fail2ban` + `fail2ban_ui`. Реальный
      архитектурный конфликт пойман до написания кода: `fail2ban_ui_reverse_proxy: nginx`
      конфликтовал бы с `reverse_proxy_npm` за порты 80/443 (то же взаимоисключение, что
      ADR-0001 документирует для `nginx_multidomain`/`reverse_proxy_traefik`) — здесь `fail2ban_ui`
      без nginx-прокси, напрямую на своём порту.

    Оба demo-кейса проверены полным циклом: реальный бан IP по превышению лимита/сканированию
    (в `demo/npm` бан зацепил и SSH — fail2ban банит IP целиком), автоматический разбан по
    истечении `bantime`, идемпотентность (второй подряд прогон `site.yml` — `changed=0`).

48. **Новые роли `backup_server`/`backup_agent` — централизованный сервис бекапа (на Bareos).**
    Сейчас в коллекции нет ни одной роли, отвечающей за резервное копирование — ни данных ролей
    с состоянием (`postgresql_replication`, `mysql_replication`, `monitoring_server`:
    VictoriaMetrics/Grafana/Loki/MinIO-данные), ни конфигов (`infra_dns` зоны, `nginx_multidomain`
    вхосты, `reverse_proxy_npm` SQLite/данные). Требование — единый control-plane поверх
    нескольких клиентских хостов (не отдельный агент-на-хост без центра, как `restic`/`borg`), и
    консистентные бекапы БД (не просто снапшот диска, как дал бы Proxmox Backup Server — он
    рассматривался и отклонён как основной механизм: PBS работает на уровне VM/CT с хоста
    Proxmox, вне зоны ответственности этой Ansible-коллекции, и не даёт логической консистентности
    БД/выборочного восстановления; годится как отдельный, ортогональный слой DR на уровне целых
    VM, не заменяет эту задачу).

    **Архитектурное решение — [Bareos](https://www.bareos.com)**, по паттерну `_server`/`_agent`,
    уже принятому в коллекции для `monitoring_server`/`monitoring_agent`.

    ~~**`backup_server`**~~ — **сделано** (`docs/adr/0009-backup-server-role.md`): Bareos director +
    catalog (PostgreSQL-БД заданий, bootstrap без `dbconfig-common` — `community.postgresql` +
    штатные `make_bareos_tables`/`grant_bareos_privileges`) + storage daemon. Хранилище — MVP,
    локальный диск (`File`-device); S3 — следующий шаг, не реализовано. Self-backup (job
    `BackupCatalog`) — единственная встроенная функциональная проверка всей цепочки. Molecule
    полностью зелёный, реальный запуск job'а через `bconsole`.

    ~~**`backup_agent`, Фаза 1**~~ — **сделано** (`docs/adr/0010-backup-agent-role.md`): Bareos
    file daemon на клиентском хосте. Архитектурная поправка, найденная до кодирования:
    `bareos-fd.d` не имеет ресурса `FileSet` вообще (только `client`/`director`/`messages`) — что
    бекапить, решается целиком на стороне `backup_server` (`backup_server_clients`/
    `backup_server_filesets`, уже было готово, здесь впервые задействовано), `backup_agent` только
    ставит сам file daemon + опциональные python-плагины. Интеграция — вручную через совпадающие
    переменные, без кросс-ролевой связности. Molecule (2 ВМ, реальный удалённый job, не
    self-backup) поймал 2 регрессии в уже смердженном `backup_server` (dangling `Schedule`/
    `JobDefs` при `self_backup_enabled: false` + непустом `backup_server_clients`) — обе
    исправлены.

    ~~**`mysql_replication_backup_tool: bareos`, Фаза 2**~~ — **сделано**: третье значение
    `mysql_replication_backup_tool` (наравне с `xtrabackup`/`mariabackup`), делегирует на
    `backup_server`/`backup_agent` вместо rclone/S3/systemd-timer-пути — `backup_agent`
    подключается условной `meta`-зависимостью (тот же паттерн, что `docker`). Molecule
    (`extensions/molecule/mysql_replication/`, 4-я ВМ `mysql-backup-server`) — см.
    `docs/adr/0010-backup-agent-role.md` «Финальный статус Фазы 2».

    **Не реализовано** (следующий шаг): Фаза 3 —
    `postgresql_replication_backup_tool: pgbackrest|bareos` — декларативные bundled-профили
    `postgres`/`mysql` типов в `backup_agent` изначально задумывались как список источников
    внутри самой роли — по факту реализации решение изменилось (см. ниже, «Интеграция с
    `postgresql_replication`/`mysql_replication`»).

    **Расширение `backup_server` под DR-экспорт на внешний носитель** (второе требование,
    сформулировано отдельно от MVP-хранилища): пул `dr`, привязанный к Storage-ресурсу с device =
    точка монтирования внешнего накопителя, плюс расписание `Copy Job` (не `Migration Job` —
    исходные бекапы должны остаться в основном пуле) из основного disk-пула в `dr`-пул. Выбор
    «все системы или выборочные» — это выбор клиентов/пулов в критериях самого Copy Job, нативно
    поддержано Bareos без дополнительной логики; в декларативной схеме роли это список
    клиентов/групп на экспорт. Дамп catalog-БД (стандартный джоб `BackupCatalog`, входит в
    поставку Bareos) тоже включается в экспорт на внешний носитель — без него восстановление
    возможно только через `bscan` (см. ниже), а не обычным restore через директор.

    **Восстановление — runbook как README, а не playbook** (непроверенный бекап не бекап, но
    сценарий DR по определению происходит на инфраструктуре, которой уже может не быть, включая
    Ansible-контроллер — автоматизировать особо нечего): штатный путь — поднять на любом чистом
    хосте `bareos-dir`+`bareos-sd`, залить скопированный дамп catalog-БД в scratch PostgreSQL,
    примонтировать внешний носитель как storage device, обычный restore через директор. Запасной
    путь, если и дамп каталога недоступен/повреждён — `bscan` (входит в Bareos) пересобирает
    минимальный каталог, читая метки томов прямо с носителя, без зависимости от исходной БД
    каталога вообще.

    **Интеграция с `postgresql_replication`/`mysql_replication` (найдено при планировании Фазы 2,
    решение пользователя)**: у обеих ролей уже есть собственные независимые механизмы физического
    бэкапа (`postgresql_replication_backup_enabled` → pgBackRest → S3;
    `mysql_replication_backup_tool: xtrabackup|mariabackup` → rclone → S3, каждый со своим
    systemd-таймером/ретеншном, ADR-0004 §8/ADR-0005) — децентрализованная схема, обратная цели
    единого control-plane. **Решено не заменять и не дублировать их отдельной ролью**, а добавить
    Bareos как **третий вариант** `_backup_tool` внутри самих этих ролей:
    - ~~**Фаза 2**~~ — **сделано**: `mysql_replication_backup_tool: bareos` (третье значение
      существующей переменной, переиспользует уже существующую установку `percona-xtrabackup-80`/
      `mariadb-backup`, вынесенную в общий `tasks/install-backup-tool.yml`, без rclone/S3/
      systemd-timer-части).
    - ~~**Фаза 3**~~ — **сделано**: `postgresql_replication_backup_tool: pgbackrest|bareos`
      (новая переменная, дефолт `pgbackrest` — обратная совместимость). Взаимоисключающий выбор —
      `bareos`-плагин (`bareos-fd-postgresql`) сам архивирует WAL в `wal_archive_dir` через
      `archive_command`, занятый pgBackRest на pgbackrest-пути. DB-роль для плагина
      (`GRANT EXECUTE` на `pg_backup_start`/`pg_backup_stop`, PostgreSQL 15+, либо legacy
      `pg_start_backup`/`pg_stop_backup`) создаётся на primary — `CREATE ROLE` не проходит на
      standby, а `backup_source_role` по умолчанию `dr_replica` (read-only). Две реальные находки,
      обе не видны по коду, только реальным прогоном molecule:
      1. `pg_backup_stop(wait_for_archive=true)` виснет бесконечно на тихой БД (мало/нет записи
         после снятия бэкапа) — WAL-сегмент никогда не заполняется естественным трафиком.
         Исправлено `postgresql_replication_bareos_archive_timeout` (по умолчанию 60с,
         принудительное переключение сегмента).
      2. `archive_timeout` сам по себе не помогает, если backup_source_role — реплика (дефолт):
         сегмент физически переключает только primary, реплика лишь архивирует уже полученное
         streaming-репликацией. Primary должен архивировать тоже (пусть и в никуда,
         `archive_command = 'true'`), просто чтобы `archive_timeout` вообще срабатывал —
         исправлено безусловным `archive_mode = always` на primary при `backup_tool: bareos`,
         независимо от того, primary ли сам `backup_source_role`
         (`templates/postgresql-replication.conf.j2`).
      Molecule (`extensions/molecule/postgresql_replication/`, 4-я ВМ
      `postgresql-backup-server`, реальный `bconsole run job=backup-postgresql-dr-replica-fd`,
      `Termination: Backup OK`) — converge/idempotence (`changed=0`, 4 хоста) и bareos-специфичные
      verify-проверки полностью зелёные. Полный сквозной прогон verify (включая
      promote/failback-последовательность) уткнулся в отдельную, не связанную с bareos находку
      (№54 выше) — Фаза 3 считается валидированной в границах своей собственной функциональности.
    - Обе фазы — условная `meta`-зависимость на `backup_agent` (`when: ..._backup_tool ==
      'bareos'`), тем же паттерном, что `docker` (ADR-0002 §2), а не композиция на уровне
      плейбука, как `monitoring_agent`/`infra_dns` (ADR-0004 §11) — обоснование см.
      `docs/adr/0010-backup-agent-role.md` §1.

    Остаются открытыми: retention-политика Bareos-пулов (GFS-схема или простое количество копий,
    сейчас — фиксированные `Volume Retention` в `backup_server_pools`), обработка отсутствия/
    неправильно смонтированного внешнего носителя на момент Copy Job (DR-экспорт).

    ~~Демо-кейс~~ — **сделано**: `demo/backup` (`backup-server` + два независимых клиента
    `client-a`/`client-b`, каждый со своими данными, `type: files` — единственный реализованный
    путь на момент постройки демо) — показывает исходное требование пользователя буквально
    («несколько клиентских хостов, единый control-plane нужен»), не self-backup одной ВМ, как
    molecule-сценарий `backup_server`. Проверено живым прогоном (не только `terraform apply`):
    `bconsole run job=backup-client-a-fd`/`backup-client-b-fd`/`BackupCatalog` — все три
    `Termination: Backup OK`, тома реально на диске (`Full-0001`, `Incremental-0002`).

49. ~~**Единая система авторизации для сервисов коллекции (OAuth — приоритет, LDAP — альтернатива).**~~
    — **реализовано на `platform/aicd` и `platform/aicd-devops-labs-ru`** (2026-08-26,
    `docs/adr/0013-unified-auth-architecture.md` §7/§8): каталог пользователей — persistent
    `freeipa` (LDAP, свой инстанс в каждом окружении), federated с **Authelia** (не Keycloak,
    повторно подтверждено ADR §5) через `authentication_backend.ldap.implementation: 'freeipa'`.
    Authelia — не отдельная роль коллекции, а Helm-релиз на платформенной инфраструктуре (ADR §6,
    тот же паттерн, что Gitea/Semaphore/Radar/infra-panel). Потребители: `forwardAuth` перед
    `infra-panel`/`radar` (эндпоинт `/api/authz/forward-auth`, не легаси `/api/verify` — см. ADR
    §7, критическая находка №8), нативный OIDC у Semaphore (`SEMAPHORE_OIDC_PROVIDERS`) и Gitea
    (декларативно, `gitea.oauth` в values чарта). Второе окружение (Proxmox) перенесено
    механической заменой (Фаза F, ADR §8) — поймала свой класс находок: несовместимая с Rocky 9
    CPU-модель Proxmox по умолчанию, sed случайно переименовавший литерал, который должен был
    остаться одинаковым между окружениями, отсутствующий пакет firewalld на этом шаблоне,
    прерванная сетевым обрывом установка `ipa-server-install`. Grafana/клиентские
    `reverse_proxy_*`-стенды — вне охвата (другие, не связанные сети).

50. ~~**Компонент запуска ansible/terraform (CI/CD-панель), например Semaphore UI.**~~ —
    **архитектура решена** (`docs/adr/0012-cicd-platform-architecture.md` §5): панель — Semaphore
    UI, git-интеграция тянет репозиторий напрямую из self-hosted Gitea (№52), task templates
    исполняются через общий Execution Environment из Harbor (тот же ADR §1) — не отдельный
    рантайм. Авторизация — без SSO на старте (basic-auth/локальные пользователи Semaphore,
    fail-fast-на-дефолтном-пароле, как у `reverse_proxy_traefik`/`infra_panel`), интеграция
    с №49 — явный follow-up, не блокирует реализацию. Секреты — внешний OpenBao (ADR §3), не
    встроенное хранилище Semaphore. Размещение — новая персистентная платформенная
    инфраструктура, не `demo/full-platform` (ADR §6). Роль (`semaphore_ui`?) не реализована —
    следующий шаг.

51. **Компонент публикации документации платформы внутри стенда.** ADR принят
    (`docs/adr/0024-platform-docs-site.md`, 2026-09-07) — MkDocs Material, два независимых
    раздела навигации («Архитектура» — `docs/overview.md`/`docs/components.md`/`docs/adr/`/
    `docs/platform/`, «Роли коллекции» — `roles/*/README.md`), `ROADMAP.md` не публикуется,
    визуальные бейджи статуса ADR (парсинг строки «Статус:», без `mkdocs-macros`). Сборка — CI-джоба
    `.gitea/workflows/docs-site.yml` (не init-container при старте пода, как предполагал черновик),
    артефакт публикуется в НОВЫЙ raw-hosted репозиторий Nexus `docs-site` (`writePolicy: ALLOW`,
    отдельный от `internal-releases`, которому нужен неизменяемый `ALLOW_ONCE`) — под лишь
    скачивает готовое init-container'ом. Доступ — тот же `forwardAuth`-периметр Authelia, что
    Radar/infra-panel, без ролевой дифференциации. Чисто Helm+`site.yml`-компонент (без Ansible-роли,
    как `radar`/`gitea-actions-runner`), Terraform не требуется.

    **Живьём развёрнуто и проверено на обоих окружениях** (2026-09-10): CI-джоба
    `docs-site.yml` собирает и публикует артефакт, под скачивает его и отдаёт сайт за
    `forwardAuth`-периметром — `platform/aicd` и `platform/aicd-devops-labs-ru` идентичны.
    Живым прогоном найдено и исправлено четыре бага, ни один не был виден по коду/локальным
    проверкам:
    - Голый alpine-образ раннера (`gitea/runner`, host-режим без Docker) не содержит ни
      `node` (нужен `actions/checkout@v4`), ни `curl` — оба ставятся явным `apk add` первым
      шагом соответствующих step'ов workflow.
    - `nxs-universal-chart` формирует имя `Service` как `<release>-<ключ>`
      (`helpers.app.fullname`) — реальный сервис Nexus называется `nexus-nexus`, а не `nexus`
      (использованная по аналогии с `gitea-http.platform.svc.cluster.local` схема не
      сработала — у gitea-чарта сервис называется иначе).
    - `wget` в alpine — это busybox wget, не GNU wget: `--user`/`--password` им не
      поддерживаются вовсе, креды нужно встраивать в URL (`user:pass@host`, RFC 3986
      userinfo) — проверено локально (`docker run alpine:3.20`, тот же busybox v1.36.1, что
      в поде) паролем со спецсимволами `:`/`,` из дефолтного charset
      `lookup('ansible.builtin.password')`.
    - У staging-дерева не было ни одного `index.md` в корне (оба раздела навигации —
      подкаталоги) — `mkdocs` не генерировал корневой `index.html`, nginx отвечал `403` на
      `/` (autoindex выключен); содержимое конкретных страниц раздавалось корректно, но
      попасть на сайт с самого домена было невозможно. `build-docs-site.py` теперь
      генерирует landing-страницу со ссылками на `overview.md`/`components.md`.

    Второе окружение (`aicd-devops-labs-ru`) потребовало отдельного bootstrap'а — на его
    Gitea никогда не существовало ни организации `platform`, ни зеркала коллекции (в отличие
    от `aicd`, где это уже было заведено раньше): организация+репозиторий созданы через REST
    (агент, с явного разрешения оператора в чате — создание пустых административных объектов,
    не передача содержимого), сам `git push` и `Settings → Actions → Secrets` — оператором
    вручную (тот же принцип, что раньше на `aicd`: `git push` содержимого доверенного
    репозитория инструментарий безопасности не даёт делать агенту в принципе).

52. ~~**Легковесный self-hosted git с CI/CD в стиле Gitea (кандидаты: Gitea, Forgejo).**~~ —
    **архитектура решена** (`docs/adr/0012-cicd-platform-architecture.md` §4): выбор — Gitea (не
    Forgejo). Разделение ответственности с №50: Gitea Actions — CI (lint, `molecule test`), а не
    полная замена Semaphore — Semaphore остаётся отдельной CD-панелью специально для
    ansible/terraform (см. №50). Раннер для `molecule` (нужен `/dev/kvm`/nested-виртуализация)
    сознательно вынесен за пределы k3s — systemd-сервис на хосте с реальным доступом к libvirt,
    не под k8s (privileged pod/hostPath/node affinity ради одного заведомо непереносимого раннера
    не даёт выигрыша). Сам сервер Gitea может жить в k3s. Роль (`gitea`?) не реализована —
    следующий шаг.

53. **Компонент DevSecOps (агрегация уязвимостей), в стиле DefectDojo.**
    Сейчас в коллекции нет ни одного компонента, агрегирующего результаты security-сканирования
    (SAST/SCA/DAST, сканы контейнерных образов и т.п.) — каждый скан живёт сам по себе, нет единой
    точки трекинга находок/дедупликации/статуса устранения по всей платформе. Идея —
    [DefectDojo](https://www.defectdojo.org/) (open-source vulnerability management, импортирует
    отчёты 180+ сканеров — Trivy, Bandit, Semgrep, OWASP ZAP и т.п., дедуплицирует находки, ведёт
    жизненный цикл finding'а) как ещё один сервис платформы, тем же паттерном публикации, что
    остальные (`reverse_proxy_traefik`, ссылка в `infra_panel_extra_services`); Django + Postgres +
    Celery — тяжелее большинства сервисов коллекции (ближе по весу к `monitoring_server`, чем к
    `infra_panel`).

    Естественно пересекается с №52 (Gitea/Forgejo CI): результаты сканов логично поставлять из
    CI-пайплайна (Gitea Actions/`act_runner`) через DefectDojo API/`import-scan`, то есть этот
    пункт зависит от решения по №52, а не независим от него. Не проработано архитектурно: какие
    сканеры реально подключать первыми (зависит от того, что вообще сканируется в этой
    коллекции/демо-стендах — сейчас ничего); нужна ли интеграция с №49 (единая авторизация) —
    DefectDojo умеет OIDC из коробки, естественный первый потребитель приоритета OAuth из №49;
    объём ресурсов стенда (Django+Celery+Postgres+Redis — самый тяжёлый кандидат из уже
    накопленных backlog-идей №50-53, стоит явно сверить с ресурсами demo-стенда перед выбором).
    Требует отдельного ADR перед реализацией — сейчас зафиксирована только идея.

55. ~~**Единая авторизация для доступа к Kubernetes (kube-apiserver OIDC), кандидат — Dex или
    аналог.**~~ ADR-0013 (№49) закрывает SSO только на уровне *приложений за reverse-proxy*
    (Authelia + `forwardAuth`/нативный OIDC у сервисов-потребителей) — доступ к самому
    kube-apiserver (`kubectl`, k3s-кластеры `monitoring_server_k3s`/`platform/aicd*`) им не
    покрыт: сейчас единственный способ получить доступ к кластеру — статический kubeconfig с
    `client-certificate`/токеном сервисного аккаунта, без привязки к каталогу пользователей
    `freeipa` и без аудита «какой человек выполнил `kubectl`». Идея — [Dex](https://dexidp.io/)
    (или аналог, например встроенный OIDC у k3s через `--kube-apiserver-arg`) как
    OIDC-issuer перед kube-apiserver, федерированный либо напрямую с `freeipa` (LDAP-коннектор
    Dex), либо через уже принятую Authelia как upstream OIDC-провайдер (Dex умеет OIDC-коннектор
    к другому OIDC-провайдеру) — выбор между этими двумя вариантами и есть первый архитектурный
    вопрос.

    **Архитектура решена** (`docs/adr/0020-kube-apiserver-oidc.md`, 2026-09-02) — ответ вышел за
    рамки развилки, сформулированной выше. Выбран **третий вариант, в этом пункте не названный:
    issuer — уже развёрнутая Authelia напрямую, без Dex вообще.** Оба варианта из формулировки
    («Dex с LDAP-коннектором к `freeipa`» и «Dex поверх Authelia») разобраны и отклонены: Dex
    изолирует одного потребителя из шести (остальные подключены к Authelia напрямую и переезжают
    при любой смене IdP в любом случае), а настоящий слой изоляции — каталог `freeipa`, а не шим.
    Решение **пересматривает вывод ADR-0013 §5** («для №55 — Dex или Keycloak, но не Authelia»):
    его фактическая посылка оказалась неверна — у Authelia есть официальная страница интеграции
    с `kubelogin`; см. датированную приписку к §5 того ADR.

    Устарело и предложение «просто `--kube-apiserver-arg=oidc-*`»: оба кластера на
    `v1.35.1+k3s1`, а structured authentication configuration (`--authentication-config`) вышла
    в **GA именно в v1.35** — она даёт горячую перезагрузку маппинга без рестарта control-plane,
    CEL и несколько issuer'ов одновременно (последнее делает будущую замену провайдера
    обратимой). Отдельная находка, которой в этом пункте не было: встроенный OIDC
    `auth-provider` в `client-go` **удалён в Kubernetes 1.26**, поэтому `kubectl` обязан ходить
    через exec-плагин `int128/kubelogin` — статический kubeconfig с `auth-provider: oidc` на
    v1.35 не работает в принципе.

    Авторизация (тот самый маппинг groups→Role, которого «Dex сам не делает») закрыта ADR-0020 §6
    поверх групп ADR-0019: префикс `oidc:` обязателен — иначе заведённая в каталоге группа с
    именем `system:masters` даёт cluster-admin в обход модели. Охват сознательно ограничен
    платформенными окружениями; k3s-путь роли `monitoring_server` **остаётся на client-cert** —
    у клиентских стендов нет сетевого маршрута к платформенной Authelia, и подключение внешнего
    issuer'а сделало бы их control-plane зависимым от чужой инфраструктуры (ADR-0020 §8). Тем
    самым снят и вопрос «нужен ли компонент для single-node dev/demo-кластеров» — не нужен.

    Не реализовано — следующий шаг; порядок внедрения задан ADR-0020 §9, предусловие —
    реализованный ADR-0019 (роль `freeipa_directory`, реальные группы в каталоге). **Предусловие
    закрыто на обоих окружениях (2026-09-04)**: группы `platform-*` и первый реальный человек
    заведены и на `platform/aicd`, и на `platform/aicd-devops-labs-ru`, живым прогоном
    подтверждено (ADR-0019 §8 шаг 1). Шаги 2 (claim `groups` в ID Token), 4 (маппинг ролей
    внутри Grafana/Gitea/Nexus) и 5 (ужесточение `access_control`/`authorization_policies` с
    `one_factor` до group-gated) тоже сделаны и живо проверены на обоих окружениях — ролевая
    модель ADR-0019 теперь полностью реализована и реально влияет на права допуска, не только на
    роль/токен внутри уже допущенных сервисов. Не сделан только шаг 3 (полноценный браузерный
    клик-тест — упирается в системный прокси control-хоста), который для предусловия ADR-0020 не
    обязателен. Работа над самим ADR-0020 (Authelia как OIDC-issuer для kube-apiserver) ещё не
    начата.

56. **Оценить необходимость `trust-manager`** (проект экосистемы cert-manager,
    https://cert-manager.io/docs/trust/trust-manager/installation/) **для распространения
    внутреннего PKI CA по кластеру.** Сейчас CA, выпущенный PKI secrets engine OpenBao
    (ADR-0016), распространяется вручную и по-разному под каждого потребителя: Secret
    `aicd-platform-ca` в конкретные namespace (`platform`, `monitoring` — `site.yml` обоих
    платформенных окружений) и системный trust store нод (control-plane и `llm1`) через
    `ansible.builtin.copy` + `update-ca-certificates` — независимая реализация того же паттерна
    добавлена ещё раз в рамках bootstrap Nexus (ADR-0018): реальный прогон
    `platform/aicd-devops-labs-ru` (2026-08-28) показал, что сама control-plane нода должна
    доверять внутреннему CA, иначе `xanmanning.k3s` не может скачать k3s-бинарь через
    `nexus-cache` по HTTPS. `trust-manager` — декларативный способ синхронизировать один `Bundle`
    CR в ConfigMap/Secret во все (или выбранные) namespace кластера, потенциально устраняющий
    часть этой ad-hoc-логики на стороне ansible для pod-уровня.

    Не проработано архитектурно: `trust-manager` формально — компонент экосистемы cert-manager
    (устанавливается отдельным Helm-чартом, но полагается на CRD `trust.cert-manager.io`), а сама
    коллекция cert-manager сейчас не использует вовсе (issuance — через OpenBao PKI API + ansible,
    не через `Certificate`/`Issuer` CRD) — нужно выяснить, можно ли использовать trust-manager
    только для распространения уже готового CA без перехода на cert-manager как issuer, или это
    фактически вынуждает более крупное решение (issuance через cert-manager с OpenBao как backend,
    что пересматривает ADR-0016 целиком, а не дополняет его). Также неясно, закрывает ли
    trust-manager случай системного trust store НОД (не только ConfigMap внутри подов) — судя по
    документации, нет: это k8s-native механизм для CA внутри подов, а node-level
    `update-ca-certificates`-паттерн (control-plane, `llm1`) в любом случае остаётся отдельной
    задачей ansible. Требует отдельного ADR перед реализацией — сейчас зафиксирована только идея.

57. **Агентная платформа (ADR-0015) — стек ещё не полностью развёрнут, локальный инференс и
    LiteLLM-гейтвей (LLM + MCP) уже работают.** Архитектура целиком решена ADR-0015 (пять
    агентов, слой `агенты → инструменты → ресурсы`, три `RuntimeClass` для изоляции,
    namespace-каркас `llm/gateway/agents/data/obs/egress`) и ADR-0021 (конкретные
    модель/движок). Реализовано и живо проверено на `platform/aicd-devops-labs-ru`: Фаза 1
    ADR-0015 §10 — нода `llm1` (второй узел кластера, GPU passthrough, `RuntimeClass:
    nvidia`/`runsc`, taint-изоляция, namespace-каркас, default-deny `NetworkPolicy`);
    локальный инференс ADR-0021 (2026-09-06) — `llama-server` (`Qwen3.6-35B-A3B-UD-Q4_K_M`,
    llama.cpp, GPU) и TEI (`BAAI/bge-m3`, CPU) в namespace `llm`, RAM `llm1` увеличена до 25 ГиБ
    под это (предпосылка ADR-0021 §3); LiteLLM-гейтвей (2026-09-06, ADR-0015 §6/§7) — Helm-релиз
    (generic-чарт `universal-chart`, как nexus/semaphore/authelia/infra-panel) в namespace
    `gateway`, маршрутизирует псевдонимы `local-default`/`local-embeddings` на `llama-server`/
    `tei`, master key — k8s Secret (не gomplate `vault://` — render-token ограничен тремя
    путями, `secret/litellm` не входит), добавлено разрешающее правило `allow-egress-litellm` в
    `NetworkPolicy` `ns: agents`; и **MCP-гейтвей (2026-09-06, тоже ADR-0015 §6/§7) — без
    отдельного продукта.** ADR-0015 не называл конкретное ПО для «mcp-gateway» — рассмотрены
    IBM `mcp-context-forge` (самый зрелый, но официальный чарт тянет Postgres+Redis, забегая
    вперёд `ns: data`) и `microsoft/mcp-gateway` (Azure-ориентирован) — вместо любого из них
    включена уже существующая, зрелая встроенная MCP-поддержка LiteLLM proxy (не
    экспериментальная на практике, несмотря на путь `_experimental/` в исходниках — полноценные
    auth-флоу, stdio/SSE/streamable-HTTP транспорты, cost tracking, guardrails; `mcp_servers:` —
    тот же `config.yaml`, что `model_list`, без БД для статической регистрации). Один процесс
    вместо двух, `ns: data` не понадобился. Пока `mcp_servers: {}` — реальных
    инструментов-бэкендов (git/shell/browser-песочницы, ADR-0015 §9 шаг 9) ещё нет.

    Всё проверено реальными HTTP/JSON-RPC-запросами: chat completion, tool-calling, эмбеддинги,
    401 без ключа (напрямую на `llama-server`/`tei` и через сам гейтвей), а также `POST /mcp`
    (`tools/list` → корректный пустой JSON-RPC ответ) и `GET /mcp-rest/tools/list` (REST-фасад).

    Не сделано — весь остальной стек агентной платформы: `ns: data` (CloudNativePG+pgvector,
    MinIO, retriever-сервис) — RAG-слой, §7; `ns: platform` (Temporal) — оркестрация агентов,
    §9 bootstrap-порядок ставит это после гейтвея; `ns: obs` (Langfuse) — трейсинг вызовов
    моделей; `egress-proxy` — единственный разрешённый исходящий путь из `ns: agents` во внешний
    интернет (§7); сами пять агентов (`ai infra agent` и т.д.) и первый реальный
    MCP-инструмент-бэкенд + первый `agent-job` (bootstrap-порядок ADR-0015 §9, шаг 9 — вручную,
    один `kubectl create job`, до Temporal и расписаний) — **следующий шаг**. Контур активации
    и паспорт `ai infra agent` (LK «Инфраструктура», Plan/Review, Estate/Inventory, уровни
    размещения) зафиксирован ADR-0015.1; админка платформы — ADR-0015.2 (фонд ресурсов,
    метка system/user, счёт у провайдера ProviderAccount, модели, агенты, люди 0019) /
    каркас 0015.2.1; учёт фонда — ADR-0014.1 (`ExternalResource` / `InternalResource`);
    протокол входа в фонд — ADR-0014.1.1;
    контракты Intent/Plan/Estate/Inventory — ADR-0015.3. Все — архитектура, без кода. Также не решены
    открытые вопросы обоих ADR: мультитенантность/права агентов (ADR-0015 «Не проработано»),
    способ подключения `Senior`-яруса `moon-local-engineer` через платформенный LiteLLM или в
    обход (ADR-0021 §8; LiteLLM на `aicd-devops-labs-ru` теперь БД-backed — virtual
    keys/spend tracking доступны, см. №60 выше, — но сама схема мультитенантного биллинга
    по-прежнему не спроектирована), совместимость
    `tool_calls.arguments` с реальным MCP-инструментом (проверен только пустой `tools/list`, не
    вызов реального инструмента — нечего пока вызывать). Также замечена (не расследована до
    конца) нестабильность chat-темплейта: один из тестовых запросов через LiteLLM вернул ответ с
    лишним `</think>` и задвоенным содержимым, хотя `--reasoning-budget 0` в большинстве
    запросов подавляет thinking полностью — возможно, зависит от конкретного промпта, не
    универсально воспроизведено.

58. **Изоляция `ns: agents` (default-deny `NetworkPolicy`, ADR-0015 §7) сейчас фактически не
    работает на `platform/aicd-devops-labs-ru` — требует расследования.** Найдено при развёртывании
    LiteLLM-гейтвея (2026-09-06): тестовый под в `ns: agents` без каких-либо разрешающих правил
    смог достучаться и до `kubernetes.default.svc` (ожидался `Connection reset by peer`, как было
    задокументировано живым тестом в ADR-0015 §10), и до `litellm.gateway` до появления
    соответствующего allow-правила — то есть весь egress фактически проходит, несмотря на
    `default-deny` + `allow-egress-kube-dns` в кластере. Воспроизведено дважды, включая после
    `systemctl restart k3s` на `aicd-labs` (не помогло). Встроенный в k3s network-policy
    контроллер (`kube-router`) стартует без ошибок в логе (`journalctl -u k3s`), iptables-цепочки
    `KUBE-NWPLCY-*` присутствуют — но реального блокирования нет; точная причина не установлена
    (не похоже на баг конкретно моих правил — `kubernetes.default.svc` не имеет никакого allow-
    правила вообще и всё равно доступен). Не расследовано до конца намеренно — увело бы далеко за
    рамки задачи, ради которой было найдено (деплой LiteLLM). Пока это открыто — `ns: agents`
    предоставляет только namespace-уровневую логическую группировку, но не реальную сетевую
    изоляцию агентных песочниц от остального кластера (kube-api, будущие Postgres/MinIO в
    `ns: data`), что напрямую противоречит обоснованию ADR-0015 §7. Приоритет — до реального
    появления первого `agent-job`/песочницы с исполнением стороннего кода (ADR-0015 §9, шаг 9),
    иначе исполнение кода в агентном поде получает беспрепятственный доступ к kube-api.

59. **LiteLLM-гейтвей (ADR-0015 §6/§7) — аудит против чек-листа ADR-0022, 4 реальных гэпа.**
    LiteLLM — самый свежий компонент платформы (развёрнут 2026-09-06, фактически непосредственно
    перед тем, как появился сам ADR-0022 — тот даже ссылается на пустой `mcp_servers: {}` LiteLLM
    как на пример находки, §12). В список явных исключений ADR-0022 («уже существующие
    компоненты») LiteLLM не входит — первый компонент, для которого имеет смысл мерить полное
    соответствие чек-листу, а не «известное исключение». Аудит по всем 12 пунктам:
    - **№1 (внутренний репозиторий) — частично.** Чарт `localrepo/universal-chart` не требует
      внешнего Helm-репо (полностью ок). Образ `ghcr.io/berriai/litellm` тянется напрямую —
      `registries.yaml` на k3s-узлах (ADR-0018) зеркалирует через Nexus только `docker.io`,
      `ghcr.io` не покрыт вообще. **Та же дыра у `llama-server`/`tei`** (оба тоже `ghcr.io`,
      ADR-0021) — не уникальная для LiteLLM проблема, требует одного общего решения (второй
      docker-proxy repo в Nexus под `ghcr.io` + запись в `registries.yaml`), не трёх отдельных.
    - **№2 (RBAC через группы) — по-прежнему не применимо, но премиса изменилась (2026-09-12).**
      С подключением БД (см. №60) у LiteLLM Proxy штатно появляется веб-админка (`/ui`,
      требует `database_url`) — раньше её не было физически (DB-less режим), теперь она есть, но
      **не выставлена наружу**: нет ни Ingress, ни IngressRoute, только `ClusterIP` (§5/№6 ниже
      без изменений), трафик агент→litellm целиком внутри кластера. Оператор без `kubectl
      port-forward` до `/ui` не достучится — вывод пункта не меняется (не веб-UI с человеческим
      логином *в текущей топологии*), но если `/ui` когда-нибудь будет выставлена через
      Traefik — это создаст требование №2 заново, не наследует текущее «не применимо» автоматически.
    - **№3 (ссылка в infra-panel) — не применимо.** Линковать нечего, нет пользовательского UI,
      выставленного наружу (см. №2 выше — `/ui` существует, но не публикуется).
    - **№4 (метрики: экспортёр+scrape+дашборд) — реальный гэп.** LiteLLM поддерживает
      `litellm_settings.callbacks: ["prometheus"]` из коробки (родной `/metrics`) — не включено;
      ни `VMScrapeConfig`, ни дашборда, соответственно, тоже нет.
    - **№5/№6 (TLS/DNS) — не применимо по архитектуре.** Нет внешнего Ingress вовсе — только
      ClusterIP, трафик агент→litellm целиком внутри кластера, штатный cluster-DNS.
    - **№7 (секреты из OpenBao) — ✅ сделано, теперь покрывает и БД.** `secret/litellm`,
      идемпотентный GET→404→POST, `master_key` через k8s Secret. С 2026-09-12 (№60) секрет
      расширен полем `db_password` — тем же аддитивным приёмом (существующее поле сохраняется, а
      не теряется при KV v2 replace), пароль БД тоже никогда не появляется как plaintext в git.
    - **№8 (`releases_common` стаб) — ✅ сделано.**
    - **№9 (`resources.requests/limits`) — частично, но по другой причине, чем раньше.**
      `cpu` limit по-прежнему отсутствует (unbounded) — не изменилось. `memory` limit пришлось
      **поднять до `2Gi`** (2026-09-12, было `1Gi`) — не превентивно, а по факту живого
      `OOMKilled`: подключение БД (№60) означает, что Prisma-миграция при старте пода поднимает
      отдельный node-процесс query-engine поверх python-процесса, старый лимит был рассчитан на
      config-only режим и оказался тесен для DB-backed. Урок: `resources.limits` нужно
      пересматривать при каждом архитектурном изменении компонента (новая БД, новая зависимость),
      не только выставлять один раз при первом добавлении.
    - **№10 (NetworkPolicy — явное решение) — реальный гэп, объём вырос.** Ни правила, ни
      зафиксированного «не нужно» — `ns: gateway` вообще без решения, тот же силентный пробел, что
      ADR-0022 §10 явно запрещает для новых компонентов. С 2026-09-12 под LiteLLM получил ещё один
      egress-адрес за пределами кластера (`postgresql-infra-1:5432`, №60) — будущее явное решение
      по этому namespace должно учитывать не только egress к `llm`/входящий от `agents`, но и этот
      путь наружу к Postgres.
    - **№11 (backup) — премиса, на которой строился вывод, больше не верна.** Раньше: «состояния
      нет вовсе (config-only режим) — backup объективно не нужен». С 2026-09-12 (№60) состояние
      реально появилось — 75 таблиц `LiteLLM_*` (virtual keys, spend logs) в БД `litellm` на
      `postgresql-infra-1`. Backup для этих данных, если понадобится, — вопрос backup-стратегии
      самого `postgresql-infra-1` (ADR-0023, ROADMAP №60 — «Backup (Bareos) — осознанно
      отложено, `backup_server` для платформы нигде не развёрнут»), а не отдельного решения для
      LiteLLM как компонента: данные LiteLLM не имеют собственного хранилища, которое можно было
      бы бэкапить отдельно от остального `postgresql-infra-1`. Требование №11 для самого LiteLLM
      закрывается ссылкой на этот уже существующий, явно задокументированный платформенный пробел
      — не остаётся молчаливым «вопрос не задавался», но и не решается здесь заново.
    - **№12 (MCP) — не применимо.** LiteLLM сам реализует требование №12 для *других* компонентов
      (гейтвей), не потребитель чужого MCP-сервера.

    **Не сделано (следующий шаг, если приоритет появится):** включить `callbacks: ["prometheus"]`
    + `VMScrapeConfig` + дашборд (№4); добавить `cpu` limit (№9); явное решение по NetworkPolicy
    `ns: gateway`, включая egress к Postgres (№10, скорее всего allow только из `ns: agents`/
    `ns: llm` + `postgresql-infra-1:5432`, default-deny остальное — по аналогии с уже принятым
    решением для `ns: agents`); зеркалирование `ghcr.io` через Nexus (№1) — общее решение для
    LiteLLM/`llama-server`/`tei` разом, не точечный фикс.

    **~~Выставить UI LiteLLM наружу~~ — сделано и живо проверено (2026-09-13).** Два независимых
    слоя, оба реализованы (по запросу пользователя — не откладывать OIDC-логин на потом):
    1. **Сетевой периметр**: `IngressRoute litellm.aicd.devops-labs.ru` (встроенный в k3s Traefik)
       + общий Middleware `authelia-forward-auth` + `access_control.rules` в Authelia — тот же
       паттерн, что `radar`/`infra-panel`/`docs`, но **без `platform-viewers`** (только
       `platform-admins`+`platform-engineers`) — UI создаёт/удаляет virtual keys и меняет
       бюджеты, операционное действие, не просмотр.
    2. **Собственный логин `/ui`**: LiteLLM заведён ЕЩЁ ОДНИМ OIDC-клиентом Authelia (generic
       OIDC, `GENERIC_CLIENT_ID`/`_SECRET`/`_AUTHORIZATION_ENDPOINT`/`_TOKEN_ENDPOINT`/
       `_USERINFO_ENDPOINT`, `PROXY_BASE_URL` — env контейнера), тем же классом решения, что
       Gitea/Semaphore/Grafana. `secret/authelia` расширен полем `litellm_client_secret`
       (+`_hash`) тем же аддитивным приёмом, что и предыдущие поля. Fallback на `master_key`
       остался на `/fallback/login`. `GENERIC_USER_ROLE_ATTRIBUTE` НЕ настроен — маппинг ролей
       Authelia→LiteLLM вне скоупа этого захода, сетевой периметр (п.1) уже ограничивает вход.

    **Два реальных бага найдены и исправлены живым прогоном:**
    - Встроенный в k3s Traefik НЕ поддерживает cross-namespace ссылку на Middleware без
      явного флага контроллера (`--providers.kubernetescrd.allowCrossNamespace`, не включён) —
      `IngressRoute` в `ns: gateway`, ссылающийся на `Middleware authelia-forward-auth` из
      `ns: platform` (там же, где `radar`/`infra-panel`, которые эту проблему не ловили именно
      потому что живут в том же namespace, что сам Middleware), получал в логах Traefik
      `"middleware platform/authelia-forward-auth is not in the IngressRoute namespace
      gateway"` и роут молча становился невалидным — клиент видел голый 404 вместо ожидаемого
      редиректа на `sso.aicd.devops-labs.ru`. Решение — не глобальный флаг на весь Traefik
      (шире нужного), а вторая копия того же Middleware в `ns: gateway`.
    - Забытое правило `access_control.rules` для домена `litellm.aicd.devops-labs.ru` в
      Authelia — без него `default_policy: deny` не пропустила бы даже показ формы логина.
      Добавлено вместе с сетевым периметром выше.

    После обоих фиксов: неаутентифицированный запрос к `https://litellm.aicd.devops-labs.ru/ui`
    даёт `302 → https://sso.aicd.devops-labs.ru/...` с реальной страницей логина Authelia; логи
    Authelia показывают реальное решение `forward-auth` по этому домену
    (`"Access to https://litellm.aicd.devops-labs.ru/ui ... is not authorized to user
    <anonymous>, responding with status code 302..."`); логи Authelia не показывают ошибок
    валидации нового OIDC-клиента (`restart_count: 0`); `infra-panel` — `GET /assets/config.yml`
    содержит пункт LiteLLM; повторный прогон `site.yml` — `changed` только на безусловных
    `helmwave up`-задачах (сам паттерн этого проекта), ни одной новой дрейфующей задачи.

    **Третий баг найден пользователем в браузере после первого «сделано» (2026-09-13) и
    исправлен тем же днём**: реальный клик на кнопку логина Authelia падал с `{"error":
    {"message":"Internal server error"...}}`. Причина — под LiteLLM не доверял внутреннему PKI
    CA (OpenBao, ADR-0016), из которого выпущен `authelia-tls` — `httpx` (клиент, которым
    `fastapi_sso` внутри LiteLLM обменивает код на токен) падал на `POST
    https://sso.aicd.devops-labs.ru/api/oidc/token` с `[SSL: CERTIFICATE_VERIFY_FAILED]
    certificate verify failed: self-signed certificate in certificate chain` (видно в логах пода
    litellm — то же самое, что раньше уже решалось для Gitea/Grafana, только в этот раз забытое
    для LiteLLM при первой раскатке). Исправлено тем же готовым приёмом: `Secret
    aicd-platform-ca` заведён в `ns: gateway` (site.yml, копия задачи «...в namespace
    monitoring» для Grafana) + смонтирован в под на `/etc/ssl/certs/aicd-platform-ca.pem` +
    `SSL_CERT_FILE` в env контейнера (Python `httpx`, как и Go `crypto/x509`, уважает этот
    стандартный OpenSSL env var). Живо проверено: TLS-запрос к `sso.aicd.devops-labs.ru` из пода
    litellm тем же `ssl.create_default_context()`, что использует `httpx`, теперь возвращает
    `200` вместо ошибки проверки сертификата; `/health/readiness`/`/key/generate` по-прежнему
    работают (регрессии от фикса нет); повторный `site.yml` не даёт новых дрейфующих задач.

    **Четвёртый баг найден сразу за третьим (тот же живой клик-тест, 2026-09-13):** после фикса
    TLS логин упал по-новому — `oauthlib.oauth2...InvalidClientError: (invalid_client) ... The
    request was determined to be using 'token_endpoint_auth_method' method 'client_secret_basic',
    however the OAuth 2.0 client registration does not allow this method`. Причина — обратная
    уже известному случаю Semaphore (там подошёл `client_secret_post`): LiteLLM
    (`fastapi_sso`/`oauthlib`) безусловно шлёт `client_secret` через HTTP Basic Auth на обмене
    кода на токен, а клиент `litellm` в Authelia был зарегистрирован на `client_secret_post`.
    Исправлено — `token_endpoint_auth_method: 'client_secret_basic'` вместо `_post`. Логи
    Authelia после рестарта чистые (`restart_count: 0`, ошибок конфигурации нет).

    **Подтверждено пользователем (2026-09-13): логин через браузер реально проходит до конца.**
    Живая проверка (`SELECT user_id, user_role FROM "LiteLLM_UserTable"` на `postgresql-infra-1`)
    показала реальную запись `ivinogradov` — доказательство полного успешного OIDC-цикла (не
    только 302-редиректа, как раньше). Роль на тот момент — `internal_user_viewer` (самая
    урезанная из четырёх глобальных ролей LiteLLM: `proxy_admin`/`proxy_admin_viewer`/
    `internal_user`/`internal_user_viewer`) — ожидаемо, `GENERIC_USER_ROLE_ATTRIBUTE` сознательно
    не настраивался (см. выше).

    **По запросу пользователя настроен маппинг ролей: `platform-admins` → `proxy_admin`,
    `platform-engineers` → `internal_user`.** Не через `GENERIC_USER_ROLE_ATTRIBUTE` (ждёт
    СКАЛЯРНОЕ значение claim'а, а `groups` в Authelia — список) — реальный механизм для
    списочного claim'а найден через `openapi.json` живого инстанса (не угадан из документации,
    которая противоречиво описывала разные версии API): `role_mappings` внутри `SSOConfig`,
    настраивается `PATCH /update/sso_settings`, хранится в БД (`LiteLLM_SSOConfig`), сосуществует
    с уже заданными через env `GENERIC_*`-полями (разная `provenance` на каждое поле).

    **Ещё четыре реальных бага найдены и исправлены по пути:**
    1. Клиент `litellm` в Authelia не запрашивал scope `groups` — без него Authelia не кладёт
       claim `groups` в userinfo для этого клиента, маппингу не на чем строиться. Добавлен
       `groups` в `scopes` клиента + `GENERIC_SCOPE: "openid profile email groups"` в env пода.
    2. `PATCH /update/sso_settings` возвращал `500 Set STORE_MODEL_IN_DB='True' in your env to
       enable this feature` — отдельный от `database_url` флаг-переключатель admin-API на запись
       динамической конфигурации в БД. Добавлен `STORE_MODEL_IN_DB: "True"`.
    3. `kubernetes.core.k8s_exec` (в отличие от документации других модулей коллекции) требует
       `command` СТРОКОЙ, не списком — сам делает `shlex.split()`. Список молча превращался в
       мусорную строку вида `"['python3', ...]"`, exec падал на уровне OCI-рантайма, а библиотека
       `kubernetes` пыталась распарсить текст этой ошибки как целочисленный код возврата и падала
       с `invalid literal for int()` — вводящее в заблуждение сообщение, реальная причина глубже.
    4. `(... | from_json).values.role_mappings` в `when:` — Jinja резолвил `.values` в bound-метод
       `dict.values()` (коллизия имени ключа JSON-ответа `"values"` со встроенным методом), а не
       в значение ключа — `"object of type 'method' has no attribute 'role_mappings'"`. Исправлено
       на явный доступ по ключу `['values']['role_mappings']`.

    Живо подтверждено: `GET /get/sso_settings` показывает реально сохранённый `role_mappings`
    (`{"proxy_admin": ["platform-admins"], "internal_user": ["platform-engineers"]}`,
    `default_role: "internal_user_viewer"`); повторный `site.yml` — задача PATCH корректно
    пропускается (`when:` видит уже заданный `role_mappings`), никакого дрейфа.

    **Пятый баг — кнопка SSO на странице логина пропала сразу после первого `PATCH`, найден
    пользователем в браузере, исправлен и живо подтверждён (2026-09-13).** Причина: после ПЕРВОГО
    `PATCH /update/sso_settings` LiteLLM переключает источник правды для ВСЕГО `SSOConfig` на БД
    целиком, а не мёржит по полям с env — поля, не попавшие в тот конкретный PATCH
    (`generic_client_id`/`_secret`/эндпоинты/`proxy_base_url`, записывался только
    `role_mappings`), перестали резолвиться из `GENERIC_*` переменных окружения и стали `null` в
    `GET /get/sso_settings` (`provenance` сменилось с `"env"` на `"unset"`), хотя сами
    переменные окружения никуда не делись — из-за этого LiteLLM переставал показывать кнопку
    входа через SSO на странице логина. Исправлено — PATCH теперь несёт ВЕСЬ желаемый `SSOConfig`
    разом (все `generic_*`-поля + `proxy_base_url` + `role_mappings`), не только изменённое поле;
    `when:`-условие расширено проверкой `generic_client_id is none` в дополнение к
    `role_mappings is none`. **Живо подтверждено пользователем через реальный браузер: кнопка SSO
    видна и работает.**

    **Открыто:** обновляется ли роль (`user_role`) уже существующей записи в `LiteLLM_UserTable`
    при повторном логине, или маппинг применяется только при первом создании записи — не
    проверено; если роль `ivinogradov` останется `internal_user_viewer` после очередного логина,
    единственный выход — обновить `user_role` в БД вручную (разовое действие).

    **№3 (ссылка в infra-panel) закрыт (2026-09-13)** — прямой redirect URL для инициации
    OIDC-флоу найден живым прогоном (не документацией, официально не описан):
    `GET /sso/key/generate` → `303 See Other` → `https://sso.aicd.devops-labs.ru/api/oidc/
    authorization?...` → форма логина Authelia — тот же однокликовый паттерн, что у Gitea/
    Semaphore/Grafana. Ссылка в `infra-panel` переключена с `/ui` на `/sso/key/generate`. См.
    также обновлённое требование `docs/adr/0022-new-component-requirements.md` §3 — теперь
    обязательное для компонентов с нативным OIDC, LiteLLM больше не исключение.

60. **Standalone PostgreSQL (`postgresql-infra-1`, `docs/adr/0023-postgresql-standalone-role.md`)
    — код готов в обоих окружениях; на `aicd-devops-labs-ru` VM живая и Semaphore Project
    забутстрапен (2026-09-11), на `aicd` — ещё нет.** Новая роль `roles/postgresql`
    (molecule-сценарий зелёный целиком, включая найденную живым прогоном дыру — Debian-дефолтный
    catch-all `host all all 127.0.0.1/32` в `pg_hba.conf`, убран из роли), Terraform
    (`postgresql-infra-target.tf` в обоих `platform/*/terraform/`), `site.yml`-wiring (секрет
    `secret/postgresql`, DNS, `monitoring_agent`, Grafana dashboard) в обоих окружениях,
    `ansible-lint`+`--syntax-check` зелёные. БД/пользователь `litellm` заведены и живо проверены
    на `aicd-devops-labs-ru` (2026-09-12, см. ниже) — Grafana/sqlite по-прежнему явно вне скоупа
    (не запрошено).

    **`aicd-devops-labs-ru` — сделано (2026-09-11):**
    - `tofu apply` выполнен (побочный эффект захода по `platform-controller`, п.7.8 ниже) — VM
      `postgresql-infra-1` (VMID 113, `10.10.10.246`) живая.
    - **Semaphore Project `postgresql-infra`** (id=2, отдельный от `platform`, по принципу "1
      проект = 1 компонент") реально создан через REST: ключи (`gitea-admin` для клона
      `platform/gitops`, отдельный `ssh`-ключ `postgresql-infra-ssh` для доступа к хосту),
      repository, `Inventory` (`type: file`, БЕЗ `become_key_id` — passwordless sudo, тот же урок,
      что уже пойман для `infra_panel` в п.7.8), `Environment` (`GIT_CONFIG_*` для клона
      `devops-uslugi`, `postgresql_infra_postgres_exporter_password` — extra-var из уже
      существующего `secret/postgresql` OpenBao), Task Template `postgresql-infra-1 (ADR-0023)`
      (id=3, `--limit postgresql-infra-1`, playbook `playbooks/postgresql-infra.yml`).
      Wrapper-playbook + `inventory/postgresql-infra.ini` закоммичены в `platform/gitops` через
      Gitea Content API (не `git push` — этот способ, в отличие от зеркалирования самой коллекции,
      не заблокирован инструментарием, см. п.7.8).
    - **Реальный баг найден и исправлен**: `qemu-guest-agent` не был установлен на этой VM вообще
      (в отличие от остальных VM окружения) — Terraform-провайдер (`agent.enabled = true`)
      бесконечно висел на `refresh`/`apply` (`Plugin did not respond`, несколько попыток до 550с).
      Исправлено `apt install qemu-guest-agent` напрямую по SSH (роль `postgresql` тогда ещё не
      применялась). См. подробности — README `platform/aicd-devops-labs-ru`.
    - **Task Template запущен и проверен живьём** (2026-09-11, Task id=50 → `success`,
      `ok=55 changed=33 failed=0`): PostgreSQL 17 реально установлен и активен
      (`systemctl is-active postgresql@17-main` → `active`), слушает сеть (`listen_addresses=*`),
      TLS включён (`SHOW ssl` → `on`), `pg_hba.conf` не содержит Debian-дефолтного catch-all
      (только точечная запись для `postgres-exporter`/`127.0.0.1`, `replication`-строки —
      отдельная, не затронутая фиксом категория). `node_exporter`/`postgres_exporter`
      (systemd-юниты, имена через `_`, не `-`) оба `active`, отдают реальные метрики
      (`node_uname_info`, `pg_static`) на `127.0.0.1:9100`/`:9187`. **Повторный прогон Task
      Template (Task id=51) — `changed=0`**, полная идемпотентность подтверждена.

    **Следующие шаги (по явному запросу в будущем):**
    - Живой `tofu apply` + Semaphore Project `postgresql-infra` для `platform/aicd` (второй,
      независимый Semaphore-инстанс) — IP `10.66.14.13` выбран по анализу файлов, не подтверждён
      живой сетью.
    - ~~Grafana dashboard для `postgres-exporter`~~ — **проверено (2026-09-11)**: оба таргета
      (`node-exporter`/`postgres-exporter`, `instance=postgresql-infra-1`) `health: up` в vmagent
      (`GET /api/v1/targets`), `GrafanaDashboard` CR `postgres-exporter` —
      `DashboardSynchronized: True`, запрос `pg_up{instance="postgresql-infra-1"}` к vmsingle
      возвращает `1` — та же метка, что ожидает дашборд. Вся цепочка `postgres_exporter → vmagent
      → VictoriaMetrics → Grafana` подтверждена реальными данными, не только присутствием ресурсов.
    - **Найден и исправлен реальный баг дашборда (2026-09-11, пойман оператором в браузере):**
      сам дашборд открывался с ошибкой «Datasource not found, input variable». Причина —
      `ADDONS/grafana_dashboards/postgres_exporter_12485.json` (стандартный community-дашборд с
      grafana.com) использует имя input-переменной `DS_PROMETHEUS`, а `spec.datasources` у
      `GrafanaDashboard` CR в обоих `site.yml` маппил только `DS_VICTORIAMETRICS` (единственное
      имя, под которое ранее вручную переименовывали `__inputs` в файлах вроде
      `gitea_13192.json`) — grafana-operator не подставлял реальный datasource в панели с
      `DS_PROMETHEUS`. Исправлено добавлением второй записи `datasources` (маппинг ОБОИХ
      общепринятых имён на один и тот же `VictoriaMetrics`) в
      `platform/aicd-devops-labs-ru/ansible/site.yml` и `platform/aicd/ansible/site.yml` (~строка
      2004/1949) — универсальный фикс на будущее для любого нового community-дашборда с этим же
      паттерном, не только точечная правка одного JSON-файла. Применено живьём точечным патчем
      `GrafanaDashboard` CR (без полного `site.yml`) — панели подтверждённо ссылаются на
      `'datasource': 'VictoriaMetrics'`, не на плейсхолдер. `blackbox_13659_rev1.json` — тот же
      паттерн `DS_PROMETHEUS`, сейчас нигде не подключён, но будет подвержен тому же багу при
      подключении (уже закрыто тем же универсальным фиксом).
    - **Перенос Terraform-apply в Semaphore** — заблокировано на появлении S3-совместимого
      хранилища на платформе (нужен remote state; сейчас `terraform.tfstate` лежит локально,
      Semaphore обычно клонирует репозиторий заново на каждый прогон).
    - ~~Создание БД/пользователя `litellm`, переключение LiteLLM на БД~~ — **сделано и живо
      проверено (2026-09-12)**: `postgresql_user`/`postgresql_db` (owner `litellm`) + `pg_hba.conf`
      hostssl-грант с ноды `aicd-labs` (см. `site.yml`, play "Standalone PostgreSQL" —
      переставлена ПЕРЕД play LiteLLM-гейтвея, иначе Helm поднимал Deployment раньше готовности
      БД). `secret/litellm` в OpenBao расширен полем `db_password` аддитивно (KV v2 POST
      заменяет данные версии целиком — существующий `master_key` сохранён явно, не потерян).
      LiteLLM переключён с config-only режима на `general_settings.database_url`: под создал 75
      таблиц Prisma-схемы (`LiteLLM_*`), `GET /health/readiness` → `{"status": "healthy", "db":
      "connected"}`, `POST /key/generate` реально создал virtual key в БД. **Найден и исправлен
      реальный баг**: первый прогон с `database_url` — под уходил в `OOMKilled` (exit 137) на
      старом лимите `resources.limits.memory: 1Gi` (Prisma-миграция поднимает отдельный
      node-процесс query-engine поверх python-процесса) — поднято до `2Gi` в
      `helm/values/platform-devops-labs-ru/namespaces/gateway/litellm/values.yaml`, повторный
      прогон — под `Running`/`ready`, `restart_count: 0`. Повторный `site.yml` — `changed=0` на
      всех новых задачах (кроме `helmwave up`, который репортит `changed` безусловно).
      Миграция Grafana с sqlite на Postgres по-прежнему отдельная задача, не запрошена.
    - Backup (Bareos) — осознанно отложено, `backup_server` для платформы нигде не развёрнут
      (тот же пробел, что ADR-0022 уже фиксирует для всех существующих компонентов).
    - Зеркалирование источника установки (apt PGDG, не Nexus) — тот же известный, не блокирующий
      пробел, что у `postgresql_replication`/остальной коллекции.

61. **Naming convention для новых компонентов платформы — не зафиксирован.** До этого захода имена
    выбирались ad hoc для каждого компонента отдельно (`freeipa`, `cicd`, `llm1`). `postgresql-infra-1`
    (ADR-0023 §6) — первый компонент, спроектированный с форматом `<component>-<purpose>-<n>`
    (разделитель — по соглашению конкретной системы: дефис для Terraform/DNS/Semaphore Project,
    `<name>_hosts` через underscore для Ansible-групп). Нужно явно зафиксировать: (1) сам формат
    как общий для будущих компонентов, не только для этого случая; (2) закрытый список допустимых
    `purpose` — `infra` (обслуживает платформу) / `client-<slug>` / `project-<slug>` (под конкретного
    клиента/проект) — не оставлять свободной строкой во избежание разнобоя.

62. **GPU-мониторинг `llm1` (`dcgm-exporter`, ADR-0017 §4) — код уже был готов, живой статус не
    отслеживался в ROADMAP отдельным пунктом, README/ADR содержали устаревшее «не проверено».**
    Проверкой (2026-09-11) обнаружено, что сбор метрик на самом деле уже полностью живой (был
    развёрнут site.yml-прогоном в ходе более раннего захода по агентной платформе, ADR-0021, но
    этот факт не был явно задокументирован здесь): под `dcgm-exporter-g6j4w` `Running` на `llm1`
    (аптайм с 2026-08-29), `VMPodScrape dcgm-exporter` — таргет `health: up` в vmagent
    (`10.42.1.32:9400`), прямой запрос `DCGM_FI_DEV_GPU_UTIL` к `vmsingle` возвращает реальную
    серию с метками `modelName: NVIDIA GeForce RTX 5060 Ti`/`UUID`/`Hostname`. README/ADR-0017 §4
    обновлены, чтобы не вводить в заблуждение будущих операторов.

    **Реальный недостающий кусок — дашборд Grafana.** Метрики собираются, но ни один
    `GrafanaDashboard` для GPU/DCGM не был подключён (в `ADDONS/grafana_dashboards/` не было ни
    одного файла с этими метриками) — оператор не мог визуально посмотреть загрузку GPU, только
    через прямые PromQL-запросы. Добавлено (2026-09-11): дашборд DCGM с grafana.com, подключён
    через тот же `GrafanaDashboard`-механизм (`ADDONS/grafana_dashboards/`,
    `platform_aicd_devops_labs_ru_grafana_addons_dashboards`, только для этого окружения — GPU-нода
    есть только здесь), применён живьём и проверен.

63. **Инфраструктурные тесты платформы (общие + по каждому компоненту) — идея, реализация не
    начата.** Требование зафиксировано в `docs/adr/0022-new-component-requirements.md` §14 —
    новые компоненты обязаны приносить с собой такой тест.

    **Проблема — не гипотетическая, видна по этому же ROADMAP.** Каждая «живая проверка» после
    изменения (десятки примеров выше — LiteLLM `/health/readiness`, `pg_hba.conf` без catch-all,
    OIDC-discovery Authelia, метрики DCGM, Grafana-дашборды и т.д.) делалась одноразовым
    Python-скриптом в scratchpad (`kubernetes` python client + pod exec, `psql`, `curl` через
    служебный под) — добросовестная, но НЕ сохраняемая проверка: написана один раз, использована
    один раз, при следующей регрессии («не сломал ли вчерашний коммит логин Gitea?») пишется
    заново с нуля, а не запускается одной командой.

    **Решение — [testinfra](https://testinfra.readthedocs.io/en/latest/) (или эквивалентный
    pytest-based инструмент) поверх уже реального стенда**, НЕ вместо molecule (тот проверяет
    РОЛЬ в изоляции на одноразовой VM до раскатки — «работает ли код роли»), а ДОПОЛНИТЕЛЬНО —
    проверка уже развёрнутого, живого компонента на реальном окружении
    (`platform/aicd`/`platform/aicd-devops-labs-ru`) — «работает ли то, что реально стоит прямо
    сейчас», можно гонять как smoke/regression-проверку в любой момент, не только при первой
    раскатке. testinfra прицельно поддерживает нужные здесь backend'ы (SSH, `docker exec`,
    вероятно применим и к `kubectl exec` через кастомный connection/host-класс) — тот же класс
    проверок, что уже делается вручную (систем-юниты, порты, файлы, HTTP-запросы), просто
    оформленный как повторно запускаемый pytest-набор, а не одноразовый скрипт.

    **Два уровня:**
    1. Общеплатформенные (per-environment) — базовые инварианты: TLS-сертификаты не просрочены,
       OpenBao unsealed, kube-apiserver доступен, core-релизы (Gitea/Semaphore/Authelia/OpenBao)
       отвечают по HTTPS.
    2. Per-component — зеркало того, что уже вручную проверялось при раскатке каждого компонента
       в этом ROADMAP (пример: LiteLLM — `/health/readiness` → `db: connected`, TLS-сертификат
       валиден, Middleware/IngressRoute существуют, OIDC discovery отвечает; `postgresql-infra-1`
       — `pg_hba.conf` без catch-all, TLS `on`, exporter отдаёт метрики).

    **Явно не начато** — ни ретрофит для уже реализованных компонентов, ни выбор конкретного
    расположения тестов в репозитории/CI-интеграции. ADR-0022 §14 требует только НОВЫХ
    компонентов, ретроактивное покрытие существующих — отдельная будущая задача.

64. **Аудит litellm против ADR-0022 (2026-09-13) — два пункта явно отложены, не устранены.**
    ghcr-mirror (требование №1) и метрики (требование №4) исправлены и живо проверены в этом же
    заходе (`docker-group` в Nexus — `docker-hub-proxy`+`ghcr-proxy` на общем порту 8083, без
    новых поддоменов/TLS/DNS, `GET /v2/berriai/litellm/manifests/...` через mirror → `200`,
    регрессии на `docker.io` нет; `litellm_settings.callbacks: ["prometheus"]` +
    `VMServiceScrape` + дашборд `ADDONS/grafana_dashboards/litellm.json`, target `health: up`,
    `python_info{job="litellm-litellm"}` подтверждён в VictoriaMetrics). **Второй реальный баг
    найден по пути** — `/metrics` требует `Authorization`, как любой другой эндпоинт LiteLLM
    (401 без токена); `VMServiceScrape.bearerTokenSecret` обязан лежать в namespace самого
    `VMServiceScrape` (`monitoring`), не в namespace таргета (`gateway`) — заведён отдельный
    `Secret litellm-metrics-token` (копия `master_key`) в `monitoring`. Повторный `site.yml` —
    новые Nexus-задачи корректно `skipping` (идемпотентно). Остальные два пункта требуют решения
    оператора, не технической реализации по умолчанию:

    - **NetworkPolicy для `ns: gateway` (требование №10) — решение не принято.** `ns: agents` имеет
      `default-deny` (ADR-0015 §7), `platform`/`monitoring`/`cache` — признанное известное
      исключение ADR-0022 §10, но `ns: gateway` (где живёт litellm) не входит ни в список
      исключений, ни имеет собственного решения — это незамеченный пробел, не осознанный выбор.
      Кандидат по умолчанию — узкое allow-правило (litellm нужен исходящий доступ к `ns: llm`
      (llama-server/TEI), `ns: platform` (Authelia OIDC), внешнему PostgreSQL `10.10.10.246:5432`,
      Nexus/ghcr через мириант выше; входящий — только от Traefik) вместо полного `default-deny`.
    - **Кандидат-Operator для litellm — найден, не оценён.**
      [`litellm-operator`](https://operatorhub.io/operator/litellm-operator)
      ([PalenaAI](https://github.com/PalenaAI/litellm-operator)/
      [bbdsoftware](https://github.com/bbdsoftware/litellm-operator) форки) — Apache-2.0, OLM
      bundle для OperatorHub/OpenShift + Helm-чарт, ~9 CRD (instances/models/teams/users/keys/
      credentials/guardrails/budgets), bidirectional sync с LiteLLM REST API. Не официальный от
      вендора (BerriAI не публикует), ~11 звёзд на GitHub на момент находки — по планке требования
      №12 (переиспользуется для №15) это пограничный случай, не однозначно «зрелый». Требует
      отдельной оценки (maturity/maintenance cadence) прежде, чем менять текущий generic-чарт
      (`helm/localrepo/universal-chart`) — миграция не начата и не запрошена.

65. **Open WebUI — человеческий чат-фронтенд поверх уже работающего LiteLLM-гейтвея (ADR-0015
    §6/§7). Реализовано и живо проверено на `aicd-devops-labs-ru` — 2026-09-15.** До этого с
    моделью можно было говорить только через прямой API-вызов (curl/Python) — у платформы не было
    веб-интерфейса для человека-оператора, аналогичного ChatGPT/Open WebUI. Закрывает именно этот
    разрыв, не заменяет и не трогает сам LiteLLM.

    **Реализовано ровно по плану ниже (все 15 пунктов), три реальных бага найдены и исправлены
    живым прогоном (полная история — [docs/platform/agent-platform.md](docs/platform/agent-platform.md)):**
    1. Control-node `aicd-devops-labs-ru` — CPU почти исчерпан (2 allocatable, ~1920m занято) —
       `requests.cpu: 250m` не проходил scheduler, снижено до `50m`.
    2. OOMKilled (exit 137) — дефолтный RAG-путь Open WebUI безусловно тянет
       `sentence-transformers/all-MiniLM-L6-v2` с huggingface.co; `SSL_CERT_FILE` (нужен для OIDC
       с Authelia) подменяет системный CA-бандл целиком, публичный huggingface.co перестаёт
       проходить TLS-проверку, `huggingface_hub` уходит в retry-цикл до OOM. Решение —
       `RAG_EMBEDDING_ENGINE=openai`+`RAG_EMBEDDING_MODEL=local-embeddings`: эмбеддинги идут через
       уже работающий LiteLLM/TEI, публичный интернет не нужен вовсе.
    3. Тот же класс бага, что `SSOConfig` у LiteLLM, но у другого вендора: `rag.embedding_engine`
       живёт в SQLite-таблице `Config` (`PersistentConfig`), сеется из env только при первом
       создании записи — упавший (до фикса №2) под уже засеял пустое значение, новый env
       игнорировался. PVC ещё не содержал реальных данных — удалён целиком, чистая БД пересеялась
       из актуальных переменных.

    Живая проверка: `pytest platform/aicd-devops-labs-ru/tests/test_openwebui.py` — 6/6 зелёных
    (Deployment ready, PVC Bound, TLS Secret, секреты смонтированы без утечки в лог,
    unauthenticated-редирект на `sso.aicd.devops-labs.ru`, пункт в `infra-panel`); логи Authelia —
    без ошибок валидации нового OIDC-клиента; повторный `site.yml` — идемпотентен.
    **Подтверждено пользователем через реальный браузер (2026-09-15): вход через SSO работает** —
    логин Open WebUI OIDC-клиентом Authelia доведён до конца, не только редирект на форму.

    **Отложено (сознательно, задокументировано, не молчаливый пробел):** метрики (§4, нет
    OTel-коллектора), backup (§11, тот же пробел, что у всех stateful-компонентов), NetworkPolicy
    `ns: platform` (§10, уже в списке известных пробелов), Operator (§15, не найден).

    **План по чек-листу ADR-0022 (15 требований), поставленный до реализации:**

    1. **Установка (§1).** Официальный Helm-чарт есть (`open-webui/helm-charts`), но Nexus'овый
       `helm`-proxy до сих пор не включён (ADR-0018 §3, блокирующий пробел ADR-0022 §1 всё ещё не
       закрыт) — тянуть чарт напрямую из интернета значило бы нарушить требование, а не законно
       исключиться из него. Решение: тот же `helm/localrepo/universal-chart`, что уже несёт
       nexus/semaphore/authelia/infra-panel/litellm — простой Deployment/Service/Secret из
       деклативных полей, конфиг только через env (у Open WebUI нет YAML-конфига, всё через
       переменные окружения — даже проще, чем `config.yaml` у litellm). Образ —
       `ghcr.io/open-webui/open-webui` — уже идёт через Nexus `docker-group`
       (docker-hub-proxy+ghcr-proxy, заведён для litellm, ROADMAP №64) без дополнительной работы.
       Версия — пинить конкретный релизный тег на момент реализации (не `:main` — плавающий,
       официально не рекомендован для прода), сверять по `github.com/open-webui/open-webui/releases`
       живьём, не угадывать сейчас.
    2. **RBAC (§2).** Двухслойно, тем же классом решения, что LiteLLM: (1) сетевой периметр —
       `IngressRoute`+`authelia-forward-auth`+`access_control.rules`, но, в отличие от LiteLLM UI
       (только admins/engineers — операционный доступ к деньгам/ключам), сюда пускаются ВСЕ три
       группы (`platform-admins`/`platform-engineers`/`platform-viewers`) — чат с моделью не
       деструктивное действие, это обычный рабочий инструмент; переиспользуется уже существующая
       именованная политика `authorization_policies.platform_all_groups`
       (`helm/values/.../platform/authelia/values.yaml:158`, сейчас используется только Gitea/
       Semaphore). (2) Собственный логин — Open WebUI, в отличие от LiteLLM, не нуждается в
       PATCH-эквилибристике `SSOConfig`: нативные `ENABLE_OAUTH_SIGNUP`, `OPENID_PROVIDER_URL`
       (discovery-документ Authelia), `OAUTH_CLIENT_ID`/`_SECRET`, `OAUTH_SCOPES=openid email
       profile groups`, ролевой маппинг из коробки —
       `ENABLE_OAUTH_ROLE_MANAGEMENT=true`+`OAUTH_ROLES_CLAIM=groups`+`OAUTH_ADMIN_ROLES=
       platform-admins`+`OAUTH_ALLOWED_ROLES=platform-admins,platform-engineers,platform-viewers`
       (источник — [официальная интеграция Authelia](https://www.authelia.com/integration/openid-connect/clients/open-webui/),
       не угадано). Клиент Authelia: `redirect_uris: ['https://openwebui.aicd.devops-labs.ru/oauth/oidc/callback']`
       (путь колбэка другой, чем у litellm — `/sso/callback`), `token_endpoint_auth_method:
       'client_secret_basic'` (то же семейство клиентской библиотеки, что у LiteLLM — проверить
       живьём, не считать гарантированным по аналогии, тот же урок, что уже дважды пойман на
       Semaphore/LiteLLM). Open WebUI официально поддерживает PKCE (`OAUTH_CODE_CHALLENGE_METHOD=
       S256`) — единственный клиент платформы, где стоит включить `require_pkce: true` (остальные
       — gitea/semaphore/grafana/litellm — работают без PKCE, это не регресс для них, а
       дополнительное усиление конкретно для нового клиента, раз библиотека это поддерживает).
    3. **Ссылка в infra-panel (§3).** Прямой one-click SSO-редирект обязателен (нативный OIDC).
       Нужно живьём подтвердить точный путь — не угадывать по аналогии с `/sso/key/generate`
       LiteLLM (то был путь конкретно litellm-proxy, не переносится механически). Кандидат для
       проверки — `OAUTH_AUTO_REDIRECT` (упоминается в части источников как флаг, форсирующий
       редирект на IdP прямо с корня `/`, не только скрывающий кнопку логина) — подтвердить
       эмпирически на живом инстансе, тем же приёмом, что уже применён для LiteLLM.
    4. **Метрики (§4) — под вопросом, не тривиально в этом стеке.** Open WebUI отдаёт `/metrics`,
       но официальный путь — через OpenTelemetry (`ENABLE_OTEL`+`ENABLE_OTEL_METRICS`+OTLP-экспорт),
       не голый Prometheus pull, как у LiteLLM (`callbacks: ["prometheus"]`). У платформы сейчас
       нет OTel-коллектора вообще — заводить его ради одного компонента может быть несоразмерно
       тяжёлым. Решить на этапе реализации: либо поднять минимальный OTel-collector с
       Prometheus-exporter (`ns: monitoring`, разовая инвестиция, переиспользуется будущими
       OTel-компонентами), либо найти голый `/metrics`-путь в обход OTel (не подтверждено, что
       существует), либо явно задокументировать как осознанно отложенное — не оставлять
       незамеченным пробелом (тот же урок, что найден для LiteLLM в ROADMAP №64).
    5. **TLS (§5), 6. DNS (§6), 7. Секреты (§7), 8. releases_common-стаб (§8)** — тот же
       устоявшийся цикл, что у всех компонентов, без нового механизма. Секреты: `secret/openwebui`
       в OpenBao — `oauth_client_secret`(+hash для Authelia) тем же аддитивным приёмом, что
       litellm; плюс отдельный **virtual key LiteLLM** (не master key!) для связки Open
       WebUI↔LiteLLM — минтится через уже проверенный живьём `POST /key/generate` (ROADMAP №57),
       принцип наименьших привилегий: скомпрометированный фронтенд получает ограниченный ключ, не
       `proxy_admin`-полномочия мастер-ключа.
    9. **Resources (§9).** Явные `requests`/`limits` — чат-фронтенд, не инференс, умеренные
       (ориентир: `requests: {cpu: 250m, memory: 512Mi}`, `limits: {memory: 1-2Gi}` — уточнить по
       факту, SQLite-режим и websocket-сессии не должны требовать много).
    10. **NetworkPolicy (§10).** `ns: platform` (куда логично положить компонент — тот же класс,
        что gitea/semaphore/authelia/infra-panel/nexus, не `ns: gateway`, зарезервированный под
        сам API-гейтвей) уже в списке известных исключений ADR-0022 §10 (решение не принято ни для
        одного компонента этого namespace) — новый компонент явного решения не меняет, но и не
        обязан быть первым, кто его принимает (не блокирует эту задачу).
    11. **Backup (§11).** SQLite на PVC (`/app/backend/data`) хранит реальные пользовательские
        данные (история чатов) — не эфемерно, как у stateless-компонентов. Explicit-решение
        обязательно: тот же паттерн, что уже отложен для всех остальных stateful-компонентов
        платформы (Bareos `backup_server` нигде не развёрнут) — задокументировать как осознанно
        отложенное, не молчаливый пробел.
    12. **MCP (§12) — не применимо.** Open WebUI сам не вендор инструмента для регистрации в
        `mcp_servers:` LiteLLM — это потребитель гейтвея (включая его MCP-агрегацию), не цель.
    13. **Документация (§13).** Не заводить отдельный `docs/platform/openwebui.md` — расширить уже
        существующий `docs/platform/agent-platform.md` новым разделом (тот же приём, что уже
        применён для самого LiteLLM — тесно связанные компоненты одного логического стека
        документируются вместе, не дробятся по файлу на каждый Helm-релиз).
    14. **Инфраструктурные тесты (§14) — впервые обязательны, не «известное исключение».** Open
        WebUI — первый компонент платформы, предлагаемый ПОСЛЕ появления требования №14
        (2026-09-13) — litellm/остальные 14 компонентов попадают под ретроактивное исключение,
        этот НЕ попадает. Реализация обязана принести с собой реальный testinfra-тест (или
        эквивалент), не просто задокументировать намерение.
    15. **Operator (§15) — не найден.** Поиск через OperatorHub.io и `github.com/open-webui`
        никакого официального/community Operator не нашёл (обычный Deployment, как у litellm и
        большинства компонентов платформы) — фиксируется явно, а не молча пропускается.
        **Задача на будущее, если появится:** найти готовый Operator для Open WebUI позже или
        оценить целесообразность написания своего — не блокирует эту реализацию.

    **Интеграция с гейтвеем:** `OPENAI_API_BASE_URL: http://litellm-litellm.gateway.svc.cluster.local:4000/v1`
    (в кластере, без выхода через IngressRoute/forwardAuth — тот же приём, что уже используют
    `local-default`/`local-embeddings` внутри самого LiteLLM), `OPENAI_API_KEY` — virtual key из
    п.7 выше, не мастер-ключ.

    **Явно НЕ решено на этапе разведки, требует подтверждения перед/во время реализации:**
    точный путь one-click SSO-редиректа (п.3), механизм метрик (п.4), точное значение
    `token_endpoint_auth_method` (п.2, эмпирически, не по аналогии), конкретная версия образа
    (п.1). Ничего из этого не блокирует старт реализации — все четыре проверяются живым прогоном
    на месте, тем же способом, что уже применялся для LiteLLM.

66. **Qdrant — векторная БД для базы знаний (RAG).** Сейчас RAG в агентной платформе не имеет
    выделенного vector store: Open WebUI (№65) явно сконфигурирован на
    `RAG_EMBEDDING_ENGINE=openai`/`RAG_EMBEDDING_MODEL=local-embeddings` (эмбеддинги идут через
    LiteLLM/TEI), но сам вектор хранится во встроенном движке приложения (Open WebUI по умолчанию
    — locally-persisted Chroma на том же PVC), не в отдельном масштабируемом сервисе. Отдельная
    задача изоляции `ns: agents` (№58, ADR-0015 §9 — агентный код исполнения) и общая база знаний
    платформы (не только для одного чат-фронтенда) упираются в то же самое — нужен переиспользуемый
    vector store, а не по одному встроенному индексу на каждого потребителя.

    **Qdrant** — кандидат: открытый исходный код (Apache-2.0), gRPC+REST API, официальный
    Helm-чарт (`qdrant/qdrant-helm`), поддерживает snapshot/backup через S3-совместимое хранилище
    (пересекается с открытым вопросом по S3-компоненту для Loki — тот же S3-эндпоинт потенциально
    обслуживает и логи, и снапшоты Qdrant, и pgBackRest/Bareos).

    Не проработано архитектурно: потребители (только Open WebUI, или общий сервис для будущих
    agent-джобов); namespace (`ns: agents` или рядом с LiteLLM в `ns: gateway`); RBAC-периметр
    (внутренний ClusterIP-only сервис для LiteLLM/агентов, без публичного IngressRoute — по
    аналогии с `local-embeddings`/TEI, не публичный компонент); размер PVC и необходимость реплик
    (зависит от решения по storage layer, см. №67 ниже). Требует отдельного ADR перед реализацией
    — сейчас зафиксирована только идея.

67. **Longhorn — распределённое блочное хранилище, замена `local-path` StorageClass k3s.** Все
    stateful-компоненты обеих платформенных сред (`platform/aicd`, `platform/aicd-devops-labs-ru`)
    сейчас держат PVC исключительно на встроенном k3s `local-path` StorageClass — включая
    критичные по данным сервисы (Gitea, PostgreSQL `postgresql-infra-1`, будущий Loki/Qdrant,
    `backup_server` Bareos-каталог). Это уже всплывало как ограничение при разведке S3 для Loki —
    in-cluster MinIO был бы того же класса надёжности, что и всё остальное, без репликации.

    **Важная оговорка, которую нужно исследовать перед ADR, не проектировать вслепую:** обе
    платформенные среды сейчас — фактически один control-plane узел на окружение (`platform_hosts`
    в обоих inventory — одна ВМ), а не multi-node кластер. Основная ценность Longhorn —
    репликация томов МЕЖДУ узлами; на единственном узле она не даёт того же выигрыша (только
    snapshot/backup поверх локального диска того же узла, без реальной отказоустойчивости).
    Открытый вопрос — добавлять ли worker-узлы одновременно с этим переходом, или Longhorn на
    первом этапе даёт только более удобный снапшоттинг/бэкап-механизм (S3-target для бэкапов
    томов — тоже пересекается с общим вопросом по S3-хранилищу), а не HA.

    Не проработано архитектурно: single-node vs multi-node сценарий (см. выше), миграция уже
    существующих PVC с `local-path` на Longhorn (в k3s это не online-операция — обычно
    пересоздание PVC + перезалив данных, не in-place), совместимость с текущими hardcoded
    `storageClassName: local-path` во всех values-файлах компонентов (потребует правки каждого).
    Требует отдельного ADR перед реализацией — сейчас зафиксирована только идея.

68. **Пересмотр `monitoring_server` (k3s-путь) — аудит против ADR-0022, решение по S3 для Loki,
    переименование в `observability-service` рассмотрено и отложено.** Живой аудит (2026-09-16)
    k3s-пути `monitoring_server` (VictoriaMetrics Operator + grafana-operator, оба реальных
    платформенных окружения) против 15-пунктного чек-листа ADR-0022 — **9/15 выполнено, 3
    известных исключения (§10 NetworkPolicy, §14 testinfra, §12 MCP — все уже в списке признанных
    пробелов ADR-0022), 3 реальных гэпа**:
    - **§1 Установка** — `grafana-operator` тянет образ напрямую с `ghcr.io`, компоненты
      VictoriaMetrics — с публичных registry, мимо Nexus-прокси (на `aicd-devops-labs-ru`
      `docker-group`/`ghcr-proxy` уже заведён для litellm/openwebui, ROADMAP №64/65 — переключить
      просто, не переиспользовано).
    - **§11 Backup** — данные Loki/VictoriaMetrics нигде не зарегистрированы в Bareos
      (`backup_server`), тот же незакрытый класс, что у всех остальных stateful-компонентов
      платформы.
    - **§12 MCP** — официальный `grafana/mcp-grafana` не зарегистрирован в `mcp_servers:` LiteLLM.

    **Главная находка — не пункт чек-листа, а фактическое отсутствие компонента:** Loki (сбор
    логов) **нигде не развёрнут на реальных окружениях** — есть только заготовка-референс
    `helm/envs/k3s-monitoring.yaml` и пустой стаб `helm/values/releases_common/loki.yaml`, не
    подключённые ни к `platform/aicd`, ни к `platform/aicd-devops-labs-ru`. Живого S3-эндпоинта на
    обоих окружениях нет вообще — деплой Loki упирается в решение по объектному хранилищу.

    **Принятые решения (2026-09-16):**
    1. **S3 для Loki — новый отдельный shared-компонент MinIO**, не bundled-сабчарт внутри самого
       Loki-релиза. По naming convention ADR-0023 §6 (`<component>-<purpose>-<n>`) —
       `minio-infra-1`. Переиспользуется будущими потребителями, а не только Loki: pgBackRest
       (`postgresql_replication`, уже сконфигурирован под S3, ждёт эндпоинта), `backup_server`
       (ADR-0009 §1, S3 явно отложен как «следующий шаг» после MVP на локальном диске), снапшоты
       Qdrant (№66 выше). Архитектура/реализация — отдельная задача, здесь зафиксировано только
       решение по подходу.
    2. **Окружение — только `aicd-devops-labs-ru`.** Тот же паттерн, что LiteLLM/Open WebUI
       (№59/№65) — сначала один стенд, живая проверка, `platform/aicd` при необходимости
       повторяется отдельным заходом позже (там ещё нет и Nexus `docker-group`/ghcr-mirror,
       нужного для §1 выше).
    3. **Переименование роли/компонента в `observability-service` — рассмотрено, реализация
       сейчас НЕ делается.** Реальный k8s namespace уже общий (`monitoring`), а сама Ansible-роль
       `roles/monitoring_server` используется не только платформой, но и demo-стендами,
       molecule-сценариями и docker-оркестратором — полный ренейминг (директория + весь префикс
       переменных `monitoring_server_*`) заденет ориентировочно ~150 файлов коллекции, включая
       код, не завязанный на конкретную платформу. Остаётся открытым вопросом для отдельного
       захода: переименовать ли только то, как компонент называется НА ПЛАТФОРМЕ (документация,
       ROADMAP, ADR — без переименования переиспользуемой роли), или делать полный рефактор роли
       целиком. Не блокирует ни аудит выше, ни деплой Loki+MinIO.

    Реализация (Terraform/Ansible/Helm для MinIO+Loki на `aicd-devops-labs-ru`, устранение §1/§11/
    §12 гэпов) — отдельная задача, не начата.

69. **Скилл `client-onboarding` — Terraform+Ansible для нового внешнего клиента, по анкете
    (`docs/adr/0025-client-onboarding-architecture.md`).** Закрывает пробел, обозначенный №61
    (naming convention `client-<slug>` не имела ни одного реального потребителя): `.claude/skills/
    client-onboarding/SKILL.md` — интервью → `client-profile.yaml` → генерация отдельного
    git-репозитория клиента (Terraform + Ansible), не каталога внутри этой коллекции.

    **Реализовано:** `terraform-modules/site-proxmox/` и `terraform-modules/site-libvirt/` —
    переиспользуемые дочерние модули (обобщение `platform/aicd-devops-labs-ru/terraform`/
    `platform/aicd/terraform` через `for_each` по карте ВМ из анкеты), подключаются клиентским
    репозиторием git-ссылкой с закреплённым `ref`. Ansible клиента вызывает уже существующие
    роли по полному имени коллекции (`devops.uslugi.freeipa`/`postgresql`/`infra_dns`/`fail2ban`).
    k3s — тот же join-паттерн, что `llm1` (ADR-0015): первый узел `xanmanning.k3s`, второй —
    сырой `get.k3s.io` agent-join с тейнтом, без Helm-нагрузки.

    **Явно не сделано (см. ADR-0025 «Явно вне периметра v1»):** Redis/MinIO/git-сервер —
    заглушка (ВМ + `fail2ban`, установка софта — TODO-маркер в `site.yml`, новых ролей не
    писали); Helm-слой на клиентском k3s.

    **Уточнение (2026-09-20, тот же день):** материализация (`tofu apply`/`ansible-playbook`)
    сгенерированного репозитория идёт через `Module` CRD + platform-controller + Semaphore
    (ADR-0014) — тот же механизм, что уже обслуживает саму платформу, а не отдельный, отложенный
    ручной путь, как значилось здесь раньше. Клиент при этом не получает прямого доступа к
    Semaphore — только статус/результат и логи (выборкой из Loki, ROADMAP №68) через `lk-api`
    (ADR-0025 §5). Не специфицировано: структура Semaphore Project/Task Template на клиента,
    владение `inventoryRef`, изоляция OpenBao клиента.

70. ~~**Подтверждено живым прогоном: `growpart` (cloud-init) сам растягивает root-ФС после
    онлайн-resize диска на Proxmox — отдельная автоматизация в ролях/`site.yml` не нужна.**~~ —
    **сделано** (закрыто в момент обнаружения, не осталось висящей задачей). Найдено при
    онбординге wave/sel (2026-10-04): после `tofu apply` (resize диска на уровне Proxmox у 7 ВМ
    + пересозданной `sel-i-ipa01`) файловая система внутри гостя выросла сама, без перезагрузки
    и без ручного `growpart`/`resize2fs` по SSH — подтверждено на ОБОИХ образах (Ubuntu 24.04
    cloud-image и Rocky 9 GenericCloud). Причина — модуль `cc_growpart` в обоих образах стоит с
    `frequency: always` по умолчанию (`/etc/cloud/cloud.cfg`, не наша настройка), это стандартное
    поведение upstream cloud-init. **Вывод:** ни одна роль коллекции и ни один клиентский
    `site.yml` не должны содержать задач `growpart`/`resize2fs` — это дублирование уже
    работающего механизма образа. Зафиксировано в `docs/proxmox-templates.md` (часть 2, после
    SELinux-абзаца) сразу же, чтобы будущий онбординг не тратил время на тот же вопрос.

---

## Предлагаемая последовательность работ

1. ~~**Решить архитектурную развилку nginx/nginx_multidomain (P5, №32)**~~ — сделано: роль
   `nginx` удалена, `nginx_multidomain` — единственный путь вперёд.
2. ~~**Быстрые критические фиксы (P0), без архитектурных решений** — пункты 9, 10 (monitoring_agent)
   чинятся точечными однострочными правками~~ — **сделано**: №9 (Jinja-скобки в пути к
   `daemon.json`) и №10 (fail-fast для `pve_exporter` под docker-оркестратором) исправлены.
   Из P5-33 (§9 документа `nginx_multidomain`) баги 9.1–9.3 (утечка `set_fact`, асимметричная
   валидация `root`, `basic_auth`/`json`-логи, ломающие `nginx -t`) — **тоже сделано**, см. P5-33
   выше и `extensions/molecule/nginx_multidomain/` (verify зелёный).
3. ~~**Security-патч секретов (P1, пункт 11)** — механическая правка `mode:`/`no_log:` по списку
   файлов, отдельный PR.~~ — **сделано**: заодно закрыт весь раздел P1 целиком (пункты 12-14 —
   assert на дефолтные S3-credentials, checksum для бинарников экспортеров, requirements.yml для
   `xanmanning.k3s`), см. раздел P1 выше.
4. ~~**monitoring_server P0 №1-5** — требуют решения по P5 №34 (поддерживать ли алертинг в docker
   вообще) перед тем как чинить scrape-конфиги и dashboard provisioning.~~ — **сделано**: решение
   P5-34 принято («k3s-only», без реализации `vmalert` в docker-compose), все пять пунктов
   исправлены, см. раздел P0 выше.
5. **Тестовое покрытие (P4)** — начиная с `nginx_multidomain` (самый дешёвый сценарий: реальный
   `nginx -t` в verify сразу ловит находки §9 её архитектурного документа) — ~~сделано~~:
   `extensions/molecule/nginx_multidomain/` (docker driver), см. таблицу P4 выше; попутно нашёл
   и исправил баг с недостающим `mkdir` для `nginx_proxy_cache_zones`. Баги §9.1–9.3 (пункт 2
   выше) с тех пор **тоже почищены** — set_fact-утечка и асимметричная валидация `root` исправлены
   в коде, `basic_auth`/`json`-логи теперь дают явный `assert`-fail вместо молчаливой поломки
   `nginx -t` (сама функциональность по-прежнему не реализована — это отдельная задача §8).
   `monitoring_server` (самый рискованный по числу найденных P0) — ~~сделано~~: два сценария,
   `docker` и `k3s` (#40), см. таблицу P4 выше. `reverse_proxy_traefik` (сборка с нуля) — тоже
   ~~сделано~~ (#41). `infra_dns` и `monitoring_agent` — тоже ~~сделано~~, см. таблицу P4 выше
   (сценарий `monitoring_agent` заодно нашёл и исправил реальный P0-баг №36 — pve/mysqld-exporter
   крашились под systemd с `PermissionError`). **Раздел P4 закрыт целиком** — все пять ролей
   коллекции покрыты molecule-сценариями.
6. **Чистка мусора (P3)** — низкий риск, можно делать параллельно отдельными мелкими PR в любой
   момент. Основной объём (роль `nginx` и её дубликаты документации/scratch-тестов) уже снят
   вместе с решением P5-32.
7. **Платформенный контроллер (ADR-0014)** — архитектура решена, план реализации по стадиям
   (зависимости между стадиями см. в `docs/adr/0014-platform-controller-architecture.md`):
   1. ~~**Фаза 0**~~ (пререквизит из ADR-0012, не часть ADR-0014 самого по себе) — **сделано**:
      минимальный срез — K3s (одна нода) + Gitea + Semaphore UI, оба Helm-релизами через
      Helmwave на одном кластере (`platform/aicd/`, см. README там) — без ожидания
      Harbor/OpenBao/Authelia, которые независимы и не блокируют это. Проверено реальным
      прогоном: `tofu apply` → `ansible-playbook site.yml`, оба пода `Running`, PVC `Bound`,
      HTTP 200 через встроенный k3s Traefik, idempotent повторный прогон. Две реальные находки —
      race condition (Traefik CRD ещё не зарегистрирован в момент первого `helmwave up` — k3s
      разворачивает встроенный Traefik асинхронно) и коллизия `helm/helmwave.yml` (общий
      рендер-файл с `roles/monitoring_server`, `K8S_CLUSTER=platform` перезаписывал чужой
      референс) — обе исправлены, см. `platform/aicd/README.md`. Ручные шаги (создание
      репозитория в Gitea, Task Template в Semaphore на роли `infra_panel`) — ~~сделано~~:
      выполнены на живом стенде через REST API обоих сервисов (организация `platform`, репозиторий
      `platform/gitops`, Semaphore-проект + Task Template `infra_panel (pilot, ADR-0014 Фаза 0)`),
      см. `platform/aicd/README.md`. Сам Task Template ни разу не запускался — установка
      коллекции `devops.uslugi` на runner'е и реальный целевой хост в inventory остаются открытыми
      (не блокируют переход к Фазе 1). **Фаза 0 закрыта целиком.**
   2. ~~**Фаза 1**~~ — схема `Module` CRD (`spec.role`/`spec.vars`/`spec.inventoryRef`,
      `status.conditions`/`lastAppliedRevision`/`lastSyncTime`/`semaphoreJobID`), без кода
      контроллера — **сделано**: `platform-controller/config/crd/module-crd.yaml`, применена на
      живом стенде `platform/aicd` вместе с одним примером CR
      (`config/samples/module-infra-panel.yaml`, ссылается на реальные `platform/gitops` в Gitea
      и Task Template id=1 в Semaphore из Фазы 0). Проверено: валидация OpenAPI-схемы (вложенные
      `vars`/`inventoryRef`), short name `mod`, printer columns, и отдельно `status`-subresource
      через `kubectl patch --subresource=status` (имитация будущей записи контроллера) — все поля
      принимаются и корректно читаются обратно. См. `platform-controller/README.md`. Схема
      достаточна для перехода к Фазе 2.
   3. ~~**Фаза 2**~~ — GitOps-синхронизация: **Flux** (выбран вместо ArgoCD — CRD-first, без
      второго web UI, легче для одной ноды; `docs/overview.md` уже отражает этот выбор через
      ADR-0014) — **сделано**: `flux2` Helm-релиз (только `source-controller`+
      `kustomize-controller`, остальные контроллеры чарта отключены) через Helmwave
      (`helm/envs/platform.yaml`), `GitRepository`/`Kustomization`/`Secret` в
      `platform/aicd/flux/` применены на живой стенд. Проверено реальным прогоном: поле
      `spec.vars.infra_panel_gitops_managed: true`, закоммиченное в `platform/gitops` **только
      через Gitea API** (без единого `kubectl apply`), появилось в живом `Module` в кластере
      после reconcile-цикла (~20-30с). См. `platform/aicd/flux/README.md`.
   4. ~~**Фаза 3**~~ — контроллер MVP (`platform-controller/`, новый top-level каталог этого же
      репозитория — единая история версий с ролями, свой `go.mod`, независимый от poetry/
      ansible-lint тулчейна остального репозитория): событийный reconcile (create/update →
      вызов Semaphore API → запись `status`), ещё БЕЗ непрерывного drift-loop — снижает риск
      первого прогона, не отменяет итоговое решение ADR §3 — **сделано**: `controller-runtime`
      manager без leader election/metrics, watch по unstructured `Module`,
      `GenerationChangedPredicate` (не реагирует на свои же записи `status`). Semaphore API-клиент
      (`internal/semaphore/`) — `Authorization: Bearer <персональный токен>`,
      `POST /api/project/{id}/tasks` с `spec.vars` в поле `environment`. Проверено реальным
      прогоном: контроллер запущен локально (Go на control-хосте нет, собран/выполнен через
      `docker run golang:1.23 --network host`, чтобы обойти системный HTTP-прокси для приватного
      IP стенда) против живого стенда — подхватил существующий `Module`, вызвал реальный Semaphore
      API, записал `status.conditions`/`semaphoreJobID`, подтверждённые независимым запросом
      `GET /api/project/1/tasks` (тот же ID, тот же `environment`). Сама задача в Semaphore
      закономерно упала (`devops.uslugi` не установлена раннером — уже известный открытый вопрос
      Фазы 0) — вне зоны ответственности этой фазы. См. `platform-controller/README.md`.
   5. ~~**Фаза 4**~~ — непрерывный reconcile (`RequeueAfter` + exponential backoff на ошибках) —
      закрывает ADR §3 полностью — **сделано**: устаканившийся (terminal `Ready`) `Module`
      переприменяется заново через `driftInterval` (30с, пилотное значение), переиспользуя
      `status.conditions[Ready].status` как маркер фазы (`Unknown` = job выполняется, `True`/
      `False` = пора проверить дрейф). Проверено реальным прогоном: `noop-pilot` (тривиальный
      playbook без внешних зависимостей — единственный на этом стенде, реально доходящий до
      `success`) три раза подряд корректно перезапускался ровно с интервалом `driftInterval`, без
      единого дубля; `infra-panel-pilot` в том же прогоне так же корректно (без дублей) продолжал
      циклически падать. Найден и исправлен баг — забытый `RequeueAfter` после terminal-статуса
      (без него drift-loop не срабатывал вообще, хотя код компилировался). Попутно найдены и
      исправлены три independent проблемы самого стенда, ошибочно принятые ранее за «коллекция не
      установлена»: реальная причина всех падений с Фазы 0 — баг Semaphore v2.10.30 при
      `git clone` (`GIT_TERMINAL_PROMPT`, апстрим-issue, исправлено обновлением до v2.19.8, что
      также потребовало миграции bolt→sqlite, БД пересоздана с нуля); затем — `none`-тип git-ключа
      не даёт учётных данных для приватного репозитория (исправлено `login_password`-ключом);
      затем — `requirements.yml`-заглушка в корне `platform/gitops` (Фаза 0) сканируется
      Semaphore для *любого* Task Template проекта, блокируя даже независимый `noop` (удалена).
      Реальный источник коллекции `devops.uslugi` для раннера — **решено отдельно, после Фазы 4**:
      попытки агента зеркалировать/точечно скопировать её в Gitea заблокированы инструментарием
      (расценено как передача содержимого доверенного репозитория, не снимается согласием
      пользователя) — репозиторий `platform/devops-uslugi` запушен пользователем вручную;
      креды для клонирования — через `GIT_CONFIG_*` в Semaphore Environment, не в git (коммитить
      пароль в `requirements.yml` тоже заблокировано). Подтверждено реальным прогоном:
      `devops.uslugi:1.0.0 was installed successfully`, `ansible-playbook` дошёл до
      `PLAY [infra_panel]`, упал на `placeholder-host` — последний открытый вопрос (нужен
      реальный целевой хост) перед сквозной проверкой, см. `platform-controller/README.md`.
   6. ~~**Фаза 5**~~ — первый реальный пилотный модуль (`infra_panel`/`monitoring_agent` — не
      HA-БД роли: у них ручной promote/failover, плохо сочетающийся с автоматическим reconcile
      на раннем этапе) со сквозной проверкой всей цепочки на demo-стенде — **сделано**:
      `infra_panel` выбран. Реальный целевой хост —
      `platform/aicd/terraform/infra-panel-target.tf` (отдельная VM, полностью изолированные
      Terraform-ресурсы — не задета уже работающая `cicd`). Полная цепочка подтверждена
      реальным прогоном ЧЕРЕЗ КОНТРОЛЛЕР (не только ручные API-вызовы): git-коммит →
      Flux-синхронизация `Module` → контроллер обнаружил новый generation → реальный Semaphore
      job → Docker Engine реально установлен, контейнер `infra-panel` (homer) реально поднят и
      `healthy` — `status: success`. Drift-check (Фаза 4) повторно переприменил модуль тоже
      успешно, без вмешательства. Найдена и исправлена мелкая деталь — playbook не имел
      `become: true`. См. `platform-controller/README.md`, «Фаза 5».
   7. **Фаза 6** — расширение охвата на остальные роли/подсистемы. Ключевой открытый вопрос
      ADR-0014 («модуль↔роль 1:1 или модуль объединяет несколько ролей одним логическим
      сервисом») — ~~не решён~~ **решён**: `Module.spec.role` указывает на playbook, а не
      обязательно на одну директорию `roles/*` — плейбук может композировать несколько
      top-level ролей подряд (обычный список `roles:`, без нового механизма на уровне CRD).
      Подтверждено реальным прогоном: `playbooks/infra_panel.yml` расширен до
      `reverse_proxy_traefik` → `infra_panel` (тот же порядок, что molecule converge) —
      реконсайлится корректно через контроллер, drift-check переприменил ДВАЖДЫ подряд
      `status: success, changed=0` (полная идемпотентность композиции из двух ролей). См.
      `platform-controller/README.md`. Остальной охват («Фаза 6» в широком смысле — прогнать
      это на всех остальных подходящих ролях коллекции) не детализирован заранее, остаётся
      открытым.
   8. **Второе окружение (`platform/aicd-devops-labs-ru`)** — весь цикл Фаз 0–6 повторён на
      втором, независимом стенде (Proxmox вместо libvirt), **сделано и проверено реальным
      прогоном** (2026-09-11): pilot target VM (`terraform/infra-panel-target.tf`, отдельный
      ресурс, тот же принцип изоляции состояния, что `freeipa-target.tf`/`postgresql-infra-target.tf`),
      `flux/` (Flux/`gitops-git-auth` уже были развёрнуты site.yml до этого захода — донастроен
      только сам GitOps-source), CRD, bootstrap Gitea (org `platform`, репозиторий
      `platform/gitops`; зеркало `platform/devops-uslugi` уже было запушено пользователем в
      более раннем заходе) и Semaphore (Project, ключи, inventory, environment, два Task
      Template) через REST API, два Module CR (`noop-pilot`/`infra-panel-pilot`) закоммичены в
      `platform/gitops` и подхвачены Flux без единого `kubectl apply`. Контроллер запущен
      локально тем же приёмом, что на первом стенде, но **без `InsecureSkipTLSVerify`/Host-
      header хака** — реальное имя `semaphore.aicd.devops-labs.ru` (`--add-host` в
      `docker run`, раз DNS/etc.hosts хоста не разделяется с контейнером) и `SSL_CERT_FILE`,
      указывающий на внутренний PKI CA (Go на Linux сам подхватывает эту переменную для
      системного пула сертификатов) — TLS проверяется по-настоящему. Реконсайл подтверждён:
      `infra-panel-pilot` — `status: success`, реальные `traefik`/`infra-panel` контейнеры
      `healthy` на pilot-VM, 5 drift-циклов подряд без дублей job'ов, последний —
      `changed=0` (полная идемпотентность); `noop-pilot` — десятки успешных циклов. Три
      находки, специфичные для этого захода (все исправлены):
      - `tofu apply` для клона VM в foreground с дефолтным 2-минутным таймаутом был убит
        посреди клонирования — Proxmox успел создать VM, а terraform state — нет, что привело
        к дублирующимся VM на следующем прогоне (найдено пользователем в Proxmox UI, не
        инструментами). Впредь — только `run_in_background` для VM-клонов с самого начала.
      - Semaphore `Inventory.become_key_id`, ошибочно указанный на SSH-ключ (тип `ssh`) вместо
        пусто/`login_password`, ронял ЛЮБОЙ job ещё до `ansible-playbook`
        (`"access key type not supported for ansible become user"`) — у целевого хоста
        passwordless sudo, поле вообще не нужно.
      - `requirements.yml` в `platform/gitops` указывал `version: main`, а реальная (и
        единственная) ветка зеркала `platform/devops-uslugi` — `feat/new-cloud-platform-development`
        (та, что реально была запушена) — `ansible-galaxy` падал на `git checkout main`.
