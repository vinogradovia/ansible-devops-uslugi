# Примеры плейбуков-оркестраторов

Иллюстративные плейбуки верхнего уровня — коллекция сама их не устанавливает и не запускает
(это не `playbooks/` в смысле точки входа коллекции, а просто примеры для копирования в
inventory-репозиторий оператора). Перед боевым использованием адаптируйте под свой inventory —
адреса, `node_id`, состав read-реплики, реальные значения секретов.

- `postgresql-replicas.yml` — оркестратор роли `devops.uslugi.postgresql_replication`
  (`roles/postgresql_replication/README.md`).
- `odyssey.yml` — оркестратор роли `devops.uslugi.odyssey` (`roles/odyssey/README.md`),
  запускать после `postgresql-replicas.yml`.

Оба файла закрывают условные имена, на которые ссылается
[`docs/runbooks/postgresql-failover.md`](../../docs/runbooks/postgresql-failover.md)
(разделы 2–3) — конкретные команды `ansible-playbook ... --tags ... --limit ...` из этой
инструкции рассчитаны именно на структуру плеев из этих примеров (обязательный порядок
`postgresql_primary` → реплики, см. комментарий в начале `postgresql-replicas.yml`).

Требуемые секреты и переменные без дефолтов — см. комментарии в начале каждого файла и разделы
«Секреты» соответствующих `roles/*/README.md` (Ansible Vault на уровне `group_vars`, ADR-0005 §9).
