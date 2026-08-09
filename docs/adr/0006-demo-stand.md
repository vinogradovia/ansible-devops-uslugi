# ADR-0006: Демо-стенд коллекции (Terraform + libvirt), первый кейс «Observability + MySQL HA»

- **Статус:** Принято
- **Дата:** 2026-07-12
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

Нужен стенд, показывающий возможности коллекции «в сборе» — не изолированный прогон одной роли
(как это делает `molecule`), а связный сценарий из нескольких ролей, применённых вместе, как это
происходило бы у реального клиента. По итогам обсуждения назначение стенда двойное: он подаётся
как демо, но фактически будет использоваться в первую очередь как **ручной регрессионный стенд**
для проверки изменений в коллекции целиком — постоянно поднятый (long-lived), а не
создаваемый/сносимый на каждый прогон, как молекула.

Существующий прецедент для многоузловых сценариев — `extensions/molecule/mysql_replication/`
(vagrant/libvirt, driver для `molecule test`, ADR-0004 §10) — не подходит по модели жизненного
цикла: molecule принципиально ephemeral (`create` → `verify` → `destroy` в рамках одного тестового
прогона), а этому стенду нужно жить постоянно между прогонами `ansible-playbook`.

Первый конкретный кейс (по итогам обсуждения) — **Observability (метрики + логи) + MySQL HA**:
демонстрирует `monitoring_server`/`monitoring_agent` (включая недавно обнаруженный, но пока нигде
не задействованный в тестах стек логов — Grafana Loki + Promtail, см. ниже) и полную топологию
`mysql_replication`+`proxysql`+`infra_dns` из ADR-0004.

**Важный факт, обнаруженный в процессе (влияет на §5):** Loki в `monitoring_server` (docker-режим)
уже реализован (`monitoring_server_grafana_loki_enabled`, `roles/monitoring_server/templates/
loki-config.yaml.j2`), но `check-and-install-requirements.docker.yml` жёстко требует
`monitoring_server_local_storage_s3_enabled: true` — конфиг Loki хардкодит `object_store: s3`,
без альтернативы на локальную ФС. Роль сама умеет поднять локальный MinIO
(`monitoring_server_local_storage_s3_*`, образ `minio/minio`) — внешний S3 для демо не нужен,
но включать Loki без включения local-storage-S3 нельзя.

## Решения

### 1. Инструмент provisioning — Terraform + libvirt-провайдер, не Vagrant и не голый virt-install

**Решение:** виртуальные машины стенда поднимаются через Terraform
(`dmacvicar/terraform-provider-libvirt`), а не через `Vagrant` (как в `extensions/molecule/
mysql_replication/`, ADR-0004 §10) и не через голые `virt-install`/скрипты.

**Обоснование:** Vagrant концептуально — инструмент для эфемерных dev-окружений (create/destroy
за один вызов), что противоречит требованию «постоянно поднятый стенд» (см. «Контекст»). Terraform
рассчитан на управление персистентной инфраструктурой и имеет провайдеры не только для `libvirt`,
но и для Proxmox, и для Yandex Cloud — при смене платформы в будущем меняется только
provider-блок и описание ресурсов ВМ, а слой «Terraform → сгенерированный Ansible-inventory →
`ansible-playbook`» остаётся тем же. Голые `virt-install`-скрипты дали бы минимум зависимостей, но
не переносились бы на другую платформу вообще — при смене платформы пришлось бы переписывать всё
с нуля.

### 2. Сеть — одна плоская сеть, без имитации двух ДЦ

**Решение:** все VM стенда — в одной libvirt-сети (NAT), включая `mysql_dr_replica`. Второй
изолированный сегмент с WireGuard/IPsec-туннелем между ними (что было бы более точной имитацией
реальной топологии ADR-0004 §5) — не делается.

**Обоснование:** предпосылка ADR-0004 §5 («межДЦ-трафик идёт через приватную сеть, которая уже
существует») в рамках одной плоской libvirt-сети выполняется тривиально — весь стенд и есть эта
приватная сеть. Усложнение до двух сегментов с туннелем не даёт для целей стенда (регрессионная
проверка ролей + демонстрация) дополнительной ценности, пропорциональной сложности настройки.

### 3. Расположение в репозитории — новая директория `demo/`, не `extensions/`

**Решение:** файлы стенда — в новой директории `demo/<кейс>/` в корне репозитория
(`demo/mysql-ha-platform/{terraform,ansible}`), не внутри `extensions/` (где сейчас только
`molecule/`).

