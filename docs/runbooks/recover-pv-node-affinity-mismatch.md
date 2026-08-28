# Восстановление PV после смены имени узла (nodeAffinity mismatch)

Для кого этот документ: оператор с доступом к k3s-кластеру платформенного окружения
(`platform/aicd` или `platform/aicd-devops-labs-ru`), столкнувшийся с тем, что после перезагрузки
или пересоздания единственной control-plane-ноды несколько подов с `local-path`-хранилищем
намертво зависли в `Pending`.

## Симптом

```
kubectl get pods -n platform
# openbao-0, gitea, semaphore, authelia (или любой другой под с PVC) — Pending, давно

kubectl describe pod <под> -n platform
# Warning  FailedScheduling  ...  0/1 nodes are available: 1 node(s) had volume node affinity conflict.
```

`kubectl get pv <имя> -o yaml` показывает `spec.nodeAffinity...values` со значением, которое
**не совпадает** с текущим именем ноды в `kubectl get nodes`.

## Почему это происходит

`local-path-provisioner` (штатный storage-provisioner k3s, `storageClassName: local-path`,
используемый везде в этой коллекции для стейта платформенных сервисов) при создании PV
записывает в `spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values` имя
ноды, на которой физически лежит каталог (`spec.local.path`), — **на момент создания PV**. Если
впоследствии единственная нода кластера была пересоздана/переименована (например, живой `tofu
apply`, меняющий RAM VM, потребовал перезагрузки гостя, и control-plane нода зарегистрировалась в
k3s под другим именем, чем при первом провижининге — так возникла эта ситуация 2026-08-28 на
`platform/aicd-devops-labs-ru`) — Kubernetes регистрирует узел заново под новым именем. Все
существующие PV продолжают ссылаться на старое, уже не существующее имя.

`kubernetes.io/hostname` в `nodeAffinity` — **иммутабельное поле PersistentVolume**. Прямой
`kubectl patch`/`edit` завершится ошибкой API:

```
field is invalid: nodeAffinity: ... field is immutable, except for updating from beta label to GA
```

Единственный путь — пересоздать объект PV (не трогая данные на диске, они по указанному
`spec.local.path` остаются нетронутыми).

## Диагностика перед началом

```bash
kubectl get nodes                                    # актуальное имя ноды
kubectl get pv -o custom-columns='NAME:.metadata.name,CLAIM:.spec.claimRef.name,AFFINITY:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values'
```

Сравните колонку `AFFINITY` со списком из `kubectl get nodes` — все несовпадающие PV подлежат
восстановлению по процедуре ниже. Убедитесь, что каталог данных на ноде физически на месте (не
трогайте, только проверьте):

```bash
ls -la /var/lib/rancher/k3s/storage/ | grep <suffix из имени PV>
```

## Процедура (один PV за раз, с проверкой между шагами)

**Не выполняйте все 4 PV параллельно** — восстановление корневых сервисов (OpenBao, каталог
авторизации) по отдельности проще диагностировать, если что-то пойдёт не так. Ниже — пример на
`data-openbao-0` (namespace `platform`); для остальных — та же последовательность с другими
именами.

### 1. Определить владельца пода и его текущее число реплик

```bash
kubectl get pod <под> -n platform -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}{"\n"}'
```

StatefulSet (например, `openbao`) или Deployment (например, `gitea`, `semaphore-semaphore`,
`authelia-authelia` — в этой платформе Deployment создаётся собственным `universal-chart`, а не
официальным чартом с `volumeClaimTemplates`).

### 2. Смасштабировать владельца до 0

**Обязательный шаг, не пропускать.** PVC защищён finalizer'ом `kubernetes.io/pvc-protection`,
который не даст удалить PVC, пока на него ссылается хоть один под — включая `Pending`-под.
Удаление самого пода не помогает: контроллер (Deployment/StatefulSet) тут же создаст новый под с
той же ссылкой на PVC, и `kubectl delete pvc` зависнет/не выполнится. Единственный надёжный способ
убрать ссылающийся под — сказать контроллеру, что реплик должно быть 0:

```bash
kubectl scale statefulset openbao -n platform --replicas=0   # или: kubectl scale deploy <имя> -n platform --replicas=0
```

Дождитесь, что под исчез (`kubectl get pods -n platform`).

### 3. Защитить данные: `persistentVolumeReclaimPolicy` → `Retain`

`persistentVolumeReclaimPolicy` (в отличие от `nodeAffinity`) — мутабельное поле. Патчим его
**до** удаления PVC, чтобы reclaim-контроллер `local-path-provisioner` не удалил каталог с данными
на диске, когда PV перейдёт в фазу `Released`:

