# ROADMAP — план улучшений коллекции `devops.uslugi`

Документ подготовлен по итогам код-ревью всех ролей коллекции (`monitoring_server`,
`monitoring_agent`, `infra_dns`, `nginx`, `nginx_multidomain`, `reverse_proxy_traefik`).
Каждый пункт содержит ссылку `файл:строка` и конкретный сценарий отказа — без общих
рекомендаций.

> **Обновление:** по решению P5-31 роль `nginx` удалена из коллекции целиком (была
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
   **закрыто по P5-33 решением «документировать как k3s-only»** (реализация `vmalert` в
   docker-compose осталась отдельной задачей архитектурного уровня, не патчем):
   - Все `monitoring_server_victoria_metrics_alerts_rules_*_default` в `defaults/main.yml` теперь
     дополнительно гейтятся на `monitoring_server_orchestrator == 'k3s'` (раньше просто наследовали
     `scrape_*`-флаг, который `true` по умолчанию почти для всех экспортеров — то есть алерты были
     бы «включены» по умолчанию и для docker, где `vmalert` не существует).
   - Добавлен fail-fast в `check-and-install-requirements.docker.yml`: если пользователь явно
     включает `alert_rules_default_enabled` для экспортера под `docker`, играется понятная ошибка
     со ссылкой на этот пункт и на P5-33, а не молчаливый no-op.
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

### nginx / nginx_multidomain — закрыто удалением роли `nginx` (см. P5-31)

6. ~~**`roles/nginx/templates/nginx.conf.j2` не является валидным nginx-конфигом (3 независимых
   бага)**~~ — файл удалён вместе с ролью. Баги (отсутствующая `;` после `gzip_types`, неверный
   синтаксис директивы `user`, ссылка на необъявленный `log_format main`) в `nginx_multidomain`
   не воспроизводятся: эта роль не рендерит главный `nginx.conf` вовсе (полагается на стоковый —
   см. §9.4 архитектурного документа `nginx_multidomain`).
7. ~~**`roles/nginx/tasks/main.yml:33-38` — задача-«обработчик» на самом деле обычная task**~~ —
   файл удалён вместе с ролью. В `nginx_multidomain` reload реализован корректно как handler с
   fail-fast `nginx -t` (`roles/nginx_multidomain/handlers/main.yml`).
8. ~~**Конфликт ролей `nginx` и `nginx_multidomain` на одном хосте**~~ — снят удалением роли
   `nginx`: конфликтовать больше не с чем. Остаётся риск §9.4 из архитектурного документа
   `nginx_multidomain` (роль полагается на нетронутый стоковый `nginx.conf` с
   `include sites-enabled/*` и не проверяет/не гарантирует это) — это уже не конфликт двух ролей
   коллекции, а внешняя предпосылка, которую стоит явно задокументировать или проверять `assert`'ом.

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

---

## P3 — Мёртвый код и репозиторный мусор

22. ~~**`roles/monitoring_server/templates/__delete/`**~~ — **исправлено удалением**: каталог
    полностью не использовался ни одной задачей (подтверждено grep), `GrafanaDashboard.j2` внутри
    к тому же был синтаксически битый (два ключа `spec:`) — удалён целиком.
23. ~~**Файлы alert-правил с подчёркиванием в имени — повторяющийся паттерн черновиков, не
    единичный случай.**~~ — **исправлено**: все три файла
    (`templates/alert-rules/proxmox-ve/prometheus-pve-exporter_.yml`,
    `templates/alert-rules/redis/oliver006-redis-exporter_.yml`,
    `templates/alert-rules/blackbox/blackbox-exporter_.yml`) удалены — решение владельца
    коллекции: черновики, никогда не подключённые через `vars/main.yml`, не оформлять как
    альтернативу, а убрать как мусор.
24. ~~**`templates/alert-rules/grafana-alloy/embedded-exporter.yml` полностью не подключён**~~ —
    перенесено в «Backlog фич» ниже (не мёртвый код, а незавершённая функциональность — см. п. 34).
25. ~~**Дублированная документация `nginx_multidomain` в двух местах**~~ — `roles/nginx/docs/`
    удалён вместе с ролью `nginx`, дублирования больше нет. **Уборка `roles/nginx_multidomain/docs/`
    тоже сделана**: помимо упомянутых `files.zip`/`nginx_multidomain_role_skeleton.tar.gz`, в
    каталоге обнаружились их же распакованные копии (`main.yml`, `static.conf.j2`,
    `mnt/user-data/outputs/nginx_multidomain/tasks/main.yml` — артефакт неудачной распаковки
    архива в чужой вложенный путь) — черновик первой скелетной генерации роли, разошедшийся с
    актуальной реализацией. Все пять файлов удалены, каталог `docs/` теперь пуст. Заодно исправлена
    ставшая битой после переименования/переноса ссылка на архитектурный документ: он живёт в
    `docs/adr/0003-ginx-multidomain-role.md` в корне коллекции, а не в `roles/nginx_multidomain/docs/`
    (обновлены CLAUDE.md и собственное дерево каталогов внутри самого документа).
26. ~~**Два висячих (никогда не вызываемых) handler'а**~~ — **исправлено**: подтверждено `grep`
    по `notify:` во всех `tasks/systemd-*-exporter.yml`, что `State service node-exporter.socket`/
    `State service nginx-exporter.socket` нигде не notify'ятся (задачи в `systemd-node-exporter.yml`/
    `systemd-nginx-exporter.yml` дублируют их содержимое inline), оба handler'а удалены из
    `roles/monitoring_agent/handlers/main.yml`.
