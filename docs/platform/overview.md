# Платформа `platform/aicd*` — обзор (HLD / LLD / DD)

Персистентная k3s-инфраструктура, обслуживающая разработку и эксплуатацию коллекции
`devops.uslugi` (CI/CD, секреты, единая авторизация, наблюдаемость) — не демо-стенд
(`docs/adr/0006-demo-stand.md`) и не клиентская инфраструктура (`roles/*`). Архитектурное
решение целиком — `docs/adr/0012-cicd-platform-architecture.md`; реестр компонентов с их
собственными HLD/LLD/DD — [`README.md`](README.md).

Два независимых окружения одного и того же стека, без общего состояния между ними:

| | `platform/aicd` | `platform/aicd-devops-labs-ru` |
|---|---|---|
| Гипервизор | libvirt | Proxmox |
| Домен | `aicd.platform` | `aicd.devops-labs.ru` |
| Helm-релизы | `helm/envs/platform.yaml` | `helm/envs/platform-devops-labs-ru.yaml` |
| Values | `helm/values/platform/` | `helm/values/platform-devops-labs-ru/` |
| Ansible | `platform/aicd/ansible/site.yml` | `platform/aicd-devops-labs-ru/ansible/site.yml` |
| Terraform | `platform/aicd/terraform/` | `platform/aicd-devops-labs-ru/terraform/` |
| Отличие в составе | — (референсное окружение) | + agent-platform (ADR-0015/0021, нода `llm1` с GPU) |

Набор релизов, версии чартов и большинство values идентичны — расхождение между окружениями
сознательно минимизировано (см. `diff helm/envs/platform.yaml helm/envs/platform-devops-labs-ru.yaml`:
комментарии второго файла в основном ссылаются на первый вместо повторения). Ниже — архитектура,
общая для обоих, с явной пометкой мест расхождения.

## HLD — граф компонентов

```mermaid
graph TD
    OP["Оператор"]

    subgraph identity["Идентичность и доступ"]
        IPA["freeipa<br/>(каталог, персистентный)"]
        AU["Authelia<br/>(OIDC + forwardAuth)"]
    end

    subgraph secrets["Секреты"]
        BAO["OpenBao<br/>(KV + внутренний PKI CA)"]
    end

    subgraph cache["Кеш"]
        NX["Nexus<br/>(docker/apt/raw proxy)"]
    end

    subgraph git_ci["Git + CI"]
        GT["Gitea"]
        RUN["gitea-actions-runner"]
    end

    subgraph gitops["GitOps + исполнение"]
        FLUX["Flux2"]
        CTRL["platform-controller<br/>(Module CRD)"]
        SEM["Semaphore<br/>(Task Template)"]
    end

    subgraph ui["Витрина / диагностика"]
        RADAR["Radar"]
        PANEL["infra-panel"]
    end

    subgraph obs["Наблюдаемость"]
        VM["VictoriaMetrics"]
        GRAF["Grafana"]
    end

    subgraph agent["agent-platform (только aicd-devops-labs-ru)"]
        LLM["llama-server + TEI<br/>(нода llm1, GPU)"]
        LITELLM["LiteLLM<br/>(гейтвей)"]
    end

    OP -->|вход| AU
    AU -->|LDAP bind| IPA
    AU -->|OIDC| GT
    AU -->|OIDC| SEM
    AU -->|OIDC| GRAF
    AU -->|forwardAuth| RADAR
    AU -->|forwardAuth| PANEL

    BAO -.->|секреты + TLS| AU
    BAO -.->|секреты + TLS| GT
    BAO -.->|секреты + TLS| SEM
    BAO -.->|секреты + TLS| RADAR
    BAO -.->|секреты + TLS| PANEL
    BAO -.->|секреты + TLS| GRAF

    GT -->|регистрирует| RUN
    GT -->|источник манифестов| FLUX
    FLUX -->|apply| CTRL
    CTRL -->|Task API| SEM
    SEM -->|ansible-playbook| EXT["Внешние VM<br/>(freeipa, infra-panel-target, …)"]

    NX -.->|образы/пакеты| GT
    NX -.->|образы/пакеты| SEM
    NX -.->|образы/пакеты| RUN

    VM -.->|scrape| GT
    VM -.->|scrape| everything["весь namespace platform/cache/…"]
    GRAF --> VM

    LITELLM --> LLM

    style EXT fill:#f9f9f9,stroke:#999
```

