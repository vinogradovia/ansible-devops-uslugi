# ADR-0017: Стандартный набор аддонов для k3s-стенда platform/cicd

- **Статус:** Принято
- **Дата:** 2026-08-25
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

K3s-нода `platform/cicd` (ADR-0012, ADR-0014, ADR-0016) до этого ADR разворачивала ровно четыре
Helm-релиза (`openbao`, `gitea`, `semaphore`, `flux2`, все — `helm/envs/platform.yaml`), и все они
обязательные: понятия "опциональный компонент" в `site.yml`/`envs/platform.yaml` не было —
второй вызов `helmwave up` ставил безусловно всё, что перечислено в файле окружения.

Требуется стандартный набор дополнительных инструментов, которые ставятся на стенд по умолчанию,
но которые можно переопределить (добавить сверх набора или исключить конкретный) без правки
`site.yml`/`envs/platform.yaml`. Первый кандидат в этот набор — [Radar](https://github.com/skyhook-io/radar),
open-source Kubernetes UI (топология, ресурсы, Helm/GitOps-диагностика, чарт `skyhook/radar`).

## Решения

### 1. Механизм "дефолт + оверрайд" — group_vars + helmwave `--tags`, без нового кода

**Решение:** новый файл `platform/cicd/ansible/group_vars/platform_hosts.yml` (директория была
зарезервирована под это с самого начала — комментарий в `inventory.yml`, «Переменные роли — в
`../ansible/group_vars/*.yml`»):

```yaml
platform_cicd_core_releases: [openbao, gitea, semaphore, flux2]
platform_cicd_default_addons: [radar]
platform_cicd_extra_addons: []
platform_cicd_disabled_addons: []
platform_cicd_enabled_addons: >-
  {{ (platform_cicd_default_addons + platform_cicd_extra_addons)
     | unique | difference(platform_cicd_disabled_addons) }}
```

Второй `helmwave up` в `site.yml` получил
`--tags "{{ (platform_cicd_core_releases + platform_cicd_enabled_addons) | join(',') }}"`.

**Обоснование:** helmwave уже автоматически тегирует каждый релиз его собственным именем
(`helm/helmwave.yml.tpl:76-78`), поэтому выборочная установка не требует ничего дописывать в
`envs/platform.yaml` — достаточно передать список нужных имён релизов через `--tags`. Это тот же
принцип, что уже применён в `roles/monitoring_server/defaults/main.yml`
(`monitoring_server_helmwave_tags`/`monitoring_server_helmwave_other_tags`,
`docs/adr/0007-monitoring-server-role.md` §6) — не изобретается параллельный механизм.

Переопределение — обычные ansible-переменные (`-e platform_cicd_disabled_addons=[radar]` или
правка `group_vars/platform_hosts.yml`), без необходимости трогать `helm/envs/platform.yaml`.

**Проверено реальным прогоном — важная асимметрия семантики `disabled_addons`.** `helmwave up
--tags` строит план ТОЛЬКО из релизов, прошедших фильтр по тегам — уже установленный, но
выпавший из фильтра релиз в план не попадает вообще, и helmwave его никак не трогает (не
обновляет, но и не удаляет). Реальный прогон с `-e platform_cicd_disabled_addons=[radar]` на уже
развёрнутом Radar подтвердил: `Releases Success 4 / 4` (без radar), под/Ingress/Secret Radar при
этом остались работать без изменений — helm-релиз просто перестал быть управляемым этим
прогоном. Значит `disabled_addons`/удаление из `default_addons`:
- **до** первой установки аддона — предотвращает его установку (работает как ожидается);
- **после** установки — не удаляет уже развёрнутый релиз, а лишь замораживает его (перестают
  применяться новые версии чарта/values). Для реального удаления нужен отдельный ручной шаг —
  `helmwave down --tags radar` или `helm uninstall radar -n platform` — это ansible-код
  сознательно не делает сам (удаление стороннего workload — не то же самое, что невключение
  нового, более рискованное действие для автоматизации без явного подтверждения оператора).

### 2. Radar — первый аддон, RBAC/auth-профиль

**Решение:** релиз `radar` (репозиторий `https://skyhook-io.github.io/helm-charts`, чарт
`skyhook/radar`, версия `1.11.0`) добавлен в `helm/envs/platform.yaml`. RBAC — дефолты чарта
(`rbac.secrets: false`, `rbac.helm: false`, `rbac.podExec: false`, `rbac.portForward: false`,
read-only `ClusterRole` на остальные ресурсы) оставлены как есть, без ослабления — Radar не
получает доступ к Kubernetes Secrets и не может изменять ресурсы через Helm, несмотря на то что
делит кластер с OpenBao, хранящим секреты всей платформы.

Аутентификация — `auth.mode: none` (дефолт чарта, встроенных `proxy`/`oidc` не используем), вход
защищён на уровне Traefik: `Middleware radar-basic-auth` (`traefik.io/v1alpha1`) + `Secret
radar-basic-auth` с htpasswd-содержимым, тот же приём, что уже применён для дашбордов
`infra_panel`/`reverse_proxy_traefik` (`community.general.htpasswd` на control-хосте). Пароль не
хардкод — читается/генерируется в уже поднятом OpenBao (`secret/radar`, тот же идемпотентный
check-404-then-generate шаблон, что `secret/gitea`/`secret/semaphore`, ADR-0016 §3). TLS —
`Secret radar-tls`, выпущен из того же внутреннего PKI CA, что `gitea-tls`/`semaphore-tls`
(переиспользован существующий цикл `tasks/issue-tls-cert.yml`, просто добавлен третий элемент
`loop`).

**Обоснование:** Radar размещается на кластере, критичном для платформы (там же OpenBao), поэтому
намеренно НЕ ослабляются дефолтные RBAC-ограничения чарта ради удобства (никакого
`rbac.secrets: true`/`rbac.helm: true`), и вход закрыт тем же способом, что уже проверен на других
внутренних дашбордах коллекции — не вводится новый паттерн авторизации специально под один сервис.

## Не проработано

- RBAC-профиль Radar не тюнится тоньше дефолтов чарта (например, `crdGroups` оставлены все
  включены по умолчанию — безвредно для CRD, которых нет в кластере, но не пересмотрено под
  конкретный состав `platform/cicd`).
- Нет отдельного ADR на каждый будущий аддон — при росте `platform_cicd_default_addons` за
  пределы одного-двух пунктов имеет смысл пересмотреть, стоит ли документировать каждый отдельно
  или продолжать расширять этот ADR.
- Basic-auth (общий пароль admin) — та же модель, что уже принята для
  `infra_panel`/`reverse_proxy_traefik`; per-user доступ (`auth.mode: oidc` чарта Radar, например
  поверх `freeipa`, ADR-0011) не рассматривался.

## Ссылки

- `docs/adr/0016-openbao-secrets-pki.md` — источник секрета (`secret/radar`) и PKI CA
  (`radar-tls`), которыми пользуется этот ADR.
- `docs/adr/0007-monitoring-server-role.md` §6 — прецедент `monitoring_server_helmwave_tags`,
  повторённый здесь как `platform_cicd_enabled_addons`.
- `docs/adr/0008-infra-panel-role.md` — прецедент basic-auth через Traefik Middleware +
  `community.general.htpasswd` для внутреннего дашборда.
- `docs/adr/0014-platform-controller-architecture.md` — платформенный контроллер, не затронут
  этим ADR (Radar — операторский инструмент, не Module).