27. ~~**Молёкула-сценарий `reverse_proxy_traefik` фактически не рабочий, а не просто неполный**~~
    — **исправлено удалением**: `extensions/molecule/reverse_proxy_traefik/` был untracked-каркасом
    (`molecule.yml` нулевого размера — не распознаётся molecule как сценарий вообще,
    `converge.yml` не вызывал роль, `test_traefik.py` падал на `NameError` при сборе тестов, плюс
    копипаст-ассерт `"Welcome to nginx"` против приложения `traefik/whoami`). Удаление не убавляет
    покрытия — рабочего сценария и не было. Пересборка с нуля остаётся отдельной P4-задачей (см.
    таблицу P4 ниже).
28. ~~**`roles/nginx/README.md:42-49` отсылает к `extensions/molecule/nginx`, у которого нет
    `molecule.yml`**~~ — оба файла удалены вместе с ролью `nginx`.
29. ~~**`roles/reverse_proxy_traefik/README.md`** — неотредактированная заготовка
    `ansible-galaxy init`~~ — **исправлено**: написан реальный README (назначение роли,
    взаимоисключаемость с `nginx_multidomain`/`reverse_proxy_npm`, обязательная проверка пароля
    дашборда, устройство дашборда/fixture-приложения `whoami`, известные ограничения — TLS не
    автоматизирован).
30. ~~**Мелкие огрехи, не блокирующие, но стоящие отдельного PR:**~~ — **исправлено**:
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

---

## P4 — Тестовое покрытие