*Пунктир — вспомогательная/фоновая связь (секреты, кеш, метрики), сплошная стрелка — прямая
рабочая зависимость. `agent-platform` — единственный блок, которого нет на `platform/aicd`
(подробности — [agent-platform.md](agent-platform.md)).*

## LLD — слои платформы

```mermaid
flowchart TD
    subgraph host["Control-host (вне кластера)"]
        ANSIBLE["ansible-playbook site.yml"]
        HELMWAVE["helmwave up<br/>(--templater gomplate)"]
        ANSIBLE --> HELMWAVE
    end

    subgraph k3s["k3s (одна control-plane нода)"]
        subgraph ns_platform["namespace: platform"]
            direction LR
            C1["openbao · gitea · gitea-actions-runner<br/>semaphore · radar · infra-panel · authelia"]
        end
        subgraph ns_cache["namespace: cache"]
            C2["nexus"]
        end
        subgraph ns_monitoring["namespace: monitoring"]
            C3["vm (VictoriaMetrics Operator)<br/>grafana-operator"]
        end
        subgraph ns_flux["namespace: flux-system"]
            C4["flux2"]
        end
        subgraph ns_gateway["namespace: gateway/llm/agents/…<br/>(только aicd-devops-labs-ru)"]
            C5["litellm · llama-server · tei"]
        end
        TRAEFIK["Traefik (встроенный в k3s)"]
    end

    subgraph vms["Внешние VM (не в k3s)"]
        VIPA["freeipa"]
        VTARGET["infra-panel-target, …<br/>(цели Semaphore/контроллера)"]
    end

    HELMWAVE -->|helm upgrade --install| ns_platform
    HELMWAVE --> ns_cache
    HELMWAVE --> ns_monitoring
    HELMWAVE --> ns_flux
    HELMWAVE --> ns_gateway

    ns_platform -->|values: vault:// datasource| BAO2["OpenBao (KV v2, PKI)"]
    ns_platform --> TRAEFIK
    ns_cache --> TRAEFIK

    ANSIBLE -->|Ansible-роли| VIPA
    C1 -->|Semaphore Task Template| VTARGET

    style ns_gateway fill:#f9f9f9,stroke:#999
```

*Рендер values — двухшаговый: `ansible-playbook` готовит предпосылки (секреты в OpenBao, PKI,
namespace для тех релизов, где создание не входит в `helmwave options.create_namespace`), затем
`helmwave up --templater gomplate` рендерит values-файлы (датасорс `vault://` читает секреты
живым HTTP-запросом к уже поднятому OpenBao в момент рендера, не подставляет их заранее) и
применяет Helm-релизы. Один `helmwave.<env>.yml` на окружение (гитигнорится, не общий файл —
находка `platform/aicd/README.md`, «Проверено реальным прогоном», п.2).*

## DD — физическое развёртывание

```mermaid
graph TB
    subgraph hv_a["platform/aicd — libvirt"]
        VM_A_CICD["VM cicd<br/>k3s control-plane + все Helm-релизы"]
        VM_A_IPA["VM freeipa<br/>(Rocky 9)"]
        VM_A_PANEL["VM infra-panel-target<br/>(Debian 12, 1vCPU/1GB)"]
    end

    subgraph hv_b["platform/aicd-devops-labs-ru — Proxmox"]
        VM_B_CICD["VM cicd<br/>k3s control-plane + все Helm-релизы"]
        VM_B_IPA["VM freeipa<br/>(Rocky 9)"]
        VM_B_LLM["VM/нода llm1<br/>GPU passthrough (RTX 5060 Ti)<br/>join как k3s agent, taint dedicated=agents"]
    end

    CTRLHOST["Control-host оператора<br/>(ansible, helmwave, gomplate, terraform)"]

    CTRLHOST -->|SSH + kubeconfig<br/>127.0.0.1→реальный IP ноды| VM_A_CICD
    CTRLHOST -->|SSH| VM_A_IPA
    CTRLHOST -->|SSH, через Semaphore/контроллер| VM_A_PANEL

    CTRLHOST -->|SSH + kubeconfig| VM_B_CICD
    CTRLHOST -->|SSH| VM_B_IPA
    CTRLHOST -->|k3s agent join<br/>K3S_URL/K3S_TOKEN| VM_B_LLM

    VM_A_CICD -.->|LDAP :389| VM_A_IPA
    VM_B_CICD -.->|LDAP :389| VM_B_IPA
    VM_B_CICD ---|один k3s-кластер, 2 ноды| VM_B_LLM
```

