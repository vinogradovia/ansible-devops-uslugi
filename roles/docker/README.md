# docker

Устанавливает и настраивает Docker Engine + `docker-compose-plugin` из официального репозитория
`download.docker.com` (Debian/Ubuntu, apt). Проектное решение и обоснование — см.
[`docs/adr/0002-docker-role.md`](../../docs/adr/0002-docker-role.md).

## Назначение

Переиспользуемый инфраструктурный примитив (в отличие от доменных ролей коллекции). Не
разворачивает прикладные контейнеры — только сам Docker Engine. Подключается **зависимостью
через `meta/main.yml`** у ролей-потребителей (`monitoring_server`, `monitoring_agent`,
`reverse_proxy_traefik`), а не вызывается напрямую из плейбуков (ADR §2, §9).

## Поддержка ОС

Только Debian/Ubuntu (apt) — см. ADR §4.

## Владение `/etc/docker/daemon.json`

Роль — единственный владелец этого файла: рендерит его целиком из `docker_daemon_json_options`
(dict). Роли-потребители **не должны** писать в файл напрямую — они передают свои ключи через vars
зависимости в своём `meta/main.yml`, например:

```yaml
dependencies:
  - role: docker
    when: monitoring_agent_orchestrator == 'docker'
    vars:
      docker_daemon_json_options: "{{ monitoring_agent_docker_daemon_json_options }}"
```

## Версионирование

`docker_ce_version` / `docker_compose_plugin_version` пинуются явно (без `latest`, ADR §5). При
обновлении версии проверить доступность пакета для целевого дистрибутива/релиза:

```bash
apt-cache madison docker-ce
```

## Доступ без root

`docker_users: []` — список пользователей, добавляемых в группу `docker` (ADR §7). По умолчанию
пусто.

## Пример

```yaml
- hosts: docker_hosts
  roles:
    - role: devops.uslugi.docker
      docker_ce_version: "27.5.1"
      docker_users:
        - deploy
```

## Вне скоупа

- RHEL/Rocky (dnf) — не поддерживается.
- Rootless Docker.
- Взаимодействие Docker с iptables/nftables хоста.

См. «Открытые вопросы / вне скоупа» в ADR.