| Роль | Что есть сейчас | Чего не хватает |
|---|---|---|
| `monitoring_server` | ~~Нет molecule-сценария вообще~~ — **сделано**: два независимых сценария, `extensions/molecule/monitoring_server/` (`monitoring_server_orchestrator: docker`) и `extensions/molecule/monitoring_server_k3s/` (`monitoring_server_orchestrator: k3s`), оба `driver: vagrant`/`libvirt` (см. CLAUDE.md, раздел «Molecule-тесты»). docker-сценарий — full-стек (VM + Grafana + Loki + MinIO), verify проверяет реальный scrape node-exporter. k3s-сценарий крупнее (k3s + VictoriaMetrics Operator + grafana-operator + grafana-alloy через реальный `Helmwave up`) и без idempotence в `test_sequence` (`Helmwave up` — `ansible.builtin.command` без `changed_when`-анализа, всегда `changed=true`). | `meta/main.yml` для роли по-прежнему отсутствует. Idempotence для k3s-сценария не достижима без переписывания задачи `Helmwave up` на `changed_when`-анализ stdout `helmwave` — отдельная задача. |
| `monitoring_agent` | `tests/test.yml` — аналогично, все экспортеры выключены по умолчанию, ничего не проверяет. Нет molecule-сценария. | Molecule-сценарий, включающий хотя бы по одному экспортеру на docker- и systemd-путях, plus pve-exporter под обоими оркестраторами (поймал бы №9, №10). |
| `infra_dns` | ~~Только ручной `tests/deploy_infra_dns.yml`~~ — **сделано**: `extensions/molecule/infra_dns/` (docker driver, одноразовый systemd-контейнер geerlingguy/docker-debian12-ansible, без docker-in-docker — bind9 обычный systemd-сервис). Converge покрывает forward-зону (дефолтный `soa_contact`, `include_hosts: true`) и reverse-зону (явный `soa_contact`, `include_hosts: false`). Verify гоняет реальный `named-checkconf` на полном `/etc/bind/named.conf` + `named-checkzone` на обоих зона-файлах (ловит P2-19/P2-20), права `bind:bind`/`0640`, наличие/отсутствие `$INCLUDE`-файла и функциональные `dig`-запросы (A, CNAME, `-x`/PTR) через реально поднятый `named`. Прогон зелёный, включая `idempotence` (0 изменений на повторном converge) — багов не найдено. | `meta/main.yml` для роли по-прежнему отсутствует. Негативный путь (reverse-зона без `soa_contact` → `assert`-fail, P2-20) сценарий не проверяет — только структурно валидные зоны. |
| `nginx_multidomain` | ~~Роль `nginx` удалена (п.31)~~ — **сделано**: `extensions/molecule/nginx_multidomain/` (docker driver, одноразовый systemd-контейнер geerlingguy/docker-debian12-ansible). Converge покрывает `type: static` и `type: proxy` (upstream-пул, `extra_upstreams`, custom-сертификаты, rate-limit/proxy-cache зоны, `conf_d_files`, `stub_status`, `enabled: false`). Verify гоняет реальный `nginx -t` + ansible-проверки (сервис running, symlink'и, дедуп зон, регрессия §9.1, функциональные `uri`-запросы на override-location и 502 от недоступного backend'а). `basic_auth`/`json`-логи (§8.3/8.4/9.3) намеренно не включены в сценарий — они по-прежнему ломают `nginx -t`, это осознанно задокументированный пробел, а не забытый. Первый же прогон сценария поймал реальный, ранее не описанный баг: `proxy_cache_zones.yml` не создавал `zone.path` (`nginx -t` падал на `mkdir()` для любого использования `nginx_proxy_cache_zones`) — исправлено в том же PR, см. архитектурный документ роли, раздел 6. | `meta/main.yml` для роли по-прежнему отсутствует (см. §8.5 документа). Когда баги §9.3 (basic_auth/json-логи) будут починены — добавить в сценарий домен, покрывающий оба случая, вместо текущего осознанного исключения. |
| `reverse_proxy_traefik` | ~~Нет molecule-сценария вообще~~ — **сделано**: `extensions/molecule/reverse_proxy_traefik/` (docker driver, одноразовый systemd-контейнер geerlingguy/docker-debian12-ansible, та же структура, что `nginx_multidomain`/`reverse_proxy_npm`). Converge реально вызывает роль (`import_role`); в отличие от удалённого нерабочего каркаса (см. P3 №27), fixture-приложение (`traefik/whoami`) не поднимается отдельно — оно уже часть compose-файла роли. Verify проверяет HTTP→HTTPS редирект, реальный ответ `whoami` через Traefik (вместо скопипащенного и никогда не совпадающего ассерта `"Welcome to nginx"` из старого каркаса) и basic-auth дашборда (401 без credentials, 200 с ними). | — |

---

## P5 — Архитектурные развилки (требуют решения, не только патча)