Ключевые физические свойства, общие для обоих окружений:

- **Одна control-plane нода** на кластер (`xanmanning.k3s`, `k3s_release_version: v1.35.1+k3s1`)
  — не HA. `platform/aicd-devops-labs-ru` — исключение: `llm1` присоединена **вторым узлом**
  того же кластера (не отдельным control-plane), изолирована `taint`
  (`dedicated=agents:NoSchedule`) и `RuntimeClass` (`nvidia`/`runsc`), см.
  [agent-platform.md](agent-platform.md).
- **freeipa — отдельная VM**, не под в k3s (LDAP/KDC/CA — не контейнеризуемая штатно роль
  коллекции, `docs/adr/0011-freeipa-role.md`) — единый каталог **для своего окружения**, между
  `aicd` и `aicd-devops-labs-ru` каталоги независимы (два разных человека с двумя разными
  паролями для одного и того же оператора, `docs/adr/0019-platform-rbac-model.md` §3).
- **Control-host не имеет прямого сетевого маршрута к ClusterIP** сервисов k3s — только к
  реальному IP ноды (объясняет `NodePort` у OpenBao, см. [openbao.md](openbao.md), и подмену
  `127.0.0.1` на реальный IP в kubeconfig, снятом `ansible.builtin.fetch`).
- **Дополнительные VM-цели** (`infra-panel-target` и будущие) заводятся отдельными
  terraform-ресурсами, не общим `for_each` — изменение shared-сети/cloudinit-шаблона не должно
  пересоздавать уже работающую control-plane VM (найдено реальным прогоном,
  `platform-controller/README.md`, «Фаза 5»). Эти VM применяются не `helmwave`, а
  Semaphore/платформенным контроллером ([platform-controller.md](platform-controller.md)) —
  они цель Ansible-ролей коллекции, а не Helm-релизов.

## Доступ к кластеру

Два независимых пути, оба существуют одновременно:

1. **Break-glass kubeconfig** (`/etc/rancher/k3s/k3s.yaml`, клиентский сертификат
   `system:masters`) — единственный реально работающий сегодня способ. Обходит RBAC целиком, не
   привязан к человеку, неотзываем без ротации CA кластера. Задокументированный, осознанно
   принятый на сегодня риск — `docs/adr/0020-kube-apiserver-oidc.md`, «Контекст».
2. **OIDC через Authelia** (`kubelogin`/`oidc-login`, structured `AuthenticationConfiguration`,
   группы `platform-*` → `ClusterRoleBinding` с префиксом `oidc:`) — **архитектурно решено,
   не реализовано** (`docs/adr/0020-kube-apiserver-oidc.md`, статус «Предложено»). Зависит от
   уже реализованных [freeipa.md](freeipa.md) (группы) и [authelia.md](authelia.md) (issuer).

## Ссылки

- `docs/adr/0012-cicd-platform-architecture.md` — исходное архитектурное решение (EE/Harbor,
  OpenBao вместо Vault, Gitea+раннер, Semaphore, размещение).
- `docs/adr/0014-platform-controller-architecture.md` — Module CRD, GitOps-reconcile,
  platform-controller.
- `docs/adr/0016-openbao-secrets-pki.md`, `0017-platform-cicd-default-addons.md`,
  `0018-internal-caching-proxy.md`, `0013-unified-auth-architecture.md`,
  `0019-platform-rbac-model.md`, `0020-kube-apiserver-oidc.md`, `0015-ai-agent-platform-architecture.md`,
  `0021-agent-platform-model-selection.md`, `0022-new-component-requirements.md` — решения по
  отдельным компонентам, см. соответствующие файлы в [README.md](README.md).
- `platform/aicd/README.md`, `platform/aicd-devops-labs-ru/README.md` — процедуры запуска,
  ручные шаги, история находок реальных прогонов.
- `docs/overview.md`, `docs/components.md` — коллекция в целом (роли `roles/*`), не платформа.