```bash
kubectl patch pv <имя-pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

### 4. Удалить PVC, затем (после перехода PV в `Released`) сам PV

```bash
kubectl delete pvc <имя-pvc> -n platform
kubectl get pv <имя-pv>              # убедиться STATUS=Released, не Bound
kubectl delete pv <имя-pv>
```

### 5. Перед пересозданием — сохранить точные поля старых объектов

**До удаления** (шаг 4) стоит сохранить полный YAML обоих объектов (`kubectl get pv/pvc ... -o
yaml`), чтобы пересоздать их один в один, кроме `nodeAffinity`. Важные поля, которые нужно
перенести без изменений:

- PV: `spec.capacity.storage`, `spec.local.path` (**не менять** — это путь к уже существующим
  данным), `spec.accessModes`, `spec.storageClassName`, `spec.volumeMode`,
  `spec.persistentVolumeReclaimPolicy` (после восстановления возвращается в исходное значение —
  как правило `Delete`, если явно не решено иначе; `Retain` из шага 3 был временной мерой защиты
  на время самой операции, а не целевым состоянием).
- PVC: `metadata.name`, `metadata.namespace`, `metadata.labels`, `spec.accessModes`,
  `spec.resources.requests.storage`, `spec.storageClassName`, `spec.volumeMode`.
- **PVC, управляемые Deployment'ом через `universal-chart` этой коллекции (gitea, semaphore,
  authelia — не openbao), несут аннотации владения Helm** (`meta.helm.sh/release-name`,
  `meta.helm.sh/release-namespace`, иногда `helm.sh/resource-policy: keep`) — их обязательно
  перенести на новый PVC, иначе следующий `helmwave up` не сможет корректно адоптировать
  существующий ресурс (Helm 3 проверяет эти аннотации перед тем, как считать объект «своим»).
  PVC, созданные из `volumeClaimTemplates` StatefulSet'а (openbao), таких аннотаций не имеют —
  это ожидаемо, не ошибка.
- Аннотации `local.path.provisioner/selected-node` (PV) и `volume.kubernetes.io/selected-node`
  (PVC) — не обязательны функционально, но стоит обновить на актуальное имя ноды для консистентности.

### 6. Создать новый PV с исправленным `nodeAffinity`

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <то же имя, что было>
  annotations:
    local.path.provisioner/selected-node: <новое имя ноды>
    pv.kubernetes.io/provisioned-by: rancher.io/local-path
spec:
  accessModes: [ReadWriteOnce]
  capacity:
    storage: <как было>
  local:
    path: <точно как было — тот же каталог с данными>
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <новое имя ноды>
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-path
  volumeMode: Filesystem
```

### 7. Создать новый PVC с явным `volumeName` (pre-bind)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <то же имя, что было>
  namespace: platform
  annotations:
    # только если было — см. шаг 5
    meta.helm.sh/release-name: <release>
    meta.helm.sh/release-namespace: platform
  labels:
    <как было>
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: <как было>
  storageClassName: local-path
  volumeMode: Filesystem
  volumeName: <то же имя PV — форсирует привязку именно к нему, а не к новому динамически>
```

`spec.volumeName` — ключевое поле: без него PVC уйдёт в обычный динамический provisioning и
получит **новый пустой** том вместо привязки к тому, где остались старые данные.

Применить оба (`kubectl apply -f`), проверить `STATUS=Bound` у обоих.

### 8. Вернуть исходное число реплик и проверить под

```bash
kubectl scale statefulset openbao -n platform --replicas=1   # или deploy, как в шаге 1
kubectl get pod <под> -n platform -o wide      # NODE = актуальное имя, STATUS движется к Running
kubectl logs <под> -n platform                 # данные читаются (для БД/хранилищ — успешная загрузка старого состояния, не пустая инициализация)
```

Признак успеха — под стартует **без** повторной инициализации (например, OpenBao поднимает
существующий raft-каталог и остаётся лишь sealed — это ожидаемо и лечится штатной
идемпотентной unseal-автоматикой `site.yml`, не требует отдельных действий; Gitea видит
существующего `gitea_admin` в SQLite вместо создания нового).

### 9. Повторить для следующего PV

Только после того как предыдущий под подтверждённо `Running`/данные на месте — переходить к
следующему. Один сломанный PV не мешает чинить остальные независимо друг от друга (кроме
каскадных зависимостей на уровне приложений — см. ниже).

## Каскадные эффекты между сервисами

Некоторые поды зависят друг от друга **логически**, не только через `nodeAffinity`. Например,
init-контейнер Gitea при каждом старте синхронизирует свою запись OIDC-провайдера с Authelia
(`.well-known/openid-configuration`) — если Authelia в это время ещё не поднята (её PV не
восстановлен), Gitea будет падать на `Init:Error` с `Non-success code for Discovery URL: 503`,
**даже если её собственный PV/PVC полностью восстановлены корректно**. Это не отдельная проблема —
под перейдёт в `Running` сам по себе (Deployment продолжает ретраить под) сразу после того, как
Authelia тоже восстановлена. Восстанавливайте сервисы каталога авторизации (`authelia`) не позже
остальных, чтобы не тратить время на диагностику мнимых проблем в других сервисах.

## После восстановления всех PV

Возобновите (или запустите заново — идемпотентно) `ansible-playbook site.yml` соответствующего
окружения: он идемпотентно распечатает (unseal) OpenBao и приведёт остальные ресурсы кластера в
соответствие конфигурации, если прогон был прерван на этом инциденте.
