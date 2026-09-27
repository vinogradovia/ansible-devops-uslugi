# Глоссарий и карта папок ADR

Термины — как в решениях control-plane (0014–0015, 0028). Это не каталог ролей и не
словарь Selectel. Номер ADR в скобках — где термин задан.

## Зачем какая папка

Дерево режет **контур решения**, не номер документа. Номер остаётся в имени файла.

| Папка | Для чего | Что класть | Что не класть |
|---|---|---|---|
| `01-overview/` | вход в серию: этот файл, позже оглавление | карта, глоссарий | сами ADR |
| `02-control-plane/` | ядро платформы: как решаем, применяем, учитываем, пускаем людей и агентов | см. подпапки | роли коллекции «как поставить nginx» |
| `…/apply/` | материализация уже описанного | [0014](../02-control-plane/apply/0014-platform-controller-architecture.md) Module → Semaphore | учёт железа, чат агента |
| `…/fund/` | книга ёмкости: что купили / свои ноды | [0014.1](../02-control-plane/fund/0014.1-platform-resource-controller.md), [0014.1.1](../02-control-plane/fund/0014.1.1-resource-onboarding-protocol.md) | Estate клиента, VLAN |
| `…/admin/` | админка оператора: фонд, провайдеры, меню LK | [0015.2](../02-control-plane/admin/0015.2-admin-panel.md), [0015.2.1](../02-control-plane/admin/0015.2.1-admin-panel-architecture.md) | кабинет клиента |
| `…/agents/` | агентная платформа и infra-агент | [0015](../02-control-plane/agents/0015-ai-agent-platform-architecture.md), [0015.1](../02-control-plane/agents/0015.1-infra-agent.md), [0015.3](../02-control-plane/agents/0015.3-contracts.md), [0021](../02-control-plane/agents/0021-agent-platform-model-selection.md), [0026](../02-control-plane/agents/0026-qdrant-vector-db-for-rag.md), [0027](../02-control-plane/agents/0027-temporal-orchestrator.md) | роли мониторинга |
| `…/network/` | сеть тенанта и край платформы | [0028](../02-control-plane/network/0028-platform-network.md) | mgmt-only допуск ноды (это fund / 0014.1.1) |
| `…/identity/` | кто человек и как входит | [0013](../02-control-plane/identity/0013-unified-auth-architecture.md), [0019](../02-control-plane/identity/0019-platform-rbac-model.md), [0020](../02-control-plane/identity/0020-kube-apiserver-oidc.md) | OpenBao (секреты, не люди) |
| `…/platform/` | обвязка самой платформы: CI, прокси, секреты, docs, онбординг репо | 0012, [0016](../02-control-plane/platform/0016-openbao-secrets-pki.md), 0017, 0018, 0022–[0025](../02-control-plane/platform/0025-client-onboarding-architecture.md) | нагрузка тенанта у провайдера |
| `03-data-plane/` | как живёт нагрузка клиента у облака (VLAN/VM/k8s) | пока пусто; появятся ADR про срез тенанта | генератор клиентского git (0025 — platform) |
| `04-roles/` | ADR **ролей** коллекции (`roles/*`) | 0001–0005, 0007–0011 | архитектура OIDC/OpenBao |
| `stands/` | принятые стенды, не прод-ядро | [0006](../stands/0006-demo-stand.md) | снятые решения (для них — `deprecated/`, когда появится) |

`0025` лежит в `platform/`: документ про то, **как платформа порождает** репо клиента, не про
сеть VM у Selectel.

## Плоскости

**Control plane платформы.** Наше ядро: контроллер, админка, агенты, edge, секреты. На железе
платформы живёт только это (`allocation: system`). Не CP Kubernetes клиента.

**Data plane тенанта.** VM, диски, k8s, VLAN у облачного провайдера. East-west там, не через
наш edge.

**Четыре канала сети** (0028): **mgmt** (PVE/API/SSH), **data** (ProjectNet), **agents**
(hop на Run), **published** (точечный выход на git/DNS проекта). Не одна шина.

## Кто и где живёт

**Project.** Контур одного заказчика в LK. Один Project — один `provider_id`. Мультиклауда нет
(0015.1). Карточка (0015.3 §6) — SoT этапа; то же зеркало в админке, без секретов.

**Оболочка Project (этап 1).** При регистрации: карточка + ProjectNet/`vlan_id` + орг Gitea
(`app` + пустой `infra`). Init кабинета и код — этап 2, не здесь (0015.1 §1.1).

**LK.** Кабинет владельца Project. Раздел «Инфраструктура» — меню и чат infra-агента. Не
админка, не Semaphore, не Open WebUI.

**Platform admin.** Кабинет оператора: фонд, провайдеры, `offered`, люди `platform-*`. Не
создаёт Estate клиента.