31. ~~**Судьба роли `nginx` vs `nginx_multidomain`**~~ — **решено и выполнено**: роль `nginx`
    была экспериментом и удалена из коллекции полностью
    (`roles/nginx/`, `extensions/molecule/nginx/`, `tests/deploy_nginx_sites.yml`,
    `tests/deploy_nginx_sites_test.yml`). `nginx_multidomain` — единственная и окончательная
    nginx-роль коллекции; конфликт №8 и находки №6/№7/№21/№25/№27(nginx-часть)/№28/№30(nginx-часть)
    сняты вместе с удалением. CLAUDE.md обновлён, чтобы не упоминать `nginx` как отдельную роль.
    Оставшийся риск — §9.4 архитектурного документа `nginx_multidomain` (роль полагается на
    нетронутый стоковый `nginx.conf` с `include sites-enabled/*` и не проверяет это) — уже не
    межролевой конфликт, а внешняя предпосылка для деплоя.
32. ~~`nginx_multidomain` уже разошлась с собственным архитектурным документом~~ — **решено и
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
    коде), затем архитектурное решение по конфликту с `roles/nginx` (P5-31), и только потом —
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
33. ~~**Механизм `alert_rules_src`/VMAlert для docker-оркестратора monitoring_server отсутствует
    как класс.**~~ — **решено**: выбран вариант «документировать как k3s-only» вместо реализации
    `vmalert` в docker-compose (это осталась отдельная задача архитектурного уровня, при желании
    заводится отдельным пунктом бэклога). Реализация решения — см. P0-1 выше: дефолты алертов
    гейтятся по оркестратору, добавлен fail-fast на явное включение под docker.
35. **Нужен ли `monitoring_server_grafana_loki_enabled` для k3s-оркестратора — отложено (Loki под
    k3s теперь реализован, 2026-07-14).** Grafana Loki под `monitoring_server_orchestrator: k3s`
    реализован — новый Helm-релиз `loki` (`grafana/loki` 6.54.0, SingleBinary + бандлованный
    MinIO-сабчарт) в `helm/envs/k3s-monitoring.yaml`, ставится через уже существующий
    `Helmwave up`, без правок кода роли (см. `docs/adr/0007-monitoring-server-role.md` §6/§11 —
    там же два побочных фикса схемы helmwave, найденных при реализации: `depends_on` не
    пробрасывался из `.tpl`, и ownership-конфликт `GrafanaDatasource loki` с уже существующим
    ресурсом в `grafana-operator/values.yaml`). Сам вопрос из заголовка пункта остаётся
    **открытым**: сознательно решено **не** прокидывать `monitoring_server_grafana_loki_enabled`
    (сейчас docker-only переменная) в `monitoring_server_helmwave_tags` — под k3s включение/
    выключение Loki определяется только присутствием release в пользовательском
    `envs/<cluster>.yaml` (та же логика, что уже у `grafana-alloy*`), а не ansible-переменной роли.
    Причина отказа: `helmwave` фильтрует релизы только по inclusion-тегам (нет exclusion), поэтому
    исключить один релиз, ничего не зная про остальные в файле пользователя, роль не может, не
    сделав предположений о его структуре — architecturally роль не должна знать содержимое
    `helm/`. Вернуться к вопросу, если реальная потребность появится — оценить, стоит ли всё-таки
    завести единый флаг (например, через `monitoring_server_helmwave_tags` по умолчанию
    вычисляемый из `monitoring_server_grafana_loki_enabled` + явный список остальных релизов) или
    оставить как есть.

---

## Backlog фич (незавершённая функциональность, не баги и не мусор)

Пункты этого раздела — не находки код-ревью, а самостоятельные задачи «добавить функциональность
по образцу уже существующей». Вынесены отдельно от P0-P5, чтобы не смешивать их с багами/мусором:
здесь нечего чинить, нужно реализовать с нуля по существующему шаблону.