**Обоснование:** это не Ansible-контент коллекции и не molecule-тест, а отдельный
provisioning-слой (Terraform) поверх коллекции — концептуально отличается от того, что сейчас
живёт в `extensions/`. Отдельная директория верхнего уровня делает границу явной: `demo/` не
влияет на `ansible-lint`/`galaxy.yml`/структуру самой коллекции.

### 4. Топология первого кейса — 7 VM

**Решение:**

| VM | Роль(и) коллекции | Оркестратор/режим |
|---|---|---|
| `monitoring-server` | `monitoring_server` | `docker` (нужен для Loki+MinIO, см. «Контекст») |
| `mysql-primary` | `mysql_replication` (`role: primary`) + `monitoring_agent` | экспортёры/promtail — `systemd` |
| `mysql-read-replica` | `mysql_replication` (`role: read_replica`) + `monitoring_agent` | `systemd` |
| `mysql-dr-replica` | `mysql_replication` (`role: dr_replica`) + `monitoring_agent` | `systemd` |
| `proxysql` | `proxysql` + `monitoring_agent` | `systemd` |
| `infra-dns` | `infra_dns` | — |
| `load-generator` | нет роли коллекции (см. §8) | — |

`monitoring_agent` — везде в **systemd**-режиме (не docker), т.к. на самих VM с базами/ProxySQL
не нужна ещё одна docker-зависимость ради пары экспортёров — совпадает с духом решения
ADR-0004 §11 (роли применяются композицией, без лишних зависимостей).

`infra_dns` заводит записи `db-write.<zone>`/`db-read.<zone>` → `proxysql`, по схеме
ADR-0004 §6, без доработок (`record.ttl` уже реализован).

### 5. Loki/логи — включены, с локальным MinIO

**Решение:** на `monitoring-server` включены и `monitoring_server_grafana_loki_enabled: true`, и
`monitoring_server_local_storage_s3_enabled: true` (см. «Контекст» — второе обязательно для
первого). Все хосты с `monitoring_agent` получают Promtail, отправляющий системные и
MySQL/ProxySQL-логи в Loki — стенд демонстрирует не только метрики, но и логи в одном Grafana.

### 6. Передача от Terraform к Ansible — сгенерированный inventory-файл, ручной запуск playbook'а

**Решение:** Terraform (ресурс `local_file`) генерирует Ansible-inventory
(`demo/mysql-ha-platform/ansible/inventory.yml`) с реальными IP-адресами поднятых VM после
`terraform apply`. Оператор вручную запускает
`ansible-playbook -i demo/mysql-ha-platform/ansible/inventory.yml
demo/mysql-ha-platform/ansible/site.yml` — без автоматического триггера (CI/по расписанию),
по итогам обсуждения использование стенда для тестирования — ручное, по мере необходимости.

Ansible-часть переиспользует паттерн `tests/ansible.cfg` (`roles_path`, не FQCN коллекции) —
`demo/mysql-ha-platform/ansible/ansible.cfg` с `roles_path = ../../../roles`.

### 7. Базовый образ и sizing VM — под среднее рабочее место

> **Обновление:** базовый образ для всех `demo/*`-стендов сменён с Debian 12 (bookworm) на
> Ubuntu 24.04 (noble) server cloud image — впервые применено в `demo/samba-server`
> (единственный на тот момент осознанный отход от решения ниже), затем распространено на
> остальные стенды. Причина: все `extensions/molecule/*`-сценарии коллекции стандартизированы на
> box `cloud-image/ubuntu-24.04` (см. `CLAUDE.md`, «Molecule-тесты») — один и тот же дистрибутив
> в molecule и в demo убирает целый класс «работает в тесте, но не в демо» расхождений
> (различия в версиях пакетов/systemd-юнитов между Debian и Ubuntu). Решение и обоснование ниже
> (Debian 12, scope ADR-0002 §4) исторические — оставлены для контекста, актуальный
> `base_image_url` — `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`.

**Решение (историческое, см. «Обновление» выше):** базовый образ — официальный Debian 12
(bookworm) generic cloud image (`qcow2`, cloud-init), совпадает со scope коллекции
(Debian/Ubuntu, ADR-0002 §4). Один раз скачивается и переиспользуется как backing-том для всех VM
(`libvirt_volume` с `base_volume_id` в Terraform — copy-on-write, не полная копия на каждую VM).

