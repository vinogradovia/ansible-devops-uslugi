# Подготовка cloud-init шаблонов Proxmox VE (Ubuntu, Rocky 9)

## Зачем это нужно

Terraform-код, разворачивающий VM на Proxmox (провайдер `bpg/proxmox`), не создаёт VM с нуля —
он клонирует уже готовый cloud-init-шаблон (`clone { vm_id = var.proxmox_template_vmid, full =
true }`). Диск, scsi-контроллер и сетевой интерфейс VM наследуются от шаблона автоматически, а
не описываются в terraform. Поэтому шаблон должен существовать на Proxmox-сервере заранее и
готовится вручную, отдельно от `terraform apply` — этот документ описывает, как именно.

Шаблоны создаются один раз на Proxmox-ноде (по SSH, под пользователем с правами `root`/`qm`),
не через Ansible-роли этой коллекции и не через Terraform.

## Общие требования к любому шаблону

- Образ — официальный cloud-init-ready qcow2/raw-образ дистрибутива (не установочный ISO).
- Диск на `scsi0`, контроллер `virtio-scsi-pci` — это то, что ожидает `interface = "scsi0"` в
  `vm.tf`; для другого диск-интерфейса шаблона нужно будет поправить terraform под него.
- Отдельный cloud-init-диск (`ide2`), datastore которого совпадает с датастором диска (обычно
  `local-lvm`) — это то, что клонирует provider как `proxmox_datastore_id`.
- `qemu-guest-agent` установлен и включён в образе — без него provider не может определить
  фактический IP VM при DHCP и `agent { enabled = true }` в `vm.tf` не имеет эффекта.
- Известный, задокументированный VMID шаблона — он передаётся в
  `var.proxmox_template_vmid` при разворачивании конкретного стенда/окружения.

Реальные значения атрибутов уже существующего шаблона (интерфейс диска, датастор, scsihw)
всегда можно проверить через API, не заходя на ноду:

```bash
curl -sk -H "Authorization: PVEAPIToken=<user>@<realm>!<token-id>=<uuid>" \
  https://<proxmox-ip>:8006/api2/json/nodes/<node>/qemu/<vmid>/config
```

## Часть 1: Ubuntu (cloud-init шаблон)

Выполняется на Proxmox-ноде по SSH. Пример — Ubuntu 24.04 LTS, VMID `9000` (тот VMID, который
по умолчанию ожидает `platform/aicd-devops-labs-ru/terraform/variables.tf`).

```bash
# 1. Скачать актуальный cloud-образ
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# 2. Создать пустую VM-заготовку (без диска — диск импортируется отдельно)
qm create 9000 \
  --name ubuntu-2404-cloudinit \
  --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26

# 3. Импортировать образ как диск в датастор (тот же датастор, что proxmox_datastore_id)
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm

# 4. Подключить импортированный диск через virtio-scsi-pci на scsi0
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0

# 5. Добавить cloud-init диск и выставить порядок загрузки
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot order=scsi0
qm set 9000 --serial0 socket --vga serial0

# 6. Включить qemu-guest-agent на уровне конфигурации VM
qm set 9000 --agent enabled=1

# 7. (опционально, но удобно для первичной диагностики) дефолтные cloud-init данные шаблона —
#    terraform всё равно переопределяет user/ключи/IP через initialization{} при клонировании
qm set 9000 --ciuser ubuntu --sshkeys ~/.ssh/authorized_keys.pub --ipconfig0 ip=dhcp

# 8. Конвертировать в шаблон (после этого VM больше нельзя запустить напрямую, только клонировать)
qm template 9000
```

Официальные cloud-образы Ubuntu уже включают пакет `qemu-guest-agent` и systemd-юнит
`qemu-guest-agent.service` в неактивном состоянии — `--agent enabled=1` на уровне VM
предоставляет гостю virtio-serial канал, cloud-init/systemd активирует агент при первом
включении клона без дополнительных действий.

## Часть 2: Rocky Linux 9 (cloud-init шаблон)

Тот же порядок действий, с поправками под RHEL-семейство.

**Автоматизация:** шаги ниже вынесены в плейбук
[`examples/playbooks/prepare-rocky9-template.yml`](../examples/playbooks/prepare-rocky9-template.yml)
(группа inventory `proxmox_hosts`, идемпотентен — пропускает сборку, если VMID уже существует).
Живой прогон (клиент wave/sel, 2026-10-04) нашёл нюанс, которого нет в ручных шагах ниже: на
dir-датасторе (`local`, без LVM — см. `terraform-modules/site-proxmox/README.md` про
проксnode1) `qm importdisk` создаёт volume-id вида `<storage>:<vmid>/vm-<vmid>-disk-0.raw`, а
не `<storage>:vm-<vmid>-disk-0`, как на LVM — плейбук вычисляет реальный volume-id из `qm
config` после импорта, не хардкодит его.

