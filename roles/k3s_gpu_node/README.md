# k3s_gpu_node

Готовит GPU-хост к тому, чтобы стать узлом k3s: NVIDIA driver + `nvidia-container-toolkit` +
gVisor (`runsc`), в этом порядке, **до** установки/первого старта k3s на этом же хосте.
Проектное решение и обоснование — см.
[`docs/adr/0015-ai-agent-platform-architecture.md`](../../docs/adr/0015-ai-agent-platform-architecture.md)
§9/§10 и [`docs/Requirements Specification/agent-stack-k3s.md`](../../docs/Requirements%20Specification/agent-stack-k3s.md).

## Назначение и границы

Роль покрывает только подготовку **хоста**. Присоединение к существующему k3s-кластеру
(`xanmanning.k3s`, agent mode) и кластерные объекты (`RuntimeClass`, `nvidia-device-plugin`
DaemonSet, каркас namespace, `NetworkPolicy`) — вне этой роли, задачи оркестрации в `site.yml`
конкретного окружения (по аналогии с тем, как `freeipa`/LDAP bind-аккаунт разделены между ролью
и `site.yml`, ADR-0013 §2).

## Порядок, почему он фиксирован

k3s сканирует `PATH` на исполняемые файлы NVIDIA-рантайма **в момент собственного старта** и
добавляет соответствующий рантайм в свой конфиг containerd автоматически. Если toolkit ставится
после того, как k3s уже стартовал хотя бы раз, рантайм не подхватывается — единственное лечение —
рестарт k3s, диагностируется небыстро (см. ADR-0015 §9/§8-«грабли» agent-stack-k3s.md). gVisor так
не подхватывается вообще — его обработчик дописывается явно в `config.toml.tmpl`, который k3s
использует только при генерации своего конфига на первом старте, поэтому шаблон должен лежать на
диске раньше, чем на этом хосте первый раз запустится сервис k3s.

## Поддержка ОС

Только Ubuntu (apt) — GPU-хосты платформы на данный момент только Ubuntu cloud-init образы.

## Версионирование

В отличие от `roles/docker` (`docker_ce_version` пинуется явно, ADR-0002 §5) — NVIDIA driver
(`ubuntu-drivers autoinstall`), `nvidia-container-toolkit` и `runsc` версии явно не пинуются:
апстрим-репозитории (NVIDIA, gVisor) сами не хранят старые версии, а версия проприетарного
драйвера должна соответствовать конкретной модели карты — единого правильного номера для всей
коллекции нет. Явный пин драйвера — через override `k3s_gpu_node_nvidia_driver_package`.

## Не проверено реальным прогоном

Путь плагина containerd в `templates/containerd-config.toml.tmpl.j2`
(`io.containerd.grpc.v1.cri`) соответствует containerd v1 CRI-плагину — начиная с containerd v2
путь меняется на `io.containerd.cri.v1.runtime`. Версия containerd, которую реально встраивает
закреплённый в site.yml k3s (`v1.35.1+k3s1`), не проверена вживую на GPU-хосте — см. комментарий
в самом шаблоне для команды проверки перед первым реальным прогоном.