**Заказчик / клиент.** Владелец Project. Не видит `:8006`, Semaphore, ключ кабинета
провайдера (если `partner`), соседа на той же ноде.

**`provider_id`.** Какой облачный кабинет у этого Project: `selectel` **или** `yandex`, не оба.

**`procurement`.** Как появился доступ к площадке: `platform_metal` (наше железо — только
ядро), `partner` (наш платный кабинет, клиенту ЛК провайдера нет), `byo` (кабинет или стойка
клиента).

**`owner`.** Кто владеет площадкой или ресурсом: `platform` | `client`. Не выводится из
hostname.

**`connect`.** Как control plane дотягивается: `api` (HTTPS на кабинет), `local` (уже есть
L3), `overlay` (туннель, часто после bootstrap dedicated).

**P1–P15.** Каталог этажей размещения (0015.1 §9). P1 — облако → dedicated → Proxmox.
Доступ к кабинету ≠ «создаём IaaS VM».

## Фонд и пул клиента

**Фонд.** Книга ёмкости в `platform-api`: купленное и свои ноды. Не «пул этого клиента».

**`allocation`.** Метка строки фонда: `unassigned` | `system` | `user`. Клиентский Project —
только `user`. Ядро — только `system`.

**`offered`.** Виден ли `user`-ресурс в LK. `system` в кабинет клиента не публикуем.

**`ExternalResource` / `InternalResource`.** Купили у провайдера / своя нода (0014.1). Метку
`allocation` пишет оператор, не контроллер учёта.

**`CloudAccount`.** Подключение платёжного кабинета провайдера (IAM, возможности, list/order
dedicated). Не нода и не строка фонда. `owner: platform` — админка; `owner: client` — LK.
У Selectel имя сервисного пользователя ≠ имя их проекта; list ящиков — обычно
project-scope. Спека — 0015.2 §7.1.

**`ProviderAccount`.** Наш счёт и квоты **кабинета** у Selectel/Yandex. Не потолок тенанта.
Деньги; подключение — `CloudAccount`.

**`ProjectQuota`.** Потолок потребления **этого** Project (у нас). Не PVE Resource Pool и не
квота Selectel.

**Срез / пул клиента.** Offered-площадка одного провайдера + свой VLAN/ProjectNet + то, что в
**Estate**, в рамках квоты. Не папка в Proxmox.

**PVE Resource Pool.** Группировка VM + ACL. Нет квоты CPU/RAM и нет своей сети. Не механизм
изоляции (0028 §8.1).

## Сеть

**ProjectNet.** Синтетический CIDR + VRF проекта. Выдаёт allocator при создании Project.
East-west — на площадке провайдера.

**ProjectSegment.** VLAN / SDN VNet проекта **на этой** ноде. Между VLAN клиентов на ноде
маршрута нет.

**SiteUnderlay.** Один туннель edge ↔ площадка (обычно WG). Не сеть клиента.

**ClusterOverlay.** CNI поверх NodeIP из ProjectNet. Не на `vmbr0` / WAN.

**Platform edge.** Системный роутер (VRF, туннели, published). Не Traefik, не CNI, не шлюз
гость↔гость.

**Изоляция на ноде.** Два Project на одном PVE — два VLAN, два ProjectNet, свои диски, свои
CIDR k8s. Общий ящик ≠ общая LAN.

## Цикл infra-агента

**Intent.** Структурированное желание (меню и/или чат). Не промпт как SoT.

**Plan.** Заявка vN: что создать, куда, зачем. Ревью, пока нет Approve. Чат без Approve Estate
не меняет.

**Approve.** Единственный переход к материализации. Сначала git-репо + Terraform; `tofu apply`
— следующий шаг через контроллер (0014), не из чата.

**Init.** Первый обход чужой/BYO инфры: RO-учётка, Inventory, галочки import. Greenfield —
Init не нужен. Ключ `partner` клиент не кладёт.

**Estate.** Реестр того, **чем управляем**. Зеркало tfstate. Не чат и не Inventory.

**Inventory.** Книга фактов: как контур выглядит (placement + гость + k8s). Ansible
`inventory.yml` из неё **выводится** после Approve.

**Два слоя create (P1).** Слой 1 — API облака (dedicated, белый IP) через `CloudAccount`.
Слой 2 — API PVE (VM, VLAN, vm-router) после SSH-init. Два state, два раннера, оба у нас
(0015.2 §7.1).

## Прочее, что часто путают

**Module CR.** Заявка 0014: роль + inventoryRef → Semaphore. Не Terraform-модуль и не папка
`04-roles`.

**`terraform-modules/`.** Модули коллекции (`site-proxmox` …), git-source в репо клиента
(0025). Не Module CR.

**Раннер.** Semaphore / `agent-job` на control plane. На ещё не существующем dedicated ему
жить негде.

**Open WebUI.** Чат с моделью. Intent/Plan не создаёт.