```bash
# 1. Скачать GenericCloud-образ Rocky 9
cd /var/lib/vz/template/iso
wget https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2

# 2. Заготовка VM — свободный VMID, отдельный от Ubuntu-шаблона (например, 9001)
qm create 9001 \
  --name rocky9-cloudinit \
  --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --ostype l26

# 3-6. Импорт диска, scsi/cloud-init/boot, guest agent — идентично шагам 3–6 для Ubuntu
qm importdisk 9001 Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 local-lvm
qm set 9001 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9001-disk-0
qm set 9001 --ide2 local-lvm:cloudinit
qm set 9001 --boot order=scsi0
qm set 9001 --serial0 socket --vga serial0
qm set 9001 --agent enabled=1
qm set 9001 --ciuser rocky --sshkeys ~/.ssh/authorized_keys.pub --ipconfig0 ip=dhcp

qm template 9001
```

**Известный нюанс RHEL-семейства (Rocky/CentOS/Alma) — `qemu-guest-agent` может не подняться
на первом boot.** В отличие от Debian/Ubuntu, где юнит `qemu-guest-agent.service` — no-op без
явного virtio-serial канала, на RHEL-семействе systemd-юнит зависит от udev-события на
`/dev/virtio-ports/org.qemu.guest_agent.0` и падает с `Dependency failed for QEMU Guest Agent`,
если канал не объявлен явно на уровне гипервизора. На Proxmox `qm set <vmid> --agent enabled=1`
сам создаёт нужный virtio-serial канал (в отличие, например, от голого libvirt-домена, где канал
нужно объявлять отдельным ресурсом) — при клонировании шаблона, подготовленного этим способом,
проблема встречаться не должна. Если после клона `qm agent <vmid> ping` не отвечает —
первым делом проверить именно наличие `--agent enabled=1` у самой VM (не только у шаблона: этот
флаг наследуется при клонировании, но его стоит перепроверить), и что пакет `qemu-guest-agent`
в образе включён в автозагрузку (`systemctl is-enabled qemu-guest-agent` внутри гостя).

SELinux в GenericCloud-образе Rocky 9 включён в `enforcing` по умолчанию — Ansible-роли,
устанавливаемые на такие VM (например, `freeipa`), должны либо учитывать SELinux-контексты,
либо явно документировать, что требуют `permissive`/установку нужных политик.

**Resize диска после клонирования (обоих образов) не требует ручного `growpart`/`resize2fs`.**
Подтверждено живым прогоном (клиент wave/sel, 2026-10-04): после онлайн-resize диска на уровне
Proxmox (`disk.size` в terraform-модуле/`qm resize`) root-ФС внутри гостя выросла сама, без
перезагрузки — на Ubuntu 24.04 cloud-image и на Rocky 9 GenericCloud одинаково. Причина —
модуль `cc_growpart` в обоих образах стоит с `frequency: always` в `/etc/cloud/cloud.cfg` по
умолчанию (upstream-поведение образа, не настройка этой коллекции) — см. ROADMAP.md Backlog
№70. Поэтому роли коллекции и клиентские `site.yml` не должны добавлять свои задачи
`growpart`/`resize2fs` — это дублирование уже работающего механизма.

## Часть 3: Проверка шаблона перед использованием в terraform

Перед тем как ссылаться на новый шаблон из `proxmox_template_vmid`, стоит вручную клонировать
его и убедиться, что cloud-init и guest agent реально работают:

```bash
qm clone 9001 9999 --full --name test-rocky9-clone
qm start 9999
# подождать boot, затем:
qm agent 9999 ping        # успешный ответ подтверждает, что guest agent поднялся
qm agent 9999 network-get-interfaces   # реальный IP, который использовал бы terraform provider
ssh rocky@<полученный-ip>              # cloud-init действительно применил ключ/пользователя

qm stop 9999 && qm destroy 9999
```

## Где используются подготовленные шаблоны

- `platform/aicd-devops-labs-ru/terraform/vm.tf` — клонирует Ubuntu-шаблон VMID `9000`
  (`var.proxmox_template_vmid`), уже подготовленный по этому документу.
- Развёртывание `freeipa` на этом же окружении (единая авторизация, LDAP-каталог) заблокировано
  отсутствием готового Rocky 9 Proxmox-шаблона — см. `ROADMAP.md`, пункт про единую систему
  авторизации. Часть 2 этого документа закрывает именно этот пререквизит.

## Права доступа

Создание и конвертация шаблона (`qm create`/`qm importdisk`/`qm template`) выполняется
интерактивно на самой Proxmox-ноде под пользователем с достаточными правами (`root@pam` или
эквивалент) — это ручная операция оператора, не автоматизация через API-токен terraform.
Права API-токена, которым Terraform клонирует шаблон в новую VM (`VM.Clone`,
`Datastore.AllocateSpace`, `SDN.Use` и т.д.), — отдельный вопрос, не связанный с подготовкой
самого шаблона, и настраиваются на стороне terraform-окружения.