Ресурсы рассчитаны на «среднее рабочее место» (8–16 ядер, 16–32 ГБ RAM), а не «хватает с
запасом» — VM намеренно compact:

- `monitoring-server`: 2 vCPU / 3 ГБ RAM (VictoriaMetrics + Grafana + VMAlert + Loki + MinIO —
  самая тяжёлая VM стенда)
- `mysql-primary` / `mysql-read-replica` / `mysql-dr-replica`: 1 vCPU / 1.5 ГБ RAM каждая
- `proxysql`: 1 vCPU / 512 МБ
- `infra-dns`: 1 vCPU / 512 МБ
- `load-generator`: 1 vCPU / 512 МБ

Суммарно ориентировочно 8 vCPU / ~9 ГБ RAM — укладывается в «среднее рабочее место» с запасом на
хост-систему.

### 8. Генератор нагрузки — ad hoc, не новая роль коллекции

**Решение:** `load-generator` — отдельная VM с простым инструментом (`sysbench oltp_read_write`
либо cron/systemd-timer скрипт с периодическими `INSERT`/`SELECT`), направленным на
`db-write`/`db-read` через ProxySQL, чтобы на Grafana были живые QPS, replication lag, число
подключений. Реализуется как ad hoc Ansible-таски внутри `demo/mysql-ha-platform/ansible/`
(например, `roles/load_generator/` **локально в демо-каталоге**, не в `roles/` коллекции) — это
демо-инструмент, а не переиспользуемая production-возможность коллекции.

### 9. Секреты — упрощённо, без Ansible Vault

**Решение:** в отличие от production-паттерна (ADR-0004 §9, ADR-0001 §5 — обязательный Vault,
fail-fast `assert` без дефолтов), пароли в демо-стенде задаются напрямую в
`demo/mysql-ha-platform/ansible/group_vars/all.yml` открытым текстом, с явным комментарием
в файле, что это демо-стенд в изолированной локальной libvirt-сети без выхода наружу.

**Обоснование:** это осознанное упрощение ради простоты воспроизведения стенда (`git clone` →
`terraform apply` → `ansible-playbook` без шага «создать/расшифровать vault-файл»), оправданное
тем, что стенд не подключён к внешней сети и не хранит реальные данные. **Не переносить этот
паттерн на роли коллекции** — там (`mysql_replication`, `proxysql`, будущий
`postgresql_replication`/`odyssey`) требование обязательного Vault остаётся в силе.

## Открытые вопросы / вне скоупа

- Автоматизация прогона (CI/по расписанию) — не делается сейчас, использование стенда ручное.
  Пересмотреть, если появится потребность в регулярной автоматической регрессии.
- Имитация двух ДЦ с реальным туннелем (§2) — не делается для этого кейса; если понадобится
  явно демонстрировать сценарий promote/DR через реальный туннель, потребует отдельного решения.
- Другие кейсы (`nginx_multidomain`, `reverse_proxy_traefik`/`npm`, будущий
  `postgresql_replication`+`odyssey` из ADR-0005) — не спроектированы, ожидаются как отдельные
  `demo/<кейс>/` в будущем, по мере готовности.
- Упрощённая схема секретов (§9) — специфична для демо-стенда, не должна использоваться как
  прецедент для production-ролей коллекции.
- Точный размер VM (§7) — ориентировочный, может потребовать корректировки по факту первого
  реального прогона (особенно `monitoring-server` при включённом Loki+MinIO).

## Ссылки

- `docs/adr/0004-mysql-ha-replication-role.md` — топология `mysql_replication`+`proxysql` (§3–4
  этого ADR), схема `db-write`/`db-read` → ProxySQL (§6, переиспользована без изменений),
  предпосылка про приватную сеть между ДЦ (§5, тривиально выполняется в §2 этого ADR).
- `docs/adr/0002-docker-role.md`, §4 — scope Debian/Ubuntu (переиспользован в §7).
- `extensions/molecule/mysql_replication/` — существующий vagrant/libvirt прецедент для
  многоузловых сценариев; отличие в модели жизненного цикла разобрано в «Контексте» и §1.
- `roles/monitoring_server/tasks/check-and-install-requirements.docker.yml` — жёсткая
  зависимость Loki от `local_storage_s3_enabled`, обнаружено в процессе обсуждения (§5).
- `tests/ansible.cfg` — паттерн `roles_path` вместо FQCN коллекции, переиспользован в §6.