34. **Подключить экспортер `grafana-alloy` (embedded-exporter) в monitoring_server/monitoring_agent.**
    Шаблон алертов уже есть — `roles/monitoring_server/templates/alert-rules/grafana-alloy/embedded-exporter.yml`
    (перенесено из P3-24, где было ошибочно классифицировано как мёртвый код). Нужно пройти
    стандартный 4-шаговый процесс подключения экспортера, описанный в CLAUDE.md/AGENTS.md:
    1. alert-правила — уже есть, шаг сделан.
    2. серверные переменные по умолчанию в `roles/monitoring_server/defaults/main.yml`:
       `monitoring_server_victoria_metrics_scrape_alloy`,
       `..._scrape_alloy_port_default`, `..._alerts_rules_alloy_default`.
    3. переменные агента в `roles/monitoring_agent/defaults/main.yml`:
       `monitoring_agent_alloy_enabled`, `_image_registry`, `_image_repository`, `_image_version`,
       `_image`, `_port`, `_systemd_name`, `_binary_download_url`, `_binary_install_path`
       (+ `_binary_checksum`, см. P1-13 — паттерн checksum теперь обязателен для новых экспортеров).
    4. регистрация в массиве `monitoring_server_victoria_metrics_exporters`
       (`roles/monitoring_server/vars/main.yml`): `name`, `scrape_src`, `scrape_dest`,
       `scrape_state`, `alert_rules_default_enabled`, `alert_rules_src`.

---

## Предлагаемая последовательность работ

1. ~~**Решить архитектурную развилку nginx/nginx_multidomain (P5, №31)**~~ — сделано: роль
   `nginx` удалена, `nginx_multidomain` — единственный путь вперёд.
2. ~~**Быстрые критические фиксы (P0), без архитектурных решений** — пункты 9, 10 (monitoring_agent)
   чинятся точечными однострочными правками~~ — **сделано**: №9 (Jinja-скобки в пути к
   `daemon.json`) и №10 (fail-fast для `pve_exporter` под docker-оркестратором) исправлены.
   Из P5-32 (§9 документа `nginx_multidomain`) баги 9.1–9.3 (утечка `set_fact`, асимметричная
   валидация `root`, `basic_auth`/`json`-логи, ломающие `nginx -t`) — **тоже сделано**, см. P5-32
   выше и `extensions/molecule/nginx_multidomain/` (verify зелёный).
3. ~~**Security-патч секретов (P1, пункт 11)** — механическая правка `mode:`/`no_log:` по списку
   файлов, отдельный PR.~~ — **сделано**: заодно закрыт весь раздел P1 целиком (пункты 12-14 —
   assert на дефолтные S3-credentials, checksum для бинарников экспортеров, requirements.yml для
   `xanmanning.k3s`), см. раздел P1 выше.
4. **monitoring_server P0 №1-5** — требуют решения по P5 №33 (поддерживать ли алертинг в docker
   вообще) перед тем как чинить scrape-конфиги и dashboard provisioning.
5. **Тестовое покрытие (P4)** — начиная с `nginx_multidomain` (самый дешёвый сценарий: реальный
   `nginx -t` в verify сразу ловит находки §9 её архитектурного документа) — ~~сделано~~:
   `extensions/molecule/nginx_multidomain/` (docker driver), см. таблицу P4 выше; попутно нашёл
   и исправил баг с недостающим `mkdir` для `nginx_proxy_cache_zones`. Баги §9.1–9.3 (пункт 2
   выше) с тех пор **тоже почищены** — set_fact-утечка и асимметричная валидация `root` исправлены
   в коде, `basic_auth`/`json`-логи теперь дают явный `assert`-fail вместо молчаливой поломки
   `nginx -t` (сама функциональность по-прежнему не реализована — это отдельная задача §8).
   `monitoring_server` (самый рискованный по числу найденных P0) — ~~сделано~~: два сценария,
   `docker` и `k3s` (#40), см. таблицу P4 выше. `reverse_proxy_traefik` (сборка с нуля) — тоже
   ~~сделано~~ (#41). `infra_dns` — тоже ~~сделано~~, см. таблицу P4 выше. Остаётся:
   `monitoring_agent`.
6. **Чистка мусора (P3)** — низкий риск, можно делать параллельно отдельными мелкими PR в любой
   момент. Основной объём (роль `nginx` и её дубликаты документации/scratch-тестов) уже снят
   вместе с решением P5-31.
